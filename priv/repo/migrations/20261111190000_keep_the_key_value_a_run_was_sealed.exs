defmodule Apiary.Repo.Migrations.KeepTheKeyValueARunWasSealed do
  use Ecto.Migration

  # Which value of each model key a run has, so a report of a key's old value, from a run
  # that still has it, writes no state of the new value (`Apiary.ModelKeys.record/3`):
  #
  # - `secret_values.value_set_at`: when the value was last set, by this server's clock: at
  #   its insert, and at each new value. A rename leaves it as it is. Each row gets its
  #   `updated_at`, the latest time it may have been set.
  # - `model_key_copies`: one row per run and key that a gateway's secrets request sealed
  #   for the run (`Apiary.Runs.SecretsRequest`), with the `value_set_at` of the value it
  #   sealed last. Both go with the run and with the key (`ON DELETE CASCADE`); the index
  #   on `secret_value_id` serves the key's deletion. Nothing exists to fill: a run with no
  #   row of a key reads as having the value set before the run's row was written.
  #
  # Rolled back, the table and the column go.
  def up do
    alter table(:secret_values) do
      add :value_set_at, :utc_datetime_usec
    end

    execute("UPDATE secret_values SET value_set_at = updated_at")

    alter table(:secret_values) do
      modify :value_set_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create table(:model_key_copies, primary_key: false) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), primary_key: true

      add :secret_value_id,
          references(:secret_values, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :value_set_at, :utc_datetime_usec, null: false
    end

    create index(:model_key_copies, [:secret_value_id])
  end

  def down do
    drop table(:model_key_copies)

    alter table(:secret_values) do
      remove :value_set_at
    end
  end
end
