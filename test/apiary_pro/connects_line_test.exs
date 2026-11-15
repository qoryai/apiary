defmodule ApiaryPro.ConnectsLineTest do
  @moduledoc """
  Who connects a system for an organisation (`c:Apiary.Edition.connects_line/2`), on the
  workspace set-up's Work sources and Destinations steps. A client's owners and admins
  connect its systems, as any organisation's (`adapter.connect` in `ApiaryPro.Access`),
  with `ApiaryPro.Flags.operator_infrastructure?/0` on or off: the line is nil everywhere,
  and the core's sentence stands.
  """
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    %{operator: operator, client: client_fixture(operator.scope)}
  end

  test "is nil in a client, with the flag on and off: its owners and admins connect",
       %{client: client} do
    for flag <- [false, true], step <- [:sources, :destinations] do
      Flags.put_operator_infrastructure(flag)
      assert Apiary.Edition.connects_line(client.organisation, step) == nil
    end
  end

  test "is nil in an organisation that has no operator, with the flag on and off", %{
    operator: operator
  } do
    %{organisation: organisation} = sign_up_fixture()

    for flag <- [false, true], step <- [:sources, :destinations] do
      Flags.put_operator_infrastructure(flag)
      assert Apiary.Edition.connects_line(organisation, step) == nil
      assert Apiary.Edition.connects_line(operator.organisation, step) == nil
    end
  end
end
