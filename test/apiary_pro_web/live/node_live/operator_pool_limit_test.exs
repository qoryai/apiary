defmodule ApiaryProWeb.NodeLive.OperatorPoolLimitTest do
  # A pool's instance limit in a client while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`): set by the operator's owners and
  # admins, an admin who owns the client among them, and not there for the client's
  # people; with the flag off, the client's owner and admins set it and the operator's
  # people read. The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features, Organisations, Repo}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  # The operator and its client, with a pool of limit 5 made by the client's owner, and
  # the people of the operator, made while the flag was off; then the flag on.
  setup do
    Flags.put_operator_infrastructure(false)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    pool = pool_fixture(client.owner.scope, instance_limit: 5)

    operator_admin = member_fixture(operator.scope, :admin).user
    owner_and_member = member_fixture(operator.scope, :owner).user
    admin_and_owner = member_fixture(operator.scope, :admin).user

    join_fixture(client.owner.scope, owner_and_member)
    %{membership: joined} = join_fixture(client.owner.scope, admin_and_owner)
    {:ok, _} = Organisations.set_member_level(client.owner.scope, joined.id, :owner)

    client_admin = client_member_fixture(client, :admin)

    Flags.put_operator_infrastructure(true)
    in_client = &scope_in(&1, client.organisation, client.workspace)

    %{
      operator: operator,
      operator_name: name,
      client: client,
      pool: pool,
      client_admin: client_admin,
      users: %{
        operator_owner: operator.user,
        operator_admin: operator_admin,
        owner_and_client_member: owner_and_member,
        admin_and_client_owner: admin_and_owner
      },
      scopes: %{
        operator_owner: client.scope,
        operator_admin: in_client.(operator_admin),
        owner_and_client_member: in_client.(owner_and_member),
        admin_and_client_owner: in_client.(admin_and_owner)
      }
    }
  end

  defp settings(ctx, user) do
    conn = log_in_user(build_conn(), user)
    path = "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}/machines"
    {:ok, lv, _html} = live(conn, "#{path}/#{ctx.pool.public_id}/settings")
    lv
  end

  defp save_limit(lv, limit),
    do: lv |> form("#node-form", node: %{instance_limit: limit}) |> render_submit()

  defp limit(ctx), do: Repo.reload!(ctx.pool).instance_limit

  defp managed_by(ctx),
    do:
      "Owners and admins of #{ctx.operator_name}, its operator, manage the machines, pools and access keys here."

  describe "while the operator owns its clients" do
    test "an operator admin sets the limit, as an owner of the operator does", ctx do
      scope = ctx.scopes.operator_admin
      assert Access.authorize(scope, :"node.set_limit", ctx.pool) == :ok
      assert Access.authorize(scope, :"node.set_limit", ctx.client.workspace) == :ok

      lv = settings(ctx, ctx.users.operator_admin)
      refute has_element?(lv, "#node-form input[name='node[instance_limit]'][disabled]")
      refute has_element?(lv, "#node-form", managed_by(ctx))

      save_limit(lv, "3")
      assert limit(ctx) == 3
    end

    test "an operator admin who is an owner of the client sets it too", ctx do
      scope = ctx.scopes.admin_and_client_owner
      assert Access.level(scope) == :owner
      assert Access.authorize(scope, :"node.set_limit", ctx.pool) == :ok

      lv = settings(ctx, ctx.users.admin_and_client_owner)
      refute has_element?(lv, "#node-form input[name='node[instance_limit]'][disabled]")

      save_limit(lv, "4")
      assert limit(ctx) == 4
    end

    test "an operator admin makes a pool with a limit", ctx do
      scope = ctx.scopes.operator_admin

      assert {:ok, made} =
               Apiary.Nodes.create_node(scope, %{
                 kind: "pool",
                 name: "spot-1",
                 instance_limit: 3
               })

      assert made.instance_limit == 3
    end

    test "the operator's owner, and an owner of it who is a member of the client, set it",
         ctx do
      for {actor, limit} <- [operator_owner: 3, owner_and_client_member: 7] do
        assert Access.authorize(ctx.scopes[actor], :"node.set_limit", ctx.pool) == :ok

        lv = settings(ctx, ctx.users[actor])
        refute has_element?(lv, "#node-form input[name='node[instance_limit]'][disabled]")
        save_limit(lv, "#{limit}")
        assert limit(ctx) == limit, "#{actor}"
      end
    end

    test "the people of the client find no node to change", ctx do
      for scope <- [ctx.client.owner.scope, ctx.client_admin.scope] do
        assert Access.authorize(scope, :"node.set_limit", ctx.pool) == {:error, :not_found}
      end
    end

    test "who may set it is said as for the other node actions", ctx do
      for scope <- [ctx.scopes.operator_admin, ctx.client.owner.scope] do
        assert ApiaryProWeb.Edition.who_may_sentence(:"node.set_limit", scope) ==
                 managed_by(ctx)
      end

      assert ApiaryProWeb.Edition.who_may_sentence(:"node.edit", ctx.scopes.operator_admin) ==
               managed_by(ctx)

      assert ApiaryProWeb.Edition.who_may_sentence(:"variable.edit", ctx.scopes.operator_admin) ==
               nil

      assert ApiaryProWeb.Edition.who_may_sentence(:"node.set_limit", ctx.operator.scope) ==
               nil
    end
  end

  describe "with the flag off" do
    setup do: Flags.put_operator_infrastructure(false)

    test "the client's owner and admins set it, and the operator's people read", ctx do
      for scope <- [ctx.client.owner.scope, ctx.client_admin.scope] do
        assert Access.authorize(scope, :"node.set_limit", ctx.pool) == :ok
      end

      for actor <- [:operator_owner, :operator_admin] do
        assert Access.authorize(ctx.scopes[actor], :"node.set_limit", ctx.pool) ==
                 {:error, :forbidden}
      end

      lv = settings(ctx, ctx.client_admin.user)
      refute has_element?(lv, "#node-form", managed_by(ctx))
      save_limit(lv, "4")
      assert limit(ctx) == 4

      assert ApiaryProWeb.Edition.who_may_sentence(:"node.set_limit", ctx.client.owner.scope) ==
               nil
    end
  end
end
