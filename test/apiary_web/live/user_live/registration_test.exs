defmodule ApiaryWeb.UserLive.RegistrationTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create your account"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")

      assert {:error, {:redirect, %{to: "/"}}} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Create your account"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      html = render_submit(form)

      # the confirmation replaces the form in place; nobody is logged in
      assert html =~ "Check your email"
      assert html =~ "We sent a confirmation link to"
      assert html =~ email
      refute has_element?(lv, "#registration_form")

      assert Apiary.Repo.get_by!(Apiary.Accounts.UserToken,
               user_id: Apiary.Accounts.get_user_by_email(email).id
             ).context == "login"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email, "organisation_name" => "Acme"}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "asks for the organisation's name, and names the organisation by it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      assert has_element?(lv, "#registration_form input[name='user[organisation_name]']")

      email = unique_user_email()

      lv
      |> form("#registration_form", user: %{"email" => email, "organisation_name" => ""})
      |> render_submit()

      assert has_element?(lv, "#registration_form [name='user[organisation_name]'][aria-invalid]")
      refute Apiary.Accounts.get_user_by_email(email)

      lv
      |> form("#registration_form", user: %{"email" => email, "organisation_name" => "Acme Ltd"})
      |> render_submit()

      user = Apiary.Accounts.get_user_by_email(email)
      [membership] = Apiary.Organisations.list_memberships(user)
      assert membership.organisation.name == "Acme Ltd"
      assert membership.organisation.slug == "acme-ltd"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
