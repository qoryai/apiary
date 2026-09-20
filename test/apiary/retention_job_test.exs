defmodule Apiary.RetentionJobTest do
  @moduledoc """
  `Apiary.Retention.prune_all/1`: which hives it visits, the tenancy of what it records,
  and the log line. Not async: the job takes an advisory lock on the database, one for
  every test that runs it, so two of these at once would find each other's lock.
  """
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Retention
  alias Apiary.Retention.RetentionRun
  alias Apiary.Runs.{Delivery, Event, LogChunk, Projector, Run}

  @now ~U[2026-12-01 03:00:00.000000Z]

  setup do
    %{scope: scope_fixture()}
  end

  defp days_ago(days), do: DateTime.add(@now, -days * 86_400, :second)

  # A whole run of the synthetic record, projected, last heard from `days` days ago.
  defp old_run(scope, days) do
    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, run} = Projector.project(run)

    Repo.insert!(%Delivery{
      organisation_id: run.organisation_id,
      hive_id: run.hive_id,
      access_key_id: key_id(scope),
      delivery_id: Ecto.UUID.generate(),
      run_id: run.run_id,
      received_at: days_ago(days),
      event_count: 14,
      inserted_count: 14,
      status: 202
    })

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [last_event_at: days_ago(days), event_count: 14]
    )

    Repo.get!(Run, run.id)
  end

  defp key_id(scope) do
    %{access_key: %{id: id}} = access_key_fixture(scope)
    id
  end

  defp retain(scope, attrs) do
    {:ok, hive} = Retention.update_retention(scope, Map.new(attrs))
    %{scope | hive: hive}
  end

  defp count(schema, run),
    do: Repo.aggregate(from(s in schema, where: s.run_id == ^run.id), :count)

  describe "prune_all/1" do
    test "a hive without a setting loses nothing", %{scope: scope} do
      run = old_run(scope, 4000)
      assert {:ok, []} = Retention.prune_all(now: @now)
      assert count(Event, run) == 14
      assert Repo.aggregate(RetentionRun, :count) == 0
    end
  end

  describe "tenancy" do
    test "one hive's setting prunes no run of another organisation", %{scope: scope} do
      scope = retain(scope, events_retention_days: 10)
      mine = old_run(scope, 50)
      other = scope_fixture()
      theirs = old_run(other, 50)

      assert {:ok, [%{hive_id: hive_id, runs_pruned: 1}]} = Retention.prune_all(now: @now)
      assert hive_id == scope.hive.id

      assert count(Event, mine) == 0
      assert count(Event, theirs) == 14
      assert count(LogChunk, theirs) == 2
      assert Repo.get!(Run, theirs.id).events_pruned_at == nil
    end

    test "a retention run is listed to its own hive only", %{scope: scope} do
      scope = retain(scope, events_retention_days: 10)
      other = retain(scope_fixture(), log_retention_days: 5)
      old_run(scope, 50)

      assert {:ok, [_, _]} = Retention.prune_all(now: @now)

      assert [%RetentionRun{} = mine] = Retention.list_retention_runs(scope)
      assert mine.hive_id == scope.hive.id
      assert mine.organisation_id == scope.organisation.id
      assert mine.trigger == "manual"
      assert mine.events_retention_days == 10
      assert mine.events_cutoff == days_ago(10)
      assert %{runs_pruned: 1, events_deleted: 14, log_bytes_deleted: 12, complete: true} = mine

      assert [%RetentionRun{runs_pruned: 0} = theirs] = Retention.list_retention_runs(other)
      assert theirs.hive_id == other.hive.id
    end
  end

  describe "the job" do
    test "the scheduled job leaves a hive alone that was just pruned; a manual one does not", %{
      scope: scope
    } do
      retain(scope, events_retention_days: 10)

      assert {:ok, [_]} = Retention.prune_all(trigger: "schedule")
      assert {:ok, []} = Retention.prune_all(trigger: "schedule")
      assert {:ok, [_]} = Retention.prune_all(trigger: "manual")
    end
  end

  test "the job says what it pruned in one line per hive" do
    scope = scope_fixture()
    {:ok, hive} = Retention.update_retention(scope, %{events_retention_days: 10})
    old_run(scope, 50)

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log([level: :info], fn -> Retention.prune_all(now: @now) end)

    assert log =~ "retention pruned hive=#{hive.id} trigger=manual"
    assert log =~ "runs=1 events=14 log_chunks=2 log_bytes=12 deliveries=1"
    assert log =~ "complete=true"
    # Nothing of a run's data is in the line.
    refute log =~ "api.example.com"
  end
end
