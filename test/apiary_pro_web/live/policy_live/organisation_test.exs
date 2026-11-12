defmodule ApiaryProWeb.PolicyLive.OrganisationTest do
  # The organisation's Policy page: its mode card above the tabs, its Rules tab with the
  # switch and the list, its Workspaces tab and its History, for an owner who changes it and
  # an admin who reads it; the sidebar's entry; and nothing of it where the feature is off.
  # Not async: the features are the node's.
  use ApiaryWeb.ConnCase, async: false

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Features, Policy}
  alias ApiaryPro.OrganisationPolicy
  alias ApiaryProWeb.Trail

  @moduletag with_features: Features.all()

  setup %{conn: conn} do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)

    %{scope: owner, organisation: organisation, workspace: main, user: user} =
      sign_up_fixture(%{organisation_name: "Example Co"})

    platform = workspace_fixture(organisation, "Platform")
    admin = member_fixture(owner, :admin)
    member = member_fixture(owner, :member)

    %{
      conn: log_in_user(conn, user),
      owner: owner,
      organisation: organisation,
      main: main,
      platform: platform,
      in_platform: workspace_scope(user, platform),
      admin: admin,
      member: member
    }
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

  # A sentence as it reads: its text, the marked-up parts in it run in without a space.
  defp sentence(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # An element's text as it is read: unlike text/2, its tags add no space.
  defp read(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp type(view, params), do: view |> form("#policy-rule-form", rule: params) |> render_change()
  defp add(view), do: view |> form("#policy-rule-form") |> render_submit()

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

  defp policy_path(ctx, rest \\ ""), do: "/#{ctx.organisation.slug}/policy" <> rest

  # Whether the organisation requires enforce in every workspace, as stored.
  defp floor?(ctx),
    do: match?({:ok, %{policy: %{enforce_everywhere: true}}}, OrganisationPolicy.get(ctx.owner))

  describe "the Rules tab" do
    test "lists the organisation's rules, denies first, with three views and the use over every workspace",
         ctx do
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "cdn.example"})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      view = open(ctx.conn, policy_path(ctx))

      assert text(view, "#policy-header-title") == "Policy"
      assert page_title(view) =~ "Policy"
      refute page_title(view) =~ "Security"

      assert text(view, "#policy-header-description") =~
               "Rules every workspace of Example Co follows."

      assert text(view, "#policy-tabs-rules") == "Rules 3"
      assert has_element?(view, "#policy-tabs-rules[aria-current=page]")
      assert text(view, "#policy-tabs-workspaces") == "Workspaces 2"
      assert text(view, "#policy-tabs-history") == "History 3"

      assert hosts(view) == ["paste.example", "api.example", "cdn.example"]
      assert text(view, "#policy-rules-view-all") == "All 3"
      assert text(view, "#policy-rules-view-allowed") == "Allowed 2"
      assert text(view, "#policy-rules-view-denied") == "Denied 1"
      refute has_element?(view, "#policy-rules-view-locked")
      assert has_element?(view, "#policy-rules-sort-button[aria-label=\"Sort: Denies first\"]")
      assert text(view, "#policy-rules thead") =~ "Last 14 days, every workspace"

      api = row(view, "api.example")
      assert has_element?(view, "##{api} code.q-rule", "/v1/*")
      assert has_element?(view, "##{api}-menu")
      refute has_element?(view, "##{api}-paths")
      assert has_element?(view, "##{api}-change", "Change to deny")
      assert has_element?(view, "##{api}-remove")
      refute has_element?(view, "##{api}-lock-toggle")
      refute has_element?(view, "##{api}-lock")

      # The floor is the mode card's, above the tabs; the switch is the Rules tab's one line.
      assert text(view, "#policy-mode-value") == "Set per workspace"
      assert has_element?(view, "#policy-mode-change")
      refute has_element?(view, "#policy-floor")
      assert has_element?(view, "#policy-switch-switch[aria-checked=true]")
      refute has_element?(view, "#policy-owners")
      refute has_element?(view, "#policy-mode-owners")
      assert text(view, "#policy-hosts-note") =~ "A deny here holds in every workspace"
    end

    test "an owner adds a rule on New rule, changes and removes one", ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      view = open(ctx.conn, policy_path(ctx))

      view |> element("#policy-rules-head #policy-rules-add") |> render_click()
      assert_patch(view, policy_path(ctx, "/rules/new"))

      type(view, %{host: "api.example", paths: ""})
      add(view)
      assert_patch(view, policy_path(ctx, "?rule=api.example"))

      assert render(view) =~ "api.example is allowed for every workspace."
      assert hosts(view) == ["api.example"]

      assert {:ok, %{rules: [%{host: "api.example", action: "allow"}]}} =
               OrganisationPolicy.get(ctx.owner)

      # Every workspace was rendered: a version after the version 1 of its creation.
      assert {:ok, %{version: 3}} = Policy.current_configuration(ctx.owner, nil)
      assert {:ok, %{version: 2}} = Policy.current_configuration(ctx.in_platform, nil)

      api = row(view, "api.example")
      view |> element("##{api}-change") |> render_click()
      assert {:ok, %{rules: [%{action: "deny"}]}} = OrganisationPolicy.get(ctx.owner)
      assert render(view) =~ "api.example is denied for every workspace."

      api = row(view, "api.example")
      view |> element("##{api}-remove") |> render_click()
      assert {:ok, %{rules: []}} = OrganisationPolicy.get(ctx.owner)

      assert text(view, "#policy-rules") =~
               "No host rules yet. Add the first with Add rule: it holds in every workspace."

      assert_push_event(view, "policy:focus", %{id: "policy-rules-add"})
    end

    test "the mode card sits between the header and the tabs, on every tab, in the core's pattern",
         ctx do
      for tab <- ["", "/workspaces", "/history"] do
        html = ctx.conn |> open(policy_path(ctx, tab)) |> render()

        ids =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("#organisation-policy > [id]")
          |> LazyHTML.attribute("id")

        assert Enum.take(ids, 3) == ["policy-header", "policy-mode", "policy-tabs"]
      end

      view = open(ctx.conn, policy_path(ctx))
      assert has_element?(view, "section#policy-mode.q-modecard[aria-labelledby=policy-mode-h]")
      assert text(view, "h2#policy-mode-h") == "Mode : Set per workspace"
      assert has_element?(view, "#policy-mode-h .sr-only", ":")

      assert sentence(view, "#policy-mode-effect") ==
               "Each workspace's mode holds, and a repository's override where it has one."

      assert has_element?(
               view,
               "button#policy-mode-change[aria-controls=policy-mode-form][aria-expanded=false]",
               "Change mode"
             )

      refute has_element?(view, "#policy-mode-form")
    end

    test "the mode is changed in the card: a pick only selects, and the button that names it saves",
         ctx do
      # Main enforces of itself; Platform observes.
      {:ok, _} = Policy.set_mode(ctx.owner, "enforce")
      view = open(ctx.conn, policy_path(ctx))

      view |> element("#policy-mode-change") |> render_click()
      assert_push_event(view, "policy:focus", %{id: "policy-mode-opt-own"})
      # The choices open in the card, never over the page, as native radios.
      refute has_element?(view, "#policy-mode-change")
      refute has_element?(view, "#main dialog, #main [role=dialog]")

      assert has_element?(
               view,
               "#policy-mode form#policy-mode-form[phx-change=mode_pick][phx-submit=mode_set] fieldset legend#policy-mode-legend",
               "Choose the mode of Example Co's workspaces"
             )

      assert has_element?(view, "input#policy-mode-opt-own[type=radio][name=mode][checked]")
      assert has_element?(view, "input#policy-mode-opt-enforce[type=radio][name=mode]")
      refute has_element?(view, "input#policy-mode-opt-enforce[checked]")
      assert text(view, "#policy-mode-opt-own-h") =~ "Each workspace chooses"
      assert text(view, "#policy-mode-opt-own-h") =~ "Current"
      assert text(view, "#policy-mode-opt-enforce-h") == "Enforce in every workspace"

      assert text(view, "#policy-mode-opt-enforce-p") ==
               "No workspace or repository may observe: a connection no rule allows is denied everywhere."

      # The pick is the mode now: no question, only Cancel.
      assert text(view, "#policy-mode-now") == "The mode is set per workspace now."
      refute has_element?(view, "#policy-mode-set")
      assert has_element?(view, "button#policy-mode-cancel[type=button][phx-click=mode_cancel]")

      # A pick only selects: the question shows under the choices, and nothing is saved.
      view |> element("#policy-mode-form") |> render_change(%{"mode" => "enforce"})
      refute floor?(ctx)
      assert has_element?(view, "input#policy-mode-opt-enforce[checked]")
      assert text(view, "h3#policy-mode-q") == "Require enforce in every workspace?"
      assert has_element?(view, ".q-modeask[role=group][aria-labelledby=policy-mode-q]")

      assert text(view, "#policy-mode-q-effect") ==
               "No workspace or repository may observe from now on: a connection no rule allows is denied everywhere, and their mode reads Enforce, required by Example Co."

      # What it changes, a line a workspace that observes now.
      assert text(view, "#policy-mode-preview") == "Platform enforces from now on."

      assert text(view, "#policy-mode-form") =~
               "Each workspace whose policy this changes gets a new version of it."

      # The button names the pick, and is never red.
      assert text(view, "#policy-mode-set") =~ "Require enforce"

      assert has_element?(
               view,
               "button#policy-mode-set[type=submit].btn-primary .btn-busy",
               "Setting"
             )

      refute has_element?(view, "#policy-mode-set.btn-error")

      view |> element("#policy-mode-form") |> render_submit()
      refute has_element?(view, "#policy-mode-form")
      assert has_element?(view, "#policy-mode-change")
      assert_push_event(view, "policy:focus", %{id: "policy-mode-change"})
      assert text(view, "#policy-mode-value") == "Enforce required"
      assert has_element?(view, "#policy-mode[data-mode=enforce]")
      assert render(view) =~ "Enforce is required in every workspace."
      assert text(view, "#policy-announce") =~ "Floor changed."

      assert sentence(view, "#policy-mode-effect") ==
               "No workspace or repository may observe: a connection no rule allows is denied everywhere. Their mode reads Enforce, required by Example Co."

      assert %{mode: "enforce", mode_source: :organisation} = Policy.effective(ctx.owner, nil)
      assert %{mode: "enforce"} = Policy.effective(ctx.in_platform, nil)
      assert text(view, "#policy-tabs-history") == "History 1"

      # Back: the question, its button primary too, then saved.
      view |> element("#policy-mode-change") |> render_click()
      assert has_element?(view, "input#policy-mode-opt-enforce[checked]")
      assert text(view, "#policy-mode-now") == "Enforce is required in every workspace now."
      view |> element("#policy-mode-form") |> render_change(%{"mode" => "own"})
      assert text(view, "h3#policy-mode-q") == "Stop requiring enforce in every workspace?"
      assert text(view, "#policy-mode-preview") == "Platform observes again."
      assert text(view, "#policy-mode-set") =~ "Stop requiring enforce"
      assert has_element?(view, "#policy-mode-set.btn-primary")
      refute has_element?(view, "#policy-mode-set.btn-error")
      view |> element("#policy-mode-form") |> render_submit()
      assert text(view, "#policy-mode-value") == "Set per workspace"
      assert %{mode: "enforce"} = Policy.effective(ctx.owner, nil)
      assert %{mode: "observe"} = Policy.effective(ctx.in_platform, nil)
    end

    test "Cancel closes the card's choices and saves nothing; the card stays open across tabs",
         ctx do
      view = open(ctx.conn, policy_path(ctx))
      view |> element("#policy-mode-change") |> render_click()
      view |> element("#policy-mode-form") |> render_change(%{"mode" => "enforce"})

      # Above the tabs, the choices stay open on another tab.
      view |> element("#policy-tabs-workspaces") |> render_click()
      assert has_element?(view, "input#policy-mode-opt-enforce[checked]")

      view |> element("#policy-mode-cancel") |> render_click()
      refute has_element?(view, "#policy-mode-form")
      assert has_element?(view, "#policy-mode-change")
      refute floor?(ctx)

      # Escape sends the same event (the core's PolicyPage hook, on the page's root).
      assert has_element?(view, "#organisation-policy[phx-hook=PolicyPage]")
      view |> element("#policy-mode-change") |> render_click()
      render_hook(view, "mode_cancel", %{})
      refute has_element?(view, "#policy-mode-form")
    end

    test "a refusal keeps the card open, its reason under the question as an alert", ctx do
      second = ApiaryWeb.RefusalsCase.person(ctx.owner, :owner)
      view = open(log_in_user(ctx.conn, second.user), policy_path(ctx))
      view |> element("#policy-mode-change") |> render_click()
      view |> element("#policy-mode-form") |> render_change(%{"mode" => "enforce"})

      # Made an admin while the page is open.
      ApiaryWeb.RefusalsCase.put_level(second, :admin)
      view |> element("#policy-mode-form") |> render_submit()

      refute floor?(ctx)
      assert has_element?(view, "input#policy-mode-opt-enforce[checked]")
      assert has_element?(view, ".q-modeask #policy-mode-error[role=alert]")

      assert text(view, "#policy-mode-error") ==
               "Only an owner changes the organisation's policy."

      # The focus goes to the button that names the pick.
      assert_push_event(view, "policy:focus", %{id: "policy-mode-set"})
      assert has_element?(view, "#policy-mode-set")
      refute has_element?(view, "#policy-write-error")

      # A new pick, or Cancel, clears it.
      view |> element("#policy-mode-form") |> render_change(%{"mode" => "own"})
      refute has_element?(view, "#policy-mode-error")
    end

    test "the switch says where no workspace allows a host of its own, with no counts", ctx do
      view = open(ctx.conn, policy_path(ctx))
      refute has_element?(view, "#policy-switch-counts")

      assert sentence(view, "#policy-switch-switch-description") ==
               "Workspace and repository allows are in force beside the hosts allowed below. Turning this off would put them out of force, leaving only those hosts allowed anywhere; their denies would still hold."

      view |> element("#policy-switch-switch") |> render_click()
      view |> element("#policy-setting-confirm-button") |> render_click()
      render_async(view)
      refute has_element?(view, "#policy-switch-counts")

      assert sentence(view, "#policy-switch-switch-description") ==
               "Only the hosts allowed below are allowed anywhere. Workspace and repository allows stay listed, and are not in force; their denies still hold."
    end

    test "the switch's sentence and its confirm count the allows it leaves out of force", ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "img.example"})
      {:ok, _} = Policy.allow(ctx.in_platform, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.deny(ctx.in_platform, nil, %{host: "tracker.example"})

      view = open(ctx.conn, policy_path(ctx))
      assert text(view, "#policy-switch-counts") == "2 in Main, 1 in Platform"

      # On, its sentence says what holds now and what turning it off would leave out.
      assert sentence(view, "#policy-switch-switch-description") ==
               "Workspace and repository allows are in force beside the hosts allowed below. Turning this off would put them out of force (2 in Main, 1 in Platform), leaving only those hosts allowed anywhere; their denies would still hold."

      view |> element("#policy-switch-switch") |> render_click()
      assert has_element?(view, "#policy-switch #policy-setting-confirm")
      assert text(view, "#policy-setting-confirm") =~ "Allow only the organisation's hosts"

      assert text(view, "#policy-setting-leaves") ==
               "It leaves 3 allows out of force: 2 in Main, 1 in Platform."

      assert has_element?(view, "#policy-setting-confirm-button.btn-primary")

      view |> element("#policy-setting-confirm-button") |> render_click()
      render_async(view)
      assert has_element?(view, "#policy-switch-switch[aria-checked=false]")
      assert text(view, "#policy-switch-counts") == "2 in Main, 1 in Platform"

      # Off, it says the allows are out of force now.
      assert sentence(view, "#policy-switch-switch-description") ==
               "Only the hosts allowed below are allowed anywhere. Workspace and repository allows stay listed, and are not in force (2 in Main, 1 in Platform); their denies still hold."

      # Turned back on, the confirm says what comes back.
      view |> element("#policy-switch-switch") |> render_click()

      assert text(view, "#policy-setting-back") ==
               "It puts 3 allows back in force: 2 in Main, 1 in Platform, but where Example Co denies the host."

      assert text(view, "#policy-setting-confirm-button") =~ "Let workspaces allow hosts"
      # Loosening is never red: either way can be turned back.
      assert has_element?(view, "#policy-setting-confirm-button.btn-primary")
      refute has_element?(view, "#policy-setting-confirm-button.btn-error")
      # Cancel gives the focus back to the switch, and asks nothing more.
      view |> element("#policy-setting-confirm-cancel") |> render_click()
      refute has_element?(view, "#policy-setting-confirm")

      effective = Policy.effective(ctx.in_platform, nil)
      assert effective.allow == []
      assert effective.deny == ["tracker.example"]
    end

    test "an admin reads, and changes nothing", ctx do
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      view = open(log_in_user(ctx.conn, ctx.admin.user), policy_path(ctx))

      assert hosts(view) == ["api.example"]
      refute has_element?(view, "#policy-rules-add")
      api = row(view, "api.example")
      refute has_element?(view, "##{api}-menu")
      assert has_element?(view, "#policy-switch-switch[disabled]")
      refute has_element?(view, "#policy-switch-switch[phx-click]")

      # The mode card: the same card, with no Change mode, and who changes it.
      assert text(view, "#policy-mode-value") == "Set per workspace"
      refute has_element?(view, "#policy-mode-change")

      assert text(view, "#policy-mode-owners") ==
               "Only an owner changes the organisation's policy."

      # It says who changes it, in words, where the switch is dimmed.
      assert has_element?(view, "#policy-owners.text-muted")

      assert text(view, "#policy-owners") ==
               "Only owners of Example Co change its policy: these settings and its rules."

      render_hook(view, "mode_open", %{})
      refute has_element?(view, "#policy-mode-form")
      assert text(view, "#policy-write-error") =~ "Only an owner changes"

      render_hook(view, "mode_set", %{})
      render_hook(view, "switch_ask", %{})
      refute has_element?(view, "#policy-setting-confirm")
      render_hook(view, "setting_confirm", %{})

      assert {:ok, %{policy: %{enforce_everywhere: false, own_allows: true}}} =
               OrganisationPolicy.get(ctx.owner)

      # A hand-made save is refused, and nothing is written.
      render_hook(view, "rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}})
      render_hook(view, "rule_save", %{})
      assert {:ok, %{rules: [_one]}} = OrganisationPolicy.get(ctx.owner)
      assert text(view, "#flash-error") == "You can read this policy but not change it."

      # With the floor on, on any tab: the card says so, and still offers no change.
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)
      view = open(log_in_user(ctx.conn, ctx.admin.user), policy_path(ctx, "/workspaces"))
      assert text(view, "#policy-mode-value") == "Enforce required"
      refute has_element?(view, "#policy-mode-change")

      assert sentence(view, "#policy-mode-effect") ==
               "No workspace or repository may observe: a connection no rule allows is denied everywhere. Their mode reads Enforce, required by Example Co. Only an owner changes the organisation's policy."
    end

    test "?rule= lands on the rule", ctx do
      {:ok, rule} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})

      view = open(ctx.conn, policy_path(ctx, "?rule=paste.example"))
      assert has_element?(view, "#rule-#{rule.id}.q-ruled")
    end

    test "New rule from a workspace's page has the host filled in, and the list it goes back to offers the way back, the rule marked",
         ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      network = "/#{ctx.organisation.slug}/#{ctx.main.slug}/network"
      # What the link carries beside the page does not ride along on the way back.
      back = network <> "?decision=denied#top"

      view =
        open(
          ctx.conn,
          policy_path(ctx, "/rules/new?" <> URI.encode_query(%{host: "new.example", back: back}))
        )

      assert has_element?(view, "#policy-rule-title", "New rule")
      assert has_element?(view, "#policy-rule-allow[checked]")
      assert has_element?(view, "#policy-rule-host[value=\"new.example\"]")
      assert read(view, "#policy-rule-reads") =~ "Allow new.example"
      assert_push_event(view, "policy:focus", %{id: "policy-rule-allow"})

      add(view)
      assert_patch(view, policy_path(ctx, "?rule=new.example"))
      new = row(view, "new.example")
      assert has_element?(view, "##{new}.q-ruled")

      assert has_element?(
               view,
               "#policy-rules-head #policy-back.q-sect-link[href=\"#{network}\"]",
               "Back to Main › Network access"
             )

      # A host with a rule already: the form says so, and adds nothing.
      view =
        open(
          ctx.conn,
          policy_path(
            ctx,
            "/rules/new?" <>
              URI.encode_query(%{
                host: "paste.example",
                back: "/#{ctx.organisation.slug}/#{ctx.main.slug}"
              })
          )
        )

      assert has_element?(view, "#policy-rule-host[value=\"paste.example\"]")
      type(view, %{action: "deny", host: "paste.example"})

      assert text(view, "#policy-rule-reads") ==
               "Nothing new: this rule is already in the list. To change its paths, edit it from its row."

      assert text(view, "#policy-rule-host-error") =~
               "paste.example is already denied for every workspace"

      add(view)
      assert has_element?(view, "#policy-rule-title", "New rule")
      assert {:ok, %{rules: rules}} = OrganisationPolicy.get(ctx.owner)

      assert Enum.map(rules, &{&1.host, &1.action}) == [
               {"new.example", "allow"},
               {"paste.example", "deny"}
             ]

      view |> element("#policy-rule-save-cancel") |> render_click()
      assert has_element?(view, "#policy-back", "Back to Main › Overview")

      # An admin is sent back to the list, told why, with the way back.
      view =
        open(
          log_in_user(ctx.conn, ctx.admin.user),
          policy_path(ctx, "/rules/new?" <> URI.encode_query(%{host: "new.example", back: back}))
        )

      assert text(view, "#flash-error") == "You can read this policy but not change it."
      refute has_element?(view, "#policy-rule-form")
      assert has_element?(view, "#policy-rules")
      assert has_element?(view, "#policy-back", "Back to Main › Network access")
    end

    test "?back= is offered only for a page of a workspace here", ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      network = "/#{ctx.organisation.slug}/#{ctx.main.slug}/network"

      # Network access narrowed to a target the workspace has, as the page writes its own
      # address: the target's id alone, the list's other filters left behind.
      target = fn organisation_id, workspace_id, system ->
        Apiary.Repo.insert!(%Apiary.Runs.Target{
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          system: system,
          path: "acme/api",
          first_seen_at: DateTime.utc_now()
        })
      end

      github = target.(ctx.organisation.id, ctx.main.id, "github")
      back_of = fn params -> network <> "?" <> URI.encode_query(params) end

      view_back = fn back ->
        open(
          ctx.conn,
          policy_path(ctx, "?" <> URI.encode_query(%{rule: "paste.example", back: back}))
        )
      end

      view = view_back.(back_of.(%{target: github.public_id, decision: "denied"}) <> "#top")

      assert has_element?(
               view,
               "#policy-back[href=\"#{back_of.(%{target: github.public_id})}\"]",
               "Back to Main › acme/api › Network access"
             )

      # Where another system has the same path, each target is still its id, named by its
      # path.
      gitlab = target.(ctx.organisation.id, ctx.main.id, "gitlab")
      view = view_back.(back_of.(%{target: gitlab.public_id}))

      assert has_element?(
               view,
               "#policy-back[href=\"#{back_of.(%{target: gitlab.public_id})}\"]",
               "Back to Main › acme/api › Network access"
             )

      # Another workspace's target, here or in another organisation, is not reached by its
      # id, nor is an id that names no target.
      platform = target.(ctx.organisation.id, ctx.platform.id, "github")
      %{organisation: elsewhere, workspace: theirs} = sign_up_fixture()
      theirs = target.(elsewhere.id, theirs.id, "github")

      # A way back that is not a page of a workspace here is not offered: nor a target the
      # workspace does not have, whatever its address says, nor an address of the older
      # form (a path, or a system and a path), several targets, the runs with none, or a
      # typed name. The page opens all the same.
      for elsewhere <- [
            back_of.(%{target: platform.public_id}),
            back_of.(%{target: theirs.public_id}),
            back_of.(%{target: "tg_0000000000000000"}),
            back_of.(%{target: "acme/api"}),
            back_of.(%{system: "github", target: "acme/api"}),
            back_of.(%{target: "acme/Back to the bank"}),
            back_of.(%{system: "bitbucket", target: "acme/api"}),
            back_of.(%{target: "#{github.public_id},acme/api"}),
            back_of.(%{target: "#{github.public_id},#{gitlab.public_id}"}),
            back_of.(%{target: "none"}),
            back_of.(%{q: "target:acme/api"}),
            "https://evil.example/",
            "//evil.example/x",
            "/other-org/main/network",
            "/#{ctx.organisation.slug}/main/settings",
            "/#{ctx.organisation.slug}/main/targets/#{github.public_id}",
            "/#{ctx.organisation.slug}/main/targets/#{github.public_id}/policy"
          ] do
        view = view_back.(elsewhere)
        assert has_element?(view, "#policy-rules")
        refute has_element?(view, "#policy-back")
      end
    end
  end

  describe "New rule and Edit rule" do
    test "Add rule is the Network access section's primary button, and a row's Edit leads to its page",
         ctx do
      {:ok, allow} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, deny} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      view = open(ctx.conn, policy_path(ctx))

      assert has_element?(view, "#policy-hosts[aria-labelledby=policy-hosts-h]")
      assert has_element?(view, "#policy-rules-head h2#policy-hosts-h", "Network access")
      assert text(view, "#policy-rules-count") == "2 rules"

      assert has_element?(
               view,
               "#policy-rules-head a#policy-rules-add.btn-primary[href='#{policy_path(ctx, "/rules/new")}']",
               "Add rule"
             )

      refute has_element?(view, "#policy-rules-bar #policy-rules-add")

      assert text(view, "#policy-rules-line") ==
               "The hosts the runs of every workspace of Example Co may reach, and those they may not."

      for rule <- [allow, deny] do
        assert has_element?(
                 view,
                 "#rule-#{rule.id}-edit[href='#{policy_path(ctx, "/rules/#{rule.id}/edit")}']",
                 "Edit"
               )
      end

      refute render(view) =~ "Edit paths"
    end

    test "New rule: the form alone under Policy › New rule, read back for every workspace",
         ctx do
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "registry.example"})
      view = open(ctx.conn, policy_path(ctx, "?sort=host"))
      view |> element("#policy-rules-add") |> render_click()
      assert_patch(view, policy_path(ctx, "/rules/new"))

      assert crumbs(view, :organisation) == [
               {"Policy", policy_path(ctx, "?sort=host")},
               {"New rule", nil}
             ]

      assert page_title(view) =~ "New rule · Policy · Example Co"
      assert has_element?(view, "h1#policy-rule-title", "New rule")

      assert text(view, ".q-page-desc") ==
               "Let the runs of every workspace of Example Co reach a host, or stop them reaching it. A deny here holds in every workspace and repository; an allow reaches every workspace, and a workspace or a repository may still deny it."

      refute has_element?(view, "#policy-rules")
      refute has_element?(view, "#policy-tabs")
      refute has_element?(view, "#policy-mode")
      refute has_element?(view, "#policy-back")
      assert has_element?(view, "#policy-rule-add[type=submit]", "Add rule")

      assert has_element?(
               view,
               "a#policy-rule-save-cancel[href='#{policy_path(ctx, "?sort=host")}']",
               "Cancel"
             )

      # Read back for every workspace: an allow, a deny, the same rule, its opposite.
      type(view, %{host: "api.example", paths: "/v1/*"})
      assert read(view, "#policy-rule-reads") =~ "Allow api.example on 1 path"

      type(view, %{action: "deny", host: "telemetry.example"})

      assert read(view, "#policy-rule-reads") =~
               "Deny telemetry.example. It holds in every workspace and repository, and no rule of theirs can allow it."

      type(view, %{action: "allow"})
      type(view, %{host: "registry.example", paths: ""})

      assert text(view, "#policy-rule-host-error") =~
               "registry.example is already allowed for every workspace"

      type(view, %{action: "deny", host: "registry.example"})

      assert read(view, "#policy-rule-reads") ==
               "registry.example is allowed for every workspace. Adding this deny replaces that rule."

      assert text(view, "#policy-rule-add") == "Replace with deny"
      add(view)

      assert_patch(view, policy_path(ctx, "?rule=registry.example&sort=host"))
      assert {:ok, %{rules: [%{action: "deny"}]}} = OrganisationPolicy.get(ctx.owner)
      assert text(view, "#flash-info") =~ "registry.example is denied for every workspace."
      assert has_element?(view, "#policy-rules tr.q-ruled", "registry.example")
      assert text(view, "#policy-announce") =~ "Rule added."
    end

    test "New rule writes an allow held to paths, and Every path opens one held", ctx do
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["/v1/*"]})
      view = open(ctx.conn, policy_path(ctx, "/rules/new"))

      type(view, %{host: "api.example", paths: ""})

      assert read(view, "#policy-rule-paths-error") =~
               "api.example is held to /v1/* for every workspace."

      view |> element("#policy-rule-paths-error button", "Every path") |> render_click()
      assert text(view, "#policy-rule-add") == "Change paths"
      add(view)

      assert {:ok, %{rules: [%{host: "api.example", paths: nil}]}} =
               OrganisationPolicy.get(ctx.owner)
    end

    @tag with_features: Features.all() -- [:path_rules]
    test "New rule and Edit rule draw no Paths field where the instance has path rules off",
         ctx do
      {:ok, rule} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})

      for rest <- ["/rules/new", "/rules/#{rule.id}/edit"], action <- ~w(allow deny) do
        view = open(ctx.conn, policy_path(ctx, rest))
        assert has_element?(view, "#policy-rule-form")

        type(view, %{action: action})
        assert has_element?(view, "#policy-rule-#{action}[checked]")
        refute has_element?(view, "label[for=policy-rule-paths]")
        refute has_element?(view, "#policy-rule-paths")
      end
    end

    test "a pasted list fills Host with the first and counts the rest", ctx do
      view = open(ctx.conn, policy_path(ctx, "/rules/new"))
      render_hook(view, "rule_paste", %{"hosts" => ["a.example", "b.example"]})
      assert text(view, "#policy-rule-queued") == "1 more to add"
      assert has_element?(view, "#policy-rule-host[value='a.example']")

      add(view)
      assert has_element?(view, "#policy-rule-host[value='b.example']")
      assert text(view, "#flash-info") =~ "a.example is allowed for every workspace."

      add(view)
      assert_patch(view, policy_path(ctx, "?rule=b.example"))
      assert {:ok, %{rules: [_, _]}} = OrganisationPolicy.get(ctx.owner)
    end

    test "Cancel goes back to the list as it was left, and saves nothing", ctx do
      view = open(ctx.conn, policy_path(ctx, "?view=denied"))
      view |> element("#policy-rules-add") |> render_click()
      type(view, %{host: "api.example", paths: ""})

      view |> element("#policy-rule-save-cancel") |> render_click()
      assert_patch(view, policy_path(ctx, "?view=denied"))
      assert has_element?(view, "#policy-rules")
      assert {:ok, %{rules: []}} = OrganisationPolicy.get(ctx.owner)
    end

    test "Edit rule: an allow's paths, and a deny's Allow, saved for every workspace", ctx do
      {:ok, allow} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, deny} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      view = open(ctx.conn, policy_path(ctx))

      view |> element("#rule-#{allow.id}-edit") |> render_click()
      assert_patch(view, policy_path(ctx, "/rules/#{allow.id}/edit"))
      assert crumbs(view, :organisation) == [{"Policy", policy_path(ctx)}, {"Edit rule", nil}]
      assert page_title(view) =~ "Edit rule · Policy · Example Co"
      assert has_element?(view, "h1#policy-rule-title", "Edit the rule for api.example")

      assert text(view, ".q-page-desc") ==
               "Change what the runs of every workspace of Example Co may do with api.example. The host stays; to rule on another host, add a new rule."

      assert text(view, "#policy-rule-host-shown") == "api.example"
      assert has_element?(view, "#policy-rule-paths[value='/v1/*']")

      type(view, %{paths: "/v1/* /v2/*"})

      assert text(view, "#policy-rule-reads") ==
               "api.example is allowed for every workspace on /v1/* . Saving changes its paths to /v1/* /v2/* ."

      assert text(view, "#policy-rule-add") == "Change paths"
      add(view)
      assert_patch(view, policy_path(ctx, "?rule=api.example"))

      assert {:ok, %{rules: [%{host: "api.example", paths: ["/v1/*", "/v2/*"]}, _deny]}} =
               OrganisationPolicy.get(ctx.owner)

      view = open(ctx.conn, policy_path(ctx, "/rules/#{deny.id}/edit"))
      assert has_element?(view, "#policy-rule-deny[checked]")
      type(view, %{action: "allow"})
      assert text(view, "#policy-rule-add") == "Replace with allow"
      add(view)

      assert_patch(view, policy_path(ctx, "?rule=paste.example"))
      assert text(view, "#flash-info") =~ "paste.example is allowed for every workspace."

      assert {:ok, %{rules: [_api, %{host: "paste.example", action: "allow"}]}} =
               OrganisationPolicy.get(ctx.owner)
    end

    test "Edit rule of a rule that is gone leads back to the list, saying so", ctx do
      {:ok, rule} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      {:ok, _} = OrganisationPolicy.remove_rule(ctx.owner, rule.id)

      for id <- [rule.id, Ecto.UUID.generate()] do
        view = open(ctx.conn, policy_path(ctx, "/rules/#{id}/edit"))
        refute has_element?(view, "#policy-rule-form")
        assert has_element?(view, "#policy-rules")
        assert text(view, "#flash-error") == "The organisation's policy has no such rule."
      end
    end

    test "a crafted Edit paths on the list leads to Edit rule only for a rule id", ctx do
      {:ok, rule} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      view = open(ctx.conn, policy_path(ctx))

      render_hook(view, "edit_paths", %{"id" => rule.id})
      assert_patch(view, policy_path(ctx, "/rules/#{rule.id}/edit"))

      view = open(ctx.conn, policy_path(ctx))

      for bad <- [%{}, %{"id" => 7}, %{"id" => "../x"}, %{"id" => "x?y=1"}] do
        render_hook(view, "edit_paths", bad)
        assert has_element?(view, "#policy-rules")
      end
    end

    test "what the domain refuses stays on the form, above the foot, until it is edited",
         ctx do
      # Platform's rules cannot resolve with an allow of the organisation's.
      {:ok, _} = Policy.allow(ctx.in_platform, nil, %{host: "*.example", paths: ["/v1/*"]})
      view = open(ctx.conn, policy_path(ctx, "/rules/new"))

      type(view, %{host: "api.example", paths: ""})
      add(view)

      assert text(view, "#policy-rule-write-error") =~ "In Platform:"
      assert has_element?(view, "#policy-rule-title", "New rule")
      refute has_element?(view, "#policy-rule-preview")
      assert {:ok, %{rules: []}} = OrganisationPolicy.get(ctx.owner)

      html = render(view)

      assert :binary.match(html, ~s(id="policy-rule-write-error")) <
               :binary.match(html, ~s(id="policy-rule-save"))

      # Edited again, the read-back is back and the refusal gone.
      type(view, %{host: "api.example", paths: "/v1/*"})
      refute has_element?(view, "#policy-rule-write-error")
      assert has_element?(view, "#policy-rule-preview")

      # Cancel leaves the refusal on the form.
      add(view)
      assert has_element?(view, "#policy-rule-write-error")
      view |> element("#policy-rule-save-cancel") |> render_click()
      refute has_element?(view, "#policy-write-error")
    end

    test "an admin sees no Add rule and no Edit, and is sent back from the form's addresses",
         ctx do
      admin = log_in_user(ctx.conn, ctx.admin.user)
      view = open(admin, policy_path(ctx))
      refute has_element?(view, "#policy-rules-add")
      assert text(view, "#policy-rules") =~ "No rules yet."
      refute text(view, "#policy-rules") =~ "Add the first"

      {:ok, rule} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})

      for rest <- ["/rules/new", "/rules/#{rule.id}/edit"] do
        view = open(admin, policy_path(ctx, rest))
        assert text(view, "#flash-error") == "You can read this policy but not change it."
        refute has_element?(view, "#policy-rule-form")
        assert has_element?(view, "#policy-rules")
      end

      refute has_element?(view, "#rule-#{rule.id}-edit")

      # A hand-made save, the form's or the composer's, writes nothing.
      for {change, save} <- [{"rule_validate", "rule_save"}, {"composer_change", "composer_save"}] do
        render_hook(view, change, %{"rule" => %{"host" => "crafted.example", "paths" => ""}})
        render_hook(view, save, %{})
      end

      assert Process.alive?(view.pid)
      assert {:ok, %{rules: [%{host: "api.example"}]}} = OrganisationPolicy.get(ctx.owner)
    end

    test "New on the organisation's pages offers a network access rule to an owner only",
         ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/#{ctx.organisation}/settings")

      assert has_element?(
               view,
               "#new-menu a#new-menu-organisation_rule[href='#{policy_path(ctx, "/rules/new")}']",
               "Network access rule"
             )

      # Not on a workspace's pages, where New offers the workspace's.
      {:ok, view, _html} = live(ctx.conn, ~p"/#{ctx.organisation}/#{ctx.main}")
      refute has_element?(view, "#new-menu-organisation_rule")
      assert has_element?(view, "#new-menu-rule")

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.admin.user), ~p"/#{ctx.organisation}/settings")

      refute has_element?(view, "#new-menu-organisation_rule")
    end

    test "the operator of a client changes its rules only while the operator owns it" do
      ApiaryPro.Flags.put_operator_infrastructure(false)
      operator = ApiaryPro.OperatorsFixtures.operator_fixture()
      client = ApiaryPro.OperatorsFixtures.client_fixture(operator.scope)
      conn = log_in_user(build_conn(), operator.user)
      path = "/#{client.organisation.slug}/policy"

      # Off: the operator's people read the client, and change nothing.
      view = open(conn, path)
      refute has_element?(view, "#policy-rules-add")
      view = open(conn, path <> "/rules/new")
      assert text(view, "#flash-error") == "You can read this policy but not change it."
      {:ok, view, _html} = live(conn, ~p"/#{client.organisation}/settings")
      refute has_element?(view, "#new-menu-organisation_rule")

      # On: the operator's owner changes them, as the client's owner.
      ApiaryPro.Flags.put_operator_infrastructure(true)
      view = open(conn, path)
      assert has_element?(view, "#policy-rules-add")
      view = open(conn, path <> "/rules/new?host=api.example")
      type(view, %{host: "api.example", paths: ""})
      add(view)
      assert_patch(view, path <> "?rule=api.example")

      assert {:ok, %{rules: [%{host: "api.example"}]}} = OrganisationPolicy.get(client.scope)

      {:ok, view, _html} = live(conn, ~p"/#{client.organisation}/settings")
      assert has_element?(view, "#new-menu-organisation_rule")
    end

    test "while the operator owns its client, the client's owner reads its policy, told who changes it" do
      ApiaryPro.Flags.put_operator_infrastructure(false)
      operator = ApiaryPro.OperatorsFixtures.operator_fixture(%{organisation_name: "Hive Ops"})
      client = ApiaryPro.OperatorsFixtures.client_fixture(operator.scope, "Acme")
      operator_admin = member_fixture(operator.scope, :admin)
      {:ok, rule} = OrganisationPolicy.allow(client.owner.scope, %{host: "api.example"})
      ApiaryPro.Flags.put_operator_infrastructure(true)

      owner = client.owner.scope
      conn = log_in_user(build_conn(), client.owner.user)
      path = "/#{client.organisation.slug}/policy"
      only = "Only owners of Hive Ops, the operator of Acme, change its policy."

      # The owner made while the flag was off reads it, and changes nothing.
      view = open(conn, path)
      refute has_element?(view, "#policy-rules-add")
      refute has_element?(view, "##{row(view, "api.example")}-menu")
      assert has_element?(view, "#policy-switch-switch[disabled]")
      refute has_element?(view, "#policy-mode-change")

      assert text(view, "#policy-owners") ==
               "Only owners of Hive Ops, the operator of Acme, change its policy: these settings and its rules."

      assert text(view, "#policy-mode-owners") == only

      # A crafted change is refused in the same words.
      for event <- ["mode_open", "switch_ask"] do
        render_hook(view, event, %{})
        assert text(view, "#policy-write-error") == only, event
      end

      # And by the policy itself.
      for refused <- [
            OrganisationPolicy.set_floor(owner, true),
            OrganisationPolicy.set_switch(owner, false),
            OrganisationPolicy.deny(owner, %{host: "paste.example"}),
            OrganisationPolicy.remove_rule(owner, rule)
          ] do
        assert {:error, %Policy.Error{reason: :forbidden, message: ^only}} = refused
      end

      assert {:ok, %{policy: %{enforce_everywhere: false, own_allows: true}, rules: [%{id: id}]}} =
               OrganisationPolicy.get(owner)

      assert id == rule.id

      # New rule sends them back, and New offers no network access rule.
      view = open(conn, path <> "/rules/new")
      assert text(view, "#flash-error") == "You can read this policy but not change it."
      refute has_element?(view, "#policy-rule-form")
      {:ok, view, _html} = live(conn, ~p"/#{client.organisation}/settings")
      refute has_element?(view, "#new-menu-organisation_rule")

      # The operator's admin is told the same.
      view = open(log_in_user(build_conn(), operator_admin.user), path)
      refute has_element?(view, "#policy-rules-add")
      assert text(view, "#policy-mode-owners") == only

      # With the flag off, the client's owner changes it, as before.
      ApiaryPro.Flags.put_operator_infrastructure(false)
      view = open(conn, path)
      assert has_element?(view, "#policy-rules-add")
      assert has_element?(view, "#policy-mode-change")
      refute has_element?(view, "#policy-owners")
      {:ok, view, _html} = live(conn, ~p"/#{client.organisation}/settings")
      assert has_element?(view, "#new-menu-organisation_rule")
    end
  end

  describe "the Workspaces tab" do
    test "lists each workspace with its mode, its own rules, its allows not in force and its version",
         ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)

      view = open(ctx.conn, policy_path(ctx, "/workspaces"))
      main = ctx.main.id
      platform = ctx.platform.id

      assert has_element?(view, "#policy-workspace-#{main}-link", "Main")
      assert text(view, "#policy-workspace-#{main}-mode") == "Enforce"
      assert text(view, "#policy-workspace-#{main}-own") == "2 rules"
      assert text(view, "#policy-workspace-#{main}-off") == "1 allow"
      assert text(view, "#policy-workspace-#{platform}-own") == "0 rules"
      assert text(view, "#policy-workspace-#{platform}-off") == "none"

      # The workspace's name is the way to its policy; the row has no other link.
      assert has_element?(
               view,
               "#policy-workspace-#{platform}-link.q-title[href='#{~p"/#{ctx.organisation}/#{ctx.platform}/policy"}']"
             )

      refute has_element?(view, "#policy-workspace-#{platform}-open")

      # Beside the name, the workspace's address under the organisation's, not its slug.
      address = ~p"/#{ctx.organisation}/#{ctx.platform}"
      assert text(view, "#policy-workspace-#{platform}") =~ address
      assert has_element?(view, "#policy-workspace-#{platform} [title='#{address}']")

      # Each tab names itself in the browser's title.
      view |> element("#policy-tabs-history") |> render_click()
      assert has_element?(view, "#policy-tabs-history[aria-current=page]")
      assert page_title(view) =~ "History · Policy"
      view |> element("#policy-tabs-workspaces") |> render_click()
      assert page_title(view) =~ "Workspaces · Policy"

      assert text(view, "#policy-workspaces") =~ "v5"
      assert text(view, "#policy-workspaces-note") =~ "narrow Example Co's"
    end
  end

  describe "the History tab" do
    test "lists each change with who, what and the workspaces it rendered again", ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)
      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, false)

      view = open(ctx.conn, policy_path(ctx, "/history"))
      # The reader's letter, then the address in hidden text: a row's text runs them in.
      email = ctx.owner.user.email
      who = "#{String.upcase(String.first(email))}#{email} (you)"

      [switch, floor, allow, deny] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#policy-history tr")
        |> Enum.map(&(LazyHTML.text(&1) |> String.replace(~r/\s+/, " ") |> String.trim()))

      # The switch struck Main's cdn.example; Platform allows nothing of its own.
      assert switch =~ "#{who} turned off “Workspaces may allow more hosts”"
      assert switch =~ "Main v6"
      refute switch =~ "Platform"
      assert floor =~ "#{who} required enforce in every workspace"
      assert floor =~ "Main v5 · Platform v4"
      # Main allowed api.example already: the same bytes, so no new version there.
      assert allow =~ "#{who} allowed api.example"
      assert allow =~ "Platform v3"
      refute allow =~ "Main v"
      assert deny =~ "#{who} denied paste.example"
      assert deny =~ "Main v4 · Platform v2"

      # Narrow, the workspaces rendered again give way first; the time always shows.
      headers =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".q-tbl:has(#policy-history) th")
        |> Enum.map(&{String.trim(LazyHTML.text(&1)), LazyHTML.attribute(&1, "class")})

      assert [{"Change", _}, {"Rendered again", [rendered]}, {"When", [when_class]}] = headers
      assert rendered =~ "q-from-md"
      refute when_class =~ "q-from-"

      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, true)
      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, false)
      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, true)
      view = open(ctx.conn, policy_path(ctx, "/history"))
      assert text(view, "#policy-tabs-history") == "History 7"
    end

    test "is empty until the first change", ctx do
      view = open(ctx.conn, policy_path(ctx, "/history"))
      assert has_element?(view, "#policy-history-empty")
    end

    test "a row's one letter is its subject, a tab stop, the address its hint", ctx do
      co_owner = member_fixture(ctx.owner, :owner)
      gone = member_fixture(ctx.owner, :owner)
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example"})
      {:ok, _} = OrganisationPolicy.deny(co_owner.scope, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.set_floor(co_owner.scope, true)
      {:ok, _} = OrganisationPolicy.allow(gone.scope, %{host: "cdn.example"})
      {:ok, _} = Apiary.Accounts.delete_user(gone.scope)
      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, false)

      # A change nobody made: the instance's.
      Apiary.Repo.update_all(
        from(e in Apiary.Audit.Entry,
          where: e.organisation_id == ^ctx.organisation.id,
          where: e.action == "organisation_policy.set_switch"
        ),
        set: [actor_kind: :instance, actor_id: nil]
      )

      view = open(ctx.conn, policy_path(ctx, "/history"))
      tip = "data-tip"

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#policy-history tr")
        |> Enum.map(fn row ->
          {row |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim(),
           row |> LazyHTML.query("abbr") |> Enum.flat_map(&LazyHTML.attribute(&1, tip)),
           row |> LazyHTML.query("[id$='-what'] b > abbr[tabindex='0']") |> Enum.count(),
           row |> LazyHTML.query(".avatar") |> Enum.count()}
        end)

      email = co_owner.user.email
      you = "#{ctx.owner.user.email} (you)"
      letter = &String.upcase(String.first(&1))

      assert [
               {switch, [], 0, 0},
               {cdn, [], 0, 0},
               {floor, [^email], 1, 0},
               {paste, [^email], 1, 0},
               {api, [^you], 1, 0}
             ] = rows

      assert switch =~ "Qory Apiary turned off"
      assert cdn =~ "Former member allowed cdn.example"
      assert floor =~ "#{letter.(email)}#{email} required enforce in every workspace"
      assert paste =~ "#{letter.(email)}#{email} denied paste.example"
      assert api =~ "#{letter.(you)}#{you} allowed api.example"

      # The letter starts the table's first column, which cuts what overflows it: its
      # tooltip opens to its right.
      assert has_element?(view, ~s{#policy-history abbr.tooltip-right[data-tip="#{email}"]})
    end
  end

  describe "who made a rule or a change" do
    # Who made a rule or a change is named by their account, member or not: the local
    # part of their address beside a rule, their letter and address in History, "Former
    # member" only for a deleted account.
    test "the operator's owner is named in a client's rules and History; a deleted account is a former member" do
      ApiaryPro.Flags.put_operator_infrastructure(false)
      operator = ApiaryPro.OperatorsFixtures.operator_fixture(%{organisation_name: "Hive Ops"})
      client = ApiaryPro.OperatorsFixtures.client_fixture(operator.scope, "Acme")
      co_owner = member_fixture(operator.scope, :owner)
      {:ok, _} = OrganisationPolicy.allow(client.owner.scope, %{host: "cdn.example"})

      ApiaryPro.Flags.put_operator_infrastructure(true)
      in_client = &ApiaryPro.OperatorsFixtures.scope_in(&1, client.organisation)
      {:ok, _} = OrganisationPolicy.allow(in_client.(operator.user), %{host: "api.example"})
      {:ok, _} = OrganisationPolicy.deny(in_client.(co_owner.user), %{host: "paste.example"})
      {:ok, _} = Apiary.Accounts.delete_user(co_owner.scope)

      conn = log_in_user(build_conn(), client.owner.user)
      path = "/#{client.organisation.slug}/policy"
      by = &text(&1, "##{row(&1, &2)} .q-pr-by")
      operator_owner = ApiaryWeb.People.short(operator.user.email)
      client_owner = ApiaryWeb.People.short(client.owner.user.email)
      letter = &"#{String.upcase(String.first(&1.email))} #{&1.email}"

      view = open(conn, path)
      assert by.(view, "api.example") =~ operator_owner
      refute by.(view, "api.example") =~ "Former member"
      assert by.(view, "cdn.example") =~ client_owner
      assert by.(view, "paste.example") =~ "Former member"

      view = open(conn, path <> "/history")
      history = text(view, "#policy-history")
      assert history =~ "#{letter.(operator.user)} allowed api.example"
      refute history =~ "Former member allowed api.example"
      assert history =~ "#{letter.(client.owner.user)} (you) allowed cdn.example"
      assert history =~ "Former member denied paste.example"
      refute history =~ co_owner.user.email

      # With the switch off, a member is named beside their rule as before.
      ApiaryPro.Flags.put_operator_infrastructure(false)
      view = open(conn, path)
      assert by.(view, "cdn.example") =~ client_owner
    end
  end

  describe "the breadcrumb" do
    test "reads Policy after the organisation on every tab and while it loads, with no parent",
         ctx do
      for path <- [
            policy_path(ctx),
            policy_path(ctx, "/workspaces"),
            policy_path(ctx, "/history")
          ] do
        # Loading: the first render, before the socket connects.
        assert ctx.conn |> get(path) |> html_response(200) |> Trail.crumbs() == ["Policy"]

        view = open(ctx.conn, path)
        assert Trail.crumbs(view) == ["Policy"]
        assert has_element?(view, "#breadcrumb [aria-current=page]", "Policy")
        # The section's own page: a phone's bar names it alone.
        assert Trail.up(view) == nil
      end
    end
  end

  describe "the sidebar and the feature" do
    test "an owner and an admin have Policy in the first group, after Overview, on the organisation's pages; a member has nothing",
         ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/#{ctx.organisation}/settings")

      assert has_element?(
               view,
               "nav#nav-group-home[aria-label=Main] #nav-organisation_policy[href='#{policy_path(ctx)}']",
               "Policy"
             )

      refute has_element?(view, "#nav-organisation_policy", "Security")

      refute has_element?(view, "#nav-group-guard")

      # After the core's entries of the group: Overview, and Audit log once it is there.
      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#nav-group-home a[id^='nav-']")
        |> LazyHTML.attribute("id")

      assert hd(ids) == "nav-organisation_overview"
      assert List.last(ids) == "nav-organisation_policy"

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.admin.user), ~p"/#{ctx.organisation}/settings")

      assert has_element?(view, "#nav-organisation_policy")

      # A workspace's pages have the workspace's Policy, not the organisation's.
      {:ok, view, _html} = live(ctx.conn, ~p"/#{ctx.organisation}/#{ctx.main}/policy")
      refute has_element?(view, "#nav-organisation_policy")
      assert has_element?(view, "#nav-policy")

      member = log_in_user(ctx.conn, ctx.member.user)
      {:ok, view, _html} = live(member, ~p"/#{ctx.organisation}/#{ctx.main}")
      refute has_element?(view, "#nav-organisation_policy")
      assert_raise ApiaryWeb.NotFound, fn -> live(member, policy_path(ctx)) end
    end

    test "the palette names it Organisation policy, beside the Workspace policy", ctx do
      labels =
        ctx.conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/#{ctx.organisation}/#{ctx.main}/jump", %{"q" => "policy"})
        |> json_response(200)
        |> Map.fetch!("groups")
        |> Enum.find(&(&1["label"] == "Go to"))
        |> Map.fetch!("items")
        |> Enum.map(& &1["label"])

      assert "Organisation policy" in labels
      assert "Workspace policy" in labels
      refute "Organisation security policy" in labels
      refute "Policy" in labels
    end

    @tag with_features: [:observability, :security, :managed_organisations]
    test "without the feature the page is not found, and nothing leads to it", ctx do
      rule_id = Ecto.UUID.generate()

      for rest <- ["", "/workspaces", "/history", "/rules/new", "/rules/#{rule_id}/edit"] do
        assert ctx.conn |> get(policy_path(ctx, rest)) |> html_response(404)
      end

      {:ok, view, _html} = live(ctx.conn, ~p"/#{ctx.organisation}/settings")
      refute has_element?(view, "#nav-organisation_policy")
      refute has_element?(view, "#new-menu-organisation_rule")
    end

    test "New has no Network access rule where a grant hides the feature from the organisation",
         ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/#{ctx.organisation}/settings")
      assert has_element?(view, "#new-menu-organisation_rule")

      Apiary.Repo.insert!(%ApiaryPro.Grants.Grant{
        organisation_id: ctx.organisation.id,
        feature: :organisation_policy,
        granted: false
      })

      assert :organisation_policy in Features.enabled()

      {:ok, view, _html} = live(ctx.conn, ~p"/#{ctx.organisation}/settings")
      refute has_element?(view, "#new-menu-organisation_rule")
    end
  end
end
