defmodule Apiary.Repo.Migrations.RecordTheInstancesKeys do
  use Ecto.Migration

  # What the instance records of its keys at its first boot, and compares at every boot
  # (`Apiary.KeyCheck`), in its own row of `instance_settings`:
  #
  # `encryption_secret_check`: the check value of APIARY_ENCRYPTION_SECRET, an HMAC-SHA256
  # of a fixed label under a key derived from it, 32 bytes, which tells nothing of the key.
  #
  # `signing_key_fingerprint`: the fingerprint of the signing key's public half, which every
  # machine pins, 22 characters of base64url.
  #
  # Both NULL until recorded, so a release before this one, which knows neither, runs on
  # this schema as it did.
  def change do
    alter table(:instance_settings) do
      add :encryption_secret_check, :binary
      add :signing_key_fingerprint, :text
    end

    create constraint(:instance_settings, :instance_settings_encryption_secret_check_length,
             check: "octet_length(encryption_secret_check) = 32"
           )

    create constraint(:instance_settings, :instance_settings_signing_key_fingerprint_format,
             check: "signing_key_fingerprint ~ '^[A-Za-z0-9_-]{22}$'"
           )
  end
end
