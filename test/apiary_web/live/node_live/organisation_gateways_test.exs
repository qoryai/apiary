defmodule ApiaryWeb.NodeLive.OrganisationGatewaysTest do
  # The organisation's gateways in the console: offered only where an organisation may have
  # more than one workspace; the list, New gateway, a gateway's page and its tabs; the
  # workspace's Nodes list and a node's choice with the organisation's gateways; a gateway
  # of another organisation named as a node uses it; and the edition's words for them.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, EditionStubs, Gateways, Nodes, Repo}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.NodeComponents

  setup :register_and_log_in_user

  defp many_workspaces(_context) do
    Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    :ok
  end

  defp gateways_path(scope, rest \\ ""), do: ~p"/#{scope.organisation}/gateways" <> rest

  defp gateway_path(scope, gateway, rest \\ ""),
    do: ~p"/#{scope.organisation}/gateways/#{gateway}" <> rest

  defp nodes_path(scope, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes" <> rest

  defp node_path(scope, node, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}" <> rest

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  describe "with one workspace an organisation" do
    test "has no Gateways page, no sidebar entry and no New gateway", %{conn: conn, scope: scope} do
      assert_error_sent(:not_found, fn -> get(conn, gateways_path(scope)) end)
      assert_error_sent(:not_found, fn -> get(conn, gateways_path(scope, "/new")) end)

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}")
      refute has_element?(lv, "#nav-gateways")
      refute has_element?(lv, "#new-menu-gateway")
    end

    test "a gateway's page at the organisation does not exist", %{conn: conn, scope: scope} do
      gateway = organisation_gateway_fixture(scope)

      assert_error_sent(:not_found, fn -> get(conn, gateway_path(scope, gateway)) end)

      assert_error_sent(:not_found, fn ->
        get(conn, gateway_path(scope, gateway, "/access-key"))
      end)
    end
  end

  describe "Organisation › Gateways" do
    setup :many_workspaces

    test "the sidebar and New lead to it; it says whose nodes can use them", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}")
      assert has_element?(lv, "#nav-gateways", "Gateways")
      assert has_element?(lv, "#new-menu-gateway", "New gateway")

      {:ok, lv, _html} = live(conn, gateways_path(scope))
      assert has_element?(lv, "main h1", "Gateways")

      assert has_element?(
               lv,
               "#gateways-intro",
               "Nodes in any workspace of #{scope.organisation.name} can use the gateways added here. A workspace can also add gateways that only its nodes use."
             )

      assert has_element?(
               lv,
               "#gateways-empty",
               "Add one so the nodes in #{scope.organisation.name}'s workspaces can send runs through it."
             )
    end

    test "lists each with its URL, Default and whether it is connected", %{
      conn: conn,
      scope: scope
    } do
      first = organisation_gateway_fixture(scope, name: "edge-1", url: "https://edge-1.example")
      second = organisation_gateway_fixture(scope, name: "edge-2")
      node_key_fixture(scope, first)

      {:ok, lv, _html} = live(conn, gateways_path(scope))

      assert has_element?(lv, "#gateway-#{first.public_id}", "https://edge-1.example")
      assert has_element?(lv, "#gateway-#{first.public_id}-default", "Default")
      refute has_element?(lv, "#gateway-#{second.public_id}-default")
      assert has_element?(lv, "#gateway-#{first.public_id}-connected", "Yes")
      assert has_element?(lv, "#gateway-#{second.public_id}-connected", "No")
    end

    test "an owner adds one on its own page, and lands on its Access key tab", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, gateways_path(scope, "/new"))

      assert has_element?(
               lv,
               "#new-gateway",
               "An address that runs of nodes and node pools in #{scope.organisation.name}'s workspaces go through, when they choose it."
             )

      {:ok, _tab, html} =
        lv
        |> form("#new-gateway-form", node: %{name: "edge-1", url: "https://edge.example"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "edge-1 is added."

      assert [%Node{workspace_id: nil, default_gateway: true}] =
               Nodes.list_organisation_gateways(scope)
    end

    test "a member reads the list, without New gateway, and the form's path refuses them", %{
      scope: scope
    } do
      organisation_gateway_fixture(scope, name: "edge-1")
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, gateways_path(scope))
      assert has_element?(lv, "#gateways", "edge-1")
      refute has_element?(lv, "#new-organisation-gateway")

      assert {:error, {:live_redirect, _}} = live(conn, gateways_path(scope, "/new"))
    end
  end

  describe "an organisation's gateway's page" do
    setup :many_workspaces

    test "says whose nodes can use it, who uses it now, and that it is the default", %{
      conn: conn,
      scope: scope
    } do
      gateway = organisation_gateway_fixture(scope, name: "edge-1")

      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway))
      assert has_element?(lv, "#breadcrumb", "Gateways")

      assert has_element?(
               lv,
               "#gateway-who-can-use",
               "Nodes in any workspace of #{scope.organisation.name} can use it."
             )

      assert has_element?(lv, "#gateway-using", "No node uses it now.")

      assert has_element?(
               lv,
               "#gateway-default",
               "The default gateway for workspaces in #{scope.organisation.name} that don't set one."
             )

      node_fixture(scope)
      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway))

      assert has_element?(
               lv,
               "#gateway-using",
               "Nodes in #{scope.organisation.name} › #{scope.workspace.name} use it now."
             )
    end

    test "names only the workspaces the reader reaches, and counts the rest", %{scope: scope} do
      gateway = organisation_gateway_fixture(scope)
      node_fixture(scope)
      other = workspace_fixture(scope.organisation, "Build")
      node_fixture(workspace_scope(scope.user, other))

      # A member reaches the workspace they were invited to, not the other.
      Edition.put_test_stub(EditionStubs.MembersReachNamed)
      EditionStubs.MembersReachNamed.put([scope.workspace.id])
      conn = member_conn(scope)
      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway))

      assert has_element?(
               lv,
               "#gateway-using",
               "Nodes in #{scope.organisation.name} › #{scope.workspace.name} and 1 more workspace use it now."
             )

      # The owner reaches both.
      {:ok, lv, _html} = live(log_in_user(build_conn(), scope.user), gateway_path(scope, gateway))

      assert has_element?(
               lv,
               "#gateway-using",
               "Nodes in #{scope.organisation.name} › Build, #{scope.organisation.name} › #{scope.workspace.name} use it now."
             )
    end

    test "its Settings rename it; its deletion is confirmed in place, refused while in use", %{
      conn: conn,
      scope: scope
    } do
      gateway = organisation_gateway_fixture(scope, name: "edge-1")
      other = workspace_fixture(scope.organisation, "Build")
      node_fixture(workspace_scope(scope.user, other), name: "build-01")

      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway, "/settings"))

      html = lv |> form("#node-form", node: %{name: "edge-2"}) |> render_submit()
      assert html =~ "edge-2 is saved."

      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway, "/settings/delete"))

      assert has_element?(
               lv,
               "#node-danger",
               "It leaves #{scope.organisation.name}'s gateways, its access keys are revoked and its name is free again."
             )

      assert has_element?(
               lv,
               "#node-danger",
               "edge-2 leaves #{scope.organisation.name}'s gateways at once"
             )

      lv |> form("#delete-node-form") |> render_submit()
      assert has_element?(lv, "#delete-node-refused", "build-01")
      assert Repo.get!(Node, gateway.id).deleted_at == nil
    end

    test "a refusal names the nodes of workspaces the reader reaches, and counts the rest",
         %{scope: scope} do
      gateway = organisation_gateway_fixture(scope, name: "edge-1")
      node_fixture(scope, name: "build-here")
      other = workspace_fixture(scope.organisation, "Build")
      node_fixture(workspace_scope(scope.user, other), name: "build-there")

      words =
        NodeComponents.in_use_words(
          scope,
          Gateways.delete_blockers(gateway),
          MapSet.new([scope.workspace.id])
        )

      assert words =~ "build-here and 1 more"

      words = NodeComponents.in_use_words(scope, Gateways.delete_blockers(gateway), MapSet.new())

      assert words =~
               "Nodes use this gateway: 2 nodes in workspaces you don't have access to."
    end

    test "deleted, it leads back to the organisation's Gateways", %{conn: conn, scope: scope} do
      gateway = organisation_gateway_fixture(scope, name: "edge-1")

      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway, "/settings/delete"))

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> form("#delete-node-form") |> render_submit()

      assert to == gateways_path(scope)
      assert Repo.get!(Node, gateway.id).deleted_at
    end

    test "its Access key tab makes a code", %{conn: conn, scope: scope} do
      gateway = organisation_gateway_fixture(scope, name: "edge-1")

      {:ok, lv, _html} = live(conn, gateway_path(scope, gateway, "/access-key"))
      assert has_element?(lv, "#breadcrumb", "Gateways")
      assert has_element?(lv, ~s{#node-tabs-access_key[aria-current="page"]})
    end
  end

  describe "a workspace's Nodes" do
    setup :many_workspaces

    test "lists the organisation's gateways, Set for the organisation, linked to their page", %{
      conn: conn,
      scope: scope
    } do
      gateway = organisation_gateway_fixture(scope, name: "edge-1")
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(conn, nodes_path(scope))

      assert has_element?(
               lv,
               "#node-#{gateway.public_id}-level",
               "Set for #{scope.organisation.name}"
             )

      assert has_element?(lv, "#node-#{gateway.public_id}-default", "Default")

      assert has_element?(
               lv,
               ~s{#node-#{gateway.public_id} a[href="#{gateway_path(scope, gateway)}"]}
             )

      refute has_element?(lv, "#node-#{node.public_id}-level")
    end

    test "a node's choice groups the gateways by level, and its hint names the organisation", %{
      conn: conn,
      scope: scope
    } do
      organisation_gateway_fixture(scope, name: "edge-org")
      gateway_fixture(scope, name: "edge-here")

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      assert has_element?(lv, ~s{#new-node-form optgroup[label="This workspace"]}, "edge-here")

      assert has_element?(
               lv,
               ~s{#new-node-form optgroup[label="#{scope.organisation.name}"]},
               "edge-org"
             )

      assert has_element?(
               lv,
               "#new-node-form",
               "On Default gateway, runs go through edge-org, the default for #{scope.organisation.name}. On Direct, they go through no gateway."
             )
    end
  end

  describe "through the edition" do
    setup %{scope: scope} do
      %{scope: other} = sign_up_fixture(%{organisation_name: "Hive Ops"})
      Edition.put_test_stub(EditionStubs.GatewaysWorded)
      EditionStubs.ServesAcross.put([{other.organisation.id, scope.organisation.id}])
      gateway = organisation_gateway_fixture(other, name: "edge-1", url: "https://edge-1.example")
      %{other: other, gateway: gateway}
    end

    test "the Gateways page and a gateway's say whose nodes can use them in its words", %{
      conn: conn,
      scope: scope
    } do
      own = organisation_gateway_fixture(scope, name: "edge-own")
      {:ok, own} = Nodes.make_default_gateway(scope, own)
      name = scope.organisation.name

      {:ok, lv, _html} = live(conn, gateways_path(scope))
      assert has_element?(lv, "#gateways-intro", "Edition reach intro of #{name}.")

      {:ok, lv, _html} = live(conn, gateway_path(scope, own))
      assert has_element?(lv, "#gateway-who-can-use", "Edition reach who_can_use of #{name}.")
      assert has_element?(lv, "#gateway-default", "Edition reach default_row of #{name}.")
    end

    test "another organisation's gateway is no row of the Nodes list", %{
      conn: conn,
      scope: scope,
      gateway: gateway
    } do
      node_fixture(scope)
      {:ok, lv, _html} = live(conn, nodes_path(scope))
      refute has_element?(lv, "#node-#{gateway.public_id}")
    end

    test "a node that uses it names it of its organisation, unlinked, with its URL", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      assert node.gateway_choice == :default

      {:ok, lv, _html} = live(conn, node_path(scope, node))
      assert has_element?(lv, "#node-about-gateway", "Default gateway")
      assert has_element?(lv, "#node-about-gateway", "edge-1 of Hive Ops")
      assert has_element?(lv, "#node-about-gateway", "https://edge-1.example")
      refute has_element?(lv, "#node-about-gateway a")

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))

      assert render(lv) =~
               "Runs of build-01 go through the gateway"

      assert render(lv) =~ "edge-1 of Hive Ops"
    end

    test "the node's choice groups the other organisation's gateways under its name", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new"))

      assert has_element?(
               lv,
               "#new-node-form",
               "On Default gateway, runs go through edge-1, the default for Hive Ops."
             )
    end

    test "who manages the nodes is said in its words, where a member may not change them", %{
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      conn = member_conn(scope)
      sentence = "Edition managers of #{scope.organisation.name} manage the nodes here."

      {:ok, lv, _html} = live(conn, node_path(scope, node, "/settings"))
      assert has_element?(lv, "#node-settings-readonly", sentence)

      node_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, node_path(scope, node, "/access-key"))
      assert has_element?(lv, "#node-keys-members", sentence)

      Repo.update_all(Node, set: [deleted_at: DateTime.utc_now(), default_gateway: false])
      {:ok, lv, _html} = live(conn, nodes_path(scope))
      assert has_element?(lv, "#nodes-empty", sentence)
    end
  end

  describe "a pool's instance limit, where the edition keeps it" do
    test "the refusal and the hint say who may in the edition's words", %{
      conn: conn,
      scope: scope
    } do
      sentence = "Edition owners alone set a node pool's instance limit."
      pool = pool_fixture(scope, name: "spot-runners", instance_limit: 5)
      Edition.put_test_stub(EditionStubs.NoLimitWorded)

      {:ok, lv, _html} = live(conn, node_path(scope, pool, "/settings"))
      assert has_element?(lv, "#node-form", sentence)

      render_hook(lv, "save", %{"node" => %{"name" => "spot-runners", "instance_limit" => "9"}})
      assert lv |> element("#flash-group") |> render() =~ "Edition owners alone set a node pool"

      {:ok, lv, _html} = live(conn, nodes_path(scope, "/new-pool"))

      html =
        render_hook(lv, "create", %{"node" => %{"name" => "spot-09", "instance_limit" => "3"}})

      assert html =~ "Edition owners alone set a node pool"
    end
  end
end
