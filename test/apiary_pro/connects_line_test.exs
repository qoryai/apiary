defmodule ApiaryPro.ConnectsLineTest do
  @moduledoc """
  Who connects a system for an organisation (`c:Apiary.Edition.connects_line/2`), on the
  workspace set-up's Work sources and Destinations steps. While the operator owns its
  clients (`ApiaryPro.Flags.operator_infrastructure?/0`), the operator's owners and admins
  connect for a client (`adapter.connect` in `ApiaryPro.Access`). Everywhere else the line
  is nil, and the core's sentence stands.
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

  test "is the operator's owners and admins, on both steps, while the operator owns the client",
       %{operator: operator, client: client} do
    Flags.put_operator_infrastructure(true)

    for step <- [:sources, :destinations] do
      assert Apiary.Edition.connects_line(client.organisation, step) ==
               "Owners and admins of #{operator.organisation.name} connect it once for #{client.organisation.name}."
    end
  end

  test "is nil in a client while the operator does not own its clients", %{client: client} do
    for step <- [:sources, :destinations] do
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
