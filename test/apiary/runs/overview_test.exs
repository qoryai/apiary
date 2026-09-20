defmodule Apiary.Runs.OverviewTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs
  alias Apiary.Runs.Run

  @now ~U[2026-09-20 14:00:00.000000Z]

  setup do
    %{scope: scope_fixture(), other: scope_fixture()}
  end

  # A run placed `ago` seconds before @now in `state`, with what the overview counts.
  defp run(scope, ago, state, attrs \\ %{}) do
    at = DateTime.add(@now, -ago, :second)

    run_fixture(
      scope,
      Map.merge(
        %{state: state, started_at: at, inserted_at: at, last_heartbeat_at: at},
        Map.new(attrs)
      )
    )
  end

  defp day(days_ago), do: @now |> DateTime.to_date() |> Date.add(-days_ago)

  describe "day_facts/3" do
    test "one row per UTC day a run started, counted in the three families", %{
      scope: scope,
      other: other
    } do
      run(scope, 10, "running")
      run(scope, 20, "pending", %{started_at: nil})
      run(scope, 3600, "succeeded", %{denied_count: 2, cost_usd: Decimal.new("0.50")})
      run(scope, 2 * 86_400, "failed", %{denied_count: 1, cost_usd: Decimal.new("0.25")})
      run(scope, 2 * 86_400 + 60, "closed")
      # Just before the window: not counted.
      run(scope, 14 * 86_400 + 1, "succeeded")
      run(other, 10, "running")

      from = DateTime.add(@now, -14 * 86_400, :second)
      assert [older, today] = Runs.day_facts(scope, from)

      assert %{runs: 2, alive: 0, ended_well: 0, ended_badly: 2, denied: 1, costed: 1} = older
      assert older.day == day(2)
      assert Decimal.equal?(older.cost, Decimal.new("0.25"))

      assert %{runs: 3, alive: 2, ended_well: 1, ended_badly: 0, denied: 2, costed: 1} = today
      assert today.day == day(0)
      assert Decimal.equal?(today.cost, Decimal.new("0.50"))

      # Today alone, bounded above and below.
      start_of_day = DateTime.new!(day(0), ~T[00:00:00.000000], "Etc/UTC")
      assert [^today] = Runs.day_facts(scope, start_of_day, DateTime.add(@now, 3600, :second))

      # A day whose runs reported no cost has none, not zero.
      assert [%{cost: nil, costed: 0}] =
               Runs.day_facts(
                 scope,
                 DateTime.add(@now, -40, :second),
                 DateTime.add(@now, -5, :second)
               )
    end
  end

  describe "the alive, the last and the lost" do
    test "alive rows are the most recently started first, bounded", %{scope: scope, other: other} do
      old = run(scope, 300, "running")
      new = run(scope, 30, "running")
      pinged = run(scope, 10, "pending", %{started_at: nil})
      run(scope, 5, "succeeded")
      run(other, 1, "running")

      assert Enum.map(Runs.list_alive(scope), & &1.id) == [pinged.id, new.id, old.id]
      assert Enum.map(Runs.list_alive(scope, 2), & &1.id) == [pinged.id, new.id]
    end

    test "the last runs are by start, alive ones included", %{scope: scope} do
      first = run(scope, 300, "succeeded")
      second = run(scope, 30, "running")
      third = run(scope, 20, "failed")

      assert Enum.map(Runs.recent_runs(scope, 2), & &1.id) == [third.id, second.id]
      assert Enum.map(Runs.recent_runs(scope), & &1.id) == [third.id, second.id, first.id]
    end

    test "lost runs since a moment, the most recently lost first", %{scope: scope, other: other} do
      recent = run(scope, 3600, "lost", %{lost_at: DateTime.add(@now, -3000, :second)})
      older = run(scope, 86_400, "lost", %{lost_at: DateTime.add(@now, -80_000, :second)})
      run(scope, 8 * 86_400, "lost", %{lost_at: DateTime.add(@now, -8 * 86_400, :second)})
      run(scope, 10, "running")
      run(other, 10, "lost", %{lost_at: @now})

      since = DateTime.add(@now, -7 * 86_400, :second)
      assert Enum.map(Runs.lost_since(scope, since), & &1.id) == [recent.id, older.id]
      assert Enum.map(Runs.lost_since(scope, since, 1), & &1.id) == [recent.id]
    end
  end

  describe "hosts_by_key/3" do
    test "counts the distinct hosts of each key's runs in the window, naming the only one", %{
      scope: scope,
      other: other
    } do
      %{access_key: pool} = access_key_fixture(scope)
      %{access_key: laptop} = access_key_fixture(scope)
      %{access_key: idle} = access_key_fixture(scope)
      %{access_key: theirs} = access_key_fixture(other)

      for host <- ~w(ci-01 ci-02 ci-02 ci-03),
          do: run(scope, 600, "succeeded", %{access_key_id: pool.id, host: host})

      run(scope, 8 * 86_400, "succeeded", %{access_key_id: pool.id, host: "ci-old"})
      run(scope, 60, "running", %{access_key_id: laptop.id, host: "dev-laptop"})
      run(scope, 30, "pending", %{access_key_id: laptop.id, started_at: nil, host: nil})
      run(other, 30, "running", %{access_key_id: theirs.id, host: "elsewhere"})

      since = DateTime.add(@now, -7 * 86_400, :second)
      assert %{} = Runs.hosts_by_key(scope, [], since)

      assert Runs.hosts_by_key(scope, [pool.id, laptop.id, idle.id, theirs.id], since) == %{
               pool.id => %{count: 3, host: nil},
               laptop.id => %{count: 1, host: "dev-laptop"}
             }
    end
  end

  describe "last_runs_by_key/2" do
    test "one run per key, the most recently started, and only the hive's", %{
      scope: scope,
      other: other
    } do
      %{access_key: a} = access_key_fixture(scope)
      %{access_key: b} = access_key_fixture(scope)
      %{access_key: idle} = access_key_fixture(scope)
      %{access_key: theirs} = access_key_fixture(other)

      run(scope, 300, "succeeded", %{access_key_id: a.id})
      newest_a = run(scope, 30, "running", %{access_key_id: a.id})
      only_b = run(scope, 600, "failed", %{access_key_id: b.id})
      run(other, 1, "running", %{access_key_id: theirs.id})

      assert %{} = Runs.last_runs_by_key(scope, [])
      last = Runs.last_runs_by_key(scope, [a.id, b.id, idle.id, theirs.id])
      assert Map.keys(last) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert %Run{id: id} = last[a.id]
      assert id == newest_a.id
      assert last[b.id].id == only_b.id
    end
  end
end
