defmodule Apiary.Dispatches.DocsTest do
  # The queue of a workspace and the role of a node pool's key that claims from it belong
  # to `factory`, a feature the documentation does not differ by (`docs: false`): every
  # instance is served the same `/docs`, the module reference included, with it on or off,
  # so no doc or type the module reference shows names the role or a run's dispatch. ExDoc
  # shows the definition of every type whose docs are not hidden; a private type (`@typep`)
  # is shown by its name alone.
  use ExUnit.Case, async: true

  alias Apiary.Access

  defp shown_docs(module) do
    {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, docs} =
      Code.fetch_docs(module)

    texts = for {_key, _anno, _signature, %{"en" => doc}, _meta} <- docs, do: doc
    [moduledoc | texts]
  end

  test "Apiary.Access's docs name no role of a feature the documentation does not differ by" do
    assert :factory in (Apiary.Features.all() -- Apiary.Features.documented())
    assert :pool_key in Map.keys(Access.roles())

    shown = shown_docs(Access)

    # The role table and the role docs are read, so the check reads what it should.
    assert Enum.any?(shown, &(&1 =~ "| `access_key` |"))
    assert Enum.any?(shown, &(&1 =~ "A role: one of the core's, `:owner`"))
    assert Enum.any?(shown, &(&1 =~ "role/1 is the role the scope acts in"))

    for text <- shown do
      refute text =~ "pool_key"
      refute text =~ "adapter_key"
    end
  end

  test "the type of a run shows none of its fields, a run's dispatch among them" do
    {:docs_v1, _anno, :elixir, _format, _moduledoc, _meta, docs} =
      Code.fetch_docs(Apiary.Runs.Run)

    assert Enum.any?(docs, &match?({{:type, :t, 0}, _, _, %{"en" => _}, _}, &1))

    {:ok, types} = Code.Typespec.fetch_types(Apiary.Runs.Run)

    for {:type, type} <- types do
      refute Macro.to_string(Code.Typespec.type_to_quoted(type)) =~ "dispatch"
    end

    assert :dispatch_run in Map.keys(%Apiary.Runs.Run{})
  end
end
