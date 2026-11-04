defmodule Apiary.Dispatches.LostRunQuestionsMigrationTest do
  # The migration that lets a run of the queue ended `lost` keep the outcome `questions`
  # (`KeepTheQuestionsOfALostRun`), run down and up again inside the test's transaction,
  # which rolls it all back: up, the check takes `questions` and no other outcome on a
  # lost run; down, it takes none, and down refuses while a lost run has an outcome. It
  # changes `dispatch_runs` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn
  # that an older migration ran after a newer one. The log is kept from the output and
  # shown only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  @version 20_261_104_090_000
  @migration Apiary.Repo.Migrations.KeepTheQuestionsOfALostRun
  @options [log: false, migration_lock: false]
  @check "dispatch_runs_result_outcome_check"

  @refusal "Set result_outcome to NULL on the runs of the queue ended lost, then roll back " <>
             "again: the check before this migration refuses an outcome on them"

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_the_questions_of_a_lost_run.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{dispatch_run: run} = explore_run_fixture(work_item_fixture(scope), registered: false)
    %{run: run}
  end

  # The run ended lost with `outcome`, nil for none: the update's row count, or the
  # check's refusal raised.
  defp lost!(run, outcome) do
    %{num_rows: count} =
      Repo.query!(
        "UPDATE dispatch_runs SET state = 'ended', end_cause = 'lost', result_outcome = $2 " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(run.id), outcome]
      )

    count
  end

  defp refused?(run, outcome) do
    assert_raise Postgrex.Error, ~r/#{@check}/, fn -> lost!(run, outcome) end
    true
  end

  test "up takes questions alone on a lost run; down takes no outcome; up again takes it", %{
    run: run
  } do
    # Up, as every test runs.
    assert lost!(run, "questions") == 1
    assert refused?(run, "proposal")
    assert lost!(run, nil) == 1

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert refused?(run, "questions")
    assert lost!(run, nil) == 1

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    assert lost!(run, "questions") == 1
    assert refused?(run, "none")
  end

  test "down refuses while a lost run has an outcome, and keeps the check and the row", %{
    run: run
  } do
    assert lost!(run, "questions") == 1

    # The migration's transaction, a savepoint of the test's, is rolled back.
    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.down(Repo, @version, @migration, @options)
      end

    assert %Postgrex.Error{postgres: %{code: :check_violation}} = error
    assert error.postgres.message == @refusal

    assert %{rows: [["questions"]]} =
             Repo.query!("SELECT result_outcome FROM dispatch_runs WHERE id = $1", [
               Ecto.UUID.dump!(run.id)
             ])

    # The check of after the migration stays: a lost run still takes questions.
    assert lost!(run, "questions") == 1
  end
end
