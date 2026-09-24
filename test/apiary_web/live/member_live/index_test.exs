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
      assert html =~ "You"
      assert html =~ "Invite member"
      assert html =~ "The people in this workplace."
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

      assert html =~ "The last owner cannot be removed or demoted"
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
      assert render(lv) =~ "The last owner cannot be removed or demoted"
      assert has_element?(lv, "#member-#{own.id}")
    end
  end

  describe "M1: a page opened before the owner lost their rights" do
    setup %{conn: conn} do
      founder = sign_up_fixture()
      %{user: user, scope: scope, membership: membership} = member_fixture(founder.scope, :owner)
      %{membership: third} = member_fixture(founder.scope, :member)

      %{
        conn: log_in_user(conn, user),
        founder: founder,
        scope: scope,
        membership: membership,
        third: third
      }
    end

    test "a demoted owner's open page can no longer set levels, remove or invite", %{
      conn: conn,
      founder: founder,
      membership: membership,
      third: third
    } do
      {:ok, lv, html} = live(conn, ~p"/hive/members")
      assert html =~ "level-form-#{third.id}"

      assert {:ok, _} = Organisations.set_member_level(founder.scope, membership.id, :member)

      # The page follows the change: the owner controls are gone.
      html = render(lv)
      refute html =~ "level-form-#{third.id}"
      refute html =~ "Invite member"

      # And the events a stale page could still send are refused.
      html = render_hook(lv, "set_level", %{"membership_id" => third.id, "level" => "owner"})
      assert html =~ "Only owners can manage members"
      assert Apiary.Repo.get!(Organisations.Membership, third.id).level == :member

      render_hook(lv, "invite", %{
        "invitation" => %{"email" => "late@example.com", "level" => "owner"}
      })

      assert Organisations.list_invitations(founder.scope) == []
    end

    test "without the announcement the stale page is still refused", %{
      conn: conn,
      membership: membership,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive/members")

      # Demoted behind the page's back: no broadcast reaches it.
      membership |> Ecto.Changeset.change(level: :member) |> Apiary.Repo.update!()

      html = lv |> form("#level-form-#{third.id}", %{level: "owner"}) |> render_change()
      assert html =~ "Only owners can manage members"
      assert Apiary.Repo.get!(Organisations.Membership, third.id).level == :member
    end

    test "a removed member's open page is sent to /hive", %{
      conn: conn,
      founder: founder,
      membership: membership
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive/members")
      assert {:ok, _} = Organisations.remove_member(founder.scope, membership.id)
      assert_redirect(lv, ~p"/hive")
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
