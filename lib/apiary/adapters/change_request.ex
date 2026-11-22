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
  # At this commit no code writes a `change_request` entry. The writer calls `validate/1`
  # before it writes one, and sends nothing when the check fails.

  alias Apiary.Kinds.Schema

  @doc """
  validate/1 is `:ok` when the decoded `entry` (a map with string keys) is a valid
  `change_request` entry, or `{:error, summary}`, the summary of the schema's refusal
  (`Apiary.Kinds.Schema.summary/1`): the number of errors and, for the first 8, the
  keyword and where in the entry it is, for a log and not for a page.
  """
  @spec validate(term) :: :ok | {:error, map}
  def validate(entry) do
    case JSV.validate(entry, root(), cast: false) do
      {:ok, _entry} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, Schema.summary(error)}
    end
  end

  # The schema is the feed answer's; the entry is its `$defs.change_request`.
  defp root do
    Schema.file!(["contract", "integration", "changes.schema.json"], fn schema ->
      schema
      |> Map.take(["$schema", "$id", "$defs"])
      |> Map.put("$ref", "#/$defs/change_request")
    end)
  end
end
