defmodule Apiary.Repo.Migrations.CreateConnections do
  use Ecto.Migration

  # What a workspace sets up for its runs: runtimes, integrations and services
  # (`Apiary.Connections`). The contract calls each a connection; the table is
  # `workspace_connections`, since `connections` is the record's, one row per host a run
  # reached.
  #
  # `integration_releases`: a release of an integration the workspace asked for, by its
  # `source` (a forge path with `forge_kind`, or an https URL of a description.json) and
  # version, and what the fetch found: the release's description.json, byte for byte, its
  # SHA-256 in lowercase hex, the integration's name and version as it says, and its
  # publisher's name and URL, as the description names them, unverified. `state`
  # is `pending` until the fetch ends, then `ready`, or `failed` with `failure`, a code.
  #
  # `service_definitions`: a workspace's own service definitions, beside the built-in ones
  # that ship with the application: the definition as canonical JSON, its SHA-256, and a
  # public id, `svc_` and 16 lowercase Crockford base32 characters.
  #
  # `workspace_connections`: one runtime, integration or service set up in the workspace,
  # with a public id, `con_` and 16 characters, which the run configuration names. It
  # applies to every repository of the workspace (`applies_to` `all`) or to those of
  # `connection_targets` (`selected`). An integration's row names its release and copies
  # its source, version and description digest; a service's names its definition, built in
  # by id or the workspace's own, and holds no host and no auth of its own. `settings` are
  # an integration's plain settings, canonical JSON of an object; `argument` the argument
  # it is started with.
  #
  # `connection_targets`: the repositories a connection applies to, and per repository the
  # ways an integration is used there (`credential`, `tool`); none uses the credential way
  # when the integration's description offers it, and a save refuses `tool`.
  #
  # Every row of the first three carries an integrity code (`Apiary.Integrity`) over the
  # fields its schema names, with the key id and the version of that choice of fields.
  def change do
    create table(:integration_releases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :source, :text, null: false
      add :forge_kind, :text
      add :requested_version, :text
      add :state, :text, null: false, default: "pending"
      add :failure, :text
      add :name, :text
      add :version, :text
      add :publisher_name, :text
      add :publisher_url, :text
      add :description, :text
      add :description_sha256, :text
      add :fetched_at, :utc_datetime_usec
      add :integrity_key_id, :text, null: false
      add :integrity_code, :binary, null: false
      add :integrity_version, :integer, null: false
      add :requested_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:integration_releases, :integration_releases_state_check,
             check: "state IN ('pending', 'ready', 'failed')"
           )

    create constraint(:integration_releases, :integration_releases_forge_kind_check,
             check: "forge_kind IN ('github', 'gitlab', 'forgejo')"
           )

    create constraint(:integration_releases, :integration_releases_ready_check,
             check:
               "state <> 'ready' OR (description IS NOT NULL AND description_sha256 IS NOT NULL " <>
                 "AND name IS NOT NULL AND version IS NOT NULL AND publisher_name IS NOT NULL)"
           )

    create constraint(:integration_releases, :integration_releases_sha256_check,
             check: "description_sha256 ~ '^[0-9a-f]{64}$'"
           )

    create unique_index(:integration_releases, [:id, :workspace_id])
    create index(:integration_releases, [:organisation_id, :workspace_id, :source])
    create index(:integration_releases, [:requested_by_id])

    create table(:service_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :public_id, :text, null: false
      add :key, :text, null: false
      add :title, :text, null: false
      add :definition, :text, null: false
      add :digest, :text, null: false
      add :integrity_key_id, :text, null: false
      add :integrity_code, :binary, null: false
      add :integrity_version, :integer, null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:service_definitions, :service_definitions_public_id_format,
             check: "public_id ~ '^svc_[0-9a-hjkmnp-tv-z]{16}$'"
           )

    create constraint(:service_definitions, :service_definitions_digest_check,
             check: "digest ~ '^[0-9a-f]{64}$'"
           )

    create unique_index(:service_definitions, [:public_id])

    create unique_index(:service_definitions, [:organisation_id, :workspace_id, :key],
             name: :service_definitions_key_index
           )

    create unique_index(:service_definitions, [:id, :workspace_id])
    create index(:service_definitions, [:created_by_id])
    create index(:service_definitions, [:updated_by_id])

    create table(:workspace_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :public_id, :text, null: false
      add :kind, :text, null: false
      add :name, :text, null: false
      add :applies_to, :text, null: false, default: "all"
      add :settings, :text, null: false, default: "{}"
      add :argument, :text

      add :release_id,
          references(:integration_releases,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :simple,
            on_delete: :nothing
          )

      add :source, :text
      add :forge_kind, :text
      add :version, :text
      add :description_sha256, :text
      add :service_builtin, :text

      add :service_definition_id,
          references(:service_definitions,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :simple,
            on_delete: :nothing
          )

      add :integrity_key_id, :text, null: false
      add :integrity_code, :binary, null: false
      add :integrity_version, :integer, null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:workspace_connections, :workspace_connections_public_id_format,
             check: "public_id ~ '^con_[0-9a-hjkmnp-tv-z]{16}$'"
           )

    create constraint(:workspace_connections, :workspace_connections_kind_check,
             check: "kind IN ('runtime', 'integration', 'service')"
           )

    create constraint(:workspace_connections, :workspace_connections_applies_to_check,
             check: "applies_to IN ('all', 'selected')"
           )

    create constraint(:workspace_connections, :workspace_connections_forge_kind_check,
             check: "forge_kind IN ('github', 'gitlab', 'forgejo')"
           )

    create constraint(:workspace_connections, :workspace_connections_settings_check,
             check: "jsonb_typeof(settings::jsonb) = 'object' AND octet_length(settings) <= 65536"
           )

    create constraint(:workspace_connections, :workspace_connections_argument_check,
             check: "octet_length(argument) BETWEEN 1 AND 4096"
           )

    # What each kind holds, and nothing it does not.
    create constraint(:workspace_connections, :workspace_connections_shape_check,
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

    create unique_index(:workspace_connections, [:public_id])
    create unique_index(:workspace_connections, [:id, :workspace_id])
    create index(:workspace_connections, [:organisation_id, :workspace_id, :kind])
    create index(:workspace_connections, [:release_id])
    create index(:workspace_connections, [:service_definition_id])
    create index(:workspace_connections, [:created_by_id])
    create index(:workspace_connections, [:updated_by_id])

    create table(:connection_targets, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :connection_id,
          references(:workspace_connections,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true,
          null: false

      add :ways, {:array, :text}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:connection_targets, :connection_targets_ways_check,
             check:
               "ways IS NULL OR (cardinality(ways) BETWEEN 1 AND 2 " <>
                 "AND ways <@ ARRAY['credential', 'tool']::text[])"
           )

    create index(:connection_targets, [:target_id])
    create index(:connection_targets, [:organisation_id, :workspace_id])
  end
end
