defmodule Apiary.Stages.Escalation do
  # A stage of a work item that waits for a person (`Apiary.Stages`): at `round`, for
  # `cause`, with the `gaps` the agent stated or the cause of a stopped run, from the run
  # of the queue `run_id` (nil for the output checks). Open while `resolved_at` is nil, at
  # most one per work item. A person resolves it with `resolution`, with their `note`.
  @moduledoc false
  use Ecto.Schema

  @causes [:round_limit, :escalate, :check_failed, :run_stopped]
  @resolutions [:accept, :another_round, :move_back, :close]

  @typedoc "An escalation of a work item's stage."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "escalations" do
    field :stage_id, :string
    field :round, :integer
    field :cause, Ecto.Enum, values: @causes
    field :gaps, :string
    field :resolution, Ecto.Enum, values: @resolutions
    field :note, :string
    field :resolved_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :process_version, Apiary.Processes.Version
    belongs_to :run, Apiary.Dispatches.DispatchRun
    belongs_to :resolved_by, Apiary.Accounts.User
  end

  # causes/0 and resolutions/0 are every cause and every resolution.
  @doc false
  @spec causes() :: [atom]
  def causes, do: @causes

  @doc false
  @spec resolutions() :: [atom]
  def resolutions, do: @resolutions
end
