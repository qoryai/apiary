defmodule Apiary.Runs.Ingest do
  @moduledoc """
  Stores a verified delivery: the receiving side of the record.

  `ingest/3` takes the access key the request was verified under, the parsed
  batch and what the request's headers said, and in one transaction creates the
  run in the key's hive when its subject is new, inserts the events that are
  new, records the delivery and counts. It projects nothing: once the
  transaction has committed, the use of the key is recorded, the projector is
  asked to project the run on its own time, and the caller answers.

  Delivery is at least once and in any order, so nothing here is an error that
  the runner could cause by sending again: an event already stored is skipped, a
  delivery already recorded is answered as before, and an event that collides
  with another (its id under a different run, or its sequence under a different
  id) is dropped and counted.

  Nothing of the request's headers but the versions and the run configuration
  digest is stored, and nothing of an event is logged: the insert of the events
  is kept out of the query log.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Batch, Delivery, Event, Projector, Run}

  @digest ~r/\Asha256=[0-9a-f]{64}\z/

  @typedoc """
  What the request said beside its body: `delivery_id` (`X-Qory-Delivery`; one is
  made up when it is absent or not a UUID), `runner_version`, `contract_version`
  and `run_configuration` (`X-Qory-Run-Configuration`), each nil when not sent.
  """
  @type meta :: %{
          optional(:delivery_id) => String.t() | nil,
          optional(:runner_version) => String.t() | nil,
          optional(:contract_version) => integer | nil,
          optional(:run_configuration) => String.t() | nil
        }

  @doc """
  Stores the batch. `{:ok, result}` with `status` 202, or 410 when the hive has
  closed the run and nothing but the delivery was recorded; `inserted` events
  were new, `duplicates` were already held, `conflicts` were dropped, and
  `repeated` says the delivery id had been recorded before.
  """
  def ingest(%AccessKey{} = access_key, %Batch{} = batch, meta \\ %{}) do
    now = DateTime.utc_now()
    delivery_id = delivery_id(meta)

    result =
      if Runs.closed?(access_key.hive_id, batch.subject) do
        Repo.transact(fn -> {:ok, gone(access_key, batch, delivery_id, now)} end)
      else
        Repo.transact(fn -> {:ok, store(access_key, batch, meta, delivery_id, now)} end)
      end

    with {:ok, result} <- result do
      touch(access_key, batch, meta, now)
      if result.conflicts > 0, do: log_conflicts(result)
      if result.status == 202, do: Projector.project_async(result.run)
      {:ok, result}
    end
  end

  defp store(access_key, batch, meta, delivery_id, now) do
    run = upsert_run(access_key, batch, meta, now)

    cond do
      run.state == "closed" ->
        gone(access_key, batch, delivery_id, now)

      not new_delivery?(access_key, batch, delivery_id, now) ->
        %{result(202, run) | repeated: true}

      true ->
        {inserted, duplicates, conflicts} = insert_events(run, batch, now)
        record_delivery(access_key, delivery_id, inserted)
        run = count(run, inserted, run_configuration(meta), now)
        %{result(202, run) | inserted: inserted, duplicates: duplicates, conflicts: conflicts}
    end
  end

  # The hive has closed the run: the delivery is recorded, nothing else is kept.
  defp gone(access_key, batch, delivery_id, now) do
    repeated = not new_delivery?(access_key, batch, delivery_id, now, 410)
    %{result(410, nil) | repeated: repeated}
  end

  defp result(status, run) do
    %{status: status, run: run, inserted: 0, duplicates: 0, conflicts: 0, repeated: false}
  end

  # Two first batches of one run may arrive at once: the insert that loses waits
  # for the one that wins and inserts nothing, and the read after it sees the row.
  defp upsert_run(access_key, batch, meta, now) do
    Repo.insert_all(
      Run,
      [
        %{
          id: Ecto.UUID.generate(),
          organisation_id: access_key.organisation_id,
          hive_id: access_key.hive_id,
          run_id: batch.subject,
          access_key_id: access_key.id,
          state: "pending",
          runner_version: meta[:runner_version],
          contract_version: meta[:contract_version],
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:hive_id, :run_id]
    )

    Repo.one!(
      from r in Run, where: r.hive_id == ^access_key.hive_id and r.run_id == ^batch.subject
    )
  end

  # The delivery is inserted first with nothing counted, so a delivery id seen
  # before is known before any event is touched.
  defp new_delivery?(access_key, batch, delivery_id, now, status \\ 202) do
    {count, _} =
      Repo.insert_all(
        Delivery,
        [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: access_key.organisation_id,
            hive_id: access_key.hive_id,
            access_key_id: access_key.id,
            delivery_id: delivery_id,
            run_id: batch.subject,
            received_at: now,
            event_count: length(batch.events),
            inserted_count: 0,
            status: status
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
          hive_id: run.hive_id,
          run_id: run.id,
          sequence: event.sequence,
          event_id: event.event_id,
          type: event.type,
          time: event.time,
          data: event.data,
          received_at: now
        }
      end)

    {inserted, stored} =
      Repo.insert_all(Event, rows, on_conflict: :nothing, returning: [:event_id], log: false)

    skipped = length(rows) - inserted
    conflicts = if skipped > 0, do: conflicts(run, rows, stored), else: 0
    {inserted, skipped - conflicts, conflicts}
  end

  # An event that was not inserted is a duplicate when the hive holds the same id
  # in the same run at the same sequence, and a conflict otherwise: its id is
  # another run's, or its sequence is another event's.
  defp conflicts(run, rows, stored) do
    stored = MapSet.new(stored, & &1.event_id)
    skipped = Enum.reject(rows, &MapSet.member?(stored, &1.event_id))
    ids = Enum.map(skipped, & &1.event_id)

    held =
      Repo.all(
        from(e in Event,
          where: e.hive_id == ^run.hive_id and e.event_id in ^ids,
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

  # Bookkeeping on the key, after the commit: it never fails the delivery.
  defp touch(access_key, batch, meta, now) do
    AccessKeys.touch_delivery(access_key, %{
      last_used_at: now,
      last_runner_version: meta[:runner_version],
      last_contract_version: meta[:contract_version],
      last_heartbeat_at: Batch.last_heartbeat(batch)
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
