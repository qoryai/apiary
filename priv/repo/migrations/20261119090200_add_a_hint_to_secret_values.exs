defmodule Apiary.Repo.Migrations.AddAHintToSecretValues do
  use Ecto.Migration

  # The last 4 characters of a model provider's key that is not a sign-in, written when
  # the key's value is set (`Apiary.Secrets.Value.hint/1`): the identity line of a key
  # shows them (`Apiary.ModelKeys.Identity`). A value of fewer than 12 characters has none,
  # so does a key saved before this column existed, and so does every other value: a
  # secret that is not a model provider's key keeps no part of its value. Nothing exists
  # to fill. Down drops the column and the hints with it.
  def change do
    alter table(:secret_values) do
      add :hint, :string
    end
  end
end
