defmodule ApiaryWeb.RunLive.ShowAfterSessionTest do
  @moduledoc """
  The Outputs saved row of a run's Run list (`ApiaryWeb.PreparationComponents`): a push
  step's row, live on an open page, and a failed push that reads as no failed
  preparation.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures

  alias Apiary.Repo
  alias Apiary.Runs.{Projector, Step}

  @moduletag needs: :factory

  @push "push work to git.example.com/acme/web-shop"
  @output "To https://git.example.com/acme/web-shop.git\n"

  setup :register_and_log_in_user

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  # A run whose only session has exited, alive, with a preparation that has settled.
  defp session_over(scope, extra \\ []) do
    project!(
      run_fixture(scope),
      [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.started", %{"session_id" => "session-0001"}},
        {4, "runtime.notification", %{"kind" => "k", "message" => "working"}},
        {5, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
      ] ++ extra
    )
  end

  defp push_started(sequence, time \\ DateTime.utc_now()) do
    {sequence, "run.step_started", %{"step" => 1, "name" => @push, "kind" => "push"}, time: time}
  end

  defp push_exited(sequence, state, exit_code),
    do:
      {sequence, "run.step_exited",
       %{"step" => 1, "state" => state, "exit_code" => exit_code, "duration_ms" => 72_000}}

  defp open(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    lv
  end

  defp arrive!(lv, run, events) do
    project!(run, events)
    send(lv.pid, :flush)
    render(lv)
  end

  defp settled?(lv), do: :sys.get_state(lv.pid).socket.assigns.preparation_settled

  # The reader is at the end of the page, so a new item joins the window. Else the window
  # stops short of the run's end, and the section waits.
  defp at_end(lv),
    do: render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

  test "a page open on a live run shows the section, a running row, then its end", ctx do
    run = session_over(ctx.scope)
    lv = open(ctx.conn, ctx.scope, run)

    refute has_element?(lv, "#prepare-machine-outputs")
    assert settled?(lv)

    arrive!(lv, run, [push_started(6)])

    assert lv |> element("#prepare-machine-outputs > summary") |> render() =~ "Outputs saved"
    assert has_element?(lv, "#prepare-machine-outputs #prepare-machine-step-1")
    assert has_element?(lv, "#prepare-machine-step-1[data-state='running']")
    row = lv |> element("#prepare-machine-step-1 summary") |> render()
    assert row =~ "Running"
    assert row =~ "q-prep-pulse"
    assert row =~ "Push work to git.example.com/acme/web-shop"
    assert has_element?(lv, "#prepare-machine-step-1-clock[data-tick='duration']")

    arrive!(lv, run, [
      {7, "run.log", step_log_data(1, @output)},
      push_exited(8, "succeeded", 0)
    ])

    assert has_element?(lv, "#prepare-machine-step-1[data-state='succeeded']")
    row = lv |> element("#prepare-machine-step-1 summary") |> render()
    assert row =~ "1 m 12 s"
    refute row =~ "Running"
    refute has_element?(lv, "#prepare-machine-step-1-clock")
    assert lv |> element("#prepare-machine-step-1-output") |> render() =~ @output |> String.trim()
    refute has_element?(lv, "#prepare-machine-step-1[open]")
  end

  test "a failed push has no cause line, and a run that goes on no Machine removed", ctx do
    run = session_over(ctx.scope, [push_started(6), push_exited(7, "failed", 1)])
    lv = open(ctx.conn, ctx.scope, run)

    assert has_element?(lv, "#prepare-machine-outputs-failed .q-prep-steps > li", "Push work")
    refute has_element?(lv, "#prepare-machine-outputs-failed .q-prep-cause")
    refute has_element?(lv, "#prepare-machine [data-clean-up]")
  end

  test "Outputs saved follows Session started, and has no place on another tab", ctx do
    run = session_over(ctx.scope, [push_started(6), push_exited(7, "succeeded", 0)])
    lv = open(ctx.conn, ctx.scope, run)
    html = render(lv)

    assert has_element?(lv, "#prepare-machine-session #timeline")

    assert [_before, after_session] =
             String.split(html, ~s(id="prepare-machine-session"), parts: 2)

    assert after_session =~ ~s(id="prepare-machine-outputs")

    {:ok, lv, _html} =
      live(
        ctx.conn,
        ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}/network"
      )

    refute has_element?(lv, "#prepare-machine-outputs")
  end

  test "a failed push is open with its output, and nothing reads as a failed preparation",
       ctx do
    run = run_fixture(ctx.scope)

    run =
      project!(run, [
        {1, "run.started", started_data()},
        {2, "run.step_started",
         %{"step" => 1, "name" => "fetch git.example.com/acme/web-shop", "kind" => "fetch"}},
        {3, "run.step_exited",
         %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
        {4, "session.started", session_started_data()},
        {5, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}},
        {6, "run.step_started", %{"step" => 2, "name" => @push, "kind" => "push"}},
        {7, "run.log", step_log_data(2, "rejected: the branch moved\n")},
        {8, "run.step_exited",
         %{"step" => 2, "state" => "failed", "exit_code" => 1, "duration_ms" => 100}},
        {9, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
      ])

    lv = open(ctx.conn, ctx.scope, run)

    assert has_element?(
             lv,
             "#prepare-machine-outputs-failed[open] #prepare-machine-step-2-failed[open]"
           )

    assert lv |> element("#prepare-machine-step-2-failed-output") |> render() =~
             "rejected: the branch moved"

    refute has_element?(lv, "#prepare-machine-step-2")
    refute has_element?(lv, ".q-prep-cause")

    html = render(lv)
    refute html =~ "The run stopped before its session started"
    refute html =~ "failed with exit code"
    refute html =~ "reads the cause in the step"
  end

  test "a failed setup step before the session still is a failed preparation", ctx do
    run =
      ctx.scope
      |> run_fixture()
      |> project!([
        {1, "run.started", started_data()},
        {2, "run.step_started", %{"step" => 1, "name" => "set up", "kind" => "setup"}},
        {3, "run.step_exited",
         %{"step" => 1, "state" => "failed", "exit_code" => 2, "duration_ms" => 100}},
        {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
      ])

    lv = open(ctx.conn, ctx.scope, run)

    refute has_element?(lv, "#prepare-machine-outputs")
    assert has_element?(lv, "#prepare-machine-cause")
    assert lv |> element(".q-limits") |> render() =~ "stopped before its session started"
  end

  describe "How it ended" do
    defp failed_push(from) do
      [
        {from, "run.step_started", %{"step" => 1, "name" => @push, "kind" => "push"}},
        {from + 1, "run.step_exited",
         %{"step" => 1, "state" => "failed", "exit_code" => 1, "duration_ms" => 100}}
      ]
    end

    defp failed_exit(sequence),
      do:
        {sequence, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}

    defp session_started do
      [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.started", %{"session_id" => "session-0001"}}
      ]
    end

    # A session whose last item, at sequence 4, is the event given, and which exited 0.
    defp session_ended(type, data) do
      session_started() ++
        [
          {4, type, data},
          {5, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
        ]
    end

    # A session in which a tool failed and which ended with a success, through sequence 7.
    defp failed_tool_then_success do
      tool = %{"tool" => "Bash", "tool_use_id" => "tool-1"}

      session_started() ++
        [
          {4, "runtime.tool_started", Map.put(tool, "input", %{"command" => "make"})},
          {5, "runtime.tool_failed", Map.put(tool, "error", "exit status 1")},
          {6, "runtime.result", %{"outcome" => "success", "result" => "done"}},
          {7, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
        ]
    end

    test "a failed tool, a success, then a failed push: no line", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          failed_tool_then_success() ++ failed_push(8) ++ [failed_exit(10)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      refute has_element?(lv, "#run-why")
    end

    test "a failed turn, a success, then a failed push: no line", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          session_started() ++
            [
              {4, "runtime.turn_failed", %{"error" => "rate_limit", "agent_id" => "agent-1"}},
              {5, "runtime.result", %{"outcome" => "success", "result" => "done"}},
              {6, "session.exited", %{"session" => 1, "state" => "succeeded", "exit_code" => 0}}
            ] ++ failed_push(7) ++ [failed_exit(9)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      refute has_element?(lv, "#run-why")
    end

    test "an earlier session's failed result, a success, then a failed push: no line", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          session_ended("runtime.result", %{"outcome" => "error", "result" => "the tests fail"}) ++
            [
              {6, "session.started", session_started_data(%{"session" => 2})},
              {7, "runtime.result", %{"outcome" => "success", "result" => "done"}},
              {8, "session.exited", %{"session" => 2, "state" => "succeeded", "exit_code" => 0}}
            ] ++ failed_push(9) ++ [failed_exit(11)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      refute has_element?(lv, "#run-why")
    end

    test "a failed newest result, then a failed push, shows it", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          session_ended("runtime.result", %{
            "outcome" => "error",
            "result" => "the tests still fail"
          }) ++ failed_push(6) ++ [failed_exit(8)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-why", "the tests still fail")
    end

    test "a failed newest turn, then a failed push, shows it", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          session_ended("runtime.turn_failed", %{"error" => "the turn stopped"}) ++
            failed_push(6) ++ [failed_exit(8)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-why", "the turn stopped")
    end

    test "a failed turn, a success, and no failed push still shows the turn", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          session_started() ++
            [
              {4, "runtime.turn_failed", %{"error" => "rate_limit", "agent_id" => "agent-1"}},
              {5, "runtime.result", %{"outcome" => "success", "result" => "done"}},
              failed_exit(6)
            ]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-why", "rate_limit")
    end

    test "a failed tool with no push step still shows its ending", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          failed_tool_then_success() ++ [failed_exit(8)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-why", "Bash failed")
    end

    test "a failed tool with a push that succeeded still shows its ending", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          failed_tool_then_success() ++
            [
              {8, "run.step_started", %{"step" => 1, "name" => @push, "kind" => "push"}},
              {9, "run.step_exited",
               %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
              failed_exit(10)
            ]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-why", "Bash failed")
    end

    test "on a live page, the run's exit in a later flush than the step's exit: no line",
         ctx do
      run = project!(run_fixture(ctx.scope), failed_tool_then_success())
      lv = open(ctx.conn, ctx.scope, run)
      at_end(lv)
      assert settled?(lv)

      arrive!(lv, run, failed_push(8))
      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      refute has_element?(lv, "#run-why")

      arrive!(lv, run, [failed_exit(10)])
      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      refute has_element?(lv, "#run-why")
    end

    test "on a live page, the step's exit and the run's exit in one flush: no line", ctx do
      run = project!(run_fixture(ctx.scope), failed_tool_then_success())
      lv = open(ctx.conn, ctx.scope, run)
      at_end(lv)

      arrive!(lv, run, failed_push(8) ++ [failed_exit(10)])

      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      refute has_element?(lv, "#run-why")
    end

    test "on a live page, a failed tool with no push step shows its ending at the exit", ctx do
      run = project!(run_fixture(ctx.scope), failed_tool_then_success())
      lv = open(ctx.conn, ctx.scope, run)
      at_end(lv)

      arrive!(lv, run, [failed_exit(8)])

      assert has_element?(lv, "#run-why", "Bash failed")
    end
  end

  test "a late event on a settled page reads the preparation again", ctx do
    # Sequence 6 is missing, and 7 is on the page: its arrival reaches below what the page
    # holds, so the flush has no rows to look at.
    run =
      session_over(ctx.scope, [{7, "runtime.notification", %{"kind" => "k", "message" => "m"}}])

    lv = open(ctx.conn, ctx.scope, run)
    at_end(lv)
    assert settled?(lv)

    arrive!(lv, run, [push_started(6)])

    assert has_element?(lv, "#prepare-machine-step-1[data-state='running']")
  end

  # The test reads the page as the server sends it, so it shows the new `id` and `open`.
  # That a browser's `details` opens needs a browser: `row/1` keeps the `open` of a row
  # that has mounted.
  test "a push that fails on an open page gets a new row, open; a success keeps the row",
       ctx do
    run = session_over(ctx.scope, [push_started(6)])
    lv = open(ctx.conn, ctx.scope, run)
    assert has_element?(lv, "#prepare-machine-step-1:not([open])")

    arrive!(lv, run, [push_exited(7, "failed", 1)])

    refute has_element?(lv, "#prepare-machine-step-1")
    assert has_element?(lv, "#prepare-machine-step-1-failed[open][phx-mounted]")

    other = session_over(ctx.scope, [push_started(6)])
    lv = open(ctx.conn, ctx.scope, other)

    arrive!(lv, other, [push_exited(7, "succeeded", 0)])

    assert has_element?(lv, "#prepare-machine-step-1:not([open])")
  end

  test "a Prepare row keeps its id when its step fails", ctx do
    run =
      ctx.scope
      |> run_fixture()
      |> project!([
        {1, "run.started", started_data()},
        {2, "run.step_started", %{"step" => 1, "name" => "set up", "kind" => "setup"}}
      ])

    lv = open(ctx.conn, ctx.scope, run)

    arrive!(lv, run, [
      {3, "run.step_exited",
       %{"step" => 1, "state" => "failed", "exit_code" => 2, "duration_ms" => 100}}
    ])

    assert has_element?(lv, "#prepare-machine-step-1[data-state='failed']")
  end

  test "a run's exit cancels an open push step on the page", ctx do
    run = session_over(ctx.scope, [push_started(6)])
    lv = open(ctx.conn, ctx.scope, run)
    at_end(lv)

    assert has_element?(lv, "#prepare-machine-step-1[data-state='running']")

    arrive!(lv, run, [
      {7, "run.exited", %{"state" => "cancelled", "reason" => "stopped", "exit_code" => -1}}
    ])

    assert has_element?(lv, "#prepare-machine-step-1[data-state='cancelled']")
    refute lv |> element("#prepare-machine-step-1 summary") |> render() =~ "Running"
    refute has_element?(lv, "#prepare-machine-outputs time[data-tick]")
  end

  test "a reader without `run.read_log` sees the row and no output", ctx do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoLog)

    run =
      session_over(ctx.scope, [
        push_started(6),
        {7, "run.log", step_log_data(1, @output)},
        push_exited(8, "failed", 1)
      ])

    lv = open(ctx.conn, ctx.scope, run)

    assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
    refute has_element?(lv, "#prepare-machine-step-1-failed-output")
    refute render(lv) =~ "web-shop.git"
  end

  test "another flush of a live session does not read the preparation again", ctx do
    run = session_over(ctx.scope)
    lv = open(ctx.conn, ctx.scope, run)
    at_end(lv)
    assert settled?(lv)

    # A row no event announced: a read would show it.
    Repo.insert!(%Step{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      step: 1,
      name: @push,
      kind: "push"
    })

    arrive!(lv, run, [{6, "runtime.notification", %{"kind" => "k", "message" => "still"}}])
    refute has_element?(lv, "#prepare-machine-step-1")

    arrive!(lv, run, [push_exited(7, "succeeded", 0)])
    assert has_element?(lv, "#prepare-machine-step-1[data-state='succeeded']")
  end

  test "a later session's join shows after Session started with no reload", ctx do
    run = session_over(ctx.scope)
    lv = open(ctx.conn, ctx.scope, run)

    arrive!(lv, run, [
      {6, "run.step_started", %{"step" => 1, "name" => "join session 2", "kind" => "join"}}
    ])

    assert has_element?(lv, "#prepare-machine-step-1[data-state='running']")
    refute has_element?(lv, "#prepare-machine-prepare")
    refute has_element?(lv, "#prepare-machine-outputs")
  end

  test "Outputs saved shows while the window stops short of the run's end", ctx do
    notes = for n <- 6..320, do: {n, "runtime.notification", %{"kind" => "k", "message" => "m"}}

    run =
      session_over(
        ctx.scope,
        notes ++ [push_started(321), push_exited(322, "succeeded", 0)]
      )

    lv = open(ctx.conn, ctx.scope, run)

    assert has_element?(lv, "#timeline-later")
    assert has_element?(lv, "#prepare-machine-outputs #prepare-machine-step-1")
  end

  test "Outputs saved stays while new events wait for a reader not at the end", ctx do
    run = session_over(ctx.scope, [push_started(6)])
    lv = open(ctx.conn, ctx.scope, run)
    assert has_element?(lv, "#prepare-machine-outputs")

    arrive!(lv, run, [{7, "runtime.notification", %{"kind" => "k", "message" => "late"}}])
    assert has_element?(lv, "#new-events")
    assert has_element?(lv, "#prepare-machine-outputs")
  end
end
