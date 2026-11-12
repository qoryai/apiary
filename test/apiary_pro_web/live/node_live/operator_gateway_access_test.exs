defmodule ApiaryProWeb.NodeLive.OperatorGatewayAccessTest do
  # Who sees to the organisation-level gateways while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`): at the operator, its owners and admins
  # add, change, mark and delete them and their keys, its members read them, and the
  # client's people find them nowhere; at the client, only the operator's owners and
  # admins add them. A node or pool in the client's workspace may name the operator's
  # gateway, or be on Default and resolve to the operator's default; another operator's
  # client may not name it. The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{AccessKeys, Features, Gateways, Nodes, Repo}
  alias Apiary.Nodes.Node
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    operator_admin = member_fixture(operator.scope, :admin)
    operator_member = member_fixture(operator.scope, :member)
    client_admin = client_member_fixture(client, :admin)
    client_member = client_member_fixture(client, :member)

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      name: name,
      client: client,
      operator_admin: operator_admin,
      operator_member: operator_member,
      client_admin: client_admin,
      client_member: client_member,
      as_operator_admin: scope_in(operator_admin.user, operator.organisation),
      in_client_as_operator_admin:
        scope_in(operator_admin.user, client.organisation, client.workspace)
    }
  end

  defp conn_of(%{user: user}), do: log_in_user(build_conn(), user)

  defp gateways_path(organisation, rest \\ ""), do: "/#{organisation.slug}/gateways" <> rest

  defp gateway_path(organisation, gateway, rest \\ ""),
    do: gateways_path(organisation, "/#{gateway.public_id}" <> rest)

  defp nodes_path(ctx, rest),
    do: "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}/machines" <> rest

  describe "at the operator" do
    test "its admin adds a gateway, renames it, makes another the default and deletes it",
         ctx do
      operator = ctx.operator.organisation
      conn = conn_of(ctx.operator_admin)

      {:ok, lv, _html} = live(conn, gateways_path(operator, "/new"))

      {:ok, _tab, html} =
        lv
        |> form("#new-gateway-form", node: %{name: "edge-1", url: "https://edge-1.example"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "edge-1 is added."
      [first] = Nodes.list_organisation_gateways(ctx.operator.scope)
      assert first.default_gateway

      {:ok, lv, _html} = live(conn, gateway_path(operator, first, "/settings"))

      assert lv |> form("#node-form", node: %{name: "edge-one"}) |> render_submit() =~
               "edge-one is saved."

      second = organisation_gateway_fixture(ctx.operator.scope, name: "edge-2")
      {:ok, lv, _html} = live(conn, gateway_path(operator, second))
      lv |> element("#gateway-make-default") |> render_click()
      assert Repo.get!(Node, second.id).default_gateway
      refute Repo.get!(Node, first.id).default_gateway

      {:ok, lv, _html} = live(conn, gateway_path(operator, first, "/settings/delete"))

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> form("#delete-node-form") |> render_submit()

      assert to == gateways_path(operator)
      assert Repo.get!(Node, first.id).deleted_at
    end

    test "its owners and admins see to a gateway's keys; its members are refused", ctx do
      gateway = organisation_gateway_fixture(ctx.operator.scope, name: "edge-1")

      for scope <- [ctx.operator.scope, ctx.as_operator_admin] do
        assert {:ok, _code, _secret} = AccessKeys.create_enrolment_code(scope, gateway, %{})
      end

      member = scope_in(ctx.operator_member.user, ctx.operator.organisation)

      assert AccessKeys.create_enrolment_code(member, gateway, %{}) == {:error, :forbidden}

      {:ok, lv, _html} =
        live(
          conn_of(ctx.operator_admin),
          gateway_path(ctx.operator.organisation, gateway, "/access-key")
        )

      assert has_element?(lv, ~s{#node-tabs-access_key[aria-current="page"]})
    end

    test "its members read the list, without New gateway", ctx do
      organisation_gateway_fixture(ctx.operator.scope, name: "edge-1")
      conn = conn_of(ctx.operator_member)

      {:ok, lv, _html} = live(conn, gateways_path(ctx.operator.organisation))
      assert has_element?(lv, "#gateways", "edge-1")
      refute has_element?(lv, "#new-organisation-gateway")

      assert {:error, {:live_redirect, _}} =
               live(conn, gateways_path(ctx.operator.organisation, "/new"))
    end

    test "the client's people find neither the list nor a gateway's page", ctx do
      gateway = organisation_gateway_fixture(ctx.operator.scope, name: "edge-1")

      for person <- [ctx.client.owner, ctx.client_admin, ctx.client_member] do
        conn = conn_of(person)

        for path <- [
              gateways_path(ctx.operator.organisation),
              gateway_path(ctx.operator.organisation, gateway),
              gateway_path(ctx.operator.organisation, gateway, "/settings")
            ] do
          assert html_response(get(conn, path), 404)
        end
      end
    end
  end

  describe "at the client" do
    test "the operator's owners and admins add its gateways; its own people read them", ctx do
      client = ctx.client.organisation

      for {person, name} <- [{ctx.operator, "edge-o"}, {ctx.operator_admin, "edge-a"}] do
        conn = conn_of(person)
        {:ok, lv, _html} = live(conn, gateways_path(client, "/new"))

        {:ok, _tab, html} =
          lv
          |> form("#new-gateway-form", node: %{name: name, url: "https://#{name}.example"})
          |> render_submit()
          |> follow_redirect(conn)

        assert html =~ "#{name} is added."
      end

      for person <- [ctx.client.owner, ctx.client_admin, ctx.client_member] do
        {:ok, lv, _html} = live(conn_of(person), gateways_path(client))
        assert has_element?(lv, "#gateways", "edge-o")
        refute has_element?(lv, "#new-organisation-gateway")
      end

      for scope <- [ctx.client.owner.scope, ctx.client_admin.scope] do
        assert Nodes.create_organisation_gateway(scope, %{
                 name: "sneaky",
                 url: "https://sneaky.example"
               }) == {:error, :not_found}
      end
    end
  end

  describe "a node in the client's workspace" do
    setup ctx do
      gateway =
        organisation_gateway_fixture(ctx.operator.scope,
          name: "edge-1",
          url: "https://edge-1.example"
        )

      %{gateway: gateway}
    end

    test "on Default resolves to the operator's default", ctx do
      assert Gateways.default_gateway_for(ctx.client.workspace).id == ctx.gateway.id

      assert {:ok, %Node{gateway_choice: :default} = node} =
               Nodes.create_node(ctx.in_client_as_operator_admin, %{
                 kind: "node",
                 name: "build-01"
               })

      assert Gateways.chosen(node).id == ctx.gateway.id

      assert {:ok, %Node{gateway_choice: :default} = pool} =
               Nodes.create_node(ctx.client.scope, %{
                 kind: "pool",
                 name: "spot-01",
                 gateway_choice: "default"
               })

      assert Gateways.chosen(pool).id == ctx.gateway.id
    end

    test "names the operator's gateway", ctx do
      assert {:ok, %Node{gateway_choice: :named} = node} =
               Nodes.create_node(ctx.in_client_as_operator_admin, %{
                 kind: "node",
                 name: "build-01",
                 gateway_choice: "named",
                 gateway_id: ctx.gateway.id
               })

      assert Gateways.chosen(node).id == ctx.gateway.id
    end

    test "is offered the operator's gateway, and Default names it of the operator", ctx do
      {:ok, lv, _html} = live(conn_of(ctx.operator), nodes_path(ctx, "/new"))

      assert has_element?(lv, ~s{#new-node-form option[value="#{ctx.gateway.id}"]}, "edge-1")

      assert has_element?(
               lv,
               "#new-node-form",
               "On Default gateway, runs go through edge-1, the default for #{ctx.name}."
             )
    end

    test "with the flag off, finds no default and may not name it", ctx do
      Flags.put_operator_infrastructure(false)
      scope = ctx.client.owner.scope

      assert Gateways.default_gateway_for(ctx.client.workspace) == nil

      assert {:error, changeset} =
               Nodes.create_node(scope, %{
                 kind: "node",
                 name: "build-01",
                 gateway_choice: "named",
                 gateway_id: ctx.gateway.id
               })

      assert "is not a gateway this machine may use" in Apiary.DataCase.errors_on(changeset).gateway_id

      assert {:error, changeset} =
               Nodes.create_node(scope, %{
                 kind: "node",
                 name: "build-02",
                 gateway_choice: "default"
               })

      assert "has no default gateway" in Apiary.DataCase.errors_on(changeset).gateway_choice
    end

    test "of another operator's client may not name it", ctx do
      other = operator_fixture()
      other_client = client_fixture(other.scope)

      assert {:error, changeset} =
               Nodes.create_node(other_client.scope, %{
                 kind: "node",
                 name: "build-01",
                 gateway_choice: "named",
                 gateway_id: ctx.gateway.id
               })

      assert "is not a gateway this machine may use" in Apiary.DataCase.errors_on(changeset).gateway_id
      refute Gateways.default_gateway_for(other_client.workspace)
    end
  end
end
