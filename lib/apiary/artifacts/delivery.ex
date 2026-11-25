defmodule Apiary.Artifacts.Delivery do
  @moduledoc false

  # Where the delivery of a version to an adapter stands, stored on the version
  # (`Apiary.Artifacts.Version`: `delivery`, `delivery_reply`, `delivery_failure` and
  # `delivery_at`). A delivery is one `change_request` entry of the adapter's change feed,
  # for the version's target.
  #
  # A version's target and type are those of its artifact: an artifact is unique per work
  # item, type and name, and a delivered output's name is the target's, so the
  # versions of one artifact are the versions for one target and type.
  #
  # ## Sending: `stored/4` and `approved/2`
  #
  # A version of a type that the run's process version marks `deliver`
  # (`Apiary.Processes.delivered_entries/1`), pushed by a run whose access level is
  # `write` (`Apiary.Runs.Cancel.write_access?/1`), in a workspace of any domain, gets its
  # entry built (`Apiary.Artifacts.ChangeEntry`) and checked when the push stores it
  # (`stored/4`), whatever its `send`. A version of a run with a lower level gets no entry, and its
  # `delivery` stays nil: the run contract has `deliver` on a `write` run alone.
  #
  # The run's target is its work item's target (`Apiary.Runs.Target.dispatched/1`). The
  # entry's `target` is that target as the contracts write it
  # (`Apiary.Runs.Target.document/1`), from the workspace's row of it where there is one,
  # never the stored text. A version whose stored `target.collection` is another
  # collection is marked `failed`, `invalid`, at `#/target`. So is a version whose entry
  # fails the contract's check (`Apiary.Adapters.ChangeRequest.validate/1`), or whose
  # entry's members are longer as jsonb text than the feed's check takes
  # (`stored_size/1`), before any gate (`record_invalid/2`). A version whose stored content
  # has no `target` gets no entry, and its `delivery` stays nil. A type whose `send` is
  # `end_of_run` is sent then; one whose `send` is `after_gate` is sent when an approval at
  # a gate covers the version (`approved/2`), built and checked again, while its
  # `delivery` is nil.
  #
  # To send, the adapter is that of the run's target. Then, in the caller's transaction:
  #
  #   * no adapter, or an adapter gone: `delivery` `failed`, `delivery_failure`
  #     `target_removed`, and no entry;
  #   * an adapter whose source lists no `change_kinds` with the version's type: no entry,
  #     and `delivery` stays nil, as the contract has it: the change stays in Qory Apiary;
  #   * no collection of the adapter with the target that is live, on a connected
  #     connection and assigned to the version's workspace, the check that ends a run
  #     `target_access_gone` (`Apiary.Runs.RunCredentials`), or no row of the target in the
  #     workspace: `delivery` `failed`, `delivery_failure` `target_removed`, no entry;
  #   * else `delivery` `sent`, `delivery_target_id` the row, `delivery_at` the time, and
  #     the entry appended to the adapter's change feed (`Apiary.Adapters.Feed.append/2`).
  #
  # Each write sets a version only while its `delivery` is nil, so a version is sent once.
  # The callers hold the work item `FOR UPDATE`, and the feed's counter row comes after it,
  # as the lock order has it (`Apiary.Adapters.Collections`).

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.Adapters.{ChangeRequest, Collection, Connection, Feed}
  alias Apiary.Artifacts.{ChangeEntry, Version}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Processes
  alias Apiary.Repo
  alias Apiary.Runs.{Cancel, Run, Target}
  alias Apiary.WorkItems.WorkItem

  # The character rule of a line (`description.schema.json`, `$defs.line`): no control
  # character, no U+2028 or U+2029, no format character other than U+200C and U+200D.
  @line ~r/\A(?:[^\p{Cc}\p{Cf}\x{2028}\x{2029}]|[\x{200C}\x{200D}])*\z/u

  @doc """
  previous_address/1 is the address of `version`'s previous delivery, the `address` of the
  adapter's newest reply for the same target and type, for the entry's `previous.address`:
  a map as the adapter sent it, or nil when no other version of the artifact has a reply,
  or when the newest reply has no address (a reply for an entry that asked for no change).

  The newest reply is the one with the latest `delivery_at`, then the latest
  `inserted_at` of its version. A version with a reply and no `delivery_at` is older than
  every version with one. The version itself is left out. It reads the versions of the
  artifact by `artifact_id`, which the unique index on `artifact_id` and `number` serves.
  """
  @spec previous_address(Version.t()) :: map | nil
  def previous_address(%Version{id: id, artifact_id: artifact_id}) do
    reply =
      Repo.one(
        from v in Version,
          where: v.artifact_id == ^artifact_id and v.id != ^id and not is_nil(v.delivery_reply),
          order_by: [desc_nulls_last: v.delivery_at, desc: v.inserted_at],
          limit: 1,
          select: v.delivery_reply
      )

    reply && reply["address"]
  end

  @doc """
  stored/4 builds and checks the entry of `version`, a version of the type `type` that the
  run `dispatch_run` pushed for the held `work_item`, with its decoded `content`, in the
  push's transaction (the moduledoc). `{:ok, version}`, with its delivery as written; the
  version as it is where its type is not delivered, or the run's access level is not
  `write`.
  """
  @spec stored(Version.t(), String.t(), DispatchRun.t(), {WorkItem.t(), map | nil}) ::
          {:ok, Version.t()}
  def stored(%Version{} = version, type, %DispatchRun{} = dispatch_run, {work_item, content}) do
    with %{"deliver" => %{"send" => send}} = delivered when is_map(content) <-
           delivered_entry(dispatch_run.process_version_id, type),
         true <- write_run?(dispatch_run) do
      built = built(version, delivered, content, work_item, dispatch_run.id)
      checked(version, built, send == "end_of_run")
    else
      _not_sent -> {:ok, version}
    end
  end

  @doc """
  approved/2 sends the versions of the work item `work_item`, held `FOR UPDATE` by the
  caller's transaction, whose public ids are in `public_ids`, the versions an approval at
  a gate covers: each one of a type whose `send` is `after_gate` in its run's process
  version, with no `delivery` (the moduledoc). `:ok`, or `{:error, :store_unavailable}`
  when the file of one cannot be read, so that the approval is not written and nothing is
  left unsent.
  """
  @spec approved(WorkItem.t(), [String.t()]) :: :ok | {:error, :store_unavailable}
  def approved(_work_item, []), do: :ok

  def approved(%WorkItem{id: work_item_id} = work_item, public_ids) do
    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        join: d in DispatchRun,
        on: d.id == v.run_id,
        where: a.work_item_id == ^work_item_id and v.public_id in ^public_ids,
        where: is_nil(v.delivery) and not v.withdrawn,
        order_by: [asc: v.inserted_at],
        select: {v, a.type, d}
    )
    |> Enum.reduce_while(:ok, fn {version, type, dispatch_run}, :ok ->
      case approved_one(version, type, dispatch_run, work_item) do
        {:ok, _version} -> {:cont, :ok}
        {:error, :store_unavailable} = error -> {:halt, error}
      end
    end)
  end

  defp approved_one(version, type, dispatch_run, work_item) do
    with %{"deliver" => %{"send" => "after_gate"}} = delivered <-
           delivered_entry(dispatch_run.process_version_id, type),
         true <- write_run?(dispatch_run),
         version = Repo.preload(version, files: Apiary.Artifacts.files_query()),
         {:ok, %{} = content} <- Apiary.Stages.Artifacts.stored_json(version) do
      checked(version, built(version, delivered, content, work_item, dispatch_run.id), true)
    else
      {:error, :store_unavailable} = error -> error
      _not_sent -> {:ok, version}
    end
  end

  # The entry of the type `type` in the record of the process version `version_id`, where
  # the process delivers the type.
  defp delivered_entry(version_id, type) do
    version_id
    |> Processes.harness_template()
    |> Processes.delivered_entries()
    |> Enum.find(&(&1["name"] == type))
  end

  # Whether the run of the queue `dispatch_run` has the access level `write`, as its claim
  # recorded it, in a workspace of any domain (`Apiary.Runs.Cancel.write_access?/1`); false
  # for a queue with no registered run.
  defp write_run?(%DispatchRun{id: id}) do
    run = Repo.one(from r in Run, where: r.dispatch_run_id == ^id, limit: 1)
    run != nil and Cancel.write_access?(run)
  end

  # The entry and where it goes: `{entry, adapter_id}`, `:no_target` for content with no
  # `target`, `:other_target` for content whose `target.collection` is not the run's.
  defp built(version, delivered, content, work_item, dispatch_run_id) do
    target = Target.dispatched(dispatch_run_id)
    schema = delivered["json_schema"] || %{}

    cond do
      not match?(%{"target" => %{}}, content) ->
        :no_target

      target && content["target"]["collection"] != target.collection_external_ref ->
        :other_target

      true ->
        adapter_id = target && target.adapter_id

        facts = %{
          change_request_id: version.public_id,
          change_kind: delivered["name"],
          work_item_title: work_item.title,
          target: target && document(version, target),
          ref: ref(work_item, adapter_id),
          previous: previous(version, schema)
        }

        {:ok, entry} = ChangeEntry.build(content, schema, facts)
        {entry, adapter_id}
    end
  end

  # The run's target as the contracts write it, from the workspace's row of it where there
  # is one, as a map with string keys.
  defp document(version, target) do
    row = Repo.one(Target.by_key(version.workspace_id, target), log: false)
    (row || target) |> Target.document() |> Jason.encode!() |> Jason.decode!()
  end

  # The check of a built entry, then the send where `send?`.
  defp checked(version, :no_target, _send?), do: {:ok, version}

  defp checked(version, :other_target, _send?),
    do:
      invalid(
        version,
        {:error,
         %{valid: false, count: 1, errors: [%{kind: :const, instanceLocation: "#/target"}]}}
      )

  defp checked(version, {entry, adapter_id}, send?) do
    case with(:ok <- ChangeRequest.validate(entry), do: stored_size(entry)) do
      :ok when send? -> send(version, entry, adapter_id)
      :ok -> {:ok, version}
      {:error, _summary} = refused -> invalid(version, refused)
    end
  end

  # The most bytes an entry's members other than `kind` take as jsonb text, as the feed's
  # check `adapter_feed_data_check` bounds a `change_request` entry.
  @max_stored 1_400_000

  # Whether the entry fits the feed's check: Postgres writes each number of a jsonb value
  # in plain notation, so `1.5e-300`, 8 bytes in JSON, takes about 300 bytes as jsonb text,
  # and an entry within the contract's bounds can be over the check's. Such an entry is
  # refused at `#/data`, as a `data` over the contract's bound is.
  defp stored_size(entry) do
    %{rows: [[size]]} =
      Repo.query!("SELECT octet_length($1::jsonb::text)", [Map.delete(entry, "kind")], log: false)

    if size <= @max_stored,
      do: :ok,
      else:
        {:error,
         %{valid: false, count: 1, errors: [%{kind: :maxBytes, instanceLocation: "#/data"}]}}
  end

  defp invalid(version, refused) do
    case record_invalid(version, refused) do
      {:ok, version} -> {:ok, version}
      {:error, :delivery_set} -> {:ok, version}
    end
  end

  # The send of a checked entry (the moduledoc).
  defp send(version, entry, adapter_id) do
    adapter = adapter_id && Repo.get(Node, adapter_id)

    cond do
      is_nil(adapter) ->
        removed(version)

      entry["change_kind"] not in List.wrap(adapter.change_kinds) ->
        {:ok, version}

      not reached?(version, adapter_id, entry) ->
        removed(version)

      row = target_row(version, adapter_id, entry) ->
        case set_once(version, delivery: :sent, delivery_target_id: row) do
          {:set, version} ->
            {:ok, _seq} = Feed.append(adapter, feed_entry(entry))
            {:ok, version}

          {:unchanged, version} ->
            {:ok, version}
        end

      true ->
        removed(version)
    end
  end

  defp removed(version) do
    {_set, version} = set_once(version, delivery: :failed, delivery_failure: :target_removed)
    {:ok, version}
  end

  # Whether a collection of the adapter `adapter_id` with the entry's target is live, on a
  # connected connection, and assigned to the version's workspace.
  defp reached?(version, adapter_id, entry) do
    Repo.exists?(
      from c in Collection,
        join: n in Connection,
        on: n.id == c.connection_id,
        where: c.adapter_id == ^adapter_id and c.workspace_id == ^version.workspace_id,
        where: c.target_collection_external_ref == ^entry["target"]["collection"],
        where: is_nil(c.ended_at) and n.state == :connected
    )
  end

  # The id of the workspace's target of the adapter `adapter_id` and the entry's
  # `target.collection`; nil for none.
  defp target_row(version, adapter_id, entry) do
    Repo.one(
      from(
        t in Target.by_key(version.workspace_id, %{
          adapter_id: adapter_id,
          collection_external_ref: entry["target"]["collection"]
        }),
        select: t.id
      ),
      log: false
    )
  end

  # Sets `set` and `delivery_at` on `version` while its `delivery` is nil: `{:set,
  # version}` with them, or `{:unchanged, version}` for a version that has a delivery.
  defp set_once(%Version{id: id} = version, set) do
    set = [delivery_at: DateTime.utc_now()] ++ set

    case Repo.update_all(from(v in Version, where: v.id == ^id and is_nil(v.delivery)), set: set) do
      {1, _rows} -> {:set, struct(version, set)}
      {0, _rows} -> {:unchanged, version}
    end
  end

  # The entry as `Apiary.Adapters.Feed.append/2` takes it: its members as atoms.
  defp feed_entry(entry) do
    Map.new(entry, fn {member, value} -> {String.to_existing_atom(member), value} end)
  end

  # The ref of the work item's source item, where the item came through the adapter of the
  # target; nil otherwise.
  defp ref(%WorkItem{adapter_id: adapter_id, external_ref: ref}, adapter_id)
       when is_binary(adapter_id) and is_binary(ref),
       do: ref

  defp ref(_work_item, _adapter_id), do: nil

  # The entry's `previous`: the title of the newest earlier version of the artifact that was
  # sent to the adapter, from its stored content, and the address of the newest reply
  # (`previous_address/1`); nil where neither is there. Where the store cannot read that
  # version's file, the title is left out, with a warning in the log: an adapter keeps the
  # current title of a change request whose entry has none.
  defp previous(version, schema) do
    sent =
      Repo.one(
        from(v in Version,
          where: v.artifact_id == ^version.artifact_id and v.number < ^version.number,
          where: v.delivery in [:sent, :delivered],
          order_by: [desc: v.number],
          limit: 1,
          preload: [files: ^Apiary.Artifacts.files_query()]
        )
      )

    content =
      case sent && Apiary.Stages.Artifacts.stored_json(sent) do
        {:ok, content} ->
          content

        {:error, :store_unavailable} ->
          Logger.warning(
            "change request sent with no previous title, previous version unreadable " <>
              "version=#{version.public_id} previous_version=#{sent.public_id}"
          )

          nil

        nil ->
          nil
      end

    previous =
      %{}
      |> put_given("title", ChangeEntry.title(content, schema))
      |> put_given("address", previous_address(version))

    if previous == %{}, do: nil, else: previous
  end

  defp put_given(map, _key, nil), do: map
  defp put_given(map, key, value), do: Map.put(map, key, value)

  @doc """
  record_invalid/2 stores that the entry for `version` failed Qory Apiary's check, so
  nothing is sent: `result` is what `Apiary.Adapters.ChangeRequest.validate/1` returned
  for the entry. For `{:error, summary}` it sets `delivery` to `:failed`,
  `delivery_failure` to `:invalid`, `delivery_detail` to the places that the check
  refused and `delivery_at` to the time, and returns the version with them. For `:ok` it changes nothing and returns the version. A version that already
  has a `delivery` is left as it is and gets `{:error, :delivery_set}`, so a delivery that
  was sent, or a reply that was stored, is not overwritten. The run is not stopped: only
  the delivery fails.

  `delivery_detail` is the `instanceLocation` of the first error of the summary that is
  not the entry itself, a JSON Pointer after `#`, such as `#/title`, or `#` when every
  error is at the entry, as for a missing member. It has the bounds of `detail` in
  `changes-failed.schema.json`: a member name with a control character or a format
  character (other than U+200C and U+200D) ends the pointer before it, and the pointer is
  cut to 1000 characters.
  """
  @spec record_invalid(Version.t(), :ok | {:error, map}) ::
          {:ok, Version.t()} | {:error, :delivery_set}
  def record_invalid(%Version{} = version, :ok), do: {:ok, version}

  def record_invalid(%Version{id: id} = version, {:error, %{valid: false, errors: errors}}) do
    at = DateTime.utc_now()
    detail = detail(errors)

    {count, _rows} =
      Repo.update_all(
        from(v in Version, where: v.id == ^id and is_nil(v.delivery)),
        set: [
          delivery: :failed,
          delivery_failure: :invalid,
          delivery_detail: detail,
          delivery_at: at
        ]
      )

    case count do
      1 ->
        {:ok,
         %{
           version
           | delivery: :failed,
             delivery_failure: :invalid,
             delivery_detail: detail,
             delivery_at: at
         }}

      0 ->
        {:error, :delivery_set}
    end
  end

  # The first place of the errors that is not the entry, as `delivery_detail` has it. The
  # check counts code points, not graphemes, so the cut counts them too.
  defp detail(errors) do
    errors
    |> Enum.map(& &1.instanceLocation)
    |> Enum.find("#", &(&1 != "#"))
    |> String.split("/")
    |> Enum.take_while(&Regex.match?(@line, &1))
    |> Enum.join("/")
    |> String.codepoints()
    |> Enum.take(1000)
    |> Enum.join()
  end

  @doc """
  find_sent/3 is the version that the adapter `adapter_id` has an entry for, as an adapter's
  report names it: the version whose `public_id` is `change_request_id`, whose `delivery` is
  `:sent`, and whose `delivery_target_id` is a target of that adapter with the collection
  ref `collection`; nil for any other case, an unknown id, another adapter's version, a
  version not sent and a version whose target is gone included.
  """
  @spec find_sent(Ecto.UUID.t(), String.t(), String.t()) :: Version.t() | nil
  def find_sent(adapter_id, change_request_id, collection),
    do: Repo.one(sent(adapter_id, change_request_id, collection))

  @doc """
  delivered/2 stores the reply `report` of the adapter `adapter_id`
  (`Apiary.Adapters.ChangeReport.submitted/1`) on the version it is about: `delivery` is
  `:delivered`, `delivery_reply` is the report's reply, and `delivery_at` the time. It
  writes only while the version is `:sent` (`find_sent/3`), in one statement, so the first
  stored result wins. `{:ok, :stored}`, or `{:ok, :ignored}` and no change for any other
  case: a report sent again, or late, is never an error.
  """
  @spec delivered(Ecto.UUID.t(), map) :: {:ok, :stored | :ignored}
  def delivered(adapter_id, %{change_request_id: id, collection: collection, reply: reply}) do
    store(adapter_id, id, collection,
      delivery: :delivered,
      delivery_reply: reply,
      delivery_at: DateTime.utc_now()
    )
  end

  @doc """
  failed/2 stores the failure `report` of the adapter `adapter_id`
  (`Apiary.Adapters.ChangeReport.failed/1`) on the version it is about: `delivery` is
  `:failed`, `delivery_failure` is the reason, `delivery_detail` is the adapter's detail, nil
  for none, and `delivery_at` the time. Otherwise as `delivered/2`.
  """
  @spec failed(Ecto.UUID.t(), map) :: {:ok, :stored | :ignored}
  def failed(adapter_id, %{change_request_id: id, collection: collection} = report) do
    store(adapter_id, id, collection,
      delivery: :failed,
      delivery_failure: report.reason,
      delivery_detail: report.detail,
      delivery_at: DateTime.utc_now()
    )
  end

  defp store(adapter_id, id, collection, set) do
    case Repo.update_all(sent(adapter_id, id, collection), set: set) do
      {1, _rows} -> {:ok, :stored}
      {0, _rows} -> {:ok, :ignored}
    end
  end

  defp sent(adapter_id, change_request_id, collection) do
    from v in Version,
      join: t in Target,
      on: t.id == v.delivery_target_id and t.workspace_id == v.workspace_id,
      where: v.public_id == ^change_request_id and v.delivery == :sent,
      where: t.adapter_id == ^adapter_id and t.collection_external_ref == ^collection
  end
end
