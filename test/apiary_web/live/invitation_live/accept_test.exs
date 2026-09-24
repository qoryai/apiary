defmodule ApiaryWeb.InvitationLive.AcceptTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  setup do
    owner = sign_up_fixture()

    %{token: token, invitation: invitation} =
      invitation_fixture(owner.scope, %{"email" => "bee@example.com"})

    %{owner: owner, token: token, invitation: invitation}
  end

  test "signed out: explains and links to register and to log in", %{
    conn: conn,
    token: token,
    owner: owner
  } do
    {:ok, _lv, html} = live(conn, ~p"/invitations/#{token}")

    assert html =~ "Join #{owner.hive.name}"
    assert html =~ owner.organisation.name
    assert html =~ "bee@example.com"
    assert html =~ ~p"/users/register?invitation=#{token}"
    assert html =~ ~p"/invitations/#{token}/continue"
    assert html =~ "workplace of the"
    assert html =~ "organisation, as a member."
    refute html =~ "<abbr"

    # the log in link remembers where to return
    conn = get(conn, ~p"/invitations/#{token}/continue")
    assert redirected_to(conn) == ~p"/users/log-in"
    assert get_session(conn, :user_return_to) == ~p"/invitations/#{token}/continue"
  end

  test "signed in: accepts and switches to the new apiary", %{
    conn: conn,
    token: token,
    owner: owner
  } do
    %{user: user} = sign_up_fixture()
    conn = log_in_user(conn, user)

    {:ok, lv, html} = live(conn, ~p"/invitations/#{token}")
    assert html =~ "Accept invitation"
    assert html =~ user.email

    html = lv |> element("button", "Accept invitation") |> render_click()
    assert html =~ "phx-trigger-action"

    conn = lv |> form("#switch-form") |> follow_trigger_action(conn)
    assert redirected_to(conn) == ~p"/hive"
    assert get_session(conn, :organisation_id) == owner.organisation.id

    assert Enum.any?(
             Organisations.list_memberships(user),
             &(&1.organisation_id == owner.organisation.id)
           )

    assert Organisations.list_invitations(owner.scope) == []

    # the session's organisation is the one shown
    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:organisation_id, owner.organisation.id)

    {:ok, _lv, html} = live(conn, ~p"/hive")
    assert html =~ owner.hive.name
    assert html =~ ~p"/organisations/switch"
  end

  test "signed in as an existing member: says so and switches", %{
    conn: conn,
    token: token,
    owner: owner
  } do
    conn = log_in_user(conn, owner.user)

    {:ok, lv, _html} = live(conn, ~p"/invitations/#{token}")
    html = lv |> element("button", "Accept invitation") |> render_click()

    assert html =~ "already a member"
    assert html =~ "phx-trigger-action"
  end

  test "an invalid token shows a friendly page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/invitations/not-a-token")
    assert html =~ "no longer valid"
    assert html =~ ~p"/users/log-in"
  end

  test "registering with the invitation joins the hive", %{
    conn: conn,
    token: token,
    owner: owner
  } do
    {:ok, lv, html} = live(conn, ~p"/users/register?invitation=#{token}")

    assert html =~ "You are invited to the"
    assert html =~ owner.hive.name
    assert html =~ ~s(value="bee@example.com")

    form = form(lv, "#registration_form", user: %{email: "bee@example.com"})
    html = render_submit(form)
    assert html =~ "Check your email"
    assert html =~ "We sent a confirmation link to"

    user = Apiary.Accounts.get_user_by_email("bee@example.com")
    assert [membership] = Organisations.list_memberships(user)
    assert membership.organisation_id == owner.organisation.id
    assert membership.level == :member
    assert Organisations.list_invitations(owner.scope) == []
  end
end
