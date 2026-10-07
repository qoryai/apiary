defmodule ApiaryWeb.MemberLive.WorkspaceTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  defp people_path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/people"

  describe "as an owner" do
    setup :register_and_log_in_user

    test "lists who reaches the workspace, read only, and leads to the organisation's People",
         %{conn: conn, user: user, scope: scope} do
      %{user: admin, membership: admin_membership} = member_fixture(scope, :admin)
      %{user: member, membership: membership} = member_fixture(scope, :member)
      %{user: suspended, membership: suspended_membership} = member_fixture(scope, :member)
      {:ok, _} = Organisations.suspend_member(scope, suspended_membership.id)

      {:ok, lv, _html} = live(conn, people_path(scope))

      # A section of the workspace's settings, under the workspace's sidebar.
      assert has_element?(lv, "#main h1", "Workspace settings")
      assert has_element?(lv, "#settings-tab-people[aria-current=page]", "People")
      assert has_element?(lv, "h2#settings-section-title", "People")
      assert has_element?(lv, ".q-sidebar-foot #nav-settings[aria-current='true']")
      assert page_title(lv) =~ "People · Workspace settings"

      assert has_element?(
               lv,
               "#settings-section-people .q-settings-head-sub",
               "The people who reach this workspace, and at what level"
             )

      # One row each, on the organisation People's row spec: the reader's own says so.
      assert has_element?(lv, "#member-#{scope.membership.id} .q-title", user.email)
      assert has_element?(lv, "#member-#{scope.membership.id} .q-side", "you")
      assert has_element?(lv, "#member-#{scope.membership.id}-level", "Owner")
      assert has_element?(lv, "#member-#{admin_membership.id}-level", "Admin")
      assert has_element?(lv, "#member-#{membership.id}-level", "Member")
      assert has_element?(lv, "#members", admin.email)
      assert has_element?(lv, "#members", member.email)

      # A suspended membership reaches nothing.
      refute has_element?(lv, "#member-#{suspended_membership.id}")
      refute render(lv) =~ suspended.email

      # Read only: no menu, no level to choose, no invitation.
      refute has_element?(lv, "#members [phx-click]")
      refute has_element?(lv, "#member-#{membership.id}-menu")
      refute has_element?(lv, "#invite-people")

      # Membership is the organisation's, where the owner is led.
      assert has_element?(
               lv,
               "#settings-section-people a#manage-people[href='/#{scope.organisation.slug}/settings/people']",
               "Manage people"
             )
    end

    test "finds a person by their email, the search in the URL", %{conn: conn, scope: scope} do
      %{user: other} = member_fixture(scope, :member)
      {:ok, lv, _html} = live(conn, people_path(scope))
      assert has_element?(lv, "#people-search-input[type=search]")
      assert has_element?(lv, "#people-status[role=status]")
      refute has_element?(lv, "#people-summary")

      needle = other.email |> String.split("@") |> hd() |> String.upcase()
      lv |> form("#people-search", q: needle) |> render_change()
      assert_patch(lv, people_path(scope) <> "?q=#{needle}")
      assert has_element?(lv, "#members", other.email)
      refute has_element?(lv, "#member-#{scope.membership.id}")
      assert has_element?(lv, "#people-summary", "1 person matches")

      lv |> form("#people-search", q: "nobody-here") |> render_change()
      assert has_element?(lv, "#people-none")
      refute has_element?(lv, "#members")

      {:ok, lv, _html} = live(conn, people_path(scope) <> "?q=#{needle}")
      assert has_element?(lv, "#members", other.email)
    end
  end

  describe "as an admin" do
    test "is led to the organisation's People too, until they are an admin no more",
         %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope, membership: membership} = member_fixture(owner.scope, :admin)
      {:ok, lv, _html} = live(log_in_user(conn, user), people_path(scope))

      assert has_element?(lv, "#manage-people")
      assert has_element?(lv, "#member-#{membership.id}-level", "Admin")

      # Their own level changed elsewhere: the open page follows.
      {:ok, _} = Organisations.set_member_level(owner.scope, membership.id, :member)
      refute has_element?(lv, "#manage-people")
      assert has_element?(lv, "#member-#{membership.id}-level", "Member")
    end
  end

  describe "as a member" do
    test "reads who reaches the workspace, with no way to manage them",
         %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :member)
      {:ok, lv, _html} = live(log_in_user(conn, user), people_path(scope))

      assert has_element?(lv, "#member-#{owner.membership.id}-level", "Owner")
      assert has_element?(lv, "#member-#{scope.membership.id} .q-side", "you")
      refute has_element?(lv, "#manage-people")

      refute has_element?(
               lv,
               "#settings-tabs a[href='/#{scope.organisation.slug}/settings/people']"
             )
    end
  end

  test "nobody outside the organisation opens it", %{conn: conn} do
    owner = sign_up_fixture()
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    assert conn |> get(people_path(owner.scope)) |> html_response(404)
  end
end
