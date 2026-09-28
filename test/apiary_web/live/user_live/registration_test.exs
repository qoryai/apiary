defmodule ApiaryWeb.UserLive.RegistrationTest do
  @moduledoc """
  The sign-up page at `/users/register`: the core's, or the edition's own page at the same
  path (`ApiaryWeb.Routes`, `except:`), and what holds on either. A sign-up with an
  invitation is offered on every instance; one without it, on the instance's first
  sign-up (`ApiaryWeb.UserLive.RegistrationFirstSignUpTest`), and after it where the
  edition opens one.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  # The page of an invitation of `email` into a fresh organisation's workspace.
  defp invited(conn, email \\ unique_user_email()) do
    %{scope: scope} = sign_up_fixture()
    %{token: token} = invitation_fixture(scope, %{"email" => email})
    {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")
    %{lv: lv, html: html, email: email, scope: scope}
  end

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create your account"
      assert html =~ "Log in"
    end

    test "without an invitation, says sign-up is by invitation where none is open", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      closed? = Apiary.Organisations.sign_up_offer() == :closed

      assert has_element?(lv, "#sign-up-closed") == closed?
      assert has_element?(lv, "#registration_form") == not closed?
    end

    test "with an invitation, asks for the invited address alone", %{conn: conn} do
      %{lv: lv, html: html, email: email, scope: scope} = invited(conn)

      assert html =~ "Create your account"
      assert html =~ "Log in"
      assert has_element?(lv, "#registration_form input[name='user[email]'][value='#{email}']")
      refute has_element?(lv, "#registration_form input[name='user[organisation_name]']")
      assert html =~ scope.organisation.name
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")

      assert {:error, {:redirect, %{to: "/"}}} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      %{lv: lv} = invited(conn)

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
      %{lv: lv, email: email, scope: scope} = invited(conn)

      html = lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()

      # the confirmation replaces the form in place; nobody is logged in
      assert html =~ "Check your email"
      assert html =~ "We sent a confirmation link to"
      assert html =~ email
      refute has_element?(lv, "#registration_form")

      user = Apiary.Accounts.get_user_by_email(email)
      assert Apiary.Repo.get_by!(Apiary.Accounts.UserToken, user_id: user.id).context == "login"

      # The account joins the workspace it was invited to.
      assert [membership] = Apiary.Organisations.list_memberships(user)
      assert membership.organisation_id == scope.organisation.id
    end

    test "renders errors for duplicated email", %{conn: conn} do
      user = user_fixture()
      %{lv: lv} = invited(conn, user.email)

      result =
        lv
        |> form("#registration_form", user: %{"email" => user.email})
        |> render_submit()

      assert result =~ "has already been taken"
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

defmodule ApiaryWeb.UserLive.RegistrationFirstSignUpTest do
  @moduledoc """
  The sign-up page on the instance's first sign-up, which every edition offers: the
  suite's instance organisation is hidden inside the test's sandbox
  (`Apiary.EditionKit`), and the page asks for the organisation's name.
  """
  # Not async: a test of the first sign-up holds the suite's instance organisation's row.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    :ok
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
