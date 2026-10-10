defmodule ApiaryWeb.PolicyLive.AboveTest do
  @moduledoc """
  The policy pages and Network access under a level above the workspace's policy
  (`Apiary.Policy.Above`), with the edition's answer faked: the line under the title, the
  level's rows first, their glyph and words, the mode fixed by its floor, the rows struck
  by its switch, and the Network access rows its rules decide.
  """
  # Not async: the faked answer is in the application environment, which is global.
  use ApiaryWeb.ConnCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import ApiaryWeb.TargetComponents, only: [target_path: 4]
  import Apiary.RunListFixtures
  import Apiary.Midnight

  alias Apiary.Policy
  alias Apiary.Policy.{Above, Effective, Rule}
  alias Apiary.Variables.Variable
  alias ApiaryWeb.ConnectionLive.Rules
  alias ApiaryWeb.PolicyLive.Common
  alias ApiaryWeb.{PolicyComponents, RunComponents}

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)
    :ok
  end

  defp rule(action, host, opts \\ []) do
    %Rule{
      id: Ecto.UUID.generate(),
      kind: "host",
      action: action,
      host: host,
      paths: opts[:paths],
      locked: false,
      inserted_at: ~U[2026-09-12 10:00:00.000000Z]
    }
  end

  defp above!(rules, opts \\ []) do
    above = %Above{
      id: Ecto.UUID.generate(),
      name: "Eight Wonders",
      slug: "8wonders",
      rules: rules,
      floor: Keyword.get(opts, :floor, false),
      own_allows: Keyword.get(opts, :own_allows, true)
    }

    Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)
    above
  end

  # A level with variables and no policy of its own, as an edition answers it.
  defp variables_only! do
    above = %Above{
      id: Ecto.UUID.generate(),
      name: "Eight Wonders",
      slug: "8wonders",
      policy: false,
      variables: [%Variable{name: "REGION", value: "eu-west-1", locked: true}]
    }

    Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)
    above
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
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp hosts(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#policy-rules .q-host")
    |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
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

  describe "the workspace's policy page" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "paste.example"})
      {:ok, _} = Policy.deny(scope, nil, %{host: "tracker.example", locked: true})

      above =
        above!([
          rule("deny", "paste.example"),
          rule("allow", "api.example", paths: ["/v1/*"]),
          rule("allow", "*.wonders.example")
        ])

      %{above: above}
    end

    test "says the level applies, lists its rules first with their source and glyph, and offers no change",
         %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/policy"))

      assert text(view, "#policy-above") == "E Eight Wonders's policy applies here: 3 rules."
      # The core's edition gives no page to view it on.
      refute has_element?(view, "#policy-above-view")

      assert hosts(view) == [
               "paste.example",
               "api.example",
               "*.wonders.example",
               "tracker.example",
               "cdn.example",
               "paste.example"
             ]

      assert has_element?(
               view,
               "#policy-rules-sort-button[aria-label=\"Sort: Eight Wonders's first\"]"
             )

      assert text(view, "#policy-hosts-note") =~ "Eight Wonders's rules come first"

      api = row(view, "api.example")
      assert text(view, "##{api} .q-pr-src") == "E Eight Wonders"

      assert has_element?(
               view,
               "##{api}-lock[data-tip=\"Eight Wonders's rule: it holds in every workspace.\"]"
             )

      refute has_element?(view, "##{api}-menu")
      assert has_element?(view, "##{api} code.q-rule", "/v1/*")

      # The workspace's allow the level denies is struck, and says whose deny.
      assert [struck] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#policy-rules tr.q-pr-off")
               |> Enum.to_list()

      assert struck |> LazyHTML.query(".q-pr-offw-full") |> LazyHTML.text() |> String.trim() ==
               "Not in force: Eight Wonders's paste.example denies it"

      # The Locked view counts the workspace's locked rule and not the level's.
      assert text(view, "#policy-rules-view-locked") == "Locked 1"

      # The Filter menu has a Source section with the level and the workspace, and the
      # token narrows to one.
      assert text(view, "#policy-rules-filter-source-0") =~ "Eight Wonders 3 rules"
      assert text(view, "#policy-rules-filter-source-1") =~ "#{scope.workspace.name} 3 rules"
      view |> element("#policy-rules-filter-source-0") |> render_click()
      assert_patch(view, workspace_path(scope, "/policy?q=source%3A8wonders"))
      assert hosts(view) == ["paste.example", "api.example", "*.wonders.example"]
      assert text(view, "#policy-rules-token-source") =~ "source: 8wonders"

      # The views count under the token: the level's three, none of them locked.
      assert text(view, "#policy-rules-view-all") == "All 3"
      assert text(view, "#policy-rules-view-locked") == "Locked 0"
    end

    test "a crafted event naming a rule of the level changes nothing", %{
      conn: conn,
      scope: scope,
      above: above
    } do
      view = open(conn, workspace_path(scope, "/policy"))
      [deny | _] = above.rules

      for event <- ~w(remove edit_paths change_action lock_toggle) do
        render_hook(view, event, %{"id" => deny.id})
      end

      render_hook(view, "remove_confirm", %{})
      assert length(Policy.list_rules(scope, nil)) == 3
      refute has_element?(view, "#policy-composer")
      assert Process.alive?(view.pid)
    end

    test "the floor fixes the mode on enforce, and a mode asked for is ignored",
         %{conn: conn, scope: scope} do
      above!([], floor: true)
      view = open(conn, workspace_path(scope, "/policy"))

      assert text(view, "#policy-above") =~ "applies here: 0 rules , enforce required"
      assert has_element?(view, "#policy-mode[data-floor=true]")
      assert text(view, "#policy-mode-value") == "Enforce"
      # The tile carries the lock; the badge says who requires it, and nothing else.
      assert has_element?(view, "#policy-mode .q-modecard-tile .hero-lock-closed")
      assert has_element?(view, "#policy-mode-required .hero-lock-closed-micro")
      assert text(view, "#policy-mode-required") == "Required by Eight Wonders"
      refute has_element?(view, "#policy-mode-source")

      assert text(view, "#policy-mode-effect") =~
               "No workspace or repository may observe: Eight Wonders requires enforce."

      refute has_element?(view, "#policy-mode-change")
      render_hook(view, "mode_open", %{"mode" => "observe"})
      refute has_element?(view, "#policy-mode-form")
      render_hook(view, "mode_pick", %{"mode" => "observe"})
      render_hook(view, "mode_set", %{})
      assert Policy.get_mode(scope) == "observe"
      assert text(view, "#nav-policy-mode") == "enforce"
    end

    test "the switch off strikes the workspace's allows and says why", %{conn: conn, scope: scope} do
      above!([rule("allow", "api.example")], own_allows: false)
      view = open(conn, workspace_path(scope, "/policy"))

      assert text(view, "#policy-above") =~ "1 rule , only its own hosts allowed"
      cdn = row(view, "cdn.example")
      assert has_element?(view, "##{cdn}.q-pr-off")

      assert text(view, "##{cdn} .q-pr-offw-full") ==
               "Not in force: Eight Wonders allows only its own hosts"

      # A struck rule is still the workspace's to remove.
      assert has_element?(view, "##{cdn}-remove")
      view |> element("##{cdn}-remove") |> render_click()
      refute Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "cdn.example"))
    end

    test "a change of the level in the history says whose it was", %{conn: conn, scope: scope} do
      {:ok, changes} =
        Apiary.Repo.transact(fn ->
          {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
          Policy.rerender_in(workspace, scope, action: "above_changed")
        end)

      assert [_baseline] = changes
      view = open(conn, workspace_path(scope, "/policy/history"))
      assert text(view, "#policy-history") =~ "changed Eight Wonders 's policy"
    end
  end

  describe "a target's Policy tab" do
    setup %{scope: scope} do
      started_run(scope, shop())
      [%{target: target}] = Policy.list_targets(scope)
      {:ok, _} = Policy.allow(scope, target, %{host: "sms.example"})
      {:ok, _} = Policy.set_mode(scope, target, "observe")
      %{target: target, path: target_path(scope, target.system, target.path, ["policy"])}
    end

    test "lists the level's rows after its own, and the floor fixes its mode", %{
      conn: conn,
      scope: scope,
      target: target,
      path: path
    } do
      # The card says "today" of the mode the setup set: in a day of the reader's, clear of
      # midnight (`Apiary.Midnight`).
      reader_at_noon(scope.user)

      above!([rule("deny", "paste.example"), rule("allow", "api.example")],
        floor: true,
        own_allows: false
      )

      view = open(conn, path)

      assert hosts(view) == ["sms.example", "paste.example", "api.example"]
      sms = row(view, "sms.example")
      assert has_element?(view, "##{sms}.q-pr-off")
      assert text(view, "##{sms} .q-pr-offw-full") =~ "Eight Wonders allows only its own hosts"
      paste = row(view, "paste.example")
      assert text(view, "##{paste} .q-pr-src") == "E Eight Wonders"
      assert has_element?(view, "##{paste}-lock")
      refute has_element?(view, "##{paste}-menu")

      assert text(view, "#policy-hosts-note") =~
               "Eight Wonders's and #{scope.workspace.name}'s follow"

      assert has_element?(view, "#policy-mode[data-floor=true]")
      assert text(view, "#policy-mode-value") == "Enforce"
      assert has_element?(view, "#policy-mode .q-modecard-tile .hero-lock-closed")
      assert text(view, "#policy-mode-required") == "Required by Eight Wonders"

      assert text(view, "#policy-mode-effect") =~
               "Its own observe, set by #{ApiaryWeb.People.short(scope.user.email)} today, is not in force: Eight Wonders requires enforce."

      refute has_element?(view, "#policy-mode-change")
      render_hook(view, "mode_open", %{"mode" => "enforce"})
      refute has_element?(view, "#policy-mode-form")
      render_hook(view, "mode_set", %{})
      assert Policy.get_mode(scope, target).own == "observe"
    end
  end

  describe "a target's own deny of a host the level allows" do
    setup %{scope: scope} do
      started_run(scope, shop())
      [%{target: target}] = Policy.list_targets(scope)
      {:ok, _} = Policy.deny(scope, target, %{host: "api.algolia.example"})
      above!([rule("allow", "api.algolia.example")])
      %{path: target_path(scope, target.system, target.path, ["policy"])}
    end

    test "strikes the level's allow and names the target, not the workspace, as its winner",
         %{conn: conn, scope: scope, path: path} do
      view = open(conn, path)

      [_own, above_row] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#policy-rules tr.q-pr-row")
        |> Enum.filter(
          &(LazyHTML.query(&1, ".q-host") |> LazyHTML.text() |> String.trim() ==
              "api.algolia.example")
        )
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      words = text(view, "##{above_row} .q-pr-offw-full")

      assert words =~
               ~r/^Not in force here: this (repository|target)'s own api\.algolia\.example denies it$/

      refute words =~ scope.workspace.name
    end
  end

  describe "Network access" do
    setup %{scope: scope} do
      started_run(scope, shop(),
        egress: [
          %{
            "host" => "paste.example",
            "decision" => "denied",
            "rule" => "paste.example",
            "outcome" => "refused"
          },
          %{"host" => "api.example", "decision" => "allowed", "rule" => "api.example"},
          %{"host" => "new.example", "decision" => "denied", "rule" => "", "outcome" => "refused"}
        ]
      )

      :ok
    end

    defp dst(host), do: RunComponents.destination_id(%{host: host, port: 443, path: ""})

    test "a row the level denies has a lock and its reason, and one it allows its reason and Deny",
         %{conn: conn, scope: scope} do
      above!([rule("deny", "paste.example"), rule("allow", "api.example")])
      view = open(conn, workspace_path(scope, "/network"))

      paste = dst("paste.example")
      assert text(view, "##{paste}-above") == "E Eight Wonders · denied"

      # A lock the keyboard reaches, its hint why; no Allow and no Deny.
      assert has_element?(
               view,
               "span##{paste}-lock.q-act-lock[tabindex=\"0\"][data-tip=\"Eight Wonders's policy denies paste.example. No workspace or repository rule can allow it.\"]"
             )

      refute has_element?(view, "##{paste}-allow")
      refute has_element?(view, "##{paste}-deny")

      # The core's edition has no page of the level to lead to: "Eight Wonders · denied"
      # leads to the rule where it is listed, on the workspace's page.
      assert has_element?(
               view,
               ~s(##{paste}-above a##{paste}-rule[href="#{workspace_path(scope, "/policy?rule=paste.example")}"])
             )

      api = dst("api.example")
      assert text(view, "##{api}-above") == "E Eight Wonders · allowed"
      assert has_element?(view, "button##{api}-deny[data-action=deny]")
      refute has_element?(view, "##{api}-allow")

      # A crafted allow of the denied row opens nothing.
      render_hook(view, "rule_open", %{
        "host" => "paste.example",
        "port" => "443",
        "path" => "",
        "action" => "allow"
      })

      refute has_element?(view, "#rule-panel")
    end

    test "a row the level denies since it was allowed links its rule once and its after line once",
         %{conn: conn, scope: scope} do
      above!([rule("deny", "api.example")])
      # LiveViewTest raises on a duplicate id: the page renders.
      view = open(conn, workspace_path(scope, "/network"))
      api = dst("api.example")
      rule = workspace_path(scope, "/policy?rule=api.example")

      assert has_element?(view, ~s(##{api}-above a##{api}-rule[href="#{rule}"]))

      assert has_element?(
               view,
               ~s(##{api}-after a##{api}-after-rule[href="#{rule}"]),
               "Show the rule"
             )
    end

    test "where the level allows only its own hosts, Allow is a lock without its page, and Deny stays",
         %{conn: conn, scope: scope} do
      above!([], own_allows: false)
      view = open(conn, workspace_path(scope, "/network"))

      new = dst("new.example")

      assert has_element?(
               view,
               "span##{new}-lock.q-act-lock[tabindex=\"0\"][data-tip=\"Only Eight Wonders's policy allows a host here\"]"
             )

      # The row says what holds, where it can be read, and Deny stays.
      assert text(view, "##{new}-elsewhere") =~ "Eight Wonders allows only its own hosts"
      refute has_element?(view, "##{new}-allow")
      assert has_element?(view, "button##{new}-deny")
    end

    test "a row's rule option says what the level decides" do
      above =
        above!([rule("deny", "*.paste.example"), rule("allow", "api.example")], own_allows: false)

      {:ok, effective} = Apiary.Policy.Resolution.resolve("enforce", [], [], nil, above)

      assert %{rule_option: :above_deny, above: %{name: "Eight Wonders", action: :deny}} =
               Rules.rule_option(%{host: "a.paste.example", decision: "denied"}, effective)

      assert %{rule_option: {:rule_added, :allow}, above: %{action: :allow}} =
               Rules.rule_option(%{host: "api.example", decision: "denied"}, effective)

      assert %{rule_option: :can_deny} =
               option =
               Rules.rule_option(
                 %{host: "api.example", decision: "allowed", rule: "api.example"},
                 effective
               )

      assert option.above == %{name: "Eight Wonders", action: :allow}

      assert %{rule_option: :can_allow, deny: true, allow_elsewhere: %{name: "Eight Wonders"}} =
               Rules.rule_option(%{host: "new.example", decision: "denied"}, effective)
    end
  end

  describe "a level that carries variables only" do
    setup %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.deny(scope, nil, %{host: "paste.example", locked: true})

      started_run(scope, shop(),
        egress: [
          %{
            "host" => "paste.example",
            "decision" => "denied",
            "rule" => "paste.example",
            "outcome" => "refused"
          },
          %{"host" => "new.example", "decision" => "denied", "rule" => "", "outcome" => "refused"}
        ]
      )

      [%{target: target}] = Policy.list_targets(scope)
      {:ok, _} = Policy.allow(scope, target, %{host: "sms.example"})
      %{above: variables_only!(), target: target}
    end

    test "shows no line, no rows and no source of it on the workspace's page",
         %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/policy"))

      refute has_element?(view, "#policy-above")
      assert hosts(view) == ["paste.example", "cdn.example"]
      refute render(view) =~ "Eight Wonders"
      refute has_element?(view, "#policy-mode[data-floor=true]")
    end

    test "shows none of it on a target's tab", %{conn: conn, scope: scope, target: target} do
      view = open(conn, target_path(scope, target.system, target.path, ["policy"]))

      assert hosts(view) == ["sms.example", "paste.example", "cdn.example"]
      refute render(view) =~ "Eight Wonders"
      refute has_element?(view, "#policy-mode[data-floor=true]")
    end

    test "decides no row of Network access", %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/network"))

      refute has_element?(view, "##{dst("paste.example")}-above")
      refute has_element?(view, "##{dst("new.example")}-elsewhere")
      refute render(view) =~ "Eight Wonders"
    end

    test "the line, the rows and the source take it as nil", %{above: above} do
      assert render_component(&PolicyComponents.above_line/1, above: above) == ""
      assert Common.above_source(above) == nil
      assert Common.above_rows(%Effective{above: above}, nil) == []

      # With a policy, the same level is all three.
      above = %{above | policy: true}
      assert render_component(&PolicyComponents.above_line/1, above: above) =~ "Eight Wonders"
      assert %{key: "8wonders", label: "Eight Wonders"} = Common.above_source(above)
    end
  end

  test "the level's rule is linked from the reason, and Allow's hint names the level's page" do
    connection = %{
      host: "paste.example",
      port: 443,
      path: "",
      decision: "denied",
      rule: "paste.example",
      outcome: "refused",
      runs: 1,
      attempts: 1,
      allowed: 0,
      denied: 1
    }

    act = %{
      rule_option: :above_deny,
      entry_host: "paste.example",
      above: %{name: "Eight Wonders", action: :deny},
      above_linked: true,
      above_can_change: true,
      rule_path: "/8wonders/policy?rule=paste.example"
    }

    html =
      render_component(&RunComponents.connection_row/1,
        id: "r",
        connection: connection,
        variant: "workspace",
        act: act
      )

    assert html =~ ~s(id="r-rule")
    assert html =~ "/8wonders/policy?rule=paste.example"

    html =
      render_component(&RunComponents.rule_actions/1,
        id: "r",
        connection: %{host: "new.example"},
        rule_option: :can_allow,
        deny: true,
        allow_elsewhere: %{name: "Eight Wonders"},
        allow_path: "/8wonders/policy?allow=new.example"
      )

    # Its name holds its hint's words.
    assert html =~ ~s(data-tip="Allow new.example in Eight Wonders&#39;s policy")
    assert html =~ ~s(aria-label="Allow new.example in Eight Wonders&#39;s policy")
  end

  test "where only the level allows a host, Allow opens a panel that says so and leads there" do
    act = %{
      rule_option: :can_allow,
      deny: true,
      allow_elsewhere: %{name: "Eight Wonders"},
      allow_path: "/8wonders/policy?allow=new.example"
    }

    # The row's Allow asks; it does not navigate on its own.
    html =
      render_component(&RunComponents.rule_actions/1,
        id: "a",
        connection: %{host: "new.example"},
        rule_option: act.rule_option,
        deny: true,
        allow_elsewhere: act.allow_elsewhere,
        allow_path: act.allow_path
      )

    assert html =~ ~s(data-action="allow")
    assert html =~ "rule_open"
    refute html =~ "/8wonders/policy?allow=new.example"
    assert html =~ ~s(id="a-deny")

    html =
      render_component(&RunComponents.rule_panel/1,
        panel: %{
          anchor: "a-allow",
          host: "new.example",
          action: :allow,
          refusal: :elsewhere,
          elsewhere: %{name: "Eight Wonders", path: "/8wonders/policy?allow=new.example"}
        }
      )

    assert html =~ "Eight Wonders allows only its own hosts"
    assert html =~ "Open Eight Wonders&#39;s policy"
    assert html =~ "/8wonders/policy?allow=new.example"
    # In the page's flow, not an overlay: no popover and no dialog; Escape cancels.
    refute html =~ "popover="
    refute html =~ ~s(role="dialog")
    assert html =~ ~s(phx-window-keydown="rule_cancel")
  end
end
