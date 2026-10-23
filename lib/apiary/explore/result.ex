defmodule Apiary.Explore.Result do
  # Result reads an Explore run's result: the JSON document of the explore contract's
  # `result.schema.json` (`priv/contract/explore/v1/`, vendored from the integrations at
  # the commit in `test/fixtures/contract/explore/v1/.contract-ref`) that the run's last
  # `dev.qory.runtime.result` event carries in its `result` string. The document is
  # untrusted: whatever fails a check below is no result, `:none`, never an error and
  # never a raise.
  #
  # `from_events/1` picks the event: among the run's events of type
  # `dev.qory.runtime.result`, the one with the highest `sequence` (a run's sequences are
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
  #   * a `version` that is exactly 1: written with at most 33 significant digits it is
  #     always read; with more, decoding may fail and the document is refused;
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
  # `outcome/1` says what one result event gave, and `given/3` what a run ended by its
  # exit, or by an outcome stored before a run of the queue was refused one, gave once it
  # is settled (`settled?/2`): the reading Explore shows
  # (`Apiary.WorkItems.Explore`) and the one Qory keeps on the run of the queue
  # (`Apiary.Dispatches.Settle`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.Kinds.{Bounds, Schema}
  alias Apiary.Runs.Run

  @type result :: %{optional(String.t()) => term}

  @typedoc "What a run gave: its result's verdict, or why it has none."
  @type outcome :: :proposal | :questions | :error | :none | :refused

  @event "dev.qory.runtime.result"
  # How long after its outcome arrived a run with no result yet is not settled.
  @settle_seconds 600
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

  # event_type/0 is the type of a run's result event.
  @doc false
  @spec event_type() :: String.t()
  def event_type, do: @event

  # settle_seconds/0 is how long after its outcome arrived a run with no result yet is
  # not settled.
  @doc false
  @spec settle_seconds() :: pos_integer
  def settle_seconds, do: @settle_seconds

  # outcome/1 is what the result event `event` gave, nil for none: `{:proposal, result}`
  # for a result whose verdict is `understood`, `{:questions, result}` for one whose
  # verdict is `not_understood`, `{:none, nil}` for no event, or one whose `is_error` is
  # `false` and that carries no result, `{:refused, nil}` for a result that fails the
  # check, and `{:error, nil}` for an event whose `is_error` is anything else.
  @doc false
  @spec outcome(map | nil) :: {outcome, result | nil}
  def outcome(nil), do: {:none, nil}

  def outcome(%{data: %{"is_error" => false, "result" => text}} = event) when is_binary(text) do
    case from_events([event]) do
      {:ok, %{"verdict" => "understood"} = result} -> {:proposal, result}
      {:ok, %{"verdict" => "not_understood"} = result} -> {:questions, result}
      _refused -> {:refused, nil}
    end
  end

  def outcome(%{data: %{"is_error" => false}}), do: {:none, nil}
  def outcome(_event), do: {:error, nil}

  # given/3 is what a run ended by its exit, or by an outcome stored before a run of the
  # queue was refused one, gave, from `run`, the run
  # registered for it or nil, and `event`, its result event with the highest sequence or
  # nil, at `now`: a proposal or questions as soon as its result says so, `:unsettled`
  # while it has none and is not settled, and otherwise `:none`, `:error` or `:refused`.
  @doc false
  @spec given(Run.t() | nil, map | nil, DateTime.t()) ::
          {:proposal | :questions, result} | :error | :none | :refused | :unsettled
  def given(run, event, %DateTime{} = now) do
    case outcome(event) do
      {verdict, result} when verdict in [:proposal, :questions] -> {verdict, result}
      {outcome, nil} -> if settled?(run, now), do: outcome, else: :unsettled
    end
  end

  # settled?/2 says whether a run ended by its exit, or by an outcome stored before a run
  # of the queue was refused one, registered as `run`
  # (nil for none), has at `now` every event that will count: its exit is folded (the
  # projector folds the events before it first), it is lost, its events are pruned, it
  # has no outcome, or its outcome arrived `settle_seconds/0` ago or more.
  @doc false
  @spec settled?(Run.t() | nil, DateTime.t()) :: boolean
  def settled?(nil, _now), do: true

  def settled?(%Run{} = run, %DateTime{} = now) do
    cond do
      is_binary(run.exit_state) -> true
      not is_nil(run.lost_at) or run.state == "lost" -> true
      not is_nil(run.events_pruned_at) -> true
      is_nil(run.outcome_received_at) -> true
      true -> DateTime.diff(now, run.outcome_received_at, :second) >= @settle_seconds
    end
  end

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
         true <- within_bounds?(document),
         {:ok, _document} <- JSV.validate(document, root(), cast: false) do
      {:ok, document}
    else
      _refused -> :none
    end
  end

  def parse(_text), do: :none

  # A number with a fraction or an exponent is decoded as a `Decimal`, so 1.0000000000000001
  # stays itself and is not rounded to 1.0. Decimal parses at most 34 significant digits,
  # leading zeros not counted, and an exponent of at most 6144 by default, a limit kept
  # against numbers that cost too much to read; Jason writes a number with an exponent and
  # no fraction with a fraction of `.0` before Decimal reads it, one digit more. So a
  # version that is exactly 1, written with at most 33 significant digits, such as 1,
  # 1.0, 1e0 or 10e-1, is always read; with more, decoding may fail and the document is
  # refused. The schema holds one number, `version`, which is `const` 1: one that is read
  # and exactly 1 is the integer 1 in the result, and any other is refused. A `Decimal`
  # anywhere else is refused by `within_bounds?/1`: the schema takes no other number.
  defp version(%{"version" => %Decimal{} = number} = document) do
    if one?(number), do: {:ok, %{document | "version" => 1}}, else: :none
  end

  defp version(document), do: {:ok, document}

  # Exactly 1 is a coefficient of 10^k with the exponent -k. Decimal has already bounded
  # the exponent; the guard on it here is a backstop, so no power of ten larger than the
  # digits 128 KiB can hold is ever made.
  defp one?(%Decimal{sign: 1, coef: coef, exp: exp})
       when is_integer(coef) and exp <= 0 and exp >= -@max_bytes,
       do: coef == Integer.pow(10, -exp)

  defp one?(_number), do: false

  # within_bounds?/1 walks the decoded `document` once, before the schema is applied, and
  # is false for a list longer than the schema allows anywhere or an object with more
  # members, at any depth, and for any struct (`Apiary.Kinds.Bounds.within?/2`, with
  # `bounds/0`). A document the schema accepts always passes; a document with tens of
  # thousands of entries is refused here at the cost of reading it, where JSV would check
  # each entry. The walk runs in constant stack, so nesting of any depth passes it.
  @doc false
  @spec within_bounds?(term) :: boolean
  def within_bounds?(document), do: Bounds.within?(document, bounds())

  # The schema, built once and kept (`Apiary.Kinds.Schema.file!/2`).
  defp root, do: Schema.file!(@schema, &code_point_lengths/1)

  # bounds/0 is `[list: max_list, members: max_members]` read from `result.schema.json`
  # (`Apiary.Kinds.Bounds.file!/2`): the largest `maxItems` of a schema of type array, and
  # the most `properties` of a schema of type object, read once and kept.
  @doc false
  @spec bounds() :: Bounds.limits()
  def bounds, do: Bounds.file!(@schema)

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
