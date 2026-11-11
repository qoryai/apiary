defmodule Apiary.Runs.TranscriptPath do
  @moduledoc """
  What a run keeps of one path of its session's transcript (`Apiary.Runs.SessionChunk`),
  which the projection reads to decide whether it keeps a chunk (`Apiary.Runs.Projector`):
  `chunks` and `bytes`, the chunks it keeps of the path and their bytes;
  `checked_sequence`, the sequence up to which those chunks were checked for a gap, in
  sequence order; `next_offset`, the offset at which the next chunk after it has to
  start, the sum of the lengths of the chunks checked; and `gap`, whether a checked chunk
  did not start there. It goes with the run, and with its chunks (`Apiary.Retention`).
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  schema "transcript_paths" do
    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run, primary_key: true
    field :path, :string, primary_key: true
    field :chunks, :integer
    field :bytes, :integer
    field :checked_sequence, :integer
    field :next_offset, :integer
    field :gap, :boolean
  end
end
