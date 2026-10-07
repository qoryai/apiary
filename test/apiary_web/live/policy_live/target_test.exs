defmodule ApiaryWeb.PolicyLive.TargetTest do
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryWeb.TargetComponents, only: [target_path: 4]
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

    %{target: target, path: target_path(scope, target.system, target.path, ["policy"])}
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
    |> LazyHTML.query("#policy-rules tr.q-pr-row")
    |> Enum.find(&(LazyHTML.query(&1, ".q-host") |> LazyHTML.text() |> String.trim() == host))
    |> LazyHTML.attribute("id")
    |> hd()
  end

  defp hosts(view, selector \\ "#policy-rules .q-host") do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
  end

  # The composer opens from Add rule: a test that types into it opens it first.
  defp compose(view) do
    if has_element?(view, "#policy-rules-add[aria-expanded=false]") do
      view |> element("#policy-rules-add") |> render_click()
    end

    view
  end

  defp type(view, params) do
    compose(view)
    view |> form("#policy-composer", rule: params) |> render_change()
  end

  defp workspace_rule(scope, host),
    do: Enum.find(Policy.list_rules(scope, nil), &(&1.host == host))

  defp own(scope, target, host),
    do: Enum.find(Policy.list_rules(scope, target), &(&1.host == host))

  test "another workspace's target is not found, by its path or by its old id", %{
    conn: conn,
    scope: scope
  } do
    other = scope_fixture()
    started_run(other, %{"forge" => "github.example", "repository" => "acme/theirs"})
    [%{target: theirs}] = Policy.list_targets(other)
    {:ok, _} = Policy.allow(other, theirs, %{host: "secret.example"})

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, target_path(scope, theirs.system, theirs.path, ["policy"]))
    end

    for id <- [theirs.id, "nope"] do
      assert_error_sent 404, fn -> get(conn, workspace_path(scope, "/policy/targets/#{id}")) end
    end
  end

  test "what its runs reached is Network access narrowed to the target", %{
    conn: conn,
    scope: scope,
    path: path
  } do
    view = open(conn, path)

    assert has_element?(
             view,
             "#policy-hosts-network[href='#{workspace_path(scope, "/network?target=acme%2Fshop")}']",
             "See what its runs reached"
           )

    # Where another system has the same path, the system is in the address too.
    started_run(scope, shop("gitlab.com"))
    view = open(conn, path)

    assert has_element?(
             view,
             "#policy-hosts-network[href='#{workspace_path(scope, "/network?system=github.example&target=acme%2Fshop")}']"
           )
  end

  test "the old paths of a target's policy send on to the Policy tab", %{
    conn: conn,
    scope: scope,
    target: target,
    path: path
  } do
    old = workspace_path(scope, "/policy/targets/#{target.id}")
    assert redirected_to(get(conn, old)) == path
    assert redirected_to(get(conn, old <> "/history?page=2")) == path <> "/history?page=2"
    assert redirected_to(get(conn, old <> "/versions/3/export")) == path <> "/versions/3/export"
  end

  test "a target without rules of its own is the workspace's list, and says so",
       %{conn: conn, path: path, scope: scope} do
    view = open(conn, path)

    assert has_element?(view, "h1", "acme/shop")
    assert text(view, "#policy-no-own") =~ "This repository has no rules of its own."

    assert text(view, "#policy-no-own") =~
             "It is served #{scope.workspace.name}'s policy, version"

    assert text(view, "#policy-baseline") == "workspace's policy"
    assert text(view, "#policy-rules-view-all") == "All 4"
    assert text(view, "#policy-rules-view-allowed") == "Allowed 2"
    assert text(view, "#policy-rules-view-denied") == "Denied 2"
    assert text(view, "#policy-rules-view-locked") == "Locked 1"

    assert hosts(view) == [
             "*.paste.example",
             "telemetry.example",
             "gitlab.example",
             "registry.example"
           ]

    assert has_element?(view, "#policy-rules-sort-button[aria-label='Sort: Its own first']")

    # Every rule is the workspace's: its source says so, its menu leads to it there, and
    # nothing changes it here.
    registry = row(view, "registry.example")
    assert text(view, "##{registry} .q-pr-src") == scope.workspace.name

    assert has_element?(
             view,
             "##{registry}-menu a[href='#{workspace_path(scope, "/policy?rule=registry.example")}']",
             "View in #{scope.workspace.name}'s policy"
           )

    refute has_element?(view, "##{registry}-menu [role=menuitem]", "Remove")
    refute has_element?(view, "##{registry}-menu [role=menuitem]", "Change to deny")
    assert text(view, "##{row(view, "*.paste.example")}-lock") == "Locked"
    refute has_element?(view, "#policy-rules .q-pr-off")

    # The policy names hosts and paths, and no credential.
    refute has_element?(view, "#policy-credentials")

    assert text(view, "#policy-hosts-note") =~
             "Its own rules come first and are changed here; #{scope.workspace.name}'s follow"

    # The target's page holds the tab: its runs and connections are its other tabs.
    assert has_element?(view, "#target-tab-policy[aria-current=page]")
    assert has_element?(view, "#target-tab-runs[href$='/acme/shop/-/runs']")
    assert has_element?(view, "#target-tab-connections[href$='/acme/shop/-/network']")
  end

  test "a deny of its own overrides the workspace's allow; removing it restores the workspace's",
       %{conn: conn, scope: scope, target: target, path: path} do
    view = open(conn, path)

    view |> compose() |> element("#policy-composer button", "Deny") |> render_click()
    type(view, %{host: "gitlab.example"})

    assert text(view, "#policy-composer-reads") =~
             "gitlab.example is allowed for the workspace. This rule denies it for this repository; other repositories keep it."

    view |> form("#policy-composer") |> render_submit()

    rule = own(scope, target, "gitlab.example")
    assert rule.action == "deny"

    assert text(view, "#flash-info") =~
             "gitlab.example is denied for github.example/acme/shop. Version 1 of this repository's own policy; until now it was served the workspace's."

    # Its own comes first, with its source and its menu; the workspace's allow stays in
    # the list, struck, and says why.
    assert hd(hosts(view)) == "gitlab.example"
    assert text(view, "#rule-#{rule.id} .q-pr-src") == "This repository"
    assert text(view, "#rule-#{rule.id}") =~ "New in v1"
    assert has_element?(view, "#rule-#{rule.id}-menu button", "Change to allow")
    assert has_element?(view, "#rule-#{rule.id}-menu button", "Remove")
    refute has_element?(view, "#rule-#{rule.id}-menu button", "Edit paths")
    refute has_element?(view, "#policy-no-own")

    beaten = workspace_rule(scope, "gitlab.example")
    assert has_element?(view, "#rule-#{beaten.id}.q-pr-off")

    assert text(view, "#rule-#{beaten.id}") =~
             "Not in force: this repository's own rule decides it"

    assert text(view, "#policy-rules-view-all") == "All 5"

    # The Filter menu's Source: its own, or the workspace's.
    assert text(view, "#policy-rules-filter-source-0") == "This repository 1 rule"
    assert text(view, "#policy-rules-filter-source-1") == "#{scope.workspace.name} 4 rules"
    view |> element("#policy-rules-filter-source-0") |> render_click()
    assert_patch(view, path <> "?q=source%3Arepo")
    assert hosts(view) == ["gitlab.example"]
    assert has_element?(view, "#policy-rules-token-source", "repo")

    view |> element("#policy-rules-filter-source-1") |> render_click()
    assert_patch(view, path <> "?q=source%3A#{scope.workspace.slug}")
    assert length(hosts(view)) == 4
    view |> element("#policy-rules-tokens-clear") |> render_click()

    view |> element("#rule-#{rule.id}-menu button", "Remove") |> render_click()
    refute own(scope, target, "gitlab.example")

    assert text(view, "#flash-info") =~
             "The workspace's rule for gitlab.example is restored for github.example/acme/shop."

    refute has_element?(view, "#rule-#{beaten.id}.q-pr-off")
    assert has_element?(view, "#policy-no-own")
  end

  test "an allow of its own overrides the workspace's deny", %{
    conn: conn,
    scope: scope,
    target: target,
    path: path
  } do
    view = open(conn, path)
    type(view, %{host: "telemetry.example", paths: ""})

    assert text(view, "#policy-composer-reads") =~
             "telemetry.example is denied for the workspace. This rule allows it for this repository; other repositories keep the deny."

    view |> form("#policy-composer") |> render_submit()

    rule = own(scope, target, "telemetry.example")
    assert rule.action == "allow"
    beaten = workspace_rule(scope, "telemetry.example")

    assert text(view, "#rule-#{beaten.id}") =~
             "Not in force: this repository's own rule decides it"

    assert has_element?(view, "#rule-#{rule.id}-menu button", "Edit paths")
    assert has_element?(view, "#rule-#{rule.id}-menu button", "Change to deny")
    assert has_element?(view, "#rule-#{rule.id}-menu button", "Remove")
    refute has_element?(view, "#rule-#{rule.id}-menu button", "Lock")

    view |> element("#rule-#{rule.id}-menu button", "Change to deny") |> render_click()
    assert own(scope, target, "telemetry.example").action == "deny"
    assert text(view, "#flash-info") =~ "telemetry.example is denied for github.example/acme/shop"
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

    assert has_element?(view, "#rule-#{held.id}.q-pr-off")
    assert text(view, "#rule-#{held.id} .q-pr-src") == "This repository"

    assert text(view, "#rule-#{held.id}") =~
             "Not in force: #{scope.workspace.name}'s locked *.paste.example holds"

    # Its menu holds only Remove: there is nothing to change while the lock holds.
    refute has_element?(view, "#rule-#{held.id}-menu button", "Change to deny")
    refute has_element?(view, "#rule-#{held.id}-menu button", "Edit paths")
    assert text(view, "#rule-#{workspace_rule(scope, "*.paste.example").id}-lock") == "Locked"

    view |> element("#rule-#{held.id}-menu button", "Remove") |> render_click()
    refute own(scope, target, "*.paste.example")
    assert text(view, "#flash-info") =~ "The rule *.paste.example is removed."
  end

  test "the composer adds for the target, and a locked workspace rule refuses it",
       %{conn: conn, scope: scope, target: target, path: path} do
    view = compose(open(conn, path))
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
    view = compose(open(conn, path))

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
    view = compose(open(log_in_user(build_conn(), member), path))

    view
    |> form("#policy-composer", rule: %{host: "bin.paste.example", paths: ""})
    |> render_change()

    assert text(view, "#policy-composer-reads") =~ "Only an owner can change or unlock it."
  end

  describe "the target's mode" do
    test "follows the workspace until an owner says otherwise, and says where it comes from",
         %{conn: conn, scope: scope, path: path} do
      view = open(conn, path)

      assert has_element?(view, "#policy-target-mode-follow[aria-checked=true]")

      assert text(view, "#policy-target-mode-effect") ==
               "It follows #{scope.workspace.name}, which observes. What no rule names is let through and recorded; a deny rule holds, and so do #{scope.workspace.name}'s locked rules."

      assert text(view, "#policy-target-mode-follow") == "Follow #{scope.workspace.name}"
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

      # In place under the switch, not a dialog; Cancel gives the focus back to the radio
      # of the mode as it is.
      assert has_element?(view, "#policy-target-mode + section#target-mode-enforce")
      refute has_element?(view, "dialog#target-mode-enforce")
      assert has_element?(view, "#policy-page section#policy-keys[hidden]")
      view |> element("#target-mode-enforce-cancel") |> render_click()
      refute has_element?(view, "#target-mode-enforce")
      assert_push_event(view, "policy:focus", %{id: "policy-target-mode-follow"})
      view |> element("#policy-target-mode-enforce") |> render_click()

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
               "Its own, set by #{ApiaryWeb.People.short(scope.user.email)} today; #{scope.workspace.name} observes. A connection no rule allows is denied."
    end

    test "to observe names the locked denies that still hold, and the card keeps saying so",
         %{conn: conn, scope: scope, target: target, path: path} do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, path)

      assert text(view, "#policy-target-mode-effect") =~
               "which enforces. A connection no rule allows is denied."

      view |> element("#policy-target-mode-observe") |> render_click()

      assert text(view, "#target-mode-observe") =~
               "only what a deny rule names is denied in this repository's runs"

      assert text(view, "#target-mode-observe") =~
               "A deny holds in either mode: *.paste.example stays denied in this repository"

      view |> element("#target-mode-confirm", "Observe this repository") |> render_click()
      assert Policy.get_mode(scope, target).own == "observe"

      assert text(view, "#policy-target-mode-effect") =~
               "Its own, set by #{ApiaryWeb.People.short(scope.user.email)} today; #{scope.workspace.name} enforces. What no rule names is let through and recorded; a deny rule holds, and so do #{scope.workspace.name}'s locked rules."

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
      assert text(view, "#policy-target-mode-owners") == "Only an owner or an admin sets a mode."

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

  test "history, versions and export are the target's own",
       %{conn: conn, scope: scope, target: target, path: path} do
    # Paths in force, so the export has a policy file to download.
    {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/acme/*"]})
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
    assert has_element?(view, "h2", "Version 1")
    assert has_element?(view, "#policy-tabs a[href='#{path}']", "Effective policy")

    # The export is a page of the tab, under the target's own title: an h2, the way back
    # to the target's policy and the version, and Done to the version.
    view = open(conn, path <> "/versions/1/export")
    assert text(view, "#export-lead") =~ "github.example/acme/shop"
    assert has_element?(view, "#export-download[download='acme-shop-policy.yaml']")
    assert has_element?(view, "h2#policy-export-h", "Export for a node without a server")
    refute has_element?(view, "dialog#policy-export")
    assert has_element?(view, "#export-crumbs a[href='#{path}']", "Policy")
    assert has_element?(view, "#export-crumbs a[href='#{path}/versions/1']", "Version 1")
    assert has_element?(view, "#export-done[href='#{path}/versions/1']", "Done")
    refute has_element?(view, "#policy-tabs")

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
