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

  test "H3: an invitation that cannot be sent is an error on the page, and is not kept", %{
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
end
