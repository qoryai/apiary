defmodule Apiary.Repo.Migrations.CreateInstanceBranding do
  use Ecto.Migration

  # Whether the instance hides "Powered by Qory Apiary" (`hide_attribution`), in one row at
  # most: its key is a boolean that the check keeps true, so a second row has no key left to
  # take, as the core's `instance_settings`. No code reads or writes the table: whether pages
  # and emails show "Powered by Qory Apiary" is `Apiary.ProductName.powered_by?/0` alone.
  # `updated_by_id` is who changed the row last. No row is the defaults. A table of the
  # instance, with no `organisation_id`.
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
