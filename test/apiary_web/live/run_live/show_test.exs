defmodule ApiaryWeb.RunLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs
  alias Apiary.Runs.Projector
  alias Mix.Tasks.Apiary.Demo

  defp demo(scope, name, now \\ DateTime.utc_now()) do
    %{access_key: access_key} = access_key_fixture(scope)
    file = Enum.find(Demo.files(), &(&1 |> Path.dirname() |> Path.basename() == name))
    {:ok, run} = Demo.replay(access_key, file, now)
    run
  end

  defp projected(scope, events, attrs \\ %{}) do
    run = run_fixture(scope, attrs)
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp project_more(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  # The page coalesces projections; a test asks for the read at once.
  defp flush(lv) do
    send(lv.pid, :flush)
    render(lv)
  end

  defp item_ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("ol#timeline > li")
    |> LazyHTML.attribute("id")
  end

  setup :register_and_log_in_user

  describe "not found" do
    test "a run of another hive, an unknown id and a malformed id render the same state", %{
      conn: conn
    } do
      theirs = projected(scope_fixture(), record())

      for id <- [theirs.run_id, theirs.id, Ecto.UUID.generate(), "0191f2a4"],
          path <- ["", "/terminal", "/connections", "/details"] do
        {:ok, _lv, html} = live(conn, "/hive/runs/#{id}#{path}")
        assert html =~ "This run is not in this hive"
        assert html =~ "Back to runs"
        refute html =~ "dev-laptop"
      end
    end

    test "signed out, the page redirects to the log-in page" do
      conn = build_conn()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, "/hive/runs/#{Ecto.UUID.generate()}")
    end
  end

  describe "the header (U6)" do
    test "everything from run.started, run.exited and the policy applied", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      # breadcrumb, title, state, alive sentence
      assert html =~ ~s(aria-label="Breadcrumb")
      assert html =~ String.slice(run.run_id, 0, 8)
      assert html =~ "<h1>#{run.task}</h1>"
      assert html =~ "Exited"
      assert html =~ "after it started"

      # the strip
      for label <- ~w(Exit Started Duration Runtime Host Policy), do: assert(html =~ "#{label}")
      assert html =~ "claude"
      assert html =~ "2.1.273"
      assert html =~ run.host
      assert html =~ run.wall
      assert html =~ run.image
      assert html =~ "enforce"
      assert html =~ String.slice(run.policy_digest, 0, 12)
      assert html =~ "3 m 52 s"

      # labels, in the record's order with forge, repository and task first
      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query(".q-labels .q-label i")
             |> Enum.map(&LazyHTML.text/1) ==
               ~w(forge repository task)

      # tabs with their counts
      assert has_element?(lv, "#run-tabs a[aria-current='page']", "Timeline")

      assert has_element?(
               lv,
               "#run-tabs a .q-tabs-n",
               "#{Apiary.Runs.Record.timeline(scope, run).session_items}"
             )

      assert has_element?(lv, "#run-tabs a .q-tabs-n.q-tabs-bad", "2 denied")
      assert html =~ ~s(aria-current="page")
    end

    test "a run without a task is titled by its short id, and one without a wall says None", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(%{"labels" => %{}})}])
      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert html =~ ~r/<h1>\s*Run <span[^>]*>#{String.slice(run.run_id, 0, 8)}/
      assert html =~ "This run had no wall"
      refute html =~ "Labels"
      # unassigned: the breadcrumb has no repository
      refute html =~ "repo="
    end

    test "a pending run says Ping only and waits on every tab but Details", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [{1, "ping", %{"runner_version" => "0.10.0", "contract_version" => 1}}])

      for path <- ["", "/terminal", "/connections"] do
        {:ok, _lv, html} = live(conn, "/hive/runs/#{run.run_id}#{path}")
        assert html =~ "Ping only"
        assert html =~ "Waiting for the run to start"
        assert html =~ "The run&#39;s first event has not arrived."
      end
    end

    test "quiet: amber after one missed interval, by the server's clock", %{
      conn: conn,
      scope: scope
    } do
      long_ago = DateTime.add(DateTime.utc_now(), -47, :second)

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: DateTime.add(long_ago, -60, :second)},
          {2, "run.heartbeat", %{"elapsed_seconds" => 60, "interval_seconds" => 30},
           time: long_ago, received_at: long_ago}
        ])

      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert html =~ "No heartbeat for"
      assert html =~ "q-alive-amber"
      assert html =~ "at least"
      assert html =~ "1 m 00 s"
    end
  end

  describe "the timeline (P2, P3, P4)" do
    setup %{scope: scope} do
      %{run: demo(scope, "session-with-subagents")}
    end

    test "every kind of item, in sequence order", %{conn: conn, run: run} do
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      ids = item_ids(html)
      assert hd(ids) == "e-2"
      assert List.last(ids) == "e-101"
      assert ids == Enum.sort_by(ids, fn "e-" <> n -> String.to_integer(n) end)

      for words <- [
            "Run started",
            "Policy applied",
            "Session started",
            "Prompt",
            "Subagent started",
            "Subagent finished",
            "Notification",
            "Turn finished",
            "Result",
            "Session ended",
            "Run exited"
          ] do
        assert html =~ words
      end

      assert html =~ "behind a docker wall"
      assert html =~ "4 hosts allowed"
      assert html =~ "fetched from the run configuration"
      assert html =~ "permission_prompt · Claude needs your permission to use Bash"
      assert html =~ "success · 14 turns · 3 m 49 s · $0.84"
      assert html =~ "exit 0"
      assert html =~ "End of the record. 101 events."
      assert has_element?(lv, "ol#timeline[aria-label='Session timeline, oldest first']")
      refute html =~ "aria-live=\"polite\" id=\"timeline\""
    end

    test "three lanes with a key, a who chip where a lane opens and closes", %{
      conn: conn,
      run: run
    } do
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert has_element?(lv, "a.q-lanekey.q-lane-main", "Main session")
      assert has_element?(lv, "a.q-lanekey.q-lane-a", "Explore")
      assert has_element?(lv, "a.q-lanekey.q-lane-b", "general-purpose")
      assert html =~ "agent-demo-a1"
      assert has_element?(lv, "ol.q-lanes-3")

      # start and finish brackets
      assert has_element?(lv, "#e-21 .q-r.q-rail-1.q-r-from")
      assert has_element?(lv, "#e-21 .q-h.q-rail-1.q-lane-a")
      assert has_element?(lv, "#e-21 .q-who.q-lane-a", "Explore")
      assert has_element?(lv, "#e-36 .q-r.q-rail-1.q-r-to")
      assert has_element?(lv, "#e-22 .q-r.q-rail-2.q-r-from")
      assert has_element?(lv, "#e-49 .q-r.q-rail-2.q-r-to")

      # a subagent's tool sits on the subagent's rail, with all three rails passing
      assert has_element?(lv, "#e-25 .q-n.q-rail-1.q-lane-a")
      assert has_element?(lv, "#e-25 .q-r.q-rail-2")
      assert has_element?(lv, "#e-25[data-lane='agent-demo-a1']")
    end

    test "a tool pairs its events: summary, duration, input and response; a failed one starts open",
         %{conn: conn, run: run} do
      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert has_element?(lv, "#e-11 summary .q-k", "Read")
      assert has_element?(lv, "#e-11 summary .q-s", "/work/shop/package.json")
      assert has_element?(lv, "#e-11 .q-well", "input")
      assert has_element?(lv, "#e-11 .q-well", "response")
      assert has_element?(lv, "#e-11 .q-well .q-key", "\"file_path\"")
      refute has_element?(lv, "#e-11 details[open]")
      # the end of a call is not an item of its own
      refute has_element?(lv, "#e-12")

      assert has_element?(lv, "#e-25 summary .q-s", "CheckoutForm in /work/shop/src")

      assert has_element?(lv, "#e-58 details[open]")
      assert has_element?(lv, "#e-58 summary .q-bad", "Failed")
      assert has_element?(lv, "#e-58 .q-n.q-n-fail")
      assert has_element?(lv, "#e-58 .q-well.q-well-err", "error")
    end

    test "a connection sits inside a call only when exactly one was open, and says while", %{
      conn: conn,
      run: run
    } do
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert has_element?(lv, "#e-58 .q-during", "1 connection while this call was open")
      assert has_element?(lv, "#e-58 .q-during .q-cx-denied", "registry.example")
      assert has_element?(lv, "#e-58 .q-during", "No rule matches")
      refute has_element?(lv, "#e-59")

      # between items while the two Task calls were open, with the caption, and no node
      assert html =~ "while 2 calls were open"
      assert has_element?(lv, "#e-6.q-ti-cx")
      refute has_element?(lv, "#e-6 .q-n")

      refute html =~ "because"
    end

    test "?seq= targets the item that holds the event; an unknown one is dropped from the URL", %{
      conn: conn,
      run: run
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}?seq=59")
      assert has_element?(lv, "ol#timeline[data-target='e-58']")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/hive/runs/#{run.run_id}?seq=99999&lane=nobody&cx=7&x=1")

      assert to == ~p"/hive/runs/#{run.run_id}"

      # a valid one among them is kept
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/hive/runs/#{run.run_id}?seq=58&x=1")

      assert to == ~p"/hive/runs/#{run.run_id}?seq=58"
    end

    test "?lane= isolates a lane and ?cx=0 hides the connections; both are toggles that patch", %{
      conn: conn,
      run: run
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      lv |> element("a.q-lanekey.q-lane-a") |> render_click()
      assert_patch(lv, ~p"/hive/runs/#{run.run_id}?lane=agent-demo-a1")
      assert has_element?(lv, "ol#timeline[data-isolate='agent-demo-a1']")
      assert has_element?(lv, "a.q-lanekey.q-lane-a[aria-pressed='true']")
      assert has_element?(lv, "a.q-lanekey.q-lane-b[aria-pressed='false']")

      lv |> element("#toggle-connections") |> render_click()
      assert_patch(lv, ~p"/hive/runs/#{run.run_id}?cx=0&lane=agent-demo-a1")
      assert has_element?(lv, "ol#timeline[data-cx='0']")

      lv |> element("a.q-lanekey.q-lane-a") |> render_click()
      assert_patch(lv, ~p"/hive/runs/#{run.run_id}?cx=0")
      refute has_element?(lv, "ol#timeline[data-isolate]")
    end

    test "event data is escaped", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.prompt_submitted", %{"prompt" => "<script>alert(1)</script>"}},
          {3, "session.tool_started",
           %{
             "tool" => "<b>Bash</b>",
             "tool_use_id" => "t",
             "input" => %{"command" => "<img src=x onerror=1>"}
           }}
        ])

      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<img src=x"
      refute html =~ "<b>Bash</b>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    end

    test "a payload over the cap is cut, and Show all loads the rest of that one item", %{
      conn: conn,
      scope: scope
    } do
      big = String.duplicate("0123456789abcdef", 1024) <> "THE-END"

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "cat big"}}},
          {3, "session.tool_finished",
           %{"tool" => "Bash", "tool_use_id" => "t", "response" => big}}
        ])

      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      refute html =~ "THE-END"
      assert html =~ "Show all 16.0 KB"

      html = lv |> element("#e-2 button.q-show-all") |> render_click()
      assert html =~ "THE-END"
      refute html =~ "Show all"
    end
  end

  describe "the limits (P5)" do
    test "another runtime: the sentence stands above the runner's items", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "failed-run")
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert html =~ "Session events exist only for Claude Code."
      assert has_element?(lv, ".q-limits code.q-rule", "make")
      assert html =~ "Run started"
      assert html =~ "exit 2"
      assert html =~ "Failed"
    end

    test "a walled claude run with no hook events reads as the contract's known limit", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started",
           started_data(%{"wall" => "docker", "image" => "registry.example/agent:1"})},
          {2, "session.result", %{"outcome" => "success", "result" => "done"}},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      assert html =~ "on an engine inside a virtual machine"
      assert html =~ "Only the result, read from the runtime&#39;s output, is shown."
    end

    test "claude without a wall and without session events: the hooks sentence", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      assert html =~ "No session events arrived."
    end

    test "a young live run has no limits sentence yet, only the live end", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(), time: DateTime.utc_now()}])
      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      refute html =~ "No session events arrived."
      assert html =~ "Listening for the next batch."
    end
  end

  describe "live (P6, P7)" do
    setup %{scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: DateTime.add(now, -30, :second)},
          {2, "session.prompt_submitted", %{"prompt" => "go"},
           time: DateTime.add(now, -29, :second)},
          {3, "session.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t1", "input" => %{"command" => "sleep 9"}},
           time: DateTime.add(now, -28, :second)}
        ])

      %{run: run, now: now}
    end

    test "an open tool is Running; its end updates the item in place", %{
      conn: conn,
      run: run,
      now: now
    } do
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      assert has_element?(lv, "#e-3 .q-running", "Running")
      assert has_element?(lv, "#e-3 .q-n .q-spin")
      assert has_element?(lv, "#e-3 .q-r-live")
      assert html =~ "Listening for the next batch."

      project_more(run, [
        {4, "session.tool_finished",
         %{"tool" => "Bash", "tool_use_id" => "t1", "response" => "ok", "duration_ms" => 9000},
         time: now}
      ])

      html = flush(lv)
      refute has_element?(lv, "#e-3 .q-running")
      assert has_element?(lv, "#e-3 .q-well", "response")
      assert item_ids(html) == ["e-1", "e-2", "e-3"]
      refute has_element?(lv, "#new-events.q-newpill-show")
    end

    test "away from the end new items are counted, not inserted; the pill loads them", %{
      conn: conn,
      run: run,
      now: now
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      project_more(run, [
        {4, "session.notification", %{"kind" => "idle_prompt", "message" => "waiting"},
         time: now},
        {5, "session.turn_finished", %{"message" => "done"}, time: now}
      ])

      html = flush(lv)
      assert item_ids(html) == ["e-1", "e-2", "e-3"]
      assert has_element?(lv, "#new-events.q-newpill-show", "2 new events")
      assert has_element?(lv, "#run-announcer", "2 new events.")

      html = lv |> element("#new-events") |> render_click()
      assert item_ids(html) == ["e-1", "e-2", "e-3", "e-4", "e-5"]
      refute has_element?(lv, "#new-events.q-newpill-show")
      assert_push_event(lv, "timeline:end", %{focus: "e-4"})
    end

    test "at the live end new items append", %{conn: conn, run: run, now: now} do
      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      render_hook(element(lv, "#run-timeline"), "live_end", %{"at_end" => true})

      project_more(run, [{4, "session.turn_finished", %{"message" => "done"}, time: now}])

      html = flush(lv)
      assert item_ids(html) == ["e-1", "e-2", "e-3", "e-4"]
      refute has_element?(lv, "#new-events.q-newpill-show")
      # the item that was last no longer fades its rail
      refute has_element?(lv, "#e-3 .q-r-live")
    end

    test "background tasks: listed while outstanding, in the record's words when the run ends", %{
      conn: conn,
      run: run,
      now: now
    } do
      task = %{
        "id" => "b3f1",
        "type" => "shell",
        "status" => "running",
        "command" => "pytest tests/checkout -q"
      }

      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      refute html =~ "in the background"

      run =
        project_more(run, [
          {4, "session.turn_finished", %{"message" => "m", "background_tasks" => [task]},
           time: now}
        ])

      html = flush(lv)
      assert html =~ "1 task"
      assert html =~ "still running in the background"
      assert html =~ "pytest tests/checkout -q"
      assert html =~ "shell b3f1 · listed at #0004"

      project_more(run, [
        {5, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 30_000},
         time: now}
      ])

      html = flush(lv)
      assert html =~ "was still listed when the run ended"
      assert has_element?(lv, "#background-tasks .q-spin-still")
    end

    test "a state change is announced once, and the header follows", %{
      conn: conn,
      run: run,
      now: now
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      project_more(run, [
        {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 30_000},
         time: now}
      ])

      html = flush(lv)

      assert has_element?(lv, "#run-announcer", "Run failed with exit 1.")
      assert html =~ "Failed with exit 1"
      assert html =~ "End of the record."
    end
  end

  describe "windowing (rj)" do
    test "300 items on mount, 200 more at either end, 600 at most, rails right at the edges", %{
      conn: conn,
      scope: scope
    } do
      events =
        [{1, "run.started", started_data()}] ++
          for(
            n <- 2..900,
            do: {n, "session.notification", %{"kind" => "k", "message" => "m#{n}"}}
          ) ++
          [{901, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}]

      run = projected(scope, events)

      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      ids = item_ids(html)
      assert length(ids) == 300
      assert hd(ids) == "e-1" and List.last(ids) == "e-300"
      assert has_element?(lv, "#timeline-later", "601 later events")
      refute has_element?(lv, "#timeline-earlier")

      html = lv |> element("#timeline-later") |> render_click()
      assert html |> item_ids() |> List.last() == "e-500"

      # around a target
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}?seq=700")
      ids = item_ids(html)
      assert length(ids) == 300
      assert hd(ids) == "e-550" and List.last(ids) == "e-849"
      assert has_element?(lv, "#timeline-earlier", "549 earlier events")
      assert has_element?(lv, "#e-550 .q-r-through")

      html = lv |> element("#timeline-earlier") |> render_click()
      ids = item_ids(html)
      assert hd(ids) == "e-350"
      assert ids == Enum.sort_by(ids, fn "e-" <> n -> String.to_integer(n) end)
      assert has_element?(lv, "#timeline-earlier", "349 earlier events")
    end
  end

  describe "the terminal tab (P1)" do
    test "the box points the hook at the log endpoint and carries numbers, never bytes", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}/terminal")

      assert has_element?(
               lv,
               "#terminal[phx-hook='Terminal'][data-src='/hive/runs/#{run.run_id}/log']"
             )

      assert has_element?(lv, "#terminal[data-live='false']")
      assert has_element?(lv, "#terminal [data-stream='stdout']")
      assert has_element?(lv, "#terminal [data-stream='stderr']")
      assert has_element?(lv, "#terminal [role='log'][aria-live='off']")
      assert has_element?(lv, "#terminal a[href='/hive/runs/#{run.run_id}/log?download=1']")
      assert html =~ "Ended"
      assert html =~ "chunks"
      assert html =~ "through #0100"
      assert html =~ "The bytes as the runtime wrote them"
      refute html =~ "vitest"
    end

    test "a live run tails: the page says how far the log advanced", %{conn: conn, scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(%{"interactive" => true}), time: now},
          {2, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\n")}, time: now}
        ])

      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}/terminal")
      assert html =~ "Live"
      assert has_element?(lv, "#terminal .q-tseg-one", "terminal")
      assert has_element?(lv, "#terminal [data-follow][aria-pressed='true']")

      project_more(run, [
        {3, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("two\n")}, time: now}
      ])

      html = flush(lv)

      assert_push_event(lv, "log_advanced", %{through: 3})
      assert html =~ "through #0003"
      assert html =~ "2 chunks"
    end

    test "no output: yet, for a live run; none, for an ended one", %{conn: conn, scope: scope} do
      live_run = projected(scope, [{1, "run.started", started_data(), time: DateTime.utc_now()}])
      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{live_run.run_id}/terminal")
      assert html =~ "No output yet"

      ended =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{ended.run_id}/terminal")
      assert html =~ "This run wrote no output"
    end
  end

  describe "the connections tab (C1, C3)" do
    test "one row per destination, denied first, with the reason and the outcome", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      {:ok, lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}/connections")

      assert html =~ "attempts to"
      assert html =~ "destinations"

      assert [first, second | _] =
               html
               |> LazyHTML.from_document()
               |> LazyHTML.query("#run-connections > tr")
               |> LazyHTML.attribute("class")

      assert first =~ "q-denied" and second =~ "q-denied"

      assert html =~ "No rule matches."
      assert html =~ "Enforce mode denies it."
      assert html =~ "Refused"
      assert html =~ "Dial failed"
      assert html =~ "POST /acme/shop.git/git-upload-pack"
      assert html =~ "forge-token"
      assert html =~ "behind a wall, anything else fails unseen."

      lv |> element("#decision a", "Denied") |> render_click()
      assert_patch(lv, ~p"/hive/runs/#{run.run_id}/connections?decision=denied")
      html = render(lv)
      refute html =~ "git-upload-pack"
      assert html =~ "registry.example"

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/hive/runs/#{run.run_id}/connections?decision=maybe")

      assert to == ~p"/hive/runs/#{run.run_id}/connections"
    end

    test "no egress: the sentence, never an empty table", %{conn: conn, scope: scope} do
      run = projected(scope, [{1, "run.started", started_data()}])
      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}/connections")

      assert html =~ "No connections recorded"
      assert html =~ "No connection went through the runner&#39;s proxy."
      refute html =~ "<table"
    end
  end

  describe "the details tab" do
    test "the command, the policy in force and the record", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")
      {:ok, _lv, html} = live(conn, ~p"/hive/runs/#{run.run_id}/details")

      for heading <- ["Command", "Policy in force", "Record"], do: assert(html =~ heading)
      assert html =~ "--verbose"
      assert html =~ "/work/shop"
      assert html =~ "No, on pipes"
      assert html =~ "0.10.0"
      assert html =~ "contract 1"
      assert html =~ run.policy_digest
      assert html =~ "api.llm.example, git.example.com"
      assert html =~ "forge-token"
      assert html =~ run.run_id
      assert html =~ "projected through"
      assert html =~ "5b8e2f14-9c3a-4d7e-a1b6-3f0c8d2e7a45"
      # an exited run is not closed by hand
      refute html =~ "close-run-button"
    end

    test "a member closes a quiet run after confirming in a modal", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30}}
        ])

      {:ok, lv, _html} = live(conn, ~p"/hive/runs/#{run.run_id}/details")

      refute has_element?(lv, "#close-run")
      lv |> element("#close-run-button") |> render_click()
      assert has_element?(lv, "#close-run", "A close is final")

      lv |> element("#close-run button", "Cancel") |> render_click()
      refute has_element?(lv, "#close-run")
      assert Runs.get_run!(scope, run.id).state == "running"

      lv |> element("#close-run-button") |> render_click()
      html = lv |> element("#close-run button", "Close run") |> render_click()

      assert Runs.get_run!(scope, run.id).state == "closed"
      assert html =~ "Closed"
      refute has_element?(lv, "#close-run-button")
      assert has_element?(lv, "#run-announcer", "Run closed.")
    end
  end
end
