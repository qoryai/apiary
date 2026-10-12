defmodule Apiary.Kinds.Pattern do
  @moduledoc """
  Pattern compiles the regular expressions of Forager's and the integrations' contracts
  the way the contracts read them.

  Every pattern of the contracts is anchored, and `$` there is the end of the string, as
  in RE2 and ECMAScript: a value with a trailing newline does not match. PCRE's `$` also
  matches before a final newline, so `"github\\n"` would pass `^[a-z]+$`. A pattern
  Qory Apiary compiles itself is compiled with `:dollar_endonly` (`compile!/1`,
  `whole_match?/2`). JSV compiles the `pattern` and `patternProperties` of a JSON Schema
  itself, so a schema is first given to `end_only/1`, which writes each `$` that is an
  anchor as `\\z`, the meaning `:dollar_endonly` gives it, before JSV builds it.
  """

  @doc "compile!/1 compiles `source` with `:unicode` and `:dollar_endonly`."
  @spec compile!(String.t()) :: Regex.t()
  def compile!(source) when is_binary(source),
    do: Regex.compile!(source, [:unicode, :dollar_endonly])

  @doc """
  compile/1 compiles `source` with `:unicode` and `:dollar_endonly`: `{:ok, regex}`, or
  `{:error, reason}` for a pattern PCRE does not take.
  """
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, term}
  def compile(source) when is_binary(source),
    do: Regex.compile(source, [:unicode, :dollar_endonly])

  @doc """
  whole_match?/2 says whether `pattern`, an RE2 pattern of a description, matches the
  whole of `value`, as Forager matches an argument: false for a pattern that does not
  compile.
  """
  @spec whole_match?(String.t(), String.t()) :: boolean
  def whole_match?(pattern, value) when is_binary(pattern) and is_binary(value) do
    case compile("\\A(?:" <> pattern <> ")\\z") do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  # The keywords whose value is data, not a schema: their members are left as they are.
  @data_keywords ~w(const enum default examples)

  @doc """
  end_only/1 is the JSON Schema `schema` with every `pattern` and every key of a
  `patternProperties` given `end_only_source/1`, at any depth, and the values of `const`,
  `enum`, `default` and `examples` left as they are.
  """
  @spec end_only(term) :: term
  def end_only(schema) when is_map(schema) do
    Map.new(schema, fn
      {"pattern", source} when is_binary(source) ->
        {"pattern", end_only_source(source)}

      {"patternProperties", properties} when is_map(properties) ->
        {"patternProperties",
         Map.new(properties, fn {source, sub} -> {end_only_source(source), end_only(sub)} end)}

      {keyword, value} when keyword in @data_keywords ->
        {keyword, value}

      {keyword, value} ->
        {keyword, end_only(value)}
    end)
  end

  def end_only(list) when is_list(list), do: Enum.map(list, &end_only/1)
  def end_only(other), do: other

  @doc """
  end_only_source/1 is the pattern `source` with each `$` that is an anchor written `\\z`:
  a `$` outside a character class and not escaped. Escapes and classes are copied as they
  are.
  """
  @spec end_only_source(String.t()) :: String.t()
  def end_only_source(source) when is_binary(source), do: rewrite(source, :out, "")

  defp rewrite(<<>>, _state, acc), do: acc

  defp rewrite(<<?\\, c::utf8, rest::binary>>, state, acc),
    do: rewrite(rest, state, <<acc::binary, ?\\, c::utf8>>)

  defp rewrite(<<?\\>>, _state, acc), do: <<acc::binary, ?\\>>
  defp rewrite(<<?$, rest::binary>>, :out, acc), do: rewrite(rest, :out, <<acc::binary, "\\z">>)

  # A class opens; a `]` first in it, after `[` or `[^`, is a member, not its end.
  defp rewrite(<<?[, ?^, ?], rest::binary>>, :out, acc),
    do: rewrite(rest, :in, <<acc::binary, "[^]">>)

  defp rewrite(<<?[, ?], rest::binary>>, :out, acc), do: rewrite(rest, :in, <<acc::binary, "[]">>)
  defp rewrite(<<?[, rest::binary>>, :out, acc), do: rewrite(rest, :in, <<acc::binary, ?[>>)
  defp rewrite(<<?], rest::binary>>, :in, acc), do: rewrite(rest, :out, <<acc::binary, ?]>>)

  defp rewrite(<<c::utf8, rest::binary>>, state, acc),
    do: rewrite(rest, state, <<acc::binary, c::utf8>>)

  defp rewrite(<<c, rest::binary>>, state, acc), do: rewrite(rest, state, <<acc::binary, c>>)
end
