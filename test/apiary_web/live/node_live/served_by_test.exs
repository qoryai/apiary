defmodule ApiaryWeb.NodeLive.ServedByTest do
  # Served by, on a node pool's settings (`ApiaryWeb.NodeLive.Show`): the integration that
  # starts the pool's queued runs, chosen from the organisation's, or none; asked of a pool
  # alone; and a choice that is not the organisation's refused.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp settings_path(scope, node),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/settings"

  defp options(lv) do
    lv
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#node-form select[name='node[served_by_id]'] option")
    |> Enum.map(&LazyHTML.text/1)
  end

  test "a pool chooses the integration that serves it, or none", %{conn: conn, scope: scope} do
    github = adapter_fixture(scope, name: "GitHub")
    adapter_fixture(scope, name: "Linear")
    pool = pool_fixture(scope)

    {:ok, lv, html} = live(conn, settings_path(scope, pool))

    assert has_element?(lv, "#node-form label", "Served by")
    assert html =~ "The integration that starts this pool&#39;s queued runs."
    assert options(lv) == ["No integration", "GitHub", "Linear"]

    lv |> form("#node-form", node: %{served_by_id: github.id}) |> render_submit()
    assert Repo.reload!(pool).served_by_id == github.id

    lv |> form("#node-form", node: %{served_by_id: ""}) |> render_submit()
    assert Repo.reload!(pool).served_by_id == nil
  end

  test "a node is served by none, so its form does not ask", %{conn: conn, scope: scope} do
    adapter_fixture(scope)
    node = node_fixture(scope)

    {:ok, lv, _html} = live(conn, settings_path(scope, node))
    refute has_element?(lv, "#node-form select[name='node[served_by_id]']")
  end

  test "another organisation's integration is refused", %{conn: conn, scope: scope} do
    %{scope: other} = sign_up_fixture()
    elsewhere = adapter_fixture(other)
    pool = pool_fixture(scope)

    {:ok, lv, _html} = live(conn, settings_path(scope, pool))

    html =
      lv
      |> element("#node-form")
      |> render_submit(%{"node" => %{"served_by_id" => elsewhere.id}})

    assert html =~ "is invalid"
    assert Repo.reload!(pool).served_by_id == nil
  end
end
