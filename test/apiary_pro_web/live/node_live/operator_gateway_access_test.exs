defmodule ApiaryProWeb.NodeLive.OperatorGatewayAccessTest do
  # Who sees to the organisation-level gateways while the operator's owners and admins act
  # in the workspaces it operates (`ApiaryPro.Flags.operator_infrastructure?/0`): at the
  # operator, its owners and admins add, change, mark and delete them and their keys, and
  # its members read them; at an organisation whose workspace the operator operates, its
  # owners and admins add them, its members read them, and the operator's people, who
  # reach only the workspace the operator operates, find them nowhere. The flag is set for
  # this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{AccessKeys, Features, Nodes, Repo}
  alias Apiary.Nodes.Node
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)

    operator =
      operator_fixture(%{organisation_name: "Hive Ops #{System.unique_integer([:positive])}"})

    operated = operated_fixture(operator.scope, "Acme")
    operator_admin = member_fixture(operator.scope, :admin)
    operator_member = member_fixture(operator.scope, :member)
    organisation_admin = organisation_member_fixture(operated, :admin)
    organisation_member = organisation_member_fixture(operated, :member)

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      operated: operated,
      operator_admin: operator_admin,
      operator_member: operator_member,
      organisation_admin: organisation_admin,
      organisation_member: organisation_member,
      as_operator_admin: scope_in(operator_admin.user, operator.organisation),
      in_main_as_operator_admin:
        scope_in(operator_admin.user, operated.organisation, operated.workspace)
    }
  end

  defp conn_of(%{user: user}), do: log_in_user(build_conn(), user)

  defp gateways_path(organisation, rest \\ ""), do: "/#{organisation.slug}/gateways" <> rest

  defp gateway_path(organisation, gateway, rest \\ ""),
    do: gateways_path(organisation, "/#{gateway.public_id}" <> rest)

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
  end

  describe "at an organisation whose workspace the operator operates" do
    test "its owners and admins add its gateways, its members read them, and the operator's people find none",
         ctx do
      organisation = ctx.operated.organisation

      for {person, name} <- [
            {ctx.operated.owner, "edge-o"},
            {ctx.organisation_admin, "edge-a"}
          ] do
        conn = conn_of(person)
        {:ok, lv, _html} = live(conn, gateways_path(organisation, "/new"))

        {:ok, _tab, html} =
          lv
          |> form("#new-gateway-form", node: %{name: name, url: "https://#{name}.example"})
          |> render_submit()
          |> follow_redirect(conn)

        assert html =~ "#{name} is added."
      end

      {:ok, lv, _html} = live(conn_of(ctx.organisation_member), gateways_path(organisation))
      assert has_element?(lv, "#gateways", "edge-o")
      refute has_element?(lv, "#new-organisation-gateway")

      for scope <- [ctx.operated.scope, ctx.in_main_as_operator_admin] do
        assert Nodes.create_organisation_gateway(scope, %{
                 name: "sneaky",
                 url: "https://sneaky.example"
               }) == {:error, :not_found}
      end
    end
  end
end
