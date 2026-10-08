defmodule ApiaryWeb.NodeLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Nodes
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.Run

  defp node_path(scope, node, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}" <> rest

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  setup :register_and_log_in_user

  describe "Overview" do
    test "names the node, its kind and its maker, under three tabs", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(conn, node_path(scope, node))

      assert has_element?(lv, "h1#node-header-title", "build-01")
      assert has_element?(lv, "#node-public-id", node.public_id)
      assert has_element?(lv, "#node-kind", "Node")
      assert has_element?(lv, "#node-state", "Never seen")
      assert has_element?(lv, "#node-made", scope.user.email)
      assert has_element?(lv, "#breadcrumb", "Nodes")

      assert has_element?(lv, ~s{nav#node-tabs[aria-label="Node"]})
      assert has_element?(lv, ~s{#node-tabs-overview[aria-current="page"]}, "Overview")

      assert has_element?(
               lv,
               ~s{#node-tabs-access_key[href="#{node_path(scope, node, "/access-key")}"]},
               "Access key"
             )

      assert has_element?(lv, "#node-tabs-settings.q-tabs-end", "Settings")
      assert lv |> element("#node-tabs") |> render() |> String.split("<a") |> length() == 4

      # No line sends the reader to a workspace's access keys: there are none.
      refute has_element?(lv, "#not-on-runs")
      refute render(lv) =~ "workspace access key"
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

      render_async(lv)
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

      lv |> element("#node-tabs-settings") |> render_click()
      assert_patch(lv, node_path(scope, node, "/settings"))
      assert has_element?(lv, "#node-form")

      lv |> element("#node-tabs-overview") |> render_click()
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
      assert has_element?(lv, "h1#node-header-title", "build-02")
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

    test "an admin made a member while the page is open reads it, with nothing to change", %{
      scope: scope
    } do
      node = node_fixture(scope)
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      conn = log_in_user(build_conn(), user)
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))
      assert has_element?(lv, "#node-save")

      Repo.update!(Ecto.Changeset.change(membership, level: :member))
      send(lv.pid, {:membership_changed, %{organisation_id: scope.organisation.id}})

      assert has_element?(lv, "#node-settings-readonly")
      assert has_element?(lv, "#node-form input[name='node[name]'][disabled]")
      refute has_element?(lv, "#node-save")
      refute has_element?(lv, "#node-danger")
    end
  end

  describe "deleting a node" do
    test "from the danger zone, through its confirmation in place, back to the list",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))
      refute has_element?(lv, "#delete-node-form")

      lv |> element("#delete-node-button") |> render_click()
      assert_patch(lv, node_path(scope, node, "/settings/delete"))
      refute has_element?(lv, "#delete-node-dialog")
      assert has_element?(lv, "#node-danger #delete-node #delete-node-form", "build-01 leaves")

      assert has_element?(
               lv,
               "#delete-node-form",
               "Its access keys are revoked, and a command not yet run is cancelled."
             )

      # The code is never named: the command not yet run is.
      refute has_element?(lv, "#delete-node-form", "enrolment")
      assert has_element?(lv, "#delete-node-confirming", "Delete build-01?")
      # No field to type: Cancel takes the focus, and the red button is ready.
      assert has_element?(lv, "#delete-node-confirming-cancel[phx-mounted]")
      assert has_element?(lv, "#delete-node-confirm:not([disabled])", "Yes, delete")

      # Cancel folds it.
      lv |> element("#delete-node-confirming-cancel") |> render_click()
      assert_patch(lv, node_path(scope, node, "/settings"))
      refute has_element?(lv, "#delete-node-form")

      lv |> element("#delete-node-button") |> render_click()

      {:ok, list, html} =
        lv
        |> form("#delete-node-form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes")

      assert html =~ "build-01 is deleted."
      refute has_element?(list, "#node-#{node.public_id}")
      assert Nodes.list_nodes(scope) == []
      assert Repo.get!(Node, node.id).deleted_at
    end

    test "a member is refused the confirmation's path, and its event", %{scope: scope} do
      node = node_fixture(scope)
      conn = member_conn(scope)

      {:ok, lv, html} =
        live(conn, node_path(scope, node, "/settings/delete")) |> follow_redirect(conn)

      assert html =~ "Only owners and admins delete nodes."
      refute has_element?(lv, "#delete-node-form")

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
        |> form("#delete-node-form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes")

      assert html =~ "This node is gone: it was deleted."
    end
  end

  describe "instances" do
    setup :register_and_log_in_user

    defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

    defp none_line(lv) do
      lv
      |> element("#node-instances-none")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "a node's running instance, its run, and Clear instance", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      instance_fixture(node, instance_id: "i_1", name: "build-01.example.com")

      run =
        node_run_fixture(node, "i_1", %{about_title: "Fix the build"})

      {:ok, lv, _html} = live(conn, node_path(scope, node))

      assert has_element?(lv, "#node-state", "Running")
      assert has_element?(lv, "#node-instance-name", "build-01.example.com")
      assert has_element?(lv, "#node-instance", "i_1")
      assert has_element?(lv, "#node-instance", "Running since")
      assert has_element?(lv, ~s{#node-instance a[href$="/runs/#{run.run_id}"]})

      assert has_element?(
               lv,
               "#node-instance-claim",
               "An instance is what a runner with this node's key reports itself as"
             )

      refute render(lv) =~ "Once runners use"

      render_async(lv)
      assert has_element?(lv, "#node-runs-table #run-#{run.run_id} .q-rowlink", "Fix the build")

      assert has_element?(lv, ~s{#node-runs-all[href*="node=#{node.public_id}"]})

      lv |> element("#node-instance-clear") |> render_click()
      assert_patch(lv, node_path(scope, node, "/instances/i_1/clear"))
      # The instance's line is the confirmation, in place: no dialog.
      refute has_element?(lv, "#clear-instance-dialog")
      refute has_element?(lv, "#node-instance-clear")
      assert has_element?(lv, "#node-instance #clear-instance", "Clear build-01.example.com?")
      assert has_element?(lv, "#node-instance #clear-instance", "stopped without saying so")

      # Cancel puts the line back.
      lv |> element("#clear-instance-cancel") |> render_click()
      assert_patch(lv, node_path(scope, node))
      refute has_element?(lv, "#clear-instance")
      assert has_element?(lv, "#node-instance-clear")

      lv |> element("#node-instance-clear") |> render_click()
      lv |> element("#clear-instance-confirm", "Yes, clear") |> render_click()
      assert_patch(lv, node_path(scope, node))
      assert render(lv) =~ "build-01.example.com is cleared: its open run is marked lost."
      assert Repo.get!(Run, run.id).state == "lost"
      refute has_element?(lv, "#clear-instance-dialog")
      assert has_element?(lv, "#node-state", "Last seen")
      assert has_element?(lv, "#node-instance", "Last seen")
      refute has_element?(lv, "#node-instance-clear")
    end

    test "a pool's running instances, against its limit, and the starts refused", %{
      conn: conn,
      scope: scope
    } do
      pool = pool_fixture(scope, name: "spot-runners", instance_limit: 10)
      instance_fixture(pool, instance_id: "i_1", name: "spot-1")
      node_run_fixture(pool, "i_1")
      node_run_fixture(pool, "i_2")
      node_run_fixture(pool, "i_3", %{state: "succeeded"})

      Repo.update_all(from(n in Node, where: n.id == ^pool.id),
        set: [instance_limit_refused: 4, instance_limit_refused_at: ago(60)]
      )

      {:ok, lv, _html} = live(conn, node_path(scope, pool))

      assert has_element?(lv, "#node-state", "2 of 10 running")
      assert has_element?(lv, "#node-instances-count", "2 of 10 running")
      assert has_element?(lv, "#node-running tr", "spot-1")
      assert has_element?(lv, "#node-running tr", "i_2")
      refute has_element?(lv, "#node-running tr", "i_3")
      assert has_element?(lv, "#node-refused", "4 starts were refused at the instance limit")

      {:ok, _} = Nodes.update_node(scope, pool, %{instance_limit: ""})
      send(lv.pid, :tick)
      assert has_element?(lv, "#node-state", "2 running")
    end

    test "a pool whose instances were pruned says when its key was last used, not Never seen",
         %{conn: conn, scope: scope} do
      pool = pool_fixture(scope, name: "spot-runners")
      %{access_key: key} = Apiary.AccessKeysFixtures.node_key_fixture(scope, pool)
      instance_fixture(pool, instance_id: "i_1", seen_at: ago(2 * 86_400))
      two_days = ago(2 * 86_400)

      Repo.update_all(from(k in Apiary.AccessKeys.AccessKey, where: k.id == ^key.id),
        set: [last_used_at: two_days]
      )

      assert Nodes.prune_instances() >= 1

      {:ok, lv, _html} = live(conn, node_path(scope, pool))

      assert has_element?(lv, "#node-state", "Last seen")
      refute has_element?(lv, "#node-state", "Never seen")

      # Its instances went a day after they were last seen: none is running.
      assert none_line(lv) ==
               "No instance of this pool is running. An instance shows here while it runs."

      refute has_element?(lv, "#node-instances-idle")

      assert has_element?(
               lv,
               ~s{#node-state-seen[datetime="#{DateTime.to_iso8601(two_days)}"]}
             )

      # A revoked key was seen too.
      {:ok, _} = Apiary.AccessKeys.revoke_access_key(scope, key)
      {:ok, lv, _html} = live(conn, node_path(scope, pool))
      assert has_element?(lv, "#node-state", "Last seen")

      # Running, it says so, whatever its keys' use.
      node_run_fixture(pool, "i_2")
      send(lv.pid, :tick)
      assert has_element?(lv, "#node-state", "1 running")
    end

    test "a node or a pool with no instance and no key used says Never seen", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      pool = pool_fixture(scope, name: "spot-runners")
      Apiary.AccessKeysFixtures.node_key_fixture(scope, pool)

      for target <- [node, pool] do
        {:ok, lv, _html} = live(conn, node_path(scope, target))
        assert has_element?(lv, "#node-state", "Never seen")
      end

      # Never seen: the lines that say none has reported yet, the pool's and the node's.
      {:ok, lv, _html} = live(conn, node_path(scope, pool))

      assert none_line(lv) ==
               "No instance of this pool has reported yet. An instance shows here while it runs."

      {:ok, lv, _html} = live(conn, node_path(scope, node))

      assert none_line(lv) ==
               "No instance of this node has reported yet. It shows here once it runs, running or when it was last seen."
    end

    test "says when a pool's last instance was seen, once none runs", %{conn: conn, scope: scope} do
      pool = pool_fixture(scope)
      instance_fixture(pool, instance_id: "i_1", seen_at: ago(3600))

      {:ok, lv, _html} = live(conn, node_path(scope, pool))

      assert has_element?(lv, "#node-state", "Last seen")
      assert has_element?(lv, "#node-instances-idle", "None is running")
      refute has_element?(lv, "#node-instances-none")
    end

    test "follows the instances as they are seen and as their runs change", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, node_path(scope, node))
      assert has_element?(lv, "#node-state", "Never seen")

      # The page follows the workspace's nodes and its runs; a change is read again.
      subscribers = fn topic -> for {pid, _} <- Registry.lookup(Apiary.PubSub, topic), do: pid end
      assert lv.pid in subscribers.(Nodes.topic(scope.workspace.id))
      assert lv.pid in subscribers.(Apiary.Runs.topic(scope.workspace.id))

      :ok = Nodes.seen(node, %{instance_id: "i_live", name: "build-02.example.com"})
      send(lv.pid, :reload)
      assert has_element?(lv, "#node-state", "Last seen")
      assert has_element?(lv, "#node-instance-name", "build-02.example.com")

      node_run_fixture(node, "i_live")
      send(lv.pid, :tick)
      assert has_element?(lv, "#node-state", "Running")
    end

    test "a pool's instance is cleared from its row's menu", %{conn: conn, scope: scope} do
      pool = pool_fixture(scope)
      run = node_run_fixture(pool, "i_1")

      {:ok, lv, _html} = live(conn, node_path(scope, pool))

      lv |> element("#node-running [id$='-clear']") |> render_click()
      assert_patch(lv, node_path(scope, pool, "/instances/i_1/clear"))
      # Its row is the confirmation, in place of its cells.
      row = "#node-running tr.q-confirming"
      assert has_element?(lv, "#{row} #clear-instance", "Clear i_1?")
      refute has_element?(lv, "#{row} [id$='-menu']")
      lv |> element("#{row} #clear-instance-confirm") |> render_click()
      assert Repo.get!(Run, run.id).state == "lost"
    end

    test "an instance that does not run now confirms its clearing at the top of the instances",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      instance_fixture(node, instance_id: "i_1", name: "build-01.example.com", seen_at: ago(3600))

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/instances/i_1/clear"))
      refute has_element?(lv, "#clear-instance-dialog")
      assert has_element?(lv, "#node-instances #clear-instance", "Clear build-01.example.com?")
      assert has_element?(lv, "#node-instance", "Last seen")

      lv |> element("#clear-instance-confirm") |> render_click()
      assert_patch(lv, node_path(scope, node))
      assert render(lv) =~ "build-01.example.com is cleared."
      refute has_element?(lv, "#clear-instance")
    end

    test "an instance the node does not have has no confirmation", %{conn: conn, scope: scope} do
      node = node_fixture(scope)

      {:ok, _lv, html} =
        live(conn, node_path(scope, node, "/instances/i_none/clear")) |> follow_redirect(conn)

      assert html =~ "This node has no such instance."
    end

    test "a member sees the instances, not Clear instance, and is refused it", %{scope: scope} do
      node = node_fixture(scope)
      run = node_run_fixture(node, "i_1")
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, node_path(scope, node))
      assert has_element?(lv, "#node-state", "Running")
      refute has_element?(lv, "#node-instance-clear")

      {:ok, lv, html} =
        live(conn, node_path(scope, node, "/instances/i_1/clear")) |> follow_redirect(conn)

      assert html =~ "Only owners and admins clear instances."
      refute has_element?(lv, "#clear-instance")

      render_hook(lv, "clear_instance", %{})
      assert render(lv) =~ "Only owners and admins clear instances."
      assert Repo.get!(Run, run.id).state == "pending"
    end
  end
end
