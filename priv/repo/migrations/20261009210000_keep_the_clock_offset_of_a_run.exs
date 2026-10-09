defmodule Apiary.Repo.Migrations.KeepTheClockOffsetOfARun do
  use Ecto.Migration

  # A run keeps its clock offset, `clock_offset_ms`: the smallest arrival less own time over
  # its heartbeats, and for a run a gateway opened its ping's, in milliseconds, NULL until
  # the first. Folded from the events (`Apiary.Runs.Fold`) like every other field; a
  # heartbeat counts by its own time corrected by it (`Apiary.Runs.Liveness`).
  def change do
    alter table(:runs) do
      add :clock_offset_ms, :bigint
    end
  end
end
