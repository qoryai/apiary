defmodule ApiaryProWeb.UserLive.SignUpSettingsTest do
  @moduledoc """
  The sign-up page under each combination of the instance's sign-up settings, before the
  instance is set up, and with an invitation while both are closed.
  """
  # Not async: the settings are the node's, and a test before set-up hides the suite's
  # instance organisation's row.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  import ApiaryPro.OperatorsFixtures, only: [tenant_of: 1]

  alias Apiary.{Accounts, Organisations, Repo}
  alias ApiaryPro.Tenants.Tenant

  defp organisation_of(email) do
    [membership] = email |> Accounts.get_user_by_email() |> Organisations.list_memberships()
    membership.organisation
  end

  defp submit(lv, attrs) do
    email = unique_user_email()

    lv
    |> form("#registration_form",
      user:
        Map.merge(%{"email" => email, "organisation_name" => unique_organisation_name()}, attrs)
    )
    |> render_submit()

    email
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

  describe "with both settings closed" do
    setup do
      open!([])
      :ok
    end

    test "sign-up is not offered: the page says it is by invitation", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#sign-up-closed")
      refute has_element?(lv, "#registration_form")
      assert html =~ "Sign-up is by invitation"
    end

    test "the landing and the log-in page offer no sign-up", %{conn: conn} do
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/users/register"

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      refute html =~ "Create an account"
    end

    test "an invitation still signs its person up", %{conn: conn} do
      open!([:organisation])
      %{scope: scope} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)
      open!([])

      {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")
      refute has_element?(lv, "#sign-up-closed")
      refute has_element?(lv, "#registration_form [name='user[kind]']")

      lv
      |> form("#registration_form", user: %{"email" => invitation.email})
      |> render_submit()

      assert organisation_of(invitation.email).id == scope.organisation.id
    end
  end

  describe "before the instance is set up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "the page says to use the set-up link, with no form, whatever the settings and the mail",
         %{conn: conn} do
      for kinds <- [[], [:organisation], [:operator], [:organisation, :operator]],
          source <- [:env, :none] do
        open!(kinds)
        Apiary.Mail.put_test_source(source)
        {:ok, lv, html} = live(conn, ~p"/users/register")

        assert has_element?(lv, "#sign-up-not-set-up")
        refute has_element?(lv, "#registration_form")
        refute has_element?(lv, "#sign-up-closed")
        assert has_element?(lv, "#main h1", "Create your account")

        assert html =~
                 "This Qory Apiary is not set up yet: use the set-up link from its install."
      end
    end
  end

  test "a form sent once the instance is found not set up says to use the set-up link",
       %{conn: conn} do
    open!([:organisation])
    {:ok, lv, _html} = live(conn, ~p"/users/register")
    assert has_element?(lv, "#registration_form")

    # The instance is found without its organisation by the time the form is sent.
    Apiary.EditionKit.hide_instance_organisation()

    email = submit(lv, %{})
    refute Accounts.get_user_by_email(email)
    assert has_element?(lv, "#sign-up-not-set-up")
    refute has_element?(lv, "#registration_form")
  end

  test "with organisations open, no choice: an organisation", %{conn: conn} do
    open!([:organisation])
    {:ok, lv, html} = live(conn, ~p"/users/register")

    refute has_element?(lv, "#registration_form [name='user[kind]']")
    refute html =~ "Start an organisation"
    assert field_names(lv) == ["user[email]", "user[organisation_name]"]

    # The page says nothing under the title and the name, and the context says what the
    # person becomes, with the settings named by their level.
    refute has_element?(lv, "#set-up-line")
    refute has_element?(lv, "#user_organisation_name-hint")

    assert context(lv) =~
             "You become the owner of the organisation. Owners rename it later in Organisation settings."

    # The core's page before sign-in: the set-up frame, and the way to sign in.
    assert has_element?(lv, "#set-up-context h2", "About accounts")
    assert has_element?(lv, "#main h1", "Create your account")
    assert has_element?(lv, "#main a[href='/users/log-in']", "Sign in")

    email = submit(lv, %{})

    assert %Tenant{kind: :organisation, instance_organisation: false} =
             tenant_of(organisation_of(email))
  end

  test "with operators open, no choice: an operator", %{conn: conn} do
    open!([:operator])
    {:ok, lv, html} = live(conn, ~p"/users/register")

    refute has_element?(lv, "#registration_form [name='user[kind]']")
    refute html =~ "Start an operator"
    assert context(lv) =~ "You become the owner of the operator."
    assert context(lv) =~ "An operator creates clients."

    email = submit(lv, %{})

    assert %Tenant{kind: :operator, instance_organisation: false} =
             tenant_of(organisation_of(email))
  end

  test "with both open, the choice in plain words, asked before anything is created",
       %{conn: conn} do
    open!([:organisation, :operator])
    {:ok, lv, html} = live(conn, ~p"/users/register")

    assert has_element?(lv, "#registration_form input[type=radio][value=organisation]")
    assert has_element?(lv, "#registration_form input[type=radio][value=operator]")
    refute has_element?(lv, "#registration_form input[type=radio][value=instance_organisation]")
    # Main, the workspace it starts with, takes the one domain there is: nothing asks it.
    assert field_names(lv) == ["user[email]", "user[kind]", "user[organisation_name]"]
    assert html =~ "For a team that works in workspaces."
    assert html =~ "Creates and runs organisations for clients."
    refute html =~ "What are you creating?"

    email = submit(lv, %{})
    assert render(lv) =~ "choose what to create"
    refute Accounts.get_user_by_email(email)

    email = submit(lv, %{"kind" => "operator"})

    assert %Tenant{kind: :operator, instance_organisation: false} =
             tenant_of(organisation_of(email))
  end

  test "with both open, an empty address and no choice are both answered under their fields",
       %{conn: conn} do
    open!([:organisation, :operator])
    {:ok, lv, _html} = live(conn, ~p"/users/register")
    users = Repo.aggregate(Accounts.User, :count)

    lv
    |> form("#registration_form",
      user: %{"email" => "", "organisation_name" => unique_organisation_name()}
    )
    |> render_submit()

    assert has_element?(lv, "#user_email-error")
    assert has_element?(lv, "#user_kind-error", "choose what to create")
    assert Repo.aggregate(Accounts.User, :count) == users
  end
end
