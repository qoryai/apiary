defmodule Apiary.Repo.Migrations.NameTheForagerVersion do
  use Ecto.Migration

  # The program that sends a run's events is Forager, and the version it reports is
  # `forager_version`: the columns that keep it take its name.
  def change do
    rename table(:runs), :runner_version, to: :forager_version
    rename table(:access_keys), :last_runner_version, to: :last_forager_version
    rename table(:node_instances), :last_runner_version, to: :last_forager_version
  end
end
