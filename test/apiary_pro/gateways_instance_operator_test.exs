defmodule ApiaryPro.GatewaysInstanceOperatorTest do
  # The instance organisation made an operator serves its clients, as `ApiaryPro.Gateways`
  # answers while an operator runs its clients' infrastructure; the other answers are in
  # `ApiaryPro.GatewaysTest`. Not async: the change of kind locks the suite's instance
  # organisation, committed once outside the sandbox (docs/conventions.md, Tests).
  use Apiary.DataCase, async: false

  import ApiaryPro.OperatorsFixtures

  alias ApiaryPro.{Flags, Gateways}

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_transfers(true)
    %{instance_scope: instance_admin} = instance_admin_fixture()
    %{instance_admin: instance_admin}
  end

  defp answers(%{id: id}), do: answers(id)

  defp answers(id) when is_binary(id),
    do: {Gateways.serving_organisations(id), Gateways.served_organisations(id)}

  describe "while the operator runs its clients' infrastructure" do
    setup do: Flags.put_operator_infrastructure(true)

    test "the instance organisation, an operator, serves its clients", ctx do
      instance =
        make_instance_organisation_an_operator(%{
          user: ctx.instance_admin.user,
          instance_scope: ctx.instance_admin
        })

      client = client_fixture(instance)
      before = Gateways.served_organisations(instance.organisation.id)

      assert client.organisation.id in before
      assert Enum.sort(before) == before
      assert answers(client.organisation) == {[instance.organisation.id], []}
      assert Gateways.serving_organisations(instance.organisation.id) == []
    end
  end
end
