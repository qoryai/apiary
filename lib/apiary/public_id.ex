defmodule Apiary.PublicId do
  @moduledoc """
  The public ids Qory Apiary gives what it names to Forager and in its pages: a prefix and
  an underscore, then 16 lowercase Crockford base32 characters, 80 random bits, as
  `ak_0123456789abcdef`. Crockford's alphabet leaves out `i`, `l`, `o` and `u`, so an id
  read aloud or copied by hand is not mistaken. The prefix says what the id names:
  `ak` an access key, `sec` a stored secret, `nd` a node, `np` a node pool and `ws` a
  workspace.
  """

  # Crockford base32 without the ambiguous letters i, l, o, u.
  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"

  @doc "generate/1 is a fresh id with `prefix`: `prefix`, `_`, 16 random characters."
  @spec generate(String.t()) :: String.t()
  def generate(prefix) when is_binary(prefix) do
    random = :crypto.strong_rand_bytes(10)
    prefix <> "_" <> for(<<chunk::5 <- random>>, into: "", do: <<Enum.at(@alphabet, chunk)>>)
  end

  @doc "valid?/2 says whether `id` is an id with `prefix`, in the shape `generate/1` makes."
  @spec valid?(String.t(), term) :: boolean
  def valid?(prefix, id) when is_binary(prefix) and is_binary(id) do
    size = byte_size(prefix)

    case id do
      <<^prefix::binary-size(^size), "_", rest::binary-size(16)>> ->
        rest |> String.to_charlist() |> Enum.all?(&(&1 in @alphabet))

      _other ->
        false
    end
  end

  def valid?(_prefix, _id), do: false
end
