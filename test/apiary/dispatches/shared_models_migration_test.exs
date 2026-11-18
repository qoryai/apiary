defmodule Apiary.Dispatches.SharedModelsMigrationTest do
  # The migration of the end causes `model_choice_missing` and `too_many_providers`, run
  # down and up again inside the test's transaction, which rolls it all back: up lets a
  # run of the queue end with either cause with the outcome `error`, and its dispatch end
  # with it; down refuses while a row has either cause, then takes both away. It changes
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

  @version 20_261_118_162_000
  @migration Apiary.Repo.Migrations.EndARunWhoseSharedStageModelsDoNotFit

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_end_a_run_whose_shared_stage_models_do_not_fit.exs")
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

  defp ended(cause), do: "state = 'ended', end_cause = '#{cause}'"

  for cause <- ~w(model_choice_missing too_many_providers) do
    test "up takes #{cause} with the outcome error, and on a dispatch", ctx do
      cause = unquote(cause)

      refused(~r/dispatch_runs_result_outcome_error_check/, fn ->
        update!("dispatch_runs", ctx.run.id, ended(cause))
      end)

      assert %{num_rows: 1} =
               update!("dispatch_runs", ctx.run.id, ended(cause) <> ", result_outcome = 'error'")

      assert %DispatchRun{result_outcome: :error} = run = Repo.get!(DispatchRun, ctx.run.id)
      assert run.end_cause == String.to_existing_atom(cause)

      assert %{num_rows: 1} =
               update!("dispatches", ctx.dispatch.id, "ended_at = now(), end_cause = '#{cause}'")

      assert Repo.get!(Dispatch, ctx.dispatch.id).end_cause == String.to_existing_atom(cause)
    end

    test "down refuses while a row has #{cause}, then takes the cause away", ctx do
      cause = unquote(cause)
      update!("dispatch_runs", ctx.run.id, ended(cause) <> ", result_outcome = 'error'")

      refused(
        ~r/Delete the runs of the queue and dispatches ended model_choice_missing or too_many_providers/,
        &down!/0
      )

      update!("dispatch_runs", ctx.run.id, "end_cause = 'released', result_outcome = NULL")
      update!("dispatches", ctx.dispatch.id, "ended_at = now(), end_cause = '#{cause}'")

      refused(
        ~r/Delete the runs of the queue and dispatches ended model_choice_missing or too_many_providers/,
        &down!/0
      )

      update!("dispatches", ctx.dispatch.id, "end_cause = 'released'")
      down!()

      refused(~r/dispatch_runs_end_cause_check/, fn ->
        update!("dispatch_runs", ctx.run.id, ended(cause) <> ", result_outcome = 'error'")
      end)

      refused(~r/dispatches_end_cause_check/, fn ->
        update!("dispatches", ctx.dispatch.id, "end_cause = '#{cause}'")
      end)

      # The causes before it keep the outcome error.
      assert %{num_rows: 1} =
               update!(
                 "dispatch_runs",
                 ctx.run.id,
                 "end_cause = 'shared_access_differs', result_outcome = 'error'"
               )

      up!()

      assert %{num_rows: 1} =
               update!("dispatch_runs", ctx.run.id, ended(cause) <> ", result_outcome = 'error'")
    end
  end
end
