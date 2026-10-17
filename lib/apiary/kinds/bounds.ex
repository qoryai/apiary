defmodule Apiary.Kinds.Bounds do
  @moduledoc """
  Bounds limits the size of an untrusted JSON document before a JSON Schema validates
  it. JSV checks every entry of a list and every member of an object even after the
  first refusal, so a list far longer than the schema allows costs a check of each entry;
  a walk of the decoded document before the schema refuses it at the cost of reading it.
  The walk bounds the document, not the schema: when the schema too comes from an
  untrusted input, a few of its references can make JSV's work grow exponentially with
  their nesting however small the document, and the walk does not bound that work.

  `within?/2` is the walk. It reads the decoded document once, keeping the values still
  to read in a list and calling itself last, so nesting of any depth runs in constant
  stack, and it is false as soon as a limit is passed:

    * `:list`, the most entries of a list;
    * `:members`, the most members of an object;
    * `:nodes`, the most values in the whole document, the document itself, every entry
      and every member's value counted;
    * `:string`, the most bytes of a string, a member's name included;
    * `:depth`, the most lists and objects nested in one another.

  A limit left out is not checked. A struct anywhere, such as a `Decimal`, is refused:
  the walk reads decoded JSON, maps with string keys, lists and scalars.
  """

  @typedoc "The limits of `within?/2`, each a non-negative integer."
  @type limits :: [
          list: non_neg_integer,
          members: non_neg_integer,
          nodes: non_neg_integer,
          string: non_neg_integer,
          depth: non_neg_integer
        ]

  @limits ~w(list members nodes string depth)a

  @doc """
  within?/2 is whether the decoded JSON `document` holds no list, object, string or
  nesting larger than `limits` allows, and no more values in all (see the module's
  documentation).
  """
  @spec within?(term, limits) :: boolean
  def within?(document, limits) when is_list(limits) do
    Enum.each(Keyword.keys(limits), fn key ->
      if key not in @limits, do: raise(ArgumentError, "an unknown limit: #{inspect(key)}")
    end)

    walk(
      [{document, 1}],
      Keyword.get(limits, :list),
      Keyword.get(limits, :members),
      Keyword.get(limits, :nodes, :none),
      Keyword.get(limits, :string),
      Keyword.get(limits, :depth)
    )
  end

  # The work list holds each value still to read with its depth, the number of lists and
  # objects it is in, itself included when it is one. `nodes` is the count of values still
  # allowed, `:none` when the total is not checked; the other limits are `nil` when not
  # checked.
  defp walk([], _list, _members, _nodes, _string, _depth), do: true

  defp walk(_values, _list, _members, nodes, _string, _depth)
       when is_integer(nodes) and nodes <= 0,
       do: false

  defp walk([{value, _at} | _rest], _list, _members, _nodes, _string, _depth)
       when is_struct(value),
       do: false

  defp walk([{value, at} | _rest], _list, _members, _nodes, _string, depth)
       when (is_list(value) or is_map(value)) and is_integer(depth) and at > depth,
       do: false

  defp walk([{list, at} | rest], max_list, members, nodes, string, depth) when is_list(list) do
    if bounded_length?(list, max_list),
      do: walk(entries(list, at + 1, rest), max_list, members, less(nodes), string, depth),
      else: false
  end

  defp walk([{map, at} | rest], list, max_members, nodes, string, depth) when is_map(map) do
    cond do
      is_integer(max_members) and map_size(map) > max_members -> false
      not names_within?(map, string) -> false
      true -> walk(members(map, at + 1, rest), list, max_members, less(nodes), string, depth)
    end
  end

  defp walk([{text, _at} | _rest], _list, _members, _nodes, string, _depth)
       when is_binary(text) and is_integer(string) and byte_size(text) > string,
       do: false

  defp walk([_scalar | rest], list, members, nodes, string, depth),
    do: walk(rest, list, members, less(nodes), string, depth)

  defp less(:none), do: :none
  defp less(nodes), do: nodes - 1

  # Whether `list` has at most `max` entries, reading at most `max + 1` of them.
  defp bounded_length?(_list, nil), do: true
  defp bounded_length?(_list, max) when max < 0, do: false
  defp bounded_length?([], _max), do: true
  defp bounded_length?([_head | tail], max), do: bounded_length?(tail, max - 1)

  # The entries go onto the work list in reverse; the order they are read in changes no
  # answer.
  defp entries([], _at, rest), do: rest
  defp entries([value | tail], at, rest), do: entries(tail, at, [{value, at} | rest])

  defp members(map, at, rest),
    do: :maps.fold(fn _name, value, acc -> [{value, at} | acc] end, rest, map)

  defp names_within?(_map, nil), do: true

  defp names_within?(map, string) do
    :maps.fold(
      fn
        name, _value, true when is_binary(name) -> byte_size(name) <= string
        _name, _value, within -> within
      end,
      true,
      map
    )
  end
end
