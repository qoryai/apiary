defmodule Apiary.Repo.Migrations.KeepTheMailSettings do
  use Ecto.Migration

  # The mail settings an instance admin saves in Instance settings › Mail (`Apiary.Mail`),
  # in the instance's own row of `instance_settings`, used while `SMTP_RELAY` is not set:
  #
  # `smtp_relay`, `smtp_port`, `smtp_tls` (`always`, `if_available` or `never`),
  # `smtp_username` and `mail_from`, the relay and the sender, as the variables of the same
  # names set them;
  #
  # `smtp_password_ciphertext`, the relay's password, encrypted with AES-256-GCM under the
  # key derived for the purpose `mail` (`Apiary.KeyDerivation`): the nonce, the ciphertext
  # and the tag; `mail_key_id`, that key's id, present exactly when the password is;
  #
  # `mail_saved_at` and `mail_saved_by_id`, when and by whom they were saved last, and
  # `mail_verified_at`, when that admin followed the test link the save sent: mail is on
  # from then. A save sets it back to NULL.
  #
  # All NULL until an instance admin saves them: no row, or a row without a relay, is no
  # mail.
  def change do
    alter table(:instance_settings) do
      add :smtp_relay, :text
      add :smtp_port, :integer
      add :smtp_tls, :text
      add :smtp_username, :text
      add :mail_from, :text
      add :smtp_password_ciphertext, :binary
      add :mail_key_id, :text
      add :mail_saved_at, :utc_datetime_usec
      add :mail_saved_by_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :mail_verified_at, :utc_datetime_usec
    end

    create constraint(:instance_settings, :instance_settings_smtp_port_range,
             check: "smtp_port BETWEEN 1 AND 65535"
           )

    create constraint(:instance_settings, :instance_settings_smtp_tls_check,
             check: "smtp_tls IN ('always', 'if_available', 'never')"
           )

    # A password is stored with the id of the key it is encrypted under, and only with it:
    # at least the nonce (12 bytes) and the tag (16).
    create constraint(:instance_settings, :instance_settings_smtp_password_key,
             check:
               "(smtp_password_ciphertext IS NULL AND mail_key_id IS NULL) OR " <>
                 "(smtp_password_ciphertext IS NOT NULL AND mail_key_id IS NOT NULL AND " <>
                 "octet_length(smtp_password_ciphertext) >= 28 AND mail_key_id ~ '^[0-9a-f]{16}$')"
           )
  end
end
