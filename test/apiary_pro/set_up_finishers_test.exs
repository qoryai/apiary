defmodule ApiaryPro.SetUpFinishersTest do
  @moduledoc """
  Who finishes a workspace's set-up (`c:Apiary.Edition.set_up_finishers_line/2`), for a
  person who may not take the next step's action. While the operator owns its clients
  (`ApiaryPro.Flags.operator_infrastructure?/0`), a client's Machines and Harness steps are
  the operator's owners' and admins' alone, and so is Model while the client's model switch
  is `:operator`; the operator's owners and admins also reach every other step. Everywhere
  else the line is the core's.
  """
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  @steps [:name, :sources, :destinations, :model, :harness, :machines, :test]

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    %{operator: operator, client: client}
  end

  defp line(scope, step), do: Apiary.Edition.set_up_finishers_line(scope, step)

  defp core(scope, step), do: Apiary.Edition.Core.set_up_finishers_line(scope, step)

  defp operator_line(operator),
    do: "Owners and admins of #{operator.organisation.name} finish the set-up."

  defp both_line(client, operator),
    do:
      "Owners and admins of #{client.organisation.name} and of #{operator.organisation.name} finish the set-up."

  describe "with the flag on, in a client" do
    setup do
      Flags.put_operator_infrastructure(true)
      :ok
    end

    test "Machines and Harness are the operator's owners' and admins'", %{
      operator: operator,
      client: client
    } do
      for step <- [:machines, :harness] do
        assert line(client.scope, step) == operator_line(operator)
        assert line(client.owner.scope, step) == operator_line(operator)
      end
    end

    test "Name, Work sources, Destinations and Test run are the client's and the operator's",
         %{operator: operator, client: client} do
      for step <- [:name, :sources, :destinations, :test] do
        assert line(client.scope, step) == both_line(client, operator)
        assert line(client.owner.scope, step) == both_line(client, operator)
      end
    end

    test "Model is the operator's while the switch is the operator's", %{
      operator: operator,
      client: client
    } do
      client = model_chain_fixture(operator.scope, client, :operator)

      assert line(client.scope, :model) == operator_line(operator)
      assert line(client.owner.scope, :model) == operator_line(operator)
    end

    test "Model is the core's while the switch is the organisation's, and follows a switch back",
         %{operator: operator, client: client} do
      assert line(client.scope, :model) == core(client.scope, :model)

      client = model_chain_fixture(operator.scope, client, :operator)
      assert line(client.scope, :model) == operator_line(operator)

      client = model_chain_fixture(operator.scope, client, :organisation)
      assert line(client.scope, :model) == core(client.scope, :model)

      assert line(client.scope, :model) ==
               "Owners and admins of #{client.organisation.name} finish the set-up."
    end

    test "the switch changes no other step", %{operator: operator, client: client} do
      client = model_chain_fixture(operator.scope, client, :operator)

      for step <- [:name, :sources, :destinations, :test] do
        assert line(client.scope, step) == both_line(client, operator)
      end

      assert line(client.scope, :machines) == operator_line(operator)
    end
  end

  describe "with the flag off, in a client" do
    test "every step is the core's", %{operator: operator, client: client} do
      for step <- @steps do
        assert line(client.scope, step) == core(client.scope, step)
        assert line(client.owner.scope, step) == core(client.owner.scope, step)
      end

      client = model_chain_fixture_off(operator, client)
      assert line(client.scope, :model) == core(client.scope, :model)
    end
  end

  describe "in an organisation that is no client" do
    test "every step is the core's, with the flag on and off" do
      %{scope: scope} = sign_up_fixture()
      operator = operator_fixture()

      for flag <- [false, true], step <- @steps do
        Flags.put_operator_infrastructure(flag)
        assert line(scope, step) == core(scope, step)
        assert line(operator.scope, step) == core(operator.scope, step)
      end
    end

    test "the core's line names the organisation" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      Flags.put_operator_infrastructure(true)

      assert line(scope, :machines) ==
               "Owners and admins of #{organisation.name} finish the set-up."
    end
  end

  # The switch is set by the operator only while the flag is on; set it, then turn the flag
  # off, and make the client's scopes again.
  defp model_chain_fixture_off(operator, client) do
    Flags.put_operator_infrastructure(true)
    client = model_chain_fixture(operator.scope, client, :operator)
    Flags.put_operator_infrastructure(false)
    client
  end
end
