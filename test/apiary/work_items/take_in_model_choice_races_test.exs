defmodule Apiary.WorkItems.TakeInModelChoiceRacesTest do
  # A take in that sends a model choice, racing the deletion of the provider it names, in
  # each order. Each side runs on a separate connection, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async: what
  # these tests commit is visible to every other test while they run, and they delete it
  # again before they end, the adapter and the keys' public halves, which outlive an
  # organisation, by what they made.
  #
  # The rule under test (`Apiary.WorkItems.Moves`, `Apiary.ModelChoices`): a take in
  # locks the ticket's connection, its collection, the work item and the workspace's
  # counter, and then the provider's row `FOR KEY SHARE`; a deletion of the provider locks
  # no adapter connection, and takes the provider's row `FOR UPDATE`. So the two end, each
  # answered, with no deadlock. A take in that comes first is stored with its choice, and
  # a provider deleted after it leaves the choice saying a provider was chosen and is
  # gone. A deletion that comes first is seen by the take in, which is refused and makes
  # no work item.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, ModelChoices, Repo, WorkItems}
  alias Apiary.AccessKeys.{AccessKey, PublicKey}
  alias Apiary.Adapters.Connection, as: AdapterConnection
  alias Apiary.Connections.Connection
  alias Apiary.ModelChoices.TakeInChoice
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.WorkItems.WorkItem
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  @await 60_000

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    pool = pool_fixture(scope)
    %{pair: pair} = enrolled_key_fixture(scope, pool)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "x"}]
      })

    # Registered after the setup of `Apiary.Races`, so it runs before that one.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      Repo.delete_all(from c in AdapterConnection, where: c.adapter_id == ^connection.adapter_id)
      Repo.delete_all(from k in AccessKey, where: k.node_id == ^connection.adapter_id)
      Repo.delete_all(from n in Node, where: n.id == ^connection.adapter_id)
      Repo.delete_all(from p in PublicKey, where: p.public_key == ^pair.public_key)
      Sandbox.checkin(Repo)
    end)

    %{scope: scope, ticket: ticket, provider: provider}
  end

  defp take_in(ctx) do
    fn ->
      WorkItems.take_in(ctx.scope, ctx.ticket.public_id, %{
        model_choice: %{provider: ctx.provider.public_id, model: "claude-sonnet-5-5"}
      })
    end
  end

  defp delete_provider(ctx), do: fn -> Connections.delete_provider(ctx.scope, ctx.provider) end

  defp work_items(ctx),
    do: Repo.all(from w in WorkItem, where: w.organisation_id == ^ctx.scope.organisation.id)

  test "the take in first: the deletion waits, then removes the provider the choice names", ctx do
    {first, first_pid} = hold(take_in(ctx))
    assert {:ok, %WorkItem{id: id}} = first.result

    second = start(delete_provider(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Connection{}} = Task.await(second.task, @await)
    assert [%WorkItem{id: ^id}] = work_items(ctx)

    # The choice stays, saying a provider was chosen and is gone.
    assert %TakeInChoice{provider_chosen: true, connection_id: nil, model_id: "claude-sonnet-5-5"} =
             ModelChoices.take_in_choice(id, 1)
  end

  test "the deletion first: the take in waits, is refused, and makes no work item", ctx do
    {first, first_pid} = hold(delete_provider(ctx))
    assert {:ok, %Connection{}} = first.result

    second = start(take_in(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, {:model_choice, %Ecto.Changeset{errors: [provider: {"is invalid", _}]}}} =
             Task.await(second.task, @await)

    assert work_items(ctx) == []
    assert Repo.aggregate(TakeInChoice, :count) == 0

    # The ticket is still open: a take in with no choice goes on.
    assert {:ok, %WorkItem{}} = WorkItems.take_in(ctx.scope, ctx.ticket.public_id)
  end
end
