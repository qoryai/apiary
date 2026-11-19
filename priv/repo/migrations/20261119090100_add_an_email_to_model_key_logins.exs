defmodule Apiary.Repo.Migrations.AddAnEmailToModelKeyLogins do
  use Ecto.Migration

  # The email of a sign-in (`Apiary.ModelKeys.Login`): the `email` claim of the `id_token`
  # that the device sign-in returned, read once when the person signs in and the only data
  # of the `id_token` that is kept. The key's identity line shows it
  # (`Apiary.ModelKeys.Identity`). Nil for a sign-in saved before this column existed, and
  # for an `id_token` without the claim; the identity line then shows the account. Nothing
  # exists to fill. Down drops the column and the emails with it.
  def change do
    alter table(:model_key_logins) do
      add :email, :string
    end
  end
end
