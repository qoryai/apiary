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

  setup :register_and_log_in_user

  defp open(conn, path \\ "/hive/runs") do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp row(run), do: "#run-#{run.run_id}"

  defp text(view, selector), do: view |> element(selector) |> render() |> plain()

  # The words of a fragment, a space between any two elements.
  defp plain(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "requires sign-in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/hive/runs")
  end

  describe "empty states" do
    test "no runs and no keys: create a key", %{conn: conn} do
      view = open(conn)
      assert has_element?(view, "h2", "No runs yet")
      assert has_element?(view, "#runs-create-key[href='/hive/keys/new']")
      refute has_element?(view, "#runs")
      assert has_element?(view, "#nav-runs[aria-current=page]")
      refute has_element?(view, "#nav-runs-alive")
    end

    test "no runs, keys exist: go to the keys, and listen", %{conn: conn, scope: scope} do
      access_key_fixture(scope)
      view = open(conn)
      assert has_element?(view, "#runs-go-to-keys[href='/hive/keys']")
      assert render(view) =~ "Listening for the first run."
    end

    test "the first render is the table's skeleton, never a spinner", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      {:ok, view, html} = live(conn, ~p"/hive/runs")
      assert html =~ "runs-loading"
      assert html |> LazyHTML.from_document() |> LazyHTML.query("#runs .loading") |> Enum.empty?()
      render_async(view)
      refute has_element?(view, "#runs-loading")
    end

    test "a family that matches nothing is named in the sentence, with the range",
         %{conn: conn, scope: scope} do
      started_run(scope, shop())

      view = open(conn, ~p"/hive/runs?state=failed,timed_out,lost,closed")
      assert has_element?(view, "h2", "No runs ended badly in the last 7 days.")
      assert has_element?(view, "#runs-hidden", "1 run is hidden by them.")

      view = open(conn, ~p"/hive/runs?state=succeeded&since=all")
      assert has_element?(view, "h2", "No runs ended well.")

      view = open(conn, ~p"/hive/runs?state=succeeded&from=2026-09-01&to=2026-09-02")
      assert has_element?(view, "h2", "No runs ended well from 1 Sep 2026 to 2 Sep 2026.")

      # A part of a family, or two families, is not one family's sentence.
      view = open(conn, ~p"/hive/runs?state=failed")
      assert has_element?(view, "h2", "No runs match these filters")
      view = open(conn, ~p"/hive/runs?state=succeeded,failed,timed_out,lost,closed")
      assert has_element?(view, "h2", "No runs match these filters")
    end

    test "filters that match nothing say how many runs they hide", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      started_run(scope, shop())
      view = open(conn, ~p"/hive/runs?state=failed")

      assert has_element?(view, "h2", "No runs match these filters")
      assert text(view, "#runs-hidden") == "2 runs are hidden by them."

      view |> element("#runs-clear") |> render_click()
      assert_patch(view, ~p"/hive/runs")
      render_async(view)
      assert has_element?(view, "#runs tr.q-row")
    end

    test "runs older than the default range are one click away", %{conn: conn, scope: scope} do
      started_run(scope, shop(), ago: 9 * 86_400)
      view = open(conn)
      assert text(view, "#runs-hidden") == "1 run is hidden by them."
      view |> element("#runs-all-time") |> render_click()
      assert_patch(view, ~p"/hive/runs?since=all")
    end
  end

  describe "the list (U1, U5)" do
    test "a row per run with state, run, runtime, host, started, duration and denials", %{
      conn: conn,
      scope: scope
    } do
      run =
        started_run(scope, Map.put(shop(), "task", "checkout-tax"),
          ago: 125,
          egress: [%{"decision" => "denied", "rule" => ""}, %{}],
          exit: %{"state" => "failed", "exit_code" => 1, "duration_ms" => 411_000}
        )

      view = open(conn)
      cells = text(view, row(run))

      assert cells =~ "Failed exit 1"
      assert cells =~ "checkout-tax #{String.slice(run.run_id, 0, 8)}"
      assert cells =~ "claude 2.1.0"
      assert cells =~ "dev-laptop"
      assert cells =~ "2 minutes ago"
      assert cells =~ "6 m 51 s"
      assert has_element?(view, "#{row(run)} .q-denials", "1")
      assert has_element?(view, "#{row(run)} a.q-rowlink[href='/hive/runs/#{run.run_id}']")
      assert text(view, "#runs-summary") =~ "1 run in 1 repository 1 ended badly 1 with denials"
      assert text(view, "#runs-footer") =~ "Showing 1 of 1."
    end

    test "a run without a task shows its command; a pinged run shows only that", %{
      conn: conn,
      scope: scope
    } do
      plain = started_run(scope, %{})
      pending = run_fixture(scope)
      view = open(conn)

      assert text(view, row(plain)) =~ "claude -p fix the build"
      assert text(view, row(plain)) =~ "· no task label"

      cells = text(view, row(pending))
      assert cells =~ "Pending"
      assert cells =~ "Ping only"
      assert cells =~ "n/a n/a"
      refute cells =~ "no task label"
    end

    test "a running run counts up; a quiet one is amber and says at least", %{
      conn: conn,
      scope: scope
    } do
      live_run = started_run(scope, shop(), ago: 100, heartbeat: {5, 90, 30})
      quiet = started_run(scope, shop("gitlab.example"), ago: 600, heartbeat: {47, 510, 30})
      view = open(conn)

      assert has_element?(view, "#{row(live_run)} .q-state-running")
      assert has_element?(view, "#{row(live_run)} time[data-tick=duration]")
      refute has_element?(view, "#{row(live_run)} .q-quiet")

      # What the runner said had elapsed (90 s) plus the server time since it said so
      # (5 s): not the 100 s since the runner's own started_at.
      assert text(view, "#{row(live_run)} time[data-tick=duration]") =~ ~r/^1 m 3[567] s$/

      assert has_element?(
               view,
               "#{row(live_run)} time[data-tick=duration][data-base='90'][data-now]"
             )

      refute has_element?(view, "#{row(quiet)} .q-state-running")

      assert text(view, "#{row(quiet)} .q-quiet") =~
               ~r/^No heartbeat for \d\d s \. Heartbeats are due every 30 s\./

      assert text(view, row(quiet)) =~ "at least 8 m 30 s"
    end

    test "a running run that never beat turns amber one default interval after it was first heard",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop(), ago: 5)
      view = open(conn)
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
      view = open(conn)

      assert text(view, row(lost)) =~ "Lost"
      assert text(view, row(lost)) =~ "at least 41 m 30 s"

      {:ok, _} = Runs.close_run(scope, lost)
      assert text(view, row(lost)) =~ "Closed"
      assert text(view, row(lost)) =~ "at least 41 m 30 s"
    end

    test "another hive's runs are not listed", %{conn: conn, scope: scope} do
      mine = started_run(scope, shop())
      theirs = started_run(scope_fixture(), shop())
      view = open(conn)

      assert has_element?(view, row(mine))
      refute has_element?(view, row(theirs))
      assert text(view, "#runs-summary") =~ "1 run in"
    end
  end

  describe "grouping (U2, U3)" do
    setup %{scope: scope} do
      %{
        github: started_run(scope, Map.put(shop(), "task", "checkout-tax"), ago: 300),
        gitlab:
          started_run(scope, Map.put(shop("gitlab.example"), "task", "checkout-tax"), ago: 200),
        plain: started_run(scope, %{}, ago: 100)
      }
    end

    test "by target: two systems with one path are two groups, unassigned is last", %{
      conn: conn
    } do
      view = open(conn)
      groups = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("tr.q-group button")
      labels = for button <- groups, do: button |> LazyHTML.attribute("aria-label") |> hd()

      assert labels == [
               "gitlab.example acme/shop, 1 run, 1 alive",
               "github.example acme/shop, 1 run, 1 alive",
               "Unassigned, 1 run, 1 alive"
             ]

      assert render(view) =~ "no forge or repository label"

      assert has_element?(
               view,
               "tr.q-group a[href='/hive/connections?system=github.example&target=acme%2Fshop']"
             )

      assert has_element?(view, "#runs-group button[aria-pressed=true]", "Repository")
    end

    test "by task: one task spans targets, each row leads with its target", %{
      conn: conn,
      github: github
    } do
      view = open(conn)
      view |> element("#runs-group button", "Task") |> render_click()
      assert_patch(view, ~p"/hive/runs?group=task")
      render_async(view)

      assert has_element?(view, "tr.q-group button[aria-label='checkout-tax, 2 runs, 2 alive']")
      assert render(view) =~ "2 runs in 2 repositories"
      assert render(view) =~ "no task label"
      assert text(view, "#{row(github)} .q-rowlink") == "github.example/ acme/shop"
      assert text(view, "#runs-summary") =~ "3 runs in 1 task"
    end

    test "not grouped: no headers, and a target column", %{conn: conn, github: github} do
      view = open(conn, ~p"/hive/runs?group=none")
      refute has_element?(view, "tr.q-group")
      assert has_element?(view, "th", "Repository")
      assert text(view, "#{row(github)} .q-c-target") == "github.example/ acme/shop"
    end
  end

  describe "filters are the URL (U4)" do
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

    test "a copied URL reproduces the view", %{conn: conn, failed: failed, running: running} do
      view =
        open(
          conn,
          ~p"/hive/runs?state=failed&system=github.example&target=acme/shop&task=fix-cart&runtime=claude&host=build-02&denials=1&since=24h"
        )

      assert has_element?(view, row(failed))
      refute has_element?(view, row(running))
      assert has_element?(view, "#filter-state-button[aria-label='State: Failed, change']")
      assert has_element?(view, "#filter-target-button", "github.example/acme/shop")
      assert has_element?(view, "#filter-since-button", "last 24 hours")
      assert has_element?(view, "#filter-denials[aria-pressed=true]")

      assert has_element?(
               view,
               "#filter-runtime-remove[aria-label='Remove filter: runtime claude']"
             )
    end

    test "unknown values are dropped and the URL is rewritten", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/hive/runs?state=failed,bogus&group=colour&since=90d&zzz=1")

      assert to == "/hive/runs?state=failed"
    end

    test "the menus are counted from the data and patch the URL", %{conn: conn, running: running} do
      view = open(conn)

      assert text(view, "#filter-state-form") =~ "Running 1"
      assert text(view, "#filter-state-form") =~ "Failed 1"
      assert text(view, "#filter-host-form") =~ "build-02 1"

      view |> form("#filter-state-form") |> render_change(%{"state" => ["running"]})
      assert_patch(view, ~p"/hive/runs?state=running")
      render_async(view)
      assert has_element?(view, row(running))
      assert text(view, "#runs-summary") =~ "1 run in"

      view |> form("#filter-task-form") |> render_change(%{"task" => "mirror-sync"})
      assert_patch(view, ~p"/hive/runs?state=running&task=mirror-sync")

      view |> element("#filter-state-remove") |> render_click()
      assert_patch(view, ~p"/hive/runs?task=mirror-sync")

      view |> element("#filter-denials") |> render_click()
      assert_patch(view, ~p"/hive/runs?denials=1&task=mirror-sync")

      view |> element("#runs-filters-clear") |> render_click()
      assert_patch(view, ~p"/hive/runs")
    end

    test "the State menu reads as three families, each heading a checkbox over its states",
         %{conn: conn} do
      view = open(conn)
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
               "Stopped by the workplace: a member closed it after it went quiet. Counted with the runs that ended badly."

      refute has_element?(view, "#{form} input[name=family_alive][checked]")
      refute has_element?(view, "#{form} input[name=family_alive][aria-checked]")
    end

    test "ticking a family fills its states into the URL, and the chip reads the family",
         %{conn: conn, failed: failed, running: running} do
      view = open(conn)

      # Without the page's script: the heading alone, the state boxes as the form has them.
      view
      |> form("#filter-state-form")
      |> render_change(%{"_target" => ["family_ended_badly"], "family_ended_badly" => "1"})

      assert URI.decode(assert_patch(view)) == "/hive/runs?state=failed,timed_out,lost,closed"
      render_async(view)
      assert has_element?(view, row(failed))
      refute has_element?(view, row(running))
      assert has_element?(view, "#filter-state-button[aria-label='State: ended badly, change']")

      assert has_element?(
               view,
               "#filter-state-remove[aria-label='Remove filter: state ended badly']"
             )

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
               "/hive/runs?state=pending,running,failed,timed_out,lost,closed"

      render_async(view)

      assert has_element?(
               view,
               "#filter-state-button[aria-label='State: alive, ended badly, change']"
             )

      # Unticking a heading takes its states out. A browser leaves an unticked box out of
      # the form it sends, which the test client would merge back in from the DOM: the
      # event is sent as the browser would.
      render_change(view, "filter", %{
        "_filter" => "state",
        "_target" => ["family_ended_badly"],
        "state" => ~w(pending running failed timed_out lost closed)
      })

      assert URI.decode(assert_patch(view)) == "/hive/runs?state=pending,running"
    end

    test "a family with some of its states chosen is mixed, and the chip reads the states",
         %{conn: conn} do
      view = open(conn, ~p"/hive/runs?state=failed")

      assert has_element?(
               view,
               "#filter-state-form input[name=family_ended_badly][aria-checked=mixed]"
             )

      refute has_element?(view, "#filter-state-form input[name=family_ended_badly][checked]")
      refute has_element?(view, "#filter-state-form input[name=family_alive][aria-checked]")
      assert has_element?(view, "#filter-state-button[aria-label='State: Failed, change']")
      assert has_element?(view, "#filter-state-remove[aria-label='Remove filter: state Failed']")
    end

    test "the summary line counts the families, a family at zero left out",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(), ago: 200, exit: %{"state" => "succeeded", "exit_code" => 0})
      view = open(conn)

      assert text(view, "#runs-summary") =~
               "3 runs in 2 repositories 1 alive 1 ended well 1 ended badly 1 with denials"

      view = open(conn, ~p"/hive/runs?state=running")
      summary = text(view, "#runs-summary")
      assert summary =~ "1 run in 1 repository 1 alive"
      refute summary =~ "ended"
    end

    test "the time range: a preset, dates, and none", %{conn: conn} do
      view = open(conn)
      assert has_element?(view, "#filter-since-button", "last 7 days")

      view
      |> form("#filter-since-form")
      |> render_change(%{"since" => "30d", "_target" => ["since"]})

      assert_patch(view, ~p"/hive/runs?since=30d")

      view
      |> form("#filter-since-form")
      |> render_change(%{"from" => "2026-09-14", "to" => "2026-09-16", "_target" => ["to"]})

      assert_patch(view, ~p"/hive/runs?from=2026-09-14&to=2026-09-16")
      render_async(view)
      assert has_element?(view, "#filter-since-button", "14 Sep 2026 to 16 Sep 2026")

      view |> element("#filter-since-remove") |> render_click()
      assert_patch(view, ~p"/hive/runs?since=all")
      render_async(view)
      refute has_element?(view, "#filter-since-remove")
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

      names = ~w(group state forge repo task runtime host since from to denials page)

      for name <- names, value <- bad do
        {view, to} = follow(conn, ~p"/hive/runs?#{%{name => value}}")
        render_async(view)
        assert has_element?(view, "#runs-filters"), "#{name}=#{inspect(value)} broke the page"
        refute has_element?(view, "#runs-error")
        assert URI.parse(to).path == "/hive/runs"
      end

      # Lists and maps where a string is expected.
      for name <- names, shape <- ["#{name}[]=x", "#{name}[a]=x", "#{name}[a][]=x"] do
        {view, to} = follow(conn, "/hive/runs?" <> shape)
        render_async(view)
        assert has_element?(view, "#runs-filters"), "#{shape} broke the page"
        assert to == "/hive/runs"
      end
    end

    test "a refused value is said, never silently an unfiltered list", %{conn: conn, scope: scope} do
      started_run(scope, shop())

      assert {:error, {:live_redirect, %{to: "/hive/runs"}}} =
               live(conn, ~p"/hive/runs?#{%{"task" => <<0>>}}")

      # The rewrite is a patch of the same view in a browser: the notice rides along.
      {:ok, view, _html} = live(conn, ~p"/hive/runs?state=running")
      render_async(view)
      refute has_element?(view, "#runs-dropped")

      render_patch(
        view,
        ~p"/hive/runs?#{%{"host" => String.duplicate("h", 1025), "since" => "90d"}}"
      )

      assert_patch(view, ~p"/hive/runs")
      render_async(view)

      assert text(view, "#runs-dropped") ==
               "The link's host, since filters could not be read, so they are not applied."

      # The reader's next change takes the notice away.
      view |> element("#filter-denials") |> render_click()
      refute has_element?(view, "#runs-dropped")
    end

    test "a host as long as the column holds is a filter like any other", %{
      conn: conn,
      scope: scope
    } do
      long = String.duplicate("h", 1024)
      run = started_run(scope, shop(), host: long)
      other = started_run(scope, shop())

      view = open(conn, ~p"/hive/runs?#{%{"host" => long}}")
      assert has_element?(view, row(run))
      refute has_element?(view, row(other))
      refute has_element?(view, "#runs-dropped")
    end
  end

  describe "targets and menus at any size" do
    test "a system with a colon groups, links and filters", %{conn: conn, scope: scope} do
      run = started_run(scope, %{"forge" => "git.example:8443", "repository" => "acme/shop"})
      other = started_run(scope, shop())
      view = open(conn)

      connections =
        ~p"/hive/connections?#{Apiary.Runs.Filters.target_params("git.example:8443", "acme/shop")}"

      assert has_element?(view, "tr.q-group a[href='#{connections}']")

      value = Apiary.Runs.Filters.target_value({"git.example:8443", "acme/shop"})
      view |> form("#filter-target-form") |> render_change(%{"target" => value})

      assert_patch(
        view,
        ~p"/hive/runs?#{%{"system" => "git.example:8443", "target" => "acme/shop"}}"
      )

      render_async(view)

      assert has_element?(view, row(run))
      refute has_element?(view, row(other))
      assert has_element?(view, "#filter-target-button", "git.example:8443/acme/shop")
    end

    test "a long menu shows fifty values, says so, and narrows on the server", %{
      conn: conn,
      scope: scope
    } do
      for n <- 1..60 do
        run_fixture(scope, %{state: "running", task: "task-#{n}", started_at: DateTime.utc_now()})
      end

      view = open(conn, ~p"/hive/runs?group=none")
      assert text(view, "#filter-task-more") == "Showing 50 of 60: type to narrow"

      view |> form("#filter-task-narrow") |> render_change(%{"q" => "task-6"})
      render_async(view)
      assert text(view, "#filter-task-form") == "task-6 1 task-60 1"
      refute has_element?(view, "#filter-task-more")

      view |> form("#filter-task-narrow") |> render_change(%{"q" => "%"})
      render_async(view)
      assert text(view, "#filter-task-form") == "Nothing matches"
    end

    test "two group labels that collide under a short hash are two groups", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, Map.put(shop(), "task", "a"))
      started_run(scope, Map.put(shop("gitlab.example"), "task", "a"))
      view = open(conn)

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#runs > tbody[data-group]")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

      assert length(ids) == 2
      assert Enum.all?(ids, &(&1 =~ ~r/^runs-group-[a-z2-7]{16}$/))
      assert ids == Enum.uniq(ids)
    end
  end

  describe "accessibility" do
    test "toggles and segments are buttons, the filter opens a named dialog, tips are text", %{
      conn: conn,
      scope: scope
    } do
      quiet = started_run(scope, shop(), ago: 600, heartbeat: {47, 510, 30})
      view = open(conn)

      assert has_element?(view, "button#filter-denials[type=button][aria-pressed=false]")

      assert has_element?(
               view,
               "#runs-group button[type=button][aria-pressed=true]",
               "Repository"
             )

      refute has_element?(view, "#runs-filters [role=button]")

      assert has_element?(
               view,
               "#filter-state-button[aria-haspopup=dialog][aria-controls=filter-state-panel]"
             )

      assert has_element?(view, "#filter-state-panel[role=dialog][aria-label='Filter by state']")

      # What a sighted reader gets from the tooltip is in the text for everyone else.
      assert has_element?(view, "#{row(quiet)} .q-quiet[tabindex='0'] .sr-only", "After 1 m 30 s")
      assert has_element?(view, "#{row(quiet)} .q-c-dur [tabindex='0'] .sr-only", "clock stops")
    end

    test "the table keeps its roles whole, headers included", %{conn: conn, scope: scope} do
      run = started_run(scope, shop())
      view = open(conn)

      assert has_element?(view, "table#runs[role=table] > thead[role=rowgroup] > tr[role=row]")
      assert has_element?(view, "#runs th[role=columnheader][scope=col]", "Denials")
      assert has_element?(view, "#runs > tbody[role=rowgroup] > #{row(run)}[role=row]")
      refute has_element?(view, "#runs th:not([role=columnheader])")
      refute has_element?(view, "#{row(run)} td:not([role=cell])")
    end
  end

  describe "pagination keeps the URL" do
    test "fifty a page, previous and next", %{conn: conn, scope: scope} do
      for _ <- 1..51, do: run_fixture(scope)
      view = open(conn, ~p"/hive/runs?group=none")

      assert text(view, "#runs-footer") =~ "Showing 50 of 51."
      assert has_element?(view, "#runs-previous[disabled]")

      view |> element("#runs-next") |> render_click()
      assert_patch(view, ~p"/hive/runs?group=none&page=2")
      render_async(view)
      assert text(view, "#runs-footer") =~ "Showing 1 of 51."
      assert has_element?(view, "#runs-next[disabled]")
    end
  end

  describe "live" do
    test "a run on the page changes in place", %{conn: conn, scope: scope} do
      run = started_run(scope, shop(), ago: 30)
      view = open(conn)
      assert text(view, row(run)) =~ "Running"

      event_fixture(run, 60, "run.exited", %{
        "state" => "succeeded",
        "exit_code" => 0,
        "duration_ms" => 30_000
      })

      {:ok, _} = Projector.project(run)

      assert text(view, row(run)) =~ "Succeeded"
      assert text(view, row(run)) =~ "30 s"
      render_async(view)
      refute text(view, "#runs-summary") =~ "alive"
    end

    test "changes inside a window are collected and applied together, without a query per message",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop(), ago: 30)
      other = started_run(scope, shop(), ago: 20)
      view = open(conn)

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
      view = open(conn)

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
      view = open(conn, ~p"/hive/runs?task=a")
      started_run(scope, Map.put(shop(), "task", "b"), ago: 1)
      refute has_element?(view, "#runs-new")
    end

    test "another hive's run changes nothing", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn)
      started_run(scope_fixture(), shop(), ago: 1)
      refute has_element?(view, "#runs-new")
    end

    test "the quiet state is the server's, on a change and on its timer", %{
      conn: conn,
      scope: scope
    } do
      run = started_run(scope, shop(), ago: 100, heartbeat: {5, 90, 30})
      view = open(conn)
      refute has_element?(view, "#{row(run)} .q-quiet")

      Repo.update_all(Apiary.Runs.Run,
        set: [last_heartbeat_at: DateTime.add(DateTime.utc_now(), -40, :second)]
      )

      Runs.broadcast_changed(Repo.reload!(run))
      assert has_element?(view, "#{row(run)} .q-quiet")

      send(view.pid, :quiet_tick)
      assert has_element?(view, "#{row(run)} .q-quiet")
    end

    test "the sidebar counts the runs alive now, on every page of the hive", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/hive/keys")
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
