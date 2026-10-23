defmodule Apiary.Stacks.Stack do
  # A stack set at a level of an organisation: `stack`, a stack name or a stack reference
  # (`Apiary.Contract.Stack`), and `saved_by_organisation_id`, the organisation a member
  # saved it in, nil for a stack saved any other way (`Apiary.Stacks.saved_by/1`) and
  # once that organisation is deleted.
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
    field :stack, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :target, Apiary.Runs.Target
    belongs_to :saved_by_organisation, Apiary.Organisations.Organisation
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
