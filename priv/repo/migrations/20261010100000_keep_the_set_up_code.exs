defmodule Apiary.Repo.Migrations.KeepTheSetUpCode do
  use Ecto.Migration

  # The instance's set-up link (`Apiary.Setup`), in its own row of `instance_settings`:
  #
  # `setup_code`: the code of the link `/setup/<code>`, 32 random bytes in base64url, 43
  # characters, stored as it is until it is used; NULL before a start has made one, and
  # once it is used.
  #
  # `set_up_at`: when the instance was set up, by the link or by the release command;
  # NULL before.
  #
  # A used code is gone: the two are never both set.
  def change do
    alter table(:instance_settings) do
      add :setup_code, :text
      add :set_up_at, :utc_datetime_usec
    end

    create constraint(:instance_settings, :instance_settings_setup_code_format,
             check: "setup_code ~ '^[A-Za-z0-9_-]{43}$'"
           )

    create constraint(:instance_settings, :instance_settings_setup_code_unused,
             check: "setup_code IS NULL OR set_up_at IS NULL"
           )
  end
end
