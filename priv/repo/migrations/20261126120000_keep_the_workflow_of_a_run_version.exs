defmodule Apiary.Repo.Migrations.KeepTheWorkflowOfARunVersion do
  use Ecto.Migration

  # `workflow` of `artifact_versions`: the workflow of the run's session that pushed the
  # version (`Apiary.Artifacts.push/5`) or withdrew its name
  # (`Apiary.Artifacts.withdraw/4`), nil for a person's version and for a run with no
  # workflow. A version stored before this column stays nil.
  def change do
    alter table(:artifact_versions) do
      add :workflow, :text
    end
  end
end
