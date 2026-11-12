defmodule Apiary.Repo.Migrations.CreateWorkspaceAccess do
  use Ecto.Migration

  # Which workspaces a person reaches, one row per person and workspace, for a level that
  # does not reach every workspace of its organisation (`ApiaryPro.WorkspaceAccess`).
  #
  # The rows are workspace data: `organisation_id` and `workspace_id` with the composite key
  # against `workspaces`, so they go with their workspace. The person is named by
  # `(organisation_id, user_id)` against the membership, so a row never outlives the
  # membership it widens: removing the member removes their rows. Both are keys the core
  # promises an edition.
  def change do
    create table(:workspace_access, primary_key: false) do
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

      add :user_id,
          references(:memberships,
            column: :user_id,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:workspace_access, [:organisation_id, :workspace_id, :user_id])
    # A person's rows in an organisation, and the key against their membership.
    create index(:workspace_access, [:organisation_id, :user_id])
  end
end
