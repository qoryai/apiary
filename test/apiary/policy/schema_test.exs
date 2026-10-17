defmodule Apiary.Policy.SchemaTest do
  # The refusal of a run configuration is summed up for the log, not normalised: a rendered
  # document is at most 1 MiB, and JSV gives an error for every entry it refuses. Whether
  # the errors are normalised is read from a trace of the calls, so the answer does not
  # depend on time; the trace pattern is global, so the module runs alone.
  use ExUnit.Case, async: false

  alias Apiary.Policy.Schema

  # The check takes less than this many milliseconds: the document below is refused in
  # about 20, where JSV and the normalising of its errors took about 0.2 s; the time leaves
  # room for a slow machine, and the trace tells the two apart.
  @budget_ms 1000

  @normalise {JSV.ErrorFormatter, :normalize_error, :_}

  setup do
    {module, _function, _arity} = @normalise
    Code.ensure_loaded!(module)
    assert :erlang.trace_pattern(@normalise, true, [:global]) > 0
    on_exit(fn -> :erlang.trace_pattern(@normalise, false, [:global]) end)
    :ok
  end

  # `fun`'s value, and how many times it normalised JSV's errors. `fun` runs in another
  # process: a process traced with itself as the tracer sends itself no trace messages.
  defp normalising(fun) do
    test = self()

    pid =
      spawn_link(fn ->
        receive do
          :go -> send(test, {:done, self(), fun.()})
        end
      end)

    # `arity`: each trace message carries the arity, not the errors.
    :erlang.trace(pid, true, [:call, :arity])
    send(pid, :go)
    assert_receive {:done, ^pid, result}, 5000
    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}
    {result, count_calls(0)}
  end

  defp count_calls(n) do
    receive do
      {:trace, _pid, :call, {JSV.ErrorFormatter, :normalize_error, _arity}} ->
        count_calls(n + 1)
    after
      0 -> n
    end
  end

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

    {{microseconds, result}, normalised} =
      normalising(fn -> :timer.tc(fn -> Schema.validate(document) end) end)

    assert normalised == 0
    assert div(microseconds, 1000) < @budget_ms, "took #{div(microseconds, 1000)} ms"

    assert {:error, %{valid: false, count: count, errors: errors}} = result
    assert count > 30_000
    assert length(errors) == 8
  end
end
