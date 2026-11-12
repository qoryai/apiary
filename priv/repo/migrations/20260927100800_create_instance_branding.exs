defmodule Apiary.Repo.Migrations.CreateInstanceBranding do
  use Ecto.Migration

  # How a white-labelled instance presents itself, in one row at most: its key is a boolean
  # that the check holds to true, so a second row has no key left to take, as the core's
  # `instance_settings`. `hide_attribution` hides "Powered by Qory Apiary" where the core
  # shows it; it applies only while the licence has white label, so it is a choice kept, not
  # a right that outlives the licence. `updated_by_id` is who changed it last. No row is the
  # defaults. The instance's own table, with no `organisation_id`.
  def change do
    create table(:instance_branding, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :hide_attribution, :boolean, null: false, default: false
      add :updated_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:instance_branding, :instance_branding_one_row_check, check: "id")
  end
end
