defmodule Apiary.Runs.LogChunk do
  @moduledoc """
  The decoded bytes of one `dev.qory.run.log` event, keyed by the event's
  sequence. `step` is the event's `step`: the chunk is a log line of the run's step with
  that number (`Apiary.Runs.Step`); nil outside every step. A projection: rebuilt from
  `events`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "log_chunks" do
    field :sequence, :integer
    field :stream, :string
    field :bytes, :binary
    field :step, :integer

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
  end
end
