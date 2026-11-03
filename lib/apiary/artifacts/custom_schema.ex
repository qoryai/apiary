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
  # `check_within/2` is `check/1` under a total over several schemas, for a file that
  # lists them (`Apiary.Artifacts.TemplateTypes`). `total/1` starts a total, of reductions
  # and of time from one deadline, and each call takes what is left and returns what is
  # left. Each schema keeps every bound of `check/1` and runs in a separate process,
  # because compiled patterns are outside the heap a budget counts: a shared process
  # would weaken that bound. A run gets the smaller of the single budget and what is
  # left, and its reductions, read in its process at the end, come off the total.
  # `{:error, :total}` is a total that ran out: nothing left before a run, a run cut short
  # only because what was left was smaller than the single budget, or a run that ended
  # past what was left, whether its schema passed or not. `{:error, :budget}` is a run
  # over the single budget with more of the total left.
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
  alias Apiary.Artifacts.SchemaError
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

  @typedoc "What is left of a total: its reductions, and its deadline in monotonic ms."
  @type left :: %{reductions: integer, deadline: integer}

  @typedoc "Why a schema or a document is refused."
  @type refusal ::
          :not_an_object
          | :too_large
          | :limits
          | :unbuildable
          | :budget
          | {:schema, SchemaError.t()}

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

  # total/1 starts a total of `reductions` and of `ms` from now.
  @doc false
  @spec total(reductions: non_neg_integer, ms: non_neg_integer) :: left
  def total(reductions: reductions, ms: ms), do: %{reductions: reductions, deadline: now() + ms}

  # check_within/3 is `check/1` under what is left of a total: `{:ok, left}`, with the
  # schema's reductions taken off, `{:error, :total}`, or `check/1`'s `{:error, refusal}`.
  # `single` is the single budget: the tests' seam, as no schema tried reaches 10,000,000
  # reductions.
  @doc false
  @spec check_within(term, left, Budget.budget()) :: {:ok, left} | {:error, refusal | :total}
  def check_within(schema, left, single \\ @budget)

  def check_within(schema, %{reductions: reductions, deadline: deadline} = left, single)
      when is_map(schema) do
    ms = deadline - now()

    cond do
      not Bounds.within?(schema, @schema_limits) -> {:error, :limits}
      byte_size(CanonicalJSON.encode!(schema)) > @schema_bytes -> {:error, :too_large}
      reductions <= 0 or ms <= 0 -> {:error, :total}
      true -> counted(schema, left, ms, single)
    end
  end

  def check_within(_schema, %{}, _single), do: {:error, :not_an_object}

  # A run past what was left is the total's, whether or not a read of its reductions came
  # in time to cut it: the same schemas get the same result. A run past the deadline is
  # the total's too.
  defp counted(schema, %{reductions: reductions, deadline: deadline} = left, ms, single) do
    most = single[:reductions]
    longest = single[:ms]
    budget = Keyword.merge(single, reductions: min(reductions, most), ms: min(ms, longest))

    result = Budget.run(fn -> {build(copy(schema)), reductions_here()} end, budget)
    late? = now() > deadline

    case result do
      {:ok, {_result, used}} when late? or used > reductions -> {:error, :total}
      {:ok, {:ok, used}} -> {:ok, %{left | reductions: reductions - used}}
      {:ok, {{:error, refusal}, _used}} -> {:error, refusal}
      {:error, :reductions} when reductions < most -> {:error, :total}
      {:error, :time} when ms < longest -> {:error, :total}
      {:error, _reason} -> {:error, :budget}
    end
  end

  defp reductions_here do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end

  defp now, do: System.monotonic_time(:millisecond)

  # validate/2 is `:ok` for `document`, decoded JSON, valid against `schema`, else
  # `{:error, refusal}`: `:limits` (the document is over the bounds),
  # `{:schema, detail}` (the schema refuses it; `detail` is its first failing place,
  # found within the budget, `Apiary.Artifacts.SchemaError`), `:unbuildable` or
  # `:budget`.
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
    case JSV.validate(document, root, cast: false) do
      {:ok, _document} -> :ok
      {:error, %JSV.ValidationError{} = error} -> {:error, {:schema, SchemaError.first(error)}}
    end
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
