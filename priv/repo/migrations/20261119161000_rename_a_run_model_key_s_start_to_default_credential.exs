defmodule Apiary.Repo.Migrations.RenameARunModelKeySStartToDefaultCredential do
  use Ecto.Migration

  # `run_model_keys.default_credential`, formerly `start`: true on the run's default model
  # provider credential, at most one per run. The index that keeps it to one per run moves
  # with it, its condition then on `default_credential`.
  def change do
    rename table(:run_model_keys), :start, to: :default_credential

    rename index(:run_model_keys, [:run_id], name: :run_model_keys_start_index),
      to: :run_model_keys_default_credential_index
  end
end
