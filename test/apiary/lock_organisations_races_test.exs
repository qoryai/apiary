defmodule Apiary.LockOrganisationsRacesTest do
  # Several organisations locked in one statement, in the lock order
  # (`Apiary.Organisations.lock_organisations/2`), against changes on connections of their
  # own, outside the SQL sandbox, so each commits and each waits on the other's locks as
  # it would in production. Which organisation names which (`places_to_lock/1`) is a table
  # the test changes while a change runs (`Apiary.EditionStubs.Classifies`). The order of
  # the two sides is forced: a side waits on a lock the other holds before the test goes
  # on (`pg_blocking_pids`), and where two are to wait on each other, the first has waited
  # half the server's `deadlock_timeout` before the second begins, so its check finds the
  # cycle first and Postgres refuses it (`await_waited/2`). Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  use ExUnit.Case, async: false

  import Apiary.Races

  alias Apiary.{Organisations, Repo}
  alias Apiary.EditionStubs.Classifies

  setup_all :clean_up_leftovers
  setup :setup_races

  # Fresh organisations, their ids in order.
  defp organisations(n),
    do: Enum.sort(for _ <- 1..n, do: sign_up().organisation.id)

  defp dump(id), do: Ecto.UUID.dump!(id)

  # The organisation's row, locked `FOR NO KEY UPDATE`, waiting for it.
  defp lock!(id) do
    Repo.query!("SELECT id FROM organisations WHERE id = $1 FOR NO KEY UPDATE", [dump(id)])
    :ok
  end

  # Whether the organisation's row is free to lock in `mode` now, without waiting.
  defp free?(id, mode) do
    case Repo.query("SELECT id FROM organisations WHERE id = $1 #{mode} NOWAIT", [dump(id)]) do
      {:ok, _result} -> true
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> false
    end
  end

  # lock_organisations/2 in a transaction of its own, which then reads once more, so a
  # transaction it left unusable would fail.
  defp locking(ids, mode) do
    start(fn ->
      Repo.transaction(fn ->
        result = Organisations.lock_organisations(ids, mode)
        Repo.query!("SELECT 1")
        result
      end)
    end)
  end

  defp classifying do
    :ok = Classifies.start()
    :ok = Apiary.Edition.put_test_stub(Classifies)
  end

  describe "the one statement" do
    test "locks in the lock order: by id with the core's edition" do
      :ok = Apiary.Edition.put_test_stub(Apiary.Edition.Core)
      [a, b, c] = organisations(3)
      {held, holder} = hold(fn -> lock!(b) end)

      locker = locking([c, b, a], :no_key_update)
      await_blocked(locker.backend, holder)

      # Waiting on b: a, before it, is locked, and c, after it, is not yet.
      refute free?(a, "FOR NO KEY UPDATE")
      assert free?(c, "FOR NO KEY UPDATE")

      commit(held)
      assert {:ok, {:ok, [^a, ^b, ^c]}} = Task.await(locker.task)
    end

    test "locks in the lock order: one that names another first" do
      classifying()
      [a, b, c] = organisations(3)
      Classifies.holds(b, [a])
      {held, holder} = hold(fn -> lock!(b) end)

      locker = locking([a, b, c], :no_key_update)
      await_blocked(locker.backend, holder)

      # Waiting on b, the first: nothing after it is locked yet.
      assert free?(a, "FOR NO KEY UPDATE")
      assert free?(c, "FOR NO KEY UPDATE")

      commit(held)
      assert {:ok, {:ok, [^b, ^a, ^c]}} = Task.await(locker.task)
    end

    test "takes each row in its own mode" do
      :ok = Apiary.Edition.put_test_stub(Apiary.Edition.Core)
      [a, b] = organisations(2)

      {held, _holder} =
        hold(fn ->
          Organisations.lock_organisations([a, b], &if(&1 == a, do: :share, else: :key_share))
        end)

      assert held.result == {:ok, [a, b]}
      assert free?(a, "FOR SHARE")
      refute free?(a, "FOR NO KEY UPDATE")
      assert free?(b, "FOR NO KEY UPDATE")
      refute free?(b, "FOR UPDATE")
      commit(held)
    end

    test "leaves out an organisation no longer there, and refuses outside a transaction" do
      :ok = Apiary.Edition.put_test_stub(Apiary.Edition.Core)
      [a] = organisations(1)

      assert {:ok, {:ok, [^a]}} =
               Repo.transaction(fn ->
                 Organisations.lock_organisations([Ecto.UUID.generate(), a], :share)
               end)

      assert_raise ArgumentError, fn -> Organisations.lock_organisations([a], :share) end
    end
  end

  describe "a classification that changes between the read and the lock" do
    test "refused once as a deadlock, it reads again and locks in the new order" do
      classifying()
      [lo, hi] = organisations(2)
      # hi names lo, so hi comes first; the change pauses once it has read that.
      Classifies.holds(hi, [lo])
      Classifies.pause_at([2])

      locker = locking([lo, hi], :no_key_update)
      assert_receive {:classified, reader}, 10_000

      # Changed meanwhile: lo names hi now, and a change that reads now locks lo first.
      Classifies.holds(hi, [])
      Classifies.holds(lo, [hi])
      {fresh, fresh_backend} = hold(fn -> lock!(lo) end)

      # The stale order: hi locked, then waiting on lo.
      send(reader, :go)
      await_waited(locker.backend, fresh_backend)

      # The fresh order: hi next, which the stale one holds. Each waits on the other, and
      # Postgres refuses the stale one, which has waited longer; it lets go of hi.
      assert :ok = continue(fresh, fn -> lock!(hi) end)

      # Read again: lo first, which the fresh change holds until it commits.
      await_blocked(locker.backend, fresh_backend)
      commit(fresh)

      assert {:ok, {:ok, [^lo, ^hi]}} = Task.await(locker.task)
    end

    test "refused twice, the second refusal is answered as it is" do
      classifying()
      [lo, hi] = organisations(2)
      Classifies.holds(hi, [lo])
      Classifies.pause_at([2, 4])

      locker = locking([lo, hi], :no_key_update)
      assert_receive {:classified, reader}, 10_000

      Classifies.holds(hi, [])
      Classifies.holds(lo, [hi])
      {first, first_backend} = hold(fn -> lock!(lo) end)
      send(reader, :go)
      await_waited(locker.backend, first_backend)
      assert :ok = continue(first, fn -> lock!(hi) end)

      # Read again, lo first; changed back before it locks, and again it waits on a change
      # that read the new order.
      assert_receive {:classified, ^reader}, 10_000
      commit(first)
      Classifies.holds(lo, [])
      Classifies.holds(hi, [lo])
      {second, second_backend} = hold(fn -> lock!(hi) end)
      send(reader, :go)
      await_waited(locker.backend, second_backend)
      assert :ok = continue(second, fn -> lock!(lo) end)
      commit(second)

      # The second refusal, answered; the rows it locked let go, its transaction usable.
      assert {:ok, {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}}} =
               Task.await(locker.task)
    end
  end
end
