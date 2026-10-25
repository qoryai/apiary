defmodule Apiary.Repo.Migrations.KeepTheInstanceDataKey do
  use Ecto.Migration

  # `instance_data_keys`: the instance's data key, 32 random bytes that encrypt the values
  # of the instance's secrets (`Apiary.Secrets.Instance`), kept only wrapped under the
  # instance's values key, as a workspace's and an organisation's are. One row at most: its
  # `id` is `true` and the check `instance_data_keys_one_row` refuses any other. The row is
  # made with the instance's first secret; this migration makes none.
  def change do
    create table(:instance_data_keys, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :wrapped_key, :binary, null: false
      add :wrapping_key_id, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:instance_data_keys, :instance_data_keys_one_row, check: "id")

    create constraint(:instance_data_keys, :instance_data_keys_wrapped_key_check,
             check: "octet_length(wrapped_key) = 60"
           )
  end
end
