defmodule ApiaryPro.Tenants.Tenant do
  @moduledoc """
  A tenant is what the edition knows of an organisation, one row per organisation,
  keyed by its `organisation_id` (`ApiaryPro.Tenants`): its `kind`, `:organisation` or
  `:operator`; whether it is the instance organisation, `instance_organisation`; its
  operator, `operator_id`, when it is a client, and since when, `operator_since`; and its
  suspension, `suspended_at` and `suspended_by_id`. The row is written in the transaction
  that creates the organisation, and goes with it.

  The database keeps the rules (the table's migration says which): one instance
  organisation, of either kind, never suspended and never a client; a client of the kind
  `organisation`, whose operator is of the kind `operator`; `operator_since` exactly while
  there is an operator; a suspender only with a suspension. `operator_kind`, generated, is
  the other half of the key to the operator, and is not read here. No field is ever cast
  from a form.
  """
  use Ecto.Schema

  @kinds [:organisation, :operator]
  @model_chains [:organisation, :operator]

  @primary_key {:organisation_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :kind, Ecto.Enum, values: @kinds, default: :organisation
    field :instance_organisation, :boolean, default: false
    field :operator_id, :binary_id
    field :operator_since, :utc_datetime_usec
    # `tenants.model_chain` is `organisation`, the default, or `operator`. The database keeps
    # it one of the two, `:operator` only with an operator: a check allows `operator` only on
    # a row that has an operator, and a drop or a leaving sets the column back to
    # `organisation` in the same change.
    field :model_chain, Ecto.Enum, values: @model_chains, default: :organisation
    field :suspended_at, :utc_datetime_usec
    field :suspended_by_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A kind of organisation: an ordinary one, or an operator, which has clients."
  @type kind :: :organisation | :operator

  # Whose model providers a client's runs use: the organisation's, or its operator's.
  @typedoc false
  @type model_chain :: :organisation | :operator

  # The type is an open map with `__struct__`, not `%__MODULE__{}`: it lists these
  # fields and allows the struct's other keys, because the docs page of a struct type
  # names every field of the struct.
  @typedoc "What the edition knows of one organisation."
  @type t :: %{
          optional(atom()) => term(),
          __struct__: __MODULE__,
          organisation_id: Ecto.UUID.t() | nil,
          kind: kind,
          instance_organisation: boolean,
          operator_id: Ecto.UUID.t() | nil,
          operator_since: DateTime.t() | nil,
          suspended_at: DateTime.t() | nil,
          suspended_by_id: Ecto.UUID.t() | nil
        }

  @doc "kinds/0 is the kinds of organisation: an ordinary organisation, and an operator."
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  # model_chains/0 is the values of `model_chain`: the organisation's, and its operator's.
  @doc false
  @spec model_chains() :: [model_chain]
  def model_chains, do: @model_chains
end
