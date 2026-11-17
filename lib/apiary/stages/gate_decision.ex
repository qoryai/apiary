defmodule Apiary.Stages.GateDecision do
  # A person's decision at a stage's gate on a work item (`Apiary.Stages`): an approval,
  # `:approve`, which covers the artifact versions in `versions` (their public ids,
  # `av_…`), a request for changes, `:request_changes`, which may point at one version,
  # `artifact_version_id`, or a move of the work item from the stage to another, `:move`.
  # A gate `none` records an approval too: `automatic` true, with no `user_id`, when the
  # runner passed the gate, and the member's `user_id` when they accepted the escalation
  # that ended the stage. A nil `user_id` with `automatic` false is a member whose account
  # is gone. `track` is the id of the track the approval chose, nil for none; only an
  # approval has one. `note` is what the person wrote, nil for nothing. `stage_id`
  # and `process_version_id` are the stage and the version of the process it was made
  # under, and `take_in` the take in of the work item it was made in. Nothing changes a
  # decision once it is written.
  #
  # `public_id` is `gd_` and sixteen lowercase Crockford base32 characters
  # (`Apiary.PublicId`): the id of a request for changes or a move in the run API's notes
  # (`Apiary.Stages.Notes`), which a run's version may have as its `decision`.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A decision at a stage's gate."
  @type t :: %__MODULE__{}

  @prefix "gd"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "gate_decisions" do
    field :public_id, :string, read_after_writes: true
    field :stage_id, :string
    field :kind, Ecto.Enum, values: [:approve, :request_changes, :move]
    field :versions, {:array, :string}, default: []
    field :artifact_version_id, :string
    field :note, :string
    field :track, :string
    field :take_in, :integer
    field :automatic, :boolean, default: false
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :process_version, Apiary.Processes.Version
    belongs_to :user, Apiary.Accounts.User
  end

  # prefix/0 is the prefix of a decision's public id, `gd`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix
end
