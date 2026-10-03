defmodule Apiary.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  # A workspace's stored secrets (`Apiary.Secrets`), and the key their values are
  # encrypted under.
  #
  # `workspace_data_keys`: the workspace's data key, 32 random bytes, kept only wrapped:
  # AES-256-GCM under the instance's values key (`Apiary.KeyDerivation`, derived from
  # APIARY_ENCRYPTION_SECRET), `wrapped_key` the 12-byte nonce, the 32 bytes of ciphertext
  # and the 16-byte tag; `wrapping_key_id` the key id of the values key it is wrapped
  # under. One per workspace, made with its first secret.
  #
  # `secrets`: a secret by name, unique in the workspace whatever the case, with a public
  # id, `sec_` and 16 lowercase Crockford base32 characters, unique on the instance, which
  # the run configuration names and the AAD of each value binds. `note` says what it is
  # used for. A secret is deleted, with its values; never while in use, which the
  # application checks.
  #
  # `secret_values`: a secret's values, one with no value id, or several, each with its
  # own (a lowercase slug), unique in the secret: the unique index reads a missing value
  # id as ''. A value is only ever stored encrypted, AES-256-GCM under the workspace's
  # data key (`data_key_id`, of the same workspace by the composite key), with a 12-byte
  # nonce and the tag after the ciphertext; a value is 1 to 16384 bytes. Its secret is
  # of the same workspace by the composite key, and its values go with it.
  def change do
    create table(:workspace_data_keys, primary_key: false) do
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

      add :wrapped_key, :binary, null: false
      add :wrapping_key_id, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:workspace_data_keys, :workspace_data_keys_wrapped_key_check,
             check: "octet_length(wrapped_key) = 60"
           )

    create unique_index(:workspace_data_keys, [:organisation_id, :workspace_id])
    create unique_index(:workspace_data_keys, [:id, :workspace_id])

    create table(:secrets, primary_key: false) do
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
      add :name, :text, null: false
      add :note, :text
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:secrets, :secrets_public_id_format,
             check: "public_id ~ '^sec_[0-9a-hjkmnp-tv-z]{16}$'"
           )

    create constraint(:secrets, :secrets_name_format,
             check: "name ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$'"
           )

    create constraint(:secrets, :secrets_note_length, check: "char_length(note) <= 500")

    create unique_index(:secrets, [:public_id])

    create unique_index(:secrets, [:organisation_id, :workspace_id, "lower(name)"],
             name: :secrets_name_index
           )

    create unique_index(:secrets, [:id, :workspace_id])
    create index(:secrets, [:created_by_id])
    create index(:secrets, [:updated_by_id])

    create table(:secret_values, primary_key: false) do
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

      add :secret_id,
          references(:secrets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :value_id, :text

      add :data_key_id,
          references(:workspace_data_keys,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :nonce, :binary, null: false
      add :ciphertext, :binary, null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:secret_values, :secret_values_value_id_format,
             check: "value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'"
           )

    create constraint(:secret_values, :secret_values_nonce_length,
             check: "octet_length(nonce) = 12"
           )

    # The value's 1 to 16384 bytes, and the 16-byte tag.
    create constraint(:secret_values, :secret_values_ciphertext_length,
             check: "octet_length(ciphertext) BETWEEN 17 AND 16400"
           )

    create unique_index(
             :secret_values,
             [:organisation_id, :secret_id, "COALESCE(value_id, '')"],
             name: :secret_values_value_id_index
           )

    create index(:secret_values, [:secret_id])
    create index(:secret_values, [:data_key_id])
    create index(:secret_values, [:organisation_id, :workspace_id])
    create index(:secret_values, [:created_by_id])
    create index(:secret_values, [:updated_by_id])
  end
end
