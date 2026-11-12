defmodule ApiaryProWeb.UserLive.SignUpMailTest do
  @moduledoc """
  The edition's sign-up page by the instance's mail (`Apiary.Mail.configured?/0`), as the core's
  page: without mail it asks for a password and signs the person in at once, an open
  sign-up and an invited one, whose address is the invitation's; with mail it asks for
  none, drops one sent all the same, and emails a link to confirm. The instance's set-up
  is its own page's (`ApiaryProWeb.SetupLiveTest`).
  """
  # Not async: the sign-up settings are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  import ApiaryPro.OperatorsFixtures, only: [tenant_of: 1]

  alias Apiary.{Accounts, Mail, Organisations}
  alias ApiaryPro.Tenants.Tenant

  @password "a long pass phrase"

  defp organisation_of(email) do
    [membership] = email |> Accounts.get_user_by_email() |> Organisations.list_memberships()
    membership.organisation
  end

  # The text of the page's About accounts column.
  defp context(lv) do
    lv
    |> element("#set-up-context")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
  end

  # The names of the fields the form asks, in their order.
  defp field_names(lv) do
    lv
    |> element("#registration_form")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input:not([type=hidden]), select, textarea")
    |> LazyHTML.attribute("name")
    |> Enum.uniq()
  end

  # The form sent with a password, then posted to the log-in controller as the browser
  # does once the account is made: the conn it answers.
  defp sign_up_with_password(conn, lv, attrs) do
    form =
      form(lv, "#registration_form",
        user: Map.merge(%{"password" => @password, "password_confirmation" => @password}, attrs)
      )

    html = render_submit(form)
    refute html =~ "Check your email"
    refute html =~ @password
    follow_trigger_action(form, conn)
  end

  # Signed in, with the password chosen, and unconfirmed: no mail has shown the address is
  # theirs.
  defp assert_signed_in(conn, email) do
    assert get_session(conn, :user_token)
    assert redirected_to(conn) =~ "/"

    user = Accounts.get_user_by_email(email)
    assert is_nil(user.confirmed_at)
    assert Accounts.get_user_by_email_and_password(email, @password)

    # No log-in link is emailed: an invitation's was sent while there was mail.
    refute Enum.any?(mailed_to(email), &(&1 =~ "/users/log-in/"))
    user
  end

  # The text of every email the test process was sent for `email`.
  defp mailed_to(email, bodies \\ []) do
    receive do
      {:email, %Swoosh.Email{to: [{_, ^email}], text_body: body}} ->
        mailed_to(email, [body | bodies])
    after
      0 -> bodies
    end
  end

  # An invitation into a fresh organisation, made while there is mail.
  defp invitation do
    %{scope: scope} = sign_up_fixture()
    %{invitation: invitation, token: token} = invitation_fixture(scope)
    %{scope: scope, invitation: invitation, token: token}
  end

  describe "without mail" do
    test "with organisations open, it asks for a password and signs the person in",
         %{conn: conn} do
      open!([:organisation])
      Mail.put_test_source(:none)
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert context(lv) =~ "You become the owner of the organisation."

      assert context(lv) =~
               "You sign in with a password."

      refute html =~ "Choose a password to sign in with."

      assert field_names(lv) == [
               "user[email]",
               "user[organisation_name]",
               "user[password]",
               "user[password_confirmation]"
             ]

      # The page never writes a password back.
      refute has_element?(lv, "#registration_form input[type=password][value]")
      assert has_element?(lv, "#registration_form[action='/users/log-in']")

      email = unique_user_email()

      conn =
        sign_up_with_password(conn, lv, %{
          "email" => email,
          "organisation_name" => unique_organisation_name()
        })

      assert_signed_in(conn, email)

      assert %Tenant{kind: :organisation, instance_organisation: false} =
               tenant_of(organisation_of(email))
    end

    test "with operators open, it says so and asks for a password", %{conn: conn} do
      open!([:operator])
      Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert context(lv) =~ "You become the owner of the operator."
      assert context(lv) =~ "An operator creates clients."

      assert context(lv) =~
               "You sign in with a password."

      email = unique_user_email()

      conn =
        sign_up_with_password(conn, lv, %{
          "email" => email,
          "organisation_name" => unique_organisation_name()
        })

      assert_signed_in(conn, email)
      assert %Tenant{kind: :operator} = tenant_of(organisation_of(email))
    end

    test "with both open, the choice and a password, and the person is signed in",
         %{conn: conn} do
      open!([:organisation, :operator])
      Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert context(lv) =~
               "You sign in with a password."

      assert field_names(lv) == [
               "user[email]",
               "user[kind]",
               "user[organisation_name]",
               "user[password]",
               "user[password_confirmation]"
             ]

      email = unique_user_email()

      conn =
        sign_up_with_password(conn, lv, %{
          "email" => email,
          "kind" => "operator",
          "organisation_name" => unique_organisation_name()
        })

      assert_signed_in(conn, email)
      assert %Tenant{kind: :operator} = tenant_of(organisation_of(email))
    end

    test "a short password, or one that does not match, is refused and nothing is made",
         %{conn: conn} do
      open!([:organisation])
      Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()
      name = unique_organisation_name()

      lv
      |> form("#registration_form",
        user: %{
          "email" => email,
          "organisation_name" => name,
          "password" => "too short",
          "password_confirmation" => "too short"
        }
      )
      |> render_submit()

      assert has_element?(lv, "#user_password-error", "should be at least 12 character(s)")
      refute has_element?(lv, "#registration_form[phx-trigger-action]")
      refute Accounts.get_user_by_email(email)

      lv
      |> form("#registration_form",
        user: %{
          "email" => email,
          "organisation_name" => name,
          "password" => @password,
          "password_confirmation" => "another pass phrase"
        }
      )
      |> render_submit()

      assert has_element?(lv, "#user_password_confirmation-error", "does not match password")
      refute Accounts.get_user_by_email(email)
    end

    test "an invited sign-up keeps the invitation's address, joins at once and signs the person in",
         %{conn: conn} do
      %{scope: scope, invitation: invitation, token: token} = invitation()
      # Sign-up is by invitation alone: the invitation still signs its person up.
      open!([])
      Mail.put_test_source(:none)

      {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")

      assert context(lv) =~
               "You sign in with a password."

      refute html =~ "Choose a password to sign in with."
      refute html =~ "need no password"
      assert html =~ "Your account joins it as soon as you create it."
      refute html =~ "as soon as you confirm"

      assert has_element?(
               lv,
               "#registration_form input[name='user[email]'][value='#{invitation.email}'][readonly]"
             )

      refute has_element?(lv, "#registration_form [name='user[kind]']")

      assert field_names(lv) == [
               "user[email]",
               "user[password]",
               "user[password_confirmation]"
             ]

      conn = sign_up_with_password(conn, lv, %{"email" => invitation.email})
      assert_signed_in(conn, invitation.email)
      assert organisation_of(invitation.email).id == scope.organisation.id
    end

    test "an invited sign-up takes the invitation's address, whatever the form sends",
         %{conn: conn} do
      %{scope: scope, invitation: invitation, token: token} = invitation()
      Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
      other = unique_user_email()

      lv
      |> element("#registration_form")
      |> render_submit(%{
        "user" => %{
          "email" => other,
          "password" => @password,
          "password_confirmation" => @password
        }
      })

      refute Accounts.get_user_by_email(other)
      assert organisation_of(invitation.email).id == scope.organisation.id
    end

    test "the invitation-only page says the inviter sends the link", %{conn: conn} do
      open!([])
      Mail.put_test_source(:none)
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#sign-up-closed")

      assert html =~
               "Accounts are created by invitation. Ask an owner or an admin of your organisation to invite you; they send you the link to sign up."

      refute html =~ "the email they send"
    end
  end

  describe "with mail" do
    test "the open sign-up asks for no password and emails a link to confirm", %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert context(lv) =~
               "You sign in with a link we email you and need no password."

      refute has_element?(lv, "#registration_form input[type=password]")
      refute has_element?(lv, "#registration_form[action]")
      refute has_element?(lv, "#registration_form[phx-trigger-action]")
      email = unique_user_email()

      html =
        lv
        |> form("#registration_form",
          user: %{
            "email" => email,
            "kind" => "organisation",
            "organisation_name" => unique_organisation_name()
          }
        )
        |> render_submit()

      assert html =~ "We sent a confirmation link to"
      assert_received {:email, %Swoosh.Email{to: [{_, ^email}]}}
    end

    test "the context says who the person becomes, by the one kind the instance opens",
         %{conn: conn} do
      for {kinds, line} <- [
            {[:organisation],
             "You become the owner of the organisation. Owners rename it later in Organisation settings."},
            {[:operator],
             "You become the owner of the operator. Owners rename it later in Organisation settings."}
          ] do
        open!(kinds)
        {:ok, lv, html} = live(conn, ~p"/users/register")

        assert context(lv) =~ line
        refute html =~ "Start an"
        refute html =~ "We will email you a link to confirm"
      end
    end

    test "a password sent all the same is dropped, and the address is confirmed by email",
         %{conn: conn} do
      open!([:organisation])
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      html =
        lv
        |> element("#registration_form")
        |> render_submit(%{
          "user" => %{
            "email" => email,
            "organisation_name" => unique_organisation_name(),
            "password" => @password,
            "password_confirmation" => @password
          }
        })

      assert html =~ "We sent a confirmation link to"
      refute has_element?(lv, "#registration_form[phx-trigger-action]")

      user = Accounts.get_user_by_email(email)
      assert is_nil(user.hashed_password)
      refute Accounts.get_user_by_email_and_password(email, @password)
    end

    test "an invited sign-up asks for no password, and its address may be changed",
         %{conn: conn} do
      %{token: token} = invitation()
      {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")

      assert context(lv) =~
               "You sign in with a link we email you and need no password."

      refute context(lv) =~ "You become the owner"
      assert html =~ "Your account joins it as soon as you confirm."
      refute has_element?(lv, "#registration_form input[type=password]")
      refute has_element?(lv, "#registration_form input[name='user[email]'][readonly]")
    end

    test "the invitation-only page says the email has the link", %{conn: conn} do
      open!([])
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "the email they send has the link to sign up."
    end
  end
end

defmodule ApiaryProWeb.UserLive.SignUpMailFailsTest do
  @moduledoc """
  The edition's sign-up page when its confirmation email cannot be sent: the account is made, and
  the page says so and leads to the log-in page, where a new link is asked for. Not async:
  the application's mailer refuses every email for this module's tests alone, and the
  sign-up settings are the node's.
  """
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, :refused}
  end

  setup do
    ApiaryPro.SignUpFixtures.open!([:organisation])
    mailer = Application.get_env(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, Keyword.put(mailer, :adapter, Refusing))
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, mailer) end)

    :ok
  end

  test "an open sign-up's account is made, and the page says the email could not be sent",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register")
    email = unique_user_email()

    {:ok, _login, html} =
      lv
      |> form("#registration_form",
        user: %{"email" => email, "organisation_name" => unique_organisation_name()}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log-in")

    assert html =~ "Your account is made, but the email with its link could not be sent."
    assert html =~ "Ask for a new link on the log-in page in a few minutes."
    assert Apiary.Accounts.get_user_by_email(email)
  end
end
