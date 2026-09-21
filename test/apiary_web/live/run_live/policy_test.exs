defmodule ApiaryWeb.RunLive.PolicyTest do
  @moduledoc """
  The run page and the security policy (`docs/design/brief-policy.md`, pd8, pd9, pe6): the
  header's version and drift mark, the timeline's "Policy applied again", and Allow and
  Deny from a row of the connections tab.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures, only: [shop: 0]

  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Projector, Record, Run}

  setup :register_and_log_in_user

  @other "sha256=" <> String.duplicate("0f", 32)

  @denied %{
    "host" => "files.cdn.example",
    "decision" => "denied",
    "rule" => "",
    "outcome" => "refused"
  }
  @registry %{"host" => "registry.example", "rule" => "registry.example"}
  @paste %{
    "host" => "bin.paste.example",
    "decision" => "denied",
    "rule" => "",
    "outcome" => "refused"
  }
  @wall %{
    "host" => "169.254.169.254",
    "port" => 80,
    "decision" => "denied",
    "rule" => "wall:own-address",
    "outcome" => "refused"
  }

  # A run of github.example/acme/shop: started, a policy applied, the egress given, and
  # with `again:` a second policy applied; `exit: true` ends it.
  defp policy_run(scope, opts \\ []) do
    run = run_fixture(scope)
    time = DateTime.add(DateTime.utc_now(), -60, :second)
    at = &DateTime.add(time, &1, :second)

    event_fixture(run, 2, "run.started", started_data(%{"labels" => shop()}), time: time)

    event_fixture(
      run,
      3,
      "run.policy_applied",
      applied(opts[:applied], ["registry.example"], opts[:mode] || "enforce"),
      time: at.(1)
    )

    for {egress, n} <- Enum.with_index(Keyword.get(opts, :egress, []), 4) do
      event_fixture(run, n, "run.egress", egress_data(egress), time: at.(n))
    end

    if again = opts[:again] do
      event_fixture(
        run,
        30,
        "run.policy_applied",
        applied(again, ["registry.example", "files.cdn.example"]),
        time: at.(30)
      )
    end

    if opts[:exit] do
      event_fixture(run, 50, "run.exited", %{"state" => "succeeded", "exit_code" => 0},
        time: at.(45)
      )
    end

    {:ok, run} = Projector.project(run)
    run
  end

  defp applied(digest, allow, mode \\ "enforce")

  defp applied(nil, allow, mode), do: %{"mode" => mode, "allow" => allow, "source" => "none"}

  defp applied(digest, allow, mode) do
    %{
      "mode" => mode,
      "allow" => allow,
      "source" => "fetched",
      "url" => "https://qory.example/v1/run-configuration",
      "digest" => String.duplicate("ab", 32),
      "run_configuration" => digest
    }
  end

  # What the run's last batch named in X-Qory-Run-Configuration.
  defp report(%Run{} = run, digest) do
    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [reported_run_configuration_digest: digest]
    )

    run = Repo.get!(Run, run.id)
    Runs.broadcast_changed(run)
    run
  end

  defp repository(scope, run) do
    {:ok, repository} = Policy.get_repository(scope, Repo.get!(Run, run.id).repository_id)
    repository
  end

  defp in_force(scope, target) do
    {:ok, configuration} = Policy.current_configuration(scope, target)
    configuration
  end

  defp connection_id(run, host) do
    Repo.one!(from c in Connection, where: c.run_id == ^run.id and c.host == ^host, select: c.id)
  end

  defp connections(conn, run) do
    {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}/connections")
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.replace("&#39;", "'")
    |> String.trim()
  end

  # The change reaches the page on the policy's own topic, once: the sidebar's hook lets
  # it through to a page that subscribed, and leaves the process one subscription. Only
  # the 250 ms of coalescing is skipped, not waited.
  defp heard_policy_change(view, scope) do
    # answered after the broadcast, which was sent before this was asked
    assert :sys.get_state(view.pid).socket.assigns.policy_flush_scheduled

    subscriptions =
      Apiary.PubSub
      |> Registry.lookup(Policy.topic(scope.hive.id))
      |> Enum.count(fn {pid, _} -> pid == view.pid end)

    assert subscriptions == 1
    send(view.pid, :policy_flush)
  end

  defp enforce(scope) do
    {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
    {:ok, _} = Policy.set_mode(scope, "enforce")
    :ok
  end

  describe "the header's policy cell (pd9)" do
    test "the version the run reported links to that exact version", %{conn: conn, scope: scope} do
      run = policy_run(scope, applied: @other)
      repository = repository(scope, run)
      enforce(scope)
      {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.acme.example"})
      configuration = in_force(scope, repository)
      run = report(run, configuration.digest)

      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      path = "/hive/policy/repositories/#{repository.id}/versions/#{configuration.version}"

      assert has_element?(
               view,
               ~s(#run-facts a.q-ver[href="#{path}"]),
               "v#{configuration.version}"
             )

      assert text(view, "#run-facts") =~ String.slice(configuration.digest, 7, 12)
      refute has_element?(view, "#run-drift")
      refute has_element?(view, "#run-behind")
    end

    test "a digest of the hive's baseline says so", %{conn: conn, scope: scope} do
      run = policy_run(scope, applied: @other)
      enforce(scope)
      configuration = in_force(scope, nil)
      run = report(run, configuration.digest)

      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert has_element?(
               view,
               ~s(#run-facts a.q-ver[href="/hive/policy/versions/#{configuration.version}"])
             )

      assert text(view, "#run-facts") =~ "v#{configuration.version} · of hive baseline"
    end

    test "behind a repository's version while on the baseline's: both numberings are named", %{
      conn: conn,
      scope: scope
    } do
      run = policy_run(scope, applied: @other)
      repository = repository(scope, run)
      enforce(scope)
      {:ok, _} = Policy.allow(scope, nil, %{host: "one.example"})
      baseline = in_force(scope, nil)
      run = report(run, baseline.digest)
      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      assert text(view, "#run-facts") =~ "v#{baseline.version} · of hive baseline"

      # the repository's first rule gives it a numbering of its own, at v1
      {:ok, _} = Policy.allow(scope, repository, %{host: "files.cdn.example"})
      own = in_force(scope, repository)
      assert own.version == 1
      heard_policy_change(view, scope)

      assert text(view, "#run-drift") == "Behind v1 · github.example/acme/shop"
      notice = text(view, "#run-behind")
      assert notice =~ "It last reported the hive baseline's v#{baseline.version}"
      assert notice =~ "github.example/acme/shop's v1"
      assert notice =~ "is in force"
      # the two numberings do not compare: the link opens the version in force
      path = "/hive/policy/repositories/#{repository.id}/versions/1"

      assert has_element?(
               view,
               ~s(#run-behind-diff[href="#{path}"]),
               "Open github.example/acme/shop's v1"
             )

      # the details tab names both
      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}/details")
      assert text(view, "#policy-version") =~ "v#{baseline.version} · of hive baseline"
      assert text(view, "#policy-in-force") =~ "v1 · of github.example/acme/shop"
    end

    test "a digest no version here has is not rendered here, and links nowhere", %{
      conn: conn,
      scope: scope
    } do
      run = policy_run(scope, applied: @other)
      enforce(scope)
      run = report(run, @other)

      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      assert text(view, "#policy-unrendered") == "0f0f0f0f0f0f · not rendered here"
      refute has_element?(view, "#run-facts a.q-ver")
    end

    test "an alive run that reported another digest is behind, until it reports the one in force",
         %{conn: conn, scope: scope} do
      run = policy_run(scope, applied: @other)
      repository = repository(scope, run)
      enforce(scope)
      {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.acme.example"})
      old = in_force(scope, repository)
      run = report(run, old.digest)

      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      refute has_element?(view, "#run-drift")

      # someone changes the policy: the page hears of it on the policy's topic
      {:ok, _} = Policy.allow(scope, repository, %{host: "files.cdn.example"})
      new = in_force(scope, repository)
      heard_policy_change(view, scope)

      # versions count per target: every one named says whose it is
      assert text(view, "#run-drift") == "Behind v#{new.version} · github.example/acme/shop"
      assert text(view, "#run-behind") =~ "This run is behind the policy in force."

      assert text(view, "#run-behind") =~
               "It last reported github.example/acme/shop's v#{old.version}"

      assert text(view, "#run-behind") =~ "github.example/acme/shop's v#{new.version}"

      assert text(view, "#run-behind") =~
               "it decides by github.example/acme/shop's v#{old.version}"

      compare =
        "/hive/policy/repositories/#{repository.id}/versions/#{new.version}?compare=#{old.version}"

      assert has_element?(view, ~s(#run-behind-diff[href="#{compare}"]))
      assert text(view, "#run-announcer") == "This run is behind the policy in force."

      # the run reloads: its next batch names the new digest
      report(run, new.digest)
      refute has_element?(view, "#run-drift")
      refute has_element?(view, "#run-behind")
      assert has_element?(view, "#run-facts a.q-ver", "v#{new.version}")
    end

    test "an ended run is never behind: it ran under what it ran under", %{
      conn: conn,
      scope: scope
    } do
      run = policy_run(scope, applied: @other, exit: true)
      repository = repository(scope, run)
      enforce(scope)
      old = in_force(scope, nil)
      run = report(run, old.digest)
      {:ok, _} = Policy.allow(scope, repository, %{host: "files.cdn.example"})

      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      refute has_element?(view, "#run-drift")
      refute has_element?(view, "#run-behind")
      assert has_element?(view, "#run-facts a.q-ver", "v#{old.version}")
    end

    test "a hive whose policy nobody has made shows no version and no drift", %{
      conn: conn,
      scope: scope
    } do
      run = policy_run(scope)
      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")
      refute has_element?(view, "#run-facts a.q-ver")
      refute has_element?(view, "#run-drift")
      assert text(view, "#run-facts") =~ "no policy"
    end
  end

  describe "the timeline (pe6)" do
    test "a second policy applied is a reload, with the delta of the two events", %{
      conn: conn,
      scope: scope
    } do
      enforce(scope)
      v1 = in_force(scope, nil)
      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example"})
      v2 = in_force(scope, nil)
      run = policy_run(scope, applied: v1.digest, again: v2.digest)

      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert text(view, "#e-3") =~ "Policy applied"
      refute text(view, "#e-3") =~ "again"
      assert has_element?(view, ~s(#e-3 a.q-ver[href="/hive/policy/versions/#{v1.version}"]))

      again = text(view, "#e-30")
      assert again =~ "Policy applied again"
      assert again =~ "reloaded · enforce · 2 hosts allowed"
      assert text(view, "#e-30 .q-delta-add") == "+ Added: files.cdn.example"
      refute has_element?(view, "#e-30 .q-delta-del")
      assert has_element?(view, ~s(#e-30 a.q-ver[href="/hive/policy/versions/#{v2.version}"]))

      assert text(view, "#e-30-reload") =~
               "The runner fetched a new run configuration after the server's answer named a new digest."

      assert text(view, "#e-30-reload") =~ "#0003 : 1 host added, none removed."

      assert text(view, "#e-30-reload") =~
               "Connections before this item were decided by the hive baseline's v#{v1.version}."

      assert text(view, "#e-30 .q-pv") == "v#{v2.version} · of hive baseline"
    end

    test "a reload that names the digest it had is not called new", %{conn: conn, scope: scope} do
      enforce(scope)
      v = in_force(scope, nil)
      run = policy_run(scope, applied: v.digest, again: v.digest)
      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      sentence = text(view, "#e-30-reload")
      refute sentence =~ "new"

      assert sentence =~
               "The runner fetched its run configuration again; the digest is the one it had."
    end

    test "a reload's deny list: the count on the item, chips with the deny mark, the Details",
         %{conn: conn, scope: scope} do
      run = run_fixture(scope)
      time = DateTime.add(DateTime.utc_now(), -60, :second)
      event_fixture(run, 2, "run.started", started_data(%{"labels" => shop()}), time: time)

      event_fixture(
        run,
        3,
        "run.policy_applied",
        Map.put(applied(nil, ["api.example"], "observe"), "deny", ["t.example"]),
        time: time
      )

      event_fixture(
        run,
        9,
        "run.policy_applied",
        Map.put(applied(nil, ["api.example"], "observe"), "deny", ["u.example", "v.example"]),
        time: time
      )

      {:ok, run} = Projector.project(run)
      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      assert text(view, "#e-3") =~ "observe · 1 host allowed · denies 1 host"
      assert text(view, "#e-9") =~ "reloaded · observe · 1 host allowed · denies 2 hosts"

      html = view |> element("#e-9") |> render()
      assert length(Regex.scan(~r/q-delta-deny-add/, html)) == 2
      assert length(Regex.scan(~r/q-delta-deny-del/, html)) == 1
      assert html =~ "hero-no-symbol-micro"
      assert text(view, "#e-9 .q-delta-deny-del") == "− Deny removed: t.example"
      refute has_element?(view, "#e-9 .q-delta-add")

      assert text(view, "#e-9-reload") =~
               "the same hosts are allowed; denies 2 hosts more and 1 host fewer."

      {:ok, _view, html} = live(conn, ~p"/hive/runs/#{run.run_id}/details")
      details = html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")
      assert details =~ "Allowed hosts api.example"
      assert details =~ "Denied hosts u.example, v.example"
    end

    test "a host of an event is text, whatever it holds", %{conn: conn, scope: scope} do
      run = run_fixture(scope)
      time = DateTime.add(DateTime.utc_now(), -60, :second)
      event_fixture(run, 2, "run.started", started_data(%{"labels" => shop()}), time: time)
      event_fixture(run, 3, "run.policy_applied", applied(nil, []), time: time)

      event_fixture(
        run,
        9,
        "run.policy_applied",
        applied(nil, [
          "<script>alert(1)</script>",
          "a.example",
          "b.example",
          "c.example",
          "d.example"
        ]),
        time: time
      )

      {:ok, run} = Projector.project(run)
      {:ok, view, _html} = live(conn, ~p"/hive/runs/#{run.run_id}")

      html = view |> element("#e-9") |> render()
      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;"
      # three chips, and the rest counted
      assert length(Regex.scan(~r/q-delta-add/, html)) == 3
      assert text(view, "#e-9") =~ "and 2 more"
    end
  end

  describe "the slot of a row (pd8)" do
    setup %{scope: scope} do
      enforce(scope)
      {:ok, rule} = Policy.deny(scope, nil, %{host: "*.paste.example"})
      {:ok, _} = Policy.lock(scope, rule)
      run = policy_run(scope, egress: [@registry, @denied, @paste, @wall])
      %{run: run}
    end

    test "Allow, Deny, the padlock, and nothing for the wall: always there", %{
      conn: conn,
      run: run
    } do
      view = connections(conn, run)
      id = &"#cx-#{connection_id(run, &1)}-act"

      assert text(view, "button" <> id.("files.cdn.example")) == "Allow"
      # no rule decides it, so it can be denied outright too; the Deny is a bordered button
      assert text(view, "button" <> id.("files.cdn.example") <> "-deny.q-rowbtn-deny") == "Deny"
      assert text(view, "button" <> id.("registry.example")) == "Deny"
      refute has_element?(view, "button" <> id.("registry.example") <> "-deny")

      assert has_element?(
               view,
               ~s(button#{id.("bin.paste.example")}[aria-label="A locked hive rule denies *.paste.example"])
             )

      assert text(view, "span" <> id.("169.254.169.254")) == "No rule changes this"
      refute has_element?(view, "#rule-popover")
    end

    test "the popover asks for whom, the repository first, and says what happens next", %{
      conn: conn,
      run: run
    } do
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")
      view |> element("#cx-#{id}-act") |> render_click()

      assert text(view, "#rule-popover-title") == "Allow files.cdn.example"
      assert has_element?(view, ~s(#rule-popover input[name=for][value=repository][checked]))
      assert text(view, "#rule-popover") =~ "This repository github.example/acme/shop"
      assert text(view, "#rule-popover") =~ "The whole hive"
      assert has_element?(view, ~s(#cx-#{id}-act[aria-expanded=true]))
      assert text(view, "#rule-popover-submit") == "Allow for this repository"

      # this run holds no configuration fetched from here
      assert text(view, "#rule-popover-next") =~
               "Takes effect in running sessions within a heartbeat, about 30 s. This run uses its machine's policy"

      view |> form("#rule-popover-form", %{"for" => "hive"}) |> render_change()
      assert text(view, "#rule-popover-submit") == "Allow for the hive"

      view |> element("#rule-popover-cancel") |> render_click()
      refute has_element?(view, "#rule-popover")
      assert has_element?(view, ~s(#cx-#{id}-act[aria-expanded=false]))
    end

    test "allowing keeps the record as it was and adds the line after", %{
      conn: conn,
      scope: scope
    } do
      # a run that fetched the configuration in force, and reports it
      digest = in_force(scope, nil).digest
      run = policy_run(scope, applied: digest, egress: [@registry, @denied])
      repository = repository(scope, run)
      run = report(run, digest)
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")

      view |> element("#cx-#{id}-act") |> render_click()

      assert text(view, "#rule-popover-next") =~
               "This run is alive: its next attempt can succeed."

      view |> form("#rule-popover-form") |> render_submit()

      # the rule is the repository's, made by the domain
      assert [%{host: "files.cdn.example", action: "allow"}] =
               Policy.list_rules(scope, repository)

      new = in_force(scope, repository)

      # the row is the record: still denied, the same counts and reason
      refute has_element?(view, "#rule-popover")
      assert has_element?(view, ~s(tr#cx-#{id}.q-denied[data-decision=denied]))
      assert text(view, "#cx-#{id}") =~ "No rule matches. Enforce mode denies it."

      # and it gains the line: a rule was added, and this run has not reloaded
      line = text(view, "#cx-#{id}-after")
      assert line =~ "Rule added"

      assert line =~
               "Allowed for this repository in v#{new.version} · of github.example/acme/shop by you"

      assert line =~ "The run has not reloaded yet."
      refute line =~ "In force in this run"

      rule = "/hive/policy/repositories/#{repository.id}?rule=files.cdn.example"
      assert has_element?(view, ~s(a#cx-#{id}-act[href="#{rule}"]), "Rule")

      # the toast names the change and the version
      html = render(view)
      assert html =~ "files.cdn.example is allowed for github.example/acme/shop."
      assert html =~ "Version #{new.version}. Running sessions have it within a heartbeat."
      assert has_element?(view, "#run-drift", "Behind v#{new.version}")

      # only the run's own report makes it "in force in this run"
      report(run, new.digest)
      line = text(view, "#cx-#{id}-after")
      assert line =~ "In force in this run"

      assert line =~
               "Allowed for this repository in v#{new.version} · of github.example/acme/shop . The run has reported it."

      refute line =~ "has not reloaded"
      assert has_element?(view, ~s(tr#cx-#{id}.q-denied))
    end

    test "once the run reloaded and the row's last attempt is allowed by the rule, the line stays",
         %{conn: conn, scope: scope} do
      # denied first; the rule is added; the run reloads and the next attempt is allowed by it
      digest = in_force(scope, nil).digest
      run = policy_run(scope, applied: digest, egress: [@denied, @registry])
      repository = repository(scope, run)
      {:ok, _} = Policy.allow(scope, repository, %{host: "files.cdn.example"})
      new = in_force(scope, repository)
      time = DateTime.add(DateTime.utc_now(), -10, :second)

      event_fixture(run, 30, "run.policy_applied", applied(new.digest, ["files.cdn.example"]),
        time: time
      )

      event_fixture(
        run,
        31,
        "run.egress",
        egress_data(%{"host" => "files.cdn.example", "rule" => "files.cdn.example"}),
        time: DateTime.add(time, 1, :second)
      )

      {:ok, run} = Projector.project(run)
      run = report(run, new.digest)
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")

      # the record: one denied, one allowed, the last by the rule
      assert has_element?(view, ~s(tr#cx-#{id}[data-decision=allowed]))
      assert text(view, "#cx-#{id}") =~ "Rule files.cdn.example"
      line = text(view, "#cx-#{id}-after")
      assert line =~ "In force in this run"

      assert line =~
               "Allowed for this repository in v#{new.version} · of github.example/acme/shop"

      assert line =~ "The run reloaded at #0030."
      assert text(view, "a#cx-#{id}-act") == "Rule"

      # a row that was never denied is not one a rule answered: it can be denied
      registry = connection_id(run, "registry.example")
      refute has_element?(view, "#cx-#{registry}-after")
      assert text(view, "button#cx-#{registry}-act") == "Deny"
    end

    test "a run that takes no policy from here is not promised a reload", %{
      conn: conn,
      run: run
    } do
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")
      view |> element("#cx-#{id}-act") |> render_click()
      view |> form("#rule-popover-form") |> render_submit()

      line = text(view, "#cx-#{id}-after")
      assert line =~ "Rule added"
      assert line =~ "This run uses its machine's policy and does not take this one."
      refute line =~ "In force"
    end

    test "an ended run has the rule for its next run", %{conn: conn, scope: scope} do
      run = policy_run(scope, egress: [@denied], exit: true)
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")
      view |> element("#cx-#{id}-act") |> render_click()
      refute text(view, "#rule-popover-next") =~ "This run"
      view |> form("#rule-popover-form") |> render_submit()

      assert text(view, "#cx-#{id}-after") =~
               "This run has ended; the next run of the repository has it."
    end

    test "denying for the hive replaces the hive's rule, and the row stays allowed", %{
      conn: conn,
      scope: scope,
      run: run
    } do
      view = connections(conn, run)
      id = connection_id(run, "registry.example")
      view |> element("#cx-#{id}-act") |> render_click()

      assert text(view, "#rule-popover") =~
               "Disables the hive's allow rule here. Other repositories keep it."

      view |> form("#rule-popover-form", %{"for" => "hive"}) |> render_change()
      assert text(view, "#rule-popover-submit") == "Deny for the hive"

      assert text(view, "#rule-popover-next") =~
               "Open connections to the host are closed at the reload."

      view |> form("#rule-popover-form") |> render_submit()

      assert Enum.any?(
               Policy.list_rules(scope, nil),
               &(&1.host == "registry.example" and &1.action == "deny")
             )

      assert has_element?(view, ~s(tr#cx-#{id}[data-decision=allowed]))
      assert text(view, "#cx-#{id}-after") =~ "Denied for the hive"
      assert has_element?(view, ~s(a#cx-#{id}-act[href="/hive/policy?rule=registry.example"]))
    end

    test "denying a host no rule decides writes the rule, and holds under observe too",
         %{conn: conn, scope: scope} do
      # this run's own policy observes (the mode of its last policy_applied)
      observed = %{"host" => "files.cdn.example", "rule" => "", "mode" => "observe"}
      run = policy_run(scope, egress: [observed], mode: "observe")
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")
      assert has_element?(view, "button#cx-#{id}-act.q-rowbtn-allow", "Allow")
      view |> element("#cx-#{id}-act-deny") |> render_click()

      assert text(view, "#rule-popover-title") == "Deny files.cdn.example"
      assert has_element?(view, ~s(#cx-#{id}-act-deny[aria-expanded=true]))
      assert has_element?(view, ~s(#cx-#{id}-act[aria-expanded=false]))
      assert text(view, "#rule-popover-submit") == "Deny for this repository"

      # A deny holds in either mode: the sentence is the one of enforce, not a promise
      # deferred to the day the mode changes.
      assert text(view, "#rule-popover-next") =~
               "Open connections to the host are closed at the reload."

      refute text(view, "#rule-popover-next") =~ "observes"

      view |> form("#rule-popover-form") |> render_submit()
      repository = Runs.fetch_repository(scope, "github.example", "acme/shop")
      assert "files.cdn.example" in Policy.effective(scope, repository).deny

      assert [%{action: "deny"}] =
               Enum.filter(
                 Policy.list_rules(scope, repository),
                 &(&1.host == "files.cdn.example")
               )

      assert text(view, "#cx-#{id}-after") =~ "Denied for this repository"
    end

    test "what the domain refuses is said in its sentence, and nothing is written", %{
      conn: conn,
      scope: scope
    } do
      # A path allowed by a pattern cannot be taken out of it: the domain refuses.
      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example", paths: ["/v1/*"]})

      run =
        policy_run(scope,
          egress: [
            %{
              "host" => "files.cdn.example",
              "rule" => "files.cdn.example",
              "method" => "GET",
              "request_method" => "GET",
              "path" => "/v1/a",
              "path_rule" => "/v1/*"
            }
          ]
        )

      id = connection_id(run, "files.cdn.example")
      {:ok, connection} = Record.connection(scope, run, id)

      {:error, %Policy.Error{message: sentence}} =
        Policy.rule_from_connection(scope, connection, :deny, :repository)

      view = connections(conn, run)
      view |> element("#cx-#{id}-act") |> render_click()
      view |> form("#rule-popover-form") |> render_submit()

      assert text(view, "#rule-popover-error") == sentence
      assert has_element?(view, "#rule-popover-error[role=alert]")
      assert Policy.list_rules(scope, repository(scope, run)) == []
    end

    test "a locked rule: the owner is told where to change it, and there is no form", %{
      conn: conn,
      run: run
    } do
      view = connections(conn, run)
      view |> element("#cx-#{connection_id(run, "bin.paste.example")}-act") |> render_click()

      assert text(view, "#rule-popover-title") == "bin.paste.example stays denied"
      refute has_element?(view, "#rule-popover-form")
      refute has_element?(view, "#rule-popover-submit")

      refusal = text(view, "#rule-popover-refusal")
      assert refusal =~ "A locked hive rule denies *.paste.example ."
      assert refusal =~ "so no rule added here would change what happens."
      assert refusal =~ "Locked by"
      assert refusal =~ "You can change or unlock it on the hive's policy page."

      assert has_element?(
               view,
               ~s(#rule-popover-locked-rule[href="/hive/policy?rule=%2A.paste.example"])
             )

      view |> element("#rule-popover-close") |> render_click()
      refute has_element?(view, "#rule-popover")
    end

    test "a member sees the padlock and the refusal, and can allow what is not locked", %{
      scope: scope,
      run: run
    } do
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)
      view = connections(conn, run)

      paste = connection_id(run, "bin.paste.example")
      assert has_element?(view, "button#cx-#{paste}-act .hero-lock-closed-micro")
      view |> element("#cx-#{paste}-act") |> render_click()
      assert text(view, "#rule-popover-refusal") =~ "Only an owner can change or unlock it."
      refute text(view, "#rule-popover-refusal") =~ "You can change"
      view |> element("#rule-popover-close") |> render_click()

      cdn = connection_id(run, "files.cdn.example")
      view |> element("#cx-#{cdn}-act") |> render_click()
      view |> form("#rule-popover-form") |> render_submit()
      assert [%{host: "files.cdn.example"}] = Policy.list_rules(scope, repository(scope, run))
    end
  end

  describe "the popover says what the chosen scope will get" do
    @pathed %{
      "host" => "api.pathed.example",
      "path" => "/v2/x",
      "request_method" => "GET",
      "decision" => "denied",
      "rule" => "api.pathed.example",
      "outcome" => "refused"
    }

    test "a path for the repository that holds the host to paths, the whole host for the hive that does not",
         %{conn: conn, scope: scope} do
      enforce(scope)
      run = policy_run(scope, egress: [@pathed])
      repository = repository(scope, run)
      {:ok, _} = Policy.allow(scope, repository, %{host: "api.pathed.example", paths: ["/ok/*"]})

      view = connections(conn, run)
      id = connection_id(run, "api.pathed.example")
      view |> element("#cx-#{id}-act") |> render_click()

      assert text(view, "#rule-popover-title") == "Allow on api.pathed.example"
      assert text(view, "#rule-popover-what") =~ "This path /v2/x is added to the paths in force"

      # for the hive the host has no paths: the rule would be the whole host, and it says so
      view |> form("#rule-popover-form", %{"for" => "hive"}) |> render_change()
      assert text(view, "#rule-popover-title") == "Allow api.pathed.example"
      refute has_element?(view, "#rule-popover-what-set")

      assert text(view, "#rule-popover-own-rule") ==
               "This repository's own rule still decides here."

      assert text(view, "#rule-popover-submit") == "Allow for the hive"

      view |> form("#rule-popover-form") |> render_submit()

      assert [%{host: "api.pathed.example", paths: nil}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "api.pathed.example"))

      html = render(view)
      assert html =~ "api.pathed.example is allowed for the hive."
      assert html =~ "This repository&#39;s own rule still decides here."

      # and the row is not said to be answered: for this repository the path is still not allowed
      refute has_element?(view, "#cx-#{id}-after")
      assert text(view, "#cx-#{id}-act") == "Allow"
    end

    test "the toast names the path when a path is what was added", %{conn: conn, scope: scope} do
      enforce(scope)
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.pathed.example", paths: ["/v1/*"]})
      run = policy_run(scope, egress: [@pathed])
      view = connections(conn, run)
      id = connection_id(run, "api.pathed.example")
      view |> element("#cx-#{id}-act") |> render_click()
      view |> form("#rule-popover-form") |> render_submit()

      assert [%{paths: ["/v1/*", "/v2/x"]}] = Policy.list_rules(scope, repository(scope, run))

      assert render(view) =~
               "/v2/x on api.pathed.example is allowed for github.example/acme/shop."

      assert text(view, "#cx-#{id}-after") =~ "Allowed for this repository"
    end
  end

  describe "a popover that the policy moved under" do
    setup %{scope: scope} do
      enforce(scope)
      %{run: policy_run(scope, egress: [@denied])}
    end

    test "is not sent: a deny made meanwhile is not overwritten by a stale Allow", %{
      conn: conn,
      scope: scope,
      run: run
    } do
      repository = repository(scope, run)
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")
      view |> element("#cx-#{id}-act") |> render_click()

      {:ok, _} = Policy.deny(scope, repository, %{host: "files.cdn.example"})
      # sent before the page has read the change
      view |> form("#rule-popover-form") |> render_submit()

      assert [%{host: "files.cdn.example", action: "deny"}] = Policy.list_rules(scope, repository)
      refute has_element?(view, "#rule-popover")
      assert render(view) =~ "The policy changed; look at the row again."
    end

    test "closes when the change arrives: a locked deny is not turned into a locked allow", %{
      conn: conn,
      scope: scope,
      run: run
    } do
      view = connections(conn, run)
      id = connection_id(run, "files.cdn.example")
      view |> element("#cx-#{id}-act") |> render_click()
      view |> form("#rule-popover-form", %{"for" => "hive"}) |> render_change()

      {:ok, rule} = Policy.deny(scope, nil, %{host: "files.cdn.example"})
      {:ok, _} = Policy.lock(scope, rule)
      heard_policy_change(view, scope)

      refute has_element?(view, "#rule-popover")
      assert render(view) =~ "The policy changed; look at the row again."
      assert has_element?(view, "button#cx-#{id}-act .hero-lock-closed-micro")

      # and a crafted send with nothing open changes nothing
      render_submit(view, "rule_submit", %{"for" => "hive"})

      assert [%{action: "deny", locked: true}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))
    end

    test "a member's crafted send against a locked host changes nothing", %{
      scope: scope,
      run: run
    } do
      {:ok, rule} = Policy.deny(scope, nil, %{host: "files.cdn.example"})
      {:ok, _} = Policy.lock(scope, rule)
      %{user: member} = member_fixture(scope, :member)
      view = connections(log_in_user(build_conn(), member), run)
      id = connection_id(run, "files.cdn.example")

      # the padlock opens the refusal, which has nothing to send
      view |> element("#cx-#{id}-act") |> render_click()
      render_change(view, "rule_change", %{"for" => "hive"})
      render_submit(view, "rule_submit", %{"for" => "hive"})
      render_click(view, "rule_open", %{"id" => id, "action" => "allow"})
      render_submit(view, "rule_submit", %{"for" => "repository"})

      assert [%{action: "deny", locked: true}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))

      assert Policy.list_rules(scope, repository(scope, run)) == []
    end
  end

  describe "tenancy of the row's events" do
    test "a connection of another hive is not found, whatever the event names", %{
      conn: conn,
      scope: scope
    } do
      enforce(scope)
      run = policy_run(scope, egress: [@denied])

      other = scope_fixture()
      enforce(other)
      theirs = policy_run(other, egress: [@denied])
      their_id = connection_id(theirs, "files.cdn.example")

      view = connections(conn, run)

      for action <- ~w(allow deny) do
        render_click(view, "rule_open", %{"id" => their_id, "action" => action})
        refute has_element?(view, "#rule-popover")
      end

      # crafted events with no popover open, or with values that are not what is asked for
      render_click(view, "rule_submit", %{"for" => "hive"})
      render_change(view, "rule_change", %{"for" => "hive"})
      render_click(view, "rule_open", %{"id" => %{"a" => 1}, "action" => "allow"})

      render_click(view, "rule_open", %{
        "id" => connection_id(run, "files.cdn.example"),
        "action" => "lock"
      })

      refute has_element?(view, "#rule-popover")

      assert Policy.list_rules(scope, nil) |> Enum.map(& &1.host) == ["registry.example"]
      assert Policy.list_rules(other, nil) |> Enum.map(& &1.host) == ["registry.example"]

      assert Record.connection(scope, run, their_id) == :error
      assert Runs.fetch_connection(scope, their_id) == :error
      assert Record.connection(scope, run, "not-a-uuid") == :error
      assert {:ok, %Connection{}} = Runs.fetch_connection(other, their_id)
    end

    test "a row asks only for what it stands for: the wall's row opens nothing", %{
      conn: conn,
      scope: scope
    } do
      enforce(scope)
      run = policy_run(scope, egress: [@denied, @wall])
      view = connections(conn, run)

      # the wall's row stands for nothing; a denied row no rule decides can be denied
      render_click(view, "rule_open", %{
        "id" => connection_id(run, "169.254.169.254"),
        "action" => "deny"
      })

      render_click(view, "rule_open", %{
        "id" => connection_id(run, "169.254.169.254"),
        "action" => "allow"
      })

      refute has_element?(view, "#rule-popover")
    end
  end
end
