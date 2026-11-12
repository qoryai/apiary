defmodule Apiary.Runs.PreparationTest do
  # Not async: one test makes the instance's pool, of which the instance has one at most.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
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

  # The Run list of `preparation` (`ApiaryWeb.PreparationComponents.run_list/1`) on a run
  # that ended in `state`, as a document; `clean_up` is what Remove the machine shows.
  defp run_list(preparation, state, clean_up \\ nil) do
    assigns = %{preparation: preparation, state: state, clean_up: clean_up}

    ~H"""
    <ApiaryWeb.PreparationComponents.run_list
      preparation={@preparation}
      alive={false}
      run_state={@state}
      clean_up={@clean_up}
    />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp row_state(html, id),
    do: html |> LazyHTML.query("##{id}") |> LazyHTML.attribute("data-state")

  defp skipped(html),
    do:
      html
      |> LazyHTML.query("div.q-prep-skipped[data-state=skipped]")
      |> LazyHTML.attribute("id")

  defp children(html, id),
    do: html |> LazyHTML.query("##{id} > .q-xb > ol > li > [id]") |> LazyHTML.attribute("id")

  # The name on the row `id`.
  defp row_name(html, id),
    do:
      html |> LazyHTML.query("##{id} > summary .q-prep-name") |> LazyHTML.text() |> String.trim()

  defp detail(kind, sent_name),
    do: Preparation.step_detail(%{kind: kind, sent_name: sent_name, number: 1})

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

    case Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now()) do
      {:ok, %{dispatch: %Dispatch{}} = claimed} ->
        claimed

      {:error, :no_gateway} ->
        _gateway = gateway_for!(ctx.scope, ctx.pool)

        {:ok, %{dispatch: %Dispatch{}} = claimed} =
          Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

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
               started_as: nil,
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
                 output: %{
                   lines: [%{number: 1, text: "Cloning into 'shop'..."}],
                   truncated: false,
                   lines_cut: false
                 }
               },
               %{
                 number: 2,
                 name: "Compose the harness for acme/shop",
                 output: %{lines: [], truncated: false}
               }
             ] = preparation.steps

      assert fetch_at == at(2)
      assert preparation.session_started_at == at(7)
      assert preparation.stopped == nil
    end

    test "the vendor's machine type is an instance admin's alone", ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      change_dispatch!(dispatch, vendor_machine_type: "example-type")
      run = project!(run, [{1, "run.started", started_data()}])

      refute Apiary.Access.instance_admin?(ctx.scope)
      assert %{started_as: nil} = Preparation.read(ctx.scope, run).machine

      # The reader's organisation made the instance's in place of the suite's, and its
      # owner an instance admin.
      Apiary.EditionKit.module().hide_instance_organisation(
        Apiary.Edition.instance_organisation_id()
      )

      Apiary.EditionKit.show_instance_organisation(ctx.scope.organisation.id)

      assert Apiary.Edition.instance_organisation_id() == ctx.scope.organisation.id
      assert Apiary.Access.instance_admin?(ctx.scope)
      assert %{started_as: "example-type"} = Preparation.read(ctx.scope, run).machine

      # The read is the action's (`instance.read_machine`): refused, it shows nothing.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReadsNoMachine)
      assert Apiary.Access.instance_admin?(ctx.scope)
      assert %{started_as: nil} = Preparation.read(ctx.scope, run).machine

      change_dispatch!(dispatch, vendor_machine_type: nil)
      assert %{started_as: nil} = Preparation.read(ctx.scope, run).machine
    end

    test "the machine type is the claim answer's, with its spec; nil for an answer without one",
         ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      run = project!(run, [{1, "run.started", started_data()}])
      assert %{machine_type: nil} = Preparation.read(ctx.scope, run).machine

      spec = Apiary.MachineTypesFixtures.spec()
      change_dispatch!(dispatch, machine_type: "large", machine_spec: spec)

      assert %{machine_type: %{key: "large", name: nil, spec: ^spec}} =
               Preparation.read(ctx.scope, run).machine

      # With the name of the type that has the key today.
      Apiary.MachineTypesFixtures.machine_type_fixture(key: "large", name: "Large builds")

      assert %{machine_type: %{key: "large", name: "Large builds", spec: ^spec}} =
               Preparation.read(ctx.scope, run).machine
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

  describe "a run's steps after the session" do
    # A run whose session started and exited, then a step of `kind` ended in `state`.
    defp after_session!(ctx, kind, state, exit_code) do
      ctx.scope
      |> run_fixture()
      |> project!([
        {1, "run.started", started_data()},
        step_started(2, 1, "fetch git.example.com/acme/web-shop", "fetch"),
        step_exited(3, 1),
        step_started(4, 2, "build the environment image", "build"),
        step_exited(5, 2),
        {6, "session.started", session_started_data()},
        {7, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
        step_started(8, 3, "push work to git.example.com/acme/web-shop", kind),
        {9, "run.log", step_log_data(3, "To https://git.example.com/acme/web-shop.git\n")},
        step_exited(10, 3, state, exit_code),
        {11, "run.exited", %{"state" => state, "exit_code" => exit_code, "duration_ms" => 1000}}
      ])
    end

    test "a push leaves `steps` for `after_session`, in the same shape; a build stays", ctx do
      run = after_session!(ctx, "push", "succeeded", 0)
      preparation = Preparation.read(ctx.scope, run)

      assert [%{number: 1, kind: "fetch"}, %{number: 2, kind: "build"}] = preparation.steps

      assert [
               %{
                 number: 3,
                 name: "Push work to git.example.com/acme/web-shop",
                 kind: "push",
                 state: "succeeded",
                 exit_code: 0,
                 duration_ms: 100,
                 output: %{
                   lines: [%{text: "To https://git.example.com/acme/web-shop.git"}],
                   truncated: false
                 }
               }
             ] = preparation.after_session

      assert preparation.stopped == nil
    end

    test "a failed push is no stop, and no step name to stop at", ctx do
      run = after_session!(ctx, "push", "failed", 1)
      preparation = Preparation.read(ctx.scope, run)

      assert [%{number: 3, state: "failed"}] = preparation.after_session
      assert preparation.stopped == nil
      assert Preparation.stopped_step(preparation) == nil

      assert Preparation.push_line(preparation) ==
               "Push work to git.example.com/acme/web-shop failed with exit code 1."
    end

    test "a stop at a step has its first sentence alone for the header, on every pool" do
      stopped = %{step: 3, what: "Start the wall failed with exit code 125.", text: "x"}

      for fixer <- [:support, :operator_admin, :workspace_admin] do
        assert Preparation.stop_line(%{stopped: Map.put(stopped, :fixer, fixer)}) ==
                 "Start the wall failed with exit code 125."
      end

      assert Preparation.stop_line(%{stopped: %{step: nil, fixer: :support, what: "x"}}) == nil
      assert Preparation.stop_line(%{stopped: nil}) == nil
    end

    test "a failed setup step still is one, in the same place of the run", ctx do
      run = after_session!(ctx, "setup", "failed", 1)
      preparation = Preparation.read(ctx.scope, run)

      assert preparation.after_session == []
      assert %{cause: :step_failed, step: 3} = preparation.stopped
      assert Preparation.stopped_step(preparation) == "Set up the dev container"
    end

    test "a reader who may not read the log has the step, with no output", ctx do
      run = after_session!(ctx, "push", "failed", 1)

      assert %{after_session: [%{number: 3, output: nil}]} =
               Preparation.read(ctx.scope, run, log: false)
    end

    test "the machine's start does not depend on the push", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          step_started(3, 1, "push work to git.example.com/acme/web-shop", "push")
        ])

      assert %{steps: [], after_session: [%{state: "running"}], machine: %{started: started}} =
               Preparation.read(ctx.scope, run)

      assert started.state == "succeeded"
    end
  end

  describe "agent sessions and helper steps" do
    defp exited(sequence, session, state \\ "succeeded"),
      do:
        {sequence, "session.exited", %{"session" => session, "state" => state, "exit_code" => 0}}

    defp bare(session),
      do: %{"session" => session, "runtime" => "git", "bare" => true, "command" => "git"}

    # Two agent sessions, then the copy of the work around a bare session 3, then a push.
    defp two_sessions_and_copy(copy_state \\ "succeeded") do
      [
        {1, "run.started", started_data()},
        step_started(2, 1, "fetch git.example.com/acme/web-shop", "fetch"),
        step_exited(3, 1),
        step_started(4, 2, "join session 1", "join"),
        step_exited(5, 2),
        {6, "session.started", session_started_data()},
        step_started(7, 3, "start the wall", "wall"),
        step_exited(8, 3),
        {9, "runtime.started", %{"session" => 1, "model" => "model-small-1"}},
        {10, "runtime.result", %{"session" => 1, "outcome" => "success", "turns" => 3}},
        exited(11, 1),
        step_started(12, 4, "join session 2", "join"),
        step_exited(13, 4),
        {14, "session.started", session_started_data(%{"session" => 2})},
        step_started(15, 5, "start the wall", "wall"),
        step_exited(16, 5),
        {17, "runtime.started", %{"session" => 2, "model" => "model-large-1"}},
        {18, "runtime.result", %{"session" => 2, "outcome" => "success", "turns" => 9}},
        exited(19, 2),
        step_started(20, 6, "copy the work back", "copy"),
        step_started(21, 7, "join session 3", "join"),
        step_exited(22, 7),
        {23, "session.started", bare(3)},
        step_started(24, 8, "start the wall", "wall"),
        step_exited(25, 8),
        exited(26, 3, "failed"),
        step_exited(27, 6, copy_state, if(copy_state == "failed", do: 128, else: 0)),
        step_started(28, 9, "push work to git.example.com/acme/web-shop", "push"),
        step_exited(29, 9)
      ]
    end

    test "each agent session has its start and its end; a bare session is none", ctx do
      run = ctx.scope |> run_fixture() |> project!(two_sessions_and_copy())
      preparation = Preparation.read(ctx.scope, run)

      assert [
               %{
                 session: 1,
                 sequence: 6,
                 started_at: first_at,
                 end: %{turns: 3, model: "model-small-1", state: "succeeded"}
               },
               %{
                 session: 2,
                 sequence: 14,
                 end: %{turns: 9, model: "model-large-1", state: "succeeded"} = second
               }
             ] = preparation.sessions

      assert preparation.session_started_at == first_at
      assert DateTime.compare(first_at, at(6)) == :eq
      # The bare session's failed exit at 26 is no agent session's.
      assert preparation.session_end == second
    end

    test "each agent session has the runtime of its start, nil when that is no text", ctx do
      with_runtimes = fn first, second ->
        Enum.map(two_sessions_and_copy(), fn
          {6, "session.started", data} ->
            {6, "session.started", Map.put(data, "runtime", first)}

          {14, "session.started", data} ->
            {14, "session.started", Map.put(data, "runtime", second)}

          event ->
            event
        end)
      end

      run = ctx.scope |> run_fixture() |> project!(with_runtimes.("claude", "qory"))

      assert [%{sequence: 6, runtime: "claude"}, %{sequence: 14, runtime: "qory"}] =
               Preparation.read(ctx.scope, run).sessions

      run = ctx.scope |> run_fixture() |> project!(with_runtimes.(%{"name" => "qory"}, 5))

      assert [%{sequence: 6, runtime: nil}, %{sequence: 14, runtime: nil}] =
               Preparation.read(ctx.scope, run).sessions
    end

    test "the copy and the bare session's join and wall are helper steps", ctx do
      run = ctx.scope |> run_fixture() |> project!(two_sessions_and_copy())
      preparation = Preparation.read(ctx.scope, run)

      assert [
               {1, "fetch", false},
               {2, "join", false},
               {3, "wall", false},
               {4, "join", false},
               {5, "wall", false},
               {7, "join", true},
               {8, "wall", true}
             ] = for(step <- preparation.steps, do: {step.number, step.kind, step.helper})

      assert [
               %{
                 number: 6,
                 kind: "copy",
                 helper: true,
                 started_sequence: 20,
                 exited_sequence: 27
               },
               %{number: 9, kind: "push", helper: false}
             ] = preparation.after_session
    end

    test "a failed copy after the agent's success is no stop, and has the header's line", ctx do
      run = ctx.scope |> run_fixture() |> project!(two_sessions_and_copy("failed"))
      preparation = Preparation.read(ctx.scope, run)

      assert preparation.stopped == nil
      assert Preparation.push_failed?(preparation)

      assert Preparation.push_line(preparation) ==
               "The run's work did not come back from the machine."
    end

    test "a failed wall of the bare session, with the copy cancelled, is no stop", ctx do
      events =
        two_sessions_and_copy()
        |> Enum.take(23)
        |> Kernel.++([
          step_started(24, 8, "start the wall", "wall"),
          step_exited(25, 8, "failed", 125),
          step_exited(27, 6, "cancelled", -1)
        ])

      run = ctx.scope |> run_fixture() |> project!(events)
      assert %{stopped: nil} = Preparation.read(ctx.scope, run)
    end

    test "a bare session's join and wall are helper steps with no copy around them", ctx do
      events =
        two_sessions_and_copy()
        |> Enum.reject(fn event -> elem(event, 0) in [20, 27] end)

      run = ctx.scope |> run_fixture() |> project!(events)
      preparation = Preparation.read(ctx.scope, run)

      assert [true, true] = for(%{number: n, helper: h} <- preparation.steps, n in [7, 8], do: h)

      assert for(%{number: n, helper: h} <- preparation.steps, n in 1..5, do: h) ==
               List.duplicate(false, 5)
    end

    test "a session whose wall failed after its start never ran its agent: it is no agent session",
         ctx do
      events = [
        {1, "run.started", started_data()},
        step_started(2, 1, "join session 1", "join"),
        step_exited(3, 1),
        {4, "session.started", session_started_data()},
        step_started(5, 2, "start the wall", "wall"),
        step_exited(6, 2, "failed", 125),
        {7, "session.exited", %{"session" => 1, "state" => "failed", "exit_code" => 1}}
      ]

      run = ctx.scope |> run_fixture() |> project!(events)
      preparation = Preparation.read(ctx.scope, run)

      assert preparation.sessions == []
      assert preparation.session_started_at == nil
      assert preparation.session_end == nil
      assert %{cause: :step_failed, step: 2} = preparation.stopped

      # The Run list: the join and the failed wall in Prepare the session, then Run the
      # agent and Save the outputs Skipped, Run the agent with no Started or Finished.
      html = run_list(preparation, "failed")

      assert children(html, "prepare-machine-session-prepare") == [
               "prepare-machine-step-1",
               "prepare-machine-step-2"
             ]

      assert row_state(html, "prepare-machine-session-prepare") == ["failed"]
      assert skipped(html) == ["prepare-machine-session-agent", "prepare-machine-session-outputs"]

      assert html |> LazyHTML.query("#prepare-machine-session-agent") |> LazyHTML.text() =~
               ~r/^\s*Run the agent\s*Skipped\s*$/
    end

    test "a wall that fails before its session starts leaves the session before it an agent session",
         ctx do
      events = [
        {1, "run.started", started_data()},
        step_started(2, 1, "join session 1", "join"),
        step_exited(3, 1),
        {4, "session.started", session_started_data()},
        step_started(5, 2, "start the wall", "wall"),
        step_exited(6, 2),
        {7, "runtime.result", %{"session" => 1, "outcome" => "success", "turns" => 3}},
        {8, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
        step_started(9, 3, "join session 2", "join"),
        step_exited(10, 3),
        step_started(11, 4, "start the wall", "wall"),
        step_exited(12, 4, "failed", 125)
      ]

      run = ctx.scope |> run_fixture() |> project!(events)
      preparation = Preparation.read(ctx.scope, run)

      assert [%{session: 1, sequence: 4, started_at: started_at, end: %{exit_code: 0}}] =
               preparation.sessions

      assert preparation.session_started_at == started_at
      assert %{cause: :step_failed, step: 4} = preparation.stopped

      # Session 1 ran its agent; the wall of session 2 failed in Agent session 2, whose Run
      # the agent and Save the outputs are Skipped.
      html = run_list(preparation, "failed")
      assert row_state(html, "prepare-machine-session-agent") == ["succeeded"]
      assert row_name(html, "prepare-machine-step-1") == "Start the agent"
      assert row_name(html, "prepare-machine-step-3") == "Start the agent"

      assert children(html, "prepare-machine-session-2-prepare") == [
               "prepare-machine-step-3",
               "prepare-machine-step-4"
             ]

      assert row_state(html, "prepare-machine-session-2-prepare") == ["failed"]

      assert skipped(html) == [
               "prepare-machine-session-2-agent",
               "prepare-machine-session-2-outputs"
             ]
    end

    test "an agent run with a build step before its first join is no prebuild", ctx do
      events = [
        {1, "run.started", started_data()},
        step_started(2, 1, "fetch acme/shop", "fetch"),
        step_exited(3, 1),
        step_started(4, 2, "build the environment image", "build"),
        step_exited(5, 2),
        step_started(6, 3, "setup npm ci", "setup"),
        step_exited(7, 3, "failed", 1)
      ]

      run = ctx.scope |> run_fixture() |> project!(events)
      preparation = Preparation.read(ctx.scope, run)
      refute preparation.prebuild

      # The build is a step of Prepare the machine, and Agent session 1 is Skipped.
      html = run_list(preparation, "failed")

      assert children(html, "prepare-machine-prepare") == [
               "prepare-machine-step-1",
               "prepare-machine-step-2",
               "prepare-machine-step-3"
             ]

      assert "prepare-machine-session" in skipped(html)
      assert html |> LazyHTML.query("#prepare-machine-outputs") |> Enum.empty?()
    end

    test "a failed wall of an agent session keeps its cause line", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!(
          Enum.take(two_sessions_and_copy(), 14) ++
            [
              step_started(15, 5, "start the wall", "wall"),
              step_exited(16, 5, "failed", 125)
            ]
        )

      assert %{stopped: %{cause: :step_failed, step: 5, what: what}} =
               Preparation.read(ctx.scope, run)

      assert what == "Start the wall failed with exit code 125."
    end

    test "a wall that fails after the next agent join, past a bare session, is no helper step",
         ctx do
      # Session 1, the bare session 2 with no copy around it, then join 3 and its wall,
      # which fails before session 3 starts.
      events =
        Enum.take(two_sessions_and_copy(), 11) ++
          [
            step_started(12, 4, "join session 2", "join"),
            step_exited(13, 4),
            {14, "session.started", bare(2)},
            step_started(15, 5, "start the wall", "wall"),
            step_exited(16, 5),
            exited(17, 2),
            step_started(18, 6, "join session 3", "join"),
            step_exited(19, 6),
            step_started(20, 7, "start the wall", "wall"),
            step_exited(21, 7, "failed", 125)
          ]

      run = ctx.scope |> run_fixture() |> project!(events)
      preparation = Preparation.read(ctx.scope, run)

      assert for(%{number: n, helper: h} <- preparation.steps, n in 4..7, do: {n, h}) ==
               [{4, true}, {5, true}, {6, false}, {7, false}]

      assert %{cause: :step_failed, step: 7, what: "Start the wall failed with exit code 125."} =
               preparation.stopped
    end

    test "an end event with no `session`, from an old record, ends the last agent session started before it",
         ctx do
      events = [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.started", %{"model" => "model-small-1"}},
        {4, "runtime.result", %{"outcome" => "error", "turns" => 2}},
        {5, "session.exited", %{"state" => "failed", "exit_code" => 1}},
        {6, "session.started", session_started_data(%{"session" => 2})},
        {7, "runtime.started", %{"model" => "model-large-1"}},
        {8, "runtime.result", %{"outcome" => "success", "turns" => 9}},
        {9, "session.exited", %{"state" => "succeeded", "exit_code" => 0}}
      ]

      run = ctx.scope |> run_fixture() |> project!(events)

      assert [
               %{session: 1, end: %{outcome: "error", state: "failed", model: "model-small-1"}},
               %{
                 session: 2,
                 end: %{outcome: "success", state: "succeeded", model: "model-large-1"}
               }
             ] = Preparation.read(ctx.scope, run).sessions
    end

    test "a run with one session and no `session` on its events reads as before", ctx do
      events = [
        {1, "run.started", started_data()},
        {2, "session.started", Map.delete(session_started_data(), "session")},
        {3, "runtime.result", %{"outcome" => "success", "turns" => 4}},
        {4, "session.exited", %{"state" => "succeeded", "exit_code" => 0}}
      ]

      run = ctx.scope |> run_fixture() |> project!(events)
      preparation = Preparation.read(ctx.scope, run)

      assert [%{session: nil, sequence: 2, end: %{turns: 4, exit_code: 0} = finished}] =
               preparation.sessions

      assert preparation.session_end == finished
    end

    test "a run with no session's start takes its end from its last end events", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data()},
          {2, "runtime.result", %{"outcome" => "success", "turns" => 4}},
          exited(3, 1)
        ])

      assert %{
               sessions: [],
               session_started_at: nil,
               session_end: %{turns: 4, state: "succeeded"}
             } =
               Preparation.read(ctx.scope, run)
    end

    test "a run whose only session is bare has no agent session", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data()},
          step_started(2, 1, "join session 1", "join"),
          step_exited(3, 1),
          {4, "session.started", bare(1)},
          exited(5, 1)
        ])

      assert %{sessions: [], session_started_at: nil, session_end: nil, steps: [%{helper: true}]} =
               Preparation.read(ctx.scope, run)

      assert Preparation.session_of([], %{sequence: 4}) == nil
    end
  end

  describe "a prebuild" do
    # A prebuild as qory runs it (`internal/pool/prebuild`): no step of the kind `build`,
    # and one session, which Forager writes as a join, the session's start, the image
    # step, its wall and its exit, then `dev.qory.run.built` with the image. Forager
    # marks the session's start `bare` from its commit c6c20c6b on, so each case runs
    # with and without the mark.
    @describetag needs: [:factory, :registry]
    # A report that fails its check is logged as a warning (`Apiary.Dispatches.Built`).
    @describetag :capture_log

    @digest String.duplicate("4c1e", 16)

    # Remove the machine as the pool's starter reports a machine that is gone.
    @gone {:report, :gone, ~U[2026-11-08 06:05:00.000000Z]}

    setup ctx do
      _gateway = gateway_for!(ctx.scope, ctx.pool)
      %{run: run, dispatch: dispatch} = prebuild_handed_over!(ctx.scope, ctx.key)
      %{run: run, dispatch: dispatch}
    end

    # The run's events: the session's join, its start, the image step and its wall with
    # `wall_state`;
    # after a wall that succeeded, the session's exit with `exit_code` and, for 0,
    # `dev.qory.run.built` with `image`, unless `report` is false; then the run's exit,
    # failed with -1 when the build sent no report, as `qory` exits when its check of the
    # build's result fails.
    defp prebuild_events(opts) do
      bare = if Keyword.get(opts, :bare), do: %{"bare" => true}, else: %{}
      wall_state = Keyword.get(opts, :wall_state, "succeeded")
      exit_code = Keyword.get(opts, :exit_code, 0)
      report? = Keyword.get(opts, :report, true)
      wall_code = if wall_state == "succeeded", do: 0, else: 125
      built = wall_state == "succeeded" and exit_code == 0 and report?

      start = session_started_data(Map.merge(%{"runtime" => "qory", "command" => "qory"}, bare))

      built_data = %{
        "image" => Keyword.fetch!(opts, :image),
        "size" => 1_048_576,
        "commit" => String.duplicate("a1", 20),
        "environment_ref" => "env-1"
      }

      session_end =
        cond do
          wall_state != "succeeded" ->
            []

          exit_code == 0 ->
            [
              {9, "session.exited",
               %{"session" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 900}}
            ] ++ if(report?, do: [{10, "run.built", built_data}], else: [])

          true ->
            [
              {9, "session.exited",
               %{
                 "session" => 1,
                 "state" => "failed",
                 "exit_code" => exit_code,
                 "duration_ms" => 900
               }}
            ]
        end

      [
        {1, "run.started", started_data(%{"wall" => "docker"})},
        step_started(2, 1, "join session 1", "join"),
        step_exited(3, 1),
        {4, "session.started", start},
        step_started(5, 2, "registry.example.com/acme/agent:1.4", "image"),
        step_exited(6, 2),
        step_started(7, 3, "start the wall", "wall"),
        step_exited(8, 3, wall_state, wall_code)
      ] ++
        session_end ++
        [
          {11, "run.exited",
           %{
             "state" => if(built, do: "succeeded", else: "failed"),
             "exit_code" =>
               cond do
                 built -> 0
                 report? -> 1
                 true -> -1
               end,
             "duration_ms" => 1000
           }}
        ]
    end

    defp rows(html),
      do: html |> LazyHTML.query("#prepare-machine > ol > li > [id]") |> LazyHTML.attribute("id")

    defp facts(html, id) do
      terms = html |> LazyHTML.query("##{id} > .q-xb > dl dt") |> Enum.map(&LazyHTML.text/1)
      values = html |> LazyHTML.query("##{id} > .q-xb > dl dd") |> Enum.map(&LazyHTML.text/1)
      Enum.zip(Enum.map(terms, &String.trim/1), Enum.map(values, &String.trim/1))
    end

    for bare <- [false, true] do
      test "with bare #{bare}: Build the image has the session, Save the outputs the image",
           ctx do
        image = destination_image(ctx.run, @digest)
        run = project!(ctx.run, prebuild_events(bare: unquote(bare), image: image))
        preparation = Preparation.read(ctx.scope, run)

        assert preparation.prebuild
        assert [%{session: 1, sequence: 4}] = preparation.sessions
        assert %{image: ^image, refused: nil, fix: nil} = preparation.built
        assert ApiaryWeb.PreparationComponents.built_line(preparation) == nil

        html = run_list(preparation, "completed", @gone)

        assert Enum.take(rows(html), -4) == [
                 "prepare-machine-prepare",
                 "prepare-machine-build",
                 "prepare-machine-outputs",
                 "prepare-machine-remove"
               ]

        assert row_state(html, "prepare-machine-build") == ["succeeded"]

        assert children(html, "prepare-machine-prepare") == ["prepare-machine-step-2"]

        assert children(html, "prepare-machine-build") == [
                 "prepare-machine-step-1",
                 "prepare-machine-step-3"
               ]

        assert row_name(html, "prepare-machine-step-1") == "Start the build"
        assert row_name(html, "prepare-machine-step-3") == "Start the wall"

        assert [{"Started", _at}, {"Finished", _end}, {"Result", "exit 0"}] =
                 facts(html, "prepare-machine-build")

        assert [{"Outputs saved", _at}, {"Image", ^image}] =
                 facts(html, "prepare-machine-outputs")

        # One event: its time, and no duration.
        assert html
               |> LazyHTML.query("#prepare-machine-outputs > summary .q-tc2")
               |> LazyHTML.text()
               |> String.trim() == ""

        text = LazyHTML.text(html)
        refute text =~ "Agent session"
        refute text =~ "Prepare the session"
        refute text =~ "Run the agent"
      end
    end

    for bare <- [false, true] do
      test "with bare #{bare}: a failed wall fails Build the image, with its cause line",
           ctx do
        run =
          project!(
            ctx.run,
            prebuild_events(bare: unquote(bare), wall_state: "failed", image: "unused")
          )

        preparation = Preparation.read(ctx.scope, run)
        html = run_list(preparation, "failed", @gone)

        assert row_state(html, "prepare-machine-build") == ["failed"]
        assert row_state(html, "prepare-machine-step-3") == ["failed"]

        assert html
               |> LazyHTML.query("#prepare-machine-step-3 #prepare-machine-cause")
               |> LazyHTML.text() =~ "Start the wall failed with exit code 125."

        assert skipped(html) == ["prepare-machine-outputs"]
      end
    end

    test "a failed join is Start the build, with its cause line", ctx do
      events = [
        {1, "run.started", started_data(%{"wall" => "docker"})},
        step_started(2, 1, "join session 1", "join"),
        step_exited(3, 1, "failed", 1),
        {4, "session.exited",
         %{"session" => 1, "state" => "failed", "exit_code" => -1, "duration_ms" => 0}},
        {5, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
      ]

      run = project!(ctx.run, events)
      preparation = Preparation.read(ctx.scope, run)
      what = "Start the build failed with exit code 1."

      assert %{cause: :step_failed, step: 1} = preparation.stopped
      assert preparation.stopped.what =~ what

      html = run_list(preparation, "failed", @gone)
      assert row_state(html, "prepare-machine-build") == ["failed"]
      assert row_name(html, "prepare-machine-step-1") == "Start the build"

      assert html
             |> LazyHTML.query("#prepare-machine-step-1 #prepare-machine-cause")
             |> LazyHTML.text() =~ what

      assert skipped(html) == ["prepare-machine-outputs"]
    end

    test "a failed session fails Build the image, with the session's cause line", ctx do
      run = project!(ctx.run, prebuild_events(bare: true, exit_code: 1, image: "unused"))
      preparation = Preparation.read(ctx.scope, run)
      assert preparation.built == nil

      html = run_list(preparation, "failed", @gone)

      assert row_state(html, "prepare-machine-build") == ["failed"]
      assert row_state(html, "prepare-machine-step-3") == ["succeeded"]

      assert html
             |> LazyHTML.query("#prepare-machine-build > .q-xb > #prepare-machine-cause")
             |> LazyHTML.text() =~ "Build the image failed with exit code 1."

      assert skipped(html) == ["prepare-machine-outputs"]
    end

    # The cause line of Save the outputs, as its text reads, and the values it shows in
    # code font.
    defp outputs_cause(html) do
      cause = LazyHTML.query(html, "#prepare-machine-outputs #prepare-machine-outputs-cause")
      codes = cause |> LazyHTML.query("code") |> Enum.map(&LazyHTML.text/1)
      {cause |> LazyHTML.text() |> String.trim(), codes}
    end

    test "a report away from the run's destination fails Save the outputs, with both addresses",
         ctx do
      destination = sent(ctx.run, "image_destination")
      image = destination <> "-x@sha256:" <> @digest
      run = project!(ctx.run, prebuild_events(image: image))
      preparation = Preparation.read(ctx.scope, run)

      assert %{image: ^image, refused: {:image_place, reported, ^destination}, fix: nil} =
               preparation.built

      assert reported == destination <> "-x"

      line =
        "The image was not saved: the run reported it at #{reported}, but this run saves " <>
          "images only under #{destination}."

      assert ApiaryWeb.PreparationComponents.built_line(preparation) == line

      html = run_list(preparation, "completed", @gone)
      assert row_state(html, "prepare-machine-build") == ["succeeded"]
      assert row_state(html, "prepare-machine-outputs") == ["failed"]
      assert [{"Image", ^image}] = facts(html, "prepare-machine-outputs")
      assert outputs_cause(html) == {line, [reported, destination]}
    end

    test "a report whose environment image was not sent shows it and the run's", ctx do
      place = sent(ctx.run, "environment_destination")
      image = destination_image(ctx.run, @digest)
      environment = place <> "-x@sha256:" <> @digest

      events =
        Enum.map(prebuild_events(image: image), fn
          {10, "run.built", data} ->
            {10, "run.built", Map.put(data, "environment_image", environment)}

          event ->
            event
        end)

      preparation = Preparation.read(ctx.scope, project!(ctx.run, events))

      line =
        "The image was not saved: the run reported its environment image at #{place}-x, " <>
          "but this run saves environment images only under #{place}."

      assert ApiaryWeb.PreparationComponents.built_line(preparation) == line
      html = run_list(preparation, "completed", @gone)
      assert outputs_cause(html) == {line, [place <> "-x", place]}
    end

    test "a report that breaks its form shows the member, the rule, and support", ctx do
      events =
        Enum.map(prebuild_events(image: destination_image(ctx.run, @digest)), fn
          {10, "run.built", data} -> {10, "run.built", Map.put(data, "commit", "ABC")}
          event -> event
        end)

      run = project!(ctx.run, events)
      preparation = Preparation.read(ctx.scope, run)

      assert %{refused: {:form, "commit"}, fix: {:support, public_id}} = preparation.built
      assert public_id == run.public_id

      what =
        "The image was not saved: commit in the image report is not 40 or 64 lower-case " <>
          "hexadecimal characters."

      assert ApiaryWeb.PreparationComponents.built_line(preparation) == what

      assert outputs_cause(run_list(preparation, "completed", @gone)) ==
               {what <> " Contact support with run #{run.public_id}.", ["commit"]}
    end

    test "a run whose documents have no destination: Rebuild, or ask an admin, by reader",
         ctx do
      %{scope: member} = member_fixture(ctx.scope)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [run_documents: ~s({"step":"prebuild"})]
        )

      run =
        project!(
          Repo.get!(Run, ctx.run.id),
          prebuild_events(image: destination_image(ctx.run, @digest))
        )

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [target_path: "northwind/storefront"]
        )

      run = Repo.get!(Run, run.id)

      what =
        "The image was not saved: this run has no registry address to check the image against."

      preparation = Preparation.read(member, run)

      assert %{refused: :no_destination, fix: {:rebuild, "northwind/storefront"}} =
               preparation.built

      assert ApiaryWeb.PreparationComponents.built_line(preparation) == what

      assert outputs_cause(run_list(preparation, "completed", @gone)) ==
               {what <> " Rebuild northwind/storefront to build the image again.", []}

      # A reader who may not rebuild the target's environment asks an admin of the
      # workspace.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoEnvironmentRebuild)
      workspace = ctx.scope.workspace.name
      preparation = Preparation.read(member, run)

      assert %{fix: {:ask_rebuild, ^workspace, "northwind/storefront"}} = preparation.built

      assert outputs_cause(run_list(preparation, "completed", @gone)) ==
               {what <> " Ask an admin of #{workspace} to rebuild northwind/storefront.", []}
    end

    test "a build whose image never arrived fails Save the outputs, with where to read why",
         ctx do
      run = project!(ctx.run, prebuild_events(report: false, image: "unused"))
      assert run.state == "failed"
      what = "The image was not saved: the build finished, but no image arrived."

      cause = fn preparation ->
        html = run_list(preparation, "failed", @gone)
        assert row_state(html, "prepare-machine-build") == ["succeeded"]
        assert row_state(html, "prepare-machine-outputs") == ["failed"]
        assert ApiaryWeb.PreparationComponents.built_line(preparation) == what
        html |> outputs_cause() |> elem(0)
      end

      # A pool of the workspace: its log on its host.
      preparation = Preparation.read(ctx.scope, run)

      assert %{refused: :not_sent, at: at, image: nil, fix: {:pool_log, "build-pool"}} =
               preparation.built

      assert at == run.exited_at

      assert cause.(preparation) ==
               what <> " Read the cause in the log of build-pool on its host."

      # A pool of another organisation, which an edition may let serve the workspace, is
      # in `ApiaryWeb.RunListTest`: a dispatch's pool is of its workspace or the
      # instance's here (`pool_place_matches`).

      # The instance's pool: support, with the run.
      change_dispatch!(ctx.dispatch, pool_id: instance_pool_fixture(%{name: "qory-pool"}).id)
      preparation = Preparation.read(ctx.scope, run)
      assert cause.(preparation) == what <> " Contact support with run #{run.public_id}."

      # An instance admin: the machine log, under Start the machine. The reader's
      # organisation made the instance's in place of the suite's.
      Apiary.EditionKit.module().hide_instance_organisation(
        Apiary.Edition.instance_organisation_id()
      )

      Apiary.EditionKit.show_instance_organisation(ctx.scope.organisation.id)

      assert Apiary.Access.instance_admin?(ctx.scope)
      preparation = Preparation.read(ctx.scope, run)
      assert %{fix: :machine_log} = preparation.built

      assert cause.(preparation) ==
               what <> " Read the machine log under Start the machine for the cause."
    end

    test "a prebuild lost or cancelled after its build fails Save the outputs, with that line",
         ctx do
      events =
        Enum.map(prebuild_events(report: false, image: "unused"), fn
          {seq, "run.exited", data} ->
            {seq, "run.exited", %{data | "state" => "cancelled", "exit_code" => -1}}

          event ->
            event
        end)

      run = project!(ctx.run, events)
      assert run.state == "cancelled"
      preparation = Preparation.read(ctx.scope, run)
      assert %{refused: :cancelled, at: at, image: nil, fix: nil} = preparation.built
      assert at == run.exited_at

      cancelled =
        "The image was not saved: the build finished, but the run was cancelled before " <>
          "an image arrived."

      assert ApiaryWeb.PreparationComponents.built_line(preparation) == nil
      assert ApiaryWeb.PreparationComponents.unsaved_line(preparation) == cancelled

      html = run_list(preparation, "cancelled", @gone)
      assert row_state(html, "prepare-machine-outputs") == ["failed"]
      assert outputs_cause(html) == {cancelled, []}

      lost_at = DateTime.add(run.exited_at, 30, :second)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [state: "lost", lost_at: lost_at]
        )

      preparation = Preparation.read(ctx.scope, Repo.get!(Run, run.id))
      assert %{refused: :lost, at: ^lost_at, fix: nil} = preparation.built

      lost =
        "The image was not saved: the build finished, but the run was lost before an " <>
          "image arrived."

      assert ApiaryWeb.PreparationComponents.unsaved_line(preparation) == lost
      assert outputs_cause(run_list(preparation, "lost", @gone)) == {lost, []}
    end
  end

  describe "the session of an item of the Timeline" do
    @sessions [
      %{session: 1, sequence: 6, started_at: ~U[2026-11-08 10:00:00Z], end: nil},
      %{session: 2, sequence: 14, started_at: ~U[2026-11-08 10:05:00Z], end: nil}
    ]

    test "is the agent session of the item's `session`" do
      assert Preparation.session_of(@sessions, %{session: 1, sequence: 30}) == 6
      assert Preparation.session_of(@sessions, %{session: 2, sequence: 7}) == 14
    end

    test "with no `session`, or a bare session's, is the last that started before it" do
      assert Preparation.session_of(@sessions, %{session: nil, sequence: 10}) == 6
      assert Preparation.session_of(@sessions, %{session: 3, sequence: 30}) == 14
      assert Preparation.session_of(@sessions, %{sequence: 15}) == 14
    end

    test "before every session is the first" do
      assert Preparation.session_of(@sessions, %{session: nil, sequence: 1}) == 6
      assert Preparation.session_of(@sessions, %{sequence: nil, time: nil}) == 6
    end

    test "with a reused number, is the last session of that number before it, as for an end event",
         ctx do
      events = [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.result", %{"session" => 1, "outcome" => "error", "turns" => 2}},
        exited(4, 1),
        {5, "session.started", session_started_data()},
        {6, "runtime.result", %{"session" => 1, "outcome" => "success", "turns" => 9}},
        exited(7, 1)
      ]

      run = ctx.scope |> run_fixture() |> project!(events)
      %{sessions: sessions} = Preparation.read(ctx.scope, run)

      assert [
               %{session: 1, sequence: 2, end: %{outcome: "error"}},
               %{session: 1, sequence: 5, end: %{outcome: "success"}}
             ] = sessions

      # The result at 6 ends the session started at 5, and an item at 6 belongs to it too.
      assert Preparation.session_of(sessions, %{session: 1, sequence: 6}) == 5
      assert Preparation.session_of(sessions, %{session: 1, sequence: 3}) == 2
    end

    test "with no sequence, as a Pushed row, goes by its time" do
      assert Preparation.session_of(@sessions, %{sequence: nil, time: ~U[2026-11-08 10:06:00Z]}) ==
               14

      assert Preparation.session_of(@sessions, %{sequence: nil, time: ~U[2026-11-08 10:05:00Z]}) ==
               14

      assert Preparation.session_of(@sessions, %{sequence: nil, time: ~U[2026-11-08 10:04:59Z]}) ==
               6
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
               what: "No machine was made: No capacity in the region.",
               fix: fix,
               detail: nil
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
               fixer: :support,
               text:
                 "The machine did not start the run within 15 minutes of the request. " <>
                   "Contact support with run #{run.public_id}.",
               what: "The machine did not start the run within 15 minutes of the request.",
               fix: "Contact support with run #{run.public_id}.",
               detail: nil
             }

      assert stopped.fix =~ run.public_id

      # Version 1 of the diagnostics contract has `instance_admin` for this fixer.
      document = Apiary.Runs.Diagnostics.document(run, :instance)
      assert document["preparation"]["stopped"]["fixer"] == "instance_admin"
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

    test "Machine requested takes from the claim to the starter's `dispatched`", ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)

      change_dispatch!(dispatch,
        dispatched_at: DateTime.add(dispatch.claimed_at, 2500, :millisecond)
      )

      assert %{machine: %{requested_ms: 2500}} = Preparation.read(ctx.scope, run)

      # Handed over at the code's redemption, with no `dispatched`: no time is recorded.
      change_dispatch!(dispatch, dispatched_at: nil)
      assert %{machine: %{requested_ms: nil}} = Preparation.read(ctx.scope, run)
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
                 "Clone the repository failed with exit code 128 (git.example.com/acme/shop). " <>
                   "An admin of " <>
                   "#{ctx.scope.workspace.name} reads the cause in the step's output.",
               what:
                 "Clone the repository failed with exit code 128 (git.example.com/acme/shop).",
               fix:
                 "An admin of #{ctx.scope.workspace.name} reads the cause in the step's output.",
               detail: "git.example.com/acme/shop"
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
      assert %{cause: :step_failed, step: 1, fixer: :support} = stopped

      assert stopped.text ==
               "Pull the images failed with exit code 0 (fetch image registry.example/agent). " <>
                 "Contact support with run #{run.public_id}."
    end

    test "a failed machine step takes the pool's row", ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      instance_pool = instance_pool_fixture(%{name: "qory-pool"})
      change_dispatch!(dispatch, pool_id: instance_pool.id)

      run =
        project!(run, [
          step_started(1, 1, "start machine", "machine"),
          step_exited(2, 1, "failed", 1)
        ])

      assert %{stopped: stopped} = preparation = Preparation.read(ctx.scope, run)
      assert %{cause: :step_failed, step: 1, fixer: :support} = stopped
      # The Test run and the run page show the step as its row: Start the machine.
      assert Preparation.stopped_step(preparation) == "Start the machine"

      assert stopped.text ==
               "Start the machine failed with exit code 1. " <>
                 "Contact support with run #{run.public_id}."
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
               "Start the agent failed. An admin of #{ctx.scope.workspace.name} reads the " <>
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

    test "a failed set-up command: the row's name, and the command in parentheses", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          step_started(1, 1, "setup postCreateCommand: npm ci", "setup"),
          step_exited(2, 1, "failed", 1)
        ])

      assert %{stopped: stopped} = preparation = Preparation.read(ctx.scope, run)

      assert %{
               what:
                 "Set up the dev container failed with exit code 1 (postCreateCommand: npm ci).",
               detail: "postCreateCommand: npm ci"
             } = stopped

      # The text is plain: diagnostics and the page header show it without code font.
      assert stopped.text ==
               "Set up the dev container failed with exit code 1 (postCreateCommand: npm ci). " <>
                 "An admin of #{ctx.scope.workspace.name} reads the cause in the step's output."

      assert Preparation.stopped_step(preparation) == "Set up the dev container"
    end

    test "a set-up step named by one word, as qory's prepare: no parentheses", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          step_started(1, 1, "prepare", "setup"),
          step_exited(2, 1, "failed", 1)
        ])

      assert %{stopped: %{what: what, detail: nil}} = Preparation.read(ctx.scope, run)
      assert what == "Set up the dev container failed with exit code 1."
    end

    test "an image step named by its reference alone: the reference as sent", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)

      run =
        project!(run, [
          step_started(1, 1, "registry.example.com/acme/storefront-dev:1", "image"),
          step_exited(2, 1, "failed", -1),
          step_started(3, 2, "pull registry.example.com/acme/storefront-dev:1", "image"),
          step_exited(4, 2, "failed", 1)
        ])

      assert %{steps: [image, pull], stopped: %{what: what}} = Preparation.read(ctx.scope, run)

      # The reference alone, one word, is in parentheses as sent: no upper-case first letter.
      assert what == "Pull the images failed (registry.example.com/acme/storefront-dev:1)."

      assert Preparation.step_detail(image) == "registry.example.com/acme/storefront-dev:1"
      assert Preparation.step_detail(pull) == "pull registry.example.com/acme/storefront-dev:1"
    end
  end

  describe "a step's detail, beside its row's name" do
    test "is the sent name without the kind, or the whole sent name when it starts otherwise" do
      assert detail("setup", "setup postCreateCommand: npm ci") == "postCreateCommand: npm ci"
      assert detail("fetch", "fetch git.example.com/acme/shop") == "git.example.com/acme/shop"
      assert detail("image", "fetch image registry.example/a") == "fetch image registry.example/a"

      assert detail("image", "registry.example.com/acme/storefront-dev:1") ==
               "registry.example.com/acme/storefront-dev:1"

      # Spaces around the name are no part of the detail.
      assert detail("image", "  fetch image registry.example/a ") ==
               "fetch image registry.example/a"

      assert detail("setup", " setup postCreateCommand: npm ci  ") ==
               "postCreateCommand: npm ci"

      assert detail("image", " registry.example.com/acme/storefront-dev:1 ") ==
               "registry.example.com/acme/storefront-dev:1"
    end

    test "is nil for one word, words of the label alone, a join, a kind with no label, no name" do
      assert detail("setup", "setup") == nil
      assert detail("setup", "prepare") == nil
      assert detail("image", "image") == nil
      assert detail("setup", "set up dev container") == nil
      assert detail("join", "join session 1") == nil
      assert detail("machine", "start machine") == nil
      assert detail("compose", "compose the harness") == nil
      assert detail("compose", "compose harness") == nil
      assert detail("setup", "set up the dev container") == nil
      assert detail("wall", "start the wall") == nil
      assert detail(nil, nil) == nil
    end

    test "names the row by its label, or the step's name for a kind with no label" do
      assert Preparation.row_name(%{kind: "join", name: "Join session 1"}) == "Start the agent"
      assert Preparation.row_name(%{kind: "wall", name: "Start wall"}) == "Start the wall"

      assert Preparation.row_name(%{kind: "compose", name: "Compose harness"}) ==
               "Compose the harness"

      assert Preparation.row_name(%{kind: "build", name: "Build image"}) == "Build the image"

      assert Preparation.row_name(%{kind: "machine", name: "start machine"}) ==
               "Start the machine"

      assert Preparation.row_name(%{kind: nil, name: nil, number: 3}) == "Step 3"
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

      assert %{steps: [%{output: %{truncated: true, lines_cut: false} = output}]} =
               Preparation.read(ctx.scope, run)

      text = Preparation.output_text(output)
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

      assert %{steps: [%{output: %{lines: [%{text: "ready"}], truncated: false}}]} =
               Preparation.read(ctx.scope, run)
    end

    test "of bytes that are not UTF-8 is cut to 64 KiB of text", ctx do
      # 300 lines of 100 bytes that are not UTF-8: each byte becomes a character of 3
      # bytes, so the text is about 90 KiB, from 30 KiB of bytes.
      line = :binary.copy(<<0xFF>>, 100) <> "\n"

      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          step_started(1, 1, "setup", "setup"),
          {2, "run.log", step_log_data(1, :binary.copy(line, 300))},
          step_exited(3, 1)
        ])

      assert %{steps: [%{output: %{truncated: true, lines_cut: false} = output}]} =
               Preparation.read(ctx.scope, run)

      assert byte_size(Preparation.output_text(output)) <= Preparation.output_bytes()
      assert %{number: 300} = List.last(output.lines)
    end

    test "of 40,000 lines of one character keeps its last 2,500", ctx do
      chunk = :binary.copy(".\n", 10_000)

      run =
        ctx.scope
        |> run_fixture()
        |> project!(
          [step_started(1, 1, "setup", "setup")] ++
            for(n <- 2..5, do: {n, "run.log", step_log_data(1, chunk)}) ++ [step_exited(6, 1)]
        )

      assert %{steps: [%{output: %{truncated: true, lines_cut: true, lines: lines}}]} =
               Preparation.read(ctx.scope, run)

      assert length(lines) == Preparation.output_lines()
      assert %{number: 37_501, text: "."} = hd(lines)
      assert %{number: 40_000} = List.last(lines)
    end

    test "has its lines numbered from 1, each with the time of the event it began in", ctx do
      t = ~U[2026-11-06 00:33:07.600000Z]
      later = fn ms -> DateTime.add(t, ms, :millisecond) end

      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          step_started(1, 1, "setup", "setup"),
          # Two lines in one chunk share its time.
          {2, "run.log", step_log_data(1, "Reading devcontainer.json\n> npm ci\n"), time: t},
          # A line split over two chunks has the time of the first; a line after a line
          # feed that ends a chunk begins in the next.
          {3, "run.log", step_log_data(1, "added 1184 "), time: later.(200)},
          {4, "run.log", step_log_data(1, "packages\n\n"), time: later.(35_000)},
          {5, "run.log", step_log_data(1, "found 0 vulnerabilities\n"), time: later.(36_100)},
          step_exited(6, 1)
        ])

      assert %{steps: [%{output: %{lines: lines, truncated: false} = output}]} =
               Preparation.read(ctx.scope, run)

      assert lines == [
               %{number: 1, at: t, text: "Reading devcontainer.json"},
               %{number: 2, at: t, text: "> npm ci"},
               %{number: 3, at: later.(200), text: "added 1184 packages"},
               %{number: 4, at: later.(35_000), text: ""},
               %{number: 5, at: later.(36_100), text: "found 0 vulnerabilities"}
             ]

      assert Preparation.output_text(output) ==
               "Reading devcontainer.json\n> npm ci\nadded 1184 packages\n\nfound 0 vulnerabilities"
    end

    test "of a machine step, its kind kept, has its lines and their times", ctx do
      at = ~U[2026-11-06 00:31:58.900000Z]
      run = ctx.scope |> run_fixture() |> project!(machine_step_events(1, 1, at))

      assert %{steps: [%{kind: "machine", name: "Start machine", output: %{lines: lines}}]} =
               Preparation.read(ctx.scope, run)

      assert [%{number: 1, at: ^at, text: "boot  14.8 s"} | _] = lines
      assert length(lines) == 5
    end

    test "cut to its end keeps each line's number in the whole output", ctx do
      line = String.duplicate("x", 95)

      events =
        [step_started(1, 1, "setup", "setup")] ++
          for(n <- 1..1_000, do: {n + 1, "run.log", step_log_data(1, "#{n} #{line}\n")}) ++
          [step_exited(1_002, 1)]

      run = ctx.scope |> run_fixture() |> project!(events)

      assert %{steps: [%{output: %{lines: lines, truncated: true}}]} =
               Preparation.read(ctx.scope, run)

      assert %{number: 1_000, text: "1000 " <> _} = List.last(lines)
      assert length(lines) in 600..999

      for %{number: number, text: text, at: time} <- lines do
        assert text == "#{number} #{line}"
        assert DateTime.compare(time, at(number + 1)) == :eq
      end
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
               steps: [%{output: %{lines: [], truncated: false}}],
               stopped: stopped
             } = Preparation.read(ctx.scope, run)

      assert pruned_at == run.log_pruned_at

      assert stopped.text ==
               "Set up the dev container failed with exit code 2. The step's output was deleted " <>
                 "under the " <>
                 "workspace's log retention, so the cause is no longer shown."
    end
  end

  test "a run of another workspace reads nothing", ctx do
    %{run: run} = handed_over_fixture(ctx.scope, ctx.key)
    run = project!(run, [step_started(1, 1, "setup", "setup"), step_exited(2, 1)])
    %{scope: other} = sign_up_fixture()

    assert %{machine: nil, steps: [], stopped: nil} = Preparation.read(other, run)
  end

  describe "the machine's end" do
    test "is nil before the starter's first report, and the last report after", ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)

      assert %{machine: %{end: nil, handed_over_at: handed_over_at, ended_at: nil}} =
               Preparation.read(ctx.scope, run)

      assert handed_over_at == dispatch.handed_over_at

      :ok = Dispatches.report_machine_end(ctx.key, dispatch.public_id, %{state: :deleting})
      at = Repo.get!(Dispatch, dispatch.id).machine_end_at

      assert %{machine: %{end: %{state: :deleting, at: ^at}}} = Preparation.read(ctx.scope, run)

      :ok = Dispatches.report_machine_end(ctx.key, dispatch.public_id, %{state: :gone})
      assert %{machine: %{end: %{state: :gone}}} = Preparation.read(ctx.scope, run)
    end

    test "ended_at is the dispatch's end, else the run's end once the run ended", ctx do
      %{run: run, dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      exited = DateTime.add(DateTime.utc_now(), -120, :second)
      run = run |> Ecto.Changeset.change(state: "failed", exited_at: exited) |> Repo.update!()

      assert %{machine: %{ended_at: ^exited}} = Preparation.read(ctx.scope, run)

      ended = DateTime.add(DateTime.utc_now(), -60, :second)
      change_dispatch!(dispatch, ended_at: ended, end_cause: :run_ended)
      assert %{machine: %{ended_at: ^ended}} = Preparation.read(ctx.scope, run)
    end

    test "a dispatch released before its handover has no handover", ctx do
      %{dispatch: dispatch, registered: registered} = claimed!(ctx)
      :ok = Dispatches.release(ctx.key, dispatch.public_id, %{reason: "No capacity."})
      run = Repo.get!(Run, registered.id)

      assert %{machine: %{handed_over_at: nil, end: nil, ended_at: %DateTime{}}} =
               Preparation.read(ctx.scope, run)
    end
  end

  describe "the queue, the session's end, what the run pushed and why the machine went" do
    test "queued_at is when the run of the queue was queued", ctx do
      %{run: run, dispatch_run: dispatch_run} = handed_over_fixture(ctx.scope, ctx.key)
      queued_at = Repo.get!(Apiary.Dispatches.DispatchRun, dispatch_run.id).queued_at

      assert %{machine: %{queued_at: ^queued_at}} = Preparation.read(ctx.scope, run)
      assert %DateTime{} = queued_at
    end

    test "session_end has the last result, the exit and the model; nil before either", ctx do
      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.started", %{"session_id" => "session-0001", "model" => "model-large-1"}}
        ])

      assert %{session_end: nil} = Preparation.read(ctx.scope, run)

      run =
        project!(run, [
          {4, "runtime.result",
           %{"outcome" => "error", "turns" => 2, "duration_ms" => 1_000, "cost_usd" => 0.1}},
          {5, "runtime.result",
           %{"outcome" => "success", "turns" => 14, "duration_ms" => 229_000, "cost_usd" => 0.84}},
          {6, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
        ])

      assert %{
               session_end: %{
                 result_at: %DateTime{},
                 outcome: "success",
                 turns: 14,
                 duration_ms: 229_000,
                 cost_usd: 0.84,
                 exited_at: %DateTime{},
                 state: "succeeded",
                 reason: nil,
                 exit_code: 0,
                 model: "model-large-1"
               }
             } = Preparation.read(ctx.scope, run)
    end

    test "session_end has the exit's reason, as the contract's paused session has it", ctx do
      path = "test/fixtures/forager-contract/link/link-batch-session-exited-model-key-limit.json"
      assert path in Apiary.ContractFixtures.vendored()

      [%{"type" => "dev.qory.session.exited", "data" => exited}] =
        path |> File.read!() |> Jason.decode!()

      run =
        ctx.scope
        |> run_fixture()
        |> project!([
          {1, "run.started", started_data()},
          {2, "session.started", Map.put(session_started_data(), "session", exited["session"])},
          {3, "session.exited", exited}
        ])

      assert %{session_end: %{state: "paused", reason: "model_key_limit", exit_code: 1}} =
               Preparation.read(ctx.scope, run)
    end

    test "outputs are the versions the run pushed, not a person's", ctx do
      %{run: run, dispatch_run: dispatch_run} = handed_over_fixture(ctx.scope, ctx.key)
      dispatch_run = Repo.get!(Apiary.Dispatches.DispatchRun, dispatch_run.id)
      work_item = fn -> Repo.get!(Apiary.WorkItems.WorkItem, dispatch_run.work_item_id) end

      file = fn text ->
        %{filename: "proposal.md", content_type: "text/markdown", binary: text}
      end

      assert %{outputs: []} = Preparation.read(ctx.scope, run)

      {:ok, _person} =
        Apiary.Artifacts.push({:person, ctx.scope}, work_item.(), "proposal", [file.("one\n")])

      {:ok, version} =
        Apiary.Artifacts.push({:run, dispatch_run}, work_item.(), "proposal", [file.("two\n")],
          name: "main"
        )

      assert %{
               outputs: [
                 %{type: "proposal", name: "main", number: 2, at: at, public_id: public_id}
               ]
             } = Preparation.read(ctx.scope, run)

      assert at == version.inserted_at
      assert public_id == version.public_id
    end

    test "outputs are this run's alone, not another run's of the queue", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)
      %{dispatch_run: other} = handed_over_fixture(ctx.scope, ctx.key)
      other = Repo.get!(Apiary.Dispatches.DispatchRun, other.id)
      work_item = Repo.get!(Apiary.WorkItems.WorkItem, other.work_item_id)
      file = %{filename: "proposal.md", content_type: "text/markdown", binary: "other\n"}

      {:ok, _version} =
        Apiary.Artifacts.push({:run, other}, work_item, "proposal", [file], name: "main")

      assert %{outputs: []} = Preparation.read(ctx.scope, run)
    end

    test "outputs read through another workspace of the organisation are none", ctx do
      %{run: run, dispatch_run: dispatch_run} = handed_over_fixture(ctx.scope, ctx.key)
      dispatch_run = Repo.get!(Apiary.Dispatches.DispatchRun, dispatch_run.id)
      work_item = Repo.get!(Apiary.WorkItems.WorkItem, dispatch_run.work_item_id)
      file = %{filename: "proposal.md", content_type: "text/markdown", binary: "plan\n"}

      {:ok, _version} =
        Apiary.Artifacts.push({:run, dispatch_run}, work_item, "proposal", [file], name: "main")

      assert %{outputs: [_version]} = Preparation.read(ctx.scope, run)

      workspace = workspace_fixture(ctx.scope.organisation)
      other = workspace_scope(ctx.scope.user, workspace)
      assert %{outputs: []} = Preparation.read(other, run)
    end

    test "queued_at after a release is when the released dispatch ended", ctx do
      %{dispatch: first, registered: released_run} = claimed!(ctx)
      :ok = Dispatches.release(ctx.key, first.public_id, %{reason: "No capacity."})
      released = Repo.get!(Dispatch, first.id)
      queued = Repo.get!(Apiary.Dispatches.DispatchRun, first.dispatch_run_id).queued_at

      # The run of the queue waits again with the same `queued_at`, and is claimed again.
      {:ok, %{dispatch: second, registered: registered}} =
        Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      assert second.dispatch_run_id == first.dispatch_run_id
      assert DateTime.before?(queued, released.ended_at)

      ended_at = released.ended_at

      assert %{machine: %{queued_at: ^ended_at}} =
               Preparation.read(ctx.scope, Repo.get!(Run, registered.id))

      # The released attempt's run keeps the first queueing.
      assert %{machine: %{queued_at: ^queued}} =
               Preparation.read(ctx.scope, Repo.get!(Run, released_run.id))
    end

    test "queued_at after a lapsed lease is when the dispatch lapsed", ctx do
      %{dispatch: first} = claimed!(ctx)
      lapse!(first)
      queued = Repo.get!(Apiary.Dispatches.DispatchRun, first.dispatch_run_id).queued_at

      # The claim frees the lapsed lease, so the run of the queue waits again with the
      # same `queued_at`, and the claim takes it again and hands it over.
      dispatch_run = Repo.get!(Apiary.Dispatches.DispatchRun, first.dispatch_run_id)

      %{dispatch: second, run: registered} =
        Apiary.DispatchedRunsFixtures.handed_over(ctx.scope, ctx.key, dispatch_run, %{})

      assert second.dispatch_run_id == first.dispatch_run_id

      assert %Dispatch{ended_at: nil, stale_at: %DateTime{} = stale_at} =
               Repo.get!(Dispatch, first.id)

      assert DateTime.before?(queued, stale_at)

      assert %{machine: %{queued_at: ^stale_at}} =
               Preparation.read(ctx.scope, Repo.get!(Run, registered.id))

      # The run exits, and its run of the queue ends: the stale dispatch ends with it,
      # after this claim. Queued still starts when the lease lapsed.
      exited =
        registered.id
        |> then(&Repo.get!(Run, &1))
        |> Ecto.Changeset.change(exited_at: DateTime.utc_now())
        |> Repo.update!()

      Apiary.Dispatches.RunEnd.run_ended(exited)

      assert %Dispatch{ended_at: %DateTime{}, end_cause: :run_ended} =
               Repo.get!(Dispatch, first.id)

      assert %{machine: %{queued_at: ^stale_at}} =
               Preparation.read(ctx.scope, Repo.get!(Run, registered.id))
    end

    test "removal_cause: the run's loss, else its exit, else nil", ctx do
      %{run: run} = handed_over_fixture(ctx.scope, ctx.key)
      assert %{machine: %{removal_cause: nil}} = Preparation.read(ctx.scope, run)

      now = DateTime.utc_now()
      run = run |> Ecto.Changeset.change(state: "failed", exited_at: now) |> Repo.update!()
      assert %{machine: %{removal_cause: :run_ended}} = Preparation.read(ctx.scope, run)

      run = run |> Ecto.Changeset.change(state: "lost", lost_at: now) |> Repo.update!()
      assert %{machine: %{removal_cause: :keep_alive_lost}} = Preparation.read(ctx.scope, run)
    end
  end
end
