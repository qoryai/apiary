defmodule ApiaryProWeb.UserLive.SetUpFrameTest do
  @moduledoc """
  The edition's sign-up page and a person's New organisation page in the core's set-up frame
  (`ApiaryWeb.SetUpComponents.frame/1`): the steps indicator, Kind as the core's choice
  field, and the statements of the About column, with mail and without.
  """
  # Not async: the sign-up settings and the features are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.AccountsFixtures

  alias Apiary.{Features, Mail}
  alias ApiaryProWeb.OrganisationComponents

  @owner_organisation "You become the owner of the organisation. Owners rename it later in Organisation settings."
  @owner_operator "You become the owner of the operator. Owners rename it later in Organisation settings."
  @operator "An operator creates clients. Each client is a separate organisation; its people belong to it, not to the operator."
  @with_mail "You sign in with a link we email you and need no password."
  @without_mail "You sign in with a password."

  # The text of the page's About column, its paragraphs apart.
  defp context(lv) do
    lv
    |> element("#set-up-context")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("p")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp choose(lv, kind) do
    lv |> form("#registration_form", user: %{kind: kind}) |> render_change()
  end

  describe "the sign-up's steps" do
    setup do
      open!([:organisation, :operator])
      :ok
    end

    test "list Your account alone, so the page shows no steps indicator", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#registration_form")
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-step")
      refute has_element?(lv, "#set-up-steps-name")
    end

    @tag with_features: Features.all()
    test "list none of the workspace's steps with the factory, for an organisation and an operator",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-steps-sources")

      choose(lv, "operator")
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-steps-sources")
    end

    test "stay without a steps indicator after Create account, while the link is not followed",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      lv
      |> form("#registration_form",
        user: %{
          "email" => unique_user_email(),
          "kind" => "organisation",
          "organisation_name" => unique_organisation_name()
        }
      )
      |> render_submit()

      assert has_element?(lv, "main h1", "Check your email")
      refute has_element?(lv, "#set-up-steps")
      assert context(lv) == ["The link confirms that the address is yours and signs you in."]
    end

    test "are not shown where sign-up is by invitation alone", %{conn: conn} do
      open!([])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#sign-up-closed")
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-context")
    end
  end

  describe "the sign-up's Kind field" do
    test "is the core's choice field with both kinds, a title and a line each", %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#registration_form #user_kind-choice legend", "Kind")
      assert has_element?(lv, "#registration_form button#user_kind", "Choose a kind")
      refute has_element?(lv, "#registration_form", "What are you creating?")

      assert has_element?(
               lv,
               "#registration_form #user_kind-options label",
               "Organisation"
             )

      assert has_element?(
               lv,
               "#registration_form #user_kind-options label",
               "For a team that works in workspaces."
             )

      assert has_element?(
               lv,
               "#registration_form #user_kind-options label",
               "Operator"
             )

      assert has_element?(
               lv,
               "#registration_form #user_kind-options label",
               "Creates and runs organisations for clients."
             )

      assert has_element?(lv, "#registration_form input[type=radio][value=organisation]")
      assert has_element?(lv, "#registration_form input[type=radio][value=operator]")
    end

    test "is not there where one kind is open", %{conn: conn} do
      open!([:operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      refute has_element?(lv, "#user_kind-choice")
      refute has_element?(lv, "#registration_form [name='user[kind]']")
    end

    test "shows the chosen kind's title and line", %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      choose(lv, "operator")

      assert has_element?(lv, "button#user_kind", "Operator")
      assert has_element?(lv, "button#user_kind", "Creates and runs organisations for clients.")
      assert has_element?(lv, "input[type=radio][value=operator][checked]")
    end
  end

  describe "the sign-up's About accounts, with mail" do
    test "says who the person becomes and how they sign in", %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, "#set-up-context h2", "About accounts")
      assert context(lv) == [@owner_organisation, @with_mail]
    end

    test "names the operator once the operator kind is chosen", %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      choose(lv, "operator")
      assert context(lv) == [@owner_operator, @operator, @with_mail]

      choose(lv, "organisation")
      assert context(lv) == [@owner_organisation, @with_mail]
    end

    test "names the operator where only operators are open", %{conn: conn} do
      open!([:operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert context(lv) == [@owner_operator, @operator, @with_mail]
    end

    test "says nothing under the title and the name", %{conn: conn} do
      open!([:organisation])
      {:ok, lv, html} = live(conn, ~p"/users/register")

      refute has_element?(lv, "#set-up-line")
      refute has_element?(lv, "#user_organisation_name-hint")
      refute html =~ "Choose a password to sign in with."
      refute html =~ "We will email you a link to confirm"
    end
  end

  describe "the sign-up's About accounts, without mail" do
    setup do
      Mail.put_test_source(:none)
      :ok
    end

    test "says the account uses a password", %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert context(lv) == [@owner_organisation, @without_mail]

      choose(lv, "operator")
      assert context(lv) == [@owner_operator, @operator, @without_mail]
    end
  end

  describe "a person's New organisation steps" do
    setup [:register_and_log_in_user]

    test "list Your organisation alone, so the page shows no steps indicator", %{conn: conn} do
      open!([:organisation])
      {:ok, lv, _html} = live(conn, ~p"/users/organisations/new")

      assert has_element?(lv, "#new-organisation-form")
      refute has_element?(lv, "#set-up-steps")
      refute has_element?(lv, "#set-up-step")
      refute has_element?(lv, "#set-up-steps-name")
      refute has_element?(lv, "#set-up-steps-account")
    end

    @tag with_features: Features.all()
    test "are one with the factory, with none of the workspace's steps after Your organisation",
         %{conn: conn} do
      open!([:organisation])
      {:ok, lv, _html} = live(conn, ~p"/users/organisations/new")

      refute has_element?(lv, "#set-up-steps-sources")

      assert [%{id: :organisation, label: "Your organisation", state: :current}] =
               OrganisationComponents.new_organisation_steps()
    end

    test "have the Kind choice where both kinds are open, and its line under About organisations",
         %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, lv, _html} = live(conn, ~p"/users/organisations/new")

      assert has_element?(lv, "#new-organisation-form button#organisation_kind", "Choose a kind")
      assert has_element?(lv, "#organisation_kind-options label", "Organisation")
      assert has_element?(lv, "#organisation_kind-options label", "Operator")

      assert context(lv) == [
               "You become the first owner. You invite its people from Organisation settings › People.",
               "Work happens in workspaces. You choose what its first one does on the organisation's overview.",
               "Owners rename the organisation later in Organisation settings."
             ]
    end
  end
end
