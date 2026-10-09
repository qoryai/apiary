defmodule Apiary.Variables.Denied do
  @moduledoc """
  The variable names Forager leaves out of what the server gives a run: the names and
  patterns of the Forager contract's deny list (`denied-variables.json`), matched against
  a whole name without case, `*` standing for any run of characters, the empty one
  included.

  Saving a name on the list is warned about, not refused, since Forager leaves it out
  anyway, with one exception: a name matching `QORY_*` is Forager's own, and is
  refused at every level (`refused?/1`).

  The list holds only `QORY_*` until the contract's file is vendored and read here.
  """

  @names []
  @patterns ["QORY_*"]
  @refused ["QORY_*"]

  @doc "The names on the list, matched whole and without case."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The patterns on the list, matched whole and without case, `*` for any run of characters."
  @spec patterns() :: [String.t()]
  def patterns, do: @patterns

  @doc "denied?/1 says whether `name` is on the list: a name of it, or matching a pattern."
  @spec denied?(String.t()) :: boolean
  def denied?(name) when is_binary(name) do
    upcased = String.upcase(name)

    Enum.any?(@names, &(String.upcase(&1) == upcased)) or
      Enum.any?(@patterns, &matches?(&1, name))
  end

  @doc """
  refused?/1 says whether `name` is refused on save at every level: a name beginning
  `QORY_`, whatever its case, which is Forager's own.
  """
  @spec refused?(String.t()) :: boolean
  def refused?(name) when is_binary(name), do: Enum.any?(@refused, &matches?(&1, name))

  @doc """
  matches?/2 says whether `pattern` matches the whole of `name`, without case: `*`
  matches any run of characters, the empty one included; every other character itself.
  """
  @spec matches?(String.t(), String.t()) :: boolean
  def matches?(pattern, name) when is_binary(pattern) and is_binary(name) do
    source =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(Regex.compile!("\\A" <> source <> "\\z", "i"), name)
  end
end
