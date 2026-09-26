defmodule ApiaryWeb.PathScopeTest do
  @moduledoc """
  The organisation and the workspace come from the path: a page shows the workspace its
  URL names, and a slug the user holds no membership in answers as a path that does not
  exist, not as forbidden.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Organisations.Workspace
  alias Apiary.Repo

  setup :register_and_log_in_user

  # A page of each kind: the workspace's, the organisation's, and the run log, which is
  # not a page.
  @pages ["", "/runs", "/connections", "/policy", "/keys", "/settings", "/runs/r-1/log"]
  @organisation_pages ["/members", "/settings"]

  # A response, whether the pipeline sent it or the endpoint rendered an error, without
  # the request id.
  defp answer(request) do
    conn = request.()
    {conn.status, conn.resp_body, headers(conn.resp_headers)}
  rescue
    _error ->
      {status, headers, body} = assert_error_sent(:not_found, request)
      {status, body, headers(headers)}
  end

  defp headers(headers),
    do: headers |> Enum.reject(fn {name, _} -> name == "x-request-id" end) |> Enum.sort()

  defp not_found?(conn, path), do: conn |> get(path) |> response(404) == "Not Found"

  test "another organisation's workspace is unreachable by its URL", %{conn: conn} do
    other = sign_up_fixture()

    for page <- @pages do
      assert not_found?(conn, workspace_path(other, page)), page
    end

    for page <- @organisation_pages do
      assert not_found?(conn, "/#{other.organisation.slug}#{page}"), page
    end

    assert not_found?(conn, "/#{other.organisation.slug}")
  end

  test "a slug that does not exist answers as the other organisation's does", %{
    conn: conn,
    scope: scope
  } do
    for page <- @pages do
      assert not_found?(conn, "/no-such-organisation/main#{page}"), page
      assert not_found?(conn, "/#{scope.organisation.slug}/no-such-workspace#{page}"), page
    end
  end

  test "an organisation's slug never reaches a workspace of another organisation", %{
    conn: conn,
    scope: scope
  } do
    other = sign_up_fixture()

    {:ok, platform} =
      %Workspace{organisation_id: other.organisation.id}
      |> Workspace.changeset(%{name: "Platform"})
      |> Workspace.put_slug("platform")
      |> Repo.insert()

    assert not_found?(conn, "/#{scope.organisation.slug}/#{platform.slug}")
    assert not_found?(conn, "/#{scope.organisation.slug}/#{platform.slug}/runs")
  end

  test "a live navigation to another organisation's workspace is not found", %{
    conn: conn,
    scope: scope
  } do
    other = sign_up_fixture()
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/keys")

    # The page is not mounted: the browser is told to load it, and gets the 404 above.
    assert {%{status: 404, reason: "reload"}, _call} =
             catch_exit(live_redirect(view, to: workspace_path(other, "/keys")))
  end

  test "one user, two workspaces, one page each: the path decides, not the session", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    other = sign_up_fixture()
    %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
    {:ok, _membership} = Organisations.accept_invitation(user, token)

    {:ok, mine, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
    {:ok, theirs, _html} = live(conn, ~p"/#{other.organisation}/#{other.workspace}/settings")

    assert has_element?(mine, "#workspace-slug", workspace_path(scope))
    assert has_element?(theirs, "#workspace-slug", workspace_path(other))
    assert has_element?(mine, "#organisation-row", scope.organisation.name)
    assert has_element?(theirs, "#organisation-row", other.organisation.name)
  end

  test "a reserved first segment is never an organisation: it answers as an unknown path" do
    json = put_req_header(build_conn(), "accept", "application/json")

    for {conn, path} <- [
          {json, "/v1/no-such-endpoint"},
          {build_conn(), "/users/no-such-page"},
          {build_conn(), "/invitations/token/keys"}
        ] do
      assert answer(fn -> get(conn, path) end) ==
               answer(fn -> get(conn, "/no/such/path/at/all/here") end),
             path
    end
  end

  test "a path that can hold no slug is not found, and no log-in is asked for" do
    for path <- [
          "/.env",
          "/wp-login.php",
          "/apple-touch-icon.png",
          "/Acme/main",
          "/acme/Main/runs",
          "/acme/.git",
          "/acme/keys",
          "/#{String.duplicate("a", 41)}/main"
        ] do
      assert answer(fn -> get(build_conn(), path) end) ==
               answer(fn -> get(build_conn(), "/no/such/path/at/all/here") end),
             path
    end
  end

  test "a shared link survives the log-in: the icon a browser asks for on the way does not take its place",
       %{scope: scope} do
    link = workspace_path(scope, "/runs?state=failed")
    conn = get(build_conn(), link)
    assert redirected_to(conn) == ~p"/users/log-in"

    # Before the log-in page is shown, the browser asks for its icon; had that been an
    # organisation's page, it would have stored itself as the return-to.
    conn = recycle(conn)

    conn = conn |> get("/apple-touch-icon.png") |> recycle()

    conn = get(conn, ~p"/users/log-in")
    assert get_session(conn, :user_return_to) == link
  end

  test "the workspace is remembered once, not written again on every request", %{
    conn: conn,
    scope: scope
  } do
    conn = get(conn, workspace_path(scope, "/keys"))
    assert get_session(conn, :last_workspace_id) == scope.workspace.id
    assert Map.has_key?(conn.resp_cookies, "_apiary_key")

    for path <- [workspace_path(scope, "/keys"), workspace_path(scope, "/runs/r-1/log")] do
      again = conn |> recycle() |> get(path)
      refute Map.has_key?(again.resp_cookies, "_apiary_key"), path
    end
  end

  test "a visitor who is not signed in is sent to log in, whatever the slugs", %{scope: scope} do
    for path <- [workspace_path(scope, "/runs"), "/no-such-organisation/main/runs"] do
      assert redirected_to(get(build_conn(), path)) == ~p"/users/log-in"
    end
  end
end
