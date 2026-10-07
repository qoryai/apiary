defmodule Apiary.KeyDerivation do
  @moduledoc """
  The keys the instance derives from `APIARY_ENCRYPTION_SECRET`, one per purpose, so no
  key serves two: HKDF-SHA256 (RFC 5869) with the secret's 32 bytes as the input keying
  material, the salt `#{inspect("apiary/kdf/v1")}`, and an info string per purpose.

  | Purpose | Info | What the key does |
  |---|---|---|
  | `:values` | `"apiary values v1"` | wraps each workspace's data key, which encrypts the workspace's stored secret values (`Apiary.Secrets`) |
  | `:integrity` | `"apiary integrity v1"` | keys the integrity codes of stored rows (`Apiary.Integrity`) |
  | `:access_keys` | `"apiary access keys v1"` | encrypts the access key secrets at rest (`Apiary.Vault`) |

  Each derived key has a **key id**: the first 8 bytes of SHA-256 over
  `"apiary key id v1"` and the key, as 16 lowercase hexadecimal characters. It names the
  key without telling anything of it, and is stored beside what the key made (a wrapped
  data key, an integrity code), so that once the secret can be rotated a reader knows
  which key to take, and one made under a key the instance no longer holds is told apart
  from one that is wrong.

  The secret is read from `config :apiary, Apiary.KeyDerivation, secret: <32 bytes>`:
  `config/runtime.exs` sets it from `APIARY_ENCRYPTION_SECRET` in production, and
  `config/dev.exs` and `config/test.exs` set a fixed one. The secret's own bytes key
  nothing: they are only ever the input to the derivation. The keys are derived on each
  call, which costs two HMACs, so nothing caches a key in a process's state.

  Losing `APIARY_ENCRYPTION_SECRET` loses every key derived from it, and with them every
  stored secret value: there is no other copy.

  The instance's signing key, which machines pin, is not derived here: its seed is a
  secret of its own, `APIARY_SIGNING_SECRET` (`Apiary.SigningKey`), so it does not change
  with this one.
  """

  @salt "apiary/kdf/v1"
  @infos %{
    values: "apiary values v1",
    integrity: "apiary integrity v1",
    access_keys: "apiary access keys v1"
  }
  @key_id_label "apiary key id v1"
  @hash_len 32

  @typedoc "A purpose a key is derived for."
  @type purpose :: :values | :integrity | :access_keys

  @typedoc "A key id: 16 lowercase hexadecimal characters."
  @type key_id :: String.t()

  @doc "The purposes a key is derived for, each with its info string."
  @spec purposes() :: %{purpose => String.t()}
  def purposes, do: @infos

  @doc """
  key/1 is the current key for `purpose`, with its key id: `{key_id, key}`, the key 32
  bytes. Raises `ArgumentError` for a purpose that is none, and when the secret is not
  configured or not 32 bytes.
  """
  @spec key(purpose) :: {key_id, binary}
  def key(purpose) do
    key = derive(secret!(), info!(purpose))
    {key_id(key), key}
  end

  @doc """
  key/2 is the key for `purpose` whose id is `key_id`, for reading what an earlier key
  made: `{:ok, key}`, or `:error` when the instance holds no such key. With one secret,
  that is the current key or nothing; a rotation adds the previous secret here.
  """
  @spec key(purpose, key_id) :: {:ok, binary} | :error
  def key(purpose, key_id) when is_binary(key_id) do
    case key(purpose) do
      {^key_id, key} -> {:ok, key}
      _other -> :error
    end
  end

  @doc "key_id/1 is the key id of `key`: see the module's documentation."
  @spec key_id(binary) :: key_id
  def key_id(key) when is_binary(key) do
    :crypto.hash(:sha256, [@key_id_label, key])
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  @doc """
  hkdf/4 is HKDF-SHA256 (RFC 5869): `length` bytes of output keying material from `ikm`,
  `salt` and `info`. `length` is at most 255 × 32. An empty salt is 32 zero bytes, as
  the RFC says.
  """
  @spec hkdf(binary, binary, iodata, pos_integer) :: binary
  def hkdf(ikm, salt, info, length)
      when is_binary(ikm) and is_binary(salt) and is_integer(length) and length > 0 and
             length <= 255 * @hash_len do
    salt = if salt == "", do: <<0::size(@hash_len * 8)>>, else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    info = IO.iodata_to_binary(info)
    blocks = div(length + @hash_len - 1, @hash_len)

    {okm, _last} =
      Enum.reduce(1..blocks, {[], ""}, fn i, {acc, previous} ->
        t = :crypto.mac(:hmac, :sha256, prk, [previous, info, <<i>>])
        {[acc, t], t}
      end)

    okm |> IO.iodata_to_binary() |> binary_part(0, length)
  end

  defp derive(secret, info), do: hkdf(secret, @salt, info, 32)

  defp info!(purpose) do
    case @infos do
      %{^purpose => info} -> info
      _ -> raise ArgumentError, "#{inspect(purpose)} is no purpose of Apiary.KeyDerivation"
    end
  end

  defp secret! do
    case Keyword.get(Application.get_env(:apiary, __MODULE__, []), :secret) do
      secret when is_binary(secret) and byte_size(secret) == 32 ->
        secret

      _ ->
        raise ArgumentError,
              "config :apiary, Apiary.KeyDerivation, secret: is not 32 bytes " <>
                "(APIARY_ENCRYPTION_SECRET, in production)"
    end
  end
end
