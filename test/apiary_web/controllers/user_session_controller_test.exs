defmodule ApiaryWeb.UserSessionControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures
  alias Apiary.Accounts

  setup do
    # Users are created the way the product creates them, so they own a workspace
    # and the workspace page can render after login.
    {:ok, %{user: unconfirmed_user} = unconfirmed} =
      Apiary.Organisations.sign_up_user(valid_user_attributes())

    %{user: user} = signed_up = Apiary.OrganisationsFixtures.sign_up_fixture()

    %{
      unconfirmed_user: unconfirmed_user,
      unconfirmed_home: ~p"/#{unconfirmed.organisation}/#{unconfirmed.workspace}",
      user: user,
      home: ~p"/#{signed_up.organisation}/#{signed_up.workspace}"
    }
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user, home: home} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == home

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == home
      conn = get(conn, home)
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user, home: home} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_apiary_web_user_remember_me"]
      assert redirected_to(conn) == home
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "You are logged in."
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password do not match."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user, home: home} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == home

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == home
      conn = get(conn, home)
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} = context do
      home = context.unconfirmed_home
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == home
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Your account is confirmed."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == home
      conn = get(conn, home)
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That link has expired. Ask for a new one below."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "where a signed-in user is sent" do
    test "a user without a membership is sent to pick an organisation", %{conn: conn} do
      user = user_fixture() |> set_password()

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/users/organisations"
      assert redirected_to(get(conn, ~p"/")) == ~p"/users/organisations"
    end

    test "the workspace last opened, while still a member of it", %{
      conn: conn,
      user: user,
      home: home
    } do
      other = Apiary.OrganisationsFixtures.sign_up_fixture()
      join(user, other.scope)
      other_home = ~p"/#{other.organisation}/#{other.workspace}"
      user = set_password(user)

      conn =
        conn
        |> init_test_session(last_workspace_id: other.workspace.id)
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == other_home

      # opening a page remembers its workspace for `/`
      conn = get(conn, home)
      assert html_response(conn, 200)
      assert redirected_to(get(conn, ~p"/")) == home

      conn = get(conn, other_home)
      assert html_response(conn, 200)
      assert redirected_to(get(conn, ~p"/")) == other_home
    end

    test "the earliest membership once the last opened workspace is not the user's", %{
      conn: conn,
      user: user,
      home: home
    } do
      other = Apiary.OrganisationsFixtures.sign_up_fixture()
      user = set_password(user)

      conn =
        conn
        |> init_test_session(last_workspace_id: other.workspace.id)
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == home
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "You are logged out"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "You are logged out"
    end
  end

  # The user joins the scope's workspace through an invitation, as a second membership.
  defp join(user, scope) do
    %{token: token} =
      Apiary.OrganisationsFixtures.invitation_fixture(scope, %{"email" => user.email})

    {:ok, _membership} = Apiary.Organisations.accept_invitation(user, token)
  end
end
