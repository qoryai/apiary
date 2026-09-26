defmodule ApiaryWeb.ConnectionLive.RulesTest do
  @moduledoc """
  Allow and Deny from a row of the workspace's connections page
  (`docs/design/brief-policy.md`, pd8), and what a row stands for
  (`ApiaryWeb.ConnectionLive.Rules`).
  """
  use ApiaryWeb.ConnCase, async: true

  # Every test here is a rule, a version or a policy on the run's pages: `security`.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
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

  defp open(conn, scope, rest \\ "/connections") do
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

  describe "the workspace's connections page" do
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
      refute has_element?(view, "#rule-popover input[name=for][checked]")
      assert has_element?(view, "#rule-popover-submit[disabled]")
      options = text(view, "#rule-popover-target")
      assert options =~ "github.example/acme/shop · 1 run"
      assert options =~ "gitlab.example/acme/shop · 1 run"

      assert text(view, "#rule-popover-next") ==
               "Takes effect in running sessions within a heartbeat, about 30 s."

      # "One repository" alone is not a scope yet
      view |> form("#rule-popover-form", %{"for" => "target"}) |> render_change()
      assert has_element?(view, "#rule-popover-submit[disabled]")
    end

    test "allowing for the workspace keeps the row as it was and adds the line after", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      cdn = dst("files.cdn.example")
      view |> element("##{cdn}-act") |> render_click()
      view |> form("#rule-popover-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-popover-submit") == "Allow for the workspace"
      view |> form("#rule-popover-form") |> render_submit()

      assert Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))
      {:ok, configuration} = Policy.current_configuration(scope, nil)

      refute has_element?(view, "#rule-popover")
      assert has_element?(view, ~s(tr##{cdn}.q-denied[data-decision=denied]))
      line = text(view, "##{cdn}-after")
      assert line =~ "Rule added"

      assert line =~
               "Allowed for the workspace in v#{configuration.version} · of workspace baseline by you"

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
      |> form("#rule-popover-form", %{"for" => "target", "target" => gitlab.id})
      |> render_change()

      assert text(view, "#rule-popover-submit") == "Allow for the repository"
      view |> form("#rule-popover-form") |> render_submit()

      assert [%{host: "files.cdn.example"}] = Policy.list_rules(scope, gitlab)
      assert Policy.list_rules(scope, target(scope, "github.example")) == []
      refute Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))
      assert render(view) =~ "files.cdn.example is allowed for gitlab.example/acme/shop."
    end

    test "with repo set, that target is chosen, and its policy is a link away", %{
      conn: conn,
      scope: scope
    } do
      github = target(scope, "github.example")
      view = open(conn, scope, "/connections?system=github.example&target=acme/shop")

      assert has_element?(
               view,
               ~s(#connections-target-policy[href="#{workspace_path(scope, "/policy/targets/#{github.id}")}"]),
               "Its policy"
             )

      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      assert has_element?(view, ~s(#rule-popover input[name=for][value=target][checked]))

      assert has_element?(
               view,
               ~s(#rule-popover-target option[value="#{github.id}"][selected])
             )

      view |> form("#rule-popover-form") |> render_submit()

      assert [%{host: "files.cdn.example"}] = Policy.list_rules(scope, github)
      line = text(view, "##{dst("files.cdn.example")}-after")
      assert line =~ "Allowed for this repository in v1 · of github.example/acme/shop by you"
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
               "Allowed for the workspace in v2 · of workspace baseline"

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
      view |> form("#rule-popover-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-popover") =~ "A repository's own allow rule still holds there."

      assert text(view, "#rule-popover-own-rule") ==
               "A repository's own rule for this host still decides there."

      view |> form("#rule-popover-form") |> render_submit()
      assert render(view) =~ "A repository&#39;s own rule for this host still decides there."

      # the baseline's deny is not the answer to this row: the target still allows it
      assert "extra.example" in Policy.effective(scope, github).allow
      refute has_element?(view, "##{d}-after")
      assert text(view, "button##{d}-act") == "Deny"

      # so the deny for that target can still be made from here
      view |> element("##{d}-act") |> render_click()

      view
      |> form("#rule-popover-form", %{"for" => "target", "target" => github.id})
      |> render_change()

      assert text(view, "#rule-popover") =~ "Replaces the repository's own rule for the host."
      view |> form("#rule-popover-form") |> render_submit()
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

      # with repo set the rows stand against that target's policy, and it answers
      view = open(conn, scope, "/connections?system=github.example&target=acme/shop")
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
      assert text(view, "#rule-popover-title") == "Allow api.pathed.example"
      refute has_element?(view, "#rule-popover-what-set")

      view
      |> form("#rule-popover-form", %{"for" => "target", "target" => github.id})
      |> render_change()

      assert text(view, "#rule-popover-title") == "Allow on api.pathed.example"
      assert text(view, "#rule-popover-what") =~ "This path /v2/x is added"

      view |> form("#rule-popover-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-popover-title") == "Allow api.pathed.example"

      view |> form("#rule-popover-form", %{"for" => "target"}) |> render_change()
      view |> form("#rule-popover-form") |> render_submit()

      assert [%{paths: ["/ok/*", "/v2/x"]}] = Policy.list_rules(scope, github)

      assert render(view) =~
               "/v2/x on api.pathed.example is allowed for github.example/acme/shop."
    end

    test "a stale popover is not sent", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      view |> form("#rule-popover-form", %{"for" => "workspace"}) |> render_change()

      {:ok, rule} = Policy.deny(scope, nil, %{host: "files.cdn.example"})
      {:ok, _} = Policy.lock(scope, rule)
      view |> form("#rule-popover-form") |> render_submit()

      assert [%{action: "deny", locked: true}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))

      refute has_element?(view, "#rule-popover")
      assert render(view) =~ "The policy changed; look at the row again."
    end

    test "a row no rule decides can be denied outright, and a denied one only allowed", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      id = dst("files.cdn.example")
      assert has_element?(view, "button##{id}-act-deny.q-rowbtn-deny", "Deny")
      assert has_element?(view, "button##{id}-act", "Allow")

      view |> element("##{id}-act-deny") |> render_click()
      assert text(view, "#rule-popover-title") == "Deny files.cdn.example"
      assert has_element?(view, ~s(##{id}-act-deny[aria-expanded=true]))
      assert has_element?(view, ~s(##{id}-act[aria-expanded=false]))

      view |> form("#rule-popover-form", %{"for" => "workspace"}) |> render_change()
      assert text(view, "#rule-popover-submit") == "Deny for the workspace"
      view |> form("#rule-popover-form") |> render_submit()

      assert [%{action: "deny", locked: false}] =
               Enum.filter(Policy.list_rules(scope, nil), &(&1.host == "files.cdn.example"))

      # the rule agrees with the record, so the row gains no line: Allow stays, Deny goes
      refute has_element?(view, "##{id}-after")
      assert text(view, "button##{id}-act") == "Allow"
      refute has_element?(view, "##{id}-act-deny")

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

      assert %{standing: :can_allow, deny: false} = Rules.standing(denied, effective)
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
      view |> element("##{id}-act-deny") |> render_click()
      view |> form("#rule-popover-form", %{"for" => "workspace"}) |> render_change()
      view |> form("#rule-popover-form") |> render_submit()

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
      assert has_element?(view, "#rule-popover-target")
      refute has_element?(view, "#rule-popover label select")
    end
  end

  describe "tenancy of the row's events" do
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
      refute has_element?(view, "#rule-popover")

      # and a target of another workspace cannot be chosen
      view |> element("##{dst("files.cdn.example")}-act") |> render_click()
      render_change(view, "rule_change", %{"for" => "target", "target" => theirs.id})
      assert has_element?(view, "#rule-popover-submit[disabled]")
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
      # Deny is not what the wall's row stands for
      render_click(view, "rule_open", Map.put(values("169.254.169.254", 80), "action", "deny"))
      refute has_element?(view, "#rule-popover")
      assert Policy.list_rules(scope, nil) |> Enum.map(& &1.host) == ["registry.example"]
    end
  end

  describe "what a row stands for" do
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
      assert %{standing: :can_allow, deny: false, entry: %{action: :deny}} =
               Rules.standing(row("tracker.internal.example", "allowed", ""), effective)

      # Denied by the rule: the same.
      assert %{standing: :can_allow, deny: false, entry: %{action: :deny}} =
               Rules.standing(
                 row("tracker.internal.example", "denied", "tracker.internal.example"),
                 effective
               )

      # Another host below the suffix is allowed now, as before.
      assert %{standing: :can_deny} =
               Rules.standing(
                 row("tax.internal.example", "allowed", "*.internal.example"),
                 effective
               )
    end

    defp row(host, decision, rule, extra \\ %{}) do
      Map.merge(%{host: host, path: "", decision: decision, rule: rule, path_rule: nil}, extra)
    end

    test "allow, deny, locked, the wall, and a rule that already answers", %{effective: effective} do
      standing = &Rules.standing(&1, effective).standing

      assert standing.(row("files.cdn.example", "denied", nil)) == :can_allow
      assert standing.(row("flags.example", "allowed", "")) == :can_allow
      # no rule decides them, so each can be denied outright as well
      assert Rules.standing(row("files.cdn.example", "denied", nil), effective).deny
      assert Rules.standing(row("flags.example", "allowed", ""), effective).deny
      assert standing.(row("registry.example", "allowed", "registry.example")) == :can_deny
      assert standing.(row("tax.internal.example", "allowed", "*.internal.example")) == :can_deny
      assert standing.(row("bin.paste.example", "denied", nil)) == :locked_deny
      assert standing.(row("github.example", "allowed", "github.example")) == :locked_allow
      assert standing.(row("169.254.169.254", "denied", "wall:own-address")) == :wall

      assert standing.(
               row("api.example", "denied", "api.example", %{path_rule: "wall:ambiguous-path"})
             ) == :wall

      # a path no path rule matches can still be allowed; one a rule matches is answered
      assert standing.(row("api.example", "denied", "api.example", %{path: "/v2/models"})) ==
               :can_allow

      assert standing.(row("api.example", "denied", "api.example", %{path: "/v1/messages"})) ==
               {:rule_added, :allow}

      # denied once, allowed since
      assert %{standing: {:rule_added, :allow}, entry: %{host: "registry.example"}} =
               Rules.standing(row("registry.example", "denied", nil), effective)
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
        assert %{standing: :unnameable} = Rules.standing(row(host, "denied", nil), effective)
      end
    end

    test "the change of a credential named like a host says nothing of the host's rule", %{
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
      assert %{standing: {:rule_added, :allow}} = Rules.standing(row, effective, :workspace, [])
      assert %{standing: :can_allow} = Rules.standing(row, effective, :workspace, :unknown)
      assert %{standing: :can_allow} = Rules.standing(row, effective, :workspace, ["*.example"])

      assert %{standing: {:rule_added, :allow}} =
               Rules.standing(row, effective, :workspace, ["x.example"])
    end

    test "a row allowed by a target's own rule can be denied from the workspace's page", %{
      effective: effective
    } do
      row = row("mcp.acme.example", "allowed", "mcp.acme.example")
      assert Rules.standing(row, effective, :workspace).standing == :can_deny
      assert Rules.standing(row, effective, :run).standing == :can_allow
    end
  end
end
