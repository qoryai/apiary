defmodule Apiary.Adapters.ChangeRequest do
  @moduledoc false

  # ChangeRequest checks a `change_request` entry of an adapter's change feed against the
  # integrations contract before Qory Apiary writes it.
  #
  # The entry is the `change_request` definition of `changes.schema.json`, vendored under
  # `priv/contract/integration/`. The schema covers the entry's `change_title` and `text`:
  # a title of 1 to 256 characters on one line, with no control character, no U+2028 or
  # U+2029, no format character other than U+200C and U+200D, and at least one character
  # that is not a space; a text without U+0000 and of at most 20,000 characters; and a
  # `data` that is a JSON object. A text with a `<!-- qory:start -->` line is valid: the
  # kind that needs the marker rule states it, not the envelope.
  #
  # The contract also bounds `data` at 786,432 bytes (768 KiB) serialized, which no schema
  # can count: `validate/1` counts it as `Jason.encode!/1` writes it, and returns
  # `{:error, summary}` for a larger one, with one error at `#/data`.
  #
  # The writer (`Apiary.Artifacts.Delivery`) calls `validate/1` before it writes an entry,
  # and sends nothing when the check fails.

  alias Apiary.Kinds.Schema

  @max_data 786_432

  @doc """
  validate/1 is `:ok` when the decoded `entry` (a map with string keys) is a valid
  `change_request` entry, or `{:error, summary}`, the summary of the schema's refusal
  (`Apiary.Kinds.Schema.summary/1`): the number of errors and, for the first 8, the
  keyword and where in the entry it is, for a log and not for a page. An entry the schema
  accepts whose `data` is over 786,432 bytes serialized has one error, of kind
  `:maxBytes`, at `#/data`.
  """
  @spec validate(term) :: :ok | {:error, map}
  def validate(entry) do
    case JSV.validate(entry, root(), cast: false) do
      {:ok, _entry} -> data_size(entry["data"])
      {:error, %JSV.ValidationError{} = error} -> {:error, Schema.summary(error)}
    end
  end

  # The part's serialized size, within the contract's bound.
  defp data_size(data) do
    if byte_size(Jason.encode!(data)) <= @max_data,
      do: :ok,
      else:
        {:error,
         %{valid: false, count: 1, errors: [%{kind: :maxBytes, instanceLocation: "#/data"}]}}
  end

  @doc "The most bytes the `data` of an entry has, serialized."
  @spec max_data() :: pos_integer
  def max_data, do: @max_data

  # The schema is the feed answer's; the entry is its `$defs.change_request`.
  defp root do
    Schema.file!(["contract", "integration", "changes.schema.json"], fn schema ->
      schema
      |> Map.take(["$schema", "$id", "$defs"])
      |> Map.put("$ref", "#/$defs/change_request")
    end)
  end
end
