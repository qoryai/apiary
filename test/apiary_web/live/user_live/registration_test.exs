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
  import ApiaryWeb.SetUpSteps, only: [steps: 1]

  # The page of an invitation of `email` into a fresh organisation's workspace, opened
  # with the instance's mail from `mail`: the sign-up and the invitation before it are made
  # by the suite's mail.
  defp invited(conn, email \\ unique_user_email(), mail \\ :env) do
    %{scope: scope} = sign_up_fixture()
    %{token: token} = invitation_fixture(scope, %{"email" => email})
    Apiary.Mail.put_test_source(mail)
    {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")
    %{lv: lv, html: html, email: email, scope: scope, token: token}
  end

  # The sign-up form in `html` is sent with POST to the page, and has no password field, so
  # none with a value.
  defp assert_posts_without_password(html) do
    form = LazyHTML.query(html, "#registration_form")
    assert LazyHTML.attribute(form, "method") == ["post"]
    assert LazyHTML.attribute(form, "action") == []
    assert LazyHTML.query(form, ~s{input[type="password"]}) |> Enum.to_list() == []
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

      assert has_element?(
               lv,
               "aside#set-up-context > h2#set-up-context-h",
               ~r/\AAbout accounts\z/
             )
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

    # An invited sign-up without mail, beside what
    # test/apiary_pro_web/live/user_live/sign_up_mail_test.exs covers in "an invited sign-up
    # keeps the invitation's address, joins at once and signs the person in".
    test "an invited sign-up shows no steps, and its password fields are masked and empty",
         %{conn: conn} do
      %{lv: lv} = invited(conn, unique_user_email(), :none)

      # An invitation into a workspace of an organisation that is no client: the account is
      # the one step, and no indicator shows.
      assert steps(lv) == []
      refute has_element?(lv, "#set-up-steps")

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

    test "the form does not post to the log-in controller", %{conn: conn} do
      %{lv: lv} = invited(conn)

      refute has_element?(lv, "#registration_form[action]")
      refute has_element?(lv, "#registration_form[phx-trigger-action]")
    end

    test "posts its form, and shows no password, first or after a refused sign-up", %{
      conn: conn
    } do
      user = user_fixture()
      %{token: token} = invited(conn, user.email)

      # The page before it connects: a submit there is the browser's, with the form's method.
      html = conn |> get(~p"/users/register?invitation=#{token}") |> html_response(200)
      assert_posts_without_password(LazyHTML.from_document(html))

      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")

      html =
        lv
        |> element("#registration_form")
        |> render_submit(%{
          "user" => %{
            "email" => user.email,
            "password" => "s3cret-example",
            "password_confirmation" => "s3cret-example"
          }
        })

      assert html =~ "has already been taken"
      refute html =~ "s3cret-example"
      assert_posts_without_password(LazyHTML.from_fragment(html))
    end

    test "a password sent all the same is dropped, and the address is confirmed by email",
         %{conn: conn} do
      %{lv: lv, email: email} = invited(conn)
      password = "a long pass phrase"

      html =
        lv
        |> element("#registration_form")
        |> render_submit(%{
          "user" => %{
            "email" => email,
            "password" => password,
            "password_confirmation" => password
          }
        })

      assert html =~ "Check your email"
      refute has_element?(lv, "#registration_form[phx-trigger-action]")

      user = Apiary.Accounts.get_user_by_email(email)
      assert is_nil(user.hashed_password)
      refute Apiary.Accounts.get_user_by_email_and_password(email, password)
    end

    # An invited sign-up with mail: test/apiary_pro_web/live/user_live/sign_up_mail_test.exs,
    # "an invited sign-up asks for no password, and its address may be changed".
  end

  describe "a sign-up that creates an organisation" do
    setup do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.SignUpOpen)
    end

    # The sign-up page of the core, by its steps and its line, under open sign-up. The page
    # is the edition's: test/apiary_pro_web/live/user_live/set_up_frame_test.exs, "list Your
    # account alone, so the page shows no steps indicator" and "list none of the workspace's
    # steps with the factory, for an organisation and an operator".

    test "creates the organisation with no workspace, and lands its owner on its overview", %{
      conn: conn
    } do
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()
      password = "a long pass phrase"

      form =
        form(lv, "#registration_form",
          user: %{
            "email" => email,
            "organisation_name" => "Signup Studio",
            "password" => password,
            "password_confirmation" => password
          }
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      user = Apiary.Accounts.get_user_by_email(email)
      assert [membership] = Apiary.Organisations.list_memberships(user)
      assert membership.level == :owner

      organisation =
        Apiary.Repo.get!(Apiary.Organisations.Organisation, membership.organisation_id)

      refute Apiary.Organisations.has_workspace?(organisation)
      assert redirected_to(conn) == ~p"/#{organisation}"
    end

    test "with mail, creates the organisation with no workspace too", %{conn: conn} do
      Apiary.Mail.put_test_source(:env)
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      html =
        lv
        |> form("#registration_form",
          user: %{"email" => email, "organisation_name" => "Signup Mail Studio"}
        )
        |> render_submit()

      assert html =~ "Check your email"

      user = Apiary.Accounts.get_user_by_email(email)
      assert [membership] = Apiary.Organisations.list_memberships(user)

      organisation =
        Apiary.Repo.get!(Apiary.Organisations.Organisation, membership.organisation_id)

      refute Apiary.Organisations.has_workspace?(organisation)
    end

    test "refuses a name whose address is taken, on the name, and creates nothing", %{
      conn: conn
    } do
      Apiary.Mail.put_test_source(:env)
      %{organisation: taken} = sign_up_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      for {name, message} <- [
            {String.upcase(taken.name),
             "Choose another name. Another organisation has the address /#{taken.slug}."},
            {"Settings", "Choose another name. Qory Apiary keeps the address /settings."},
            {"株式会社",
             "Choose a name with at least one letter or digit from A to Z or 0 to 9. " <>
               "The address is made from those characters."}
          ] do
        lv
        |> form("#registration_form", user: %{"email" => email, "organisation_name" => name})
        |> render_submit()

        assert has_element?(lv, "#registration_form", message)
        refute Apiary.Accounts.get_user_by_email(email)
      end
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

defmodule ApiaryWeb.UserLive.RegistrationBeforeSetUpTest do
  @moduledoc """
  The sign-up page before the instance is set up: nobody signs up before its set-up link
  is used (`Apiary.Setup`). The suite's instance organisation is hidden inside the test's
  sandbox (`Apiary.EditionKit`).
  """
  # Not async: the test hides the suite's instance organisation's row.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  test "says to use the set-up link, with no form, with mail or without", %{conn: conn} do
    for source <- [:env, :none] do
      Apiary.Mail.put_test_source(source)
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#sign-up-not-set-up")
      refute has_element?(lv, "#registration_form")
      refute has_element?(lv, "#sign-up-closed")

      assert html =~
               "This Qory Apiary is not set up yet: use the set-up link from its install."
    end
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
