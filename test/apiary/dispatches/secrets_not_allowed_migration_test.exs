defmodule Apiary.Dispatches.SecretsNotAllowedMigrationTest do
  # The migration of the end cause `secrets_not_allowed`, run down and up again inside the
  # test's transaction, which rolls it all back. It changes the tables under every other
  # test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun}

  @version 20_261_019_080_000
  @migration Apiary.Repo.Migrations.EndARunItsGatewayMayNotSealFor
  @name "end_a_run_its_gateway_may_not_seal_for"
  @options [log: false, migration_lock: false]

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_#{@name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{key: key} = handover_place_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)
    %{dispatch: dispatch, run: queued} = dispatched!(key)
    %{queued: queued, dispatch: dispatch}
  end

  # The run of the queue ended with `cause` and `outcome`, in a savepoint: :ok, or the
  # name of the check it broke.
  defp end_run(%DispatchRun{id: id}, cause, outcome) do
    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE dispatch_runs SET state = 'ended', end_cause = $2, result_outcome = $3 " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(id), cause, outcome]
      )
    end)

    :ok
  rescue
    error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
  end

  defp end_dispatch(%Dispatch{id: id}, cause) do
    Repo.transaction(fn ->
      Repo.query!("UPDATE dispatches SET ended_at = now(), end_cause = $2 WHERE id = $1", [
        Ecto.UUID.dump!(id),
        cause
      ])
    end)

    :ok
  rescue
    error in Postgrex.Error -> error.postgres[:constraint] || error.postgres.code
  end

  test "down takes the cause away, and up puts it back", ctx do
    assert :ok = end_run(ctx.queued, "secrets_not_allowed", "error")
    assert :ok = end_dispatch(ctx.dispatch, "secrets_not_allowed")

    # Back to a cause the roll back keeps, so it runs.
    assert :ok = end_run(ctx.queued, "model_gone", "error")
    assert :ok = end_dispatch(ctx.dispatch, "model_gone")

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert end_run(ctx.queued, "secrets_not_allowed", "error") ==
             "dispatch_runs_end_cause_check"

    assert end_dispatch(ctx.dispatch, "secrets_not_allowed") == "dispatches_end_cause_check"

    # The causes before it stay, each with its outcome.
    assert :ok = end_run(ctx.queued, "key_gone", "error")
    assert end_run(ctx.queued, "key_gone", nil) == "dispatch_runs_result_outcome_error_check"

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    assert :ok = end_run(ctx.queued, "secrets_not_allowed", "error")
    assert :ok = end_dispatch(ctx.dispatch, "secrets_not_allowed")

    assert %DispatchRun{end_cause: :secrets_not_allowed, result_outcome: :error} =
             Repo.get!(DispatchRun, ctx.queued.id)
  end

  test "the cause comes with the outcome error on a run that is not a prebuild", ctx do
    assert end_run(ctx.queued, "secrets_not_allowed", nil) ==
             "dispatch_runs_result_outcome_error_check"

    assert end_run(ctx.queued, "secrets_not_allowed", "none") ==
             "dispatch_runs_result_outcome_error_check"

    assert :ok = end_run(ctx.queued, "secrets_not_allowed", "error")
  end

  test "down refuses while a run of the queue ended for the cause", ctx do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^ctx.queued.id),
        set: [state: :ended, end_cause: :secrets_not_allowed, result_outcome: :error]
      )

    assert_raise Postgrex.Error, ~r/check_violation|violated/, fn ->
      Ecto.Migrator.down(Repo, @version, @migration, @options)
    end
  end

  test "down refuses while a dispatch ended for the cause", ctx do
    assert :ok = end_dispatch(ctx.dispatch, "secrets_not_allowed")

    assert_raise Postgrex.Error, ~r/check_violation|violated/, fn ->
      Ecto.Migrator.down(Repo, @version, @migration, @options)
    end
  end
end
