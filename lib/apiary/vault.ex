defmodule Apiary.Vault do
  @moduledoc """
  The application-held encryption key for secrets at rest.

  Configured under `config :apiary, Apiary.Vault` with a `:ciphers` list; the
  production key comes from the `APIARY_ENCRYPTION_SECRET` environment variable (32
  bytes, base64) and is read in `config/runtime.exs`.
  """
  use Cloak.Vault, otp_app: :apiary
end
