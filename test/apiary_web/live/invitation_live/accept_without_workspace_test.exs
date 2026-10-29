defmodule ApiaryWeb.InvitationLive.AcceptWithoutWorkspaceTest do
  # The pages of an invitation sent while its organisation has no workspace: its link, its
  # acceptance and where it lands, the sign-up with it, and People, which lists it.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryWeb.SetUpSteps

  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  # The owner of a fresh organisation with no workspace, confirmed, and an invitation of
  # theirs to `bee@example.com`.
  setup do
    {:ok, %{user: owner, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: "Acme Studio"},
        nil,
        open: true,
        workspace: false
      )

    token = extract_user_token(&Accounts.deliver_login_instructions(owner, &1))
    {:ok, {owner, _expired}} = Accounts.login_user_by_magic_link(token)
    scope = Organisations.load_scope(Scope.for_user(owner))

    %{token: token, invitation: invitation} =
      invitation_fixture(scope, %{"email" => "bee@example.com"})

    %{
      owner: owner,
      scope: scope,
      organisation: organisation,
      token: token,
      invitation: invitation
    }
  end

  # The page's words, one space between each.
  defp text(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "signed out: the link names the organisation", %{conn: conn, token: token} do
    {:ok, lv, html} = live(conn, ~p"/invitations/#{token}")

    assert html =~ "Join Acme Studio"
    assert text(lv) =~ "You are invited to the Acme Studio organisation, as a member."
    refute html =~ "workspace of the"
    assert html =~ ~p"/users/register?invitation=#{token}"
  end

  test "signed out: the set-up starts with the invitation, then the account and the workspace",
       %{conn: conn, token: token} do
    {:ok, lv, _html} = live(conn, ~p"/invitations/#{token}")

    # Name alone of the flow, with the feature or without: the invitation makes a member,
    # who waits for an owner to set up the first workspace.
    assert steps(lv) ==
             [{"Invitation", :current}, {"Your account", :to_come}, {"Name", :to_come}]

    # The Invitation step has the organisation's id, for the edition; the page never
    # shows it.
    invitation = Organisations.get_invitation_by_token(token)

    assert [%{id: :invitation, organisation_id: organisation_id} | _] =
             ApiaryWeb.SetUpComponents.steps_for(nil, :invitation,
               invitation: invitation,
               token: token
             )

    assert organisation_id == invitation.organisation_id
    refute render(lv) =~ organisation_id

    {:ok, _register, register_html} = live(build_conn(), ~p"/users/register?invitation=#{token}")
    refute register_html =~ organisation_id

    assert has_element?(lv, "#invitation-email", "The invitation is for bee@example.com.")
    refute text(lv) =~ "Create an account with"

    assert has_element?(
             lv,
             "#set-up-context #invitation-context",
             "The invitation adds you to Acme Studio. Acme Studio has no workspace " <>
               "yet: its first one is set up after your account."
           )

    # The sign-up after it: the invitation done, a link back to its page.
    {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")

    assert [{"Invitation", :done, :link}, {"Your account", :current}, {"Name", :to_come}] =
             steps(lv)

    assert has_element?(lv, ~s{#set-up-steps-invitation[href="/invitations/#{token}"]})
  end

  test "signed in: accepts and lands on the workspace set-up", %{
    conn: conn,
    token: token,
    organisation: organisation
  } do
    user = user_fixture(%{email: "bee@example.com"})
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/invitations/#{token}")
    set_up = ~p"/#{organisation}/set-up"

    assert {:error, {:redirect, %{to: ^set_up}}} =
             lv |> element("button", "Accept invitation") |> render_click()

    assert [membership] = Organisations.list_memberships(user)
    assert membership.organisation_id == organisation.id
    assert membership.level == :member

    # A member does not create the first workspace: the page says who does.
    {:ok, lv, _html} = live(conn, set_up)
    assert has_element?(lv, "#set-up-waiting")
    refute has_element?(lv, "#set-up-form")

    # And the landing sends them there too.
    assert redirected_to(get(conn, ~p"/")) == set_up
  end

  test "signed in, after the organisation got a workspace: lands on its overview", %{
    conn: conn,
    scope: scope,
    token: token,
    organisation: organisation
  } do
    {:ok, _main} = Organisations.create_first_workspace(scope, %{"domain" => "software"})
    conn = log_in_user(conn, user_fixture(%{email: "bee@example.com"}))

    {:ok, lv, html} = live(conn, ~p"/invitations/#{token}")
    assert html =~ "Join Acme Studio"
    overview = ~p"/#{organisation}"

    assert {:error, {:redirect, %{to: ^overview}}} =
             lv |> element("button", "Accept invitation") |> render_click()
  end

  test "registering with it joins the organisation", %{
    conn: conn,
    token: token,
    organisation: organisation
  } do
    {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")

    assert text(lv) =~
             "You are invited to Acme Studio. You can open it as soon as you confirm your email address."

    html =
      lv
      |> form("#registration_form", user: %{email: "bee@example.com"})
      |> render_submit()

    assert html =~ "Check your email"

    user = Accounts.get_user_by_email("bee@example.com")
    assert [membership] = Organisations.list_memberships(user)
    assert membership.organisation_id == organisation.id
  end

  test "registering with it, without mail, says the account joins once made", %{
    conn: conn,
    token: token
  } do
    Apiary.Mail.put_test_source(:none)
    {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{token}")

    assert text(lv) =~
             "You are invited to Acme Studio. You can open it as soon as you create your account."
  end

  test "People lists it with no workspace, before and after the organisation has one", %{
    conn: conn,
    owner: owner,
    scope: scope,
    organisation: organisation,
    invitation: invitation
  } do
    conn = log_in_user(conn, owner)

    {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/people")
    assert has_element?(lv, "#invitation-#{invitation.id}")
    assert has_element?(lv, "#invitation-#{invitation.id}-workspace", "None")

    {:ok, _main} = Organisations.create_first_workspace(scope, %{"domain" => "software"})

    {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/people")
    assert has_element?(lv, "#invitation-#{invitation.id}-workspace", "None")
  end
end
