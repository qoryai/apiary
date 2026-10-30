defmodule Apiary.Dispatches.MachineLogsTest do
  # Each dispatch's machine log (`Apiary.Dispatches.MachineLogs`,
  # `Apiary.Dispatches.MachineLogStore`): the file, named by the dispatch id alone, mode
  # 0600, in the folder and nowhere else; the record linked to the dispatch and its run;
  # one per dispatch; no folder set refused and nothing kept; a run whose machine never
  # redeemed its code ended at once; the read, an instance
  # admin's alone; the retention job's pruning and its setting; and the purge. What the
  # route answers is `ApiaryWeb.Contract.MachineLogControllerTest`'s. Not async: the
  # folder and the setting are the whole node's.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Deletion, Dispatches, InstanceConfig, Repo, Retention}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun, MachineLog, MachineLogs, MachineLogStore}
  alias Apiary.Environments.Record
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Run

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @log "2026-10-15T12:01:05Z machine created: small\n2026-10-15T12:09:15Z machine stopped\n"

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "machine-logs")
    put_env(:machine_logs_dir, dir)
    put_env(:machine_log_retention_days, nil)
    %{scope: scope} = sign_up_fixture()
    scope |> handover_place_fixture() |> Map.merge(%{scope: scope, dir: dir})
  end

  defp put_env(key, value) do
    before = Application.fetch_env(:apiary, key)
    Application.put_env(:apiary, key, value)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, key, value)
        :error -> Application.delete_env(:apiary, key)
      end
    end)
  end

  # A dispatch of a fresh work item, claimed and its job started, not handed over.
  defp dispatch!(ctx) do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    dispatched!(ctx.key).dispatch
  end

  # A dispatch claimed, before `dispatched`, which its starter may release.
  defp claimed!(ctx) do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    dispatch
  end

  defp upload(ctx, %Dispatch{public_id: id}, log \\ @log, truncated \\ false),
    do: Dispatches.upload_machine_log(ctx.key, id, %{log: log, truncated: truncated})

  defp record(%Dispatch{id: id}), do: Repo.get_by(MachineLog, dispatch_id: id)

  describe "the upload" do
    test "writes the file, named by the dispatch id alone, mode 0600, and its record", ctx do
      dispatch = dispatch!(ctx)
      assert upload(ctx, dispatch) == :ok

      assert File.ls!(ctx.dir) == [dispatch.public_id]
      path = Path.join(ctx.dir, dispatch.public_id)
      assert File.read!(path) == @log
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      assert %MachineLog{
               storage_key: key,
               byte_size: size,
               truncated: false,
               organisation_id: organisation_id,
               workspace_id: workspace_id
             } = record(dispatch)

      assert key == dispatch.public_id
      assert size == byte_size(@log)
      assert {organisation_id, workspace_id} == {dispatch.organisation_id, dispatch.workspace_id}
    end

    test "keeps truncated, and the size in bytes of a text with characters beyond ASCII", ctx do
      dispatch = dispatch!(ctx)
      log = "2026-10-15T12:09:12Z job ended: exit 0 — größe\n"
      assert upload(ctx, dispatch, log, true) == :ok
      assert %MachineLog{truncated: true, byte_size: size} = record(dispatch)
      assert size == byte_size(log) and size > String.length(log)
    end

    test "is accepted once per dispatch: a second is machine_log_exists and changes nothing",
         ctx do
      dispatch = dispatch!(ctx)
      assert upload(ctx, dispatch) == :ok
      assert upload(ctx, dispatch, "another\n") == {:error, :machine_log_exists}
      assert File.read!(Path.join(ctx.dir, dispatch.public_id)) == @log
      assert Repo.aggregate(MachineLog, :count) == 1
    end

    test "is accepted after the dispatch ended", ctx do
      dispatch = claimed!(ctx)
      :ok = Dispatches.release(ctx.key, dispatch.public_id, %{reason: "stopped"})
      assert %Dispatch{ended_at: %DateTime{}} = Repo.get!(Dispatch, dispatch.id)
      assert upload(ctx, dispatch) == :ok
    end

    test "for a run that opened, links the record to the run through the dispatch", ctx do
      %{dispatch: dispatch, dispatch_run: queued} = handed_over_fixture(ctx.scope, ctx.key)
      assert upload(ctx, dispatch) == :ok

      assert {:ok, %{run_id: run_id}} =
               Dispatches.machine_log(instance_admin_scope(), dispatch.public_id)

      assert run_id == queued.run_id
    end

    test "an unknown dispatch, one of no dispatch's shape, or another pool's is forbidden",
         ctx do
      dispatch = dispatch!(ctx)

      %{access_key: other} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(
          ctx.scope,
          Apiary.NodesFixtures.pool_fixture(ctx.scope)
        )

      meta = %{log: @log, truncated: false}

      assert Dispatches.upload_machine_log(ctx.key, "dp_0000000000000000", meta) ==
               {:error, :forbidden}

      assert Dispatches.upload_machine_log(ctx.key, "../../etc/passwd", meta) ==
               {:error, :forbidden}

      assert Dispatches.upload_machine_log(other, dispatch.public_id, meta) ==
               {:error, :forbidden}

      assert Repo.aggregate(MachineLog, :count) == 0
      refute File.exists?(ctx.dir)
    end

    test "with no folder set is unavailable, keeps nothing, and a later upload succeeds", ctx do
      dispatch = dispatch!(ctx)
      put_env(:machine_logs_dir, " ")

      log = capture_log(fn -> assert upload(ctx, dispatch) == {:error, :unavailable} end)
      assert log =~ "a machine log could not be stored: APIARY_MACHINE_LOGS_DIR is not set"
      refute log =~ "machine created"
      assert record(dispatch) == nil

      put_env(:machine_logs_dir, ctx.dir)
      assert upload(ctx, dispatch) == :ok
    end

    test "a file that cannot be written is unavailable and keeps no record", ctx do
      dispatch = dispatch!(ctx)
      # A file where the folder would be.
      File.write!(ctx.dir, "")

      log = capture_log(fn -> assert upload(ctx, dispatch) == {:error, :unavailable} end)
      assert log =~ ~r/a machine log could not be stored: :e(exist|notdir)\n/
      assert record(dispatch) == nil
    end
  end

  describe "a run whose machine never redeemed its code" do
    test "ends at once once the log arrives: failed, machine_stopped; its run of the queue and dispatch lost",
         ctx do
      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
      %{dispatch: dispatch, run: queued, registered: registered} = dispatched!(ctx.key)
      assert %Run{state: "pending"} = registered
      assert Apiary.Dispatches.Slots.held(ctx.pool.id) == 1

      Phoenix.PubSub.subscribe(Apiary.PubSub, Apiary.Runs.topic(registered.workspace_id))
      assert upload(ctx, dispatch) == :ok

      assert %Run{
               state: "failed",
               reason: "machine_stopped",
               start_failure: "machine_stopped",
               start_failed_at: %DateTime{},
               lost_at: nil
             } = failed = Repo.get!(Run, registered.id)

      assert {failed.dispatch_id, failed.dispatch_run_id} == {dispatch.id, queued.id}
      assert %DispatchRun{state: :ended, end_cause: :lost} = Repo.get!(DispatchRun, queued.id)
      assert %Dispatch{end_cause: :lost, ended_at: %DateTime{}} = Repo.get!(Dispatch, dispatch.id)
      assert Apiary.Dispatches.Slots.held(ctx.pool.id) == 0
      assert_received {:run_changed, %Run{id: id, state: "failed"}} when id == registered.id

      # The lost-run check at the code's expiry changes nothing more.
      Apiary.Runs.Liveness.check(DateTime.add(DateTime.utc_now(), 1000, :second))
      assert %Run{state: "failed", reason: "machine_stopped"} = Repo.get!(Run, registered.id)
    end

    test "stays as it is when its machine redeemed the code first", ctx do
      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)

      %{dispatch: dispatch, run: queued, registered: registered, run_code: code} =
        dispatched!(ctx.key)

      _run_key = redeemed_run_key!(code)
      assert upload(ctx, dispatch) == :ok

      assert %Run{state: "pending", start_failure: nil} = Repo.get!(Run, registered.id)
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, queued.id)
    end

    test "stays as it is when the dispatch was not handed over: its release or lapse decides",
         ctx do
      dispatch = claimed!(ctx)
      assert upload(ctx, dispatch) == :ok

      run = Repo.one!(from r in Run, where: r.dispatch_run_id == ^dispatch.dispatch_run_id)
      assert %Run{state: "pending", start_failure: nil} = run
      assert %DispatchRun{state: :claimed} = Repo.get!(DispatchRun, dispatch.dispatch_run_id)
    end

    test "keeps the cause of a release that came first", ctx do
      dispatch = claimed!(ctx)
      :ok = Dispatches.release(ctx.key, dispatch.public_id, %{reason: "No capacity."})
      assert upload(ctx, dispatch) == :ok

      assert %Run{state: "failed", start_failure: "machine_not_made"} =
               Repo.one!(from r in Run, where: r.dispatch_id == ^dispatch.id)
    end

    test "of a prebuild records its build lost, as the code's expiry would", ctx do
      %{dispatch: dispatch, run: run, collection: collection} =
        prebuild_handed_over!(ctx.scope, ctx.key)

      assert upload(ctx, dispatch) == :ok

      assert %Run{state: "failed", start_failure: "machine_stopped"} = Repo.get!(Run, run.id)

      assert %Record{failure_cause: :lost} =
               Repo.get_by!(Record, source_collection_id: collection.id, pool_id: ctx.pool.id)
    end
  end

  describe "the store" do
    test "refuses a key that is not a dispatch id, and writes nothing outside the folder", ctx do
      for key <- ["../outside", "dp_0000000000000000/../../outside", "/tmp/outside", ""] do
        assert MachineLogStore.put(key, "text") == {:error, :invalid_key}
        assert MachineLogStore.get(key) == {:error, :invalid_key}
        assert MachineLogStore.delete(key) == {:error, :invalid_key}
      end

      refute File.exists?(Path.join(Path.dirname(ctx.dir), "outside"))
      refute File.exists?(ctx.dir)
    end

    test "replaces a file of the key whole, and deleting a file not there is :ok", ctx do
      key = "dp_0000000000000001"
      assert MachineLogStore.put(key, "one") == :ok
      assert MachineLogStore.put(key, "two") == :ok
      assert MachineLogStore.get(key) == {:ok, "two"}
      assert File.ls!(ctx.dir) == [key]
      assert MachineLogStore.delete(key) == :ok
      assert MachineLogStore.delete(key) == :ok
      assert MachineLogStore.get(key) == {:error, :enoent}
    end

    test "with no folder set refuses a write and a read, and has nothing to delete" do
      put_env(:machine_logs_dir, nil)
      assert MachineLogStore.dir() == nil
      assert MachineLogStore.put("dp_0000000000000001", "text") == {:error, :no_folder}
      assert MachineLogStore.get("dp_0000000000000001") == {:error, :no_folder}
      assert MachineLogStore.delete("dp_0000000000000001") == :ok
      assert MachineLogStore.files() == {:ok, []}
    end
  end

  describe "the read" do
    test "is an instance admin's: the text and its record", ctx do
      dispatch = dispatch!(ctx)
      :ok = upload(ctx, dispatch, @log, true)

      assert {:ok, read} = Dispatches.machine_log(instance_admin_scope(), dispatch.public_id)
      assert read.text == @log
      assert read.dispatch_id == dispatch.public_id
      assert read.byte_size == byte_size(@log)
      assert read.truncated == true
      assert read.organisation_id == ctx.scope.organisation.id
      assert read.workspace_id == ctx.scope.workspace.id
      assert %DateTime{} = read.uploaded_at
    end

    test "is forbidden to anyone else, the dispatch's organisation's owner among them", ctx do
      dispatch = dispatch!(ctx)
      :ok = upload(ctx, dispatch)
      refute Apiary.Access.instance_admin?(ctx.scope)
      assert Dispatches.machine_log(ctx.scope, dispatch.public_id) == {:error, :forbidden}

      assert Dispatches.machine_log(member_fixture(ctx.scope).scope, dispatch.public_id) ==
               {:error, :forbidden}

      assert Dispatches.machine_log(nil, dispatch.public_id) == {:error, :forbidden}

      {:ok, key} = Apiary.AccessKeys.fetch_for_verification(ctx.key.key_id)

      assert Dispatches.machine_log(Scope.for_access_key(key), dispatch.public_id) ==
               {:error, :forbidden}
    end

    test "is not_found for a dispatch with none, or no dispatch; unreadable for a lost file",
         ctx do
      admin = instance_admin_scope()
      dispatch = dispatch!(ctx)
      assert Dispatches.machine_log(admin, dispatch.public_id) == {:error, :not_found}
      assert Dispatches.machine_log(admin, "dp_0000000000000000") == {:error, :not_found}
      assert Dispatches.machine_log(admin, "../x") == {:error, :not_found}

      :ok = upload(ctx, dispatch)
      File.rm!(Path.join(ctx.dir, dispatch.public_id))

      assert capture_log(fn ->
               assert Dispatches.machine_log(admin, dispatch.public_id) == {:error, :unreadable}
             end) =~ "a machine log could not be read: :enoent"
    end
  end

  describe "retention" do
    test "the setting: the environment's, else the saved one, else 30 days" do
      assert MachineLogs.retention_days() == 30
      assert InstanceConfig.source(:machine_log_retention_days) == :default

      assert {:ok, %{machine_log_retention_days: 7}} =
               InstanceConfig.save(signed_in(instance_admin_scope()), :machine_logs, %{
                 "machine_log_retention_days" => "7"
               })

      assert MachineLogs.retention_days() == 7
      put_env(:machine_log_retention_days, 14)
      assert MachineLogs.retention_days() == 14
      assert InstanceConfig.source(:machine_log_retention_days) == :env
    end

    test "the variable is read as days from 1 to 365, 30 when unset or blank" do
      assert MachineLogs.parse_retention_days(nil) == {:ok, 30}
      assert MachineLogs.parse_retention_days(" ") == {:ok, 30}
      assert MachineLogs.parse_retention_days("1") == {:ok, 1}
      assert MachineLogs.parse_retention_days("365") == {:ok, 365}

      for value <- ["0", "366", "7.5", "seven"],
          do: assert({:error, _reason} = MachineLogs.parse_retention_days(value))
    end

    test "a save outside 1 to 365 days is refused, and so is a member's" do
      admin = signed_in(instance_admin_scope())

      for value <- ["0", "366"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 InstanceConfig.save(admin, :machine_logs, %{
                   "machine_log_retention_days" => value
                 })

        assert errors_on(changeset).machine_log_retention_days == [
                 "must be between 1 and 365 days, or empty for the default"
               ]
      end

      %{scope: member} = sign_up_fixture()

      assert InstanceConfig.save(signed_in(member), :machine_logs, %{
               "machine_log_retention_days" => "7"
             }) == {:error, :forbidden}
    end

    test "the job deletes a machine log older than the setting, file then record, and keeps a newer one",
         ctx do
      [old, new] = [dispatch!(ctx), dispatch!(ctx)]
      :ok = upload(ctx, old)
      :ok = upload(ctx, new)
      put_env(:machine_log_retention_days, 7)

      Repo.update_all(from(l in MachineLog, where: l.dispatch_id == ^old.id),
        set: [uploaded_at: DateTime.add(DateTime.utc_now(), -8, :day)]
      )

      assert MachineLogs.prune(dry_run: true) == %{machine_logs_deleted: 1, files_deleted: 0}
      assert record(old)

      assert {:ok, _results} = Retention.prune_all()
      assert record(old) == nil
      assert record(new)
      assert File.ls!(ctx.dir) == [new.public_id]
    end

    test "the job deletes a file whose record is gone, and a temporary file, an hour old; it keeps a file with a record",
         ctx do
      [dispatch, kept] = [dispatch!(ctx), dispatch!(ctx)]
      :ok = upload(ctx, dispatch)
      :ok = upload(ctx, kept)
      # The dispatch's row deleted, as with its run of the queue: the record goes with it.
      Repo.delete_all(from d in Dispatch, where: d.id == ^dispatch.id)
      assert record(dispatch) == nil
      temporary = Path.join(ctx.dir, ".#{dispatch.public_id}.abc.tmp")
      File.write!(temporary, "half")

      # Less than an hour old: left alone, as a write whose record is not committed yet.
      assert MachineLogs.prune() == %{machine_logs_deleted: 0, files_deleted: 0}
      assert length(File.ls!(ctx.dir)) == 3

      later = DateTime.add(DateTime.utc_now(), 3_601, :second)
      assert MachineLogs.prune(now: later) == %{machine_logs_deleted: 0, files_deleted: 2}
      assert File.ls!(ctx.dir) == [kept.public_id]
      assert File.read!(Path.join(ctx.dir, kept.public_id)) == @log
      assert %MachineLog{} = record(kept)
    end

    test "a file written again since the job listed it is left as it is", ctx do
      key = "dp_0000000000000002"
      :ok = MachineLogStore.put(key, "old")
      path = Path.join(ctx.dir, key)
      listed = System.os_time(:second) - 7_200
      File.touch!(path, listed)
      assert {:ok, [{:key, ^key, ^listed}]} = MachineLogStore.files()

      # An upload renames its file over the listed one before the delete.
      :ok = MachineLogStore.put(key, "new")
      assert MachineLogStore.delete_unchanged(key, listed) == :changed
      assert File.read!(path) == "new"

      {:ok, [{:key, ^key, now}]} = MachineLogStore.files()
      assert MachineLogStore.delete_unchanged(key, now) == :ok
      refute File.exists?(path)
      # A file not there is not counted as deleted.
      assert MachineLogStore.delete_unchanged(key, now) == :gone
    end

    test "a temporary file not there any more is :gone, so the job does not count it", ctx do
      File.mkdir_p!(ctx.dir)
      name = ".dp_0000000000000003.abc.tmp"
      File.write!(Path.join(ctx.dir, name), "half")
      assert MachineLogStore.delete_temporary(name) == :ok
      assert MachineLogStore.delete_temporary(name) == :gone
    end

    test "the job leaves a file of another name alone", ctx do
      File.mkdir_p!(ctx.dir)
      File.write!(Path.join(ctx.dir, "notes.txt"), "kept")
      later = DateTime.add(DateTime.utc_now(), 3_601, :second)
      assert MachineLogs.prune(now: later) == %{machine_logs_deleted: 0, files_deleted: 0}
      assert File.ls!(ctx.dir) == ["notes.txt"]
    end
  end

  describe "the purge" do
    test "of an organisation deletes its machine logs' files and records, and no other's", ctx do
      dispatch = dispatch!(ctx)
      :ok = upload(ctx, dispatch)

      %{scope: other} = sign_up_fixture()
      other_place = handover_place_fixture(other)
      other_dispatch = dispatch!(Map.merge(other_place, %{scope: other}))
      :ok = upload(%{key: other_place.key}, other_dispatch)

      {:ok, _} = Deletion.delete_organisation(ctx.scope, ctx.scope.organisation.slug)

      Repo.update_all(from(o in Organisation, where: o.id == ^ctx.scope.organisation.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_organisation(Scope.for_instance(ctx.scope.organisation))

      assert record(dispatch) == nil
      assert File.ls!(ctx.dir) == [other_dispatch.public_id]
      assert record(other_dispatch)
    end

    test "delete_files/2 of a workspace deletes the files of that workspace alone", ctx do
      dispatch = dispatch!(ctx)
      :ok = upload(ctx, dispatch)
      organisation_id = ctx.scope.organisation.id

      assert MachineLogs.delete_files(organisation_id, Ecto.UUID.generate()) == 0
      assert File.ls!(ctx.dir) == [dispatch.public_id]
      assert MachineLogs.delete_files(organisation_id, ctx.scope.workspace.id) == 1
      assert File.ls!(ctx.dir) == []
    end
  end

  defp signed_in(scope),
    do: put_in(scope.user.authenticated_at, DateTime.utc_now())
end
