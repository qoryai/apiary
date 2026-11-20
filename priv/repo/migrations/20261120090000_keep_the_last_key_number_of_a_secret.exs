defmodule Apiary.Repo.Migrations.KeepTheLastKeyNumberOfASecret do
  use Ecto.Migration

  # The number `n` of the last value id `key-<n>` that Apiary gave a secret's value
  # (`secrets.last_key_number`, `Apiary.Secrets.next_key_id/1`): the next key of a model
  # provider takes the number after it, so a number is never given twice, even after the
  # key that had it is deleted. A secret starts at the highest `key-<n>` its values have
  # now, 1 to 9 digits (0 for none); a value id of another form does not count. No value is
  # read or changed, and the associated data of a value does not change. Down drops the
  # column.
  def up do
    alter table(:secrets) do
      add :last_key_number, :integer, null: false, default: 0
    end

    execute("""
    UPDATE secrets s
    SET last_key_number = k.highest
    FROM (
      SELECT secret_id, max(substring(value_id FROM 5)::integer) AS highest
      FROM secret_values
      WHERE value_id ~ '^key-[0-9]{1,9}$'
      GROUP BY secret_id
    ) k
    WHERE s.id = k.secret_id
    """)
  end

  def down do
    alter table(:secrets) do
      remove :last_key_number
    end
  end
end
