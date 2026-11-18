defmodule Apiary.Variables.Denied do
  @moduledoc """
  The variable names Forager leaves out of what the server gives a run: Forager's built-in
  deny list, `denied-variables.json`, vendored byte for byte as
  `priv/contract/denied-variables.json` at the commit in `.forager-contract-ref`. It has
  four lists, each matched against a whole name without case, `*` standing for any run
  of characters, the empty one included: `names` and `patterns`, which no value reaches
  the run's process by, and `forge_tokens` and `model_keys`, the names a code forge's
  token and a model key are read from. The file is read when the application is
  compiled.

  Two questions ask it:

    * `left_out?/1`, for a variable: a name on any of the four lists. A run receives none
      of them: `Apiary.Variables.for_run/2` leaves them out, and a page warns when one is
      saved.
    * `denied?/1`, for a connection's placeholder: a name of `names` or a pattern of
      `patterns` alone. Forager allows a placeholder on a forge token's name or a model
      key's name, which the gateway then replaces.

  Saving a name on the list is warned about, not refused, since Forager leaves it out
  anyway, with one exception: a name matching `QORY_*` is reserved for Forager, and is
  refused at every level (`refused?/1`).

  Forager's `QORY_*` entry leaves in two names when the server sets them, by these names
  exactly, in upper case: `QORY_RUN_SYSTEM` and `QORY_RUN_REPOSITORIES`, the system and the
  paths in it a run's preparation may use. Only the server sets them, for a run it
  composes them for; a level's variable of either name is still refused on save.
  """

  @path Path.join([__DIR__, "..", "..", "..", "priv", "contract", "denied-variables.json"])
  @external_resource @path

  # A list the file lacks fails the compile, as a key `Runtimes` needs does.
  @list (fn ->
           %{
             "version" => 1,
             "names" => names,
             "patterns" => patterns,
             "forge_tokens" => forge_tokens,
             "model_keys" => model_keys
           } = @path |> File.read!() |> Jason.decode!()

           %{
             names: names,
             patterns: patterns,
             forge_tokens: forge_tokens,
             model_keys: model_keys
           }
         end).()

  @refused ["QORY_*"]

  @doc "The list's `names`, matched whole and without case."
  @spec names() :: [String.t()]
  def names, do: @list.names

  @doc "The list's `patterns`, matched whole and without case, `*` for any run of characters."
  @spec patterns() :: [String.t()]
  def patterns, do: @list.patterns

  @doc "The list's `forge_tokens`, matched whole and without case."
  @spec forge_tokens() :: [String.t()]
  def forge_tokens, do: @list.forge_tokens

  @doc "The list's `model_keys`, matched whole and without case."
  @spec model_keys() :: [String.t()]
  def model_keys, do: @list.model_keys

  @doc """
  denied?/1 says whether a connection's placeholder may not take `name`: a name of the
  list's `names`, or matching one of its `patterns`. A forge token's or a model key's name
  is not denied here (`left_out?/1`).
  """
  @spec denied?(String.t()) :: boolean
  def denied?(name) when is_binary(name) do
    listed?(@list.names, name) or Enum.any?(@list.patterns, &matches?(&1, name))
  end

  @doc """
  left_out?/1 says whether a run is given no variable of `name`: a name of any of the four
  lists, or matching a pattern.
  """
  @spec left_out?(String.t()) :: boolean
  def left_out?(name) when is_binary(name) do
    denied?(name) or listed?(@list.forge_tokens, name) or listed?(@list.model_keys, name)
  end

  defp listed?(names, name) do
    upcased = String.upcase(name)
    Enum.any?(names, &(String.upcase(&1) == upcased))
  end

  @doc """
  refused?/1 says whether `name` is refused on save at every level: a name beginning
  `QORY_`, whatever its case, which is reserved for Forager.
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
