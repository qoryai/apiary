defmodule Apiary.FeatureSetsScan do
  @moduledoc """
  FeatureSetsScan checks the `:feature_sets` tags of a suite. CI runs every test once,
  with every feature on, and runs again under each other feature set only the tests
  tagged `:feature_sets` (`Apiary.TestSetup`). A test needs the tag when it reads the
  instance's features while it runs, before it sets them: in its body, a `setup` or a
  helper. Untagged, it would run with every feature on alone, and a branch of a feature
  that is off would go untested.

  These calls are reads (`reads/0`):

  - `Apiary.Features.on?/1`, `enabled/0`, `visible?/2` and `hidden_of/1`, and
    `ApiaryWeb.Features.on?/1`;
  - `Apiary.TestSetup.off/0`;
  - `Application.get_env(:apiary, :features)` and `:features_setting`.

  An edition adds the reads of its modules with `reads:`. The scan matches the code, not
  its comments, strings, `@moduledoc` or `@doc`.

  A test sets its features first with `with_features:` (`Apiary.DataCase.setup_features/1`),
  `setup {Apiary.DataCase, :without_registry}`, or a `put_env` of `:features` that
  `on_exit` or an `after` puts back.

  `violations/2` scans `<dir>/**/*_test.exs` and `<dir>/support/**/*.ex` of each
  directory it is given, and returns a violation for:

  - `:untagged`: a test file that reads the features, has no test tagged
    `:feature_sets`, sets no features first, and has a test that runs under more than
    one feature set, one whose `needs:` has none of the features `once:` lists;
  - `:reads_nothing`: a test file with a test tagged `:feature_sets` that reads nothing;
  - `:both_tags`: a test tagged both `with_features:` and `:feature_sets`, which runs
    under the features it lists, whatever the set;
  - `:unknown_helper`: a file of `support/` that reads the features and is not one of
    `helpers:`.

  The tests of a module of `use ExUnit.Case, register: false` do not run, and it skips
  them.

  Its limit: it sees files, not call paths. A file with one tagged test passes, whatever
  its other tests read; a test that reaches a listed helper is not checked. A reviewer
  checks which test of a file carries the tag, and which test reaches a helper.
  """

  @reads ~r/Features\.(on\?|enabled\b|visible\?|hidden_of\b)|TestSetup\.off\b|(get|fetch)_env\(:apiary, :features\b|:features_setting\b/

  @type violation ::
          {:untagged | :reads_nothing | :unknown_helper, Path.t()}
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
  def format({:untagged, path}),
    do:
      "#{path}: tag :feature_sets on the tests that read the features, " <>
        "or set the features first with with_features:"

  def format({:reads_nothing, path}),
    do: "#{path}: remove :feature_sets, as the file reads no feature"

  def format({:both_tags, path, test}),
    do: "#{path}: remove :feature_sets from #{inspect(test)}, which sets with_features:"

  def format({:unknown_helper, path}),
    do: "#{path}: add the helper to helpers:, and tag :feature_sets on the tests that call it"

  defp test_file(path, reads, once) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path) |> without_docs()
    tests = tests(ast, reads)
    around? = ast |> Macro.prewalk(&without_test/1) |> reads?(reads)
    tagged? = Enum.any?(tests, & &1.tags[:feature_sets])

    exposed? =
      (around? and tests == []) or
        Enum.any?(tests, &((around? or &1.reads?) and not once?(&1, once)))

    both =
      for test <- tests,
          test.tags[:feature_sets],
          test.tags[:with_features],
          do: {:both_tags, path, test.name}

    cond do
      tagged? and not around? and not Enum.any?(tests, & &1.reads?) ->
        [{:reads_nothing, path} | both]

      exposed? and not tagged? and not sets_first?(code(ast), tests) ->
        [{:untagged, path} | both]

      true ->
        both
    end
  end

  defp once?(test, once) do
    test.tags[:with_features] != nil or
      Enum.any?(List.wrap(test.tags[:needs]), &(&1 in once))
  end

  defp sets_first?(code, tests) do
    Enum.any?(tests, & &1.tags[:with_features]) or code =~ ":without_registry" or
      (code =~ "put_env(:apiary, :features," and code =~ ~r/\bon_exit\(|^\s*after$/m)
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

  # A file's text without its comments, `@moduledoc`, `@doc` and `@typedoc`, which read
  # nothing.
  defp without_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _, [{doc, _, _}]} when doc in [:moduledoc, :doc, :typedoc] -> nil
      node -> node
    end)
  end

  defp without_test({:test, _, [_ | _]}), do: nil
  defp without_test(node), do: node

  # The tests of a file's modules, each with the tags ExUnit gives it: `@moduletag`, then
  # `@describetag`, then `@tag`, a later key replacing an earlier one. A tag's value is
  # kept where it is a literal, and is `:unknown` elsewhere. `reads?` is whether the
  # test's body reads the features.
  defp tests(ast, reads) do
    {_ast, tests} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [_name, [do: body]]}, acc ->
          if registered?(body),
            do: {nil, acc ++ block(body, {%{}, %{}, reads}, %{}, [])},
            else: {nil, acc}

        node, acc ->
          {node, acc}
      end)

    tests
  end

  # A module of `use ExUnit.Case, register: false` gives its tests to another test, which
  # reads their tags; the suite does not run them.
  defp registered?(body) do
    not Enum.any?(statements(body), fn
      {:use, _, [_case, opts]} when is_list(opts) -> Keyword.get(opts, :register) == false
      _statement -> false
    end)
  end

  defp block(body, scope, pending, acc) do
    {_scope, _pending, acc} =
      Enum.reduce(statements(body), {scope, pending, acc}, fn statement, {scope, pending, acc} ->
        statement(statement, scope, pending, acc)
      end)

    acc
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(statement), do: [statement]

  defp statement({:@, _, [{:moduletag, _, [tags]}]}, {module, describe, reads}, pending, acc),
    do: {{Map.merge(module, tags(tags)), describe, reads}, pending, acc}

  defp statement({:@, _, [{:tag, _, [tags]}]}, scope, pending, acc),
    do: {scope, Map.merge(pending, tags(tags)), acc}

  defp statement({:describe, _, [_name, [do: body]]}, {module, _, reads} = scope, _, acc) do
    describe =
      for {:@, _, [{:describetag, _, [tags]}]} <- statements(body),
          reduce: %{},
          do: (describe -> Map.merge(describe, tags(tags)))

    {scope, %{}, block(body, {module, describe, reads}, %{}, acc)}
  end

  defp statement({:test, _, [name | _]} = test, {module, describe, reads} = scope, pending, acc) do
    tags = module |> Map.merge(describe) |> Map.merge(pending)
    {scope, %{}, acc ++ [%{name: name(name), tags: tags, reads?: reads?(test, reads)}]}
  end

  defp statement({:for, _, [_ | _] = args}, scope, pending, acc) do
    [do: body] = List.last(args)
    {scope, pending, block(body, scope, pending, acc)}
  end

  defp statement(_statement, scope, pending, acc), do: {scope, pending, acc}

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
