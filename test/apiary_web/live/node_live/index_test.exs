defmodule ApiaryWeb.NodeLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Nodes
  alias Apiary.Nodes.Node

  defp nodes_path(scope, query \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes" <> query

  # A member of the scope's organisation, signed in on a connection of their own.
  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  describe "the list" do
    setup :register_and_log_in_user

    test "lists the workspace's nodes, a pool's kind in words", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      pool = pool_fixture(scope, name: "spot-runners")
      theirs = node_fixture(sign_up_fixture().scope, name: "elsewhere")

      {:ok, lv, _html} = live(conn, nodes_path(scope))

      assert has_element?(lv, "#node-#{node.public_id}", "build-01")
      assert has_element?(lv, "#node-#{node.public_id}", node.public_id)
      assert has_element?(lv, "#node-#{pool.public_id}-kind", "Pool")
      refute has_element?(lv, "#node-#{node.public_id}-kind")
      assert has_element?(lv, "#node-#{node.public_id}-state", "Never seen")
      refute has_element?(lv, "#node-#{theirs.public_id}")

      assert has_element?(
               lv,
               ~s{#node-#{node.public_id} a[href="#{nodes_path(scope, "/#{node.public_id}")}"]}
             )
    end

    test "has no entry in the sidebar, and the workspace's sidebar", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      refute has_element?(lv, "#nav-nodes")
      refute has_element?(lv, ~s{nav a[aria-current="page"][href$="/nodes"]})
      assert has_element?(lv, "#nav-runs")
      assert has_element?(lv, "#breadcrumb", "Nodes")
    end

    test "says so when there are none, with the ways to add one", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      assert has_element?(lv, "#nodes-empty", "No nodes yet")
      assert has_element?(lv, "#nodes-empty a", "New node")
      assert has_element?(lv, "#nodes-empty a", "New node pool")
      refute has_element?(lv, "#nodes")
    end

    test "narrows by a name or an id, and by kind", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      pool = pool_fixture(scope, name: "spot-runners")

      {:ok, lv, _html} = live(conn, nodes_path(scope))

      lv |> form("#nodes-search", %{q: "build"}) |> render_change()
      assert_patch(lv, nodes_path(scope, "?q=build"))
      assert has_element?(lv, "#node-#{node.public_id}")
      refute has_element?(lv, "#node-#{pool.public_id}")
      assert has_element?(lv, "#nodes-summary", "1 node matches")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "?q=#{pool.public_id}"))
      assert has_element?(lv, "#node-#{pool.public_id}")
      refute has_element?(lv, "#node-#{node.public_id}")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "?kind=pool"))
      assert has_element?(lv, "#node-#{pool.public_id}")
      refute has_element?(lv, "#node-#{node.public_id}")
      assert has_element?(lv, "#nodes-token-kind", "Node pool")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "?q=nothing-like-it"))
      assert has_element?(lv, "#nodes-status", "No node matches")
      refute has_element?(lv, "#nodes")
    end
  end

  describe "New node and New node pool" do
    setup :register_and_log_in_user

    test "a node is named, and its page opens on Settings", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      lv |> element("#new-node") |> render_click()
      assert_patch(lv, nodes_path(scope, "/new"))
      assert has_element?(lv, "#new-node-dialog", "You can't change the kind later.")
      refute has_element?(lv, "#new-node-form input[name='node[instance_limit]']")

      assert lv |> form("#new-node-form", node: %{name: ""}) |> render_change() =~
               "can&#39;t be blank"

      {:ok, _show, html} =
        lv
        |> form("#new-node-form", node: %{name: "build-01"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [%Node{kind: :node, name: "build-01", instance_limit: 1} = node] =
               Nodes.list_nodes(scope)

      assert html =~ "build-01 is added."
      assert html =~ ~s{id="node-form"}
      assert html =~ node.public_id
    end

    test "a pool is named with its limit, or none", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-pool"))

      assert has_element?(lv, "#new-node-form input[name='node[instance_limit]']")

      assert lv
             |> form("#new-node-form", node: %{name: "spot-runners", instance_limit: "0"})
             |> render_change() =~ "must be greater than or equal to 1"

      {:ok, _show, _html} =
        lv
        |> form("#new-node-form", node: %{name: "spot-runners", instance_limit: "10"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [%Node{kind: :pool, instance_limit: 10, public_id: "np_" <> _}] =
               Nodes.list_nodes(scope)
    end

    test "a name in use is refused in the dialog", %{conn: conn, scope: scope} do
      node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      html = lv |> form("#new-node-form", node: %{name: "build-01"}) |> render_submit()
      assert html =~ "is already the name of a node in this workspace"
      assert length(Nodes.list_nodes(scope)) == 1
    end

    test "an admin adds nodes", %{scope: scope} do
      conn = member_conn(scope, :admin)
      {:ok, lv, _html} = live(conn, nodes_path(scope))
      assert has_element?(lv, "#new-node")
      assert has_element?(lv, "#new-node-pool")
    end
  end

  describe "a member" do
    setup :register_and_log_in_user

    test "reads the list without the buttons", %{scope: scope} do
      node = node_fixture(scope, name: "build-01")
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, nodes_path(scope))
      assert has_element?(lv, "#node-#{node.public_id}")
      refute has_element?(lv, "#new-node")
      refute has_element?(lv, "#new-node-pool")
    end

    test "is told who adds nodes when there are none", %{scope: scope} do
      {:ok, lv, _html} = live(member_conn(scope), nodes_path(scope))

      assert has_element?(lv, "#nodes-empty", "An owner or admin adds nodes.")
      refute has_element?(lv, "#nodes-empty a")
    end

    test "is refused the dialog's path, and its event", %{scope: scope} do
      conn = member_conn(scope)

      {:ok, lv, html} = live(conn, nodes_path(scope, "/new")) |> follow_redirect(conn)

      assert html =~ "Only owners and admins add nodes."
      refute has_element?(lv, "#new-node-dialog")

      render_hook(lv, "create", %{"node" => %{"name" => "build-01"}})
      assert render(lv) =~ "Only owners and admins add nodes."
      assert Nodes.list_nodes(scope) == []
    end
  end
end
