defmodule ApiaryWeb.WorkspaceLive.OverviewTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo
  alias Apiary.Policy
  alias Apiary.Retention
  alias Apiary.Runs
  alias Apiary.Runs.{Liveness, Projector, Run}

  setup :register_and_log_in_user

  # No coalescing and no throttling here, so a broadcast is followed by its read as the
  # next message and no test waits on a clock.
  setup do
    Application.put_env(:apiary, ApiaryWeb.WorkspaceLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    :ok
  end

  defp open(conn, scope) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    render_async(view, 5_000)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s+([,.;:])/, "\\1")
    |> String.trim()
  end

  defp as_member(%{scope: scope}) do
    %{user: member} = member_fixture(scope, :member)
    log_in_user(build_conn(), member)
  end

  defp long_ago(%AccessKey{id: id}, days) do
    Repo.update_all(from(k in AccessKey, where: k.id == ^id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -days, :day)]
    )
  end

  defp lost_run(scope, attrs \\ %{}) do
    now = DateTime.utc_now()

    run_fixture(
      scope,
      Map.merge(
        %{
          state: "lost",
          task: "nightly-mirror",
          started_at: DateTime.add(now, -7200, :second),
          last_heartbeat_at: DateTime.add(now, -3600, :second),
          lost_at: DateTime.add(now, -3000, :second),
          elapsed_seconds: 510,
          heartbeat_interval_seconds: 30
        },
        attrs
      )
    )
  end

  describe "the empty workspace" do
    test "no key: the checklist is the page, step 1 current, nothing else renders", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert html =~ scope.workspace.name

      assert html =~
               ~r{<title[^>]*>\s*#{Regex.escape(scope.workspace.name)} · #{Regex.escape(scope.organisation.name)} · Qory Apiary\s*</title>}

      # No filler under the title: the name says which workspace it is.
      refute html =~ "The workspace of the #{scope.organisation.name} organisation."
      refute html =~ ~r/<abbr[^>]*>(hive|apiary)<\/abbr>/

      assert has_element?(view, "#onboarding[data-step='1'] h2", "Send your first run")
      assert has_element?(view, "#onboarding .q-step-current", "Create an access key")
      assert has_element?(view, "#onboarding", "Listening for the first post from a machine.")
      refute has_element?(view, "#overview-strip")
      refute has_element?(view, "#days")
      refute has_element?(view, "#overview-policy")
      refute has_element?(view, "#overview-retention")
      refute has_element?(view, "#overview-keys")

      {:ok, _lv, html} =
        view
        |> element("#onboarding-create")
        |> render_click()
        |> follow_redirect(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      assert html =~ "New access key"
    end

    test "a key, nothing posted: step 1 done, step 2 current, the box and nothing else", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key} = access_key_fixture(scope, label: "build-01")
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='2'] h2", "Send your first run")
      assert text(view, "#onboarding") =~ "One key can serve many hosts"
      assert has_element?(view, "#onboarding .q-step-done", "Create an access key")
      assert has_element?(view, "#onboarding .q-step-current", "Paste the server block")
      assert has_element?(view, "#onboarding-keys", "Manage access keys")
      assert text(view, "#onboarding") =~ key.key_id
      refute has_element?(view, "#overview-strip")
      refute has_element?(view, "#overview-targets")
    end

    test "a key was used, no run yet: step 2 done, step 3 current, listening for the run", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key} = access_key_fixture(scope, label: "build-01")
      {:ok, _} = AccessKeys.touch(key, %{last_runner_version: "v0.4.2", last_contract_version: 1})
      view = open(conn, scope)

      assert has_element?(view, "#onboarding[data-step='3']")
      assert has_element?(view, "#onboarding .q-step-current", "See runs here")
      assert text(view, "#onboarding") =~ "The machine has verified with its key."
      assert text(view, "#onboarding") =~ "Listening for the first run. build-01 verified"
      assert text(view, "#onboarding") =~ "What you pasted into ~/.config/qory/runner.yaml"
    end

    test "the first run lands: step 3 ticks, the box stays with a link, and leaves on the next mount",
         %{conn: conn, scope: scope} do
      access_key_fixture(scope, label: "build-01")
      view = open(conn, scope)
      assert has_element?(view, "#onboarding[data-step='2']")

      run = run_fixture(scope)
      event_fixture(run, 2, "run.started", started_data(), time: DateTime.utc_now())
      {:ok, _} = Projector.project(run)
      render_async(view, 5_000)

      assert has_element?(view, "#onboarding[data-step='4']")
      assert has_element?(view, "#onboarding .q-step-done", "See runs here")

      assert has_element?(
               view,
               "#onboarding-landed a[href='#{workspace_path(scope, "/runs/#{run.run_id}")}']",
               "Open it"
             )

      refute has_element?(view, "#onboarding", "Listening")
      assert has_element?(view, "#overview-strip")
      assert has_element?(view, "#overview-guard")

      view = open(conn, scope)
      refute has_element?(view, "#onboarding")
      assert has_element?(view, "#overview-strip")
    end
  end

  describe "the activity" do
    test "the summary counts the runs, the ended badly and the denials; the cost is a caption",
         %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        exit: %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 10}
      )

      started_run(scope, shop(),
        exit: %{"state" => "failed", "exit_code" => 1, "duration_ms" => 10}
      )

      started_run(scope, shop(),
        egress: [%{"host" => "ads.example", "decision" => "denied", "rule" => ""}]
      )

      # Another workspace counts for nothing here.
      started_run(scope_fixture(), shop())

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive .q-sum-v") == "1"
      assert text(view, "#overview-strip-runs .q-sum-v") == "3"
      assert text(view, "#overview-strip-runs") =~ "1 ended well"
      assert text(view, "#overview-strip-bad .q-sum-v") == "1"
      assert text(view, "#overview-strip-bad") =~ "33% of the runs"
      assert text(view, "#overview-strip-denied .q-sum-v") == "1"
      assert text(view, "#overview-strip-denied") =~ "to 1 destination"
      refute has_element?(view, "#activity-cost")
      assert text(view, "#activity-foot") =~ "Days in UTC."

      costed = run_fixture(scope)
      event_fixture(costed, 2, "run.started", started_data(), time: DateTime.utc_now())
      event_fixture(costed, 3, "session.result", %{"outcome" => "success", "cost_usd" => 0.8412})
      {:ok, _} = Projector.project(costed)
      render_async(view, 5_000)

      assert text(view, "#activity-cost") =~ "Cost reported: $0.84, by 1 of the 4 runs."
    end

    test "the chart and the active targets read the same record", %{
      conn: conn,
      scope: scope
    } do
      # The page's today is the clock's, on which a run a minute back is yesterday's for the
      # first minute after midnight UTC: the three start now, the quiet one after the
      # running one, which makes it the target's last run.
      running = started_run(scope, shop(), host: "build-01", ago: 0)
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30}, ago: 0)

      started_run(scope, %{},
        ago: 0,
        exit: %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}
      )

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive .q-sum-v") == "2"
      assert text(view, "#overview-strip-alive") =~ "1 gone quiet"

      target = Repo.get!(Apiary.Runs.Target, running.target_id)
      # One target: the run without one is on the runs list only.
      assert text(view, "#overview-targets-list") =~ "acme/shop"
      refute text(view, "#overview-targets-list") =~ "github.example"
      assert text(view, "#active-#{target.id}") =~ "2 runs"
      # The last run is the quiet one: its word, in the colour of a quiet run.
      assert has_element?(view, "#active-#{target.id} .q-rs-quiet", "Running")
      assert quiet.target_id == target.id

      assert has_element?(
               view,
               "#active-#{target.id} a[href='#{workspace_path(scope, "/targets/github.example/acme/shop")}']"
             )

      assert has_element?(view, "#overview-targets-all", "All 1 repository")

      assert has_element?(
               view,
               "#activity-all[href='#{workspace_path(scope, "/runs")}']",
               "All runs"
             )

      html = render(view)

      slots =
        html |> LazyHTML.from_document() |> LazyHTML.query("#days a[data-day]") |> Enum.to_list()

      assert length(slots) == 14
      today = Date.to_iso8601(Date.utc_today())

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][href='#{workspace_path(scope, "/runs?from=#{today}&to=#{today}")}']"
             )

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][aria-label*='Today: 3 runs (1 ended well, 2 alive or ended badly), 0 denied attempts']"
             )

      assert has_element?(view, "#days .q-col-runs.q-col-today")

      assert has_element?(
               view,
               "#days svg[aria-label*='3 runs and 0 denied attempts in 14 days; most runs on today, 3.']"
             )

      # The chart is drawn for the width the browser measured.
      render_hook(view, "chart_size", %{"width" => 503})
      assert has_element?(view, "#days svg[viewBox^='0 0 500 ']")

      # The table twin, then the chart again.
      view |> element("#days-toggle") |> render_click()
      assert has_element?(view, "#days-toggle[aria-pressed=true]", "As a chart")
      assert has_element?(view, "#days table th", "Ended well")
      assert has_element?(view, "#days-row-#{today} td", "Today")
      refute has_element?(view, "#days svg")
      render_hook(view, "chart_table", %{"on" => false})
      assert has_element?(view, "#days svg")
    end

    test "the active targets are the eight with the most runs; a path on two systems names them",
         %{conn: conn, scope: scope} do
      for _ <- 1..3, do: started_run(scope, shop(), ago: 600)
      for _ <- 1..2, do: started_run(scope, shop("gitlab.example"), ago: 600)

      for n <- 1..8,
          do: started_run(scope, %{"forge" => "github.example", "repository" => "acme/t#{n}"})

      view = open(conn, scope)

      rows =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#overview-targets-list li")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.replace(&1, ~r/\s+/, " "))

      assert length(rows) == 8
      assert Enum.at(rows, 0) =~ "github.example/acme/shop"
      assert Enum.at(rows, 1) =~ "gitlab.example/acme/shop"
      assert Enum.at(rows, 2) =~ "acme/t1"
      refute Enum.at(rows, 2) =~ "github.example"
      assert has_element?(view, "#overview-targets-all", "All 10 repositories")
    end

    test "with no run in the fortnight the chart has fourteen stubs and no target is active",
         %{conn: conn, scope: scope} do
      run_fixture(scope, %{
        state: "succeeded",
        started_at: DateTime.add(DateTime.utc_now(), -20, :day)
      })

      view = open(conn, scope)

      assert text(view, "#overview-strip-alive") =~ "none"
      html = render(view)

      assert html |> LazyHTML.from_document() |> LazyHTML.query("#days .q-stub") |> Enum.count() ==
               28

      assert has_element?(view, "#days.q-chart-empty")
      assert has_element?(view, "#overview-targets-none", "in the last 14 days")
    end

    test "the caption says when the denied destinations were not counted", %{
      conn: conn,
      scope: scope
    } do
      Application.put_env(:apiary, Apiary.Policy.Activity, cap: 2)
      on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Activity) end)

      started_run(scope, shop(),
        egress: [
          %{"host" => "a.example", "decision" => "denied", "rule" => ""},
          %{"host" => "b.example", "decision" => "denied", "rule" => ""},
          %{"host" => "c.example", "decision" => "denied", "rule" => ""}
        ]
      )

      view = open(conn, scope)
      assert has_element?(view, "#activity-uncounted", "Denied destinations were not counted")
      refute has_element?(view, "#attention li[data-kind=denied]")
      # The summary's denials come from the runs, not from the capped read: they stay.
      assert text(view, "#overview-strip-denied .q-sum-v") == "3"
    end
  end

  describe "guard" do
    @tag needs: :security
    test "policy: a new workspace, then a managed one with a version, own rules and hosts to review",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop())
      view = open(conn, scope)

      assert text(view, "#overview-policy-version") == "observe"

      assert text(view, "#overview-policy-mode") ==
               "Machines use their own policy until the first change here."

      assert has_element?(
               view,
               "#overview-policy-open[href='#{workspace_path(scope, "/policy")}']"
             )

      event_fixture(run, 20, "run.policy_applied", %{
        "harness_hosts" => ["registry.example", "cdn.example"]
      })

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.set_mode(scope, "enforce")
      render_async(view, 5_000)

      assert text(view, "#overview-policy-version") == "enforce · v2"
      assert text(view, "#overview-policy-mode") =~ "In force since"
      assert text(view, "#overview-policy-mode") =~ "1 of 1 repository follow it."
      assert text(view, "#overview-policy-mode") =~ "2 declared hosts to review in 1 repository."
      assert text(view, "#overview-own") =~ "Every repository follows the workspace's mode."

      target = Repo.get!(Apiary.Runs.Target, run.target_id)
      {:ok, _} = Policy.set_mode(scope, target, "observe")
      render_async(view, 5_000)

      assert text(view, "#overview-own") =~ "acme/shop observes; the rest follow the workspace."

      assert has_element?(
               view,
               "#overview-own-review[href='#{workspace_path(scope, "/policy/targets")}']"
             )
    end

    test "retention: the setting in a few words and the last prune", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn, scope)
      assert text(view, "#overview-retention-setting") == "Everything is kept"
      assert text(view, "#overview-retention-last") =~ "Nothing is pruned"

      assert has_element?(
               view,
               "#overview-retention-settings[href='#{workspace_path(scope, "/settings/runs")}']"
             )

      {:ok, _} =
        Retention.update_retention(scope, %{
          "events_retention_days" => "90",
          "log_retention_days" => "30"
        })

      view = open(conn, scope)

      assert text(view, "#overview-retention-setting") == "30 days of log output"

      assert text(view, "#overview-retention-last") ==
               "No prune has run yet. The job runs nightly."

      workspace = Apiary.Repo.get!(Apiary.Organisations.Workspace, scope.workspace.id)
      %{runs_pruned: 0} = Retention.prune_workspace(workspace)
      view = open(conn, scope)

      assert text(view, "#overview-retention-last") =~
               "Nothing was old enough to prune last night."
    end
  end

  describe "needs attention" do
    @tag needs: :security
    test "is absent when there is nothing to do", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, scope)
      refute has_element?(view, "#attention")
      assert has_element?(view, "#overview-strip")
    end

    @tag needs: :security
    test "the kinds, in the order of the brief, bounded at five with the overflow linked", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: idle} = access_key_fixture(scope, label: "old-runner")
      long_ago(idle, 34)

      # Two denied destinations, one of them under a locked deny.
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "denied", "rule" => "*.paste.example"}
        ]
      )

      {:ok, deny} = Policy.deny(scope, nil, %{host: "*.paste.example"})
      {:ok, _} = Policy.lock(scope, deny)
      # An allow rule under observe, with a run this week: the enforce nudge.
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})

      lost = lost_run(scope)
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30})

      view = open(conn, scope)

      assert text(view, "#attention-n") == "5"
      assert has_element?(view, "#attention-more", "and 1 more")

      assert has_element?(
               view,
               "#attention-more[href='#{workspace_path(scope, "/settings/keys")}']"
             )

      kinds =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li")
        |> LazyHTML.attribute("data-kind")

      assert kinds == ~w(denied denied lost quiet enforce)

      denied = text(view, "#attention-list li[data-kind=denied]:first-child")
      assert denied =~ "files.cdn.example:443"
      assert denied =~ "acme/shop"
      assert denied =~ "Denied 2 times in 1 run"

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:first-child button[aria-label='Allow files.cdn.example for github.example/acme/shop']",
               "Allow here"
             )

      locked = text(view, "#attention-list li[data-kind=denied]:nth-child(2)")
      assert locked =~ "bin.paste.example:443"
      assert locked =~ "Denied by a locked rule"

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:nth-child(2) .q-ar-why[title='A locked workspace rule denies *.paste.example. Only an owner can change it.']"
             )

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:nth-child(2) a",
               "Open the rule"
             )

      assert text(view, "#att-run-#{lost.run_id}") =~ "Lost, never posted its exit"

      assert has_element?(
               view,
               "#att-run-#{lost.run_id}-act[aria-label='Close nightly-mirror']",
               "Close"
             )

      assert has_element?(
               view,
               "#att-run-#{lost.run_id} a[href='#{workspace_path(scope, "/runs/#{lost.run_id}")}']",
               "nightly-mirror"
             )

      assert text(view, "#att-run-#{quiet.run_id}") =~ "No heartbeat for"

      assert has_element?(
               view,
               "#att-run-#{quiet.run_id} .q-ar-why[title='Heartbeats are due every 30 s; after 1 m 30 s of silence it is marked lost.']"
             )

      assert has_element?(
               view,
               "#att-run-#{quiet.run_id}-act[href='#{workspace_path(scope, "/runs/#{quiet.run_id}")}']",
               "Open"
             )

      # The idle key is the sixth: on the keys page, not on this list.
      refute has_element?(view, "#att-key-#{idle.id}")
    end

    @tag needs: :security
    test "the policy items: unmanaged with runs, enforce for an owner, open policy for a member",
         %{conn: conn, scope: scope} = ctx do
      started_run(scope, shop())
      view = open(conn, scope)

      assert text(view, "#att-policy-unmanaged") =~ "Qory serves no policy yet"

      assert text(view, "#att-policy-unmanaged") =~ "1 run under the machines' policies"

      assert has_element?(
               view,
               "#att-policy-unmanaged-act[href='#{workspace_path(scope, "/policy")}']",
               "Open policy"
             )

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})
      render_async(view, 5_000)
      assert text(view, "#att-policy-unmanaged") =~ "Qory serves the policy now."
      assert has_element?(view, "#att-policy-unmanaged.q-resolved")

      assert text(view, "#att-policy-enforce") =~ "Observe is the workspace's default"

      assert text(view, "#att-policy-enforce") =~ "Enforce would deny nothing today"

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='#{workspace_path(scope, "/policy?confirm=enforce")}']",
               "Set to enforce"
             )

      member = as_member(ctx)
      view = open(member, scope)

      assert has_element?(
               view,
               "#att-policy-enforce .q-ar-why[title='Only an owner or an admin sets a mode.']"
             )

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='#{workspace_path(scope, "/policy")}']",
               "Open policy"
             )

      refute has_element?(view, "#att-policy-enforce", "Set the default")

      # Something uncovered: review, not a one-click switch.
      started_run(scope, shop(),
        egress: [%{"host" => "new.example", "decision" => "allowed", "rule" => ""}]
      )

      view = open(conn, scope)

      assert text(view, "#att-policy-enforce") =~ "Enforce would deny 1 destination"

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='#{workspace_path(scope, "/policy")}']",
               "Review"
             )
    end

    test "an idle key names its label and links to the revoke confirm", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop())
      %{access_key: idle} = access_key_fixture(scope, label: "old-runner")
      long_ago(idle, 34)
      %{access_key: fresh} = access_key_fixture(scope, label: "build-02")
      {:ok, _} = AccessKeys.touch(fresh, %{last_runner_version: "v0.4.1"})

      view = open(conn, scope)
      assert text(view, "#att-key-#{idle.id}") =~ "old-runner #{idle.key_id}"

      assert text(view, "#att-key-#{idle.id}") =~ "Never used in 34 days"

      assert has_element?(
               view,
               "#att-key-#{idle.id}-act[href='#{workspace_path(scope, "/settings/keys/#{idle.id}/revoke")}'][aria-label='Revoke old-runner']",
               "Revoke"
             )

      refute has_element?(view, "#att-key-#{fresh.id}")
    end

    test "close a lost run in place: the row stays struck, the count drops, the page says so",
         %{conn: conn, scope: scope} do
      lost = lost_run(scope)
      started_run(scope, shop())
      view = open(conn, scope)
      # With `security` the unmanaged policy is the second item, and focus goes to it;
      # without it the lost run is the only one, and focus goes to All runs.
      security? = Apiary.Features.on?(:security)
      assert text(view, "#attention-n") == if(security?, do: "2", else: "1")

      view |> element("#att-run-#{lost.run_id}-act") |> render_click()

      # The row itself asks, in place: no modal over the page.
      assert has_element?(
               view,
               "#att-run-#{lost.run_id}.q-confirming #close-run",
               "Close nightly-mirror?"
             )

      refute has_element?(view, "dialog#close-run")
      refute has_element?(view, "#att-run-#{lost.run_id}-act")

      view |> element("#close-run-cancel") |> render_click()
      refute has_element?(view, "#close-run")
      close_act = "att-run-#{lost.run_id}-act"
      assert_push_event(view, "overview:focus", %{id: ^close_act})

      view |> element("#att-run-#{lost.run_id}-act") |> render_click()
      view |> element("#att-run-#{lost.run_id} #close-confirm", "Yes, close") |> render_click()

      assert %Run{state: "closed"} = Runs.get_run!(scope, lost.id)
      assert has_element?(view, "#att-run-#{lost.run_id}.q-resolved .q-mark-closed")
      assert text(view, "#att-run-#{lost.run_id}") =~ "Closed."
      refute has_element?(view, "#att-run-#{lost.run_id}-act")
      assert text(view, "#attention-n") == if(security?, do: "1", else: "0")
      assert text(view, "#overview-announcer") == "nightly-mirror is closed."

      next = if security?, do: "att-policy-unmanaged-act", else: "activity-all"
      assert_push_event(view, "overview:focus", %{id: ^next})
    end

    @tag needs: :security
    test "allow a denied destination here: the panel in place, the rule, the struck row", %{
      conn: conn,
      scope: scope
    } do
      run =
        started_run(scope, shop(),
          egress: [%{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""}]
        )

      view = open(conn, scope)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      refute has_element?(view, "##{item}-act[aria-haspopup]")

      assert has_element?(
               view,
               "##{item}-act[aria-expanded=false][aria-controls='#{item}-panel']"
             )

      view |> element("##{item}-act") |> render_click()

      # In place, inside the item, not an overlay.
      assert has_element?(
               view,
               "li##{item} > ##{item}-panel > #rule-panel[role=group][data-anchor='#{item}-act']"
             )

      refute has_element?(view, "#rule-panel[popover], #rule-panel[role=dialog]")
      assert has_element?(view, "##{item}-act[aria-expanded=true]")
      assert has_element?(view, "#rule-panel", "files.cdn.example")
      assert has_element?(view, "#rule-panel-submit", "Allow for the repository")
      # The one target is chosen, so its option takes the focus.
      assert has_element?(view, "#rule-panel input[value=target][checked][data-autofocus]")

      # Cancel closes it; the act opens it again.
      view |> element("#rule-panel-cancel") |> render_click()
      refute has_element?(view, "##{item}-panel")
      assert has_element?(view, "##{item}-act[aria-expanded=false]")
      view |> element("##{item}-act") |> render_click()

      view |> element("#rule-panel form") |> render_submit()

      target = Repo.get!(Apiary.Runs.Target, run.target_id)

      assert [%{host: "files.cdn.example", action: "allow"}] =
               Policy.list_rules(scope, target)

      refute has_element?(view, "#rule-panel")
      assert has_element?(view, "##{item}.q-resolved .q-mark-ok")
      assert has_element?(view, "##{item}-done", "Allowed here")

      assert text(view, "#overview-announcer") =~
               "files.cdn.example is allowed for github.example/acme/shop."

      # The policy topic re-reads the list: the struck row stays where it is, and the
      # workspace is managed now, so the unmanaged item resolves in words too. A target's
      # rule is no allow rule of the workspace: no enforce nudge.
      render_async(view, 5_000)
      assert has_element?(view, "##{item}.q-resolved")
      assert has_element?(view, "#att-policy-unmanaged.q-resolved")
      refute has_element?(view, "#att-policy-enforce")
      assert text(view, "#attention-n") == "0"
    end

    @tag needs: :security
    test "a request a path rule refused is a denied request to its tool", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [
          tool_invocation_data(%{
            "path" => "/media/acme/other/checkout.png",
            "path_rule" => "",
            "decision" => "denied",
            "outcome" => "refused"
          })
        ]
      )

      view = open(conn, scope)
      selector = "#attention-list li[data-kind=denied]"

      assert has_element?(view, "#{selector} .q-dest-tool .q-tool-name", "files")

      assert text(view, "#{selector} .q-dest-tool") ==
               "Tool files /media/acme/other/checkout.png files.tools.internal:443"

      assert has_element?(
               view,
               ~s(#{selector} .q-host[title="files.tools.internal:443/media/acme/other/checkout.png, a host the tool files serves"])
             )
    end

    @tag needs: :security
    test "allow for the workspace, where several targets reached the host", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
      )

      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"},
        egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
      )

      view = open(conn, scope)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      assert text(view, "##{item}") =~ "2 repositories"
      assert text(view, "##{item}") =~ "Denied 2 times in 2 runs"
      # Several targets: the page does not guess a scope.
      assert has_element?(
               view,
               "##{item}-act[aria-label='Allow flags.example, choose a scope']",
               "Allow"
             )

      view |> element("##{item}-act") |> render_click()
      assert has_element?(view, "#rule-panel-submit[disabled]")
      render_hook(view, "rule_change", %{"for" => "workspace"})
      view |> element("#rule-panel form") |> render_submit()

      assert Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "flags.example"))
      assert has_element?(view, "##{item}-done", "Allowed for the workspace")
    end
  end

  describe "live" do
    test "a run that starts is counted; the active target's last run follows in place",
         %{conn: conn, scope: scope} do
      first = started_run(scope, shop(), ago: 600)
      view = open(conn, scope)
      target = Repo.get!(Apiary.Runs.Target, first.target_id)
      assert text(view, "#overview-strip-alive .q-sum-v") == "1"

      second = run_fixture(scope)

      event_fixture(
        second,
        2,
        "run.started",
        started_data(%{"labels" => Map.put(shop(), "task", "mirror-sync")}),
        time: DateTime.utc_now()
      )

      {:ok, _} = Projector.project(second)
      render_async(view, 5_000)

      assert text(view, "#overview-strip-alive .q-sum-v") == "2"
      assert text(view, "#overview-strip-runs .q-sum-v") == "2"
      assert has_element?(view, "#active-#{target.id} .q-rs-running", "Running")

      event_fixture(second, 50, "run.exited", %{
        "state" => "failed",
        "exit_code" => 1,
        "duration_ms" => 10
      })

      {:ok, _} = Projector.project(second)
      render_async(view, 5_000)
      assert text(view, "#overview-strip-alive .q-sum-v") == "1"
      assert has_element?(view, "#active-#{target.id} .q-rs-failed", "Failed")
      assert text(view, "#overview-strip-bad .q-sum-v") == "1"
    end

    test "a quiet run that beats again resolves its row in words; a lost run gets a row", %{
      conn: conn,
      scope: scope
    } do
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30})
      view = open(conn, scope)
      assert has_element?(view, "#att-run-#{quiet.run_id}[data-kind=quiet]")

      event_fixture(
        quiet,
        41,
        "run.heartbeat",
        %{"elapsed_seconds" => 150, "interval_seconds" => 30},
        time: DateTime.utc_now(),
        received_at: DateTime.utc_now()
      )

      {:ok, _} = Projector.project(quiet)
      render_async(view, 5_000)
      assert text(view, "#att-run-#{quiet.run_id}") =~ "Heartbeats resumed."
      assert has_element?(view, "#att-run-#{quiet.run_id}.q-resolved")
      assert text(view, "#attention-n") =~ ~r/^\d$/

      other = started_run(scope, shop())
      # The read its start set off lands first, so the page knows it as just started and
      # the row arrives Lost; a read after the backdating would find it quiet first, the
      # next test's case.
      render_async(view, 5_000)

      Repo.update_all(from(r in Run, where: r.id == ^other.id),
        set: [last_heartbeat_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert [_] = Liveness.check(DateTime.utc_now())
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{other.run_id}[data-kind=lost].q-arrived", "Lost")
      assert text(view, "#overview-announcer") == "1 more item needs attention."
    end

    test "a quiet run the check finds lost turns its row to Lost in place", %{
      conn: conn,
      scope: scope
    } do
      # Silent for four intervals: quiet on the page, and lost at the check's three.
      quiet = started_run(scope, shop(), heartbeat: {120, 100, 30})
      view = open(conn, scope)
      assert has_element?(view, "#att-run-#{quiet.run_id}[data-kind=quiet]")

      assert [_] = Liveness.check(DateTime.utc_now())
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{quiet.run_id}[data-kind=lost]", "Lost")
      refute has_element?(view, "#att-run-#{quiet.run_id}.q-resolved")
      refute text(view, "#att-run-#{quiet.run_id}") =~ "Heartbeats resumed."
      # The same row, patched: nothing arrived.
      refute has_element?(view, "#att-run-#{quiet.run_id}.q-arrived")
      assert text(view, "#overview-announcer") == ""
    end

    test "another workspace's runs change nothing here", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn, scope)
      other = scope_fixture()
      started_run(other, shop())
      render_async(view, 5_000)
      assert text(view, "#overview-strip-alive .q-sum-v") == "1"
      assert text(view, "#overview-strip-runs .q-sum-v") == "1"
    end
  end

  test "redirects to log in when signed out", %{scope: scope} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/#{scope.organisation}/#{scope.workspace}")
  end

  test "answers not found to a user who is not a member", %{scope: scope} do
    conn = log_in_user(build_conn(), Apiary.AccountsFixtures.user_fixture())
    assert conn |> get(~p"/#{scope.organisation}/#{scope.workspace}") |> html_response(404)
  end
end
