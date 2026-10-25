defmodule Apiary.OperatorChainWritesTest do
  # The operator's chain of model providers and choices in the organisation that an
  # edition says a scope writes (`c:Apiary.Edition.operator_chain_writer?/1`): the core's
  # edition refuses every write to it, and the organisation's chain is not touched.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.EditionStubs.WritesOperatorChain
  alias Apiary.ModelChoices.ModelChoice

  @moduletag needs: :factory

  @model "claude-sonnet-5-5"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp anthropic(scope, chain \\ nil) do
    attrs = %{
      provider: "anthropic",
      keys: [%{value_id: "main", value: "sk-chain-test-0123456789"}]
    }

    attrs = if chain, do: Map.put(attrs, :chain, chain), else: attrs
    Connections.create_provider(scope, attrs)
  end

  defp choice_attrs(provider),
    do: %{provider: provider.public_id, key: "main", model: @model, effort: "high"}

  defp trail(id),
    do: Repo.all(from e in Entry, where: e.subject_id == ^id, order_by: [asc: e.inserted_at])

  describe "under the core's edition" do
    test "a provider of the operator's chain is refused", %{scope: scope} do
      assert anthropic(scope, "operator") == {:error, :forbidden}
      assert anthropic(scope, "other") == {:error, :forbidden}
      assert Repo.aggregate(Connection, :count) == 0

      assert Connections.list_providers(scope, "operator") == {:error, :not_found}
      assert Connections.get_provider(scope, "con_unknown", "operator") == {:error, :not_found}
    end

    test "a choice of the operator's chain is refused, and the organisation's is kept", %{
      scope: scope
    } do
      {:ok, provider} = anthropic(scope)
      {:ok, kept} = ModelChoices.put_choice(scope, :organisation, choice_attrs(provider))

      assert ModelChoices.put_choice(scope, :organisation, choice_attrs(provider), "operator") ==
               {:error, :not_found}

      assert ModelChoices.delete_choice(scope, :organisation, "operator") == {:error, :not_found}
      assert ModelChoices.list_choices(scope, "operator") == {:error, :not_found}

      assert {:ok, [%ModelChoice{id: id}]} = ModelChoices.list_choices(scope)
      assert id == kept.id
    end
  end

  describe "for a scope that writes the operator's chain" do
    setup %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(WritesOperatorChain)
      {:ok, own} = anthropic(scope)
      {:ok, operator} = anthropic(scope, "operator")
      %{own: own, operator: operator}
    end

    test "a provider is made on the operator's chain and listed apart", ctx do
      %{scope: scope, own: own, operator: operator} = ctx

      assert operator.chain == "operator"
      assert own.chain == "organisation"

      assert {:ok, [listed]} = Connections.list_providers(scope)
      assert listed.id == own.id
      assert {:ok, [listed]} = Connections.list_providers(scope, "operator")
      assert listed.id == operator.id

      assert {:ok, %Connection{id: id}} =
               Connections.get_provider(scope, operator.public_id, "operator")

      assert id == operator.id
      assert Connections.get_provider(scope, operator.public_id) == {:error, :not_found}
      assert Connections.get_provider(scope, own.public_id, "operator") == {:error, :not_found}
    end

    test "the audit entry of the write is in the scope's organisation", ctx do
      %{scope: scope, operator: operator} = ctx

      assert [entry] = trail(operator.id)
      assert entry.organisation_id == scope.organisation.id
      assert entry.details["change"] == "provider_created"
      assert entry.after["chain"] == "operator"
    end

    test "a provider of the operator's chain is changed and deleted", ctx do
      %{scope: scope, operator: operator} = ctx

      assert {:ok, %Connection{name: "Shared"}} =
               Connections.update_provider(scope, operator, %{name: "Shared"})

      assert {:ok, _deleted} = Connections.delete_provider(scope, operator)
      assert {:ok, []} = Connections.list_providers(scope, "operator")
    end

    test "a scope that is not a writer any more changes nothing", ctx do
      %{scope: scope, operator: operator} = ctx
      WritesOperatorChain.writer(false)

      assert Connections.update_provider(scope, operator, %{name: "Shared"}) ==
               {:error, :forbidden}

      assert Connections.delete_provider(scope, operator) == {:error, :forbidden}
      assert anthropic(scope, "operator") == {:error, :forbidden}
      assert Connections.list_providers(scope, "operator") == {:error, :not_found}
    end

    test "a choice of the operator's chain is set with a provider of that chain", ctx do
      %{scope: scope, own: own, operator: operator} = ctx

      assert {:ok, %ModelChoice{chain: "operator", workspace_id: nil} = choice} =
               ModelChoices.put_choice(scope, :organisation, choice_attrs(operator), "operator")

      assert choice.connection_id == operator.id
      assert [entry] = trail(choice.id)
      assert entry.organisation_id == scope.organisation.id
      assert entry.action == "provider.write"
      assert entry.details["change"] == "choice_set"

      # The organisation's default is another row: one per place and chain.
      assert {:ok, %ModelChoice{chain: "organisation"} = mine} =
               ModelChoices.put_choice(scope, :organisation, choice_attrs(own))

      assert mine.id != choice.id

      assert {:ok, [%ModelChoice{id: id}]} = ModelChoices.list_choices(scope)
      assert id == mine.id
      assert {:ok, [%ModelChoice{id: id}]} = ModelChoices.list_choices(scope, "operator")
      assert id == choice.id
    end

    test "a choice names a provider of the same chain only", ctx do
      %{scope: scope, own: own, operator: operator} = ctx

      assert {:error, changeset} =
               ModelChoices.put_choice(scope, :organisation, choice_attrs(own), "operator")

      assert errors_on(changeset).provider == ["is invalid"]

      assert {:error, changeset} =
               ModelChoices.put_choice(scope, :organisation, choice_attrs(operator))

      assert errors_on(changeset).provider == ["is invalid"]
    end

    test "the operator's chain has the organisation's default alone", ctx do
      %{scope: scope, operator: operator} = ctx

      for place <- [:workspace, {:workspace, "hello"}] do
        assert ModelChoices.put_choice(scope, place, choice_attrs(operator), "operator") ==
                 {:error, :not_found}
      end

      assert Repo.aggregate(ModelChoice, :count) == 0
    end

    test "a choice of the operator's chain is replaced and deleted, the other kept", ctx do
      %{scope: scope, own: own, operator: operator} = ctx
      {:ok, mine} = ModelChoices.put_choice(scope, :organisation, choice_attrs(own))

      {:ok, first} =
        ModelChoices.put_choice(scope, :organisation, choice_attrs(operator), "operator")

      assert {:ok, %ModelChoice{id: id, effort: "low"}} =
               ModelChoices.put_choice(
                 scope,
                 :organisation,
                 %{choice_attrs(operator) | effort: "low"},
                 "operator"
               )

      assert id == first.id

      assert {:ok, %ModelChoice{id: ^id}} =
               ModelChoices.delete_choice(scope, :organisation, "operator")

      assert ModelChoices.delete_choice(scope, :organisation, "operator") == {:error, :not_found}
      assert {:ok, [%ModelChoice{id: kept}]} = ModelChoices.list_choices(scope)
      assert kept == mine.id
    end

    test "a member without provider.write is refused whatever the edition says", ctx do
      %{scope: scope, operator: operator} = ctx
      %{scope: member} = member_fixture(scope)

      assert anthropic(member, "operator") == {:error, :forbidden}

      assert ModelChoices.put_choice(member, :organisation, choice_attrs(operator), "operator") ==
               {:error, :forbidden}

      assert ModelChoices.delete_choice(member, :organisation, "operator") ==
               {:error, :forbidden}

      assert Connections.update_provider(member, operator, %{name: "Shared"}) ==
               {:error, :forbidden}
    end
  end
end
