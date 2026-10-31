defmodule Apiary.Artifacts.CustomSchema do
  # CustomSchema checks the JSON Schema of a custom structured artifact type, and
  # validates a version's document against it, within the bounds Qory Apiary keeps for a
  # schema it does not ship (`Apiary.Integrations.Description.check_settings/2` keeps the
  # same for an integration's settings schema).
  #
  # `check/1`, for a type's form: the schema is a JSON object of at most 65,536 bytes as
  # canonical JSON, with no list of more than 1024 entries, no object of more than 1024
  # members, at most 4096 values in all, no string of more than 16,384 bytes and at most
  # 64 lists and objects nested in one another (`Apiary.Kinds.Bounds.within?/2`). Then JSV
  # builds it, in another process within a budget (`Apiary.Kinds.Budget`): a schema of a
  # few references can make the work grow exponentially with their nesting. Before the
  # build, the patterns it would compile are estimated (`Apiary.Kinds.PatternMemory`),
  # and a schema whose patterns would take more than 16 MiB is refused.
  #
  # `validate/2`, for a push: the document is checked against the bounds below before
  # JSV is given it, and JSV builds the schema and validates the document in the budget's
  # process. A `jsv-cast` or `x-jsv-cast` keyword is dropped everywhere before the build,
  # since JSV loads the module in such a keyword; a `jsv:` reference resolves to a
  # schema no value is valid against (`Apiary.Kinds.SettingsResolver`); no reference is
  # fetched over the network.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  alias Apiary.Kinds.{Bounds, Budget, CanonicalJSON, PatternMemory, RegexFormat}
  alias Apiary.Kinds.{Schema, SettingsResolver}

  @schema_bytes 65_536
  @schema_limits [list: 1024, members: 1024, nodes: 4096, string: 16_384, depth: 64]

  # The bounds of a document: a structured type's file is at most 1 MiB
  # (`Apiary.Artifacts.Type`), and these bound what JSV reads of it.
  @document_limits [list: 10_000, members: 1024, nodes: 65_536, string: 65_536, depth: 32]

  # The budget of a build and a validation: 10,000,000 reductions, 4,194,304 words of heap
  # (32 MiB on a 64-bit machine), and 10 s, a bound only on a check that runs away while
  # it counts few reductions.
  @budget [reductions: 10_000_000, heap_words: 4_194_304, ms: 10_000]
  @pattern_bytes 16_777_216
  @casts ~w(jsv-cast x-jsv-cast)

  @typedoc "Why a schema or a document is refused."
  @type refusal :: :not_an_object | :too_large | :limits | :unbuildable | :budget | :schema

  # check/1 is `:ok` for a JSON Schema a custom type may have, else `{:error, refusal}`:
  # `:not_an_object`, `:too_large` (over 65,536 bytes), `:limits` (over the bounds),
  # `:unbuildable` (JSV cannot build it) or `:budget` (its build passed the budget).
  @doc false
  @spec check(term) :: :ok | {:error, refusal}
  def check(schema) when is_map(schema) do
    cond do
      not Bounds.within?(schema, @schema_limits) -> {:error, :limits}
      byte_size(CanonicalJSON.encode!(schema)) > @schema_bytes -> {:error, :too_large}
      true -> in_budget(fn -> build(copy(schema)) end)
    end
  end

  def check(_schema), do: {:error, :not_an_object}

  # validate/2 is `:ok` for `document`, decoded JSON, valid against `schema`, else
  # `{:error, refusal}`: `:limits` (the document is over the bounds), `:schema` (the
  # schema refuses it), `:unbuildable` or `:budget`.
  @doc false
  @spec validate(term, map) :: :ok | {:error, refusal}
  def validate(document, schema) when is_map(schema) do
    if Bounds.within?(document, @document_limits) do
      document = copy(document)
      schema = copy(schema)

      in_budget(fn ->
        with {:ok, root} <- built(schema), do: valid(document, root)
      end)
    else
      {:error, :limits}
    end
  end

  defp in_budget(fun) do
    case Budget.run(fun, @budget) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :budget}
    end
  end

  # In the budget's process: the patterns estimated, then the schema built.
  defp build(schema) do
    case built(schema) do
      {:ok, _root} -> :ok
      error -> error
    end
  end

  defp built(schema) do
    schema = without_casts(schema)
    used = PatternMemory.schema(schema)

    if used <= @pattern_bytes do
      :ok = RegexFormat.pattern_bytes(used, @pattern_bytes)

      case Schema.build(schema, resolver: SettingsResolver, formats: RegexFormat.formats()) do
        {:ok, root} -> {:ok, root}
        {:error, _reason} -> {:error, :unbuildable}
      end
    else
      {:error, :budget}
    end
  end

  defp valid(document, root) do
    if Schema.valid?(document, root), do: :ok, else: {:error, :schema}
  catch
    :throw, {RegexFormat, :pattern_bytes} -> {:error, :budget}
  end

  defp without_casts(map) when is_map(map),
    do: for({key, value} <- map, key not in @casts, into: %{}, do: {key, without_casts(value)})

  defp without_casts(list) when is_list(list), do: Enum.map(list, &without_casts/1)
  defp without_casts(other), do: other

  # `term` with every binary in it copied, so that none is a part of a larger binary,
  # which the budget would count in full (`Apiary.Kinds.Budget`).
  defp copy(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {copy(key), copy(value)} end)

  defp copy(list) when is_list(list), do: Enum.map(list, &copy/1)
  defp copy(binary) when is_binary(binary), do: :binary.copy(binary)
  defp copy(other), do: other
end
