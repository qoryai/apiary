defmodule Apiary.Vault do
  @moduledoc """
  The application-held encryption key for secrets at rest.

  Configured under `config :apiary, Apiary.Vault` with a `:ciphers` list; the
  production key comes from the `CLOAK_KEY` environment variable (32 bytes,
  base64) and is read in `config/runtime.exs`.
  """
  use Cloak.Vault, otp_app: :apiary
end
