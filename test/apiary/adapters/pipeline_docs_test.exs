defmodule Apiary.Adapters.PipelineDocsTest do
  # The adapters belong to `factory`, a feature the documentation does not differ by
  # (`docs: false`): every instance is served the same `/docs`, the module reference
  # included, with it on or off, so no module of theirs is in it, nor the endpoint and the
  # plug of their requests. ExDoc leaves out a module whose docs are hidden
  # (`@moduledoc false`), and every function with it.
  use ExUnit.Case, async: true

  # The functions `use Apiary.Job` defines in a job's module, documented for every job.
  @job_functions [new: 2, for_scope: 1, for_scope: 2, for_scope: 3]

  defp adapters_modules do
    {:ok, modules} = :application.get_key(:apiary, :modules)

    Enum.filter(modules, fn module ->
      name = Atom.to_string(module)
      name == "Elixir.Apiary.Adapters" or String.starts_with?(name, "Elixir.Apiary.Adapters.")
    end)
  end

  test "the docs of every adapters module and of their requests' endpoint are hidden, and of each of their functions" do
    modules = adapters_modules()

    assert Enum.sort(modules) ==
             Enum.sort([
               Apiary.Adapters,
               Apiary.Adapters.ConnectPass,
               Apiary.Adapters.Feed,
               Apiary.Adapters.SeenRequests,
               Apiary.Adapters.SeenRequestsPurge,
               Apiary.Adapters.Wire
             ])

    for module <-
          modules ++ [ApiaryWeb.Contract.AdapterRequest, ApiaryWeb.Contract.AdapterController] do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(module),
             inspect(module)

      for {{kind, name, arity}, _anno, _signature, doc, _meta} <- docs,
          kind in [:function, :macro],
          not (module == Apiary.Adapters.SeenRequestsPurge and {name, arity} in @job_functions) do
        assert doc in [:hidden, :none], inspect({module, name, arity})
      end
    end
  end

  test "the pipeline of their requests is hidden in the router's docs, which list the others" do
    {:docs_v1, _anno, :elixir, _format, _moduledoc, _meta, docs} =
      Code.fetch_docs(ApiaryWeb.Router)

    pipelines = for {{:function, name, 2}, _, _, doc, _} <- docs, do: {name, doc}
    assert {:contract_adapter, :hidden} in pipelines
    assert {:contract, :none} in pipelines
  end
end
