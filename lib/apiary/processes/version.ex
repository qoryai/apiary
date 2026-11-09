defmodule Apiary.Processes.Version do
  @moduledoc """
  A version of a workspace's process (`Apiary.Processes`): its document, as
  `priv/schemas/process/v1.schema.json` describes it, numbered 1, 2, … within the
  workspace. Each save makes a new row; nothing changes a row's document after.

  - `status`: `:current`, at most one per workspace, the version work items taken in run
    under; `:trial`, a version chosen work items run under before it is made current;
    `:past`, a current version a later one replaced; `:dropped`, a trial that was not
    made current.
  - `author_id`: who saved it. On version 1, nil for a copy of the type's default or of
    the Qory template, and the person who made the workspace for a copy of a repository's
    template; nil on a version that the switch Keep the process at the latest saved.
  - `based_on_id`: the version the save started from, nil for version 1.
  - `template`: what the workspace copied, on version 1 and on each version made from its
    harness (`Apiary.Processes.HarnessUpdate`), nil on the others: `%{"type" => type,
    "version" => version}` for the type's default, or the keys `source`, `git`, `commit`,
    `module`, `stack`, `type` and `version` for a template, where `type` is the template
    file's `type`, the same value as `workspaces.type`. A version made from the harness
    also has `ref_kind` (`branch`, `tag` or `commit`) and `ref`, the version of the
    harness it was read at, `version` nil, and `added_types`, the names of the artifact
    types its save added, where it added any.
  - `public_id`: `pv_` and 16 characters (`Apiary.PublicId`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:current, :trial, :past, :dropped]

  # Where a work item is in its stage: its sequence runs, the stage waits for a required
  # input, for answers to a run's questions, or for a workflow the harness no longer
  # declares; a person must act on an escalation, the gate waits for its approval, or the
  # stage is done.
  @stage_states [
    :running,
    :waiting_inputs,
    :waiting_answers,
    :waiting_workflow,
    :escalated,
    :at_gate,
    :done
  ]

  @typedoc "A version of a workspace's process."
  @type t :: %__MODULE__{}

  @typedoc "A version's status."
  @type status :: :current | :trial | :past | :dropped

  schema "process_versions" do
    field :public_id, :string
    field :number, :integer
    field :status, Ecto.Enum, values: @statuses
    field :document, :map
    field :template, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :author, Apiary.Accounts.User
    belongs_to :based_on, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @doc "statuses/0 is every status a version may have."
  @spec statuses() :: [status]
  def statuses, do: @statuses

  @doc """
  stage_states/0 is every state a work item may be in within its stage, its
  `stage_state`.
  """
  @spec stage_states() :: [atom]
  def stage_states, do: @stage_states
end
