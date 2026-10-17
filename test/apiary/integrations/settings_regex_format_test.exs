defmodule Apiary.Integrations.SettingsRegexFormatTest do
  # The settings check builds the settings schema with `Apiary.Kinds.RegexFormat`, so each
  # `"format": "regex"` it applies is charged in reductions. The calls are traced in the
  # process the settings are checked in, so the answer does not depend on time. The trace
  # pattern is global, so the module runs alone.
  use ExUnit.Case, async: false

  import Apiary.DescriptionFixtures

  alias Apiary.Integrations.Description
  alias Apiary.Kinds.RegexFormat

  @traced {RegexFormat, :validate_cast, 2}

  setup do
    # A pattern matches only the functions of a loaded module.
    Code.ensure_loaded!(RegexFormat)
    assert :erlang.trace_pattern(@traced, true, [:global]) > 0
    on_exit(fn -> :erlang.trace_pattern(@traced, false, [:global]) end)
    :ok
  end

  # The result of `fun` and the arguments of each traced call it makes, in order. `fun`
  # runs in another process: a process traced with itself as the tracer sends itself no
  # trace messages.
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
    assert_receive {:done, ^pid, result}
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}
    {result, collect([])}
  end

  defp collect(acc) do
    receive do
      {:trace, _, :call, {RegexFormat, :validate_cast, args}} -> collect([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a regex-format setting is checked with RegexFormat, and its verdict is the same" do
    schema = %{
      "type" => "object",
      "properties" => %{"match" => %{"type" => "string", "format" => "regex"}}
    }

    {:ok, description} =
      Description.parse(encode(tracker_description(%{"settings" => schema})))

    assert calls(fn -> Description.check_settings(description, %{"match" => "^[a-z]+$"}) end) ==
             {:ok, [["regex", "^[a-z]+$"]]}

    assert {{:error, {:integration_settings_invalid, %{valid: false}}}, [["regex", "("]]} ==
             calls(fn -> Description.check_settings(description, %{"match" => "("}) end)
  end
end
