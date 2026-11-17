defmodule Apiary.Stages.Departure do
  # A stage that a person's entry into an earlier stage left (`Apiary.Stages`): the stage
  # (`stage_id`), the take in, when the work item had last entered the stage (`entered_at`,
  # nil for a work item placed before that was kept) and when it left it (`inserted_at`).
  # `Apiary.Stages.inputs/1` reads the outputs the stage made in between. Nothing changes a
  # departure once it is written.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A stage that a move back left."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stage_departures" do
    field :stage_id, :string
    field :take_in, :integer
    field :entered_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
  end
end
