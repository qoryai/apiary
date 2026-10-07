defmodule Apiary.SecretLogFilterTest do
  use ExUnit.Case, async: true

  alias Apiary.SecretLogFilter

  # The runner contract's fixture secret (keys.json), and one in capitals.
  @secret "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

  defp event(msg), do: %{level: :debug, msg: msg, meta: %{}}

  test "is installed at boot, once" do
    %{filters: filters} = :logger.get_primary_config()
    assert Keyword.has_key?(filters, :apiary_access_key_secrets)
    assert SecretLogFilter.install() == :ok
  end

  test "replaces a secret in a string message, in any case, and keeps the rest" do
    for secret <- [@secret, String.upcase(@secret), "Qak_x-y_z"] do
      %{msg: {:string, text}} =
        SecretLogFilter.filter(
          event({:string, ["Parameters: ", inspect(%{"label" => secret})]}),
          nil
        )

      assert text == ~s(Parameters: %{"label" => "[FILTERED]"})
    end
  end

  test "replaces a secret in a format and its arguments" do
    %{msg: {:string, text}} = SecretLogFilter.filter(event({~c"got ~s here", [@secret]}), nil)
    assert text == "got [FILTERED] here"
  end

  test "replaces a secret in a string message that is not text, part by part" do
    secret = "qak_" <> String.duplicate("A", 43)
    msg = {:string, ["a ", <<255>>, " ", secret]}

    assert %{msg: {:string, ["a ", <<255>>, " ", "[FILTERED]"]}} =
             SecretLogFilter.filter(event(msg), nil)
  end

  test "leaves an event without a secret as it came" do
    for msg <- [
          {:string, "HANDLE EVENT \"generate_key\""},
          {~c"~p", [:ok]},
          {:report, %{a: "spot-runners", b: [~c"build-01", {:ok, self()}]}}
        ] do
      meta = %{crash_reason: {%RuntimeError{message: "acme"}, []}, file: ~c"lib/x.ex"}
      event = %{event(msg) | meta: meta}
      assert SecretLogFilter.filter(event, nil) == event
    end
  end

  test "replaces a secret anywhere in a report's terms, and keeps their shapes" do
    report = %{
      label: {:gen_server, :terminate},
      last_message: {:value, @secret},
      state: %{"label" => "ci " <> String.upcase(@secret), @secret => [~c"x #{@secret}", 1]},
      reason: {%FunctionClauseError{module: Acme, function: :f, arity: 1, args: [@secret]}, []},
      improper: [:a | "tail #{@secret}"]
    }

    %{msg: {:report, scrubbed}} = SecretLogFilter.filter(event({:report, report}), nil)

    assert scrubbed == %{
             label: {:gen_server, :terminate},
             last_message: {:value, "[FILTERED]"},
             state: %{"label" => "ci [FILTERED]", "[FILTERED]" => [~c"x [FILTERED]", 1]},
             reason:
               {%FunctionClauseError{module: Acme, function: :f, arity: 1, args: ["[FILTERED]"]},
                []},
             improper: [:a | "tail [FILTERED]"]
           }
  end

  test "replaces a secret in the metadata, the crash reason's among it" do
    stacktrace = [{Acme, :handle_event, ["bogus", %{"value" => @secret}], []}]

    meta = %{
      crash_reason: {%FunctionClauseError{module: Acme, args: [@secret]}, stacktrace},
      request_path: "/x/" <> @secret,
      pid: self()
    }

    %{meta: scrubbed} = SecretLogFilter.filter(%{event({:string, "x"}) | meta: meta}, nil)

    assert scrubbed == %{
             crash_reason:
               {%FunctionClauseError{module: Acme, args: ["[FILTERED]"]},
                [{Acme, :handle_event, ["bogus", %{"value" => "[FILTERED]"}], []}]},
             request_path: "/x/[FILTERED]",
             pid: self()
           }

    refute inspect(scrubbed) =~ ~r/qak_/i
  end

  test "keeps a secret out of a GenServer's crash report" do
    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        {:ok, pid} = GenServer.start(Apiary.SecretLogFilterTest.Crashing, nil)
        ref = Process.monitor(pid)
        send(pid, {:value, @secret})
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)

    assert log =~ "terminating"
    assert log =~ "Last message: {:value, \"[FILTERED]\"}"
    refute log =~ ~r/qak_/i
  end

  test "keeps a secret out of a line Logger writes" do
    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        require Logger
        Logger.warning("a value: #{@secret}.")
      end)

    assert log =~ "a value: [FILTERED]."
    refute log =~ ~r/qak_/i
  end

  defmodule Crashing do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info({:value, value}, _state), do: raise(ArgumentError, "refused #{value}")
  end
end
