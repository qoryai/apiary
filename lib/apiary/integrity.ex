defmodule Apiary.Integrity do
  @moduledoc """
  Integrity codes: an HMAC-SHA256, under the instance's integrity key
  (`Apiary.KeyDerivation`, purpose `:integrity`), over a row's chosen fields, stored
  with the row so that a change made to it outside the application, by anyone who can
  write to the database but does not hold `APIARY_ENCRYPTION_SECRET`, is found when the
  row is read for something that trusts it.

  A caller names what it codes:

    * **`kind`**, a string naming the kind of row, such as `"access_key"`; a code made
      for one kind never verifies for another;
    * **`version`**, an integer from 0 to 65535, the version of the caller's choice of
      fields: a caller that codes another field from a release on bumps it, and verifies
      a stored row with the version it was coded under;
    * **`fields`**, a keyword list (or a list of `{name, value}` pairs) of the fields, in
      the caller's fixed order, each name unique.

  `code/3` gives `{key_id, code}`: the code is 32 bytes, and the key id names the key it
  was made under (`Apiary.KeyDerivation`), stored beside it. `verify/5` takes the same
  three and the stored key id and code, and answers `:ok`, `{:error, :mismatch}`, or
  `{:error, :unknown_key}` when the instance holds no key with that id. The comparison
  is in constant time (`:crypto.hash_equals/2`).

  ## The encoding

  What is coded is one binary, canonical, so that no two different inputs encode alike:

      lp("apiary-integrity-v1") ‖ lp(kind) ‖ u16(version) ‖ u16(count)
        ‖ for each field: lp(name) ‖ value(value)

  `lp(x)` is the byte length of `x` as an unsigned 16-bit big-endian integer, then `x`;
  `u16` and `u32` are unsigned big-endian integers of 16 and 32 bits. A value is a
  one-byte tag, then its bytes with a 32-bit length:

  | Value | Tag | Bytes |
  |---|---|---|
  | `nil` | 0 | none, length 0 |
  | a binary | 1 | the binary |
  | an integer | 2 | its decimal digits, `-` before a negative one |
  | `true`, `false` | 3 | `1` or `0` |
  | a `DateTime` | 4 | microseconds since the Unix epoch, as an integer's digits |
  | a list | 5 | `u32(count)`, then each element encoded as a value |
  | another atom | 6 | its name |

  The tags keep `nil` apart from `""`, an integer from its digits as a string, and a
  list from its concatenation. A `DateTime` is coded as an instant, so its precision and
  its time zone do not change the code, and a row read back from the database codes as
  it did when written. A UUID is coded as its string. A value of another type raises
  `ArgumentError`, as do a duplicate field name, a name or kind over 65535 bytes, and a
  version out of range: those are mistakes of the caller, never of the data.
  """

  alias Apiary.KeyDerivation

  @scheme "apiary-integrity-v1"

  @typedoc "A field's value: what the encoding takes."
  @type value ::
          nil | binary | integer | boolean | atom | DateTime.t() | [value]

  @typedoc "The fields coded, in order."
  @type fields :: [{atom | String.t(), value}]

  @typedoc "A code: 32 bytes."
  @type code :: <<_::256>>

  @doc """
  code/3 is the integrity code of `fields` of a row of `kind`, at `version`, under the
  current integrity key: `{key_id, code}`.
  """
  @spec code(String.t(), non_neg_integer, fields) :: {KeyDerivation.key_id(), code}
  def code(kind, version, fields) do
    {key_id, key} = KeyDerivation.key(:integrity)
    {key_id, mac(key, encode(kind, version, fields))}
  end

  @doc """
  verify/5 checks `code`, stored with `key_id`, against `fields` of a row of `kind` at
  `version`: `:ok`; `{:error, :mismatch}` when it is not their code, whatever the
  reason; `{:error, :unknown_key}` when the instance holds no key with `key_id`. In
  constant time over the code.
  """
  @spec verify(String.t(), non_neg_integer, fields, String.t() | nil, binary | nil) ::
          :ok | {:error, :mismatch | :unknown_key}
  def verify(kind, version, fields, key_id, code) when is_binary(key_id) and is_binary(code) do
    # Encoded first, so a caller's mistake raises whatever was stored.
    message = encode(kind, version, fields)

    with {:ok, key} <- known(KeyDerivation.key(:integrity, key_id)) do
      expected = mac(key, message)

      if byte_size(code) == byte_size(expected) and :crypto.hash_equals(expected, code),
        do: :ok,
        else: {:error, :mismatch}
    end
  end

  def verify(kind, version, fields, _key_id, _code) do
    _ = encode(kind, version, fields)
    {:error, :mismatch}
  end

  defp known({:ok, key}), do: {:ok, key}
  defp known(:error), do: {:error, :unknown_key}

  @doc """
  encode/3 is the canonical encoding that `code/3` codes (see the module's
  documentation). Public for the tests and for a reader who must reproduce a code.
  """
  @spec encode(String.t(), non_neg_integer, fields) :: binary
  def encode(kind, version, fields)
      when is_binary(kind) and is_integer(version) and version in 0..65_535 and
             is_list(fields) do
    names = Enum.map(fields, fn {name, _value} -> to_string(name) end)

    if length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "a field is named twice: #{inspect(names)}")

    if length(fields) > 65_535, do: raise(ArgumentError, "too many fields")

    IO.iodata_to_binary([
      lp(@scheme),
      lp(kind),
      <<version::16, length(fields)::16>>,
      Enum.map(fields, fn {name, value} -> [lp(to_string(name)), value(value)] end)
    ])
  end

  def encode(kind, version, fields) do
    raise ArgumentError,
          "an integrity code needs a kind, a version from 0 to 65535 and a list of fields, " <>
            "got: #{inspect({kind, version, is_list(fields)})}"
  end

  @doc """
  lp/1 is `x`'s byte length as an unsigned 16-bit big-endian integer, then `x`. Raises
  `ArgumentError` for a binary over 65535 bytes.
  """
  @spec lp(binary) :: binary
  def lp(x) when is_binary(x) and byte_size(x) <= 65_535, do: <<byte_size(x)::16, x::binary>>

  def lp(x) when is_binary(x),
    do: raise(ArgumentError, "lp/1 takes at most 65535 bytes, got #{byte_size(x)}")

  defp value(nil), do: tagged(0, "")
  defp value(true), do: tagged(3, "1")
  defp value(false), do: tagged(3, "0")
  defp value(value) when is_binary(value), do: tagged(1, value)
  defp value(value) when is_integer(value), do: tagged(2, Integer.to_string(value))

  defp value(%DateTime{} = at),
    do: tagged(4, at |> DateTime.to_unix(:microsecond) |> Integer.to_string())

  defp value(list) when is_list(list) do
    body = IO.iodata_to_binary([<<length(list)::32>> | Enum.map(list, &value/1)])
    tagged(5, body)
  end

  defp value(atom) when is_atom(atom), do: tagged(6, Atom.to_string(atom))

  # The value is not in the message: a caller may code what it would not log.
  defp value(%module{}),
    do: raise(ArgumentError, "an integrity code cannot encode a #{inspect(module)}")

  defp value(_other),
    do: raise(ArgumentError, "an integrity code cannot encode a map, tuple, float or function")

  defp tagged(tag, bytes), do: [<<tag, byte_size(bytes)::32>>, bytes]

  defp mac(key, message), do: :crypto.mac(:hmac, :sha256, key, message)
end
