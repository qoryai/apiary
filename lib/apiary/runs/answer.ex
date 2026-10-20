defmodule Apiary.Runs.Answer do
  @moduledoc false

  # The bytes of a run configuration sent with members beside the document: an attach's
  # `labels` and `about` (`Apiary.Runs.Attach`). The document's bytes are kept as they
  # are, and its digest stays the document's, the digest a reload of the run returns.

  @doc """
  `document`, one JSON object, with `members`, `{name, value}` in order, added after its
  last member, each value encoded as JSON; a member whose value is nil or empty is left
  out. Raises `ArgumentError` when the document has a member of one of the names already,
  since the run would be given two.
  """
  @spec append_members(binary, [{String.t(), term}]) :: binary
  def append_members(document, members) when is_binary(document) and is_list(members) do
    case Enum.reject(members, fn {_name, value} -> empty?(value) end) do
      [] ->
        document

      members ->
        present = document |> Jason.decode!() |> Map.keys()

        for {name, _value} <- members,
            name in present,
            do: raise(ArgumentError, "the run configuration has a #{name} member already")

        encoded =
          Enum.map(members, fn {name, value} ->
            [?,, Jason.encode!(name), ?:, Jason.encode!(value)]
          end)

        with_members(document, encoded)
    end
  end

  defp empty?(value), do: value in [nil, %{}] or value == Jason.OrderedObject.new([])

  # A document is one JSON object: its members end before its last `}`.
  defp with_members(document, members) do
    trimmed = String.trim_trailing(document)
    size = byte_size(trimmed) - 1
    <<head::binary-size(^size), "}">> = trimmed
    members = if String.trim(head) == "{", do: tl(List.flatten(members)), else: members
    IO.iodata_to_binary([head, members, "}"])
  end
end
