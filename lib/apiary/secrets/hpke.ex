defmodule Apiary.Secrets.Hpke do
  @moduledoc """
  HPKE base mode (RFC 9180), single shot, with the suite `x25519-sha256-aes256gcm`:
  DHKEM(X25519, HKDF-SHA256) 0x0020, HKDF-SHA256 0x0001 and AES-256-GCM 0x0002, with
  `:crypto`. Pure functions: nothing here touches the database or writes a log line.

  `seal/5` seals to a recipient's X25519 public key with an ephemeral key it makes from a
  function, so no caller's frame contains that key. `open/5` opens with the recipient's
  X25519 private key. Both refuse an all-zero shared secret (RFC 9180, 7.1.4). Any
  exception of `:crypto` is dropped with its stack trace, whose top frame can contain a
  key among its arguments: a seal answers `{:error, :key}` and an open `:error`, and
  nothing of a key, the shared secret or a plaintext leaves this module in an error.
  """

  @kem_id 0x0020
  @kdf_id 0x0001
  @aead_id 0x0002

  # The suite ids as RFC 9180 prefixes its labels: the KEM's alone, and the whole suite's.
  @kem_suite "KEM" <> <<@kem_id::16>>
  @hpke_suite "HPKE" <> <<@kem_id::16, @kdf_id::16, @aead_id::16>>

  @doc "suite_ids/0 is the suite's three ids as u16 big-endian, as an `info` contains them."
  @spec suite_ids() :: <<_::48>>
  def suite_ids, do: <<@kem_id::16, @kdf_id::16, @aead_id::16>>

  @doc """
  seal/5 seals `pt` to the X25519 public key `pk_r` under `info` and `aad`. `ephemeral`
  is a function of no arguments that returns the ephemeral private key. The answer is
  `{:ok, enc, ct}`, `enc` the ephemeral public key and `ct` the ciphertext with its
  16-byte tag, or `{:error, :key}`.
  """
  @spec seal((-> <<_::256>>), <<_::256>>, binary, binary, binary) ::
          {:ok, <<_::256>>, binary} | {:error, :key}
  def seal(ephemeral, pk_r, info, aad, pt) when is_function(ephemeral, 0) do
    do_seal(ephemeral, pk_r, info, aad, pt)
  rescue
    _exception -> {:error, :key}
  catch
    _kind, _reason -> {:error, :key}
  end

  defp do_seal(ephemeral, pk_r, info, aad, pt) do
    {pk_e, sk_e} = :crypto.generate_key(:ecdh, :x25519, ephemeral.())
    dh = :crypto.compute_key(:ecdh, pk_r, sk_e, :x25519)

    # An all-zero shared secret is refused (RFC 9180, 7.1.4); a key that passes the key
    # checks never gives one.
    if dh == <<0::256>> do
      {:error, :key}
    else
      {key, nonce} = schedule(dh, pk_e, pk_r, info)
      {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, pt, aad, 16, true)
      {:ok, pk_e, ct <> tag}
    end
  end

  @doc """
  open/5 opens `ct`, the ciphertext with its 16-byte tag, sealed with the ephemeral public
  key `enc` to the X25519 private key `sk_r`, under `info` and `aad`: `{:ok, pt}`, or
  `:error` for anything that does not open.
  """
  @spec open(<<_::256>>, binary, binary, binary, binary) :: {:ok, binary} | :error
  def open(sk_r, enc, info, aad, ct)
      when byte_size(sk_r) == 32 and byte_size(enc) == 32 and is_binary(info) and
             is_binary(aad) and is_binary(ct) and byte_size(ct) >= 16 do
    do_open(sk_r, enc, info, aad, ct)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  def open(_sk_r, _enc, _info, _aad, _ct), do: :error

  defp do_open(sk_r, enc, info, aad, ct) do
    {pk_r, _sk} = :crypto.generate_key(:ecdh, :x25519, sk_r)
    dh = :crypto.compute_key(:ecdh, enc, sk_r, :x25519)

    if dh == <<0::256>> do
      :error
    else
      {key, nonce} = schedule(dh, enc, pk_r, info)
      size = byte_size(ct) - 16
      <<body::binary-size(^size), tag::binary-size(16)>> = ct

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, body, aad, tag, false) do
        pt when is_binary(pt) -> {:ok, pt}
        :error -> :error
      end
    end
  end

  # The key schedule of base mode: the AEAD key and base nonce from the shared secret.
  defp schedule(dh, enc, pk_r, info) do
    eae_prk = labeled_extract(@kem_suite, "", "eae_prk", dh)
    shared = labeled_expand(@kem_suite, eae_prk, "shared_secret", enc <> pk_r, 32)

    psk_id_hash = labeled_extract(@hpke_suite, "", "psk_id_hash", "")
    info_hash = labeled_extract(@hpke_suite, "", "info_hash", info)
    context = <<0>> <> psk_id_hash <> info_hash
    secret = labeled_extract(@hpke_suite, shared, "secret", "")

    {labeled_expand(@hpke_suite, secret, "key", context, 32),
     labeled_expand(@hpke_suite, secret, "base_nonce", context, 12)}
  end

  defp labeled_extract(suite, salt, label, ikm),
    do: :crypto.mac(:hmac, :sha256, salt, ["HPKE-v1", suite, label, ikm])

  defp labeled_expand(suite, prk, label, info, length),
    do: expand(prk, [<<length::16>>, "HPKE-v1", suite, label, info], length)

  # HKDF-Expand (RFC 5869) with SHA-256.
  defp expand(prk, info, length) do
    {okm, _last} =
      Enum.reduce(1..div(length + 31, 32), {"", ""}, fn i, {okm, last} ->
        block = :crypto.mac(:hmac, :sha256, prk, [last, info, <<i>>])
        {okm <> block, block}
      end)

    binary_part(okm, 0, length)
  end
end
