defmodule ApiaryProWeb.LayoutsTest do
  @moduledoc """
  The organisation menu under the edition's workspace access: a member is listed only in the
  workspaces they were added to, and an organisation where they reach none is listed on
  its own, leading to its own path. And New workspace, for an owner: in New on an
  organisation's pages, and at the foot of the workspace menu. And the Qory Apiary menu's
  button, which names the product Qory Apiary. And the edition's entries in the
  organisation's sidebar of the core's two-level shell: Policy in the first group, an
  operator's Clients and Policy requests in a group of their own, the settings' sections
  in the second column.
  """
  use ApiaryWeb.ConnCase, async: true

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  setup :register_and_log_in_user

  test "a member is listed in the workspaces they were added to, and an organisation where they reach none on its own",
       %{conn: conn, user: user, scope: scope} do
    other = sign_up_fixture()
    %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
    {:ok, membership} = Organisations.accept_invitation(user, token)
    other_platform = workspace_fixture(other.organisation, "Platform")

    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

    # A member reaches the one workspace they were invited to, not the other.
    assert has_element?(view, "#switch-#{other.organisation.slug}_#{other.workspace.slug}")
    refute has_element?(view, "#switch-#{other.organisation.slug}_#{other_platform.slug}")

    # Removed from their one workspace there, the organisation is listed on its own, with
    # no workspace, and its link leads to its own path.
    {:ok, _} = ApiaryPro.WorkspaceAccess.remove(other.scope, membership.id, other.workspace.id)

    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

    href = "/#{other.organisation.slug}/-/switch/overview"

    assert has_element?(
             view,
             "#organisation-menu a#switch-#{other.organisation.slug}[href='#{href}']"
           )

    assert has_element?(
             view,
             "#organisation-menu-of-#{other.organisation.slug}",
             "No workspace yet"
           )

    refute has_element?(view, "#organisation-menu-of-#{other.organisation.slug} a")
    assert redirected_to(get(conn, href)) == "/#{other.organisation.slug}"
  end

  test "New offers a workspace on an organisation's pages, to an owner, before the core's",
       %{conn: conn, scope: scope} do
    {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/settings")

    assert has_element?(
             view,
             "#new-menu a#new-menu-workspace[role='menuitem'][href='/#{scope.organisation.slug}/workspaces/new']",
             "New workspace"
           )

    assert has_element?(view, "#new-menu a#new-menu-invite")

    [first, second] =
      Regex.scan(~r/id="new-menu-(workspace|invite)"/, html) |> Enum.map(&List.last/1)

    assert {first, second} == {"workspace", "invite"}

    # not on a workspace's pages, where New is the workspace's
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    refute has_element?(view, "#new-menu-workspace")
    assert has_element?(view, "#new-menu-node")

    # an admin adds no workspace
    %{user: admin} = member_fixture(scope, :admin)

    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), ~p"/#{scope.organisation}/settings")

    refute has_element?(view, "#new-menu-workspace")
    assert has_element?(view, "#new-menu-invite")
  end

  test "the workspace menu offers New workspace to whoever may add one to the organisation",
       %{conn: conn, scope: scope} do
    org = scope.organisation.slug
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

    # An owner: the menu is there for its entry, with one workspace too.
    assert has_element?(view, "button#workspace-menu-button[aria-controls='workspace-menu']")

    assert has_element?(
             view,
             "#workspace-menu .q-switcher-foot a#workspace-menu-new[href='/#{org}/workspaces/new']",
             "New workspace"
           )

    assert [%{key: :new}] = ApiaryWeb.Edition.workspace_switcher_entries(scope)

    # An admin and a member add no workspace: their menu, of the two workspaces they
    # reach, has no entry.
    platform = workspace_fixture(scope.organisation, "Platform")

    for level <- [:admin, :member] do
      %{user: user, membership: membership} = member_fixture(scope, level)

      if level == :member do
        {:ok, _} = ApiaryPro.WorkspaceAccess.add(scope, membership.id, platform.id)
      end

      assert ApiaryWeb.Edition.workspace_switcher_entries(workspace_scope(user, platform)) == []

      {:ok, view, _html} =
        live(log_in_user(build_conn(), user), ~p"/#{scope.organisation}/#{platform}")

      assert has_element?(view, "#workspace-menu")
      refute has_element?(view, "#workspace-menu-new")
      refute has_element?(view, "#workspace-menu .q-switcher-foot")
    end
  end

  test "the Qory Apiary menu's button names the product Qory Apiary",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

    assert ApiaryWeb.Edition.product_name() == "Qory Apiary"

    assert has_element?(
             view,
             "#brand-menu button#brand-menu-button[aria-label='Qory Apiary menu'] .q-brand-name",
             "Qory Apiary"
           )
  end

  @tag with_features: Apiary.Features.all()
  test "an operator's sidebar: Policy after Overview, its own group, and the settings beside" do
    operator = ApiaryPro.OperatorsFixtures.operator_fixture()
    ApiaryPro.OperatorsFixtures.client_fixture(operator.scope)
    org = operator.organisation.slug

    {:ok, view, html} =
      live(log_in_user(build_conn(), operator.user), ~p"/#{org}/settings")

    # The first group, without a heading: Overview first, Policy last.
    ids =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#sidebar nav#nav-group-home[aria-label=Main] a[id^='nav-']")
      |> LazyHTML.attribute("id")

    assert hd(ids) == "nav-organisation_overview"
    assert List.last(ids) == "nav-organisation_policy"
    refute has_element?(view, "#nav-group-guard")

    # The operator's group, under its heading, Clients with its number.
    assert has_element?(view, "#sidebar nav#nav-group-operator[aria-label=Operator]")
    assert has_element?(view, "#nav-group-operator #nav-clients[href='/#{org}/clients']", "1")
    assert has_element?(view, "#nav-group-operator #nav-client_requests")

    # Settings' sections are the frame's second column, beside the page, not in it.
    refute has_element?(view, "#main #settings-tabs")

    assert has_element?(
             view,
             "#shell-content > nav#settings-tabs a#settings-tab-organisation[aria-current='page']"
           )

    # Nothing to say about this organisation: no notices at all.
    refute has_element?(view, "#organisation-notices")
  end
end
