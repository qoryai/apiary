defmodule Apiary.Runs.Event do
  @moduledoc """
  One event of a run, stored as received: the record everything else is
  projected from. `run_id` is the row of `runs`, not the subject; `sequence`
  is the ten-digit string of the wire as an integer; `data` is the event's
  `data` untouched, whatever its type. `projected_at` is null until the
  projector has folded the event.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "events" do
    field :sequence, :integer
    field :event_id, Ecto.UUID
    field :type, :string
    field :time, :utc_datetime_usec
    field :data, :map, default: %{}
    field :received_at, :utc_datetime_usec
    field :projected_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :run, Apiary.Runs.Run
  end
end
