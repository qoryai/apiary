defmodule ApiaryProWeb.PolicyPageProTest do
  # The core's policy pages and Network access under the organisation's policy, as the edition
  # answers the level above the workspace: the line under the title with its link, the
  # organisation's rows first with their source, glyph and menu, the Filter's Source
  # section, the mode fixed by the floor, a target's tab, and the Network access rows
  # the organisation decides, which lead to its page.
  # Not async: the features are the node's.
  use ApiaryWeb.ConnCase, async: false

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import ApiaryWeb.TargetComponents, only: [target_path: 3]
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.{Features, Policy, Repo, Variables}
  alias ApiaryPro.{OperatorsFixtures, OrganisationPolicy, OrganisationVariables}
  alias ApiaryWeb.RunComponents

  @moduletag with_features: Features.all()

  setup %{conn: conn} do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)

    %{scope: owner, organisation: organisation, user: user} =
      sign_up_fixture(%{organisation_name: "Example Co"})

    admin = member_fixture(owner, :admin)
    %{conn: log_in_user(conn, user), owner: owner, organisation: organisation, admin: admin}
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

  defp organisation_policy(ctx), do: ~p"/#{ctx.organisation}/policy"

  # A client's workspace policy page, as one of its people or of its operator's.
  defp open_as(ctx, actor), do: open(log_in_user(ctx.conn, ctx.people[actor]), ctx.path)

  # Whether the client's rule not locked, then its locked one, are locked now.
  defp locks(ctx), do: Enum.map([ctx.open, ctx.locked], &Repo.get!(Policy.Rule, &1.id).locked)

  @only_the_operator "Only owners of Hive Ops, its operator, lock, unlock or change a locked rule."
  @vault_locked "The rule for vault.example is locked. " <> @only_the_operator

  # What a target's rule form and a connection's panel say of vault.example before who may
  # change it.
  @vault_on_the_target "A locked workspace rule denies vault.example . It holds against every repository, so no rule added here would change what happens."

  # The lock's tips with the date a rule was locked on as ‹date›.
  defp dated(tips),
    do: for(row <- tips, do: Enum.map(row, &String.replace(&1, ~r/ on [^.]+\./, " on ‹date›.")))

  # The New rule form, opened from Add rule where it is shut, with `params` typed in.
  defp type(view, params) do
    unless has_element?(view, "#policy-rule-form"),
      do: view |> element("#policy-rules-add") |> render_click()

    view |> form("#policy-rule-form", rule: params) |> render_change()
  end

  # The mode's choices: Change mode opens them, where they are shut; a pick only selects.
  defp pick_mode(view, setting) do
    if has_element?(view, "#policy-mode-change"),
      do: view |> element("#policy-mode-change") |> render_click()

    view |> form("#policy-mode-form", %{"mode" => setting}) |> render_change()
    view
  end

  defp attribute(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> hd()
  end

  # Where a client's people read who may change a locked rule. Before the flag, Acme's
  # owner locked api.example, so the pages know who locked it, and a run of acme/shop was
  # refused vault.example, which the locked rule denies, and let bin.lock.example through
  # with no rule.
  defp lock_places(ctx) do
    on? = ApiaryPro.Flags.operator_infrastructure?()
    ApiaryPro.Flags.put_operator_infrastructure(false)
    owner = ctx.client.owner.scope
    {:ok, api} = Policy.allow(owner, nil, %{host: "api.example"})
    {:ok, _} = Policy.lock(owner, api)

    run =
      started_run(owner, shop(),
        egress: [
          %{
            "host" => "vault.example",
            "decision" => "denied",
            "rule" => "vault.example",
            "outcome" => "refused"
          },
          %{"host" => "bin.lock.example", "decision" => "allowed", "rule" => ""}
        ]
      )

    [%{target: target}] = Policy.list_targets(owner)
    ApiaryPro.Flags.put_operator_infrastructure(on?)
    workspace = "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}"

    %{
      run: run,
      target: target,
      workspace: workspace,
      tab: target_path(owner, target, ["policy"])
    }
  end

  # Each sentence that says who may change a locked rule, as Acme's member reads it or as
  # the policy refuses them, at `places`. The target's Destinations are read by `locker`,
  # who may lock: it picks enforce on the target's tab, then locks a deny of
  # *.lock.example, which bin.lock.example falls under, and removes it again.
  defp lock_words(ctx, places, locker) do
    conn = log_in_user(build_conn(), ctx.people.client_member)

    member =
      OperatorsFixtures.scope_in(
        ctx.people.client_member,
        ctx.client.organisation,
        ctx.client.workspace
      )

    tips =
      for path <- [ctx.path, places.tab] do
        view = open(conn, path)

        for host <- ["api.example", "vault.example"],
            do: attribute(view, "##{row(view, host)}-lock", "data-tip")
      end

    form = open(conn, ctx.path)
    type(form, %{host: "vault.example", paths: ""})
    tab_form = open(conn, places.tab)
    type(tab_form, %{host: "vault.example", paths: ""})

    assert {:error, %Policy.Error{reason: :locked, message: paths}} =
             Policy.allow_path(member, places.target, "vault.example", "/v1")

    assert {:error, %Policy.Error{reason: :forbidden, message: change}} =
             Policy.allow(member, nil, %{host: "vault.example"})

    assert {:error, %Policy.Error{reason: :forbidden, message: remove}} =
             Policy.remove_rule(member, ctx.locked)

    view = pick_mode(open(log_in_user(build_conn(), locker.user), places.tab), "enforce")
    {:ok, deny} = Policy.deny(locker.scope, nil, %{host: "*.lock.example", locked: true})
    _ = render(view)
    key = ApiaryWeb.PolicyLive.Common.would_key(%{host: "bin.lock.example", path: nil})
    destination = attribute(view, "#would-#{key} .q-locked", "data-tip")
    {:ok, _} = Policy.remove_rule(locker.scope, deny)

    connection =
      Repo.one!(
        from c in Apiary.Runs.Connection,
          where: c.run_id == ^places.run.id and c.host == "vault.example",
          select: c.id
      )

    {:ok, run, _html} = live(conn, "#{places.workspace}/runs/#{places.run.number}/network")
    run |> element("#cx-#{connection}-lock") |> render_click()
    network = open(conn, "#{places.workspace}/network")
    network |> element("##{dst("vault.example")}-lock") |> render_click()

    overview =
      conn
      |> open(places.workspace)
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#attention-list li[data-kind=denied] .q-ar-why")
      |> LazyHTML.attribute("title")

    %{
      tips: tips,
      form: text(form, "#policy-rule-refusal"),
      tab_form: text(tab_form, "#policy-rule-refusal"),
      paths: paths,
      change: change,
      remove: remove,
      destination: destination,
      run_panel: text(run, "#rule-panel-refusal"),
      network_panel: text(network, "#rule-panel-refusal"),
      overview: overview
    }
  end

  describe "the workspace's policy page" do
    setup ctx do
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
      {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      {:ok, _} = OrganisationPolicy.allow(ctx.owner, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, _} = OrganisationPolicy.set_floor(ctx.owner, true)
      :ok
    end

    test "says the organisation's policy applies, lists its rows first, and leads to its page",
         ctx do
      view = open(ctx.conn, workspace_path(ctx.owner, "/policy"))

      assert text(view, "#policy-above") ==
               "E Example Co's policy applies here: 2 rules , enforce required . View it"

      assert has_element?(view, "#policy-above-view[href='#{organisation_policy(ctx)}']")
      assert hosts(view) == ["paste.example", "api.example", "cdn.example", "paste.example"]

      api = row(view, "api.example")
      assert text(view, "##{api} .q-pr-src") == "E Example Co"
      assert has_element?(view, "##{api}-lock")
      assert has_element?(view, "##{api}-menu")

      assert has_element?(
               view,
               "##{api}-view[href='#{organisation_policy(ctx)}?rule=api.example']",
               "View in Example Co's policy"
             )

      refute has_element?(view, "##{api}-remove")

      assert text(view, "#policy-rules-filter-source-0") =~ "Example Co 2 rules"
      assert text(view, "#policy-rules-filter-source-1") =~ "Main 2 rules"

      assert has_element?(view, "#policy-mode[data-floor=true]")
      assert text(view, "#policy-mode-value") == "Enforce"
      assert text(view, "#policy-mode-required") == "Required by Example Co"

      # A struck row says whose deny.
      assert [struck] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#policy-rules tr.q-pr-off")
               |> Enum.to_list()

      assert struck |> LazyHTML.query(".q-pr-offw-full") |> LazyHTML.text() |> String.trim() ==
               "Not in force: Example Co's paste.example denies it"

      # The organisation's change is in the workspace's history, with its name.
      view = open(ctx.conn, workspace_path(ctx.owner, "/policy/history"))
      assert text(view, "#policy-history") =~ "changed Example Co 's policy"
    end

    test "a crafted event naming the organisation's rule changes nothing", ctx do
      view = open(ctx.conn, workspace_path(ctx.owner, "/policy"))
      {:ok, %{rules: [rule | _]}} = OrganisationPolicy.get(ctx.owner)

      for event <- ~w(remove edit_paths change_action lock_toggle) do
        render_hook(view, event, %{"id" => rule.id})
      end

      assert {:ok, %{rules: [_, _]}} = OrganisationPolicy.get(ctx.owner)
      assert length(Policy.list_rules(ctx.owner, nil)) == 2
    end

    test "a target's tab lists the organisation's rows after its own, with the floor", ctx do
      started_run(ctx.owner, shop())
      [%{target: target}] = Policy.list_targets(ctx.owner)
      {:ok, _} = Policy.allow(ctx.owner, target, %{host: "sms.example"})

      view = open(ctx.conn, target_path(ctx.owner, target, ["policy"]))

      assert hosts(view) == [
               "sms.example",
               "paste.example",
               "api.example",
               "cdn.example",
               "paste.example"
             ]

      paste = row(view, "paste.example")
      assert text(view, "##{paste} .q-pr-src") == "E Example Co"

      assert has_element?(
               view,
               "##{paste}-view[href='#{organisation_policy(ctx)}?rule=paste.example']"
             )

      assert has_element?(view, "#policy-mode[data-floor=true]")
      assert text(view, "#policy-mode-required") == "Required by Example Co"
    end
  end

  describe "Network access" do
    setup ctx do
      started_run(ctx.owner, shop(),
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

      :ok
    end

    defp dst(host), do: RunComponents.destination_id(%{host: host, port: 443, path: ""})

    test "a row the organisation denies says so, with a lock, and leads to the organisation's policy",
         ctx do
      {:ok, _} = OrganisationPolicy.deny(ctx.owner, %{host: "paste.example"})
      rule = "#{organisation_policy(ctx)}?rule=paste.example"

      # An owner changes the organisation's policy, an admin reads it: both are led there.
      for user <- [ctx.owner.user, ctx.admin.user] do
        view = open(log_in_user(ctx.conn, user), workspace_path(ctx.owner, "/network"))
        paste = dst("paste.example")

        assert text(view, "##{paste}-above") == "E Example Co · denied"
        assert has_element?(view, "##{paste}-rule[href='#{rule}']", "Example Co · denied")

        assert has_element?(view, "span##{paste}-lock.q-act-lock")

        assert [tip] =
                 view
                 |> render()
                 |> LazyHTML.from_fragment()
                 |> LazyHTML.query("##{paste}-lock")
                 |> LazyHTML.attribute("data-tip")

        assert tip ==
                 "Example Co's policy denies paste.example. No workspace or repository rule can allow it."

        refute has_element?(view, "##{paste}-allow")
      end
    end

    test "where only the organisation allows, Allow leads to its New rule page with the host",
         ctx do
      {:ok, _} = OrganisationPolicy.set_switch(ctx.owner, false)
      view = open(ctx.conn, workspace_path(ctx.owner, "/network"))
      new = dst("new.example")

      # The way there carries the way back to this page.
      to =
        "#{organisation_policy(ctx)}/rules/new?" <>
          URI.encode_query(%{
            "host" => "new.example",
            "back" => workspace_path(ctx.owner, "/network")
          })

      assert has_element?(
               view,
               ~s(button##{new}-allow[data-tip="Allow new.example in Example Co's policy"])
             )

      # The row's Allow opens a panel under the row, in place, that says why and leads
      # there.
      view |> element("##{new}-allow") |> render_click()
      assert has_element?(view, "tr##{new}-panel #rule-panel-elsewhere-open[href='#{to}']")

      # Narrowed to a target, the way there carries the narrowed list, and the
      # organisation's page offers the way back to it.
      [%{target: shop}] = Policy.list_targets(ctx.owner)

      narrowed =
        workspace_path(ctx.owner, "/network?" <> URI.encode_query(%{target: shop.public_id}))

      view = open(ctx.conn, narrowed)
      view |> element("##{new}-allow") |> render_click()

      [href] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tr##{new}-panel #rule-panel-elsewhere-open")
        |> LazyHTML.attribute("href")

      assert URI.decode_query(URI.parse(href).query)["back"] == narrowed

      view = open(ctx.conn, href)
      assert has_element?(view, "#policy-rule-host[value='new.example']")
      view |> element("#policy-rule-save-cancel") |> render_click()

      assert has_element?(
               view,
               "#policy-back[href='#{narrowed}']",
               "Back to #{ctx.owner.workspace.name} › acme/shop › Network access"
             )

      # An admin, who reads the organisation's policy, is offered no way to allow it there.
      view = open(log_in_user(ctx.conn, ctx.admin.user), workspace_path(ctx.owner, "/network"))
      refute has_element?(view, "##{new}-allow")
    end
  end

  # The organisation with variables and no policy in force, as the edition answers it: a
  # level with `policy: false`, which the core raises on where it holds anything of a
  # policy. Every page that reads the level, and the writes under it, go through.
  defp variables_without_policy!(ctx) do
    {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "cdn.example"})
    {:ok, _} = Policy.deny(ctx.owner, nil, %{host: "paste.example"})
    {:ok, own} = Variables.create_variable(ctx.owner, :workspace, %{name: "REGION", value: "x"})

    {:ok, _} =
      OrganisationVariables.create(ctx.owner, %{name: "REGION", value: "eu-west-1", locked: true})

    started_run(ctx.owner, shop(),
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

    [%{target: target}] = Policy.list_targets(ctx.owner)
    {:ok, _} = Policy.allow(ctx.owner, target, %{host: "sms.example"})
    %{own: own, target: target}
  end

  defp says_no_policy_above(view) do
    refute has_element?(view, "#policy-above")
    refute has_element?(view, "#policy-mode[data-floor=true]")
    refute has_element?(view, "#policy-rules tr.q-pr-off")
    html = render(view)
    refute html =~ "Example Co&#39;s policy"
    refute html =~ "Required by Example Co"
  end

  defp pages_without_the_level(ctx) do
    view = open(ctx.conn, workspace_path(ctx.owner, "/policy"))
    says_no_policy_above(view)
    assert hosts(view) == ["paste.example", "cdn.example"]

    view = open(ctx.conn, workspace_path(ctx.owner, "/policy/history"))
    says_no_policy_above(view)

    view = open(ctx.conn, target_path(ctx.owner, ctx.target, ["policy"]))
    says_no_policy_above(view)
    assert hosts(view) == ["sms.example", "paste.example", "cdn.example"]

    view = open(ctx.conn, workspace_path(ctx.owner, "/network"))
    says_no_policy_above(view)
    refute has_element?(view, "##{dst("paste.example")}-above")

    # The variables page: the workspace's own REGION set aside by the organisation's lock,
    # and a new one of the name, in any spelling, refused.
    {:ok, view, _html} = live(ctx.conn, workspace_path(ctx.owner, "/settings/variables"))

    assert has_element?(
             view,
             "#variable-#{ctx.own.id}-lock",
             "Set aside: locked above the workspace"
           )

    {:ok, view, _html} = live(ctx.conn, workspace_path(ctx.owner, "/settings/variables/new"))

    for name <- ["REGION", "region"] do
      html =
        view
        |> form("#variable-form", variable: %{name: name, value: "us-east-1"})
        |> render_submit()

      assert html =~ "is locked above, so it cannot be set here"
    end

    view
    |> form("#variable-form", variable: %{name: "NPM_REGISTRY", value: "https://npm.example"})
    |> render_submit()

    assert {:ok, resolution} = Variables.resolve(ctx.owner, :workspace)

    assert Variables.Resolution.values(resolution) == %{
             "REGION" => "eu-west-1",
             "NPM_REGISTRY" => "https://npm.example"
           }

    # The policy's writes under the level: a rule, the mode, and their pages again.
    assert {:ok, _} = Policy.allow(ctx.owner, nil, %{host: "api.example"})
    assert {:ok, "enforce"} = Policy.set_mode(ctx.owner, nil, "enforce")
    assert {:ok, _configuration} = Policy.current_configuration(ctx.owner, nil)
    assert %{above: nil, mode: "enforce"} = Policy.effective(ctx.owner, nil)

    view = open(ctx.conn, workspace_path(ctx.owner, "/policy"))
    says_no_policy_above(view)
    assert text(view, "#policy-mode-value") == "Enforce"
  end

  describe "a client's workspace policy page while the operator owns it" do
    # Hive Ops and its client Acme, whose owner was made while the flag was off: a rule of
    # Acme's workspace and a locked one, then the flag on, and the people who open it.
    setup do
      ApiaryPro.Flags.put_operator_infrastructure(false)
      operator = OperatorsFixtures.operator_fixture(%{organisation_name: "Hive Ops"})
      client = OperatorsFixtures.client_fixture(operator.scope, "Acme")
      operator_admin = member_fixture(operator.scope, :admin)
      {:ok, open} = Policy.allow(client.owner.scope, nil, %{host: "cdn.example"})

      {:ok, locked} =
        Policy.deny(client.owner.scope, nil, %{host: "vault.example", locked: true})

      ApiaryPro.Flags.put_operator_infrastructure(true)

      people = %{
        operator_owner: operator.user,
        operator_admin: operator_admin.user,
        client_owner: client.owner.user,
        client_admin: OperatorsFixtures.client_member_fixture(client, :admin).user,
        client_member: OperatorsFixtures.client_member_fixture(client, :member).user
      }

      %{
        client: client,
        open: open,
        locked: locked,
        people: people,
        path: "/#{client.organisation.slug}/#{client.workspace.slug}/policy"
      }
    end

    test "the operator's owner locks and unlocks the client's rules", ctx do
      view = open_as(ctx, :operator_owner)
      open = row(view, "cdn.example")
      locked = row(view, "vault.example")
      assert text(view, "##{open}-lock-toggle") == "Lock"
      assert text(view, "##{locked}-lock-toggle") == "Unlock"

      view |> element("##{open}-lock-toggle") |> render_click()
      view |> element("##{locked}-lock-toggle") |> render_click()
      refute has_element?(view, "#policy-write-error")
      assert locks(ctx) == [true, false]
    end

    test "anyone else edits the rules not locked, and is refused a lock in the operator's words",
         ctx do
      for actor <- [:operator_admin, :client_owner, :client_admin, :client_member] do
        view = open_as(ctx, actor)
        open = row(view, "cdn.example")
        locked = row(view, "vault.example")

        # The rule not locked has its menu, with no Lock; the locked one has no menu.
        assert has_element?(view, "##{open}-change"), "#{actor}"
        refute has_element?(view, "##{open}-lock-toggle"), "#{actor}"
        refute has_element?(view, "##{locked}-menu"), "#{actor}"

        # A crafted Lock or Unlock is refused, and names the operator.
        for rule <- [ctx.open, ctx.locked] do
          render_hook(view, "lock_toggle", %{"id" => rule.id})
          assert text(view, "#policy-write-error") == @only_the_operator, "#{actor}"
        end

        assert locks(ctx) == [false, true], "#{actor}"
      end
    end

    test "the client's owner made before is refused a lock and an unlock in the operator's words",
         ctx do
      scope = ctx.client.owner.scope

      for rule <- [ctx.open, ctx.locked], set <- [&Policy.lock/2, &Policy.unlock/2] do
        assert {:error, %Policy.Error{reason: :forbidden, message: @only_the_operator}} =
                 set.(scope, rule)
      end

      # Nor does it change or remove a locked rule.
      assert {:error, %Policy.Error{reason: :forbidden, message: @vault_locked}} =
               Policy.allow(scope, nil, %{host: "vault.example"})

      assert {:error, %Policy.Error{reason: :forbidden, message: @vault_locked}} =
               Policy.remove_rule(scope, ctx.locked)

      assert locks(ctx) == [false, true]
    end

    test "each sentence of who may change a locked rule names the operator, after what is locked",
         ctx do
      places = lock_places(ctx)
      locker = %{user: ctx.people.operator_owner, scope: ctx.client.scope}
      words = lock_words(ctx, places, locker)
      by = "Locked by #{ctx.people.client_owner.email} on ‹date›."

      # The lock's tip on the workspace's page and on the target's tab, with who locked it
      # known and not known.
      assert dated(words.tips) == [
               ["#{by} #{@only_the_operator}", "Locked. #{@only_the_operator}"],
               ["#{by} #{@only_the_operator}", "Locked. #{@only_the_operator}"]
             ]

      assert words.form == @only_the_operator

      assert words.tab_form ==
               "#{@vault_on_the_target} #{@only_the_operator} Show the locked rule"

      assert words.paths ==
               "The workspace's rule for vault.example is locked, so a repository cannot change its paths. #{@only_the_operator}"

      assert words.change == @vault_locked
      assert words.remove == @vault_locked

      assert words.destination ==
               "A locked workspace rule denies *.lock.example. #{@only_the_operator}"

      assert words.run_panel == "#{@vault_on_the_target} #{@only_the_operator}"
      assert words.network_panel == words.run_panel

      assert words.overview == [
               "A locked workspace rule denies vault.example. #{@only_the_operator}"
             ]
    end

    test "with the flag off, each sentence of who may change a locked rule is the core's", ctx do
      places = lock_places(ctx)
      ApiaryPro.Flags.put_operator_infrastructure(false)
      locker = %{user: ctx.people.client_owner, scope: ctx.client.owner.scope}
      words = lock_words(ctx, places, locker)
      by = "Locked by #{ctx.people.client_owner.email} on ‹date›."

      assert dated(words.tips) == [
               [
                 "#{by} Only an owner can change or unlock it.",
                 "Locked. Only an owner can change or unlock it."
               ],
               [
                 "#{by} Only an owner can change or unlock it.",
                 "Locked. Only an owner can change or unlock it."
               ]
             ]

      assert words.form == "Only an owner can lock, unlock or change a locked rule."

      assert words.tab_form ==
               "#{@vault_on_the_target} Only an owner can change or unlock it. Show the locked rule"

      assert words.paths ==
               "The workspace's rule for vault.example is locked, so a repository cannot change its paths. An owner changes it in the workspace."

      core =
        "The rule for vault.example is locked. Only an owner changes or removes a locked rule."

      assert words.change == core
      assert words.remove == core

      assert words.destination ==
               "A locked workspace rule denies *.lock.example. Only an owner can change it, on the workspace's policy page."

      assert words.run_panel == "#{@vault_on_the_target} Only an owner can change or unlock it."
      assert words.network_panel == words.run_panel

      assert words.overview == [
               "A locked workspace rule denies vault.example. Only an owner can change it."
             ]
    end

    test "with the flag off, the client's owner locks, and its admin is refused as before",
         ctx do
      ApiaryPro.Flags.put_operator_infrastructure(false)

      view = open_as(ctx, :client_owner)
      assert text(view, "##{row(view, "cdn.example")}-lock-toggle") == "Lock"
      assert text(view, "##{row(view, "vault.example")}-lock-toggle") == "Unlock"

      view = open_as(ctx, :client_admin)
      refute has_element?(view, "##{row(view, "cdn.example")}-lock-toggle")
      render_hook(view, "lock_toggle", %{"id" => ctx.open.id})

      assert text(view, "#policy-write-error") ==
               "Only an owner can lock, unlock or change a locked rule."

      admin_scope =
        OperatorsFixtures.scope_in(
          ctx.people.client_admin,
          ctx.client.organisation,
          ctx.client.workspace
        )

      assert {:error, %Policy.Error{message: "Only an owner locks or unlocks a rule."}} =
               Policy.lock(admin_scope, ctx.open)
    end
  end

  describe "an organisation with variables and no policy" do
    # The organisation's variables and the workspace's need `secrets`.
    @describetag needs: :organisation_variables
    setup ctx, do: variables_without_policy!(ctx)

    test "every page and write takes the level as no policy, and resolves its variables",
         ctx do
      assert %Apiary.Policy.Above{policy: false} =
               Apiary.Edition.above_workspace(ctx.owner.workspace)

      pages_without_the_level(ctx)
    end
  end

  describe "an organisation with variables and a policy whose feature is off" do
    # The organisation's variables and the workspace's need `secrets`.
    @describetag needs: :organisation_variables
    @describetag with_features: Features.all() -- [:organisation_policy]

    setup ctx do
      # A policy kept from before, with every setting a policy in force would show.
      Repo.insert!(%OrganisationPolicy.Policy{
        organisation_id: ctx.organisation.id,
        enforce_everywhere: true,
        own_allows: false
      })

      Repo.insert!(%OrganisationPolicy.Rule{
        organisation_id: ctx.organisation.id,
        created_by_id: ctx.owner.user.id,
        action: "deny",
        host: "cdn.example"
      })

      variables_without_policy!(ctx)
    end

    test "every page and write takes the level as no policy, none of the policy kept", ctx do
      assert %Apiary.Policy.Above{policy: false, rules: [], floor: false, own_allows: true} =
               Apiary.Edition.above_workspace(ctx.owner.workspace)

      pages_without_the_level(ctx)
    end
  end
end
