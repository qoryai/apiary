defmodule Apiary.Repo.Migrations.IndexARunSRunCode do
  use Ecto.Migration

  # A run code's hash names one run (`Apiary.Runs.RunCode`): unique, and partial, so the
  # runs without a code stay out of it.
  #
  # Concurrently, since `runs` holds every run: outside a transaction and without the
  # migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create unique_index(:runs, [:run_code_sha256],
             where: "run_code_sha256 IS NOT NULL",
             name: :runs_run_code_sha256_index,
             concurrently: true
           )
  end
end
