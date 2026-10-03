defmodule Apiary.KeyDerivationTest do
  # Not async: the secret is the application's configuration, set for a test and put
  # back after it.
  use ExUnit.Case, async: false

  alias Apiary.KeyDerivation

  # The secret 00 01 02 … 1f. The expected keys and key ids were computed outside the
  # application, with Python's hmac and hashlib.
  @secret :binary.list_to_bin(Enum.to_list(0..31))
  @known %{
    values:
      {"177466b95597544b", "9cb21f43cb1109e63ad703da4ed8d6fafff5e4686ca53a32b1fcaef824452080"},
    integrity:
      {"00c237515a3185d8", "d1ab9a54546e72272622c028ba38845262ea3a0732b383b1dc888841c8519bbf"},
    envelope_signing:
      {"263a8e3cde68784b", "152f1493707535f6910c20635b1d92f0e5163efe832bc1545e224c0b5504e65f"}
  }

  setup do
    previous = Application.get_env(:apiary, KeyDerivation)
    Application.put_env(:apiary, KeyDerivation, secret: @secret)
    on_exit(fn -> Application.put_env(:apiary, KeyDerivation, previous) end)
  end

  test "hkdf/4 gives RFC 5869's first test case" do
    ikm = :binary.copy(<<0x0B>>, 22)
    salt = Base.decode16!("000102030405060708090A0B0C")
    info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")

    assert Base.encode16(KeyDerivation.hkdf(ikm, salt, info, 42), case: :lower) ==
             "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
  end

  test "each purpose's key and key id are the known answers" do
    for {purpose, {key_id, key}} <- @known do
      assert KeyDerivation.key(purpose) == {key_id, Base.decode16!(key, case: :lower)}
    end
  end

  test "each key is HKDF-SHA256 of the secret, salt apiary/kdf/v1 and the purpose's info" do
    for {purpose, info} <- KeyDerivation.purposes() do
      {key_id, key} = KeyDerivation.key(purpose)
      assert key == hkdf_by_hand(@secret, "apiary/kdf/v1", info)
      assert key_id == KeyDerivation.key_id(key)
      assert key_id =~ ~r/\A[0-9a-f]{16}\z/
    end
  end

  test "the purposes' keys differ, and so do their key ids" do
    keys = Enum.map(Map.keys(KeyDerivation.purposes()), &KeyDerivation.key/1)
    assert length(Enum.uniq_by(keys, &elem(&1, 0))) == length(keys)
    assert length(Enum.uniq_by(keys, &elem(&1, 1))) == length(keys)
  end

  test "another secret gives other keys, with other key ids" do
    {key_id, key} = KeyDerivation.key(:values)
    Application.put_env(:apiary, KeyDerivation, secret: :binary.copy(<<7>>, 32))
    {other_id, other} = KeyDerivation.key(:values)

    refute other == key
    refute other_id == key_id
    # The earlier key id is one this instance no longer holds.
    assert KeyDerivation.key(:values, key_id) == :error
    assert KeyDerivation.key(:values, other_id) == {:ok, other}
  end

  test "key/2 finds the current key by its id, and nothing for another id" do
    {key_id, key} = KeyDerivation.key(:integrity)
    assert KeyDerivation.key(:integrity, key_id) == {:ok, key}
    assert KeyDerivation.key(:integrity, "0000000000000000") == :error
    {values_id, _key} = KeyDerivation.key(:values)
    assert KeyDerivation.key(:integrity, values_id) == :error
  end

  test "a purpose that is none, and a secret that is not 32 bytes, raise" do
    assert_raise ArgumentError, fn -> KeyDerivation.key(:other) end

    for secret <- [nil, "", :binary.copy(<<1>>, 31), :binary.copy(<<1>>, 33)] do
      Application.put_env(:apiary, KeyDerivation, secret: secret)

      assert_raise ArgumentError, ~r/APIARY_ENCRYPTION_SECRET/, fn ->
        KeyDerivation.key(:values)
      end
    end
  end

  # HKDF-SHA256 for one block, written out from RFC 5869: extract, then T(1).
  defp hkdf_by_hand(ikm, salt, info) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end
end
