defmodule ApiaryPro.OperatorHarnessOwnerTest do
  # Who owns a harness document saved in a workspace an operator operates, and who may save
  # one (the core's answer to `Apiary.Edition.harness_owner/1` and the action
  # `harness.save`), through the core's `Apiary.Stacks.put_stack/3`, which asks the edition
  # for the owner and checks no access. The flags are set for this process.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias Apiary.Stacks
  alias Apiary.Stacks.Stack
  alias ApiaryPro.{Edition, Flags}

  @moduletag with_features: Apiary.Features.all()

  @document "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"

  # An operator that operates the workspace Main of another organisation, with an admin and
  # a member, and an instance admin, made while the flag is off, then the flag on.
  setup do
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    operated = operated_fixture(operator.scope)
    admin = member_fixture(operator.scope, :admin)
    member = member_fixture(operator.scope, :member)
    instance_admin = suite_instance_admin()

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      operated: operated,
      admin: admin,
      member: member,
      instance_admin: instance_admin
    }
  end

  defp in_operated(ctx, person),
    do: scope_in(person.user, ctx.operated.organisation, ctx.operated.workspace)

  defp save(scope, ctx),
    do: Stacks.put_stack(scope, {:workspace, ctx.operated.workspace}, @document)

  describe "the owner of a save, as the core answers" do
    test "by an instance admin is the instance organisation", ctx do
      %{user: user} = ctx.instance_admin
      scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      assert scope.reach == :instance
      assert Edition.harness_owner(scope) == instance_organisation().id

      assert {:ok, %Stack{} = stack} = save(scope, ctx)
      assert stack.owner_organisation_id == instance_organisation().id
    end

    test "by a person of the organisation is the organisation", ctx do
      assert Edition.harness_owner(ctx.operated.owner.scope) == ctx.operated.organisation.id

      assert {:ok, %Stack{} = stack} = save(ctx.operated.owner.scope, ctx)
      assert stack.owner_organisation_id == ctx.operated.organisation.id
    end

    test "in the operator is the operator", ctx do
      assert Edition.harness_owner(ctx.operator.scope) == ctx.operator.organisation.id
    end
  end

  describe "the action harness.save in an operated workspace" do
    test "is held by the operator's owners and admins", ctx do
      workspace = ctx.operated.workspace

      assert Access.authorize(ctx.operated.scope, :"harness.save", workspace) == :ok
      assert Access.authorize(in_operated(ctx, ctx.admin), :"harness.save", workspace) == :ok
    end

    test "is not there for the operator's members, nor for the organisation's people", ctx do
      organisation_admin = organisation_member_fixture(ctx.operated, :admin)
      organisation_member = organisation_member_fixture(ctx.operated, :member)

      for scope <- [
            in_operated(ctx, ctx.member),
            ctx.operated.owner.scope,
            organisation_admin.scope,
            organisation_member.scope
          ] do
        assert Access.authorize(scope, :"harness.save", ctx.operated.workspace) ==
                 {:error, :not_found}
      end
    end
  end

  describe "with the flag off" do
    setup do
      Flags.put_operator_infrastructure(false)
      :ok
    end

    test "the organisation's people own and hold, the operator's people do not", ctx do
      organisation = ctx.operated.organisation
      workspace = ctx.operated.workspace

      assert Edition.harness_owner(ctx.operated.owner.scope) == organisation.id
      assert Edition.harness_owner(ctx.operated.scope) == nil
      assert save(ctx.operated.scope, ctx) == {:error, :forbidden}

      assert Access.authorize(ctx.operated.owner.scope, :"harness.save", workspace) == :ok

      assert Access.authorize(ctx.operated.scope, :"harness.save", workspace) ==
               {:error, :forbidden}

      assert {:ok, %Stack{} = stack} = save(ctx.operated.owner.scope, ctx)
      assert stack.owner_organisation_id == organisation.id
    end

    test "an instance admin's save is the instance organisation's", ctx do
      %{user: user} = ctx.instance_admin
      scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      assert Edition.harness_owner(scope) == instance_organisation().id
    end
  end
end
