defmodule ApiaryPro.PeopleLockRacesTest do
  # The people locks (`ApiaryPro.Tenants.lock_people/2`) against other transactions, each
  # on a connection of its own, outside the SQL sandbox, so each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end.
  #
  # The rule under test: the rows are locked in the order of their ids, whatever order
  # they are given in, `FOR SHARE` or `FOR UPDATE`; a row held `FOR SHARE` keeps a
  # `FOR UPDATE` of it waiting until the holder commits, and lets another `FOR SHARE` by.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.Repo
  alias ApiaryPro.Tenants
  alias ApiaryPro.Tenants.PeopleLock

  setup_all :clean_up_leftovers
  setup :setup_races

  # Two organisations' ids, the lower first.
  setup do
    [low, high] = Enum.sort([sign_up().organisation.id, sign_up().organisation.id])
    %{low: low, high: high}
  end

  test "rows are locked in the order of their ids, whatever order they are given in",
       %{low: low, high: high} do
    # The higher row held, the lower free.
    {held, holder} = hold(fn -> Tenants.lock_people([high], :update) end)

    # Given the higher first, the second side takes the lower before it waits on the
    # higher.
    waiter =
      start(fn -> Repo.transaction(fn -> Tenants.lock_people([high, low, high], :update) end) end)

    await_blocked(waiter.backend, holder)

    # So the lower is taken already: a third connection may not have it.
    assert_raise Postgrex.Error, ~r/lock_not_available/, fn ->
      Repo.transaction(fn -> lock_now!(low, "FOR UPDATE NOWAIT") end)
    end

    commit(held)
    assert {:ok, :ok} = Task.await(waiter.task)
  end

  test "a row held for share keeps an update of it waiting, and lets a share by",
       %{low: low} do
    {held, holder} = hold(fn -> Tenants.lock_people([low], :share) end)

    # Another share is let by at once.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               lock_now!(low, "FOR SHARE NOWAIT")
               :ok
             end)

    waiter =
      start(fn ->
        Repo.transaction(fn -> Tenants.lock_people([low], :update) end)
      end)

    await_blocked(waiter.backend, holder)

    commit(held)
    assert {:ok, :ok} = Task.await(waiter.task)
  end

  test "a row held for update keeps another update of it waiting", %{low: low, high: high} do
    {held, holder} = hold(fn -> Tenants.lock_people([low, high], :update) end)

    waiter =
      start(fn ->
        Repo.transaction(fn -> lock_now!(high, "FOR UPDATE") end)
      end)

    await_blocked(waiter.backend, holder)

    commit(held)
    assert {:ok, [_id]} = Task.await(waiter.task)
  end

  # The people lock of the organisation `id`, locked in `mode` on this connection.
  defp lock_now!(id, mode) do
    query = from p in PeopleLock, where: p.organisation_id == ^id, select: p.organisation_id

    case mode do
      "FOR SHARE NOWAIT" -> Repo.all(lock(query, "FOR SHARE NOWAIT"))
      "FOR UPDATE NOWAIT" -> Repo.all(lock(query, "FOR UPDATE NOWAIT"))
      "FOR UPDATE" -> Repo.all(lock(query, "FOR UPDATE"))
    end
  end
end
