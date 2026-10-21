defmodule Apiary.Adapters.DocsTest do
  # An adapter belongs to `factory`, a feature the documentation does not differ by
  # (`docs: false`): every instance is served the same `/docs`, with it on or off, so no
  # type or spec the module reference shows names the adapter kind. ExDoc shows the
  # definition of every type whose docs are not hidden, and the specs of every function
  # whose docs are not hidden, of every module whose docs are not hidden. A private type
  # (`@typep`) is shown by its name alone.
  use ExUnit.Case, async: true

  defp shown_modules do
    {:ok, modules} = :application.get_key(:apiary, :modules)

    for module <- modules,
        {:docs_v1, _anno, :elixir, _format, moduledoc, _meta, docs} <- [Code.fetch_docs(module)],
        moduledoc != :hidden,
        do: {module, docs}
  end

  defp shown?(docs, kind, name, arity) do
    Enum.any?(docs, fn {{k, n, a}, _anno, _signature, doc, _meta} ->
      k == kind and n == name and a == arity and doc != :hidden
    end)
  end

  defp adapter?(quoted), do: Macro.to_string(quoted) =~ ":adapter"

  test "no type or spec the module reference shows names the adapter kind" do
    modules = shown_modules()
    assert Enum.any?(modules, fn {module, _docs} -> module == Apiary.Nodes.Node end)

    for {module, docs} <- modules do
      {:ok, types} = Code.Typespec.fetch_types(module)

      for {:type, {name, _, args} = type} <- types,
          shown?(docs, :type, name, length(args)) do
        refute adapter?(Code.Typespec.type_to_quoted(type)), inspect({module, name})
      end

      {:ok, specs} = Code.Typespec.fetch_specs(module)

      for {{name, arity}, clauses} <- specs,
          shown?(docs, :function, name, arity) or shown?(docs, :macro, name, arity),
          clause <- clauses do
        refute adapter?(Code.Typespec.spec_to_quoted(name, clause)),
               inspect({module, name, arity})
      end
    end
  end

  test "no doc the module reference or the guides show names an adapter's code prefix" do
    prefix = Apiary.AccessKeys.EnrolmentCode.prefix(:adapter)
    pattern = ~r/#{Regex.escape(prefix)}/i

    shown =
      for {:docs_v1, _anno, :elixir, _format, moduledoc, _meta, docs} <-
            Enum.map(all_modules(), &Code.fetch_docs/1),
          moduledoc != :hidden,
          %{} = doc <- [moduledoc | Enum.map(docs, &elem(&1, 3))],
          text <- Map.values(doc),
          do: text

    # The module reference holds the codes' prefixes (`Apiary.AccessKeys.EnrolmentCode`),
    # so the check reads what it should.
    assert Enum.any?(shown, &(&1 =~ Apiary.AccessKeys.EnrolmentCode.prefix(:node)))
    for text <- shown, do: refute(text =~ pattern)

    root = Path.dirname(Mix.Project.project_file())
    extras = Keyword.fetch!(Mix.Project.config()[:docs], :extras)
    assert "guides/contract.md" in extras

    for extra <- extras,
        do: refute(File.read!(Path.join(root, extra)) =~ pattern, extra)
  end

  defp all_modules do
    {:ok, modules} = :application.get_key(:apiary, :modules)
    modules
  end

  test "a node's kind and an enrolment's answer still admit the adapter kind" do
    {:ok, types} = Code.Typespec.fetch_types(Apiary.Nodes.Node)

    assert Enum.any?(types, fn
             {:typep, {:feature_kind, _, []} = type} ->
               adapter?(Code.Typespec.type_to_quoted(type))

             _ ->
               false
           end)

    {:ok, types} = Code.Typespec.fetch_types(Apiary.Contract.Enrolment)

    assert Enum.any?(types, fn
             {:typep, {:node_kind, _, []} = type} ->
               adapter?(Code.Typespec.type_to_quoted(type))

             _ ->
               false
           end)
  end
end
