defmodule Apiary.RetentionTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Organisations.Hive
  alias Apiary.Retention
  alias Apiary.Retention.RetentionRun
  alias Apiary.Runs.{Connection, Delivery, Event, LogChunk, Projector, Rebuild, Run}

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

  defp log_events(run) do
    Repo.aggregate(
      from(e in Event, where: e.run_id == ^run.id and e.type == "ai.qory.run.log"),
      :count
    )
  end

  describe "the setting" do
    test "is unlimited by default", %{scope: scope} do
      assert %Hive{events_retention_days: nil, log_retention_days: nil} = scope.hive
    end

    test "an owner sets it, each on its own, and clears it", %{scope: scope} do
      assert {:ok, %Hive{events_retention_days: 90, log_retention_days: nil}} =
               Retention.update_retention(scope, %{"events_retention_days" => "90"})

      scope = retain(scope, log_retention_days: 30)
      assert scope.hive.log_retention_days == 30

      assert {:ok, %Hive{events_retention_days: nil, log_retention_days: 30}} =
               Retention.update_retention(scope, %{"events_retention_days" => ""})
    end

    test "a member does not", %{scope: scope} do
      %{scope: member} = member_fixture(scope)

      assert {:error, :unauthorized} =
               Retention.update_retention(member, %{log_retention_days: 7})

      assert Repo.get!(Hive, scope.hive.id).log_retention_days == nil
    end

    test "the bounds", %{scope: scope} do
      for days <- [0, -1, 3651, 1_000_000] do
        assert {:error, changeset} =
                 Retention.update_retention(scope, %{events_retention_days: days})

        assert %{events_retention_days: [message]} = errors_on(changeset)
        assert message =~ "between 1 and 3650"

        assert {:error, changeset} =
                 Retention.update_retention(scope, %{log_retention_days: days})

        assert %{log_retention_days: [_]} = errors_on(changeset)
      end

      assert {:error, changeset} = Retention.update_retention(scope, %{log_retention_days: "1.5"})
      assert %{log_retention_days: [_]} = errors_on(changeset)

      for days <- [1, 3650] do
        assert {:ok, _hive} =
                 Retention.update_retention(scope, %{
                   events_retention_days: days,
                   log_retention_days: days
                 })
      end
    end

    test "the database holds the bounds too", %{scope: scope} do
      assert_raise Postgrex.Error, ~r/hives_events_retention_days_check/, fn ->
        Repo.update_all(from(h in Hive, where: h.id == ^scope.hive.id),
          set: [events_retention_days: 0]
        )
      end
    end

    test "the log is not kept longer than the events", %{scope: scope} do
      assert {:error, changeset} =
               Retention.update_retention(scope, %{
                 events_retention_days: 30,
                 log_retention_days: 31
               })

      assert %{log_retention_days: [message]} = errors_on(changeset)
      assert message =~ "cannot be longer than the events are kept"
    end
  end

  describe "prune_hive/2" do
    test "a hive without a setting loses nothing", %{scope: scope} do
      run = old_run(scope, 4000)
      assert {:ok, []} = Retention.prune_all(now: @now)
      assert count(Event, run) == 14
      assert Repo.aggregate(RetentionRun, :count) == 0
    end

    test "past the log cut-off a run loses its log bytes and keeps its timeline", %{scope: scope} do
      scope = retain(scope, log_retention_days: 30)
      old = old_run(scope, 31)
      young = old_run(scope, 29)

      result = Retention.prune_hive(scope.hive, now: @now)

      assert %{
               runs_pruned: 1,
               events_deleted: 2,
               log_chunks_deleted: 2,
               log_bytes_deleted: 12,
               deliveries_deleted: 0,
               complete: true,
               events_cutoff: nil
             } = result

      assert result.log_cutoff == days_ago(30)

      assert count(LogChunk, old) == 0
      assert log_events(old) == 0
      assert count(Event, old) == 12
      assert %Run{log_pruned_at: %DateTime{}, events_pruned_at: nil} = Repo.get!(Run, old.id)

      assert count(LogChunk, young) == 2
      assert count(Event, young) == 14
      assert %Run{log_pruned_at: nil} = Repo.get!(Run, young.id)
    end

    test "past the events cut-off a run keeps its row, its counts and its connections", %{
      scope: scope
    } do
      scope = retain(scope, events_retention_days: 90)
      old = old_run(scope, 91)
      young = old_run(scope, 89)

      assert %{
               runs_pruned: 1,
               events_deleted: 14,
               log_chunks_deleted: 2,
               log_bytes_deleted: 12,
               deliveries_deleted: 1
             } = Retention.prune_hive(scope.hive, now: @now)

      assert count(Event, old) == 0
      assert count(LogChunk, old) == 0
      assert count(Connection, old) == 2

      pruned = Repo.get!(Run, old.id)
      assert %Run{events_pruned_at: %DateTime{}, log_pruned_at: %DateTime{}} = pruned

      kept = [
        :state,
        :runtime,
        :host,
        :repository,
        :task,
        :exit_code,
        :duration_ms,
        :denied_count
      ]

      assert Map.take(pruned, kept) == Map.take(old, kept)
      assert pruned.event_count == 14
      assert pruned.state == "exited"

      assert count(Event, young) == 14
      assert Repo.aggregate(from(d in Delivery, where: d.run_id == ^young.run_id), :count) == 1
    end

    test "both settings: the log first, the events later, nothing counted twice", %{scope: scope} do
      scope = retain(scope, events_retention_days: 90, log_retention_days: 30)
      _ancient = old_run(scope, 100)
      _middle = old_run(scope, 60)

      dry = Retention.prune_hive(scope.hive, now: @now, dry_run: true)
      wet = Retention.prune_hive(scope.hive, now: @now)

      counts = [:runs_pruned, :events_deleted, :log_chunks_deleted, :log_bytes_deleted]
      assert Map.take(dry, counts) == Map.take(wet, counts)

      assert %{runs_pruned: 2, events_deleted: 16, log_chunks_deleted: 4, log_bytes_deleted: 24} =
               wet

      # Again: nothing is left to do.
      assert %{runs_pruned: 0, events_deleted: 0} = Retention.prune_hive(scope.hive, now: @now)
    end

    test "a run that is alive is never pruned, however old", %{scope: scope} do
      scope = retain(scope, events_retention_days: 1)
      run = run_fixture(scope)
      events_fixture(run, Enum.take(record(), 9))
      {:ok, %Run{state: "running"}} = Projector.project(run)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [last_event_at: days_ago(50)])

      assert %{runs_pruned: 0} = Retention.prune_hive(scope.hive, now: @now)
      assert count(Event, run) == 9
    end

    test "deletes in batches, and a bound on the runs of one job leaves the rest for the next", %{
      scope: scope
    } do
      scope = retain(scope, events_retention_days: 10)
      runs = for days <- [40, 30, 20], do: old_run(scope, days)

      assert %{runs_pruned: 2, events_deleted: 28, complete: false} =
               Retention.prune_hive(scope.hive, now: @now, batch: 3, max_runs: 2)

      # Oldest first.
      assert [0, 0, 14] = Enum.map(runs, &count(Event, &1))

      assert %{runs_pruned: 1, complete: true} =
               Retention.prune_hive(scope.hive, now: @now, batch: 3, max_runs: 2)
    end

    test "a dry run deletes nothing and records nothing", %{scope: scope} do
      scope = retain(scope, events_retention_days: 10)
      run = old_run(scope, 11)

      assert {:ok, [%{runs_pruned: 1, events_deleted: 14, dry_run: true}]} =
               Retention.prune_all(now: @now, dry_run: true)

      assert count(Event, run) == 14
      assert Repo.get!(Run, run.id).events_pruned_at == nil
      assert Retention.list_retention_runs(scope) == []
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

  describe "rebuild on a pruned run" do
    test "keeps the projection of a run whose events are gone", %{scope: scope} do
      scope = retain(scope, events_retention_days: 10)
      run = old_run(scope, 50)
      Retention.prune_hive(scope.hive, now: @now)
      pruned = Repo.get!(Run, run.id)

      assert {:ok, kept} = Projector.rebuild(pruned)
      assert kept.state == "exited"
      assert Repo.get!(Run, run.id) == pruned
      assert count(Connection, run) == 2

      assert Rebuild.run(all: true) == %{rebuilt: 0, failed: 0}
      assert Repo.get!(Run, run.id) == pruned
      assert count(Connection, run) == 2
    end

    test "keeps the projection of a run retention is due to prune", %{scope: scope} do
      run = old_run(scope, 50)
      # The projector asks the database's clock, not the test's.
      long_ago = DateTime.add(DateTime.utc_now(), -50 * 86_400, :second)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [last_event_at: long_ago])
      # Half pruned, as a job that died would leave it, under a setting made since.
      Repo.delete_all(from e in Event, where: e.run_id == ^run.id and e.sequence < 8)

      Repo.update_all(from(h in Hive, where: h.id == ^scope.hive.id),
        set: [events_retention_days: 10]
      )

      assert {:ok, %Run{state: "exited"}} = Projector.rebuild(run)
      assert count(Connection, run) == 2
      assert Repo.get!(Run, run.id).denied_count == 1
    end

    test "rebuilds a run that lost only its log, without falling back over the gaps", %{
      scope: scope
    } do
      scope = retain(scope, log_retention_days: 10)
      run = old_run(scope, 50)
      Retention.prune_hive(scope.hive, now: @now)

      assert {:ok, rebuilt} = Projector.rebuild(Repo.get!(Run, run.id))
      assert rebuilt.state == "exited"
      assert rebuilt.projected_sequence == 14
      assert rebuilt.denied_count == 1
      assert %DateTime{} = rebuilt.log_pruned_at
      assert count(Connection, run) == 2
      assert count(LogChunk, run) == 0
    end
  end

  describe "Scheduler.until_next/3" do
    alias Apiary.Retention.Scheduler

    test "the next three o'clock, today or tomorrow, plus the jitter" do
      assert Scheduler.until_next(~U[2026-12-01 01:00:00Z], 3, 0) == 2 * 3_600_000
      assert Scheduler.until_next(~U[2026-12-01 03:00:00Z], 3, 0) == 24 * 3_600_000
      assert Scheduler.until_next(~U[2026-12-01 02:59:30Z], 3, 0) == 24 * 3_600_000 + 30_000
      assert Scheduler.until_next(~U[2026-12-01 23:00:00Z], 3, 60) == 4 * 3_600_000 + 60_000
    end
  end
end
