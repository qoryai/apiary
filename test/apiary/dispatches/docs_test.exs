defmodule Apiary.Dispatches.DocsTest do
  # The queue of a workspace belongs to `factory`. No type the module reference shows
  # mentions a run's dispatch, so no type served to an instance without factory mentions a
  # run's dispatch.
  # ExDoc shows the definition of every type whose docs are not hidden; a private type
  # (`@typep`) is shown by its name alone.
  use ExUnit.Case, async: true

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
