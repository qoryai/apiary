defmodule Apiary.AnswersTable do
  @moduledoc """
  The table `work_item_answers` back for a test of a migration that ran while the table
  existed: the migration that drops it (`DropWorkItemAnswers`) run down inside the
  test's transaction, which rolls it back as the test ends. Ecto warns that an older
  migration ran after a newer one; a test that calls `back!/0` captures the log.
  """

  @version 20_261_104_100_000
  @migration Apiary.Repo.Migrations.DropWorkItemAnswers

  @doc "Runs `DropWorkItemAnswers` down: the table back, empty."
  def back! do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_drop_work_item_answers.exs")
      |> Code.require_file()
    end

    :ok = Ecto.Migrator.down(Apiary.Repo, @version, @migration, log: false, migration_lock: false)
  end
end
