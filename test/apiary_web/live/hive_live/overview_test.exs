defmodule ApiaryWeb.HiveLive.OverviewTest do
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
    Application.put_env(:apiary, ApiaryWeb.HiveLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    :ok
  end

  defp open(conn, path \\ "/hive") do
    {:ok, view, _html} = live(conn, path)
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

  describe "the empty hive (oe6)" do
    test "no key: the checklist is the page, step 1 current, nothing else renders", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, html} = live(conn, ~p"/hive")

      assert html =~ scope.hive.name
      assert html =~ ~r{<title[^>]*>\s*#{Regex.escape(scope.hive.name)} · Qory Apiary\s*</title>}
      assert html =~ ~r/<abbr[^>]*data-tip="organisation"[^>]*>apiary<\/abbr>/
      assert html =~ ~r/<abbr[^>]*data-tip="workplace"[^>]*>hive<\/abbr>/
      refute html =~ "organisation</p>"

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
        |> follow_redirect(conn, ~p"/hive/keys/new")

      assert html =~ "New access key"
    end

    test "a key, nothing posted: step 1 done, step 2 current, the keys card with the key", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key} = access_key_fixture(scope, label: "build-01")
      view = open(conn)

      assert has_element?(view, "#onboarding[data-step='2'] h2", "Send your first run")
      assert text(view, "#onboarding") =~ "One key can serve many hosts"
      assert has_element?(view, "#onboarding .q-step-done", "Create an access key")
      assert has_element?(view, "#onboarding .q-step-current", "Paste the server block")
      assert has_element?(view, "#onboarding-keys", "Manage access keys")
      assert text(view, "#onboarding") =~ key.key_id
      assert has_element?(view, "#overview-keys #key-#{key.id}", "Never posted")
      assert has_element?(view, "#overview-keys #key-#{key.id}", "No run yet")
      refute has_element?(view, "#overview-keys-create")
      refute has_element?(view, "#overview-strip")
    end

    test "a key was used, no run yet: step 2 done, step 3 current, listening for the run", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key} = access_key_fixture(scope, label: "build-01")
      {:ok, _} = AccessKeys.touch(key, %{last_runner_version: "v0.4.2", last_contract_version: 1})
      view = open(conn)

      assert has_element?(view, "#onboarding[data-step='3']")
      assert has_element?(view, "#onboarding .q-step-current", "See runs here")
      assert text(view, "#onboarding") =~ "The machine has verified with its key."
      assert text(view, "#onboarding") =~ "Listening for the first run. build-01 verified"
      assert has_element?(view, "#overview-keys #key-#{key.id}", "0.4.2")
    end

    test "the first run lands: step 3 ticks, the card stays with a link, and leaves on the next mount",
         %{conn: conn, scope: scope} do
      access_key_fixture(scope, label: "build-01")
      view = open(conn)
      assert has_element?(view, "#onboarding[data-step='2']")

      run = run_fixture(scope)
      event_fixture(run, 2, "run.started", started_data(), time: DateTime.utc_now())
      {:ok, _} = Projector.project(run)
      render_async(view, 5_000)

      assert has_element?(view, "#onboarding[data-step='4']")
      assert has_element?(view, "#onboarding .q-step-done", "See runs here")

      assert has_element?(
               view,
               "#onboarding-landed a[href='/hive/runs/#{run.run_id}']",
               "Open it"
             )

      refute has_element?(view, "#onboarding", "Listening")
      assert has_element?(view, "#overview-strip")
      assert has_element?(view, "#overview-keys-create", "Create another access key")

      view = open(conn)
      refute has_element?(view, "#onboarding")
      assert has_element?(view, "#overview-keys-create")
    end
  end

  describe "the activity (od3 to od6)" do
    test "the strip counts the families, the denials and no cost cell until a run reported one",
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

      # Another hive counts for nothing here.
      started_run(scope_fixture(), shop())

      view = open(conn)

      assert text(view, "#overview-strip-alive") == "1"
      assert text(view, "#overview-strip-runs") == "3"
      assert text(view, "#overview-strip") =~ "1 ended well · 1 ended badly · 1 alive"
      assert text(view, "#overview-strip-denied") == "1"
      assert text(view, "#overview-strip") =~ "to 1 destination"
      assert text(view, "#overview-strip-cost") =~ "n/a"
      assert text(view, "#overview-strip") =~ "no run reported one"

      costed = run_fixture(scope)
      event_fixture(costed, 2, "run.started", started_data(), time: DateTime.utc_now())
      event_fixture(costed, 3, "session.result", %{"outcome" => "success", "cost_usd" => 0.8412})
      {:ok, _} = Projector.project(costed)
      render_async(view, 5_000)

      assert text(view, "#overview-strip-cost") =~ "$0.84"
      assert text(view, "#overview-strip-cost") =~ "by 1 of 4 runs"
    end

    test "alive rows, the last runs and the chart read the same record", %{
      conn: conn,
      scope: scope
    } do
      running = started_run(scope, shop(), host: "build-01")
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30})

      ended =
        started_run(scope, %{},
          exit: %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 48_000}
        )

      view = open(conn)

      assert text(view, "#alive-n") == "2"
      assert has_element?(view, "#alive-#{running.run_id} .q-state-running")
      assert has_element?(view, "#alive-#{running.run_id} .q-repo", "acme/shop")
      assert has_element?(view, "#alive-#{running.run_id} .q-host", "build-01")
      assert has_element?(view, "#alive-#{running.run_id} .q-alive", "Alive")
      assert has_element?(view, "#alive-#{quiet.run_id} .q-alive-amber", "No heartbeat for")
      refute has_element?(view, "#alive-#{ended.run_id}")

      assert has_element?(view, "#last-runs tr#run-#{running.run_id} .q-c-repo", "acme/shop")
      assert has_element?(view, "#last-runs tr#run-#{ended.run_id} .q-c-repo", "no repository")
      assert has_element?(view, "#last-runs tr#run-#{ended.run_id} .q-c-dur", "48 s")
      assert has_element?(view, "#last-runs-all[href='/hive/runs']", "All runs")

      assert text(view, "#days-totals") =~ "3 runs · 0 denied attempts, 14 days"
      html = render(view)

      slots =
        html |> LazyHTML.from_document() |> LazyHTML.query("#days a[data-day]") |> Enum.to_list()

      assert length(slots) == 14
      today = Date.to_iso8601(Date.utc_today())

      assert has_element?(
               view,
               "#days a[data-day='#{today}'][href='/hive/runs?from=#{today}&to=#{today}']"
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

      # The table twin, then the chart again.
      view |> element("#days-toggle") |> render_click()
      assert has_element?(view, "#days-toggle[aria-pressed=true]", "As a chart")
      assert has_element?(view, "#days table th", "Ended well")
      assert has_element?(view, "#days-row-#{today} td", "Today")
      refute has_element?(view, "#days svg")
      render_hook(view, "chart_table", %{"on" => false})
      assert has_element?(view, "#days svg")
    end

    test "with no run alive the block says so in words, and an empty fortnight has fourteen stubs",
         %{conn: conn, scope: scope} do
      run_fixture(scope, %{
        state: "succeeded",
        started_at: DateTime.add(DateTime.utc_now(), -20, :day)
      })

      view = open(conn)

      assert has_element?(view, "#alive-none", "No run alive now.")
      assert text(view, "#days-totals") == "No run in the last 14 days"
      html = render(view)

      assert html |> LazyHTML.from_document() |> LazyHTML.query("#days .q-stub") |> Enum.count() ==
               28

      assert has_element?(view, "#days.q-chart-empty")
      assert text(view, "#overview-strip") =~ "none"
    end

    test "the foot says when the denied destinations were not counted", %{
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

      view = open(conn)
      assert has_element?(view, "#activity-uncounted", "Denied destinations were not counted")
      refute has_element?(view, "#attention li[data-kind=denied]")
      # The strip's denials come from the runs, not from the capped read: they stay.
      assert text(view, "#overview-strip-denied") == "3"
    end
  end

  describe "the glances (od7 to od9)" do
    test "policy: a new hive, then a managed one with a version, repositories and things to review",
         %{conn: conn, scope: scope} do
      run = started_run(scope, shop())
      view = open(conn)

      assert text(view, "#overview-policy-mode") =~
               "observe Not served Machines use their own policy until the first change here."

      assert has_element?(view, "#overview-policy-version", "No version yet")
      assert text(view, "#overview-policy-repositories") =~ "1 has posted a run"
      assert has_element?(view, "#overview-policy-review", "Nothing declared and unallowed.")
      assert has_element?(view, "#overview-policy-open[href='/hive/policy']")

      event_fixture(run, 20, "run.policy_applied", %{
        "harness_hosts" => ["registry.example", "cdn.example"]
      })

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.set_mode(scope, "enforce")
      render_async(view, 5_000)

      assert text(view, "#overview-policy-mode") =~
               "enforce Hive default Every repository follows it."

      assert has_element?(view, "#overview-policy-version .q-vpill", "v2")
      assert text(view, "#overview-policy-version") =~ "since"
      assert has_element?(view, "#overview-policy-review a.badge", "2 to review")
      assert text(view, "#overview-policy-review") =~ "in 1 repository"

      repository = Repo.get!(Apiary.Runs.Repository, run.repository_id)
      {:ok, _} = Policy.set_mode(scope, repository, "observe")
      render_async(view, 5_000)

      assert text(view, "#overview-policy-mode") =~
               "0 repositories follow it · 1 sets its own: github.example/acme/shop observes"
    end

    test "retention: every sentence", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn)
      assert text(view, "#overview-retention") =~ "This hive keeps everything."
      refute has_element?(view, "#overview-retention-last")
      assert has_element?(view, "#overview-retention-settings[href='/hive/settings#retention']")

      {:ok, _} =
        Retention.update_retention(scope, %{
          "events_retention_days" => "90",
          "log_retention_days" => "30"
        })

      view = open(conn)

      assert text(view, "#overview-retention-setting") ==
               "Log output is pruned after 30 days, events after 90 days."

      assert text(view, "#overview-retention-last") ==
               "No prune has run yet. The job runs nightly."

      hive = Apiary.Repo.get!(Apiary.Organisations.Hive, scope.hive.id)
      %{runs_pruned: 0} = Retention.prune_hive(hive)
      view = open(conn)

      assert text(view, "#overview-retention-last") =~
               "Nothing was old enough to prune last night."
    end

    test "access keys: five at most, most recently seen first, with hosts and last run", %{
      conn: conn,
      scope: scope
    } do
      keys = for n <- 1..7, do: access_key_fixture(scope, label: "build-0#{n}").access_key
      [first, second | _] = keys
      newest = List.last(keys)

      {:ok, _} =
        AccessKeys.touch(second, %{last_runner_version: "v0.4.2", last_contract_version: 1})

      run = started_run(scope, Map.put(shop(), "task", "checkout-tax"), host: "ci-runner-07")
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [access_key_id: second.id])
      pool = for host <- ~w(ci-a ci-b ci-c), do: started_run(scope, shop(), host: host, ago: 600)
      ids = Enum.map(pool, & &1.id)
      Repo.update_all(from(r in Run, where: r.id in ^ids), set: [access_key_id: first.id])
      {:ok, _} = AccessKeys.touch(first, %{})

      view = open(conn)

      assert text(view, "#overview-keys-n") == "7"

      rows =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#overview-keys tbody tr")
        |> Enum.to_list()

      assert length(rows) == 5
      # The key that was seen comes first, then the never-seen, newest first; the oldest
      # never-seen key is the sixth and on the keys page.
      assert render(view) =~ ~r/id="key-#{second.id}".*id="key-#{newest.id}"/s
      assert has_element?(view, "#key-#{second.id} .q-c-rv", "0.4.2")
      assert has_element?(view, "#key-#{second.id} .q-c-rv [title='Contract version 1']", "v1")

      assert has_element?(
               view,
               "#key-#{second.id} .q-c-last a[href='/hive/runs/#{run.run_id}']",
               "checkout-tax"
             )

      assert has_element?(view, "#key-#{newest.id} .q-c-last", "No run yet")
      assert has_element?(view, "#key-#{second.id} .q-c-hosts", "ci-runner-07")
      assert has_element?(view, "#key-#{first.id} .q-c-hosts", "3 hosts")
      assert has_element?(view, "#key-#{newest.id} .q-c-hosts", "none")
      assert has_element?(view, "#overview-keys-more[href='/hive/keys']", "and 2 more")
    end
  end

  describe "needs attention (od1)" do
    test "is absent when there is nothing to do", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn)
      refute has_element?(view, "#attention")
      assert has_element?(view, "#overview-strip")
    end

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

      view = open(conn)

      assert text(view, "#attention-n") == "5"
      assert has_element?(view, "#attention-more", "and 1 more")
      assert has_element?(view, "#attention-more[href='/hive/keys']")

      kinds =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li")
        |> LazyHTML.attribute("data-kind")

      assert kinds == ~w(denied denied lost quiet enforce)

      denied = text(view, "#attention-list li[data-kind=denied]:first-child")
      assert denied =~ "files.cdn.example:443"
      assert denied =~ ~r"Denied 2 times in 1 run of github.example/acme/shop\s*, last"

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:first-child button[aria-label='Allow files.cdn.example for github.example/acme/shop']",
               "Allow here"
             )

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:first-child [role=menuitem]",
               "Allow for the hive"
             )

      locked = text(view, "#attention-list li[data-kind=denied]:nth-child(2)")
      assert locked =~ "bin.paste.example:443"

      assert locked =~
               ~r"A locked hive rule denies \*\.paste\.example\s*\. Only an owner can change it\."

      assert has_element?(
               view,
               "#attention-list li[data-kind=denied]:nth-child(2) a",
               "Open the rule"
             )

      assert text(view, "#att-run-#{lost.run_id}") =~ "Lost. Last heard"

      assert text(view, "#att-run-#{lost.run_id}") =~
               "at least 8 m 30 s in. The run never posted its exit."

      assert has_element?(
               view,
               "#att-run-#{lost.run_id}-act[aria-label='Close nightly-mirror']",
               "Close"
             )

      assert has_element?(
               view,
               "#att-run-#{lost.run_id} a[href='/hive/runs/#{lost.run_id}']",
               "Open"
             )

      assert text(view, "#att-run-#{quiet.run_id}") =~ "No heartbeat for"

      assert text(view, "#att-run-#{quiet.run_id}") =~
               "Heartbeats are due every 30 s; after 1 m 30 s of silence it is marked lost."

      assert has_element?(
               view,
               "#att-run-#{quiet.run_id}-act[href='/hive/runs/#{quiet.run_id}']",
               "Open"
             )

      # The idle key is the sixth: on the keys page, not on this list.
      refute has_element?(view, "#att-key-#{idle.id}")
    end

    test "the policy items: unmanaged with runs, enforce for an owner, open policy for a member",
         %{conn: conn, scope: scope} = ctx do
      started_run(scope, shop())
      view = open(conn)

      assert text(view, "#att-policy-unmanaged") =~ "Qory serves no policy yet"

      assert text(view, "#att-policy-unmanaged") =~
               "1 run landed under the machines' own policies."

      assert has_element?(view, "#att-policy-unmanaged-act[href='/hive/policy']", "Open policy")

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example.com"})
      render_async(view, 5_000)
      assert text(view, "#att-policy-unmanaged") =~ "Qory serves the policy now."
      assert has_element?(view, "#att-policy-unmanaged.q-resolved")

      assert text(view, "#att-policy-enforce") =~ "Observe is the hive's default"

      assert text(view, "#att-policy-enforce") =~
               "1 allow rule is in force and every destination reached in the last 7 days is covered. Enforce would deny nothing today."

      assert has_element?(
               view,
               "#att-policy-enforce-act.btn-primary[href='/hive/policy?confirm=enforce']",
               "Set the default to enforce"
             )

      member = as_member(ctx)
      view = open(member)
      assert text(view, "#att-policy-enforce") =~ "Only an owner sets a mode."
      assert has_element?(view, "#att-policy-enforce-act[href='/hive/policy']", "Open policy")
      refute has_element?(view, "#att-policy-enforce", "Set the default")

      # Something uncovered: review, not a one-click switch.
      started_run(scope, shop(),
        egress: [%{"host" => "new.example", "decision" => "allowed", "rule" => ""}]
      )

      view = open(conn)

      assert text(view, "#att-policy-enforce") =~
               "Enforce would deny 1 destination reached in the last 7 days."

      assert has_element?(
               view,
               "#att-policy-enforce-act[href='/hive/policy']",
               "Review on the policy page"
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

      view = open(conn)
      assert text(view, "#att-key-#{idle.id}") =~ "old-runner #{idle.key_id}"

      assert text(view, "#att-key-#{idle.id}") =~
               "Never used since it was created 34 days ago. A key nobody uses is a key to revoke."

      assert has_element?(
               view,
               "#att-key-#{idle.id}-act[href='/hive/keys/#{idle.id}/revoke'][aria-label='Revoke old-runner']",
               "Revoke"
             )

      refute has_element?(view, "#att-key-#{fresh.id}")
    end

    test "close a lost run in place: the row stays struck, the count drops, the page says so",
         %{conn: conn, scope: scope} do
      lost = lost_run(scope)
      started_run(scope, shop())
      view = open(conn)
      assert text(view, "#attention-n") == "2"

      view |> element("#att-run-#{lost.run_id}-act") |> render_click()
      assert has_element?(view, "#close-run", "Close this run")
      view |> element("#close-confirm") |> render_click()

      assert %Run{state: "closed"} = Runs.get_run!(scope, lost.id)
      assert has_element?(view, "#att-run-#{lost.run_id}.q-resolved .q-mark-closed")
      assert text(view, "#att-run-#{lost.run_id}") =~ "Closed."
      refute has_element?(view, "#att-run-#{lost.run_id}-act")
      assert text(view, "#attention-n") == "1"
      assert text(view, "#overview-announcer") == "nightly-mirror is closed."
      assert_push_event(view, "overview:focus", %{id: "att-policy-unmanaged-act"})
    end

    test "allow a denied destination here: the popover, the rule, the struck row", %{
      conn: conn,
      scope: scope
    } do
      run =
        started_run(scope, shop(),
          egress: [%{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""}]
        )

      view = open(conn)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      view |> element("##{item}-act") |> render_click()
      assert has_element?(view, "#rule-popover[data-anchor='#{item}-act']")
      assert has_element?(view, "#rule-popover", "files.cdn.example")
      assert has_element?(view, "#rule-popover-submit", "Allow for the repository")

      view |> element("#rule-popover form") |> render_submit()

      repository = Repo.get!(Apiary.Runs.Repository, run.repository_id)

      assert [%{host: "files.cdn.example", action: "allow"}] =
               Policy.list_rules(scope, repository)

      refute has_element?(view, "#rule-popover")
      assert has_element?(view, "##{item}.q-resolved .q-mark-ok")
      assert has_element?(view, "##{item}-done", "Allowed here")

      assert text(view, "#overview-announcer") =~
               "files.cdn.example is allowed for github.example/acme/shop."

      # The policy topic re-reads the list: the struck row stays where it is, and the hive
      # is managed now, so the unmanaged item resolves in words too. A repository's rule
      # is no allow rule of the hive: no enforce nudge.
      render_async(view, 5_000)
      assert has_element?(view, "##{item}.q-resolved")
      assert has_element?(view, "#att-policy-unmanaged.q-resolved")
      refute has_element?(view, "#att-policy-enforce")
      assert text(view, "#attention-n") == "0"
    end

    test "allow for the hive from the caret menu", %{conn: conn, scope: scope} do
      started_run(scope, shop(),
        egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
      )

      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"},
        egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
      )

      view = open(conn)

      [item] =
        render(view)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#attention-list li[data-kind=denied]")
        |> LazyHTML.attribute("id")

      assert text(view, "##{item}") =~ "Denied 2 times in 2 runs of 2 repositories"
      # Several repositories: the page does not guess a scope.
      assert has_element?(
               view,
               "##{item}-act[aria-label='Allow flags.example, choose a scope']",
               "Allow"
             )

      view |> element("##{item}-act") |> render_click()
      assert has_element?(view, "#rule-popover-submit[disabled]")
      render_hook(view, "rule_change", %{"for" => "hive"})
      view |> element("#rule-popover form") |> render_submit()

      assert Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "flags.example"))
      assert has_element?(view, "##{item}-done", "Allowed for the hive")
    end
  end

  describe "live (oa 5, oj 2)" do
    test "a run that starts appends an alive row; one that ends leaves; the strip and chart follow",
         %{conn: conn, scope: scope} do
      first = started_run(scope, shop())
      view = open(conn)
      assert text(view, "#alive-n") == "1"

      second = run_fixture(scope)

      event_fixture(
        second,
        2,
        "run.started",
        started_data(%{"labels" => %{"task" => "mirror-sync"}}),
        time: DateTime.utc_now()
      )

      {:ok, _} = Projector.project(second)
      render_async(view, 5_000)

      assert text(view, "#alive-n") == "2"
      assert has_element?(view, "#alive-#{second.run_id}.q-arrived", "mirror-sync")
      assert render(view) =~ ~r/id="alive-#{first.run_id}".*id="alive-#{second.run_id}"/s
      assert text(view, "#overview-strip-runs") == "2"
      assert text(view, "#days-totals") =~ "2 runs"
      # Not on the last runs under the reader: a new run in words.
      assert has_element?(view, "#last-runs-new", "1 new run")
      refute has_element?(view, "#last-runs tr#run-#{second.run_id}")

      view |> element("#last-runs-new") |> render_click()
      render_async(view, 5_000)
      assert has_element?(view, "#last-runs tr#run-#{second.run_id}")
      refute has_element?(view, "#last-runs-new")

      event_fixture(first, 50, "run.exited", %{
        "state" => "succeeded",
        "exit_code" => 0,
        "duration_ms" => 10
      })

      {:ok, _} = Projector.project(first)
      render_async(view, 5_000)
      refute has_element?(view, "#alive-#{first.run_id}")
      assert text(view, "#alive-n") == "1"
      assert has_element?(view, "#last-runs tr#run-#{first.run_id} .q-state", "Succeeded")
      assert text(view, "#overview-strip") =~ "1 ended well · 1 alive"
    end

    test "a quiet run that beats again resolves its row in words; a lost run gets a row", %{
      conn: conn,
      scope: scope
    } do
      quiet = started_run(scope, shop(), heartbeat: {45, 100, 30})
      view = open(conn)
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

      Repo.update_all(from(r in Run, where: r.id == ^other.id),
        set: [last_heartbeat_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert [_] = Liveness.check(DateTime.utc_now())
      render_async(view, 5_000)
      assert has_element?(view, "#att-run-#{other.run_id}[data-kind=lost].q-arrived", "Lost")
      assert text(view, "#overview-announcer") == "1 more item needs attention."
    end

    test "another hive's runs change nothing here", %{conn: conn, scope: scope} do
      started_run(scope, shop())
      view = open(conn)
      other = scope_fixture()
      started_run(other, shop())
      render_async(view, 5_000)
      assert text(view, "#alive-n") == "1"
      assert text(view, "#overview-strip-runs") == "1"
    end
  end

  test "redirects to log in when signed out" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/hive")
  end

  test "sends a user without a hive to a friendly page", %{conn: _conn} do
    conn = log_in_user(build_conn(), Apiary.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/no-hive"}}} = live(conn, ~p"/hive")
  end
end
