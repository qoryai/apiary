defmodule Apiary.Explore.Result do
  # Result reads an Explore run's result: the JSON document of the explore contract's
  # `result.schema.json` (`priv/contract/explore/v1/`, vendored from the integrations at
  # 273fb00f) that the run's last `dev.qory.session.result` event carries in its `result`
  # string. The document is untrusted: whatever fails a check below is no result, `:none`,
  # never an error and never a raise.
  #
  # `from_events/1` picks the event: among the run's events of type
  # `dev.qory.session.result`, the one with the highest `sequence` (a run's sequences are
  # unique). That event alone counts: when its `data` has an `is_error` other than
  # `false`, or no `result` string, the run has no result, whatever an earlier result
  # event said; so has a run without a result event.
  #
  # `parse/1` reads the result string, in this order:
  #
  #   * at most 128 KiB, 131072 bytes, counted on the string as the event carries it once
  #     the event is read, not on the escaped form the event's JSON writes it in;
  #   * valid UTF-8, checked before any function that assumes it;
  #   * one JSON object, its numbers with a fraction or an exponent read exactly;
  #   * a `version` that is exactly 1, however it is written;
  #   * no list longer, and no object with more members, than the schema allows anywhere,
  #     checked in one walk of the decoded document before the schema, so a document of
  #     tens of thousands of entries costs its reading, not a check of each entry;
  #   * valid against `result.schema.json`: every object refuses a member the schema does
  #     not define, the verdict decides which members are required or absent, every text
  #     refuses the control, bidirectional, separator and format characters the schema's
  #     `$defs/text` lists, and every source is an https URL whose authority is not empty
  #     and holds no `@` and no backslash, with no space or refused character anywhere.
  #     A refusal is `:none` as soon as JSV gives it; its errors are not read.
  #
  # Two changes to how the schema is built make it read as the contract means it:
  #
  #   * JSV counts `minLength` and `maxLength` in graphemes, and the contract counts
  #     characters, code points, as JSON Schema does: a text of 2002 code points written as
  #     1001 letters with a combining accent would pass a `maxLength` of 2000. Each
  #     `minLength` and `maxLength` is replaced, before the schema is built, by a pattern
  #     that counts code points between the same bounds (`code_point_lengths/1`).
  #   * PCRE's `$` also matches before a final line feed; `Apiary.Kinds.Schema` builds the
  #     schema with each `$` read as the end of the string (`Apiary.Kinds.Pattern`), as the
  #     contract reads it.
  #
  # A result is the decoded document: a map with string keys, as the schema has them,
  # such as `%{"version" => 1, "verdict" => "not_understood", "questions" => [...]}`;
  # `version` is the integer 1 however the text wrote it.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.Kinds.Schema

  @type result :: %{optional(String.t()) => term}

  @event "dev.qory.session.result"
  @schema ["contract", "explore", "v1", "result.schema.json"]
  @max_bytes 128 * 1024

  # The keywords whose value is data, not a schema: their members are left as they are.
  @data_keywords ~w(const enum default examples)

  # from_events/1 is the result of a run whose events are `events`: maps or
  # `Apiary.Runs.Event` structs with `type`, `sequence` and `data`, in any order.
  # `{:ok, result}` from the result event with the highest sequence when its `is_error`
  # is `false` and its `result` string passes `parse/1`; `:none` otherwise.
  @doc false
  @spec from_events(Enumerable.t()) :: {:ok, result} | :none
  def from_events(events) do
    events
    |> Enum.filter(&result_event?/1)
    |> Enum.max_by(& &1.sequence, fn -> nil end)
    |> from_event()
  end

  defp result_event?(%{type: @event, sequence: sequence}) when is_integer(sequence), do: true
  defp result_event?(_event), do: false

  defp from_event(%{data: %{"is_error" => false, "result" => text}}) when is_binary(text),
    do: parse(text)

  defp from_event(_event), do: :none

  # parse/1 checks `text`, the `result` string of a result event: `{:ok, result}`, or
  # `:none` for anything that is not a binary, is larger than 128 KiB, is not UTF-8, is
  # not one JSON object, has a version that is not exactly 1, holds a list or an object
  # larger than the schema allows anywhere, or fails `result.schema.json`.
  @doc false
  @spec parse(term) :: {:ok, result} | :none
  def parse(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    with true <- String.valid?(text),
         {:ok, %{} = document} <- Jason.decode(text, floats: :decimals),
         {:ok, document} <- version(document),
         true <- within_bounds?(document, bounds()),
         {:ok, _document} <- JSV.validate(document, root()) do
      {:ok, document}
    else
      _refused -> :none
    end
  end

  def parse(_text), do: :none

  # A number with a fraction or an exponent is decoded as a `Decimal`, so 1.0000000000000001
  # stays itself and is not rounded to 1.0. The schema holds one number, `version`, which
  # is `const` 1: a version that is exactly 1, written 1, 1.0, 1e0 or 10e-1, is the
  # integer 1 in the result, and any other is refused. A `Decimal` anywhere else is
  # refused by `within_bounds?/2`: the schema takes no other number.
  defp version(%{"version" => %Decimal{} = number} = document) do
    if one?(number), do: {:ok, %{document | "version" => 1}}, else: :none
  end

  defp version(document), do: {:ok, document}

  # Exactly 1 is a coefficient of 10^k with the exponent -k. The exponent is bounded
  # first, by the digits 128 KiB can hold, so no power of ten larger than that is made.
  defp one?(%Decimal{sign: 1, coef: coef, exp: exp})
       when is_integer(coef) and exp <= 0 and exp >= -@max_bytes,
       do: coef == Integer.pow(10, -exp)

  defp one?(_number), do: false

  # within_bounds?/2 walks the decoded document once, before the schema is applied, and
  # refuses a list longer than `max_list` or an object with more members than
  # `max_members`, at any depth, and any struct. The bounds are the largest the schema
  # allows anywhere (`bounds/0`), so a document the schema accepts is never refused; a
  # document with tens of thousands of entries is refused here at the cost of reading
  # it, where JSV would check each entry. The walk keeps the values still to read in a
  # list and calls itself last, so nesting of any depth runs in constant stack.
  defp within_bounds?(document, {max_list, max_members}),
    do: walk([document], max_list, max_members)

  defp walk([], _max_list, _max_members), do: true

  defp walk([value | _rest], _max_list, _max_members) when is_struct(value), do: false

  defp walk([list | rest], max_list, max_members) when is_list(list) do
    if bounded_length?(list, max_list),
      do: walk(list ++ rest, max_list, max_members),
      else: false
  end

  defp walk([map | rest], max_list, max_members) when is_map(map) do
    if map_size(map) <= max_members,
      do: walk(Map.values(map) ++ rest, max_list, max_members),
      else: false
  end

  defp walk([_scalar | rest], max_list, max_members), do: walk(rest, max_list, max_members)

  # Whether `list` has at most `max` elements, reading at most `max + 1` of them.
  defp bounded_length?(_list, max) when max < 0, do: false
  defp bounded_length?([], _max), do: true
  defp bounded_length?([_head | tail], max), do: bounded_length?(tail, max - 1)

  # The schema, built once and kept (`Apiary.Kinds.Schema.file!/2`).
  defp root, do: Schema.file!(@schema, &code_point_lengths/1)

  # bounds/0 is `{max_list, max_members}` read from `result.schema.json` (`bounds/1`),
  # read once and kept in `:persistent_term`.
  @doc false
  @spec bounds() :: {pos_integer, pos_integer}
  def bounds do
    key = {__MODULE__, :bounds}

    case :persistent_term.get(key, nil) do
      nil ->
        bounds =
          Application.app_dir(:apiary, ["priv" | @schema])
          |> File.read!()
          |> Jason.decode!()
          |> bounds()

        :persistent_term.put(key, bounds)
        bounds

      bounds ->
        bounds
    end
  end

  # bounds/1 is `{max_list, max_members}` of a decoded JSON Schema: the largest `maxItems`
  # of a schema of type array, and the most `properties` of a schema of type object. It
  # holds only when every array has a `maxItems` and every object refuses a member it
  # does not define; a schema where one does not raises, so a bound is never guessed.
  @doc false
  @spec bounds(map) :: {pos_integer, pos_integer}
  def bounds(schema) when is_map(schema) do
    schema
    |> schema_nodes()
    |> Enum.reduce({0, 0}, fn
      %{"type" => "array", "maxItems" => max}, {lists, members} when is_integer(max) ->
        {max(lists, max), members}

      %{"type" => "array"} = node, _bounds ->
        raise ArgumentError, "an array without maxItems: #{inspect(node)}"

      %{"type" => "object", "additionalProperties" => false} = node, {lists, members} ->
        {lists, max(members, map_size(Map.get(node, "properties", %{})))}

      %{"type" => "object"} = node, _bounds ->
        raise ArgumentError, "an object that takes any member: #{inspect(node)}"

      _node, bounds ->
        bounds
    end)
  end

  # Every map of `schema`, itself included, at any depth, leaving out the values of the
  # data keywords.
  defp schema_nodes(schema) when is_map(schema) do
    [
      schema
      | Enum.flat_map(schema, fn
          {keyword, _value} when keyword in @data_keywords -> []
          {_keyword, value} -> schema_nodes(value)
        end)
    ]
  end

  defp schema_nodes(list) when is_list(list), do: Enum.flat_map(list, &schema_nodes/1)
  defp schema_nodes(_other), do: []

  # code_point_lengths/1 is `schema` with each object that has an integer `minLength` or
  # `maxLength` given the bounds as a pattern instead, `^[\s\S]{min,max}$`, which PCRE in
  # UTF mode counts in code points: `%{"allOf" => [rest, %{"pattern" => ...}]}`. Both
  # keywords and the pattern apply to strings only, so nothing else changes.
  @doc false
  @spec code_point_lengths(term) :: term
  def code_point_lengths(schema) when is_map(schema) do
    schema =
      Map.new(schema, fn
        {keyword, value} when keyword in @data_keywords -> {keyword, value}
        {keyword, value} -> {keyword, code_point_lengths(value)}
      end)

    case Map.split(schema, ["minLength", "maxLength"]) do
      {bounds, rest} when bounds != %{} ->
        min = Map.get(bounds, "minLength", 0)
        max = Map.get(bounds, "maxLength")

        if is_integer(min) and (is_integer(max) or is_nil(max)) do
          %{"allOf" => [rest, %{"pattern" => "^[\\s\\S]{#{min},#{max}}$"}]}
        else
          schema
        end

      _none ->
        schema
    end
  end

  def code_point_lengths(list) when is_list(list), do: Enum.map(list, &code_point_lengths/1)
  def code_point_lengths(other), do: other
end
