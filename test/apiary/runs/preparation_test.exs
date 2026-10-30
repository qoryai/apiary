defmodule Apiary.Runs.PreparationTest do
  # Not async: one test makes the instance's pool, of which the instance has one at most.
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Runs.{Preparation, Projector, Run}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope, %{name: "build-pool"})
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{scope: scope, pool: pool, key: key}
  end

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp step_started(sequence, step, name, kind),
    do: {sequence, "run.step_started", %{"step" => step, "name" => name, "kind" => kind}}

  defp step_exited(sequence, step, state \\ "succeeded", exit_code \\ 0),
    do:
      {sequence, "run.step_exited",
       %{"step" => step, "state" => state, "exit_code" => exit_code, "duration_ms" => 100}}

  # A run of a fresh work item, claimed by the pool, its machine not started.
  defp claimed!(ctx) do
    {:ok, _queued} =
      Repo.transact(fn ->
        Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope), 1)
      end)

    case Dispatches.claim(ctx.key, Dispatches.now()) do
      {:ok, %{dispatch: %Dispatch{}} = claimed} ->
        claimed

      {:error, :no_gateway} ->
        _gateway = gateway_for!(ctx.scope, ctx.pool)
        {:ok, %{dispatch: %Dispatch{}} = claimed} = Dispatches.claim(ctx.key, Dispatches.now())
        claimed
    end
  end

  # Past its lease, as the clock would have it ten minutes and more after the claim.
  defp lapse!(%Dispatch{id: id}) do
    now = DateTime.utc_now()

    lease_until = %{
      DateTime.truncate(DateTime.add(now, -60, :second), :second)
      | microsecond: {0, 6}
    }

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [claimed_at: DateTime.add(now, -700, :second), lease_until: lease_until]
      )
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

  defp change_dispatch!(%Dispatch{id: id}, set),
    do: {1, _rows} = Repo.update_all(from(d in Dispatch, where: d.id == ^id), set: set)

  # A claimed run whose code no machine redeemed: pending, never attached.
  defp unredeemed!(%{run: run, dispatch: dispatch}, changes \\ []) do
    run
    |> Ecto.Changeset.change(unattached())
    |> Ecto.Changeset.change(
      run_code_public_key: nil,
      run_key_payload: nil,
      run_key_signature: nil,
      run_key_issued_at: dispatch.claimed_at,
      attach_by: run.run_code_expires_at
    )
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  describe "a run that prepared its machine and started its session" do
    test "has the machine, the steps with their output, and the session's start", ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          step_started(2, 1, "fetch git.example.com/acme/shop", "fetch"),
          {3, "run.log", step_log_data(1, "Cloning into 'shop'...\n")},
          step_exited(4, 1),
          step_started(5, 2, "compose the harness for acme/shop", "compose"),
          step_exited(6, 2),
          {7, "session.started", session_started_data()}
        ])

      preparation = Preparation.read(ctx.scope, run)

      assert %{
               dispatch_id: dispatch_id,
               pool: %{name: "build-pool", place: :workspace, operator: nil},
               machine_type: nil,
               requested_at: requested_at,
               started: %{state: "succeeded", started_at: started_at, ended_at: ended_at}
             } = preparation.machine

      assert dispatch_id == dispatch.public_id
      assert requested_at == dispatch.claimed_at
      assert started_at == dispatch.dispatched_at
      assert ended_at == run.run_key_issued_at

      assert [
               %{
                 number: 1,
                 name: "Fetch git.example.com/acme/shop",
                 kind: "fetch",
                 state: "succeeded",
                 exit_code: 0,
                 started_at: fetch_at,
                 duration_ms: 100,
                 output: %{text: "Cloning into 'shop'...", truncated: false}
               },
               %{
                 number: 2,
                 name: "Compose the harness for acme/shop",
                 output: %{text: "", truncated: false}
               }
             ] = preparation.steps

      assert fetch_at == at(2)
      assert preparation.session_started_at == at(7)
      assert preparation.stopped == nil
    end

    test "a run with no repository has no fetch step, and nothing reads as one", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data(%{"labels" => %{}})},
          step_started(2, 1, "compose the harness", "compose"),
          step_exited(3, 1),
          step_started(4, 2, "setup", "setup"),
          step_exited(5, 2),
          step_started(6, 3, "join session 1", "join"),
          step_exited(7, 3, "succeeded", -1),
          {8, "session.started", session_started_data()}
        ])

      preparation = Preparation.read(ctx.scope, run)

      assert preparation.machine == nil

      assert Enum.map(preparation.steps, & &1.name) == [
               "Compose the harness",
               "Setup",
               "Join session 1"
             ]

      assert Enum.map(preparation.steps, & &1.kind) == ["compose", "setup", "join"]
      assert preparation.session_started_at == at(8)
      assert preparation.stopped == nil
    end

    test "a run whose session events retention deleted has no session start", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)
      run = project!(run, [{1, "session.started", session_started_data()}])
      Repo.delete_all(from e in Apiary.Runs.Event, where: e.run_id == ^run.id)

      assert Preparation.read(ctx.scope, run).session_started_at == nil
    end
  end

  describe "each cause of a failed preparation" do
    test "a release: no machine was made, with the starter's reason", ctx do
      %{dispatch: dispatch, registered: registered} = claimed!(ctx)

      :ok =
        Dispatches.release(ctx.key, dispatch.public_id, %{reason: "No capacity in the region."})

      run = Repo.get!(Run, registered.id)
      assert %Run{start_failure: "machine_not_made", dispatch_run_id: nil} = run

      assert %{machine: machine, stopped: stopped} = Preparation.read(ctx.scope, run)
      assert machine.dispatch_id == dispatch.public_id
      assert machine.release_reason == "No capacity in the region."

      assert machine.started == %{
               state: "failed",
               started_at: nil,
               ended_at: run.start_failed_at,
               duration_ms: nil
             }

      fix =
        "An admin of #{ctx.scope.workspace.name} reads why in the log of build-pool on its host."

      assert stopped == %{
               cause: :machine_not_made,
               step: nil,
               fixer: :workspace_admin,
               text: "No machine was made: No capacity in the region. " <> fix,
               fix: fix
             }
    end

    test "a lapsed lease", ctx do
      %{dispatch: dispatch, registered: registered} = claimed!(ctx)
      lapse!(dispatch)

      assert Dispatches.dispatched(ctx.key, dispatch.public_id, %{external: nil}) ==
               {:error, :lease_expired}

      run = Repo.get!(Run, registered.id)
      assert %Run{start_failure: "lease_lapsed"} = run
      at = run.start_failed_at

      assert %{machine: %{started: %{state: "failed", ended_at: ^at}}, stopped: stopped} =
               Preparation.read(ctx.scope, run)

      assert stopped.cause == :lease_lapsed
      assert stopped.fixer == :workspace_admin

      assert stopped.text ==
               "build-pool did not start a machine within 10 minutes. An admin of " <>
                 "#{ctx.scope.workspace.name} checks that build-pool is running."
    end

    test "a code not redeemed within 15 minutes, on the instance's pool", ctx do
      fixture = handed_over_fixture(ctx.scope, ctx.key)
      instance_pool = instance_pool_fixture(%{name: "qory-pool"})
      change_dispatch!(fixture.dispatch, pool_id: instance_pool.id)
      run = unredeemed!(fixture, state: "lost", lost_at: fixture.run.run_code_expires_at)

      assert %{machine: machine, stopped: stopped} = Preparation.read(ctx.scope, run)

      assert machine.pool == %{
               id: instance_pool.public_id,
               name: "qory-pool",
               place: :instance,
               operator: nil
             }

      assert machine.started.state == "failed"
      assert machine.started.ended_at == run.lost_at

      assert stopped == %{
               cause: :code_not_redeemed,
               step: nil,
               fixer: :instance_admin,
               text:
                 "The machine did not start the run within 15 minutes of the request. " <>
                   "An instance admin finds the cause in the machine log of the Machine " <>
                   "started step.",
               fix:
                 "An instance admin finds the cause in the machine log of the Machine started step."
             }
    end

    @tag :tmp_dir
    test "a machine that stopped before it redeemed the code", ctx do
      put_env(:machine_logs_dir, Path.join(ctx.tmp_dir, "machine-logs"))
      %{dispatch: dispatch, registered: registered} = claimed!(ctx)
      :ok = Dispatches.dispatched(ctx.key, dispatch.public_id, %{external: nil})

      :ok =
        Dispatches.upload_machine_log(ctx.key, dispatch.public_id, %{
          log: "qory-machine-start: Docker started\n",
          truncated: false
        })

      run = Repo.get!(Run, registered.id)
      assert %Run{start_failure: "machine_stopped"} = run

      assert %{machine: machine, stopped: stopped} = Preparation.read(ctx.scope, run)
      assert machine.started.started_at == Repo.get!(Dispatch, dispatch.id).dispatched_at
      assert machine.started.ended_at == run.start_failed_at
      assert stopped.cause == :machine_stopped

      assert stopped.text ==
               "The machine stopped before it started the run. An admin of " <>
                 "#{ctx.scope.workspace.name} reads why in the log of build-pool on its host."
    end

    test "a pending run whose code is still good has not stopped", ctx do
      run = ctx.scope |> handed_over_fixture(ctx.key) |> unredeemed!()

      assert %{machine: %{started: %{state: "running", ended_at: nil}}, stopped: nil} =
               Preparation.read(ctx.scope, run)
    end

    test "a failed step: its number and its exit code; the workspace fixes a fetch", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          step_started(1, 1, "fetch git.example.com/acme/shop", "fetch"),
          {2, "run.log", step_log_data(1, "fatal: repository not found\n")},
          step_exited(3, 1, "failed", 128)
        ])

      assert %{machine: machine, stopped: stopped} = Preparation.read(ctx.scope, run)
      assert machine.started.state == "succeeded"

      assert stopped == %{
               cause: :step_failed,
               step: 1,
               fixer: :workspace_admin,
               text:
                 "Fetch git.example.com/acme/shop failed with exit code 128. An admin of " <>
                   "#{ctx.scope.workspace.name} reads the cause in the step's output.",
               fix:
                 "An admin of #{ctx.scope.workspace.name} reads the cause in the step's output."
             }
    end

    test "a failed image step takes the pool's row; the state decides, not the exit code",
         ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      instance_pool = instance_pool_fixture(%{name: "qory-pool"})
      change_dispatch!(dispatch, pool_id: instance_pool.id)

      run =
        project!(run, [
          step_started(1, 1, "fetch image registry.example/agent", "image"),
          step_exited(2, 1, "failed", 0),
          step_started(3, 2, "setup", "setup"),
          step_exited(4, 2, "succeeded", 1)
        ])

      assert %{stopped: stopped} = Preparation.read(ctx.scope, run)
      assert %{cause: :step_failed, step: 1, fixer: :instance_admin} = stopped

      assert stopped.text ==
               "Fetch image registry.example/agent failed with exit code 0. An instance admin " <>
                 "reads the cause in the step's output."
    end

    test "a refused join has no exit status: its line shows no exit code", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          step_started(1, 1, "join session 1", "join"),
          step_exited(2, 1, "failed", -1)
        ])

      assert %{steps: [%{exit_code: -1}], stopped: stopped} = Preparation.read(ctx.scope, run)

      assert stopped.text ==
               "Join session 1 failed. An admin of #{ctx.scope.workspace.name} reads the " <>
                 "cause in the step's output."
    end

    test "a step with only its exit: no name and no start, named by its number", ctx do
      run = ctx.scope |> run_fixture() |> project!([step_exited(1, 1, "failed", 2)])

      assert %{steps: [step], stopped: stopped} = Preparation.read(ctx.scope, run)

      assert %{number: 1, name: nil, kind: nil, started_at: nil, state: "failed", exit_code: 2} =
               step

      assert Preparation.step_name(step) == "Step 1"

      assert stopped.text ==
               "Step 1 failed with exit code 2. An admin of #{ctx.scope.workspace.name} " <>
                 "reads the cause in the step's output."
    end
  end

  describe "a step's output" do
    test "is cut to its last 64 KiB, at a whole line", ctx do
      line = String.duplicate("x", 99) <> "\n"
      chunk = String.duplicate(line, 300)

      events =
        [step_started(1, 1, "setup", "setup")] ++
          for(n <- 2..4, do: {n, "run.log", step_log_data(1, chunk)}) ++
          [{5, "run.log", step_log_data(1, "the last line\n")}, step_exited(6, 1)]

      run = ctx.scope |> run_fixture() |> project!(events)

      assert %{steps: [%{output: %{text: text, truncated: true}}]} =
               Preparation.read(ctx.scope, run)

      assert byte_size(text) <= Preparation.output_bytes()
      assert String.ends_with?(text, "\n" <> String.duplicate("x", 99) <> "\nthe last line")
      assert text |> String.split("\n") |> hd() == String.duplicate("x", 99)
      # Every byte of the last 64 KiB but the line the cut fell in.
      assert byte_size(text) > Preparation.output_bytes() - 100 - 1
    end

    test "under 64 KiB is whole", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          step_started(1, 1, "setup", "setup"),
          {2, "run.log", step_log_data(1, "\e[32mready\e[0m\n")},
          step_exited(3, 1)
        ])

      assert %{steps: [%{output: %{text: "ready", truncated: false}}]} =
               Preparation.read(ctx.scope, run)
    end
  end

  describe "a run whose log output retention deleted" do
    test "has steps with no output, and a cause line that shows the output was deleted",
         ctx do
      {:ok, workspace} = Apiary.Retention.update_retention(ctx.scope, %{log_retention_days: 7})

      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          step_started(1, 1, "setup", "setup"),
          {2, "run.log", step_log_data(1, "make: *** [setup] Error 2\n")},
          step_exited(3, 1, "failed", 2),
          {4, "run.exited", %{"state" => "failed", "exit_code" => 2, "duration_ms" => 1_000}}
        ])

      now = DateTime.add(DateTime.utc_now(), 10 * 86_400, :second)
      assert %{runs_pruned: 1} = Apiary.Retention.prune_workspace(workspace, now: now)
      run = Repo.get!(Run, run.id)
      assert %DateTime{} = run.log_pruned_at

      assert %{
               log_pruned_at: pruned_at,
               steps: [%{output: %{text: "", truncated: false}}],
               stopped: stopped
             } = Preparation.read(ctx.scope, run)

      assert pruned_at == run.log_pruned_at

      assert stopped.text ==
               "Setup failed with exit code 2. The step's output was deleted under the " <>
                 "workspace's log retention, so the cause is no longer shown."
    end
  end

  test "a run of another workspace reads nothing", ctx do
    %{run: run} = handed_over_fixture(ctx.scope, ctx.key)
    run = project!(run, [step_started(1, 1, "setup", "setup"), step_exited(2, 1)])
    %{scope: other} = sign_up_fixture()

    assert %{machine: nil, steps: [], stopped: nil} = Preparation.read(other, run)
  end
end
