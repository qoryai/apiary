defmodule Apiary.Dispatches.SharedAccessDiffersMigrationTest do
  # The migration of the end cause `shared_access_differs`, run down and up again inside
  # the test's transaction, which rolls it all back: up lets a run of the queue end
  # `shared_access_differs` with the outcome `error`, and its dispatch end with the
  # cause; down refuses while a row has the cause, then takes the cause away. It changes
  # `dispatch_runs` and `dispatches` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun}

  @version 20_261_118_130_200
  @migration Apiary.Repo.Migrations.EndARunWhoseSharedStageAccessDiffers

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_end_a_run_whose_shared_stage_access_differs.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp refused(pattern, fun), do: assert_raise(Postgrex.Error, pattern, fun)

  defp update!(table, id, assignments) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [Ecto.UUID.dump!(id)])
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{key: key} = handover_place_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)
    %{dispatch: dispatch, run: run} = dispatched!(key)
    %{run: run, dispatch: dispatch}
  end

  @ended "state = 'ended', end_cause = 'shared_access_differs'"

  test "up takes shared_access_differs with the outcome error, and on a dispatch", ctx do
    refused(~r/dispatch_runs_result_outcome_error_check/, fn ->
      update!("dispatch_runs", ctx.run.id, @ended)
    end)

    assert %{num_rows: 1} =
             update!("dispatch_runs", ctx.run.id, @ended <> ", result_outcome = 'error'")

    assert %DispatchRun{end_cause: :shared_access_differs, result_outcome: :error} =
             Repo.get!(DispatchRun, ctx.run.id)

    assert %{num_rows: 1} =
             update!(
               "dispatches",
               ctx.dispatch.id,
               "ended_at = now(), end_cause = 'shared_access_differs'"
             )

    assert %Dispatch{end_cause: :shared_access_differs} = Repo.get!(Dispatch, ctx.dispatch.id)
  end

  test "down refuses while a row has the cause, then takes the cause away", ctx do
    update!("dispatch_runs", ctx.run.id, @ended <> ", result_outcome = 'error'")

    refused(
      ~r/Delete the runs of the queue and dispatches ended shared_access_differs/,
      &down!/0
    )

    update!("dispatch_runs", ctx.run.id, "end_cause = 'released', result_outcome = NULL")

    update!(
      "dispatches",
      ctx.dispatch.id,
      "ended_at = now(), end_cause = 'shared_access_differs'"
    )

    refused(
      ~r/Delete the runs of the queue and dispatches ended shared_access_differs/,
      &down!/0
    )

    update!("dispatches", ctx.dispatch.id, "end_cause = 'released'")
    down!()

    refused(~r/dispatch_runs_end_cause_check/, fn ->
      update!("dispatch_runs", ctx.run.id, @ended <> ", result_outcome = 'error'")
    end)

    refused(~r/dispatches_end_cause_check/, fn ->
      update!("dispatches", ctx.dispatch.id, "end_cause = 'shared_access_differs'")
    end)

    # The causes before it keep the outcome error.
    assert %{num_rows: 1} =
             update!(
               "dispatch_runs",
               ctx.run.id,
               "end_cause = 'write_without_work_item', result_outcome = 'error'"
             )

    up!()

    assert %{num_rows: 1} =
             update!("dispatch_runs", ctx.run.id, @ended <> ", result_outcome = 'error'")
  end
end
