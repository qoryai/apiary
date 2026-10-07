defmodule ApiaryWeb.PageControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  test "GET / shows the landing to a visitor", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Qory"
    assert response =~ "Log in"
    assert response =~ ~p"/users/log-in"
    # The way to sign up is there where a sign-up without an invitation is offered.
    offered? = Apiary.Organisations.sign_up_offered?()
    assert response =~ "Create an account" == offered?
    assert response =~ ~p"/users/register" == offered?
    assert response =~ "Give your workspace an access key"
    # The documentation, which the sidebar's product menu opens once signed in.
    assert response =~ ~r{<a[^>]*id="home-docs"[^>]*>|<a[^>]*href="/docs"[^>]*id="home-docs"}
    assert response =~ ~s(href="/docs")
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

  test "GET /:org is the organisation's overview, which leads to its workspace", %{conn: conn} do
    %{user: user, organisation: organisation, workspace: workspace} = sign_up_fixture()
    html = conn |> log_in_user(user) |> get(~p"/#{organisation}") |> html_response(200)
    assert html =~ ~s(href="/#{organisation.slug}/#{workspace.slug}")
  end

  test "GET /:org answers not found to anyone who is not a member", %{conn: conn} do
    %{user: user} = sign_up_fixture()
    other = sign_up_fixture()
    conn = log_in_user(conn, user)

    assert conn |> get(~p"/#{other.organisation}") |> html_response(404)
    assert conn |> get(~p"/no-such-organisation") |> html_response(404)
  end
end

defmodule ApiaryWeb.PageControllerFirstSignUpTest do
  @moduledoc """
  The landing on the instance's first sign-up, which every edition offers: the suite's
  instance organisation is hidden inside the test's sandbox (`Apiary.EditionKit`), and
  the landing leads to the sign-up.
  """
  # Not async: a test of the first sign-up holds the suite's instance organisation's row.
  use ApiaryWeb.ConnCase, async: false

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  test "GET / offers a visitor the first sign-up", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)
    assert response =~ "Create an account"
    assert response =~ ~p"/users/register"
  end
end
