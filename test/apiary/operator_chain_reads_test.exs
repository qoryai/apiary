defmodule Apiary.OperatorChainReadsTest do
  # What a resolution reads of the choices of a run's chain (`Apiary.ModelChoices.choices_for/3`):
  # the organisation's chain at all levels of the run's organisation, and the operator's chain
  # from the operator's organisation at its default alone.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.EditionStubs.{ServesAcross, ServesAcrossWithChain}
  alias Apiary.ModelChoices.ModelChoice

  @moduletag needs: :factory

  @key "sk-chain-reads-0123456789"

  setup do
    %{scope: client} = sign_up_fixture()
    %{scope: operator} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()

    :ok = Apiary.Edition.put_test_stub(ServesAcrossWithChain)
    ServesAcross.put([{operator.organisation.id, client.organisation.id}])
    ServesAcrossWithChain.writer(true)

    %{client: client, operator: operator, other: other}
  end

  defp provider!(scope, chain) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        chain: chain,
        keys: [%{value_id: "main", value: @key}]
      })

    provider
  end

  defp choose!(scope, place, provider, chain, model) do
    attrs = %{provider: provider.public_id, key: "main", model: model}
    {:ok, %ModelChoice{} = choice} = ModelChoices.put_choice(scope, place, attrs, chain)
    choice
  end

  defp read(scope), do: ModelChoices.choices_for(scope.workspace, nil, nil)

  test "on the organisation's chain, reads the run's organisation and not the operator's", ctx do
    %{client: client, operator: operator} = ctx

    mine =
      choose!(
        client,
        :organisation,
        provider!(client, "organisation"),
        "organisation",
        "claude-haiku-5-5"
      )

    choose!(
      operator,
      :organisation,
      provider!(operator, "operator"),
      "operator",
      "claude-haiku-5-5"
    )

    assert [%ModelChoice{id: id}] = read(client).choices
    assert id == mine.id
  end

  test "on the operator's chain, reads the operator's default, not the client's rows", ctx do
    %{client: client, operator: operator} = ctx

    theirs =
      choose!(
        operator,
        :organisation,
        provider!(operator, "operator"),
        "operator",
        "claude-haiku-5-5"
      )

    own = provider!(client, "organisation")
    choose!(client, :organisation, own, "organisation", "claude-haiku-5-5")
    choose!(client, :workspace, own, "organisation", "claude-sonnet-5-5")
    ServesAcrossWithChain.chain("operator")

    assert %{choices: [%ModelChoice{id: id, chain: "operator"}], workspace_id: workspace_id} =
             read(client)

    assert id == theirs.id
    assert workspace_id == client.workspace.id
  end

  test "on the operator's chain, reads no row of another operator or of the organisation chain",
       ctx do
    %{client: client, operator: operator, other: other} = ctx
    choose!(other, :organisation, provider!(other, "operator"), "operator", "claude-haiku-5-5")

    choose!(
      operator,
      :organisation,
      provider!(operator, "organisation"),
      "organisation",
      "claude-haiku-5-5"
    )

    ServesAcrossWithChain.chain("operator")

    assert read(client).choices == []
  end

  test "on the operator's chain, reads no choice where the edition names no operator", ctx do
    %{client: client, operator: operator} = ctx

    choose!(
      operator,
      :organisation,
      provider!(operator, "operator"),
      "operator",
      "claude-haiku-5-5"
    )

    ServesAcrossWithChain.chain("operator")
    ServesAcrossWithChain.operator(nil)

    assert read(client).choices == []
  end
end
