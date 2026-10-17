defmodule Apiary.Policy.SchemaTest do
  # The refusal of a run configuration is summed up for the log, not normalised: a rendered
  # document is at most 1 MiB, and JSV gives an error for every entry it refuses.
  use ExUnit.Case, async: true

  alias Apiary.Policy.Schema

  # The check takes less than this many milliseconds: the document below is refused in
  # about 20, where JSV and the normalising of its errors took about 0.2 s; the budget
  # leaves room for a slow machine.
  @budget_ms 150

  test "a refused run configuration's errors are summed up, at once" do
    # The schema is built once; the first check pays for it.
    assert Schema.validate(~s({"version":1})) == :ok

    document =
      Jason.encode!(%{
        "version" => 1,
        "security_policy" => %{
          "version" => 1,
          "egress" => %{"mode" => "enforce", "allow" => List.duplicate("A", 30_000)}
        }
      })

    {microseconds, result} = :timer.tc(fn -> Schema.validate(document) end)
    assert div(microseconds, 1000) < @budget_ms, "took #{div(microseconds, 1000)} ms"

    assert {:error, %{valid: false, count: count, errors: errors}} = result
    assert count > 30_000
    assert length(errors) == 8
  end
end
