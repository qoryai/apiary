defmodule Apiary.Repo.Migrations.KeepTheUsedPresetCode do
  use Ecto.Migration

  # `used_setup_code_sha256`: the SHA-256 of the preset set-up code that set the instance
  # up (`QORY_SETUP_CODE_SHA256`, `Apiary.Setup`), 32 bytes; NULL until a preset sets it
  # up. A preset equal to it is refused, so a preset sets an instance up once, a set-up
  # after a purge of the instance's organisation included.
  def change do
    alter table(:instance_settings) do
      add :used_setup_code_sha256, :binary
    end

    create constraint(:instance_settings, :instance_settings_used_setup_code_sha256_length,
             check: "octet_length(used_setup_code_sha256) = 32"
           )
  end
end
