defmodule ApiaryWeb.UserLive.LoginTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  @remember_me_cookie "_apiary_web_user_remember_me"

  defp password_mode(lv) do
    lv |> element("button[phx-click=toggle_mode]") |> render_click()
    lv
  end

  describe "login page" do
    test "renders one form with one email field, in link mode", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in to Qory Apiary"
      assert html =~ "Send me a log-in link"
      assert html =~ "Use a password instead"
      # The way to sign up is there where a sign-up without an invitation is offered.
      assert html =~ "Create an account" == Apiary.Organisations.sign_up_offered?()

      assert [_one] = Regex.scan(~r/<form[^>]*id="login_form"/, html)
      assert [_one] = Regex.scan(~r/<input[^>]*type="email"/, html)
      refute has_element?(lv, "input[type=password]")
      refute has_element?(lv, "input[type=checkbox]")
    end

    test "the toggle reveals the password and keeps the typed email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      lv |> form("#login_form", user: %{email: "dana@example.com"}) |> render_change()
      html = lv |> password_mode() |> render()

      assert html =~ "Email me a link instead"
      assert html =~ "Keep me signed in"
      assert [_one] = Regex.scan(~r/<input[^>]*type="email"/, html)
      assert has_element?(lv, ~s|#login_form_email[value="dana@example.com"]|)
      assert has_element?(lv, "#login_form input[type=password]")

      assert has_element?(
               lv,
               ~s|#login_form input[type=checkbox][name="user[remember_me]"][checked]|
             )

      html = lv |> password_mode() |> render()
      assert html =~ "Send me a log-in link"
      refute has_element?(lv, "input[type=password]")
      assert has_element?(lv, ~s|#login_form_email[value="dana@example.com"]|)
    end
  end

  describe "user login - magic link" do
    test "sends the email and shows the confirmation in place", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html = lv |> form("#login_form", user: %{email: user.email}) |> render_submit()

      assert html =~ "Check your email"
      assert html =~ user.email
      assert html =~ "a log-in link is on its way"
      refute has_element?(lv, "#login_form")

      assert Apiary.Repo.get_by!(Apiary.Accounts.UserToken, user_id: user.id).context ==
               "login"

      html = lv |> element("button", "Use a different email") |> render_click()
      assert html =~ "Send me a log-in link"
      assert has_element?(lv, "#login_form")
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        lv |> form("#login_form", user: %{email: "idonotexist@example.com"}) |> render_submit()

      assert html =~ "Check your email"
      assert html =~ "a log-in link is on its way"
      assert Apiary.Repo.aggregate(Apiary.Accounts.UserToken, :count) == 0
    end
  end

  describe "an address that cannot be one" do
    test "the link form answers in the field, and sends nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      for email <- ["dana", "dana @example.com", ""] do
        html = lv |> form("#login_form", user: %{email: email}) |> render_submit()

        assert has_element?(
                 lv,
                 "#login_form_email-error",
                 "Enter an email address, such as dana@example.com."
               )

        assert has_element?(lv, ~s|#login_form_email[aria-invalid="true"]|)
        refute html =~ "Check your email"
        refute html =~ "a log-in link is on its way"
      end

      assert Apiary.Repo.aggregate(Apiary.Accounts.UserToken, :count) == 0

      # The error goes as soon as the address is one.
      lv |> form("#login_form", user: %{email: "dana@example.com"}) |> render_change()
      refute has_element?(lv, "#login_form_email-error")
    end

    test "an unknown address and a known one get the same answer", %{conn: conn} do
      user = user_fixture()

      for email <- [user.email, "nobody@example.com"] do
        {:ok, lv, _html} = live(conn, ~p"/users/log-in")
        html = lv |> form("#login_form", user: %{email: email}) |> render_submit()

        refute has_element?(lv, "#login_form_email-error")
        assert html =~ "a log-in link is on its way"
      end
    end

    test "the password form answers in the field, and does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      password_mode(lv)

      lv
      |> form("#login_form", user: %{email: "dana", password: valid_user_password()})
      |> render_submit()

      assert has_element?(lv, "#login_form_email-error", "Enter an email address")
      refute has_element?(lv, "#login_form_password-error")
      refute has_element?(lv, "#login_form[phx-trigger-action]")
    end

    test "the password form asks for the password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      password_mode(lv)

      lv
      |> form("#login_form", user: %{email: "dana@example.com", password: ""})
      |> render_submit()

      assert has_element?(lv, "#login_form_password-error", "Enter your password.")
      refute has_element?(lv, "#login_form_email-error")
      refute has_element?(lv, "#login_form[phx-trigger-action]")

      lv
      |> form("#login_form", user: %{email: "dana@example.com", password: "something"})
      |> render_change()

      refute has_element?(lv, "#login_form_password-error")
    end
  end

  describe "user login - password" do
    test "logs in with valid credentials and sets the remember-me cookie", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      password_mode(lv)

      form =
        form(lv, "#login_form",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/users/organisations"
      assert get_session(conn, :user_token)
      assert conn.resp_cookies[@remember_me_cookie]
    end

    test "sets no remember-me cookie when the box is unchecked", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      password_mode(lv)

      form =
        form(lv, "#login_form",
          user: %{email: user.email, password: valid_user_password(), remember_me: false}
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/users/organisations"
      assert get_session(conn, :user_token)
      refute conn.resp_cookies[@remember_me_cookie]
    end

    test "comes back with an error, in password mode, if credentials are invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")
      password_mode(lv)

      form = form(lv, "#login_form", user: %{email: "test@email.com", password: "123456"})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password do not match."

      assert redirected_to(conn) == ~p"/users/log-in"

      {:ok, lv, html} = live(recycle(conn), ~p"/users/log-in")
      assert html =~ "That email and password do not match."
      assert has_element?(lv, "#login_form input[type=password]")
      assert has_element?(lv, ~s|#login_form_email[value="test@email.com"]|)
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Confirm it is you"
      assert html =~ "Log in again to change sensitive account settings."
      refute html =~ "Create an account"
      assert html =~ "Send me a log-in link"

      assert has_element?(lv, ~s|#login_form_email[readonly][value="#{user.email}"]|)
    end
  end
end

defmodule ApiaryWeb.UserLive.LoginBeforeSetUpTest do
  @moduledoc """
  The log-in page before the instance is set up: there is nobody to log in, and the page
  says to use the set-up link (`Apiary.Setup`). The suite's instance organisation is
  hidden inside the test's sandbox (`Apiary.EditionKit`).
  """
  # Not async: the test hides the suite's instance organisation's row.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  test "says to use the set-up link, with no form and no sign-up", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/users/log-in")

    assert html =~ "This Qory Apiary is not set up yet: use the set-up link from its install."
    refute has_element?(lv, "#login_form")
    refute has_element?(lv, "main a", "Create an account")
  end
end
