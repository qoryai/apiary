defmodule Apiary.Mailer do
  @moduledoc """
  The application's Swoosh mailer. Email is sent through `Apiary.Accounts.UserNotifier`,
  which delivers with the configuration `Apiary.Mail.mailer_config/0` gives, and sends
  nothing when no mail is set. In production without `SMTP_RELAY` the mailer has no
  adapter (`config/runtime.exs`).
  """
  use Swoosh.Mailer, otp_app: :apiary

  @default_from "qory@localhost"

  @doc """
  The sender of every email Qory Apiary sends, as `{name, address}` for `Swoosh.Email.from/2`.

  The address comes from `config :apiary, :mail_from`, which production sets from
  `MAIL_FROM` (default `qory@<public host>`, see config/runtime.exs). Development and
  test fall back to `#{@default_from}`.
  """
  def from do
    {"Qory Apiary", Application.get_env(:apiary, :mail_from) || @default_from}
  end
end
