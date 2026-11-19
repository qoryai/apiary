defmodule Apiary.Repo.Migrations.CreateModelKeyRejections do
  use Ecto.Migration

  # The keys whose provider returned 401 to a run's request, as the run's gateway reports it
  # (`Apiary.ModelKeys.Report`, `unauthorized`): one row per such key, by the value's row id
  # (`secret_values.id`), which a rename of the value id leaves as it is. The key needs a new
  # value until it gets one, and runs skip it meanwhile (`Apiary.ModelKeys.Rejection`).
  #
  #   * `rejected_at`: when the provider's 401 arrived, the gateway's clock, from the
  #     report;
  #   * `value_set_at`: the key's `secret_values.value_set_at` when the row was written. A
  #     row counts only while the key's `value_set_at` is still this time, so a new value,
  #     written by any path, ends it, even a value equal to the old one;
  #   * `updated_at`: when this server wrote the row.
  #
  # The row is of the key's organisation: the composite key to `secret_values` holds
  # `organisation_id` to the value's, as `model_key_states` does. The row goes with the
  # value (`ON DELETE CASCADE`). Nothing exists to fill. Down drops the table.
  def change do
    create table(:model_key_rejections, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :secret_value_id,
          references(:secret_values,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true

      add :rejected_at, :utc_datetime_usec, null: false
      add :value_set_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:model_key_rejections, [:organisation_id])
  end
end
