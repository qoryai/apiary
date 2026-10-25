defmodule ApiaryWeb.UserSessionControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures
  alias Apiary.Accounts

  setup do
    # Users are created the way the product creates them, so they own a workspace
    # and the workspace page can render after login: a later sign-up, which the test
    # makes whether or not the edition opens one.
    {:ok, %{user: unconfirmed_user} = unconfirmed} =
      Apiary.Organisations.sign_up_user(valid_user_attributes(), nil, open: true)

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

      assert conn.resp_cookies["__Host-_apiary_web_user_remember_me"]
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

    test "logs in an unconfirmed account with its password", %{
      conn: conn,
      unconfirmed_user: user,
      unconfirmed_home: home
    } do
      user = set_password(user)
      assert is_nil(user.confirmed_at)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == home
      assert is_nil(Accounts.get_user!(user.id).confirmed_at)
    end

    test "a post without a password is answered as wrong credentials", %{conn: conn, user: user} do
      user = set_password(user)
      conn = post(conn, ~p"/users/log-in", %{"user" => %{"email" => user.email}})

      refute get_session(conn, :user_token)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password do not match."

      assert redirected_to(conn) == ~p"/users/log-in"

      conn = post(build_conn(), ~p"/users/log-in", %{})
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "an address holding a NUL is answered as wrong credentials", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email <> <<0>>, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password do not match."

      assert redirected_to(conn) == ~p"/users/log-in"
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

    test "an unconfirmed account's password goes at its first link log-in, and the page says so",
         %{conn: conn, unconfirmed_user: user} = context do
      user = set_password(user)
      other_session = Accounts.generate_user_session_token(user)
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == context.unconfirmed_home

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Your address is confirmed. The password set before it was confirmed is removed: set a new one in Account settings if you want one."

      user = Accounts.get_user!(user.id)
      assert user.confirmed_at
      assert is_nil(user.hashed_password)
      refute Accounts.get_user_by_session_token(other_session)
    end

    test "without mail, an invalid link's answer offers no new one", %{conn: conn} do
      Apiary.Mail.put_test_source(:none)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => "invalid"}})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That link has expired."
      assert redirected_to(conn) == ~p"/users/log-in"
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

  # A page on an adapter's host, `<adapter>.<instance name>`, can set a cookie with
  # `Domain=<instance name>`; a browser rejects that Domain on a `__Host-` cookie, and one
  # without Secure or Path=/.
  describe "the sign-in cookies" do
    @session_cookie "__Host-_apiary_key"
    @remember_me_cookie "__Host-_apiary_web_user_remember_me"

    test "both have the __Host- prefix, Secure, Path=/ and no Domain", %{conn: conn, user: user} do
      conn = log_in_with_password(conn, user, "true")

      for name <- [@session_cookie, @remember_me_cookie] do
        attributes = set_cookie_attributes(conn, name)
        assert "secure" in attributes, name
        assert "path=/" in attributes, name
        refute Enum.any?(attributes, &String.starts_with?(&1, "domain")), name
      end
    end

    test "sign in, the remember-me sign-in and sign out work", %{
      conn: conn,
      user: user,
      home: home
    } do
      conn = log_in_with_password(conn, user, "true")
      assert redirected_to(conn) == home

      assert conn |> recycle() |> get(home) |> html_response(200) =~ user.email

      # The remember-me cookie alone, as a browser sends it after the session cookie ended.
      %{value: remembered} = conn.resp_cookies[@remember_me_cookie]

      assert build_conn()
             |> put_req_cookie(@remember_me_cookie, remembered)
             |> get(home)
             |> html_response(200) =~ user.email

      conn = conn |> recycle() |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      deleted = set_cookie_attributes(conn, @remember_me_cookie)
      assert "max-age=0" in deleted
      assert "secure" in deleted
      assert "path=/" in deleted

      assert conn |> recycle() |> get(home) |> redirected_to() == ~p"/users/log-in"
    end

    test "a request with a cookie under its old name is not signed in", %{
      conn: conn,
      user: user,
      home: home
    } do
      conn = log_in_with_password(conn, user, "true")
      %{value: session} = conn.resp_cookies[@session_cookie]
      token = conn.cookies[@remember_me_cookie]

      # The session cookie's value is signed with the signing salt alone, so it is valid
      # under either name. Plug signs a cookie with the salt `<name>_cookie`, so the
      # remember-me token is signed for each name.
      sign = fn name ->
        Plug.Crypto.sign(conn.secret_key_base, name <> "_cookie", token, keys: Plug.Keys)
      end

      old_names = [
        {"_apiary_key", session},
        {"_apiary_web_user_remember_me", sign.("_apiary_web_user_remember_me")}
      ]

      new_names = [
        {@session_cookie, session},
        {@remember_me_cookie, sign.(@remember_me_cookie)}
      ]

      for {name, value} <- old_names do
        conn = build_conn() |> put_req_cookie(name, value) |> get(home)
        assert conn.status == 302, "#{name} signed the request in"
        assert redirected_to(conn) == ~p"/users/log-in"
      end

      for {name, value} <- new_names do
        conn = build_conn() |> put_req_cookie(name, value) |> get(home)
        assert conn.status == 200, "#{name} did not sign the request in"
        assert html_response(conn, 200) =~ user.email
      end
    end
  end

  defp log_in_with_password(conn, user, remember_me) do
    user = set_password(user)

    post(conn, ~p"/users/log-in", %{
      "user" => %{
        "email" => user.email,
        "password" => valid_user_password(),
        "remember_me" => remember_me
      }
    })
  end

  # The attributes of the response's Set-Cookie header for `name`, in lower case.
  defp set_cookie_attributes(conn, name) do
    header =
      conn
      |> get_resp_header("set-cookie")
      |> Enum.find(&String.starts_with?(&1, name <> "="))

    assert header, "no Set-Cookie header for #{name}"
    [_name_and_value | attributes] = String.split(header, ";")
    Enum.map(attributes, &(&1 |> String.trim() |> String.downcase()))
  end

  # The user joins the scope's workspace through an invitation, as a second membership.
  defp join(user, scope) do
    %{token: token} =
      Apiary.OrganisationsFixtures.invitation_fixture(scope, %{"email" => user.email})

    {:ok, _membership} = Apiary.Organisations.accept_invitation(user, token)
  end
end
