defmodule Apiary.WorkItems.DocsTest do
  # The work items belong to `factory`, a feature the documentation does not differ by
  # (`docs: false`): every instance is served the same `/docs`, the module reference
  # included, with it on or off, so no module of theirs is in it. ExDoc leaves out a
  # module whose docs are hidden (`@moduledoc false`), and every function with it.
  use ExUnit.Case, async: true

  # The pages of the feature, which answer as a path that does not exist until they are
  # built, and the link to an integration, are hidden the same way.
  @pages [
    ApiaryWeb.AdapterLive.Index,
    ApiaryWeb.AdapterLive.Show,
    ApiaryWeb.AdapterLive.AccessKey,
    ApiaryWeb.BacklogLive.Index,
    ApiaryWeb.WorkItemLive.Index,
    ApiaryWeb.WorkItemLive.Show,
    ApiaryWeb.AdapterRedirectController
  ]

  defp work_items_modules do
    {:ok, modules} = :application.get_key(:apiary, :modules)

    Enum.filter(
      modules,
      &(&1 == Apiary.WorkItems or
          String.starts_with?(Atom.to_string(&1), "Elixir.Apiary.WorkItems."))
    )
  end

  defp assert_hidden(module) do
    assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} = Code.fetch_docs(module),
           inspect(module)

    for {{kind, name, arity}, _anno, _signature, doc, _meta} <- docs,
        kind in [:function, :macro] do
      assert doc in [:hidden, :none], inspect({module, name, arity})
    end
  end

  test "the docs of every work items module are hidden, and of each of its functions" do
    modules = work_items_modules()

    assert Enum.sort(modules) ==
             Enum.sort([
               Apiary.WorkItems,
               Apiary.WorkItems.Number,
               Apiary.WorkItems.State,
               Apiary.WorkItems.WorkItem,
               Apiary.WorkItems.WorkItemEvent
             ])

    for module <- modules, do: assert_hidden(module)
  end

  test "the docs of the feature's pages are hidden, and of each of their functions" do
    for module <- @pages, do: assert_hidden(module)
  end
end
