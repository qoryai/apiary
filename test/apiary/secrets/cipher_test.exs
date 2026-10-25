defmodule Apiary.Secrets.CipherTest do
  # The instance's level of `Apiary.Secrets.Cipher` (v3): the associated data of a value of
  # an adapter's secret and of the instance's data key, byte for byte, and a value that
  # decrypts only where it was encrypted. The workspace's (v1) and the organisation's (v2)
  # are tested in `test/apiary/organisation_secrets_test.exs`.
  use ExUnit.Case, async: true

  alias Apiary.Secrets.Cipher

  @adapter_id "na_0123456789abcdef"
  @secret_id "sec_0123456789abcdef"
  @organisation_id "0b6f6c1e-8a4e-4b8e-9d55-3f1f3b0c7a10"

  test "v3 binds a value to its adapter, its secret and its value id, byte for byte" do
    assert Cipher.instance_value_aad(@adapter_id, @secret_id, "signing-key") ==
             <<0, 14>> <>
               "qory-secret-v3" <>
               <<0, 19>> <>
               @adapter_id <> <<0, 20>> <> @secret_id <> <<0, 11>> <> "signing-key"
  end

  test "v3 binds the instance's data key, byte for byte" do
    assert Cipher.instance_data_key_aad() ==
             <<0, 18>> <> "apiary-data-key-v3" <> <<0, 8>> <> "instance"

    refute Cipher.instance_data_key_aad() ==
             Cipher.organisation_data_key_aad(@organisation_id)
  end

  test "a value moved to another adapter, secret, value id or level does not decrypt" do
    key = Cipher.new_data_key()
    aad = Cipher.instance_value_aad(@adapter_id, @secret_id, "signing-key")
    {nonce, ciphertext} = Cipher.encrypt(key, aad, "plain")

    assert Cipher.decrypt(key, aad, nonce, ciphertext) == {:ok, "plain"}

    for other <- [
          Cipher.instance_value_aad("na_0123456789abcdeg", @secret_id, "signing-key"),
          Cipher.instance_value_aad(@adapter_id, "sec_0123456789abcdeg", "signing-key"),
          Cipher.instance_value_aad(@adapter_id, @secret_id, "event-secret"),
          Cipher.organisation_value_aad(@organisation_id, @secret_id, "signing-key")
        ] do
      assert Cipher.decrypt(key, other, nonce, ciphertext) == :error
    end
  end

  test "the instance's data key unwraps only with its associated data" do
    wrapping_key = Cipher.new_data_key()
    data_key = Cipher.new_data_key()
    wrapped = Cipher.wrap(wrapping_key, data_key, Cipher.instance_data_key_aad())

    assert byte_size(wrapped) == 60
    assert Cipher.unwrap(wrapping_key, wrapped, Cipher.instance_data_key_aad()) == {:ok, data_key}

    assert Cipher.unwrap(
             wrapping_key,
             wrapped,
             Cipher.organisation_data_key_aad(@organisation_id)
           ) ==
             :error
  end
end
