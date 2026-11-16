defmodule ApiaryPro.ReachTest do
  # The places the edition gives the switcher beside the core's: none of them gives a
  # scope, which the core reads when a link to the place is followed.
  use Apiary.DataCase, async: true

  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias Apiary.Organisations.Membership
  alias ApiaryPro.OperatedPlace

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  setup do
    operator = operator_fixture()
    operated = operated_fixture(operator.scope, "Acme")
    %{operator: operator, operated: operated}
  end

  test "the switcher's places give no scope", ctx do
    place = %OperatedPlace{
      organisation: ctx.operated.organisation,
      organisation_id: ctx.operated.organisation.id
    }

    assert ApiaryProWeb.Edition.place_scope(place, ctx.operated.workspace) == nil

    %Membership{} = membership = ctx.operated.owner.scope.membership
    assert ApiaryProWeb.Edition.place_scope(membership, ctx.operated.workspace) == nil
  end
end
