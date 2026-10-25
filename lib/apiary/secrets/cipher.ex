defmodule Apiary.Secrets.Cipher do
  @moduledoc """
  The encryption of stored secret values, and of the data keys they are encrypted under:
  AES-256-GCM with `:crypto`, a random 96-bit nonce for each encryption, and a 128-bit
  tag stored after the ciphertext.

  A value and a data key are bound to the level their secret is at: a workspace (v1), an
  organisation (v2) or the instance (v3). The three bindings are in use, each for its
  level.

  **A value of a workspace's secret** is encrypted under its workspace's data key, with
  associated data that binds it to where it belongs:

      lp("qory-secret-v1") ‖ lp(workspace id) ‖ lp(secret id) ‖ lp(value id, or "")

  **A value of an organisation's secret** is encrypted under its organisation's data key,
  with the associated data

      lp("qory-secret-v2") ‖ lp(organisation id) ‖ lp(secret id) ‖ lp(value id, or "")

  **A value of an instance's secret** belongs to one adapter, and is encrypted under the
  instance's data key, with the associated data

      lp("qory-secret-v3") ‖ lp(adapter id) ‖ lp(secret id) ‖ lp(value id)

  The workspace id and the organisation id are UUIDs in their canonical string form, the
  adapter id the adapter's public `na_` id, the secret id the secret's public `sec_` id,
  and the value id the value's, or the empty string for a secret's one value without one;
  an instance's secret's every value has one. A value copied to another workspace,
  organisation or adapter, another secret, another value id or another level does not
  decrypt there, so the database alone cannot move a value.

  **A data key**, 32 random bytes per workspace, per organisation and one for the
  instance, is encrypted
  (wrapped) under the instance's values key (`Apiary.KeyDerivation`, purpose `:values`),
  with the associated data

      lp("apiary-data-key-v1") ‖ lp(organisation id) ‖ lp(workspace id)

  for a workspace's, and

      lp("apiary-data-key-v2") ‖ lp(organisation id)

  for an organisation's, and

      lp("apiary-data-key-v3") ‖ lp("instance")

  for the instance's, so a wrapped key copied to another workspace, another organisation
  or another level does not unwrap there.

  `lp(x)` is `x`'s byte length as an unsigned 16-bit big-endian integer, then `x`.

  Nothing here logs, and nothing keeps a key or a plaintext beyond the call.
  """

  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @value_label "qory-secret-v1"
  @data_key_label "apiary-data-key-v1"
  @organisation_value_label "qory-secret-v2"
  @organisation_data_key_label "apiary-data-key-v2"
  @instance_value_label "qory-secret-v3"
  @instance_data_key_label "apiary-data-key-v3"

  @typedoc "A 32-byte AES-256 key."
  @type key :: <<_::256>>

  @doc """
  value_aad/3 is the associated data of a value of a workspace's secret: see the module's
  documentation.
  """
  @spec value_aad(Ecto.UUID.t(), String.t(), String.t() | nil) :: binary
  def value_aad(workspace_id, secret_id, value_id)
      when is_binary(workspace_id) and is_binary(secret_id) and
             (is_binary(value_id) or is_nil(value_id)) do
    IO.iodata_to_binary([lp(@value_label), lp(workspace_id), lp(secret_id), lp(value_id || "")])
  end

  @doc "data_key_aad/2 is the associated data of a workspace's wrapped data key."
  @spec data_key_aad(Ecto.UUID.t(), Ecto.UUID.t()) :: binary
  def data_key_aad(organisation_id, workspace_id)
      when is_binary(organisation_id) and is_binary(workspace_id) do
    IO.iodata_to_binary([lp(@data_key_label), lp(organisation_id), lp(workspace_id)])
  end

  @doc """
  organisation_value_aad/3 is the associated data of a value of an organisation's secret:
  see the module's documentation.
  """
  @spec organisation_value_aad(Ecto.UUID.t(), String.t(), String.t() | nil) :: binary
  def organisation_value_aad(organisation_id, secret_id, value_id)
      when is_binary(organisation_id) and is_binary(secret_id) and
             (is_binary(value_id) or is_nil(value_id)) do
    IO.iodata_to_binary([
      lp(@organisation_value_label),
      lp(organisation_id),
      lp(secret_id),
      lp(value_id || "")
    ])
  end

  @doc "organisation_data_key_aad/1 is the associated data of an organisation's wrapped data key."
  @spec organisation_data_key_aad(Ecto.UUID.t()) :: binary
  def organisation_data_key_aad(organisation_id) when is_binary(organisation_id) do
    IO.iodata_to_binary([lp(@organisation_data_key_label), lp(organisation_id)])
  end

  @doc """
  instance_value_aad/3 is the associated data of a value of an instance's secret: see the
  module's documentation. `adapter_id` is the adapter's public `na_` id.
  """
  @spec instance_value_aad(String.t(), String.t(), String.t()) :: binary
  def instance_value_aad(adapter_id, secret_id, value_id)
      when is_binary(adapter_id) and is_binary(secret_id) and is_binary(value_id) do
    IO.iodata_to_binary([
      lp(@instance_value_label),
      lp(adapter_id),
      lp(secret_id),
      lp(value_id)
    ])
  end

  @doc "instance_data_key_aad/0 is the associated data of the instance's wrapped data key."
  @spec instance_data_key_aad() :: binary
  def instance_data_key_aad,
    do: IO.iodata_to_binary([lp(@instance_data_key_label), lp("instance")])

  @doc """
  encrypt/3 encrypts `plaintext` under `key` with `aad`: `{nonce, ciphertext}`, the
  ciphertext with the tag after it.
  """
  @spec encrypt(key, binary, binary) :: {binary, binary}
  def encrypt(<<_::binary-size(@key_bytes)>> = key, aad, plaintext)
      when is_binary(aad) and is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, @tag_bytes, true)

    {nonce, ciphertext <> tag}
  end

  @doc """
  decrypt/4 decrypts what `encrypt/3` made: `{:ok, plaintext}`, or `:error` when the key,
  the associated data, the nonce or the ciphertext is not the one it was made with.
  """
  @spec decrypt(key, binary, binary, binary) :: {:ok, binary} | :error
  def decrypt(<<_::binary-size(@key_bytes)>> = key, aad, nonce, ciphertext)
      when is_binary(aad) and byte_size(nonce) == @nonce_bytes and
             byte_size(ciphertext) >= @tag_bytes do
    size = byte_size(ciphertext) - @tag_bytes
    <<body::binary-size(^size), tag::binary-size(@tag_bytes)>> = ciphertext

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, body, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_key, _aad, _nonce, _ciphertext), do: :error

  @doc "new_data_key/0 is a fresh data key: 32 random bytes."
  @spec new_data_key() :: key
  def new_data_key, do: :crypto.strong_rand_bytes(@key_bytes)

  @doc """
  wrap/2 wraps `data_key` under `wrapping_key` with `aad`: the nonce, the ciphertext and
  the tag, 60 bytes.
  """
  @spec wrap(key, key, binary) :: <<_::480>>
  def wrap(wrapping_key, <<_::binary-size(@key_bytes)>> = data_key, aad) do
    {nonce, ciphertext} = encrypt(wrapping_key, aad, data_key)
    nonce <> ciphertext
  end

  @doc "unwrap/3 is the data key `wrap/3` wrapped, or `:error`."
  @spec unwrap(key, binary, binary) :: {:ok, key} | :error
  def unwrap(wrapping_key, <<nonce::binary-size(@nonce_bytes), ciphertext::binary>>, aad) do
    case decrypt(wrapping_key, aad, nonce, ciphertext) do
      {:ok, <<_::binary-size(@key_bytes)>> = data_key} -> {:ok, data_key}
      _ -> :error
    end
  end

  def unwrap(_wrapping_key, _wrapped, _aad), do: :error

  @doc """
  lp/1 is `x`'s byte length as an unsigned 16-bit big-endian integer, then `x`. Raises
  `ArgumentError` for a binary over 65535 bytes.
  """
  @spec lp(binary) :: binary
  def lp(x) when is_binary(x) and byte_size(x) <= 65_535, do: <<byte_size(x)::16, x::binary>>

  def lp(x) when is_binary(x),
    do: raise(ArgumentError, "lp/1 takes at most 65535 bytes, got #{byte_size(x)}")
end
