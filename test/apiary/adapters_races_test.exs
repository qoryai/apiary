defmodule Apiary.AdaptersRacesTest do
  # A pool naming its adapter and the adapter's deletion, racing. Each side runs on a
  # connection of its own, outside the SQL sandbox, so each commits and each waits on the
  # other's locks as it would in production. Not async: what these tests commit is visible
  # to every other test while they run, and they delete it again before they end.
  #
  # The rule under test (`20261015131100_let_a_pool_be_served_by_an_adapter`): the trigger
  # `nodes_served_by_is_an_adapter` holds the adapter's row `FOR SHARE` for the rest of the
  # transaction that names it, and `Apiary.Adapters.delete_adapter/2` holds it `FOR UPDATE`
  # before it clears the pools the adapter serves. So the deletion either waits for the
  # pool's change and then clears it, or comes first and the pool's change, which waits for
  # it, finds the adapter deleted and is refused.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Adapters, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup_all :clean_up_leftovers
  setup :setup_races

  defp serve(pool, adapter),
    do: Repo.update_all(from(n in Node, where: n.id == ^pool.id), set: [served_by_id: adapter.id])

  test "a pool's adapter named first: the adapter's deletion waits, then clears the pool" do
    %{scope: scope} = sign_up()
    adapter = adapter_fixture(scope, name: "Acme tracker")
    pool = pool_fixture(scope, name: "spot-runners")

    {first, first_pid} = hold(fn -> serve(pool, adapter) end)
    assert {1, nil} = first.result

    second = start(fn -> Adapters.delete_adapter(scope, adapter) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Node{deleted_at: %DateTime{}}} = Task.await(second.task)
    assert Repo.get!(Node, pool.id).served_by_id == nil

    assert %Entry{details: details} =
             Repo.one!(
               from e in Entry,
                 where:
                   e.action == "adapter.delete" and e.organisation_id == ^adapter.organisation_id
             )

    assert details["unserved_pool_ids"] == [pool.public_id]
  end

  test "the adapter's deletion first: the pool's change waits, then is refused" do
    %{scope: scope} = sign_up()
    adapter = adapter_fixture(scope, name: "Acme tracker")
    pool = pool_fixture(scope, name: "spot-runners")

    {first, first_pid} = hold(fn -> Adapters.delete_adapter(scope, adapter) end)
    assert {:ok, %Node{}} = first.result

    second =
      start(fn ->
        try do
          serve(pool, adapter)
        rescue
          error in Postgrex.Error -> {:error, error.postgres.constraint}
        end
      end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, "nodes_served_by_is_an_adapter"}
    assert Repo.get!(Node, pool.id).served_by_id == nil
  end
end
