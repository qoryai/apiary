defmodule ApiaryPro.OperatorHarnessOwnerTest do
  # Who owns a harness document saved in a workspace an operator operates (the owner rule
  # of the core's `Apiary.Stacks.put_stack/4`, which checks no access), and who may save one
  # (the action `harness.save`). The flags are set for this process.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias Apiary.Stacks
  alias Apiary.Stacks.Stack
  alias ApiaryPro.Flags

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

  describe "the owner of a save" do
    test "by an instance admin is the instance organisation", ctx do
      %{user: user} = ctx.instance_admin
      scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      assert scope.reach == :instance

      assert {:ok, %Stack{} = stack} = save(scope, ctx)
      assert stack.owner_organisation_id == instance_organisation().id
    end

    test "by a person of the organisation is the organisation", ctx do
      assert {:ok, %Stack{} = stack} = save(ctx.operated.owner.scope, ctx)
      assert stack.owner_organisation_id == ctx.operated.organisation.id
    end

    test "in the operator is the operator", ctx do
      place = {:workspace, ctx.operator.workspace}
      assert {:ok, %Stack{} = stack} = Stacks.put_stack(ctx.operator.scope, place, @document)

      assert stack.owner_organisation_id == ctx.operator.organisation.id
    end
  end

  describe "the action harness.save in an operated workspace" do
    # The operator's people save no harness document there, whatever the flag: the
    # organisation's owners and admins save them.
    for on <- [true, false] do
      test "is the organisation's owners' and admins' with the flag #{on}", ctx do
        Flags.put_operator_infrastructure(unquote(on))
        workspace = ctx.operated.workspace
        organisation_admin = organisation_member_fixture(ctx.operated, :admin)
        organisation_member = organisation_member_fixture(ctx.operated, :member)

        for scope <- [ctx.operated.owner.scope, organisation_admin.scope] do
          assert Access.authorize(scope, :"harness.save", workspace) == :ok
        end

        assert Access.authorize(organisation_member.scope, :"harness.save", workspace) ==
                 {:error, :forbidden}

        assert {:ok, %Stack{} = stack} = save(ctx.operated.owner.scope, ctx)
        assert stack.owner_organisation_id == ctx.operated.organisation.id
      end

      test "is not there for the operator's people with the flag #{on}", ctx do
        Flags.put_operator_infrastructure(unquote(on))

        for scope <- [
              ctx.operated.scope,
              in_operated(ctx, ctx.admin),
              in_operated(ctx, ctx.member)
            ] do
          assert Access.authorize(scope, :"harness.save", ctx.operated.workspace) ==
                   {:error, :not_found}
        end

        assert save(ctx.operated.scope, ctx) == {:error, :forbidden}
      end
    end
  end

  describe "with the flag off" do
    setup do
      Flags.put_operator_infrastructure(false)
      :ok
    end

    test "an instance admin's save is the instance organisation's", ctx do
      %{user: user} = ctx.instance_admin
      scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      assert {:ok, %Stack{} = stack} = save(scope, ctx)
      assert stack.owner_organisation_id == instance_organisation().id
    end
  end
end
