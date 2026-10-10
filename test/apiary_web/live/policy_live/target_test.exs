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

  # The card says when the target's mode was set as the reader's day: today, yesterday or
  # a date. The change's time is the database's, taken when the test's transaction began,
  # and the page reads its day from the clock, so a test that ran across midnight UTC read
  # "yesterday". A test that asserts "today" gives its reader a zone whose clock reads
  # between 12:00 and 13:00 now, so the change and the read lie in one of the reader's
  # days, whatever the hour in UTC.
  defp reader_at_noon(user) do
    hours = 12 - DateTime.utc_now().hour
    # The Etc zones count the other way: Etc/GMT-12 is twelve hours ahead of UTC.
    zone = if hours > 0, do: "Etc/GMT-#{hours}", else: "Etc/GMT+#{-hours}"
    {:ok, _} = Apiary.Accounts.update_user_preferences(user, %{time_zone: zone})
    :ok
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  # An element's text as it is read: unlike text/2, its tags add no space.
  defp read_name(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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

  # A name as it reads: its parts joined, as `<.target_name>` writes them.
  defp name(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, "")
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

  # The mode's choices: Change mode opens them, where they are shut; a pick only selects.
  defp pick_mode(view, setting) do
    if has_element?(view, "#policy-mode-change") do
      view |> element("#policy-mode-change") |> render_click()
    end

    view |> form("#policy-mode-form", %{"mode" => setting}) |> render_change()
    view
  end

  defp set_mode(view), do: view |> form("#policy-mode-form") |> render_submit()

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

    # Where another system has the same path, the system is in the address too: the
    # target's own, where its tab now is, and the narrowed list's.
    started_run(scope, shop("gitlab.com"))
    view = open(conn, workspace_path(scope, "/targets/github.example/acme/shop/-/policy"))

    assert has_element?(
             view,
             "#policy-hosts-network[href='#{workspace_path(scope, "/network?system=github.example&target=acme%2Fshop")}']"
           )
  end

  test "a target no other system has is named by its path alone, in its title and its words",
       %{conn: conn, scope: scope, path: path} do
    view = open(conn, path)

    assert page_title(view) =~ "Policy · acme/shop"
    refute page_title(view) =~ "github.example"
    assert name(view, "#target-header h1") == "acme/shop"
    crumb = "#breadcrumb a[href='#{workspace_path(scope, "/targets/acme/shop")}']"
    assert name(view, crumb) == "acme/shop"

    assert has_element?(
             view,
             "#policy-rules[aria-label='Network access rules in force for acme/shop']"
           )
  end

  test "a target whose path another system has: named with its system, every link at its address",
       %{conn: conn, scope: scope, target: target} do
    started_run(scope, shop("gitlab.com"))
    {:ok, _} = Policy.deny(scope, target, %{host: "gitlab.example"})
    rule = own(scope, target, "gitlab.example")
    base = workspace_path(scope, "/targets/github.example/acme/shop/-/policy")

    view = open(conn, base)
    assert page_title(view) =~ "Policy · github.example/acme/shop"
    assert name(view, "#target-header h1") == "github.example/acme/shop"

    crumb = "#breadcrumb a[href='#{workspace_path(scope, "/targets/github.example/acme/shop")}']"
    assert name(view, crumb) == "github.example/acme/shop"

    assert has_element?(
             view,
             "#policy-rules[aria-label='Network access rules in force for github.example/acme/shop']"
           )

    assert has_element?(view, "#policy-tabs a[href='#{base}']", "Effective policy")
    assert has_element?(view, "#policy-tabs a[href='#{base}/history']", "History")
    assert has_element?(view, "#policy-tabs a[href='#{base}/document']", "Document")
    assert has_element?(view, "#policy-version-pill a[href='#{base}/history']")
    assert has_element?(view, "#policy-export-button[href='#{base}/versions/1/export']")

    # A toast names it with its system.
    view |> element("#rule-#{rule.id}-menu button", "Change to allow") |> render_click()

    assert text(view, "#flash-info") =~
             "gitlab.example is allowed for github.example/acme/shop."

    # Its views open at its address, never on the page that lists the systems.
    view |> element("#policy-tabs a", "History") |> render_click()
    assert_patch(view, base <> "/history")
    assert page_title(view) =~ "History · github.example/acme/shop · Policy"

    view |> element("#policy-tabs a", "Document") |> render_click()
    assert_patch(view, base <> "/document")
    assert has_element?(view, "h2#policy-version-h", "Version 2")
    assert page_title(view) =~ "Version 2 · github.example/acme/shop · Policy"
    assert has_element?(view, "#version-doc .q-docwell-bar #version-copy[aria-label=Copy]")
    refute has_element?(view, "#version-export")
    refute has_element?(view, "#policy-export-button")

    # A version and its export continue the breadcrumb as on the workspace's Policy.
    page = workspace_path(scope, "/targets/github.example/acme/shop")
    repositories = {"Repositories", workspace_path(scope, "/targets")}

    view = open(conn, base <> "/versions/2")

    assert crumbs(view) == [
             repositories,
             {"github.example/acme/shop", page},
             {"Version 2", nil}
           ]

    assert has_element?(view, "#version-export[href='#{base}/versions/2/export']")
    view |> element("#version-export") |> render_click()
    assert_patch(view, base <> "/versions/2/export")

    assert crumbs(view) == [
             repositories,
             {"github.example/acme/shop", page},
             {"Version 2", base <> "/versions/2"},
             {"Export", nil}
           ]

    # The top bar's breadcrumb is the one way back: the page draws no trail of its own.
    refute has_element?(view, "#export-crumbs")
    refute has_element?(view, "#policy-export nav")

    assert text(view, "#export-lead") =~ "The effective policy of github.example/acme/shop as of"
    assert has_element?(view, "#export-done[href='#{base}/document']")
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

    # The target's page holds the tab, beside Overview: its runs and its network access
    # are the workspace's lists, narrowed to it, not tabs of its page.
    assert has_element?(view, "#target-tabs-policy[aria-current=page]")
    assert has_element?(view, "#target-tabs-overview")
    refute has_element?(view, "#target-tabs-runs")
    refute has_element?(view, "#target-tabs-network")
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
             "gitlab.example is denied for acme/shop. Version 1 of this repository's own policy; until now it was served the workspace's."

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
             "The workspace's rule for gitlab.example is restored for acme/shop."

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
    assert text(view, "#flash-info") =~ "telemetry.example is denied for acme/shop."
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
         %{conn: conn, scope: scope, target: target, path: path} do
      view = open(conn, path)

      assert text(view, "#policy-mode-value") == "Observe"
      assert read_name(view, "#policy-mode-h") == "Mode: Observe"
      assert text(view, "#policy-mode-source") == "Follows #{scope.workspace.name}"
      assert has_element?(view, "#policy-mode-source .hero-link-micro")
      assert has_element?(view, "#policy-mode .q-modecard-tile .hero-eye")

      assert text(view, "#policy-mode-effect") ==
               "It follows #{scope.workspace.name}, which observes. What no rule names is let through and recorded; a deny rule holds, and so do #{scope.workspace.name}'s locked rules."

      # The card is above the views, on each of them, and not on a version or its export.
      for rest <- ["", "/history", "/document"] do
        view = open(conn, path <> rest)
        html = render(view)
        {card, _} = :binary.match(html, ~s(id="policy-mode"))
        {views, _} = :binary.match(html, ~s(id="policy-tabs"))
        assert card < views
      end

      {:ok, _} = Policy.allow(scope, target, %{host: "a.example"})

      for rest <- ["/versions/1", "/versions/1/export"] do
        refute has_element?(open(conn, path <> rest), "#policy-mode")
      end

      view = open(conn, path)
      view |> element("#policy-mode-change") |> render_click()
      assert_push_event(view, "policy:focus", %{id: "policy-mode-opt-follow"})
      assert text(view, "#policy-mode-legend") == "Choose the mode for acme/shop"

      assert text(view, "#policy-mode-opt-follow-h") ==
               "Follow #{scope.workspace.name} Current"

      assert has_element?(view, "#policy-mode-opt-follow-h .hero-link")
      refute has_element?(view, "#policy-mode .hero-arrow-uturn-left")

      assert text(view, "#policy-mode-opt-follow-p") ==
               "#{scope.workspace.name}'s mode, now observe. It changes when #{scope.workspace.name}'s does."

      assert text(view, "#policy-mode-now") == "Follow #{scope.workspace.name} is the mode now."
    end

    test "to enforce asks with this target's own list, and Allow here adds a target rule",
         %{conn: conn, scope: scope, target: target, path: path} do
      reader_at_noon(scope.user)

      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "bin.paste.example", "decision" => "allowed", "rule" => ""}
        ]
      )

      view = open(conn, path)
      pick_mode(view, "enforce")

      assert Policy.get_mode(scope, target).own == nil
      assert text(view, "#policy-mode-q") == "Enforce acme/shop?"

      # In the card, under the options, not a dialog; what it does is read with it and with
      # its button.
      assert has_element?(view, "#policy-mode #policy-mode-form #policy-mode-q")
      refute has_element?(view, "#policy-page dialog")
      assert has_element?(view, "[role=group][aria-describedby=policy-mode-q-effect]")
      assert has_element?(view, "#policy-mode-set[aria-describedby=policy-mode-q-effect]")

      assert text(view, "#policy-mode-q-effect") =~
               "a connection no rule allows is denied in this repository's runs"

      assert has_element?(view, "#policy-page section#policy-keys[hidden]")
      view |> element("#policy-mode-cancel") |> render_click()
      refute has_element?(view, "#policy-mode-form")
      assert_push_event(view, "policy:focus", %{id: "policy-mode-change"})
      pick_mode(view, "enforce")

      assert text(view, "#policy-mode-q-effect") =~
               "The mode becomes this repository's own: it stays enforce"

      assert text(view, "#mode-would") =~ "Let through in this repository's runs"
      # A host the locked deny covers is denied in either mode already: enforcing this
      # target would not start denying it, so it is not in the list.
      refute text(view, "#mode-would") =~ "bin.paste.example"
      assert text(view, "#mode-would") =~ "1 destination"

      view |> element("#mode-would button", "Allow here: files.cdn.example") |> render_click()
      assert own(scope, target, "files.cdn.example")
      # None left open: the focus goes to the button that saves the pick.
      assert_push_event(view, "policy:focus", %{id: "policy-mode-set"})
      assert has_element?(view, "input#policy-mode-opt-enforce[checked]")

      assert has_element?(view, "#policy-mode-set.btn-primary", "Enforce this repository")
      set_mode(view)

      assert %{mode: "enforce", own: "enforce", workspace: "observe"} =
               Policy.get_mode(scope, target)

      refute has_element?(view, "#policy-mode-form")
      assert text(view, "#policy-mode-value") == "Enforce"
      assert text(view, "#policy-mode-source") == "Its own"
      assert has_element?(view, "#policy-mode .q-modecard-tile .hero-shield-exclamation")
      assert_push_event(view, "policy:focus", %{id: "policy-mode-change"})
      assert text(view, "#flash-info") =~ "acme/shop enforces on its own. Version"
      assert text(view, "#policy-announce") =~ "This repository's mode is enforce."
      refute text(view, "#flash-info") =~ "github.example"

      assert text(view, "#policy-mode-effect") =~
               "Its own, set by #{ApiaryWeb.People.short(scope.user.email)} today; #{scope.workspace.name} observes. A connection no rule allows is denied."
    end

    test "the Document view is the document in force under the card, and follows the mode in place",
         %{conn: conn, scope: scope, target: target, path: path} do
      # Served the workspace's: its version in force, the workspace's mode.
      view = open(conn, path <> "/document")
      html = render(view)
      {card, _} = :binary.match(html, ~s(id="policy-mode"))
      {views, _} = :binary.match(html, ~s(id="policy-tabs"))
      {version, _} = :binary.match(html, ~s(id="policy-version-h"))
      assert card < views and views < version
      assert has_element?(view, "h2#policy-version-h", "Version 4")
      assert text(view, "#version-strip") =~ "Mode observe"

      # Enforce, its own: its first version of its own, in place, with its mode.
      pick_mode(view, "enforce")
      set_mode(view)

      assert has_element?(view, "#policy-mode")
      assert text(view, "#policy-mode-value") == "Enforce"
      assert has_element?(view, "#policy-tabs a[href='#{path}/document'][aria-current=page]")
      assert has_element?(view, "h2#policy-version-h", "Version 1")
      assert text(view, "#version-strip") =~ "Mode enforce"
      assert has_element?(view, "#ver-1[href='#{path}/document'][aria-current=page]")
      assert has_element?(view, "#version-doc .q-docwell-bar #version-copy[aria-label=Copy]")
      refute has_element?(view, "#version-export")
      refute has_element?(view, "#policy-export-button")
      assert page_title(view) =~ "Version 1 · acme/shop · Policy"

      # A rule of its own, from elsewhere: the next version, in place.
      {:ok, _} = Policy.allow(scope, target, %{host: "a.example"})
      _ = render(view)
      assert has_element?(view, "h2#policy-version-h", "Version 2")
      assert text(view, "#version-strip") =~ "Mode enforce"
      assert has_element?(view, "#ver-2[href='#{path}/document'][aria-current=page]")
      assert has_element?(view, "#ver-1[href='#{path}/versions/1']")
      refute has_element?(view, "#ver-1[aria-current]")

      # A version opened from the history states its own mode: no card, an older one or
      # the one in force.

      for rest <- ["/versions/1", "/versions/2", "/versions/2/export"] do
        refute has_element?(open(conn, path <> rest), "#policy-mode"), rest
      end
    end

    test "to observe names the locked denies that still hold, and the card keeps saying so",
         %{conn: conn, scope: scope, target: target, path: path} do
      reader_at_noon(scope.user)
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, path)

      assert text(view, "#policy-mode-effect") =~
               "which enforces. A connection no rule allows is denied."

      pick_mode(view, "observe")
      assert text(view, "#policy-mode-q") == "Observe acme/shop?"

      assert text(view, "#policy-mode-q-effect") =~
               "only what a deny rule names is denied in this repository's runs"

      assert text(view, "#policy-mode-form") =~
               "A deny holds in either mode: *.paste.example stays denied in this repository"

      # Observe can be undone as easily: its button is the primary one, never red.
      assert has_element?(view, "#policy-mode-set.btn-primary", "Observe this repository")
      refute has_element?(view, "#policy-mode .btn-error")
      set_mode(view)
      assert Policy.get_mode(scope, target).own == "observe"

      assert text(view, "#policy-mode-effect") =~
               "Its own, set by #{ApiaryWeb.People.short(scope.user.email)} today; #{scope.workspace.name} enforces. What no rule names is let through and recorded; a deny rule holds, and so do #{scope.workspace.name}'s locked rules."

      pick_mode(view, "follow")
      assert text(view, "#policy-mode-q") == "Let acme/shop follow #{scope.workspace.name}?"

      assert text(view, "#policy-mode-q-effect") =~
               "The mode follows the workspace's default from now on"

      assert has_element?(view, "#policy-mode-set", "Follow #{scope.workspace.name}")
      set_mode(view)
      assert Policy.get_mode(scope, target).own == nil

      assert text(view, "#flash-info") =~ "acme/shop follows the workspace: enforce."
      refute text(view, "#flash-info") =~ "github.example"
    end

    test "each Allow here names its destination, and the focus goes on to the next one open",
         %{conn: conn, scope: scope, path: path} do
      started_run(scope, shop(),
        egress: [
          %{"host" => "files.cdn.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "mirror.example", "decision" => "allowed", "rule" => ""},
          %{"host" => "mirror.example", "decision" => "allowed", "rule" => ""}
        ]
      )

      view = open(conn, path)
      pick_mode(view, "enforce")

      allow = fn host ->
        "would-#{ApiaryWeb.PolicyLive.Common.would_key(%{host: host, path: nil})}-allow"
      end

      # Each reads "Allow here"; its name goes on with the destination.
      for host <- ~w(mirror.example files.cdn.example) do
        assert read_name(view, "button##{allow.(host)}") == "Allow here: #{host}"
        assert text(view, "button##{allow.(host)} .sr-only") == ": #{host}"
      end

      view |> element("##{allow.("mirror.example")}") |> render_click()
      next = allow.("files.cdn.example")
      assert_push_event(view, "policy:focus", %{id: ^next})

      view |> element("##{next}") |> render_click()
      assert_push_event(view, "policy:focus", %{id: "policy-mode-set"})
    end

    # Until 2026-10-07 a setting that changed nothing today saved on its click; every
    # change now asks, and says that nothing changes today.
    test "a setting that changes nothing today asks too, and says so",
         %{conn: conn, scope: scope, target: target, path: path} do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, path)

      pick_mode(view, "enforce")
      refute has_element?(view, "#flash-info")
      assert Policy.get_mode(scope, target).own == nil
      assert text(view, "#policy-mode-q") == "Enforce acme/shop?"

      assert text(view, "#policy-mode-q-effect") ==
               "Nothing changes today: #{scope.workspace.name} enforces too. From now on acme/shop stays on enforce whatever #{scope.workspace.name}'s mode becomes."

      refute has_element?(view, "#mode-would")

      set_mode(view)
      assert Policy.get_mode(scope, target).own == "enforce"

      assert text(view, "#flash-info") =~
               "acme/shop enforces on its own. Nothing changes today: the workspace's default is enforce too."

      refute text(view, "#flash-info") =~ "github.example"

      # And back: following the workspace changes nothing today either, and asks.
      pick_mode(view, "follow")

      assert text(view, "#policy-mode-q-effect") ==
               "Nothing changes today: #{scope.workspace.name} enforces too. The mode follows the workspace's default from now on, and changes when it does."

      assert Policy.get_mode(scope, target).own == "enforce"
    end

    test "on a workspace nobody has changed, a mode of its own is its first change, and says so",
         %{conn: _conn} do
      other = scope_fixture()
      started_run(other, shop())
      [%{target: target}] = Policy.list_targets(other)
      refute Policy.managed?(other)

      view =
        open(
          log_in_user(build_conn(), other.user),
          target_path(other, target.system, target.path, ["policy"])
        )

      # It follows the workspace, which observes: picking observe changes the mode of
      # none of its runs, but it starts serving every machine of the workspace a policy.
      pick_mode(view, "observe")
      effect = text(view, "#policy-mode-q-effect")
      refute effect =~ "Nothing changes today"
      assert effect =~ "only what a deny rule names is denied in this repository's runs"

      assert effect =~
               "This is the workspace's first change: it renders version 1, and from then on each machine applies it, narrowed by its own."

      refute effect =~ "other repositories do not change"

      pick_mode(view, "enforce")
      effect = text(view, "#policy-mode-q-effect")
      assert effect =~ "This is the workspace's first change"
      refute effect =~ "Other repositories do not change."
      refute Policy.managed?(other)
    end

    test "picks never save, and only the last pick's question shows; Cancel keeps the mode",
         %{conn: conn, scope: scope, target: target, path: path} do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      view = open(conn, path)

      pick_mode(view, "observe")
      assert text(view, "#policy-mode-q") == "Observe acme/shop?"
      assert has_element?(view, "#policy-mode-set", "Observe this repository")

      pick_mode(view, "enforce")
      assert text(view, "#policy-mode-q") == "Enforce acme/shop?"
      assert has_element?(view, "#policy-mode-set", "Enforce this repository")
      refute render(view) =~ "Observe acme/shop?"

      pick_mode(view, "follow")
      assert has_element?(view, "input#policy-mode-opt-follow[checked]")
      refute has_element?(view, "input#policy-mode-opt-enforce[checked]")
      refute has_element?(view, "#policy-mode-q")
      assert text(view, "#policy-mode-now") == "Follow #{scope.workspace.name} is the mode now."

      assert %{own: nil, mode: "enforce"} = Policy.get_mode(scope, target)
      assert text(view, "#policy-mode-value") == "Enforce"
      refute has_element?(view, "#flash-info")

      view |> element("#policy-mode-cancel") |> render_click()
      refute has_element?(view, "#policy-mode-form")
      assert_push_event(view, "policy:focus", %{id: "policy-mode-change"})
      assert %{own: nil, mode: "enforce"} = Policy.get_mode(scope, target)
      assert text(view, "#policy-mode-source") == "Follows #{scope.workspace.name}"
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

      assert text(view, "#policy-mode-value") == "Observe"
      refute has_element?(view, "#policy-mode-change")
      refute has_element?(view, "#policy-mode [aria-disabled]")
      assert text(view, "#policy-mode-owners") == "Only an owner or an admin sets a mode."

      render_hook(view, "mode_open", %{})
      refute has_element?(view, "#policy-mode-form")
      assert text(view, "#policy-write-error") == "Only an owner or an admin sets a mode."
      render_hook(view, "mode_pick", %{"mode" => "enforce"})
      render_hook(view, "mode_set", %{"mode" => "enforce"})
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

    view = open(conn, path <> "/document")
    assert has_element?(view, "#policy-tabs a[href='#{path}/document'][aria-current=page]")
    assert has_element?(view, "h2#policy-version-h", "Version 1")
    assert has_element?(view, "#ver-1[href='#{path}/document'][aria-current=page]")

    view = open(conn, path <> "/versions/1")
    assert has_element?(view, "#ver-1[href='#{path}/document'][aria-current=true]")
    assert has_element?(view, "h2", "Version 1")
    assert has_element?(view, "#policy-tabs a[href='#{path}']", "Effective policy")

    # The export is a page of the tab, under the target's own title: an h2 and Done to the
    # Document view. The way back is the top bar's breadcrumb, never a trail of the page's own.
    view = open(conn, path <> "/versions/1/export")
    # The page names the target as it is addressed; the file's head names it in full.
    assert text(view, "#export-lead") =~ "The effective policy of acme/shop as of version 1"

    assert text(view, "#export-policy-text") =~
             "Qory policy of github.example/acme/shop, version 1"

    assert has_element?(view, "#export-download[download='acme-shop-policy.yaml']")
    assert has_element?(view, "h2#policy-export-h", "Export for a node without a server")
    refute has_element?(view, "dialog#policy-export")
    refute has_element?(view, "#export-crumbs")
    assert Enum.take(crumbs(view), -2) == [{"Version 1", path <> "/versions/1"}, {"Export", nil}]
    assert has_element?(view, "#export-done[href='#{path}/document']", "Done")
    refute has_element?(view, "#policy-tabs")

    # Done and Export are patches: the heading of what is shown takes the focus.
    view |> element("#export-done") |> render_click()
    assert_patch(view, path <> "/document")
    assert has_element?(view, "#policy-mode")
    assert has_element?(view, "h2#policy-version-h[tabindex='-1']", "Version 1")
    assert_push_event(view, "policy:focus", %{id: "policy-version-h"})

    # The Document view has Copy and Download in the document's bar, and no Export;
    # Download saves the target's own version as served.
    refute has_element?(view, "#version-export")
    refute has_element?(view, "#policy-export-button")
    bar = "#version-doc .q-docwell-bar"
    assert has_element?(view, "#{bar} #version-copy[aria-label=Copy]")

    assert has_element?(
             view,
             "#{bar} a#version-download[aria-label=Download][download='run-configuration.json']"
           )

    {:ok, own} = Policy.get_configuration(scope, target, 1)
    assert downloaded(view) == own.document

    # The version's own page keeps its Export.
    view = open(conn, path <> "/versions/1")
    view |> element("#version-export") |> render_click()
    assert_patch(view, path <> "/versions/1/export")
    assert has_element?(view, "h2#policy-export-h[tabindex='-1']")
    assert_push_event(view, "policy:focus", %{id: "policy-export-h"})

    # The workspace's change is not this target's.
    [workspace_change | _] = Policy.list_changes(scope, nil, 1).items
    view = open(conn, path <> "/history?change=#{workspace_change.id}")
    refute has_element?(view, ".q-chg[open]")

    view = open(conn, path <> "/versions/9")
    assert has_element?(view, "h2", "There is no version 9")
  end

  test "a target served the baseline has no versions of its own: Document is the workspace's",
       %{conn: conn, path: path, scope: scope} do
    # The workspace's version in force, in place under the target's card, its links the
    # workspace's.
    view = open(conn, path <> "/document")
    assert has_element?(view, "#policy-mode")
    assert text(view, "#policy-mode-source") == "Follows #{scope.workspace.name}"
    assert has_element?(view, "#policy-tabs a[href='#{path}/document'][aria-current=page]")
    assert has_element?(view, "h2#policy-version-h", "Version 4")
    assert has_element?(view, "#ver-4[href='#{path}/document'][aria-current=page]")
    assert has_element?(view, "#ver-3[href='#{workspace_path(scope, "/policy/versions/3")}']")

    # The workspace's version, Copy in its bar; the tab no Export.
    assert has_element?(view, "#version-doc .q-docwell-bar #version-copy[aria-label=Copy]")
    refute has_element?(view, "#version-export")
    refute has_element?(view, "#policy-export-button")

    view |> element("#version-view button", "As served") |> render_click()
    assert_patch(view, path <> "/document?view=served")

    view = open(conn, path <> "/versions/1")
    assert text(view, "#policy-page") =~ "This repository has no versions of its own"
  end

  test "a target served the baseline downloads the workspace's version in force, as served",
       %{conn: conn, path: path, scope: scope} do
    # Hosts alone, then a rule with paths: the document shown, each time.
    view = open(conn, path <> "/document")
    {:ok, workspace} = Policy.get_configuration(scope, nil, 4)

    assert has_element?(
             view,
             "#version-doc .q-docwell-bar a#version-download[download='run-configuration.json']"
           )

    assert downloaded(view) == workspace.document

    {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/acme/*"]})
    _ = render(view)
    assert has_element?(view, "h2#policy-version-h", "Version 5")
    {:ok, workspace} = Policy.get_configuration(scope, nil, 5)
    assert downloaded(view) == workspace.document
    assert downloaded(view) =~ "/acme/*"
  end

  # What the Document view's Download saves: the bytes its data URI carries.
  defp downloaded(view) do
    "data:application/json;base64," <> data = attribute(view, "#version-download", "href")
    Base.decode64!(data)
  end

  defp attribute(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> hd()
  end
end
