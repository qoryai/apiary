defmodule Apiary.Dispatches.ResultOutcomeMigrationTest do
  # The migration that keeps what a run of the queue gave, run down and up again inside
  # the test's transaction, which rolls it all back: up sets `error` on the runs that are
  # not prebuilds and ended because their handover could not form them, and on no other,
  # then holds the checks; down takes the columns, the checks and the index away. It
  # changes `dispatch_runs` under every other test, so this is not async. The rows are
  # read and written in raw SQL, as the schema names the columns the migration takes away.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Environments}

  @moduletag needs: :factory

  @migration {20_261_019_001_000, Apiary.Repo.Migrations.KeepWhatARunOfTheQueueGave,
              "keep_what_a_run_of_the_queue_gave"}

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'dispatch_runs' AND column_name IN ('result_outcome', 'result') " <>
          "ORDER BY column_name"
      )

    List.flatten(rows)
  end

  defp index? do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM pg_indexes WHERE indexname = 'dispatch_runs_unsettled_index'")

    rows != []
  end

  defp checks do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conname LIKE 'dispatch_runs_result%' " <>
          "ORDER BY conname"
      )

    List.flatten(rows)
  end

  defp ended!(id, cause) do
    Repo.query!(
      "UPDATE dispatch_runs SET state = 'ended', end_cause = $2 WHERE id = $1",
      [Ecto.UUID.dump!(id), cause]
    )
  end

  defp outcome(id) do
    %{rows: [[outcome]]} =
      Repo.query!("SELECT result_outcome FROM dispatch_runs WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    outcome
  end

  test "up sets error on the runs their handover could not form, and holds the checks; down takes it all away" do
    %{scope: scope} = sign_up_fixture()
    _pool = pool_fixture(scope)
    collection = collection_fixture(scope)

    {:ok, [prebuild]} =
      Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

    queued = fn ->
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)
      run
    end

    [gone, invalid, variables, ended, released, waiting] = for _ <- 1..6, do: queued.()

    down!(@migration)
    assert columns() == []
    refute index?()
    assert checks() == []

    # Written as the release before this one wrote them.
    ended!(gone.id, "ticket_gone")
    ended!(invalid.id, "inputs_invalid")
    ended!(variables.id, "variables_invalid")
    ended!(ended.id, "run_ended")
    ended!(released.id, "released")
    ended!(prebuild.id, "inputs_invalid")

    up!(@migration)
    assert columns() == ["result", "result_outcome"]
    assert index?()

    assert checks() == [
             "dispatch_runs_result_check",
             "dispatch_runs_result_kept_check",
             "dispatch_runs_result_outcome_check",
             "dispatch_runs_result_outcome_error_check"
           ]

    for run <- [gone, invalid, variables], do: assert(outcome(run.id) == "error")
    for run <- [ended, released, waiting, prebuild], do: assert(outcome(run.id) == nil)

    # The checks hold from then on.
    for {id, assignments, constraint} <- [
          {gone.id, "result_outcome = NULL", "dispatch_runs_result_outcome_error_check"},
          {waiting.id, "result_outcome = 'none'", "dispatch_runs_result_outcome_check"},
          {prebuild.id, "result_outcome = 'error'", "dispatch_runs_result_outcome_check"},
          {ended.id, "result_outcome = 'none', result = '{}'", "dispatch_runs_result_kept_check"},
          {ended.id, "result_outcome = 'proposal', result = '[]'", "dispatch_runs_result_check"}
        ] do
      assert_raise Postgrex.Error, ~r/#{constraint}/, fn ->
        Repo.query!("UPDATE dispatch_runs SET #{assignments} WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])
      end
    end

    down!(@migration)
    assert columns() == []
    refute index?()
    assert checks() == []
  end
end
