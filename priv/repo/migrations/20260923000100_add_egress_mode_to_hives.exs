defmodule Apiary.Repo.Migrations.AddEgressModeToHives do
  use Ecto.Migration

  # Expand only. The mode of the hive's security policy, `observe` or `enforce`; every hive
  # that exists starts in `observe`, which denies nothing, so an upgrade changes no run.
  def change do
    alter table(:hives) do
      add :egress_mode, :text, null: false, default: "observe"
    end

    create constraint(:hives, :hives_egress_mode_check,
             check: "egress_mode IN ('observe', 'enforce')"
           )
  end
end
