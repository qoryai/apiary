defmodule Apiary.Artifacts.SchemaError do
  # SchemaError is the first place where a structured file fails its JSON Schema, as a
  # person or a run reads it: `%{path: path, error: error}`, `path` the JSON pointer of
  # the failing value (`#/gaps/1`) and `error` JSV's message for it ("value is not of
  # type string").
  #
  # "First" is in one order for one file and one schema: JSV's errors sorted by their
  # data path, segment by segment, then by keyword, the ties in JSV's order. An error
  # that only points at a deeper one, such as "property 'gaps' did not conform to the
  # property schema", is passed over while a deeper error exists. An `allOf` error, which
  # a `$ref` to a definition with a limit on its length makes, is the errors of its
  # schemas that failed, so "value did not conform to all of the given schemas" is
  # replaced by the failing limit's message.
  #
  # Both strings come from the file: a member name is part of the path, and a message
  # can quote a member name or a value. Each is cut to at most 1,024 bytes before its
  # control characters are replaced (`Apiary.ExternalText.line/1`), then the path to at
  # most 256 bytes and the error to at most 300 characters, on a character boundary.
  # A caller that validates within a budget calls `first/1` inside it.
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

  # first/1 is the first failing place of JSV's `error`.
  @doc false
  @spec first(JSV.ValidationError.t()) :: t
  def first(%JSV.ValidationError{errors: errors}) do
    sorted =
      errors |> Enum.flat_map(&failed/1) |> Enum.sort_by(&{Enum.reverse(&1.data_path), &1.kind})

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

  # An `allOf` error is the errors of its failed schemas, each read the same way.
  defp failed(%{kind: :allOf, args: args} = error) do
    nested =
      for {_index, %{errors: errors}} <- Keyword.get(args, :invalidated, []),
          error <- errors,
          do: error

    if nested == [], do: [error], else: Enum.flat_map(nested, &failed/1)
  end

  defp failed(error), do: [error]

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
