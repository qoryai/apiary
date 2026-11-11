defmodule Apiary.RetentionJobTest do
  @moduledoc """
  `Apiary.Retention.prune_all/1`: which workspaces it visits, the isolation of what it
  records, and the log line. Not async: the job takes an advisory lock on the database,
  one for every test that runs it, so two of these at once would find each other's lock.
  """
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Retention
  alias Apiary.Retention.RetentionRun
  alias Apiary.Runs.{Delivery, Event, LogChunk, Projector, Run, SessionChunk}
  alias Apiary.WorkItems.WorkItem

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
      workspace_id: run.workspace_id,
      access_key_id: key_id(scope),
      node_delivery_id: Ecto.UUID.generate(),
      node_run_id: run.node_run_id,
      received_at: days_ago(days),
      event_count: 15,
      inserted_count: 15,
      status: 202
    })

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [last_event_at: days_ago(days), event_count: 15]
    )

    Repo.get!(Run, run.id)
  end

  defp key_id(scope) do
    %{access_key: %{id: id}} = access_key_fixture(scope)
    id
  end

  defp retain(scope, attrs) do
    {:ok, workspace} = Retention.update_retention(scope, Map.new(attrs))
    %{scope | workspace: workspace}
  end

  defp count(schema, run),
    do: Repo.aggregate(from(s in schema, where: s.run_id == ^run.id), :count)

  describe "prune_all/1" do
    test "a workspace without a setting loses nothing", %{scope: scope} do
      run = old_run(scope, 4000)
      assert {:ok, []} = Retention.prune_all(now: @now)
      assert count(Event, run) == 15
      assert Repo.aggregate(RetentionRun, :count) == 0
    end
  end

  describe "a session's transcript" do
    @describetag needs: [:factory]

    defp chunk!(run) do
      Repo.insert!(%SessionChunk{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        run_id: run.id,
        sequence: 1,
        session: 1,
        session_id: "5f2c9a1e",
        path: "~/.claude/projects/-workspace/5f2c9a1e.jsonl",
        offset: 0,
        bytes: "{}\n"
      })
    end

    defp chunks(run),
      do: Repo.aggregate(from(c in SessionChunk, where: c.run_id == ^run.id), :count)

    defp handed_over_run(scope) do
      pool = pool_fixture(scope)
      %{access_key: key} = enrolled_key_fixture(scope, pool)
      handed_over_fixture(scope, key)
    end

    test "goes once its work item is closed, or its run of no work item ended", %{
      scope: scope
    } do
      %{run: exploring} = handed_over_run(scope)
      %{run: closed, dispatch_run: dispatch_run} = handed_over_run(scope)
      ended = run_fixture(scope, %{state: "completed"})
      alive = run_fixture(scope)
      Enum.each([exploring, closed, ended, alive], &chunk!/1)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^dispatch_run.work_item_id),
          set: [state: :closed, closed_at: @now]
        )

      assert {:ok, _results} = Retention.prune_all(now: @now, dry_run: true)
      assert Enum.map([exploring, closed, ended, alive], &chunks/1) == [1, 1, 1, 1]

      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
      log = capture_log([level: :info], fn -> Retention.prune_all(now: @now) end)

      assert Enum.map([exploring, closed, ended, alive], &chunks/1) == [1, 0, 0, 1]
      assert log =~ "retention pruned transcripts=2"
      refute log =~ "{}"
    end

    test "stays in a workspace or an organisation marked for deletion", %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      %{scope: third} = sign_up_fixture()
      marked = run_fixture(scope, %{state: "completed"})
      in_marked_organisation = run_fixture(other, %{state: "completed"})
      kept_out = run_fixture(third, %{state: "completed"})
      Enum.each([marked, in_marked_organisation, kept_out], &chunk!/1)

      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Organisations.Workspace, where: h.id == ^scope.workspace.id),
          set: [deletion_marked_at: @now, purge_after: @now, purge_trigger: "grace_period"]
        )

      {1, _rows} =
        Repo.update_all(
          from(o in Apiary.Organisations.Organisation, where: o.id == ^other.organisation.id),
          set: [deletion_marked_at: @now, purge_after: @now, purge_trigger: "grace_period"]
        )

      assert {:ok, _results} = Retention.prune_all(now: @now)
      assert Enum.map([marked, in_marked_organisation, kept_out], &chunks/1) == [1, 1, 0]
    end

    test "stays while its work item explores, when a phase deletes the run's events", %{
      scope: scope
    } do
      %{run: run} = handed_over_run(scope)
      events_fixture(run, record())
      {:ok, _run} = Projector.project(run)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id),
          set: [state: "paused", last_event_at: days_ago(4000), event_count: 15]
        )

      chunk!(run)
      retain(scope, events_retention_days: 10)

      assert {:ok, [_]} = Retention.prune_all(now: @now)
      assert count(Event, run) == 0
      assert chunks(run) == 1
    end
  end

  describe "a node's instances" do
    test "go when the pages no longer show them, whatever the workspace's setting", %{
      scope: scope
    } do
      pool = pool_fixture(scope)
      gone = instance_fixture(pool, seen_at: days_ago(2))
      kept = instance_fixture(pool, seen_at: DateTime.add(@now, -3600, :second))

      assert {:ok, _results} = Retention.prune_all(now: @now, dry_run: true)
      assert Repo.get(Apiary.Nodes.Instance, gone.id)

      assert {:ok, []} = Retention.prune_all(now: @now)
      refute Repo.get(Apiary.Nodes.Instance, gone.id)
      assert Repo.get(Apiary.Nodes.Instance, kept.id)
    end
  end

  describe "isolation" do
    test "one workspace's setting prunes no run of another organisation", %{scope: scope} do
      scope = retain(scope, events_retention_days: 10)
      mine = old_run(scope, 50)
      other = scope_fixture()
      theirs = old_run(other, 50)

      assert {:ok, [%{workspace_id: workspace_id, runs_pruned: 1}]} =
               Retention.prune_all(now: @now)

      assert workspace_id == scope.workspace.id

      assert count(Event, mine) == 0
      assert count(Event, theirs) == 15
      assert count(LogChunk, theirs) == 2
      assert Repo.get!(Run, theirs.id).events_pruned_at == nil
    end

    test "a retention run is listed to its own workspace only", %{scope: scope} do
      scope = retain(scope, events_retention_days: 10)
      other = retain(scope_fixture(), log_retention_days: 5)
      old_run(scope, 50)

      assert {:ok, [_, _]} = Retention.prune_all(now: @now)

      assert [%RetentionRun{} = mine] = Retention.list_retention_runs(scope)
      assert mine.workspace_id == scope.workspace.id
      assert mine.organisation_id == scope.organisation.id
      assert mine.trigger == "manual"
      assert mine.events_retention_days == 10
      assert mine.events_cutoff == days_ago(10)
      assert %{runs_pruned: 1, events_deleted: 15, log_bytes_deleted: 12, complete: true} = mine

      assert [%RetentionRun{runs_pruned: 0} = theirs] = Retention.list_retention_runs(other)
      assert theirs.workspace_id == other.workspace.id
    end
  end

  describe "the job" do
    test "the scheduled job leaves a workspace alone that was just pruned; a manual one does not",
         %{
           scope: scope
         } do
      retain(scope, events_retention_days: 10)

      assert {:ok, [_]} = Retention.prune_all(trigger: "schedule")
      assert {:ok, []} = Retention.prune_all(trigger: "schedule")
      assert {:ok, [_]} = Retention.prune_all(trigger: "manual")
    end
  end

  test "the job says what it pruned in one line per workspace" do
    scope = scope_fixture()
    {:ok, workspace} = Retention.update_retention(scope, %{events_retention_days: 10})
    old_run(scope, 50)

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log([level: :info], fn -> Retention.prune_all(now: @now) end)

    assert log =~ "retention pruned workspace=#{workspace.id} trigger=manual"
    assert log =~ "runs=1 events=15 log_chunks=2 log_bytes=12 deliveries=1"
    assert log =~ "complete=true"
    # Nothing of a run's data is in the line.
    refute log =~ "api.example.com"
  end
end
