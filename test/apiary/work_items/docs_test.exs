defmodule Apiary.WorkItems.DocsTest do
  # The work items belong to `factory`, a feature the documentation does not differ by
  # (`docs: false`): every instance is served the same `/docs`, the module reference
  # included, with it on or off, so no module of theirs is in it. ExDoc leaves out a
  # module whose docs are hidden (`@moduledoc false`), and every function with it.
  use ExUnit.Case, async: true

  defp work_items_modules do
    {:ok, modules} = :application.get_key(:apiary, :modules)
    Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.Apiary.WorkItems."))
  end

  test "the docs of every work items module are hidden, and of each of its functions" do
    modules = work_items_modules()

    assert Enum.sort(modules) ==
             Enum.sort([
               Apiary.WorkItems.Number,
               Apiary.WorkItems.State,
               Apiary.WorkItems.WorkItem,
               Apiary.WorkItems.WorkItemEvent
             ])

    for module <- modules do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(module),
             inspect(module)

      for {{kind, name, arity}, _anno, _signature, doc, _meta} <- docs,
          kind in [:function, :macro] do
        assert doc in [:hidden, :none], inspect({module, name, arity})
      end
    end
  end
end
