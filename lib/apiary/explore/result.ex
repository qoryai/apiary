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
  #   * one JSON document;
  #   * valid against `result.schema.json`: every object refuses a member the schema does
  #     not define, the verdict decides which members are required or absent, every text
  #     refuses the control, bidirectional, separator and format characters the schema's
  #     `$defs/text` lists, and every source is an https URL whose authority is not empty
  #     and holds no `@` and no backslash, with no space or refused character anywhere.
  #
  # Two things are done in code beside the schema, so the schema reads as the contract
  # means it:
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
  # such as `%{"version" => 1, "verdict" => "not_understood", "questions" => [...]}`.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.Kinds.Schema

  @type result :: %{optional(String.t()) => term}

  @event "dev.qory.session.result"
  @schema ["contract", "explore", "v1", "result.schema.json"]
  @max_bytes 128 * 1024

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
  # not one JSON document or fails `result.schema.json`.
  @doc false
  @spec parse(term) :: {:ok, result} | :none
  def parse(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    with true <- String.valid?(text),
         {:ok, document} <- Jason.decode(text),
         :ok <- Schema.validate(document, root()) do
      {:ok, document}
    else
      _refused -> :none
    end
  end

  def parse(_text), do: :none

  # The schema, built once and kept (`Apiary.Kinds.Schema.file!/2`).
  defp root, do: Schema.file!(@schema, &code_point_lengths/1)

  # The keywords whose value is data, not a schema: their members are left as they are.
  @data_keywords ~w(const enum default examples)

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
