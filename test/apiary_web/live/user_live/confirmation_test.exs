defmodule ApiaryWeb.UserLive.ConfirmationTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  alias Apiary.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "Confirm user" do
    test "renders confirmation page for unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      assert html =~ "Welcome to Qory Apiary"
      assert html =~ "Confirm my account"
      assert html =~ "Keep me signed in"
    end

    test "renders login page for confirmed user", %{conn: conn, confirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Welcome back"
      assert html =~ "Keep me signed in"
    end

    test "renders login page for already logged in user", %{conn: conn, confirmed_user: user} do
      conn = log_in_user(conn, user)

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Confirm my account"
      refute html =~ "Keep me signed in"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Your account is confirmed."

      assert Accounts.get_user!(user.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/organisations"

      # log out, new conn
      conn = build_conn()

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")

      assert html =~ "That link has expired"
      refute has_element?(lv, "form")
      assert has_element?(lv, ~s|a[href="/users/log-in"]|, "Send a new link")
    end

    test "logs confirmed user in without changing confirmed_at", %{
      conn: conn,
      confirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "You are logged in."

      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")

      assert html =~ "That link has expired"
      refute has_element?(lv, "form")
      assert has_element?(lv, ~s|a[href="/users/log-in"]|, "Send a new link")
    end

    test "has one button and the keep-me-signed-in checkbox, checked", %{
      conn: conn,
      unconfirmed_user: unconfirmed,
      confirmed_user: confirmed
    } do
      for {user, form_id, label} <- [
            {unconfirmed, "#confirmation_form", "Confirm my account"},
            {confirmed, "#login_form", "Log in"}
          ] do
        token = extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)
        {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")

        assert [_one] = Regex.scan(~r/<button[^>]*btn-primary/, html)
        assert has_element?(lv, "#{form_id} button", label)

        assert has_element?(
                 lv,
                 ~s|#{form_id} input[type=checkbox][name="user[remember_me]"][checked]|
               )
      end
    end

    test "the checkbox decides the remember-me cookie", %{conn: conn, confirmed_user: user} do
      for {remember, cookie?} <- [{"true", true}, {"false", false}] do
        token = extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)
        {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

        form =
          form(lv, "#login_form", %{"user" => %{"token" => token, "remember_me" => remember}})

        render_submit(form)
        conn = follow_trigger_action(form, conn)

        assert redirected_to(conn) == ~p"/users/organisations"
        assert is_map_key(conn.resp_cookies, "_apiary_web_user_remember_me") == cookie?
      end
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in/invalid-token")

      assert html =~ "That link has expired"
      refute has_element?(lv, "form")
      assert has_element?(lv, ~s|a[href="/users/log-in"]|, "Send a new link")
    end
  end
end
