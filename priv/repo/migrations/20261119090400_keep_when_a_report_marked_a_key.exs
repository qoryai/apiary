defmodule Apiary.Repo.Migrations.KeepWhenAReportMarkedAKey do
  use Ecto.Migration

  # When a report of the run marked the key as rejected by its provider
  # (`model_key_copies.marked_at`, `Apiary.ModelKeys.reject/3`): the database's UTC time
  # of the one mark a run makes of a key. A later report of the same key by the same run
  # marks nothing and moves nothing. The copy is one row per run and key, so the run has
  # one mark of each key, and a new run marks the key again.
  #
  # Nullable: no report has marked the key for the run. It changes no row.
  def change do
    alter table(:model_key_copies) do
      add :marked_at, :utc_datetime_usec
    end
  end
end
