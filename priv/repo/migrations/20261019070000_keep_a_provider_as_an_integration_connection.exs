defmodule Apiary.Repo.Migrations.KeepAProviderAsAnIntegrationConnection do
  use Ecto.Migration

  # A model provider is an integration connection added from a description that Qory
  # vendors, with no release (`Apiary.Kinds.Providers`). `organisation_connections` gains:
  #
  #   * `provider_kind`, the description's name, and `description_ref`, the integrations
  #     commit it was vendored from; `description_sha256` is its digest;
  #   * `secret_id`, the organisation's secret whose values are the provider's keys, by a
  #     key on `(secret_id, organisation_id)` that refuses to delete a secret a provider
  #     links, and `default_value_id`, the value id of its default key;
  #   * `chain`, `organisation` for the organisation's providers, or `operator` for those
  #     an operator sets up for a client.
  #
  # The shape check lets an integration have a release, or else a `provider_kind`: never
  # both, and the provider's columns only on a provider. A row coded before this migration
  # keeps its integrity code of version 2; a row written after it is coded under version 3,
  # which covers the new columns (`Apiary.Connections.Connection`).
  def up do
    alter table(:organisation_connections) do
      add :provider_kind, :text
      add :description_ref, :text

      add :secret_id,
          references(:secrets,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :simple,
            on_delete: :restrict
          )

      add :default_value_id, :text
      add :chain, :text, null: false, default: "organisation"
    end

    create index(:organisation_connections, [:secret_id], where: "secret_id IS NOT NULL")

    create constraint(:organisation_connections, :organisation_connections_provider_kind_format,
             check: "provider_kind ~ '^[a-z][a-z0-9-]{0,63}$'"
           )

    create constraint(:organisation_connections, :organisation_connections_description_ref_format,
             check: "description_ref ~ '^[0-9a-f]{40}$'"
           )

    create constraint(
             :organisation_connections,
             :organisation_connections_default_value_id_format,
             check: "default_value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'"
           )

    create constraint(:organisation_connections, :organisation_connections_chain_check,
             check: "chain IN ('organisation', 'operator')"
           )

    # The provider's columns only on a provider; a default key only with its secret; an
    # operator's chain only for a provider.
    create constraint(:organisation_connections, :organisation_connections_provider_check,
             check: """
             (provider_kind IS NOT NULL
               OR (description_ref IS NULL AND secret_id IS NULL AND chain = 'organisation'))
             AND (default_value_id IS NULL OR secret_id IS NOT NULL)
             """
           )

    drop constraint(:organisation_connections, :organisation_connections_shape_check)

    create constraint(:organisation_connections, :organisation_connections_shape_check,
             check: """
             (kind = 'integration' AND description_sha256 IS NOT NULL
               AND service_builtin IS NULL AND service_definition_id IS NULL
               AND ((release_id IS NOT NULL AND source IS NOT NULL AND version IS NOT NULL
                     AND provider_kind IS NULL)
                 OR (release_id IS NULL AND source IS NULL AND forge_kind IS NULL
                     AND version IS NULL AND argument IS NULL
                     AND provider_kind IS NOT NULL AND description_ref IS NOT NULL)))
             OR (kind = 'service' AND release_id IS NULL AND source IS NULL
               AND forge_kind IS NULL AND version IS NULL AND description_sha256 IS NULL
               AND argument IS NULL AND settings = '{}' AND provider_kind IS NULL
               AND (service_builtin IS NULL) <> (service_definition_id IS NULL))
             OR (kind = 'runtime' AND release_id IS NULL AND source IS NULL
               AND forge_kind IS NULL AND version IS NULL AND description_sha256 IS NULL
               AND argument IS NULL AND settings = '{}' AND provider_kind IS NULL
               AND service_builtin IS NULL AND service_definition_id IS NULL)
             """
           )
  end

  # Rolling back drops the provider's columns, and the code before this migration verifies
  # a connection's integrity code under version 2 only. So it runs only while no connection
  # is coded under version 3: no provider, and no connection written since.
  def down do
    execute("LOCK TABLE organisation_connections IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM organisation_connections WHERE integrity_version >= 3) THEN
        RAISE EXCEPTION 'Rolling back drops the columns of a model provider, and the code before it verifies a connection coded under version 2 only, so it runs only while no connection is coded under version 3. One is.';
      END IF;
    END
    $$
    """)

    drop constraint(:organisation_connections, :organisation_connections_shape_check)

    create constraint(:organisation_connections, :organisation_connections_shape_check,
             check: """
             (kind = 'integration' AND release_id IS NOT NULL AND source IS NOT NULL
               AND version IS NOT NULL AND description_sha256 IS NOT NULL
               AND service_builtin IS NULL AND service_definition_id IS NULL)
             OR (kind = 'service' AND release_id IS NULL AND source IS NULL
               AND forge_kind IS NULL AND version IS NULL AND description_sha256 IS NULL
               AND argument IS NULL AND settings = '{}'
               AND (service_builtin IS NULL) <> (service_definition_id IS NULL))
             OR (kind = 'runtime' AND release_id IS NULL AND source IS NULL
               AND forge_kind IS NULL AND version IS NULL AND description_sha256 IS NULL
               AND argument IS NULL AND settings = '{}'
               AND service_builtin IS NULL AND service_definition_id IS NULL)
             """
           )

    drop constraint(:organisation_connections, :organisation_connections_provider_check)
    drop constraint(:organisation_connections, :organisation_connections_chain_check)

    drop constraint(
           :organisation_connections,
           :organisation_connections_default_value_id_format
         )

    drop constraint(:organisation_connections, :organisation_connections_description_ref_format)
    drop constraint(:organisation_connections, :organisation_connections_provider_kind_format)
    drop index(:organisation_connections, [:secret_id], where: "secret_id IS NOT NULL")

    alter table(:organisation_connections) do
      remove :chain
      remove :default_value_id
      remove :secret_id
      remove :description_ref
      remove :provider_kind
    end
  end
end
