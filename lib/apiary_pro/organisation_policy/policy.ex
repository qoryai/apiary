defmodule ApiaryPro.OrganisationPolicy.Policy do
  @moduledoc """
  The organisation's policy, the row that holds its two settings (`organisation_policies`,
  one per organisation): `enforce_everywhere`, the mode floor (on, no workspace or target
  may observe: their mode is `enforce`, required by the organisation), and `own_allows`,
  the switch (on by default; off, only the organisation's allows grant a host, and every
  workspace's or target's allow is listed but not in force). Its host rules are
  `ApiaryPro.OrganisationPolicy.Rule`s. Written only by `ApiaryPro.OrganisationPolicy`,
  never cast from a form.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organisation_policies" do
    field :enforce_everywhere, :boolean, default: false
    field :own_allows, :boolean, default: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end
end
