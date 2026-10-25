defmodule Apiary.Repo.Migrations.KeepAnOrganisationSGrants do
  use Ecto.Migration

  # The grants of an organisation's connections to the instance's adapters,
  # `adapter_grants` (`Apiary.Adapters.Grant`), as the integration contract has them
  # (`grant.schema.json`, `grants.schema.json`): one row per external account a
  # connection reaches, which the adapter reports after a person's linked connect return.
  #
  # `public_id` is `ag_` and sixteen lowercase Crockford base32 characters. The connection,
  # its organisation and its adapter are held to the connection's by the composite key, so
  # a grant stays with its connection's organisation and adapter. `grant_ref` is the
  # adapter's ref to the grant, 1 to 200 characters, which Qory Apiary compares and stores
  # and never reads meaning into. `pass_nonce` is the 16 bytes of the nonce of the connect
  # pass the grant was last reported under: one grant per pass and connection. A grant is
  # `live` from `granted_at`, when Qory Apiary last accepted its report, until `ended_at`,
  # `ended`, for `ended_reason`: `connection_ended`, when its connection ended. Final: a
  # ref reported again after its end makes a new row. One live grant per adapter and ref
  # (the unique partial index), so an external account is linked to one live connection
  # at a time.
  @public_id "^ag_[0-9a-hjkmnp-tv-z]{16}$"

  def change do
    create table(:adapter_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :nothing), null: false

      add :connection_id,
          references(:adapter_connections,
            type: :binary_id,
            with: [organisation_id: :organisation_id, adapter_id: :adapter_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :grant_ref, :text, null: false
      add :state, :text, null: false
      add :pass_nonce, :binary, null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :ended_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:adapter_grants, [:public_id])

    create unique_index(:adapter_grants, [:adapter_id, :grant_ref],
             where: "ended_at IS NULL",
             name: :adapter_grants_live_index
           )

    create unique_index(:adapter_grants, [:connection_id, :pass_nonce])
    create index(:adapter_grants, [:organisation_id])

    create constraint(:adapter_grants, :adapter_grants_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    create constraint(:adapter_grants, :adapter_grants_grant_ref_check,
             check: "char_length(grant_ref) BETWEEN 1 AND 200"
           )

    create constraint(:adapter_grants, :adapter_grants_pass_nonce_check,
             check: "octet_length(pass_nonce) = 16"
           )

    create constraint(:adapter_grants, :adapter_grants_state_check,
             check:
               "(state = 'live' AND ended_at IS NULL) OR " <>
                 "(state = 'ended' AND ended_at IS NOT NULL)"
           )

    create constraint(:adapter_grants, :adapter_grants_ended_reason_check,
             check:
               "(ended_at IS NULL) = (ended_reason IS NULL) AND " <>
                 "(ended_reason IS NULL OR ended_reason IN ('connection_ended'))"
           )
  end
end
