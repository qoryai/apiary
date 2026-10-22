defmodule Apiary.Repo.Migrations.KeepAStackAtEachLevel do
  use Ecto.Migration

  # The stack a run uses, set at a level of an organisation (`Apiary.Stacks.Stack`): a
  # stack name or a stack reference (`Apiary.Contract.Stack`). A row is at one of five
  # levels, by the columns it has set:
  #
  #   * a target and a workflow: `workspace_id`, `target_id` and `workflow`;
  #   * a target: `workspace_id` and `target_id`;
  #   * the workspace and a workflow: `workspace_id` and `workflow`;
  #   * the workspace: `workspace_id`;
  #   * the organisation's default: neither.
  #
  # `saved_by_organisation_id` is the organisation a member saved the value in, NULL for
  # a value saved any other way (`Apiary.Stacks.saved_by/1`); it becomes NULL when that
  # organisation is deleted. One row per place: the unique index
  # reads a missing workspace or target as the nil UUID and a missing workflow as the
  # empty text. A target or a workspace takes its rows with it. The check on `stack`
  # takes a name, or an `https://` text of at most 2,560 characters; `Apiary.Stacks`
  # checks a reference in full before it saves one.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def change do
    create table(:stacks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :simple,
            on_delete: :delete_all
          )

      add :target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :simple,
            on_delete: :delete_all
          )

      add :workflow, :text
      add :stack, :text, null: false

      add :saved_by_organisation_id,
          references(:organisations, type: :binary_id, on_delete: :nilify_all)

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:stacks, :stacks_workflow_format,
             check: "workflow ~ '^[a-z][a-z0-9-]{0,63}$'"
           )

    create constraint(:stacks, :stacks_stack_format,
             check: """
             stack ~ '^[a-z][a-z0-9-]{0,63}$'
             OR (stack LIKE 'https://%' AND char_length(stack) <= 2560)
             """
           )

    create constraint(:stacks, :stacks_shape_check,
             check: """
             (target_id IS NULL OR workspace_id IS NOT NULL)
             AND (workflow IS NULL OR workspace_id IS NOT NULL)
             """
           )

    create unique_index(
             :stacks,
             [
               :organisation_id,
               "COALESCE(workspace_id, #{@nobody})",
               "COALESCE(target_id, #{@nobody})",
               "COALESCE(workflow, '')"
             ],
             name: :stacks_place_index
           )

    create index(:stacks, [:workspace_id])
    create index(:stacks, [:target_id])
    create index(:stacks, [:saved_by_organisation_id])
    create index(:stacks, [:created_by_id])
    create index(:stacks, [:updated_by_id])
  end
end
