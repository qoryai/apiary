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

  defp key_share!(id) do
    Repo.query!("SELECT id FROM organisations WHERE id = $1 FOR KEY SHARE", [dump(id)])
    :ok
  end

  # Each retry of lock_organisations/2, said to the test as `{:retried, pid}`.
  defp report_retries do
    handler = "lock-organisations-retries-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ "ROLLBACK TO SAVEPOINT apiary_lock_organisations",
          do: send(test, {:retried, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Each lock statement of lock_organisations/2, said to the test as `{:statement, pid}`.
  defp report_statements do
    handler = "lock-organisations-statements-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ "WITH ORDINALITY", do: send(test, {:statement, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
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

  describe "a write's organisation rows, FOR SHARE, against a change in a stale order" do
    test "the write is refused once as a deadlock, reads again and holds them" do
      classifying()
      %{scope: scope, organisation: %{id: x}} = sign_up()
      %{organisation: %{id: y}} = sign_up()
      :ok = report_retries()

      # The change reads that y names x, and so locks y first; it pauses once it has.
      Classifies.holds(y, [x])
      Classifies.pause_at([2])
      change = locking([x, y], :update)
      assert_receive {:classified, reader}, 10_000

      # Changed meanwhile: x names y now, and the write takes x first, then y.
      Classifies.holds(y, [])
      Classifies.holds(x, [y])

      # A row that only names x holds it FOR KEY SHARE: the change, y locked, waits on it
      # for x; the write's FOR SHARE of x does not.
      {names, names_backend} = hold(fn -> key_share!(x) end)
      send(reader, :go)
      await_blocked(change.backend, names_backend)

      write = start(fn -> Repo.transaction(fn -> Apiary.Access.lock_organisations(scope) end) end)
      await_waited(write.backend, change.backend)

      # Let go, the change waits on the write's x, and the write on the change's y: Postgres
      # refuses the write, which has waited longer, and it reads again.
      commit(names)

      assert {:ok, {:ok, [^y, ^x]}} = Task.await(change.task)
      assert {:ok, :ok} = Task.await(write.task)
      assert_received {:retried, pid} when pid == write.task.pid
      refute_received {:retried, _pid}
    end
  end

  describe "a write's organisation rows, what the edition names changed before the lock" do
    test "it lets go of the stale set and holds the fresh one, taken in one statement" do
      classifying()
      %{scope: scope, organisation: %{id: x}} = sign_up()
      [stale, fresh] = organisations(2)
      :ok = report_statements()

      # The write reads, without a lock, that x names `stale`; asked after, it names
      # `fresh`, as if that changed between the read and the lock.
      Classifies.answers(x, [[stale], [fresh]])
      {held, _backend} = hold(fn -> Apiary.Access.lock_organisations(scope) end)
      assert held.result == :ok

      # The stale one is let go of; x and the fresh one are held, FOR SHARE.
      assert free?(stale, "FOR NO KEY UPDATE")
      refute free?(x, "FOR NO KEY UPDATE")
      refute free?(fresh, "FOR NO KEY UPDATE")
      assert free?(fresh, "FOR SHARE")

      # Two attempts, each one statement: the stale set, let go of, then the fresh one.
      assert_received {:statement, pid} when pid == held.pid
      assert_received {:statement, ^pid}
      refute_received {:statement, _pid}
      commit(held)
    end

    test "what the edition names changes on every attempt: it gives up after three" do
      classifying()
      %{scope: scope, organisation: %{id: x}} = sign_up()
      Classifies.shifting(x)
      :ok = report_statements()

      {held, _backend} =
        hold(fn ->
          try do
            Apiary.Access.lock_organisations(scope)
          rescue
            error in RuntimeError -> {:raised, error.message}
          end
        end)

      assert {:raised, message} = held.result
      assert message =~ "changed on each of 3 attempts"

      # Three statements, and nothing held after: the transaction goes on, and commits.
      for _attempt <- 1..3, do: assert_received({:statement, _pid})
      refute_received {:statement, _pid}
      assert free?(x, "FOR UPDATE")
      commit(held)
    end
  end
end
