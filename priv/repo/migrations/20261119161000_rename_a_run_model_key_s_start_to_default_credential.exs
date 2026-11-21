defmodule Apiary.Repo.Migrations.RenameARunModelKeySStartToDefaultCredential do
  use Ecto.Migration

  # The column `run_model_keys.start` is renamed `default_credential`: true on the run's
  # default model provider credential, at most one per run. The index that keeps it to one
  # per run is renamed too, and its condition is then on `default_credential`.
  def change do
    rename table(:run_model_keys), :start, to: :default_credential

    rename index(:run_model_keys, [:run_id], name: :run_model_keys_start_index),
      to: :run_model_keys_default_credential_index
  end
end
