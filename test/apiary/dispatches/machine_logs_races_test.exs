defmodule Apiary.Dispatches.MachineLogsRacesTest do
  # The retention job's delete of a machine log file with no record
  # (`Apiary.Dispatches.MachineLogs.prune/1`) racing an upload of the same dispatch
  # (`Apiary.Dispatches.MachineLogs.upload/3`), each on a separate connection, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test: an upload writes its record, which locks its dispatch's row
  # `FOR KEY SHARE`, before its file, and holds the lock until it commits; the job's delete
  # locks that row `FOR UPDATE` first. So the two take turns, and an uploaded file is
  # never deleted under its record.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.DispatchedRunsFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Edition, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, MachineLog, MachineLogs, MachineLogStore}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @log "2026-10-15T12:01:05Z machine created: small\n"

  setup_all :clean_up_leftovers
  setup :setup_races

  setup %{tmp_dir: tmp_dir} do
    started = DateTime.utc_now()
    dir = Path.join(tmp_dir, "machine-logs")
    before = Application.fetch_env(:apiary, :machine_logs_dir)
    Application.put_env(:apiary, :machine_logs_dir, dir)

    %{scope: scope} = sign_up()
    place = handover_place_fixture(scope)
    {gateway_key, _seed} = place.gateway_key
    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = dispatched!(place.key)

    # Before the clean up of `setup_races`: the organisation, then what outlives it, the
    # adapter the work item came through, the keys' public halves and the entries the
    # adapter left in the instance's trail.
    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, :machine_logs_dir, value)
        :error -> Application.delete_env(:apiary, :machine_logs_dir)
      end

      :ok = Sandbox.checkout(Repo, sandbox: false)
      adapters = [work_item.adapter_id]
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)

      adapter_keys =
        Repo.all(from k in AccessKey, where: k.node_id in ^adapters, select: k.key_id)

      Repo.delete_all(
        from p in PublicKey,
          where: p.key_id in ^[place.key.key_id, gateway_key.key_id | adapter_keys]
      )

      Repo.delete_all(from c in Connection, where: c.adapter_id in ^adapters)
      Repo.delete_all(from k in AccessKey, where: k.node_id in ^adapters)
      Repo.delete_all(from c in EnrolmentCode, where: c.node_id in ^adapters)
      Repo.delete_all(from n in Node, where: n.id in ^adapters)

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    %{key: place.key, dispatch: dispatch, path: Path.join(dir, dispatch.public_id)}
  end

  # A file of the dispatch with no record, two hours old, as an upload whose commit failed
  # leaves it.
  defp orphan!(%{dispatch: dispatch, path: path}) do
    :ok = MachineLogStore.put(dispatch.public_id, "left by a failed upload")
    File.touch!(path, System.os_time(:second) - 7_200)
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 3_601, :second)

  test "the job waits for an upload that wrote its record and its file, then leaves the file",
       ctx do
    orphan!(ctx)

    # The upload's steps in its order, held before its commit: the record, then the file.
    {upload, upload_pid} =
      hold(fn ->
        {1, _rows} =
          Repo.insert_all(MachineLog, [
            %{
              id: Ecto.UUID.generate(),
              organisation_id: ctx.dispatch.organisation_id,
              workspace_id: ctx.dispatch.workspace_id,
              dispatch_id: ctx.dispatch.id,
              storage_key: ctx.dispatch.public_id,
              byte_size: byte_size(@log),
              truncated: false,
              uploaded_at: DateTime.utc_now()
            }
          ])

        :ok = MachineLogStore.put(ctx.dispatch.public_id, @log)
      end)

    pruning = start(fn -> MachineLogs.prune(now: later()) end)
    await_blocked(pruning.backend, upload_pid)
    commit(upload)

    assert Task.await(pruning.task) == %{machine_logs_deleted: 0, files_deleted: 0}
    assert File.read!(ctx.path) == @log
  end

  test "an upload waits for the job's delete before it writes its file, and its file stays",
       ctx do
    orphan!(ctx)
    [{:key, key, listed}] = elem(MachineLogStore.files(), 1)

    # The job's delete, held with the dispatch's row locked.
    {delete, delete_pid} =
      hold(fn ->
        Repo.one!(
          from d in Dispatch, where: d.public_id == ^key, select: d.id, lock: "FOR UPDATE"
        )
      end)

    uploading =
      start(fn ->
        Dispatches.upload_machine_log(ctx.key, key, %{log: @log, truncated: false})
      end)

    await_blocked(uploading.backend, delete_pid)
    # Blocked on its record, the upload has not written its file yet.
    assert File.read!(ctx.path) == "left by a failed upload"
    assert continue(delete, fn -> MachineLogStore.delete_unchanged(key, listed) end) == :ok
    commit(delete)

    assert Task.await(uploading.task) == :ok
    assert File.read!(ctx.path) == @log
    assert Repo.get_by(MachineLog, dispatch_id: ctx.dispatch.id)
  end
end
