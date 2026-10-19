defmodule Apiary.Repo.Migrations.DropARunSQuietPeriod do
  use Ecto.Migration

  # A run no longer keeps the quiet period of an exit with the reason `quiet`,
  # `runs.quiet_seconds`: Forager writes neither the reason nor the period, and the fold no
  # longer reads the period. An exit stored with one keeps it in its event's data.
  def up do
    alter table(:runs) do
      remove :quiet_seconds
    end
  end

  # Rolled back, the column is back and NULL on every row; a rebuild of a run
  # (`Apiary.Runs.Projector.rebuild/1`) under the code of before folds it from the exit again.
  def down do
    alter table(:runs) do
      add :quiet_seconds, :integer
    end
  end
end
