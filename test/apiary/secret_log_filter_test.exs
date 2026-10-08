defmodule Apiary.SecretLogFilterTest do
  use ExUnit.Case, async: true

  alias Apiary.SecretLogFilter

  # The runner contract's fixture secret (keys.json), and one in capitals.
  @secret "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

  # An enrolment code as Apiary makes it, as the command carries it (the server key's
  # fingerprint after it), and as a person may type it.
  @code "qec_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A"
  @issued @code <> ".SHA256:ZL8ipvzkSHdqzJf607icofxF23BESvl"
  @typed "QEC_7k3m-9p2q-4r6s-8t0v-1w5x-3y9z-2a"

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

  describe "an enrolment code" do
    test "is replaced in a message, in any case and as typed, the fingerprint after it kept" do
      for {code, after_} <- [{@code, ""}, {String.downcase(@code), ""}, {@typed, ""}] do
        %{msg: {:string, text}} =
          SecretLogFilter.filter(
            event({:string, ["Parameters: ", inspect(%{"code" => code})]}),
            nil
          )

        assert text == ~s(Parameters: %{"code" => "[FILTERED]#{after_}"})
      end

      %{msg: {:string, text}} =
        SecretLogFilter.filter(event({~c"run ~s", ["qory access-key enrol #{@issued}"]}), nil)

      assert text == "run qory access-key enrol [FILTERED].SHA256:ZL8ipvzkSHdqzJf607icofxF23BESvl"
    end

    test "is replaced in a report's terms and in the metadata" do
      report = %{last_message: {:value, @issued}, state: %{"code" => [~c"x #{@code}"]}}
      %{msg: {:report, scrubbed}} = SecretLogFilter.filter(event({:report, report}), nil)

      assert scrubbed == %{
               last_message: {:value, "[FILTERED].SHA256:ZL8ipvzkSHdqzJf607icofxF23BESvl"},
               state: %{"code" => [~c"x [FILTERED]"]}
             }

      meta = %{
        crash_reason: {%FunctionClauseError{module: Acme, args: [@code]}, []},
        request_path: "/x/" <> @typed
      }

      %{meta: scrubbed} = SecretLogFilter.filter(%{event({:string, "x"}) | meta: meta}, nil)

      assert scrubbed == %{
               crash_reason: {%FunctionClauseError{module: Acme, args: ["[FILTERED]"]}, []},
               request_path: "/x/[FILTERED]"
             }

      refute inspect(scrubbed) =~ ~r/qec_/i
    end

    test "is kept out of a GenServer's crash report and a line Logger writes" do
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          {:ok, pid} = GenServer.start(Apiary.SecretLogFilterTest.Crashing, nil)
          ref = Process.monitor(pid)
          send(pid, {:value, @code})
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

          require Logger
          Logger.warning("a command: qory access-key enrol #{@issued}.")
        end)

      assert log =~ "Last message: {:value, \"[FILTERED]\"}"
      assert log =~ "a command: qory access-key enrol [FILTERED].SHA256:"
      refute log =~ ~r/qec_/i
      refute log =~ "7K3M9P2Q4R6S8T0V1W5X3Y9Z2A"
    end
  end

  defmodule Crashing do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info({:value, value}, _state), do: raise(ArgumentError, "refused #{value}")
  end
end
