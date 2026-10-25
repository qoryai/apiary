defmodule Apiary.Dispatches.HarnessUnresolvedMigrationTest do
  # The migration that ends a run whose harness walk failed, run down and up again inside
  # the test's transaction, which rolls it all back: up lets a run of the queue end
  # `harness_unresolved` with the outcome `error` and its failure code as `end_detail`;
  # down refuses while a row has the cause, then takes the cause away. It changes
  # `dispatch_runs` and `dispatches` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.DispatchRun

  @version 20_261_025_150_100
  @migration Apiary.Repo.Migrations.EndARunWhoseHarnessWalkFailed

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_end_a_run_whose_harness_walk_failed.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp refused(pattern, fun), do: assert_raise(Postgrex.Error, pattern, fun)

  defp update!(id, assignments, params \\ []) do
    Repo.query!("UPDATE dispatch_runs SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)
    %{run: run}
  end

  @ended "state = 'ended', end_cause = 'harness_unresolved', end_detail = 'not_covered'"

  test "up takes harness_unresolved with the outcome error and a failure code", %{run: run} do
    refused(~r/dispatch_runs_result_outcome_error_check/, fn -> update!(run.id, @ended) end)

    assert %{num_rows: 1} = update!(run.id, @ended <> ", result_outcome = 'error'")

    assert %DispatchRun{end_cause: :harness_unresolved, end_detail: "not_covered"} =
             Repo.get!(DispatchRun, run.id)

    refused(~r/dispatch_runs_end_detail_check/, fn ->
      update!(run.id, "end_detail = 'Not a code'")
    end)
  end

  test "down refuses while a run has the cause, then takes the cause away", %{run: run} do
    update!(run.id, @ended <> ", result_outcome = 'error'")
    refused(~r/Delete the runs of the queue and dispatches ended harness_unresolved/, &down!/0)

    update!(run.id, "end_cause = 'released', end_detail = NULL, result_outcome = NULL")
    down!()

    refused(~r/dispatch_runs_end_cause_check/, fn ->
      update!(run.id, @ended <> ", result_outcome = 'error'")
    end)

    up!()
    assert %{num_rows: 1} = update!(run.id, @ended <> ", result_outcome = 'error'")
  end
end
