defmodule Apiary.Adapters.GrantRule do
  # The rule of a grant (`Apiary.Adapters.Grant`): a workspace chose All for the grant,
  # so every collection that a listing makes for the grant is assigned to that workspace
  # as it is made (`Apiary.Adapters.Collections`). A grant has one rule at most. `backlog`
  # is true when the rule was chosen in Work sources: a collection the rule assigns has
  # its Backlog on; false when it was chosen in Destinations alone. The table and its
  # rules are `20261029141700_keep_a_grant_s_rule`'s.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Ecto.Schema

  alias Apiary.Adapters.Grant
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc "The rule of a grant."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "grant_rules" do
    field :backlog, :boolean

    belongs_to :organisation, Organisation
    belongs_to :grant, Grant
    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end
end
