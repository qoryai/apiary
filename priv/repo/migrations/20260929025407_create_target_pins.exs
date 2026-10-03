defmodule Apiary.Repo.Migrations.CreateTargetPins do
  use Ecto.Migration

  # The targets a person pinned in a workspace (`Apiary.Targets`), which the sidebar lists
  # in the order they were pinned: one row per person and target. A pin is the person's
  # own reading preference, kept where every page can read it, and goes with its target
  # and with its workspace.
  #
  # The target is of the pin's workspace, by the composite key. The unique index is the
  # one row per person and target, scoped by the organisation; the next is what the
  # sidebar reads, a person's pins in one workspace in the order they were pinned.
  def change do
    create table(:target_pins, primary_key: false) do
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

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:target_pins, [:organisation_id, :user_id, :target_id])
    create index(:target_pins, [:workspace_id, :user_id, :inserted_at])
    create index(:target_pins, [:target_id])
    create index(:target_pins, [:user_id])
  end
end
