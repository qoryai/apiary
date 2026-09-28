defmodule Apiary.Repo.Migrations.CreateTheInstancesOwnTables do
  use Ecto.Migration

  # The two tables that are the instance's own, with no `organisation_id`, so neither is one
  # the purge walks (`Apiary.Deletion.Tables`).
  #
  # `purged_organisations`: the one line the instance keeps of an organisation it purged,
  # written in the transaction that deletes the organisation's row (`Apiary.Deletion`), since
  # the organisation's own audit trail goes with it: its id, when it was marked for deletion
  # and by whom (none for the instance), when it was purged, and why: `grace_period` for a
  # deletion the daily sweep purged, `erasure_request` for a purge at once, with the instance
  # admin who asked for it. No name and no slug.
  #
  # `instance_settings`: the instance's settings, in one row at most. Its key is a boolean
  # that the check holds to true, so a second row has no key left to take. `product_name` is
  # the product's name on this instance, which an instance admin changes; NULL is "Qory
  # Apiary". `updated_by_id` is who changed it last. No row is the defaults.
  def change do
    create table(:purged_organisations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :marked_at, :utc_datetime_usec, null: false
      add :marked_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :purged_at, :utc_datetime_usec, null: false
      add :trigger, :text, null: false
      add :requested_by_id, references(:users, type: :binary_id, on_delete: :nothing)
    end

    create constraint(:purged_organisations, :purged_organisations_trigger_check,
             check: "trigger IN ('grace_period', 'erasure_request')"
           )

    create table(:instance_settings, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :product_name, :text
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:instance_settings, :instance_settings_one_row_check, check: "id")
  end
end
