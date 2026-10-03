defmodule Apiary.Contract.Ed25519 do
  @moduledoc """
  Ed25519 as the server contract uses it for access keys: the strict encoding of a
  public key, the checks every public key the server is given passes, its fingerprint,
  and cofactorless verification of a signature. Pure functions; nothing here touches the
  database or logs.

  **Encoding.** A public key, like every binary value of the contract, is base64url
  without padding, decoded strictly (`decode/2`): padding, a character of the standard
  alphabet (`+` or `/`), or bits set after the last full byte are refused, by decoding,
  encoding again and comparing.

  **The key checks** (`check_public_key/1`), on every key received, whatever path it
  came by, since a proof of possession proves nothing for a key of small order:

    1. 32 bytes;
    2. a canonical encoding: y below p, and no sign bit on x = 0;
    3. a point on the curve;
    4. y ≠ 1, so the conversion to X25519, which divides by 1 − y, is defined;
    5. not of small order: [8]A is not the identity;
    6. of prime order: [ℓ]A is the identity, ℓ the order of the base point;

  and not one of the contract's published fixture keys, which no instance accepts.
  Anything else is refused, and the caller gives every refusal the same answer, so a
  refusal says nothing about why.

  **The fingerprint** (`fingerprint/1`) is `base64url(SHA-256(public key)[:16])`, 22
  characters, for an access key's key and the server's alike.

  **Verification** (`verify/3`) is cofactorless, by RFC 8032: a signature whose R is not
  a canonical encoding, or whose S is not below ℓ, is refused before the curve is asked;
  then `:crypto` checks [S]B = R + [k]A on the encoded R, which is cofactorless.

  The arithmetic is on integers, in extended twisted Edwards coordinates, with the
  complete addition law (Hisil, Wong, Carter and Dawson, 2008); it runs when a key is
  received, never on a request.
  """

  # The field's prime, 2^255 − 19; the order of the base point, ℓ; the curve's d,
  # −121665/121666; a square root of −1, 2^((p − 1)/4).
  @p Integer.pow(2, 255) - 19
  @l Integer.pow(2, 252) + 27_742_317_777_372_353_535_851_937_790_883_648_493
  @d Integer.mod(
       -121_665 *
         :binary.decode_unsigned(:crypto.mod_pow(121_666, Integer.pow(2, 255) - 21, @p)),
       @p
     )
  @sqrt_m1 :binary.decode_unsigned(:crypto.mod_pow(2, div(Integer.pow(2, 255) - 20, 4), @p))

  @identity {0, 1, 1, 0}

  # The contract's published fixture keys, which every instance refuses: the access key's,
  # from the seed of bytes 1 to 32, and the server's signing keys, current and next, from
  # the seeds of bytes 65 to 96 and 161 to 192.
  @fixture_seeds [1..32, 65..96, 161..192]

  @typedoc "A raw Ed25519 public key: 32 bytes."
  @type public_key :: <<_::256>>

  @typedoc "Why a public key is refused; never shown to whoever sent it."
  @type refusal ::
          :length
          | :non_canonical
          | :not_on_curve
          | :y_is_one
          | :small_order
          | :not_prime_order
          | :fixture

  @doc """
  decode/2 decodes `value`, base64url without padding, strictly (see the module's
  documentation), to `size` bytes: `{:ok, bytes}`, or `:error` for anything else.
  """
  @spec decode(term, pos_integer) :: {:ok, binary} | :error
  def decode(value, size) when is_binary(value) and is_integer(size) and size > 0 do
    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- byte_size(bytes) == size,
         true <- Base.url_encode64(bytes, padding: false) == value do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  def decode(_value, _size), do: :error

  @doc "encode/1 is `bytes` as base64url without padding."
  @spec encode(binary) :: String.t()
  def encode(bytes) when is_binary(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc """
  decode_public_key/1 decodes a public key given as base64url and checks it
  (`check_public_key/1`): `{:ok, key}`, the 32 raw bytes, or `{:error, refusal}`.
  """
  @spec decode_public_key(term) :: {:ok, public_key} | {:error, refusal}
  def decode_public_key(value) do
    case decode(value, 32) do
      {:ok, key} -> with :ok <- check_public_key(key), do: {:ok, key}
      :error -> {:error, :length}
    end
  end

  @doc """
  check_public_key/1 checks the raw bytes of a public key against every key check of the
  module's documentation, in order: `:ok`, or `{:error, refusal}` naming the first that
  fails.
  """
  @spec check_public_key(term) :: :ok | {:error, refusal}
  def check_public_key(<<_::binary-size(32)>> = key) do
    with {:ok, {x, y}} <- decompress(key),
         :ok <- if(y == 1, do: {:error, :y_is_one}, else: :ok),
         point = {x, y, 1, mod(x * y)},
         :ok <- if(identity?(times_8(point)), do: {:error, :small_order}, else: :ok),
         :ok <- if(identity?(multiply(point, @l)), do: :ok, else: {:error, :not_prime_order}),
         :ok <- if(key in fixture_keys(), do: {:error, :fixture}, else: :ok) do
      :ok
    end
  end

  def check_public_key(_key), do: {:error, :length}

  @doc """
  fingerprint/1 is a public key's fingerprint: `base64url(SHA-256(key)[:16])`, 22
  characters.
  """
  @spec fingerprint(binary) :: String.t()
  def fingerprint(<<_::binary-size(32)>> = key) do
    <<head::binary-size(16), _rest::binary>> = :crypto.hash(:sha256, key)
    encode(head)
  end

  @doc """
  verify/3 says whether `signature`, 64 raw bytes, is a signature of `message` under
  `public_key`, 32 raw bytes, verified cofactorless: false for a non-canonical R, an S
  not below ℓ, and anything that is not of those sizes. The key is not checked here: it
  was checked when it was received.
  """
  @spec verify(binary, binary, binary) :: boolean
  def verify(message, <<r::binary-size(32), s::binary-size(32)>> = signature, public_key)
      when is_binary(message) and byte_size(public_key) == 32 do
    canonical_r?(r) and :binary.decode_unsigned(s, :little) < @l and
      :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  def verify(_message, _signature, _public_key), do: false

  @doc """
  fixture_keys/0 is the contract's published fixture public keys, which every key check
  refuses (`check_public_key/1`).
  """
  @spec fixture_keys() :: [public_key]
  def fixture_keys do
    for range <- @fixture_seeds do
      seed = :binary.list_to_bin(Enum.to_list(range))
      {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
      public
    end
  end

  # R is canonical when its y is below p and x = 0 carries no sign bit; whether it is on
  # the curve is left to the equation, which a point off the curve never satisfies.
  defp canonical_r?(r), do: decompress(r) != {:error, :non_canonical}

  # RFC 8032, 5.1.3, refusing what a lenient decoder accepts: a y not below p, and the
  # sign bit on x = 0.
  defp decompress(encoded) do
    <<value::little-size(256)>> = encoded
    sign = Bitwise.bsr(value, 255)
    y = Bitwise.band(value, Bitwise.bsl(1, 255) - 1)

    if y >= @p do
      {:error, :non_canonical}
    else
      u = mod(y * y - 1)
      v = mod(@d * y * y + 1)
      x = mod(u * pow(v, 3) * pow(u * pow(v, 7), div(@p - 5, 8)))

      x =
        cond do
          mod(v * x * x) == u -> {:ok, x}
          mod(v * x * x) == mod(-u) -> {:ok, mod(x * @sqrt_m1)}
          true -> :error
        end

      case x do
        :error -> {:error, :not_on_curve}
        {:ok, 0} when sign == 1 -> {:error, :non_canonical}
        {:ok, x} when Bitwise.band(x, 1) != sign -> {:ok, {mod(-x), y}}
        {:ok, x} -> {:ok, {x, y}}
      end
    end
  end

  defp times_8(point), do: point |> double() |> double() |> double()

  defp multiply(point, scalar) do
    scalar
    |> Integer.digits(2)
    |> Enum.reduce(@identity, fn bit, acc ->
      acc = double(acc)
      if bit == 1, do: add(acc, point), else: acc
    end)
  end

  defp double(point), do: add(point, point)

  # add-2008-hwcd-3, complete for a = −1 and a non-square d.
  defp add({x1, y1, z1, t1}, {x2, y2, z2, t2}) do
    a = mod((y1 - x1) * (y2 - x2))
    b = mod((y1 + x1) * (y2 + x2))
    c = mod(t1 * 2 * @d * t2)
    d = mod(z1 * 2 * z2)
    e = b - a
    f = d - c
    g = d + c
    h = b + a
    {mod(e * f), mod(g * h), mod(f * g), mod(e * h)}
  end

  defp identity?({x, y, z, _t}), do: mod(x) == 0 and mod(y - z) == 0

  defp mod(value), do: Integer.mod(value, @p)

  defp pow(base, exponent),
    do: :crypto.mod_pow(mod(base), exponent, @p) |> :binary.decode_unsigned()
end
