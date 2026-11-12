defmodule ApiaryPro.Grants.Grant do
  @moduledoc """
  What one link below the instance says of one feature (`Apiary.Features`): an
  organisation's row says a feature is granted (`granted: true`, to an operator or a
  client, which have only what they are granted) or taken away (`granted: false`, from an
  organisation with no operator, which follows the instance otherwise). One row per
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
    # It may name the nodes too, `:nodes`, a part of no feature: the nodes, the node
    # pools, their access keys and the gateways. Only a client's row hides them, written
    # by its operator, and only while the operator owns its clients
    # (`ApiaryPro.Flags.operator_infrastructure?/0`) and features are shown by who asks.
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
