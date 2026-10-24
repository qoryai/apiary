defmodule Apiary.Secrets.HpkeTest do
  # `Apiary.Secrets.Hpke`: a seal opens with the recipient's private key under the same
  # info and associated data, and under nothing else. The seal's known answers are the
  # Forager contract's, in `test/apiary/secrets/sealing_test.exs`.
  use ExUnit.Case, async: true

  alias Apiary.Secrets.Hpke

  setup do
    sk_r = :crypto.strong_rand_bytes(32)
    {pk_r, _sk} = :crypto.generate_key(:ecdh, :x25519, sk_r)
    %{sk_r: sk_r, pk_r: pk_r}
  end

  test "a seal opens with the recipient's private key", %{sk_r: sk_r, pk_r: pk_r} do
    assert {:ok, enc, ct} =
             Hpke.seal(fn -> :crypto.strong_rand_bytes(32) end, pk_r, "info", "aad", "plain")

    assert byte_size(enc) == 32
    assert byte_size(ct) == byte_size("plain") + 16
    assert Hpke.open(sk_r, enc, "info", "aad", ct) == {:ok, "plain"}
  end

  test "opens under no other info, associated data, key or ciphertext", %{sk_r: sk_r, pk_r: pk_r} do
    {:ok, enc, ct} =
      Hpke.seal(fn -> :crypto.strong_rand_bytes(32) end, pk_r, "info", "aad", "plain")

    <<first, rest::binary>> = ct

    assert Hpke.open(sk_r, enc, "other", "aad", ct) == :error
    assert Hpke.open(sk_r, enc, "info", "other", ct) == :error
    assert Hpke.open(:crypto.strong_rand_bytes(32), enc, "info", "aad", ct) == :error
    assert Hpke.open(sk_r, enc, "info", "aad", <<Bitwise.bxor(first, 1), rest::binary>>) == :error
    assert Hpke.open(sk_r, enc, "info", "aad", binary_part(ct, 0, 15)) == :error
    assert Hpke.open(sk_r, <<0::256>>, "info", "aad", ct) == :error
    assert Hpke.open(sk_r, binary_part(enc, 0, 31), "info", "aad", ct) == :error
  end

  test "a recipient key that is not a key is refused without its bytes in the answer" do
    assert Hpke.seal(fn -> :crypto.strong_rand_bytes(32) end, <<1, 2, 3>>, "info", "aad", "plain") ==
             {:error, :key}

    assert Hpke.seal(fn -> :crypto.strong_rand_bytes(32) end, <<0::256>>, "info", "aad", "plain") ==
             {:error, :key}
  end
end
