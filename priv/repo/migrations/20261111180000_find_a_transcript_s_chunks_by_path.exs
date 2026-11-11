defmodule Apiary.Repo.Migrations.FindATranscriptSChunksByPath do
  use Ecto.Migration

  # The chunks of one file of a run's transcript, in sequence order
  # (`Apiary.Runs.Transcript`, `Apiary.Runs.Projector`): each pass that stores chunks
  # reads the totals of their path and the last chunk up to the projected sequence, and
  # a restore reads the file in that order.
  def change do
    create index(:session_chunks, [:run_id, :path, :sequence])
  end
end
