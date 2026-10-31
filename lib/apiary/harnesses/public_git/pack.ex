defmodule Apiary.Harnesses.PublicGit.Pack do
  # Reads a git pack, version 2 or 3, that a public repository's host sent
  # (`Apiary.Harnesses.PublicGit`). The bytes are untrusted, so every size is bounded
  # before memory is taken for it:
  #
  #   * the pack: its header, then the object count, at most one object per 9 bytes (the
  #     smallest object a pack can hold) and at most `max_objects` (50,000), then exactly
  #     that many objects and the checksum of everything before it, which must match;
  #   * an object: its declared size at most `max_object` (16 MiB) and at most what is
  #     left of `budget`, read before it is inflated; its zlib stream inflated in steps,
  #     stopped once the output passes the declared size, and its end found by the
  #     stream's Adler-32 checksum, at most 8 tries, each checked by inflating the
  #     stream again up to that end;
  #   * a delta: its base's declared size must be the base's size, and its result's
  #     declared size at most `max_object` and what is left of `budget`; each copy stays
  #     inside the base, and the result stops at its declared size. The result grows as
  #     one binary, because a list takes more memory for each instruction of one byte
  #     than the byte: `budget` would not bound it;
  #   * the bases: an offset delta's base starts earlier in the pack, at an object; a
  #     reference delta's base is an object of the pack; a delta whose base is missing,
  #     or that is part of a cycle, fails; at most `max_depth` deltas on one chain
  #     (4,095, the most git allows). Chains are resolved with a work list, not by
  #     recursion.
  #
  # `budget` (16 MiB by default) counts every byte inflated, every delta's result, and
  # `object_cost` (256) bytes more for each object, the memory an object takes beyond
  # its bytes.
  # Nothing in the input becomes an atom or a term. Every failure is `{:error,
  # :too_large}` for a size over a bound, else `{:error, :invalid}`.
  @moduledoc false

  import Bitwise

  @max_object 16 * 1024 * 1024
  @max_depth 4095
  @max_objects 50_000
  @object_cost 256
  @end_tries 8
  @types %{1 => :commit, 2 => :tree, 3 => :blob, 4 => :tag}

  @typedoc "An object's type."
  @type type :: :commit | :tree | :blob | :tag

  @typedoc "The objects of a pack by id (raw bytes), and the bytes it inflated."
  @type objects :: %{objects: %{binary => {type, binary}}, inflated: non_neg_integer}

  @doc false
  # read/2 is the objects of `pack`. `opts`: `hash`, `:sha` (default) or `:sha256`;
  # `budget`, the bytes it may inflate (16 MiB); `max_object` (16 MiB); `max_depth`
  # (4,095); `max_objects` (50,000); `object_cost` (256). `inflated` counts each
  # object's cost too.
  @spec read(binary, keyword) :: {:ok, objects} | {:error, :too_large | :invalid}
  def read(pack, opts \\ []) when is_binary(pack) do
    hash = Keyword.get(opts, :hash, :sha)

    limits = %{
      hash: hash,
      id_size: id_size(hash),
      budget: Keyword.get(opts, :budget, @max_object),
      max_object: Keyword.get(opts, :max_object, @max_object),
      max_depth: Keyword.get(opts, :max_depth, @max_depth),
      max_objects: Keyword.get(opts, :max_objects, @max_objects),
      object_cost: Keyword.get(opts, :object_cost, @object_cost)
    }

    with {:ok, body, count} <- header(pack, limits),
         {:ok, entries, used} <- entries(body, count, limits),
         {:ok, objects, inflated} <- resolve(entries, %{limits | budget: limits.budget - used}) do
      {:ok, %{objects: objects, inflated: used + inflated}}
    end
  rescue
    # A bound missed above is a failure of the read, never a crash of the caller.
    _error -> {:error, :invalid}
  end

  @doc false
  # id_size/1 is the bytes of an object id under `hash`.
  @spec id_size(:sha | :sha256) :: 20 | 32
  def id_size(:sha), do: 20
  def id_size(:sha256), do: 32

  @doc false
  # object_id/3 is the id of an object of `type` with `data`, under `hash`.
  @spec object_id(type, binary, :sha | :sha256) :: binary
  def object_id(type, data, hash),
    do:
      :crypto.hash(hash, [Atom.to_string(type), " ", Integer.to_string(byte_size(data)), 0, data])

  @doc false
  # tree_entry/3 is the entry `name` of the tree `data`: `{:ok, mode, id}`, `:none`, or
  # `:invalid` for a tree that does not read.
  @spec tree_entry(binary, String.t(), 20 | 32) :: {:ok, binary, binary} | :none | :invalid
  def tree_entry(<<>>, _name, _id_size), do: :none

  def tree_entry(data, name, id_size) do
    with {space, 1} when space in 5..6 <-
           :binary.match(data, " ", scope: {0, min(7, byte_size(data))}),
         mode = binary_part(data, 0, space),
         true <- octal?(mode),
         rest = binary_part(data, space + 1, byte_size(data) - space - 1),
         {nul, 1} when nul > 0 <- :binary.match(rest, <<0>>),
         <<entry::binary-size(^nul), 0, id::binary-size(^id_size), next::binary>> <- rest do
      if entry == name, do: {:ok, mode, id}, else: tree_entry(next, name, id_size)
    else
      _invalid -> :invalid
    end
  end

  defp octal?(mode), do: for(<<c <- mode>>, reduce: true, do: (ok -> ok and c in ?0..?7))

  @doc false
  # commit_tree/2 is the id of the tree of the commit `data`: `{:ok, id}` or `:invalid`.
  @spec commit_tree(binary, 20 | 32) :: {:ok, binary} | :invalid
  def commit_tree(data, id_size) do
    hex = 2 * id_size

    with <<"tree ", tree::binary-size(^hex), "\n", _rest::binary>> <- data,
         {:ok, id} <- Base.decode16(tree, case: :lower) do
      {:ok, id}
    else
      _invalid -> :invalid
    end
  end

  ## The pack

  defp header(pack, limits) do
    size = byte_size(pack) - limits.id_size

    with true <- size >= 12,
         <<body::binary-size(^size), checksum::binary>> <- pack,
         <<"PACK", version::32, count::32, _objects::binary>> when version in [2, 3] <- body,
         true <- count <= div(size - 12, 9),
         true <- :crypto.hash(limits.hash, body) == checksum do
      if count <= limits.max_objects and count * limits.object_cost <= limits.budget,
        do: {:ok, body, count},
        else: {:error, :too_large}
    else
      _invalid -> {:error, :invalid}
    end
  end

  # Each object at its offset: `{:full, type, data}`, `{:ofs, base_offset, delta}` or
  # `{:ref, base_id, delta}`, and the bytes inflated.
  defp entries(body, count, limits), do: entries(body, 12, count, limits, %{}, 0)

  defp entries(body, at, 0, _limits, entries, used),
    do: if(at == byte_size(body), do: {:ok, entries, used}, else: {:error, :invalid})

  defp entries(body, at, left, limits, entries, used) do
    with {:ok, type, size, at_data} <- object_header(body, at),
         :ok <- fits(size, limits.max_object, limits.budget - used - limits.object_cost),
         {:ok, kind, at_stream} <- kind(type, body, at, at_data, limits),
         {:ok, data, ends} <- inflate(body, at_stream, size) do
      entry =
        case kind do
          {:full, type} -> {:full, type, data}
          {:ofs, base} -> {:ofs, base, data}
          {:ref, base} -> {:ref, base, data}
        end

      used = used + size + limits.object_cost
      entries(body, ends, left - 1, limits, Map.put(entries, at, entry), used)
    end
  end

  defp fits(size, max_object, left),
    do: if(size <= max_object and size <= left, do: :ok, else: {:error, :too_large})

  # The type and size of the object at `at`, at most 10 bytes of header.
  defp object_header(body, at) do
    case body do
      <<_::binary-size(^at), more::1, type::3, low::4, _::binary>> ->
        with {:ok, size, next} <- size_bytes(body, at + 1, more, low, 4, 1),
             do: {:ok, type, size, next}

      _short ->
        {:error, :invalid}
    end
  end

  defp size_bytes(_body, at, 0, size, _shift, _n), do: {:ok, size, at}
  defp size_bytes(_body, _at, 1, _size, _shift, n) when n >= 10, do: {:error, :invalid}

  defp size_bytes(body, at, 1, size, shift, n) do
    case body do
      <<_::binary-size(^at), more::1, bits::7, _::binary>> ->
        size = size ||| bits <<< shift

        if size > @max_object * 2,
          do: {:error, :too_large},
          else: size_bytes(body, at + 1, more, size, shift + 7, n + 1)

      _short ->
        {:error, :invalid}
    end
  end

  defp kind(type, _body, _at, at_data, _limits) when type in [1, 2, 3, 4],
    do: {:ok, {:full, Map.fetch!(@types, type)}, at_data}

  defp kind(6, body, at, at_data, _limits) do
    with {:ok, back, at_stream} <- offset(body, at_data, nil, 0),
         true <- back > 0 and back <= at - 12 do
      {:ok, {:ofs, at - back}, at_stream}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp kind(7, body, _at, at_data, %{id_size: id_size}) do
    case body do
      <<_::binary-size(^at_data), base::binary-size(^id_size), _::binary>> ->
        {:ok, {:ref, base}, at_data + id_size}

      _short ->
        {:error, :invalid}
    end
  end

  defp kind(_type, _body, _at, _at_data, _limits), do: {:error, :invalid}

  # An offset delta's distance back to its base, at most 9 bytes.
  defp offset(_body, _at, _value, n) when n >= 9, do: {:error, :invalid}

  defp offset(body, at, value, n) do
    case body do
      <<_::binary-size(^at), more::1, bits::7, _::binary>> ->
        value = if value == nil, do: bits, else: (value + 1) <<< 7 ||| bits
        if more == 1, do: offset(body, at + 1, value, n + 1), else: {:ok, value, at + 1}

      _short ->
        {:error, :invalid}
    end
  end

  ## Inflating

  # The zlib stream at `at`, `size` bytes inflated: `{:ok, data, end_offset}`.
  defp inflate(body, at, size) do
    stream = binary_part(body, at, byte_size(body) - at)

    with {:ok, data} <- inflate_all(stream, size),
         {:ok, length} <- stream_end(stream, data, size) do
      {:ok, data, at + length}
    end
  end

  # The output of the stream at the start of `stream`, stopped once it passes `size`;
  # `:invalid` for any other size, or a stream that does not end.
  defp inflate_all(stream, size) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)

      with {:ok, out} <- collect(z, :zlib.safeInflate(z, stream), [], 0, size) do
        :ok = :zlib.inflateEnd(z)
        {:ok, IO.iodata_to_binary(out)}
      end
    rescue
      _error -> {:error, :invalid}
    after
      :zlib.close(z)
    end
  end

  defp collect(z, {:continue, out}, acc, total, size) do
    total = total + IO.iodata_length(out)

    if total > size,
      do: {:error, :invalid},
      else: collect(z, :zlib.safeInflate(z, []), [acc | out], total, size)
  end

  defp collect(_z, {:finished, out}, acc, total, size) do
    if total + IO.iodata_length(out) == size,
      do: {:ok, [acc | out]},
      else: {:error, :invalid}
  end

  defp collect(_z, _need_dictionary, _acc, _total, _size), do: {:error, :invalid}

  # The length of the zlib stream at the start of `stream` whose output is `data`: it
  # ends with the Adler-32 of `data`, at the first place that, inflated alone, is a
  # whole stream of `size` bytes.
  defp stream_end(stream, data, size),
    do: stream_end(stream, <<:erlang.adler32(data)::32>>, size, 2, @end_tries)

  defp stream_end(_stream, _pattern, _size, _from, 0), do: {:error, :invalid}

  defp stream_end(stream, pattern, size, from, tries) do
    with true <- from < byte_size(stream),
         {at, 4} <- :binary.match(stream, pattern, scope: {from, byte_size(stream) - from}) do
      length = at + 4

      case inflate_all(binary_part(stream, 0, length), size) do
        {:ok, _data} -> {:ok, length}
        {:error, _} -> stream_end(stream, pattern, size, at + 1, tries - 1)
      end
    else
      _none -> {:error, :invalid}
    end
  end

  ## Deltas

  # Every object resolved, by id, with a work list: each object resolved queues the deltas
  # waiting on its offset or its id. A delta still waiting at the end has a missing base
  # or is part of a cycle.
  defp resolve(entries, limits) do
    {queue, by_offset, by_id} =
      Enum.reduce(entries, {[], %{}, %{}}, fn
        {at, {:full, type, data}}, {queue, by_offset, by_id} ->
          {[{at, type, data, 0} | queue], by_offset, by_id}

        {at, {:ofs, base, _delta}}, {queue, by_offset, by_id} ->
          {queue, Map.update(by_offset, base, [at], &[at | &1]), by_id}

        {at, {:ref, base, _delta}}, {queue, by_offset, by_id} ->
          {queue, by_offset, Map.update(by_id, base, [at], &[at | &1])}
      end)

    state = %{
      entries: entries,
      by_offset: by_offset,
      by_id: by_id,
      objects: %{},
      done: 0,
      inflated: 0
    }

    with {:ok, state} <- work(queue, state, limits) do
      if state.done == map_size(entries),
        do: {:ok, state.objects, state.inflated},
        else: {:error, :invalid}
    end
  end

  defp work([], state, _limits), do: {:ok, state}

  defp work([{at, type, data, depth} | queue], state, limits) do
    id = object_id(type, data, limits.hash)
    {after_offset, by_offset} = Map.pop(state.by_offset, at, [])
    {after_id, by_id} = Map.pop(state.by_id, id, [])

    state = %{
      state
      | objects: Map.put_new(state.objects, id, {type, data}),
        by_offset: by_offset,
        by_id: by_id,
        done: state.done + 1
    }

    case apply_all(after_offset ++ after_id, type, data, depth + 1, queue, state, limits) do
      {:ok, queue, state} -> work(queue, state, limits)
      error -> error
    end
  end

  defp apply_all([], _type, _base, _depth, queue, state, _limits), do: {:ok, queue, state}

  defp apply_all(_deltas, _type, _base, depth, _queue, _state, %{max_depth: max})
       when depth > max,
       do: {:error, :invalid}

  defp apply_all([at | rest], type, base, depth, queue, state, limits) do
    {_kind, _base_ref, delta} = Map.fetch!(state.entries, at)
    left = limits.budget - state.inflated

    case patch(base, delta, min(limits.max_object, left)) do
      {:ok, data} ->
        state = %{state | inflated: state.inflated + byte_size(data)}
        apply_all(rest, type, base, depth, [{at, type, data, depth} | queue], state, limits)

      error ->
        error
    end
  end

  # `base` with `delta` applied, its result at most `max` bytes.
  defp patch(base, delta, max) do
    with {:ok, base_size, delta} <- delta_size(delta),
         true <- base_size == byte_size(base) || {:error, :invalid},
         {:ok, size, ops} <- delta_size(delta),
         true <- size <= max || {:error, :too_large} do
      ops(ops, base, size, <<>>)
    end
  end

  # A delta's size, little-endian groups of 7 bits, at most 5 bytes.
  defp delta_size(delta), do: delta_size(delta, 0, 0)
  defp delta_size(_delta, _value, shift) when shift > 28, do: {:error, :invalid}

  defp delta_size(<<more::1, bits::7, rest::binary>>, value, shift) do
    value = value ||| bits <<< shift
    if more == 1, do: delta_size(rest, value, shift + 7), else: {:ok, value, rest}
  end

  defp delta_size(<<>>, _value, _shift), do: {:error, :invalid}

  defp ops(<<>>, _base, size, out) when byte_size(out) == size, do: {:ok, out}
  defp ops(<<>>, _base, _size, _out), do: {:error, :invalid}

  # A copy from the base: the offset and size bytes its flags list; a size of 0 is
  # 65,536 bytes.
  defp ops(<<1::1, flags::7, rest::binary>>, base, size, out) do
    with {:ok, offset, rest} <- copy_bytes(rest, flags, 0, 4, 0, 0),
         {:ok, count, rest} <- copy_bytes(rest, flags >>> 4, 0, 3, 0, 0),
         count = if(count == 0, do: 0x10000, else: count),
         true <- offset + count <= byte_size(base),
         true <- byte_size(out) + count <= size do
      ops(rest, base, size, <<out::binary, binary_part(base, offset, count)::binary>>)
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp ops(<<0::1, count::7, rest::binary>>, base, size, out)
       when count > 0 and byte_size(rest) >= count and byte_size(out) + count <= size do
    <<insert::binary-size(^count), rest::binary>> = rest
    ops(rest, base, size, <<out::binary, insert::binary>>)
  end

  defp ops(_ops, _base, _size, _out), do: {:error, :invalid}

  # The bytes of a copy's offset or size: for each of `n` flag bits, one byte when set.
  defp copy_bytes(rest, _flags, i, n, _shift, value) when i == n, do: {:ok, value, rest}

  defp copy_bytes(rest, flags, i, n, shift, value) do
    if (flags >>> i &&& 1) == 1 do
      case rest do
        <<byte, rest::binary>> ->
          copy_bytes(rest, flags, i + 1, n, shift + 8, value ||| byte <<< shift)

        <<>> ->
          {:error, :invalid}
      end
    else
      copy_bytes(rest, flags, i + 1, n, shift + 8, value)
    end
  end
end
