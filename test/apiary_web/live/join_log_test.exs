defmodule ApiaryWeb.JoinLogTest do
  @moduledoc """
  A join frame a LiveView's process fails on, sent through the socket's code as a browser
  sends it (`Phoenix.LiveView.Socket`'s connect, init and handle_in, in a process standing
  in for the web server's handler): no log line, of the socket's process or of the
  LiveView's, holds what the frame carried, the endpoint's secret key base, the LiveView
  signing salt or a person's session token; the join that failed is still logged, at error,
  with the call it failed in (`Apiary.SecretLogFilter`).
  """
  # Not async: the log handler reads every event logged while a frame is handled.
  use ApiaryWeb.ConnCase, async: false

  @moduletag :capture_log

  import Apiary.AccountsFixtures

  # What a client sends: no log line may hold it.
  @marker "plaintext-marker-6j1n"

  # Hands the test every event logged, after the primary filters.
  defmodule Sink do
    @moduledoc false
    def log(event, %{config: %{test: test}}) do
      send(test, {:join_log_event, event})
      :ok
    end
  end

  # The socket's process: what the web server's handler runs for a frame.
  defmodule Transport do
    @moduledoc false
    use GenServer

    @impl true
    def init(session) do
      config = %{
        endpoint: ApiaryWeb.Endpoint,
        transport: :websocket,
        options: [serializer: [{Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}]],
        params: %{"vsn" => "2.0.0"},
        connect_info: %{
          session: session,
          peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil},
          user_agent: "test",
          x_headers: []
        }
      }

      {:ok, state} = Phoenix.LiveView.Socket.connect(config)
      Phoenix.LiveView.Socket.init(state)
    end

    @impl true
    def handle_call({:frame, frame}, _from, state) do
      case Phoenix.LiveView.Socket.handle_in({frame, opcode: :text}, state) do
        {:reply, status, _reply, state} -> {:reply, status, state}
        {:ok, state} -> {:reply, :ok, state}
        {:push, _push, state} -> {:reply, :ok, state}
      end
    end

    @impl true
    def handle_info(message, state) do
      case Phoenix.LiveView.Socket.handle_info(message, state) do
        {:stop, reason, state} -> {:stop, reason, state}
        {_continue, state} -> {:noreply, state}
        {:push, _push, state} -> {:noreply, state}
      end
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    id = :"join_log_sink_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, Sink, %{level: :all, config: %{test: self()}})
    on_exit(fn -> :logger.remove_handler(id) end)
    :ok
  end

  # The frame `[join_ref, ref, topic, "phx_join", payload]`, handled by a socket opened
  # with `session`: the reply's status and every event logged meanwhile.
  defp join(session, topic, payload) do
    {:ok, pid} = GenServer.start_link(Transport, session)
    flush()

    status =
      GenServer.call(pid, {:frame, JSON.encode!(["1", "1", topic, "phx_join", payload])})

    {status, events()}
  end

  defp flush do
    receive do
      {:join_log_event, _event} -> flush()
    after
      0 -> :ok
    end
  end

  # The LiveView's process logs as it ends, before the socket's process hears of it.
  defp events do
    receive do
      {:join_log_event, event} -> [event | events()]
    after
      100 -> []
    end
  end

  defp text(%{msg: msg, meta: meta}) do
    message =
      case msg do
        {:string, chardata} -> IO.chardata_to_string(chardata)
        other -> inspect(other, limit: :infinity, printable_limit: :infinity)
      end

    message <> inspect(meta, limit: :infinity, printable_limit: :infinity)
  end

  # What no log line may hold: the frame's marker, the endpoint's secret key base and the
  # LiveView signing salt.
  defp needles(extra) do
    [
      @marker,
      ApiaryWeb.Endpoint.config(:secret_key_base),
      ApiaryWeb.Endpoint.config(:live_view)[:signing_salt] | extra
    ]
  end

  defp assert_clean({status, events}, extra \\ []) do
    assert status == :error

    for needle <- needles(extra), event <- events do
      refute text(event) =~ needle, "a log line holds #{inspect(String.slice(needle, 0, 12))}"
    end

    events
  end

  # The join that failed is logged at error by the socket's process, its call named.
  defp assert_join_logged(events) do
    assert Enum.any?(
             events,
             &match?(
               %{
                 level: :error,
                 msg: {:string, "[FILTERED]"},
                 meta: %{mfa: {Phoenix.Channel.Server, :join, 4}}
               },
               &1
             )
           )
  end

  # A page's tokens as its dead render writes them, and the cookie's session.
  defp page(conn, path) do
    conn = get(conn, path)
    html = html_response(conn, 200)

    [_, id] =
      Regex.run(~r/id="(phx-[^"]+)"[^>]*data-phx-main/, html) ||
        Regex.run(~r/data-phx-main[^>]*id="(phx-[^"]+)"/, html)

    [_, session] = Regex.run(~r/data-phx-session="([^"]+)"/, html)
    [_, static] = Regex.run(~r/data-phx-static="([^"]+)"/, html)

    %{
      topic: "lv:" <> id,
      payload: %{
        "url" => "http://www.example.com" <> path,
        "params" => %{"_mounts" => 0},
        "session" => session,
        "static" => static
      },
      session: conn.private[:plug_session] || %{}
    }
  end

  describe "a join without a session the LiveView can read" do
    test "logs neither the secret key base nor the signing salt" do
      %{} |> join("lv:phx-test", %{"session" => 1}) |> assert_clean() |> assert_join_logged()
    end

    test "logs no term of the session it sent" do
      for session <- [%{"password" => @marker}, [@marker], 987_654_321_987] do
        %{}
        |> join("lv:phx-test", %{"session" => session})
        |> assert_clean(["987654321987"])
        |> assert_join_logged()
      end
    end

    test "logs no term of a payload that is not a map" do
      %{} |> join("lv:phx-test", [@marker]) |> assert_clean() |> assert_join_logged()
    end

    test "logs no topic a client chose" do
      # A mount without a session, and a topic no route takes.
      for topic <- ["lv:" <> @marker, "zz:" <> @marker] do
        {status, events} = join(%{}, topic, %{"url" => @marker})
        assert_clean({status, events})
        assert Enum.any?(events, &match?(%{msg: {:string, "[FILTERED]"}}, &1))
      end
    end
  end

  describe "a signed-in person's join" do
    test "logs no byte of the session's token", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      %{session: session, topic: topic} = page(conn, "/users/settings")
      token = session["user_token"]
      assert is_binary(token)

      session
      |> join(topic, ["x"])
      |> assert_clean([
        inspect(token, limit: :infinity),
        Base.url_encode64(token),
        Base.url_encode64(token, padding: false)
      ])
      |> assert_join_logged()
    end
  end

  describe "a join with the page's session" do
    test "logs no term of a static, a url, a redirect or params of the wrong kind",
         %{conn: conn} do
      %{session: session, topic: topic, payload: payload} = page(conn, "/users/log-in")

      for change <- [
            %{"static" => 1},
            %{"static" => %{"x" => @marker}},
            %{"url" => %{"x" => @marker}},
            %{"url" => [@marker]},
            %{"redirect" => %{"x" => @marker}},
            %{"params" => @marker}
          ] do
        {status, events} = join(session, topic, Map.merge(payload, change))
        assert_clean({status, events})
        assert_join_logged(events)
      end
    end
  end
end
