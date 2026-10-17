defmodule Apiary.PoolKeyRoleTest do
  # A node pool's key acts in the role `pool_key`, apart from a node's key: what a node's
  # key holds, and the dispatch actions besides, on its workspace's queue and the
  # dispatches its pool claimed there alone.
  # Not async: the features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Audit, Features, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias Apiary.Policy.Serving

  @moduletag with_features: Features.all()

  @dispatch_actions [
    :"dispatch.claim",
    :"dispatch.dispatched",
    :"dispatch.handover",
    :"dispatch.release"
  ]

  # What a node pool's key held before it acted in `pool_key`, as a node's key does.
  @key_actions [:"run.post_events", :"run_configuration.fetch"]

  # Every feature but `factory`, and those that need it.
  @without_factory Enum.reject(
                     Features.all(),
                     &(&1 == :factory or :factory in Features.needs(&1))
                   )

  setup do
    %{scope: owner} = sign_up_fixture()
    pool = pool_fixture(owner)
    %{access_key: key} = access_key_fixture(owner, node: pool)
    %{access_key: node_key} = access_key_fixture(owner)

    %{
      owner: owner,
      workspace: owner.workspace,
      pool: pool,
      key: key,
      pool_scope: Scope.for_access_key(key),
      node_scope: Scope.for_access_key(node_key)
    }
  end

  # A dispatch of `workspace` as the key is asked of one: its organisation, its workspace,
  # and the pool whose key claimed it.
  defp dispatch(workspace, pool_id),
    do: %{
      organisation_id: workspace.organisation_id,
      workspace_id: workspace.id,
      pool_id: pool_id
    }

  describe "the role" do
    test "a node pool's key acts as pool_key, a node's and a gateway's as access_key", ctx do
      assert Access.role(ctx.pool_scope) == :pool_key
      assert Access.role(ctx.node_scope) == :access_key

      # Read from the database, its node not loaded: the scope loads it.
      bare = AccessKey |> Repo.get!(ctx.key.id) |> Repo.preload(:workspace)
      assert Access.role(Scope.for_access_key(bare)) == :pool_key

      %{access_key: gateway_key} = access_key_fixture(ctx.owner, node: gateway_fixture(ctx.owner))
      assert Access.role(Scope.for_access_key(gateway_key)) == :access_key

      %{access_key: organisation_gateway_key} =
        enrolled_key_fixture(ctx.owner, organisation_gateway_fixture(ctx.owner))

      organisation_gateway_scope =
        Scope.for_access_key(Repo.get!(AccessKey, organisation_gateway_key.id))

      assert Access.role(organisation_gateway_scope) == :access_key

      %{access_key: adapter_key} = enrolled_key_fixture(instance_admin_scope(), adapter_fixture())
      assert Access.role(Scope.for_access_key(adapter_key)) == :adapter_key
    end

    test "holds what a node's key holds, and the dispatch actions besides" do
      assert Access.roles().access_key == @key_actions
      assert Access.roles().pool_key == @key_actions ++ @dispatch_actions

      for action <- @key_actions do
        assert Access.action(action).roles == [:access_key, :pool_key]
      end

      for action <- @dispatch_actions do
        assert Access.action(action).roles == [:pool_key]
        assert Access.feature(action) == :factory
        assert Access.action(action).asked_of == :workspace
      end

      for {role, actions} <- Access.roles(), role != :pool_key, action <- @dispatch_actions do
        refute action in actions, "#{role} holds #{action}"
      end
    end
  end

  describe "the dispatch actions" do
    test "are held on the key's workspace, its queue, and on a dispatch its pool claimed",
         ctx do
      for action <- @dispatch_actions do
        for subject <- [ctx.workspace, dispatch(ctx.workspace, ctx.pool.id)] do
          assert Access.authorize(ctx.pool_scope, action, subject) == :ok,
                 "#{action} on #{inspect(subject)}"

          assert Access.can?(ctx.pool_scope, action, subject)
        end
      end
    end

    test "any pool of the workspace claims from its queue, but not another pool's dispatch",
         ctx do
      second = pool_fixture(ctx.owner)
      %{access_key: second_key} = access_key_fixture(ctx.owner, node: second)
      second_scope = Scope.for_access_key(second_key)

      for action <- @dispatch_actions do
        assert Access.authorize(second_scope, action, ctx.workspace) == :ok
        assert Access.authorize(second_scope, action, dispatch(ctx.workspace, second.id)) == :ok

        assert Access.authorize(second_scope, action, dispatch(ctx.workspace, ctx.pool.id)) ==
                 {:error, :not_found}

        assert Access.authorize(ctx.pool_scope, action, dispatch(ctx.workspace, second.id)) ==
                 {:error, :not_found}
      end
    end

    test "are not found for another workspace or another organisation", ctx do
      other_workspace = workspace_fixture(ctx.owner.organisation)
      %{scope: elsewhere} = sign_up_fixture()

      for action <- @dispatch_actions,
          subject <- [
            other_workspace,
            dispatch(other_workspace, nil),
            dispatch(other_workspace, ctx.pool.id),
            elsewhere.workspace,
            elsewhere.organisation,
            dispatch(elsewhere.workspace, nil),
            dispatch(elsewhere.workspace, ctx.pool.id)
          ] do
        assert Access.authorize(ctx.pool_scope, action, subject) == {:error, :not_found},
               "#{action} on #{inspect(subject)}"

        refute Access.can?(ctx.pool_scope, action, subject)
      end

      # A pool of the other workspace claims nothing from this one's queue.
      there = %{ctx.owner | workspace: other_workspace}
      %{access_key: there_key} = access_key_fixture(there, node: pool_fixture(there))
      there_scope = Scope.for_access_key(there_key)

      for action <- @dispatch_actions do
        assert Access.authorize(there_scope, action, other_workspace) == :ok
        assert Access.authorize(there_scope, action, ctx.workspace) == {:error, :not_found}

        assert Access.authorize(there_scope, action, dispatch(ctx.workspace, nil)) ==
                 {:error, :not_found}
      end
    end

    test "are not found for a dispatch that names no pool, another pool, or no field by name",
         ctx do
      other_pool = pool_fixture(ctx.owner)

      string_keyed = %{
        "organisation_id" => ctx.workspace.organisation_id,
        "workspace_id" => ctx.workspace.id,
        "pool_id" => ctx.pool.id
      }

      for action <- @dispatch_actions,
          subject <- [
            dispatch(ctx.workspace, nil),
            dispatch(ctx.workspace, other_pool.id),
            dispatch(ctx.workspace, Ecto.UUID.generate()),
            string_keyed
          ] do
        assert Access.authorize(ctx.pool_scope, action, subject) == {:error, :not_found},
               "#{action} on #{inspect(subject)}"

        refute Access.can?(ctx.pool_scope, action, subject)
      end
    end

    test "are asked of the queue or a dispatch alone: not the pool, the organisation or nothing",
         ctx do
      other_pool = pool_fixture(ctx.owner)

      for action <- @dispatch_actions,
          subject <- [ctx.pool, other_pool, ctx.owner.organisation, %Organisation{}, nil] do
        assert Access.authorize(ctx.pool_scope, action, subject) == {:error, :not_found},
               "#{action} on #{inspect(subject)}"
      end
    end

    test "are held by no node's, gateway's or adapter's key", ctx do
      %{access_key: gateway_key} = access_key_fixture(ctx.owner, node: gateway_fixture(ctx.owner))

      %{access_key: organisation_gateway_key} =
        enrolled_key_fixture(ctx.owner, organisation_gateway_fixture(ctx.owner))

      %{access_key: adapter_key} = enrolled_key_fixture(instance_admin_scope(), adapter_fixture())

      for action <- @dispatch_actions do
        for scope <- [ctx.node_scope, Scope.for_access_key(gateway_key)],
            subject <- [ctx.workspace, dispatch(ctx.workspace, ctx.pool.id)] do
          assert Access.authorize(scope, action, subject) == {:error, :forbidden}
          refute Access.can?(scope, action, subject)
        end

        for scope <- [
              Scope.for_access_key(Repo.get!(AccessKey, organisation_gateway_key.id)),
              Scope.for_access_key(adapter_key)
            ],
            subject <- [ctx.workspace, dispatch(ctx.workspace, ctx.pool.id)] do
          assert {:error, _reason} = Access.authorize(scope, action, subject)
          refute Access.can?(scope, action, subject)
        end
      end
    end

    @tag with_features: @without_factory
    test "are not found without the factory feature, and the key keeps the rest", ctx do
      for action <- @dispatch_actions,
          subject <- [ctx.workspace, dispatch(ctx.workspace, ctx.pool.id)] do
        assert Access.authorize(ctx.pool_scope, action, subject) == {:error, :not_found}
        refute Access.can?(ctx.pool_scope, action, subject)
      end

      for action <- @key_actions do
        assert Access.authorize(ctx.pool_scope, action, ctx.workspace) == :ok
      end
    end

    test "leave an audit entry for a handover and a release, and none for a claim or its start" do
      assert Access.action(:"dispatch.handover").audited == true
      assert Access.action(:"dispatch.release").audited == true
      assert {:not, claim} = Access.action(:"dispatch.claim").audited
      assert {:not, dispatched} = Access.action(:"dispatch.dispatched").audited
      assert is_binary(claim) and claim != ""
      assert is_binary(dispatched) and dispatched != ""

      assert Enum.filter(@dispatch_actions, &Audit.audited?/1) ==
               [:"dispatch.handover", :"dispatch.release"]
    end
  end

  describe "what the key held before" do
    test "holds run.post_events and run_configuration.fetch as before", ctx do
      for action <- @key_actions do
        assert Access.authorize(ctx.pool_scope, action, ctx.workspace) == :ok
        assert Access.authorize(ctx.pool_scope, action, Scope.key_place(ctx.pool_scope)) == :ok
        assert Access.can?(ctx.pool_scope, action, ctx.key.workspace)
      end

      assert Serving.managed?(ctx.key) == Serving.managed?(ctx.node_scope.access_key)
    end

    test "answers every other action of its workspace as a node's key does", ctx do
      other_workspace = workspace_fixture(ctx.owner.organisation)
      %{scope: elsewhere} = sign_up_fixture()

      for action <- Access.actions() -- @dispatch_actions,
          subject <- [ctx.workspace, other_workspace, elsewhere.workspace] do
        assert Access.authorize(ctx.pool_scope, action, subject) ==
                 Access.authorize(ctx.node_scope, action, subject),
               "#{action} on #{inspect(subject)}"
      end
    end

    test "acts on its pool, but on no other node and not on the organisation", ctx do
      other_pool = pool_fixture(ctx.owner)

      for action <- @key_actions do
        assert Access.authorize(ctx.pool_scope, action, ctx.pool) == :ok
        assert Access.authorize(ctx.pool_scope, action, other_pool) == {:error, :not_found}

        assert Access.authorize(ctx.pool_scope, action, ctx.owner.organisation) ==
                 {:error, :not_found}
      end
    end
  end
end
