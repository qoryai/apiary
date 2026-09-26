defmodule ApiaryWeb.PolicyLive.TargetTest do
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias ApiaryWeb.PolicyComponents

  setup :register_and_log_in_user

  # The coalescing window of a reload is none here, so a broadcast is followed by its
  # reload as the next message and no test waits.
  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  setup %{scope: scope} do
    started_run(scope, shop())
    [%{target: target}] = Policy.list_targets(scope)

    {:ok, _} = Policy.deny(scope, nil, %{host: "*.paste.example", locked: true})
    {:ok, _} = Policy.allow(scope, nil, %{host: "gitlab.example"})
    {:ok, _} = Policy.deny(scope, nil, %{host: "telemetry.example"})
    {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
    {:ok, _} = Policy.allow(scope, nil, %{kind: "credential", name: "model-key"})

    %{target: target, path: workspace_path(scope, "/policy/targets/#{target.id}")}
  end

  defp open(conn, path) do
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
    |> String.trim()
  end

  defp row(view, host) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#policy-rules tr.q-rule-row")
    |> Enum.find(&(LazyHTML.query(&1, ".q-host") |> LazyHTML.text() |> String.trim() == host))
    |> LazyHTML.attribute("id")
    |> hd()
  end

  defp own(scope, target, host),
    do: Enum.find(Policy.list_rules(scope, target), &(&1.host == host))

  test "another workspace's target is not found, nor is an id that is none", %{
    conn: conn,
    scope: scope
  } do
    other = scope_fixture()
    started_run(other, shop())
    [%{target: theirs}] = Policy.list_targets(other)
    {:ok, _} = Policy.allow(other, theirs, %{host: "secret.example"})

    for path <- [
          workspace_path(scope, "/policy/targets/#{theirs.id}"),
          workspace_path(scope, "/policy/targets/nope")
        ] do
      {:ok, view, html} = live(conn, path)
      assert html =~ "This repository is not in this workspace"
      refute html =~ "secret.example"
      assert has_element?(view, "#nav-policy[aria-current=page]")
      assert has_element?(view, "a[href='#{workspace_path(scope, "/policy")}']", "Back to policy")
      assert render_hook(view, "composer_save", %{}) =~ "This repository is not in this workspace"
    end
  end

  test "a target without rules of its own is the workspace's list, and says so",
       %{conn: conn, path: path, scope: scope} do
    view = open(conn, path)

    assert has_element?(view, "h1", "acme/shop")
    assert text(view, "#policy-no-own") =~ "This repository has no rules of its own."
    assert text(view, "#policy-no-own") =~ "It is served the workspace baseline, version"
    assert text(view, "#policy-baseline") == "workspace baseline"
    assert text(view, "#policy-effective-n") == "4 rules · 2 hosts allowed · 2 denied"
    assert text(view, "##{row(view, "registry.example")}") =~ "Workspace"
    assert text(view, "##{row(view, "registry.example")}") =~ "Disable here"
    assert text(view, "##{row(view, "telemetry.example")}") =~ "Allow here"
    assert text(view, "##{row(view, "*.paste.example")}") =~ "Workspace, locked"

    assert has_element?(
             view,
             "##{row(view, "*.paste.example")} a[href^='#{workspace_path(scope, "/policy?rule=")}'][href$='.paste.example']",
             "Open"
           )

    assert text(view, "#policy-effective-foot") =~
             "Mode observe , the workspace's default. Credentials: model-key from the workspace."

    assert has_element?(view, "#policy-tab-runs[href*='target=acme%2Fshop']")
    assert text(view, "#policy-tab-runs") == "Runs 1"
    assert has_element?(view, "#policy-tab-connections[href*='system=github.example']")
  end

  test "disable here, then restore: the beaten rule hangs under the rule that beat it",
       %{conn: conn, scope: scope, target: target, path: path} do
    view = open(conn, path)

    view |> element("##{row(view, "gitlab.example")}-act", "Disable here") |> render_click()

    rule = own(scope, target, "gitlab.example")
    assert rule.action == "deny"

    assert text(view, "#flash-info") =~
             "gitlab.example is denied for github.example/acme/shop. Version 1."

    assert text(view, "#rule-#{rule.id}") =~ "This repository"
    assert text(view, "#rule-#{rule.id}") =~ "New in v1"
    assert text(view, "#rule-#{rule.id}-act") == "Restore"

    over = text(view, "tr[id^='rule-#{rule.id}-over-']")
    assert over =~ "Overrides the workspace's rule"
    assert over =~ "not in force: allow gitlab.example"
    assert over =~ "Disabled here by"
    assert over =~ "Other repositories keep it."
    refute has_element?(view, "#policy-no-own")

    view |> element("#policy-show button", "Overrides") |> render_click()
    assert_patch(view, path <> "?show=overrides")
    refute has_element?(view, "#policy-rules .q-host", "registry.example")

    view |> element("#rule-#{rule.id}-act", "Restore") |> render_click()
    refute own(scope, target, "gitlab.example")
    view = open(conn, path)
    assert text(view, "##{row(view, "gitlab.example")}") =~ "Disable here"
  end

  test "allow here overrides the workspace's deny", %{
    conn: conn,
    scope: scope,
    target: target,
    path: path
  } do
    view = open(conn, path)
    view |> element("##{row(view, "telemetry.example")}-act", "Allow here") |> render_click()

    rule = own(scope, target, "telemetry.example")
    assert rule.action == "allow"
    assert text(view, "tr[id^='rule-#{rule.id}-over-']") =~ "not in force: deny telemetry.example"
    assert text(view, "tr[id^='rule-#{rule.id}-over-']") =~ "Allowed here by"
    assert text(view, "#rule-#{rule.id}-act") == "Remove"
  end

  test "a rule a lock holds is struck under the locked rule, and can be removed",
       %{conn: conn, scope: scope, target: target, path: path} do
    {:ok, _} =
      Policy.unlock(
        scope,
        Enum.find(Policy.list_rules(scope, nil), &(&1.host == "*.paste.example"))
      )

    {:ok, held} = Policy.allow(scope, target, %{host: "*.paste.example"})

    {:ok, _} =
      Policy.lock(
        scope,
        Enum.find(Policy.list_rules(scope, nil), &(&1.host == "*.paste.example"))
      )

    view = open(conn, path)
    locked = row(view, "*.paste.example")

    assert text(view, "##{locked}-over-#{held.id}") =~ "Holds against this repository's rule"
    assert text(view, "##{locked}-over-#{held.id}") =~ "not in force: allow *.paste.example"
    assert text(view, "##{locked}-over-#{held.id}") =~ "It is not in force."

    view |> element("##{locked}-over-#{held.id} button", "Remove it") |> render_click()
    refute own(scope, target, "*.paste.example")
  end

  test "the composer adds for the target, and a locked workspace rule refuses it",
       %{conn: conn, scope: scope, target: target, path: path} do
    view = open(conn, path)
    assert text(view, "#policy-composer-add") == "Add for this repository"

    view
    |> form("#policy-composer", rule: %{host: "bin.paste.example", paths: ""})
    |> render_change()

    assert has_element?(view, "#policy-composer-reads[role=alert]")

    assert text(view, "#policy-composer-reads") =~
             "A locked workspace rule denies *.paste.example ."

    assert text(view, "#policy-composer-reads") =~
             "You can change or unlock it on the workspace's policy page."

    assert has_element?(view, "#policy-composer-add[disabled]")

    view
    |> form("#policy-composer", rule: %{host: "mcp.acme.example", paths: "/mcp/*"})
    |> render_change()

    view |> form("#policy-composer") |> render_submit()

    assert own(scope, target, "mcp.acme.example").paths == ["/mcp/*"]
    assert Enum.all?(Policy.list_rules(scope, nil), &(&1.host != "mcp.acme.example"))
  end

  test "a deny under the workspace's suffix is accepted and said; under a locked suffix it is refused",
       %{conn: conn, scope: scope, target: target, path: path} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "*.cdn.example"})
    {:ok, _} = Policy.allow(scope, nil, %{host: "*.internal.example", locked: true})
    view = open(conn, path)

    view |> element("#policy-composer button", "Deny") |> render_click()
    view |> form("#policy-composer", rule: %{host: "files.cdn.example"}) |> render_change()

    assert text(view, "#policy-composer-reads") =~
             "*.cdn.example still allows the other hosts below it."

    refute has_element?(view, "#policy-composer-add[disabled]")
    view |> form("#policy-composer") |> render_submit()

    assert "files.cdn.example" in Policy.effective(scope, target).deny
    assert has_element?(view, "#policy-rules .q-host", "files.cdn.example")

    view |> element("#policy-composer button", "Deny") |> render_click()
    view |> form("#policy-composer", rule: %{host: "tax.internal.example"}) |> render_change()

    assert text(view, "#policy-composer-reads") =~
             "A locked workspace rule allows *.internal.example"

    assert has_element?(view, "#policy-composer-add[disabled]")
  end

  test "a member is told only an owner changes the lock", %{scope: scope, path: path} do
    %{user: member} = member_fixture(scope, :member)
    view = open(log_in_user(build_conn(), member), path)

    view
    |> form("#policy-composer", rule: %{host: "bin.paste.example", paths: ""})
    |> render_change()

    assert text(view, "#policy-composer-reads") =~ "Only an owner can change or unlock it."
  end

  describe "the target's mode" do
    test "follows the workspace until an owner says otherwise, and says where it comes from",
         %{conn: conn, path: path} do
      view = open(conn, path)

      assert has_element?(view, "#policy-target-mode-follow[aria-checked=true]")

      assert text(view, "#policy-target-mode-effect") ==
               "In effect: observe , the workspace's default. It changes when the workspace's does."
    end

    test "to enforce asks with this target's own list, and Allow here adds a target rule",
         %{conn: conn, scope: scope, target: target, path: path} do
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "allowed", "rule" => ""}
        ]
      )

      view = open(conn, path)
      view |> element("#policy-target-mode-enforce") |> render_click()

      assert Policy.get_mode(scope, target).own == nil
      assert text(view, "#target-mode-enforce") =~ "Enforce github.example/acme/shop"

      assert text(view, "#target-mode-enforce") =~
               "The mode becomes this repository's own: it stays enforce"

      assert text(view, "#mode-would") =~ "Let through in this repository's runs"
      # A host the locked deny covers is denied in either mode already: enforcing this
      # target would not start denying it, so it is not in the list.
      refute text(view, "#mode-would") =~ "bin.paste.example"
      assert text(view, "#mode-would") =~ "1 destination"

      view |> element("#mode-would button", "Allow here") |> render_click()
      assert own(scope, target, "files.cdn.example")

      view |> element("#target-mode-confirm", "Enforce this repository") |> render_click()

      assert %{mode: "enforce", own: "enforce", workspace: "observe"} =
               Policy.get_mode(scope, target)

      assert has_element?(view, "#policy-target-mode-enforce[aria-checked=true]")
      assert text(view, "#flash-info") =~ "github.example/acme/shop enforces on its own. Version"

      assert text(view, "#policy-target-mode-effect") =~
               "In effect: enforce , this repository's own. The workspace's default is observe."

      assert text(view, "#policy-effective-foot") =~ "Mode enforce , this repository's own."
    end

    test "to observe names the locked denies that still hold, and the card keeps saying so",
         %{conn: conn, scope: scope, target: target, path: path} do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, path)
      refute has_element?(view, "#policy-target-mode-locked-note")

      view |> element("#policy-target-mode-observe") |> render_click()

      assert text(view, "#target-mode-observe") =~
               "only what a deny rule names is denied in this repository's runs"

      assert text(view, "#target-mode-observe") =~
               "A deny holds in either mode: *.paste.example stays denied in this repository"

      view |> element("#target-mode-confirm", "Observe this repository") |> render_click()
      assert Policy.get_mode(scope, target).own == "observe"

      assert text(view, "#policy-target-mode-locked-note") =~
               "This repository observes: the locked deny still holds."

      assert text(view, "#policy-target-mode-locked-note") =~
               "under observe it is the only thing denied here"

      view |> element("#policy-target-mode-follow") |> render_click()

      assert text(view, "#target-mode-enforce") =~
               "The mode follows the workspace's default from now on"

      view |> element("#target-mode-confirm", "Follow the workspace") |> render_click()
      assert Policy.get_mode(scope, target).own == nil

      assert text(view, "#flash-info") =~
               "github.example/acme/shop follows the workspace: enforce."
    end

    test "a setting that changes nothing today is immediate, and says so",
         %{conn: conn, scope: scope, target: target, path: path} do
      view = open(conn, path)
      view |> element("#policy-target-mode-observe") |> render_click()

      refute has_element?(view, "#target-mode-observe")
      assert Policy.get_mode(scope, target).own == "observe"

      assert text(view, "#flash-info") =~
               "github.example/acme/shop observes on its own. Nothing changes today: the workspace's default is observe too."
    end

    test "its history words the change", %{
      conn: conn,
      scope: scope,
      target: target,
      path: path
    } do
      {:ok, _} = Policy.set_mode(scope, target, "enforce")
      view = open(conn, path <> "/history")

      assert text(view, "#history-list") =~ "set this repository's mode to enforce"
      assert text(view, "#history-list") =~ "Its own from now on."
    end

    test "a member reads it, and a crafted event is refused", %{
      scope: scope,
      target: target,
      path: path
    } do
      %{user: member} = member_fixture(scope, :member)
      view = open(log_in_user(build_conn(), member), path)

      assert has_element?(view, "#policy-target-mode-enforce[aria-disabled=true]")
      assert text(view, "#policy-target-mode-owners") == "Only an owner sets a mode."

      render_hook(view, "target_mode_ask", %{"setting" => "enforce"})
      refute has_element?(view, "#target-mode-enforce")
      assert Policy.get_mode(scope, target).own == nil
    end
  end

  describe "suggestions" do
    setup %{scope: scope, target: target} do
      run = run_fixture(scope)

      event_fixture(run, 2, "run.started", started_data(%{"labels" => shop()}))

      event_fixture(run, 3, "run.policy_applied", %{
        "mode" => "observe",
        "allow" => [],
        "harness_hosts" => ["flags.example", "downloads.runtime.example", "registry.example"]
      })

      {:ok, _run} = Apiary.Runs.Projector.project(run)
      %{suggested: Policy.suggestions(scope, target)}
    end

    test "hosts the harness declared and nothing covers, allowed with one click",
         %{conn: conn, scope: scope, target: target, path: path, suggested: suggested} do
      assert Enum.map(suggested, & &1.host) |> Enum.sort() == [
               "downloads.runtime.example",
               "flags.example"
             ]

      view = open(conn, path)

      assert text(view, "#policy-suggestions-n") == "2 to review"
      assert text(view, "#policy-suggestions") =~ "A declaration allows nothing by itself."
      assert has_element?(view, "#policy-suggestions .q-mark-pend")

      assert text(view, "#policy-suggestions") =~
               "No run has tried to reach it in the last 7 days."

      assert text(view, "#policy-suggestions-covered") ==
               "1 more declared host is already allowed: registry.example by the workspace."

      id = PolicyComponents.suggestion_id("flags.example")
      view |> element("##{id}-allow") |> render_click()

      assert own(scope, target, "flags.example").action == "allow"
      assert text(view, "##{id}") =~ "Allowed here"
      assert has_element?(view, "##{id} .q-mark-ok")
      assert text(view, "#policy-suggestions-n") == "1 to review"
      refute has_element?(view, "#policy-suggestions-all")
    end

    test "allow both here, and allow for the workspace from the caret",
         %{conn: conn, scope: scope, target: target, path: path} do
      view = open(conn, path)
      assert text(view, "#policy-suggestions-all") == "Allow both here"

      id = PolicyComponents.suggestion_id("flags.example")
      view |> element("##{id}-menu button", "Allow for the workspace") |> render_click()
      assert Enum.find(Policy.list_rules(scope, nil), &(&1.host == "flags.example"))
      assert text(view, "##{id}") =~ "Allowed for the workspace"

      view = open(conn, path)
      refute has_element?(view, "#policy-suggestions-all")
      other = PolicyComponents.suggestion_id("downloads.runtime.example")
      view |> element("##{other}-menu button", "Allow with paths") |> render_click()
      assert has_element?(view, "#policy-composer-host[value='downloads.runtime.example']")
      refute own(scope, target, "downloads.runtime.example")
    end

    test "with nothing to review the card is absent", %{conn: conn, scope: scope, path: path} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "flags.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "downloads.runtime.example"})
      refute has_element?(open(conn, path), "#policy-suggestions")
    end
  end

  test "credentials live in the footer, and open in place",
       %{conn: conn, scope: scope, target: target, path: path} do
    view = open(conn, path)
    refute has_element?(view, "#policy-credential")

    view |> element("#policy-credentials-toggle", "Edit credentials") |> render_click()
    assert has_element?(view, "#policy-credentials-toggle[aria-expanded=true]")

    view
    |> form("#policy-credential", credential: %{name: "forge-token", argument: "acme/shop"})
    |> render_change()

    view |> form("#policy-credential") |> render_submit()

    assert Enum.find(Policy.list_rules(scope, target), &(&1.name == "forge-token"))

    assert text(view, "#policy-effective-foot") =~
             "forge-token argument acme/shop from this repository, model-key from the workspace."
  end

  test "history, versions and export are the target's own",
       %{conn: conn, scope: scope, target: target, path: path} do
    {:ok, _} = Policy.deny(scope, target, %{host: "gitlab.example"})
    [change] = Policy.list_changes(scope, target, 1).items

    view = open(conn, path <> "/history?change=#{change.id}")
    assert text(view, "#history-summary") =~ "1 change"
    assert text(view, "#chg-#{change.id}") =~ "denied gitlab.example"
    assert text(view, "#chg-#{change.id}-diff") =~ "Added: Deny gitlab.example"
    assert text(view, "#history-foot") =~ "are in the workspace's history"

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, path <> "/document")
    assert to == path <> "/versions/1"

    view = open(conn, path <> "/versions/1")
    assert has_element?(view, "h1", "Version 1")
    assert has_element?(view, ".q-crumbs a[href='#{path}']")

    view = open(conn, path <> "/versions/1/export")
    assert text(view, "#export-lead") =~ "github.example/acme/shop"
    assert has_element?(view, "#export-download[download='acme-shop-policy.yaml']")

    # The workspace's change is not this target's.
    [workspace_change | _] = Policy.list_changes(scope, nil, 1).items
    view = open(conn, path <> "/history?change=#{workspace_change.id}")
    refute has_element?(view, ".q-chg[open]")

    view = open(conn, path <> "/versions/9")
    assert has_element?(view, "h2", "There is no version 9")
  end

  test "a target served the baseline has no versions of its own: Document is the workspace's",
       %{conn: conn, path: path, scope: scope} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, path <> "/document")
    assert String.starts_with?(to, workspace_path(scope, "/policy/versions/"))

    view = open(conn, path <> "/versions/1")
    assert text(view, "#policy-page") =~ "This repository has no versions of its own"
  end
end
