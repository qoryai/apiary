defmodule Apiary.Runs.Event do
  @moduledoc """
  One event of a run, stored as received: the record everything else is
  projected from. `run_id` is the row of `runs`, not the subject; `node_event_id`
  is the event's id as the node gave it, `id` of the event on the wire; `sequence`
  is the ten-digit string of the wire as an integer; `data` is the event's
  `data` untouched, whatever its type. `node_instance_id` is the node's instance id of
  the request that delivered it, nil for one stored before it was kept or when it
  could not be kept (`Apiary.Nodes.Instance.instance_id?/1`). `projected_at` is
  null until the projector has folded the event.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "events" do
    field :sequence, :integer
    field :node_event_id, Ecto.UUID
    field :type, :string
    field :time, :utc_datetime_usec
    field :data, :map, default: %{}
    field :received_at, :utc_datetime_usec
    field :node_instance_id, :string
    field :projected_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
  end
end
