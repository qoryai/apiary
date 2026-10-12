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

  # The words of the line a list narrowed to a node has.
  defp narrowed(view), do: view |> element("#runs-narrowed-what") |> render() |> plain()

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

  describe "the nodes hidden from the reader" do
    # An edition may hide the nodes from a person (the part `nodes`): the record still
    # names a run's node, without a link to a page they cannot open.
    setup %{scope: scope} do
      node = node_fixture(scope, name: "build-01")
      instance_fixture(node, instance_id: "i_1", name: "build-01.example.com")
      run = node_run_fixture(node, "i_1")

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      %{node: node, run: run}
    end

    test "the list names the node with no link, and still keeps its runs", %{
      conn: conn,
      scope: scope,
      node: node,
      run: run
    } do
      view = open(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, "#{row(run)} td.q-rl-c5", "build-01")
      refute has_element?(view, "#{row(run)} td.q-rl-c5 a")
      refute render(view) =~ "/nodes"

      render_hook(view, "viewport", %{"wide" => true})
      render_async(view)
      assert has_element?(view, "#runs-preview-node", "build-01")
      refute has_element?(view, "#runs-preview-node a")
      assert has_element?(view, "#runs-preview-instance", "i_1")

      for value <- [node.public_id, "build-01"] do
        view = open(conn, workspace_path(scope, "/runs?node=#{value}"))
        assert has_element?(view, row(run))

        assert view |> element("#runs-narrowed-what") |> render() |> plain() ==
                 "Showing the runs of build-01 only."

        refute has_element?(view, "a#runs-narrowed-name")
        refute render(view) =~ "/nodes"
      end
    end

    test "the run page names the node with no link", %{conn: conn, scope: scope, run: run} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs/#{run.run_id}"))

      assert has_element?(view, "#run-node", "build-01")
      refute has_element?(view, "#run-node a")
      assert has_element?(view, "#run-instance", "build-01.example.com")
      refute render(view) =~ "/nodes"
    end

    test "shown again, each links to the node's page", %{
      conn: conn,
      scope: scope,
      node: node,
      run: run
    } do
      :ok = Apiary.EditionStubs.HidesNamed.put([])
      node_page = workspace_path(scope, "/nodes/#{node.public_id}")

      view = open(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, ~s(#{row(run)} td.q-rl-c5 a[href="#{node_page}"]), "build-01")

      view = open(conn, workspace_path(scope, "/runs?node=#{node.public_id}"))
      assert has_element?(view, ~s(a#runs-narrowed-name[href="#{node_page}"]), "build-01")

      {:ok, view, _html} = live(conn, workspace_path(scope, "/runs/#{run.run_id}"))
      assert has_element?(view, ~s(#run-node a[href="#{node_page}"]), "build-01")
    end
  end

  describe "a filter's node, with the nodes hidden from the reader" do
    # A reader the nodes are hidden from reads a node's name only as a run names it: the
    # address's node is read among the nodes the runs ran on, and any other is a node that
    # matches nothing, said as the address gave it.
    setup %{scope: scope} do
      node = node_fixture(scope, name: "build-01")
      run = node_run_fixture(node, "i_1")
      idle = node_fixture(scope, name: "never-ran")
      gateway = gateway_fixture(scope, name: "edge-gateway")

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      %{node: node, run: run, idle: idle, gateway: gateway}
    end

    test "a node no run names, by its id, is not named", %{
      conn: conn,
      scope: scope,
      run: run,
      idle: idle,
      gateway: gateway
    } do
      for value <- [idle.public_id, gateway.public_id] do
        view = open(conn, workspace_path(scope, "/runs?node=#{value}"))

        assert narrowed(view) == "Showing the runs of #{value} only."
        refute has_element?(view, row(run))
        html = render(view)
        refute html =~ "never-ran"
        refute html =~ "edge-gateway"
        refute html =~ "/nodes"
      end
    end

    test "a node no run names, by its name, reads as a name nothing has", %{
      conn: conn,
      scope: scope
    } do
      page = fn value ->
        view = open(conn, workspace_path(scope, "/runs?node=#{value}"))
        assert narrowed(view) == "Showing the runs of #{value} only."
        view |> element("#runs-page") |> render() |> String.replace(value, "NAME")
      end

      assert page.("never-ran") == page.("made-up-node")
      assert page.("edge-gateway") == page.("made-up-node")
    end

    test "a node a run names is named, with no link", %{
      conn: conn,
      scope: scope,
      node: node,
      run: run
    } do
      for value <- [node.public_id, "build-01"] do
        view = open(conn, workspace_path(scope, "/runs?node=#{value}"))
        assert has_element?(view, row(run))
        assert narrowed(view) == "Showing the runs of build-01 only."
        refute has_element?(view, "a#runs-narrowed-name")
      end
    end

    test "shown the nodes, any node of the workspace is named and linked", %{
      conn: conn,
      scope: scope,
      idle: idle,
      gateway: gateway
    } do
      :ok = Apiary.EditionStubs.HidesNamed.put([])

      for {node, value} <- [
            {idle, idle.public_id},
            {idle, "never-ran"},
            {gateway, gateway.public_id}
          ] do
        view = open(conn, workspace_path(scope, "/runs?node=#{value}"))
        assert narrowed(view) == "Showing the runs of #{node.name} only."

        assert has_element?(
                 view,
                 ~s(a#runs-narrowed-name[href="#{workspace_path(scope, "/nodes/#{node.public_id}")}"]),
                 node.name
               )
      end
    end
  end

  describe "the nodes hidden while the list is open" do
    setup do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([])
    end

    test "the empty list's way to the nodes goes", %{conn: conn, scope: scope} do
      node_fixture(scope, name: "build-01")
      view = open(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, "#runs-go-to-nodes")

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      send(view.pid, {:membership_changed, :hidden})

      refute has_element?(view, "#runs-go-to-nodes")
      refute render(view) =~ "/nodes"
    end

    test "the empty list's New node goes", %{conn: conn, scope: scope} do
      view = open(conn, workspace_path(scope, "/runs"))
      assert has_element?(view, "#runs-new-node")

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      send(view.pid, {:membership_changed, :hidden})

      refute has_element?(view, "#runs-new-node")
      refute has_element?(view, "#runs-go-to-nodes")
      refute render(view) =~ "/nodes"
    end

    test "the line's node is read again: one no run names is no longer named", %{
      conn: conn,
      scope: scope
    } do
      idle = node_fixture(scope, name: "never-ran")
      view = open(conn, workspace_path(scope, "/runs?node=#{idle.public_id}"))
      assert narrowed(view) == "Showing the runs of never-ran only."

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      send(view.pid, {:membership_changed, :hidden})

      assert narrowed(view) == "Showing the runs of #{idle.public_id} only."
      refute render(view) =~ "never-ran"
    end
  end
end
