defmodule Apiary.Kinds.BoundsCallersTest do
  # Each caller that checks an untrusted document against a schema walks it first
  # (`Apiary.Kinds.Bounds.within?/2`), with its limits, and never gives JSV a document over
  # them. The calls are traced, so the answer does not depend on time. The trace patterns
  # are global, so the module runs alone.
  use ExUnit.Case, async: false

  import Apiary.DescriptionFixtures

  alias Apiary.Explore.Result
  alias Apiary.Integrations.Description
  alias Apiary.Kinds.{Bounds, ServiceDefinition}

  @traced [{JSV, :validate, :_}, {Bounds, :within?, 2}]

  @description_limits [list: 1024, members: 1024, nodes: 4096, string: 16_384, depth: 64]
  @settings_limits [list: 1024, members: 1024, nodes: 4096, depth: 64]

  setup do
    # A pattern matches only the functions of a loaded module.
    for {module, _function, _arity} = mfa <- @traced do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:global]) > 0
    end

    on_exit(fn -> for mfa <- @traced, do: :erlang.trace_pattern(mfa, false, [:global]) end)
    :ok
  end

  # The traced calls `fun` makes: `{:within?, limits}` and `:jsv`, in order. `fun` runs in
  # another process: a process traced with itself as the tracer sends itself no trace
  # messages.
  defp calls(fun) do
    test = self()

    pid =
      spawn_link(fn ->
        receive do
          :go -> send(test, {:done, self(), fun.()})
        end
      end)

    :erlang.trace(pid, true, [:call])
    send(pid, :go)
    assert_receive {:done, ^pid, _result}
    ref = :erlang.trace_delivered(pid)
    assert_receive {:trace_delivered, ^pid, ^ref}
    collect([])
  end

  defp collect(acc) do
    receive do
      {:trace, _, :call, {Bounds, :within?, [_document, limits]}} ->
        collect([{:within?, limits} | acc])

      {:trace, _, :call, {JSV, :validate, _args}} ->
        collect([:jsv | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a description is walked within its limits, and JSV never reads one over them" do
    valid = encode(tracker_description())
    over = encode(tracker_description(%{"domains" => List.duplicate(1, 5000)}))

    assert calls(fn -> Description.parse(valid) end) == [{:within?, @description_limits}, :jsv]
    assert calls(fn -> Description.parse(over) end) == [{:within?, @description_limits}]
  end

  test "settings are walked within their limits, and JSV never reads them over" do
    {:ok, description} = Description.parse(encode(tracker_description()))
    valid = %{"url" => "https://tracker.example.com"}
    over = %{"url" => List.duplicate(1, 5000)}

    assert calls(fn -> Description.check_settings(description, valid) end) ==
             [{:within?, @settings_limits}, :jsv]

    assert calls(fn -> Description.check_settings(description, over) end) ==
             [{:within?, @settings_limits}]
  end

  test "a service definition is walked within the schema's bounds, and JSV never reads one over them" do
    valid = %{
      "version" => 1,
      "key" => "status-api",
      "title" => "Status API",
      "hosts" => ["status.example.com"],
      "auth" => %{"scheme" => "bearer", "secret" => "key"},
      "declares" => [%{"id" => "key", "title" => "API key"}]
    }

    over = %{valid | "hosts" => List.duplicate("status.example.com", 33)}
    bounds = [list: 32, members: 8]

    assert calls(fn -> ServiceDefinition.validate(valid) end) == [{:within?, bounds}, :jsv]
    assert calls(fn -> ServiceDefinition.validate(over) end) == [{:within?, bounds}]
  end

  test "an explore result is walked within the schema's bounds, and JSV never reads one over them" do
    valid = ~s({"version":1,"verdict":"not_understood","questions":["q"]})
    questions = Enum.join(List.duplicate(~s("q"), 51), ",")
    over = ~s({"version":1,"verdict":"not_understood","questions":[#{questions}]})
    bounds = [list: 50, members: 8]

    assert calls(fn -> Result.parse(valid) end) == [{:within?, bounds}, :jsv]
    assert calls(fn -> Result.parse(over) end) == [{:within?, bounds}]
  end
end
