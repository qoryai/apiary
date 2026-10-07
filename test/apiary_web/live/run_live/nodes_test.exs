defmodule ApiaryWeb.RunLive.NodesTest do
  # The node a run ran on and the instance it ran as, where the record shows a run: the
  # runs list's `node:` filter and Node column, the preview and the run page's details.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Nodes

  setup :register_and_log_in_user

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp row(run), do: "#run-#{run.run_id}"

  # The words of a fragment, a space between any two elements.
  defp plain(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(" .", ".")
    |> String.trim()
  end

  describe "the runs list" do
    test "keeps a node's runs by its id or its name, said as a token", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      other = node_fixture(scope, name: "build-02")
      mine = node_run_fixture(node, "i_1")
      theirs = node_run_fixture(other, "i_2")
      none = run_fixture(scope)

      view = open(conn, workspace_path(scope, "/runs?node=#{node.public_id}"))
      assert has_element?(view, row(mine))
      refute has_element?(view, row(theirs))
      refute has_element?(view, row(none))
      assert has_element?(view, "#runs-token-node", node.public_id)

      view |> form("#runs-query", %{"q" => "node:build-02"}) |> render_submit()
      assert_patch(view, workspace_path(scope, "/runs?node=build-02"))
      render_async(view)
      assert has_element?(view, row(theirs))
      refute has_element?(view, row(mine))
    end

    test "narrowed to a node, the line names it and leads to its page; nothing carries", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      node_run_fixture(node, "i_1")
      node_page = workspace_path(scope, "/nodes/#{node.public_id}")

      for value <- [node.public_id, "build-01"] do
        view = open(conn, workspace_path(scope, "/runs?node=#{value}"))

        assert view |> element("#runs-narrowed-what") |> render() |> plain() ==
                 "Showing the runs of build-01 only."

        assert has_element?(view, ~s(a#runs-narrowed-name[href="#{node_page}"]), "build-01")

        assert has_element?(
                 view,
                 ~s(#runs-narrowed-all[href="#{workspace_path(scope, "/runs")}"])
               )

        # Network access cannot be narrowed to a node: no link, and nothing carries.
        refute has_element?(view, "#runs-narrowed-network")
        refute has_element?(view, "#runs-narrowed-policy")
        assert has_element?(view, ~s(#nav-network[href="#{workspace_path(scope, "/network")}"]))
        assert has_element?(view, ~s(#nav-runs[href="#{workspace_path(scope, "/runs")}"]))
      end

      # With a target too, the line names the target and the node stays a token.
      view = open(conn, workspace_path(scope, "/runs?node=#{node.public_id}&target=acme/shop"))
      assert has_element?(view, "#runs-narrowed-what", "acme/shop")
      assert has_element?(view, "#runs-narrowed-network")
      assert has_element?(view, "#runs-token-node", node.public_id)
    end

    test "a deleted node's runs are found by its id, not its name", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      run = node_run_fixture(node, "i_1")
      {:ok, _} = Nodes.delete_node(scope, node)

      view = open(conn, workspace_path(scope, "/runs?node=#{node.public_id}"))
      assert has_element?(view, row(run))

      view = open(conn, workspace_path(scope, "/runs?node=build-01"))
      refute has_element?(view, row(run))
    end

    test "has a Node column where the workspace has nodes", %{conn: conn, scope: scope} do
      bare = run_fixture(scope)
      view = open(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, row(bare))
      refute has_element?(view, "#runs th.q-rl-c5")

      node = node_fixture(scope, name: "build-01")
      run = node_run_fixture(node, "i_1")
      view = open(conn, workspace_path(scope, "/runs"))

      assert has_element?(view, "#runs th.q-rl-c5", "Node")
      assert has_element?(view, "#{row(run)} td.q-rl-c5 a", "build-01")
      assert has_element?(view, "#{row(bare)} td.q-rl-c5", "n/a")
    end

    test "the preview names the run's node and instance", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      node_run_fixture(node, "i_1")

      view = open(conn, workspace_path(scope, "/runs"))
      render_hook(view, "viewport", %{"wide" => true})
      render_async(view)

      assert has_element?(view, "#runs-preview-node a", "build-01")
      assert has_element?(view, "#runs-preview-instance", "i_1")
    end
  end

  describe "the run page" do
    test "says the node and the instance beside the key, only when set", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      instance_fixture(node, instance_id: "i_1", name: "build-01.example.com")
      run = node_run_fixture(node, "i_1")
      bare = run_fixture(scope)

      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs/#{run.run_id}"))

      assert has_element?(
               view,
               ~s{#run-node a[href="#{workspace_path(scope, "/nodes/#{node.public_id}")}"]},
               "build-01"
             )

      assert has_element?(view, "#run-instance", "build-01.example.com")
      assert has_element?(view, "#run-instance", "i_1")

      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs/#{bare.run_id}"))
      refute has_element?(view, "#run-node")
      refute has_element?(view, "#run-instance")
    end

    test "a deleted node is named, and not linked", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      run = node_run_fixture(node, "i_1")
      {:ok, _} = Nodes.delete_node(scope, node)

      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs/#{run.run_id}"))

      assert has_element?(view, "#run-node", "build-01 (deleted)")
      refute has_element?(view, "#run-node a")
      assert has_element?(view, "#run-instance", "i_1")
    end
  end
end
