defmodule Apiary.Artifacts.SchemaError do
  # SchemaError is the first place where a structured file fails its JSON Schema, as a
  # person or a run reads it: `%{path: path, error: error}`, `path` the JSON pointer of
  # the failing value (`#/gaps/1`) and `error` JSV's message for it ("value is not of
  # type string").
  #
  # "First" is in one order for one file and one schema: JSV's errors sorted by their
  # data path, segment by segment, then by keyword, the ties in JSV's order. An error
  # that only points at a deeper one, such as "property 'gaps' did not conform to the
  # property schema", is passed over while a deeper error exists. An `if` error is the
  # errors of its failed `then` or `else` schema, each with its path, so "value validated
  # 'if' but not 'then'" is replaced by a message such as "property 'fix' is not
  # allowed"; an `if` error with none keeps its message. An `if` inside an `allOf` is
  # read so only with `unwrap: true`, or with `unwrap: :conditions` where every failed
  # schema of the `allOf` is an `if`. Outside an `allOf` are the check on a verdict's
  # point (`verdict.schema.json`) and the two checks in `questions.schema.json` that an
  # answer with option null has a note. A verdict's top-level checks, the checks on a
  # question in `questions.schema.json` (its answer, its decision, and `about.item` where
  # an option has `proposal`) and every `if` in `review-comments.schema.json` sit inside
  # an `allOf`. With `unwrap: :conditions`, as for the type `questions`, a question with
  # `proposal` and an `about` with no `item` fails as "property 'item' is required" at
  # the question's `about`, and an `allOf` of a length limit keeps its message. With
  # `unwrap: true`, as for the type `mockup`, an `allOf` error, which a `$ref` to a
  # definition with a limit on its length makes, is the errors of its schemas that
  # failed, so "value did not conform to all of the given schemas" is replaced by the
  # failing limit's message. With either, a `oneOf` that no schema matched, as a question's
  # `about` in `questions.schema.json`, is the errors of the schema the value is closest
  # to (`failed/2`): an `item` of the acceptance criteria that is no criterion id fails at
  # `#/questions/0/about/item` with its pattern.
  #
  # Both strings come from the file: a member name is part of the path, and a message
  # can quote a member name or a value. Each is cut to at most 1,024 bytes before its
  # control characters are replaced (`Apiary.ExternalText.line/1`), then the path to at
  # most 256 bytes and the error to at most 300 characters, on a character boundary.
  # A caller that validates within a budget calls `first/2` inside it.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  alias Apiary.ExternalText
  alias JSV.ErrorFormatter

  @path_bytes 256
  @error_characters 300
  @raw_bytes 1024

  @typedoc "Where a structured file fails its JSON Schema, and why."
  @type t :: %{path: String.t(), error: String.t()}

  # first/2 is the first failing place of JSV's `error`; `opts` is `[]`,
  # `[unwrap: true]`, which reads the errors inside an `allOf`, or
  # `[unwrap: :conditions]`, which reads them only where each failed schema of the
  # `allOf` is an `if`. The errors inside an `if` are read with each.
  @doc false
  @spec first(JSV.ValidationError.t(), keyword) :: t
  def first(%JSV.ValidationError{errors: errors}, opts \\ []) do
    all_of? = Keyword.get(opts, :unwrap, false)
    true = all_of? in [true, false, :conditions]
    errors = Enum.flat_map(errors, &failed(&1, all_of?))

    sorted = Enum.sort_by(errors, &{Enum.reverse(&1.data_path), &1.kind})

    {error, message} =
      Enum.find_value(sorted, fn error ->
        case message(error) do
          {:leaf, message} -> {error, message}
          {:pointer, _message} -> nil
        end
      end) || first_pointer(sorted)

    detail(ErrorFormatter.format_data_path(error.data_path), message)
  end

  # detail/2 is `path` and `error` cut and cleaned as `first/1` returns them.
  @doc false
  @spec detail(String.t(), String.t()) :: t
  def detail(path, error) do
    %{
      path: path |> cleaned() |> cut_bytes(@path_bytes),
      error: error |> cleaned() |> cut_characters(@error_characters)
    }
  end

  # An `allOf` error, where `all_of?` is true, or `:conditions` and each of its failed
  # schemas is an `if`, is the errors of its failed schemas, and an `if` error the errors
  # of its failed `then` or `else` schema, each read the same way.
  defp failed(%{kind: :allOf, args: args} = error, true) do
    unwrapped(error, all_of_errors(args), true)
  end

  defp failed(%{kind: :allOf, args: args} = error, :conditions) do
    nested = all_of_errors(args)

    if nested != [] and Enum.all?(nested, &(&1.kind == :jsv@if)),
      do: unwrapped(error, nested, :conditions),
      else: [error]
  end

  defp failed(%{kind: :jsv@if, args: args} = error, all_of?) do
    nested =
      case Keyword.get(args, :after_err_vctx) do
        %{errors: errors} -> :lists.flatten(errors)
        _none -> []
      end

    unwrapped(error, nested, all_of?)
  end

  # A `oneOf` error where no schema matched, read with `unwrap`, is the errors of the one
  # schema that has an error at a place deeper than the `oneOf`'s, not counting an error
  # that its parent reports (`message/1`): the shape the value is closest to. Where no
  # schema's errors, or more than one's, reach deeper, it keeps its message.
  defp failed(%{kind: :oneOf, args: args, data_path: path} = error, all_of?)
       when all_of? in [true, :conditions] do
    deeper =
      for {_index, %{errors: errors}} <- Keyword.get(args, :invalidated, []),
          nested = Enum.flat_map(:lists.flatten(errors), &failed(&1, all_of?)),
          Enum.any?(nested, &(length(&1.data_path) > length(path) and leaf?(&1))),
          do: nested

    case deeper do
      [nested] -> nested
      _none_or_more -> [error]
    end
  end

  defp failed(error, _all_of?), do: [error]

  defp all_of_errors(args) do
    for {_index, %{errors: errors}} <- Keyword.get(args, :invalidated, []),
        error <- :lists.flatten(errors),
        do: error
  end

  defp unwrapped(error, [], _all_of?), do: [error]
  defp unwrapped(_error, nested, all_of?), do: Enum.flat_map(nested, &failed(&1, all_of?))

  defp leaf?(error), do: match?({:leaf, _message}, message(error))

  defp first_pointer([error | _rest]) do
    {_level, message} = message(error)
    {error, message}
  end

  # JSV's message for one error: `{:leaf, message}`, or `{:pointer, message}` for one
  # whose level is below JSV's cause level, a message that points at a deeper error or one
  # that its parent's error reports.
  defp message(%{kind: kind, args: args, data: data, formatter: formatter}) do
    case formatter.format_error(kind, Map.new(args), data) do
      message when is_binary(message) ->
        {:leaf, message}

      %{message: message} = map when is_binary(message) ->
        if Map.get(map, :level, ErrorFormatter.level_cause()) < ErrorFormatter.level_cause(),
          do: {:pointer, message},
          else: {:leaf, message}

      _other ->
        {:leaf, Atom.to_string(kind)}
    end
  end

  defp cleaned(text), do: text |> cut_bytes(@raw_bytes) |> ExternalText.line() |> :binary.copy()

  # The longest start of `text` of at most `bytes` bytes that ends on a character.
  defp cut_bytes(text, bytes) when byte_size(text) <= bytes, do: text
  defp cut_bytes(text, bytes), do: text |> binary_part(0, bytes) |> whole_characters()

  defp whole_characters(text) do
    if String.valid?(text),
      do: text,
      else: whole_characters(binary_part(text, 0, byte_size(text) - 1))
  end

  # The first `count` characters (code points) of `text`.
  defp cut_characters(text, count), do: take(text, count, 0, text)

  defp take(_rest, 0, taken, text), do: binary_part(text, 0, taken)
  defp take(<<>>, _count, _taken, text), do: text

  defp take(<<char::utf8, rest::binary>>, count, taken, text),
    do: take(rest, count - 1, taken + byte_size(<<char::utf8>>), text)
end
