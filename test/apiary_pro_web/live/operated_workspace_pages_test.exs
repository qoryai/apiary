defmodule ApiaryProWeb.OperatedWorkspacePagesTest do
  # The pages of an organisation for a person of the operator of one of its workspaces,
  # Ann, with no membership in it: what the organisation owns as a whole is not found for
  # her, and the operated workspace's page opens.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features

  @moduletag with_features: Features.all()

  setup %{conn: conn} do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    %{user: ann} = member_fixture(operator.scope, :member)

    conn =
      conn
      |> log_in_user(ann)
      |> put_session(:last_workspace_id, client.workspace.id)

    %{conn: conn, client: client}
  end

  for {page, path} <- [
        {"People", "/settings/people"},
        {"Secrets", "/settings/secrets"},
        {"Variables", "/settings/variables"},
        {"Integrations", "/settings/integrations"},
        {"Policy", "/policy"}
      ] do
    @path path
    test "the organisation's #{page} page is not found", ctx do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(ctx.conn, "/#{ctx.client.organisation.slug}#{@path}")
      end
    end
  end

  # Each page at the organisation's path is checked against the organisation, not against
  # W1, the workspace the scope keeps from her last visit.
  describe "the organisation's gateways" do
    setup ctx do
      gateway = Apiary.NodesFixtures.organisation_gateway_fixture(ctx.client.owner.scope)
      %{gateway: gateway}
    end

    for {page, rest} <- [
          {"list", ""},
          {"New gateway", "/new"},
          {"gateway's", "/:gateway"},
          {"gateway's settings", "/:gateway/settings"},
          {"gateway's access key", "/:gateway/access-key"}
        ] do
      @rest rest
      test "the #{page} page is not found for her, and opens for the organisation's owner",
           ctx do
        path =
          ~p"/#{ctx.client.organisation}/gateways" <>
            String.replace(@rest, ":gateway", ctx.gateway.public_id)

        assert_raise ApiaryWeb.NotFound, fn -> live(ctx.conn, path) end

        owner = log_in_user(build_conn(), ctx.client.owner.user)
        assert {:ok, _lv, _html} = live(owner, path)
      end
    end
  end

  test "the operated workspace's page opens", ctx do
    assert {:ok, _lv, _html} =
             live(ctx.conn, ~p"/#{ctx.client.organisation}/#{ctx.client.workspace}")
  end
end
