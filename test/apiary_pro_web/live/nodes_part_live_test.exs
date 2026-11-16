defmodule ApiaryProWeb.NodesPartLiveTest do
  # The nodes, a part of no feature (`:nodes`): no Features page offers them, and a row of
  # them hides nothing (`ApiaryPro.Features.hidden/1`), so the people of an organisation
  # whose workspace an operator operates open every page of the nodes, the access keys and
  # the gateways while the operator's owners and admins act in the workspaces it operates
  # (`ApiaryPro.Flags.operator_infrastructure?/0`) and features are shown by who asks
  # (`ApiaryPro.Flags.feature_visibility?/0`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Flags
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()

  # An operator and an organisation whose workspace Main it operates; in Main a gateway and
  # a node, with a key, and a gateway of the organisation, all made while the operator's
  # flag was off; a row that would hide the nodes from the organisation; then both
  # switches on.
  setup do
    Flags.put_operator_infrastructure(false)
    Flags.put_feature_visibility(true)
    %{instance_scope: admin} = suite_instance_admin()
    operator = operator_fixture()
    operated = operated_fixture(operator.scope, "Acme")
    scope = operated.owner.scope

    gateway = gateway_fixture(scope, name: "edge-1")
    node = node_fixture(scope, name: "build-01")
    _key = contract_key_fixture(scope, node: node)

    Apiary.Repo.insert!(%Grant{
      organisation_id: operated.organisation.id,
      feature: :nodes,
      granted: false
    })

    ctx = %{
      admin: admin,
      operator: operator,
      operated: operated,
      node: node,
      gateway: gateway,
      organisation_gateway: organisation_gateway_fixture(scope, name: "edge-org")
    }

    Flags.put_operator_infrastructure(true)
    ctx
  end

  defp operated_path(ctx, tail),
    do: "/#{ctx.operated.organisation.slug}/#{ctx.operated.workspace.slug}" <> tail

  # The pages of the nodes, the access keys and the gateways of the organisation.
  defp node_pages(ctx) do
    org = ctx.operated.organisation.slug

    [
      operated_path(ctx, "/machines"),
      operated_path(ctx, "/machines/#{ctx.node.public_id}"),
      operated_path(ctx, "/machines/#{ctx.node.public_id}/access-key"),
      operated_path(ctx, "/machines/#{ctx.gateway.public_id}"),
      "/#{org}/gateways",
      "/#{org}/gateways/#{ctx.organisation_gateway.public_id}",
      "/#{org}/gateways/#{ctx.organisation_gateway.public_id}/access-key"
    ]
  end

  test "a row of the nodes hides no page of them from the organisation's owner", ctx do
    conn = log_in_user(build_conn(), ctx.operated.owner.user)

    for path <- node_pages(ctx),
        do: assert({:ok, _lv, _html} = live(conn, path))
  end

  test "the nodes' box is not on Instance settings › Organisations › Features", ctx do
    conn = log_in_user(build_conn(), ctx.admin.user)

    for organisation <- [ctx.operator.organisation, ctx.operated.organisation] do
      {:ok, lv, _html} = live(conn, "/instance/organisations/#{organisation.id}/features")

      render_async(lv)
      assert has_element?(lv, "#organisation-features-observability")
      refute has_element?(lv, "#organisation-features-nodes")
      refute render(lv) =~ "Machines and access keys"
    end
  end
end
