defmodule ApiaryWeb.DeletionLiveTest do
  # The pages where an owner deletes a workspace or the organisation, cancels it, and a
  # person deletes their account.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Deletion, Organisations, Repo}
  alias Apiary.Accounts.User
  alias Apiary.Organisations.{Organisation, Workspace}

  describe "the organisation's settings, for an owner" do
    setup :register_and_log_in_user

    test "the only workspace is not deleted on its own", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/workspaces")

      assert has_element?(lv, "#workspace-#{scope.workspace.id}", scope.workspace.name)
      refute has_element?(lv, "#workspaces a", "Delete")
      assert has_element?(lv, "#workspaces-note", "delete the organisation instead")

      # A crafted path to its modal says so, and deletes nothing.
      path = ~p"/#{scope.organisation}/settings/workspaces/#{scope.workspace.id}/delete"
      settings = ~p"/#{scope.organisation}/settings/workspaces"

      assert {:error, {:live_redirect, %{to: ^settings, flash: flash}}} = live(conn, path)
      assert flash["error"] == "That workspace cannot be deleted here."
      assert Repo.get!(Workspace, scope.workspace.id).deletion_marked_at == nil
    end

    test "deletes a workspace after its slug is typed, and cancels it", %{
      conn: conn,
      scope: scope
    } do
      workspace = workspace_fixture(scope.organisation, "Staging")
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings/workspaces")

      lv |> element("#workspace-#{workspace.id} a", "Delete") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/settings/workspaces/#{workspace.id}/delete")
      assert has_element?(lv, "#delete-workspace-modal")
      assert has_element?(lv, "#delete-workspace-confirm[disabled]")

      lv |> form("#delete-workspace-form", confirm: %{slug: "stag"}) |> render_change()
      assert has_element?(lv, "#delete-workspace-confirm[disabled]")
      lv |> form("#delete-workspace-form", confirm: %{slug: "staging"}) |> render_change()
      refute has_element?(lv, "#delete-workspace-confirm[disabled]")

      html = lv |> form("#delete-workspace-form", confirm: %{slug: "staging"}) |> render_submit()
      assert html =~ "Staging is deleted and is purged on"
      assert %Workspace{deletion_marked_at: %DateTime{}} = Repo.get!(Workspace, workspace.id)

      # Gone from the list, and a notice with its cancel in its place.
      refute has_element?(lv, "#workspace-#{workspace.id}")
      assert has_element?(lv, "#marked-workspace-#{workspace.id}", "Staging")

      lv |> element("#restore-workspace-#{workspace.id}") |> render_click()
      refute has_element?(lv, "#marked-workspace-#{workspace.id}")
      assert has_element?(lv, "#workspace-#{workspace.id}")
      assert Repo.get!(Workspace, workspace.id).deletion_marked_at == nil
    end

    test "a slug typed wrong is refused on the form", %{conn: conn, scope: scope} do
      workspace = workspace_fixture(scope.organisation)
      path = ~p"/#{scope.organisation}/settings/workspaces/#{workspace.id}/delete"
      {:ok, lv, _html} = live(conn, path)

      html = render_submit(lv, "delete_workspace", %{"confirm" => %{"slug" => "wrong"}})
      assert html =~ "is not the slug"
      assert Repo.get!(Workspace, workspace.id).deletion_marked_at == nil
    end

    test "deletes the organisation, and its owner cancels it from their organisations",
         %{conn: conn, scope: scope} do
      %{access_key: key} = access_key_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/settings")

      lv |> element("#delete-organisation-button") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/settings/danger")
      assert has_element?(lv, "#delete-organisation-modal")

      slug = scope.organisation.slug

      lv |> form("#delete-organisation-form", confirm: %{slug: slug}) |> render_submit()
      flash = assert_redirect(lv, ~p"/users/organisations")
      assert flash["info"] =~ "is deleted and is purged on"
      assert Repo.get!(Organisation, scope.organisation.id).deletion_marked_at

      # Its pages answer not found, and its key is refused.
      assert get(conn, ~p"/#{scope.organisation}/#{scope.workspace}").status == 404
      assert Apiary.AccessKeys.fetch_for_verification(key.key_id) == :error

      {:ok, lv, _html} = live(conn, ~p"/users/organisations")
      assert has_element?(lv, "#pending-#{scope.organisation.id}", scope.organisation.name)
      refute has_element?(lv, "#organisation-#{scope.organisation.id}")

      html = lv |> element("#restore-#{scope.organisation.id}") |> render_click()
      assert html =~ "is back, with its access keys"
      # Its membership is back, which sends the page on to it.
      assert_redirect(lv, ~p"/")
      assert {:ok, _} = Apiary.AccessKeys.fetch_for_verification(key.key_id)

      {:ok, lv, _html} = live(conn, ~p"/users/organisations")
      refute has_element?(lv, "#pending-#{scope.organisation.id}")
      assert has_element?(lv, "#organisation-#{scope.organisation.id}")
    end
  end

  describe "the organisation's settings, for a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), owner: owner}
    end

    test "offer no deletion, and its paths refuse", %{conn: conn, owner: owner} do
      organisation = owner.scope.organisation
      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings")
      refute has_element?(lv, "#workspaces")
      refute has_element?(lv, "#danger-zone")
      refute has_element?(lv, "#delete-organisation")

      settings = ~p"/#{organisation}/settings"

      # Each section says its own refusal, never another's.
      for {section, sentence} <- [
            {"/workspaces", "Only owners and admins open the list of workspaces."},
            {"/danger", "Only owners delete the organisation."},
            {"/delete", "Only owners delete the organisation."}
          ] do
        assert {:error, {:live_redirect, %{to: ^settings, flash: flash}}} =
                 live(conn, ~p"/#{organisation}/settings" <> section)

        assert flash["error"] == sentence
      end

      # A crafted event is refused all the same.
      html =
        render_submit(lv, "delete_organisation", %{"confirm" => %{"slug" => organisation.slug}})

      assert html =~ "Only owners and admins can change these settings."
      assert Repo.get!(Organisation, organisation.id).deletion_marked_at == nil
    end

    test "do not see the organisation once it is deleted, nor may cancel it",
         %{conn: conn, owner: owner} do
      {:ok, _} = Deletion.delete_organisation(owner.scope, owner.scope.organisation.slug)

      {:ok, lv, _html} = live(conn, ~p"/users/organisations")
      refute has_element?(lv, "#pending-deletions")
      assert has_element?(lv, "h1", "You are not part of an organisation yet")
    end
  end

  describe "the account settings" do
    setup :register_and_log_in_user

    test "the only owner of an organisation cannot delete their account", ctx do
      %{conn: conn, scope: scope, user: user} = ctx
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert render_async(lv) =~ "You are the only owner of this organisation."
      assert has_element?(lv, "#sole-owned-#{scope.organisation.id}", scope.organisation.name)
      assert has_element?(lv, "button#delete-account-button[disabled]")

      # Asked for anyway, with the email typed, it is refused.
      {:ok, lv, _html} = live(conn, ~p"/users/settings/delete")
      html = render_submit(lv, "delete_account", %{"confirm" => %{"email" => user.email}})
      assert html =~ "You are the only owner of an organisation."
      assert Repo.get!(User, user.id).deleted_at == nil
    end

    test "the only owner of a deleted organisation is told nobody is left to cancel it",
         %{conn: conn, scope: scope} do
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      render_async(lv)
      refute has_element?(lv, "#delete-account-blocked")
      assert has_element?(lv, "#delete-account-orphans", "nobody is left who can cancel")
      assert has_element?(lv, "#marked-alone-#{scope.organisation.id}", scope.organisation.name)

      lv |> element("a#delete-account-button") |> render_click()
      assert has_element?(lv, "#delete-account-modal-orphans")
    end

    test "a person deletes their account after confirming, and is logged out everywhere",
         %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user} = member_fixture(owner.scope, :member)
      other_session = Apiary.Accounts.generate_user_session_token(user)
      conn = log_in_user(conn, user)
      own_session = Plug.Conn.get_session(conn, :user_token)
      conn = Plug.Conn.put_session(conn, :live_socket_id, live_socket_id(own_session))
      ApiaryWeb.Endpoint.subscribe(live_socket_id(own_session))
      ApiaryWeb.Endpoint.subscribe(live_socket_id(other_session))
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      render_async(lv)
      refute has_element?(lv, "#delete-account-blocked")
      # Deleting the account is the danger zone that ends Profile, and no entry of the list.
      assert has_element?(lv, "#danger-zone #delete-account", "Delete account")
      refute has_element?(lv, "#sidebar a[href='/users/settings/delete']")
      lv |> element("a#delete-account-button") |> render_click()
      assert_patch(lv, ~p"/users/settings/delete")
      assert has_element?(lv, "#delete-account-modal")
      assert has_element?(lv, "#nav-user_settings[aria-current='page']")

      # The red button waits for the account's email, typed; the server asks again.
      assert has_element?(lv, "#delete-account-confirm[disabled]")

      lv
      |> form("#delete-account-form", confirm: %{email: "someone@else.example"})
      |> render_change()

      assert has_element?(lv, "#delete-account-confirm[disabled]")

      html =
        render_submit(lv, "delete_account", %{"confirm" => %{"email" => "someone@else.example"}})

      assert html =~ "is not your email"
      assert Repo.get!(User, user.id).deleted_at == nil

      lv
      |> form("#delete-account-form", confirm: %{email: String.upcase(user.email)})
      |> render_change()

      refute has_element?(lv, "#delete-account-confirm[disabled]")
      lv |> form("#delete-account-form", confirm: %{email: user.email}) |> render_submit()
      assert_redirect(lv, ~p"/users/account-deleted")
      assert %User{email: nil, deleted_at: %DateTime{}} = Repo.get!(User, user.id)

      # Every other session is disconnected at once; the page's own where it is sent,
      # which ends it as a log-out does.
      other_topic = live_socket_id(other_session)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^other_topic}

      conn = get(conn, ~p"/users/account-deleted")
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Your account is deleted."
      own_topic = live_socket_id(own_session)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^own_topic}

      # The session is gone with the account.
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/settings")
      assert Organisations.list_memberships(user) == []
    end
  end

  defp live_socket_id(token), do: "users_sessions:#{Base.url_encode64(token)}"
end
