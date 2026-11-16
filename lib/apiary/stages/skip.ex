defmodule Apiary.Stages.Skip do
  # A workflow entry of a stage, or a whole stage, that the stage runner passed over, with
  # no run, because a condition held it back (`Apiary.Stages.Runner`). The condition is
  # `{input: T}` (`input` is the type) or `{track: ID}` (`track` is the id): exactly one of
  # them is set. `negated` is true where the condition was an `unless` that was met; for a
  # `when`, the condition was not met. A stage passed over has no `workflow`, `stage_entry`
  # or `loop_entry`, and `round` 1. A workflow entry has the take in, its position and its
  # workflow. `after_attempt` is the newest attempt of the take in when the runner passed it
  # over (0 for none), which places it among the runs on the work item page. Nothing changes
  # a skip once it is written.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A workflow entry or a stage passed over."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stage_skips" do
    field :stage_id, :string
    field :take_in, :integer
    field :stage_entry, :integer
    field :loop_entry, :integer
    field :round, :integer
    field :workflow, :string
    field :input, :string
    field :track, :string
    field :negated, :boolean, default: false
    field :after_attempt, :integer
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :process_version, Apiary.Processes.Version
  end
end
