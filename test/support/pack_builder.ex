defmodule Apiary.PackBuilder do
  @moduledoc """
  Git packs for the tests of `Apiary.Harnesses.PublicGit.Pack`, built by hand, so a test
  can make one a host would never send: a size that lies, a delta that copies past its
  base, a base that is missing or refers back to itself.
  """

  import Bitwise

  @types %{commit: 1, tree: 2, blob: 3, tag: 4}

  @doc """
  pack/2 is a pack of `entries`, each one of:

    * `{type, data}`, `type` `:commit`, `:tree`, `:blob` or `:tag`;
    * `{:ofs, index, delta}`, a delta on the entry at `index` (from 0), by offset;
    * `{:ref, id, delta}`, a delta on the object `id` (raw bytes);
    * `{:raw, type, size, stream}`, a header of `type` (a number) and `size` with
      `stream` after it as it is.

  `opts`: `hash` (`:sha`), `count`, the object count the header gives (the entries'
  count by default).
  """
  def pack(entries, opts \\ []) do
    hash = Keyword.get(opts, :hash, :sha)

    {body, _offsets} =
      Enum.reduce(
        entries,
        {<<"PACK", 2::32, Keyword.get(opts, :count, length(entries))::32>>, []},
        fn entry, {body, offsets} ->
          at = byte_size(body)
          {body <> object(entry, at, Enum.reverse(offsets)), [at | offsets]}
        end
      )

    body <> :crypto.hash(hash, body)
  end

  defp object({type, data}, _at, _offsets) when is_map_key(@types, type),
    do: header(@types[type], byte_size(data)) <> :zlib.compress(data)

  defp object({:ofs, index, delta}, at, offsets),
    do:
      header(6, byte_size(delta)) <> offset(at - Enum.at(offsets, index)) <> :zlib.compress(delta)

  defp object({:ref, id, delta}, _at, _offsets),
    do: header(7, byte_size(delta)) <> id <> :zlib.compress(delta)

  defp object({:raw, type, size, stream}, _at, _offsets), do: header(type, size) <> stream

  @doc "header/2 is an object's header of `type` (a number) and `size`."
  def header(type, size) do
    low = size &&& 0x0F
    rest = size >>> 4

    if rest == 0,
      do: <<0::1, type::3, low::4>>,
      else: <<1::1, type::3, low::4>> <> varint(rest)
  end

  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<0x80 ||| (n &&& 0x7F)>> <> varint(n >>> 7)

  # An offset delta's distance back, as git writes it.
  defp offset(n) do
    last = <<n &&& 0x7F>>
    offset(n >>> 7, last)
  end

  defp offset(0, acc), do: acc
  defp offset(n, acc), do: offset((n - 1) >>> 7, <<0x80 ||| (n - 1 &&& 0x7F)>> <> acc)

  @doc """
  delta/3 is a delta from a base of `base_size` to a result of `result_size`, by `ops`:
  `{:insert, bytes}` (at most 127) or `{:copy, offset, size}`.
  """
  def delta(base_size, result_size, ops) do
    varint(base_size) <> varint(result_size) <> Enum.map_join(ops, &op/1)
  end

  defp op({:insert, bytes}), do: <<byte_size(bytes)>> <> bytes

  defp op({:copy, offset, size}) do
    offsets = for i <- 0..3, do: offset >>> (8 * i) &&& 0xFF
    sizes = for i <- 0..2, do: size >>> (8 * i) &&& 0xFF

    flags =
      for {b, i} <- Enum.with_index(offsets ++ sizes), b != 0, reduce: 0, do: (f -> f ||| 1 <<< i)

    <<0x80 ||| flags>> <>
      for({b, _i} <- Enum.with_index(offsets ++ sizes), b != 0, into: <<>>, do: <<b>>)
  end

  @doc "id/3 is the id of an object of `type` with `data`."
  def id(type, data, hash \\ :sha),
    do:
      :crypto.hash(hash, [Atom.to_string(type), " ", Integer.to_string(byte_size(data)), 0, data])
end
