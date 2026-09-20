defmodule Apiary.Repo.Migrations.AddPrunedAtToRuns do
  use Ecto.Migration

  # Expand only. When retention deleted the run's events, and when it deleted the run's
  # log bytes; null on a run whose record is whole. Nullable without a default: instant.
  def change do
    alter table(:runs) do
      add :events_pruned_at, :utc_datetime_usec
      add :log_pruned_at, :utc_datetime_usec
    end
  end
end
