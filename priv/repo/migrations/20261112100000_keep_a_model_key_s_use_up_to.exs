defmodule Apiary.Repo.Migrations.KeepAModelKeySUseUpTo do
  use Ecto.Migration

  # A model key's Use up to percentage (`Apiary.ModelKeys.Setting`):
  # `model_key_settings.use_up_to_percent`, a whole percent from 1 to 99, nullable. While
  # a window of the key that its provider's catalogue entry lists in `limit_windows` has a
  # stored utilization at or above it, runs skip the key until that window resets. Null:
  # runs use the key up to the provider's limit. It changes no row.
  def change do
    alter table(:model_key_settings) do
      add :use_up_to_percent, :smallint
    end

    create constraint(:model_key_settings, :model_key_settings_use_up_to_percent_check,
             check: "use_up_to_percent IS NULL OR use_up_to_percent BETWEEN 1 AND 99"
           )
  end
end
