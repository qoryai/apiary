defmodule ApiaryPro.ClientModelChainRefreshTest do
  # The model providers of a client's waiting runs after its operator changes the
  # client's switch (`ApiaryPro.Operators.set_model_chain/3`): set again from the new
  # chain once the change has committed (`Apiary.Dispatches.refresh_model_providers/1`),
  # and left as they are for the value the switch has already.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.WorkItemsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices}
  alias Apiary.Dispatches.DispatchRun
  alias ApiaryPro.{Flags, Operators}

  @moduletag with_features: Apiary.Features.all()

  # An operator and its client, made while the flag is off, then the flag on. Each has a
  # provider with one key, chosen at the organisation's default of its chain: the client's
  # in the chain "organisation", the operator's in the chain "operator". A run of a fresh
  # work item of the client's owner waits in the queue.
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)

    Flags.put_operator_infrastructure(true)

    client_provider = provider!(client.owner.scope, "organisation")
    operator_provider = provider!(operator.scope, "operator")

    work_item = work_item_fixture(client.owner.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    %{
      operator: operator,
      client: client,
      client_provider: client_provider,
      operator_provider: operator_provider,
      queued: queued
    }
  end

  # A provider of the scope's organisation in `chain`, with its choice at the
  # organisation's default of that chain.
  defp provider!(scope, chain) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        chain: chain,
        keys: [%{value_id: "main", value: "sk-ant-#{chain}-0123456789"}]
      })

    attrs = %{provider: provider.public_id}
    {:ok, _choice} = ModelChoices.put_choice(scope, :organisation, attrs, chain)

    provider
  end

  defp set(ctx, chain),
    do: Operators.set_model_chain(ctx.operator.scope, ctx.client.organisation.id, chain)

  defp row(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)

  defp provider_ids(run), do: row(run).model_provider_ids

  # The run with `ids` as its model providers, written straight to the row, not through
  # `Apiary.Dispatches`.
  defp providers!(%DispatchRun{id: id}, ids) do
    query = from r in DispatchRun, where: r.id == ^id
    {1, _rows} = Repo.update_all(query, set: [model_provider_ids: ids])

    :ok
  end

  test "a change of the switch sets the client's waiting run's providers again", ctx do
    assert ctx.queued.model_provider_ids == [ctx.client_provider.id]

    assert {:ok, _client} = set(ctx, :operator)
    assert provider_ids(ctx.queued) == [ctx.operator_provider.id]

    assert {:ok, _client} = set(ctx, :organisation)
    assert provider_ids(ctx.queued) == [ctx.client_provider.id]
  end

  test "the value the switch has already leaves the client's waiting run as it is", ctx do
    assert {:ok, _client} = set(ctx, :operator)
    assert provider_ids(ctx.queued) == [ctx.operator_provider.id]

    # The client's provider, of the chain before the change, which a refresh would
    # replace with the operator's.
    :ok = providers!(ctx.queued, [ctx.client_provider.id])
    before = row(ctx.queued)

    assert {:ok, _client} = set(ctx, :operator)
    assert row(ctx.queued) == before
  end
end
