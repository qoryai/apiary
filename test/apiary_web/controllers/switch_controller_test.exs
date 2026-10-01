defmodule ApiaryWeb.SwitchControllerTest do
  @moduledoc """
  The switcher's link to a workspace keeps the reader's section only where that workspace
  has it: a section of a feature that is off there leads to the workspace's overview, never
  to a page that is not found.
  """
  # Not async: one test switches the node's features.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  setup :register_and_log_in_user

  defp other_place(user) do
    other = sign_up_fixture()
    %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
    {:ok, _membership} = Organisations.accept_invitation(user, token)
    other
  end

  @tag needs: :security
  test "a section of a feature leads through the destination, which keeps it where it has it",
       %{conn: conn, user: user, scope: scope} do
    other = other_place(user)
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy")

    switch = workspace_path(other, "/switch/policy")
    assert has_element?(view, "#organisation-menu a[data-place][href='#{switch}']")

    assert redirected_to(get(conn, switch)) == workspace_path(other, "/policy")
  end

  @tag with_features: [:observability]
  test "where the destination lacks the section's feature, its overview", %{
    conn: conn,
    user: user
  } do
    other = other_place(user)

    assert redirected_to(get(conn, workspace_path(other, "/switch/policy"))) ==
             workspace_path(other)
  end

  test "a section nobody has leads to the overview, and a place the reader does not reach is not found",
       %{conn: conn, user: user} do
    other = other_place(user)

    assert redirected_to(get(conn, workspace_path(other, "/switch/nothing"))) ==
             workspace_path(other)

    stranger = sign_up_fixture()
    assert conn |> get(workspace_path(stranger, "/switch/runs")) |> response(404)
  end

  test "a section of no feature, and the overview, are linked as they are", %{
    conn: conn,
    user: user,
    scope: scope
  } do
    other = other_place(user)
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    assert has_element?(view, "#organisation-menu a[data-place][href='#{workspace_path(other)}']")
  end
end
