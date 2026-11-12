defmodule ApiaryProWeb.UserLive.FirstSignInTest do
  @moduledoc """
  The edition's sign-up, followed to the first sign-in: the confirmation link in the email
  logs the person in, and they land on the organisation's overview, where the kind card
  creates the first workspace and opens its Name step; the workspace's overview then shows a
  first-run box that starts at adding a node. An owner is offered New node; an invited
  member is told who adds them.
  """
  # Not async: the sign-up settings are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Organisations}

  setup do
    open!([:organisation])
    :ok
  end

  # The token of the log-in link the sign-up sent to `email`.
  defp login_token(email) do
    receive do
      {:email, %{to: [{_, ^email}], text_body: body}} ->
        case Regex.run(~r{/users/log-in/([A-Za-z0-9_-]+)}, body) do
          [_, token] -> token
          nil -> login_token(email)
        end
    after
      1000 -> flunk("no log-in link was sent to #{email}")
    end
  end

  # Confirms the account with the link's token, as the person does, and follows where the
  # log-in sends them: the path, its page, and the signed-in connection.
  defp first_sign_in(conn, email) do
    token = login_token(email)
    {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")
    assert html =~ "Confirm my account"

    form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Your account is confirmed."
    to = redirected_to(conn)
    conn = recycle(conn)
    {:ok, lv, _html} = live(conn, to)
    {to, lv, conn}
  end

  # The first-run box that the workspace's overview shows, which the `factory` feature's
  # setup list takes the place of: the test runs without that feature, so only in the leg
  # with every feature on.
  @tag with_features: [:observability, :security]
  test "a sign-up's first sign-in lands on the organisation's overview, then the new workspace",
       %{conn: conn} do
    email = unique_user_email()
    {:ok, lv, _html} = live(conn, ~p"/users/register")

    lv
    |> form("#registration_form",
      user: %{"email" => email, "organisation_name" => unique_organisation_name()}
    )
    |> render_submit()

    {to, lv, conn} = first_sign_in(conn, email)

    [membership] = email |> Accounts.get_user_by_email() |> Organisations.list_memberships()
    refute Organisations.has_workspace?(membership.organisation)
    assert to == ~p"/#{membership.organisation}"

    # The overview shows the kind cards; the software card links to the type's page, and
    # Create workspace there creates the workspace and opens its Name step.
    assert has_element?(lv, "#set-up-card-software-link")

    assert {:error, {:live_redirect, %{to: type_page}}} =
             lv |> element("#set-up-card-software-link") |> render_click()

    {:ok, type_view, _html} = live(conn, type_page)

    {:ok, lv, _html} =
      type_view |> element("#workspace-type-create") |> render_click() |> follow_redirect(conn)

    assert Organisations.has_workspace?(membership.organisation)

    lv |> form("#set-up-form", workspace: %{name: "Main"}) |> render_submit()
    assert_redirect(lv)

    {:ok, lv, _html} = live(conn, ~p"/#{membership.organisation}/main")
    assert has_element?(lv, "#onboarding[data-step='1']", "Add a machine")
    assert has_element?(lv, "#onboarding-new-node", "New machine")
    refute has_element?(lv, "#onboarding-members")
  end

  # The first-run box that the workspace's overview shows, which the `factory` feature's
  # setup list takes the place of: the test runs without that feature, so only in the leg
  # with every feature on.
  @tag with_features: [:observability, :security]
  test "an invited member's first sign-in is told who adds nodes", %{conn: conn} do
    %{scope: owner} = sign_up_fixture()
    %{invitation: invitation, token: token} = invitation_fixture(owner)

    {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")

    lv
    |> form("#registration_form", user: %{"email" => invitation.email})
    |> render_submit()

    {to, lv, _conn} = first_sign_in(conn, invitation.email)
    assert to == ~p"/#{owner.organisation}/#{owner.workspace}"

    assert has_element?(lv, "#onboarding[data-step='1']", "Add a machine")

    assert has_element?(
             lv,
             "#onboarding-members",
             "An owner or admin adds machines and connects them."
           )

    refute has_element?(lv, "#onboarding-new-node")
    refute has_element?(lv, "#onboarding-new-pool")
  end
end
