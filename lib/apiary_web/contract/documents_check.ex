defmodule ApiaryWeb.Contract.DocumentsCheck do
  @moduledoc false

  # The rules of a run's documents that `documents.schema.json` cannot state and that
  # `Documents.Check()` of qoryai/integrations (`contracts/run.go`) states in Go, which
  # Qory Apiary cannot call. `check/1` reports the first one that the documents break,
  # with the message of the Go function, in the same order:
  #
  #   1. no two entries of `deliver` have the same `type`;
  #   2. no two entries of `further_targets` have the same `collection`, and none has the
  #      `collection` of `target`.
  #
  # Call it after the schema has accepted the documents: it reads only the members that the
  # schema defines, and a document the schema refuses has no defined answer here.
  #
  # At this commit nothing calls it: no run's documents have `deliver` or `further_targets`
  # until the control plane writes them.

  @doc """
  check/1 is `:ok` for the decoded run `documents` (a map with string keys), or
  `{:error, message}` with the message of `Documents.Check()` for the first rule they break.
  """
  @spec check(map) :: :ok | {:error, String.t()}
  def check(documents) when is_map(documents) do
    with :ok <- deliver_types(documents["deliver"]) do
      further_targets(documents["target"], documents["further_targets"])
    end
  end

  defp deliver_types(entries) do
    entries
    |> List.wrap()
    |> Enum.map(& &1["type"])
    |> first_repeat()
    |> case do
      nil -> :ok
      type -> {:error, "List each deliver type once: #{quote_string(type)} appears twice."}
    end
  end

  defp further_targets(target, entries) do
    main = target && target["collection"]

    entries
    |> List.wrap()
    |> Enum.map(& &1["collection"])
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {collection, index}, seen ->
      cond do
        main != nil and collection == main ->
          {:halt,
           {:error,
            "Remove the collection #{quote_string(collection)} from further_targets " <>
              "(index #{index}): target has it."}}

        collection in seen ->
          {:halt,
           {:error,
            "List each collection of further_targets once: " <>
              "#{quote_string(collection)} appears twice."}}

        true ->
          {:cont, MapSet.put(seen, collection)}
      end
    end)
    |> case do
      {:error, _message} = error -> error
      _seen -> :ok
    end
  end

  # The first value, in the order of the list, that an earlier entry already has.
  defp first_repeat(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if value in seen, do: {:halt, {:repeat, value}}, else: {:cont, MapSet.put(seen, value)}
    end)
    |> case do
      {:repeat, value} -> value
      _seen -> nil
    end
  end

  # Go's `%q` (`strconv.Quote`): the string in double quotes; `\` and `"` escaped with a
  # backslash; `\a \b \f \n \r \t \v` for those controls; `\xNN` for any other character
  # below U+0020 and U+007F; `\uNNNN` or `\UNNNNNNNN`, in lower case, for any other
  # character that Go's `unicode.IsPrint` refuses. IsPrint is true for a letter, mark,
  # number, punctuation or symbol, and for U+0020 alone; `printable?/1` tests the first four.
  # shortcut: the categories are those of this Erlang/OTP release, not of Go's Unicode
  # version, so a character that only one of them has assigned is written differently;
  # replace it when a collection ref or a type may hold such a character. A decoded JSON
  # string has no invalid UTF-8, so Go's `\xNN` for an invalid byte is not needed.
  defp quote_string(value) when is_binary(value) do
    escaped = for <<char::utf8 <- value>>, into: "", do: escape(char)
    ~s("#{escaped}")
  end

  defp escape(?\\), do: "\\\\"
  defp escape(?"), do: "\\\""
  defp escape(7), do: "\\a"
  defp escape(8), do: "\\b"
  defp escape(12), do: "\\f"
  defp escape(?\n), do: "\\n"
  defp escape(?\r), do: "\\r"
  defp escape(?\t), do: "\\t"
  defp escape(11), do: "\\v"
  defp escape(char) when char < 0x20 or char == 0x7F, do: "\\x" <> hex(char, 2)
  defp escape(?\s), do: " "

  defp escape(char) do
    cond do
      printable?(char) -> <<char::utf8>>
      char < 0x10000 -> "\\u" <> hex(char, 4)
      true -> "\\U" <> hex(char, 8)
    end
  end

  defp printable?(char), do: Regex.match?(~r/\A[\p{L}\p{M}\p{N}\p{P}\p{S}]\z/u, <<char::utf8>>)

  defp hex(code, width),
    do: code |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
end
