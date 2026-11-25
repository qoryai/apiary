defmodule Apiary.PublicId do
  @moduledoc """
  The public ids Qory Apiary gives what it names to Forager and in its pages: a prefix and
  an underscore, then 16 lowercase Crockford base32 characters, 80 random bits, as
  `ak_0123456789abcdef`. Crockford's alphabet leaves out `i`, `l`, `o` and `u`, so an id
  read aloud or copied by hand is not mistaken. The prefix says what the id names:
  `ak` an access key, `sec` a stored secret, `nd` a node, `np` a node pool, `rn` a run,
  `tg` a target and `ws` a workspace.
  """

  # `cm` names a comment on a work item (`Apiary.WorkItems.Comment`), of the `factory`
  # feature. `an` is the prefix of a member's answer to a run's question and `rc` of the
  # comment of Run another round, both made by `derive/2` from the member's move
  # (`Apiary.Explore.Given`).

  # Crockford base32 without the ambiguous letters i, l, o, u.
  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"

  # The module that gives the 10 random bytes: `:crypto`. Only the test configuration
  # names another, to make an id collide (`config/test.exs`).
  @random Application.compile_env(:apiary, [__MODULE__, :random], :crypto)

  @doc "generate/1 is a fresh id with `prefix`: `prefix`, `_`, 16 random characters."
  @spec generate(String.t()) :: String.t()
  def generate(prefix) when is_binary(prefix) do
    random = @random.strong_rand_bytes(10)
    prefix <> "_" <> for(<<chunk::5 <- random>>, into: "", do: <<Enum.at(@alphabet, chunk)>>)
  end

  @doc """
  derive/2 is the id with `prefix` made from `seed`: `prefix`, `_`, then the first 80 bits
  of the SHA-256 of `prefix`, a zero byte and `seed`, in the alphabet of `generate/1`.
  The same prefix and seed make the same id at every read, for a record that has no
  stored id.
  """
  @spec derive(String.t(), String.t()) :: String.t()
  def derive(prefix, seed) when is_binary(prefix) and is_binary(seed) do
    <<bits::binary-size(10), _rest::binary>> = :crypto.hash(:sha256, [prefix, 0, seed])
    prefix <> "_" <> for(<<chunk::5 <- bits>>, into: "", do: <<Enum.at(@alphabet, chunk)>>)
  end

  @doc "valid?/2 says whether `id` is an id with `prefix`, in the shape `generate/1` makes."
  @spec valid?(String.t(), term) :: boolean
  def valid?(prefix, id) when is_binary(prefix) and is_binary(id) do
    size = byte_size(prefix)

    case id do
      # Byte by byte: the alphabet is ASCII, so a byte outside it, the first byte of a
      # character that takes more than one, or bytes that are not UTF-8 at all, is refused.
      <<^prefix::binary-size(^size), "_", rest::binary-size(16)>> ->
        for <<byte <- rest>>, reduce: true, do: (ok -> ok and byte in @alphabet)

      _other ->
        false
    end
  end

  def valid?(_prefix, _id), do: false
end
