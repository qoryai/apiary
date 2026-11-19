defmodule Apiary.Dispatches.SessionKeyMigrationTest do
  # The migration of the end cause `session_key_missing`, run down and up again inside the
  # test's transaction, which rolls it all back: up lets a run of the queue end with the
  # cause with the outcome `error`, and its dispatch end with it; down refuses while a row
  # has the cause, then takes it away. It changes `dispatch_runs` and `dispatches` under
  # every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun}

  @version 20_261_118_162_400
  @migration Apiary.Repo.Migrations.EndARunWhoseSessionHasNoKey
  @cause "session_key_missing"
  @refusal ~r/Delete the runs of the queue and dispatches ended session_key_missing, then roll back again/

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_end_a_run_whose_session_has_no_key.exs")
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

  defp ended, do: "state = 'ended', end_cause = '#{@cause}'"

  test "up takes session_key_missing with the outcome error, and on a dispatch", ctx do
    refused(~r/dispatch_runs_result_outcome_error_check/, fn ->
      update!("dispatch_runs", ctx.run.id, ended())
    end)

    assert %{num_rows: 1} =
             update!("dispatch_runs", ctx.run.id, ended() <> ", result_outcome = 'error'")

    assert %DispatchRun{result_outcome: :error, end_cause: :session_key_missing} =
             Repo.get!(DispatchRun, ctx.run.id)

    assert %{num_rows: 1} =
             update!("dispatches", ctx.dispatch.id, "ended_at = now(), end_cause = '#{@cause}'")

    assert Repo.get!(Dispatch, ctx.dispatch.id).end_cause == :session_key_missing
  end

  test "down refuses while a row has session_key_missing, then takes the cause away", ctx do
    update!("dispatch_runs", ctx.run.id, ended() <> ", result_outcome = 'error'")
    refused(@refusal, &down!/0)

    update!("dispatch_runs", ctx.run.id, "end_cause = 'released', result_outcome = NULL")
    update!("dispatches", ctx.dispatch.id, "ended_at = now(), end_cause = '#{@cause}'")
    refused(@refusal, &down!/0)

    update!("dispatches", ctx.dispatch.id, "end_cause = 'released'")
    down!()

    refused(~r/dispatch_runs_end_cause_check/, fn ->
      update!("dispatch_runs", ctx.run.id, ended() <> ", result_outcome = 'error'")
    end)

    refused(~r/dispatches_end_cause_check/, fn ->
      update!("dispatches", ctx.dispatch.id, "end_cause = '#{@cause}'")
    end)

    # The causes before it keep the outcome error.
    for cause <- ~w(model_choice_missing too_many_providers) do
      assert %{num_rows: 1} =
               update!(
                 "dispatch_runs",
                 ctx.run.id,
                 "end_cause = '#{cause}', result_outcome = 'error'"
               )
    end

    up!()

    assert %{num_rows: 1} =
             update!("dispatch_runs", ctx.run.id, ended() <> ", result_outcome = 'error'")
  end
end
