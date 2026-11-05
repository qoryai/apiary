defmodule Apiary.Kinds.BoundsCallersTest do
  # Each caller that checks an untrusted document against a schema walks it first
  # (`Apiary.Kinds.Bounds.within?/2`), with its limits, and never gives JSV a document over
  # them. The calls are traced, so the answer does not depend on time. The trace patterns
  # are global, so the module runs alone.
  use ExUnit.Case, async: false

  import Apiary.DescriptionFixtures

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

    # `set_on_spawn` traces the processes it starts too, such as the one the settings are
    # checked in (`Apiary.Kinds.Budget`).
    :erlang.trace(pid, true, [:call, :set_on_spawn])
    send(pid, :go)
    assert_receive {:done, ^pid, _result}
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}
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

  @tag :tmp_dir
  test "a questions artifact is walked within its bounds, and JSV never reads one over them",
       %{tmp_dir: dir} do
    type = Enum.find(Apiary.Artifacts.Type.standard(), &(&1.name == "questions"))

    question = %{
      "id" => "q1",
      "question" => "Which region?",
      "options" => [%{"title" => "Europe", "explanation" => "Serve from Europe."}],
      "state" => "open",
      "asked" => %{"run" => 1, "at" => "2026-11-04T10:00:00Z"}
    }

    write = fn name, document ->
      path = Path.join(dir, name)
      File.write!(path, Jason.encode!(document))
      path
    end

    valid = write.("valid.json", %{"questions" => [question]})
    # A document of more values than the walk takes: 65,537 ids in `follows`.
    over =
      write.("over.json", %{
        "questions" => [Map.put(question, "follows", List.duplicate("q1", 65_537))]
      })

    # The format's lists are unbounded: the walk bounds them by the values in all, and an
    # object by a question's 9 members (`Apiary.Artifacts.Format`).
    bounds = [list: 65_536, members: 9, nodes: 65_536, string: 131_072, depth: 16]

    assert {:ok, "application/json"} =
             Apiary.Artifacts.Format.check(type, "questions.json", valid)

    assert calls(fn -> Apiary.Artifacts.Format.check(type, "questions.json", valid) end) == [
             {:within?, bounds},
             :jsv
           ]

    assert calls(fn -> Apiary.Artifacts.Format.check(type, "questions.json", over) end) == [
             {:within?, bounds}
           ]
  end
end
