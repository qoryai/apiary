defmodule ApiaryPro.OperatorMemberReachTest do
  # A person of the operator of W1 who is also a member of W1's organisation reads W1's
  # secrets and variables only where their membership reaches W1
  # (`ApiaryPro.Access`): Ann, an admin of the operator and a member of the organisation
  # added to W3 alone, finds them not found in W1, and reads everything else there.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access

  @moduletag with_features: Apiary.Features.all()

  setup do
    operator = operator_fixture()
    %{scope: owner, organisation: organisation} = sign_up_fixture()
    w1 = owner.workspace
    operate_fixture(w1, operator.organisation)
    w3 = workspace_fixture(organisation, "W3")

    # Each an admin of the operator; in the organisation, Ann a member added to W3, Bea an
    # admin, Cal a member added to W1.
    [ann, bea, cal] = for _n <- 1..3, do: member_fixture(operator.scope, :admin).user
    join_fixture(workspace_scope(owner.user, w3), ann)
    %{membership: bea_membership} = join_fixture(owner, bea)
    {:ok, _} = Apiary.Organisations.set_member_level(owner, bea_membership.id, :admin)
    join_fixture(owner, cal)

    %{
      organisation: organisation,
      w1: w1,
      w3: w3,
      ann: scope_in(ann, organisation, w1),
      ann_in_w3: scope_in(ann, organisation, w3),
      bea: scope_in(bea, organisation, w1),
      cal: scope_in(cal, organisation, w1)
    }
  end

  test "a member whose membership does not reach W1 finds W1's secrets and variables not found",
       ctx do
    assert Access.level(ctx.ann) == :member

    for action <- [:"secret.read", :"variable.read"] do
      assert Access.check(ctx.ann, action, ctx.w1) == {:error, :not_found}, "#{action}"
    end

    # She reads everything else in W1, as a person of its operator.
    for action <- [:"run.read", :"work_item.read", :"node.read"] do
      assert Access.check(ctx.ann, action, ctx.w1) == :ok, "#{action}"
    end

    # In W3, which her membership reaches, she reads them.
    for action <- [:"secret.read", :"variable.read"] do
      assert Access.check(ctx.ann_in_w3, action, ctx.w3) == :ok, "#{action}"
    end
  end

  test "a membership that reaches W1 reads its secrets and variables", ctx do
    for scope <- [ctx.bea, ctx.cal], action <- [:"secret.read", :"variable.read"] do
      assert Access.check(scope, action, ctx.w1) == :ok, "#{action}"
    end
  end
end
