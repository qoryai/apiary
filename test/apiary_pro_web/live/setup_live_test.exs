defmodule ApiaryProWeb.SetupLiveTest do
  @moduledoc """
  The core's set-up page, `/setup/<code>` (`ApiaryWeb.SetupLive`), on an instance: its
  line names what the set-up makes (`ApiaryPro.SignUp.first_sign_up_line/0`), an operator
  with `managed_organisations` and an organisation without, and the set-up makes the
  instance organisation of that kind (`ApiaryPro.Tenants.first_sign_up_kind/0`), its
  no workspace, and its owner an instance admin, signed in. The suite's instance is set
  up; each test hides its organisation inside its sandbox (`Apiary.EditionKit`) and names
  the features it runs with.
  """
  # Not async: the tests hide the suite's instance organisation, a row every test shares,
  # and switch the node's features.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  import ApiaryPro.OperatorsFixtures, only: [tenant_of: 1]

  alias Apiary.{Access, Accounts, Features, Organisations, Setup}
  alias ApiaryPro.Tenants.Tenant

  @password "a long pass phrase"

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    %{code: Setup.code!()}
  end

  # The page's line under its heading, as it reads.
  defp line(lv) do
    lv
    |> element("main h1 + p")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  # The set-up by the page, without mail, then posted to the log-in controller as the
  # browser does once the account is made: the conn it answers.
  defp set_up(conn, lv, email) do
    form =
      form(lv, "#setup_form",
        user: %{
          "email" => email,
          "organisation_name" => "Acme Hosting",
          "password" => @password,
          "password_confirmation" => @password
        }
      )

    render_submit(form)
    follow_trigger_action(form, conn)
  end

  # The instance organisation the set-up made, of `kind`, with no workspace, and the
  # account at `email` its owner, an instance admin, signed in on `conn`.
  defp assert_set_up(conn, email, kind) do
    assert get_session(conn, :user_token)
    assert Setup.set_up?()

    user = Accounts.get_user_by_email(email)
    assert Accounts.get_user_by_email_and_password(email, @password)
    assert Access.instance_admin?(Accounts.Scope.for_user(user))

    [membership] = Organisations.list_memberships(user)
    assert membership.level == :owner
    organisation = membership.organisation
    assert organisation.name == "Acme Hosting"
    assert ApiaryPro.Organisations.instance_organisation().id == organisation.id
    assert %Tenant{kind: ^kind, instance_organisation: true} = tenant_of(organisation)

    assert [] = Organisations.list_workspaces(Accounts.Scope.for_instance(organisation))
    refute Organisations.has_workspace?(organisation)
  end

  describe "with managed_organisations" do
    @describetag with_features: Features.all()

    test "the page says the set-up starts an operator", %{conn: conn, code: code} do
      {:ok, lv, html} = live(conn, ~p"/setup/#{code}")

      assert html =~ "Set up Qory Apiary"

      assert line(lv) ==
               "Your account and your operator, to run organisations for clients."

      assert line(lv) == Apiary.Edition.first_sign_up_line()
      refute html =~ "Your account and your organisation."
    end

    test "the set-up makes the instance organisation, an operator, and signs its owner in",
         %{conn: conn, code: code} do
      assert ApiaryPro.Tenants.first_sign_up_kind() == :operator
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      conn = set_up(conn, lv, email)
      assert_set_up(conn, email, :operator)
      refute Setup.valid_code?(code)
    end
  end

  describe "without managed_organisations" do
    @describetag with_features: Features.all() -- [:managed_organisations]

    test "the page says the set-up starts an organisation", %{conn: conn, code: code} do
      {:ok, lv, html} = live(conn, ~p"/setup/#{code}")

      assert line(lv) == "Your account and your organisation."
      assert line(lv) == Apiary.Edition.first_sign_up_line()
      refute html =~ "operator"
    end

    test "the set-up makes the instance organisation, an organisation, and signs its owner in",
         %{conn: conn, code: code} do
      assert ApiaryPro.Tenants.first_sign_up_kind() == :organisation
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      conn = set_up(conn, lv, email)
      assert_set_up(conn, email, :organisation)
      refute Setup.valid_code?(code)
    end
  end
end
