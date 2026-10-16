defmodule Apiary.SecretLogFilterTest do
  use ExUnit.Case, async: true

  alias Apiary.AccessKeys.EnrolmentCode
  alias Apiary.SecretLogFilter

  # The fixture secret of Forager's contract (keys.json), and one in capitals.
  @secret "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

  # An enrolment code's 26 characters, and the server key's fingerprint the command
  # carries after a code.
  @code_body "7K3M9P2Q4R6S8T0V1W5X3Y9Z2A"
  @fingerprint ".SHA256:ZL8ipvzkSHdqzJf607icofxF23BESvl"

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
    # A code of each kind as Qory Apiary makes it, as the command carries it (the server
    # key's fingerprint after it), as a person may type it, and with its `_` URL-encoded.
    defp codes do
      for {kind, prefix} <- EnrolmentCode.prefixes() do
        code = prefix <> @code_body
        stem = String.trim_trailing(prefix, "_")

        %{
          kind: kind,
          code: code,
          issued: code <> @fingerprint,
          typed: String.upcase(prefix) <> "7k3m-9p2q-4r6s-8t0v-1w5x-3y9z-2a",
          encoded: stem <> "%5F" <> @code_body,
          encoded_lower: String.upcase(stem) <> "%5f" <> @code_body
        }
      end
    end

    test "every kind's prefix is taken, and one of the broader shape that is no kind's" do
      kinds = EnrolmentCode.prefixes()
      assert Enum.sort(Enum.map(codes(), & &1.kind)) == Enum.sort(Map.keys(kinds))

      letter =
        Enum.find_value(?a..?z, &if(("qec" <> <<&1>> <> "_") not in Map.values(kinds), do: &1))

      %{msg: {:string, text}} =
        SecretLogFilter.filter(event({:string, "got qec#{<<letter>>}_#{@code_body}"}), nil)

      assert text == "got [FILTERED]"
    end

    test "is replaced in a message, in any case, as typed and URL-encoded, the fingerprint after it kept" do
      for c <- codes(),
          code <- [c.code, String.downcase(c.code), c.typed, c.encoded, c.encoded_lower] do
        %{msg: {:string, text}} =
          SecretLogFilter.filter(
            event({:string, ["Parameters: ", inspect(%{"code" => code})]}),
            nil
          )

        assert text == ~s(Parameters: %{"code" => "[FILTERED]"}), inspect({c.kind, code})
      end

      for c <- codes() do
        %{msg: {:string, text}} =
          SecretLogFilter.filter(event({~c"run ~s", ["qory access-key enrol #{c.issued}"]}), nil)

        assert text == "run qory access-key enrol [FILTERED]" <> @fingerprint, inspect(c.kind)
      end
    end

    test "is replaced inside a path and a URL, bare and URL-encoded" do
      for c <- codes(), code <- [c.code, c.typed, c.encoded] do
        %{msg: {:string, text}} =
          SecretLogFilter.filter(event({:string, "GET /x/#{code}/y?z=1"}), nil)

        assert text == "GET /x/[FILTERED]/y?z=1", inspect({c.kind, code})

        %{msg: {:string, text}} =
          SecretLogFilter.filter(
            event({:string, ~s(join %{"url" => "https://qory.example.com/x?code=#{code}"})}),
            nil
          )

        assert text == ~s(join %{"url" => "https://qory.example.com/x?code=[FILTERED]"}),
               inspect({c.kind, code})
      end
    end

    test "is replaced in a report's terms and in the metadata" do
      for c <- codes() do
        report = %{last_message: {:value, c.issued}, state: %{"code" => [~c"x #{c.code}"]}}
        %{msg: {:report, scrubbed}} = SecretLogFilter.filter(event({:report, report}), nil)

        assert scrubbed == %{
                 last_message: {:value, "[FILTERED]" <> @fingerprint},
                 state: %{"code" => [~c"x [FILTERED]"]}
               },
               inspect(c.kind)

        meta = %{
          crash_reason: {%FunctionClauseError{module: Acme, args: [c.code]}, []},
          request_path: "/x/" <> c.typed,
          query_string: "code=" <> c.encoded
        }

        %{meta: scrubbed} = SecretLogFilter.filter(%{event({:string, "x"}) | meta: meta}, nil)

        assert scrubbed == %{
                 crash_reason: {%FunctionClauseError{module: Acme, args: ["[FILTERED]"]}, []},
                 request_path: "/x/[FILTERED]",
                 query_string: "code=[FILTERED]"
               },
               inspect(c.kind)

        refute inspect(scrubbed) =~ ~r/qec[a-z]?(_|%5F)/i
      end
    end

    test "is kept out of a GenServer's crash report and a line Logger writes" do
      for c <- codes() do
        log =
          ExUnit.CaptureLog.capture_log([level: :warning], fn ->
            {:ok, pid} = GenServer.start(Apiary.SecretLogFilterTest.Crashing, nil)
            ref = Process.monitor(pid)
            send(pid, {:value, c.code})
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

            require Logger
            Logger.warning("a command: qory access-key enrol #{c.issued}.")
          end)

        assert log =~ "Last message: {:value, \"[FILTERED]\"}", inspect(c.kind)
        assert log =~ "a command: qory access-key enrol [FILTERED].SHA256:", inspect(c.kind)
        refute log =~ ~r/qec[a-z]?(_|%5F)/i
        refute log =~ @code_body
      end
    end

    test "leaves a word that merely starts like a prefix as it is" do
      for text <- ["qecho is no code", "the qec module", "QEC-1 is a part number"] do
        event = event({:string, text})
        assert SecretLogFilter.filter(event, nil) == event
      end
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

  describe "a crash of a LiveView's process, a channel's or the socket's" do
    # What a client sends: no log line of such a process may hold it.
    @marker "plaintext-marker-3f8a"

    # A call in a stacktrace, with its arguments.
    @call {Acme.Page, :handle_event, ["save", %{"password" => @marker}, %{assigns: %{}}],
           [file: ~c"lib/acme.ex", line: 7]}

    # The crash report of a GenServer, as OTP logs it, of a process labelled `label`, sent
    # by another process.
    defp terminate_report(label, reason, last_message) do
      %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:gen_server, :terminate},
             name: self(),
             process_label: label,
             last_message: last_message,
             state: %{assigns: %{password: @marker}},
             log: [{:in, @marker}],
             reason: reason,
             client_info: {self(), {self(), [@call]}}
           }},
        meta: %{pid: :c.pid(0, 1, 0), domain: [:otp]}
      }
    end

    test "has each term the process was sent replaced, and keeps the exception's names" do
      label = {Phoenix.LiveView, Acme.Page, "lv:phx-1"}
      message = %Phoenix.Socket.Message{topic: "lv:phx-1", event: "event", payload: @marker}

      %{msg: {:report, report}} =
        SecretLogFilter.filter(
          terminate_report(label, {{:badmatch, %{"password" => @marker}}, [@call]}, message),
          nil
        )

      stack = [{Acme.Page, :handle_event, 3, [file: ~c"lib/acme.ex", line: 7]}]

      assert report == %{
               label: {:gen_server, :terminate},
               name: self(),
               process_label: label,
               last_message: %{message | payload: "[FILTERED]"},
               state: "[FILTERED]",
               log: [],
               reason: {%MatchError{term: "[FILTERED]"}, stack},
               client_info: {self(), {self(), stack}}
             }
    end

    test "keeps of a socket message the topic the join verified and an event LiveView names" do
      label = {Phoenix.LiveView, Acme.Page, "lv:phx-1"}

      for {message, kept} <- [
            {%Phoenix.Socket.Message{topic: "lv:phx-1", event: "event", ref: "7", join_ref: 4},
             %Phoenix.Socket.Message{
               topic: "lv:phx-1",
               event: "event",
               ref: "[FILTERED]",
               join_ref: "[FILTERED]",
               payload: "[FILTERED]"
             }},
            {%Phoenix.Socket.Message{topic: "lv:" <> @marker, event: @marker, ref: @marker},
             %Phoenix.Socket.Message{
               topic: "[FILTERED]",
               event: "[FILTERED]",
               ref: "[FILTERED]",
               payload: "[FILTERED]"
             }}
          ] do
        %{msg: {:report, report}} =
          SecretLogFilter.filter(terminate_report(label, {:shutdown, :closed}, message), nil)

        assert report.last_message == kept
      end

      # A channel's topic, and a socket's id, which names its session, are a client's.
      for {label, stripped} <- [
            {{Phoenix.Channel, Acme.Channel, "room:" <> @marker},
             {Phoenix.Channel, Acme.Channel, "[FILTERED]"}},
            {{Phoenix.Socket, Phoenix.LiveView.Socket, "users_sessions:" <> @marker},
             {Phoenix.Socket, Phoenix.LiveView.Socket, "[FILTERED]"}}
          ] do
        %{msg: {:report, report}} =
          SecretLogFilter.filter(terminate_report(label, :killed, :timeout), nil)

        assert report.process_label == stripped
      end
    end

    test "has a number replaced, and keeps an arity" do
      label = {Phoenix.LiveView, Acme.Page, "lv:phx-1"}

      %{msg: {:report, report}} =
        SecretLogFilter.filter(
          terminate_report(
            label,
            {{:badmatch, {:ok, 987_654_321_987, 1.5}}, [@call]},
            {:tcp, :socket, 42}
          ),
          nil
        )

      assert {%MatchError{term: {:ok, "[FILTERED]", "[FILTERED]"}},
              [{Acme.Page, :handle_event, 3, _}]} =
               report.reason

      assert report.last_message == {:tcp, :socket, "[FILTERED]"}
    end

    test "keeps a Protocol.UndefinedError's protocol and the type of its value" do
      label = {Phoenix.LiveView, Acme.Page, "lv:phx-1"}

      for {value, type} <- [
            {987_654_321_987, "Integer"},
            {98_765.4321, "Float"},
            {@marker, "BitString"},
            {[@marker], "List"},
            {%{"x" => @marker}, "Map"},
            {{:ok, @marker}, "Tuple"},
            {%URI{host: @marker}, "URI (a struct)"},
            {:an_atom, "Atom"}
          ] do
        error = %Protocol.UndefinedError{protocol: Enumerable, value: value, description: "x"}

        %{msg: {:report, report}} =
          SecretLogFilter.filter(terminate_report(label, {error, [@call]}, :timeout), nil)

        {%Protocol.UndefinedError{} = stripped, _stack} = report.reason
        message = Exception.message(stripped)

        assert message =~ "protocol Enumerable not implemented for #{type}, x"
        refute message =~ @marker
        refute message =~ "987654321987"
        refute message =~ "98765.4321"
      end
    end

    test "writes [FILTERED] for a line a client's terms reach, its level and metadata kept" do
      mfa = {Phoenix.Socket, :handle_in, 4}
      text = ~s(Ignoring unmatched topic "zz:#{@marker}" in Phoenix.LiveView.Socket)
      event = %{level: :warning, msg: {:string, text}, meta: %{pid: self(), mfa: mfa}}

      assert SecretLogFilter.filter(event, nil) == %{event | msg: {:string, "[FILTERED]"}}

      in_process = fn level, mfa, msg ->
        Task.async(fn ->
          Process.put(:"$process_label", {Phoenix.Socket, Phoenix.LiveView.Socket, nil})
          event = %{level: level, msg: msg, meta: %{pid: self(), mfa: mfa}}
          {event, SecretLogFilter.filter(event, nil)}
        end)
        |> Task.await()
      end

      # At error, a line of a LiveView's process, a channel's or the socket's, as text or
      # as a format and its arguments.
      for msg <- [{:string, "got #{@marker}"}, {~c"got ~s", [@marker]}] do
        {event, filtered} = in_process.(:error, {Plug.Crypto, :verify, 4}, msg)
        assert filtered == %{event | msg: {:string, "[FILTERED]"}}
      end

      # A line the app logs, and one below error, keep their text.
      for {level, mfa} <- [
            {:error, {Apiary.Organisations, :invite, 3}},
            {:info, {Plug.Crypto, :verify, 4}}
          ] do
        {event, filtered} = in_process.(level, mfa, {:string, "a line"})
        assert filtered == event
      end
    end

    test "makes an Erlang error the exception it stands for, and keeps an exit's atoms" do
      label = {Phoenix.Socket, Phoenix.LiveView.Socket, nil}
      strip = &SecretLogFilter.filter(terminate_report(label, &1, {:tcp, :socket, @marker}), nil)

      for {reason, stripped} <- [
            {{:function_clause, [@call]},
             %FunctionClauseError{module: Acme.Page, function: :handle_event, arity: 3}},
            {{%FunctionClauseError{module: Acme.Page, function: :f, arity: 1, args: [@marker]},
              [@call]}, %FunctionClauseError{module: Acme.Page, function: :f, arity: 1}},
            {{{:badkey, @marker, %{@marker => 1}}, [@call]},
             %KeyError{key: "[FILTERED]", term: "[FILTERED]"}},
            {{%Ecto.CastError{type: :map, value: @marker, message: "got: #{@marker}"}, [@call]},
             %Ecto.CastError{type: :map, value: "[FILTERED]", message: "[FILTERED]"}},
            {{{:case_clause, {:ok, @marker}}, [@call]},
             %CaseClauseError{term: {:ok, "[FILTERED]"}}}
          ] do
        %{msg: {:report, report}} = strip.(reason)
        assert {^stripped, [{Acme.Page, :handle_event, 3, _location}]} = report.reason
        assert report.last_message == {:tcp, :socket, "[FILTERED]"}
      end

      %{msg: {:report, report}} = strip.({:shutdown, {:closed, @marker}})
      assert report.reason == {:shutdown, {:closed, "[FILTERED]"}}
    end

    test "keeps the frame out of the crash report of the socket's process, a channel's, " <>
           "and a LiveView's before its label" do
      for {key, value} <- [
            {:"$process_label", {Phoenix.Socket, Phoenix.LiveView.Socket, nil}},
            {:"$process_label", {Phoenix.Channel, Acme.Channel, "room:1"}},
            {:"$initial_call", {Phoenix.LiveView.Channel, :init, 1}}
          ] do
        log =
          ExUnit.CaptureLog.capture_log([level: :error], fn ->
            {:ok, pid} = GenServer.start(Apiary.SecretLogFilterTest.Socket, {key, value})
            ref = Process.monitor(pid)
            send(pid, {:tcp, :socket, JSON.encode!(%{"payload" => @marker})})
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
          end)

        assert log =~ "terminating"
        assert log =~ "** (MatchError)"
        assert log =~ "Phoenix.Socket.V2.JSONSerializer"
        assert log =~ ~s(Last message: {:tcp, :socket, "[FILTERED]"})
        refute log =~ @marker
      end
    end

    test "keeps the detail of any other process's crash report" do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          {:ok, pid} = GenServer.start(Apiary.SecretLogFilterTest.Crashing, nil)
          ref = Process.monitor(pid)
          send(pid, {:clause, @marker})
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        end)

      assert log =~ ~s{Apiary.SecretLogFilterTest.Crashing.only_ok("#{@marker}")}
      assert log =~ ~s(Last message: {:clause, "#{@marker}"})
    end

    test "has the crash reason of another event of such a process replaced" do
      crash_reason = {{:badmatch, @marker}, [@call]}

      meta =
        Task.async(fn ->
          Process.put(:"$process_label", {Phoenix.LiveView, Acme.Page, "lv:phx-1"})

          event = %{
            level: :error,
            msg: {:string, "x"},
            meta: %{pid: self(), crash_reason: crash_reason}
          }

          SecretLogFilter.filter(event, nil).meta
        end)
        |> Task.await()

      assert meta.crash_reason ==
               {%MatchError{term: "[FILTERED]"},
                [{Acme.Page, :handle_event, 3, [file: ~c"lib/acme.ex", line: 7]}]}

      # Logged by another process, it is kept.
      event = %{
        level: :error,
        msg: {:string, "x"},
        meta: %{pid: self(), crash_reason: crash_reason}
      }

      assert SecretLogFilter.filter(event, nil) == event
    end

    test "keeps the frame out of OTP's crash report of the process" do
      crashed = [
        initial_call: {Phoenix.LiveView.Channel, :init, [:Argument__1]},
        pid: self(),
        registered_name: [],
        process_label: :undefined,
        error_info: {:error, {:badmatch, %{"password" => @marker}}, [@call]},
        ancestors: [],
        message_queue_len: 1,
        messages: [%Phoenix.Socket.Message{topic: "lv:phx-1", event: "event", payload: @marker}],
        links: [],
        dictionary: [{:"$initial_call", {Phoenix.LiveView.Channel, :init, 1}}, {:held, @marker}],
        trap_exit: false,
        status: :running,
        heap_size: 1,
        stack_size: 1,
        reductions: 1
      ]

      event = %{
        level: :error,
        msg: {:report, %{label: {:proc_lib, :crash}, report: [crashed, []]}},
        meta: %{pid: :c.pid(0, 1, 0), domain: [:otp, :sasl]}
      }

      %{msg: {:report, %{report: data}}} = SecretLogFilter.filter(event, nil)
      refute inspect(data, limit: :infinity, printable_limit: :infinity) =~ @marker

      {:ok, text, meta} =
        Logger.Translator.translate(:debug, :error, :report, {{:proc_lib, :crash}, data})

      text = IO.chardata_to_string(text)
      assert text =~ "** (MatchError)"
      assert text =~ "Acme.Page.handle_event/3"
      refute text =~ @marker
      refute inspect(meta, limit: :infinity, printable_limit: :infinity) =~ @marker
    end

    test "writes [FILTERED] for a crash report that defeats it" do
      crashed = [
        {:process_label, {Phoenix.LiveView, Acme.Page, "lv:phx-1"}},
        {:messages, [@marker]} | :tail
      ]

      event = %{
        level: :error,
        msg: {:report, %{label: {:proc_lib, :crash}, report: [crashed, []]}},
        meta: %{pid: self(), crash_reason: {@marker, []}}
      }

      assert SecretLogFilter.filter(event, nil) == %{
               event
               | msg: {:string, "[FILTERED]"},
                 meta: %{pid: self()}
             }
    end
  end

  defmodule Crashing do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info({:value, value}, _state), do: raise(ArgumentError, "refused #{value}")
    def handle_info({:clause, value}, state), do: {:noreply, only_ok(value) && state}

    def only_ok(:ok), do: :ok
  end

  # A process labelled as Phoenix labels a socket's, or a channel's, or started as a
  # LiveView's is: a frame it cannot read takes it down.
  defmodule Socket do
    use GenServer

    @impl true
    def init({key, value}) do
      Process.put(key, value)
      {:ok, %{held: :none}}
    end

    @impl true
    def handle_info({:tcp, _socket, frame}, state) do
      Phoenix.Socket.V2.JSONSerializer.decode!(frame, opcode: :text)
      {:noreply, state}
    end
  end
end
