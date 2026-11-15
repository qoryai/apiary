defmodule Apiary.Repo.Migrations.KeepTheOperatorOfAWorkspace do
  use Ecto.Migration

  # The operator of a workspace (`ApiaryPro.Operators.WorkspaceOperator`), one row per
  # operated workspace: `workspace_id` and its organisation, `operator_id`, the operator
  # that manages the workspace, and `since`, since when. A workspace without a row has no
  # operator. The table starts empty, and no code writes it.
  #
  # The database keeps the rules:
  #
  # - At most one operator per workspace: `workspace_id` is the primary key. The row goes
  #   with its workspace, by the key `(organisation_id, workspace_id)`.
  # - The operator is an organisation of the kind `operator`: `operator_kind` is
  #   generated, always `operator`, and `(operator_id, operator_kind)` is a foreign key to
  #   `tenants (organisation_id, kind)`. An operator that operates a workspace can neither
  #   become an organisation nor go while a row references it (no action).
  # - An operator does not operate a workspace of its organisation.
  def change do
    create table(:workspace_operators, primary_key: false) do
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
          primary_key: true

      add :operator_id, :binary_id, null: false
      add :operator_kind, :text, generated: "ALWAYS AS ('operator') STORED"
      add :since, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
      ALTER TABLE workspace_operators ADD CONSTRAINT workspace_operators_operator_fkey
        FOREIGN KEY (operator_id, operator_kind) REFERENCES tenants (organisation_id, kind)
      """,
      "ALTER TABLE workspace_operators DROP CONSTRAINT workspace_operators_operator_fkey"
    )

    create index(:workspace_operators, [:operator_id])
    create index(:workspace_operators, [:organisation_id])

    create constraint(:workspace_operators, :workspace_operators_not_its_organisation,
             check: "operator_id <> organisation_id"
           )
  end
end
