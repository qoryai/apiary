defmodule Apiary.WorkItems.DocsTest do
  # The work items belong to `factory`, and no module of theirs is in the module
  # reference, so an instance without factory is served no page of them. ExDoc leaves out
  # a module whose docs are hidden (`@moduledoc false`), and every function with it.
  use ExUnit.Case, async: true

  # The pages of the feature, which answer as a path that does not exist until they are
  # built, the link to an integration, and the session's nonces of its installs, are
  # hidden the same way.
  @pages [
    ApiaryWeb.AdapterLive.Index,
    ApiaryWeb.AdapterLive.Show,
    ApiaryWeb.AdapterLive.AccessKey,
    ApiaryWeb.BacklogLive.Index,
    ApiaryWeb.BacklogLive.Ticket,
    ApiaryWeb.WorkItemLive.Index,
    ApiaryWeb.WorkItemLive.Show,
    ApiaryWeb.WorkItemLive.Comments,
    ApiaryWeb.AdapterRedirectController,
    ApiaryWeb.ConnectSession
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
               Apiary.WorkItems.Answer,
               Apiary.WorkItems.Comment,
               Apiary.WorkItems.Confirmation,
               Apiary.WorkItems.Explore,
               Apiary.WorkItems.ExploreView,
               Apiary.WorkItems.Moves,
               Apiary.WorkItems.Number,
               Apiary.WorkItems.Proposal,
               Apiary.WorkItems.State,
               Apiary.WorkItems.WorkItem,
               Apiary.WorkItems.WorkItemEvent,
               Apiary.WorkItems.WorkList
             ])

    for module <- modules, do: assert_hidden(module)
  end

  test "the docs of the feature's pages are hidden, and of each of their functions" do
    for module <- @pages, do: assert_hidden(module)
  end
end
