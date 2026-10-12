defmodule ApiaryWeb.NodesPartTest do
  @moduledoc """
  The part `nodes`, of no feature (`Apiary.Features.parts/0`): the nodes, the node pools,
  their access keys and the gateways. Hidden from a person, every page of them answers
  not found and an open one leaves; the navigation, New, the palette and the Runs list's
  empty state leave them out. Shown, each has them as before.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures

  alias Apiary.AccessKeys

  @node_views [
    ApiaryWeb.NodeLive.Index,
    ApiaryWeb.NodeLive.Show,
    ApiaryWeb.NodeLive.AccessKey,
    ApiaryWeb.NodeLive.Gateways
  ]

  setup :register_and_log_in_user

  # The organisation's gateways are offered where it may have many workspaces; the
  # edition hides from people what the test names.
  setup %{scope: scope} do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspacesHidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([])

    node = node_fixture(scope, name: "build-01")
    %{access_key: key} = access_key_fixture(scope, node: node)
    {:ok, code, _secret} = AccessKeys.create_enrolment_code(scope, node, %{})
    gateway = organisation_gateway_fixture(scope)

    %{node: node, key: key, code: code, gateway: gateway}
  end

  defp hide(names), do: :ok = Apiary.EditionStubs.HidesNamed.put(names)

  # Every route of the nodes' pages, each `{verb, path}`.
  defp node_routes do
    for {verb, path, module} <- ApiaryWeb.RoutesFeaturesCase.routes(ApiaryWeb.Router),
        module in @node_views,
        do: {verb, path}
  end

  # A route's path with the test's organisation, workspace, node or gateway, key and code.
  defp concrete(path, ctx) do
    node = if String.starts_with?(path, "/:org/gateways"), do: ctx.gateway, else: ctx.node

    path
    |> String.replace(":org", ctx.scope.organisation.slug)
    |> String.replace(":workspace", ctx.scope.workspace.slug)
    |> String.replace(":node_id", node.public_id)
    |> String.replace(":key_id", ctx.key.key_id)
    |> String.replace(":code_id", to_string(ctx.code.id))
    |> String.replace(":instance", "i_1")
  end

  defp jump(conn, scope) do
    conn
    |> put_req_header("accept", "application/json")
    |> get(workspace_path(scope, "/jump"), %{"q" => ""})
    |> json_response(200)
  end

  defp labels(answer, group) do
    case Enum.find(answer["groups"], &(&1["label"] == group)) do
      nil -> []
      found -> Enum.map(found["items"], & &1["label"])
    end
  end

  describe "hidden from a person" do
    test "every page of the nodes answers not found", %{conn: conn} = ctx do
      routes = node_routes()
      assert {:get, "/:org/:workspace/nodes"} in routes
      assert {:get, "/:org/:workspace/nodes/:node_id/access-key"} in routes
      assert {:get, "/:org/gateways"} in routes
      assert {:get, "/:org/gateways/:node_id"} in routes

      hide([:nodes])

      for {:get, path} <- routes do
        path = concrete(path, ctx)
        assert_error_sent(:not_found, fn -> get(conn, path) end)
      end
    end

    test "an open Nodes page, node page, Access key tab or Gateways page leaves, and says so",
         %{conn: conn, scope: scope, node: node, gateway: gateway} do
      for path <- [
            workspace_path(scope, "/nodes"),
            workspace_path(scope, "/nodes/#{node.public_id}"),
            workspace_path(scope, "/nodes/#{node.public_id}/access-key"),
            ~p"/#{scope.organisation}/gateways",
            ~p"/#{scope.organisation}/gateways/#{gateway.public_id}"
          ] do
        hide([])
        {:ok, view, _html} = live(conn, path)

        # Hidden meanwhile: the page hears of it as of any change to the reader's place.
        hide([:nodes])
        send(view.pid, {:membership_changed, :hidden})

        {to, flash} = assert_redirect(view)
        assert to == ~p"/#{scope.organisation}", path
        assert flash["error"] == "That page is no longer shown in #{scope.organisation.name}."
      end
    end

    test "an act on an open page, the nodes hidden before it heard so, leaves and says so",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/nodes/new"))
      hide([:nodes])

      view |> form("#new-node-form", node: %{name: "build-02"}) |> render_submit()

      {to, flash} = assert_redirect(view)
      assert to == ~p"/#{scope.organisation}"
      assert flash["error"] == "That page is no longer shown in #{scope.organisation.name}."
      refute Apiary.Repo.get_by(Apiary.Nodes.Node, name: "build-02")
    end

    test "an open page whose nodes are still shown stays", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/nodes"))
      hide([:"observability.terminal"])
      send(view.pid, {:membership_changed, :hidden})

      refute_redirected(view)
      assert has_element?(view, "#nav-nodes[aria-current]")
    end

    test "the sidebar, New and the palette have no nodes and no gateways",
         %{conn: conn, scope: scope} do
      hide([:nodes])

      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, "#sidebar a#nav-runs")
      refute has_element?(view, "#nav-nodes")
      refute has_element?(view, "#new-menu-node")
      refute has_element?(view, "#new-menu-node_pool")
      refute render(view) =~ workspace_path(scope, "/nodes")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}")
      refute has_element?(view, "#nav-gateways")
      refute has_element?(view, "#new-menu-gateway")
      refute render(view) =~ ~p"/#{scope.organisation}/gateways"

      answer = jump(conn, scope)
      refute "New node" in labels(answer, "Actions")
      refute "New node pool" in labels(answer, "Actions")
      assert "Invite people" in labels(answer, "Actions")
      refute "Nodes" in labels(answer, "Go to")
      refute "Gateways" in labels(answer, "Go to")
      assert "Runs" in labels(answer, "Go to")
    end

    test "the Runs list's empty state leads to no nodes page", %{conn: conn, scope: scope} do
      hide([:nodes])
      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs"))
      render_async(view)

      assert render(view) =~ "No runs yet"

      assert render(view) =~ "A machine posts once it is connected to a node."
      refute has_element?(view, "#runs-go-to-nodes")
      refute has_element?(view, "#runs-new-node")
      refute render(view) =~ workspace_path(scope, "/nodes")
    end

    test "the Runs list's empty state of a workspace with no node leads nowhere either",
         %{conn: conn, scope: scope, node: node} do
      {:ok, _} = Apiary.Nodes.delete_node(scope, node)
      hide([:nodes])
      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs"))
      render_async(view)

      assert render(view) =~ "An owner or admin adds nodes."
      refute has_element?(view, "#runs-go-to-nodes")
      refute has_element?(view, "#runs-new-node")
      refute render(view) =~ workspace_path(scope, "/nodes")
    end
  end

  describe "shown" do
    test "every page opens, and the navigation, New and the palette have them",
         %{conn: conn, scope: scope, node: node, gateway: gateway} do
      for path <- [
            workspace_path(scope, "/nodes"),
            workspace_path(scope, "/nodes/#{node.public_id}"),
            workspace_path(scope, "/nodes/#{node.public_id}/access-key"),
            ~p"/#{scope.organisation}/gateways",
            ~p"/#{scope.organisation}/gateways/#{gateway.public_id}"
          ] do
        assert {:ok, _view, _html} = live(conn, path)
      end

      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, "#nav-nodes")
      assert has_element?(view, "#new-menu-node")
      assert has_element?(view, "#new-menu-node_pool")
      assert has_element?(view, "#runs-go-to-nodes")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}")
      assert has_element?(view, "#nav-gateways")
      assert has_element?(view, "#new-menu-gateway")

      answer = jump(conn, scope)
      assert "New node" in labels(answer, "Actions")
      assert "Nodes" in labels(answer, "Go to")
    end
  end
end
