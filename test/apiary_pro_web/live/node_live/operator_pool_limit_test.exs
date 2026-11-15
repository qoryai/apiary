defmodule ApiaryProWeb.NodeLive.OperatorPoolLimitTest do
  # A pool's instance limit in a workspace an operator operates while its owners and admins
  # act there (`ApiaryPro.Flags.operator_infrastructure?/0`): set by the operator's owners
  # and admins, an admin of the operator who is an owner of the organisation among them,
  # and not there for the organisation's people; with the flag off, the organisation's
  # owner and admins set it and the operator's people read. The flag is set for this
  # process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features, Organisations, Repo}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  # The operator and the organisation whose workspace Main it operates, with a pool of
  # limit 5 made by the organisation's owner, and the people of the operator, made while
  # the flag was off; then the flag on.
  setup do
    Flags.put_operator_infrastructure(false)

    operator =
      operator_fixture(%{organisation_name: "Hive Ops #{System.unique_integer([:positive])}"})

    operated = operated_fixture(operator.scope, "Acme")
    pool = pool_fixture(operated.owner.scope, instance_limit: 5)

    operator_admin = member_fixture(operator.scope, :admin).user
    owner_and_member = member_fixture(operator.scope, :owner).user
    admin_and_owner = member_fixture(operator.scope, :admin).user

    join_fixture(operated.owner.scope, owner_and_member)
    %{membership: joined} = join_fixture(operated.owner.scope, admin_and_owner)
    {:ok, _} = Organisations.set_member_level(operated.owner.scope, joined.id, :owner)

    organisation_admin = organisation_member_fixture(operated, :admin)

    Flags.put_operator_infrastructure(true)
    in_main = &scope_in(&1, operated.organisation, operated.workspace)

    %{
      operated: operated,
      pool: pool,
      organisation_admin: organisation_admin,
      users: %{
        operator_owner: operator.user,
        operator_admin: operator_admin,
        owner_and_organisation_member: owner_and_member,
        admin_and_organisation_owner: admin_and_owner
      },
      scopes: %{
        operator_owner: operated.scope,
        operator_admin: in_main.(operator_admin),
        owner_and_organisation_member: in_main.(owner_and_member),
        admin_and_organisation_owner: in_main.(admin_and_owner)
      }
    }
  end

  defp settings(ctx, user) do
    conn = log_in_user(build_conn(), user)
    path = "/#{ctx.operated.organisation.slug}/#{ctx.operated.workspace.slug}/machines"
    {:ok, lv, _html} = live(conn, "#{path}/#{ctx.pool.public_id}/settings")
    lv
  end

  defp save_limit(lv, limit),
    do: lv |> form("#node-form", node: %{instance_limit: limit}) |> render_submit()

  defp limit(ctx), do: Repo.reload!(ctx.pool).instance_limit

  describe "while the operator's owners and admins act in the workspace" do
    test "an operator admin sets the limit, as an owner of the operator does", ctx do
      scope = ctx.scopes.operator_admin
      assert Access.authorize(scope, :"node.set_limit", ctx.pool) == :ok
      assert Access.authorize(scope, :"node.set_limit", ctx.operated.workspace) == :ok

      lv = settings(ctx, ctx.users.operator_admin)
      refute has_element?(lv, "#node-form input[name='node[instance_limit]'][disabled]")

      save_limit(lv, "3")
      assert limit(ctx) == 3
    end

    test "an operator admin who is an owner of the organisation sets it too", ctx do
      scope = ctx.scopes.admin_and_organisation_owner
      assert Access.level(scope) == :owner
      assert Access.authorize(scope, :"node.set_limit", ctx.pool) == :ok

      lv = settings(ctx, ctx.users.admin_and_organisation_owner)
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

    test "the operator's owner, and an owner of it who is a member of the organisation, set it",
         ctx do
      for {actor, limit} <- [operator_owner: 3, owner_and_organisation_member: 7] do
        assert Access.authorize(ctx.scopes[actor], :"node.set_limit", ctx.pool) == :ok

        lv = settings(ctx, ctx.users[actor])
        refute has_element?(lv, "#node-form input[name='node[instance_limit]'][disabled]")
        save_limit(lv, "#{limit}")
        assert limit(ctx) == limit, "#{actor}"
      end
    end

    test "the people of the organisation find no node to change", ctx do
      for scope <- [ctx.operated.owner.scope, ctx.organisation_admin.scope] do
        assert Access.authorize(scope, :"node.set_limit", ctx.pool) == {:error, :not_found}
      end
    end
  end

  describe "with the flag off" do
    setup do: Flags.put_operator_infrastructure(false)

    test "the organisation's owner and admins set it, and the operator's people read", ctx do
      for scope <- [ctx.operated.owner.scope, ctx.organisation_admin.scope] do
        assert Access.authorize(scope, :"node.set_limit", ctx.pool) == :ok
      end

      for actor <- [:operator_owner, :operator_admin] do
        assert Access.authorize(ctx.scopes[actor], :"node.set_limit", ctx.pool) ==
                 {:error, :forbidden}
      end

      lv = settings(ctx, ctx.organisation_admin.user)
      save_limit(lv, "4")
      assert limit(ctx) == 4
    end
  end
end
