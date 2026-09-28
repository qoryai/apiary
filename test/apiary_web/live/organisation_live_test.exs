defmodule ApiaryWeb.OrganisationLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures

  describe "a person who reaches a workspace" do
    test "is sent on to the one they opened last while they reach it, else the first", %{
      conn: conn
    } do
      %{user: user, scope: scope, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      conn = log_in_user(conn, user)

      assert redirected_to(get(conn, ~p"/#{organisation}")) ==
               ~p"/#{organisation}/#{scope.workspace}"

      conn = conn |> get(~p"/#{organisation}/#{platform}/keys") |> recycle()
      assert redirected_to(get(conn, ~p"/#{organisation}")) == ~p"/#{organisation}/#{platform}"
    end

    test "a member opens the workspace they were invited to, and is sent on to it", %{
      conn: conn
    } do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{user: user} = member_fixture(owner, :member)
      conn = log_in_user(conn, user)

      assert conn |> get(~p"/#{organisation}/#{owner.workspace}") |> html_response(200)
      assert conn |> get(~p"/#{organisation}/#{owner.workspace}/runs") |> html_response(200)
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{organisation}/#{owner.workspace}"
    end

    test "an admin opens every workspace", %{conn: conn} do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      %{user: user} = member_fixture(owner, :admin)
      conn = log_in_user(conn, user)

      for workspace <- [owner.workspace, platform] do
        assert conn |> get(~p"/#{organisation}/#{workspace}") |> html_response(200)
      end
    end
  end
end
