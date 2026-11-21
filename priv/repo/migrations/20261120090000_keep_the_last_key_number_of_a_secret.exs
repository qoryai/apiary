defmodule Apiary.Repo.Migrations.KeepTheLastKeyNumberOfASecret do
  use Ecto.Migration

  # The number `n` of the last value id `key-<n>` that Apiary gave a secret's value
  # (`secrets.last_key_number`, `Apiary.Secrets.next_key_id/1`): the next key of a model
  # provider takes the number after it, so a number is never given twice, even after the
  # key that had it is deleted. A secret starts at 0 and `Apiary.Secrets.create_provider_keys/4`
  # sets it for the keys the secret starts with. No value is read or changed. Down drops the
  # column.
  def change do
    alter table(:secrets) do
      add :last_key_number, :integer, null: false, default: 0
    end
  end
end
