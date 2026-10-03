defmodule ApiaryWeb.UserLive.OrganisationsTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Deletion

  test "lists each organisation the person is a member of, with a link to their workspace",
       %{conn: conn} do
    %{scope: own, user: user} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    %{token: token} = invitation_fixture(other, %{"email" => user.email})
    {:ok, _} = Apiary.Organisations.accept_invitation(user, token)

    {:ok, lv, html} = live(log_in_user(conn, user), ~p"/users/organisations")

    assert html =~ ~r{<title[^>]*>\s*Your organisations · Qory Apiary\s*</title>}

    for scope <- [own, other] do
      assert has_element?(
               lv,
               "#organisation-#{scope.organisation.id} a[href='/#{scope.organisation.slug}/#{scope.workspace.slug}']",
               scope.organisation.name
             )
    end

    refute has_element?(lv, "#pending-deletions")
  end

  test "an owner sees an organisation pending deletion, and when it is purged",
       %{conn: conn} do
    %{scope: scope, user: user} = sign_up_fixture()
    {:ok, marked} = Deletion.delete_organisation(scope, scope.organisation.slug)

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/users/organisations")

    assert has_element?(lv, "#pending-#{scope.organisation.id}", scope.organisation.name)
    assert has_element?(lv, "#pending-#{scope.organisation.id}", "Purged on")

    assert has_element?(
             lv,
             "#pending-#{scope.organisation.id}",
             ApiaryWeb.Format.date(marked.purge_after)
           )

    refute has_element?(lv, "#organisation-#{scope.organisation.id}")
  end

  describe "a suspended membership" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      member = member_fixture(owner.scope, :member)
      {:ok, _} = Apiary.Organisations.suspend_member(owner.scope, member.membership.id)
      %{conn: log_in_user(conn, member.user), owner: owner, member: member}
    end

    test "is listed, and says who activates it", %{conn: conn, owner: owner} do
      {:ok, lv, _html} = live(conn, ~p"/users/organisations")

      assert has_element?(
               lv,
               "#suspended-memberships #suspended-#{owner.organisation.id}",
               owner.organisation.name
             )

      assert has_element?(lv, "#suspended-memberships", "An owner or an admin of each")
      refute has_element?(lv, "#organisation-#{owner.organisation.id}")
    end

    test "sends them here, saying why, rather than answering not found", %{
      conn: conn,
      owner: owner
    } do
      said = "Your membership in #{owner.organisation.name} is suspended."

      conn = get(conn, ~p"/#{owner.organisation}/settings/people")
      assert redirected_to(conn) == ~p"/users/organisations"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ said

      assert {:error, {:redirect, %{to: "/users/organisations", flash: flash}}} =
               live(recycle(conn), ~p"/#{owner.organisation}/#{owner.workspace}/runs")

      assert flash["error"] =~ said
    end

    test "a live navigation into it says the same", %{owner: owner} do
      # A person with an organisation of their own besides, where the navigation starts.
      own = sign_up_fixture()
      %{token: token} = invitation_fixture(owner.scope, %{"email" => own.user.email})
      {:ok, _} = Apiary.Organisations.accept_invitation(own.user, token)

      joined =
        Apiary.Repo.get_by!(Apiary.Organisations.Membership,
          organisation_id: owner.organisation.id,
          user_id: own.user.id
        )

      {:ok, _} = Apiary.Organisations.suspend_member(owner.scope, joined.id)

      conn = log_in_user(build_conn(), own.user)
      {:ok, lv, _html} = live(conn, ~p"/#{own.organisation}/settings/people")

      assert {:error, {:redirect, %{to: "/users/organisations"}}} =
               redirected = live_redirect(lv, to: ~p"/#{owner.organisation}/settings/people")

      {:ok, conn} = follow_redirect(redirected, conn)
      html = html_response(conn, 200)
      assert html =~ "Your membership in #{owner.organisation.name} is suspended."
      assert html =~ ~s(id="suspended-#{owner.organisation.id}")
    end

    test "anyone else is answered not found", %{owner: owner} do
      %{user: stranger} = sign_up_fixture()

      assert build_conn()
             |> log_in_user(stranger)
             |> get(~p"/#{owner.organisation}/settings/people")
             |> response(404)
    end
  end

  test "without an organisation, says how to join one", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/users/organisations")
    assert has_element?(lv, "h1", "You are not part of an organisation yet")
  end
end
