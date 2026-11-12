defmodule ApiaryProWeb.NodeLive.OperatorGatewaysTest do
  # What the pages of gateways and nodes say while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`): an operator's Gateways page and a
  # gateway's page say that its clients' nodes can use them, with their number, and its
  # empty Gateways page says the core's body; a client's Gateways page says that its
  # nodes can use the operator's gateways, which the operator's owners and admins manage
  # and add; a client's Nodes pages, and a refusal of a node or key action in a client,
  # say that the operator's owners and admins manage its nodes, and a client's
  # node names the operator's gateway as the operator's, with a link for the operator's
  # people and none for the client's, who may not open its page. With the flag
  # off, and for an operator without clients, the core's words. The flag is set for this
  # process.
  use ApiaryWeb.ConnCase, async: true

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  # The operator and its client, a node of the client's with a key, made by the client's
  # owner, and a member of the client, made while the flag was off; then the flag on.
  setup do
    Flags.put_operator_infrastructure(false)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    client_member = client_member_fixture(client, :member)
    node = node_fixture(client.owner.scope, name: "build-01")
    node_key_fixture(client.owner.scope, node)

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      name: name,
      client: client,
      client_member: client_member,
      node: node,
      managed:
        "Owners and admins of #{name}, its operator, manage the machines, pools and access keys here."
    }
  end

  defp operator_conn(ctx), do: log_in_user(build_conn(), ctx.operator.user)

  defp gateways_path(ctx, rest \\ ""), do: "/#{ctx.operator.organisation.slug}/gateways" <> rest

  defp nodes_path(ctx, rest \\ ""),
    do: "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}/machines" <> rest

  defp client_gateways_path(ctx), do: "/#{ctx.client.organisation.slug}/gateways"

  defp text(lv, selector),
    do:
      lv
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  defp core_empty(name),
    do: "Add one so the machines and pools in #{name}'s workspaces can send runs through it."

  defp intro(name, clients),
    do:
      "Machines and pools in any workspace of #{name} and of its #{clients} can use the gateways added here. A workspace can also add gateways that only its machines and pools use."

  describe "an operator's Gateways, while the operator owns its clients" do
    test "the list says its clients' nodes can use them, with their number", ctx do
      {:ok, lv, _html} = live(operator_conn(ctx), gateways_path(ctx))
      assert has_element?(lv, "#gateways-intro", intro(ctx.name, "1 client"))

      client_fixture(ctx.operator.scope, "Beta")
      client_fixture(ctx.operator.scope, "Gamma")

      {:ok, lv, _html} = live(operator_conn(ctx), gateways_path(ctx))
      assert has_element?(lv, "#gateways-intro", intro(ctx.name, "3 clients"))
    end

    test "a gateway's page says who can use it, and that it is the default for its clients",
         ctx do
      gateway = organisation_gateway_fixture(ctx.operator.scope, name: "edge-1")
      assert gateway.default_gateway

      {:ok, lv, _html} = live(operator_conn(ctx), gateways_path(ctx, "/#{gateway.public_id}"))

      assert has_element?(
               lv,
               "#gateway-who-can-use",
               "Machines and pools in any workspace of #{ctx.name} and of its 1 client can use it."
             )

      assert has_element?(
               lv,
               "#gateway-default",
               "The default gateway for workspaces in #{ctx.name}, and in its clients where neither the workspace nor the client sets one."
             )
    end

    test "the empty list says the core's body, with its clients' intro above it", ctx do
      {:ok, lv, _html} = live(operator_conn(ctx), gateways_path(ctx))
      assert has_element?(lv, "#gateways-intro", intro(ctx.name, "1 client"))
      assert has_element?(lv, "#gateways-empty", "No gateways yet")
      assert text(lv, "#gateways-empty p") == core_empty(ctx.name)
    end

    test "an operator without clients is said in the core's words" do
      lone = operator_fixture()
      name = lone.organisation.name
      gateway = organisation_gateway_fixture(lone.scope, name: "edge-1")
      conn = log_in_user(build_conn(), lone.user)

      {:ok, lv, _html} = live(conn, "/#{lone.organisation.slug}/gateways")

      assert has_element?(
               lv,
               "#gateways-intro",
               "Machines and pools in any workspace of #{name} can use the gateways added here. A workspace can also add gateways that only its machines and pools use."
             )

      {:ok, lv, _html} = live(conn, "/#{lone.organisation.slug}/gateways/#{gateway.public_id}")

      assert has_element?(
               lv,
               "#gateway-who-can-use",
               "Machines and pools in any workspace of #{name} can use it."
             )

      assert has_element?(
               lv,
               "#gateway-default",
               "The default gateway for workspaces in #{name} that don't set one."
             )
    end
  end

  describe "an operator's Gateways, with the flag off" do
    setup do: Flags.put_operator_infrastructure(false)

    test "the list and a gateway's page say it in the core's words", ctx do
      gateway = organisation_gateway_fixture(ctx.operator.scope, name: "edge-1")

      {:ok, lv, _html} = live(operator_conn(ctx), gateways_path(ctx))

      assert has_element?(
               lv,
               "#gateways-intro",
               "Machines and pools in any workspace of #{ctx.name} can use the gateways added here. A workspace can also add gateways that only its machines and pools use."
             )

      {:ok, lv, _html} = live(operator_conn(ctx), gateways_path(ctx, "/#{gateway.public_id}"))

      assert has_element?(
               lv,
               "#gateway-who-can-use",
               "Machines and pools in any workspace of #{ctx.name} can use it."
             )

      assert has_element?(
               lv,
               "#gateway-default",
               "The default gateway for workspaces in #{ctx.name} that don't set one."
             )
    end
  end

  describe "a client's Gateways" do
    # Acme has no gateways at the organisation level: its Gateways page, read by the
    # client's owner and by the operator's, says under the heading whose gateways its
    # nodes can use, and in the empty state's body who adds them.
    defp client_gateways(ctx) do
      for user <- [ctx.client.owner.user, ctx.operator.user] do
        {:ok, lv, _html} = live(log_in_user(build_conn(), user), client_gateways_path(ctx))
        assert has_element?(lv, "#gateways-empty", "No gateways yet")
        {text(lv, "#gateways-intro"), text(lv, "#gateways-empty p")}
      end
    end

    test "while the operator owns its clients, name the operator's gateways and people",
         ctx do
      intro =
        "Machines and pools in any workspace of Acme can use the gateways listed here and the gateways of #{ctx.name}. Owners and admins of #{ctx.name}, its operator, manage them."

      empty =
        "Machines and pools in Acme's workspaces can use the gateways of #{ctx.name}, its operator, whose owners and admins also add gateways here."

      assert client_gateways(ctx) == List.duplicate({intro, empty}, 2)
    end

    test "with the flag off, say the core's words", ctx do
      Flags.put_operator_infrastructure(false)

      intro =
        "Machines and pools in any workspace of Acme can use the gateways added here. A workspace can also add gateways that only its machines and pools use."

      assert client_gateways(ctx) == List.duplicate({intro, core_empty("Acme")}, 2)
    end
  end

  describe "a client's Nodes, while the operator owns its clients" do
    test "New node is refused to its people in the operator's words", ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)

      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live(conn, nodes_path(ctx, "/new"))

      assert flash == ctx.managed
    end

    test "the empty list says who manages the nodes", ctx do
      {:ok, _} = Apiary.Nodes.delete_node(ctx.client.scope, ctx.node)
      conn = log_in_user(build_conn(), ctx.client_member.user)

      {:ok, lv, _html} = live(conn, nodes_path(ctx))
      assert has_element?(lv, "#nodes-empty", ctx.managed)
    end

    test "a node's Settings and its Access key tab say who manages it", ctx do
      for user <- [ctx.client.owner.user, ctx.client_member.user] do
        conn = log_in_user(build_conn(), user)

        {:ok, lv, _html} = live(conn, nodes_path(ctx, "/#{ctx.node.public_id}/settings"))
        assert has_element?(lv, "#node-settings-readonly", ctx.managed)

        {:ok, lv, _html} = live(conn, nodes_path(ctx, "/#{ctx.node.public_id}/access-key"))
        assert has_element?(lv, "#node-keys-members", ctx.managed)
      end
    end

    test "the operator's owner, who manages them, is told nothing of it", ctx do
      {:ok, lv, _html} =
        live(operator_conn(ctx), nodes_path(ctx, "/#{ctx.node.public_id}/settings"))

      refute has_element?(lv, "#node-settings-readonly")
      refute render(lv) =~ ctx.managed
    end
  end

  describe "a refused node or key action in a client, while the operator owns its clients" do
    # The client's gateway at the organisation, which the operator's owner adds.
    setup ctx do
      gateway = organisation_gateway_fixture(ctx.client.scope, name: "edge-c")
      %{client_gateway: gateway}
    end

    test "deleting a gateway or a node is refused in the operator's words", ctx do
      conn = log_in_user(build_conn(), ctx.client.owner.user)

      for path <- [
            "/#{ctx.client.organisation.slug}/gateways/#{ctx.client_gateway.public_id}/settings/delete",
            nodes_path(ctx, "/#{ctx.node.public_id}/settings/delete")
          ] do
        assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} = live(conn, path)
        assert flash == ctx.managed
      end
    end

    test "getting the command to connect a node is refused in the operator's words", ctx do
      conn = log_in_user(build_conn(), ctx.client_member.user)

      {:ok, lv, _html} =
        live(conn, "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}")

      render_hook(lv, "get_command", %{})
      assert render(lv) =~ ctx.managed
    end
  end

  describe "a client's node through the operator's gateway" do
    # The operator's gateway edge-1, the client's default; a node of the client's that names
    # it and one on Default, which the operator's owner makes in the client; and an admin
    # of the operator.
    setup ctx do
      gateway =
        organisation_gateway_fixture(ctx.operator.scope,
          name: "edge-1",
          url: "https://edge-1.example"
        )

      in_client =
        scope_in(ctx.operator.user, ctx.client.organisation, ctx.client.workspace)

      named =
        node_fixture(in_client,
          name: "build-02",
          gateway_choice: "named",
          gateway_id: gateway.id
        )

      on_default = node_fixture(in_client, name: "build-03", gateway_choice: "default")
      operator_admin = Apiary.OrganisationsFixtures.member_fixture(ctx.operator.scope, :admin)

      %{gateway: gateway, nodes: [named, on_default], operator_admin: operator_admin}
    end

    defp operator_gateway_link(ctx),
      do: ~s{a[href="/#{ctx.operator.organisation.slug}/gateways/#{ctx.gateway.public_id}"]}

    # A node's About and its Access key tab, as `user` opens them: the gateway named as the
    # operator's, with its URL, and on Default said so; then whether each links the
    # gateway's page.
    defp gateway_links(ctx, user) do
      conn = log_in_user(build_conn(), user)

      for node <- ctx.nodes do
        {:ok, about, _html} = live(conn, nodes_path(ctx, "/#{node.public_id}"))
        {:ok, tab, _html} = live(conn, nodes_path(ctx, "/#{node.public_id}/access-key"))

        for {lv, id} <- [{about, "#node-about-gateway"}, {tab, "#node-gateway"}] do
          assert has_element?(lv, id, "edge-1 of #{ctx.name}")
          assert has_element?(lv, id, "https://edge-1.example")
        end

        if node.gateway_choice == :default,
          do: assert(has_element?(about, "#node-about-gateway", "Default gateway"))

        [
          has_element?(about, "#node-about-gateway " <> operator_gateway_link(ctx)),
          has_element?(tab, "#node-gateway " <> operator_gateway_link(ctx))
        ]
      end
      |> List.flatten()
    end

    test "its member reads the gateway as the operator's, with its URL and no link", ctx do
      assert gateway_links(ctx, ctx.client_member.user) == [false, false, false, false]
    end

    test "the operator's owner and admin read it as the operator's, with its URL and a link",
         ctx do
      for user <- [ctx.operator.user, ctx.operator_admin.user] do
        assert gateway_links(ctx, user) == [true, true, true, true]
      end
    end
  end

  describe "a client's Nodes, with the flag off" do
    setup do: Flags.put_operator_infrastructure(false)

    test "its member is told in the core's words", ctx do
      conn = log_in_user(build_conn(), ctx.client_member.user)

      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live(conn, nodes_path(ctx, "/new"))

      assert flash == "Only owners and admins add machines."

      {:ok, lv, _html} = live(conn, nodes_path(ctx, "/#{ctx.node.public_id}/settings"))

      assert has_element?(
               lv,
               "#node-settings-readonly",
               "Only owners and admins change these settings."
             )

      {:ok, lv, _html} = live(conn, nodes_path(ctx, "/#{ctx.node.public_id}/access-key"))

      assert has_element?(
               lv,
               "#node-keys-members",
               "Only owners and admins manage a machine's keys."
             )

      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live(conn, nodes_path(ctx, "/#{ctx.node.public_id}/settings/delete"))

      assert flash == "Only owners and admins delete machines."

      {:ok, lv, _html} =
        live(conn, "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}")

      render_hook(lv, "get_command", %{})
      assert render(lv) =~ "Only owners and admins connect a machine."

      {:ok, _} = Apiary.Nodes.delete_node(ctx.client.owner.scope, ctx.node)
      {:ok, lv, _html} = live(conn, nodes_path(ctx))
      assert has_element?(lv, "#nodes-empty", "An owner or admin adds machines.")
      refute render(lv) =~ "its operator"
    end
  end
end
