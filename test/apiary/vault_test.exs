defmodule Apiary.VaultTest do
  use ExUnit.Case, async: true

  alias Apiary.KeyDerivation

  test "the access key cipher's key is the derived :access_keys key, not the secret itself" do
    {:ok, config} = Cloak.Vault.read_config(:"Elixir.Apiary.Vault.Config")
    [default: {Cloak.Ciphers.AES.GCM, cipher}] = config[:ciphers]

    {_key_id, derived} = KeyDerivation.key(:access_keys)
    secret = Application.fetch_env!(:apiary, KeyDerivation)[:secret]

    assert cipher[:key] == derived
    refute cipher[:key] == secret

    for {purpose, _info} <- KeyDerivation.purposes(), purpose != :access_keys do
      refute cipher[:key] == elem(KeyDerivation.key(purpose), 1)
    end

    {:ok, ciphertext} = Apiary.Vault.encrypt("an access key secret")
    assert Apiary.Vault.decrypt(ciphertext) == {:ok, "an access key secret"}
  end
end
