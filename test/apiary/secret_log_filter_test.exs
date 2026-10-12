defmodule Apiary.SecretLogFilterTest do
  use ExUnit.Case, async: true

  alias Apiary.SecretLogFilter

  # The fixture secret of Forager's contract (keys.json), and one in capitals.
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

  describe "a link's token" do
    # A token as the app makes one: 32 random bytes in base64url.
    setup do
      %{token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
    end

    test "is replaced in every route that carries one, bare or in a URL", %{token: token} do
      for {path, redacted} <- [
            {"/invitations/#{token}", "/invitations/:token"},
            {"/invitations/#{token}/continue", "/invitations/:token/continue"},
            {"/users/log-in/#{token}", "/users/log-in/:token"},
            {"/users/settings/confirm-email/#{token}", "/users/settings/confirm-email/:token"},
            {"/users/password/#{token}", "/users/password/:token"},
            {"/setup/#{token}", "/setup/:code"},
            {"/instance/mail/confirm/#{token}", "/instance/mail/confirm/:token"},
            {"//users//password/#{token}/", "//users//password/:token/"}
          ] do
        %{msg: {:string, text}} = SecretLogFilter.filter(event({:string, "GET " <> path}), nil)
        assert text == "GET " <> redacted

        %{msg: {:string, text}} =
          SecretLogFilter.filter(
            event({:string, ~s(join %{"url" => "https://qory.example.com#{path}?x=1"}.)}),
            nil
          )

        assert text == ~s(join %{"url" => "https://qory.example.com#{redacted}?x=1"}.)
      end
    end

    test "is replaced in a report's terms and in the metadata, a path's segments among them",
         %{token: token} do
      report = %{
        last_message: %{"url" => "http://localhost:4000/users/password/#{token}"},
        args: [~c"/setup/#{token}"]
      }

      %{msg: {:report, scrubbed}} = SecretLogFilter.filter(event({:report, report}), nil)

      assert scrubbed == %{
               last_message: %{"url" => "http://localhost:4000/users/password/:token"},
               args: [~c"/setup/:code"]
             }

      conn = Plug.Test.conn(:get, "/users/password/#{token}")

      %{meta: %{conn: scrubbed}} =
        SecretLogFilter.filter(%{event({:string, "x"}) | meta: %{conn: conn}}, nil)

      assert scrubbed.request_path == "/users/password/:token"
      assert scrubbed.path_info == ["users", "password", ":token"]
    end

    test "leaves every other path as it is" do
      for text <- [
            "GET /users/log-in",
            "GET /users/password/:token",
            "GET /acme/settings/people",
            "lib/apiary_web/live/setup/page.ex:12",
            "GET /setup",
            # Another route's path, that holds one after a segment of its own.
            "GET /acme/users/password/abc",
            "GET https://qory.example.com/docs/setup/abc"
          ] do
        event = event({:string, text})
        assert SecretLogFilter.filter(event, nil) == event
      end
    end

    test "is kept out of the production line of a request that crashed", %{token: token} do
      # As Bandit logs a request that raised: the formatted exception, with the conn in the
      # metadata, which the production formatter writes as request.connection.path.
      conn = Plug.Test.conn(:get, "/users/password/#{token}")
      reason = %RuntimeError{message: "the database is away"}

      event = %{
        level: :error,
        msg: {:string, Exception.format(:error, reason, [])},
        meta: %{
          domain: [:bandit],
          crash_reason: {reason, []},
          plug: {ApiaryWeb.Endpoint, []},
          conn: conn,
          time: System.os_time(:microsecond)
        }
      }

      {formatter, config} = LoggerJSON.Formatters.Basic.new(metadata: [:crash_reason])

      line =
        event |> SecretLogFilter.filter(nil) |> formatter.format(config) |> IO.iodata_to_binary()

      assert line =~ "/users/password/:token"
      refute line =~ token
    end

    test "is kept out of a line Logger writes, but for the set-up link's own", %{token: token} do
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          require Logger
          Logger.warning(fn -> ["GET ", "/setup/", token] end)

          Logger.warning("Set up Qory Apiary at https://qory.example.com/setup/#{token}.",
            setup_link: true
          )
        end)

      assert log =~ "GET /setup/:code"
      assert log =~ "Set up Qory Apiary at https://qory.example.com/setup/#{token}."
      assert length(String.split(log, token)) == 2
    end
  end

  describe "an invitation's token in a query" do
    setup do
      %{token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
    end

    test "is replaced in a join's url, alone and among other parameters, and URL-encoded",
         %{token: token} do
      url = "https://qory.example.com/users/register"

      for {query, redacted} <- [
            {"?invitation=#{token}", "?invitation=:token"},
            {"?invitation=#{token}&lang=en", "?invitation=:token&lang=en"},
            {"?lang=en&invitation=#{token}", "?lang=en&invitation=:token"},
            {"?lang=en&invitation=#{token}#top", "?lang=en&invitation=:token#top"}
          ] do
        %{msg: {:string, text}} =
          SecretLogFilter.filter(event({:string, ~s(join %{"url" => "#{url}#{query}"})}), nil)

        assert text == ~s(join %{"url" => "#{url}#{redacted}"})
      end

      %{msg: {:string, text}} =
        SecretLogFilter.filter(
          event(
            {:string, "GET /users/log-in?return_to=%2Fusers%2Fregister%3Finvitation%3D#{token}"}
          ),
          nil
        )

      assert text == "GET /users/log-in?return_to=%2Fusers%2Fregister%3Finvitation%3D:token"

      conn = Plug.Test.conn(:get, "/users/register?invitation=#{token}")

      %{meta: %{conn: scrubbed}} =
        SecretLogFilter.filter(%{event({:string, "x"}) | meta: %{conn: conn}}, nil)

      assert scrubbed.query_string == "invitation=:token"
    end

    test "is kept out of the production line of a LiveView that crashed", %{token: token} do
      # A crashed LiveView's report: its join payload, the url among it.
      report = %{
        label: {:gen_server, :terminate},
        last_message: %{
          "url" => "https://qory.example.com/users/register?invitation=#{token}&lang=en"
        }
      }

      event = %{
        level: :error,
        msg: {:report, report},
        meta: %{time: System.os_time(:microsecond)}
      }

      {formatter, config} = LoggerJSON.Formatters.Basic.new(metadata: [])

      line =
        event |> SecretLogFilter.filter(nil) |> formatter.format(config) |> IO.iodata_to_binary()

      assert line =~ "invitation=:token&lang=en"
      refute line =~ token
    end

    test "leaves a value that is no token as it is, an invitation's id among them" do
      for text <- [
            "invitation not withdrawn after a failed delivery invitation=#{Ecto.UUID.generate()}",
            "GET /users/register?invitation=#{Ecto.UUID.generate()}",
            "GET /users/register?invitation=short",
            "GET /users/register?reinvitation=#{String.duplicate("A", 43)}"
          ] do
        event = event({:string, text})
        assert SecretLogFilter.filter(event, nil) == event
      end
    end

    test "is masked by the parameters' filter, as Phoenix logs parameters", %{token: token} do
      assert Phoenix.Logger.filter_values(%{"invitation" => token, "lang" => "en"}) ==
               %{"invitation" => "[FILTERED]", "lang" => "en"}
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
