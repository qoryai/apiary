defmodule Apiary.Stages.Escalation do
  # A stage of a work item that waits for a person (`Apiary.Stages`): at `round`, for
  # `cause`, with the `points` a person reads, from the run of the queue `run_id` (nil for
  # the output checks). Each point is `%{"text", "action", "question"?, "fix"?,
  # "action_in_text"?}` (`Apiary.Stages.Points`): the run's verdict writes them for
  # `escalate`, and the stage runner writes them for the causes it sets
  # (`Apiary.Stages.Runner`); `return_limit` has the runner's point, then the points of
  # the verdict of the run that reached the limit.
  # Open while `resolved_at` is nil, at most one per work item. A person resolves it with
  # `resolution`, with their `note`.
  #
  # `public_id` is `es_` and sixteen lowercase Crockford base32 characters
  # (`Apiary.PublicId`): the id of the escalation in the run API's notes
  # (`Apiary.Stages.Notes`), which a run's version may have as its `decision`.
  @moduledoc false
  use Ecto.Schema

  @causes [:round_limit, :escalate, :check_failed, :run_stopped, :return_limit]
  @resolutions [:accept, :another_round, :move_back, :switch, :close]
  @prefix "es"

  @typedoc "An escalation of a work item's stage."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "escalations" do
    field :public_id, :string, read_after_writes: true
    field :stage_id, :string
    field :round, :integer
    field :cause, Ecto.Enum, values: @causes
    field :points, {:array, :map}, default: []
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

  # prefix/0 is the prefix of an escalation's public id, `es`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix
end
