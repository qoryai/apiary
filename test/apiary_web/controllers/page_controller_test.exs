defmodule ApiaryWeb.PageControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures

  test "GET / shows the landing to a visitor", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Qory"
    assert response =~ "Log in"
    assert response =~ "Create an account"
    assert response =~ ~p"/users/log-in"
    assert response =~ ~p"/users/register"
    assert response =~ "Give your workplace an access key"
    refute response =~ ~r/\b(hive|apiary)\b/
  end

  test "GET / sends a signed-in user to the hive", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/hive"
  end
end
