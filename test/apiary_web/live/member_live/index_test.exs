defmodule ApiaryWeb.MemberLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  describe "as an owner" do
    setup :register_and_log_in_user

    test "lists the members", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/hive/members")
      assert html =~ user.email
      assert html =~ "you"
      assert html =~ "Invite member"
      assert html =~ ~r/<abbr[^>]*title="team"[^>]*>hive<\/abbr>/
    end

    test "invites a member and can revoke the invitation", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/hive/members")

      lv |> element("a", "Invite member") |> render_click()
      assert_patch(lv, ~p"/hive/members/invite")

      lv
      |> form("#invitation-form", invitation: %{email: "bee@example.com", level: "member"})
      |> render_submit()

      assert_patch(lv, ~p"/hive/members")

      html = render(lv)
      assert html =~ "Invitation sent to bee@example.com"
      assert html =~ "Pending invitations"
      assert [invitation] = Organisations.list_invitations(scope)
      assert has_element?(lv, "#invitation-#{invitation.id}", "bee@example.com")

      lv |> element("#invitation-#{invitation.id} button", "Revoke") |> render_click()
      assert Organisations.list_invitations(scope) == []
      refute has_element?(lv, "#invitation-#{invitation.id}")
    end

    test "refuses to invite an existing member", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/hive/members/invite")

      html =
        lv
        |> form("#invitation-form", invitation: %{email: user.email, level: "member"})
        |> render_submit()

      assert html =~ "already a member"
      assert has_element?(lv, "#invitation-form")
      assert Organisations.list_invitations(scope) == []
    end

    test "changes a member's level and refuses to demote the last owner", %{
      conn: conn,
      scope: scope
    } do
      %{membership: membership} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(conn, ~p"/hive/members")

      html = lv |> form("#level-form-#{membership.id}", %{level: "owner"}) |> render_change()
      assert html =~ "is now an owner"

      html = lv |> form("#level-form-#{membership.id}", %{level: "member"}) |> render_change()
      assert html =~ "is now a member"

      html =
        lv |> form("#level-form-#{scope.membership.id}", %{level: "member"}) |> render_change()

      assert html =~ "The last owner cannot be demoted"
      assert Organisations.owner?(Organisations.load_scope(scope))
    end

    test "removes a member and refuses to remove the last owner", %{conn: conn, scope: scope} do
      %{membership: membership, user: member} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(conn, ~p"/hive/members")

      lv |> element("#member-#{membership.id} a", "Remove") |> render_click()
      assert_patch(lv, ~p"/hive/members/#{membership.id}/remove")
      assert render(lv) =~ "They lose access"

      lv |> element("#remove-member button", "Remove member") |> render_click()
      assert_patch(lv, ~p"/hive/members")

      html = render(lv)
      assert html =~ "#{member.email} is removed"
      refute has_element?(lv, "#member-#{membership.id}")

      own = scope.membership
      lv |> element("#member-#{own.id} a", "Remove") |> render_click()
      assert render(lv) =~ "You will leave"

      lv |> element("#remove-member button", "Remove member") |> render_click()
      assert render(lv) =~ "The last owner cannot be removed"
      assert has_element?(lv, "#member-#{own.id}")
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), user: user, scope: scope, owner: owner}
    end

    test "sees the page read-only", %{conn: conn, owner: owner, user: user} do
      {:ok, lv, html} = live(conn, ~p"/hive/members")

      assert html =~ owner.user.email
      assert html =~ user.email
      assert html =~ "Owner"
      assert html =~ "Member"
      refute html =~ "Invite member"
      refute html =~ "Pending invitations"
      refute has_element?(lv, "a", "Remove")
      refute has_element?(lv, "form[phx-change=set_level]")
    end

    test "cannot open the invite or remove dialogs", %{conn: conn, owner: owner} do
      assert {:error, {_, %{to: "/hive/members"}}} = live(conn, ~p"/hive/members/invite")

      assert {:error, {_, %{to: "/hive/members"}}} =
               live(conn, ~p"/hive/members/#{owner.membership.id}/remove")
    end
  end
end
