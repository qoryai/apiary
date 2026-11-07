defmodule Apiary.Repo.Migrations.KeepWhatARunUsed do
  use Ecto.Migration

  # What a run used, measured over everything behind each session's wall:
  # `runs.peak_memory_bytes`, the highest peak memory that a session of the run reported
  # in its `dev.qory.session.exited`, in bytes; and `runs.cpu_time_ms`, the sum of the
  # CPU time those sessions reported, in milliseconds. Folded (`Apiary.Runs.Fold`), so a
  # rebuild sets them again; null while no session reported one. Adding columns that may
  # be empty, with no default, rewrites no row.
  def change do
    alter table(:runs) do
      add :peak_memory_bytes, :bigint
      add :cpu_time_ms, :bigint
    end
  end
end
