defmodule Apiary.Repo.Migrations.KeyAModelChoiceByWorkflow do
  use Ecto.Migration

  # A model choice of levels 2 and 4 is set for a workflow (`model_choices.workflow`), the
  # name the machines file gives a workspace's workflow, as a time limit is
  # (`time_limits.workflow`), where it was set for a step of the queue (`run_kind`). The
  # column is renamed and keeps its values; its check is the machines file's name rule: a
  # lower-case letter, then up to 63 lower-case letters, digits and hyphens. The unique
  # index of a place reads the renamed column.
  def up do
    drop constraint(:model_choices, :model_choices_run_kind_format)
    rename table(:model_choices), :run_kind, to: :workflow

    create constraint(:model_choices, :model_choices_workflow_format,
             check: "workflow ~ '^[a-z][a-z0-9-]{0,63}$'"
           )
  end

  def down do
    drop constraint(:model_choices, :model_choices_workflow_format)
    rename table(:model_choices), :workflow, to: :run_kind

    create constraint(:model_choices, :model_choices_run_kind_format,
             check: "run_kind ~ '^[a-z][a-z_]{0,39}$'"
           )
  end
end
