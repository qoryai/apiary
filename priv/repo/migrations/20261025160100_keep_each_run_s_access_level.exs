defmodule Apiary.Repo.Migrations.KeepEachRunSAccessLevel do
  use Ecto.Migration

  # The access level of an explore run of the queue, which its harness walk writes
  # (`Apiary.Harnesses.Walk`): `run_harnesses.access_level`, text, not null, `read` or
  # `write`, `read` by default. The run's documents give it as the run's `access`. Every
  # row before this migration gets `read`, the level every run had until then.
  #
  # Rolled back, the column goes with its check.
  def change do
    alter table(:run_harnesses) do
      add :access_level, :text, null: false, default: "read"
    end

    create constraint(:run_harnesses, :run_harnesses_access_level_check,
             check: "access_level IN ('read', 'write')"
           )
  end
end
