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
  The sender of every email Qory Apiary sends, as `{name, address}` for `Swoosh.Email.from/2`:
  `address`, or where it is `nil` the one `Apiary.Mail.sender/0` gives.

  That address is the sender saved in Instance settings › Mail while mail comes from
  there and it names one, else `config :apiary, :mail_from`, which production sets from
  `MAIL_FROM` (default `qory@<public host>`, see config/runtime.exs). Development and
  test fall back to `#{@default_from}`.
  """
  @spec from(String.t() | nil) :: {String.t(), String.t()}
  def from(address \\ nil) do
    {"Qory Apiary", address || Apiary.Mail.sender() || @default_from}
  end

  @doc """
  The address email is sent from when the settings saved in Instance settings › Mail name
  no sender: `config :apiary, :mail_from` (`Apiary.Mail.default_sender/0`), or
  `#{@default_from}` where it is not set.
  """
  @spec default_address() :: String.t()
  def default_address, do: Apiary.Mail.default_sender() || @default_from
end
