defmodule Apiary.Stages.Check do
  # The Exists checks of a stage that failed at the end of its sequence and started another
  # round of its last loop (`Apiary.Stages`): the round they started, and their gaps, one
  # line per output type that no version of the stage has. Nothing changes a check once it
  # is written.
  @moduledoc false
  use Ecto.Schema

  @typedoc "Failed checks that started a round."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stage_checks" do
    field :stage_id, :string
    field :round, :integer
    field :gaps, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :process_version, Apiary.Processes.Version
  end
end
