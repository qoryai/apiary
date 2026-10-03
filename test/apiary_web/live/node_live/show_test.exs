defmodule ApiaryWeb.NodeLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Nodes
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  defp node_path(scope, node, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}" <> rest

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  setup :register_and_log_in_user

  describe "Overview" do
    test "names the node, its kind and its maker, under two tabs", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(conn, node_path(scope, node))

      assert has_element?(lv, "h1 #node-name", "build-01")
      assert has_element?(lv, "#node-public-id", node.public_id)
      assert has_element?(lv, "#node-kind", "Node")
      assert has_element?(lv, "#node-state", "Never seen")
      assert has_element?(lv, "#node-made", scope.user.email)
      assert has_element?(lv, "#breadcrumb", "Nodes")

      assert has_element?(lv, ~s{#node-tab-overview[aria-current="page"]}, "Overview")
      assert has_element?(lv, "#node-tab-settings.q-tabs-end", "Settings")
      assert lv |> element("#node-tabs") |> render() |> String.split("<a") |> length() == 3
    end

    test "says no instance and no run has reported yet", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      pool = pool_fixture(scope, instance_limit: 10)

      {:ok, lv, _html} = live(conn, node_path(scope, node))
      assert has_element?(lv, "#node-instances h2", "Instance")

      assert has_element?(
               lv,
               "#node-instances-none",
               "No instance of this node has reported yet."
             )

      assert has_element?(lv, "#node-runs-none", "No run of this node is in the record yet.")
      assert has_element?(lv, "#node-about-limit", "1, one instance at a time")

      {:ok, lv, _html} = live(conn, node_path(scope, pool))
      assert has_element?(lv, "#node-kind", "Node pool")
      assert has_element?(lv, "#node-instances h2", "Running instances")

      assert has_element?(
               lv,
               "#node-instances-none",
               "No instance of this pool has reported yet."
             )

      assert has_element?(lv, "#node-about-limit", "10")

      {:ok, _} = Nodes.update_node(scope, pool, %{instance_limit: ""})
      {:ok, lv, _html} = live(conn, node_path(scope, pool))
      assert has_element?(lv, "#node-about-limit", "No limit")
    end

    test "a tab is a patch of the page", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, node_path(scope, node))

      lv |> element("#node-tab-settings") |> render_click()
      assert_patch(lv, node_path(scope, node, "/settings"))
      assert has_element?(lv, "#node-form")

      lv |> element("#node-tab-overview") |> render_click()
      assert_patch(lv, node_path(scope, node))
      assert has_element?(lv, "#node-overview")
    end

    test "a node of another workspace or organisation, or a deleted one, is not found", %{
      conn: conn,
      scope: scope
    } do
      other_workspace = node_fixture(%{scope | workspace: workspace_fixture(scope.organisation)})
      other_organisation = node_fixture(sign_up_fixture().scope)
      deleted = node_fixture(scope)
      {:ok, _} = Nodes.delete_node(scope, deleted)

      for node <- [other_workspace, other_organisation, deleted] do
        assert_raise Ecto.NoResultsError, fn -> live(conn, node_path(scope, node)) end
      end

      assert_raise Ecto.NoResultsError, fn -> live(conn, node_path(scope, "nd_nothing")) end
    end
  end

  describe "Settings › General" do
    test "renames a node; its kind and limit are shown, not changed", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))

      assert has_element?(lv, "#settings-tab-general[aria-current=page]", "General")
      refute has_element?(lv, "#settings-tabs a", "Access keys")
      assert has_element?(lv, "#node-kind-field", "Node: one permanent machine.")
      assert has_element?(lv, "#node-limit-field", "A node runs one instance at a time.")
      refute has_element?(lv, "#node-form input[name='node[instance_limit]']")

      html = lv |> form("#node-form", node: %{name: "build-02"}) |> render_submit()
      assert html =~ "build-02 is saved."
      assert has_element?(lv, "h1 #node-name", "build-02")
      assert %Node{name: "build-02", kind: :node} = Repo.get!(Node, node.id)
    end

    test "changes a pool's limit, and empties it for none", %{conn: conn, scope: scope} do
      pool = pool_fixture(scope, name: "spot-runners")
      {:ok, lv, _html} = live(conn, node_path(scope, pool, "/settings"))

      assert has_element?(lv, "#node-kind-field", "Node pool")

      assert lv
             |> form("#node-form", node: %{instance_limit: "10001"})
             |> render_change() =~ "must be less than or equal to 10000"

      lv
      |> form("#node-form", node: %{name: "spot-runners", instance_limit: "10"})
      |> render_submit()

      assert Repo.get!(Node, pool.id).instance_limit == 10

      lv
      |> form("#node-form", node: %{name: "spot-runners", instance_limit: ""})
      |> render_submit()

      assert Repo.get!(Node, pool.id).instance_limit == nil
    end

    test "a member reads it, with nothing to change", %{scope: scope} do
      node = node_fixture(scope, name: "build-01")
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))

      assert has_element?(
               lv,
               "#node-settings-readonly",
               "Only owners and admins change these settings."
             )

      assert has_element?(lv, "#node-form input[name='node[name]'][disabled]")
      refute has_element?(lv, "#node-save")
      refute has_element?(lv, "#node-danger")

      render_hook(lv, "save", %{"node" => %{"name" => "mine"}})
      assert render(lv) =~ "Only owners and admins change nodes."
      assert Repo.get!(Node, node.id).name == "build-01"
    end

    test "an admin changes it", %{scope: scope} do
      pool = pool_fixture(scope)
      conn = member_conn(scope, :admin)

      {:ok, lv, _html} = live(conn, node_path(scope, pool, "/settings"))
      assert has_element?(lv, "#node-save")
      assert has_element?(lv, "#node-danger")

      lv |> form("#node-form", node: %{instance_limit: "3"}) |> render_submit()
      assert Repo.get!(Node, pool.id).instance_limit == 3
    end
  end

  describe "deleting a node" do
    test "from the danger zone, through its dialog, back to the list", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))

      lv |> element("#delete-node-button") |> render_click()
      assert_patch(lv, node_path(scope, node, "/settings/delete"))
      assert has_element?(lv, "#delete-node-dialog", "Delete build-01?")

      {:ok, list, html} =
        lv
        |> element("#delete-node-confirm")
        |> render_click()
        |> follow_redirect(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes")

      assert html =~ "build-01 is deleted."
      refute has_element?(list, "#node-#{node.public_id}")
      assert Nodes.list_nodes(scope) == []
      assert Repo.get!(Node, node.id).deleted_at
    end

    test "a member is refused the dialog's path, and its event", %{scope: scope} do
      node = node_fixture(scope)
      conn = member_conn(scope)

      {:ok, lv, html} =
        live(conn, node_path(scope, node, "/settings/delete")) |> follow_redirect(conn)

      assert html =~ "Only owners and admins delete nodes."
      refute has_element?(lv, "#delete-node-dialog")

      render_hook(lv, "delete", %{})
      assert render(lv) =~ "Only owners and admins delete nodes."
      assert Repo.get!(Node, node.id).deleted_at == nil
    end

    test "a node deleted since the page opened is gone", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings/delete"))
      {:ok, _} = Nodes.delete_node(scope, node)

      {:ok, _list, html} =
        lv
        |> element("#delete-node-confirm")
        |> render_click()
        |> follow_redirect(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes")

      assert html =~ "This node is gone: it was deleted."
    end
  end
end
