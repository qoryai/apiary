defmodule ApiaryPro.OperatorHarnessOwnerTest do
  # Who owns a harness document saved in a client of an operator, and who may save one
  # (`ApiaryPro.Edition.harness_owner/1` and the action `harness.save`), through the core's
  # `Apiary.Stacks.put_stack/3`, which asks the edition for the owner and checks no access.
  # The flags are set for this process.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias Apiary.Stacks
  alias Apiary.Stacks.Stack
  alias ApiaryPro.{Edition, Flags, Transfers}

  @moduletag with_features: Apiary.Features.all()

  @document "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"

  # An operator with a client and an admin, a second operator, and an instance admin, made
  # while the flag is off, then the flag on.
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    admin = member_fixture(operator.scope, :admin)
    member = member_fixture(operator.scope, :member)
    elsewhere = operator_fixture()
    instance_admin = suite_instance_admin()

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      client: client,
      admin: admin,
      member: member,
      elsewhere: elsewhere,
      instance_admin: instance_admin
    }
  end

  defp in_client(ctx, person),
    do: scope_in(person.user, ctx.client.organisation, ctx.client.workspace)

  defp save(scope, ctx),
    do: Stacks.put_stack(scope, {:workspace, ctx.client.workspace}, @document)

  describe "a save by a person of the client's operator" do
    test "is owned by the operator, whatever their level there", ctx do
      scopes = [ctx.client.scope, in_client(ctx, ctx.admin), in_client(ctx, ctx.member)]

      for scope <- scopes do
        assert {:operator, _membership} = scope.reach
        assert Edition.harness_owner(scope) == ctx.operator.organisation.id
      end

      assert {:ok, %Stack{} = stack} = save(ctx.client.scope, ctx)
      assert stack.owner_organisation_id == ctx.operator.organisation.id
      assert stack.organisation_id == ctx.client.organisation.id
      assert stack.updated_by_id == ctx.operator.user.id
    end
  end

  describe "a save by a person who reaches the client another way" do
    test "by a person of another operator is refused", ctx do
      assert ctx.elsewhere.organisation.id != ctx.operator.organisation.id

      # Their membership in their operator, which is not this client's.
      scope = %{ctx.client.scope | reach: {:operator, ctx.elsewhere.scope.membership}}

      assert Edition.harness_owner(scope) == nil
      assert save(scope, ctx) == {:error, :forbidden}
      refute Repo.exists?(Stack)
    end

    test "by an instance admin is owned by the instance organisation", ctx do
      %{user: user} = ctx.instance_admin
      scope = scope_in(user, ctx.client.organisation, ctx.client.workspace)

      assert scope.reach == :instance
      assert Edition.harness_owner(scope) == instance_organisation().id

      assert {:ok, %Stack{} = stack} = save(scope, ctx)
      assert stack.owner_organisation_id == instance_organisation().id
    end

    test "by a person of the client stays the client's, as the core answers", ctx do
      assert Edition.harness_owner(ctx.client.owner.scope) == ctx.client.organisation.id

      assert {:ok, %Stack{} = stack} = save(ctx.client.owner.scope, ctx)
      assert stack.owner_organisation_id == ctx.client.organisation.id
    end

    test "in the operator is owned by the operator, as the core answers", ctx do
      assert Edition.harness_owner(ctx.operator.scope) == ctx.operator.organisation.id
    end
  end

  describe "the action harness.save in an operated client" do
    test "is held by the operator's owners and admins", ctx do
      client = ctx.client.organisation

      assert Access.authorize(ctx.client.scope, :"harness.save", client) == :ok
      assert Access.authorize(in_client(ctx, ctx.admin), :"harness.save", client) == :ok
    end

    test "is not there for the operator's members, nor for the client's people", ctx do
      client = ctx.client.organisation
      client_admin = client_member_fixture(ctx.client, :admin)
      client_member = client_member_fixture(ctx.client, :member)

      for scope <- [
            in_client(ctx, ctx.member),
            ctx.client.owner.scope,
            client_admin.scope,
            client_member.scope
          ] do
        assert Access.authorize(scope, :"harness.save", client) == {:error, :not_found}
      end
    end

    test "is the client's people's again after a drop", ctx do
      id = ctx.client.organisation.id
      client_admin = client_member_fixture(ctx.client, :admin)

      assert Access.authorize(ctx.client.owner.scope, :"harness.save", ctx.client.organisation) ==
               {:error, :not_found}

      # A drop is not offered while the operator owns its clients: it is done as before.
      Flags.put_operator_infrastructure(false)

      assert {:ok, dropped} =
               Transfers.drop(ctx.operator.scope, id, ctx.client.organisation.name)

      Flags.put_operator_infrastructure(true)

      for person <- [ctx.client.owner, client_admin] do
        scope = scope_in(person.user, dropped, ctx.client.workspace)
        assert Access.authorize(scope, :"harness.save", dropped) == :ok
      end

      owner = scope_in(ctx.client.owner.user, dropped, ctx.client.workspace)
      assert {:ok, %Stack{} = stack} = save(owner, ctx)
      assert stack.owner_organisation_id == id
    end
  end

  describe "with the flag off" do
    setup do
      Flags.put_operator_infrastructure(false)
      :ok
    end

    test "the core's answers stand: the client's people own and hold, its operator does not",
         ctx do
      client = ctx.client.organisation

      assert Edition.harness_owner(ctx.client.owner.scope) == client.id
      assert Edition.harness_owner(ctx.client.scope) == nil
      assert save(ctx.client.scope, ctx) == {:error, :forbidden}

      assert Access.authorize(ctx.client.owner.scope, :"harness.save", client) == :ok
      assert Access.authorize(ctx.client.scope, :"harness.save", client) == {:error, :forbidden}

      assert {:ok, %Stack{} = stack} = save(ctx.client.owner.scope, ctx)
      assert stack.owner_organisation_id == client.id
    end

    test "an instance admin's save is the instance organisation's", ctx do
      %{user: user} = ctx.instance_admin
      scope = scope_in(user, ctx.client.organisation, ctx.client.workspace)

      assert Edition.harness_owner(scope) == instance_organisation().id
    end
  end
end
