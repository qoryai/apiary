defmodule ApiaryWeb.ConnectionLive.RulesTest do
  @moduledoc """
  Allow and Deny from a row of the workspace's Network access page, and a row's rule option
  (`ApiaryWeb.ConnectionLive.Rules`).
  """
  use ApiaryWeb.ConnCase, async: true

  # Every test here is a rule, a version or a policy on the run's pages: `security`.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import ApiaryWeb.TargetComponents, only: [target_path: 4]
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias ApiaryWeb.ConnectionLive.Rules
  alias ApiaryWeb.RunComponents

  setup :register_and_log_in_user

  @denied %{
    "host" => "files.cdn.example",
    "decision" => "denied",
    "rule" => "",
    "outcome" => "refused"
  }
  @registry %{"host" => "registry.example", "rule" => "registry.example"}
  @wall %{
    "host" => "169.254.169.254",
    "port" => 80,
    "decision" => "denied",
    "rule" => "wall:own-address",
    "outcome" => "refused"
  }

  defp open(conn, scope, rest \\ "/network") do
    {:ok, view, _html} = live(conn, workspace_path(scope, rest))
    render_async(view, 2_000)
    view
  end

  defp dst(host, port \\ 443, path \\ ""),
    do: RunComponents.destination_id(%{host: host, port: port, path: path})

  defp values(host, port \\ 443, path \\ ""),
    do: %{"host" => host, "port" => Integer.to_string(port), "path" => path}

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
      |> Registry.lookup(Policy.topic(scope.workspace.id))
      |> Enum.count(fn {pid, _} -> pid == view.pid end)

    assert subscriptions == 1
    send(view.pid, :policy_flush)
  end

  defp target(scope, system) do
    scope
    |> Policy.list_targets()
    |> Enum.find_value(&(&1.target.system == system && &1.target))
  end

  setup %{scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})
    started_run(scope, shop(), egress: [@registry, @denied, @wall])
    started_run(scope, shop("gitlab.example"), egress: [@denied])
    :ok
  end

  describe "a target's version and rule, named and addressed" do
    test "its system only where its path is shared; a caller that does not say names it in full",
         %{scope: scope} do
      target = %{id: "t", system: "github.example", path: "acme/shop"}
      shared = MapSet.new(["acme/shop"])

      assert Rules.version_label("t", target, false) == "acme/shop"
      assert Rules.version_label("t", target, MapSet.new()) == "acme/shop"
      assert Rules.version_label("t", target, true) == "github.example/acme/shop"
      assert Rules.version_label("t", target, shared) == "github.example/acme/shop"
      assert Rules.version_label("t", target) == "github.example/acme/shop"
      assert Rules.version_label(nil, target, true) == "the workspace's policy"

      assert Rules.version_path(scope, target, 3) ==
               workspace_path(scope, "/targets/acme/shop/-/policy/versions/3")

      assert Rules.version_path(scope, target, 3, %{"compare" => 2}, shared) ==
               workspace_path(
                 scope,
                 "/targets/github.example/acme/shop/-/policy/versions/3?compare=2"
               )

      assert Rules.rule_path(scope, target, "x.example") ==
               workspace_path(scope, "/targets/acme/shop/-/policy?rule=x.example")

      assert Rules.rule_path(scope, target, "x.example", true) ==
               workspace_path(scope, "/targets/github.example/acme/shop/-/policy?rule=x.example")
    end
  end

  describe "the workspace's Network access page" do
    test "a row's acts are text and its menu; a locked rule says who locked it, the wall why",
         %{conn: conn, scope: scope} do
      {:ok, rule} = Policy.deny(scope, nil, %{host: "files.cdn.example"})
      {:ok, _} = Policy.lock(scope, rule)
      view = open(conn, scope)

      # A locked rule: a lock that opens the refusal; the menu says who locked it and when,
      # and leads to the rule.
      cdn = dst("files.cdn.example")
      assert has_element?(view, "button##{cdn}-act.q-act-lock")
      assert text(view, "##{cdn}-menu .q-mh-t") =~ "Locked by #{scope.user.email} on "

      assert has_element?(
               view,
               ~s(a##{cdn}-menu-rule[href="#{workspace_path(scope, "/policy?rule=files.cdn.example")}"])
             )

      # The wall: a lock, and the menu says why no rule changes it.
      wall = dst("169.254.169.254", 80)
      assert has_element?(view, "span##{wall}-act.q-act-lock")
      assert text(view, "##{wall}-menu .q-mh-t") == "No rule changes this"

      assert text(view, "##{wall}-menu .q-mh-s") ==
               "The wall refuses the machine's own address, in either mode."

      # A row a rule allows: Deny as text, and in the menu, where it opens the same
      # panel, under the row.
      registry = dst("registry.example")
      assert has_element?(view, "button##{registry}-act.q-act-t[data-action=deny]", "Deny")
      assert has_element?(view, "##{registry}-menu-deny", "Deny…")
      refute has_element?(view, "##{registry}-menu-allow")

      # The rule that decides it is a link to the rule, in the policy's Network access.
      assert has_element?(
               view,
               ~s(a##{registry}-menu-rule[href="#{workspace_path(scope, "/policy?rule=registry.example")}"]),
               "Show the rule"
             )

      # Nothing on a row says it opens a dialog: it expands the row.
      refute has_element?(view, "#destinations [aria-haspopup]:not(.q-rowmenu-btn)")

      assert has_element?(
               view,
               ~s(##{registry}-act[aria-expanded=false][aria-controls="#{registry}-panel"])
             )

      view |> element("##{registry}-menu-deny") |> render_click()

      # In place: a row of its own right under the row, in the table, not an overlay.
      assert has_element?(
               view,
               ~s(tr##{registry} + tr##{registry}-panel > td > #rule-panel[role=group][data-anchor="#{registry}-act"][data-kind=deny])
             )

      refute has_element?(view, "#rule-panel[popover], #rule-panel[role=dialog]")
      assert has_element?(view, ~s(##{registry}-act[aria-expanded=true]))
      assert text(view, "#rule-panel-title") == "Deny registry.example"

      # Escape cancels it, wherever the focus is.
      view |> element("#rule-panel") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#rule-panel")
      refute has_element?(view, "tr##{registry}-panel")
      assert has_element?(view, ~s(##{registry}-act[aria-expanded=false]))

      # The reason is one line, whole in its title; no bordered button on any row.
      assert has_element?(view, ~s(##{registry} .q-why-l[title="Rule registry.example"]))
      refute has_element?(view, "#destinations .q-rowbtn")

      # Only this host narrows the list to it; Copy the host copies it.
      assert has_element?(view, "##{registry}-menu-copy[data-copy='registry.example']")
      view |> element("##{registry}-menu-host") |> render_click()
      assert_patch(view, workspace_path(scope, "/network?host=registry.example"))
    end

    test "every row has its slot, and the scope of a rule is not guessed", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      cdn = dst("files.cdn.example")

      assert text(view, "button##{cdn}-act") == "Allow"
      assert text(view, "button##{dst("registry.example")}-act") == "Deny"
      assert text(view, "span##{dst("169.254.169.254", 80)}-act") == "No rule changes this"

      view |> element("##{cdn}-act") |> render_click()

      # two targets reached it: neither is chosen,
      # nor the workspace, and nothing can be sent
      refute has_element?(view, "#rule-panel input[name=for][checked]")
      assert has_element?(view, "#rule-panel-submit[disabled]")
      options = text(view, "#rule-panel-target")
      assert options =~ "github.example/acme/shop · 1 run"
      assert options =~ "gitlab.example/acme/shop · 1 run"

      assert text(view, "#rule-panel-next") ==
               "Takes effect in running sessions within a heartbeat, about 30 s."

      # "One repository" alone is not a scope yet
      view |> form("#rule-panel-form", %{"for" => "target"}) |> render_change()
      assert has_element?(view, "#rule-panel-submit[disabled]")
    end

    test "allowing for the workspace keeps the row as it was and adds the line after", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      cdn = dst("files.cdn.example")
      view |> element("##{cdn}-act") |> render_click()
      view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-panel-submit") == "Allow for the workspace"
      view |> form("#rule-panel-form") |> render_submit()

      assert Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))
      {:ok, configuration} = Policy.current_configuration(scope, nil)

      refute has_element?(view, "#rule-panel")
      assert has_element?(view, ~s(tr##{cdn}.q-denied[data-decision=denied]))
      line = text(view, "##{cdn}-after")
      assert line =~ "Rule added"

      assert line =~
               "Allowed for the workspace in v#{configuration.version} · of the workspace's policy by you"

      refute line =~ "run"

      assert has_element?(
               view,
               ~s(a##{cdn}-act[href="#{workspace_path(scope, "/policy?rule=files.cdn.example")}"])
             )
    end

    test "allowing for one target is that target's rule", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      gitlab = target(scope, "gitlab.example")
      view |> element("##{dst("files.cdn.example")}-act") |> render_click()

      view
      |> form("#rule-panel-form", %{"for" => "target", "target" => gitlab.id})
      |> render_change()

      assert text(view, "#rule-panel-submit") == "Allow for the repository"
      view |> form("#rule-panel-form") |> render_submit()

      assert [%{host: "files.cdn.example"}] = Policy.list_rules(scope, gitlab)
      assert Policy.list_rules(scope, target(scope, "github.example")) == []
      refute Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))
      assert render(view) =~ "files.cdn.example is allowed for gitlab.example/acme/shop."
    end

    test "a target no other system has is named by its path alone, in the panel and the toast",
         %{conn: conn, scope: scope} do
      docs = %{"host" => "docs.cdn.example", "decision" => "denied", "rule" => ""}

      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"},
        egress: [docs]
      )

      target = Enum.find(Policy.list_targets(scope), &(&1.target.path == "acme/docs")).target

      view = open(conn, scope)
      view |> element("##{dst("docs.cdn.example")}-act") |> render_click()
      assert text(view, "#rule-panel-target") =~ "acme/docs · 1 run"
      refute text(view, "#rule-panel-target") =~ "github.example"

      view
      |> form("#rule-panel-form", %{"for" => "target", "target" => target.id})
      |> render_change()

      view |> form("#rule-panel-form") |> render_submit()
      assert [%{host: "docs.cdn.example"}] = Policy.list_rules(scope, target)
      assert render(view) =~ "docs.cdn.example is allowed for acme/docs."
    end

    test "with repo set, that target is chosen, and its policy is a link away", %{
      conn: conn,
      scope: scope
    } do
      github = target(scope, "github.example")
      view = open(conn, scope, "/network?system=github.example&target=acme/shop")

      # The path is on two systems: its policy's address keeps the system.
      assert has_element?(
               view,
               ~s(#connections-target-policy[href="#{workspace_path(scope, "/targets/github.example/acme/shop/-/policy")}"]),
               "Its policy"
             )

      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      assert has_element?(view, ~s(#rule-panel input[name=for][value=target][checked]))

      assert has_element?(
               view,
               ~s(#rule-panel-target option[value="#{github.id}"][selected])
             )

      view |> form("#rule-panel-form") |> render_submit()

      assert [%{host: "files.cdn.example"}] = Policy.list_rules(scope, github)
      line = text(view, "##{dst("files.cdn.example")}-after")
      assert line =~ "Allowed for this repository in v1 · of github.example/acme/shop by you"

      # The rule and its version are at the target's own address, its system kept.
      policy = workspace_path(scope, "/targets/github.example/acme/shop/-/policy")

      assert has_element?(
               view,
               ~s(a##{dst("files.cdn.example")}-act[href="#{policy}?rule=files.cdn.example"])
             )

      assert has_element?(
               view,
               ~s(##{dst("files.cdn.example")}-after a[href="#{policy}/versions/1"])
             )
    end

    test "a row denied before and allowed since by a rule added lately keeps its line", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example"})

      # the later run's attempt is the destination's last
      started_run(scope, shop(),
        ago: 10,
        egress: [%{"host" => "files.cdn.example", "rule" => "files.cdn.example"}]
      )

      view = open(conn, scope)
      cdn = dst("files.cdn.example")

      assert has_element?(view, ~s(tr##{cdn}[data-decision=allowed]))

      assert text(view, "##{cdn}-after") =~
               "Allowed for the workspace in v2 · of the workspace's policy"

      assert text(view, "a##{cdn}-act") == "Rule"
    end

    test "a rule someone else adds reaches the rows over the policy's topic", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      cdn = dst("files.cdn.example")
      assert text(view, "##{cdn}-act") == "Allow"

      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example"})
      heard_policy_change(view, scope)

      assert text(view, "##{cdn}-act") == "Rule"
      assert text(view, "##{cdn}-after") =~ "Allowed for the workspace"
    end
  end

  describe "a target's own rule on the unfiltered page" do
    @extra %{"host" => "extra.example", "rule" => "extra.example"}

    test "Deny for the workspace warns that the target's rule still holds, and Deny stays reachable",
         %{conn: conn, scope: scope} do
      github = target(scope, "github.example")
      {:ok, _} = Policy.allow(scope, github, %{host: "extra.example"})
      started_run(scope, shop(), egress: [@extra])

      view = open(conn, scope)
      d = dst("extra.example")
      assert text(view, "##{d}-act") == "Deny"
      view |> element("##{d}-act") |> render_click()
      view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-panel") =~ "A repository's own allow rule still holds there."

      assert text(view, "#rule-panel-own-rule") ==
               "A repository's own rule for this host still decides there."

      view |> form("#rule-panel-form") |> render_submit()
      assert render(view) =~ "A repository&#39;s own rule for this host still decides there."

      # the baseline's deny is not the answer to this row: the target still allows it
      assert "extra.example" in Policy.effective(scope, github).allow
      refute has_element?(view, "##{d}-after")
      assert text(view, "button##{d}-act") == "Deny"

      # so the deny for that target can still be made from here
      view |> element("##{d}-act") |> render_click()

      view
      |> form("#rule-panel-form", %{"for" => "target", "target" => github.id})
      |> render_change()

      assert text(view, "#rule-panel") =~ "Replaces the repository's own rule for the host."
      view |> form("#rule-panel-form") |> render_submit()
      refute "extra.example" in Policy.effective(scope, github).allow
    end

    test "a baseline rule is not said to answer a row a target's own rule decides", %{
      conn: conn,
      scope: scope
    } do
      github = target(scope, "github.example")
      {:ok, _} = Policy.deny(scope, nil, %{host: "extra.example"})
      {:ok, _} = Policy.allow(scope, github, %{host: "extra.example"})
      # and the other way round: the workspace allows, the target denies
      {:ok, _} = Policy.allow(scope, nil, %{host: "files.cdn.example"})
      {:ok, _} = Policy.deny(scope, github, %{host: "files.cdn.example"})
      started_run(scope, shop(), egress: [@extra])

      view = open(conn, scope)
      refute has_element?(view, "##{dst("extra.example")}-after")
      assert text(view, "button##{dst("extra.example")}-act") == "Deny"
      refute has_element?(view, "##{dst("files.cdn.example")}-after")
      assert text(view, "button##{dst("files.cdn.example")}-act") == "Allow"

      # with repo set the rows are weighed against that target's policy, and it answers
      view = open(conn, scope, "/network?system=github.example&target=acme/shop")
      assert text(view, "##{dst("files.cdn.example")}-act") == "Allow"
      refute has_element?(view, "##{dst("files.cdn.example")}-after")
    end

    test "what the rule will be is said for the target chosen, and the toast says what was made",
         %{conn: conn, scope: scope} do
      github = target(scope, "github.example")
      {:ok, _} = Policy.allow(scope, github, %{host: "api.pathed.example", paths: ["/ok/*"]})

      started_run(scope, shop(),
        egress: [
          %{
            "host" => "api.pathed.example",
            "path" => "/v2/x",
            "request_method" => "GET",
            "decision" => "denied",
            "rule" => "api.pathed.example",
            "outcome" => "refused"
          }
        ]
      )

      view = open(conn, scope)
      d = dst("api.pathed.example", 443, "/v2/x")
      view |> element("##{d}-act") |> render_click()

      # nothing chosen: nothing is promised
      assert text(view, "#rule-panel-title") == "Allow api.pathed.example"
      refute has_element?(view, "#rule-panel-what-set")

      view
      |> form("#rule-panel-form", %{"for" => "target", "target" => github.id})
      |> render_change()

      assert text(view, "#rule-panel-title") == "Allow on api.pathed.example"
      assert text(view, "#rule-panel-what") =~ "This path /v2/x is added"

      view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-panel-title") == "Allow api.pathed.example"

      view |> form("#rule-panel-form", %{"for" => "target"}) |> render_change()
      view |> form("#rule-panel-form") |> render_submit()

      assert [%{paths: ["/ok/*", "/v2/x"]}] = Policy.list_rules(scope, github)

      assert render(view) =~
               "/v2/x on api.pathed.example is allowed for github.example/acme/shop."
    end

    test "a stale panel is not sent", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()

      {:ok, rule} = Policy.deny(scope, nil, %{host: "files.cdn.example"})
      {:ok, _} = Policy.lock(scope, rule)
      view |> form("#rule-panel-form") |> render_submit()

      assert [%{action: "deny", locked: true}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))

      refute has_element?(view, "#rule-panel")
      assert render(view) =~ "The policy changed; look at the row again."
    end

    test "a row no rule decides can be denied outright, and a denied one only allowed", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      id = dst("files.cdn.example")
      # One text action a row, Allow on a denied destination; Deny… is in its menu.
      refute has_element?(view, "##{id}-act-deny")
      assert has_element?(view, "button##{id}-act", "Allow")
      assert has_element?(view, "##{id}-menu-deny", "Deny…")

      view |> element("##{id}-menu-deny") |> render_click()
      assert text(view, "#rule-panel-title") == "Deny files.cdn.example"
      assert has_element?(view, ~s(##{id}-act[aria-expanded=false]))

      view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-panel-submit") == "Deny for the workspace"
      view |> form("#rule-panel-form") |> render_submit()

      assert [%{action: "deny", locked: false}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))

      # the rule agrees with the record, so the row gains no line: Allow stays, Deny goes
      refute has_element?(view, "##{id}-after")
      assert text(view, "button##{id}-act") == "Allow"
      refute has_element?(view, "##{id}-menu-deny")

      # a host a deny rule already decides is only offered Allow
      {:ok, _} = Policy.deny(scope, nil, %{host: "ads.example"})
      effective = Policy.effective(scope, nil)

      denied = %{
        host: "ads.example",
        path: "",
        decision: "denied",
        rule: "ads.example",
        path_rule: nil
      }

      assert %{rule_option: :can_allow, deny: false} = Rules.rule_option(denied, effective)
    end

    test "a row let through under observe that is denied since gains the line and the link", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop(),
        egress: [%{"host" => "flags.example", "rule" => "", "mode" => "observe"}]
      )

      view = open(conn, scope)
      id = dst("flags.example")
      view |> element("##{id}-menu-deny") |> render_click()
      view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()
      view |> form("#rule-panel-form") |> render_submit()

      assert render(view) =~ "flags.example is denied for the workspace."
      # the row is the record and stays let through; the line after says what holds now
      assert has_element?(view, ~s(tr##{id}[data-decision=allowed]))
      assert text(view, "##{id}-after") =~ "Denied for the workspace in v"

      assert has_element?(
               view,
               ~s(a##{id}-act[href="#{workspace_path(scope, "/policy?rule=flags.example")}"])
             )

      refute has_element?(view, "##{id}-act-deny")
    end

    test "the target's select is not part of the radio's name", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      assert has_element?(view, "#rule-panel-target")
      refute has_element?(view, "#rule-panel label select")
    end
  end

  describe "the organisation keys of the row's events" do
    test "a destination or a target of another workspace is not found", %{
      conn: conn,
      scope: scope
    } do
      other = scope_fixture()

      started_run(other, shop("forge.other.example"),
        egress: [%{@denied | "host" => "only.theirs.example"}]
      )

      theirs = target(other, "forge.other.example")
      view = open(conn, scope)

      # a destination this workspace never reached opens nothing
      render_click(view, "rule_open", Map.put(values("only.theirs.example"), "action", "allow"))
      refute has_element?(view, "#rule-panel")

      # and a target of another workspace cannot be chosen
      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      render_change(view, "rule_change", %{"for" => "target", "target" => theirs.id})
      assert has_element?(view, "#rule-panel-submit[disabled]")
      render_submit(view, "rule_submit", %{"for" => "target", "target" => theirs.id})

      assert Policy.list_rules(other, theirs) == []
      assert Policy.list_rules(other, nil) == []
      assert Policy.list_rules(scope, nil) |> Enum.map(& &1.host) == ["registry.example"]
    end

    test "crafted events with nothing open do nothing", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      render_submit(view, "rule_submit", %{"for" => "workspace"})
      render_change(view, "rule_change", %{"for" => "workspace"})
      render_click(view, "rule_open", %{"host" => %{"a" => 1}, "action" => "allow"})
      render_click(view, "rule_open", Map.put(values("files.cdn.example"), "action", "lock"))
      # Deny is not a rule option of the wall's row
      render_click(view, "rule_open", Map.put(values("169.254.169.254", 80), "action", "deny"))
      refute has_element?(view, "#rule-panel")
      assert Policy.list_rules(scope, nil) |> Enum.map(& &1.host) == ["registry.example"]
    end
  end

  describe "a row's rule option" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.internal.example"})
      {:ok, rule} = Policy.deny(scope, nil, %{host: "*.paste.example"})
      {:ok, _} = Policy.lock(scope, rule)
      {:ok, rule} = Policy.allow(scope, nil, %{host: "github.example"})
      {:ok, _} = Policy.lock(scope, rule)
      # A deny below the allowed suffix: decided first by the runner, in either mode.
      {:ok, _} = Policy.deny(scope, nil, %{host: "tracker.internal.example"})
      %{effective: Policy.effective(scope, nil)}
    end

    test "a host a deny covers is not allowed now, though a suffix above it allows", %{
      effective: effective
    } do
      assert effective.deny == ["tracker.internal.example", "*.paste.example"]

      # Let through with no rule before the deny: not allowed now, since the deny is decided
      # before the suffix that allows the rest, so the row keeps its Allow and no second
      # deny is offered (`answered/3` then says the deny answered it).
      assert %{rule_option: :can_allow, deny: false, entry: %{action: :deny}} =
               Rules.rule_option(row("tracker.internal.example", "allowed", ""), effective)

      # Denied by the rule: the same.
      assert %{rule_option: :can_allow, deny: false, entry: %{action: :deny}} =
               Rules.rule_option(
                 row("tracker.internal.example", "denied", "tracker.internal.example"),
                 effective
               )

      # Another host below the suffix is allowed now, as before.
      assert %{rule_option: :can_deny} =
               Rules.rule_option(
                 row("tax.internal.example", "allowed", "*.internal.example"),
                 effective
               )
    end

    defp row(host, decision, rule, extra \\ %{}) do
      Map.merge(%{host: host, path: "", decision: decision, rule: rule, path_rule: nil}, extra)
    end

    test "allow, deny, locked, the wall, and a rule that already answers", %{effective: effective} do
      rule_option = &Rules.rule_option(&1, effective).rule_option

      assert rule_option.(row("files.cdn.example", "denied", nil)) == :can_allow
      assert rule_option.(row("flags.example", "allowed", "")) == :can_allow
      # no rule decides them, so each can be denied outright as well
      assert Rules.rule_option(row("files.cdn.example", "denied", nil), effective).deny
      assert Rules.rule_option(row("flags.example", "allowed", ""), effective).deny
      assert rule_option.(row("registry.example", "allowed", "registry.example")) == :can_deny

      assert rule_option.(row("tax.internal.example", "allowed", "*.internal.example")) ==
               :can_deny

      assert rule_option.(row("bin.paste.example", "denied", nil)) == :locked_deny
      assert rule_option.(row("github.example", "allowed", "github.example")) == :locked_allow
      assert rule_option.(row("169.254.169.254", "denied", "wall:own-address")) == :wall

      assert rule_option.(
               row("api.example", "denied", "api.example", %{path_rule: "wall:ambiguous-path"})
             ) == :wall

      # a path no path rule matches can still be allowed; one a rule matches is answered
      assert rule_option.(row("api.example", "denied", "api.example", %{path: "/v2/models"})) ==
               :can_allow

      assert rule_option.(row("api.example", "denied", "api.example", %{path: "/v1/messages"})) ==
               {:rule_added, :allow}

      # denied once, allowed since
      assert %{rule_option: {:rule_added, :allow}, entry: %{host: "registry.example"}} =
               Rules.rule_option(row("registry.example", "denied", nil), effective)
    end

    test "a host no rule can name has no action, whatever a runner sent", %{effective: effective} do
      for host <- [
            "*.example",
            "UPPER case.example",
            "<script>",
            "",
            nil,
            String.duplicate("a", 300),
            "[::1]"
          ] do
        assert %{rule_option: :unnameable} =
                 Rules.rule_option(row(host, "denied", nil), effective)
      end
    end

    test "a past change of a credential named like a host says nothing of the host's rule", %{
      effective: effective
    } do
      entry = Enum.find(effective.entries, &(&1.host == "registry.example"))
      at = DateTime.utc_now()

      credential = %{
        subject: "registry.example",
        action: "rule_added",
        after: %{"rules" => [%{"kind" => "credential", "name" => "registry.example"}]},
        version_after: 9,
        changed_by: nil,
        changed_by_id: nil,
        inserted_at: at
      }

      host = %{
        credential
        | after: %{"rules" => [%{"kind" => "host", "host" => "registry.example"}]},
          version_after: 4
      }

      assert Rules.change_for(entry, %{workspace: [credential]}) == nil
      assert %{version: 4} = Rules.change_for(entry, %{workspace: [credential, host]})
    end

    test "past what can be read of the targets' own rules, the baseline claims nothing", %{
      effective: effective
    } do
      row = row("registry.example", "denied", nil)

      assert %{rule_option: {:rule_added, :allow}} =
               Rules.rule_option(row, effective, :workspace, [])

      assert %{rule_option: :can_allow} = Rules.rule_option(row, effective, :workspace, :unknown)

      assert %{rule_option: :can_allow} =
               Rules.rule_option(row, effective, :workspace, ["*.example"])

      assert %{rule_option: {:rule_added, :allow}} =
               Rules.rule_option(row, effective, :workspace, ["x.example"])
    end

    test "a row allowed by a target's own rule can be denied from the workspace's page", %{
      effective: effective
    } do
      row = row("mcp.acme.example", "allowed", "mcp.acme.example")
      assert Rules.rule_option(row, effective, :workspace).rule_option == :can_deny
      assert Rules.rule_option(row, effective, :run).rule_option == :can_allow
    end
  end
end
