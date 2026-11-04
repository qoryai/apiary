defmodule Apiary.WorkItems.DropAnswersMigrationTest do
  # The migration that drops `work_item_answers` (`DropWorkItemAnswers`), run down and up
  # again inside the test's transaction, which rolls it all back: up, the table is gone;
  # down, it is back, empty, with the columns and the checks of before. It changes the
  # schema under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn
  # that an older migration ran after a newer one. The log is kept from the output and
  # shown only when a test fails.
  @moduletag :capture_log

  @version 20_261_104_100_000
  @migration Apiary.Repo.Migrations.DropWorkItemAnswers
  @options [log: false, migration_lock: false]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_drop_work_item_answers.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'work_item_answers'"
      )

    Map.new(rows, fn [name, nullable] -> {name, nullable} end)
  end

  # The table's constraints by name, but its NOT NULL ones, which `columns/0` shows.
  defp checks do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint " <>
          "WHERE conrelid = 'work_item_answers'::regclass AND contype <> 'n'"
      )

    rows |> List.flatten() |> Enum.sort()
  end

  test "up drops the table; down brings it back empty, as it was; up drops it again" do
    assert columns() == %{}

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert columns() == %{
             "id" => "NO",
             "organisation_id" => "NO",
             "workspace_id" => "NO",
             "work_item_id" => "NO",
             "take_in" => "NO",
             "attempt" => "NO",
             "position" => "NO",
             "question" => "YES",
             "answer" => "NO",
             "answered_by_id" => "YES",
             "answered_at" => "NO",
             "custom" => "YES",
             "proposal_version" => "YES",
             "done_version" => "YES",
             "done_at" => "YES"
           }

    assert checks() == [
             "work_item_answers_answer_check",
             "work_item_answers_answered_by_id_fkey",
             "work_item_answers_kind_check",
             "work_item_answers_organisation_id_fkey",
             "work_item_answers_pkey",
             "work_item_answers_question_check",
             "work_item_answers_run_check",
             "work_item_answers_work_item_id_fkey",
             "work_item_answers_workspace_id_fkey"
           ]

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM work_item_answers")

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)
    assert columns() == %{}
  end
end
