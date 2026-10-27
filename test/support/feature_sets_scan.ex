defmodule Apiary.FeatureSetsScan do
  @moduledoc """
  FeatureSetsScan checks the `:feature_sets` tags of a suite. CI runs every test once,
  with every feature on, and runs again under each other feature set only the tests
  tagged `:feature_sets` (`Apiary.TestSetup`). A test needs the tag when it reads the
  instance's features while it runs, in its body, a `setup` or a helper, has no
  `with_features:`, and has no feature of `once:` in its `needs:`. Untagged, it would run
  with every feature on alone, and a branch of a feature that is off would go untested.

  These calls are reads (`reads/0`):

  - `Apiary.Features.on?/1`, `enabled/0`, `visible?/2` and `hidden_of/1`, and
    `ApiaryWeb.Features.on?/1`;
  - `Apiary.TestSetup.off/0`;
  - `Application.get_env(:apiary, :features)`, `fetch_env/2` and `fetch_env!/2` of it,
    and `:features_setting`.

  An edition adds the reads of its modules with `reads:`. The scan matches the code, not
  its comments, strings, `@moduledoc` or `@doc`.

  A test sets its features first with `with_features:` (`Apiary.DataCase.setup_features/1`)
  alone: it then runs under the features it lists, whatever the set. The scan does not
  count a `put_env` of `:features` or `setup {Apiary.DataCase, :without_registry}` as
  setting them, because `without_registry` keeps the set's other features, so a test
  that reads them after either takes the tag.

  `violations/2` scans `<dir>/**/*_test.exs` and `<dir>/support/**/*.ex` of each
  directory it is given, and returns a violation for:

  - `:untagged`: a test that reads the features, is not tagged `:feature_sets`, and runs
    under more than one feature set: it has no `with_features:` on the test, its describe
    or its module, and its `needs:` has none of the features `once:` lists. A test
    reads them in its body, in a `setup` of its module or describe, or in a function of
    its file that either calls;
  - `:reads_nothing`: a test file with a test tagged `:feature_sets`, none of whose tests
    reads the features;
  - `:both_tags`: a test tagged both `with_features:` and `:feature_sets`, which runs
    under the features it lists, whatever the set;
  - `:unknown_helper`: a file of `support/` that reads the features and is not one of
    `helpers:`.

  The tests of a module of `use ExUnit.Case, register: false` do not run, and it skips
  them. A file whose test modules define no test, as a module of a template's tests,
  is `:untagged` as a whole when it reads the features.

  Its limits: it follows the calls within a file, not into another module, so a test that
  reaches a listed helper of `support/` or a module of `lib/` is not checked, nor a
  `setup {Module, :name}`. Functions of one name in two modules of a file count as one. A
  `setup` that reads counts for every test of its module or describe. A reviewer checks
  a test that reaches another module.
  """

  @reads ~r/Features\.(on\?|enabled\b|visible\?|hidden_of\b)|TestSetup\.off\b|(get|fetch)_env!?\(:apiary, :features\b|:features_setting\b/

  @type violation ::
          {:reads_nothing | :unknown_helper, Path.t()}
          | {:untagged, Path.t(), String.t() | nil}
          | {:both_tags, Path.t(), String.t()}

  @doc "reads/0 is the pattern of the core's reads of the features."
  @spec reads() :: Regex.t()
  def reads, do: @reads

  @doc """
  violations/2 is the violations of the test files and helpers under each of `dirs`, a
  suite's `test` directory, sorted. Options:

  - `reads:`, more patterns of a read, for an edition's modules;
  - `helpers:`, the paths under `support/` of the helpers known to read the features;
  - `once:`, the features whose `needs:` runs a test under one feature set alone,
    by default the opt-in features (`Apiary.Features.opt_in/0`), which CI's other sets
    leave off.
  """
  @spec violations([Path.t()], keyword) :: [violation]
  def violations(dirs, opts \\ []) do
    reads = [@reads | Keyword.get(opts, :reads, [])]
    helpers = Keyword.get(opts, :helpers, [])
    once = Keyword.get_lazy(opts, :once, &Apiary.Features.opt_in/0)

    tests =
      for dir <- dirs,
          path <- Path.wildcard(Path.join(dir, "**/*_test.exs")),
          violation <- test_file(path, reads, once),
          do: violation

    support =
      for dir <- dirs,
          path <- Path.wildcard(Path.join(dir, "support/**/*.ex")),
          Path.expand(path) != __ENV__.file,
          Path.relative_to(path, Path.join(dir, "support")) not in helpers,
          path
          |> File.read!()
          |> Code.string_to_quoted!(file: path)
          |> without_docs()
          |> reads?(reads),
          do: {:unknown_helper, path}

    Enum.sort(tests ++ support)
  end

  @doc "format/1 is a violation as a line that says what to change."
  @spec format(violation) :: String.t()
  def format({:untagged, path, nil}),
    do:
      "#{path}: the file reads the features and defines no test; tag :feature_sets " <>
        "on the tests it makes, or set the features first"

  def format({:untagged, path, test}),
    do:
      "#{path}: tag :feature_sets on #{inspect(test)}, which reads the features, " <>
        "or set them first with with_features:"

  def format({:reads_nothing, path}),
    do: "#{path}: remove :feature_sets, as the file reads no feature"

  def format({:both_tags, path, test}),
    do: "#{path}: remove :feature_sets from #{inspect(test)}, which sets with_features:"

  def format({:unknown_helper, path}),
    do: "#{path}: add the helper to helpers:, and tag :feature_sets on the tests that call it"

  defp test_file(path, reads, once) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path) |> without_docs()
    {tests, registered} = tests(ast, %{reads: reads, local: local_reads(ast, reads)})

    both =
      for test <- tests,
          test.tags[:feature_sets],
          test.tags[:with_features],
          do: {:both_tags, path, test.name}

    untagged =
      for test <- tests,
          test.reads?,
          !test.tags[:feature_sets],
          not once?(test, once),
          do: {:untagged, path, test.name}

    cond do
      tests == [] and registered > 0 and reads?(ast, reads) ->
        [{:untagged, path, nil}]

      Enum.any?(tests, & &1.tags[:feature_sets]) and not Enum.any?(tests, & &1.reads?) ->
        [{:reads_nothing, path} | both]

      true ->
        untagged ++ both
    end
  end

  defp once?(test, once) do
    test.tags[:with_features] != nil or
      Enum.any?(List.wrap(test.tags[:needs]), &(&1 in once))
  end

  defp reads?(ast, reads) do
    code = code(ast)
    Enum.any?(reads, &Regex.match?(&1, code))
  end

  # The text of the code without its strings, which read nothing.
  defp code(ast) do
    ast
    |> Macro.prewalk(fn
      string when is_binary(string) -> ""
      node -> node
    end)
    |> Macro.to_string()
  end

  # A file's code without its comments, `@moduledoc`, `@doc` and `@typedoc`, which read
  # nothing.
  defp without_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :typedoc] -> nil
      node -> node
    end)
  end

  # The names of the functions the file defines that read the features, directly or
  # through another of them. Clauses of every arity count as one name.
  defp local_reads(ast, reads) do
    {_ast, bodies} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, Map.update(acc, name_of(head), [body], &[body | &1])}

        node, acc ->
          {node, acc}
      end)

    direct = for {name, list} <- bodies, reads?(list, reads), into: MapSet.new(), do: name
    close(direct, bodies)
  end

  defp close(names, bodies) do
    more = for {name, list} <- bodies, calls?(list, names), into: names, do: name
    if MapSet.equal?(more, names), do: names, else: close(more, bodies)
  end

  defp name_of({:when, _, [head | _]}), do: name_of(head)
  defp name_of({name, _, _}), do: name

  # Whether `ast` calls one of `names`, or captures it (`&name/1`).
  defp calls?(ast, names) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {name, _, _} = node, found? when is_atom(name) -> {node, found? or name in names}
        node, found? -> {node, found?}
      end)

    found?
  end

  # Whether a `setup` names one of `names`: `setup :name` or `setup [:a, :b]`.
  defp names?({:setup, _, args}, names) do
    {_ast, found?} =
      Macro.prewalk(args, false, fn
        atom, found? when is_atom(atom) -> {atom, found? or atom in names}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp names?(_statement, _names), do: false

  # The tests of a file's modules, each with the tags ExUnit gives it: `@moduletag`, then
  # `@describetag`, then `@tag`, a later key replacing an earlier one. A tag's value is
  # kept where it is a literal, and is `:unknown` elsewhere. `reads?` is whether the test,
  # a `setup` of its module or describe, or a function of the file either calls reads the
  # features. With them, the count of the file's modules whose tests run.
  defp tests(ast, ctx) do
    {_ast, found} =
      Macro.prewalk(ast, {[], 0}, fn
        {:defmodule, _, [_name, [do: body]]}, {tests, registered} = acc ->
          if registered?(body) do
            scope = scope(body, %{tags: %{}, reads?: false}, ctx)
            {nil, {tests ++ block(body, scope, %{}, [], ctx), registered + 1}}
          else
            {nil, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  # A module or describe's scope: its tags, and whether a statement of it that is no
  # test, describe or function reads the features, as a `setup` does for each of its
  # tests.
  defp scope(body, outer, ctx) do
    statements =
      Enum.reject(statements(body), fn
        {kind, _, _} -> kind in [:test, :describe, :for, :def, :defp, :defmacro, :defmacrop]
        _statement -> false
      end)

    tags =
      for {:@, _, [{tag, _, [value]}]} <- statements,
          tag in [:moduletag, :describetag],
          reduce: outer.tags,
          do: (tags -> Map.merge(tags, tags(value)))

    %{
      tags: tags,
      reads?:
        outer.reads? or
          Enum.any?(statements, fn statement ->
            reads?(statement, ctx.reads) or calls?(statement, ctx.local) or
              names?(statement, ctx.local)
          end)
    }
  end

  # A module of `use ExUnit.Case, register: false` gives its tests to another test, which
  # reads their tags; the suite does not run them.
  defp registered?(body) do
    not Enum.any?(statements(body), fn
      {:use, _, [_case, opts]} when is_list(opts) -> Keyword.get(opts, :register) == false
      _statement -> false
    end)
  end

  defp block(body, scope, pending, acc, ctx) do
    {_pending, acc} =
      Enum.reduce(statements(body), {pending, acc}, fn statement, {pending, acc} ->
        statement(statement, scope, pending, acc, ctx)
      end)

    acc
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  defp statement({:@, _, [{:tag, _, [tags]}]}, _scope, pending, acc, _ctx),
    do: {Map.merge(pending, tags(tags)), acc}

  defp statement({:describe, _, [_name, [do: body]]}, scope, _pending, acc, ctx),
    do: {%{}, block(body, scope(body, scope, ctx), %{}, acc, ctx)}

  defp statement({:test, _, [name | _]} = test, scope, pending, acc, ctx) do
    tags = Map.merge(scope.tags, pending)

    test = %{
      name: name(name),
      tags: tags,
      reads?: scope.reads? or reads?(test, ctx.reads) or calls?(test, ctx.local)
    }

    {%{}, acc ++ [test]}
  end

  defp statement({:for, _, [_ | _] = args}, scope, pending, acc, ctx) do
    [do: body] = List.last(args)
    {pending, block(body, scope, pending, acc, ctx)}
  end

  defp statement(_statement, _scope, pending, acc, _ctx), do: {pending, acc}

  defp tags(tag) when is_atom(tag), do: %{tag => true}

  defp tags(tags) when is_list(tags),
    do: Map.new(tags, fn {key, value} -> {key, literal(value)} end)

  defp tags(_tags), do: %{}

  defp literal(value) do
    if Macro.quoted_literal?(value), do: value, else: :unknown
  end

  defp name(name) when is_binary(name), do: name
  defp name(name), do: Macro.to_string(name)
end
