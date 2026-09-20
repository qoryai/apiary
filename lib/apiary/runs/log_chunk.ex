defmodule Apiary.Runs.LogChunk do
  @moduledoc """
  The decoded bytes of one `ai.qory.run.log` event, keyed by the event's
  sequence. A projection: rebuilt from `events`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "log_chunks" do
    field :sequence, :integer
    field :stream, :string
    field :bytes, :binary

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :run, Apiary.Runs.Run
  end
end
