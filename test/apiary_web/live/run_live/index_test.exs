defmodule ApiaryWeb.RunLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Liveness, Projector}
  alias ApiaryWeb.RunComponents

  setup :register_and_log_in_user

  defp open(conn, %{workspace: _} = scope), do: open(conn, workspace_path(scope, "/runs"))

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp runs(scope, query \\ ""), do: workspace_path(scope, "/runs") <> query

  defp row(run), do: "#run-#{run.run_id}"

  defp text(view, selector), do: view |> element(selector) |> render() |> plain()

  # A token as the query writes it: the qualifier, a colon and the value, one word.
  defp token(view, key), do: view |> text("#runs-token-#{key}") |> String.replace(": ", ":")

  # The words of a fragment, a space between any two elements.
  defp plain(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "requires sign-in", %{scope: scope} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/#{scope.organisation}/#{scope.workspace}/runs")
  end

  describe "empty states" do
    test "no runs and no keys: create a key", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      assert has_element?(view, "h2", "No runs yet")

      assert has_element?(
               view,
               "#runs-create-key[href='#{workspace_path(scope)}/settings/keys/new']"
             )

      refute has_element?(view, "#runs")
      refute has_element?(view, "#runs-views")
      assert has_element?(view, "#nav-runs[aria-current=page]")
      refute has_element?(view, "#nav-runs-alive")
    end

    test "no runs, keys exist: go to the keys, and listen", %{conn: conn, scope: scope} do
      access_key_fixture(scope)
      view = open(conn, scope)
      assert has_element?(view, "#runs-go-to-keys[href='#{workspace_path(scope)}/settings/keys']")
      assert render(view) =~ "Listening for the first run."
    end

    test "the first render is the table's skeleton, never a spinner", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      assert html =~ "runs-loading"
      assert html |> LazyHTML.from_document() |> LazyHTML.query("#runs .loading") |> Enum.empty?()
      render_async(view)
      refute has_element?(view, "#runs-loading")
    end

    test "a family that matches nothing is named in the sentence, with the range",
         %{conn: conn, scope: scope} do
      started_run(scope, shop())

      view = open(conn, runs(scope, "?state=failed,timed_out,lost,closed"))
      assert has_element?(view, "h2", "No runs ended badly.")
      assert has_element?(view, "#runs-hidden", "1 run is hidden by them.")

      view = open(conn, runs(scope, "?state=failed,timed_out,lost,closed&since=7d"))
      assert has_element?(view, "h2", "No runs ended badly in the last 7 days.")

      view = open(conn, runs(scope, "?state=succeeded&from=2026-09-01&to=2026-09-02"))
      assert has_element?(view, "h2", "No runs ended well from 1 Sept 2026 to 2 Sept 2026.")

      # A part of a family, or two families, is not one family's sentence.
      view = open(conn, runs(scope, "?state=failed"))
      assert has_element?(view, "h2", "No runs match these filters")

      view = open(conn, runs(scope, "?state=succeeded,failed,timed_out,lost,closed"))
      assert has_element?(view, "h2", "No runs match these filters")
    end

    test "filters that match nothing say how many runs they hide, with no table and no pages",
         %{conn: conn, scope: scope} do
      started_run(scope, shop())
      started_run(scope, shop())
      view = open(conn, runs(scope, "?state=failed&host=gpu-01"))

      assert has_element?(view, "h2", "No runs match these filters")
      assert text(view, "#runs-hidden") == "2 runs are hidden by them."
      refute has_element?(view, "#runs")
      refute has_element?(view, "#runs-pager")

      # The last filter can go on its own, or every filter at once.
      assert text(view, "#runs-remove-last") == "Remove host:gpu-01"
      view |> element("#runs-remove-last") |> render_click()
      assert_patch(view, runs(scope, "?state=failed"))

      view |> element("#runs-clear") |> render_click()
      assert_patch(view, runs(scope))
      render_async(view)
      assert has_element?(view, "#runs tr.q-rl-row")
    end

    test "there is no default range: a run of any age is in the list", %{
      conn: conn,
      scope: scope
    } do
      old = started_run(scope, shop(), ago: 90 * 86_400)
      view = open(conn, scope)
      assert has_element?(view, row(old))
      refute has_element?(view, "#runs-token-started")
    end
  end

  describe "the list (U1, U5)" do
    test "one line per run: its state, its title, its target, runtime, host, started, duration and denials",
         %{conn: conn, scope: scope} do
      run =
        started_run(scope, Map.put(shop(), "task", "checkout-tax"),
          ago: 125,
          egress: [%{"decision" => "denied", "rule" => ""}, %{}],
          exit: %{"state" => "failed", "exit_code" => 1, "duration_ms" => 411_000}
        )

      view = open(conn, scope)
      cells = text(view, row(run))

      assert cells =~ "Failed"
      refute cells =~ "exit 1"
      assert cells =~ "checkout-tax acme/shop"
      assert cells =~ "claude 2.1.0"
      assert cells =~ "dev-laptop"
      assert cells =~ "2 minutes ago"
      assert cells =~ "6 m 51 s"
      assert has_element?(view, "#{row(run)} .q-st-failed .q-st-w:not(.sr-only)", "Failed")
      assert has_element?(view, "#{row(run)} .q-rl-denied", "1")

      assert has_element?(
               view,
               "#{row(run)} a.q-rowlink[href='#{workspace_path(scope)}/runs/#{run.run_id}']",
               "checkout-tax"
             )

      # One notation: a path the workspace has on one system reads as the path alone.
      refute has_element?(view, "#{row(run)} .q-tname-sys")

      assert text(view, "#runs-view-all") == "All 1"
      assert text(view, "#runs-view-ended-badly") == "Ended badly 1"
      assert text(view, "#runs-view-denials") == "With denials 1"
      assert text(view, "#runs-footer") == "1–1 of 1"
      refute has_element?(view, "#runs-summary")
      # The status region is there before anything narrows the list, so what does is heard.
      assert has_element?(view, "#runs-status[role=status]")
    end

    test "a run that ended well is its dot, its word for a screen reader only", %{
      conn: conn,
      scope: scope
    } do
      run = started_run(scope, shop(), exit: %{"state" => "succeeded", "exit_code" => 0})
      view = open(conn, scope)

      assert has_element?(view, "#{row(run)} .q-st-succeeded .q-st-w.sr-only", "Succeeded")
      refute has_element?(view, "#{row(run)} .q-rl-denied")
    end

    test "a run without a task is its id; a pinged run is pending", %{
      conn: conn,
      scope: scope
    } do
      plain = started_run(scope, %{})
      pending = run_fixture(scope)
      view = open(conn, scope)

      assert text(view, "#{row(plain)} .q-rowlink") == String.slice(plain.run_id, 0, 8)
      assert has_element?(view, "#{row(plain)} .q-rl-c3", "n/a")

      cells = text(view, row(pending))
      assert cells =~ "Pending"
      assert cells =~ String.slice(pending.run_id, 0, 8)
      assert cells =~ "n/a n/a"
    end

    test "a path on more than one system is written with its system", %{
      conn: conn,
      scope: scope
    } do
      github = started_run(scope, shop("github.example"))
      gitlab = started_run(scope, shop("gitlab.example"))
      api = started_run(scope, %{"forge" => "github.example", "repository" => "acme/api"})
      view = open(conn, scope)

      assert text(view, "#{row(github)} .q-rl-c3") == "github.example / acme/shop"
      assert text(view, "#{row(gitlab)} .q-rl-inl") == "gitlab.example / acme/shop"
      assert text(view, "#{row(api)} .q-rl-c3") == "acme/api"
    end

    test "a running run counts up; a quiet one is amber and says at least", %{
      conn: conn,
      scope: scope
    } do
      live_run = started_run(scope, shop(), ago: 100, heartbeat: {5, 90, 30})
      quiet = started_run(scope, shop("gitlab.example"), ago: 600, heartbeat: {47, 510, 30})
      view = open(conn, scope)

      assert has_element?(view, "#{row(live_run)} .q-st-running:not(.q-st-quiet)")
      assert has_element?(view, "#{row(live_run)} time[data-tick=duration]")
      refute has_element?(view, "#{row(live_run)} .q-quiet")

      # What the runner said had elapsed (90 s) plus the server time since it said so
      # (5 s): not the 100 s since the runner's own started_at.
      assert text(view, "#{row(live_run)} time[data-tick=duration]") =~ ~r/^1 m 3[567] s$/

      assert has_element?(
               view,
               "#{row(live_run)} time[data-tick=duration][data-base='90'][data-now]"
             )

      assert has_element?(view, "#{row(quiet)} .q-st-quiet")

      assert text(view, "#{row(quiet)} .q-quiet") =~
               ~r/^No heartbeat for \d\d s \. Heartbeats are due every 30 s\./

      assert text(view, row(quiet)) =~ "at least 8 m 30 s"
    end

    test "a running run that never beat turns amber one default interval after it was first heard",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop(), ago: 5)
      view = open(conn, scope)
      refute has_element?(view, "#{row(run)} .q-quiet")

      Repo.update_all(Apiary.Runs.Run,
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -45, :second)]
      )

      send(view.pid, :quiet_tick)
      refute has_element?(view, "#{row(run)} .q-quiet")

      Runs.broadcast_changed(Repo.reload!(run))

      assert text(view, "#{row(run)} .q-quiet") =~
               ~r/^No heartbeat for 4\d s \. Heartbeats are due every 30 s\./

      assert render(view) =~ "Heartbeats are due every 30 s."
    end

    test "lost and closed runs keep at least", %{conn: conn, scope: scope} do
      lost = started_run(scope, %{}, ago: 4000, heartbeat: {3000, 2490, 30})
      Liveness.check()
      view = open(conn, scope)

      assert text(view, row(lost)) =~ "Lost"
      assert text(view, row(lost)) =~ "at least 41 m 30 s"

      {:ok, _} = Runs.close_run(scope, lost)
      assert text(view, row(lost)) =~ "Closed"
      assert text(view, row(lost)) =~ "at least 41 m 30 s"
    end

    test "another workspace's runs are not listed", %{conn: conn, scope: scope} do
      mine = started_run(scope, shop())
      theirs = started_run(scope_fixture(), shop())
      view = open(conn, scope)

      assert has_element?(view, row(mine))
      refute has_element?(view, row(theirs))
      assert text(view, "#runs-view-all") == "All 1"
    end
  end

  describe "views, the query and the Filter menu (U4)" do
    setup %{scope: scope} do
      %{
        failed:
          started_run(scope, Map.put(shop(), "task", "fix-cart"),
            ago: 300,
            host: "build-02",
            egress: [%{"decision" => "denied", "rule" => ""}],
            exit: %{"state" => "failed", "exit_code" => 1}
          ),
        running:
          started_run(scope, Map.put(shop("gitlab.example"), "task", "mirror-sync"), ago: 100)
      }
    end

    test "the views are tabs with their counts, each a link that keeps the other filters", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, runs(scope, "?host=build-02"))

      assert has_element?(view, "#runs-views[aria-label=Views]")
      assert has_element?(view, "#runs-view-all[aria-current=page]", "All")
      assert text(view, "#runs-view-all") == "All 1"
      assert text(view, "#runs-view-alive") == "Alive 0"
      assert text(view, "#runs-view-ended-badly") == "Ended badly 1"

      view |> element("#runs-view-alive") |> render_click()
      assert_patch(view, runs(scope, "?host=build-02&state=pending%2Crunning"))
      render_async(view)
      assert has_element?(view, "#runs-view-alive[aria-current=page]")
      refute has_element?(view, "#runs-view-all[aria-current]")
      # The view says the states: no token repeats them.
      refute has_element?(view, "#runs-token-state")

      view |> element("#runs-view-denials") |> render_click()
      assert_patch(view, runs(scope, "?denials=1&host=build-02"))
    end

    test "a copied URL reproduces the view, its filters as tokens", %{
      conn: conn,
      failed: failed,
      running: running,
      scope: scope
    } do
      view =
        open(
          conn,
          runs(
            scope,
            "?state=failed&system=github.example&target=acme/shop&task=fix-cart&runtime=claude&host=build-02&denials=1&since=24h"
          )
        )

      assert has_element?(view, row(failed))
      refute has_element?(view, row(running))

      # acme/shop is on two systems here: its token names the system.
      assert token(view, "target") == "repo:github.example/acme/shop"
      assert token(view, "state") == "state:failed"
      assert token(view, "task") == "task:fix-cart"
      assert token(view, "started") == "started:24h"
      assert token(view, "denied") == "denied:yes"
      assert has_element?(view, "#runs-token-runtime a[aria-label='Remove runtime:claude']")
      assert text(view, "#runs-summary") =~ "1 run matches"
      assert has_element?(view, "#runs-status[role=status] #runs-summary")

      # The Filter menu says what each section is set to.
      assert text(view, "#runs-filter-value-state") == "Failed"
      assert text(view, "#runs-filter-value-since") == "last 24 hours"
      assert text(view, "#runs-filter-value-denials") == "With denials"

      view |> element("#runs-tokens-clear") |> render_click()
      assert_patch(view, runs(scope))
    end

    test "the query: qualifiers become the URL's filters, the rest is the free text", %{
      conn: conn,
      failed: failed,
      running: running,
      scope: scope
    } do
      view = open(conn, scope)

      view
      |> form("#runs-query", %{"q" => "state:failed repo:acme/shop fix"})
      |> render_submit()

      # acme/shop is on two systems: the path alone is every system's.
      assert_patch(view, runs(scope, "?q=fix&state=failed&target=acme%2Fshop"))
      render_async(view)
      assert has_element?(view, row(failed))
      refute has_element?(view, row(running))
      assert has_element?(view, "#runs-query-input[value=fix]")

      # A token goes with its button, and the rest stays.
      view |> element("#runs-token-state a") |> render_click()
      assert_patch(view, runs(scope, "?q=fix&target=acme%2Fshop"))

      # The free text alone: a run's task, id or target.
      view |> form("#runs-query", %{"q" => "mirror"}) |> render_submit()
      assert_patch(view, runs(scope, "?q=mirror&target=acme%2Fshop"))
      render_async(view)
      assert has_element?(view, row(running))
      refute has_element?(view, row(failed))

      view
      |> form("#runs-query", %{"q" => String.slice(failed.run_id, 0, 8)})
      |> render_submit()

      render_async(view)
      assert has_element?(view, row(failed))
      refute has_element?(view, row(running))
    end

    test "a query word that cannot be read is said, and nothing else changes", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, runs(scope, "?host=build-02"))
      view |> form("#runs-query", %{"q" => "state:bogus"}) |> render_submit()
      assert_patch(view, runs(scope, "?host=build-02"))
      render_async(view)
      assert text(view, "#runs-dropped") == "state:bogus could not be read, so it is not applied."

      # The reader's next change takes the notice away.
      view |> element("#runs-view-alive") |> render_click()
      refute has_element?(view, "#runs-dropped")
    end

    test "the Filter menu: one dialog of sections, each counted from the data, patching the URL",
         %{conn: conn, running: running, scope: scope} do
      view = open(conn, scope)

      assert has_element?(
               view,
               "#runs-filter-button[aria-haspopup=dialog][aria-controls=runs-filter-panel]",
               "Filter"
             )

      assert has_element?(view, "#runs-filter-panel[role=dialog]")

      for key <- ~w(target state task runtime host key since denials) do
        assert has_element?(view, "#runs-filter-open-#{key}")
        assert has_element?(view, "#runs-filter-section-#{key}[role=group]")
      end

      # The rail does the Target section's work from 1280 px.
      assert has_element?(view, "#runs-filter-open-target.q-norail")
      assert has_element?(view, "#runs-filter-open-state .q-fm-meta", "state:")

      assert text(view, "#filter-state-form") =~ "Running 1"
      assert text(view, "#filter-state-form") =~ "Failed 1"
      assert text(view, "#filter-host-form") =~ "build-02 1"

      view |> form("#filter-state-form") |> render_change(%{"state" => ["running"]})
      assert_patch(view, runs(scope, "?state=running"))
      render_async(view)
      assert has_element?(view, row(running))

      view |> form("#filter-task-form") |> render_change(%{"task" => "mirror-sync"})
      assert_patch(view, runs(scope, "?state=running&task=mirror-sync"))

      view |> form("#filter-denials-form") |> render_change(%{"denials" => "1"})
      assert_patch(view, runs(scope, "?denials=1&state=running&task=mirror-sync"))

      # Nothing matches: the empty state clears them, and the line that counts is not there.
      render_async(view)
      refute has_element?(view, "#runs-summary")
      view |> element("#runs-clear") |> render_click()
      assert_patch(view, runs(scope))
    end

    test "the State section reads as three families, each heading a checkbox over its states",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      form = "#filter-state-form"

      for {key, name} <- [
            {"alive", "Every alive state"},
            {"ended_well", "Every state that ended well"},
            {"ended_badly", "Every state that ended badly"}
          ] do
        assert has_element?(
                 view,
                 "#{form} .q-filter-family input[name=family_#{key}][value='1'][aria-label='#{name}']"
               )
      end

      # Every state shows under its family, counted when a run has it.
      assert text(view, form) =~
               "Alive Pending Running 1 Ended well Succeeded Ended badly Failed 1 Timed out Lost Closed"

      assert has_element?(
               view,
               "#{form} input[name='state[]'][value=closed][aria-describedby=filter-state-tip-closed]"
             )

      assert text(view, "#filter-state-tip-closed") =~
               "Stopped by the workspace: a member closed it after it went quiet. Counted with the runs that ended badly."

      refute has_element?(view, "#{form} input[name=family_alive][checked]")
      refute has_element?(view, "#{form} input[name=family_alive][aria-checked]")
    end

    test "ticking a family fills its states into the URL, and the view is that family's",
         %{conn: conn, failed: failed, running: running, scope: scope} do
      view = open(conn, scope)

      # Without the page's script: the heading alone, the state boxes as the form has them.
      view
      |> form("#filter-state-form")
      |> render_change(%{"_target" => ["family_ended_badly"], "family_ended_badly" => "1"})

      assert URI.decode(assert_patch(view)) ==
               "#{workspace_path(scope)}/runs?state=failed,timed_out,lost,closed"

      render_async(view)
      assert has_element?(view, row(failed))
      refute has_element?(view, row(running))
      assert has_element?(view, "#runs-view-ended-badly[aria-current=page]")
      assert text(view, "#runs-filter-value-state") == "ended badly"
      assert has_element?(view, "#filter-state-form input[name=family_ended_badly][checked]")
      refute has_element?(view, "#filter-state-form input[name=family_ended_badly][aria-checked]")

      # With the script, which ticks the family's boxes before the change is sent.
      view
      |> form("#filter-state-form")
      |> render_change(%{
        "_target" => ["family_alive"],
        "family_alive" => "1",
        "state" => ~w(pending running failed timed_out lost closed)
      })

      assert URI.decode(assert_patch(view)) ==
               "#{workspace_path(scope)}/runs?state=pending,running,failed,timed_out,lost,closed"

      render_async(view)
      assert text(view, "#runs-filter-value-state") == "alive, ended badly"
      assert token(view, "state") == "state:alive,ended_badly"

      # Unticking a heading takes its states out. A browser leaves an unticked box out of
      # the form it sends, which the test client would merge back in from the DOM: the
      # event is sent as the browser would.
      render_change(view, "filter", %{
        "_filter" => "state",
        "_target" => ["family_ended_badly"],
        "state" => ~w(pending running failed timed_out lost closed)
      })

      assert URI.decode(assert_patch(view)) ==
               "#{workspace_path(scope)}/runs?state=pending,running"
    end

    test "a family with some of its states chosen is mixed, and the token reads the states",
         %{conn: conn, scope: scope} do
      view = open(conn, runs(scope, "?state=failed"))

      assert has_element?(
               view,
               "#filter-state-form input[name=family_ended_badly][aria-checked=mixed]"
             )

      refute has_element?(view, "#filter-state-form input[name=family_ended_badly][checked]")
      refute has_element?(view, "#filter-state-form input[name=family_alive][aria-checked]")
      assert token(view, "state") == "state:failed"
      assert has_element?(view, "#runs-view-all[aria-current=page]")
    end

    test "the Started section: every run, a preset, dates", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      assert has_element?(view, "#filter-since-form input[name=since][value=all][checked]")
      refute has_element?(view, "#runs-filter-value-since")

      view
      |> form("#filter-since-form")
      |> render_change(%{"since" => "30d", "_target" => ["since"]})

      assert_patch(view, runs(scope, "?since=30d"))

      view
      |> form("#filter-since-form")
      |> render_change(%{"from" => "2026-09-14", "to" => "2026-09-16", "_target" => ["to"]})

      assert_patch(view, runs(scope, "?from=2026-09-14&to=2026-09-16"))
      render_async(view)
      assert token(view, "started") == "started:2026-09-14..2026-09-16"
      assert text(view, "#runs-filter-value-since") == "14 Sept 2026 to 16 Sept 2026"

      view |> element("#runs-token-started a") |> render_click()
      assert_patch(view, runs(scope))
    end

    test "Sort: newest, oldest, longest, most denials", %{
      conn: conn,
      failed: failed,
      running: running,
      scope: scope
    } do
      view = open(conn, scope)

      assert has_element?(view, "#runs-sort-button[aria-label='Sort: newest first']", "Sort")
      assert has_element?(view, "#runs-sort-newest[role=menuitemradio][aria-checked=true]")

      view |> element("#runs-sort-oldest") |> render_click()
      assert_patch(view, runs(scope, "?sort=oldest"))
      render_async(view)

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#runs tr[data-run]")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-run"))

      assert ids == [failed.run_id, running.run_id]
      assert has_element?(view, "#runs-sort-oldest[aria-checked=true]", "Oldest")

      view |> element("#runs-sort-denials") |> render_click()
      assert_patch(view, runs(scope, "?sort=denials"))
    end
  end

  describe "links that cannot be read in full" do
    # Follows the rewrite, as a browser does, and returns the view on the canonical URL.
    defp follow(conn, path) do
      case live(conn, path) do
        {:ok, view, _html} ->
          {view, path}

        {:error, {:live_redirect, %{to: to}}} ->
          {:ok, view, _html} = live(conn, to)
          {view, to}
      end
    end

    test "no value of any parameter breaks the page, and it ends on the canonical URL", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop())

      bad = [
        <<0>>,
        "a" <> <<0>> <> "b",
        "\e[31m",
        String.duplicate("x", 5000),
        "99999999999999999999999999",
        "-1",
        "2026-02-31",
        "none,none",
        "%",
        "' OR 1=1 --"
      ]

      names =
        ~w(group state system target task runtime host key q since from to denials sort per page run)

      for name <- names, value <- bad do
        {view, to} =
          follow(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{%{name => value}}")

        render_async(view)
        assert has_element?(view, "#runs-filters"), "#{name}=#{inspect(value)} broke the page"
        refute has_element?(view, "#runs-error")
        assert URI.parse(to).path == "#{workspace_path(scope)}/runs"
      end

      # Lists and maps where a string is expected.
      for name <- names, shape <- ["#{name}[]=x", "#{name}[a]=x", "#{name}[a][]=x"] do
        {view, to} = follow(conn, "#{workspace_path(scope)}/runs?" <> shape)
        render_async(view)
        assert has_element?(view, "#runs-filters"), "#{shape} broke the page"
        assert to == "#{workspace_path(scope)}/runs"
      end
    end

    test "an old link's grouping and default range are dropped quietly", %{
      conn: conn,
      scope: scope
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, runs(scope, "?group=task&since=all&state=failed"))

      assert to == runs(scope, "?state=failed")
    end

    test "a refused value is said, never silently an unfiltered list", %{conn: conn, scope: scope} do
      started_run(scope, shop())

      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 conn,
                 ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{%{"task" => <<0>>}}"
               )

      assert to == ~p"/#{scope.organisation}/#{scope.workspace}/runs"

      # The rewrite is a patch of the same view in a browser: the notice rides along.
      {:ok, view, _html} = live(conn, runs(scope, "?state=running"))
      render_async(view)
      refute has_element?(view, "#runs-dropped")

      render_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{%{"host" => String.duplicate("h", 1025), "since" => "90d"}}"
      )

      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      render_async(view)

      assert text(view, "#runs-dropped") ==
               "The link's host, since filters could not be read, so they are not applied."

      # The reader's next change takes the notice away.
      view |> element("#runs-view-denials") |> render_click()
      refute has_element?(view, "#runs-dropped")
    end

    test "a host as long as the column holds is a filter like any other", %{
      conn: conn,
      scope: scope
    } do
      long = String.duplicate("h", 1024)
      run = started_run(scope, shop(), host: long)
      other = started_run(scope, shop())

      view = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{%{"host" => long}}")
      assert has_element?(view, row(run))
      refute has_element?(view, row(other))
      refute has_element?(view, "#runs-dropped")
    end
  end

  describe "the rail, and targets and sections at any size" do
    test "the rail lists the targets with their runs under the other filters; one is a link that sets it",
         %{conn: conn, scope: scope} do
      shop_run = started_run(scope, Map.put(shop(), "task", "a"))
      started_run(scope, Map.put(shop(), "task", "b"))
      api = started_run(scope, %{"forge" => "github.example", "repository" => "acme/api"})
      started_run(scope, %{})
      view = open(conn, runs(scope, "?task=a"))

      assert has_element?(view, "nav#runs-rail[aria-label=Repositories]")
      assert text(view, "#runs-rail-all") == "All repositories 1"
      assert has_element?(view, "#runs-rail-all[aria-current=true]")

      view = open(conn, scope)
      assert text(view, "#runs-rail-all") == "All repositories 4"
      assert text(view, "#runs-rail-none") == "Unassigned 1"

      shop_link = "#runs-rail-t-#{RunComponents.dom_token({"github.example", "acme/shop"})}"
      assert text(view, shop_link) == "acme/shop 2"

      view |> element(shop_link) |> render_click()
      assert_patch(view, runs(scope, "?system=github.example&target=acme%2Fshop"))
      render_async(view)
      assert has_element?(view, row(shop_run))
      refute has_element?(view, row(api))
      assert has_element?(view, "#{shop_link}[aria-current=true]")
      # The rail counts under every filter but the target: the others are still there.
      assert text(view, "#runs-rail-all") == "All repositories 4"
    end

    test "the rail searches on the server and shows twenty, then more", %{
      conn: conn,
      scope: scope
    } do
      for n <- 1..23 do
        started_run(scope, %{"forge" => "github.example", "repository" => "acme/r#{n}"})
      end

      view = open(conn, scope)

      rows = fn ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#runs-rail a[id^='runs-rail-t-']")
        |> Enum.count()
      end

      assert rows.() == 20
      assert text(view, "#runs-rail-more") == "3 more"

      view |> element("#runs-rail-more") |> render_click()
      render_async(view)
      assert rows.() == 23
      refute has_element?(view, "#runs-rail-more")

      view |> form("#runs-rail-search", %{"q" => "R2"}) |> render_change()
      render_async(view)
      # acme/r2, r20 to r23.
      assert rows.() == 5
      assert has_element?(view, "#runs-rail", "Matches")

      view |> form("#runs-rail-search", %{"q" => "nothing"}) |> render_change()
      render_async(view)
      assert has_element?(view, "#runs-rail", "No repository matches.")
    end

    test "a system with a colon filters and reads back", %{conn: conn, scope: scope} do
      run = started_run(scope, %{"forge" => "git.example:8443", "repository" => "acme/shop"})
      other = started_run(scope, shop())
      view = open(conn, scope)

      value = Apiary.Runs.Filters.target_value({"git.example:8443", "acme/shop"})
      view |> form("#filter-target-form") |> render_change(%{"target" => value})

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{%{"system" => "git.example:8443", "target" => "acme/shop"}}"
      )

      render_async(view)

      assert has_element?(view, row(run))
      refute has_element?(view, row(other))
      assert token(view, "target") == "repo:git.example:8443/acme/shop"
    end

    test "a long section shows fifty values, says so, shows more and narrows on the server", %{
      conn: conn,
      scope: scope
    } do
      for n <- 1..60 do
        run_fixture(scope, %{state: "running", task: "task-#{n}", started_at: DateTime.utc_now()})
      end

      view = open(conn, scope)
      assert text(view, "#filter-task-more") == "Showing 50 of 60: type to narrow"

      view |> element("#filter-task-show-more") |> render_click()
      render_async(view)
      refute has_element?(view, "#filter-task-more")
      refute has_element?(view, "#filter-task-show-more")

      view |> form("#filter-task-narrow") |> render_change(%{"q" => "task-6"})
      render_async(view)
      assert text(view, "#filter-task-form") == "task-6 1 task-60 1"

      view |> form("#filter-task-narrow") |> render_change(%{"q" => "%"})
      render_async(view)
      assert text(view, "#filter-task-form") == "Nothing matches"
    end
  end

  describe "the preview from 1920 px" do
    setup %{scope: scope} do
      %{
        older:
          started_run(scope, Map.put(shop(), "task", "older"),
            ago: 300,
            egress: [%{"decision" => "denied", "rule" => "", "host" => "files.cdn.example"}],
            exit: %{"state" => "failed", "exit_code" => 1, "duration_ms" => 12_000}
          ),
        newer: started_run(scope, Map.put(shop(), "task", "newer"), ago: 100)
      }
    end

    test "below 1920 px there is none, and a row is its link", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      refute has_element?(view, "#runs-preview")
      render_hook(view, "viewport", %{"wide" => false})
      refute has_element?(view, "#runs-preview")
      refute has_element?(view, "#runs tr[aria-current]")
    end

    test "the first row is chosen until the reader chooses one; the choice is the URL", %{
      conn: conn,
      newer: newer,
      older: older,
      scope: scope
    } do
      log = %{"stream" => "stdout", "bytes" => Base.encode64("\e[32m✓\e[0m tests pass\nbye\n")}
      event_fixture(older, 60, "run.log", log)
      {:ok, _} = Projector.project(older)

      view = open(conn, scope)
      render_hook(view, "viewport", %{"wide" => true})
      render_async(view)

      assert has_element?(view, "#{row(newer)}[aria-current=true]")
      assert has_element?(view, "#runs-preview h2", "newer")
      assert has_element?(view, "#runs-preview-log", "No log recorded.")

      render_hook(view, "select", %{"id" => older.run_id})
      assert_patch(view, runs(scope, "?run=#{older.run_id}"))
      render_async(view)

      assert has_element?(view, "#{row(older)}[aria-current=true]")
      refute has_element?(view, "#{row(newer)}[aria-current]")
      assert has_element?(view, "#runs-preview .q-st-failed", "Failed")
      assert has_element?(view, "#runs-preview .q-st-code", "exit 1")
      assert text(view, "#runs-preview-log") == "✓ tests pass bye"
      assert text(view, "#runs-preview-denials") =~ "1 files.cdn.example:443"

      assert has_element?(
               view,
               "#runs-preview-open[href='#{workspace_path(scope)}/runs/#{older.run_id}']"
             )

      # Enter, or a second click, opens the run.
      render_hook(view, "open", %{"id" => older.run_id})
      assert_redirect(view, "#{workspace_path(scope)}/runs/#{older.run_id}")
    end

    test "a link with a run shows it; a run of another workspace or no run at all is not shown",
         %{conn: conn, older: older, scope: scope} do
      view = open(conn, runs(scope, "?run=#{older.run_id}"))
      render_hook(view, "viewport", %{"wide" => true})
      render_async(view)
      assert has_element?(view, "#runs-preview h2", "older")

      theirs = started_run(scope_fixture(), shop())
      view = open(conn, runs(scope, "?run=#{theirs.run_id}"))
      render_hook(view, "viewport", %{"wide" => true})
      render_async(view)
      refute has_element?(view, "#runs-preview h2")

      # A run of another page cannot be chosen from this one.
      render_hook(view, "select", %{"id" => theirs.run_id})
      refute_patched(view)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, runs(scope, "?run=nope"))
      assert to == runs(scope)
    end
  end

  describe "accessibility" do
    test "the controls are buttons and named dialogs, tips are text", %{
      conn: conn,
      scope: scope
    } do
      quiet = started_run(scope, shop(), ago: 600, heartbeat: {47, 510, 30})
      view = open(conn, scope)

      assert has_element?(view, "#runs-query[role=search] label", "Filter runs")
      assert has_element?(view, "#runs-query-input[name=q]")
      assert has_element?(view, "#runs-filter-panel[role=dialog][aria-label=Filter]")
      assert has_element?(view, "#runs-sort-button[aria-haspopup=menu]")
      assert has_element?(view, "#runs-per button[type=button][aria-pressed=true]", "50")

      # What a sighted reader gets from the tooltip is in the text for everyone else.
      assert has_element?(view, "#{row(quiet)} .q-quiet[tabindex='0'] .sr-only", "After 1 m 30 s")
      assert has_element?(view, "#{row(quiet)} .q-rl-dur [tabindex='0'] .sr-only", "clock stops")
    end

    test "the table keeps its roles whole, headers included", %{conn: conn, scope: scope} do
      run = started_run(scope, shop())
      view = open(conn, scope)

      assert has_element?(view, "#runs-region[role=region][tabindex='0'][aria-label=Runs]")
      assert has_element?(view, "table#runs[role=table] > thead[role=rowgroup] > tr[role=row]")
      assert has_element?(view, "#runs th[role=columnheader][scope=col]", "Denied")
      assert has_element?(view, "#runs > tbody[role=rowgroup] > #{row(run)}[role=row]")
      refute has_element?(view, "#runs th:not([role=columnheader])")
      refute has_element?(view, "#{row(run)} td:not([role=cell])")
    end
  end

  describe "pages keep the URL" do
    test "fifty a page, newer and older, the page size and a jump to a day", %{
      conn: conn,
      scope: scope
    } do
      for _ <- 1..51, do: run_fixture(scope)
      view = open(conn, scope)

      assert text(view, "#runs-footer") == "1–50 of 51"
      assert has_element?(view, "#runs-previous[disabled]", "Newer")

      view |> element("#runs-next", "Older") |> render_click()
      assert_patch(view, runs(scope, "?page=2"))
      render_async(view)
      assert text(view, "#runs-footer") == "51–51 of 51"
      assert has_element?(view, "#runs-next[disabled]")

      view |> element("#runs-per button", "25") |> render_click()
      assert_patch(view, runs(scope, "?per=25"))
      render_async(view)
      assert text(view, "#runs-footer") == "1–25 of 51"

      # Every run was pinged today: a day before it is past the last of them.
      view
      |> form("#runs-jump-form", %{"date" => Date.to_iso8601(Date.add(Date.utc_today(), -1))})
      |> render_submit()

      assert_patch(view, runs(scope, "?page=3&per=25"))
    end

    test "Jump to date is for the orders by time only", %{conn: conn, scope: scope} do
      run_fixture(scope)
      assert has_element?(open(conn, scope), "#runs-jump")
      refute has_element?(open(conn, runs(scope, "?sort=longest")), "#runs-jump")
    end
  end

  describe "live" do
    test "a run on the page changes in place", %{conn: conn, scope: scope} do
      run = started_run(scope, shop(), ago: 30)
      view = open(conn, scope)
      assert text(view, row(run)) =~ "Running"
      assert text(view, "#runs-view-alive") == "Alive 1"

      event_fixture(run, 60, "run.exited", %{
        "state" => "succeeded",
        "exit_code" => 0,
        "duration_ms" => 30_000
      })

      {:ok, _} = Projector.project(run)

      assert text(view, row(run)) =~ "Succeeded"
      assert text(view, row(run)) =~ "30 s"
      render_async(view)
      assert text(view, "#runs-view-alive") == "Alive 0"
    end

    test "changes inside a window are collected and applied together, without a query per message",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop(), ago: 30)
      other = started_run(scope, shop(), ago: 20)
      view = open(conn, scope)

      # The first change opens the window and is applied at once.
      Runs.broadcast_changed(%{Repo.reload!(run) | host: "first"})
      assert text(view, row(run)) =~ "first"

      # The rest wait for the window's end, the last word on each run winning.
      for host <- ~w(second third fourth) do
        Runs.broadcast_changed(%{Repo.reload!(run) | host: host})
      end

      Runs.broadcast_changed(%{Repo.reload!(other) | host: "other-host"})
      assert text(view, row(run)) =~ "first"
      refute text(view, row(other)) =~ "other-host"

      send(view.pid, :flush_runs)
      assert text(view, row(run)) =~ "fourth"
      assert text(view, row(other)) =~ "other-host"

      # A window with nothing in it closes; the next change is applied at once again.
      send(view.pid, :flush_runs)
      Runs.broadcast_changed(%{Repo.reload!(run) | host: "fifth"})
      assert text(view, row(run)) =~ "fifth"
    end

    test "a new run is counted, not inserted, until the reader asks", %{conn: conn, scope: scope} do
      first = started_run(scope, shop(), ago: 30)
      view = open(conn, scope)

      new = started_run(scope, shop(), ago: 1)
      refute has_element?(view, row(new))
      assert text(view, "#runs-new") == "1 new run"
      # Said politely, and never followed for the reader.
      assert has_element?(view, "#runs-new-status[role=status][aria-live=polite] #runs-new")
      refute has_element?(view, "#runs-new[phx-hook]")

      # More of the same run's batches do not count it twice.
      Runs.broadcast_changed(Repo.reload!(new))
      send(view.pid, :flush_runs)
      assert text(view, "#runs-new") == "1 new run"

      view |> element("#runs-new") |> render_click()
      render_async(view)
      assert has_element?(view, row(new))
      assert has_element?(view, row(first))
      refute has_element?(view, "#runs-new")
    end

    test "a new run the filters do not return is not announced", %{conn: conn, scope: scope} do
      started_run(scope, Map.put(shop(), "task", "a"), ago: 30)
      view = open(conn, runs(scope, "?task=a"))
      started_run(scope, Map.put(shop(), "task", "b"), ago: 1)
      refute has_element?(view, "#runs-new")
    end

    test "another workspace's run changes nothing", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn, scope)
      started_run(scope_fixture(), shop(), ago: 1)
      refute has_element?(view, "#runs-new")
    end

    test "the quiet state is the server's, on a change and on its timer", %{
      conn: conn,
      scope: scope
    } do
      run = started_run(scope, shop(), ago: 100, heartbeat: {5, 90, 30})
      view = open(conn, scope)
      refute has_element?(view, "#{row(run)} .q-quiet")

      Repo.update_all(Apiary.Runs.Run,
        set: [last_heartbeat_at: DateTime.add(DateTime.utc_now(), -40, :second)]
      )

      Runs.broadcast_changed(Repo.reload!(run))
      assert has_element?(view, "#{row(run)} .q-quiet")

      send(view.pid, :quiet_tick)
      assert has_element?(view, "#{row(run)} .q-quiet")
    end

    test "the sidebar counts the runs alive now, on every page of the workspace", %{
      conn: conn,
      scope: scope
    } do
      # A page of the workspace that does not follow the runs itself; a page of settings
      # lists the settings in the sidebar, and has no Runs entry to count beside.
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/network")
      refute has_element?(view, "#nav-runs-alive")

      run = started_run(scope, shop(), ago: 5)
      assert text(view, "#nav-runs-alive") == "1"
      assert has_element?(view, "#nav-runs-alive[title='1 run alive now']")

      # Within the window a change is remembered, and counted when the window ends.
      event_fixture(run, 60, "run.exited", %{"state" => "succeeded", "exit_code" => 0})
      {:ok, _} = Projector.project(run)
      send(view.pid, :alive_window_over)
      refute has_element?(view, "#nav-runs-alive")
    end
  end
end
