defmodule ApiaryWeb.OrganisationSessionControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  describe "POST /organisations/switch" do
    setup :register_and_log_in_user

    test "switches to an organisation the user belongs to", %{conn: conn, user: user} do
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      conn =
        post(conn, ~p"/organisations/switch", %{"organisation_id" => other.organisation.id})

      assert redirected_to(conn) == ~p"/workspace"
      assert get_session(conn, :organisation_id) == other.organisation.id

      # the workspace page follows the session, and offers the switcher
      conn =
        build_conn()
        |> log_in_user(user)
        |> put_session(:organisation_id, other.organisation.id)
        |> get(~p"/workspace")

      response = html_response(conn, 200)
      assert response =~ other.workspace.name
      assert response =~ other.organisation.name
      assert response =~ ~p"/organisations/switch"
    end

    test "refuses an organisation the user does not belong to", %{conn: conn} do
      other = sign_up_fixture()

      conn =
        post(conn, ~p"/organisations/switch", %{"organisation_id" => other.organisation.id})

      assert redirected_to(conn) == ~p"/workspace"
      refute get_session(conn, :organisation_id)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not a member"
    end

    test "requires a signed-in user", %{conn: _conn} do
      conn = post(build_conn(), ~p"/organisations/switch", %{"organisation_id" => "x"})
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
