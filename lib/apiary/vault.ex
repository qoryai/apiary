defmodule Apiary.Vault do
  @moduledoc """
  The encryption of the access key secrets at rest (Cloak): AES-256-GCM under the key
  `Apiary.KeyDerivation` derives from `APIARY_ENCRYPTION_SECRET` for the purpose
  `:access_keys`, never the secret's own bytes, which are only ever the input to the
  derivation. The key is set when the vault starts (`init/1`), from the secret that
  `config/runtime.exs`, `config/dev.exs` or `config/test.exs` gives the derivation.
  """
  use Cloak.Vault, otp_app: :apiary

  @impl GenServer
  def init(config) do
    {_key_id, key} = Apiary.KeyDerivation.key(:access_keys)

    {:ok,
     Keyword.put(config, :ciphers, default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key})}
  end
end
