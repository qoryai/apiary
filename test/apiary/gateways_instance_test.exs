defmodule Apiary.GatewaysInstanceTest do
  # The instance level of the gateways (`Apiary.Gateways`): the instance's gateway, with no
  # organisation and no workspace, comes last among a workspace's levels, may serve every
  # workspace, and is the default where no other level has one, while a workspace's or an
  # organisation's first gateway still becomes its default; the instance's pool's
  # choice leads to it. Then what the keys of the instance's pool and gateway reach
  # (`Apiary.Access`). Not async: the instance has one pool and one gateway in use, which
  # two tests at once would make in turn.
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Features, Gateways, Nodes}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    %{scope: scope, other: other, gateway: instance_gateway_fixture()}
  end

  describe "the instance level" do
    test "comes last among a workspace's levels, and is the instance gateway's", ctx do
      assert Gateways.level(ctx.gateway) == :instance
      assert List.last(Gateways.levels(ctx.scope.workspace)) == :instance

      assert Gateways.levels(ctx.scope.workspace) == [
               {:workspace, ctx.scope.workspace.id},
               {:organisation, ctx.scope.organisation.id},
               :instance
             ]
    end

    test "its gateway may serve the workspaces of two organisations", ctx do
      assert Gateways.may_serve?(ctx.gateway, ctx.scope.workspace)
      assert Gateways.may_serve?(ctx.gateway, ctx.other.workspace)

      served = ctx.gateway |> Gateways.serves() |> Enum.map(& &1.id)
      assert ctx.scope.workspace.id in served
      assert ctx.other.workspace.id in served
    end

    test "a deleted instance gateway serves nothing", ctx do
      deleted = %{ctx.gateway | deleted_at: DateTime.utc_now()}
      refute Gateways.may_serve?(deleted, ctx.scope.workspace)
      assert Gateways.serves(deleted) == []
    end

    test "is the default where no other level has one; a workspace's default comes first",
         ctx do
      assert %Node{id: id} = Gateways.default_gateway_for(ctx.scope.workspace)
      assert id == ctx.gateway.id
      assert Gateways.default_at(:instance, nil).id == ctx.gateway.id

      {:ok, own} = Nodes.make_default_gateway(ctx.scope, gateway_fixture(ctx.scope))
      assert Gateways.default_gateway_for(ctx.scope.workspace).id == own.id
      assert Gateways.default_gateway_for(ctx.other.workspace).id == ctx.gateway.id
    end

    test "is among a workspace's gateway choices, last", ctx do
      own = gateway_fixture(ctx.scope)
      assert Enum.map(Gateways.gateway_choices(ctx.scope), & &1.id) == [own.id, ctx.gateway.id]
    end

    test "a workspace's first gateway becomes its default, and its nodes on the default move to it",
         ctx do
      node = node_fixture(ctx.scope)
      assert node.gateway_choice == :default
      assert Gateways.chosen(node).id == ctx.gateway.id

      gateway = gateway_fixture(ctx.scope)
      assert gateway.default_gateway
      assert Gateways.chosen(node).id == gateway.id
      assert Gateways.default_gateway_for(ctx.scope.workspace).id == gateway.id

      # A second gateway of the workspace is no default: the first is.
      refute gateway_fixture(ctx.scope).default_gateway
      assert Gateways.default_gateway_for(ctx.other.workspace).id == ctx.gateway.id
    end

    test "an organisation's first gateway becomes its default", ctx do
      organisation_gateway = organisation_gateway_fixture(ctx.scope)
      assert organisation_gateway.default_gateway

      assert Gateways.default_gateway_for(ctx.scope.workspace).id == organisation_gateway.id
      assert Gateways.default_gateway_for(ctx.other.workspace).id == ctx.gateway.id
    end

    test "after a workspace's default is deleted, the oldest gateway left there becomes its default",
         ctx do
      first = gateway_fixture(ctx.scope)
      second = gateway_fixture(ctx.scope)
      assert first.default_gateway
      refute second.default_gateway

      {:ok, _deleted} = Nodes.delete_node(ctx.scope, first)
      assert Repo.reload!(second).default_gateway
      assert Gateways.default_gateway_for(ctx.scope.workspace).id == second.id
    end

    test "nodes on the default that reach no other default hold it", ctx do
      node = node_fixture(ctx.scope)
      {:ok, _theirs} = Nodes.make_default_gateway(ctx.other, gateway_fixture(ctx.other))
      _their_node = node_fixture(ctx.other)

      assert %{nodes: [%Node{id: id}], runs: []} = Gateways.delete_blockers(ctx.gateway)
      assert id == node.id
      assert Enum.map(Gateways.workspaces_using(ctx.gateway), & &1.id) == [ctx.scope.workspace.id]
    end
  end

  describe "the instance's pool" do
    test "its default leads to the instance's gateway, with an active key", ctx do
      pool = instance_pool_fixture()
      assert Gateways.chosen(pool).id == ctx.gateway.id
      assert Gateways.resolve(pool) == {:error, :gateway_without_key}

      installed_key_fixture(ctx.gateway, allow_secrets: true)
      assert {:gateway, %Node{id: id}} = Gateways.resolve(pool)
      assert id == ctx.gateway.id
    end

    test "it may name the instance's gateway alone, and go direct", ctx do
      installed_key_fixture(ctx.gateway, allow_secrets: true)
      named = instance_pool_fixture(gateway_choice: :named, gateway_id: ctx.gateway.id)
      assert {:gateway, %Node{}} = Gateways.resolve(named)

      Repo.delete!(named)
      theirs = gateway_fixture(ctx.scope)
      elsewhere = instance_pool_fixture(gateway_choice: :named, gateway_id: theirs.id)
      assert Gateways.chosen(elsewhere) == nil
      assert Gateways.resolve(elsewhere) == {:error, :gateway_not_serving}

      Repo.delete!(elsewhere)
      assert Gateways.resolve(instance_pool_fixture(gateway_choice: :direct)) == :direct
    end

    test "with no instance gateway, its default leads nowhere", ctx do
      Repo.delete!(ctx.gateway)
      assert Gateways.resolve(instance_pool_fixture()) == {:error, :no_default_gateway}
    end
  end

  describe "the keys of the instance's pool and gateway" do
    @describetag with_features: Features.all()

    @dispatch_actions [
      :"dispatch.claim",
      :"dispatch.dispatched",
      :"dispatch.release",
      :"dispatch.machine_log"
    ]

    defp dispatch(workspace, pool_id),
      do: %{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        pool_id: pool_id
      }

    test "the pool's key acts on its pool and the dispatches it claimed, in any workspace",
         ctx do
      pool = instance_pool_fixture()
      %{access_key: key} = installed_key_fixture(pool)
      scope = Scope.for_access_key(key)

      assert Access.role(scope) == :pool_key
      assert Scope.key_place(scope).id == pool.id

      for action <- @dispatch_actions do
        assert Access.authorize(scope, action, pool) == :ok
        assert Access.authorize(scope, action, dispatch(ctx.scope.workspace, pool.id)) == :ok
        assert Access.authorize(scope, action, dispatch(ctx.other.workspace, pool.id)) == :ok
      end

      assert Access.authorize(scope, :"run.post_events", Scope.key_place(scope)) == :ok
    end

    test "the pool's key reaches nothing else", ctx do
      pool = instance_pool_fixture()
      %{access_key: key} = installed_key_fixture(pool)
      scope = Scope.for_access_key(key)
      workspace_pool = pool_fixture(ctx.scope)
      adapter = adapter_fixture()

      for action <- @dispatch_actions,
          subject <- [
            ctx.scope.workspace,
            ctx.scope.organisation,
            dispatch(ctx.scope.workspace, workspace_pool.id),
            ctx.gateway,
            adapter
          ] do
        assert Access.authorize(scope, action, subject) == {:error, :not_found},
               "#{action} on #{inspect(subject)}"
      end

      for action <- [:"run.post_events", :"run_configuration.fetch"],
          subject <- [ctx.scope.workspace, ctx.scope.organisation, ctx.gateway, adapter] do
        assert Access.authorize(scope, action, subject) == {:error, :not_found}
      end
    end

    test "the gateway's key acts on its gateway alone", ctx do
      pool = instance_pool_fixture()
      %{access_key: key} = installed_key_fixture(ctx.gateway, allow_secrets: true)
      scope = Scope.for_access_key(key)

      assert Access.role(scope) == :access_key
      assert Scope.key_place(scope).id == ctx.gateway.id
      assert Access.authorize(scope, :"run.post_events", Scope.key_place(scope)) == :ok

      for action <- [
            :"run.post_events",
            :"run_configuration.fetch",
            :"secret.seal",
            :"run_credential.issue"
          ],
          subject <- [
            pool,
            adapter_fixture(),
            ctx.scope.workspace,
            ctx.scope.organisation,
            dispatch(ctx.scope.workspace, pool.id)
          ] do
        assert Access.authorize(scope, action, subject) == {:error, :not_found},
               "#{action} on #{inspect(subject)}"
      end
    end
  end
end
