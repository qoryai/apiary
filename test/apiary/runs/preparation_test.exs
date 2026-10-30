defmodule Apiary.Runs.PreparationTest do
  # Not async: one test makes the instance's pool, of which the instance has one at most.
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches.{Dispatch, MachineLog}
  alias Apiary.Runs.{Preparation, Projector}

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
      fixture = handed_over_fixture(ctx.scope, ctx.key)
      at = DateTime.add(fixture.dispatch.claimed_at, 3, :second)

      change_dispatch!(fixture.dispatch,
        dispatched_at: nil,
        handed_over_at: nil,
        ended_at: at,
        end_cause: :released
      )

      run = unredeemed!(fixture)

      assert %{machine: machine, stopped: stopped} = Preparation.read(ctx.scope, run)

      assert machine.started == %{
               state: "failed",
               started_at: nil,
               ended_at: at,
               duration_ms: nil
             }

      assert stopped == %{
               cause: :machine_not_made,
               step: nil,
               fixer: :workspace_admin,
               text:
                 "No machine was made: no reason given. An admin of #{ctx.scope.workspace.name} " <>
                   "reads why in the log of build-pool on its host."
             }
    end

    test "a lapsed lease", ctx do
      fixture = handed_over_fixture(ctx.scope, ctx.key)
      stale_at = fixture.dispatch.lease_until

      change_dispatch!(fixture.dispatch,
        dispatched_at: nil,
        handed_over_at: nil,
        stale_at: stale_at
      )

      run = unredeemed!(fixture)

      assert %{machine: %{started: %{state: "failed", ended_at: ^stale_at}}, stopped: stopped} =
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
                   "An instance admin reads why in this step's machine log."
             }
    end

    test "a machine that stopped before it redeemed the code", ctx do
      fixture = handed_over_fixture(ctx.scope, ctx.key)
      run = unredeemed!(fixture)
      uploaded_at = DateTime.add(fixture.dispatch.claimed_at, 90, :second)

      Repo.insert!(%MachineLog{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        dispatch_id: fixture.dispatch.id,
        storage_key: fixture.dispatch.public_id,
        byte_size: 0,
        uploaded_at: uploaded_at
      })

      assert %{machine: machine, stopped: stopped} = Preparation.read(ctx.scope, run)
      assert machine.started.ended_at == uploaded_at
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
                   "#{ctx.scope.workspace.name} reads the cause in the step's output."
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

  test "a run of another workspace reads nothing", ctx do
    %{run: run} = handed_over_fixture(ctx.scope, ctx.key)
    run = project!(run, [step_started(1, 1, "setup", "setup"), step_exited(2, 1)])
    %{scope: other} = sign_up_fixture()

    assert %{machine: nil, steps: [], stopped: nil} = Preparation.read(other, run)
  end
end
