defmodule Apiary.RunsTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Runs

  setup do
    %{scope: scope_fixture(), other: scope_fixture()}
  end

  test "topics" do
    assert Runs.topic("h") == "runs:h"
    assert Runs.topic("h", "r") == "run:h:r"
  end

  describe "count_alive/1" do
    test "counts the pending and the running runs of the scope's workspace only", %{
      scope: scope,
      other: other
    } do
      for state <- ~w(pending running running completed failed cancelled lost) do
        run_fixture(scope, %{state: state})
      end

      run_fixture(other, %{state: "running"})

      assert Runs.count_alive(scope) == 3
      assert Runs.count_alive(other) == 1
    end

    test "counts a cancelling run that is lost and may still attach, as the Alive view lists it",
         %{scope: scope} do
      now = DateTime.utc_now()
      marked = %{cancel_requested_at: now}
      later = DateTime.add(now, 3600, :second)

      run_fixture(scope, Map.merge(marked, %{state: "lost", backstop_at: later}))
      run_fixture(scope, Map.merge(marked, %{state: "running"}))
      # Lost for good, and a cancelled run with its exit: neither is alive.
      run_fixture(scope, Map.merge(marked, %{state: "lost", silenced_at: now}))
      run_fixture(scope, Map.merge(marked, %{state: "cancelled", exit_state: "cancelled"}))
      run_fixture(scope, %{state: "lost", backstop_at: later})

      assert Runs.count_alive(scope) == 2

      assert Runs.view_counts(scope, Apiary.Runs.Filters.new()).alive == 2
    end
  end

  describe "list_alive/2" do
    test "lists the runs count_alive/1 counts, a lost cancelling run that may still attach among them",
         %{scope: scope} do
      now = DateTime.utc_now()
      marked = %{cancel_requested_at: now}
      later = DateTime.add(now, 3600, :second)

      lost = run_fixture(scope, Map.merge(marked, %{state: "lost", backstop_at: later}))
      running = run_fixture(scope, %{state: "running"})
      pending = run_fixture(scope, %{state: "pending"})
      run_fixture(scope, Map.merge(marked, %{state: "lost", silenced_at: now}))
      run_fixture(scope, %{state: "lost", backstop_at: later})
      run_fixture(scope, %{state: "completed"})

      listed = Runs.list_alive(scope, 10)

      assert Enum.sort(Enum.map(listed, & &1.id)) == Enum.sort([lost.id, running.id, pending.id])
      assert length(listed) == Runs.count_alive(scope)
      assert [%{state: "lost"} = run] = Enum.filter(listed, &(&1.id == lost.id))
      assert Apiary.Runs.Cancel.cancelling?(run)
    end
  end

  describe "get_run!/2 and list_runs/2" do
    test "a run of another workspace is not reachable", %{scope: scope, other: other} do
      run = run_fixture(scope)

      assert Runs.get_run!(scope, run.id).id == run.id
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(other, run.id) end
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(scope, "not-an-id") end
      assert Runs.list_runs(other) == []
    end

    test "newest first, limited", %{scope: scope} do
      now = DateTime.utc_now()

      [_oldest, middle, newest] =
        for age <- [30, 20, 10] do
          run_fixture(scope, %{inserted_at: DateTime.add(now, -age, :second)})
        end

      assert Enum.map(Runs.list_runs(scope, limit: 2), & &1.id) == [newest.id, middle.id]
      assert length(Runs.list_runs(scope)) == 3
    end
  end

  describe "last_heartbeats_by_key/1" do
    test "the workspace's keys that delivered a heartbeat, by id", %{scope: scope, other: other} do
      %{access_key: beating} = access_key_fixture(scope)
      %{access_key: silent} = access_key_fixture(scope)
      %{access_key: elsewhere} = access_key_fixture(other)
      at = ~U[2026-09-16 12:00:30.000000Z]

      Repo.update_all(from(k in AccessKey, where: k.id in ^[beating.id, elsewhere.id]),
        set: [last_heartbeat_at: at]
      )

      assert Runs.last_heartbeats_by_key(scope) == %{beating.id => at}
      refute Map.has_key?(Runs.last_heartbeats_by_key(scope), silent.id)
    end
  end
end
