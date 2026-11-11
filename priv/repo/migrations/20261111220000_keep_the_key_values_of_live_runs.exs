defmodule Apiary.Repo.Migrations.KeepTheKeyValuesOfLiveRuns do
  use Ecto.Migration

  # A copy of the key value each live run has (`model_key_copies`), for a run registered
  # before the upgrade, whose secrets request kept no copy: a row for each pending or
  # running run and each of its model keys (`runs.model_keys`), with the key's
  # `secret_values.value_set_at`. A key whose row of `secret_values` is gone gets no row,
  # and a run and key that have a copy keep it as it is.
  #
  # Without it, such a run is compared by the time its row was written. 20261111190000
  # fills `value_set_at` from `updated_at`, which a rename before the upgrade also moved,
  # so a key renamed after the run was written read as set since the run, and the run's
  # reports of it were left out (`Apiary.ModelKeys.record/3`). A key whose value changed
  # before the upgrade, after the run got the old value, gets the new value's time: that
  # run's reports of the old value count for the new one until its next secrets request.
  #
  # Rolled back, it changes nothing: its rows cannot be told apart from those of a secrets
  # request, which 20261111190000 rolled back takes away with the table.
  def up do
    execute("""
    INSERT INTO model_key_copies (run_id, secret_value_id, value_set_at)
    SELECT r.id, v.id, v.value_set_at
    FROM runs r
    CROSS JOIN LATERAL jsonb_array_elements(r.model_keys) k
    JOIN secret_values v
      ON v.id = (k ->> 'id')::uuid AND v.secret_id = r.provider_secret_id
    WHERE r.state IN ('pending', 'running')
    ON CONFLICT (run_id, secret_value_id) DO NOTHING
    """)
  end

  def down, do: :ok
end
