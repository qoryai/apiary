defmodule Apiary.Kinds.Bounds do
  @moduledoc """
  Bounds keeps the validation of an untrusted JSON document by a JSON Schema in bounded
  time. JSV checks every entry of a list and every member of an object even after the
  first refusal, so a list far longer than the schema allows costs a check of each entry;
  a walk of the decoded document before the schema refuses it at the cost of reading it.

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

  The limits of a schema whose every list and object is bounded are read from it by
  `from_schema/2`, which raises on a schema whose bounds it cannot tell; a schema that
  takes any document needs limits that do not depend on it.
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

  @doc """
  from_schema/2 is `[list: max_list, members: max_members]` of a decoded JSON Schema: the
  largest `maxItems` of a schema of type array, and the most `properties` of a schema of
  type object, the limits of `within?/2` that every document the schema accepts passes.
  `documents` holds the other schema documents the schema refers to, each decoded, by
  its URL without a fragment.

  It reads the keywords listed below, and raises on a schema whose bounds it cannot tell,
  so a bound is never guessed:

    * a keyword outside those it reads, `patternProperties` among them;
    * a `type` that is not one string;
    * an array without an integer `maxItems`, or an object without
      `additionalProperties: false`;
    * `true`, or a map without a string `type`, a `$ref`, a `const` or an `enum`, where a
      value is described: the schema itself, a member of `properties`, `items` or `$defs`;
      or `items`, `properties` or `additionalProperties` in such a map;
    * a `$ref` that is neither into the schema's `$defs` nor into a document of
      `documents`, or a `const` or `enum` that holds a list or an object.

  The members of `allOf`, `anyOf`, `oneOf`, `not`, `if`, `then` and `else` narrow the
  value their schema describes, which that schema bounds: they need no `type`. The
  members of `properties` and `$defs` are read by name, never as keywords.

  A `$ref` into a document of `documents` is followed: its target is read where the
  `$ref` is, and every document of `documents` is read as a schema. Inside a document of
  `documents`, a `$ref` into another document raises.
  """
  @spec from_schema(map, %{optional(String.t()) => map}) :: limits
  def from_schema(schema, documents \\ %{}) when is_map(schema) and is_map(documents) do
    acc =
      Enum.reduce(documents, {0, 0}, fn {_url, document}, acc ->
        bounds(document, :value, acc, %{})
      end)

    {max_list, max_members} = bounds(schema, :value, acc, documents)
    [list: max_list, members: max_members]
  end

  @read ~w($schema $id $ref $defs title description type const enum required properties
           additionalProperties items minItems maxItems uniqueItems minLength maxLength
           pattern allOf anyOf oneOf not if then else)
  @described ~w(items properties additionalProperties)
  @narrowing ~w(not if then else)

  # `place` is `:value` where the schema describes a value, `:narrowing` in `allOf`,
  # `anyOf`, `oneOf`, `not`, `if`, `then` and `else`, and below them.
  defp bounds(false, _place, acc, _documents), do: acc
  defp bounds(true, :narrowing, acc, _documents), do: acc
  defp bounds(true, :value, _acc, _documents), do: refuse("true, which takes any value", true)

  defp bounds(schema, place, acc, documents) when is_map(schema) do
    Enum.each(Map.keys(schema), fn keyword ->
      if keyword not in @read, do: refuse("a keyword from_schema/2 does not read", keyword)
    end)

    type = Map.get(schema, "type")

    cond do
      Map.has_key?(schema, "type") and not is_binary(type) ->
        refuse("a type that is not one string", schema)

      place == :value and type == nil and not described?(schema) ->
        refuse("a value described by no type", schema)

      place == :value and type == nil and Enum.any?(@described, &Map.has_key?(schema, &1)) ->
        refuse("items, properties or additionalProperties with no type", schema)

      Enum.any?([schema["const"] | List.wrap(schema["enum"])], &(is_list(&1) or is_map(&1))) ->
        refuse("a const or an enum that holds a list or an object", schema)

      true ->
        :ok
    end

    acc =
      case type do
        "array" ->
          case schema do
            %{"maxItems" => max} when is_integer(max) -> put_elem(acc, 0, max(elem(acc, 0), max))
            _no_max -> refuse("an array without maxItems", schema)
          end

        "object" ->
          case schema do
            %{"additionalProperties" => false} ->
              put_elem(acc, 1, max(elem(acc, 1), map_size(Map.get(schema, "properties", %{}))))

            _open ->
              refuse("an object that takes any member", schema)
          end

        _other ->
          acc
      end

    acc
    |> ref(Map.get(schema, "$ref"), place, documents)
    |> bounds_each(Map.get(schema, "properties", %{}), place, documents)
    |> bounds_each(Map.get(schema, "$defs", %{}), :value, documents)
    |> bounds_list([Map.get(schema, "items", false)], place, documents)
    |> bounds_list(Map.get(schema, "allOf", []), :narrowing, documents)
    |> bounds_list(Map.get(schema, "anyOf", []), :narrowing, documents)
    |> bounds_list(Map.get(schema, "oneOf", []), :narrowing, documents)
    |> bounds_list(
      for(key <- @narrowing, Map.has_key?(schema, key), do: schema[key]),
      :narrowing,
      documents
    )
  end

  defp bounds(schema, _place, _acc, _documents),
    do: refuse("a schema that from_schema/2 cannot read", schema)

  defp described?(schema), do: Enum.any?(~w($ref const enum), &Map.has_key?(schema, &1))

  # A `$ref` into the schema's `$defs` needs nothing more: every member of `$defs` is read
  # as a value. A `$ref` into a document of `documents` has its target read where the
  # `$ref` is, with no further documents.
  defp ref(acc, nil, _place, _documents), do: acc
  defp ref(acc, "#/$defs/" <> _name, _place, _documents), do: acc

  defp ref(acc, ref, place, documents) when is_binary(ref) do
    with [url, "/" <> pointer] <- String.split(ref, "#", parts: 2),
         {:ok, document} <- Map.fetch(documents, url),
         {:ok, target} <- pointer(document, String.split(pointer, "/")) do
      bounds(target, place, acc, %{})
    else
      _unknown -> refuse("a $ref outside the schema's $defs and documents", ref)
    end
  end

  defp ref(_acc, ref, _place, _documents), do: refuse("a $ref that is not a string", ref)

  # The value at a JSON Pointer's reference tokens, `~1` read as `/` and `~0` as `~`.
  defp pointer(value, []), do: {:ok, value}

  defp pointer(value, [token | tokens]) do
    token = token |> String.replace("~1", "/") |> String.replace("~0", "~")

    cond do
      is_map(value) and Map.has_key?(value, token) ->
        pointer(Map.fetch!(value, token), tokens)

      is_list(value) and Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, token) and
          String.to_integer(token) < length(value) ->
        pointer(Enum.at(value, String.to_integer(token)), tokens)

      true ->
        :error
    end
  end

  # The members of a map of named schemas, `properties` or `$defs`, by name.
  defp bounds_each(acc, named, place, documents) when is_map(named),
    do:
      Enum.reduce(named, acc, fn {_name, schema}, acc ->
        bounds(schema, place, acc, documents)
      end)

  defp bounds_each(_acc, named, _place, _documents),
    do: refuse("named schemas that are not a map", named)

  defp bounds_list(acc, schemas, place, documents) when is_list(schemas),
    do: Enum.reduce(schemas, acc, &bounds(&1, place, &2, documents))

  defp bounds_list(_acc, schemas, _place, _documents),
    do: refuse("schemas that are not a list", schemas)

  defp refuse(what, schema), do: raise(ArgumentError, "#{what}: #{inspect(schema)}")

  @doc """
  file!/2 is `from_schema/2` of the JSON Schema file at `path` under the application's
  `priv`, with `documents` the files under `priv` it refers to, each a path by its URL;
  read once and kept in `:persistent_term`.
  """
  @spec file!([String.t()], %{optional(String.t()) => [String.t()]}) :: limits
  def file!(path, documents \\ %{}) when is_list(path) and is_map(documents) do
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      nil ->
        limits = from_schema(read!(path), Map.new(documents, fn {url, p} -> {url, read!(p)} end))
        :persistent_term.put(key, limits)
        limits

      limits ->
        limits
    end
  end

  defp read!(path),
    do: Application.app_dir(:apiary, ["priv" | path]) |> File.read!() |> Jason.decode!()
end
