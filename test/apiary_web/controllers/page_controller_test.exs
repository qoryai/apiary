defmodule ApiaryWeb.PageControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  test "GET / shows the landing to a visitor", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Qory"
    assert response =~ "Log in"
    assert response =~ "Create an account"
    assert response =~ ~p"/users/log-in"
    assert response =~ ~p"/users/register"
    assert response =~ "Give your workspace an access key"
    refute response =~ ~r/\b(hive|apiary)\b/
  end

  test "GET / sends a signed-in user to their workspace", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: workspace} = sign_up_fixture()
    conn = conn |> log_in_user(user) |> get(~p"/")
    assert redirected_to(conn) == ~p"/#{organisation}/#{workspace}"
  end

  test "GET / sends a user to the workspace they opened last, while they are a member",
       %{conn: conn} do
    %{user: user, scope: scope} = sign_up_fixture()
    other = sign_up_fixture()
    %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
    {:ok, _membership} = Apiary.Organisations.accept_invitation(user, token)

    conn = log_in_user(conn, user)
    assert redirected_to(get(conn, ~p"/")) == ~p"/#{scope.organisation}/#{scope.workspace}"

    conn = get(conn, ~p"/#{other.organisation}/#{other.workspace}/runs")
    assert html_response(conn, 200)

    conn = conn |> recycle() |> get(~p"/")
    assert redirected_to(conn) == ~p"/#{other.organisation}/#{other.workspace}"
  end

  test "GET / sends a user without a membership to their organisations", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/users/organisations"
  end

  test "GET /:org sends a member on to their workspace in it", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: workspace} = sign_up_fixture()
    conn = conn |> log_in_user(user) |> get(~p"/#{organisation}")
    assert redirected_to(conn) == ~p"/#{organisation}/#{workspace}"
  end

  test "GET /:org answers not found to anyone who is not a member", %{conn: conn} do
    %{user: user} = sign_up_fixture()
    other = sign_up_fixture()
    conn = log_in_user(conn, user)

    assert conn |> get(~p"/#{other.organisation}") |> html_response(404)
    assert conn |> get(~p"/no-such-organisation") |> html_response(404)
  end
end
