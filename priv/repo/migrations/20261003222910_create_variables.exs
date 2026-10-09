defmodule Apiary.Repo.Migrations.CreateVariables do
  use Ecto.Migration

  # A workspace's variables (`Apiary.Variables`): a name and a value a run's process is
  # given. A row with no target is the workspace's, a row with one is that target's (a
  # repository's), of the variable's workspace by the composite key, and goes with it.
  # Names keep a variable's rule and are unique at a level whatever their case: the
  # unique index reads a workspace variable's missing target as the nil UUID, as the
  # policy's rules do. A value is at most 4096 bytes, with no NUL, carriage return or line
  # feed. Only a workspace's variable is locked: a lock is what holds it against the
  # repositories.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def change do
    create table(:variables, primary_key: false) do
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

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: :delete_all
          )

      add :name, :text, null: false
      add :value, :text, null: false
      add :locked, :boolean, null: false, default: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:variables, :variables_name_format,
             check: "name ~ '^[A-Za-z_][A-Za-z0-9_]{0,127}$'"
           )

    create constraint(:variables, :variables_value_check,
             check: "octet_length(value) <= 4096 AND value !~ '[\\r\\n]'"
           )

    create constraint(:variables, :variables_locked_is_the_workspaces_check,
             check: "NOT locked OR target_id IS NULL"
           )

    create unique_index(
             :variables,
             [:workspace_id, "COALESCE(target_id, #{@nobody})", "lower(name)"],
             name: :variables_name_index
           )

    create index(:variables, [:organisation_id, :workspace_id])
    create index(:variables, [:target_id])
    create index(:variables, [:created_by_id])
    create index(:variables, [:updated_by_id])
  end
end
