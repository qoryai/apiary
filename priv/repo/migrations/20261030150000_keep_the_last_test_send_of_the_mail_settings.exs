defmodule Apiary.Repo.Migrations.KeepTheLastTestSendOfTheMailSettings do
  use Ecto.Migration

  # The last test link sent through the mail settings saved in Instance settings › Mail
  # (`Apiary.Mail`), by a save or by Send the test link again:
  #
  # `mail_test_sent_at`, when it was sent, which allows one test send a minute;
  # `mail_test_result`, its result: `sent` where the relay accepted the email, else why it
  # did not, by class; `mail_test_reply_code`, the relay's reply code, such as `550 5.7.1`,
  # where the result has one. The relay's reply text is never stored: it can contain the
  # relay's host and this server's IP address.
  #
  # All NULL until a test link is sent; `mail_test_result` NULL while a send runs.
  def change do
    alter table(:instance_settings) do
      add :mail_test_sent_at, :utc_datetime_usec
      add :mail_test_result, :text
      add :mail_test_reply_code, :text
    end

    create constraint(:instance_settings, :instance_settings_mail_test_result_check,
             check:
               "mail_test_result IN ('sent', 'connect', 'tls', 'login', 'sender', " <>
                 "'rejected', 'temporary', 'other')"
           )

    # A reply code and an enhanced status code: digits, dots and one space.
    create constraint(:instance_settings, :instance_settings_mail_test_reply_code_check,
             check:
               "char_length(mail_test_reply_code) <= 16 AND " <>
                 "mail_test_reply_code ~ '^[0-9]{3}( [0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})?$'"
           )
  end
end
