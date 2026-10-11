defmodule Apiary.Runs.Ingest do
  @moduledoc """
  Stores a verified delivery: the receiving side of the record.

  `ingest/3` takes the access key the request was verified under, the parsed
  batch and what the request's headers said, and in one transaction creates the
  run in the key's workspace when its subject is new, inserts the events that are
  new, records the delivery and counts. It projects nothing: once the
  transaction has committed, the use of the key is recorded, the projector is
  asked to project the run on its own time, and the caller answers.

  Delivery is at least once and in any order, so nothing here is an error that
  the gateway could cause by sending again: an event already stored is skipped, a
  delivery already recorded is answered as before, and an event that collides
  with another (its id under a different run, or its sequence under a different
  id) is dropped and counted.

  **Where a run runs.** A run starts by its registration (`Apiary.Runs.Registration`),
  which the node's instance limit admits (`Apiary.Nodes.admit/4`) and which creates its
  row: its batches are stored on that row and admitted by nothing again. A batch of a run
  the workspace does not hold creates it, on the node of the key it came with and the
  instance id it claimed (`Apiary.Nodes.placement/2`), both fixed from then on, and held
  to no limit; each delivery records its instance id too.

  **Who may send.** A run's batches, its heartbeats among them, are taken only from the
  active keys of the node or node pool it is bound to (`Apiary.Runs.Sender`): the node
  whose key registered it, or whose key's batch opened it. A batch of a run of another
  node is refused whole, `{:error, :wrong_node}`, and nothing of it is stored: a batch is
  one run's, every event's subject the same.

  **The end.** Once the run's starter has given its outcome (`Apiary.Runs.Outcome`), every
  answer for the run says so, `end` in the result, until the run's `dev.qory.run.exited`
  arrives: the answer to the batch that carries it, and to every batch after, has none.

  Nothing of the request's headers but the versions, the instance id and the run
  configuration digest is stored, and nothing of an event is logged: the insert of the
  events is kept out of the query log.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Nodes}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Policy.Serving
  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Delivery, Event, Projector, Run, Sender}

  @digest ~r/\Asha256=[0-9a-f]{64}\z/
  @log "dev.qory.run.log"
  @exited "dev.qory.run.exited"
  @insert_chunk 500

  @typedoc """
  What the request said beside its body: `contract_version`, the revision of
  `X-Qory-Contract-Version`, which the gateway sends on every request and the events
  endpoint has checked; `delivery_id` (`X-Qory-Delivery`; one is made up when it is
  absent or not a UUID), `forager_version`, `run_configuration`
  (`X-Qory-Run-Configuration`) and `instance_id` (`X-Qory-Instance-Id`, as the request
  verified it), each nil when not sent.
  """
  @type meta :: %{
          required(:contract_version) => pos_integer,
          optional(:delivery_id) => String.t() | nil,
          optional(:instance_id) => String.t() | nil,
          optional(:forager_version) => String.t() | nil,
          optional(:run_configuration) => String.t() | nil
        }

  @doc """
  Stores the batch. `{:ok, result}` with `status` 202, or 410 when retention has pruned
  the run's events (`runs.events_pruned_at`) and nothing but the delivery was recorded;
  `inserted` events were new, `duplicates` were already held, `conflicts` were dropped,
  and `repeated` says the delivery id had been recorded before; `managed` says whether
  the workspace serves a run configuration (nil when that could not be read) and
  `run_configuration_digest` is the digest in force for the run's target, for the
  answer's headers (nil for a workspace that is not managed, and when it could not be
  read); `end` is the run's outcome, `%{state: state, reason: reason}` (reason nil when it
  gave none), while the run has one and no `dev.qory.run.exited` has arrived, else nil.
  `{:error, :unavailable}` when the batch could not be stored, `{:error, :not_found}` when
  the key may not post (`run.post_events` in `Apiary.Access`), `{:error, :wrong_node}`
  when the run is another node's (`Apiary.Runs.Sender`), with nothing stored.

  The digest the request reported (`meta.run_configuration`) is kept on the delivery
  and, as the last one reported, on the run. The digest in force is read after the
  commit, outside the run's lock, and never rendered: a read that says the workspace is
  managed, then one read of an index for the digest, two when the run's target has
  no configuration of its own and the baseline's is read after it.
  """
  @spec ingest(AccessKey.t(), Batch.t(), meta) ::
          {:ok, map}
          | {:error, :unavailable | :not_found | :wrong_node | :wrong_gateway | :unauthorized}
  def ingest(%AccessKey{} = access_key, %Batch{} = batch, %{contract_version: _} = meta) do
    now = DateTime.utc_now()
    delivery_id = delivery_id(meta)
    # A verified key carries its workspace and node; one that does not is given them here.
    access_key = Repo.preload(access_key, [:workspace, :node])
    scope = Scope.for_access_key(access_key)

    with :ok <- may_post(scope),
         {:ok, result} <- transact(access_key, batch, meta, delivery_id, now) do
      if not result.repeated, do: touch(access_key, meta, now)
      if result.conflicts > 0, do: log_conflicts(result)
      if result.status == 202, do: Projector.project_async(result.run)

      {:ok, Map.merge(result, in_force(place(result.run, access_key), result.run, batch, meta))}
    end
  end

  # What is read for the run is read under its own place, a gateway's batch's too.
  defp place(%Run{} = run, access_key), do: Sender.place_key(run, access_key)
  defp place(nil, access_key), do: access_key

  # A key's scope is never refused a role here; what can refuse it is a feature that is off.
  defp may_post(scope) do
    case Access.authorize(scope, :"run.post_events", scope.workspace) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # What the answer's digests are decided by, read after the commit and never failing the
  # delivery: whether the workspace's policy is managed (nil when that could not be read),
  # and, for a managed workspace, the digest of the run configuration in force for the
  # run.
  defp in_force(access_key, run, batch, meta) do
    if Serving.managed?(access_key) do
      digest = Serving.digest_for(access_key, run, batch, run_configuration(meta))
      %{managed: true, run_configuration_digest: digest}
    else
      %{managed: false, run_configuration_digest: nil}
    end
  rescue
    _exception -> %{managed: nil, run_configuration_digest: nil}
  end

  # Whatever the database refuses or cannot do is `{:error, :unavailable}`, a
  # 503 the gateway retries, never an exception into the request. The log line
  # names the exception's module and nothing else: a Postgres message can
  # quote the row, which is an event.
  defp transact(access_key, batch, meta, delivery_id, now) do
    Repo.transact(fn -> store(access_key, batch, meta, delivery_id, now) end)
  rescue
    exception ->
      Logger.error("a delivery could not be stored: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  defp store(access_key, batch, meta, delivery_id, now) do
    run = held(access_key, batch, meta, now)

    cond do
      # A gateway's batch of a run that is not one it attached: a gateway opens no run.
      is_nil(run) ->
        {:error, :wrong_gateway}

      # Another node's run: refused whole, before anything of the batch is recorded, and
      # the transaction rolls back.
      not Sender.may_send?(run, access_key) ->
        {:error, Sender.refusal(run)}

      # A run through a gateway is held to its own place, as a key of it would be.
      (refused = place_refusal(run, access_key)) != :ok ->
        refused

      # Retention deleted the run's events, and with them what a replay would be
      # deduplicated against: the workspace wants nothing more of this run.
      not is_nil(run.events_pruned_at) ->
        {:ok, gone(access_key, run, batch, meta, delivery_id, now)}

      not new_delivery?(access_key, run, batch, meta, delivery_id, now) ->
        {:ok, %{result(202, run) | repeated: true, end: run_end(run, batch)}}

      true ->
        {stored_batch, pruned} = without_pruned_log(run, batch)
        {inserted, duplicates, conflicts} = insert_events(run, stored_batch, now)
        record_delivery(access_key, delivery_id, inserted)
        run = count(run, inserted, run_configuration(meta), now)

        {:ok,
         %{
           result(202, run)
           | inserted: inserted,
             duplicates: duplicates + pruned,
             conflicts: conflicts,
             end: run_end(run, batch)
         }}
    end
  end

  # The run's outcome, while the run has one and its exit has not arrived: not in this
  # batch, and not among the events it holds. Read under the run's lock, so an outcome
  # stored meanwhile is seen by the next answer.
  defp run_end(%Run{outcome_state: nil}, _batch), do: nil

  defp run_end(%Run{} = run, %Batch{events: events}) do
    exited? =
      Enum.any?(events, &(&1.type == @exited)) or
        Repo.exists?(from e in Event, where: e.run_id == ^run.id and e.type == @exited)

    if not exited?, do: %{state: run.outcome_state, reason: run.outcome_reason}
  end

  # A run whose log retention has pruned takes no more log events: the ones it had are
  # gone, so a replay of them could not be told from new ones, and any that is new is
  # older than the workspace keeps log output. They are answered as duplicates; every
  # other event is still deduplicated against the events the run keeps.
  defp without_pruned_log(%Run{log_pruned_at: nil}, batch), do: {batch, 0}

  defp without_pruned_log(%Run{}, %Batch{events: events} = batch) do
    kept = Enum.reject(events, &(&1.type == @log))
    {%{batch | events: kept}, length(events) - length(kept)}
  end

  # Retention has pruned the run's events: the delivery is recorded, nothing else is
  # kept.
  defp gone(access_key, run, batch, meta, delivery_id, now) do
    repeated = not new_delivery?(access_key, run, batch, meta, delivery_id, now, 410)
    %{result(410, nil) | repeated: repeated}
  end

  # The run of the batch, its row locked: a gateway's batch finds a run it attached, by the
  # gateway and the run's id, and opens none; it finds a run of its own workspace that is
  # not one through it only to be refused with that run's code. Any other key's batch
  # finds its workspace's run, or opens it.
  defp held(%AccessKey{node: %Nodes.Node{kind: :gateway}} = access_key, batch, _meta, _now) do
    Repo.one(Sender.run_query(access_key, batch.subject, lock: true)) ||
      Repo.one(
        from r in Run,
          where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^batch.subject
      )
  end

  defp held(access_key, batch, meta, now), do: upsert_run(access_key, batch, meta, now)

  # The run's own organisation and workspace, for a run through a gateway, whose key may
  # be of another place: out of use is refused as a key of it would be, and a feature that
  # is off there as a path that does not exist.
  defp place_refusal(run, access_key) do
    cond do
      not Run.through_gateway?(run) ->
        :ok

      not AccessKeys.place_in_use?(run.organisation_id, run.workspace_id) ->
        {:error, :unauthorized}

      true ->
        may_post(Scope.for_access_key(Sender.place_key(run, access_key)))
    end
  end

  defp result(status, run) do
    %{
      status: status,
      run: run,
      inserted: 0,
      duplicates: 0,
      conflicts: 0,
      repeated: false,
      end: nil
    }
  end

  # Two first batches of one run may arrive at once: the insert that loses waits
  # for the one that wins and inserts nothing, and the read after it sees the row.
  # The read locks the row for the rest of the transaction.
  defp upsert_run(access_key, batch, meta, now) do
    Repo.insert_all(
      Run,
      [
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            organisation_id: access_key.organisation_id,
            workspace_id: access_key.workspace_id,
            run_id: batch.subject,
            access_key_id: access_key.id,
            state: "pending",
            forager_version: meta[:forager_version],
            contract_version: meta.contract_version,
            inserted_at: now,
            updated_at: now
          },
          placement(access_key, meta)
        )
      ],
      on_conflict: :nothing,
      conflict_target: [:workspace_id, :run_id]
    )

    Repo.one!(
      from r in Run,
        where: r.workspace_id == ^access_key.workspace_id and r.run_id == ^batch.subject,
        lock: "FOR UPDATE"
    )
  end

  # The delivery is inserted first with nothing counted, so a delivery id seen
  # before is known before any event is touched. It is the run's workspace's, whichever
  # key posted it.
  defp new_delivery?(access_key, run, batch, meta, delivery_id, now, status \\ 202) do
    {count, _} =
      Repo.insert_all(
        Delivery,
        [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: run.organisation_id,
            workspace_id: run.workspace_id,
            access_key_id: access_key.id,
            delivery_id: delivery_id,
            run_id: batch.subject,
            received_at: now,
            event_count: length(batch.events),
            inserted_count: 0,
            status: status,
            run_configuration_digest: run_configuration(meta),
            instance_id: placement(access_key, meta).instance_id
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:access_key_id, :delivery_id]
      )

    count == 1
  end

  defp record_delivery(_access_key, _delivery_id, 0), do: :ok

  defp record_delivery(access_key, delivery_id, inserted) do
    Repo.update_all(
      from(d in Delivery,
        where: d.access_key_id == ^access_key.id and d.delivery_id == ^delivery_id
      ),
      set: [inserted_count: inserted]
    )
  end

  defp insert_events(run, batch, now) do
    rows =
      Enum.map(batch.events, fn event ->
        %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          sequence: event.sequence,
          event_id: event.event_id,
          type: event.type,
          time: event.time,
          data: event.data,
          received_at: now
        }
      end)

    # In sequence order, so two deliveries that overlap take their locks in the
    # same order; in chunks, far under the parameters one statement may carry.
    {inserted, stored} =
      rows
      |> Enum.sort_by(& &1.sequence)
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.reduce({0, []}, fn chunk, {count, stored} ->
        {inserted, returned} =
          Repo.insert_all(Event, chunk,
            on_conflict: :nothing,
            returning: [:event_id],
            log: false
          )

        {count + inserted, returned ++ stored}
      end)

    skipped = length(rows) - inserted
    conflicts = if skipped > 0, do: conflicts(run, rows, stored), else: 0
    {inserted, skipped - conflicts, conflicts}
  end

  # An event that was not inserted is a duplicate when the workspace holds the same id
  # in the same run at the same sequence, and a conflict otherwise: its id is
  # another run's, or its sequence is another event's.
  defp conflicts(run, rows, stored) do
    stored = MapSet.new(stored, & &1.event_id)
    skipped = Enum.reject(rows, &MapSet.member?(stored, &1.event_id))
    ids = Enum.map(skipped, & &1.event_id)

    held =
      Repo.all(
        from(e in Event,
          where: e.workspace_id == ^run.workspace_id and e.event_id in ^ids,
          select: {e.event_id, {e.run_id, e.sequence}}
        ),
        log: false
      )
      |> Map.new()

    Enum.count(skipped, fn row ->
      Map.get(held, row.event_id) != {row.run_id, row.sequence}
    end)
  end

  defp count(run, inserted, run_configuration, now) do
    set =
      [updated_at: now] ++
        if(inserted > 0, do: [last_event_at: now], else: []) ++
        if(run_configuration,
          do: [reported_run_configuration_digest: run_configuration],
          else: []
        )

    {1, [run]} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id, select: r),
        inc: [event_count: inserted],
        set: set
      )

    run
  end

  defp placement(access_key, meta), do: Nodes.placement(access_key.node, meta[:instance_id])

  defp run_configuration(meta) do
    case meta[:run_configuration] do
      digest when is_binary(digest) -> if Regex.match?(@digest, digest), do: digest
      _ -> nil
    end
  end

  defp delivery_id(meta) do
    with id when is_binary(id) <- meta[:delivery_id],
         {:ok, id} <- Ecto.UUID.cast(id) do
      id
    else
      _ -> Ecto.UUID.generate()
    end
  end

  # Bookkeeping on the key, after the commit: it never fails the delivery. The key's
  # last heartbeat is the projector's (`Apiary.Runs.Projector`), by the heartbeat's own
  # time.
  defp touch(access_key, meta, now) do
    AccessKeys.touch_delivery(access_key, %{
      last_used_at: now,
      last_forager_version: meta[:forager_version],
      last_contract_version: meta.contract_version
    })
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp log_conflicts(result) do
    run = if result.run, do: result.run.id

    Logger.warning(
      "a delivery held #{result.conflicts} event(s) that collide with stored ones; dropped",
      run: run
    )
  end
end
