defmodule ApiaryWeb.RunLive.ShowAfterSessionTest do
  @moduledoc """
  The Save the outputs row of an Agent session in a run's Run list
  (`ApiaryWeb.PreparationComponents`): a push step's row, live on an open page, and a
  failed push that reads as no failed preparation; each agent session's Agent session
  with its Run the agent and its Timeline, and the copy of the work, which has no row.
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

    refute has_element?(lv, "#prepare-machine-session-outputs")
    assert settled?(lv)

    arrive!(lv, run, [push_started(6)])

    assert lv |> element("#prepare-machine-session-outputs > summary") |> render() =~
             "Save the outputs"

    assert has_element?(
             lv,
             "#prepare-machine-session #prepare-machine-session-outputs #prepare-machine-step-1"
           )

    assert has_element?(lv, "#prepare-machine-step-1[data-state='running']")
    row = lv |> element("#prepare-machine-step-1 summary") |> render()
    assert row =~ "Running"
    assert row =~ "q-prep-pulse"
    assert row =~ "Push work to git.example.com/acme/web-shop"
    # A step inside a step shows no time: the clock is its Agent session's.
    refute has_element?(lv, "#prepare-machine-step-1-clock")
    assert has_element?(lv, "#prepare-machine-session-clock[data-tick='duration']")

    arrive!(lv, run, [
      {7, "run.log", step_log_data(1, @output)},
      push_exited(8, "succeeded", 0)
    ])

    assert has_element?(lv, "#prepare-machine-step-1[data-state='succeeded']")
    row = lv |> element("#prepare-machine-step-1 summary") |> render()
    refute row =~ "Running"
    refute has_element?(lv, "#prepare-machine-session-clock")
    assert lv |> element("#prepare-machine-step-1-output") |> render() =~ @output |> String.trim()
    refute has_element?(lv, "#prepare-machine-step-1[open]")
  end

  test "a failed push has no cause line, and a run that goes on no Remove the machine", ctx do
    run = session_over(ctx.scope, [push_started(6), push_exited(7, "failed", 1)])
    lv = open(ctx.conn, ctx.scope, run)

    assert has_element?(
             lv,
             "#prepare-machine-session-outputs-failed .q-prep-steps > li",
             "Push work"
           )

    refute has_element?(lv, "#prepare-machine-session-outputs-failed .q-prep-cause")
    refute has_element?(lv, "#prepare-machine [data-clean-up]")
    refute has_element?(lv, "#prepare-machine-remove")
  end

  test "Save the outputs follows Run the agent in its Agent session, and has no place on another tab",
       ctx do
    run = session_over(ctx.scope, [push_started(6), push_exited(7, "succeeded", 0)])
    lv = open(ctx.conn, ctx.scope, run)
    html = render(lv)

    assert has_element?(lv, "#prepare-machine-session #prepare-machine-session-agent #timeline")

    assert [_before, after_agent] =
             String.split(html, ~s(id="prepare-machine-session-agent"), parts: 2)

    assert after_agent =~ ~s(id="prepare-machine-session-outputs")

    {:ok, lv, _html} =
      live(
        ctx.conn,
        ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}/network"
      )

    refute has_element?(lv, "#prepare-machine-session-outputs")
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
             "#prepare-machine-session-outputs-failed[open] #prepare-machine-step-2-failed[open]"
           )

    assert lv |> element("#prepare-machine-step-2-failed-output") |> render() =~
             "rejected: the branch moved"

    refute has_element?(lv, "#prepare-machine-step-2")
    refute has_element?(lv, ".q-prep-cause")

    # The push's cause line is the header's ending alone, not a row's.
    main = lv |> element("main") |> render() |> LazyHTML.from_fragment()
    assert main |> LazyHTML.query("#run-why") |> LazyHTML.text() =~ "failed with exit code 1"

    refute main |> LazyHTML.query("#prepare-machine") |> LazyHTML.text() =~
             "failed with exit code"
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

    refute has_element?(lv, "#prepare-machine-session-outputs")
    assert has_element?(lv, "#prepare-machine-cause")
    refute has_element?(lv, ".q-limits")
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

    # What happened at the failed push, whole, with no advice and no link: the step has no
    # item.
    defp assert_push_line(lv) do
      assert lv |> element("#run-why .q-run-why-whole") |> render() =~
               ">Push work to git.example.com/acme/web-shop failed with exit code 1.</span>"

      refute has_element?(lv, "#run-why-jump")
      refute has_element?(lv, "#run-why [title]")
    end

    test "a success, then a failed copy of the work: the copy's line, and no row of it", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          session_ended("runtime.result", %{"outcome" => "success", "result" => "done"}) ++
            [
              {6, "run.step_started",
               %{"step" => 1, "name" => "copy the work back", "kind" => "copy"}},
              {7, "run.step_exited",
               %{"step" => 1, "state" => "failed", "exit_code" => 128, "duration_ms" => 100}},
              failed_exit(8)
            ]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert lv
             |> element("#run-why .q-run-why-whole")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text() == "The run's work did not come back from the machine."

      refute has_element?(lv, "#prepare-machine-step-1")
      refute has_element?(lv, "#prepare-machine-step-1-failed")
      refute render(lv) =~ ~r/copy the work back/i
    end

    test "a failed tool, a success, then a failed push: the push's line", ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          failed_tool_then_success() ++ failed_push(8) ++ [failed_exit(10)]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      assert_push_line(lv)
    end

    test "a failed turn, a success, then a failed push: the push's line", ctx do
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
      assert_push_line(lv)
    end

    test "an earlier session's failed result, a success, then a failed push: the push's line",
         ctx do
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
      assert_push_line(lv)
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

    test "on a live page, the run's exit in a later flush than the step's: then the push's line",
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
      assert_push_line(lv)
    end

    test "on a live page, the step's exit and the run's exit in one flush: the push's line",
         ctx do
      run = project!(run_fixture(ctx.scope), failed_tool_then_success())
      lv = open(ctx.conn, ctx.scope, run)
      at_end(lv)

      arrive!(lv, run, failed_push(8) ++ [failed_exit(10)])

      assert has_element?(lv, "#prepare-machine-step-1-failed[data-state='failed']")
      assert_push_line(lv)
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
    assert has_element?(lv, "#prepare-machine-step-1[open][data-state='running']")

    arrive!(lv, run, [push_exited(7, "failed", 1)])

    refute has_element?(lv, "#prepare-machine-step-1")
    refute has_element?(lv, "#prepare-machine-session-outputs")
    assert has_element?(lv, "#prepare-machine-session-outputs-failed[open][phx-mounted]")
    assert has_element?(lv, "#prepare-machine-step-1-failed[open][phx-mounted]")

    other = session_over(ctx.scope, [push_started(6)])
    lv = open(ctx.conn, ctx.scope, other)

    arrive!(lv, other, [push_exited(7, "succeeded", 0)])

    assert has_element?(lv, "#prepare-machine-step-1:not([open])")
  end

  test "a step of Prepare the machine keeps its id when it fails", ctx do
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
    refute has_element?(lv, "#prepare-machine-session-clock")
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

  test "a later session's join shows in Agent session 2 with no reload", ctx do
    run = session_over(ctx.scope)
    lv = open(ctx.conn, ctx.scope, run)

    arrive!(lv, run, [
      {6, "run.step_started", %{"step" => 1, "name" => "join session 2", "kind" => "join"}}
    ])

    assert has_element?(
             lv,
             "#prepare-machine-session-2 #prepare-machine-session-2-prepare #prepare-machine-step-1[data-state='running']"
           )

    refute has_element?(lv, "#prepare-machine-session-2-agent")
    refute has_element?(lv, "#prepare-machine-prepare")
    refute has_element?(lv, "#prepare-machine-session-outputs")
  end

  describe "agent sessions and the copy of the work" do
    defp step(sequence, step, name, kind),
      do: {sequence, "run.step_started", %{"step" => step, "name" => name, "kind" => kind}}

    defp step_end(sequence, step, state \\ "succeeded", exit_code \\ 0),
      do:
        {sequence, "run.step_exited",
         %{"step" => step, "state" => state, "exit_code" => exit_code, "duration_ms" => 1000}}

    defp exit(sequence, session),
      do:
        {sequence, "session.exited",
         %{"session" => session, "state" => "succeeded", "exit_code" => 0}}

    # Session 1 from 2 to 5, session 2's join from 6 to 7 and its session from 8 to 11.
    defp two_sessions do
      [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.started", %{"session" => 1, "session_id" => "session-0001"}},
        {4, "runtime.result", %{"session" => 1, "outcome" => "success", "result" => "one"}},
        exit(5, 1),
        step(6, 1, "join session 2", "join"),
        step_end(7, 1),
        {8, "session.started", session_started_data(%{"session" => 2})},
        {9, "runtime.started", %{"session" => 2, "session_id" => "session-0002"}},
        {10, "runtime.result", %{"session" => 2, "outcome" => "success", "result" => "two"}},
        exit(11, 2)
      ]
    end

    # The copy, step 2 from 12, around the bare session 3: its join, start and wall.
    defp copy_begun do
      [
        step(12, 2, "copy the work back", "copy"),
        step(13, 3, "join session 3", "join"),
        step_end(14, 3),
        {15, "session.started", %{"session" => 3, "bare" => true, "runtime" => "git"}},
        step(16, 4, "start the wall", "wall")
      ]
    end

    test "each agent session is an Agent session with its Run the agent and Timeline; the copy and the bare session have no row",
         ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          two_sessions() ++
            copy_begun() ++
            [
              step_end(17, 4),
              exit(18, 3),
              step_end(19, 2),
              {20, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
            ]
        )

      lv = open(ctx.conn, ctx.scope, run)

      section = lv |> element("#prepare-machine") |> render() |> LazyHTML.from_fragment()

      ids =
        section
        |> LazyHTML.query("#prepare-machine > ol > li > [id]")
        |> LazyHTML.attribute("id")

      assert ids == ["prepare-machine-session", "prepare-machine-session-2"]

      names =
        section
        |> LazyHTML.query("#prepare-machine > ol > li > details > summary .q-prep-name")
        |> Enum.map(&LazyHTML.text/1)

      assert names == ["Agent session 1", "Agent session 2"]

      assert has_element?(lv, "#prepare-machine-session #prepare-machine-session-agent #timeline")

      assert has_element?(
               lv,
               "#prepare-machine-session-2 #prepare-machine-session-2-agent #timeline-2"
             )

      # Session 2's join is in its Prepare the session.
      assert has_element?(
               lv,
               "#prepare-machine-session-2-prepare #prepare-machine-step-1",
               "Start the agent"
             )

      refute has_element?(lv, "#prepare-machine-session-3")
      refute has_element?(lv, "#prepare-machine-step-2")
      refute has_element?(lv, "#prepare-machine-step-3")
      refute has_element?(lv, "#prepare-machine-step-4")
      refute render(lv) =~ "Copy the work back"
    end

    defp texts(sequence, session, prompt, answer) do
      [
        {sequence, "runtime.text", %{"session" => session, "role" => "user", "text" => prompt}},
        {sequence + 1, "runtime.text",
         %{"session" => session, "role" => "assistant", "text" => answer}}
      ]
    end

    # Session 1 from 2 to 9, session 2 from 12 to 19; the run ends at 20.
    defp two_timelines do
      [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.started", %{"session" => 1, "session_id" => "session-0001"}}
      ] ++
        texts(4, 1, "Map the checkout", "The checkout has four steps.") ++
        [
          {6, "runtime.result", %{"session" => 1, "outcome" => "success", "result" => "one"}},
          # Forager's line with no `session`, from an older version: it goes by its place.
          {7, "runtime.notification", %{"kind" => "idle"}},
          {8, "runtime.ended", %{"session" => 1, "reason" => "other"}},
          exit(9, 1),
          step(10, 1, "join session 2", "join"),
          step_end(11, 1),
          {12, "session.started", session_started_data(%{"session" => 2})},
          {13, "runtime.started", %{"session" => 2, "session_id" => "session-0002"}}
        ] ++
        texts(14, 2, "Add a test", "The storefront has a test.") ++
        [
          {16, "runtime.result", %{"session" => 2, "outcome" => "success", "result" => "two"}},
          {17, "runtime.notification", %{"kind" => "idle"}},
          {18, "runtime.ended", %{"session" => 2, "reason" => "other"}},
          exit(19, 2),
          {20, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ]
    end

    defp listed(lv, id) do
      lv
      |> element("##{id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{id} > li")
      |> LazyHTML.attribute("id")
    end

    test "each Run the agent has the Timeline of its session, with its Main session",
         ctx do
      run = project!(run_fixture(ctx.scope), two_timelines())
      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-session-agent #timeline")
      assert has_element?(lv, "#prepare-machine-session-2-agent #timeline-2")

      assert listed(lv, "timeline") == ~w(e-1 e-3 e-4 main-session e-5 e-6 e-7 e-8)

      assert listed(lv, "timeline-2") ==
               ~w(e-13 e-14 main-session-2 e-15 e-16 e-17 e-18 e-20)

      assert lv |> element("#main-session") |> render() =~ "The checkout has four steps."
      assert lv |> element("#main-session-2") |> render() =~ "The storefront has a test."
    end

    test "?seq= of a later session's item opens its Agent session and Run the agent alone",
         ctx do
      run = project!(run_fixture(ctx.scope), two_timelines())

      {:ok, lv, _html} =
        live(
          ctx.conn,
          ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}?seq=15"
        )

      assert has_element?(
               lv,
               "#prepare-machine-session-2[open] #prepare-machine-session-2-agent[open]"
             )

      refute has_element?(lv, "#prepare-machine-session[open]")
      refute has_element?(lv, "#prepare-machine-session-agent[open]")
      assert has_element?(lv, "#timeline-2[data-target='e-15']")
      refute has_element?(lv, "#timeline[data-target]")
    end

    test "a live item of a later session arrives in its Timeline", ctx do
      events = two_timelines()
      run = project!(run_fixture(ctx.scope), Enum.take(events, 10))
      lv = open(ctx.conn, ctx.scope, run)
      at_end(lv)
      refute has_element?(lv, "#timeline-2")

      arrive!(lv, run, events |> Enum.drop(10) |> Enum.take(4))

      assert listed(lv, "timeline") == ~w(e-1 e-3 e-4 main-session e-5 e-6 e-7 e-8)
      assert listed(lv, "timeline-2") == ~w(e-13 e-14 main-session-2)
    end

    test "a later session's start shows its Run the agent with no reload", ctx do
      run = project!(run_fixture(ctx.scope), Enum.take(two_sessions(), 7))
      lv = open(ctx.conn, ctx.scope, run)
      at_end(lv)
      assert settled?(lv)
      # Session 2's join ran: Agent session 2 has it, and no Run the agent yet.
      assert has_element?(lv, "#prepare-machine-session-2 #prepare-machine-step-1")
      refute has_element?(lv, "#prepare-machine-session-2-agent")

      arrive!(lv, run, [{8, "session.started", session_started_data(%{"session" => 2})}])

      assert has_element?(
               lv,
               "#prepare-machine-session-2[open][data-state='running'] #prepare-machine-session-2-agent[open][data-state='running']"
             )

      assert has_element?(lv, "#prepare-machine-session-agent[data-state='succeeded']")
    end

    # Session 1 from 2 to 9, as in `two_timelines/0`; session 2 from 12, its events from
    # 13 on.
    defp session_two(rest) do
      Enum.take(two_timelines(), 11) ++
        [
          {12, "session.started", session_started_data(%{"session" => 2})},
          {13, "runtime.started", %{"session" => 2, "session_id" => "session-0002"}}
        ] ++ rest
    end

    defp page(ctx, run, query \\ "") do
      path = ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(ctx.conn, path <> query)
      lv
    end

    test "Connections inline puts an allowed connection at its place in a later session",
         ctx do
      [prompt, answer] = texts(14, 2, "Add a test", "The storefront has a test.")

      run =
        project!(
          run_fixture(ctx.scope),
          session_two([
            prompt,
            {15, "run.egress", egress_data()},
            put_elem(answer, 0, 16),
            {17, "runtime.result", %{"session" => 2, "outcome" => "success", "result" => "two"}},
            exit(18, 2),
            {19, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
          ])
        )

      lv = page(ctx, run)
      assert listed(lv, "timeline-2") == ~w(e-13 e-14 main-session-2 e-16 e-17 e-19)

      render_patch(
        lv,
        ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{run.number}?cx=1"
      )

      assert listed(lv, "timeline") == ~w(e-1 e-3 e-4 main-session e-5 e-6 e-7 e-8)
      assert listed(lv, "timeline-2") == ~w(e-13 e-14 main-session-2 e-15 e-16 e-17 e-19)
    end

    test "a subagent that opens in a later session puts its items under its start", ctx do
      a1 = %{"session" => 2, "agent_id" => "agent-a1", "agent_type" => "Explore"}

      run =
        project!(
          run_fixture(ctx.scope),
          session_two(
            texts(14, 2, "Add a test", "Look for the tests.") ++
              [
                {16, "runtime.subagent_started", a1},
                {17, "runtime.text", Map.merge(a1, %{"role" => "assistant", "text" => "Found."})},
                {18, "runtime.subagent_finished", Map.put(a1, "message", "Found.")},
                {19, "runtime.result",
                 %{"session" => 2, "outcome" => "success", "result" => "two"}},
                exit(20, 2),
                {21, "run.exited",
                 %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
              ]
          )
        )

      lv = page(ctx, run)
      assert listed(lv, "timeline-2") == ~w(e-13 e-14 main-session-2 e-15 e-16 e-19 e-21)

      lv |> element("#e-16 .q-sub-caret") |> render_click()

      assert listed(lv, "timeline") == ~w(e-1 e-3 e-4 main-session e-5 e-6 e-7 e-8)

      assert listed(lv, "timeline-2") ==
               ~w(e-13 e-14 main-session-2 e-15 e-16 e-17 e-18 e-19 e-21)
    end

    test "a live call of a later session that fails takes its place in that session", ctx do
      call = %{"session" => 2, "tool" => "Bash", "tool_use_id" => "tool-1"}

      events =
        session_two([
          {14, "runtime.text", %{"session" => 2, "role" => "user", "text" => "Add a test"}},
          {15, "runtime.tool_started", Map.put(call, "input", %{"command" => "make test"})},
          {16, "runtime.text",
           %{"session" => 2, "role" => "assistant", "text" => "The tests run."}}
        ])

      run = project!(run_fixture(ctx.scope), events)
      lv = page(ctx, run)
      assert listed(lv, "timeline-2") == ~w(e-13 e-14 main-session-2 e-16)

      arrive!(lv, run, [{17, "runtime.tool_failed", Map.put(call, "error", "exit status 2")}])

      assert listed(lv, "timeline") == ~w(e-1 e-3 e-4 main-session e-5 e-6 e-7 e-8)
      assert listed(lv, "timeline-2") == ~w(e-13 e-14 main-session-2 e-15 e-16)
    end

    test "Load earlier and Load newer keep each session's list to the window", ctx do
      notes = fn range, extra ->
        for n <- range,
            do: {n, "runtime.notification", Map.merge(%{"kind" => "k", "message" => "m"}, extra)}
      end

      # Session 1's rows are e-1, e-3 and e-4 to e-298; session 2's join runs from 299 to
      # 300, so the Run list is drawn, and session 2 starts at 301.
      run =
        project!(
          run_fixture(ctx.scope),
          [
            {1, "run.started", started_data()},
            {2, "session.started", session_started_data()},
            {3, "runtime.started", %{"session" => 1, "session_id" => "session-0001"}}
          ] ++
            notes.(4..298, %{"session" => 1}) ++
            [
              step(299, 1, "join session 2", "join"),
              step_end(300, 1),
              {301, "session.started", session_started_data(%{"session" => 2})},
              {302, "runtime.started", %{"session" => 2, "session_id" => "session-0002"}}
            ]
        )

      lv = page(ctx, run)
      at_end(lv)
      assert length(listed(lv, "timeline")) == 297
      assert listed(lv, "timeline-2") == ["e-302"]

      # 400 rows arrive in session 2: the page keeps the last 600 rows of the run.
      arrive!(lv, run, notes.(303..702, %{"session" => 2}))

      one = listed(lv, "timeline")
      two = listed(lv, "timeline-2")
      assert length(one) == 199 and hd(one) == "e-100" and List.last(one) == "e-298"
      assert length(two) == 401 and hd(two) == "e-302" and List.last(two) == "e-702"
      assert has_element?(lv, "#timeline-earlier", "98 earlier events")
      refute has_element?(lv, "#timeline-2-earlier")

      # Load earlier fills session 1, and the page drops session 2's last rows.
      lv |> element("#timeline-earlier") |> render_click()

      one = listed(lv, "timeline")
      two = listed(lv, "timeline-2")
      assert length(one) == 297 and hd(one) == "e-1"
      assert length(two) == 303 and List.last(two) == "e-604"
      refute has_element?(lv, "#timeline-earlier")
      assert has_element?(lv, "#timeline-2-later")
      refute has_element?(lv, "#timeline-later")

      # Load newer brings them back, and the page drops session 1's first rows again.
      lv |> element("#timeline-2-later") |> render_click()

      one = listed(lv, "timeline")
      two = listed(lv, "timeline-2")
      assert length(one) == 199 and hd(one) == "e-100"
      assert length(two) == 401 and List.last(two) == "e-702"
      refute has_element?(lv, "#timeline-2-later")
    end

    # Session 1 starts at 2 with its prompt at 4. Session 2's join runs from 5 to 6, so the
    # Run list is drawn, and session 2 starts at 7 with its prompt at 9. Then come session
    # 1's call, text and result, from 10 to 13: the two sessions overlap in time. The run
    # ends at 14.
    defp overlapping do
      one = %{"session" => 1}
      two = %{"session" => 2}

      [
        {1, "run.started", started_data()},
        {2, "session.started", session_started_data()},
        {3, "runtime.started", Map.put(one, "session_id", "session-0001")},
        {4, "runtime.text", Map.merge(one, %{"role" => "user", "text" => "Map the checkout"})},
        step(5, 1, "join session 2", "join"),
        step_end(6, 1),
        {7, "session.started", session_started_data(two)},
        {8, "runtime.started", Map.put(two, "session_id", "session-0002")},
        {9, "runtime.text", Map.merge(two, %{"role" => "user", "text" => "Add a test"})},
        {10, "runtime.tool_started",
         Map.merge(one, %{"tool" => "Bash", "tool_use_id" => "tool-1", "input" => %{}})},
        {11, "runtime.tool_failed",
         Map.merge(one, %{"tool" => "Bash", "tool_use_id" => "tool-1", "error" => "exit 2"})},
        {12, "runtime.text",
         Map.merge(one, %{"role" => "assistant", "text" => "The checkout has four steps."})},
        {13, "runtime.result", Map.merge(one, %{"outcome" => "success", "result" => "one"})},
        {14, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
      ]
    end

    test "sessions that overlap in time each list their items, by session number", ctx do
      run = project!(run_fixture(ctx.scope), overlapping())
      lv = page(ctx, run)

      assert listed(lv, "timeline") == ~w(e-1 e-3 e-4 main-session e-10 e-12 e-13)
      assert listed(lv, "timeline-2") == ~w(e-8 e-9 main-session-2 e-14)
      assert lv |> element("#main-session") |> render() =~ "The checkout has four steps."
      refute lv |> element("#main-session-2") |> render() =~ "The checkout has four steps."
    end

    test "?seq= of an item of the earlier of two overlapping sessions opens its row", ctx do
      run = project!(run_fixture(ctx.scope), overlapping())
      lv = page(ctx, run, "?seq=10")

      assert has_element?(lv, "#prepare-machine-session[open]")
      refute has_element?(lv, "#prepare-machine-session-2[open]")
      assert has_element?(lv, "#timeline[data-target='e-10']")
      refute has_element?(lv, "#timeline-2[data-target]")
    end

    test "a running copy shows no running row, and neither do its join and wall", ctx do
      run = project!(run_fixture(ctx.scope), two_sessions())
      lv = open(ctx.conn, ctx.scope, run)

      arrive!(lv, run, copy_begun())

      assert has_element?(lv, "#prepare-machine-step-1[data-state='succeeded']")
      refute has_element?(lv, "#prepare-machine [data-state='running']")
      refute has_element?(lv, "#prepare-machine-step-2")
      refute has_element?(lv, "#prepare-machine-step-3")
      refute has_element?(lv, "#prepare-machine-step-4")
    end

    test "a bare session that reuses an agent session's number does not end that session",
         ctx do
      run =
        project!(
          run_fixture(ctx.scope),
          [
            {1, "run.started", started_data()},
            step(2, 1, "join session 1", "join"),
            step_end(3, 1),
            {4, "session.started", session_started_data()},
            {5, "runtime.result", %{"session" => 1, "outcome" => "success", "result" => "done"}},
            exit(6, 1),
            {7, "session.started", %{"session" => 1, "bare" => true, "runtime" => "git"}},
            {8, "session.exited", %{"session" => 1, "state" => "failed", "exit_code" => 1}},
            {9, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
          ]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#prepare-machine-session-agent[data-state=succeeded]")
      refute has_element?(lv, "#prepare-machine-session-2")
      refute has_element?(lv, "#prepare-machine [data-state=failed]")
    end

    test "a failed copy after a success: no row, no stop, and the copy's line, not an earlier tool's",
         ctx do
      tool = %{"tool" => "Bash", "tool_use_id" => "tool-1"}

      run =
        project!(
          run_fixture(ctx.scope),
          [
            {1, "run.started", started_data()},
            step(2, 1, "join session 1", "join"),
            step_end(3, 1),
            {4, "session.started", session_started_data()},
            {5, "runtime.tool_started", Map.put(tool, "input", %{"command" => "make"})},
            {6, "runtime.tool_failed", Map.put(tool, "error", "exit status 1")},
            {7, "runtime.result", %{"session" => 1, "outcome" => "success", "result" => "done"}},
            exit(8, 1),
            step(9, 2, "copy the work back", "copy"),
            step_end(10, 2, "failed", 128),
            failed_exit(11)
          ]
        )

      lv = open(ctx.conn, ctx.scope, run)

      assert has_element?(lv, "#run-state", "Failed")
      # The Run list has the join's row, and no row of the copy.
      assert has_element?(lv, "#prepare-machine-session-prepare #prepare-machine-step-1")
      refute has_element?(lv, "#prepare-machine-step-2")
      refute has_element?(lv, "#prepare-machine-step-2-failed")
      refute has_element?(lv, "#prepare-machine [data-state=failed]")

      why = lv |> element("#run-why") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert why =~ "The run's work did not come back from the machine."
      refute why =~ "exit status 1"
    end
  end

  test "Save the outputs shows while the window stops short of the run's end", ctx do
    notes = for n <- 6..320, do: {n, "runtime.notification", %{"kind" => "k", "message" => "m"}}

    run =
      session_over(
        ctx.scope,
        notes ++ [push_started(321), push_exited(322, "succeeded", 0)]
      )

    lv = open(ctx.conn, ctx.scope, run)

    assert has_element?(lv, "#timeline-later")
    assert has_element?(lv, "#prepare-machine-session-outputs #prepare-machine-step-1")
  end

  test "Save the outputs stays while new events wait for a reader not at the end", ctx do
    run = session_over(ctx.scope, [push_started(6)])
    lv = open(ctx.conn, ctx.scope, run)
    assert has_element?(lv, "#prepare-machine-session-outputs")

    arrive!(lv, run, [{7, "runtime.notification", %{"kind" => "k", "message" => "late"}}])
    assert has_element?(lv, "#new-events")
    assert has_element?(lv, "#prepare-machine-session-outputs")
  end
end
