defmodule ApiaryWeb.MemberLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
  alias Apiary.Organisations.Membership

  describe "as an owner" do
    setup :register_and_log_in_user

    test "lists the members", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert html =~ user.email
      assert html =~ "You"
      assert html =~ "Invite people"

      # A member changes the policy's rules only where there is a policy: with `security`.
      if Apiary.Features.on?(:security) do
        assert html =~
                 "The people in this organisation. Owners and admins manage members, settings and nodes; members see the runs and change the policy&#39;s rules that are not locked."
      else
        assert html =~
                 "The people in this organisation. Owners and admins manage members, settings and nodes; members see the runs."

        refute html =~ "policy"
      end

      # Only owners and admins add a node's key: a member manages no keys.
      refute html =~ "manage access keys"
      refute html =~ "Manages access keys"

      assert has_element?(lv, "#member-#{scope.membership.id}")
      # The only owner, reading: the last-owner rule is theirs to hear.
      assert html =~
               "The only owner cannot be removed or demoted until another member is an owner."

      member_fixture(scope, :owner)
      {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      refute html =~ "The only owner cannot be removed"
    end

    test "finds a person by their email, the search in the URL", %{conn: conn, scope: scope} do
      %{user: other} = member_fixture(scope, :member)
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert has_element?(lv, "#people-search-input[type=search]")
      assert has_element?(lv, "#people-status[role=status]")
      refute has_element?(lv, "#people-summary")

      needle = other.email |> String.split("@") |> hd() |> String.upcase()
      lv |> form("#people-search", q: needle) |> render_change()
      assert_patch(lv, ~p"/#{scope.organisation}/settings/people?q=#{needle}")
      assert has_element?(lv, "#members", other.email)
      refute has_element?(lv, "#member-#{scope.membership.id}")
      assert has_element?(lv, "#people-summary", "1 person matches")

      lv |> form("#people-search", q: "nobody-here") |> render_change()
      assert has_element?(lv, "#people-none")
      refute has_element?(lv, "#members")
    end

    test "invites a member and can revoke the invitation", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      lv |> element("#invite-people") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/settings/people/invite")

      # A form page of the section, not a dialog over the list: the section's list beside
      # it, People its parent, the breadcrumb ending with People and the page, Cancel to
      # People, and no bare Back.
      people = ~p"/#{scope.organisation}/settings/people"
      refute has_element?(lv, "#invite-member")
      refute has_element?(lv, "#members")
      assert has_element?(lv, "#settings-tab-people[aria-current=true]")
      refute has_element?(lv, "[aria-current=page]:not(#breadcrumb *)")
      assert has_element?(lv, "h1#invite-title", "Invite people")
      refute has_element?(lv, "#invite-back")
      assert has_element?(lv, "#breadcrumb a[href='#{people}']", "People")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Invite people")
      assert has_element?(lv, "#invitation-form input[type=email][phx-mounted]")
      assert has_element?(lv, "#invitation-save button[type=submit]", "Send invitation")
      assert has_element?(lv, "#invitation-save-cancel[href='#{people}']", "Cancel")
      assert page_title(lv) =~ "Invite people"

      # Cancel goes back to People, sending nothing.
      lv |> element("#invitation-save-cancel") |> render_click()
      assert_patch(lv, people)
      assert has_element?(lv, "#members")
      assert page_title(lv) =~ "People"
      refute page_title(lv) =~ "Invite"
      assert Organisations.list_invitations(scope) == []

      lv |> element("#invite-people") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/settings/people/invite")

      lv
      |> form("#invitation-form", invitation: %{email: "bee@example.com"})
      |> render_submit()

      assert_patch(lv, ~p"/#{scope.organisation}/settings/people")

      html = render(lv)
      assert html =~ "Invitation sent to bee@example.com"
      assert html =~ "Pending invitations"
      # A part of the page under its h1, People.
      assert has_element?(lv, "h2", "Pending invitations")
      refute has_element?(lv, "h3", "Pending invitations")
      assert [invitation] = Organisations.list_invitations(scope)
      assert has_element?(lv, "#invitation-#{invitation.id}", "bee@example.com")

      lv |> element("#invitation-#{invitation.id} button", "Revoke") |> render_click()
      assert Organisations.list_invitations(scope) == []
      refute has_element?(lv, "#invitation-#{invitation.id}")
    end

    test "refuses to invite an existing member", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people/invite")

      html =
        lv
        |> form("#invitation-form", invitation: %{email: user.email})
        |> render_submit()

      # A refused invitation stays on the page, the error under its field.
      assert html =~ "already a member"
      assert has_element?(lv, "#invitation-form")
      assert has_element?(lv, "#invite-title", "Invite people")
      assert Organisations.list_invitations(scope) == []
    end

    test "changes a member's level and refuses to demote the last owner", %{
      conn: conn,
      scope: scope
    } do
      %{membership: membership, user: member} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      # Each level says what it may do: owners and admins manage the nodes and their keys.
      assert has_element?(
               lv,
               "#member-#{membership.id}-level-admin",
               "Manages members, workspaces, nodes and settings"
             )

      assert has_element?(lv, "#member-#{membership.id}-level-member", "Sees the runs")
      refute render(lv) =~ "Manages access keys"

      html = lv |> element("#member-#{membership.id}-level-owner") |> render_click()
      assert html =~ "#{member.email} is now an owner."

      html = lv |> element("#member-#{membership.id}-level-admin") |> render_click()
      assert html =~ "#{member.email} is now an admin."

      html = lv |> element("#member-#{membership.id}-level-member") |> render_click()
      assert html =~ "#{member.email} is now a member."

      html =
        lv |> element("#member-#{scope.membership.id}-level-member") |> render_click()

      assert html =~ "The last owner cannot be removed or demoted"
      assert %{level: :owner} = Organisations.load_scope(scope).membership
    end

    test "removes a member and refuses to remove the last owner", %{conn: conn, scope: scope} do
      %{membership: membership, user: member} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      people = ~p"/#{scope.organisation}/settings/people"
      remove = ~p"/#{scope.organisation}/settings/people/#{membership.id}/remove"
      confirm = "#member-#{membership.id}-remove-confirm"

      lv |> element("#member-#{membership.id} a", "Remove") |> render_click()
      assert_patch(lv, remove)

      # Confirmed in place: the member's row asks, no dialog over the list.
      refute has_element?(lv, "#remove-member")
      assert has_element?(lv, "#member-#{membership.id}.q-confirming #{confirm}")
      assert has_element?(lv, confirm, "Remove #{member.email}?")
      assert has_element?(lv, confirm, "Their account stays")
      refute has_element?(lv, "#member-#{scope.membership.id}.q-confirming")

      # Cancel, and Escape, go back to People, removing no one.
      lv |> element("#{confirm}-cancel") |> render_click()
      assert_patch(lv, people)
      refute has_element?(lv, "#member-#{membership.id}.q-confirming")
      assert has_element?(lv, "#member-#{membership.id}-menu")

      lv |> element("#member-#{membership.id} a", "Remove") |> render_click()
      assert_patch(lv, remove)
      lv |> element(confirm) |> render_keydown(%{"key" => "Escape"})
      assert_patch(lv, people)
      assert Repo.get(Membership, membership.id)

      lv |> element("#member-#{membership.id} a", "Remove") |> render_click()
      assert_patch(lv, remove)
      lv |> element("#{confirm} #remove-confirm", "Yes, remove") |> render_click()
      assert_patch(lv, people)

      html = render(lv)
      assert html =~ "#{member.email} is removed"
      refute has_element?(lv, "#member-#{membership.id}")

      own = scope.membership
      lv |> element("#member-#{own.id}-remove", "Leave") |> render_click()

      assert has_element?(
               lv,
               "#member-#{own.id}-remove-confirm",
               "Leave #{scope.organisation.name}?"
             )

      assert has_element?(lv, "#member-#{own.id}.q-confirming #leave-confirm", "Yes, leave")

      lv |> element("#leave-confirm") |> render_click()
      assert render(lv) =~ "The last owner cannot be removed or demoted"
      assert has_element?(lv, "#member-#{own.id}")
    end
  end

  describe "an invitation's workspace, as an owner" do
    setup :register_and_log_in_user

    test "an invitation sent from another workspace names it, and is revoked from Main", %{
      conn: conn,
      scope: scope
    } do
      platform = workspace_fixture(scope.organisation, "Platform")
      organisation = scope.organisation

      # Opened Platform last: the invitation is sent from it.
      conn = conn |> get(~p"/#{organisation}/#{platform}") |> recycle()
      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/people/invite")

      lv
      |> form("#invitation-form", invitation: %{email: "bee@example.com"})
      |> render_submit()

      assert [invitation] = Organisations.list_invitations(scope)
      assert invitation.workspace_id == platform.id

      # Then Main.
      conn = conn |> get(~p"/#{organisation}/#{scope.workspace}") |> recycle()
      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/people")
      assert has_element?(lv, "#invitation-#{invitation.id}-workspace", "Platform")

      lv |> element("#invitation-#{invitation.id} button", "Revoke") |> render_click()
      assert Organisations.list_invitations(scope) == []
      refute has_element?(lv, "#invitation-#{invitation.id}")
    end
  end

  describe "as an admin" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :admin)
      %{membership: other_admin} = member_fixture(owner.scope, :admin)
      %{membership: member, user: member_user} = member_fixture(owner.scope, :member)

      %{
        conn: log_in_user(conn, user),
        scope: scope,
        owner: owner,
        other_admin: other_admin,
        member: member,
        member_user: member_user
      }
    end

    test "changes no level, and removes and manages members only", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings/people")

      refute has_element?(lv, "[phx-click=set_level]")
      assert has_element?(lv, "#member-#{ctx.member.id}-remove")

      for target <- [ctx.owner.membership, ctx.other_admin] do
        refute has_element?(lv, "#member-#{target.id}-remove")
      end

      # Their own row: they may leave.
      assert has_element?(lv, "#member-#{ctx.scope.membership.id}-remove", "Leave")

      html = render_hook(lv, "set_level", %{"membership_id" => ctx.member.id, "level" => "admin"})
      assert html =~ "Only owners and admins manage members"
      assert Apiary.Repo.get!(Organisations.Membership, ctx.member.id).level == :member

      assert {:error, {_, %{to: _members}}} =
               live(
                 ctx.conn,
                 ~p"/#{ctx.scope.organisation}/settings/people/#{ctx.owner.membership.id}/remove"
               )
    end

    test "invites by address alone, and the person joins as a member", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings/people/invite")

      refute has_element?(lv, "#invitation-form select")
      refute has_element?(lv, "#invitation-form [name='invitation[level]']")

      lv
      |> form("#invitation-form", invitation: %{email: "bee@example.com"})
      |> render_submit()

      assert [%{email: "bee@example.com"}] = Organisations.list_invitations(ctx.owner.scope)

      # A level sent all the same is not read: the invitation is the address.
      render_hook(lv, "invite", %{
        "invitation" => %{"email" => "boss@example.com", "level" => "owner"}
      })

      assert [%{email: "boss@example.com"} = invitation, _] =
               Organisations.list_invitations(ctx.owner.scope)

      refute Map.has_key?(invitation, :level)
    end

    test "an owner is offered no level to invite at either", %{conn: conn} do
      %{user: user, scope: scope} = sign_up_fixture()

      {:ok, lv, html} =
        live(log_in_user(conn, user), ~p"/#{scope.organisation}/settings/people/invite")

      refute has_element?(lv, "#invitation-form select")
      assert html =~ "as a member"
    end
  end

  describe "a page opened before the owner lost their rights" do
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
      scope: scope,
      founder: founder,
      membership: membership,
      third: third
    } do
      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert html =~ "member-#{third.id}-level-owner"

      assert {:ok, _} = Organisations.set_member_level(founder.scope, membership.id, :member)

      # The page follows the change: the owner controls are gone.
      html = render(lv)
      refute html =~ "member-#{third.id}-level-owner"
      refute html =~ "Invite people"

      # And the events a stale page could still send are refused.
      html = render_hook(lv, "set_level", %{"membership_id" => third.id, "level" => "owner"})
      assert html =~ "Only owners and admins manage members"
      assert Apiary.Repo.get!(Organisations.Membership, third.id).level == :member

      render_hook(lv, "invite", %{
        "invitation" => %{"email" => "late@example.com", "level" => "owner"}
      })

      assert Organisations.list_invitations(founder.scope) == []
    end

    test "without the announcement the stale page is still refused", %{
      conn: conn,
      scope: scope,
      membership: membership,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      # Demoted behind the page's back: no broadcast reaches it.
      membership |> Ecto.Changeset.change(level: :member) |> Apiary.Repo.update!()

      html = lv |> element("#member-#{third.id}-level-owner") |> render_click()
      assert html =~ "Only owners and admins manage members"
      assert Apiary.Repo.get!(Organisations.Membership, third.id).level == :member
    end

    test "a removed member's open page is sent to /", %{
      conn: conn,
      scope: scope,
      founder: founder,
      membership: membership
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert {:ok, _} = Organisations.remove_member(founder.scope, membership.id)
      assert_redirect(lv, ~p"/")
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), user: user, scope: scope, owner: owner}
    end

    test "sees the page read-only", %{conn: conn, owner: owner, user: user, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      assert html =~ owner.user.email
      assert html =~ user.email
      assert html =~ "Owner"
      assert html =~ "Member"
      refute html =~ "Invite people"
      refute html =~ "Pending invitations"
      refute has_element?(lv, "a", "Remove")
      refute has_element?(lv, "[phx-click=set_level]")
    end

    test "cannot open the invite page or a removal", %{conn: conn, owner: owner, scope: scope} do
      members = ~p"/#{scope.organisation}/settings/people"

      assert {:error, {_, %{to: ^members}}} =
               live(conn, ~p"/#{scope.organisation}/settings/people/invite")

      assert {:error, {_, %{to: ^members}}} =
               live(
                 conn,
                 ~p"/#{scope.organisation}/settings/people/#{owner.membership.id}/remove"
               )
    end

    test "leaves the organisation", %{conn: conn, owner: owner, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")

      # Only their own row has the button.
      refute has_element?(lv, "#member-#{owner.membership.id}-remove")
      lv |> element("#member-#{scope.membership.id}-remove", "Leave") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/settings/people/#{scope.membership.id}/remove")

      lv |> element("#leave-confirm") |> render_click()
      assert_redirect(lv, ~p"/")
      refute Apiary.Repo.get(Organisations.Membership, scope.membership.id)
    end
  end

  describe "suspending a membership" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      admin = member_fixture(owner.scope, :admin)
      member = member_fixture(owner.scope, :member)
      %{conn: conn, owner: owner, admin: admin, member: member}
    end

    test "an owner suspends a member after confirming, and activates them again", ctx do
      %{owner: owner, member: member} = ctx
      conn = log_in_user(ctx.conn, owner.user)
      {:ok, lv, _html} = live(conn, ~p"/#{owner.organisation}/settings/people")

      refute has_element?(lv, "#member-#{member.membership.id}-suspended")
      refute has_element?(lv, "#member-#{member.membership.id}-activate")
      # Nobody suspends themselves.
      refute has_element?(lv, "#member-#{owner.membership.id}-suspend")

      lv |> element("#member-#{member.membership.id}-suspend") |> render_click()
      assert_patch(lv, ~p"/#{owner.organisation}/settings/people/#{member.membership.id}/suspend")
      confirm = "#member-#{member.membership.id}-suspend-confirm"
      refute has_element?(lv, "#suspend-member")
      assert has_element?(lv, "#member-#{member.membership.id}.q-confirming #{confirm}")
      assert has_element?(lv, confirm, "Suspend #{member.user.email}?")
      assert has_element?(lv, confirm, "until an owner or an admin activates them")

      # Cancel goes back to People, suspending no one.
      lv |> element("#{confirm}-cancel") |> render_click()
      assert_patch(lv, ~p"/#{owner.organisation}/settings/people")
      refute has_element?(lv, confirm)
      refute Repo.get!(Membership, member.membership.id).suspended_at

      lv |> element("#member-#{member.membership.id}-suspend") |> render_click()
      lv |> element("#{confirm} #suspend-confirm", "Yes, suspend") |> render_click()
      assert_patch(lv, ~p"/#{owner.organisation}/settings/people")
      assert render(lv) =~ "#{member.user.email} is suspended."
      assert has_element?(lv, "#member-#{member.membership.id}-suspended", "Suspended")
      refute has_element?(lv, "#member-#{member.membership.id}-suspend")
      assert Repo.get!(Membership, member.membership.id).suspended_at

      lv |> element("#member-#{member.membership.id}-activate") |> render_click()
      assert render(lv) =~ "#{member.user.email} is active again."
      refute has_element?(lv, "#member-#{member.membership.id}-suspended")
      refute Repo.get!(Membership, member.membership.id).suspended_at
    end

    test "an admin suspends members only", ctx do
      %{owner: owner, admin: admin, member: member} = ctx
      other = member_fixture(owner.scope, :admin)
      {:ok, _} = Organisations.suspend_member(owner.scope, other.membership.id)

      conn = log_in_user(ctx.conn, admin.user)
      {:ok, lv, _html} = live(conn, ~p"/#{owner.organisation}/settings/people")

      assert has_element?(lv, "#member-#{member.membership.id}-suspend")
      refute has_element?(lv, "#member-#{owner.membership.id}-suspend")
      refute has_element?(lv, "#member-#{admin.membership.id}-suspend")
      assert has_element?(lv, "#member-#{other.membership.id}-suspended")
      refute has_element?(lv, "#member-#{other.membership.id}-activate")

      # The owner's modal by its path is refused, and the event without it suspends no one.
      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 conn,
                 ~p"/#{owner.organisation}/settings/people/#{owner.membership.id}/suspend"
               )

      assert to == ~p"/#{owner.organisation}/settings/people"
      render_hook(lv, "suspend", %{})
      refute Repo.get!(Membership, owner.membership.id).suspended_at

      html = render_hook(lv, "activate", %{"id" => other.membership.id})
      assert html =~ "Only owners and admins manage members"
      assert Repo.get!(Membership, other.membership.id).suspended_at
    end

    test "a member is offered neither", ctx do
      %{owner: owner, admin: admin, member: member} = ctx
      {:ok, _} = Organisations.suspend_member(owner.scope, admin.membership.id)

      conn = log_in_user(ctx.conn, member.user)
      {:ok, lv, _html} = live(conn, ~p"/#{owner.organisation}/settings/people")

      assert has_element?(lv, "#member-#{admin.membership.id}-suspended")
      refute has_element?(lv, "#member-#{owner.membership.id}-suspend")
      refute has_element?(lv, "#member-#{admin.membership.id}-activate")
    end

    test "the suspended person's open page leaves, and says why", ctx do
      %{owner: owner, member: member} = ctx
      conn = log_in_user(ctx.conn, member.user)
      {:ok, lv, _html} = live(conn, ~p"/#{owner.organisation}/settings/people")

      {:ok, _} = Organisations.suspend_member(owner.scope, member.membership.id)

      flash = assert_redirect(lv, ~p"/users/organisations")
      assert flash["error"] =~ "Your membership in #{owner.organisation.name} is suspended."
    end
  end
end
