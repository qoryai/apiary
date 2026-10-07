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

    test "is the workspace sidebar's Nodes, the current entry", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      assert has_element?(lv, ~s{#nav-nodes[aria-current="page"][href$="/nodes"]})
      assert has_element?(lv, "#nav-runs:not([aria-current])")
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

    test "the header has New node, then New node pool, alike", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      ids =
        render(lv)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#page-header-actions a")
        |> LazyHTML.attribute("id")

      assert ids == ["new-node", "new-node-pool"]
      refute has_element?(lv, "#page-header-actions .btn-primary")
    end

    test "New node is a page of the Nodes section", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      lv |> element("#new-node") |> render_click()
      assert_patch(lv, nodes_path(scope, "/new"))

      refute has_element?(lv, "#new-node-dialog")
      refute has_element?(lv, "#nodes-empty")
      assert has_element?(lv, "main h1", "New node")
      assert has_element?(lv, "main header", "One permanent machine.")
      assert has_element?(lv, "main header", "You can't change the kind later.")
      assert has_element?(lv, ~s{#breadcrumb a[href="#{nodes_path(scope)}"]}, "Nodes")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New node")
      assert has_element?(lv, ~s{#new-node-form input[name="node[name]"][phx-mounted]})
      assert has_element?(lv, "#new-node-save #new-node-submit", "Add node")
      assert has_element?(lv, ~s{#new-node-save-cancel[href="#{nodes_path(scope)}"]}, "Cancel")
      assert page_title(lv) =~ "New node"

      lv |> element("#new-node-save-cancel") |> render_click()
      assert_patch(lv, nodes_path(scope))
      refute has_element?(lv, "#new-node-form")
      assert has_element?(lv, "#nodes-empty", "No nodes yet")
    end

    test "New node pool is a page of the Nodes section", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope))

      lv |> element("#new-node-pool") |> render_click()
      assert_patch(lv, nodes_path(scope, "/new-pool"))

      refute has_element?(lv, "#new-node-dialog")
      assert has_element?(lv, "main h1", "New node pool")
      assert has_element?(lv, "main header", "Short-lived instances that share one access key.")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New node pool")
      assert has_element?(lv, "#new-node-save #new-node-submit", "Add node pool")
      assert has_element?(lv, ~s{#new-node-save-cancel[href="#{nodes_path(scope)}"]}, "Cancel")
      assert page_title(lv) =~ "New node pool"
    end

    test "a node is named, and its page opens on its Access key tab", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

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
      assert html =~ ~s{id="node-access-key"}
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

    test "a name in use is refused on the page", %{conn: conn, scope: scope} do
      node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      html = lv |> form("#new-node-form", node: %{name: "build-01"}) |> render_submit()
      assert html =~ "is already the name of a node in this workspace"
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New node")
      assert length(Nodes.list_nodes(scope)) == 1
      refute has_element?(lv, "main h1", "New node pool")
      refute has_element?(lv, "#new-node-form input[name='node[instance_limit]']")

      # The page keeps its kind after a refused save, and the next one is made.
      {:ok, _show, _html} =
        lv
        |> form("#new-node-form", node: %{name: "build-02"})
        |> render_submit()
        |> follow_redirect(conn)

      assert [%Node{name: "build-01"}, %Node{kind: :node, name: "build-02"}] =
               Enum.sort_by(Nodes.list_nodes(scope), & &1.name)
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

    test "is refused the form's paths, and its event", %{scope: scope} do
      conn = member_conn(scope)

      {:ok, _lv, html} = live(conn, nodes_path(scope, "/new-pool")) |> follow_redirect(conn)
      assert html =~ "Only owners and admins add nodes."

      {:ok, lv, html} = live(conn, nodes_path(scope, "/new")) |> follow_redirect(conn)

      assert html =~ "Only owners and admins add nodes."
      refute has_element?(lv, "#new-node-form")

      render_hook(lv, "create", %{"node" => %{"name" => "build-01"}})
      assert render(lv) =~ "Only owners and admins add nodes."
      assert Nodes.list_nodes(scope) == []
    end
  end

  describe "what the nodes are doing" do
    setup :register_and_log_in_user

    defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

    test "each node's state, and a pool's running instances under it", %{
      conn: conn,
      scope: scope
    } do
      running = node_fixture(scope, name: "build-01")
      idle = node_fixture(scope, name: "build-02")
      never = node_fixture(scope, name: "build-03")
      pool = pool_fixture(scope, name: "spot-runners", instance_limit: 20)
      node_run_fixture(running, "i_1")
      instance_fixture(idle, instance_id: "i_2", seen_at: ago(7200))
      instance_fixture(pool, instance_id: "p_1", name: "spot-1")
      for n <- 1..12, do: node_run_fixture(pool, "p_#{n}")

      {:ok, lv, _html} = live(conn, nodes_path(scope))

      assert has_element?(lv, "#node-#{running.public_id}-state", "Running")
      assert has_element?(lv, "#node-#{idle.public_id}-state", "Last seen")
      assert has_element?(lv, "#node-#{never.public_id}-state", "Never seen")
      assert has_element?(lv, "#node-#{pool.public_id}-state", "12 of 20 running")

      # Ten instances under the pool, then the rest as a count that leads to its page.
      assert has_element?(lv, "#nodes tr[id^='node-#{pool.public_id}-instance-']", "spot-1")

      assert lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#nodes tr[id^='node-#{pool.public_id}-instance-']")
             |> Enum.count() == 10

      assert has_element?(lv, "#node-#{pool.public_id}-more-link", "and 2 more")
      refute has_element?(lv, "#nodes tr[id^='node-#{running.public_id}-instance-']")
    end

    test "the views count and keep the running and the rest", %{conn: conn, scope: scope} do
      running = node_fixture(scope, name: "build-01")
      idle = node_fixture(scope, name: "build-02")
      node_run_fixture(running, "i_1")

      {:ok, lv, _html} = live(conn, nodes_path(scope))
      assert has_element?(lv, ~s{#nodes-view-all[aria-current="page"]}, "2")
      assert has_element?(lv, "#nodes-view-running", "1")
      assert has_element?(lv, "#nodes-view-idle", "1")

      lv |> element("#nodes-view-running") |> render_click()
      assert_patch(lv, nodes_path(scope, "?view=running"))
      assert has_element?(lv, "#node-#{running.public_id}")
      refute has_element?(lv, "#node-#{idle.public_id}")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "?view=idle"))
      refute has_element?(lv, "#node-#{running.public_id}")
      assert has_element?(lv, "#node-#{idle.public_id}")
    end

    test "sorts by name, or by last seen", %{conn: conn, scope: scope} do
      a = node_fixture(scope, name: "a-never")
      b = node_fixture(scope, name: "b-seen")
      c = node_fixture(scope, name: "c-running")
      instance_fixture(b, seen_at: ago(60))
      node_run_fixture(c, "i_1")

      order = fn lv ->
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#nodes > tr")
        |> LazyHTML.attribute("id")
      end

      {:ok, lv, _html} = live(conn, nodes_path(scope))
      assert order.(lv) == Enum.map([a, b, c], &"node-#{&1.public_id}")

      lv |> element("#nodes-sort-seen") |> render_click()
      assert_patch(lv, nodes_path(scope, "?sort=seen"))
      assert order.(lv) == Enum.map([c, b, a], &"node-#{&1.public_id}")
    end

    test "reads the nodes again as they change, and on its tick", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, nodes_path(scope))
      assert has_element?(lv, "#node-#{node.public_id}-state", "Never seen")

      subscribers = fn topic -> for {pid, _} <- Registry.lookup(Apiary.PubSub, topic), do: pid end
      assert lv.pid in subscribers.(Nodes.topic(scope.workspace.id))

      node_run_fixture(node, "i_1")
      send(lv.pid, :tick)
      assert has_element?(lv, "#node-#{node.public_id}-state", "Running")
    end
  end
end
