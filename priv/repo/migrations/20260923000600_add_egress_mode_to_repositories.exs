defmodule Apiary.Repo.Migrations.AddEgressModeToRepositories do
  use Ecto.Migration

  # Expand only. A repository's own mode, `observe` or `enforce`; null, the default and
  # what every repository that exists gets, follows the hive's. Nothing changes for a run
  # until somebody sets one.
  def change do
    alter table(:repositories) do
      add :egress_mode, :text
    end

    create constraint(:repositories, :repositories_egress_mode_check,
             check: "egress_mode IS NULL OR egress_mode IN ('observe', 'enforce')"
           )
  end
end
