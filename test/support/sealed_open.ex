defmodule Apiary.SealedOpen do
  @moduledoc """
  SealedOpen opens a secrets answer (`secrets-answer.schema.json`) as the gateway does,
  for the tests: it verifies the envelope's signature under the server's public key,
  checks the identifiers against the ones given, and opens the HPKE base mode seal
  (RFC 9180, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-256-GCM) with the recipient's
  X25519 private key, with info and aad built from the given values.
  """

  alias Apiary.Contract.Ed25519
  alias Apiary.Secrets.Sealing

  @kem_suite "KEM" <> <<0x0020::16>>
  @hpke_suite "HPKE" <> <<0x0020::16, 0x0001::16, 0x0002::16>>

  @doc """
  x25519_private_key/1 is the X25519 private key of an access key whose Ed25519 seed is
  `seed`: the first 32 bytes of SHA-512(seed), which `:crypto` clamps when it uses them.
  """
  @spec x25519_private_key(<<_::256>>) :: <<_::256>>
  def x25519_private_key(<<_::binary-size(32)>> = seed),
    do: binary_part(:crypto.hash(:sha512, seed), 0, 32)

  @doc """
  open/2 opens `answer`, the bytes of a secrets answer, for `expected`: `access_key_id`,
  `run_id`, `run_configuration`, `signing_public_key` (32 raw bytes) and
  `x25519_private_key` (32 raw bytes). `{:ok, plaintext, envelope}`, the plaintext's bytes
  and the decoded envelope, or `{:error, step}` with the first step that failed.
  """
  @spec open(binary, map) :: {:ok, binary, map} | {:error, atom}
  def open(answer, expected) when is_binary(answer) do
    with {:ok, %{"version" => 1, "sealed" => sealed}} <- Jason.decode(answer),
         true <- sealed["suite"] == Sealing.suite() || {:error, :suite},
         {:ok, enc} <- decode(sealed["enc"]),
         {:ok, ct} <- decode(sealed["ct"]),
         {:ok, sig} <- decode(sealed["sig"]),
         true <- signed?(sealed, enc, ct, sig, expected.signing_public_key) || {:error, :sig},
         true <- identifiers?(sealed, expected) || {:error, :identifiers},
         {:ok, plaintext} <- hpke_open(enc, ct, sealed["exp"], expected) do
      {:ok, plaintext, sealed}
    else
      {:error, step} when is_atom(step) -> {:error, step}
      _other -> {:error, :answer}
    end
  end

  defp decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :base64}
    end
  end

  defp decode(_value), do: {:error, :base64}

  defp signed?(sealed, enc, ct, sig, public_key) do
    message =
      Enum.map_join(
        [
          "qory envelope v1",
          sealed["suite"],
          sealed["access_key_id"],
          sealed["run_id"],
          sealed["run_configuration"],
          Integer.to_string(sealed["exp"]),
          enc,
          ct
        ],
        &(<<byte_size(&1)::32>> <> &1)
      )

    Ed25519.verify(message, sig, public_key)
  end

  defp identifiers?(sealed, expected) do
    sealed["access_key_id"] == expected.access_key_id and sealed["run_id"] == expected.run_id and
      sealed["run_configuration"] == expected.run_configuration
  end

  defp hpke_open(enc, ct, exp, expected) do
    sk_r = expected.x25519_private_key
    {pk_r, _sk} = :crypto.generate_key(:ecdh, :x25519, sk_r)
    dh = :crypto.compute_key(:ecdh, enc, sk_r, :x25519)

    eae_prk = extract(@kem_suite, "", "eae_prk", dh)
    shared = expand(@kem_suite, eae_prk, "shared_secret", enc <> pk_r, 32)

    info = Sealing.info(expected.access_key_id)
    aad = Sealing.aad(expected.run_id, expected.access_key_id, expected.run_configuration, exp)

    psk_id_hash = extract(@hpke_suite, "", "psk_id_hash", "")
    info_hash = extract(@hpke_suite, "", "info_hash", info)
    context = <<0>> <> psk_id_hash <> info_hash
    secret = extract(@hpke_suite, shared, "secret", "")
    key = expand(@hpke_suite, secret, "key", context, 32)
    nonce = expand(@hpke_suite, secret, "base_nonce", context, 12)

    size = byte_size(ct) - 16
    <<body::binary-size(^size), tag::binary-size(16)>> = ct

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, body, aad, tag, false) do
      :error -> {:error, :open}
      plaintext -> {:ok, plaintext}
    end
  end

  defp extract(suite, salt, label, ikm),
    do: :crypto.mac(:hmac, :sha256, salt, ["HPKE-v1", suite, label, ikm])

  defp expand(suite, prk, label, info, length) do
    info = [<<length::16>>, "HPKE-v1", suite, label, info]

    {okm, _last} =
      Enum.reduce(1..div(length + 31, 32), {"", ""}, fn i, {okm, last} ->
        block = :crypto.mac(:hmac, :sha256, prk, [last, info, <<i>>])
        {okm <> block, block}
      end)

    binary_part(okm, 0, length)
  end
end
