defmodule Mix.Tasks.Docs.All do
  @shortdoc "Builds the documentation once for each set of features it differs by"

  @moduledoc """
  Builds the documentation an instance serves at `/docs` as one tree per set of features
  the documentation differs by, all into the one image.

  A feature that is off is absent, and that includes the documentation: its guides, its
  modules and the passages about it are not in the pages, the sidebar or the search index
  of an instance without it. ExDoc's sidebar and search list every page, so hiding a file
  at request time is not enough; each tree is built without what it leaves out, and
  `ApiaryWeb.DocsController.dir/0` picks the one the instance's features cover.

      mix docs.all                          # every tree, under the docs `:output`
      mix docs.all --warnings-as-errors     # the check CI and `mix precommit` run

  `mix docs` is an alias of this task in `mix.exs`, so every way the documentation was
  built before builds all the trees now. The arguments go to ExDoc's `mix docs`, once per
  tree.

  ## What needs a feature

  - **An extra or a module**, in the `:features` of the docs configuration in `mix.exs`:
    `security: [extras: [...], modules: [...]]`, a module given by name or by a regex on
    it. The key `all` is every feature: the release notes, which name them all, are only
    in the tree of an instance that has every one, and so is the module reference but for
    the tasks the guides name: the prose of a shared module names features too, and ExDoc
    reads it from the compiled docs, where no marker reaches.
  - **A module that declares its feature** with `use ApiaryWeb.Features`, without anything
    in `mix.exs`.
  - **A passage of a guide**, between marker lines that stand on their own:

        <!-- feature: security -->
        A paragraph about the policy.
        <!-- /feature -->

    `feature: a, b` needs both. Markers do not nest. The marker lines are removed from every
    tree, and the passage from each tree without the feature. The guides are copied with
    the markers resolved to `_build/<env>/docs/<tree>/` and ExDoc reads the copies.

  ## The trees

  A tree is named by its features in the order of `Apiary.Features.all/0`, joined with
  `+`, or `all` for every feature (`ApiaryWeb.DocsController.tree_name/1`), and holds what
  those features need: `observability` (nothing that needs a feature),
  `observability+security`, and `all`, which is the one with the release notes. There is one tree for each different content an instance can be owed,
  so adding markers for a feature that had none adds the trees it needs and nothing else.
  A link from a guide into a page a tree leaves out is a warning, which
  `--warnings-as-errors` makes a failure: a passage that needs a feature and is not marked
  is found by the build.
  """

  use Mix.Task

  @open ~r/^\s*<!--\s*feature:\s*(.*?)\s*-->\s*$/
  @close ~r/^\s*<!--\s*\/feature\s*-->\s*$/

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", [])

    config = Mix.Project.config()
    {owned, docs} = Keyword.pop(docs(config), :features, [])
    output = Keyword.fetch!(docs, :output)
    sources = Path.join(Mix.Project.build_path(), "docs")

    extras = Enum.map(Keyword.get(docs, :extras, []), &extra_path/1)
    passages = Map.new(extras, &{&1, split!(File.read!(&1), &1)})
    extra_needs = extra_needs(owned)
    module_needs = module_needs(owned)

    needs =
      Map.values(extra_needs) ++
        Enum.map(module_needs, &elem(&1, 1)) ++
        for({_, segments} <- passages, {need, _} <- segments, need, do: need) ++
        declared_needs()

    File.rm_rf!(output)
    File.rm_rf!(sources)

    for tree <- trees(needs) do
      name = ApiaryWeb.DocsController.tree_name(tree)
      Mix.shell().info("Documentation for #{name}")

      copies =
        for extra <- extras, covered?(Map.get(extra_needs, extra, []), tree), into: %{} do
          copy = Path.join([sources, name, extra])
          File.mkdir_p!(Path.dirname(copy))
          File.write!(copy, join(passages[extra], tree))
          {extra, copy}
        end

      tree_docs =
        docs
        |> Keyword.put(:output, Path.join(output, name))
        |> Keyword.update(:extras, [], &rename_extras(&1, copies))
        |> Keyword.update(:groups_for_extras, [], &rename_groups(&1, copies))
        |> Keyword.put(:filter_modules, filter_modules(docs, module_needs, tree))
        |> Keyword.update(:api_reference, false, &(&1 and any_module?(module_needs, tree)))
        |> Keyword.put(:skip_code_autolink_to, skip_autolink(docs, module_needs, tree))

      # ExDoc's task with the tree's configuration in place of the project's.
      Mix.Tasks.Docs.run(args, Keyword.put(config, :docs, tree_docs))
    end

    :ok
  end

  defp docs(config) do
    case config[:docs] do
      docs when is_function(docs, 0) -> docs.()
      docs when is_list(docs) -> docs
    end
  end

  defp extra_path({path, _opts}), do: to_string(path)
  defp extra_path(path), do: to_string(path)

  defp rename_extras(extras, copies) do
    for extra <- extras, Map.has_key?(copies, extra_path(extra)) do
      case extra do
        {path, opts} -> {copies[to_string(path)], opts}
        path -> copies[to_string(path)]
      end
    end
  end

  defp rename_groups(groups, copies) do
    for {group, entries} <- groups do
      {group, entries |> Enum.map(&rename_entry(&1, copies)) |> Enum.reject(&is_nil/1)}
    end
  end

  defp rename_entry(path, copies) when is_binary(path), do: copies[path]
  defp rename_entry(other, _copies), do: other

  ## What needs which features

  defp needs_of(:all), do: Apiary.Features.all()
  defp needs_of(feature), do: [check!(feature)]

  defp extra_needs(owned) do
    for {key, owns} <- owned, extra <- Keyword.get(owns, :extras, []), into: %{} do
      {to_string(extra), needs_of(key)}
    end
  end

  defp module_needs(owned) do
    for {key, owns} <- owned, pattern <- Keyword.get(owns, :modules, []) do
      {pattern, needs_of(key)}
    end
  end

  # The modules that say which feature they belong to (`ApiaryWeb.Features`).
  defp declared_needs do
    for module <- app_modules(), feature <- [declared(module)], feature, do: [feature]
  end

  defp app_modules do
    case :application.get_key(Mix.Project.config()[:app], :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  defp declared(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__feature__, 0) and
      module.__feature__()
  end

  defp needs_of_module(module, module_needs) do
    owned =
      for {pattern, needs} <- module_needs, matches?(pattern, module), need <- needs, do: need

    case declared(module) do
      false -> owned
      feature -> [feature | owned]
    end
  end

  defp matches?(%Regex{} = regex, module), do: Regex.match?(regex, inspect(module))
  defp matches?(name, module), do: name == module

  defp filter_modules(docs, module_needs, tree) do
    filter =
      case Keyword.get(docs, :filter_modules) do
        nil -> fn _module, _metadata -> true end
        %Regex{} = regex -> fn module, _ -> Regex.match?(regex, inspect(module)) end
        fun when is_function(fun, 2) -> fun
      end

    fn module, metadata ->
      filter.(module, metadata) and covered?(needs_of_module(module, module_needs), tree)
    end
  end

  # A module the tree leaves out is still named, in backticks, in the docs of modules it
  # keeps. The name stays code and is not linked: a link would lead nowhere, and ExDoc
  # warns of each.
  defp skip_autolink(docs, module_needs, tree) do
    skip =
      case Keyword.get(docs, :skip_code_autolink_to) do
        nil -> fn _term -> false end
        terms when is_list(terms) -> &(&1 in terms)
        fun when is_function(fun, 1) -> fun
      end

    fn term -> skip.(term) or left_out?(term, module_needs, tree) end
  end

  # `mix apiary.rebuild` links to the task's module, as a module name does.
  defp left_out?("mix " <> task, module_needs, tree) do
    case Mix.Task.get(task |> String.split(" ") |> hd()) do
      nil -> false
      module -> not covered?(needs_of_module(module, module_needs), tree)
    end
  end

  defp left_out?(term, module_needs, tree) do
    case Regex.run(~r/^(?:[mtc]:)?([A-Z][\w.]*?)(?:\.[a-z_]\w*[?!]?\/\d+)?$/, term) do
      [_, name] ->
        module = Module.concat([name])

        Code.ensure_loaded?(module) and
          not covered?(needs_of_module(module, module_needs), tree)

      nil ->
        false
    end
  end

  defp covered?(needs, tree), do: Enum.all?(needs, &(&1 in tree))

  # A tree that keeps no module has no module reference page either, rather than an empty one.
  defp any_module?(module_needs, tree),
    do: Enum.any?(app_modules(), &covered?(needs_of_module(&1, module_needs), tree))

  defp check!(feature) do
    if feature in Apiary.Features.all() do
      feature
    else
      Mix.raise(
        "docs: #{inspect(feature)} is not a feature; the features are " <>
          inspect(Apiary.Features.all())
      )
    end
  end

  @doc """
  The trees to build for the given needs, each a list of features in the order of
  `Apiary.Features.all/0`: for every set of features an instance can be launched with,
  the features among `needs` it covers, plus `observability`, which every instance has.
  Sets that come to the same tree are built once.

      iex> Mix.Tasks.Docs.All.trees([[:security]])
      [[:observability], [:observability, :security]]
  """
  @spec trees([[Apiary.Features.feature()]]) :: [[Apiary.Features.feature()]]
  def trees(needs) do
    all = Apiary.Features.all()

    for instance <- subsets(all),
        {:ok, ^instance} <- [Apiary.Features.parse(Enum.map_join(instance, ",", &to_string/1))],
        uniq: true do
      covered = for need <- needs, covered?(need, instance), feature <- need, do: feature
      Enum.filter(all, &(&1 == :observability or &1 in covered))
    end
    |> Enum.sort_by(&length/1)
  end

  defp subsets([]), do: [[]]

  defp subsets([feature | rest]) do
    rest = subsets(rest)
    Enum.map(rest, &[feature | &1]) ++ rest
  end

  ## The markers

  @doc """
  Splits a guide into its passages: `{nil, lines}` for every tree, `{features, lines}` for
  a tree with all of `features`. `file` is for the error, which names the line.
  """
  @spec split!(String.t(), String.t()) :: [{[Apiary.Features.feature()] | nil, [String.t()]}]
  def split!(text, file) do
    {segments, open} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil}, fn {line, number}, {segments, open} ->
        cond do
          match = Regex.run(@open, line) ->
            if open, do: marker!(file, number, "a feature marker inside another")
            {segments, {features!(Enum.at(match, 1), file, number), [], number}}

          Regex.match?(@close, line) ->
            case open do
              nil -> marker!(file, number, "<!-- /feature --> without a marker to close")
              {features, lines, _} -> {[{features, Enum.reverse(lines)} | segments], nil}
            end

          open ->
            {features, lines, from} = open
            {segments, {features, [line | lines], from}}

          true ->
            {[{nil, [line]} | segments], nil}
        end
      end)

    case open do
      nil -> Enum.reverse(segments)
      {_, _, from} -> marker!(file, from, "a feature marker never closed")
    end
  end

  defp features!(list, file, number) do
    features = list |> String.split(",") |> Enum.map(&String.trim/1)
    known = Map.new(Apiary.Features.all(), &{Atom.to_string(&1), &1})

    for feature <- features do
      Map.get(known, feature) ||
        marker!(file, number, "#{inspect(feature)} is not a feature")
    end
  end

  defp marker!(file, line, message), do: Mix.raise("#{file}:#{line}: #{message}")

  @doc "The text of a split guide for a tree with `features`: the marker lines removed."
  @spec join([{[Apiary.Features.feature()] | nil, [String.t()]}], [Apiary.Features.feature()]) ::
          String.t()
  def join(segments, features) do
    segments
    |> Enum.flat_map(fn
      {nil, lines} -> lines
      {needs, lines} -> if covered?(needs, features), do: lines, else: []
    end)
    |> Enum.join("\n")
  end
end
