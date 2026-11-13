defmodule ApiaryWeb.EndpointStopTest do
  # On a stop, the endpoint's listeners finish open requests for up to 20 s in total, and
  # Oban then finishes running jobs for up to 15 s: 35 s, under a stop grace period of
  # 40 s, the least an install sets (guides/upgrading.md).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ApiaryWeb.Endpoint
  alias ApiaryWeb.EndpointStopTest.Served

  # The listeners Bandit's adapter makes of a configuration: their child specs, built
  # without starting anything.
  defp listeners(config) do
    for %{id: {Endpoint, scheme}, start: {Bandit, :start_link, [opts]}} <-
          Bandit.PhoenixAdapter.child_specs(Endpoint, [otp_app: :apiary] ++ config),
        do: {scheme, opts}
  end

  defp shutdown_timeout(opts), do: opts[:thousand_island_options][:shutdown_timeout]

  defp env, do: Application.get_env(:apiary, Endpoint)

  test "the http listener waits 20 s for open requests on a stop, the endpoint's limit" do
    assert shutdown_timeout(Endpoint.config(:http)) == 20_000
    assert Endpoint.stop_timeout() == 20_000

    assert [http: opts] = listeners(env())
    assert shutdown_timeout(opts) == 20_000
  end

  test "an https listener waits the same, beside the options its `https:` sets" do
    https = [port: 4443, thousand_island_options: [num_acceptors: 10]]
    config = Endpoint.bound_https(env() ++ [https: https])

    assert [http: http, https: opts] = listeners(config)
    assert shutdown_timeout(http) == 20_000
    assert opts[:thousand_island_options] == [shutdown_timeout: 20_000, num_acceptors: 10]

    # A wait the `https:` sets is kept.
    https = [port: 4443, thousand_island_options: [shutdown_timeout: 5_000]]
    assert shutdown_timeout(Endpoint.bound_https(env() ++ [https: https])[:https]) == 5_000
  end

  test "Oban waits 15 s for running jobs on a stop" do
    assert Application.fetch_env!(:apiary, Oban)[:shutdown_grace_period] == 15_000
    assert Oban.config(Oban).shutdown_grace_period == 15_000
  end

  describe "a stop of the endpoint" do
    # A stop ends within this many limits. Without `ApiaryWeb.EndpointDeadline`, a stop
    # with hung requests in two acceptors takes at least two limits.
    @margin 1.9

    # The endpoint's `http:` options on a free port of the loopback address, with `limit`
    # in place of the 20 s, so the tests stay short.
    defp http(limit) do
      env()[:http]
      |> Keyword.merge(ip: {127, 0, 0, 1}, port: 0, startup_log: false)
      |> Keyword.update!(:thousand_island_options, &Keyword.put(&1, :shutdown_timeout, limit))
    end

    # An `https:` listener as `ApiaryWeb.Endpoint.bound_https/1` makes it of the endpoint's
    # configuration, on a free port, with a certificate made for the test.
    defp https(limit) do
      %{cert: cert, key: key} =
        :public_key.pkix_test_root_cert(~c"localhost", key: {:rsa, 2048, 65_537})

      key = {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)}
      tls = [cert: cert, key: key]

      Endpoint.bound_https(http: http(limit), https: [ip: {127, 0, 0, 1}, port: 0])[:https]
      |> Keyword.merge(startup_log: false)
      |> Keyword.update!(:thousand_island_options, &Keyword.put(&1, :transport_options, tls))
    end

    # The endpoint's tree as `Apiary.Application` starts it, with `limit` in place of the
    # 20 s: a supervisor of the listeners, `Served` in place of the endpoint, then
    # `ApiaryWeb.EndpointDeadline` with the options under `:deadline`. With `https: true`,
    # an https listener beside the http one. Returns the application's supervisor and the
    # port of each listener.
    defp start_endpoint(limit, opts \\ []) do
      listeners =
        [http: http(limit)] ++ if(opts[:https], do: [https: https(limit)], else: [])

      endpoint = %{
        id: Served,
        start:
          {Supervisor, :start_link,
           [
             Bandit.PhoenixAdapter.child_specs(Served, [otp_app: :apiary] ++ listeners),
             [strategy: :one_for_one, name: Served]
           ]},
        type: :supervisor
      }

      deadline = [endpoint: Served, timeout: limit] ++ Keyword.get(opts, :deadline, [])
      children = [endpoint, {ApiaryWeb.EndpointDeadline, deadline}]

      app =
        start_supervised!(%{
          id: :app,
          start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
          type: :supervisor,
          restart: :temporary
        })

      ports =
        for {scheme, _opts} <- listeners, into: %{} do
          {:ok, {_ip, port}} = Bandit.PhoenixAdapter.server_info(Served, scheme)
          {scheme, port}
        end

      {app, ports}
    end

    defp connect(port, scheme \\ :http)

    defp connect(port, :http) do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      {:gen_tcp, socket}
    end

    defp connect(port, :https) do
      {:ok, socket} =
        :ssl.connect(~c"127.0.0.1", port, [:binary, active: false, verify: :verify_none])

      {:ssl, socket}
    end

    defp get({transport, socket}, path, connection) do
      request = "GET #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: #{connection}\r\n\r\n"
      :ok = transport.send(socket, request)
    end

    # The bytes read until the connection closes, and when it closed: `:open` when it is
    # still open after 5 s.
    defp read_all({transport, socket}, acc \\ "") do
      case transport.recv(socket, 0, 5_000) do
        {:ok, data} -> read_all({transport, socket}, acc <> data)
        {:error, :closed} -> {acc, System.monotonic_time(:millisecond)}
        {:error, :timeout} -> {acc, :open}
      end
    end

    # One response of a connection kept alive, read up to its body "ok".
    defp read_ok({transport, socket}, acc \\ "") do
      case transport.recv(socket, 0, 5_000) do
        {:ok, data} ->
          acc = acc <> data

          if String.ends_with?(acc, "\r\n\r\nok"),
            do: acc,
            else: read_ok({transport, socket}, acc)

        {:error, reason} ->
          raise "no response to GET /ok after #{inspect(acc)}: #{inspect(reason)}"
      end
    end

    # A request that never ends, on a connection of `scheme`, in a task.
    defp hang(port, scheme, test) do
      Task.async(fn ->
        socket = connect(port, scheme)
        get(socket, Served.path("hang", test), "close")
        read_all(socket)
      end)
    end

    # Returns once the listener on `port` refuses connections.
    defp await_closed(port, tries \\ 200)
    defp await_closed(_port, 0), do: flunk("the listener still accepts connections")

    defp await_closed(port, tries) do
      case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          Process.sleep(10)
          await_closed(port, tries - 1)

        {:error, _refused} ->
          :ok
      end
    end

    # Each connection closed without a response, within the margin after `started`.
    defp assert_cut(replies, started, limit) do
      for {reply, closed} <- replies do
        assert reply == ""
        assert is_integer(closed), "a connection is still open 5 s after the stop"
        assert closed - started < @margin * limit
      end
    end

    test "waits for a request that ends within the limit" do
      {app, %{http: port}} = start_endpoint(2_000)
      test = self()

      response =
        Task.async(fn ->
          socket = connect(port)
          get(socket, Served.path("sleep/300", test), "close")
          read_all(socket)
        end)

      assert_receive {:in_flight, _handler}, 2_000
      {micros, :ok} = :timer.tc(fn -> Supervisor.stop(app) end)

      assert {"HTTP/1.1 200 OK\r\n" <> _ = reply, _closed} = Task.await(response)
      assert String.ends_with?(reply, "slept 300 ms")
      assert micros < 2_000_000
    end

    test "after a crash of the deadline, the listener goes on accepting" do
      {app, %{http: port}} = start_endpoint(1_000)

      [deadline] =
        for {ApiaryWeb.EndpointDeadline, pid, _, _} <- Supervisor.which_children(app), do: pid

      capture_log(fn -> :ok = GenServer.stop(deadline, :crash) end)

      socket = connect(port)
      get(socket, Served.path("ok", self()), "close")
      assert {"HTTP/1.1 200 OK\r\n" <> _, _closed} = read_all(socket)
    end

    test "ends within its limit, every connection cut, kept-alive ones too" do
      limit = 1_000
      {app, %{http: port}} = start_endpoint(limit)
      test = self()

      # Five requests that never end, each on a separate connection.
      hung = for _ <- 1..5, do: hang(port, :http, test)

      # Two connections kept alive, which send a request that never ends once the stop has
      # closed the port.
      kept =
        for _ <- 1..2 do
          Task.async(fn ->
            socket = connect(port)
            get(socket, Served.path("ok", test), "keep-alive")
            read_ok(socket)
            send(test, {:kept, self()})

            receive do
              :go -> get(socket, Served.path("hang", test), "keep-alive")
            end

            read_all(socket)
          end)
        end

      for _ <- 1..5, do: assert_receive({:in_flight, _handler}, 2_000)

      kept_pids =
        for _ <- 1..2 do
          assert_receive {:kept, pid}, 2_000
          pid
        end

      endpoint = Process.monitor(Served)
      started = System.monotonic_time(:millisecond)
      stop = Task.async(fn -> :timer.tc(fn -> Supervisor.stop(app) end) end)

      await_closed(port)
      for pid <- kept_pids, do: send(pid, :go)

      {micros, :ok} = Task.await(stop, 5_000)
      assert micros < @margin * limit * 1_000
      # The endpoint stopped, and was not killed: only the connections were.
      assert_receive {:DOWN, ^endpoint, :process, _pid, :shutdown}

      assert_cut(Task.await_many(hung ++ kept, 10_000), started, limit)
    end

    test "cuts the connections of the http and the https listener together" do
      limit = 1_000
      {app, %{http: http, https: https}} = start_endpoint(limit, https: true)
      test = self()

      hung = [hang(http, :http, test), hang(http, :http, test)]
      hung = hung ++ [hang(https, :https, test), hang(https, :https, test)]
      for _ <- 1..4, do: assert_receive({:in_flight, _handler}, 5_000)

      endpoint = Process.monitor(Served)
      started = System.monotonic_time(:millisecond)
      {micros, :ok} = :timer.tc(fn -> Supervisor.stop(app) end)

      assert micros < @margin * limit * 1_000
      assert_receive {:DOWN, ^endpoint, :process, _pid, :shutdown}
      assert_cut(Task.await_many(hung, 10_000), started, limit)
    end

    test "cuts the connections at its limit when closing the ports fails" do
      limit = 1_000

      {app, %{http: port}} =
        start_endpoint(limit, deadline: [suspend: fn _server -> raise "suspend failed" end])

      test = self()
      hung = for _ <- 1..3, do: hang(port, :http, test)
      for _ <- 1..3, do: assert_receive({:in_flight, _handler}, 2_000)

      endpoint = Process.monitor(Served)
      started = System.monotonic_time(:millisecond)
      {micros, :ok} = :timer.tc(fn -> Supervisor.stop(app) end)

      assert micros < @margin * limit * 1_000
      assert_receive {:DOWN, ^endpoint, :process, _pid, :shutdown}
      assert_cut(Task.await_many(hung, 10_000), started, limit)
    end
  end

  defmodule Served do
    # Stands in for the endpoint: `GET /ok/<token>` gets a 200 at once, `GET
    # /sleep/<ms>/<token>` after `ms` milliseconds, and `GET /hang/<token>` never. Each
    # request but `/ok` first sends `{:in_flight, handler}` to the process of the token.
    @behaviour Plug

    @doc false
    def path(action, pid) do
      "/#{action}/" <> (pid |> :erlang.term_to_binary() |> Base.url_encode64(padding: false))
    end

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{path_info: ["ok", _token]} = conn, _opts) do
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    def call(%Plug.Conn{path_info: path_info} = conn, _opts) do
      token = List.last(path_info)

      send(
        :erlang.binary_to_term(Base.url_decode64!(token, padding: false)),
        {:in_flight, self()}
      )

      case path_info do
        ["sleep", ms, _token] ->
          Process.sleep(String.to_integer(ms))
          Plug.Conn.send_resp(conn, 200, "slept #{ms} ms")

        ["hang", _token] ->
          Process.sleep(:infinity)
      end
    end
  end
end
