defmodule ApiaryProWeb.InstanceLive.OrganisationsTest do
  # Not async: instance admins are owners of the suite's one instance organisation, and
  # the features are the node's.
  use ApiaryWeb.ConnCase, async: false

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.Suspensions
  alias ApiaryPro.Transfers.Transfer
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryWeb.Nav.Entry

  @moduletag with_features: Features.all()

  setup %{conn: conn} do
    admin = instance_admin_fixture()
    here = admin.instance_scope.organisation
    %{conn: log_in_user(conn, admin.user), admin: admin, here: here}
  end

  test "an instance admin sees every organisation, with its kind and its operator", ctx do
    operator = operator_fixture(%{organisation_name: "Hive Ops"})
    client = client_fixture(operator.scope, "Acme")

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
    render_async(lv)

    assert has_element?(lv, "#instance-tabs #instance-tab-organisations[aria-current=page]")
    assert has_element?(lv, "#organisation-#{ctx.here.id}-kind", "The instance owner")
    assert has_element?(lv, "#organisation-#{operator.organisation.id}-kind", "Operator")
    assert has_element?(lv, "#organisation-#{operator.organisation.id}-operator", "1 client")
    assert has_element?(lv, "#organisation-#{client.organisation.id}-operator", "Hive Ops")
    # The organisation's name, the operator's name and the slug beside the name are cut
    # to the cell, whole in their titles.
    assert has_element?(
             lv,
             "#organisation-#{operator.organisation.id}-link.q-title.q-org-name[title='Hive Ops']",
             "Hive Ops"
           )

    refute has_element?(lv, "#organisation-#{operator.organisation.id}-link.q-cut")

    assert has_element?(
             lv,
             "#organisation-#{client.organisation.id}-operator > .q-cut[class*='max-w-[24ch]'][title='Hive Ops']"
           )

    refute has_element?(lv, "#organisation-#{client.organisation.id}-operator .truncate")

    assert has_element?(
             lv,
             "#organisation-#{operator.organisation.id} .q-nm > .q-side.q-mono[title='#{operator.organisation.slug}']",
             operator.organisation.slug
           )

    # Its slug and its kind also on the line under its name, for a table too narrow for
    # them beside it.
    line = "#organisation-#{operator.organisation.id} .q-fold-line"
    assert has_element?(lv, "#{line} .q-fold.q-mono", operator.organisation.slug)

    # There too the slug is cut to the line, whole in its title.
    assert has_element?(
             lv,
             "#{line} > .q-fold.q-org-slug[title='#{operator.organisation.slug}']",
             operator.organisation.slug
           )

    assert has_element?(lv, "#{line} .q-fold", "Operator")

    # On the instance organisation itself a change of kind alone is offered, as on any
    # organisation that is no client: it is never purged.
    refute has_element?(lv, "#organisation-#{ctx.here.id}-purge-button")
    assert has_element?(lv, "#organisation-#{ctx.here.id}-kind-button")
    # An operator with clients stays one; a client becomes no operator.
    refute has_element?(lv, "#organisation-#{operator.organisation.id}-kind-button")
    refute has_element?(lv, "#organisation-#{client.organisation.id}-kind-button")
  end

  test "the Instance's sections are the second column, Organisations current", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
    render_async(lv)

    # The core's settings frame, as on its Configuration: the section is the page's one
    # h1, in a list's column, and the level is the column's heading.
    assert has_element?(lv, "#settings-section-organisations.q-settings-main-list")
    assert has_element?(lv, "h1#settings-section-title", "Organisations")
    refute has_element?(lv, "#page-header-title")

    assert has_element?(
             lv,
             "#settings-section-organisations .q-settings-head-sub",
             "change one only under Instance settings."
           )

    assert has_element?(lv, "#instance-tabs-heading", "Instance settings")

    assert has_element?(
             lv,
             ~s(#instance-tabs a#instance-tab-organisations[aria-current=page][href="/instance/organisations"]),
             "Organisations"
           )

    assert has_element?(
             lv,
             ~s(#instance-tabs a#instance-tab-accounts[href="/instance/accounts"]),
             "Accounts"
           )

    refute has_element?(lv, "#instance-tab-accounts[aria-current]")
    # The breadcrumb: Instance settings, which leads to its first section, the core's
    # General, then the section.
    assert has_element?(
             lv,
             ~s(#breadcrumb a[href="/instance/general"]),
             "Instance settings"
           )

    assert has_element?(lv, "#breadcrumb [aria-current=page]", "Organisations")
    # The organisation's sidebar has no Instance entry: the Qory Apiary menu leads to the
    # first section, the core's General.
    refute has_element?(lv, "#nav-instance")
    assert has_element?(lv, ~s(#brand-menu-instance[href="/instance/general"]))
    # The accounts are a section of their own, not under the organisations.
    refute has_element?(lv, "#accounts")
    assert page_title(lv) == "Organisations · Instance settings · Qory Apiary"
  end

  test "the Instance's sections are the instance admins' alone, wherever they are", ctx do
    # In the organisation they came from, not only in the instance organisation.
    for scope <- [ctx.admin.instance_scope, ctx.admin.scope] do
      assert [
               %Entry{key: :organisations, place: :instance, path: "/instance/organisations"},
               %Entry{key: :accounts, place: :instance, path: "/instance/accounts"}
             ] = ApiaryProWeb.Edition.instance_sections(scope)
    end

    # After the core's General and before its Mail and Configuration, which the core adds.
    assert [:general, :organisations, :accounts | _core] =
             ctx.admin.scope |> ApiaryWeb.Layouts.instance_sections() |> Enum.map(& &1.key)

    %{scope: io_admin} = member_fixture(ctx.admin.instance_scope, :admin)
    %{scope: stranger} = sign_up_fixture()

    for scope <- [io_admin, stranger, nil] do
      assert ApiaryProWeb.Edition.instance_sections(scope) == []
    end
  end

  test "the addresses under the instance organisation lead to the Instance", ctx do
    id = Ecto.UUID.generate()
    here = ctx.here

    for {old, new} <- [
          {~p"/#{here}/instance", ~p"/instance/organisations"},
          {~p"/#{here}/instance?view=deleted&q=acme",
           "/instance/organisations?view=deleted&q=acme"},
          {~p"/#{here}/instance/new", ~p"/instance/organisations/new"},
          {~p"/#{here}/instance/#{id}/kind", ~p"/instance/organisations/#{id}/kind"},
          {~p"/#{here}/instance/#{id}/purge", ~p"/instance/organisations/#{id}/purge"},
          {~p"/#{here}/instance/#{id}/suspend", ~p"/instance/organisations/#{id}/suspend"},
          {~p"/#{here}/instance/#{id}/transfer", ~p"/instance/organisations/#{id}/transfer"},
          {~p"/#{here}/instance/#{id}/features", ~p"/instance/organisations/#{id}/features"},
          # The one page's accounts, their view and search, are Accounts'.
          {~p"/#{here}/instance?accounts=suspended&aq=dana",
           ~p"/instance/accounts?view=suspended&q=dana"},
          {~p"/#{here}/instance?view=deleted&aq=dana%40example.com",
           ~p"/instance/accounts?q=dana%40example.com"},
          {~p"/#{here}/instance?accounts=suspended", ~p"/instance/accounts?view=suspended"},
          {~p"/#{here}/instance?accounts=all&aq=+",
           ~p"/instance/organisations?accounts=all&aq=+"},
          {~p"/#{here}/instance/accounts", ~p"/instance/accounts"},
          {~p"/#{here}/instance/accounts/#{id}/suspend", ~p"/instance/accounts/#{id}/suspend"}
        ] do
      assert redirected_to(get(ctx.conn, old)) == new
    end

    # Not an act there ever was.
    assert_error_sent 404, fn -> get(ctx.conn, "/#{here.slug}/instance/#{id}/rename") end
  end

  test "the search narrows the list, says how many match, and clears", ctx do
    %{organisation: organisation} = sign_up_fixture(%{organisation_name: "Zephyr Works"})

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations?q=zephyr")
    render_async(lv)
    assert has_element?(lv, "#organisation-#{organisation.id}")
    refute has_element?(lv, "#organisation-#{ctx.here.id}")
    assert has_element?(lv, "#organisations-status", "1 organisation matches")

    lv |> form("#organisations-search", q: "nothing-is-called-this") |> render_change()
    assert_patch(lv, ~p"/instance/organisations?q=nothing-is-called-this")
    refute has_element?(lv, "#organisations")
    assert has_element?(lv, "#organisations-none", "No organisation matches")
    assert has_element?(lv, "#organisations-status", "0 organisations match")

    lv |> element("#organisations-clear") |> render_click()
    assert_patch(lv, ~p"/instance/organisations")
    assert has_element?(lv, "#organisation-#{organisation.id}")
    assert has_element?(lv, "#organisation-#{ctx.here.id}")
  end

  test "an empty view says what it keeps, an empty search that nothing matches", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations?view=deleted")
    render_async(lv)
    assert has_element?(lv, "#organisations-none", "No organisation is deleted")
    refute has_element?(lv, "#organisations-clear")

    lv |> element("#organisations-view-suspended") |> render_click()
    assert has_element?(lv, "#organisations-none", "No organisation is suspended")

    lv |> form("#organisations-search", q: "nothing-is-called-this") |> render_change()
    assert has_element?(lv, "#organisations-none", "No organisation matches")
  end

  test "an instance admin creates an organisation, and is led to its overview", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
    # Organisations is a section page: a phone's bar names it alone.
    assert ApiaryProWeb.Trail.up(lv) == nil
    lv |> element("#new-organisation") |> render_click()
    assert_patch(lv, ~p"/instance/organisations/new")
    # A page of Organisations, never a dialog: the breadcrumb ends with New organisation.
    refute has_element?(lv, "#main dialog, #main [role=dialog]")
    refute has_element?(lv, "#organisations")
    assert has_element?(lv, "#breadcrumb [aria-current=page]", "New organisation")
    assert has_element?(lv, ~s(#breadcrumb a[href="/instance/organisations"]), "Organisations")
    # A phone's bar keeps Organisations as the page's parent, a link back.
    assert ApiaryProWeb.Trail.up(lv) == {"Organisations", ~p"/instance/organisations"}
    assert page_title(lv) =~ "New organisation · Instance settings"

    # The title alone is under the heading: what the page knows goes under About organisations.
    assert has_element?(lv, "#organisation-page h1", "New organisation")
    refute has_element?(lv, "#organisation-page #set-up-line")
    refute has_element?(lv, "#organisation-page", "You are its first owner")

    assert has_element?(lv, "#set-up-context h2", "About organisations")

    assert has_element?(
             lv,
             "#set-up-context",
             "You become its first owner, because an instance admin creates it. You invite its people from its Organisation settings › People."
           )

    assert has_element?(
             lv,
             "#set-up-context",
             "You can leave the organisation once another person is an owner."
           )

    assert has_element?(
             lv,
             "#set-up-context",
             "Work happens in workspaces. You choose what its first one does on the organisation's overview."
           )

    # The steps list Your organisation alone, so the page shows no steps indicator.
    refute has_element?(lv, "#set-up-steps")
    refute has_element?(lv, "#set-up-step")

    # Kind is the choice field, Organisation chosen: a button, and a radio for each kind.
    assert has_element?(lv, "#organisation-form #organisation_kind-choice", "Kind")

    assert has_element?(
             lv,
             "#organisation-form #organisation_kind",
             "For a team that works in workspaces."
           )

    refute has_element?(lv, "#organisation-form", "What are you creating?")

    assert has_element?(
             lv,
             "#organisation-form input[name='organisation[kind]'][value=organisation][checked]"
           )

    assert has_element?(
             lv,
             "#organisation-form input[name='organisation[kind]'][value=operator]"
           )

    assert has_element?(lv, "#organisation-form", "Creates and runs organisations for clients.")

    assert has_element?(lv, "#organisation-form input#organisation_name[phx-mounted]")
    assert has_element?(lv, "#organisation-save a#organisation-save-cancel", "Cancel")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv
             |> form("#organisation-form", organisation: %{name: "Newco", kind: "operator"})
             |> render_submit()

    organisation = Repo.get_by!(Organisation, name: "Newco")
    assert tenant_of(organisation).kind == :operator
    assert to == ~p"/#{organisation}"
    refute Apiary.Organisations.has_workspace?(organisation)

    # Its only owner, until they hand it on.
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
    render_async(lv)
    assert has_element?(lv, "#organisation-#{organisation.id}-only-owner", "only owner")

    # The one act it asks for, the row's text action: an owner invited on its people page.
    people = ~p"/#{organisation}/settings/people"

    assert has_element?(
             lv,
             ~s(#organisation-#{organisation.id}-invite-owner[href="#{people}"]),
             "Invite an owner"
           )

    refute has_element?(lv, "#organisation-#{ctx.here.id}-invite-owner")

    other = sign_up_fixture()
    refute has_element?(lv, "#organisation-#{other.organisation.id}-only-owner")
  end

  @tag with_features: Features.all() -- [:factory, :workflow_model]
  test "without the factory feature, the new organisation's steps list no indicator", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/new")

    assert has_element?(lv, "#organisation-form")
    refute has_element?(lv, "#set-up-steps")
    refute has_element?(lv, "#set-up-steps-name")
  end

  test "a name another organisation has is refused with its address", ctx do
    sign_up_fixture(%{organisation_name: "Acme"})
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/new")
    count = Repo.aggregate(Organisation, :count)

    html = lv |> form("#organisation-form", organisation: %{name: "Acme"}) |> render_submit()

    assert html =~ "Choose another name. Another organisation has the address /acme."
    assert has_element?(lv, "#organisation_name-error", "Choose another name.")
    assert Repo.aggregate(Organisation, :count) == count
  end

  test "an empty name for a new organisation is answered under its field", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/new")
    count = Repo.aggregate(Organisation, :count)

    lv |> form("#organisation-form", organisation: %{name: ""}) |> render_submit()

    assert has_element?(lv, "#organisation_name-error")
    assert has_element?(lv, ~s|#organisation_name[aria-invalid="true"]|)
    assert Repo.aggregate(Organisation, :count) == count
  end

  test "an instance admin makes an organisation an operator, and back", ctx do
    %{organisation: organisation} = sign_up_fixture()

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{organisation.id}/kind")
    render_async(lv)
    # The organisation's row is the confirmation, in place of its cells.
    assert has_element?(lv, "#organisation-#{organisation.id}.q-confirming #kind", "Make ")
    assert has_element?(lv, "#kind-confirm", "Yes, make operator")
    lv |> element("#kind-confirm") |> render_click()
    assert_patch(lv, ~p"/instance/organisations")
    assert Repo.get!(Tenant, organisation.id).kind == :operator
    assert render(lv) =~ "is an operator now"

    render_async(lv)
    lv |> element("#organisation-#{organisation.id}-kind-button") |> render_click()
    lv |> element("#kind-confirm") |> render_click()
    assert Repo.get!(Tenant, organisation.id).kind == :organisation
  end

  test "Cancel goes back to the list as it was left, its view and search kept", ctx do
    %{organisation: organisation} = sign_up_fixture(%{organisation_name: "Zephyr Works"})

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations?view=all&q=zephyr&sort=created")
    render_async(lv)

    lv |> element("#organisation-#{organisation.id}-kind-button") |> render_click()
    assert_patch(lv, ~p"/instance/organisations/#{organisation.id}/kind")
    assert has_element?(lv, "#kind")

    lv |> element("#kind-cancel") |> render_click()
    assert_patch(lv, "/instance/organisations?q=zephyr&sort=created")
    refute has_element?(lv, "#kind")
    refute has_element?(lv, "#organisation-#{ctx.here.id}")
  end

  test "an instance admin purges an organisation at once, its slug typed", ctx do
    %{organisation: organisation} = sign_up_fixture()

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{organisation.id}/purge")
    render_async(lv)
    assert has_element?(lv, "#organisation-#{organisation.id}.q-confirming #purge-form")
    assert has_element?(lv, "#purge-confirm[disabled]", "Yes, purge")

    lv |> form("#purge-form", confirm: %{slug: organisation.slug}) |> render_change()
    refute has_element?(lv, "#purge-confirm[disabled]")

    lv |> form("#purge-form", confirm: %{slug: organisation.slug}) |> render_submit()
    assert_patch(lv, ~p"/instance/organisations")
    refute Repo.get(Organisation, organisation.id)
    assert render(lv) =~ "The organisation is purged."
  end

  test "an operator with clients is not purged from the page", ctx do
    operator = operator_fixture()
    client_fixture(operator.scope)

    {:ok, lv, _html} =
      live(ctx.conn, ~p"/instance/organisations/#{operator.organisation.id}/purge")

    render_async(lv)
    assert has_element?(lv, "#organisation-#{operator.organisation.id} #purge-has-clients")
    refute has_element?(lv, "#purge-confirm")
  end

  test "the page is not there for the instance organisation's admins, nor anyone else", ctx do
    %{user: admin} = member_fixture(ctx.admin.instance_scope, :admin)

    assert_raise ApiaryWeb.NotFound, fn ->
      live(log_in_user(build_conn(), admin), ~p"/instance/organisations")
    end

    # An owner of another organisation, there or anywhere.
    %{user: owner, organisation: own} = sign_up_fixture()

    for path <- [~p"/instance/organisations", ~p"/instance/organisations/new"] do
      assert_raise ApiaryWeb.NotFound, fn -> live(log_in_user(build_conn(), owner), path) end
    end

    # Its old address leads there all the same.
    assert build_conn() |> log_in_user(owner) |> get(~p"/#{own}/instance") |> redirected_to() ==
             ~p"/instance/organisations"
  end

  test "an instance admin reads another organisation, and is offered no change there", ctx do
    home = sign_up_fixture()

    {:ok, lv, _html} = live(ctx.conn, ~p"/#{home.organisation}/settings/people")
    assert has_element?(lv, "#member-#{home.membership.id}")
    refute has_element?(lv, "a", "Invite member")
    refute has_element?(lv, "#level-#{home.membership.id}")

    # The notices say how they read it, on every page there, as the operator's people
    # are told; and nothing of an operator.
    assert has_element?(
             lv,
             "main #organisation-notices #instance-reader [role=note]",
             "You read #{home.organisation.name} as support: everything here can be read, and nothing changed."
           )

    refute has_element?(lv, "#operator-reader")

    {:ok, lv, _html} = live(ctx.conn, ~p"/#{home.organisation}/#{home.workspace}/runs")
    assert has_element?(lv, "#organisation-notices #instance-reader")
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{home.organisation}/audit-log")
    assert has_element?(lv, "#organisation-notices #instance-reader")

    # Not where they are a member: their own organisation, and the instance's own.
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.admin.organisation}")
    refute has_element?(lv, "#instance-reader")
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.here}")
    refute has_element?(lv, "#instance-reader")

    # Nor for its own member.
    {:ok, lv, _html} =
      live(log_in_user(build_conn(), home.user), ~p"/#{home.organisation}/settings/people")

    refute has_element?(lv, "#instance-reader")
    refute has_element?(lv, "#organisation-notices")

    # Nobody else reaches it.
    %{user: stranger} = sign_up_fixture()

    assert build_conn()
           |> log_in_user(stranger)
           |> get(~p"/#{home.organisation}/settings/people")
           |> response(404)
  end

  test "an instance admin of a client's operator reads the client as its operator's", _ctx do
    operator = operator_fixture(%{organisation_name: "Hive Ops"})
    client = client_fixture(operator.scope, "Acme")
    {:ok, _} = Apiary.Organisations.grant_instance_admin(operator.user)

    {:ok, lv, _html} =
      live(log_in_user(build_conn(), operator.user), ~p"/#{client.organisation}")

    # One notice, the operator's, as before: never both.
    assert has_element?(
             lv,
             "#organisation-notices #operator-reader",
             "You read Acme as a person of Hive Ops, its operator: everything here can be read, and nothing changed."
           )

    refute has_element?(lv, "#instance-reader")
  end

  test "a person who manages nobody sees no Clients or Instance entry", ctx do
    # The instance organisation an operator, as the first sign-up of an instance with
    # `managed_organisations` makes it.
    make_instance_organisation_an_operator(ctx.admin)
    %{user: user, organisation: organisation} = sign_up_fixture()
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), ~p"/#{organisation}")
    assert has_element?(lv, "aside#sidebar[aria-label='Organisation']")
    refute has_element?(lv, "#nav-clients")
    refute has_element?(lv, "#brand-menu-instance")

    # An admin of the instance organisation, which has no clients of its own: neither.
    %{user: admin} = member_fixture(ctx.admin.instance_scope, :admin)
    {:ok, lv, _html} = live(log_in_user(build_conn(), admin), ~p"/#{ctx.here}")
    refute has_element?(lv, "#nav-clients")
    refute has_element?(lv, "#brand-menu-instance")

    # Its owners, the instance admins, find the Instance in the Qory Apiary menu, wherever
    # they are, and no entry of it in the sidebar; no Clients while it has none, which
    # the Instance's Organisations lead to.
    {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.here}")
    refute has_element?(lv, "#nav-clients")
    refute has_element?(lv, "#nav-group-operator")
    refute has_element?(lv, "#nav-instance")
    assert has_element?(lv, ~s(#brand-menu-instance[href="/instance/general"]))

    {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.admin.organisation}")
    assert has_element?(lv, ~s(#brand-menu-instance[href="/instance/general"]))

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
    render_async(lv)

    assert has_element?(
             lv,
             "#organisation-#{ctx.here.id}-clients[href='/#{ctx.here.slug}/clients']",
             "0 clients"
           )
  end

  test "an instance admin made a member moves to / from the open page, without a click", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
    render_async(lv)
    assert has_element?(lv, "#organisation-#{ctx.here.id}-kind")

    %{instance_scope: other} = instance_admin_fixture()

    {:ok, _member} =
      Apiary.Organisations.set_member_level(
        other,
        ctx.admin.instance_scope.membership.id,
        :member
      )

    assert_redirect(lv, "/")
  end

  test "an instance admin removed while their scope is in the instance organisation moves to /",
       ctx do
    # The membership of the scope is gone, so `ApiaryWeb.UserAuth.reload_scope/1` sends
    # the page to `/`, before and after the page mounts on the core's Access check.
    workspace = workspace_fixture(ctx.here)
    conn = put_session(ctx.conn, :last_workspace_id, workspace.id)

    {:ok, lv, _html} = live(conn, ~p"/instance/organisations")
    render_async(lv)

    assert :sys.get_state(lv.pid).socket.assigns.current_scope.organisation.id == ctx.here.id

    %{instance_scope: other} = instance_admin_fixture()

    {:ok, _removed} =
      Apiary.Organisations.remove_member(other, ctx.admin.instance_scope.membership.id)

    assert_redirect(lv, "/")
  end

  describe "suspending an organisation" do
    test "an instance admin suspends an operator after confirming, and activates it", ctx do
      operator = operator_fixture(%{organisation_name: "Hive Ops"})
      id = operator.organisation.id

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)

      # Never the instance organisation.
      refute has_element?(lv, "#organisation-#{ctx.here.id}-suspend-button")
      refute has_element?(lv, "#organisation-#{ctx.here.id}-transfer-button")

      lv |> element("#organisation-#{id}-suspend-button") |> render_click()
      assert_patch(lv, ~p"/instance/organisations/#{id}/suspend")

      assert has_element?(
               lv,
               "#organisation-#{id}.q-confirming #suspend-organisation",
               "access keys are refused"
             )

      assert has_element?(lv, "#suspend-organisation-question", "Suspend Hive Ops?")
      assert has_element?(lv, "#suspend-operator-clients", "keep running")

      # Cancel gives the row back; its path asks again.
      lv |> element("#suspend-organisation-cancel") |> render_click()
      assert_patch(lv, ~p"/instance/organisations")
      refute has_element?(lv, "#suspend-organisation")
      lv |> element("#organisation-#{id}-suspend-button") |> render_click()

      lv |> element("#suspend-organisation-confirm") |> render_click()
      assert_patch(lv, ~p"/instance/organisations")
      assert render(lv) =~ "Hive Ops is suspended."
      assert Repo.get!(Tenant, id).suspended_at

      render_async(lv)
      assert has_element?(lv, "#organisation-#{id}-status", "Suspended")
      refute has_element?(lv, "#organisation-#{id}-suspend-button")

      lv |> element("#organisation-#{id}-activate-button") |> render_click()
      assert render(lv) =~ "Hive Ops is active again."
      refute Repo.get!(Tenant, id).suspended_at
      render_async(lv)
      assert has_element?(lv, "#organisation-#{id}-status", "In use")
    end

    test "an organisation that is no operator is told nothing of clients", ctx do
      %{organisation: organisation} = sign_up_fixture()

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{organisation.id}/suspend")
      render_async(lv)
      assert has_element?(lv, "#organisation-#{organisation.id} #suspend-organisation")
      refute has_element?(lv, "#suspend-operator-clients")
    end
  end

  describe "the arbiter's transfer" do
    test "offers the ownership of a client whose owners are all suspended to one of its admins, with a reason",
         ctx do
      operator = operator_fixture(%{organisation_name: "Hive Ops"})
      client = client_fixture(operator.scope, "Acme")
      %{membership: admin, user: admin_user} = member_fixture(client.owner.scope, :admin)
      id = client.organisation.id

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)
      # Its owner may act: the instance does not overrule them.
      refute has_element?(lv, "#organisation-#{operator.organisation.id}-transfer-button")
      refute has_element?(lv, "#organisation-#{id}-transfer-button")

      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, client.owner.user.id)
      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)

      lv |> element("#organisation-#{id}-transfer-button") |> render_click()
      assert_patch(lv, ~p"/instance/organisations/#{id}/transfer")
      render_async(lv)
      # A page of the instance, never a dialog.
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Transfer ownership")
      assert page_title(lv) =~ "Transfer ownership · Instance settings"
      assert has_element?(lv, "#transfer-form", admin_user.email)

      # A reason is required.
      html =
        lv
        |> form("#transfer-form", transfer: %{membership_id: admin.id, reason: " "})
        |> render_submit()

      assert html =~ "is required, and at most 500 characters"
      refute Repo.get_by(Transfer, organisation_id: id)

      lv
      |> form("#transfer-form",
        transfer: %{membership_id: admin.id, reason: "The owner is away."}
      )
      |> render_submit()

      assert_patch(lv, ~p"/instance/organisations")
      assert render(lv) =~ "The ownership is offered to #{admin_user.email}."

      assert %Transfer{arbitrated: true, reason: "The owner is away."} =
               Repo.get_by(Transfer, organisation_id: id)
    end

    test "answers an admin not chosen and a reason not given under their fields, at once",
         ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{membership: admin} = member_fixture(client.owner.scope, :admin)
      id = client.organisation.id
      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, client.owner.user.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{id}/transfer")
      render_async(lv)

      lv |> form("#transfer-form", transfer: %{reason: ""}) |> render_submit()

      assert has_element?(lv, "#transfer_membership_id-error", "choose an admin to offer it to")
      assert has_element?(lv, ~s|#transfer_membership_id[aria-invalid="true"]|)
      assert has_element?(lv, "#transfer_reason-error", "is required, and at most 500 characters")
      refute Repo.get_by(Transfer, organisation_id: id)

      # A change answers each field again: the reason given, the admin still not chosen.
      lv |> form("#transfer-form", transfer: %{reason: "The owner is away."}) |> render_change()

      assert has_element?(lv, "#transfer_membership_id-error", "choose an admin to offer it to")
      refute has_element?(lv, "#transfer_reason-error")

      # A reason alone still lacks the admin.
      lv |> form("#transfer-form", transfer: %{reason: "The owner is away."}) |> render_submit()

      assert has_element?(lv, "#transfer_membership_id-error", "choose an admin to offer it to")
      refute has_element?(lv, "#transfer_reason-error")
      refute Repo.get_by(Transfer, organisation_id: id)

      # Choosing the admin takes its error away.
      lv
      |> form("#transfer-form",
        transfer: %{membership_id: admin.id, reason: "The owner is away."}
      )
      |> render_change()

      refute has_element?(lv, "#transfer_membership_id-error")
      refute has_element?(lv, "#transfer_reason-error")

      # With no error left, a field made wrong again is answered again.
      lv
      |> form("#transfer-form", transfer: %{membership_id: admin.id, reason: ""})
      |> render_change()

      assert has_element?(lv, "#transfer_reason-error", "is required, and at most 500 characters")
      refute Repo.get_by(Transfer, organisation_id: id)
    end

    test "answers a field sent as anything but text as not given, and stays up", ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{membership: admin} = member_fixture(client.owner.scope, :admin)
      id = client.organisation.id
      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, client.owner.user.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{id}/transfer")
      render_async(lv)

      forged = %{"x" => "y"}

      render_submit(lv, "transfer", %{
        "transfer" => %{"membership_id" => forged, "reason" => forged}
      })

      assert has_element?(lv, "#transfer_membership_id-error", "choose an admin to offer it to")
      assert has_element?(lv, "#transfer_reason-error", "is required, and at most 500 characters")

      render_change(lv, "validate_transfer", %{
        "transfer" => %{"membership_id" => admin.id, "reason" => forged}
      })

      refute has_element?(lv, "#transfer_membership_id-error")
      assert has_element?(lv, "#transfer_reason-error")

      render_submit(lv, "transfer", %{
        "transfer" => %{"membership_id" => forged, "reason" => "The owner is away."}
      })

      assert has_element?(lv, "#transfer_membership_id-error", "choose an admin to offer it to")
      refute has_element?(lv, "#transfer_reason-error")

      render_change(lv, "validate_transfer", %{"transfer" => "forged"})
      assert has_element?(lv, "#transfer_membership_id-error")
      assert has_element?(lv, "#transfer_reason-error")

      assert Process.alive?(lv.pid)
      refute Repo.get_by(Transfer, organisation_id: id)
    end

    test "answers an admin who stopped being one meanwhile under the field, and offers the others",
         ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{membership: gone, user: gone_user} = member_fixture(client.owner.scope, :admin)
      %{user: other_user} = member_fixture(client.owner.scope, :admin)
      id = client.organisation.id
      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, client.owner.user.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{id}/transfer")
      render_async(lv)
      assert has_element?(lv, "#transfer-form", gone_user.email)

      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, gone_user.id)

      lv
      |> form("#transfer-form", transfer: %{membership_id: gone.id, reason: "The owner is away."})
      |> render_submit()

      assert has_element?(
               lv,
               "#transfer_membership_id-error",
               "is no longer an admin who can act: choose another"
             )

      refute has_element?(lv, "#transfer-form", gone_user.email)
      assert has_element?(lv, "#transfer-form", other_user.email)
      refute Repo.get_by(Transfer, organisation_id: id)
    end

    test "says so when there is no admin to offer it to", ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, client.owner.user.id)

      {:ok, lv, _html} =
        live(ctx.conn, ~p"/instance/organisations/#{client.organisation.id}/transfer")

      render_async(lv)
      assert has_element?(lv, "#transfer-no-admin")
      refute has_element?(lv, "#transfer-confirm")
    end

    test "Back goes to the list as it was left, its view and search kept", ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      id = client.organisation.id
      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, client.owner.user.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations?view=clients&q=acme")
      render_async(lv)

      lv |> element("#organisation-#{id}-transfer-button") |> render_click()
      assert_patch(lv, ~p"/instance/organisations/#{id}/transfer")
      assert has_element?(lv, "#transfer-no-admin")

      lv |> element("#transfer-back") |> render_click()
      assert_patch(lv, "/instance/organisations?view=clients&q=acme")
      assert has_element?(lv, "#organisations-view-clients[aria-current=page]")
    end

    test "is offered for an organisation only while its owners are suspended", ctx do
      home = sign_up_fixture()
      %{membership: admin} = member_fixture(home.scope, :admin)
      id = home.organisation.id

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)
      refute has_element?(lv, "#organisation-#{id}-transfer-button")

      # Its path all the same: the instance does not overrule an owner who can act.
      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations/#{id}/transfer")
      render_async(lv)

      lv
      |> form("#transfer-form", transfer: %{membership_id: admin.id, reason: "Asked to."})
      |> render_submit()

      assert render(lv) =~ "It has an owner who can act; the instance does not overrule them."

      {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, home.user.id)

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)
      assert has_element?(lv, "#organisation-#{id}-status", "Owner suspended")
      assert has_element?(lv, "#organisation-#{id}-transfer-button")
    end
  end

  describe "an instance organisation of the kind organisation" do
    # An instance without `managed_organisations`: its first sign-up, inside the test's
    # sandbox, makes the instance organisation an organisation like any other.
    @describetag with_features: Features.all() -- [:managed_organisations]

    setup do
      Apiary.EditionKit.hide_instance_organisation()
      first = sign_up_fixture()

      assert %Tenant{kind: :organisation, instance_organisation: true} =
               tenant_of(first.organisation)

      %{first: first, first_conn: log_in_user(build_conn(), first.user)}
    end

    test "its owners see the Instance's Organisations, and no Clients entry",
         %{first: first} = ctx do
      {:ok, lv, _html} = live(ctx.first_conn, ~p"/instance/organisations")
      render_async(lv)

      assert has_element?(lv, "#instance-tab-organisations")
      refute has_element?(lv, "#nav-clients")
      assert has_element?(lv, "#organisation-#{first.organisation.id}-kind", "Organisation")
      assert has_element?(lv, "#organisation-#{first.organisation.id}-kind", "The instance owner")
      # No operator without the feature: no change of kind, and no operator to create.
      refute has_element?(lv, "#organisation-#{first.organisation.id}-kind-button")

      assert ctx.first_conn |> get(~p"/#{first.organisation}/clients") |> response(404)
    end

    test "they create an organisation and read another, as the instance admins", ctx do
      home = sign_up_fixture()

      {:ok, lv, _html} = live(ctx.first_conn, ~p"/instance/organisations")
      render_async(lv)
      assert has_element?(lv, "#organisation-#{home.organisation.id}-purge-button")
      assert has_element?(lv, "#organisation-#{home.organisation.id}-suspend-button")
      assert has_element?(lv, "#organisation-#{home.organisation.id}-features-button")

      lv |> element("#new-organisation") |> render_click()
      refute has_element?(lv, "#organisation-form input[type=radio][value=operator]")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> form("#organisation-form", organisation: %{name: "Newco"})
               |> render_submit()

      newco = Repo.get_by!(Organisation, name: "Newco")
      assert tenant_of(newco).kind == :organisation
      assert to == ~p"/#{newco}"

      {:ok, lv, _html} = live(ctx.first_conn, ~p"/#{home.organisation}/settings/people")
      assert has_element?(lv, "#organisation-notices #instance-reader")
    end

    test "once the instance has managed_organisations, an instance admin makes it an operator, and its Clients entry comes",
         %{first: first} = ctx do
      features_on!(Features.all())

      # Never offered to an operator: no Ownership section, where another organisation has
      # one.
      {:ok, lv, _html} = live(ctx.first_conn, ~p"/#{first.organisation}/settings")
      refute has_element?(lv, "#settings-tab-ownership")
      home = sign_up_fixture()

      {:ok, lv, html} =
        live(log_in_user(build_conn(), home.user), ~p"/#{home.organisation}/settings")

      assert has_element?(lv, "#settings-tabs #settings-tab-ownership")
      # The edition's section joins the organisation's after the core's; no danger zone is listed.
      assert html =~ ~r/id="settings-tab-workspaces".*id="settings-tab-ownership"/s
      refute has_element?(lv, "#settings-tab-danger")

      {:ok, lv, _html} = live(ctx.first_conn, ~p"/instance/organisations")
      render_async(lv)
      refute has_element?(lv, "#nav-clients")

      # The item is named by its words alone, in the menu named for the organisation.
      assert has_element?(
               lv,
               "#organisation-#{first.organisation.id}-kind-button:not([aria-label])",
               "Make operator…"
             )

      assert has_element?(
               lv,
               "[role=menu][aria-label='Actions for #{first.organisation.name}'] #organisation-#{first.organisation.id}-kind-button"
             )

      lv |> element("#organisation-#{first.organisation.id}-kind-button") |> render_click()
      assert_patch(lv, ~p"/instance/organisations/#{first.organisation.id}/kind")
      lv |> element("#kind-confirm") |> render_click()

      assert %Tenant{kind: :operator, instance_organisation: true} = tenant_of(first.organisation)

      # Its Clients entry comes with its first client; until then the Instance's
      # Organisations lead to its clients.
      {:ok, lv, _html} = live(ctx.first_conn, ~p"/#{first.organisation}")
      refute has_element?(lv, "#nav-clients")
      assert has_element?(lv, "#brand-menu-instance")
      {:ok, _lv, _html} = live(ctx.first_conn, ~p"/#{first.organisation}/clients")
    end
  end

  # The instance's features switched for the rest of the test, and back after.
  defp features_on!(features) do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
  end
end
