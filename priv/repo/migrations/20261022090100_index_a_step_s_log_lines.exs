defmodule Apiary.Repo.Migrations.IndexAStepSLogLines do
  use Ecto.Migration

  # The log lines of one step of a run, in sequence order (`Apiary.Runs.Record.step_log/4`):
  # partial, so the chunks outside every step, a session's output among them, stay out of
  # it.
  #
  # Concurrently, since `log_chunks` holds every byte of every run's log: outside a
  # transaction and without the migration lock, as Postgres requires.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:log_chunks, [:run_id, :step, :sequence],
             where: "step IS NOT NULL",
             name: :log_chunks_run_id_step_sequence_index,
             concurrently: true
           )
  end
end
