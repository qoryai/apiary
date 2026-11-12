defmodule ApiaryPro.OperatorAsOwnerArbiterTest do
  # The instance's arbiter has no part in a client of an operator that owns its clients;
  # the other tests of the operator as owner are in `ApiaryPro.OperatorAsOwnerTest`. Not
  # async: an account suspended by an instance admin locks the owners of the suite's
  # instance organisation, committed once outside the sandbox (docs/conventions.md, Tests).
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    platform = workspace_fixture(client.organisation, "Platform")
    operator_admin = member_fixture(operator.scope, :admin)
    operator_member = member_fixture(operator.scope, :member)

    Flags.put_operator_infrastructure(true)

    # On the operator's providers: what the operator sets in the client includes its model
    # providers, runtimes and model choices.
    client = model_chain_fixture(operator.scope, client, :operator)

    %{
      operator: operator,
      client: client,
      platform: platform,
      client_admin: client_member_fixture(client, :admin),
      client_member: client_member_fixture(client, :member),
      invitation: invitation_fixture(client.owner.scope).invitation,
      operator_admin: operator_admin,
      operator_member: operator_member,
      as_owner: client.scope,
      as_admin: scope_in(operator_admin.user, client.organisation, client.workspace),
      as_member: scope_in(operator_member.user, client.organisation, client.workspace)
    }
  end

  describe "what is the client's own to decide" do
    test "the instance's arbiter has no part in a client", ctx do
      admin = instance_admin_fixture()

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_account(admin.instance_scope, ctx.client.owner.user.id)

      client = ctx.client.organisation
      refute ApiaryPro.Suspensions.owner_suspended?(client)

      assert ApiaryPro.Transfers.arbitrate(
               admin.instance_scope,
               client.id,
               ctx.client_admin.membership.id,
               "The owner is away."
             ) == {:error, :has_owner}

      # With the flag off, the client's owners are its own, and all suspended.
      Flags.put_operator_infrastructure(false)
      assert ApiaryPro.Suspensions.owner_suspended?(client)
    end
  end
end
