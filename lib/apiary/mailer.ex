defmodule Apiary.Mailer do
  use Swoosh.Mailer, otp_app: :apiary

  @default_from "apiary@localhost"

  @doc """
  The sender of every email Apiary sends, as `{name, address}` for `Swoosh.Email.from/2`.

  The address comes from `config :apiary, :mail_from`, which production sets from
  `MAIL_FROM` (default `apiary@<public host>`, see config/runtime.exs). Development and
  test fall back to `#{@default_from}`.
  """
  def from do
    {"Apiary", Application.get_env(:apiary, :mail_from) || @default_from}
  end
end
