defmodule ApiaryPro.OperatorChainWriterTest do
  # Who writes the operator's chain of model providers and choices, and for whom it
  # resolves (`ApiaryPro.Edition.operator_chain_writer?/1` and
  # `operator_chain_organisation/1`), through the core's functions that ask them
  # (`Apiary.Connections`, `Apiary.ModelChoices`). The flags are set for this process.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures, only: [model_key: 0]
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.Accounts.Scope
  alias ApiaryPro.{Edition, Flags, Tenants, Transfers}

  @moduletag with_features: Apiary.Features.all()

  # Two operators, each with clients, made while the flag is off, then the flag on: the
  # first operator has a client on its switch (`on`) and one on the default (`off`).
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    on = client_fixture(operator.scope)
    off = client_fixture(operator.scope)
    admin = member_fixture(operator.scope, :admin)
    member = member_fixture(operator.scope, :member)
    client_admin = client_member_fixture(on, :admin)
    %{instance_scope: instance_scope, user: instance_user} = suite_instance_admin()

    elsewhere = operator_fixture()
    other_client = client_fixture(elsewhere.scope)

    Flags.put_operator_infrastructure(true)

    on = model_chain_fixture(operator.scope, on, :operator)
    other_client = model_chain_fixture(elsewhere.scope, other_client, :operator)

    %{
      operator: operator,
      on: on,
      off: off,
      admin: admin,
      member: member,
      client_admin: client_admin,
      instance_scope: instance_scope,
      instance_user: instance_user,
      elsewhere: elsewhere,
      other_client: other_client
    }
  end

  defp id(client), do: client.organisation.id

  defp provider_attrs(chain),
    do: %{provider: "anthropic", chain: chain, keys: [%{value_id: "main", value: model_key()}]}

  defp in_operator(ctx, person), do: scope_in(person.user, ctx.operator.organisation)

  describe "the operator's chain writer" do
    test "is an owner or an admin of an operator through their membership", ctx do
      assert Edition.operator_chain_writer?(ctx.operator.scope)
      assert Edition.operator_chain_writer?(in_operator(ctx, ctx.admin))
      assert Edition.operator_chain_writer?(ctx.elsewhere.scope)
    end

    test "is not a member of the operator", ctx do
      refute Edition.operator_chain_writer?(in_operator(ctx, ctx.member))
    end

    test "is not a person of a client, nor of an organisation that is no operator", ctx do
      refute Edition.operator_chain_writer?(ctx.on.owner.scope)
      refute Edition.operator_chain_writer?(ctx.client_admin.scope)
      refute Edition.operator_chain_writer?(ctx.off.owner.scope)
      refute Edition.operator_chain_writer?(sign_up_fixture().scope)
    end

    test "is not a person of the operator who acts in a client through their reach", ctx do
      assert {:operator, _membership} = ctx.on.scope.reach
      refute Edition.operator_chain_writer?(ctx.on.scope)
      refute Edition.operator_chain_writer?(scope_in(ctx.admin.user, ctx.on.organisation))
    end

    test "is not an instance admin who has no membership in the operator", ctx do
      scope = scope_in(ctx.instance_user, ctx.operator.organisation)
      assert scope.reach == :instance
      assert scope.membership == nil
      refute Edition.operator_chain_writer?(scope)
    end

    test "is not an access key, nor a scope that carries no person", ctx do
      %{access_key: key} = Apiary.ContractFixtures.contract_key_fixture(ctx.operator.scope)

      key_scope =
        key |> Scope.for_access_key() |> Scope.key_in_organisation(ctx.operator.organisation)

      refute Edition.operator_chain_writer?(key_scope)
      refute Edition.operator_chain_writer?(%{ctx.operator.scope | user: nil})
      refute Edition.operator_chain_writer?(%{ctx.operator.scope | membership: nil})
    end

    test "is not a person whose membership is another person's or another organisation's",
         ctx do
      other = ctx.elsewhere.scope.membership
      refute Edition.operator_chain_writer?(%{ctx.operator.scope | membership: other})
    end

    test "is no one with the flag off", ctx do
      Flags.put_operator_infrastructure(false)

      refute Edition.operator_chain_writer?(ctx.operator.scope)
      refute Edition.operator_chain_writer?(in_operator(ctx, ctx.admin))
    end
  end

  describe "the operator's organisation for a client" do
    test "is the client's operator while its switch is the operator's", ctx do
      assert Edition.operator_chain_organisation(id(ctx.on)) == ctx.operator.organisation.id
      assert Edition.model_choice_chain(id(ctx.on)) == "operator"
    end

    test "is nil for a client on the default, an operator and an organisation", ctx do
      assert Edition.operator_chain_organisation(id(ctx.off)) == nil
      assert Edition.operator_chain_organisation(ctx.operator.organisation.id) == nil
      assert Edition.operator_chain_organisation(sign_up_fixture().organisation.id) == nil
      assert Edition.operator_chain_organisation(Ecto.UUID.generate()) == nil
    end

    test "is the operator of each client, not another's", ctx do
      assert Edition.operator_chain_organisation(id(ctx.other_client)) ==
               ctx.elsewhere.organisation.id
    end

    test "is nil for every organisation with the flag off", ctx do
      Flags.put_operator_infrastructure(false)

      assert Edition.operator_chain_organisation(id(ctx.on)) == nil
      assert Edition.operator_chain_organisation(id(ctx.other_client)) == nil
      assert Tenants.model_chain_of(id(ctx.on)) == :operator
      assert Edition.model_choice_chain(id(ctx.on)) == "organisation"
    end
  end

  describe "a write of the operator's chain" do
    test "is made by an owner of the operator: a provider with its key, and a choice", ctx do
      assert {:ok, provider} =
               Connections.create_provider(ctx.operator.scope, provider_attrs("operator"))

      assert provider.chain == "operator"
      assert provider.organisation_id == ctx.operator.organisation.id

      assert {:ok, [listed]} = Connections.list_providers(ctx.operator.scope, "operator")
      assert listed.public_id == provider.public_id
      assert {:ok, []} = Connections.list_providers(ctx.operator.scope)

      assert {:ok, choice} =
               ModelChoices.put_choice(
                 ctx.operator.scope,
                 :organisation,
                 %{provider: provider.public_id},
                 "operator"
               )

      assert choice.chain == "operator"
      assert choice.organisation_id == ctx.operator.organisation.id
    end

    test "is made by an admin of the operator", ctx do
      scope = in_operator(ctx, ctx.admin)

      assert {:ok, provider} = Connections.create_provider(scope, provider_attrs("operator"))

      assert {:ok, _choice} =
               ModelChoices.put_choice(
                 scope,
                 :organisation,
                 %{provider: provider.public_id},
                 "operator"
               )
    end

    test "is deleted by the operator's owner", ctx do
      {:ok, provider} =
        Connections.create_provider(ctx.operator.scope, provider_attrs("operator"))

      assert {:ok, _deleted} = Connections.delete_provider(ctx.operator.scope, provider)
      assert {:ok, []} = Connections.list_providers(ctx.operator.scope, "operator")
    end

    test "is refused to the people of a client", ctx do
      # On the operator's switch the client's people do not write providers at all; on the
      # default they do, but only the organisation's chain.
      for person <- [ctx.on.owner.scope, ctx.client_admin.scope] do
        assert {:error, :not_found} =
                 Connections.create_provider(person, provider_attrs("operator"))

        assert {:error, :not_found} = Connections.list_providers(person, "operator")
        assert {:error, _reason} = ModelChoices.put_choice(person, :organisation, %{}, "operator")
      end

      assert {:error, :forbidden} =
               Connections.create_provider(ctx.off.owner.scope, provider_attrs("operator"))

      assert {:error, :not_found} = Connections.list_providers(ctx.off.owner.scope, "operator")

      assert {:error, _reason} =
               ModelChoices.put_choice(ctx.off.owner.scope, :organisation, %{}, "operator")

      assert {:ok, []} = Connections.list_providers(ctx.off.owner.scope)
    end

    test "is refused to a person of the operator who acts in a client through their reach",
         ctx do
      assert {:operator, _membership} = ctx.on.scope.reach

      assert {:error, :forbidden} =
               Connections.create_provider(ctx.on.scope, provider_attrs("operator"))

      assert {:error, :not_found} = Connections.list_providers(ctx.on.scope, "operator")

      assert {:error, _reason} =
               ModelChoices.put_choice(ctx.on.scope, :organisation, %{}, "operator")
    end

    test "is refused to a member of the operator and to another operator's owner", ctx do
      member = in_operator(ctx, ctx.member)

      assert {:error, :forbidden} =
               Connections.create_provider(member, provider_attrs("operator"))

      assert {:error, :not_found} = Connections.list_providers(member, "operator")

      {:ok, theirs} = Connections.create_provider(ctx.elsewhere.scope, provider_attrs("operator"))

      assert {:ok, [only]} = Connections.list_providers(ctx.elsewhere.scope, "operator")
      assert only.public_id == theirs.public_id
      assert {:ok, []} = Connections.list_providers(ctx.operator.scope, "operator")
    end

    test "is refused to an instance admin who has no membership in the operator", ctx do
      scope = scope_in(ctx.instance_user, ctx.operator.organisation)

      assert {:error, :forbidden} = Connections.create_provider(scope, provider_attrs("operator"))
      assert {:error, :not_found} = Connections.list_providers(scope, "operator")
    end

    test "is refused to everyone with the flag off", ctx do
      Flags.put_operator_infrastructure(false)

      assert {:error, :forbidden} =
               Connections.create_provider(ctx.operator.scope, provider_attrs("operator"))

      assert {:error, :not_found} = Connections.list_providers(ctx.operator.scope, "operator")

      assert {:error, _reason} =
               ModelChoices.put_choice(ctx.operator.scope, :organisation, %{}, "operator")
    end

    test "leaves a provider of the organisation's chain in the operator as it is", ctx do
      assert {:ok, provider} =
               Connections.create_provider(ctx.operator.scope, provider_attrs("organisation"))

      assert provider.chain == "organisation"
      assert {:ok, [_one]} = Connections.list_providers(ctx.operator.scope)
      assert {:ok, []} = Connections.list_providers(ctx.operator.scope, "operator")
    end
  end

  describe "a drop" do
    test "sets the switch back to the organisation's, and the client resolves no operator",
         ctx do
      assert Tenants.model_chain_of(id(ctx.on)) == :operator
      assert Edition.operator_chain_organisation(id(ctx.on)) == ctx.operator.organisation.id

      # A drop is not offered while the operator owns its clients: it is done as before.
      Flags.put_operator_infrastructure(false)

      assert {:ok, _client} =
               Transfers.drop(ctx.operator.scope, id(ctx.on), ctx.on.organisation.name)

      Flags.put_operator_infrastructure(true)

      assert Tenants.model_chain_of(id(ctx.on)) == :organisation
      assert Edition.model_choice_chain(id(ctx.on)) == "organisation"
      assert Edition.operator_chain_organisation(id(ctx.on)) == nil
    end

    test "reads the organisation's switch for an organisation that is no client", ctx do
      assert Tenants.model_chain_of(ctx.operator.organisation.id) == :organisation
      assert Tenants.model_chain_of(sign_up_fixture().organisation.id) == :organisation
    end
  end
end
