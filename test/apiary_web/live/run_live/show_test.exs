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

  # What the policy made of the record is on the page only where the instance has
  # `security`; the record itself is there in every configuration.
  defp security?, do: Apiary.Features.on?(:security)

  defp item_ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("ol#timeline > li")
    |> LazyHTML.attribute("id")
  end

  setup :register_and_log_in_user

  describe "not found" do
    test "a run of another workspace, an unknown id and a malformed id render the same state", %{
      conn: conn,
      scope: scope
    } do
      theirs = projected(scope_fixture(), record())

      for id <- [theirs.run_id, theirs.id, Ecto.UUID.generate(), "0191f2a4"],
          path <- ["", "/terminal", "/network", "/details"] do
        {:ok, _lv, html} = live(conn, "#{workspace_path(scope)}/runs/#{id}#{path}")
        assert html =~ "This run is not in this workspace"
        assert html =~ "Back to runs"
        refute html =~ "dev-laptop"
      end
    end

    test "the breadcrumb leads to Runs, then names the run asked for when its id is a run's",
         %{conn: conn, scope: scope} do
      runs = workspace_path(scope, "/runs")
      id = Ecto.UUID.generate()

      {:ok, lv, _html} = live(conn, "#{runs}/#{id}")
      assert crumbs(lv) == [{"Runs", runs}, {"Run #{String.slice(id, 0, 8)}", nil}]
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Run #{String.slice(id, 0, 8)}")

      # An address that is no run's id names no run.
      {:ok, lv, _html} = live(conn, "#{runs}/0191f2a4")
      assert crumbs(lv) == [{"Runs", runs}]
    end

    test "signed out, the page redirects to the log-in page", %{scope: scope} do
      conn = build_conn()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, "#{workspace_path(scope)}/runs/#{Ecto.UUID.generate()}")
    end
  end

  describe "the header (U6)" do
    test "two lines: the title, then the state and the run's facts; the rest is the rail's", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      target = workspace_path(scope, "/targets/acme/shop")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      # the title alone on its line
      assert has_element?(lv, "h1#run-title", ApiaryWeb.RunComponents.run_title(run))

      # the meta line: the state as a dot and its word, the target's page, runtime, host,
      # when it started, how long it took, its denials, which lead to its connections
      assert has_element?(lv, "#run-meta #run-state.q-sdot-succeeded", "Completed")
      assert has_element?(lv, ~s(#run-meta a#run-target[href="#{target}"]), "acme/shop")
      # one system has acme/shop: the path is written alone
      refute has_element?(lv, "#run-target .q-tname-sys")
      # a long name is cut on the meta line (`.q-run-meta > #run-target`), whole in its title
      assert has_element?(lv, ~s(#run-meta > #run-target > .q-tname[title="acme/shop"]))
      assert has_element?(lv, "#run-runtime", "claude 2.1.273")
      assert has_element?(lv, "#run-host", run.host)
      assert has_element?(lv, "#run-meta time#run-started[datetime]")
      assert has_element?(lv, "#run-duration-line", "3 m 52 s")

      assert has_element?(
               lv,
               ~s(#run-denied[href="#{workspace_path(scope)}/runs/#{run.run_id}/network?decision=denied"]),
               "2 denied"
             )

      # no in-page breadcrumb and no strip of cells: the top bar has the one, the rail the
      # other
      refute html =~ ~s(aria-label="Breadcrumb")
      refute has_element?(lv, ".q-kvs")

      # the top bar's segments: Runs, a link to the list, then this run; the target is on
      # the meta line, not in the breadcrumb
      assert crumbs(lv) == [
               {"Runs", workspace_path(scope, "/runs")},
               {"Run #{String.slice(run.run_id, 0, 8)}", nil}
             ]

      assert has_element?(
               lv,
               "#breadcrumb [aria-current='page']",
               "Run #{String.slice(run.run_id, 0, 8)}"
             )

      # the rail: the run's facts as key and value lines
      for label <- ~w(State Exit Started Duration Runtime Host Wall Key),
          do: assert(has_element?(lv, "#run-details #run-facts dt", label))

      assert has_element?(lv, "#run-facts", run.wall)
      assert has_element?(lv, "#run-facts", run.image)

      if security?() do
        assert has_element?(lv, "#run-facts .q-kv-policy", "enforce")
        # the run configuration it applied was not rendered by this workspace
        assert has_element?(lv, "#policy-unrendered", "a4e1d0c97b3f")
        assert has_element?(lv, "#policy-unrendered", "Not a version made in this workspace")
      else
        refute has_element?(lv, "#run-facts .q-kv-policy")
        refute has_element?(lv, "#policy-unrendered")
      end

      # labels are key and value lines, in the record's order: forge and repository first,
      # then by name; a label that names the target leads to its page, and a task is an
      # ordinary label
      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#run-labels dt")
             |> Enum.map(&LazyHTML.text/1)
             |> Enum.map(&String.trim/1) ==
               ~w(forge repository task)

      assert has_element?(lv, ~s(#run-labels a[href="#{target}"]), "acme/shop")
      refute has_element?(lv, ~s(#run-labels a[href*="task="]))
      refute has_element?(lv, ".q-label")

      # tabs with their counts; Details is the rail's, a tab below 1440 px and on Terminal
      assert has_element?(lv, "#run-tab a#run-tab-timeline[aria-current='page']", "Timeline")

      assert has_element?(
               lv,
               "#run-tab a .q-tabs-n",
               "#{Apiary.Runs.Record.timeline(scope, run).session_items}"
             )

      assert has_element?(lv, "#run-tab a .q-tabs-n.q-tabs-bad", "2 denied")
      assert has_element?(lv, "#run-tab a#run-tab-details", "Details")
    end

    test "the more menu copies the id and offers the log, to a reader of the log", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      log = "#{workspace_path(scope)}/runs/#{run.run_id}/log"

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-menu[phx-hook='Menu'] #run-menu-button[aria-haspopup='menu']")

      assert has_element?(
               lv,
               ~s(#run-menu-copy[phx-hook="CopyToClipboard"][data-copy="#{run.run_id}"])
             )

      assert has_element?(lv, ~s(#run-menu-raw[href="#{log}"][target="_blank"]), "Raw log")
      assert has_element?(lv, ~s(#run-menu-download[href="#{log}?download=1"][download]))
    end

    test "the Terminal tab is wide: the rail folds away and Details is a tab", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}"

      # what the page's CSS keys on from 1440 px: no rail beside the column, and the
      # Details tab shown; the rail is still the one element, for the Details tab
      {:ok, lv, _html} = live(conn, path <> "/terminal")
      assert has_element?(lv, "#run-page.q-run-wide #run-tab a#run-tab-details", "Details")
      assert has_element?(lv, "#run-page.q-run-wide #run-details")
      refute has_element?(lv, "#run-page.q-run-on-details")

      # a patch to another tab brings the rail back beside it
      lv |> element("#run-tab-timeline") |> render_click()
      assert has_element?(lv, "#run-tab-timeline[aria-current='page']")
      refute has_element?(lv, "#run-page.q-run-wide")

      for tab <- ["", "/network", "/details"] do
        {:ok, lv, _html} = live(conn, path <> tab)
        assert has_element?(lv, "#run-page #run-details")
        refute has_element?(lv, "#run-page.q-run-wide")
      end
    end

    test "the Details tab is the rail, in the column", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert has_element?(lv, "#run-page.q-run-on-details #run-details")
      assert has_element?(lv, "#run-tab-details[aria-current='page']")

      for section <- ~w(rail-run rail-labels rail-command rail-record),
          do: assert(has_element?(lv, "#run-details ##{section}"))

      assert has_element?(lv, "#run-id", run.run_id)
      # one element: the rail is not drawn a second time
      refute has_element?(lv, "#run-timeline")
    end

    test "a run's page ends a narrowing: the sidebar's Runs and Network access lead plainly", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      for tab <- ["", "/terminal", "/network", "/details"] do
        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}" <> tab)

        assert has_element?(lv, ~s(#nav-runs[href="#{workspace_path(scope, "/runs")}"]))
        assert has_element?(lv, ~s(#nav-network[href="#{workspace_path(scope, "/network")}"]))
        refute has_element?(lv, "#nav-runs[aria-label]")
        # the run's tabs are a thing's tabs, named for the run
        assert has_element?(lv, "nav#run-tab.q-tabs[aria-label=Run]")
      end
    end

    test "a shared path is written with its system, in the meta line and the top bar", %{
      conn: conn,
      scope: scope
    } do
      demo(scope, "session-with-subagents")

      other =
        projected(scope, [
          {1, "run.started",
           started_data(%{
             "labels" => %{"forge" => "github.example", "repository" => "acme/shop"}
           })}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{other.run_id}")

      assert has_element?(lv, "#run-target .q-tname-sys", "github.example")

      # Its link lands on its page at its address, which keeps the system.
      page = workspace_path(scope, "/targets/github.example/acme/shop")
      assert has_element?(lv, "#run-target[href='#{page}']")
    end

    test "the title is the one the run gave; a task is an ordinary label, never the title", %{
      conn: conn,
      scope: scope
    } do
      labels = %{"task" => "fix-login", "team" => "web"}

      titled =
        projected(scope, [
          {1, "run.started",
           started_data(%{"about" => %{"title" => "Fix the login redirect"}, "labels" => labels})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{titled.run_id}")

      assert has_element?(lv, "h1#run-title", "Fix the login redirect")
      assert page_title(lv) == "Fix the login redirect · Runs · Qory Apiary"
      assert has_element?(lv, "#run-labels dd", "fix-login")
      refute has_element?(lv, "#run-labels a")

      untitled = projected(scope, [{1, "run.started", started_data(%{"labels" => labels})}])
      short = String.slice(untitled.run_id, 0, 8)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{untitled.run_id}/details")

      assert has_element?(lv, "h1#run-title", "Run #{short}")
      refute has_element?(lv, "h1#run-title", "fix-login")
      assert page_title(lv) == "Details · Run #{short} · Runs · Qory Apiary"
    end

    test "a run without a title is titled by its short id, and one without a wall says None", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(%{"labels" => %{}})}])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "h1#run-title", "Run #{String.slice(run.run_id, 0, 8)}")
      assert html =~ "This run had no wall"
      refute has_element?(lv, "#run-labels")
      # unassigned: the meta line names no target, and the breadcrumb is Runs and the run
      refute has_element?(lv, "#run-target")

      assert crumbs(lv) == [
               {"Runs", workspace_path(scope, "/runs")},
               {"Run #{String.slice(run.run_id, 0, 8)}", nil}
             ]
    end

    test "the run's crumb is the page on the Timeline and a link to it on the other tabs", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(%{"labels" => %{}})}])
      timeline = workspace_path(scope, "/runs/#{run.run_id}")
      short = "Run #{String.slice(run.run_id, 0, 8)}"

      {:ok, lv, _html} = live(conn, timeline)
      assert crumbs(lv) == [{"Runs", workspace_path(scope, "/runs")}, {short, nil}]

      for tab <- ["/terminal", "/network", "/details"] do
        {:ok, lv, _html} = live(conn, timeline <> tab)
        assert crumbs(lv) == [{"Runs", workspace_path(scope, "/runs")}, {short, timeline}]
        # A tab of the same page: the way back is a patch, as the tabs are.
        assert has_element?(lv, "#breadcrumb a[href='#{timeline}'][data-phx-link=patch]")
      end
    end

    test "a pending run says Ping only and waits on every tab but Details", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [{1, "ping", %{"forager_version" => "0.10.0", "contract_version" => 1}}])

      for path <- ["", "/terminal", "/network"] do
        {:ok, _lv, html} = live(conn, "#{workspace_path(scope)}/runs/#{run.run_id}#{path}")
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

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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

    test "every kind of item, in sequence order", %{conn: conn, run: run, scope: scope} do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      ids = item_ids(html)
      assert hd(ids) == "e-2"
      assert List.last(ids) == "e-101"
      assert ids == Enum.sort_by(ids, fn "e-" <> n -> String.to_integer(n) end)

      for words <- [
            "Run started",
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

      # the policy the run applied is an item where the instance has security, and only there
      if security?() do
        assert html =~ "Policy applied"
        assert html =~ "4 hosts allowed"
        assert html =~ "fetched from the run configuration"
      else
        refute html =~ "Policy applied"
        refute html =~ "hosts allowed"
      end

      assert html =~ "permission_prompt · Claude needs your permission to use Bash"
      assert html =~ "success · 14 turns · 3 m 49 s · $0.84"
      assert html =~ "exit 0"
      assert html =~ "End of the record. 101 events."
      assert has_element?(lv, "ol#timeline[aria-label='Session timeline, oldest first']")
      refute html =~ "aria-live=\"polite\" id=\"timeline\""
    end

    test "three lanes with a key, a who chip where a lane opens and closes", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "button.q-lanekey.q-lane-main", "Main session")
      assert has_element?(lv, "button.q-lanekey.q-lane-a", "Explore")
      assert has_element?(lv, "button.q-lanekey.q-lane-b", "general-purpose")
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
         %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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
      run: run,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#e-58 .q-during", "1 connection while this call was open")
      assert has_element?(lv, "#e-58 .q-during .q-cx-denied", "registry.example")

      assert has_element?(
               lv,
               "#e-58 .q-during",
               if(security?(), do: "No rule matches", else: "Denied.")
             )

      refute has_element?(lv, "#e-59")

      # between items while the two Task calls were open, with the caption, and no node
      assert html =~ "while 2 calls were open"
      assert has_element?(lv, "#e-6.q-ti-cx")
      refute has_element?(lv, "#e-6 .q-n")

      refute has_element?(lv, "#timeline", "because")
    end

    test "?seq= targets the item that holds the event; an unknown one is dropped from the URL", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=59")

      assert has_element?(lv, "ol#timeline[data-target='e-58']")

      # what is not valid is dropped: the page is the plain one, and its links carry none of it
      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=99999&lane=nobody&cx=7&x=1"
        )

      refute has_element?(lv, "ol#timeline[data-target]")
      refute has_element?(lv, "ol#timeline[data-isolate]")
      assert has_element?(lv, "ol#timeline[data-cx='1']")
      refute html =~ "nobody"
      refute html =~ "99999"

      # a valid one among them is kept
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=58&x=1")

      assert has_element?(lv, "ol#timeline[data-target='e-58']")
    end

    test "?lane= isolates a lane and ?cx=0 hides the connections; both are toggles that patch", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      lv |> element("button.q-lanekey.q-lane-a") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?lane=agent-demo-a1"
      )

      assert has_element?(lv, "ol#timeline[data-isolate='agent-demo-a1']")
      assert has_element?(lv, "button.q-lanekey.q-lane-a[aria-pressed='true']")
      assert has_element?(lv, "button.q-lanekey.q-lane-b[aria-pressed='false']")

      assert has_element?(lv, "#toggle-connections[aria-pressed='true'] .q-toggle[data-on]")
      lv |> element("#toggle-connections") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?cx=0&lane=agent-demo-a1"
      )

      assert has_element?(lv, "ol#timeline[data-cx='0']")

      assert has_element?(
               lv,
               "#toggle-connections[aria-pressed='false'] .q-toggle:not([data-on])"
             )

      lv |> element("button.q-lanekey.q-lane-a") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?cx=0")
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

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      refute html =~ "THE-END"
      assert html =~ "Show all 16.4 kB"

      html = lv |> element("#e-2 button.q-show-all") |> render_click()
      assert html =~ "THE-END"
      refute html =~ "Show all"
    end
  end

  describe "the limits (P5)" do
    test "another runtime: the sentence stands above Forager's items", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "failed-run")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert html =~ "No session events arrived."
    end

    test "a young live run has no limits sentence yet, only the live end", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(), time: DateTime.utc_now()}])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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
      now: now,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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
      now: now,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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

    test "at the live end new items append", %{conn: conn, run: run, now: now, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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
      now: now,
      scope: scope
    } do
      task = %{
        "id" => "b3f1",
        "type" => "shell",
        "status" => "running",
        "command" => "pytest tests/checkout -q"
      }

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

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
      now: now,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      project_more(run, [
        {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 30_000},
         time: now}
      ])

      html = flush(lv)

      assert has_element?(lv, "#run-announcer", "Run failed with exit 1.")
      assert has_element?(lv, "#run-state.q-sdot-failed", "Failed")
      assert has_element?(lv, "#run-meta", "exit 1")
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

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      ids = item_ids(html)
      assert length(ids) == 300
      assert hd(ids) == "e-1" and List.last(ids) == "e-300"
      assert has_element?(lv, "#timeline-later", "601 later events")
      refute has_element?(lv, "#timeline-earlier")

      html = lv |> element("#timeline-later") |> render_click()
      assert html |> item_ids() |> List.last() == "e-500"

      # around a target
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=700")

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

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert has_element?(
               lv,
               "#terminal[phx-hook='Terminal'][data-src='#{workspace_path(scope)}/runs/#{run.run_id}/log']"
             )

      assert has_element?(lv, "#terminal[data-live='false']")
      assert has_element?(lv, "#terminal [data-stream='stdout']")
      assert has_element?(lv, "#terminal [data-stream='stderr']")
      assert has_element?(lv, "#terminal [role='log'][aria-live='off']")

      assert has_element?(
               lv,
               "#terminal a[href='#{workspace_path(scope)}/runs/#{run.run_id}/log?download=1']"
             )

      assert html =~ "Ended"
      assert html =~ "chunks"
      assert html =~ "through #0100"
      assert html =~ "The bytes as the runtime wrote them"
      assert has_element?(lv, "#terminal[data-sized='false'] [data-wrap]")
      refute has_element?(lv, "#terminal[data-cols]")
      refute html =~ "vitest"
    end

    test "the bar: follow, wrap, the text size, download, focus and full screen", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert has_element?(lv, "#terminal-bar [data-follow]")
      assert has_element?(lv, "#terminal-bar [data-wrap]", "Wrap")
      assert has_element?(lv, ~s(#terminal-bar [data-size-step="-1"][aria-label="Smaller text"]))
      assert has_element?(lv, ~s(#terminal-bar [data-size-step="1"][aria-label="Larger text"]))
      assert has_element?(lv, "#terminal-bar [data-size-label][aria-live='polite']")
      # Fit is for a recorded size: pipes are fitted to the box already
      refute has_element?(lv, "#terminal-bar [data-size-fit]")
      assert has_element?(lv, "#terminal-bar [data-focus][aria-keyshortcuts='f']", "Focus")
      # the browser's full screen shows only where the browser has one, which the hook asks
      assert has_element?(lv, "#terminal-bar [data-fullscreen][hidden]")
      assert has_element?(lv, "#terminal-bar .q-term-hint", "leaves focus")

      # the script's words are the server's, in the domain's language
      words =
        lv
        |> element("#terminal")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#terminal")
        |> LazyHTML.attribute("data-words")
        |> hd()
        |> Jason.decode!()

      assert words["size"] == "%{size} px"
      assert words["fullScreen"] == "Full screen"
      assert words["leaveFullScreen"] == "Leave full screen"
    end

    test "a run with a recorded size replays at it: the size on the box, no wrap", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started",
           started_data(%{"interactive" => true, "terminal" => %{"cols" => 120, "rows" => 40}})},
          {2, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\r\n")}},
          {3, "run.resized", %{"cols" => 100, "rows" => 30}},
          {4, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert has_element?(lv, "#terminal[data-sized='true'][data-cols='100'][data-rows='30']")
      assert has_element?(lv, "#terminal [data-size]", "100×30")
      refute has_element?(lv, "#terminal [data-wrap]")
      assert has_element?(lv, "#terminal [data-size-fit]")
      assert html =~ "drawn at the columns they were recorded at"

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert html =~ "Yes, on a pseudo-terminal"
      assert html =~ "100×30"
    end

    test "a live run tails: the page says how far the log advanced", %{conn: conn, scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(%{"interactive" => true}), time: now},
          {2, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\n")}, time: now}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

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

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{live_run.run_id}/terminal")

      assert html =~ "No output yet"

      ended =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{ended.run_id}/terminal")

      assert html =~ "This run wrote no output"
    end
  end

  describe "the connections tab (C1, C3)" do
    test "one row per destination, denied first, with the reason and the outcome", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      assert html =~ "attempts to"
      assert html =~ "destinations"

      assert [first, second | _] =
               html
               |> LazyHTML.from_document()
               |> LazyHTML.query("#run-connections > tr")
               |> LazyHTML.attribute("class")

      assert first =~ "q-denied" and second =~ "q-denied"

      assert html =~ "Refused"
      assert html =~ "Dial failed"
      assert html =~ "POST /acme/shop.git/git-upload-pack"

      # the reason is what the policy made of the attempt: which rule, in which mode
      if security?() do
        assert html =~ "No rule matches."
        assert html =~ "Enforce mode denies it."
        assert html =~ "forge-token"

        assert has_element?(
                 lv,
                 "#connections-footnote",
                 "A rule added here changes what happens next; what the record already says stays as it was."
               )
      else
        refute html =~ "No rule matches."
        refute has_element?(lv, "#run-connections .q-why")

        assert has_element?(
                 lv,
                 "#connections-footnote",
                 "The outcome is that of the last attempt."
               )
      end

      lv |> element("#decision button", "Denied") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network?decision=denied"
      )

      html = render(lv)
      refute html =~ "git-upload-pack"
      assert html =~ "registry.example"

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network?decision=maybe"
        )

      assert has_element?(lv, "#decision button[aria-pressed='true']", "All")
    end

    test "a row holds its place when it is seen again: the order is by first seen", %{
      conn: conn,
      scope: scope
    } do
      denied = fn host ->
        egress_data(%{
          "host" => host,
          "decision" => "denied",
          "rule" => "",
          "outcome" => "refused"
        })
      end

      t = DateTime.utc_now()
      at = &DateTime.add(t, &1, :second)

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.egress", denied.("first.example"), time: at.(1)},
          {3, "run.egress", denied.("second.example"), time: at.(2)}
        ])

      hosts = fn html ->
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#run-connections > tr .q-dest")
        |> LazyHTML.text()
      end

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      assert hosts.(html) =~ ~r/second\.example.*first\.example/s

      # the first host is refused again, later than the second: it stays below it
      project_more(run, [{4, "run.egress", denied.("first.example"), time: at.(30)}])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      assert hosts.(html) =~ ~r/second\.example.*first\.example/s
    end

    test "a tool invocation reads as a call to its tool, a refused request as a denial", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, tool_record())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      %{rows: rows} = Apiary.Runs.Record.connections(scope, run)
      call = Enum.find(rows, &(&1.path == "/media/acme/shop/checkout.png"))
      refused = Enum.find(rows, &(&1.path == "/media/acme/other/checkout.png"))
      plain = Enum.find(rows, &(&1.host == "api.example.com"))

      assert has_element?(lv, "#cx-#{call.id} .q-dest-tool .q-tool-name", "files")

      assert has_element?(
               lv,
               "#cx-#{call.id} .q-dest-tool .q-rq",
               "PUT /media/acme/shop/checkout.png"
             )

      assert has_element?(lv, "#cx-#{call.id} .q-dest-tool .q-on", "files.tools.internal:443")

      if security?(),
        do: assert(has_element?(lv, "#cx-#{call.id} .q-why", "Handed to")),
        else: refute(has_element?(lv, "#cx-#{call.id} .q-why"))

      assert has_element?(lv, "#cx-#{call.id} .q-outcome", "Answered 201")

      assert has_element?(lv, "#cx-#{refused.id}.q-denied .q-dest", "files.tools.internal")
      refute has_element?(lv, "#cx-#{refused.id} .q-dest-tool")

      if security?(),
        do:
          assert(has_element?(lv, "#cx-#{refused.id} .q-why", "Refused before reaching the tool")),
        else: refute(has_element?(lv, "#cx-#{refused.id} .q-why"))

      assert has_element?(lv, "#cx-#{refused.id} .q-outcome", "Refused")

      refute has_element?(lv, "#cx-#{plain.id} .q-dest-tool")
      assert has_element?(lv, "#cx-#{plain.id} .q-outcome", "Connected")
    end

    test "no egress: the sentence, never an empty table", %{conn: conn, scope: scope} do
      run = projected(scope, [{1, "run.started", started_data()}])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      assert html =~ "No connections recorded"
      assert html =~ "No connection went through the gateway."
      refute html =~ "<table"
    end
  end

  describe "the details tab" do
    test "the command, the policy in force and the record", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      for heading <- ["Command", "Record"], do: assert(html =~ heading)
      assert html =~ "--verbose"
      assert html =~ "/work/shop"
      assert html =~ "No, on pipes"
      refute html =~ "<dt>Terminal</dt>"
      assert html =~ "0.10.0"
      assert html =~ "contract 1"

      if security?() do
        assert html =~ "Policy in force"
        assert html =~ run.policy_digest
        assert html =~ "api.llm.example, codeberg.org"
        assert html =~ "forge-token"
      else
        refute html =~ "Policy in force"
        refute html =~ run.policy_digest
      end

      assert html =~ run.run_id
      assert html =~ "projected through"
      assert html =~ "5b8e2f14-9c3a-4d7e-a1b6-3f0c8d2e7a45"
    end
  end

  describe "read budget of a live page" do
    # What twenty projections cost the page must not depend on how long the run is.
    defp live_run(scope, items) do
      now = DateTime.utc_now()

      events =
        [{1, "run.started", started_data(), time: now}] ++
          for(
            n <- 2..items,
            do: {n, "session.notification", %{"kind" => "k", "message" => "m#{n}"}, time: now}
          ) ++
          for(
            n <- (items + 1)..(items + 40),
            do: {n, "run.egress", egress_data(%{"host" => "h#{n}.example"}), time: now}
          ) ++
          for(
            n <- (items + 41)..(items + 80),
            do:
              {n, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("l\n")}, time: now}
          )

      {projected(scope, events), items + 80, now}
    end

    defp twenty_projections(conn, scope, items, path) do
      {run, last, now} = live_run(scope, items)
      {:ok, lv, _html} = live(conn, "#{workspace_path(scope)}/runs/#{run.run_id}" <> path)

      handler = {__MODULE__, make_ref()}
      counter = :counters.new(2, [])
      page = lv.pid

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # The sidebar's count of alive runs comes on a timer of its own, in the page's
          # process; it is tagged, and is not what this budget is about.
          if self() == page and not (metadata[:options][:sidebar] == true) do
            :counters.add(counter, 1, 1)

            case metadata[:result] do
              {:ok, %{num_rows: rows}} when is_integer(rows) -> :counters.add(counter, 2, rows)
              _ -> :ok
            end
          end
        end,
        nil
      )

      for n <- 1..20 do
        sequence = last + n

        event =
          case rem(n, 4) do
            0 ->
              {sequence, "run.egress", egress_data(%{"host" => "late#{n}.example"}), time: now}

            1 ->
              {sequence, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")},
               time: now}

            _ ->
              {sequence, "session.notification", %{"kind" => "k", "message" => "new #{n}"},
               time: now}
          end

        project_more(run, [event])
        flush(lv)
      end

      :telemetry.detach(handler)
      html = render(lv)
      {:counters.get(counter, 1), :counters.get(counter, 2), html}
    end

    for {tab, path} <- [
          timeline: "",
          terminal: "/terminal",
          connections: "/network",
          details: "/details"
        ] do
      test "#{tab}: twenty projections read the same whatever the size of the run", %{
        conn: conn,
        scope: scope
      } do
        # Both are longer than a window, so what differs is the size of the run alone.
        {small_queries, small_rows, _} = twenty_projections(conn, scope, 400, unquote(path))
        {large_queries, large_rows, html} = twenty_projections(conn, scope, 3_000, unquote(path))

        IO.puts(
          "\n[budget] #{unquote(tab)}: 20 projections on a run of 480 events: #{small_queries} queries, #{small_rows} rows; of 3,080 events: #{large_queries} queries, #{large_rows} rows"
        )

        assert large_queries == small_queries
        assert large_rows == small_rows
        assert large_queries <= 80

        # and the page followed all the same
        if unquote(tab) == :timeline, do: assert(html =~ "new events")
        if unquote(tab) == :terminal, do: assert(html =~ "45 chunks")
      end
    end

    test "opening the page reads the record once: the static render has the header and a skeleton",
         %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")

      html =
        conn
        |> get(~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")
        |> html_response(200)

      assert html =~ "#{ApiaryWeb.RunComponents.run_title(run)} · Runs"
      assert html =~ "Completed"
      assert html =~ ~s(id="run-loading")
      refute html =~ ~s(id="timeline")
      refute html =~ "package.json"
    end

    test "an event that arrives below what the page holds is read in its place", %{
      conn: conn,
      scope: scope
    } do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: now},
          {2, "session.prompt_submitted", %{"prompt" => "go"}, time: now},
          {5, "session.turn_finished", %{"message" => "done"}, time: now}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert item_ids(html) == ["e-1", "e-2", "e-5"]

      project_more(run, [
        {3, "session.notification", %{"kind" => "late", "message" => "late"}, time: now}
      ])

      assert lv |> flush() |> item_ids() == ["e-1", "e-2", "e-3", "e-5"]
    end
  end

  describe "a call the record never ends" do
    setup %{scope: scope} do
      run =
        projected(scope, [
          {1, "session.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "sleep 9"}}},
          {2, "session.turn_finished", %{"message" => "done"}},
          {3, "session.ended", %{"reason" => "other"}},
          {4, "session.started", %{"source" => "resume"}},
          {5, "run.egress",
           egress_data(%{
             "host" => "late.example",
             "decision" => "denied",
             "outcome" => "refused",
             "rule" => ""
           })}
        ])

      %{run: run}
    end

    test "the later connection is an item at its own sequence, and ?seq=5 is that item", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=5")

      assert has_element?(lv, "ol#timeline[data-target='e-5']")
      assert has_element?(lv, "#e-5.q-ti-cx .q-cx-denied", "late.example")
      refute has_element?(lv, "#e-1 .q-during")
    end

    test "the call reads No end recorded, never Running", %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#e-1 .q-no-end", "No end recorded")
      refute has_element?(lv, "#e-1 .q-running")
      refute has_element?(lv, "#e-1 .q-spin")
    end

    test "on a run that has ended an open call is not Running either", %{conn: conn, scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: now},
          {2, "session.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "x"}}, time: now}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#e-2 .q-running", "Running")

      # the run is found lost: no projection, only the change of state
      {:ok, lost} =
        Runs.get_run!(scope, run.id)
        |> Ecto.Changeset.change(state: "lost")
        |> Apiary.Repo.update()

      send(lv.pid, {:run_changed, lost})
      flush(lv)

      refute has_element?(lv, "#e-2 .q-running")
      assert has_element?(lv, "#e-2 .q-no-end", "No end recorded")
    end
  end

  describe "clocks" do
    test "so far counts from Forager's elapsed seconds and this server's clock, never from started_at",
         %{conn: conn, scope: scope} do
      received = DateTime.add(DateTime.utc_now(), -5, :second)

      run =
        projected(scope, [
          # Forager's clock is a day behind.
          {1, "run.started", started_data(),
           time: DateTime.add(received, -86_400, :second), received_at: received},
          {2, "run.heartbeat", %{"elapsed_seconds" => 600, "interval_seconds" => 60},
           time: DateTime.add(received, -85_800, :second), received_at: received}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-duration[data-base='600']")
      assert lv |> element("#run-duration") |> render() =~ ~r/10 m 0\d s/
      refute render(lv) =~ "24 h"
    end
  end

  describe "bounds of what is drawn" do
    test "a dozen lane chips and the rest as a number; any lane can still be isolated", %{
      conn: conn,
      scope: scope
    } do
      now = DateTime.utc_now()

      events =
        [{1, "run.started", started_data(), time: now}] ++
          for(
            n <- 1..30,
            do:
              {n + 1, "session.subagent_started",
               %{"agent_id" => "agent-#{n}", "agent_type" => "Explore"}, time: now}
          )

      run = projected(scope, events)

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("button.q-lanekey")
             |> Enum.count() == 13

      assert has_element?(lv, "#more-lanes", "and 18 more")
      # ids are the lanes' numbers, not Forager's strings
      assert has_element?(lv, "button#lane-0", "Main session")
      assert has_element?(lv, "button#lane-12", "agent-12")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?lane=agent-27")

      assert has_element?(lv, "ol#timeline[data-isolate='agent-27']")
      assert has_element?(lv, "button#lane-27[aria-pressed='true']", "agent-27")
    end

    test "the run's connections page by fifty, denied first, and Showing x of y is true", %{
      conn: conn,
      scope: scope
    } do
      events =
        [{1, "run.started", started_data()}] ++
          for(n <- 1..120, do: {n + 1, "run.egress", egress_data(%{"host" => "h#{n}.example"})}) ++
          [
            {200, "run.egress",
             egress_data(%{
               "host" => "denied.example",
               "decision" => "denied",
               "outcome" => "refused",
               "rule" => ""
             })}
          ]

      run = projected(scope, events)

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      assert html =~ "Showing 50 of 121."

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#run-connections > tr")
             |> Enum.count() == 50

      assert has_element?(lv, "#run-connections > tr:first-child", "denied.example")
      assert html =~ "121"

      lv |> element("#connections-pages a", "Next") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network?page=2"
      )

      refute has_element?(lv, "#run-connections", "denied.example")

      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network?page=3"
        )

      assert html =~ "Showing 21 of 121."
      refute has_element?(lv, "#connections-pages a", "Next")

      # a page past the last is the last
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network?page=99&decision=denied"
        )

      assert has_element?(lv, "#decision button[aria-pressed='true']", "Denied")
      assert render(lv) =~ "Showing 1 of 1."
    end
  end

  describe "no Close" do
    test "no run page offers a Close, whatever opened the run, its credential and its state", %{
      conn: conn,
      scope: scope
    } do
      starts = [
        started_data(),
        started_data(%{"credential" => "issuer"}),
        Map.delete(started_data(), "credential"),
        gateway_started_data()
      ]

      runs =
        for data <- starts, state <- ~w(running lost) do
          run = projected(scope, [{1, "run.started", data}])
          if state == "lost", do: Apiary.Repo.update!(Ecto.Changeset.change(run, state: "lost"))
          run
        end

      for run <- [run_fixture(scope, %{state: "pending"}) | runs] do
        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

        assert has_element?(lv, ".q-run-actions #run-menu")
        refute has_element?(lv, "#close-run-button")
        refute has_element?(lv, "#close-run")
        refute html =~ "Close run"
      end
    end

    test "show_all and load_earlier on a page without a run do nothing", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, "#{workspace_path(scope)}/runs/#{Ecto.UUID.generate()}")

      assert render_hook(lv, "show_all", %{"seq" => "1"}) =~ "This run is not in this workspace"
      assert render_hook(lv, "load_earlier", %{}) =~ "This run is not in this workspace"
    end
  end

  describe "read aloud" do
    test "an item in a subagent's lane says whose it is in words", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#e-25 .sr-only", "in Explore -demo-a1")
      assert has_element?(lv, "#e-27 .sr-only", "in general-purpose -demo-a2")
      refute has_element?(lv, "#e-11 .sr-only", "in ")
    end

    test "earlier items are announced, and the list only says oldest first when it starts at the start",
         %{conn: conn, scope: scope} do
      events =
        [{1, "run.started", started_data()}] ++
          for(
            n <- 2..400,
            do: {n, "session.notification", %{"kind" => "k", "message" => "m#{n}"}}
          )

      run = projected(scope, events)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(
               lv,
               "ol#timeline[aria-label='Session timeline, in sequence order; 100 later events not loaded']"
             )

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=400")

      assert has_element?(
               lv,
               "ol#timeline[aria-label^='Session timeline, in sequence order; 100 earlier events not loaded']"
             )

      lv |> element("#timeline-earlier") |> render_click()
      assert has_element?(lv, "#run-announcer", "100 earlier events loaded.")
      assert has_element?(lv, "ol#timeline[aria-label='Session timeline, oldest first']")
    end

    test "the terminal offers the log as text and a polite place for a summary; xterm's reader mode is never on",
         %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert has_element?(
               lv,
               "#terminal a.sr-only[href$='/log?download=1']",
               "Read the log as text"
             )

      assert has_element?(lv, "#terminal [data-announce][aria-live='polite']")
      # one tab stop: xterm's own input, which the hook names with its keys
      refute has_element?(lv, "#terminal [data-screen][tabindex]")

      hook = File.read!(Path.expand("../../../../assets/js/hooks/terminal.js", __DIR__))
      assert hook =~ "screenReaderMode: false"
      refute hook =~ "screenReaderMode = "
      assert hook =~ "linkHandler"
    end
  end

  describe "a run with tools" do
    test "the timeline groups a tool's allowed calls under its name and lists the tools", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, tool_record())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      # the tools are listed on the policy applied, an item only where there is security
      if security?() do
        assert has_element?(lv, "#e-2-tools", "files")
        assert has_element?(lv, "#e-2-tools", "files.tools.internal")
      else
        refute has_element?(lv, "#e-2")
      end

      assert has_element?(lv, "#e-4-group .q-cx-sum .q-tool-name", "files")
      assert has_element?(lv, "#e-4-group .q-cx-sum", "2 allowed requests")
      refute render(element(lv, "#e-4-group .q-cx-sum")) =~ "calls"
      assert has_element?(lv, "#e-4-cx-4 .q-outcome", "Answered 200")
      assert has_element?(lv, "#e-4-cx-5 .q-outcome", "Answered 201")

      assert has_element?(
               lv,
               ~s(#e-4-cx-5 .q-dest[data-request-id="0a1b2c3d4e5f60718293a4b5c6d7e8f9"])
             )

      # The refused request is a denial of its own, never folded into the group, and names
      # the tool only as the one it did not reach.
      assert has_element?(lv, "#e-6-cx.q-cx-denied .q-dest", "files.tools.internal")
      refute has_element?(lv, "#e-6-cx .q-dest-tool")
      assert has_element?(lv, "#e-6-cx .q-for-tool", "files")
      assert has_element?(lv, "#e-3-cx .q-dest", "api.example.com")
      refute has_element?(lv, "#e-3-cx .q-dest-tool")
    end

    @tag needs: :security
    test "the policy in force names the tools and the hosts they serve", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, tool_record())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert has_element?(lv, "#policy-tools", "files (files.tools.internal)")

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied", tool_policy_data(%{"tools" => []})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert has_element?(lv, "#policy-tools", "none")
    end

    @tag needs: :security
    test "the policy in force shows a credential's and a tool's argument beside its name", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied",
           tool_policy_data(%{
             "credentials" => [
               %{
                 "name" => "forge-token",
                 "argument" => "acme/shop",
                 "hosts" => ["forge.example"],
                 "scheme" => "basic"
               },
               %{
                 "name" => "forge-token",
                 "argument" => "acme/shop",
                 "hosts" => ["api.forge.example", "forge.example"],
                 "scheme" => "bearer"
               },
               %{"name" => "model", "hosts" => ["api.model.example"], "scheme" => "header"},
               %{
                 "name" => "markup",
                 "argument" => "<b>acme</b>",
                 "hosts" => ["markup.example"],
                 "scheme" => "bearer"
               }
             ],
             "tools" => [
               %{
                 "name" => "files",
                 "argument" => "acme/shop",
                 "hosts" => ["files.tools.internal"]
               }
             ]
           })}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      # The uses of one credential show as one, its argument once, the hosts of every use.
      assert has_element?(
               lv,
               "#policy-credentials-0",
               "forge-token acme/shop (forge.example, api.forge.example)"
             )

      assert has_element?(lv, "#policy-credentials-0 code.q-rule", "acme/shop")
      assert has_element?(lv, "#policy-credentials-1", "model (api.model.example)")
      refute has_element?(lv, "#policy-credentials-1 code")
      assert has_element?(lv, "#policy-credentials-2 code", "<b>acme</b>")
      assert render(element(lv, "#policy-credentials-2 code")) =~ "&lt;b&gt;acme&lt;/b&gt;"
      refute has_element?(lv, "#policy-credentials-3")
      assert has_element?(lv, "#policy-tools-0", "files acme/shop (files.tools.internal)")
      assert has_element?(lv, "#policy-tools-0 code.q-rule", "acme/shop")
      refute has_element?(lv, "#policy-credentials", "more")

      # The timeline's policy applied item shows a tool's argument, and no credentials.
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#e-2-tools code.q-rule", "acme/shop")
      refute has_element?(lv, "#e-2", "forge-token")
    end

    @tag needs: :security
    test "the timeline shows a long tool argument cut short, and whole in its title", %{
      conn: conn,
      scope: scope
    } do
      argument = "acme/" <> String.duplicate("r", 95)

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied",
           tool_policy_data(%{
             "tools" => [
               %{"name" => "files", "argument" => argument, "hosts" => ["files.tools.internal"]}
             ]
           })}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      code = lv |> element("#e-2-tools code.q-rule") |> render() |> LazyHTML.from_fragment()
      assert LazyHTML.text(code) == String.slice(argument, 0, 64) <> "…"
      assert LazyHTML.attribute(code, "title") == [argument]
      assert has_element?(lv, "#e-2-tools", "files.tools.internal")

      # The Details tab shows it whole.
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert has_element?(lv, "#policy-tools-0 code.q-rule", argument)
    end

    @tag needs: :security
    test "the policy in force counts the credentials and tools past those it lists", %{
      conn: conn,
      scope: scope
    } do
      # Fifteen credentials of two uses each: the twenty uses read are ten credentials.
      uses =
        for n <- 1..15, host <- ["a", "b"] do
          %{"name" => "c#{n}", "argument" => "acme/r#{n}", "hosts" => ["#{host}#{n}.example"]}
        end

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied",
           tool_policy_data(%{
             "credentials" => uses,
             "tools" => for(n <- 1..21, do: %{"name" => "t#{n}", "hosts" => []})
           })}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert has_element?(lv, "#policy-credentials-0", "c1 acme/r1 (a1.example, b1.example)")
      assert has_element?(lv, "#policy-credentials-9")
      refute has_element?(lv, "#policy-credentials-10")
      assert has_element?(lv, "#policy-credentials", "and 5 more")
      assert has_element?(lv, "#policy-tools-19")
      assert has_element?(lv, "#policy-tools", "and 1 more")
    end
  end

  describe "how a run that ended badly ended" do
    test "the header says the result it ended with, and leads to it", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.result",
           %{"outcome" => "error", "result" => "I could not finish:\nthe tests still fail."}},
          {3, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-why", "I could not finish: the tests still fail.")
      # one cut line in the meta lines' box, which takes the column's width on a phone
      assert has_element?(lv, ".q-run-sub > .q-run-meta-wrap > #run-why > .q-run-why-t[title]")

      jump = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=2"
      assert has_element?(lv, ~s(#run-why-jump[href="#{jump}"]), "Jump to it")
    end

    test "a run that ended well says nothing more", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.result", %{"outcome" => "success", "result" => "done"}},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      refute has_element?(lv, "#run-why")
    end
  end

  # The terms of the rail's Run section, in order.
  defp run_terms(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#run-facts > dt")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp gateway_run(scope, exit) do
    projected(scope, [
      {1, "run.started", gateway_started_data()},
      {2, "run.egress", egress_data()},
      {3, "run.exited", exit}
    ])
  end

  describe "a run with no session" do
    setup %{scope: scope} do
      %{run: demo(scope, "no-session")}
    end

    test "the header: Cancelled and why, no runtime and no host", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-meta #run-state.q-sdot-ended", "Cancelled")
      assert has_element?(lv, "#run-meta #run-state + #run-reason", "no activity for 10 minutes")
      refute has_element?(lv, "#run-runtime")
      refute has_element?(lv, "#run-host")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#run-duration-line", "10 m 35 s")
      assert has_element?(lv, "#run-denied", "1 denied")

      # the tabs are a session run's
      for tab <- ~w(timeline terminal connections details),
          do: assert(has_element?(lv, "#run-tab-#{tab}"))
    end

    test "the timeline: started by a gateway, ended quiet on a neutral stop, and no notice", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#e-2", "Run started")
      assert has_element?(lv, "#e-2", "by a gateway with no session")
      refute html =~ "without a wall"

      assert has_element?(lv, "#e-10", "Run ended")
      assert has_element?(lv, "#e-10", "no activity for 10 minutes")
      assert has_element?(lv, "#e-10", "10 m 35 s")
      assert has_element?(lv, "#e-10 .hero-stop-micro")
      refute has_element?(lv, "#e-10 .hero-x-mark-micro")
      refute html =~ "Run exited"

      # the lane key and the switch stay; nothing says the run had no session here
      assert has_element?(lv, ".q-tl-bar", "Main session")
      assert has_element?(lv, "#toggle-connections", "Connections inline")
      refute html =~ "No session."
      refute has_element?(lv, "#run-timeline .q-limits")
    end

    test "the Terminal tab: the terminal, empty, with the note, its controls disabled", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert has_element?(lv, "#terminal[phx-hook='Terminal'][data-empty='true']")
      assert has_element?(lv, "#terminal-note.q-term-msg b", "No session.")

      assert has_element?(
               lv,
               "#terminal-note",
               "A gateway opened this run for a program that reports none, so there is no terminal output. Its connections are on the Network access tab."
             )

      refute html =~ "This run wrote no output"

      for control <- [
            "input[data-find]",
            "[data-follow]",
            "[data-wrap]",
            ~s([data-size-step="-1"]),
            ~s([data-size-step="1"]),
            "[data-download]"
          ] do
        assert has_element?(lv, "#terminal-bar #{control}[disabled]")
      end

      # nothing to download: no link to the log in the box
      refute has_element?(lv, "#terminal a[download]")
      # Focus stays
      assert has_element?(lv, "#terminal-bar [data-focus]:not([disabled])", "Focus")
      assert has_element?(lv, "#terminal .q-term-foot", "Ended")
      assert has_element?(lv, "#terminal .q-term-foot", "0 B")
      # no caption under the box
      refute has_element?(lv, ".q-term-note")
    end

    test "the Network access tab lists its connections", %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/network")

      assert has_element?(lv, "#run-connections", "api.example")
      assert has_element?(lv, "#run-connections", "metrics.example")
    end

    test "the Details: opened by a gateway, the Forager that reported it, no session's facts", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      assert has_element?(lv, "#run-facts .q-sdot-ended", "Cancelled")
      assert has_element?(lv, "#run-facts #rail-reason", "no activity for 10 minutes")
      assert has_element?(lv, "#run-opened-by", "gateway (no session)")
      assert has_element?(lv, "#run-forager", "0.10.0 · contract 1")

      terms = run_terms(lv)
      assert Enum.take(terms, 2) == ["State", "Opened by"]
      for term <- ["Started", "Duration", "Key", "Forager"], do: assert(term in terms)
      for term <- ["Exit", "Runtime", "Host", "Wall"], do: refute(term in terms)

      # the Forager row sits after Node and before Instance, where they are
      forager = Enum.find_index(terms, &(&1 == "Forager"))
      key = Enum.find_index(terms, &(&1 == "Key"))
      assert forager > key

      if node = Enum.find_index(terms, &(&1 == "Node")), do: assert(forager == node + 1)

      if instance = Enum.find_index(terms, &(&1 == "Instance")),
        do: assert(instance == forager + 1)

      # the Command section is gone, and the Session is none
      refute has_element?(lv, "#rail-command")
      refute html =~ "Arguments"
      assert html =~ ~r{<dt>Session</dt>\s*<dd class="font-mono">\s*none\s*</dd>}
    end

    test "every reason in words, after the state and under it", %{
      conn: conn,
      scope: scope
    } do
      for {exit, state, words} <- [
            {%{"reason" => "credential_expired"}, "ended", "permission to run expired"},
            {%{"reason" => "run_ended_at_issuer"}, "ended", "stopped, no outcome given"},
            {%{"reason" => "gateway_lost"}, "failed", "end not recorded"},
            {%{"reason" => "session_lost"}, "failed", "stopped responding"},
            {%{"reason" => "timeout"}, "timed_out", "time limit reached"}
          ] do
        run = gateway_run(scope, exit)

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

        assert has_element?(lv, "#run-meta #run-state.q-sdot-#{state}")
        assert has_element?(lv, "#run-reason", words)
        assert has_element?(lv, "#rail-reason", words)
        # a run with no session has no exit to show
        refute has_element?(lv, "#run-meta", "exit")
        refute "Exit" in run_terms(lv)
      end
    end

    test "an exit with the reason run_closed reads Failed, with no words", %{
      conn: conn,
      scope: scope
    } do
      run = gateway_run(scope, %{"reason" => "run_closed"})

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")
      refute has_element?(lv, "#run-reason")
      refute has_element?(lv, "#rail-reason")
    end

    test "the timeline's last item: Run ended for an end that is no failure, Run exited else", %{
      conn: conn,
      scope: scope
    } do
      for {reason, kind, words, glyph} <- [
            {"credential_expired", "Run ended", "permission to run expired", "hero-stop-micro"},
            {"run_ended_at_issuer", "Run ended", "stopped, no outcome given", "hero-stop-micro"},
            {"gateway_lost", "Run exited", "end not recorded", "hero-x-mark-micro"},
            {"timeout", "Run exited", "time limit reached", "hero-x-mark-micro"}
          ] do
        run = gateway_run(scope, %{"reason" => reason, "duration_ms" => 95_000})

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

        assert has_element?(lv, "#e-3", kind)
        assert has_element?(lv, "#e-3", words)
        assert has_element?(lv, "#e-3", "1 m 35 s")
        assert has_element?(lv, "#e-3 .#{glyph}")
      end
    end

    test "a run credential that could not be checked: Failed, and why after it, under it and in the timeline",
         %{conn: conn, scope: scope} do
      for {reason, words} <- [
            {"issuer_unreachable", "couldn't check whether the run may go on: no answer"},
            {"issuer_answer_invalid",
             "couldn't check whether the run may go on: unreadable answer"}
          ] do
        run = gateway_run(scope, %{"reason" => reason, "duration_ms" => 130_000})
        assert run.state == "failed"

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

        assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")
        assert has_element?(lv, "#run-meta #run-state + #run-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
        assert has_element?(lv, "#run-facts #rail-reason", words)
        refute "Exit" in run_terms(lv)
        assert has_element?(lv, "#e-3", "Run exited")
        assert has_element?(lv, "#e-3", words)
        assert has_element?(lv, "#e-3", "2 m 10 s")
        refute has_element?(lv, "#e-3", "n/a")
        assert has_element?(lv, "#e-3 .hero-x-mark-micro")
      end
    end
  end

  describe "a run with a session, beside one with none" do
    test "its page is as it was; the reason's words stand under the state", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "timed-out")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      # timed out: Cancelled, the words after it on the meta line and under it in the rail, and
      # no exit beside them
      assert has_element?(lv, "#run-meta #run-state.q-sdot-timed_out", "Cancelled")
      assert has_element?(lv, "#run-meta #run-state + #run-reason", "time limit reached")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#run-facts #rail-reason", "time limit reached")
      assert has_element?(lv, "#run-runtime")
      assert html =~ "Run exited"
      refute html =~ "by a gateway with no session"

      terms = run_terms(lv)
      for term <- ["Exit", "Runtime", "Host", "Wall"], do: assert(term in terms)
      refute "Opened by" in terms
      refute "Forager" in terms
      refute has_element?(lv, "#run-opened-by")
      assert has_element?(lv, "#rail-command")
      assert has_element?(lv, "#rail-command + dl", "Forager")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert has_element?(lv, "#terminal[data-empty='false']")
      refute has_element?(lv, "#terminal-note")
      refute has_element?(lv, "#terminal-bar [disabled]:not([data-size-step])")
      assert has_element?(lv, "#terminal a[download]")
      assert has_element?(lv, ".q-term-note")
    end

    test "a session's lost gateway is said once on the meta line, and its exit is in the rail",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "failed", "exit_code" => -1, "reason" => "gateway_lost"}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-meta #run-state", "Failed")
      assert has_element?(lv, "#run-reason", "end not recorded")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#rail-reason", "end not recorded")
      assert "Exit" in run_terms(lv)
      refute has_element?(lv, "#run-opened-by")
      assert has_element?(lv, ".q-run-rail", "n/a")

      # with no output, it says so, as before
      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      assert html =~ "This run wrote no output"
      refute html =~ "No session."
    end

    test "a lost session is said once on the meta line, and as its exit in the rail and timeline",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "failed", "exit_code" => -1, "reason" => "session_lost"}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(lv, "#run-meta #run-state", "Failed")
      assert has_element?(lv, "#run-reason", "stopped responding")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#rail-reason", "stopped responding")
      assert "Exit" in run_terms(lv)
      assert html =~ ~r{<dt>Exit</dt>\s*<dd class="font-mono">\s*session lost\s*</dd>}
      assert has_element?(lv, "#e-2", "Run exited")
      assert has_element?(lv, "#e-2", "stopped responding")
      refute html =~ "exit -1"
    end

    test "an expired run credential or the starter's end is said after the state, under it and in the timeline",
         %{conn: conn, scope: scope} do
      for {reason, words, exit_row} <- [
            {"credential_expired", "permission to run expired", "run credential expired"},
            {"run_ended_at_issuer", "stopped, no outcome given",
             "the issuer reported the run ended"}
          ] do
        run =
          projected(scope, [
            {1, "run.started", started_data()},
            {2, "run.exited", %{"state" => "failed", "exit_code" => -1, "reason" => reason}}
          ])

        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

        assert has_element?(lv, "#run-meta #run-state", "Failed")
        assert has_element?(lv, "#run-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
        assert has_element?(lv, "#rail-reason", words)
        assert "Exit" in run_terms(lv)
        assert html =~ ~r{<dt>Exit</dt>\s*<dd class="font-mono">\s*#{exit_row}\s*</dd>}
        assert has_element?(lv, "#e-2", "Run ended")
        assert has_element?(lv, "#e-2", words)
        refute html =~ "exit -1"
      end
    end

    test "a run credential that could not be checked is said after the state, under it and in the timeline, and it is Failed",
         %{conn: conn, scope: scope} do
      for {reason, words, exit_row} <- [
            {"issuer_unreachable", "couldn't check whether the run may go on: no answer",
             "issuer unreachable"},
            {"issuer_answer_invalid",
             "couldn't check whether the run may go on: unreadable answer",
             "issuer answer invalid"}
          ] do
        exit = %{
          "state" => "failed",
          "exit_code" => -1,
          "signal" => "SIGTERM",
          "reason" => reason,
          "duration_ms" => 130_000
        }

        run = projected(scope, [{1, "run.started", started_data()}, {2, "run.exited", exit}])
        assert run.state == "failed"

        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

        assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")
        assert has_element?(lv, "#run-meta #run-state + #run-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
        assert has_element?(lv, "#run-facts #rail-reason", words)
        assert "Exit" in run_terms(lv)
        assert html =~ ~r{<dt>Exit</dt>\s*<dd class="font-mono">\s*#{exit_row}\s*</dd>}
        assert has_element?(lv, "#e-2", "Run exited")
        assert has_element?(lv, "#e-2", words)
        assert has_element?(lv, "#e-2", "2 m 10 s")
        refute has_element?(lv, "#e-2", "SIGTERM")
        refute html =~ "exit -1"
      end
    end
  end
end
