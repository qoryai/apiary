defmodule ApiaryWeb.MemberLive.DeliveryTest do
  # Not async: the mailer's adapter is application configuration.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Organisations

  setup :register_and_log_in_user

  setup do
    previous = Application.fetch_env!(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)
  end

  test "an invitation that cannot be sent is an error on the page, and is not kept", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/members/invite")

    html =
      lv
      |> form("#invitation-form", invitation: %{email: "bee@example.com", level: "member"})
      |> render_submit()

    assert html =~ "could not be sent"
    refute html =~ "Invitation sent"
    assert Organisations.list_invitations(scope) == []
  end

  @tag :capture_log
  test "one that cannot be sent nor taken back says it is still pending, and lists it", %{
    conn: conn,
    scope: scope
  } do
    # Every deletion of an invitation fails, as when the database is away: the withdrawal
    # cannot happen. Inside the test's transaction, so it goes with it.
    Apiary.Repo.query!("""
    CREATE FUNCTION refuse_invitation_deletes() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'refused'; END $$ LANGUAGE plpgsql
    """)

    Apiary.Repo.query!("""
    CREATE TRIGGER refuse_invitation_deletes BEFORE DELETE ON invitations
    FOR EACH ROW EXECUTE FUNCTION refuse_invitation_deletes()
    """)

    {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/members/invite")

    html =
      lv
      |> form("#invitation-form", invitation: %{email: "bee@example.com", level: "member"})
      |> render_submit()

    assert html =~ "is still pending"
    refute html =~ "so it was not created"
    assert [%{email: "bee@example.com"} = invitation] = Organisations.list_invitations(scope)
    assert has_element?(lv, "#invitation-#{invitation.id}")
  end
end
