defmodule Apiary.Stages.GateDecision do
  # A person's decision at a stage's gate on a work item (`Apiary.Stages`): an approval,
  # `:approve`, which covers the artifact versions in `versions` (their public ids,
  # `av_…`), a request for changes, `:request_changes`, which may point at one version,
  # `artifact_version_id`, or a move of the work item from the stage to another, `:move`.
  # `note` is what the person wrote, nil for nothing. `stage_id`
  # and `process_version_id` are the stage and the version of the process it was made
  # under. Nothing changes a decision once it is written.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A decision at a stage's gate."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gate_decisions" do
    field :stage_id, :string
    field :kind, Ecto.Enum, values: [:approve, :request_changes, :move]
    field :versions, {:array, :string}, default: []
    field :artifact_version_id, :string
    field :note, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :process_version, Apiary.Processes.Version
    belongs_to :user, Apiary.Accounts.User
  end
end
