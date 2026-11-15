defmodule ApiaryPro.Tenants.Tenant do
  @moduledoc """
  A tenant is what the edition knows of an organisation, one row per organisation,
  keyed by its `organisation_id` (`ApiaryPro.Tenants`): its `kind`, `:organisation` or
  `:operator`; whether it is the instance organisation, `instance_organisation`; and its
  suspension, `suspended_at` and `suspended_by_id`. The row is written in the transaction
  that creates the organisation, and goes with it.

  The database keeps the rules (the table's migration says which): one instance
  organisation, of either kind, never suspended; a suspender only with a suspension. The
  columns `operator_id`, `operator_since`, `model_chain` and `operator_kind` stay in the
  table and are not read or written here. No field is ever cast from a form.
  """
  use Ecto.Schema

  @kinds [:organisation, :operator]

  @primary_key {:organisation_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "tenants" do
    field :kind, Ecto.Enum, values: @kinds, default: :organisation
    field :instance_organisation, :boolean, default: false
    field :suspended_at, :utc_datetime_usec
    field :suspended_by_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @typedoc "A kind of organisation: an ordinary one, or an operator, which operates workspaces."
  @type kind :: :organisation | :operator

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
          suspended_at: DateTime.t() | nil,
          suspended_by_id: Ecto.UUID.t() | nil
        }

  @doc "kinds/0 is the kinds of organisation: an ordinary organisation, and an operator."
  @spec kinds() :: [kind]
  def kinds, do: @kinds
end
