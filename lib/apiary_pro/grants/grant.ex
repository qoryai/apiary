defmodule ApiaryPro.Grants.Grant do
  @moduledoc """
  What one link below the instance says of one feature (`Apiary.Features`): an
  organisation's row says a feature is granted (`granted: true`, to an operator, which has
  only what it is granted) or taken away (`granted: false`, from any other organisation,
  which follows the instance otherwise). One row per
  organisation and feature. Written only by `ApiaryPro.Grants`, never cast from a form.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_grants" do
    # A row may name a part of a feature as well (`Apiary.Features.parts/0`), the run's
    # Terminal, `:"observability.terminal"`. A part is shown wherever its feature is, so
    # its row only hides it, `granted` false, for every kind of organisation. Written
    # only while features are shown by who asks
    # (`ApiaryPro.Flags.feature_visibility?/0`), and read only then
    # (`ApiaryPro.Features.hidden/1`).
    #
    # A row written before this release may name `:nodes`, a part of no feature. Such a
    # row hides nothing (`ApiaryPro.Features.hidden/1` skips it), and no page writes one.
    field :feature, Ecto.Enum,
      values: [
        :observability,
        :security,
        :managed_organisations,
        :organisation_policy,
        :organisation_variables,
        :"observability.terminal",
        :nodes
      ]

    field :granted, :boolean

    belongs_to :organisation, Apiary.Organisations.Organisation

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
