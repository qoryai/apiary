defmodule Apiary.ModelChoices.ModelChoice do
  # A model choice set at a level of an organisation: the runtime its runs use (`runtime`,
  # a name of `Apiary.Kinds.Runtimes`), its model provider (`connection_id`, an
  # `Apiary.Connections.Connection` with a `provider_kind`), the value id of one of the
  # provider's keys (`value_id`), a model id (`model_id`), of the provider's description or
  # any other, an effort value of that model (`effort`), and a tier map (`tiers`). Each
  # field but the provider or the tier map may be empty: the catalogue's default runtime
  # (`Apiary.ModelChoices.default_runtime/0`), the provider's default key, the provider's
  # default model, and the runtime's default effort.
  #
  # Its level is read from the columns it has set (`level/1`):
  #
  # | Level | Place | Columns |
  # |---|---|---|
  # | 2 | a target and a workflow | `workspace_id`, `target_id`, `workflow` |
  # | 3 | a target | `workspace_id`, `target_id` |
  # | 4 | the workspace and a workflow | `workspace_id`, `workflow` |
  # | 5 | the workspace | `workspace_id` |
  # | 6 | the organisation's default | none of them |
  #
  # `chain` is
  # `organisation`, or `operator` for a row an operator sets for a client, which an edition
  # writes. Only a row of levels 4 and 5 is `locked`.
  #
  # A tier map has one to three of the tiers `light`, `fast` and `thinking`, each an object
  # of a `model` id and, when it sets one, an `effort` value.
  #
  # Changed only through `Apiary.ModelChoices`.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A model choice at levels 2 to 6."
  @type t :: %__MODULE__{}

  @typedoc "A level of a model choice: 2, a target and a workflow, to 6, the organisation's default."
  @type level :: 2..6

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "model_choices" do
    field :workflow, :string
    field :chain, :string, default: "organisation"
    field :locked, :boolean, default: false
    field :runtime, :string
    field :value_id, :string
    field :model_id, :string
    field :effort, :string
    field :tiers, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :target, Apiary.Runs.Target
    belongs_to :connection, Apiary.Connections.Connection
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :updated_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  # level/1 is the level of `choice`, 2 to 6, read from the columns it has set.
  @spec level(t) :: 2..6
  def level(%__MODULE__{workspace_id: nil}), do: 6
  def level(%__MODULE__{target_id: nil, workflow: nil}), do: 5
  def level(%__MODULE__{target_id: nil}), do: 4
  def level(%__MODULE__{workflow: nil}), do: 3
  def level(%__MODULE__{}), do: 2
end
