defmodule Apiary.Kinds.CanonicalJSON do
  @moduledoc """
  CanonicalJSON encodes a JSON value one way only: the members of every object sorted by
  their keys, by their bytes, no white space, and strings and numbers as `Jason` writes
  them. Two equal values encode to the same bytes, so the bytes can be stored, compared,
  digested and coded (`Apiary.Integrity`), and decoding them and encoding again gives
  them back.
  """

  @doc "encode!/1 is `value`'s canonical JSON. Raises for a value JSON cannot hold."
  @spec encode!(term) :: String.t()
  def encode!(value), do: value |> ordered() |> Jason.encode!()

  @doc "sha256/1 is the lowercase hexadecimal SHA-256 of `bytes`."
  @spec sha256(iodata) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp ordered(%{} = map) when not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other
end
