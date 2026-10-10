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

  # The page of an invitation of `email` into a fresh organisation's workspace, opened
  # with the instance's mail from `mail`: the sign-up and the invitation before it are made
  # by the suite's mail.
  defp invited(conn, email \\ unique_user_email(), mail \\ :env) do
    %{scope: scope} = sign_up_fixture()
    %{token: token} = invitation_fixture(scope, %{"email" => email})
    Apiary.Mail.put_test_source(mail)
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

  describe "without mail" do
    test "the invitation-only page says the inviter sends the link", %{conn: conn} do
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, html} = live(conn, ~p"/users/register")

      if has_element?(lv, "#sign-up-closed") do
        assert html =~
                 "Ask an owner or an admin of your organisation to invite you; they send you the link to sign up."

        refute html =~ "the email they send"
      end
    end

    test "an invited sign-up asks for a password, keeps the invited address and says the account joins at once",
         %{conn: conn} do
      %{lv: lv, html: html, email: email} = invited(conn, unique_user_email(), :none)

      assert html =~ "Choose a password to sign in with."
      refute html =~ "no password needed"
      assert html =~ "Your account joins it as soon as you create it."

      assert has_element?(
               lv,
               "#registration_form input[name='user[email]'][value='#{email}'][readonly]"
             )

      assert has_element?(lv, "#registration_form input[name='user[password]'][type=password]")

      assert has_element?(
               lv,
               "#registration_form input[name='user[password_confirmation]'][type=password]"
             )

      # The page never writes a password back.
      refute has_element?(lv, "#registration_form input[type=password][value]")
    end

    test "an invited sign-up makes the account, joins the workspace and signs the person in",
         %{conn: conn} do
      %{lv: lv, email: email, scope: scope} = invited(conn, unique_user_email(), :none)
      password = "a long pass phrase"

      # The browser sends the invited address, which the page shows and cannot change.
      form =
        form(lv, "#registration_form",
          user: %{"email" => email, "password" => password, "password_confirmation" => password}
        )

      html = render_submit(form)
      refute html =~ "Check your email"
      refute html =~ password

      conn = follow_trigger_action(form, conn)
      assert get_session(conn, :user_token)
      assert redirected_to(conn) =~ "/"

      user = Apiary.Accounts.get_user_by_email(email)
      assert is_nil(user.confirmed_at)
      assert Apiary.Accounts.get_user_by_email_and_password(email, password)
      assert [membership] = Apiary.Organisations.list_memberships(user)
      assert membership.organisation_id == scope.organisation.id

      # No email: the invitation's was sent before the mail was off.
      refute_received {:email,
                       %Swoosh.Email{
                         subject: "Confirm your Qory Apiary account",
                         to: [{_, ^email}]
                       }}
    end

    test "a short password, or one that does not match, is refused and nothing is made",
         %{conn: conn} do
      %{lv: lv, email: email} = invited(conn, unique_user_email(), :none)

      html =
        lv
        |> form("#registration_form",
          user: %{"password" => "too short", "password_confirmation" => "too short"}
        )
        |> render_submit()

      assert html =~ "should be at least 12 character(s)"
      assert has_element?(lv, "#user_password-error")
      refute Apiary.Accounts.get_user_by_email(email)

      html =
        lv
        |> form("#registration_form",
          user: %{
            "password" => "a long pass phrase",
            "password_confirmation" => "another pass phrase"
          }
        )
        |> render_submit()

      assert html =~ "does not match password"
      assert has_element?(lv, "#user_password_confirmation-error")
      refute Apiary.Accounts.get_user_by_email(email)
    end
  end

  describe "with mail" do
    test "the invitation-only page says the email has the link", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")

      if has_element?(lv, "#sign-up-closed") do
        assert html =~ "the email they send has the link to sign up."
      end
    end

    test "an invited sign-up asks for no password", %{conn: conn} do
      %{lv: lv, html: html} = invited(conn)

      assert html =~ "We will email you a link to confirm; no password needed."
      assert html =~ "Your account joins it as soon as you confirm."
      refute has_element?(lv, "#registration_form input[type=password]")
      refute has_element?(lv, "#registration_form input[name='user[email]'][readonly]")
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

    # Nothing about the workspace's type: Main takes the default domain while there is one.
    fields =
      lv
      |> element("#registration_form")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input:not([type=hidden]), select, textarea")
      |> LazyHTML.attribute("name")

    assert Enum.sort(fields) == ["user[email]", "user[organisation_name]"]

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

  test "without mail, asks for a password too, and signs the first admin in", %{conn: conn} do
    Apiary.Mail.put_test_source(:none)
    {:ok, lv, html} = live(conn, ~p"/users/register")

    assert html =~
             "Start an organisation and its first workspace. Choose a password to sign in with."

    fields =
      lv
      |> element("#registration_form")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input:not([type=hidden]), select, textarea")
      |> LazyHTML.attribute("name")

    assert Enum.sort(fields) ==
             [
               "user[email]",
               "user[organisation_name]",
               "user[password]",
               "user[password_confirmation]"
             ]

    email = unique_user_email()
    password = "a long pass phrase"

    form =
      form(lv, "#registration_form",
        user: %{
          "email" => email,
          "organisation_name" => "Acme Ltd",
          "password" => password,
          "password_confirmation" => password
        }
      )

    render_submit(form)
    conn = follow_trigger_action(form, conn)
    assert get_session(conn, :user_token)

    user = Apiary.Accounts.get_user_by_email(email)
    assert Apiary.Accounts.get_user_by_email_and_password(email, password)
    [membership] = Apiary.Organisations.list_memberships(user)
    assert membership.organisation.name == "Acme Ltd"
    assert Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(user))
  end
end

defmodule ApiaryWeb.UserLive.RegistrationMailFailsTest do
  @moduledoc """
  The sign-up page when its confirmation email cannot be sent: the account is made, and the
  page says so and leads to the log-in page, where a new link is asked for. Not async: the
  application's mailer is one that refuses every email, for this module's tests alone.
  """
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, :refused}
  end

  setup do
    # The invitation goes out first, by the suite's own mailer.
    %{scope: scope} = sign_up_fixture()
    email = unique_user_email()
    %{token: token} = invitation_fixture(scope, %{"email" => email})

    mailer = Application.get_env(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, Keyword.put(mailer, :adapter, Refusing))
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, mailer) end)

    %{email: email, token: token}
  end

  test "the account is made, and the page says the email could not be sent", %{
    conn: conn,
    email: email,
    token: token
  } do
    {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")

    {:ok, _login, html} =
      lv
      |> form("#registration_form", user: %{"email" => email})
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log-in")

    # The toast shows the first sentence as its title, and the second under it.
    assert html =~ "Your account is made, but the email with its link could not be sent."
    assert html =~ "Ask for a new link on the log-in page in a few minutes."

    assert Apiary.Accounts.get_user_by_email(email)
  end
end
