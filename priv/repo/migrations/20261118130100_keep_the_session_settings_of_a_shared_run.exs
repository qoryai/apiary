defmodule Apiary.Repo.Migrations.KeepTheSessionSettingsOfASharedRun do
  use Ecto.Migration

  # `runs.session_settings`: for a run of a stage with `shared_run: true`, the settings of
  # each workflow entry of the stage, those in a loop's body included, as the claim read
  # them (`Apiary.Stages.claim_sessions!/2`). A JSON object with one member per entry: the
  # key is the entry's place in the stage's sequence, such as `0`, or `2.1` for the second
  # entry of the loop at place 2; the value has `workflow`, `time_limit_minutes` and
  # `full_suite`. Each later session of the run reads its settings here, so a change to
  # the time limits after the claim changes nothing for the run. NULL for every other run.
  def change do
    alter table(:runs) do
      add :session_settings, :map
    end
  end
end
