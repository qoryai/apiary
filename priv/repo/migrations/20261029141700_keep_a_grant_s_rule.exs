defmodule Apiary.Repo.Migrations.KeepAGrantSRule do
  use Ecto.Migration

  # The rule of a grant, `grant_rules` (`Apiary.Adapters.GrantRule`): a workspace chose
  # All for a grant, so every collection that a listing makes for that grant from then on
  # is assigned to that workspace (`Apiary.Adapters.Collections`). One rule per grant
  # (`grant_id`, unique), so a new collection goes to one workspace. `backlog` is true
  # when the rule was chosen in Work sources: a collection it assigns has its Backlog on.
  #
  # The grant, the workspace and the rule are held to one organisation by the composite
  # keys. Deleting a grant deletes its rule; a grant that ends and a workspace's purge
  # delete it too (`Apiary.Adapters.Collections.end_for_grant/2`,
  # `Apiary.Deletion.Tables`). The table is new, so its indexes are built inside the
  # transaction.
  def change do
    # The key that a rule's foreign key to its grant links to: the grant and its
    # organisation at once.
    create unique_index(:adapter_grants, [:id, :organisation_id])

    create table(:grant_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :grant_id,
          references(:adapter_grants,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :backlog, :boolean, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:grant_rules, [:grant_id])
    create index(:grant_rules, [:workspace_id])
    create index(:grant_rules, [:organisation_id])
  end
end
