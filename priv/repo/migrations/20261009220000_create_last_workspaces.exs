defmodule Apiary.Repo.Migrations.CreateLastWorkspaces do
  use Ecto.Migration

  # The workspace a person last used in each organisation they reach
  # (`Apiary.Organisations.LastWorkspace`): one row per person and organisation, which an
  # organisation's page and the switcher's link to the organisation open. It goes with the
  # person, the organisation and the workspace.
  #
  # The workspace is of the row's organisation, by the composite key. The indexes are the
  # purge's, which deletes an organisation's rows and a workspace's.
  def change do
    create table(:last_workspaces, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:last_workspaces, [:organisation_id])
    create index(:last_workspaces, [:workspace_id])
  end
end
