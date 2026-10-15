defmodule Apiary.Repo.Migrations.KeepStoredSecretsAtTheOrganisation do
  use Ecto.Migration

  # The stored secrets (`Apiary.Secrets`), their values and the key they are encrypted
  # under are the organisation's from now on, not a workspace's. A fresh start: the guard
  # before it (`20261016090000_expect_the_integration_tables_empty`) found these tables
  # empty, and this migration counts them again under its lock, so it moves no row,
  # encrypts no value again and wraps no data key again.
  #
  # - `workspace_data_keys` becomes `organisation_data_keys`, without `workspace_id`: one
  #   data key per organisation (unique on `organisation_id`), made with its first secret.
  # - `secrets` loses `workspace_id`: a name is unique in the organisation whatever its
  #   case (`secrets_name_index`).
  # - `secret_values` loses `workspace_id`: its secret and its data key are of its
  #   organisation by the composite keys, `MATCH FULL`.
  #
  # `down` refuses while any of the three holds a row, then puts the workspace back.
  @tables ~w(secret_values secrets workspace_data_keys)
  @tables_now ~w(secret_values secrets organisation_data_keys)

  def up do
    execute lock(@tables)
    flush()
    refuse_rows!(repo(), @tables)

    drop constraint(:secret_values, :secret_values_secret_id_fkey)
    drop constraint(:secret_values, :secret_values_data_key_id_fkey)

    # Each drop takes the column's foreign key to `workspaces` and every index on it.
    alter table(:secret_values), do: remove(:workspace_id)
    alter table(:secrets), do: remove(:workspace_id)
    alter table(:workspace_data_keys), do: remove(:workspace_id)

    rename table(:workspace_data_keys), to: table(:organisation_data_keys)

    execute rename_constraints(
              :organisation_data_keys,
              "workspace_data_keys_",
              "organisation_data_keys_"
            )

    create unique_index(:organisation_data_keys, [:organisation_id])
    create unique_index(:organisation_data_keys, [:id, :organisation_id])

    create unique_index(:secrets, [:organisation_id, "lower(name)"], name: :secrets_name_index)
    create unique_index(:secrets, [:id, :organisation_id])

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_secret_id_fkey
      FOREIGN KEY (secret_id, organisation_id) REFERENCES secrets (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_data_key_id_fkey
      FOREIGN KEY (data_key_id, organisation_id)
      REFERENCES organisation_data_keys (id, organisation_id)
      MATCH FULL ON DELETE NO ACTION
    """

    create index(:secret_values, [:organisation_id])
  end

  def down do
    execute lock(@tables_now)
    flush()
    refuse_rows!(repo(), @tables_now)

    drop index(:secret_values, [:organisation_id])
    drop constraint(:secret_values, :secret_values_data_key_id_fkey)
    drop constraint(:secret_values, :secret_values_secret_id_fkey)
    drop index(:secrets, [:id, :organisation_id])
    drop index(:secrets, [:organisation_id, "lower(name)"], name: :secrets_name_index)
    drop index(:organisation_data_keys, [:id, :organisation_id])
    drop index(:organisation_data_keys, [:organisation_id])

    execute rename_constraints(
              :organisation_data_keys,
              "organisation_data_keys_",
              "workspace_data_keys_"
            )

    rename table(:organisation_data_keys), to: table(:workspace_data_keys)

    for name <- [:workspace_data_keys, :secrets, :secret_values] do
      alter table(name) do
        add :workspace_id,
            references(:workspaces,
              type: :binary_id,
              with: [organisation_id: :organisation_id],
              match: :full,
              on_delete: :delete_all
            ),
            null: false
      end
    end

    create unique_index(:workspace_data_keys, [:organisation_id, :workspace_id])
    create unique_index(:workspace_data_keys, [:id, :workspace_id])

    create unique_index(:secrets, [:organisation_id, :workspace_id, "lower(name)"],
             name: :secrets_name_index
           )

    create unique_index(:secrets, [:id, :workspace_id])

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_secret_id_fkey
      FOREIGN KEY (secret_id, workspace_id) REFERENCES secrets (id, workspace_id)
      MATCH FULL ON DELETE CASCADE
    """

    execute """
    ALTER TABLE secret_values ADD CONSTRAINT secret_values_data_key_id_fkey
      FOREIGN KEY (data_key_id, workspace_id) REFERENCES workspace_data_keys (id, workspace_id)
      MATCH FULL ON DELETE NO ACTION
    """

    create index(:secret_values, [:organisation_id, :workspace_id])
  end

  # Every constraint of `table` whose name starts with `from` renamed to start with `to`:
  # the primary key, the foreign key, the check, and the NOT NULL constraints of a Postgres
  # that names them.
  defp rename_constraints(table, from, to) do
    """
    DO $$
    DECLARE
      name text;
    BEGIN
      FOR name IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = '#{table}'::regclass AND starts_with(conname, '#{from}')
      LOOP
        EXECUTE format('ALTER TABLE #{table} RENAME CONSTRAINT %I TO %I',
          name, '#{to}' || substr(name, #{String.length(from) + 1}));
      END LOOP;
    END
    $$
    """
  end

  defp lock(tables),
    do: "LOCK TABLE #{Enum.join(tables, ", ")} IN ACCESS EXCLUSIVE MODE"

  defp refuse_rows!(repo, tables) do
    holding =
      Enum.filter(tables, fn table ->
        %{rows: [[count]]} = repo.query!("SELECT count(*) FROM #{table}", [], log: false)
        count > 0
      end)

    case holding do
      [] -> :ok
      holding -> raise "holding rows: " <> Enum.join(holding, ", ")
    end
  end
end
