defmodule Apiary.Stacks.Stack do
  # A stack set at a level of an organisation: `harness`, a harness document, the
  # contents of the `harness` section of qory's format written in YAML
  # (`Apiary.Stacks.Document`), nil for a row that sets only the workflow; and
  # `owner_organisation_id`, the organisation that owns the row, which the edition gives
  # for the person who saved it last (`Apiary.Edition.harness_owner/1`), nil once that
  # organisation is deleted. A row has a document, a workflow or both; a row with a
  # choice has its document.
  #
  # Its level is read from the columns it has set (`level/1`):
  #
  # | Level | Place | Columns |
  # |---|---|---|
  # | `:target_workflow` | a target and a workflow | `workspace_id`, `target_id`, `workflow` |
  # | `:target` | a target | `workspace_id`, `target_id` |
  # | `:workspace_workflow` | the workspace and a workflow | `workspace_id`, `workflow` |
  # | `:workspace` | the workspace | `workspace_id` |
  # | `:organisation` | the organisation's default | none of them |
  #
  # `workflow` is a workflow name: a lower-case letter, then up to 63 lower-case letters,
  # digits and hyphens. A run's workflow is read from these rows
  # (`Apiary.Stacks.workflow/2`).
  #
  # `access` is the access level recorded for the runs of the row's workflow, `:read` or
  # `:write`, nil for none, and only on a row with a workflow. It only lowers the level
  # the workflow declares in its stack (`Apiary.Harnesses.Walk`).
  #
  # `choice` is a harness choice, nil for none, only on a row with no workflow, and with
  # the row's document (`Apiary.Stacks`):
  #
  #   * at `:target`: the stack chosen for that target (`Apiary.Stacks.target_choice/2`);
  #   * at `:workspace`: the workspace's choice (`Apiary.Stacks.choice/1`);
  #   * at `:organisation`: the harness the organisation shares with every workspace
  #     (`Apiary.Stacks.shared/1`).
  #
  # `:qory` is the Qory harness, and `:repository` a harness repository or a stack of
  # one; each row's document extends it.
  #
  # `version_kind` is the version of a choice, nil on a row the save wrote before versions,
  # whose document's `ref` is read as written (`Apiary.Stacks.version_ref/3`):
  #
  #   * `:latest` and `:named`, under `:qory`: the newest version of the Qory harness the
  #     release ships (`Apiary.Lingo.Domain.Definition.qory_harness/0`), or the named
  #     version `version_name`;
  #   * `:branch`, `:tag` and `:commit`, under `:repository`: the newest commit of the
  #     branch `version_name` when each run starts; the tag `version_name`; the commit
  #     whose full id is `version_name`;
  #   * `:workspace`, on a target's row: the version of the workspace's harness.
  #
  # Changed only through `Apiary.Stacks`.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A stack at one of the five levels."
  @type t :: %__MODULE__{}

  @typedoc "A level of a stored stack, the most specific first."
  @type level :: :target_workflow | :target | :workspace_workflow | :workspace | :organisation

  @levels [:target_workflow, :target, :workspace_workflow, :workspace, :organisation]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stacks" do
    field :workflow, :string
    field :harness, :string
    field :access, Ecto.Enum, values: [:read, :write]
    field :choice, Ecto.Enum, values: [:qory, :repository]

    field :version_kind, Ecto.Enum, values: [:latest, :named, :branch, :tag, :commit, :workspace]

    field :version_name, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :target, Apiary.Runs.Target
    belongs_to :owner_organisation, Apiary.Organisations.Organisation
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  # levels/0 is the five levels, the most specific first.
  @spec levels() :: [level]
  def levels, do: @levels

  @doc false
  # level/1 is the level of `stack`, read from the columns it has set.
  @spec level(t) :: level
  def level(%__MODULE__{workspace_id: nil}), do: :organisation
  def level(%__MODULE__{target_id: nil, workflow: nil}), do: :workspace
  def level(%__MODULE__{target_id: nil}), do: :workspace_workflow
  def level(%__MODULE__{workflow: nil}), do: :target
  def level(%__MODULE__{}), do: :target_workflow
end
