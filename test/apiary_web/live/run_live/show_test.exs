defmodule ApiaryWeb.RunLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
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

  # The registration fields of a run that registered, with `attrs`, as
  # `Apiary.Runs.Registration` stores them: projected from sequence 1.
  defp registered(attrs) do
    Map.merge(
      %{
        projected_sequence: 1,
        registered_at: DateTime.utc_now(),
        registration_labels: %{},
        registration_about: %{},
        registration_digest: :crypto.hash(:sha256, "registration"),
        registration_interval_seconds: 30,
        registration_answer_digest: Apiary.Policy.Render.digest(~s({"version":1}))
      },
      attrs
    )
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

  # Opens the Timeline's subagents whose starts have these sequences: a finished one is
  # closed on the page until the reader opens it.
  defp open_subagents(lv, seqs) do
    for seq <- seqs, do: lv |> element("#e-#{seq} .q-sub-caret") |> render_click()
    render(lv)
  end

  setup :register_and_log_in_user

  describe "not found" do
    test "a run of another workspace, an unknown id and a malformed id render the same state", %{
      conn: conn,
      scope: scope
    } do
      theirs = projected(scope_fixture(), record())

      for id <- [
            theirs.number,
            theirs.number + 1_000_000,
            theirs.public_id,
            theirs.node_run_id,
            theirs.id,
            Ecto.UUID.generate(),
            "0191f2a4"
          ],
          path <- ["", "/terminal", "/network", "/details"] do
        {:ok, _lv, html} = live(conn, "#{workspace_path(scope)}/runs/#{id}#{path}")
        assert html =~ "This run is not in this workspace"
        assert html =~ "Back to runs"
        refute html =~ "dev-laptop"
      end
    end

    test "an old address, by the node's run id, is not found and sends nowhere", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, record())
      old = "#{workspace_path(scope)}/runs/#{run.node_run_id}"

      for path <- ["", "/terminal", "/network", "/details"] do
        assert {:ok, _lv, html} = live(conn, old <> path)
        assert html =~ "This run is not in this workspace"
        refute html =~ "dev-laptop"
      end

      page = get(conn, old)
      refute page.status in 300..399
      assert get_resp_header(page, "location") == []
      assert page.resp_body =~ "This run is not in this workspace"
      assert response(get(conn, old <> "/log"), 404)
    end

    test "an address whose id is 16 bytes that are not UTF-8 is not found", %{
      conn: conn,
      scope: scope
    } do
      # `%FF` decodes to the byte 0xFF: with the 15 characters after it, 16 bytes after `rn_`.
      address = "#{workspace_path(scope)}/runs/rn_%FF123456789abcdef"

      for path <- ["", "/terminal", "/network", "/details"] do
        assert {:ok, _lv, html} = live(conn, address <> path)
        assert html =~ "This run is not in this workspace"
      end

      page = get(conn, address)
      assert page.status == 200
      assert page.resp_body =~ "This run is not in this workspace"
    end

    test "the breadcrumb leads to Runs, then names the run asked for when it is a number",
         %{conn: conn, scope: scope} do
      runs = workspace_path(scope, "/runs")

      {:ok, lv, _html} = live(conn, "#{runs}/99999999")
      assert crumbs(lv) == [{"Runs", runs}, {"Run 99999999", nil}]
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Run 99999999")
      assert render(lv) =~ "or the run number is mistyped"

      # An address that is no run's number names no run: an `rn_` id of no run of the
      # workspace, a leading zero and the node's run id are none.
      for other <- [Apiary.Runs.Run.new_public_id(), "014", "0191f2a4", Ecto.UUID.generate()] do
        {:ok, lv, _html} = live(conn, "#{runs}/#{other}")
        assert crumbs(lv) == [{"Runs", runs}]
      end
    end

    test "one number in two workspaces: each address shows the run of its workspace", %{
      conn: conn,
      scope: scope
    } do
      ours = projected(scope, record())
      other = scope_fixture()
      theirs = projected(other, record())
      assert ours.number == theirs.number

      # Each address is read by a member of its workspace.
      {:ok, _lv, html} = live(conn, "#{workspace_path(scope)}/runs/#{ours.number}/details")
      assert html =~ ours.public_id
      refute html =~ theirs.public_id

      theirs_conn = log_in_user(build_conn(), other.user)

      {:ok, _lv, html} =
        live(theirs_conn, "#{workspace_path(other)}/runs/#{theirs.number}/details")

      assert html =~ theirs.public_id
      refute html =~ ours.public_id
    end

    test "a number of no run and the number of another workspace's run render the same page",
         %{conn: conn, scope: scope} do
      # Two runs there, so the second's number is one this workspace, with one run, has not.
      other = scope_fixture()
      projected(other, record())
      theirs = projected(other, record())
      projected(scope, record())
      assert theirs.number == 2
      missing = 3
      address = &"#{workspace_path(scope)}/runs/#{&1}"

      # The page names the number it was asked by, and nothing else differs.
      same = fn number ->
        conn
        |> get(address.(number))
        |> html_response(200)
        |> String.replace("Run #{number}", "Run N")
        |> String.replace("/runs/#{number}", "/runs/N")
        |> String.replace(~r/csrf-token" content="[^"]*"/, "")
        |> String.replace(~r/data-phx-(session|static|id)="[^"]*"/, "")
        |> String.replace(~r/data-csrf="[^"]*"/, "")
        |> String.replace(~r/(name="_csrf_token"[^>]*value=")[^"]*"/, "\\1")
        |> String.replace(~r/nonce="[^"]*"/, "")
        |> String.replace(~r/id="phx-[^"]*"/, "")
      end

      {ours, none} = {same.(theirs.number), same.(missing)}
      # On a failure, only the parts that differ.
      assert ours == none,
             inspect(for {op, s} <- String.myers_difference(ours, none), op != :eq, do: {op, s})
    end

    test "the run's rn_ address in this workspace sends on to its number, with its tab and query",
         %{conn: conn, scope: scope} do
      run = projected(scope, record())
      path = workspace_path(scope, "/runs")

      # Percent-encoded too: the router decodes `rn%5F…` to the same id.
      encoded = String.replace(run.public_id, "_", "%5F")

      for id <- [run.public_id, encoded], tab <- ["", "/terminal", "/network"] do
        assert {:error, {:live_redirect, %{to: to}}} = live(conn, "#{path}/#{id}#{tab}?cx=0")
        assert to == "#{path}/#{run.number}#{tab}?cx=0"
      end
    end

    test "signed out, the page redirects to the log-in page", %{scope: scope} do
      conn = build_conn()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, "#{workspace_path(scope)}/runs/#{Ecto.UUID.generate()}")
    end
  end

  describe "Policy in Details" do
    @tag :feature_sets
    test "a run with no policy event has no Policy and no Policy in force; one with it has both",
         %{conn: conn, scope: scope} do
      without = projected(scope, [{1, "run.started", started_data()}])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{without.number}")

      refute has_element?(lv, "#run-facts dt", "Policy")
      refute has_element?(lv, "#rail-policy")

      with_policy = projected(scope, Enum.take(record(), 4))

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{with_policy.number}")

      assert has_element?(lv, "#run-facts dt", "Policy") == security?()
      assert has_element?(lv, "#rail-policy", "Policy in force") == security?()
    end
  end

  describe "the header (U6)" do
    @tag :feature_sets
    test "two lines: the title, then the state and the run's facts; the rest is the rail's", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      %{public_id: target_id} = Apiary.Repo.get!(Apiary.Runs.Target, run.target_id)
      target = workspace_path(scope, "/targets/#{target_id}")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # the title alone on its line
      assert has_element?(lv, "h1#run-title", ApiaryWeb.RunComponents.run_title(run))

      # the meta line: the state as a dot and its word, the target's page, runtime, host,
      # when it started, how long it took, its denials, which lead to its connections
      assert has_element?(lv, "#run-meta #run-state.q-sdot-completed", "Completed")
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
               ~s(#run-denied[href="#{workspace_path(scope)}/runs/#{run.number}/network?decision=denied"]),
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
               {"Run #{run.number}", nil}
             ]

      assert has_element?(
               lv,
               "#breadcrumb [aria-current='page']",
               "Run #{run.number}"
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

      # three tabs with their counts; Details is beside them, never a tab
      assert has_element?(lv, "#run-tab a#run-tab-timeline[aria-current='page']", "Timeline")

      # The Timeline's count is the rows it lists, every subagent open; the policy applied is
      # a row only where the instance has security.
      items =
        scope
        |> Apiary.Runs.Record.timeline(Runs.get_run!(scope, run.id))
        |> Map.fetch!(:items)
        |> Enum.reject(&(&1.kind == :policy_applied and not security?()))

      assert has_element?(
               lv,
               "#run-tab a .q-tabs-n",
               "#{length(Apiary.Runs.Record.Overview.list(items))}"
             )

      assert has_element?(lv, "#run-tab a .q-tabs-n.q-tabs-bad", "2 denied")
      refute has_element?(lv, "#run-tab-details")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("nav#run-tab > a")
             |> Enum.map(&LazyHTML.attribute(&1, "id"))
             |> List.flatten() == ~w(run-tab-timeline run-tab-terminal run-tab-connections)
    end

    test "the more menu copies the run id and offers the log, to a reader of the log", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      log = "#{workspace_path(scope)}/runs/#{run.number}/log"

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-menu[phx-hook='Menu'] #run-menu-button[aria-haspopup='menu']")

      assert has_element?(
               lv,
               ~s(#run-menu-copy[phx-hook="CopyToClipboard"][data-copy="#{run.public_id}"])
             )

      assert has_element?(lv, ~s(#run-menu-raw[href="#{log}"][target="_blank"]), "Raw log")
      assert has_element?(lv, ~s(#run-menu-download[href="#{log}?download=1"][download]))

      # Copy diagnostics, beside Copy run id: the hook reads the run's document and copies it.
      diagnostics = "#{workspace_path(scope)}/runs/#{run.number}/diagnostics"

      assert has_element?(
               lv,
               ~s(#run-menu-diagnostics[phx-hook="CopyToClipboard"][data-copy-url="#{diagnostics}"]),
               "Copy diagnostics"
             )

      # The line a failed copy writes is outside the menu, empty until a copy fails.
      assert lv |> element("#run-menu-status[role=status]") |> render() =~
               ~r{\A<p[^>]*></p>\z}

      refute has_element?(lv, "#run-menu-diagnostics [aria-live]")
      assert has_element?(lv, ~s(#run-menu-diagnostics[data-status="#run-menu-status"]))

      # A line for each way the copy can fail, which the hook writes there instead.
      for {cause, line} <- [
            {"network",
             "Check your connection, then copy again. The diagnostics did not arrive."},
            {"gone",
             "Reload the page, then copy again. This run, or your access to its log, is gone."},
            {"signed-out", "Sign in again, then copy again. Your session ended."},
            {"server",
             "Copy again in a minute. If it fails again, contact support with run " <>
               "#{run.public_id}. Qory Apiary could not build the diagnostics."},
            {"clipboard",
             "Allow this page to use the clipboard, then copy again. " <>
               "The browser did not allow the copy."}
          ] do
        assert has_element?(lv, ~s(#run-menu-diagnostics[data-failed-#{cause}="#{line}"])),
               cause
      end

      ids =
        lv
        |> element("#run-menu ul")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li > [id]")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert ["run-menu-copy", "run-menu-diagnostics" | _] = ids
    end

    test "Details is beside every tab, Terminal too", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      # what the page's CSS keys on: one Details element on every tab, after the header
      # and its button, before the tabs; no wide tab and no Details tab
      for tab <- ["", "/terminal", "/network"] do
        {:ok, lv, html} = live(conn, path <> tab)
        assert has_element?(lv, "#run-page > #run-details")
        refute has_element?(lv, ".q-run-wide")
        refute has_element?(lv, ".q-run-on-details")
        refute has_element?(lv, "#run-tab-details")

        assert has_element?(
                 lv,
                 ~s(#run-page > button#run-details-toggle[type="button"][aria-controls="run-details"][aria-expanded="false"]),
                 "Details"
               )

        assert html
               |> LazyHTML.from_document()
               |> LazyHTML.query("#run-page > *")
               |> Enum.map(&LazyHTML.attribute(&1, "id"))
               |> Enum.map(&List.first/1) ==
                 [nil, "run-details-toggle", "run-details", "run-tab", nil]

        assert has_element?(lv, "#run-page > header.q-run-head")

        assert has_element?(
                 lv,
                 "#run-page > header + #run-details-toggle + #run-details + nav#run-tab"
               )
      end

      # a patch to another tab keeps the one element and the button's state
      {:ok, lv, _html} = live(conn, path <> "/terminal")
      lv |> element("#run-tab-timeline") |> render_click()
      assert has_element?(lv, "#run-tab-timeline[aria-current='page']")
      assert has_element?(lv, "#run-page > #run-details")
      assert has_element?(lv, "#run-details-toggle[aria-expanded='false']")
    end

    test "the Details button opens Details in place and Escape closes it", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      toggle =
        lv |> element("#run-details-toggle") |> render() |> LazyHTML.from_fragment()

      # the button toggles itself; Escape on it closes it and keeps the focus on it
      assert toggle |> LazyHTML.attribute("phx-click") |> hd() |> Jason.decode!() ==
               [["toggle_attr", %{"attr" => ["aria-expanded", "true", "false"]}]]

      assert LazyHTML.attribute(toggle, "phx-key") == ["Escape"]

      assert toggle |> LazyHTML.attribute("phx-keydown") |> hd() |> Jason.decode!() == [
               [
                 "set_attr",
                 %{"attr" => ["aria-expanded", "false"], "to" => "#run-details-toggle"}
               ],
               ["focus", %{"to" => "#run-details-toggle"}]
             ]
    end

    test "an old Details link lands on the Timeline with Details open", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, lv, _html} = live(conn, path <> "/details")

      # The address is the Timeline's: the patch is made while the page joins, so the
      # LiveView itself says where it is (the test client drops a join's patch).
      assert :sys.get_state(lv.pid).socket.assigns.live_action == :timeline
      assert has_element?(lv, "#run-tab-timeline[aria-current='page']")
      refute has_element?(lv, "#run-tab-details")
      assert has_element?(lv, "#run-details-toggle[aria-expanded='true']")
      assert has_element?(lv, "#run-timeline")

      for section <- ~w(rail-run rail-labels rail-command rail-record),
          do: assert(has_element?(lv, "#run-details ##{section}"))

      assert has_element?(lv, "#run-details dt", "Run id")
      assert has_element?(lv, "#run-id", run.public_id)
      assert has_element?(lv, "#copy-run-id[aria-label='Copy the run id']")
      assert has_element?(lv, "#run-menu-copy[data-copy='#{run.public_id}']", "Copy run id")
      assert has_element?(lv, "#run-details dt", "Run id on the machine")
      assert has_element?(lv, "#run-details dd#run-node-run-id", run.node_run_id)
      refute page_title(lv) =~ "Details ·"
      assert page_title(lv) == "#{ApiaryWeb.RunComponents.run_title(run)} · Runs · Qory Apiary"

      # Details stays open across the tabs
      lv |> element("#run-tab-terminal") |> render_click()
      assert has_element?(lv, "#run-details-toggle[aria-expanded='true']")
    end

    test "a run's page ends a narrowing: the sidebar's Runs and Network access lead plainly", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      for tab <- ["", "/terminal", "/network"] do
        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}" <> tab)

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{other.number}")

      assert has_element?(lv, "#run-target .q-tname-sys", "github.example")

      # Its link lands on its page, by its public id.
      page = target_page_path(scope, "github.example", "acme/shop")
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{titled.number}")

      # The header names the run by its number; the title it gave is the line under it.
      assert has_element?(lv, "h1#run-title", "Run #{titled.number}")
      refute has_element?(lv, "h1#run-title", "Fix the login redirect")
      assert has_element?(lv, "#run-given-title", "Fix the login redirect")
      assert page_title(lv) == "Run #{titled.number} · Runs · Qory Apiary"
      assert has_element?(lv, "#run-labels dd", "fix-login")
      refute has_element?(lv, "#run-labels a")

      untitled = projected(scope, [{1, "run.started", started_data(%{"labels" => labels})}])

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{untitled.number}/terminal"
        )

      assert has_element?(lv, "h1#run-title", "Run #{untitled.number}")
      refute has_element?(lv, "#run-given-title")
      refute has_element?(lv, "h1#run-title", "fix-login")
      assert page_title(lv) == "Terminal · Run #{untitled.number} · Runs · Qory Apiary"
      assert has_element?(lv, "#run-details #run-labels dd", "fix-login")
    end

    test "a run without a title is titled by its number, and one without a wall says None", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(%{"labels" => %{}})}])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "h1#run-title", "Run #{run.number}")
      assert html =~ "This run had no wall"
      refute has_element?(lv, "#run-labels")
      # unassigned: the meta line names no target, and the breadcrumb is Runs and the run
      refute has_element?(lv, "#run-target")

      assert crumbs(lv) == [
               {"Runs", workspace_path(scope, "/runs")},
               {"Run #{run.number}", nil}
             ]
    end

    test "the run's crumb is the page on the Timeline and a link to it on the other tabs", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(%{"labels" => %{}})}])
      timeline = workspace_path(scope, "/runs/#{run.number}")
      short = "Run #{run.number}"

      {:ok, lv, _html} = live(conn, timeline)
      assert crumbs(lv) == [{"Runs", workspace_path(scope, "/runs")}, {short, nil}]

      for tab <- ["/terminal", "/network"] do
        {:ok, lv, _html} = live(conn, timeline <> tab)
        assert crumbs(lv) == [{"Runs", workspace_path(scope, "/runs")}, {short, timeline}]
        # A tab of the same page: the way back is a patch, as the tabs are.
        assert has_element?(lv, "#breadcrumb a[href='#{timeline}'][data-phx-link=patch]")
      end
    end

    test "a pending run says Registered only and waits on every tab", %{
      conn: conn,
      scope: scope
    } do
      # A run that registered and posted nothing.
      run = projected(scope, [], registered(%{forager_version: "0.10.0"}))

      for path <- ["", "/terminal", "/network"] do
        {:ok, _lv, html} = live(conn, "#{workspace_path(scope)}/runs/#{run.number}#{path}")
        assert html =~ "Registered only"
        refute html =~ "Ping only"
        assert html =~ "Waiting for the run to start"
        assert html =~ "The run is registered. Its first event has not arrived."
        refute html =~ "Forager has pinged."
      end
    end

    test "a pending run stored before the registration, which only pinged, says Ping only", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [{1, "ping", %{"forager_version" => "0.10.0", "contract_version" => 1}}])

      assert run.registered_at == nil

      for path <- ["", "/terminal", "/network"] do
        {:ok, _lv, html} = live(conn, "#{workspace_path(scope)}/runs/#{run.number}#{path}")
        assert html =~ "Ping only"
        refute html =~ "Registered only"
        assert html =~ "Waiting for the run to start"
        assert html =~ "Forager has pinged. The run&#39;s first event has not arrived."
        refute html =~ "The run is registered."
      end
    end

    test "a registered run's events are counted from its sequence 2, a batch-created run's from 1",
         %{conn: conn, scope: scope} do
      page = &live(conn, "#{workspace_path(scope)}/runs/#{&1.number}")

      # Registered, nothing projected: as any run with nothing projected.
      run = projected(scope, [], registered(%{forager_version: "0.10.0"}))
      assert run.projected_sequence == 1
      {:ok, _lv, html} = page.(run)
      assert html =~ ~r/projected through <span[^>]*>#0000</
      refute html =~ "Last event #"

      # Two events stored and not read yet: two, by either kind of run.
      started = %{"opened_by" => "session", "forager_version" => "0.10.0"}
      running = %{state: "running", started_at: DateTime.utc_now(), event_count: 2}

      for {attrs, first} <- [{registered(running), 2}, {running, 1}] do
        run = run_fixture(scope, attrs)

        events_fixture(run, [
          {first, "run.started", started},
          {first + 1, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30}}
        ])

        {:ok, _lv, html} = page.(run)
        assert html =~ "2 events have arrived and are being read.", inspect(first)

        # Once read, none is left, and the record is projected through its last.
        {:ok, run} = Projector.project(run)
        assert run.projected_sequence == first + 1
        {:ok, _lv, html} = page.(run)
        refute html =~ "have arrived and are being read."
        assert html =~ ~r/projected through <span[^>]*>#000#{first + 1}</
      end
    end

    # `quiet_for/2` counts from `inserted_at` for a run with no heartbeat, and such a run
    # may have no event either.
    test "quiet with no heartbeat and no event: the page counts from when the run was heard of",
         %{conn: conn, scope: scope} do
      long_ago = DateTime.add(DateTime.utc_now(), -47, :second)
      run = run_fixture(scope, %{state: "running", inserted_at: long_ago})
      assert is_nil(run.last_heartbeat_at) and is_nil(run.last_event_at)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert lv |> element("#run-alive") |> render() =~ "No heartbeat for"
      assert has_element?(lv, "#run-alive.q-alive-amber")
    end

    # The state's dot and the alive line show one state: pulsed is alive, amber and still is
    # quiet, in the header and in the rail.
    test "the state's dot: quiet is amber and still, alive pulses, by the same run", %{
      conn: conn,
      scope: scope
    } do
      now = DateTime.utc_now()
      alive = run_fixture(scope, %{state: "running", last_heartbeat_at: now, inserted_at: now})
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{alive.number}"
      {:ok, lv, _html} = live(conn, path)

      for place <- ["#run-state", "#run-facts .q-sdot-running"] do
        assert has_element?(lv, "#{place} > i")
        refute has_element?(lv, "#{place} .q-dot")
      end

      refute has_element?(lv, "#run-alive.q-alive-amber")

      # The heartbeat is late: the page changes with no reload.
      old = DateTime.add(now, -47, :second)

      alive
      |> Ecto.Changeset.change(last_heartbeat_at: old)
      |> Repo.update!()
      |> Runs.broadcast_changed()

      assert has_element?(lv, "#run-alive.q-alive-amber")

      for place <- ["#run-state", "#run-facts .q-sdot-running"] do
        assert has_element?(lv, "#{place} > .q-dot.q-alive-amber")
        refute has_element?(lv, "#{place} > i")
        refute has_element?(lv, "#{place} .q-ripple")
        assert lv |> element(place) |> render() =~ "Running"
      end
    end

    test "the state's dot of a pending or ended run stays as it is", %{conn: conn, scope: scope} do
      for state <- ["pending", "failed"] do
        run =
          run_fixture(scope, %{
            state: state,
            inserted_at: DateTime.add(DateTime.utc_now(), -47, :second)
          })

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-facts .q-sdot-#{state} > i")
        refute has_element?(lv, "#run-facts .q-sdot .q-dot")
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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

    @tag :feature_sets
    test "every kind of item, in sequence order", %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      html = open_subagents(lv, [22, 23])
      ids = item_ids(html)
      assert hd(ids) == "e-2"
      assert List.last(ids) == "e-103"
      # The Main session row follows the main agent's prompt; every other row is an event's.
      assert ids |> Enum.drop_while(&(&1 != "e-9")) |> Enum.take(2) == ["e-9", "main-session"]
      numbered = List.delete(ids, "main-session")
      assert numbered == Enum.sort_by(numbered, fn "e-" <> n -> String.to_integer(n) end)
      assert has_element?(lv, "#e-22 .q-sub-said .q-k", "Explore")

      for words <- [
            "Run started",
            "Session started",
            "Prompt",
            "Subagent finished",
            "Notification",
            "Turn finished",
            "Result",
            "Session ended",
            "Run ended"
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
      assert html =~ "success · 14 turns · $0.84"
      assert has_element?(lv, "#e-98 .q-tct", "3 m 49 s")
      assert html =~ "exit 0"
      assert html =~ "End of the record. 102 events."
      assert has_element?(lv, "ol#timeline[aria-label='Session timeline, oldest first']")
      refute html =~ "aria-live=\"polite\" id=\"timeline\""
    end

    test "three lanes with a key, a who chip where a lane opens and closes", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "button.q-lanekey.q-lane-main", "Main session")
      assert has_element?(lv, "button.q-lanekey.q-lane-a", "Explore")
      assert has_element?(lv, "button.q-lanekey.q-lane-b", "general-purpose")
      assert html =~ "agent-demo-a1"
      assert has_element?(lv, "ol.q-lanes-3")
      open_subagents(lv, [22, 23])

      # start and finish brackets
      assert has_element?(lv, "#e-22 .q-r.q-rail-1.q-r-from")
      assert has_element?(lv, "#e-22 .q-h.q-rail-1.q-lane-a")
      assert has_element?(lv, "#e-37 .q-who.q-lane-a", "Explore")
      assert has_element?(lv, "#e-37 .q-r.q-rail-1.q-r-to")
      assert has_element?(lv, "#e-23 .q-r.q-rail-2.q-r-from")
      assert has_element?(lv, "#e-50 .q-r.q-rail-2.q-r-to")

      # a subagent's finish sits on the subagent's rail, with the other subagent's passing;
      # its routine calls are in the Terminal only
      assert has_element?(lv, "#e-37 .q-n.q-rail-1.q-lane-a")
      assert has_element?(lv, "#e-37 .q-r.q-rail-2")
      assert has_element?(lv, "#e-37[data-lane='agent-demo-a1']")
      refute has_element?(lv, "#e-26")
    end

    test "a tool pairs its events: summary, duration, input and response; a failed one starts open",
         %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # A call with a connection inside is listed; a routine call is in the Terminal only.
      refute has_element?(lv, "#e-12")
      assert has_element?(lv, "#e-65 summary .q-k", "Bash")
      # Recorded before Forager sent summaries: the tool alone, never words made from its input.
      refute has_element?(lv, "#e-65 summary .q-s", "npm install")
      assert has_element?(lv, "#e-65 .q-well", "input")
      assert has_element?(lv, "#e-65 .q-well", "stdout")
      assert has_element?(lv, "#e-65 .q-well .q-key", "\"command\"")
      refute has_element?(lv, "#e-65 details[open]")
      # the end of a call is not a separate item
      refute has_element?(lv, "#e-70")

      assert has_element?(lv, "#e-59 details[open]")
      assert has_element?(lv, "#e-59 summary .q-bad", "Failed")
      assert has_element?(lv, "#e-59 .q-n.q-n-fail")
      assert has_element?(lv, "#e-59 .q-well.q-well-err", "error")
    end

    @tag :feature_sets
    test "a connection sits inside a call only when exactly one was open, and says while", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      # Allowed connections outside a call are rows with Connections inline on.
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1")

      assert has_element?(lv, "#e-59 .q-during", "1 connection while this call was open")
      assert has_element?(lv, "#e-59 .q-during .q-cx-denied", "registry.example")

      assert has_element?(
               lv,
               "#e-59 .q-during",
               if(security?(), do: "No rule matches", else: "Denied.")
             )

      refute has_element?(lv, "#e-60")

      # between items while the two Task calls were open, with the caption, and no node
      assert html =~ "while 2 calls were open"
      assert has_element?(lv, "#e-7.q-ti-cx")
      refute has_element?(lv, "#e-7 .q-n")

      refute has_element?(lv, "#timeline", "because")
    end

    test "?seq= targets the item that holds the event; an unknown one is dropped from the URL", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=60")

      assert has_element?(lv, "ol#timeline[data-target='e-59']")

      # what is not valid is dropped: the page is the plain one, and its links carry none of it.
      # The unknown sequence has 10 digits, the most the page parses: a short one such as 99999
      # can occur in the page's generated numbers (fixture names, user emails, microseconds).
      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=8642097531&lane=nobody&cx=7&x=1"
        )

      refute has_element?(lv, "ol#timeline[data-target]")
      refute has_element?(lv, "ol#timeline[data-isolate]")
      assert has_element?(lv, "ol#timeline[data-cx='0']")
      refute html =~ "nobody"
      refute html =~ "8642097531"

      # a valid one among them is kept
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=59&x=1")

      assert has_element?(lv, "ol#timeline[data-target='e-59']")
    end

    test "?lane= isolates a lane and ?cx=1 shows the allowed connections; both toggles patch", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      lv |> element("button.q-lanekey.q-lane-a") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?lane=agent-demo-a1"
      )

      assert has_element?(lv, "ol#timeline[data-isolate='agent-demo-a1']")
      assert has_element?(lv, "button.q-lanekey.q-lane-a[aria-pressed='true']")
      assert has_element?(lv, "button.q-lanekey.q-lane-b[aria-pressed='false']")

      assert has_element?(
               lv,
               "#toggle-connections[aria-pressed='false'] .q-toggle:not([data-on])"
             )

      lv |> element("#toggle-connections") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1&lane=agent-demo-a1"
      )

      assert has_element?(lv, "ol#timeline[data-cx='1']")
      assert has_element?(lv, "#toggle-connections[aria-pressed='true'] .q-toggle[data-on]")

      lv |> element("button.q-lanekey.q-lane-a") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1")
      refute has_element?(lv, "ol#timeline[data-isolate]")
    end

    test "event data is escaped", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.prompt_submitted", %{"prompt" => "<script>alert(1)</script>"}},
          {3, "runtime.tool_started",
           %{
             "tool" => "<b>Bash</b>",
             "tool_use_id" => "t",
             "input" => %{"command" => "<img src=x onerror=1>"}
           }}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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
          {2, "runtime.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "cat big"}}},
          # A failed call is listed; a routine one is in the Terminal only.
          {3, "runtime.tool_failed", %{"tool" => "Bash", "tool_use_id" => "t", "error" => big}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute html =~ "THE-END"
      assert html =~ "Show all 16.4 kB"

      html = lv |> element("#e-2 button.q-show-all") |> render_click()
      assert html =~ "THE-END"
      refute html =~ "Show all"
    end
  end

  describe "the Timeline as an overview" do
    setup %{scope: scope} do
      %{run: demo(scope, "session-with-subagents")}
    end

    defp tab_count(lv) do
      lv
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#run-tab-timeline .q-tabs-n")
      |> LazyHTML.text()
      |> String.trim()
    end

    test "routine tool calls are the Terminal's only; failed, denied and connected calls are rows",
         %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      ids = lv |> open_subagents([22, 23]) |> item_ids()

      # Calls that finished with no connection inside, and the Task calls of the subagents.
      for seq <- [12, 15, 26, 28, 30, 32, 34, 40, 54, 72, 19, 21],
          do: refute("e-#{seq}" in ids, "e-#{seq} is a row")

      # Failed with a denied connection inside, with allowed connections inside, with a
      # denied connection inside.
      for seq <- [59, 65, 91, 85], do: assert("e-#{seq}" in ids, "e-#{seq} is no row")
      assert has_element?(lv, "#e-65 .q-only-open")

      # A denied call is a row; a call that still runs with no connection is not.
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.tool_started", %{"tool" => "Bash", "tool_use_id" => "a"}},
          {3, "runtime.tool_denied", %{"tool" => "Bash", "tool_use_id" => "a"}},
          {4, "runtime.tool_started", %{"tool" => "Read", "tool_use_id" => "b"}}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert item_ids(html) == ["e-1", "e-2"]
    end

    test "a row with a Terminal line links to it; Run started, a notification and a connection do not",
         %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1")

      open_subagents(lv, [22, 23])

      # A prompt, a call, a subagent's start, and in this run, recorded with no texts, a
      # turn's end and the result.
      for seq <- [9, 59, 22, 97, 98],
          do: assert(has_element?(lv, ~s(#e-#{seq} a[href$="/terminal?seq=#{seq}"])), "#{seq}")

      for row <- ["#e-2", "#e-57", "li.q-ti-cx", "#main-session"],
          do: refute(has_element?(lv, ~s(#{row} a[href*="/terminal"])), row)

      # The Main session row links to the main agent's last text.
      run = projected(scope, session_texts())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, ~s(#main-session a[href$="/terminal?seq=4"]))
      assert has_element?(lv, "#main-session .q-k", "Main session")
    end

    test "the tab's count is the rows listed with every subagent open, the same on every tab",
         %{conn: conn, run: run, scope: scope} do
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)

      # Both subagents finished: they are closed, and their rows count all the same.
      closed = lv |> render() |> item_ids() |> length()
      count = tab_count(lv)
      rows = lv |> open_subagents([22, 23]) |> item_ids() |> length()
      assert count == Integer.to_string(rows)
      assert closed < rows
      refute count == Integer.to_string(Apiary.Runs.Record.timeline(scope, run).session_items)

      lv |> element("#e-22 .q-sub-caret") |> render_click()
      assert tab_count(lv) == count

      # The allowed connections outside a call are rows, and count, with Connections
      # inline on, here and on the Terminal tab.
      {:ok, lv, _html} = live(conn, path <> "?cx=1")
      rows_cx = lv |> open_subagents([22, 23]) |> item_ids() |> length()
      assert rows_cx > rows
      assert tab_count(lv) == Integer.to_string(rows_cx)

      lv |> element("#run-tab-terminal") |> render_click()
      assert tab_count(lv) == Integer.to_string(rows_cx)

      # Turned off on the page: the connections leave the rows and the count.
      {:ok, lv, _html} = live(conn, path <> "?cx=1")
      lv |> element("#toggle-connections") |> render_click()
      assert tab_count(lv) == count
      assert lv |> open_subagents([22, 23]) |> item_ids() |> length() == rows
    end

    test "?seq= of a routine call opens its Terminal line for a reader of the log",
         %{conn: conn, run: run, scope: scope} do
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)
      render_patch(lv, path <> "?seq=12")
      assert_patch(lv, path <> "/terminal?seq=12")
      assert has_element?(lv, ~s([data-transcript][data-target="e-12"]))
    end

    test "?seq= of an allowed connection while Connections inline is off stays on the Timeline",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "One."})},
          {3, "run.egress", egress_data(%{"decision" => "allowed"})},
          {4, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Two."})}
        ])

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      # The connection has no row: the Timeline shows the row after it, for a reader of
      # the log and for any other reader, and keeps the address.
      for hidden <- [[], [:"observability.terminal"]] do
        :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
        :ok = Apiary.EditionStubs.HidesNamed.put(hidden)
        {:ok, lv, _html} = live(conn, path <> "?seq=3")
        assert has_element?(lv, "#run-tab a#run-tab-timeline[aria-current='page']")
        assert lv |> render() |> item_ids() == ~w(e-1 e-2 e-4)
        assert has_element?(lv, ~s(ol#timeline[data-target="e-3"]))
      end

      # With Connections inline on, the connection is the row.
      {:ok, lv, _html} = live(conn, path <> "?seq=3&cx=1")
      assert lv |> render() |> item_ids() == ~w(e-1 e-2 e-3 e-4)
      assert has_element?(lv, ~s(ol#timeline[data-target="e-3"]))
    end

    test "the pill counts the events that wait, and the Main session row is none",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert lv |> render() |> item_ids() == ~w(e-1)

      # Away from the live end, the main agent's first prompt arrives: its row and the
      # Main session row wait, one event.
      project_more(run, [
        {3, "runtime.text",
         Map.merge(main, %{"kind" => "text", "role" => "user", "text" => "Go."})}
      ])

      flush(lv)
      assert has_element?(lv, "#new-events.q-newpill-show", "1 new event")
      refute has_element?(lv, "#new-events", "2 new events")

      lv |> element("#new-events") |> render_click()
      assert lv |> render() |> item_ids() == ~w(e-1 e-3 main-session)
      refute has_element?(lv, "#new-events.q-newpill-show")
    end

    test "Connections inline turned on at the live end keeps following the events",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "One."})},
          {3, "run.egress", egress_data(%{"decision" => "allowed"})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})
      assert lv |> render() |> item_ids() == ~w(e-1 e-2)

      # The connection at the end comes into the window, which still ends at the list's
      # end: the next event is drawn, with no pill.
      lv |> element("#toggle-connections") |> render_click()
      assert lv |> render() |> item_ids() == ~w(e-1 e-2 e-3)

      project_more(run, [
        {4, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Two."})}
      ])

      flush(lv)
      assert lv |> render() |> item_ids() == ~w(e-1 e-2 e-3 e-4)
      refute has_element?(lv, "#new-events.q-newpill-show")
      refute has_element?(lv, "#timeline-later")

      # Turned off again, the window ends at the list's end still.
      lv |> element("#toggle-connections") |> render_click()
      assert lv |> render() |> item_ids() == ~w(e-1 e-2 e-4)

      project_more(run, [
        {5, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Three."})}
      ])

      flush(lv)
      assert lv |> render() |> item_ids() == ~w(e-1 e-2 e-4 e-5)
      refute has_element?(lv, "#new-events.q-newpill-show")
    end
  end

  describe "the limits (P5)" do
    test "a helper session after the agent leaves the agent's page", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started",
           session_started_data(%{
             "interactive" => true,
             "terminal" => %{"cols" => 120, "rows" => 40}
           })},
          {5, "session.started",
           session_started_data(%{
             "session" => 2,
             "runtime" => "git",
             "bare" => true,
             "command" => "git",
             "args" => ["status"],
             "interactive" => false
           })
           |> Map.delete("runtime_version")},
          {6, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute html =~ "This session ran"
      assert html =~ "120×40"
    end

    test "a run with only a helper session shows it", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started",
           session_started_data(%{
             "runtime" => "sh",
             "bare" => true,
             "command" => "sh",
             "args" => []
           })
           |> Map.delete("runtime_version")},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert limits_text(lv) =~ "This session ran sh"
    end

    test "an agent on pipes shows no terminal size after a helper's resize",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {5, "session.started",
           session_started_data(%{
             "session" => 2,
             "runtime" => "git",
             "bare" => true,
             "command" => "git",
             "interactive" => true,
             "terminal" => %{"cols" => 80, "rows" => 24}
           })},
          {6, "run.resized", %{"cols" => 100, "rows" => 30, "session" => 2}},
          {7, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute "Terminal" in details_terms(lv)
      refute html =~ "100×30"
      refute html =~ "80×24"
    end

    test "another runtime: the sentence stands above Forager's items", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "failed-run")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert html =~ "Only Claude Code sends session events."
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
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "session.started", session_started_data(%{"image" => "registry.example/agent:1"})},
          {3, "runtime.result", %{"outcome" => "success", "result" => "done"}},
          {4, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert html =~ "it ran behind runs inside a virtual machine. The run has a terminal"
      assert html =~ "Only the result, read from the runtime&#39;s output, is shown."
    end

    test "claude without a wall and without session events: the hooks sentence", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert html =~ "No session events arrived."
    end

    test "a running run with no session events, heard of over a minute ago: the hooks sentence",
         %{conn: conn, scope: scope} do
      ago = DateTime.add(DateTime.utc_now(), -120, :second)

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: ago},
          {2, "session.started", session_started_data(), time: ago}
        ])

      Apiary.Repo.update_all(Apiary.Runs.Run, set: [inserted_at: ago, last_event_at: ago])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-meta #run-state", "Running")
      assert html =~ "No session events arrived."
      assert has_element?(lv, "#run-meta #run-duration-line")
    end

    test "a run that did not start: no sentence on session events, and no n/a for its duration",
         %{conn: conn, scope: scope} do
      for started <- [started_data()] do
        run =
          projected(scope, [
            {1, "run.started", started},
            {2, "run.refused", %{"code" => "image_unknown"}}
          ])

        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-meta #run-state", "Failed")
        refute html =~ "No session events arrived."
        refute has_element?(lv, ".q-limits")
        refute has_element?(lv, "#run-meta #run-duration-line")
        refute has_element?(lv, "#run-meta", "n/a")
        refute "Duration" in run_terms(lv)
      end
    end

    test "the rail's Duration stays for a running run and for one Apiary marked lost", %{
      conn: conn,
      scope: scope
    } do
      now = DateTime.utc_now()
      started = DateTime.add(now, -4000, :second)
      heard = DateTime.add(now, -3000, :second)

      silent =
        projected(scope, [
          {1, "run.started", started_data(), time: started},
          {2, "run.heartbeat", %{"elapsed_seconds" => 1000, "interval_seconds" => 30},
           time: heard, received_at: heard}
        ])

      Apiary.Runs.Liveness.check()
      running = projected(scope, [{1, "run.started", started_data(), time: now}])

      for {run, state} <- [{silent, "Lost"}, {running, "Running"}] do
        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-meta #run-state", state)
        assert "Duration" in run_terms(lv)
      end
    end

    test "a young live run has no limits sentence yet, only the live end", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data(), time: DateTime.utc_now()}])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute html =~ "No session events arrived."
      assert html =~ "Listening for the next batch."
    end
  end

  describe "where the run's Terminal is hidden from the reader" do
    setup do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
    end

    test "no Terminal tab, no log in the more menu, no terminal on Details; the rest reads",
         %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, lv, html} = live(conn, path)

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("nav#run-tab > a")
             |> Enum.map(&LazyHTML.attribute(&1, "id"))
             |> List.flatten() == ~w(run-tab-timeline run-tab-connections)

      refute has_element?(lv, "#run-tab-terminal")
      assert has_element?(lv, ~s(#run-menu-copy[data-copy="#{run.public_id}"]))
      refute has_element?(lv, "#run-menu-raw")
      refute has_element?(lv, "#run-menu-download")
      # Copy diagnostics copies the log, so it is not offered either.
      refute has_element?(lv, "#run-menu-diagnostics")
      refute html =~ "/runs/#{run.number}/diagnostics"
      refute html =~ "/runs/#{run.number}/log"
      refute html =~ "/runs/#{run.number}/terminal"

      # The timeline, the connections and the outcome are there as before.
      assert item_ids(html) != []
      assert has_element?(lv, "#run-meta #run-state")

      {:ok, lv, _html} = live(conn, path <> "/network")
      assert has_element?(lv, "#run-tab-connections[aria-current]")
      refute has_element?(lv, "#run-tab-terminal")
    end

    test "/terminal is a path that does not exist, the part hidden or its feature",
         %{conn: conn, scope: scope} do
      run = projected(scope, record())
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal"

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end

      :ok = Apiary.EditionStubs.HidesNamed.put([])
      assert {:ok, lv, _html} = live(conn, path)
      assert has_element?(lv, "#terminal[phx-hook='Terminal']")
    end

    test "an open Terminal tab leaves for the Timeline once the part is hidden from the reader",
         %{conn: conn, scope: scope} do
      run = projected(scope, record())
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      :ok = Apiary.EditionStubs.HidesNamed.put([])
      {:ok, lv, _html} = live(conn, path <> "/terminal")
      assert has_element?(lv, "#terminal[data-src]")

      # Hidden meanwhile: the page hears of it as of any change to the reader's place.
      :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
      send(lv.pid, {:membership_changed, :hidden})

      assert_patch(lv, path)
      refute has_element?(lv, "#terminal")
      refute has_element?(lv, "#run-tab-terminal")
      refute render(lv) =~ "/runs/#{run.number}/log"
      assert has_element?(lv, "#run-tab-timeline[aria-current]")
    end

    test "the live follow of an open Terminal tab reads no more once the reader may not read the log",
         %{conn: conn, scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: now},
          {2, "session.started", session_started_data(%{"interactive" => true}), time: now},
          {3, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\n")}, time: now}
        ])

      :ok = Apiary.EditionStubs.HidesNamed.put([])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      project_more(run, [
        {4, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("two\n")}, time: now}
      ])

      flush(lv)
      assert_push_event(lv, "log_advanced", %{through: 4})

      # The edition refuses the log from now on, with no change to the reader's place to
      # load the scope again: the page asks at each read, and pushes nothing.
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoLog)

      project_more(run, [
        {5, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("three\n")}, time: now}
      ])

      flush(lv)
      refute_push_event(lv, "log_advanced", %{})
      refute has_element?(lv, "#terminal")
    end

    test "Details names no terminal size", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started",
           session_started_data(%{
             "interactive" => true,
             "terminal" => %{"cols" => 120, "rows" => 40}
           })},
          {3, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\r\n")}},
          {4, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network"

      {:ok, lv, html} = live(conn, path)
      refute "Terminal" in details_terms(lv)
      refute html =~ "120×40"
      assert "Interactive" in details_terms(lv)

      :ok = Apiary.EditionStubs.HidesNamed.put([])
      {:ok, lv, html} = live(conn, path)
      assert "Terminal" in details_terms(lv)
      assert html =~ "120×40"
    end

    test "the sentences on session events name no terminal; shown, they do as before",
         %{conn: conn, scope: scope} do
      walled =
        projected(scope, [
          {1, "run.started", started_data(%{"wall" => "docker"})},
          {2, "session.started", session_started_data(%{"image" => "registry.example/agent:1"})},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      no_hooks =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      sentences = [
        {walled,
         "This run's session events could not be recorded: the wall it ran behind runs inside a virtual machine. The run has connections and no session timeline.",
         "This run's session events could not be recorded: the wall it ran behind runs inside a virtual machine. The run has a terminal and connections, and no session timeline."},
        {no_hooks,
         "No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its connections.",
         "No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its terminal and connections."}
      ]

      for {run, hidden, shown} <- sentences do
        path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

        :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
        {:ok, lv, _html} = live(conn, path)
        assert limits_text(lv) =~ hidden
        refute limits_text(lv) =~ "terminal"

        :ok = Apiary.EditionStubs.HidesNamed.put([])
        {:ok, lv, _html} = live(conn, path)
        assert limits_text(lv) =~ shown
      end
    end

    # A session whose every text is a word in capitals, so that a test can look for each one
    # in the page: the run's command and arguments, a prompt, a text, a tool call with its
    # input and output, a subagent's last message, a failed turn with its error, message and
    # details, a turn's end with a background task, a notification, and a result. The run
    # failed: its header shows how it ended, from the failed turn.
    defp session_texts do
      main = %{"session_id" => "s"}
      agent = %{"session_id" => "s", "agent_id" => "agent-1", "agent_type" => "Explore"}

      task = %{
        "id" => "b3f1",
        "type" => "shell",
        "status" => "running",
        "command" => "BACKGROUNDWORDS"
      }

      [
        {1, "run.started", started_data()},
        {2, "session.started",
         session_started_data(%{"command" => "COMMANDWORD", "args" => ["-p", "ARGUMENTWORDS"]})},
        {3, "runtime.prompt_submitted", Map.put(main, "prompt", "PROMPTWORDS")},
        {4, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "TEXTWORDS"})},
        {5, "runtime.tool_started",
         Map.merge(main, %{
           "tool" => "Bash",
           "tool_use_id" => "t1",
           "input" => %{"command" => "INPUTWORDS"},
           "summary" => "SUMMARYWORDS"
         })},
        # The call fails: the Timeline lists it, where a routine call is the Terminal's only.
        {6, "runtime.tool_failed",
         Map.merge(main, %{"tool" => "Bash", "tool_use_id" => "t1", "error" => "OUTPUTWORDS"})},
        {7, "runtime.subagent_started", agent},
        {8, "runtime.subagent_finished", Map.put(agent, "message", "SUBAGENTWORDS")},
        {9, "runtime.turn_finished",
         Map.merge(main, %{"message" => "LASTWORDS", "background_tasks" => [task]})},
        {10, "runtime.notification", %{"kind" => "idle_prompt", "message" => "NOTICEWORDS"}},
        {11, "runtime.turn_failed",
         Map.merge(main, %{
           "error" => "ERRORWORDS",
           "message" => "MESSAGEWORDS",
           "details" => "DETAILSWORDS"
         })},
        {12, "runtime.result",
         Map.merge(main, %{"outcome" => "success", "turns" => 3, "result" => "RESULTWORDS"})},
        {13, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
      ]
    end

    @session_words ~w(COMMANDWORD ARGUMENTWORDS PROMPTWORDS TEXTWORDS INPUTWORDS SUMMARYWORDS
                      OUTPUTWORDS SUBAGENTWORDS BACKGROUNDWORDS NOTICEWORDS ERRORWORDS
                      MESSAGEWORDS DETAILSWORDS)

    defp row_kinds(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("ol#timeline .q-k")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    test "the Timeline, the header and Details show no text of the session; each row keeps its label",
         %{conn: conn, scope: scope} do
      run = projected(scope, session_texts())

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      for word <- @session_words, do: refute(html =~ word, "#{word} is on the page")

      for kind <- [
            "Prompt",
            "Text",
            "Bash",
            "Explore",
            "Turn finished",
            "Notification",
            "Turn failed"
          ],
          do: assert(kind in row_kinds(html), "no row #{kind}")

      # The subagent is one closed row: its type and its calls, and no line of its last
      # message.
      assert has_element?(lv, "#e-7 .q-sub-said .q-k", "Explore")
      assert has_element?(lv, "#e-7 .q-sub-said .q-s", "0 calls")
      refute has_element?(lv, "#e-7", "SUBAGENTWORDS")
      refute has_element?(lv, "#e-7 .q-hd > .q-s")
      refute has_element?(lv, "#e-8")
      assert has_element?(lv, "#e-12", "success · 3 turns")
      refute has_element?(lv, "#e-5 .q-xb")
      refute has_element?(lv, "#e-11 .q-well")

      # The background task keeps its type and id, the notification its kind.
      assert has_element?(lv, "#background-tasks", "shell b3f1 · listed at #0009")
      assert has_element?(lv, "#e-10 .q-k", "Notification")
      assert has_element?(lv, "#e-10", "idle_prompt")

      # The header keeps how it ended and the way to the item.
      assert has_element?(lv, "#run-why .q-run-why-k", "How it ended")
      refute has_element?(lv, "#run-why .q-run-why-t")
      assert has_element?(lv, "#run-why-jump")

      assert "Command" in details_terms(lv)
      assert "Arguments" in details_terms(lv)
      assert has_element?(lv, "#run-command", "n/a")
      assert has_element?(lv, "#run-args", "n/a")
    end

    test "a Timeline open when the Terminal is hidden builds its rows again, without the texts",
         %{conn: conn, scope: scope} do
      :ok = Apiary.EditionStubs.HidesNamed.put([])
      run = projected(scope, session_texts())

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert html =~ "PROMPTWORDS"
      assert has_element?(lv, "#run-why .q-run-why-t", "ERRORWORDS")
      assert has_element?(lv, "#e-5 summary .q-chev")

      # Hidden meanwhile: the page hears of it as of any change to the reader's place.
      :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
      send(lv.pid, {:membership_changed, :hidden})
      html = render(lv)

      for word <- @session_words, do: refute(html =~ word, "#{word} is on the page")
      assert has_element?(lv, "#e-3 .q-k", "Prompt")
      assert has_element?(lv, "#e-5 .q-k", "Bash")
      refute has_element?(lv, "#e-5 .q-chev")
      assert has_element?(lv, "#run-why .q-run-why-k", "How it ended")
      refute has_element?(lv, "#run-why .q-run-why-t")
    end

    test "a tool row with nothing to open has no arrow; one with a connection inside keeps it",
         %{conn: conn, scope: scope} do
      run = projected(scope, session_texts())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # A failed call without connections: one line with its tool, state and times.
      refute has_element?(lv, "#e-5 details")
      refute has_element?(lv, "#e-5 .q-chev")
      assert has_element?(lv, "#e-5-tool.q-hd .q-k", "Bash")
      assert has_element?(lv, "#e-5-tool .q-t .q-t-at")
      assert has_element?(lv, ~s(#e-5-tool .q-t a[data-permalink]), "#0005")

      run = demo(scope, "session-with-subagents")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # A failed call with a denied connection inside opens to that connection.
      assert has_element?(lv, "#e-59 details[open] > summary .q-chev")
      assert has_element?(lv, "#e-59 summary .q-bad", "Failed")
      assert has_element?(lv, "#e-59 .q-during", "1 connection while this call was open")
      refute has_element?(lv, "#e-59 .q-well")
    end

    test "with the Terminal shown, a tool row with nothing to open keeps its arrow",
         %{conn: conn, scope: scope} do
      :ok = Apiary.EditionStubs.HidesNamed.put([])

      # A failed call with no input and no error: listed, with nothing to show inside.
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.tool_started", %{"tool" => "Bash", "tool_use_id" => "t"}},
          {3, "runtime.tool_failed", %{"tool" => "Bash", "tool_use_id" => "t"}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute has_element?(lv, "#e-2 .q-xb")
      assert has_element?(lv, "#e-2 details > summary .q-chev")
      assert has_element?(lv, "#e-2 summary .q-k", "Bash")
    end

    test "the header shows a run that ended on a result by the way to it only",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.result", %{"outcome" => "error", "result" => "RESULTWORDS"}},
          {3, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute html =~ "RESULTWORDS"
      assert has_element?(lv, "#e-2 .q-k", "Result")
      assert has_element?(lv, "#run-why .q-run-why-k", "How it ended")
      refute has_element?(lv, "#run-why .q-run-why-t")
      assert has_element?(lv, "#run-why-jump")
    end

    test "an event that arrives after the page opened shows no text either",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      now = DateTime.utc_now()
      run = projected(scope, [{1, "run.started", started_data(), time: now}])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

      project_more(run, [
        {2, "runtime.prompt_submitted", Map.put(main, "prompt", "PROMPTWORDS"), time: now},
        {3, "runtime.tool_started",
         Map.merge(main, %{
           "tool" => "Bash",
           "tool_use_id" => "t1",
           "input" => %{"command" => "INPUTWORDS"},
           "summary" => "SUMMARYWORDS"
         }), time: now}
      ])

      html = flush(lv)
      assert has_element?(lv, "#e-2 .q-k", "Prompt")
      # A running call is in the Terminal only.
      refute has_element?(lv, "#e-3")

      # The call fails: its row comes in at its place.
      project_more(run, [
        {4, "runtime.tool_failed",
         Map.merge(main, %{"tool" => "Bash", "tool_use_id" => "t1", "error" => "OUTPUTWORDS"}),
         time: now}
      ])

      html = html <> flush(lv)
      assert has_element?(lv, "#e-3 .q-k", "Bash")

      for word <- ~w(PROMPTWORDS INPUTWORDS SUMMARYWORDS OUTPUTWORDS),
          do: refute(html =~ word, "#{word} is on the page")
    end

    test "the header shows a failed tool by its name only", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "summary" => "SUMMARYWORDS"}},
          {3, "runtime.tool_failed",
           %{"tool" => "Bash", "tool_use_id" => "t", "error" => "ERRORWORDS"}},
          {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-why .q-run-why-t", "Bash failed")
      refute html =~ "SUMMARYWORDS"
      refute html =~ "ERRORWORDS"
      assert has_element?(lv, "#e-2 .q-k", "Bash")
      assert has_element?(lv, "#e-2", "Failed")
    end

    test "Show all and a Transcript's result that opens read no whole payload",
         %{conn: conn, scope: scope} do
      big = String.duplicate("0123456789abcdef", 1024) <> "THE-END"

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "cat big"}}},
          {3, "runtime.tool_finished",
           %{"tool" => "Bash", "tool_use_id" => "t", "response" => big}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute html =~ "Show all"

      refute render_hook(lv, "show_all", %{"seq" => "2"}) =~ "THE-END"
      refute render_hook(lv, "transcript_open", %{"seq" => "2"}) =~ "THE-END"

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.full == MapSet.new()
      assert assigns.opened == MapSet.new()
    end

    test "the same rows and count as for a reader of the log, by their labels, with no Terminal link",
         %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      rows = fn ->
        {:ok, lv, _html} = live(conn, path)
        html = open_subagents(lv, [22, 23])
        count = lv |> element("#run-tab-timeline .q-tabs-n") |> render()
        {lv, item_ids(html), count}
      end

      {_lv, hidden_ids, hidden_count} = rows.()
      :ok = Apiary.EditionStubs.HidesNamed.put([])
      {shown_lv, shown_ids, shown_count} = rows.()
      assert has_element?(shown_lv, ~s(ol#timeline a[href*="/terminal"]))

      :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
      {lv, _ids, _count} = rows.()
      assert hidden_ids == shown_ids
      assert hidden_count == shown_count
      refute has_element?(lv, ~s(ol#timeline a[href*="/terminal"]))
      refute "e-12" in hidden_ids

      # No text of the session, the Main session's last text included.
      run = projected(scope, session_texts())

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      for word <- @session_words, do: refute(html =~ word, "#{word} is on the page")
      assert has_element?(lv, "#main-session .q-k", "Main session")
      assert has_element?(lv, "#main-session", "1 call")
      refute has_element?(lv, ~s(ol#timeline a[href*="/terminal"]))
    end

    test "?seq= of a routine call shows the row before it", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, lv, _html} = live(conn, path)
      render_patch(lv, path <> "?seq=12")
      assert_patch(lv, path <> "?seq=9")
      assert has_element?(lv, ~s(ol#timeline[data-target="e-9"]))
      refute has_element?(lv, "#e-12")
    end

    test "with the Terminal shown, the session's texts read as before",
         %{conn: conn, scope: scope} do
      :ok = Apiary.EditionStubs.HidesNamed.put([])
      run = projected(scope, session_texts())

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      for word <- @session_words, do: assert(html =~ word, "#{word} is not on the page")

      assert has_element?(lv, "#run-why .q-run-why-t", "ERRORWORDS")
      assert has_element?(lv, "#run-details dd", "COMMANDWORD")
      assert has_element?(lv, "#background-tasks", "BACKGROUNDWORDS")
    end
  end

  describe "live (P6, P7)" do
    setup %{scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: DateTime.add(now, -30, :second)},
          {2, "runtime.prompt_submitted", %{"prompt" => "go"},
           time: DateTime.add(now, -29, :second)},
          {3, "runtime.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t1", "input" => %{"command" => "sleep 9"}},
           time: DateTime.add(now, -28, :second)}
        ])

      %{run: run, now: now}
    end

    test "an open tool is listed once it is the only open call at a connection; its end updates it in place",
         %{conn: conn, run: run, now: now, scope: scope} do
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # Running, with no connection: the Terminal's only.
      refute has_element?(lv, "#e-3")
      assert html =~ "Listening for the next batch."
      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

      project_more(run, [{4, "run.egress", egress_data(), time: now}])
      flush(lv)
      assert has_element?(lv, "#e-3 .q-running", "Running")
      assert has_element?(lv, "#e-3 .q-n .q-spin")
      assert has_element?(lv, "#e-3 .q-r-live")

      project_more(run, [
        {5, "runtime.tool_finished",
         %{"tool" => "Bash", "tool_use_id" => "t1", "response" => "ok", "duration_ms" => 9000},
         time: now}
      ])

      html = flush(lv)
      refute has_element?(lv, "#e-3 .q-running")
      assert has_element?(lv, "#e-3 .q-well", "response")
      assert item_ids(html) == ["e-1", "e-2", "main-session", "e-3"]
      refute has_element?(lv, "#new-events.q-newpill-show")
    end

    test "away from the end new items are counted, not inserted; the pill loads them", %{
      conn: conn,
      run: run,
      now: now,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      project_more(run, [
        {4, "runtime.notification", %{"kind" => "idle_prompt", "message" => "waiting"},
         time: now},
        {5, "runtime.turn_finished", %{"message" => "done"}, time: now}
      ])

      html = flush(lv)
      assert item_ids(html) == ["e-1", "e-2", "main-session"]
      # The turn ended without the call's end: the call comes as a row too.
      assert has_element?(lv, "#new-events.q-newpill-show", "3 new events")
      assert has_element?(lv, "#run-announcer", "3 new events.")

      html = lv |> element("#new-events") |> render_click()
      assert item_ids(html) == ["e-1", "e-2", "main-session", "e-3", "e-4", "e-5"]
      refute has_element?(lv, "#new-events.q-newpill-show")
      assert_push_event(lv, "timeline:end", %{focus: "e-3"})
    end

    # LiveView locks a hook's element until the acknowledgement of the hook's event
    # arrives; a stream patched inside a locked element appends new rows at the end.
    test "the hooks that push sit outside the timeline's stream, live and ended", %{
      conn: conn,
      run: run,
      now: now,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#live-end[phx-hook=LiveEnd]", "Listening for the next batch.")
      assert has_element?(lv, "#timeline[phx-update=stream]")
      refute has_element?(lv, "[phx-hook=LiveEnd] #timeline")
      assert has_element?(lv, "#timeline-push[phx-hook=TimelinePush]")
      refute has_element?(lv, "#timeline #timeline-push")

      project_more(run, [
        {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 30_000},
         time: now}
      ])

      flush(lv)
      assert has_element?(lv, "#live-end[phx-hook=LiveEnd]", "End of the record.")
      refute has_element?(lv, "[phx-hook=LiveEnd] #timeline")
      assert has_element?(lv, "#timeline-push[phx-hook=TimelinePush]")
      refute has_element?(lv, "#timeline #timeline-push")
    end

    test "at the live end new items append", %{conn: conn, run: run, now: now, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

      project_more(run, [{4, "runtime.turn_finished", %{"message" => "done"}, time: now}])

      assert has_element?(lv, "#main-session .q-r-live")
      html = flush(lv)
      # The turn ended without the call's end: the call is listed, with No end recorded.
      assert item_ids(html) == ["e-1", "e-2", "main-session", "e-3", "e-4"]
      assert has_element?(lv, "#e-3 .q-no-end", "No end recorded")
      refute has_element?(lv, "#new-events.q-newpill-show")
      # the row that was last no longer fades its rail
      refute has_element?(lv, "#main-session .q-r-live")
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute html =~ "in the background"

      run =
        project_more(run, [
          {4, "runtime.turn_finished", %{"message" => "m", "background_tasks" => [task]},
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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

    test "a pause is announced as its line on the page says it", %{
      conn: conn,
      run: run,
      now: now,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      project_more(run, [
        {4, "run.exited", %{"state" => "cancelled", "reason" => "model_key_limit"}, time: now}
      ])

      _html = flush(lv)

      assert has_element?(lv, "#run-announcer", "Paused: a model key reached its limit.")
      assert has_element?(lv, "#run-why", "Paused: a model key reached its limit.")
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
            do: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}}
          ) ++
          [{901, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}]

      run = projected(scope, events)

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      ids = item_ids(html)
      assert length(ids) == 300
      assert hd(ids) == "e-1" and List.last(ids) == "e-300"
      assert has_element?(lv, "#timeline-later", "601 later events")
      refute has_element?(lv, "#timeline-earlier")

      html = lv |> element("#timeline-later") |> render_click()
      assert html |> item_ids() |> List.last() == "e-500"

      # around a target
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=700")

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

    test "Load earlier and Load newer count events, and the Main session row is none", %{
      conn: conn,
      scope: scope
    } do
      main = %{"session_id" => "s"}
      prompt = Map.merge(main, %{"kind" => "text", "role" => "user", "text" => "Go."})
      exited = %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}

      # The Main session row follows the main agent's first prompt: before the window with
      # the prompt at 3, after it with the prompt at 880. Either way the window has e-550
      # to e-849, with 548 events before it (e-2 is no row) and 52 after it.
      for at <- [3, 880] do
        middle =
          for n <- 3..900 do
            if n == at,
              do: {n, "runtime.text", prompt},
              else: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}}
          end

        run =
          projected(
            scope,
            [{1, "run.started", started_data()}, {2, "session.started", session_started_data()}] ++
              middle ++ [{901, "run.exited", exited}]
          )

        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=700")

        ids = item_ids(html)
        assert hd(ids) == "e-550" and List.last(ids) == "e-849"
        refute "main-session" in ids
        assert has_element?(lv, "#timeline-earlier", "548 earlier events")
        assert has_element?(lv, "#timeline-later", "52 later events")

        assert has_element?(
                 lv,
                 "ol#timeline[aria-label='Session timeline, in sequence order; 548 earlier events not loaded; 52 later events not loaded']"
               )
      end
    end

    # A version pushed before the run started is a Pushed row before every other row.
    @tag needs: :factory
    test "Load earlier shows no count when only a Pushed row is before the window", %{
      conn: conn,
      scope: scope
    } do
      pool = Apiary.NodesFixtures.pool_fixture(scope, name: "build-pool")
      %{access_key: key} = enrolled_key_fixture(scope, pool)

      %{run: run, dispatch_run: dispatch_run} =
        Apiary.DispatchedRunsFixtures.handed_over_fixture(scope, key)

      at = &DateTime.add(DateTime.utc_now(), &1, :second)

      # The rows are the Pushed row, then e-1 to e-400: the window around e-151 has e-1 to
      # e-300, with the Pushed row before it and 100 events after it.
      run =
        project_more(
          run,
          [{1, "run.started", started_data(), time: at.(-500)}] ++
            for(
              n <- 2..400,
              do:
                {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"},
                 time: at.(-400)}
            )
        )

      dispatch_run = Repo.get!(DispatchRun, dispatch_run.id)
      work_item = Repo.get!(Apiary.WorkItems.WorkItem, dispatch_run.work_item_id)
      file = %{filename: "proposal.md", content_type: "text/markdown", binary: "Plan\n"}

      {:ok, version} =
        Apiary.Artifacts.push({:run, dispatch_run}, work_item, "proposal", [file], name: "main")

      {1, _rows} =
        Repo.update_all(from(v in Apiary.Artifacts.Version, where: v.id == ^version.id),
          set: [inserted_at: at.(-600)]
        )

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=151")

      ids = item_ids(html)
      assert hd(ids) == "e-1" and List.last(ids) == "e-300"
      assert has_element?(lv, "#timeline-earlier", "Load earlier")
      refute has_element?(lv, "#timeline-earlier", "earlier event")
      assert has_element?(lv, "#timeline-later", "100 later events")

      assert has_element?(
               lv,
               "ol#timeline[aria-label='Session timeline, in sequence order; 100 later events not loaded']"
             )
    end

    test "Load newer shows no count when only the Main session row is after the window", %{
      conn: conn,
      scope: scope
    } do
      prompt = %{"session_id" => "s", "kind" => "text", "role" => "user", "text" => "Go."}

      # The rows are e-1, e-3 to e-400 with the prompt at 400, then the Main session row:
      # the window around e-251 has e-101 to e-400, with 99 events before it and the Main
      # session row after it.
      run =
        projected(
          scope,
          [{1, "run.started", started_data()}, {2, "session.started", session_started_data()}] ++
            for(
              n <- 3..399,
              do: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}}
            ) ++ [{400, "runtime.text", prompt}]
        )

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=251")

      ids = item_ids(html)
      assert hd(ids) == "e-101" and List.last(ids) == "e-400"
      assert has_element?(lv, "#timeline-earlier", "99 earlier events")
      assert has_element?(lv, "#timeline-later", "Load newer")
      refute has_element?(lv, "#timeline-later", "later event")
      refute has_element?(lv, "#timeline-later .text-faint")

      assert has_element?(
               lv,
               "ol#timeline[aria-label='Session timeline, in sequence order; 99 earlier events not loaded']"
             )
    end

    test "the label has no count when only the Main session row is outside the window", %{
      conn: conn,
      scope: scope
    } do
      prompt = %{"session_id" => "s", "kind" => "text", "role" => "user", "text" => "Go."}

      # The rows are e-1, e-3 to e-301 with the prompt at 301, then the Main session row:
      # 301 rows. The window of 300 has every event, and only the Main session row is after
      # it.
      run =
        projected(
          scope,
          [{1, "run.started", started_data()}, {2, "session.started", session_started_data()}] ++
            for(
              n <- 3..300,
              do: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}}
            ) ++ [{301, "runtime.text", prompt}]
        )

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      ids = item_ids(html)
      assert hd(ids) == "e-1" and List.last(ids) == "e-301"
      refute "main-session" in ids
      refute has_element?(lv, "#timeline-earlier")
      assert has_element?(lv, "#timeline-later", "Load newer")
      refute has_element?(lv, "#timeline-later", "later event")

      assert has_element?(lv, "ol#timeline[aria-label='Session timeline, in sequence order']")
    end

    # Loading by scrolling (`phx-viewport-top` and `-bottom`) puts LiveView's InfiniteScroll
    # hook on the list in place of TimelineKeys, and its pushes lock the stream, whose rows
    # then land at the end. Rows load only through Load earlier and Load newer.
    test "a run over 300 items keeps the keys on its list and loads nothing by scrolling", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, many_items(900))

      for query <- ["", "?seq=700"] do
        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}" <> query)

        assert has_element?(lv, "#timeline-later")
        assert has_element?(lv, "ol#timeline[phx-hook=TimelineKeys]")
        refute has_element?(lv, "#timeline[phx-viewport-top]")
        refute has_element?(lv, "#timeline[phx-viewport-bottom]")
      end
    end

    test "Load earlier puts its rows before the shown ones, Load newer after, in order", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, many_items(900))

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, lv, html} = live(conn, path <> "?seq=700")
      shown = item_seqs(html)
      after_earlier = lv |> element("#timeline-earlier") |> render_click() |> item_seqs()
      loaded = after_earlier -- shown
      assert loaded != [] and loaded == Enum.sort(loaded)
      assert after_earlier == loaded ++ shown
      assert List.last(loaded) < hd(shown)
      refute has_element?(lv, "#timeline[phx-viewport-top]")

      {:ok, lv, html} = live(conn, path)
      shown = item_seqs(html)
      after_newer = lv |> element("#timeline-later") |> render_click() |> item_seqs()
      loaded = after_newer -- shown
      assert loaded != [] and loaded == Enum.sort(loaded)
      assert after_newer == shown ++ loaded
      assert hd(loaded) > List.last(shown)
      refute has_element?(lv, "#timeline[phx-viewport-bottom]")
    end

    # The page's window after each press: every row from `first` through `last` once, in
    # order, and the counts of the rows on either side.
    defp assert_window(lv, html, first, last, total) do
      assert item_seqs(html) == Enum.to_list(first..last)

      if first > 1,
        do: assert(has_element?(lv, "#timeline-earlier", ~r/(^|\D)#{first - 1} earlier event/)),
        else: refute(has_element?(lv, "#timeline-earlier"))

      if last < total,
        do: assert(has_element?(lv, "#timeline-later", ~r/(^|\D)#{total - last} later event/)),
        else: refute(has_element?(lv, "#timeline-later"))
    end

    defp press(lv, button), do: lv |> element(button) |> render_click()

    test "Load earlier, then Load newer, on one page loads every row once and in order", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, many_items(499))

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=300")

      assert_window(lv, html, 150, 449, 500)
      assert_window(lv, press(lv, "#timeline-earlier"), 1, 449, 500)
      assert_window(lv, press(lv, "#timeline-later"), 1, 500, 500)
    end

    test "Load newer, then Load earlier, on one page loads every row once and in order", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, many_items(499))

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=300")

      assert_window(lv, html, 150, 449, 500)
      assert_window(lv, press(lv, "#timeline-later"), 150, 500, 500)
      assert_window(lv, press(lv, "#timeline-earlier"), 1, 500, 500)
    end

    test "past 600 rows the other end leaves, its count is right, and it loads back in order",
         %{conn: conn, scope: scope} do
      run = projected(scope, many_items(900))

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=700")

      assert_window(lv, html, 550, 849, 901)
      assert_window(lv, press(lv, "#timeline-earlier"), 350, 849, 901)
      # 700 rows: the 100 at the end leave.
      assert_window(lv, press(lv, "#timeline-earlier"), 150, 749, 901)
      # They load back, and 152 rows at the top leave.
      assert_window(lv, press(lv, "#timeline-later"), 302, 901, 901)
      assert_window(lv, press(lv, "#timeline-earlier"), 102, 701, 901)
    end

    defp many_items(last) do
      [{1, "run.started", started_data()}] ++
        for(
          n <- 2..last,
          do: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}}
        ) ++
        [
          {last + 1, "run.exited",
           %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ]
    end

    defp item_seqs(html), do: Enum.map(item_ids(html), fn "e-" <> n -> String.to_integer(n) end)
  end

  describe "the Transcript (C3)" do
    defp terminal(conn, scope, run, query \\ "") do
      live(
        conn,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal" <> query
      )
    end

    test "the session from its runtime events, in order, with links to Raw", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, runtime_record())
      {:ok, lv, _html} = terminal(conn, scope, run)

      assert has_element?(lv, ~s(#terminal[data-view="transcript"][data-raw="true"]))
      assert has_element?(lv, "#e-7.q-tr-prompt", "/harness:hello")
      assert has_element?(lv, "#e-10.q-tr-tool", "Skill")
      assert has_element?(lv, "#e-10 .q-tr-ln", "Launching skill: harness:greet")
      assert has_element?(lv, "#e-15 .q-tr-warn", "Denied: Quoted text")
      assert has_element?(lv, "#e-17 .q-tr-think", "Thinking")
      assert has_element?(lv, "#e-18 .q-tr-md h3, #e-18 .q-tr-md h2")
      assert has_element?(lv, "#e-20.q-tr-result", "success · 6 turns · 14 s · $0.09")

      # Texts are there, so a turn's end is not a line.
      refute has_element?(lv, "#e-19")
      # The Timeline's rows are not the Transcript's.
      refute has_element?(lv, "#e-1")

      assert has_element?(
               lv,
               ~s(#e-9 .q-tr-raw[data-raw-line="2"][data-session="1"][aria-label="Show line 2 in Raw"])
             )

      render_hook(lv, "raw_line", %{"session" => 1, "line" => 2, "stream" => nil})
      assert_reply(lv, %{offset: 42})

      render_hook(lv, "raw_line", %{"session" => 1, "line" => 5, "stream" => "stdout"})
      assert_reply(lv, %{offset: 141})
    end

    test "a result opens to every line and folds again", %{conn: conn, scope: scope} do
      lines = Enum.map_join(1..5, "\n", &"line #{&1}")

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.tool_started",
           %{"session_id" => "s", "tool" => "Bash", "tool_use_id" => "a", "input" => %{}}},
          {4, "runtime.tool_result",
           %{"session_id" => "s", "tool_use_id" => "a", "content" => lines}},
          {5, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      refute has_element?(lv, "#e-3 .q-tr-ln", "line 4")

      lv |> element("#e-3 .q-tr-fold", "2 more lines") |> render_click()
      assert has_element?(lv, "#e-3 .q-tr-ln", "line 5")

      lv |> element("#e-3 .q-tr-fold", "Show less") |> render_click()
      refute has_element?(lv, "#e-3 .q-tr-ln", "line 4")
    end

    test "a Timeline text links to its line in the Transcript", %{conn: conn, scope: scope} do
      run = projected(scope, runtime_record())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#e-18 .q-s-fit", "Hello, Dana")
      refute has_element?(lv, "#e-17")

      lv |> element("#e-18 .q-to-term") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal?seq=18"
      )

      assert has_element?(lv, ~s(#transcript-box[data-target="e-18"]))
    end

    test "a session with no runtime events opens in Raw, with no Transcript", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("plain\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      assert has_element?(lv, ~s(#terminal[data-view="raw"]))
      refute has_element?(lv, "#terminal [data-view-button]")
      refute has_element?(lv, "#transcript")
    end

    test "a pruned log leaves the Transcript, under the pruned notice, with no Raw", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, runtime_record())
      Repo.delete_all(from l in Apiary.Runs.LogChunk, where: l.run_id == ^run.id)

      {1, _} =
        Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^run.id),
          set: [log_pruned_at: DateTime.utc_now()]
        )

      {:ok, lv, html} = terminal(conn, scope, run)
      assert html =~ "log output was pruned on"
      assert has_element?(lv, ~s(#terminal[data-view="transcript"][data-raw="false"]))
      assert has_element?(lv, "#e-18")
      refute has_element?(lv, ".q-tr-raw")
      refute has_element?(lv, "#terminal-screen")
    end

    test "a run recorded before the text events shows each turn's last message", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.tool_started",
           %{"session_id" => "s", "tool" => "Read", "tool_use_id" => "a", "input" => %{}}},
          {4, "runtime.tool_finished",
           %{
             "session_id" => "s",
             "tool" => "Read",
             "tool_use_id" => "a",
             "response" => %{"ok" => true}
           }},
          {5, "runtime.turn_finished", %{"session_id" => "s", "message" => "Done, Dana"}},
          {6, "runtime.result",
           %{
             "session_id" => "s",
             "outcome" => "success",
             "is_error" => false,
             "result" => "Done, Dana"
           }},
          {7, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      assert has_element?(lv, "#e-5", "Done, Dana")
      refute has_element?(lv, "#e-6", "Done, Dana")
      assert has_element?(lv, "#e-3 .q-tr-fold", "more line")
    end

    test "a live run adds its lines as they arrive", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.text", %{"session_id" => "s", "kind" => "text", "text" => "First"}},
          {4, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      assert has_element?(lv, "#e-3", "First")

      project_more(run, [
        {5, "runtime.text", %{"session_id" => "s", "kind" => "text", "text" => "Second"}}
      ])

      flush(lv)
      assert has_element?(lv, "#e-5", "Second")
    end

    test "a live run's turn end leaves the Transcript when the turn's text arrives", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.turn_finished", %{"session_id" => "s", "message" => "Hi, Dana"}},
          {4, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      # No text yet, so the turn's end shows the turn's message.
      assert has_element?(lv, "#e-3", "Hi, Dana")

      project_more(run, [
        {5, "runtime.text", %{"session_id" => "s", "kind" => "text", "text" => "Hi, Dana"}}
      ])

      html = flush(lv)
      refute has_element?(lv, "#e-3")
      assert has_element?(lv, "#e-5", "Hi, Dana")
      assert length(String.split(html, "Hi, Dana")) == 2
    end

    test "a subagent's prompt is a prompt, and its call's result follows the subagent's lines",
         %{conn: conn, scope: scope} do
      agent = %{"session_id" => "s", "agent_id" => "agent-a1", "agent_type" => "Explore"}

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.tool_started",
           %{"session_id" => "s", "tool" => "Task", "tool_use_id" => "t", "input" => %{}}},
          {4, "runtime.subagent_started", agent},
          {5, "runtime.text",
           Map.merge(agent, %{"kind" => "text", "role" => "user", "text" => "Report the kernel"})},
          {6, "runtime.tool_started",
           Map.merge(agent, %{"tool" => "Bash", "tool_use_id" => "b", "input" => %{}})},
          {7, "runtime.tool_result",
           %{"session_id" => "s", "tool_use_id" => "b", "content" => "7.0.0"}},
          {8, "runtime.text",
           Map.merge(agent, %{"kind" => "text", "role" => "assistant", "text" => "Linux 7.0.0"})},
          {9, "runtime.tool_result",
           %{"session_id" => "s", "tool_use_id" => "t", "content" => "Linux 7.0.0 for Dana"}},
          {10, "runtime.tool_finished",
           %{"session_id" => "s", "tool" => "Task", "tool_use_id" => "t", "input" => %{}}},
          {11, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, html} = terminal(conn, scope, run)

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#transcript > li")
             |> LazyHTML.attribute("id") ==
               ["e-3", "e-4", "e-5", "e-6", "e-8", "e-9"]

      assert has_element?(lv, "#e-5.q-tr-prompt.q-tr-sub", "Report the kernel")
      refute has_element?(lv, "#e-3 .q-tr-out")
      assert has_element?(lv, ~s(#e-9[data-part="result"] .q-tr-ln), "Linux 7.0.0 for Dana")
      refute has_element?(lv, "#e-9.q-tr-sub")

      # The Transcript's bar: its end (a live run: Following) and Wrap, beside Raw's.
      assert has_element?(lv, ~s(#terminal-bar [data-tr-end][aria-pressed="true"]), "Following")
      assert has_element?(lv, ~s(#terminal-bar [data-tr-wrap][aria-pressed="false"]), "Wrap")

      {:ok, timeline, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(timeline, "#e-5 .q-k", "Prompt")
      refute has_element?(timeline, "#e-5 .q-k", "Text")
    end

    test "a pseudo-terminal run with runtime events opens in Raw, with the Transcript", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data(%{"interactive" => true})},
          {3, "runtime.tool_started",
           %{"session_id" => "s", "tool" => "Read", "tool_use_id" => "a", "input" => %{}}},
          {4, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\r\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      assert has_element?(lv, ~s(#terminal[data-pty="true"][data-view="raw"]))
      assert has_element?(lv, ~s(#terminal-bar [data-view-button="transcript"]))
      assert has_element?(lv, "#e-3.q-tr-tool", "Read")
    end
  end

  describe "the Transcript's subagents" do
    defp agent(id, type), do: %{"session_id" => "s", "agent_id" => id, "agent_type" => type}

    defp call(seq, agent, id, tool),
      do:
        {seq, "runtime.tool_started",
         Map.merge(agent, %{"tool" => tool, "tool_use_id" => id, "input" => %{}})}

    defp transcript_ids(lv) do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#transcript > li")
      |> LazyHTML.attribute("id")
    end

    defp said(lv, selector) do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/u, " ") |> String.trim()))
    end

    test "subagents at once: lines under their start, closed at the finish, as the reader chose",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")
      a2 = agent("a2", "general-purpose")

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, main, "t1", "Task"),
          call(4, main, "t2", "Task"),
          {5, "runtime.subagent_started", a1},
          {6, "runtime.subagent_started", a2},
          call(7, a1, "g1", "Grep"),
          call(8, a2, "b1", "Bash"),
          {9, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)

      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-7 e-6 e-8)
      assert said(lv, "#terminal-subagents .q-tr-subs") == ["2 subagents, 2 running"]
      assert said(lv, "#e-5 .q-tr-head") == ["Explore · running · 1 call so far"]
      assert said(lv, "#e-5 .q-tr-fold") == ["Hide 1 call"]
      assert has_element?(lv, ~s(#e-7.q-tr-in[data-group="5"]))

      # A line of the first subagent arrives after the second one's: it goes under its start.
      project_more(run, [call(10, a1, "r1", "Read")])
      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-7 e-10 e-6 e-8)
      assert said(lv, "#e-5 .q-tr-head") == ["Explore · running · 2 calls so far"]

      # The first finishes: its lines close to one line with its message.
      project_more(run, [
        {11, "runtime.subagent_finished", Map.put(a1, "message", "Orders store an ISO code.")}
      ])

      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-6 e-8)
      assert said(lv, "#e-5 .q-tr-head") == ["Explore · finished in 6 s · 2 calls"]
      assert said(lv, "#e-5 .q-tr-ln") == ["Orders store an ISO code."]
      assert said(lv, "#e-5 .q-tr-fold") == ["Show 2 calls"]
      assert said(lv, "#terminal-subagents .q-tr-subs") == ["2 subagents, 1 running"]

      # The reader closes the running one: its lines stay closed while they arrive.
      lv |> element("#e-6 .q-tr-caret") |> render_click()
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-6)
      assert has_element?(lv, ~s(#e-6 .q-tr-caret[aria-expanded="false"]))

      project_more(run, [call(12, a2, "b2", "Bash")])
      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-6)
      assert said(lv, "#e-6 .q-tr-head") == ["general-purpose · running · 2 calls so far"]
      assert said(lv, "#e-6 .q-tr-fold") == ["Show 2 calls"]

      # Show opens a finished one.
      lv |> element("#e-5 .q-tr-fold", "Show 2 calls") |> render_click()
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-7 e-10 e-6)
      assert said(lv, "#e-5 .q-tr-fold") == ["Hide 2 calls"]

      # Expand all opens every one, and the choice stays after the second one's finish.
      lv |> element("#terminal-subagents button", "Expand all") |> render_click()
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-7 e-10 e-6 e-8 e-12)

      project_more(run, [
        {13, "runtime.subagent_finished", Map.put(a2, "message", "6 tests pass.")}
      ])

      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-7 e-10 e-6 e-8 e-12)
      assert said(lv, "#e-6 .q-tr-head") == ["general-purpose · finished in 7 s · 2 calls"]
      assert said(lv, "#terminal-subagents .q-tr-subs") == ["2 subagents, 0 running"]

      lv |> element("#terminal-subagents button", "Collapse all") |> render_click()
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5 e-6)
    end

    test "a run without subagents has no subagents in the bar", %{conn: conn, scope: scope} do
      run = projected(scope, runtime_record())
      {:ok, lv, _html} = terminal(conn, scope, run)
      refute has_element?(lv, "#terminal-subagents")
      assert has_element?(lv, "#terminal-bar [data-tr-end]")
    end

    test "a long subagent opens a window of its lines, and earlier ones load in place",
         %{conn: conn, scope: scope} do
      a1 = agent("a1", "Explore")

      events =
        [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, %{"session_id" => "s"}, "t1", "Task"),
          {4, "runtime.subagent_started", a1}
        ] ++
          for(n <- 5..904, do: call(n, a1, "c#{n}", "Read")) ++
          [{905, "runtime.subagent_finished", Map.put(a1, "message", "Read them all.")}] ++
          for(
            n <- 906..1005,
            do: {n, "runtime.text", %{"session_id" => "s", "kind" => "text", "text" => "t#{n}"}}
          ) ++
          [
            {1006, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}},
            {1007, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
          ]

      run = projected(scope, events)
      {:ok, lv, _html} = terminal(conn, scope, run)

      ids = transcript_ids(lv)
      assert length(ids) == 102
      assert Enum.take(ids, 3) == ~w(e-3 e-4 e-906)
      assert said(lv, "#e-4 .q-tr-fold") == ["Show 900 calls"]
      assert said(lv, "#terminal-subagents .q-tr-subs") == ["1 subagent, 0 running"]
      refute has_element?(lv, "#transcript-earlier")

      # Opened, the window keeps its start and has at most what the page keeps.
      lv |> element("#e-4 .q-tr-fold") |> render_click()
      ids = transcript_ids(lv)
      assert length(ids) == 600
      assert Enum.take(ids, 3) == ~w(e-3 e-4 e-5) and List.last(ids) == "e-602"
      assert has_element?(lv, "#transcript-later", "402 later events")

      lv |> element("#transcript-later") |> render_click()
      ids = transcript_ids(lv)
      assert length(ids) == 600
      assert hd(ids) == "e-203" and List.last(ids) == "e-802"
      assert has_element?(lv, "#transcript-earlier", "200 earlier events")

      lv |> element("#transcript-earlier") |> render_click()
      ids = transcript_ids(lv)
      assert hd(ids) == "e-3" and List.last(ids) == "e-602"

      # Closed again from the bar, the window starts where it did.
      lv |> element("#terminal-subagents button", "Collapse all") |> render_click()
      assert length(transcript_ids(lv)) == 102

      # Closed after Load newer, when the window starts inside the subagent's lines: the
      # window is filled from before its start.
      lv |> element("#terminal-subagents button", "Expand all") |> render_click()
      lv |> element("#transcript-later") |> render_click()
      assert hd(transcript_ids(lv)) == "e-203"

      lv |> element("#terminal-subagents button", "Collapse all") |> render_click()
      ids = transcript_ids(lv)
      assert length(ids) == 102 and Enum.take(ids, 2) == ~w(e-3 e-4)
      refute has_element?(lv, "#transcript-earlier")
    end

    test "a subagent that closes at the end of the window leaves the end followed",
         %{conn: conn, scope: scope} do
      a1 = agent("a1", "Explore")
      main = %{"session_id" => "s"}

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, main, "t1", "Task"),
          {4, "runtime.subagent_started", a1},
          call(5, a1, "g1", "Grep"),
          {6, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      assert transcript_ids(lv) == ~w(e-3 e-4 e-5)

      project_more(run, [{7, "runtime.subagent_finished", Map.put(a1, "message", "Found.")}])
      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4)

      # The window ends at the head now, so a line after it is added at the end.
      project_more(run, [
        {8, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Next."})}
      ])

      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4 e-8)
    end

    test "a window of a subagent's lines alone is drawn again when the subagent closes",
         %{conn: conn, scope: scope} do
      a1 = agent("a1", "Explore")

      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "session.started", session_started_data()},
            call(3, %{"session_id" => "s"}, "t1", "Task"),
            {4, "runtime.subagent_started", a1}
          ] ++
            for(n <- 5..804, do: call(n, a1, "c#{n}", "Read")) ++
            [{805, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}]
        )

      {:ok, lv, _html} = terminal(conn, scope, run)
      lv |> element("#transcript-later") |> render_click()
      lv |> element("#transcript-later") |> render_click()
      ids = transcript_ids(lv)
      assert length(ids) == 600 and hd(ids) == "e-103"

      project_more(run, [{806, "runtime.subagent_finished", Map.put(a1, "message", "Read.")}])
      flush(lv)
      assert transcript_ids(lv) == ~w(e-3 e-4)
      assert said(lv, "#e-4 .q-tr-fold") == ["Show 800 calls"]
    end

    test "a result the reader opened stays open when a subagent opens or closes",
         %{conn: conn, scope: scope} do
      a1 = agent("a1", "Explore")
      main = %{"session_id" => "s"}

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, main, "a", "Bash"),
          {4, "runtime.tool_result",
           Map.merge(main, %{
             "tool_use_id" => "a",
             "content" => Enum.map_join(1..5, "\n", &"line #{&1}")
           })},
          {5, "runtime.subagent_started", a1},
          call(6, a1, "g1", "Grep"),
          {7, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("x\n")}}
        ])

      {:ok, lv, _html} = terminal(conn, scope, run)
      lv |> element("#e-3 .q-tr-fold", "2 more lines") |> render_click()
      assert has_element?(lv, "#e-3 .q-tr-ln", "line 5")

      lv |> element("#e-5 .q-tr-caret") |> render_click()
      assert transcript_ids(lv) == ~w(e-3 e-5)
      assert has_element?(lv, "#e-3 .q-tr-ln", "line 5")
    end
  end

  describe "the Timeline's subagents" do
    # Two subagents at once: Explore (a1) finishes at 9, general-purpose (a2) runs. Each
    # has a text the Timeline lists; the Task calls that start them are the Terminal's only.
    defp two_subagents(scope) do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")
      a2 = agent("a2", "general-purpose")

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, main, "t1", "Task"),
          call(4, main, "t2", "Task"),
          {5, "runtime.subagent_started", a1},
          {6, "runtime.subagent_started", a2},
          {7, "runtime.text", Map.merge(a1, %{"kind" => "text", "text" => "Orders."})},
          {8, "runtime.text", Map.merge(a2, %{"kind" => "text", "text" => "Steps."})},
          {9, "runtime.subagent_finished",
           Map.put(a1, "message", "Orders store an ISO code.\nThe receipt reads it.")},
          {10, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Next."})}
        ])

      {run, a2}
    end

    defp timeline_ids(lv), do: lv |> render() |> item_ids()

    test "a finished subagent is one closed row; a running one is open; each keeps its rail",
         %{conn: conn, scope: scope} do
      {run, a2} = two_subagents(scope)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)

      assert said(lv, "#e-5 .q-sub-said > span") == ["Explore", "0 calls"]
      assert said(lv, "#e-5 .q-tct") == ["4 s"]
      assert said(lv, "#e-5 .q-hd > .q-s") == ["Orders store an ISO code."]
      assert has_element?(lv, ~s(#e-5 .q-sub-caret[aria-expanded="false"]))

      assert said(lv, "#e-6 .q-sub-said > span") == [
               "general-purpose",
               "running · 0 calls so far"
             ]

      assert has_element?(lv, ~s(#e-6 .q-sub-caret[aria-expanded="true"]))
      refute has_element?(lv, "#e-5 .q-k", "Subagent started")

      # The closed one's rail is not drawn; its branch is, and the running one stays on the
      # second rail.
      assert has_element?(lv, "#e-5 .q-h.q-rail-1")
      refute has_element?(lv, "#e-5 .q-r.q-rail-1")
      refute has_element?(lv, "#e-6 .q-r.q-rail-1")
      refute has_element?(lv, "#e-8 .q-r.q-rail-1")
      assert has_element?(lv, "#e-6 .q-n.q-rail-2")
      assert has_element?(lv, "#e-8 .q-n.q-rail-2")
      assert has_element?(lv, "ol.q-lanes-3")

      # The running one finishes: it closes.
      project_more(run, [{11, "runtime.subagent_finished", Map.put(a2, "message", "Done.")}])
      flush(lv)
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-10)

      assert said(lv, "#e-6 .q-sub-said > span") == ["general-purpose", "0 calls"]
      assert said(lv, "#e-6 .q-tct") == ["5 s"]

      assert has_element?(lv, ~s(#e-6 .q-sub-caret[aria-expanded="false"]))
    end

    test "the chevron opens a subagent's items in time order, and closes them",
         %{conn: conn, scope: scope} do
      {run, a2} = two_subagents(scope)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      lv |> element("#e-5 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-7 e-8 e-9 e-10)
      assert has_element?(lv, ~s(#e-5 .q-sub-caret[aria-expanded="true"]))
      assert has_element?(lv, "#e-5 .q-r.q-rail-1.q-r-from")
      assert has_element?(lv, "#e-6 .q-r.q-rail-1")
      assert has_element?(lv, "#e-9 .q-k", "Subagent finished")

      lv |> element("#e-5 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)
      refute has_element?(lv, "#e-6 .q-r.q-rail-1")

      # The reader closes the running one: its items stay closed while they arrive.
      lv |> element("#e-6 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-10)

      project_more(run, [
        {11, "runtime.text", Map.merge(a2, %{"kind" => "text", "text" => "More."})},
        call(12, a2, "b2", "Bash")
      ])

      flush(lv)
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-10)

      assert said(lv, "#e-6 .q-sub-said > span") == [
               "general-purpose",
               "running · 1 call so far"
             ]
    end

    test "?seq= on an item of a closed subagent opens it", %{conn: conn, scope: scope} do
      {run, _a2} = two_subagents(scope)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, lv, _html} = live(conn, path <> "?seq=7")
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-7 e-8 e-9 e-10)
      assert has_element?(lv, ~s(ol#timeline[data-target="e-7"]))
      assert has_element?(lv, ~s(#e-5 .q-sub-caret[aria-expanded="true"]))

      # The reader can close it again, and it stays closed while another parameter
      # changes: Connections inline here.
      lv |> element("#e-5 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)
      render_patch(lv, path <> "?seq=7&cx=1")
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)

      # A link to its finish, followed on the page, opens it again.
      render_patch(lv, path <> "?seq=9")
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-7 e-8 e-9 e-10)
      assert has_element?(lv, ~s(ol#timeline[data-target="e-9"]))
    end

    test "?lane= on a closed subagent's lane opens it; main opens none",
         %{conn: conn, scope: scope} do
      {run, _a2} = two_subagents(scope)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      {:ok, lv, _html} = live(conn, path <> "?lane=main")
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)

      render_patch(lv, path <> "?lane=a1")
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-7 e-8 e-9 e-10)
      assert has_element?(lv, ~s(ol#timeline[data-isolate="a1"]))
      assert has_element?(lv, ~s(#e-7[data-lane="a1"]))

      # Closed by the reader, it stays closed while another parameter changes.
      lv |> element("#e-5 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)
      render_patch(lv, path <> "?lane=a1&cx=1")
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)
    end

    test "an agent on a shared rail keeps the rail when the rail's subagent closes",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      [o1, o2, o3, o4] = for n <- 1..4, do: agent("o#{n}", "Explore")

      # Four at once: o1 to o3 have rails 1 to 3, o4 shares rail 3, o3's.
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, main, "t1", "Task"),
          {4, "runtime.subagent_started", o1},
          {5, "runtime.subagent_started", o2},
          {6, "runtime.subagent_started", o3},
          {7, "runtime.subagent_started", o4},
          {8, "runtime.text", Map.merge(o4, %{"kind" => "text", "text" => "One."})},
          {9, "runtime.subagent_finished", Map.put(o3, "message", "Done.")},
          {10, "runtime.text", Map.merge(o4, %{"kind" => "text", "text" => "Two."})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert timeline_ids(lv) == ~w(e-1 e-4 e-5 e-6 e-7 e-8 e-10)
      assert has_element?(lv, ~s(#e-6 .q-sub-caret[aria-expanded="false"]))
      refute has_element?(lv, "#e-6 .q-r.q-rail-3")
      assert has_element?(lv, "#e-7 .q-n.q-rail-3")
      assert has_element?(lv, "#e-7 .q-r.q-rail-3")
      assert has_element?(lv, "#e-8 .q-n.q-rail-3")
      assert has_element?(lv, "#e-8 .q-r.q-rail-3")
    end

    test "the last row fades the rails when the run's last event is hidden",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")
      a2 = agent("a2", "general-purpose")

      # The record is still being written; its last event is a1's finish, hidden.
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          call(3, main, "t1", "Task"),
          {4, "runtime.subagent_started", a1},
          {5, "runtime.subagent_started", a2},
          {6, "runtime.text", Map.merge(a2, %{"kind" => "text", "text" => "Steps."})},
          {7, "runtime.text", Map.merge(a1, %{"kind" => "text", "text" => "Orders."})},
          {8, "runtime.subagent_finished", Map.put(a1, "message", "Found.")}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert timeline_ids(lv) == ~w(e-1 e-4 e-5 e-6)
      assert has_element?(lv, "#e-6 .q-r.q-rail-0.q-r-live")
      refute has_element?(lv, "#e-5 .q-r-live")

      # The reader closes a2: its head is the last row now.
      lv |> element("#e-5 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-4 e-5)
      assert has_element?(lv, "#e-5 .q-r.q-rail-0.q-r-live")

      # Opened, a1's finish is the last row, with the fade it always had.
      lv |> element("#e-4 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-4 e-5 e-7 e-8)
      assert has_element?(lv, "#e-8 .q-r.q-rail-0.q-r-live")
      refute has_element?(lv, "#e-5 .q-r-live")
    end

    test "a subagent the reader opened stays open when it finishes",
         %{conn: conn, scope: scope} do
      {run, a2} = two_subagents(scope)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # At the live end, closed and opened again by the reader.
      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})
      lv |> element("#e-6 .q-sub-caret") |> render_click()
      lv |> element("#e-6 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10)

      project_more(run, [{11, "runtime.subagent_finished", Map.put(a2, "message", "Done.")}])
      flush(lv)
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-8 e-10 e-11)
      assert has_element?(lv, ~s(#e-6 .q-sub-caret[aria-expanded="true"]))
    end

    test "a subagent opens in place while new events wait under the pill",
         %{conn: conn, scope: scope} do
      {run, _a2} = two_subagents(scope)
      main = %{"session_id" => "s"}

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # Away from the live end, two events of main arrive and wait.
      project_more(run, [
        {11, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "One."})},
        {12, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Two."})}
      ])

      flush(lv)
      assert has_element?(lv, "#new-events.q-newpill-show", "2 new events")

      lv |> element("#e-5 .q-sub-caret") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-7 e-8 e-9 e-10)
      assert has_element?(lv, "#new-events.q-newpill-show", "2 new events")
      refute has_element?(lv, "#timeline-later")

      lv |> element("#new-events") |> render_click()
      assert timeline_ids(lv) == ~w(e-1 e-5 e-6 e-7 e-8 e-9 e-10 e-11 e-12)
      refute has_element?(lv, "#new-events.q-newpill-show")
    end

    test "a subagent opens and closes inside a window in the middle of the Timeline",
         %{conn: conn, scope: scope} do
      a1 = agent("a1", "Explore")
      main = %{"session_id" => "s"}
      text = &{&1, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "t#{&1}"})}

      run =
        projected(
          scope,
          [{1, "run.started", started_data()}, {2, "session.started", session_started_data()}] ++
            Enum.map(3..402, text) ++
            [call(403, main, "t1", "Task"), {404, "runtime.subagent_started", a1}] ++
            for(n <- 405..414, do: call(n, a1, "c#{n}", "Read")) ++
            [{415, "runtime.subagent_finished", Map.put(a1, "message", "Read.")}] ++
            Enum.map(416..815, text) ++
            [{816, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}]
        )

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"

      # 804 rows closed; a window of 300 around the head.
      {:ok, lv, _html} = live(conn, path <> "?seq=404")
      ids = timeline_ids(lv)
      assert length(ids) == 300 and hd(ids) == "e-254" and List.last(ids) == "e-564"
      assert has_element?(lv, "#timeline-earlier", "252 earlier events")
      assert has_element?(lv, "#timeline-later", "252 later events")
      assert has_element?(lv, ~s(ol#timeline[data-until="564"]))

      # Opened: its 11 rows come in after the head; the window keeps both ends.
      lv |> element("#e-404 .q-sub-caret") |> render_click()
      ids = timeline_ids(lv)
      at = Enum.find_index(ids, &(&1 == "e-404"))
      assert length(ids) == 311 and hd(ids) == "e-254" and List.last(ids) == "e-564"
      assert Enum.slice(ids, at, 13) == Enum.map(404..416, &"e-#{&1}")
      assert has_element?(lv, "#timeline-earlier", "252 earlier events")
      assert has_element?(lv, "#timeline-later", "252 later events")

      # Closed: the window is as it was, and earlier rows load in order before it.
      lv |> element("#e-404 .q-sub-caret") |> render_click()
      ids = timeline_ids(lv)
      assert length(ids) == 300 and hd(ids) == "e-254" and List.last(ids) == "e-564"

      lv |> element("#timeline-earlier") |> render_click()
      ids = timeline_ids(lv)
      assert hd(ids) == "e-54" and List.last(ids) == "e-564" and length(ids) == 500
      assert has_element?(lv, "#timeline-earlier", "52 earlier events")
    end

    test "x and Shift+x open a closed subagent for its denied call", %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")

      denied =
        egress_data(%{
          "host" => "registry.example",
          "decision" => "denied",
          "outcome" => "refused",
          "rule" => ""
        })

      # a1's call at 4 had a connection denied while it was the one call open.
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "runtime.subagent_started", a1},
          call(4, a1, "b1", "Bash"),
          {5, "run.egress", denied},
          {6, "runtime.tool_finished", Map.merge(a1, %{"tool" => "Bash", "tool_use_id" => "b1"})},
          {7, "runtime.subagent_finished", Map.put(a1, "message", "Blocked.")},
          {8, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Next."})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # Closed and finished, its head has the call for the keys; the window is the tab.
      assert timeline_ids(lv) == ~w(e-1 e-3 e-8)
      assert has_element?(lv, ~s(#e-3[data-hidden-denied="4"]))
      refute has_element?(lv, "ol#timeline[data-until]")

      # x from the run's start: the subagent opens, and the call is on the page.
      render_hook(element(lv, "#timeline"), "subagent_open", %{"seq" => "4"})
      assert timeline_ids(lv) == ~w(e-1 e-3 e-4 e-7 e-8)
      assert has_element?(lv, ~s(#e-4[data-denied="1"]))
      assert has_element?(lv, ~s(#e-3 .q-sub-caret[aria-expanded="true"]))
      refute has_element?(lv, "#e-3[data-hidden-denied]")

      # Closed again, then Shift+x from the row after it opens it the same way.
      lv |> element("#e-3 .q-sub-caret") |> render_click()
      assert has_element?(lv, ~s(#e-3[data-hidden-denied="4"]))
      render_hook(element(lv, "#timeline"), "subagent_open", %{"seq" => "4"})
      assert timeline_ids(lv) == ~w(e-1 e-3 e-4 e-7 e-8)

      # The key closes nothing: a second one leaves the subagent open.
      render_hook(element(lv, "#timeline"), "subagent_open", %{"seq" => "4"})
      assert has_element?(lv, ~s(#e-3 .q-sub-caret[aria-expanded="true"]))
    end

    test "a link to an event far into a closed subagent shows the window around the event",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")
      said = &{&1, "runtime.text", Map.merge(a1, %{"kind" => "text", "text" => "t#{&1}"})}

      # a1 has 700 lines: opened, the line at 690 is past the 600 rows the page keeps
      # from the window's first row.
      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "session.started", session_started_data()},
            {3, "runtime.subagent_started", a1}
          ] ++
            Enum.map(4..703, said) ++
            [
              {704, "runtime.subagent_finished", Map.put(a1, "message", "Read.")},
              {705, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Next."})}
            ]
        )

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)
      assert timeline_ids(lv) == ~w(e-1 e-3 e-705)

      # The link, on the loaded Timeline: the subagent opens, and the page has only the
      # window around the line.
      render_patch(lv, path <> "?seq=690")
      ids = timeline_ids(lv)
      assert length(ids) == 300 and "e-690" in ids and List.last(ids) == "e-705"
      assert has_element?(lv, "#timeline-earlier")
    end

    test "a link to a thinking event far into a closed subagent shows the rows around it",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")

      said = fn
        690 -> {690, "runtime.text", Map.merge(a1, %{"kind" => "thinking", "text" => "t690"})}
        n -> {n, "runtime.text", Map.merge(a1, %{"kind" => "text", "text" => "t#{n}"})}
      end

      # The Timeline has no row for the thinking at 690: its row is the line at 691, for a
      # reader of the log and for any other reader.
      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "session.started", session_started_data()},
            {3, "runtime.subagent_started", a1}
          ] ++
            Enum.map(4..703, said) ++
            [
              {704, "runtime.subagent_finished", Map.put(a1, "message", "Read.")},
              {705, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Next."})}
            ]
        )

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)
      assert timeline_ids(lv) == ~w(e-1 e-3 e-705)

      for hidden <- [[], [:"observability.terminal"]] do
        :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
        :ok = Apiary.EditionStubs.HidesNamed.put(hidden)
        {:ok, lv, _html} = live(conn, path)
        render_patch(lv, path <> "?seq=690")
        assert has_element?(lv, "#run-tab a#run-tab-timeline[aria-current='page']")
        ids = timeline_ids(lv)
        seqs = Enum.map(ids, &(&1 |> String.trim_leading("e-") |> String.to_integer()))
        assert length(ids) == 300 and seqs == Enum.sort(seqs)
        assert "e-691" in ids and List.last(ids) == "e-705"
      end
    end

    test "x moves the window to a denied call past what the page keeps of its subagent",
         %{conn: conn, scope: scope} do
      main = %{"session_id" => "s"}
      a1 = agent("a1", "Explore")
      said = &{&1, "runtime.text", Map.merge(a1, %{"kind" => "text", "text" => "t#{&1}"})}

      denied =
        egress_data(%{
          "host" => "registry.example",
          "decision" => "denied",
          "outcome" => "refused",
          "rule" => ""
        })

      # a1 has 700 lines, then a call at 704 with a connection denied: opened, the call
      # is the 703rd row, past the 600 the page keeps from the window's first row.
      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "session.started", session_started_data()},
            {3, "runtime.subagent_started", a1}
          ] ++
            Enum.map(4..703, said) ++
            [
              call(704, a1, "b1", "Bash"),
              {705, "run.egress", denied},
              {706, "runtime.tool_finished",
               Map.merge(a1, %{"tool" => "Bash", "tool_use_id" => "b1"})},
              {707, "runtime.subagent_finished", Map.put(a1, "message", "Blocked.")},
              {708, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "Next."})}
            ]
        )

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert timeline_ids(lv) == ~w(e-1 e-3 e-708)
      assert has_element?(lv, ~s(#e-3[data-hidden-denied="704"]))

      # x: the subagent opens, and the window is drawn again around the call.
      render_hook(element(lv, "#timeline"), "subagent_open", %{"seq" => "704"})
      ids = timeline_ids(lv)
      assert "e-704" in ids and length(ids) == 300
      assert has_element?(lv, ~s(#e-704[data-denied="1"]))
      assert has_element?(lv, "#timeline-earlier")
    end

    test "the window counts only the rows on the page", %{conn: conn, scope: scope} do
      a1 = agent("a1", "Explore")
      main = %{"session_id" => "s"}

      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "session.started", session_started_data()},
            call(3, main, "t1", "Task"),
            {4, "runtime.subagent_started", a1}
          ] ++
            for(n <- 5..904, do: call(n, a1, "c#{n}", "Read")) ++
            [{905, "runtime.subagent_finished", Map.put(a1, "message", "Read them all.")}] ++
            for(
              n <- 906..1005,
              do: {n, "runtime.text", Map.merge(main, %{"kind" => "text", "text" => "t#{n}"})}
            ) ++
            [
              {1006, "run.exited",
               %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
            ]
        )

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)

      # Closed: 3 rows (the session's start is in the run's), the 100 texts and the run's
      # end, every one on the page.
      ids = timeline_ids(lv)
      assert length(ids) == 104 and Enum.take(ids, 4) == ~w(e-1 e-3 e-4 e-906)
      refute has_element?(lv, "#timeline-later")
      assert has_element?(lv, "ol#timeline[aria-label='Session timeline, oldest first']")

      # Opened: 1,005 rows; the window keeps its start and what the page keeps.
      lv |> element("#e-4 .q-sub-caret") |> render_click()
      ids = timeline_ids(lv)
      assert length(ids) == 600 and hd(ids) == "e-1" and List.last(ids) == "e-601"
      assert has_element?(lv, "#timeline-later", "405 later events")

      # Closed again: every row is in the window again.
      lv |> element("#e-4 .q-sub-caret") |> render_click()
      assert length(timeline_ids(lv)) == 104
      refute has_element?(lv, "#timeline-later")

      # The lane filter on the subagent opens it: its rows count.
      {:ok, lv, _html} = live(conn, path <> "?lane=a1")
      assert length(timeline_ids(lv)) == 300
      assert has_element?(lv, "#timeline-later", "705 later events")
    end
  end

  describe "the terminal tab (P1)" do
    test "the box points the hook at the log endpoint and carries numbers, never bytes", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert has_element?(
               lv,
               "#terminal[phx-hook='Terminal'][data-src='#{workspace_path(scope)}/runs/#{run.number}/log']"
             )

      assert has_element?(lv, "#terminal[data-live='false']")
      assert has_element?(lv, "#terminal [data-stream='stdout']")
      assert has_element?(lv, "#terminal [data-stream='stderr']")
      assert has_element?(lv, "#terminal [role='log'][aria-live='off']")

      assert has_element?(
               lv,
               "#terminal a[href='#{workspace_path(scope)}/runs/#{run.number}/log?download=1']"
             )

      assert html =~ "Ended"
      assert html =~ "chunks"
      assert html =~ "through #0101"
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

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

      # a run on pipes with a session has the two views, Transcript first, and search's label
      # shows what it switches to
      assert has_element?(lv, ~s(#terminal[data-pty="false"][data-view="transcript"]))
      assert has_element?(lv, ~s(#terminal-bar [data-view-button="transcript"]), "Transcript")
      assert has_element?(lv, ~s(#terminal-bar [data-view-button="raw"]), "Raw")
      assert has_element?(lv, "#terminal-bar .q-term-find", "Searching shows the Raw view.")
      # the Transcript has its end and Wrap too, which show only in the Transcript
      assert has_element?(lv, ~s(#terminal-bar .q-term-trv[data-tr-end]), "Jump to end")
      assert has_element?(lv, ~s(#terminal-bar .q-term-trv[data-tr-wrap]), "Wrap")
      refute has_element?(lv, "#terminal-bar", "Collapsed")

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
      assert words["kilobytes"] == "%{number} kB"
    end

    test "a run with a recorded size replays at it: the size on the box, no wrap", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started",
           session_started_data(%{
             "interactive" => true,
             "terminal" => %{"cols" => 120, "rows" => 40}
           })},
          {3, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\r\n")}},
          {4, "run.resized", %{"cols" => 100, "rows" => 30}},
          {5, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert has_element?(lv, "#terminal[data-sized='true'][data-cols='100'][data-rows='30']")
      assert has_element?(lv, "#terminal [data-size]", "100×30")
      refute has_element?(lv, "#terminal [data-wrap]")
      assert has_element?(lv, "#terminal [data-size-fit]")
      assert html =~ "drawn at the columns they were recorded at"
      # a pseudo-terminal's log is cursor movement: it stays raw, with no choice of view
      assert has_element?(lv, ~s(#terminal[data-pty="true"]))
      refute has_element?(lv, "#terminal [data-view]")
      refute html =~ "Searching shows the Raw view."

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      assert html =~ "Yes, on a pseudo-terminal"
      assert html =~ "100×30"
    end

    test "a live run tails: the page says how far the log advanced", %{conn: conn, scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: now},
          {2, "session.started", session_started_data(%{"interactive" => true}), time: now},
          {3, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("one\n")}, time: now}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert html =~ "Live"
      assert has_element?(lv, "#terminal .q-tseg-one", "terminal")
      assert has_element?(lv, "#terminal [data-follow][aria-pressed='true']")

      project_more(run, [
        {4, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("two\n")}, time: now}
      ])

      html = flush(lv)

      assert_push_event(lv, "log_advanced", %{through: 4})
      assert html =~ "through #0004"
      assert html =~ "2 chunks"
    end

    test "no output: yet, for a live run; none, for an ended one", %{conn: conn, scope: scope} do
      live_run = projected(scope, [{1, "run.started", started_data(), time: DateTime.utc_now()}])

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{live_run.number}/terminal"
        )

      assert html =~ "No output yet"

      ended =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{ended.number}/terminal")

      assert html =~ "This run wrote no output"
    end
  end

  describe "the connections tab (C1, C3)" do
    test "a row of the stack proxy says it fetched the harness; a session row does not", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.egress", egress_data(%{"host" => "git.example", "channel" => "stack"})},
          {3, "run.egress", egress_data(%{"host" => "api.example"})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      rows =
        Repo.all(
          from c in Apiary.Runs.Connection,
            where: c.run_id == ^run.id,
            select: {c.host, c.id}
        )
        |> Map.new()

      assert has_element?(lv, "#cx-#{rows["git.example"]}-stack", "Harness fetch")
      refute has_element?(lv, "#cx-#{rows["api.example"]}-stack")
    end

    @tag :feature_sets
    test "one row per destination, denied first, with the reason and the outcome", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "session-with-subagents")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

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
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network?decision=denied"
      )

      html = render(lv)
      refute html =~ "git-upload-pack"
      assert html =~ "registry.example"

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network?decision=maybe"
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      assert hosts.(html) =~ ~r/second\.example.*first\.example/s

      # the first host is refused again, later than the second: it stays below it
      project_more(run, [{4, "run.egress", denied.("first.example"), time: at.(30)}])

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      assert hosts.(html) =~ ~r/second\.example.*first\.example/s
    end

    @tag :feature_sets
    test "a tool invocation reads as a call to its tool, a refused request as a denial", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, tool_record())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      assert html =~ "No connections recorded"
      assert html =~ "No connection went through the gateway."
      refute html =~ "<table"
    end
  end

  describe "Details" do
    test "Details says the session once it started, on every tab", %{conn: conn, scope: scope} do
      now = DateTime.utc_now()
      record = "#run-details section[aria-labelledby=rail-record] dd.font-mono"

      for path <- ["/terminal", "/network", ""] do
        run =
          projected(scope, [
            {1, "run.started", started_data(), time: now},
            {2, "runtime.prompt_submitted", %{"prompt" => "go"}, time: now}
          ])

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}" <> path)

        assert has_element?(lv, record, "n/a")

        if path == "",
          do: render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

        project_more(run, [
          {3, "runtime.started", %{"session_id" => "session-0001"}, time: now}
        ])

        html = flush(lv)
        assert has_element?(lv, record, "session-0001")

        # Only the session is assigned: the Timeline's window is not read again, and it
        # follows the live end as before.
        if path == "" do
          assert item_ids(html) == ["e-1", "e-2", "main-session", "e-3"]
          refute has_element?(lv, "#new-events.q-newpill-show")
        end
      end
    end

    @tag :feature_sets
    test "the command, the policy in force and the record", %{conn: conn, scope: scope} do
      run = demo(scope, "session-with-subagents")

      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

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

      assert html =~ run.node_run_id
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
            do: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}, time: now}
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
      # The sidebar reads its Set up group again with each count of alive runs, once a
      # second while projections come, untagged. With the set-up finished it shows no such
      # group, so the count does not depend on how long the twenty projections take.
      Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
      {run, last, now} = live_run(scope, items)
      {:ok, lv, _html} = live(conn, "#{workspace_path(scope)}/runs/#{run.number}" <> path)

      handler = {__MODULE__, make_ref()}
      counter = :counters.new(2, [])
      page = lv.pid

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # The sidebar's count of alive runs comes on a separate timer, in the page's
          # process; it is tagged, and is not what this budget is about. Who may sign up is
          # read from `ApiaryPro.SignUp.Cache` in production, which the tests start without,
          # so its row is not counted either.
          if self() == page and not (metadata[:options][:sidebar] == true) and
               metadata[:source] != "instance_sign_up" do
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
              {sequence, "runtime.notification", %{"kind" => "k", "message" => "new #{n}"},
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
          connections: "/network"
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
        |> get(~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")
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
          {2, "runtime.prompt_submitted", %{"prompt" => "go"}, time: now},
          {5, "runtime.turn_finished", %{"message" => "done"}, time: now}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert item_ids(html) == ["e-1", "e-2", "main-session", "e-5"]

      project_more(run, [
        {3, "runtime.notification", %{"kind" => "late", "message" => "late"}, time: now}
      ])

      assert lv |> flush() |> item_ids() == ["e-1", "e-2", "main-session", "e-3", "e-5"]
    end
  end

  describe "a call the record never ends" do
    setup %{scope: scope} do
      run =
        projected(scope, [
          {1, "runtime.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "sleep 9"}}},
          {2, "runtime.turn_finished", %{"message" => "done"}},
          {3, "runtime.ended", %{"reason" => "other"}},
          {4, "runtime.started", %{"source" => "resume"}},
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

    test "the later connection is an item at sequence 5, and ?seq=5 is that item", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=5")

      assert has_element?(lv, "ol#timeline[data-target='e-5']")
      assert has_element?(lv, "#e-5.q-ti-cx .q-cx-denied", "late.example")
      refute has_element?(lv, "#e-1 .q-during")
    end

    test "the call reads No end recorded, never Running", %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#e-1 .q-no-end", "No end recorded")
      refute has_element?(lv, "#e-1 .q-running")
      refute has_element?(lv, "#e-1 .q-spin")
    end

    test "on a run that has ended an open call is not Running either", %{conn: conn, scope: scope} do
      now = DateTime.utc_now()

      run =
        projected(scope, [
          {1, "run.started", started_data(), time: now},
          {2, "runtime.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "x"}}, time: now}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # Running, it is the Terminal's only; once the run ends with no end of the call, the
      # call is listed as a failure.
      refute has_element?(lv, "#e-2")
      render_hook(element(lv, "#live-end"), "live_end", %{"at_end" => true})

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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
              {n + 1, "runtime.subagent_started",
               %{"agent_id" => "agent-#{n}", "agent_type" => "Explore"}, time: now}
          )

      run = projected(scope, events)

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("button.q-lanekey")
             |> Enum.count() == 13

      assert has_element?(lv, "#more-lanes", "and 18 more")
      # ids are the lanes' numbers, not Forager's strings
      assert has_element?(lv, "button#lane-0", "Main session")
      assert has_element?(lv, "button#lane-12", "agent-12")

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?lane=agent-27"
        )

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

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
        ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network?page=2"
      )

      refute has_element?(lv, "#run-connections", "denied.example")

      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network?page=3"
        )

      assert html =~ "Showing 21 of 121."
      refute has_element?(lv, "#connections-pages a", "Next")

      # a page past the last is the last
      {:ok, lv, _html} =
        live(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network?page=99&decision=denied"
        )

      assert has_element?(lv, "#decision button[aria-pressed='true']", "Denied")
      assert render(lv) =~ "Showing 1 of 1."
    end
  end

  describe "no Close" do
    test "no run page offers a Close, whatever its state", %{
      conn: conn,
      scope: scope
    } do
      runs =
        for state <- ~w(running lost) do
          run = projected(scope, [{1, "run.started", started_data()}])
          if state == "lost", do: Apiary.Repo.update!(Ecto.Changeset.change(run, state: "lost"))
          run
        end

      for run <- [run_fixture(scope, %{state: "pending"}) | runs] do
        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      open_subagents(lv, [22, 23])
      assert has_element?(lv, "#e-37 .sr-only", "in Explore -demo-a1")
      assert has_element?(lv, "#e-50 .sr-only", "in general-purpose -demo-a2")
      refute has_element?(lv, "#e-59 .sr-only", "in ")
    end

    test "earlier items are announced, and the list only says oldest first when it starts at the start",
         %{conn: conn, scope: scope} do
      events =
        [{1, "run.started", started_data()}] ++
          for(
            n <- 2..400,
            do: {n, "runtime.notification", %{"kind" => "k", "message" => "m#{n}"}}
          )

      run = projected(scope, events)

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(
               lv,
               "ol#timeline[aria-label='Session timeline, in sequence order; 100 later events not loaded']"
             )

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=400")

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert has_element?(
               lv,
               "#terminal a.sr-only[href$='/log?download=1']",
               "Read the log as text"
             )

      assert has_element?(lv, "#terminal [data-announce][aria-live='polite']")
      # one tab stop: the input xterm makes, which the hook names with its keys
      refute has_element?(lv, "#terminal [data-screen][tabindex]")

      hook = File.read!(Path.expand("../../../../assets/js/hooks/terminal.js", __DIR__))
      assert hook =~ "screenReaderMode: false"
      refute hook =~ "screenReaderMode = "
      assert hook =~ "linkHandler"
    end
  end

  describe "a connection's host" do
    test "the wall refused for its form: marked in the timeline and the connections tab",
         %{conn: conn, scope: scope} do
      host = "Files\u202E.CDN\u200B.example."
      marked = "Files\uFFFD.CDN\uFFFD.example."

      refused =
        egress_data(%{
          "host" => host,
          "decision" => "denied",
          "outcome" => "refused",
          "rule" => "wall:host-form"
        })

      events = [{1, "run.started", started_data()}, {2, "run.egress", refused}]
      run = projected(scope, events)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      pages = [{path, "#e-2 .q-dest > bdi"}, {path <> "/network", ".q-cx-h > bdi"}]

      for {page, row} <- pages do
        {:ok, lv, _html} = live(conn, page)
        assert has_element?(lv, row, marked), page
        # Only what the row acts on and copies is the host as sent.
        shown = String.replace(render(lv), ~r{ (data-copy|phx-value-host)="[^"]*"}, "")
        refute shown =~ "\u202E", page
      end
    end

    test "is isolated in the timeline, its groups and the connections tab, so a bidi override reorders nothing",
         %{conn: conn, scope: scope} do
      host = "evil\u202Elpmaxe.<script>"
      # A group's summary and the rows drop the override (`Apiary.ExternalText`).
      shown = "evillpmaxe.<script>"
      shown_escaped = "evillpmaxe.&lt;script&gt;"

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.egress", egress_data(%{"host" => host, "rule" => ""})},
          {3, "run.egress", egress_data(%{"host" => host, "rule" => ""})},
          {4, "run.egress",
           egress_data(%{
             "host" => host,
             "decision" => "denied",
             "outcome" => "refused",
             "rule" => ""
           })},
          {5, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      # The allowed connections are rows with Connections inline on.
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1")

      # Two allowed connections to the host read as one group, the denied one as a row.
      assert has_element?(lv, "#e-2-group .q-cx-sum .q-dest > bdi", shown)
      assert has_element?(lv, "#e-2-cx-3 .q-dest > bdi", shown)
      assert has_element?(lv, "#e-4 .q-dest > bdi", shown)
      assert html =~ "<bdi>#{shown_escaped}</bdi><span class=\"q-port\">:443</span>"
      refute html =~ "elpmaxe.<script>"

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      assert has_element?(lv, ".q-cx-h > bdi", shown)
      assert html =~ "#{shown_escaped}</bdi><span class=\"q-cx-p\">:443</span>"
      refute html =~ "elpmaxe.<script>"
    end

    test "longer than 255 bytes reads in the timeline as on its connection's row: cut and marked",
         %{conn: conn, scope: scope} do
      long = String.duplicate("a", 292) <> ".example"
      assert byte_size(long) == 300
      cut = String.duplicate("a", 252) <> "…"

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.egress", egress_data(%{"host" => long, "rule" => ""})},
          {3, "run.egress", egress_data(%{"host" => long, "rule" => ""})},
          {4, "run.egress",
           egress_data(%{
             "host" => long,
             "decision" => "denied",
             "outcome" => "refused",
             "rule" => ""
           })},
          {5, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
        ])

      # The allowed connections are rows with Connections inline on.
      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1")

      assert has_element?(lv, "#e-2-group .q-cx-sum .q-dest > bdi", cut)
      assert has_element?(lv, "#e-2-cx-3 .q-dest > bdi", cut)
      assert has_element?(lv, "#e-4 .q-dest > bdi", cut)
      assert html =~ "<bdi>#{cut}</bdi><span class=\"q-port\">:443</span>"
      refute html =~ String.duplicate("a", 253)

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      assert has_element?(lv, ".q-cx-h > bdi", cut)
      assert html =~ "#{cut}</bdi><span class=\"q-cx-p\">:443</span>"
      refute html =~ String.duplicate("a", 253)
    end
  end

  describe "a run with tools" do
    @tag :feature_sets
    test "the timeline groups a tool's allowed calls under its name and lists the tools", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, tool_record())

      # The allowed connections are rows with Connections inline on.
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?cx=1")

      # the tools are listed on the policy applied, an item only where there is security
      if security?() do
        assert has_element?(lv, "#e-3-tools", "files")
        assert has_element?(lv, "#e-3-tools", "files.tools.internal")
      else
        refute has_element?(lv, "#e-3")
      end

      assert has_element?(lv, "#e-5-group .q-cx-sum .q-tool-name", "files")
      assert has_element?(lv, "#e-5-group .q-cx-sum", "2 allowed requests")
      refute render(element(lv, "#e-5-group .q-cx-sum")) =~ "calls"
      assert has_element?(lv, "#e-5-cx-5 .q-outcome", "Answered 200")
      assert has_element?(lv, "#e-5-cx-6 .q-outcome", "Answered 201")

      assert has_element?(
               lv,
               ~s(#e-5-cx-6 .q-dest[data-request-id="0a1b2c3d4e5f60718293a4b5c6d7e8f9"])
             )

      # The refused request is a separate denial, never folded into the group, and names
      # the tool only as the one it did not reach.
      assert has_element?(lv, "#e-7-cx.q-cx-denied .q-dest", "files.tools.internal")
      refute has_element?(lv, "#e-7-cx .q-dest-tool")
      assert has_element?(lv, "#e-7-cx .q-for-tool", "files")
      assert has_element?(lv, "#e-4-cx .q-dest", "api.example.com")
      refute has_element?(lv, "#e-4-cx .q-dest-tool")
    end

    @tag needs: :security
    test "the policy in force names the tools and the hosts they serve", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, tool_record())

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert has_element?(lv, "#policy-tools", "files (files.tools.internal)")

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied", tool_policy_data(%{"tools" => []})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

      # The page calls them secrets, and says a secret is why the proxy reads a host.
      assert has_element?(lv, "dt:has(+ dd#policy-credentials)", "Secrets")
      refute has_element?(lv, "dt", "Credentials")

      assert has_element?(
               lv,
               "abbr.term[data-tip='A host whose requests the proxy reads, because the run holds a secret, a tool or path rules for it. Every other host is a blind tunnel.']",
               "Reads requests to"
             )

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      code = lv |> element("#e-2-tools code.q-rule") |> render() |> LazyHTML.from_fragment()
      assert LazyHTML.text(code) == String.slice(argument, 0, 64) <> "…"
      assert LazyHTML.attribute(code, "title") == [argument]
      assert has_element?(lv, "#e-2-tools", "files.tools.internal")

      # Details shows it whole.
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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
          {2, "runtime.result",
           %{"outcome" => "error", "result" => "I could not finish:\nthe tests still fail."}},
          {3, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-why", "I could not finish: the tests still fail.")
      # one cut line in the meta lines' box, which takes the column's width on a phone
      assert has_element?(lv, ".q-run-sub > .q-run-meta-wrap > #run-why > .q-run-why-t[title]")

      jump = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}?seq=2"
      assert has_element?(lv, ~s(#run-why-jump[href="#{jump}"]), "Jump to it")
    end

    test "a run whose image was missing and whose work was queued again says so, and leads to its exit",
         %{conn: conn, scope: scope} do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      {1, _rows} =
        Repo.update_all(
          from(r in DispatchRun, where: r.id == ^queued.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "run.exited",
             %{"state" => "failed", "reason" => "image_missing", "exit_code" => -1}}
          ],
          %{dispatch_run_id: queued.id}
        )

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)
      refute has_element?(lv, "#run-why", "environment image")

      ended = Repo.get!(DispatchRun, queued.id)

      {:ok, %{attempt: 2}} =
        Repo.transact(fn -> Dispatches.requeue_for_image(ended) end)

      {:ok, lv, _html} = live(conn, path)

      assert has_element?(
               lv,
               "#run-why",
               "Ended before it started: its environment image was missing from the registry. The work is queued again and waits for a new build of the image."
             )

      assert has_element?(lv, ~s(#run-why-jump[href="#{path}?seq=2"]), "Jump to it")
    end

    @tag needs: [:factory, :secrets]
    test "a paused run says why it paused and links the run that continues it",
         %{conn: conn, scope: scope, user: user} do
      Repo.update!(Ecto.Changeset.change(user, time_zone: "Europe/Berlin"))

      {:ok, provider} =
        Apiary.Connections.create_provider(scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-fixture-main-0123456789"}]
        })

      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      {1, _rows} =
        Repo.update_all(
          from(r in DispatchRun, where: r.id == ^queued.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      # The run that continues it, queued as the end of the paused run queues it.
      ended = Repo.get!(DispatchRun, queued.id)
      {:ok, next} = Repo.transact(fn -> Dispatches.requeue_for_pause(ended, nil) end)
      number = Repo.one!(from r in Apiary.Runs.Run, where: r.dispatch_run_id == ^next.id).number

      run =
        projected(
          scope,
          [
            {1, "run.started", started_data()},
            {2, "run.exited",
             %{"state" => "cancelled", "reason" => "model_key_limit", "exit_code" => -1}}
          ],
          %{
            dispatch_run_id: queued.id,
            provider_connection_id: provider.id,
            provider_secret_id: provider.secret_id,
            provider_chain: "organisation",
            provider_api: %{
              "format" => "anthropic-messages",
              "endpoint" => "https://api.model.example/anthropic",
              "auth" => %{"scheme" => "x-api-key"}
            },
            model_keys: [],
            run_settings: %{}
          }
        )

      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}"
      {:ok, lv, _html} = live(conn, path)

      assert has_element?(
               lv,
               "#run-why",
               "Paused: a key of #{provider.name} reached its limit. It continues in run #{number}."
             )

      next_path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{number}"
      assert has_element?(lv, ~s(#run-why a[href="#{next_path}"]), "#{number}")
      refute has_element?(lv, "#run-why-jump")

      # Two days on: the weekday and the clock in the reader's time zone.
      until = DateTime.add(DateTime.utc_now(), 2, :day)
      clock = until |> DateTime.shift_zone!("Europe/Berlin") |> Calendar.strftime("%a %H:%M")

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
          set: [paused_until: until]
        )

      {:ok, lv, _html} = live(conn, path)

      line =
        lv
        |> element("#run-why .q-run-why-t")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert line ==
               "Paused: every key of #{provider.name} is in cooldown until #{clock}. " <>
                 "It continues in run #{number}."

      # A paused run that no run continues has its state alone.
      alone =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "cancelled", "reason" => "model_key_limit"}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{alone.number}")

      assert has_element?(lv, "#run-state", "Paused")
      assert has_element?(lv, "#run-why", "Paused: a model key reached its limit.")
      refute has_element?(lv, "#run-why", "It continues")
    end

    test "a run that ended well says nothing more", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.result", %{"outcome" => "success", "result" => "done"}},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      refute has_element?(lv, "#run-why")
    end
  end

  # The rail's Exit row, as read.
  defp exit_row(lv) do
    case Regex.run(~r{<dt>Exit</dt>\s*<dd class="font-mono">\s*(.*?)\s*</dd>}s, render(lv)) do
      [_, value] -> value
      nil -> nil
    end
  end

  # The terms of the rail's Run section, in order.
  defp details_terms(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#run-details dt")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "what the run used" do
    defp exited(extra) do
      Map.merge(
        %{"session" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 900},
        extra
      )
    end

    test "the rail shows the peak memory and the CPU time after Duration", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "session.exited",
           exited(%{"peak_memory_bytes" => 10_522_669_875, "cpu_time_ms" => 2_460_000})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert ["Duration", "Peak memory", "CPU time" | _] =
               Enum.drop_while(run_terms(lv), &(&1 != "Duration"))

      assert has_element?(lv, "#rail-peak-memory", "9.8 GiB")
      refute has_element?(lv, "#rail-peak-memory", "of")
      assert has_element?(lv, "#rail-cpu-time", "41 m 00 s")
    end

    test "a CPU time under a minute is in seconds, and each value shows alone", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.exited", exited(%{"cpu_time_ms" => 12_400})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#rail-cpu-time", "12 s")
      refute "Peak memory" in run_terms(lv)
      refute has_element?(lv, "#rail-peak-memory")
    end

    test "a run whose sessions reported neither value shows neither row", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.exited", exited(%{})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      terms = run_terms(lv)
      assert "Duration" in terms
      refute "Peak memory" in terms
      refute "CPU time" in terms
      refute has_element?(lv, "#rail-peak-memory")
      refute has_element?(lv, "#rail-cpu-time")
    end

    test "a peak memory shows without a CPU time", %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.exited", exited(%{"peak_memory_bytes" => 2_147_483_648})}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#rail-peak-memory", "2 GiB")
      refute "CPU time" in run_terms(lv)
      refute has_element?(lv, "#rail-cpu-time")
    end

    test "a CPU time rounds half up to a second and reads as a duration", %{
      conn: conn,
      scope: scope
    } do
      for {ms, shown} <- [
            {59_499, "59 s"},
            {59_500, "1 m 00 s"},
            {89_999, "1 m 30 s"},
            {2_470_000, "41 m 10 s"},
            {3_600_000, "1 h 00 m"},
            {18_000_000, "5 h 00 m"}
          ] do
        run =
          projected(scope, [
            {1, "run.started", started_data()},
            {2, "session.exited", exited(%{"cpu_time_ms" => ms})}
          ])

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert lv
               |> element("#rail-cpu-time")
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.text()
               |> String.trim() == shown,
               "#{ms} ms"
      end
    end
  end

  # The words of the page's limits notice, as a reader reads them.
  defp limits_text(lv) do
    lv
    |> element(".q-limits")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp run_terms(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#run-facts > dt")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp ended_run(scope, exit) do
    projected(scope, [
      {1, "run.started", started_data()},
      {2, "run.egress", egress_data()},
      {3, "run.exited", exit}
    ])
  end

  describe "a run's end in words" do
    test "every reason in words, after the state and under it", %{
      conn: conn,
      scope: scope
    } do
      for {exit, state, words} <- [
            {%{"state" => "cancelled", "reason" => "credential_expired"}, "cancelled",
             "permission to run expired"},
            {%{"state" => "cancelled", "reason" => "run_ended_at_issuer"}, "cancelled",
             "stopped, no outcome given"},
            {%{"reason" => "gateway_lost"}, "lost", "end not recorded"},
            {%{"reason" => "session_lost"}, "lost", "stopped responding"},
            {%{"state" => "cancelled", "reason" => "timeout"}, "cancelled", "time limit reached"}
          ] do
        run = ended_run(scope, exit)

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-meta #run-state.q-sdot-#{state}")
        assert has_element?(lv, "#run-reason", words)
        assert has_element?(lv, "#rail-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
      end
    end

    test "an exit with the reason run_closed reads Failed, with no words", %{
      conn: conn,
      scope: scope
    } do
      run = ended_run(scope, %{"reason" => "run_closed"})

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")
      refute has_element?(lv, "#run-reason")
      refute has_element?(lv, "#rail-reason")
    end

    test "a run refused at its start: Failed, the check of its settings and its code, after the state and under it",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.refused", %{"code" => "image_unknown"}}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")

      assert has_element?(
               lv,
               "#run-meta #run-state + #run-reason",
               "The run's settings did not pass a check on the machine (image_unknown)."
             )

      assert has_element?(
               lv,
               "#run-facts #rail-reason",
               "The run's settings did not pass a check on the machine (image_unknown)."
             )
    end

    test "a run refused because its machine could not check an earlier run's container: those words, the code in mono",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.refused", %{"code" => "engine_unreachable"}}
        ])

      {:ok, lv, _html} = run_page(conn, scope, run)

      for reason <- ["#run-meta #run-reason", "#run-facts #rail-reason"] do
        assert words_of(lv, reason) ==
                 "The machine could not check an earlier run's container (engine_unreachable)."

        assert words_of(lv, "#{reason} .font-mono") == "engine_unreachable"
      end
    end

    test "the timeline's last item: Run ended for every end, its mark the state's", %{
      conn: conn,
      scope: scope
    } do
      for {state, reason, words, mark} <- [
            {"cancelled", "credential_expired", "permission to run expired",
             "q-n.q-n-sys .hero-stop-micro"},
            {"cancelled", "run_ended_at_issuer", "stopped, no outcome given",
             "q-n.q-n-sys .hero-stop-micro"},
            {"failed", "gateway_lost", "end not recorded", "q-n-warn .hero-signal-slash-micro"},
            {"cancelled", "timeout", "time limit reached", "q-n.q-n-sys .hero-stop-micro"}
          ] do
        run =
          ended_run(scope, %{"state" => state, "reason" => reason, "duration_ms" => 95_000})

        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#e-3", "Run ended")
        assert has_element?(lv, "#e-3", words)
        assert has_element?(lv, "#e-3", "1 m 35 s")
        assert has_element?(lv, "#e-3 .#{mark}")
        refute html =~ "Run exited"
      end
    end

    test "a run credential that could not be checked: Failed, and why after it, under it and in the timeline",
         %{conn: conn, scope: scope} do
      for {reason, words} <- [
            {"issuer_unreachable", "couldn't check whether the run may go on: no answer"},
            {"issuer_answer_invalid",
             "couldn't check whether the run may go on: unreadable answer"}
          ] do
        run = ended_run(scope, %{"reason" => reason, "duration_ms" => 130_000})
        assert run.state == "failed"

        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")
        assert has_element?(lv, "#run-meta #run-state + #run-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
        assert has_element?(lv, "#run-facts #rail-reason", words)
        assert has_element?(lv, "#e-3", "Run ended")
        assert has_element?(lv, "#e-3", words)
        assert has_element?(lv, "#e-3", "2 m 10 s")
        refute has_element?(lv, "#e-3", "n/a")
        assert has_element?(lv, "#e-3 .hero-x-mark-micro")
      end
    end
  end

  describe "a run with a session" do
    test "its page is as it was; the reason's words stand under the state", %{
      conn: conn,
      scope: scope
    } do
      run = demo(scope, "timed-out")

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      # cancelled at its time limit: the words after the state on the meta line and under it in
      # the rail, and no exit beside them
      assert has_element?(lv, "#run-meta #run-state.q-sdot-cancelled", "Cancelled")
      assert has_element?(lv, "#run-meta #run-state + #run-reason", "time limit reached")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#run-facts #rail-reason", "time limit reached")
      assert has_element?(lv, "#run-runtime")
      assert html =~ "Run ended"
      refute html =~ "Run exited"

      terms = run_terms(lv)
      for term <- ["Exit", "Runtime", "Host", "Wall"], do: assert(term in terms)
      refute "Forager" in terms
      assert has_element?(lv, "#rail-command")
      assert has_element?(lv, "#rail-command + dl", "Forager")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert has_element?(lv, "#terminal")
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
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-meta #run-state", "Lost")
      assert has_element?(lv, "#run-reason", "end not recorded")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#rail-reason", "end not recorded")
      assert "Exit" in run_terms(lv)
      assert exit_row(lv) == "not recorded"

      # with no output, it says so, as before
      {:ok, _lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

      assert html =~ "This run wrote no output"
    end

    test "a lost session is said once on the meta line, and as its exit in the rail and timeline",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "failed", "exit_code" => -1, "reason" => "session_lost"}}
        ])

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      assert has_element?(lv, "#run-meta #run-state", "Lost")
      assert has_element?(lv, "#run-reason", "stopped responding")
      refute has_element?(lv, "#run-meta", "exit")
      assert has_element?(lv, "#rail-reason", "stopped responding")
      assert "Exit" in run_terms(lv)
      assert exit_row(lv) == "not recorded"
      assert has_element?(lv, "#e-2", "Run ended")
      assert has_element?(lv, "#e-2", "stopped responding")
      assert has_element?(lv, "#e-2 .q-n-warn .hero-signal-slash-micro")
      refute html =~ "exit -1"
    end

    test "an expired run credential or the starter's end is said after the state, under it and in the timeline",
         %{conn: conn, scope: scope} do
      for {reason, words} <- [
            {"credential_expired", "permission to run expired"},
            {"run_ended_at_issuer", "stopped, no outcome given"}
          ] do
        run =
          projected(scope, [
            {1, "run.started", started_data()},
            {2, "run.exited", %{"state" => "cancelled", "exit_code" => -1, "reason" => reason}}
          ])

        {:ok, lv, html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-meta #run-state", "Cancelled")
        assert has_element?(lv, "#run-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
        assert has_element?(lv, "#rail-reason", words)
        assert "Exit" in run_terms(lv)
        assert exit_row(lv) == "not recorded"
        assert has_element?(lv, "#e-2", "Run ended")
        assert has_element?(lv, "#e-2", words)
        assert has_element?(lv, "#e-2 .q-n.q-n-sys .hero-stop-micro")
        refute html =~ "exit -1"
      end
    end

    test "a run credential that could not be checked is said after the state, under it and in the timeline, and it is Failed",
         %{conn: conn, scope: scope} do
      for {reason, words} <- [
            {"issuer_unreachable", "couldn't check whether the run may go on: no answer"},
            {"issuer_answer_invalid",
             "couldn't check whether the run may go on: unreadable answer"}
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
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

        assert has_element?(lv, "#run-meta #run-state.q-sdot-failed", "Failed")
        assert has_element?(lv, "#run-meta #run-state + #run-reason", words)
        refute has_element?(lv, "#run-meta", "exit")
        assert has_element?(lv, "#run-facts #rail-reason", words)
        assert "Exit" in run_terms(lv)
        # the program's exit as recorded: the signal that stopped it
        assert exit_row(lv) == "SIGTERM"
        assert has_element?(lv, "#e-2", "Run ended")
        assert has_element?(lv, "#e-2", words)
        assert has_element?(lv, "#e-2 .q-n-fail .hero-x-mark-micro")
        assert has_element?(lv, "#e-2", "2 m 10 s")
        refute has_element?(lv, "#e-2", "SIGTERM")
        refute html =~ "exit -1"
      end
    end
  end

  describe "how a run ended, on its page (decision 216)" do
    defp session_run(scope, exit) do
      projected(scope, [{1, "run.started", started_data()}, {2, "run.exited", exit}])
    end

    defp run_page(conn, scope, run),
      do: live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    defp words_of(lv, selector) do
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end

    # The item's mark, by the state it ends in.
    @marks %{
      "Completed" => ".q-n.q-n-sys:not(.q-n-fail):not(.q-n-warn) .hero-check-micro",
      "Cancelled" => ".q-n.q-n-sys:not(.q-n-fail):not(.q-n-warn) .hero-stop-micro",
      "Lost" => ".q-n.q-n-sys.q-n-warn .hero-signal-slash-micro",
      "Failed" => ".q-n.q-n-sys.q-n-fail .hero-x-mark-micro"
    }

    test "a session's run: the state and why after it, the reason under it, the exit as recorded, and one Run ended",
         %{conn: conn, scope: scope} do
      # {exit, state, reason words, Exit row, the header's exit}
      for {exit, state, words, exit_row, header_exit} <- [
            # time limit: Cancelled · time limit reached; Exit is the program's signal
            {%{"state" => "cancelled", "reason" => "timeout", "signal" => "SIGTERM"}, "Cancelled",
             "time limit reached", "SIGTERM", nil},
            # permission expired
            {%{"state" => "cancelled", "reason" => "credential_expired", "exit_code" => -1},
             "Cancelled", "permission to run expired", "not recorded", nil},
            # the starter's end with no outcome
            {%{"state" => "cancelled", "reason" => "stopped", "exit_code" => -1}, "Cancelled",
             "stopped, no outcome given", "not recorded", nil},
            # stopped where it was started: Cancelled · interrupted; Exit is what the program exited with,
            # an exit 0 that is no success, the program's 130 on a SIGINT, the session's signal
            {%{"state" => "cancelled", "reason" => "interrupted", "exit_code" => 0}, "Cancelled",
             "interrupted", "0", nil},
            {%{"state" => "cancelled", "reason" => "interrupted", "exit_code" => 130},
             "Cancelled", "interrupted", "130", nil},
            {%{
               "state" => "cancelled",
               "reason" => "interrupted",
               "exit_code" => 130,
               "signal" => "SIGINT"
             }, "Cancelled", "interrupted", "SIGINT", nil},
            {%{
               "state" => "cancelled",
               "reason" => "interrupted",
               "exit_code" => -1,
               "signal" => "SIGTERM"
             }, "Cancelled", "interrupted", "SIGTERM", nil},
            # the outcome and reason the starter gave
            {%{"state" => "succeeded", "reason" => "all_checks_passed", "exit_code" => 0},
             "Completed", "all checks passed", "0", nil},
            {%{"state" => "failed", "reason" => "checks_failed", "exit_code" => 0}, "Failed",
             "checks failed", "0", nil},
            {%{"state" => "cancelled", "reason" => "no_longer_needed", "exit_code" => -1},
             "Cancelled", "no longer needed", "not recorded", nil},
            # the run credential could not be checked, new names and old
            {%{
               "state" => "failed",
               "reason" => "credential_check_unreachable",
               "exit_code" => -1
             }, "Failed", "couldn't check whether the run may go on: no answer", "not recorded",
             nil},
            {%{"state" => "failed", "reason" => "issuer_unreachable", "exit_code" => -1},
             "Failed", "couldn't check whether the run may go on: no answer", "not recorded",
             nil},
            {%{"state" => "failed", "reason" => "credential_check_invalid", "exit_code" => -1},
             "Failed", "couldn't check whether the run may go on: unreadable answer",
             "not recorded", nil},
            {%{"state" => "failed", "reason" => "issuer_answer_invalid", "exit_code" => -1},
             "Failed", "couldn't check whether the run may go on: unreadable answer",
             "not recorded", nil},
            # the session went silent; a batch was refused; the record's machine died
            {%{"state" => "failed", "reason" => "session_lost", "exit_code" => -1}, "Lost",
             "stopped responding", "not recorded", nil},
            {%{"state" => "failed", "reason" => "batch_refused", "exit_code" => -1}, "Failed",
             "events refused", "not recorded", nil},
            {%{"state" => "failed", "reason" => "gateway_lost", "exit_code" => -1}, "Lost",
             "end not recorded", "not recorded", nil},
            # the program's exit, unchanged
            {%{"state" => "succeeded", "exit_code" => 0}, "Completed", nil, "0", nil},
            {%{"state" => "failed", "exit_code" => 1}, "Failed", nil, "1", "exit 1"},
            {%{"state" => "failed", "exit_code" => -1, "signal" => "SIGKILL"}, "Failed", nil,
             "SIGKILL", "SIGKILL"},
            # the starter's outcome with no reason: no exit beside a state that is not Failed
            {%{"state" => "cancelled", "exit_code" => -1}, "Cancelled", nil, "not recorded", nil},
            {%{"state" => "succeeded", "exit_code" => 1}, "Completed", nil, "1", nil}
          ] do
        run = session_run(scope, Map.put(exit, "duration_ms", 720_000))
        {:ok, lv, html} = run_page(conn, scope, run)
        case_ = inspect(exit)

        assert words_of(lv, "#run-meta #run-state") == state, case_

        if words do
          assert words_of(lv, "#run-meta #run-state + #run-reason") == words, case_
          assert words_of(lv, "#run-facts #rail-reason") == words, case_
        else
          refute has_element?(lv, "#run-reason"), case_
          refute has_element?(lv, "#rail-reason"), case_
        end

        assert exit_row(lv) == exit_row, case_

        meta = words_of(lv, "#run-meta")

        if header_exit,
          do: assert(meta =~ header_exit, case_),
          else: refute(meta =~ ~r/\bexit\b|SIG/, case_)

        # the timeline's last item: Run ended, why or the exit, how long; its mark the state's
        assert words_of(lv, "#e-2 .q-k") == "Run ended", case_

        end_words =
          words || header_exit ||
            if(exit["exit_code"] in [0, 1] and !exit["signal"], do: "exit #{exit["exit_code"]}")

        assert words_of(lv, "#e-2 .q-s") == (end_words || ""), case_
        assert words_of(lv, "#e-2 .q-tct") == "12 m 00 s", case_
        assert has_element?(lv, "#e-2 #{@marks[state]}"), case_
        refute html =~ "Run exited", case_
        refute html =~ "exit -1", case_
      end
    end

    test "an exit with no exit code: the same words", %{conn: conn, scope: scope} do
      for {exit, state, words} <- [
            {%{"state" => "cancelled", "reason" => "credential_expired"}, "Cancelled",
             "permission to run expired"},
            {%{"state" => "cancelled", "reason" => "stopped"}, "Cancelled",
             "stopped, no outcome given"},
            {%{"state" => "succeeded", "reason" => "all_checks_passed"}, "Completed",
             "all checks passed"},
            {%{"state" => "cancelled", "reason" => "no_longer_needed"}, "Cancelled",
             "no longer needed"}
          ] do
        run = ended_run(scope, Map.put(exit, "duration_ms", 1_804_000))
        {:ok, lv, _html} = run_page(conn, scope, run)
        case_ = inspect(exit)

        assert words_of(lv, "#run-meta #run-state") == state, case_
        assert words_of(lv, "#run-meta #run-state + #run-reason") == words, case_
        assert words_of(lv, "#run-facts #rail-reason") == words, case_
        assert words_of(lv, "#e-3 .q-k") == "Run ended", case_
        assert words_of(lv, "#e-3 .q-s") == words, case_
        assert words_of(lv, "#e-3 .q-tct") == "30 m 04 s", case_
        assert has_element?(lv, "#e-3 #{@marks[state]}"), case_
      end
    end

    test "an exit with no reason and no exit code: Run ended and how long, no n/a",
         %{conn: conn, scope: scope} do
      for {exit, says} <- [
            {%{"state" => "failed", "duration_ms" => 720_000}, "12 m 00 s"},
            {%{"state" => "failed"}, ""}
          ] do
        run = ended_run(scope, exit)
        {:ok, lv, _html} = run_page(conn, scope, run)
        case_ = inspect(exit)

        assert words_of(lv, "#e-3 .q-k") == "Run ended", case_
        assert words_of(lv, "#e-3 .q-s") == "", case_
        assert words_of(lv, "#e-3 .q-tct") == says, case_
        refute has_element?(lv, "#e-3", "n/a"), case_
        assert has_element?(lv, "#e-3 #{@marks["Failed"]}"), case_
      end
    end

    test "a run that did not start: Failed, why after it and under it, no Exit row, and its item",
         %{conn: conn, scope: scope} do
      for started <- [started_data()] do
        run =
          projected(scope, [
            {1, "run.started", started},
            {2, "run.refused", %{"code" => "image_unknown"}}
          ])

        {:ok, lv, _html} = run_page(conn, scope, run)

        assert words_of(lv, "#run-meta #run-state") == "Failed"

        assert words_of(lv, "#run-meta #run-reason") ==
                 "The run's settings did not pass a check on the machine (image_unknown)."

        assert words_of(lv, "#run-facts #rail-reason") ==
                 "The run's settings did not pass a check on the machine (image_unknown)."

        # the code in mono, as the timeline's item has it; the words around it are not
        for reason <- ["#run-meta #run-reason", "#run-facts #rail-reason"] do
          assert words_of(lv, "#{reason} .font-mono") == "image_unknown"
        end

        # the rail's reason line wraps rather than being cut, unlike its other muted lines
        assert has_element?(lv, "#rail-reason.q-rail-sub.q-rail-sub-wrap")

        refute exit_row(lv)
        refute "Exit" in run_terms(lv)
        refute words_of(lv, "#run-meta") =~ "exit"

        assert words_of(lv, "#e-2 .q-k") == "Run did not start"
        assert words_of(lv, "#e-2 .q-s") == "image_unknown"
        assert has_element?(lv, "#e-2 .q-s .font-mono", "image_unknown")
        assert has_element?(lv, "#e-2 #{@marks["Failed"]}")
      end
    end

    test "the announcer says how the run ended", %{conn: conn, scope: scope} do
      for {event, sentence} <- [
            {{"run.exited",
              %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 720_000}},
             "Run completed after 12 m 00 s."},
            {{"run.exited", %{"state" => "succeeded", "exit_code" => 0}}, "Run completed."},
            {{"run.exited",
              %{"state" => "cancelled", "reason" => "timeout", "signal" => "SIGTERM"}},
             "Run cancelled: time limit reached."},
            {{"run.exited", %{"state" => "cancelled", "reason" => "no_longer_needed"}},
             "Run cancelled: no longer needed."},
            {{"run.exited", %{"state" => "cancelled", "exit_code" => -1}}, "Run cancelled."},
            {{"run.exited",
              %{"state" => "cancelled", "reason" => "interrupted", "exit_code" => 130}},
             "Run cancelled: interrupted."},
            {{"run.exited",
              %{"state" => "cancelled", "reason" => "interrupted", "exit_code" => 0}},
             "Run cancelled: interrupted."},
            {{"run.exited",
              %{"state" => "failed", "reason" => "session_lost", "exit_code" => -1}},
             "Run lost: stopped responding."},
            {{"run.refused", %{"code" => "image_unknown"}}, "Run did not start."},
            {{"run.exited", %{"state" => "failed", "exit_code" => 1}}, "Run failed with exit 1."},
            {{"run.exited", %{"state" => "failed", "signal" => "SIGKILL", "exit_code" => -1}},
             "Run failed with SIGKILL."},
            {{"run.exited",
              %{"state" => "failed", "reason" => "checks_failed", "exit_code" => 0}},
             "Run failed."},
            {{"run.exited",
              %{
                "state" => "failed",
                "reason" => "credential_check_unreachable",
                "exit_code" => -1
              }}, "Run failed."}
          ] do
        run = projected(scope, [{1, "run.started", started_data()}])
        {:ok, lv, _html} = run_page(conn, scope, run)
        {type, data} = event
        project_more(run, [{2, type, data}])
        flush(lv)

        assert words_of(lv, "#run-announcer") == sentence, inspect(event)
      end
    end

    test "the announcer counts no heartbeat for a run lost at its backstop", %{
      conn: conn,
      scope: scope
    } do
      now = DateTime.utc_now()

      heard = fn at ->
        [
          {1, "run.started", started_data(), time: at, received_at: at},
          {2, "run.heartbeat", %{"elapsed_seconds" => 1, "interval_seconds" => 30},
           time: at, received_at: at}
        ]
      end

      # Beating still, past the backstop its attach set; silent for 200 s, with none.
      beating = projected(scope, heard.(DateTime.add(now, -5, :second)))

      beating =
        beating
        |> Ecto.Changeset.change(backstop_at: DateTime.add(now, -1, :second))
        |> Apiary.Repo.update!()

      silent = projected(scope, heard.(DateTime.add(now, -200, :second)))
      pages = for run <- [beating, silent], do: elem(run_page(conn, scope, run), 1)

      assert length(Apiary.Runs.Liveness.check(now)) == 2

      for {lv, sentence} <- Enum.zip(pages, ["Run lost.", "Run lost. No heartbeat for 90 s."]) do
        flush(lv)
        assert words_of(lv, "#run-announcer") == sentence
      end
    end

    test "a run its starter released says so in the header, the rail and the announcer", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data()}])
      {:ok, lv, _html} = run_page(conn, scope, run)

      # As the release writes it (`Apiary.Dispatches.RunEnd`): the fold decides, no outcome.
      now = DateTime.utc_now()
      run = Apiary.Repo.get!(Apiary.Runs.Run, run.id)
      applied = Apiary.Runs.Fold.settle(%{run | released_at: now})

      released =
        run
        |> Ecto.Changeset.change(
          released_at: now,
          state: applied.state,
          reason: applied.reason,
          lost_at: applied.lost_at
        )
        |> Apiary.Repo.update!()

      assert %{state: "cancelled", reason: "released"} = released

      Runs.broadcast_changed(released)
      flush(lv)

      assert has_element?(lv, "#run-meta #run-state", "Cancelled")
      assert words_of(lv, "#run-meta #run-state + #run-reason") == "the starter released it"
      assert words_of(lv, "#run-facts #rail-reason") == "the starter released it"
      assert words_of(lv, "#run-announcer") == "Run cancelled: the starter released it."
    end

    test "workflow_not_in_harness: the workflow and where the run's harness comes from, in the header, the rail and the timeline",
         %{conn: conn, scope: scope} do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)

      %{dispatch_run: dispatch_run} =
        Apiary.WorkItemsFixtures.explore_run_fixture(work_item, registered: false)

      Repo.insert!(%Apiary.Harnesses.RunHarness{
        dispatch_run_id: dispatch_run.id,
        state: :resolved,
        origin: :file,
        workflow: "explore-a-ticket"
      })

      run =
        session_run(scope, %{
          "state" => "failed",
          "reason" => "workflow_not_in_harness",
          "exit_code" => -1
        })

      Repo.update_all(from(r in Runs.Run, where: r.id == ^run.id),
        set: [dispatch_run_id: dispatch_run.id]
      )

      {:ok, lv, _html} = run_page(conn, scope, run)

      words =
        "The run's harness has no skill for the workflow explore-a-ticket. The harness comes from the harness file at the root of repository acme/shop."

      assert words_of(lv, "#run-meta #run-state + #run-reason") == words
      assert words_of(lv, "#run-facts #rail-reason") == words

      # The timeline's end item too: a third time on the page.
      text = lv |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert length(String.split(String.replace(text, ~r/\s+/, " "), words)) - 1 >= 3
    end

    test "no end reason's words, nor the Exit row, nor the timeline, say issuer on the page", %{
      conn: conn,
      scope: scope
    } do
      reasons =
        ~w(timeout quiet credential_expired stopped interrupted no_session session_lost
           gateway_lost batch_refused credential_check_unreachable credential_check_invalid run_closed
           run_ended_at_issuer issuer_unreachable issuer_answer_invalid example_reason)

      runs =
        for reason <- reasons, state <- [nil, "succeeded", "failed", "cancelled"] do
          exit =
            %{"reason" => reason, "exit_code" => -1}
            |> then(&if(state, do: Map.put(&1, "state", state), else: &1))

          session_run(scope, exit)
        end

      refused =
        for code <- ~w(run_ended_at_issuer issuer_unreachable issuer_answer_invalid image_unknown) do
          projected(scope, [
            {1, "run.started", started_data()},
            {2, "run.refused", %{"code" => code}}
          ])
        end

      for run <- runs ++ refused do
        {:ok, _lv, html} = run_page(conn, scope, run)
        text = html |> LazyHTML.from_document() |> LazyHTML.text()
        refute text =~ ~r/issuer/i, inspect({run.state, run.reason})
      end
    end
  end

  describe "what a run sent, as a page shows an external system's text" do
    # A bidirectional override, a zero-width space and a control character, and what is
    # left of them on the page (`Apiary.ExternalText.line/1`).
    defp sent(text), do: "\u202E" <> text <> "\u200B\a"
    defp shown(text), do: text <> "\uFFFD"

    defp open(conn, scope, run) do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

      lv
    end

    test "the title, the header's facts and the rail: cleaned, isolated in <bdi>", %{
      conn: conn,
      scope: scope
    } do
      run =
        run_fixture(scope, %{
          about_title: sent("Fix the login"),
          runtime: sent("claude"),
          runtime_version: sent("2.1.0"),
          host: sent("dev-laptop"),
          wall: sent("docker"),
          image: sent("registry.example/agent:1"),
          command: sent("claude-code"),
          args: ["-p", sent("fix it")],
          dir: sent("/work"),
          forager_version: sent("v0.4.0"),
          labels: %{sent("zone") => sent("eu-1")}
        })

      lv = open(conn, scope, run)

      assert has_element?(lv, "h1#run-title", "Run #{run.number}")
      assert has_element?(lv, "#run-given-title > bdi", shown("Fix the login"))
      assert page_title(lv) == "Run #{run.number} · Runs · Qory Apiary"
      assert has_element?(lv, "#run-runtime > bdi", shown("claude") <> " " <> shown("2.1.0"))
      assert has_element?(lv, "#run-host > bdi", shown("dev-laptop"))

      for value <- ["claude", "dev-laptop", "docker", "claude-code", "/work", "v0.4.0"] do
        assert has_element?(lv, "#run-details dd > bdi", shown(value))
      end

      assert has_element?(lv, "#run-details dd > span.font-mono > bdi", shown("2.1.0"))
      image = shown("registry.example/agent:1")
      assert has_element?(lv, ~s(#run-image[title="#{image}"] > bdi), image)
      assert has_element?(lv, "#run-details .q-arg > bdi", shown("fix it"))
      assert has_element?(lv, "#run-labels dt > bdi", shown("zone"))
      assert has_element?(lv, ~s(#run-labels dd[title="#{shown("eu-1")}"] bdi), shown("eu-1"))
    end

    test "a title with nothing left to show is no title: Run and its number", %{
      conn: conn,
      scope: scope
    } do
      for title <- ["\u202E\u200B", " \u200B "] do
        run = run_fixture(scope, %{about_title: title})
        lv = open(conn, scope, run)

        assert has_element?(lv, "h1#run-title", "Run #{run.number}")
        refute has_element?(lv, "#run-given-title")
        assert page_title(lv) == "Run #{run.number} · Runs · Qory Apiary"
      end
    end

    test "a signal: cleaned in the header's exit and the rail's", %{conn: conn, scope: scope} do
      exit = %{"state" => "failed", "signal" => sent("SIGKILL"), "duration_ms" => 1000}
      run = projected(scope, [{1, "run.started", started_data()}, {2, "run.exited", exit}])
      lv = open(conn, scope, run)

      assert exit_row(lv) == shown("SIGKILL")
      assert has_element?(lv, "#run-meta", shown("SIGKILL"))
      refute has_element?(lv, "#run-meta", "\u202E")
    end

    test "the Forager cell: the version cleaned; n/a for one with nothing left", %{
      conn: conn,
      scope: scope
    } do
      for {version, cell} <- [
            {sent("v0.4.0"), shown("v0.4.0") <> " · contract 1"},
            {"\u202E\u200B", "n/a · contract 1"},
            {nil, "n/a · contract 1"}
          ] do
        run = run_fixture(scope, %{forager_version: version, contract_version: 1})
        html = render(open(conn, scope, run))
        cell_re = ~r{<dt>Forager</dt>\s*(<dd class="font-mono">.*?</dd>)}s
        [_, dd] = Regex.run(cell_re, html)

        assert dd |> LazyHTML.from_fragment() |> LazyHTML.text() == cell
      end
    end

    test "the announcer says a signal cleaned", %{conn: conn, scope: scope} do
      run = projected(scope, [{1, "run.started", started_data()}])
      {:ok, lv, _html} = run_page(conn, scope, run)
      exit = %{"state" => "failed", "signal" => sent("SIGKILL"), "exit_code" => -1}
      project_more(run, [{2, "run.exited", exit}])
      flush(lv)

      assert words_of(lv, "#run-announcer") == "Run failed with #{shown("SIGKILL")}."
    end

    test "a signal with nothing left to show reads as the exit code", %{
      conn: conn,
      scope: scope
    } do
      run = projected(scope, [{1, "run.started", started_data()}])
      {:ok, lv, _html} = run_page(conn, scope, run)
      exit = %{"state" => "failed", "signal" => "\u202E\u200B", "exit_code" => 137}
      project_more(run, [{2, "run.exited", exit}])
      flush(lv)

      assert words_of(lv, "#run-announcer") == "Run failed with exit 137."
      assert exit_row(lv) == "137"
      assert has_element?(lv, "#run-meta", "exit 137")
      refute render(element(lv, "#run-meta")) =~ "\u202E"
    end

    @tag :feature_sets
    test "how it ended, the session, the node's instance, the policy and the record: cleaned",
         %{conn: conn, scope: scope} do
      policy = %{
        "mode" => sent("enforce"),
        "allow" => [sent("api.example")],
        "deny" => [sent("ads.example")],
        "terminated" => [sent("files.tools.internal")],
        "digest" => sent("4f4f"),
        "run_configuration" => sent("abab"),
        "credentials" => [
          %{
            "name" => sent("forge-token"),
            "argument" => sent("acme"),
            "hosts" => [sent("git.example")]
          }
        ],
        "tools" => [%{"name" => sent("files"), "hosts" => [sent("files.tools.internal")]}]
      }

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.started", %{"session_id" => sent("session-0001")}},
          {3, "run.policy_applied", tool_policy_data(policy)},
          {4, "run.egress", egress_data(%{})},
          {5, "runtime.result", %{"outcome" => "error", "result" => sent("I could not finish")}},
          {6, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      run = Apiary.Repo.update!(Ecto.Changeset.change(run, node_instance_id: sent("i-42")))
      lv = open(conn, scope, run)

      assert has_element?(lv, ~s(#run-why .q-run-why-t[title="#{shown("I could not finish")}"]))
      assert has_element?(lv, "#run-instance bdi", shown("i-42"))

      record = "#run-details section[aria-labelledby=rail-record] dd.font-mono"
      assert has_element?(lv, record, shown("session-0001"))

      if security?() do
        assert has_element?(lv, ".q-kv-policy", shown("enforce"))

        {:ok, network, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

        assert has_element?(network, ".q-summary b", shown("enforce"))
        rail = lv |> element("#run-details") |> render() |> LazyHTML.from_fragment()
        shown = LazyHTML.text(rail)

        for value <- ["api.example", "ads.example", "files.tools.internal", "forge-token"],
            do: assert(shown =~ shown(value), value)

        assert shown =~ "#{shown("acme")} (#{shown("git.example")})"
        assert shown =~ shown("files")
        assert shown =~ shown("4f4f")
        assert shown =~ shown("abab")
      end

      # The rail and the header; the timeline's items say what the session said.
      for part <- ["#run-details", "#run-why"] do
        refute lv
               |> element(part)
               |> render()
               |> String.replace(~r/ (data-copy|text)="[^"]*"/, "") =~ "\u202E",
               part
      end
    end

    test "a result with nothing left to show is marked where it says how the run ended", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.result", %{"outcome" => "error", "result" => " \u00A0"}},
          {3, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(conn, scope, run)
      assert has_element?(lv, ~s(#run-why .q-run-why-t[title="\uFFFD"]), "\uFFFD")
    end

    test "a runtime other than Claude Code, in the sentence that says so: cleaned", %{
      conn: conn,
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data(%{"runtime" => sent("make")})},
          {3, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(conn, scope, run)
      assert has_element?(lv, "code.q-rule", shown("make"))
      refute has_element?(lv, "code.q-rule", "\u202E")
    end

    test "the target path: cleaned; one sent with nothing left to show is marked", %{
      conn: conn,
      scope: scope
    } do
      at = &%{target_system: "git.example", target_path: &1}
      run = run_fixture(scope, at.(sent("acme/shop")))
      lv = open(conn, scope, run)
      assert has_element?(lv, "#run-target .q-tname", shown("acme/shop"))
      refute render(element(lv, "#run-target")) =~ "\u202E"

      run = run_fixture(scope, at.("\u202E\u200B"))
      lv = open(conn, scope, run)
      assert has_element?(lv, "#run-target .q-tname", "\uFFFD\uFFFD")
      refute render(element(lv, "#run-target")) =~ "\u202E"

      run = run_fixture(scope, %{target_system: nil, target_path: nil})
      refute has_element?(open(conn, scope, run), "#run-target")
    end

    test "a host, runtime, command and directory sent blank are marked; never sent, n/a", %{
      conn: conn,
      scope: scope
    } do
      run =
        run_fixture(scope, %{
          runtime: "\u200B",
          runtime_version: nil,
          host: " \u00A0",
          command: "\u3000",
          dir: "\u202E"
        })

      lv = open(conn, scope, run)

      assert has_element?(lv, "#run-runtime > bdi", "\uFFFD")
      assert has_element?(lv, "#run-host > bdi", "\uFFFD")

      details = lv |> element("#run-details") |> render() |> LazyHTML.from_fragment()
      cells = details |> LazyHTML.query("dd > bdi") |> Enum.map(&LazyHTML.text/1)
      # The runtime, the host, the command and the directory.
      assert Enum.count(cells, &(&1 == "\uFFFD")) == 4

      none = run_fixture(scope, %{runtime: nil, host: nil, command: nil, dir: nil})
      lv = open(conn, scope, none)
      refute has_element?(lv, "#run-runtime")
      refute has_element?(lv, "#run-host")
      refute render(element(lv, "#run-details")) =~ "\uFFFD"
    end

    test "an ending whose words have nothing left to show is marked, never the item before",
         %{conn: conn, scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "runtime.turn_failed", %{"error" => "the earlier words"}},
          {3, "runtime.result", %{"outcome" => "error", "result" => "\u202E\u200B"}},
          {4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 1000}}
        ])

      lv = open(conn, scope, run)
      assert has_element?(lv, "#run-why .q-run-why-t", "\uFFFD")
      refute has_element?(lv, "#run-why", "the earlier words")
      assert has_element?(lv, ~s(#run-why .q-run-why-t[title="\uFFFD\uFFFD"]))
    end
  end
end
