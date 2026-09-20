defmodule Apiary.Repo.Migrations.AddRetentionToHives do
  use Ecto.Migration

  # Expand only. How long the hive keeps a run's events and a run's log bytes, in days,
  # each on its own; null is unlimited, which is what every hive that exists gets, so an
  # upgrade prunes nothing.
  def change do
    alter table(:hives) do
      add :events_retention_days, :integer
      add :log_retention_days, :integer
    end

    create constraint(:hives, :hives_events_retention_days_check,
             check: "events_retention_days BETWEEN 1 AND 3650"
           )

    create constraint(:hives, :hives_log_retention_days_check,
             check: "log_retention_days BETWEEN 1 AND 3650"
           )
  end
end
