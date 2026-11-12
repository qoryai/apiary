defmodule ApiaryProWeb.MemberLive.WorkspacesTest do
  @moduledoc """
  A member's workspaces: under each member on the People page, the workspaces they
  reach of those the reader reaches, and their own page, where an owner or an admin adds
  them to a workspace or removes them from one.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias ApiaryProWeb.Trail

  defp workspaces(scope, membership),
    do: ~p"/#{scope.organisation}/settings/people/#{membership.id}/workspaces"

  describe "as an owner" do
    setup :register_and_log_in_user

    test "People says an owner reaches every workspace", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert has_element?(lv, "#member-#{scope.membership.id}-workspaces", "Every workspace")
    end

    test "a demotion names the workspace the person keeps", %{conn: conn, scope: scope} do
      _platform = workspace_fixture(scope.organisation, "Platform")
      %{membership: owner, user: user} = member_fixture(scope, :owner)

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      html = lv |> element("#member-#{owner.id}-level-member") |> render_click()
      assert html =~ "#{user.email} is now a member."
      assert has_element?(lv, "#member-#{owner.id}-workspaces", scope.workspace.name)
      refute has_element?(lv, "#member-#{owner.id}-workspaces", "Platform")
    end

    test "lists a member's workspaces, and adds them to one and removes them from it", %{
      conn: conn,
      scope: scope
    } do
      second = workspace_fixture(scope.organisation, "Platform")
      %{membership: membership, user: member} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert has_element?(lv, "#member-#{membership.id}-workspaces", scope.workspace.name)
      refute has_element?(lv, "#member-#{membership.id}-workspaces", "Platform")
      # An owner reaches every workspace: there is nothing to add them to.
      refute has_element?(lv, "#member-#{scope.membership.id}-manage-workspaces")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#member-#{membership.id}-manage-workspaces") |> render_click()

      assert to == workspaces(scope, membership)
      {:ok, lv, _html} = live(conn, to)
      assert has_element?(lv, "#member-workspace-#{scope.workspace.id}-act", "Remove")
      # Its title names the member, the level and the organisation, as the core's form
      # pages name theirs: the act, not the section.
      assert page_title(lv) ==
               "Workspaces of #{member.email} · Organisation settings · #{scope.organisation.name} · Qory Apiary"

      # A page of People: the frame writes the level and People, the page only Workspaces;
      # each row the workspace's name and slug, and whether the member is added.
      assert Trail.crumbs(lv) == ["Organisation settings", "People", "Workspaces"]

      assert has_element?(
               lv,
               "#breadcrumb a#breadcrumb-section[href='#{~p"/#{scope.organisation}/settings/people"}']",
               "People"
             )

      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Workspaces")
      # People, the section the page is in, is current as the parent of the page.
      assert has_element?(lv, "#settings-tab-people[aria-current=true]")
      # A form page's head: the page's title as its h1, and no Back beside it (the
      # breadcrumb's People leads back); no Done.
      assert has_element?(lv, "h1#member-workspaces-page-title", "Workspaces of #{member.email}")
      refute has_element?(lv, "#member-workspaces-page-back")
      refute has_element?(lv, "#member-workspaces-done")

      assert has_element?(
               lv,
               "#member-workspace-#{second.id} .q-side",
               second.slug
             )

      assert has_element?(lv, "#member-workspace-#{second.id}-reach", "Not added")
      assert has_element?(lv, "#member-workspace-#{scope.workspace.id}-reach", "Added")

      # One button a row, the same one after it acts, its words and event following the
      # reach.
      assert has_element?(
               lv,
               "#member-workspace-#{second.id}-act[phx-click=add_workspace]" <>
                 "[aria-label='Add #{member.email} to Platform']",
               "Add"
             )

      lv |> element("#member-workspace-#{second.id}-act") |> render_click()
      assert render(lv) =~ "#{member.email} is added to Platform."

      assert has_element?(
               lv,
               "#member-workspace-#{second.id}-act[phx-click=remove_workspace]" <>
                 "[aria-label='Remove #{member.email} from Platform']",
               "Remove"
             )

      assert workspace_scope(member, second)

      lv |> element("#member-workspace-#{scope.workspace.id}-act") |> render_click()
      assert render(lv) =~ "#{member.email} is removed from #{scope.workspace.name}."
      assert has_element?(lv, "#member-workspace-#{scope.workspace.id}-act", "Add")
      refute workspace_scope(member, scope.workspace)

      lv |> element("#member-workspace-#{second.id}-act") |> render_click()

      assert {:error, {:live_redirect, %{to: members}}} =
               lv |> element("a#breadcrumb-section", "People") |> render_click()

      {:ok, lv, _html} = live(conn, members)
      assert has_element?(lv, "#member-#{membership.id}-workspaces", "No workspace yet")
    end

    test "an owner or an admin has no workspaces to manage", %{conn: conn, scope: scope} do
      %{membership: admin} = member_fixture(scope, :admin)
      members = ~p"/#{scope.organisation}/settings/people"

      assert has_element?(
               elem(live(conn, members), 1),
               "#member-#{admin.id}-workspaces",
               "Every workspace"
             )

      assert {:error, {_, %{to: ^members, flash: %{"info" => info}}}} =
               live(conn, workspaces(scope, admin))

      assert info =~ "reaches every workspace"
    end

    test "a member who is gone sends the page back", %{conn: conn, scope: scope} do
      %{membership: membership} = member_fixture(scope, :member)
      {:ok, lv, _html} = live(conn, workspaces(scope, membership))
      {:ok, _} = Organisations.remove_member(scope, membership.id)

      render_click(lv, "add_workspace", %{"workspace" => scope.workspace.id})
      assert {path, flash} = assert_redirect(lv)
      assert path == ~p"/#{scope.organisation}/settings/people"
      assert flash["error"] =~ "no longer in the organisation"
    end
  end

  describe "as an admin" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :admin)
      %{membership: other_admin} = member_fixture(owner.scope, :admin)
      %{membership: member} = member_fixture(owner.scope, :member)

      %{conn: log_in_user(conn, user), scope: scope, other_admin: other_admin, member: member}
    end

    test "manages the workspaces of members only", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings/people")
      assert has_element?(lv, "#member-#{ctx.member.id}-manage-workspaces")
      refute has_element?(lv, "#member-#{ctx.other_admin.id}-manage-workspaces")
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), user: user, scope: scope, owner: owner}
    end

    test "is offered no workspaces to manage, and the path refuses them", ctx do
      %{conn: conn, scope: scope} = ctx
      members = ~p"/#{scope.organisation}/settings/people"
      {:ok, lv, _html} = live(conn, members)
      refute has_element?(lv, "[id$=-manage-workspaces]")

      assert {:error, {_, %{to: ^members, flash: %{"error" => error}}}} =
               live(conn, workspaces(scope, scope.membership))

      assert error =~ "Only owners and admins manage members"
    end

    test "sees only the workspaces they reach", %{conn: conn, owner: owner, scope: scope} do
      second = workspace_fixture(scope.organisation, "Platform")
      %{membership: other} = member_fixture(owner.scope, :member)
      {:ok, _} = ApiaryPro.WorkspaceAccess.add(owner.scope, other.id, second.id)
      %{membership: elsewhere} = member_fixture(owner.scope, :member)
      {:ok, _} = ApiaryPro.WorkspaceAccess.add(owner.scope, elsewhere.id, second.id)

      {:ok, _} =
        ApiaryPro.WorkspaceAccess.remove(owner.scope, elsewhere.id, scope.workspace.id)

      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert has_element?(lv, "#member-#{other.id}-workspaces", scope.workspace.name)
      refute html =~ "Platform"
      # In a workspace the reader does not reach: not "none", but none they can see.
      assert has_element?(lv, "#member-#{elsewhere.id}-workspaces", "None you can see")
    end
  end

  describe "as a member added to no workspace" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, membership: membership} = member_fixture(owner.scope, :member)

      {:ok, _} =
        ApiaryPro.WorkspaceAccess.remove(owner.scope, membership.id, owner.workspace.id)

      %{conn: log_in_user(conn, user), owner: owner, membership: membership}
    end

    test "sees the members, and themselves in no workspace", ctx do
      {:ok, lv, html} = live(ctx.conn, ~p"/#{ctx.owner.organisation}/settings/people")

      assert html =~ ctx.owner.user.email
      assert has_element?(lv, "#member-#{ctx.membership.id}-workspaces", "No workspace yet")
      refute html =~ "Invite member"
      # Nor the workspace they are not in, beside the owner.
      assert has_element?(lv, "#member-#{ctx.owner.membership.id}-workspaces", "Every workspace")
      refute has_element?(lv, "#nav-runs")
    end
  end
end
