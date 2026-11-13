defmodule ApiaryWeb.EndpointStopTest do
  # On a stop, the endpoint's listeners finish open requests for up to 20 s in total, and
  # Oban then finishes running jobs for up to 15 s: 35 s, under a stop grace period of
  # 40 s, the least an install sets (guides/upgrading.md).
  use ExUnit.Case, async: true

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
    # The endpoint's `http:` options on a free port of the loopback address, with `limit`
    # in place of the 20 s, so the tests stay short.
    defp http(limit) do
      env()[:http]
      |> Keyword.merge(ip: {127, 0, 0, 1}, port: 0, startup_log: false)
      |> Keyword.update!(:thousand_island_options, &Keyword.put(&1, :shutdown_timeout, limit))
    end

    # The endpoint's tree as `Apiary.Application` starts it, with `limit` in place of the
    # 20 s: a supervisor of the listeners, `Served` in place of the endpoint, killed when
    # its stop outlasts `limit`, then `ApiaryWeb.EndpointDeadline`. Returns the
    # application's supervisor and the port.
    defp start_endpoint(limit) do
      endpoint = %{
        id: Served,
        start:
          {Supervisor, :start_link,
           [
             Bandit.PhoenixAdapter.child_specs(Served, otp_app: :apiary, http: http(limit)),
             [strategy: :one_for_one, name: Served]
           ]},
        type: :supervisor,
        shutdown: limit
      }

      children = [endpoint, {ApiaryWeb.EndpointDeadline, endpoint: Served, timeout: limit}]

      app =
        start_supervised!(%{
          id: :app,
          start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
          type: :supervisor,
          restart: :temporary
        })

      {:ok, {_ip, port}} = Bandit.PhoenixAdapter.server_info(Served, :http)
      {app, port}
    end

    defp connect(port) do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      socket
    end

    defp get(socket, path, connection) do
      :ok =
        :gen_tcp.send(
          socket,
          "GET #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: #{connection}\r\n\r\n"
        )
    end

    # The bytes read until the connection closes, and when it closed.
    defp read_all(socket, acc \\ "") do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_all(socket, acc <> data)
        {:error, :closed} -> {acc, System.monotonic_time(:millisecond)}
      end
    end

    # One response of a connection kept alive, read up to its body "ok".
    defp read_ok(socket, acc \\ "") do
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      acc = acc <> data
      if String.ends_with?(acc, "\r\n\r\nok"), do: acc, else: read_ok(socket, acc)
    end

    test "waits for a request that ends within the limit" do
      {app, port} = start_endpoint(2_000)
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

    test "ends within its limit, every listener's connection cut, kept-alive ones too" do
      limit = 1_000
      {app, port} = start_endpoint(limit)
      test = self()

      # Five requests that never end, each on a separate connection.
      hung =
        for _ <- 1..5 do
          Task.async(fn ->
            socket = connect(port)
            get(socket, Served.path("hang", test), "close")
            read_all(socket)
          end)
        end

      # Two connections kept alive, which send a request that never ends during the stop.
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

      started = System.monotonic_time(:millisecond)
      stop = Task.async(fn -> :timer.tc(fn -> Supervisor.stop(app) end) end)

      # The stop has begun by then; were it not, the requests would only be open longer.
      Process.sleep(100)
      for pid <- kept_pids, do: send(pid, :go)

      {micros, :ok} = Task.await(stop, 5_000)
      assert micros < 1.5 * limit * 1_000

      for {reply, closed} <- Task.await_many(hung ++ kept, 5_000) do
        assert reply == ""
        assert closed - started < 1.5 * limit
      end
    end
  end

  defmodule Served do
    # Stands in for the endpoint: `GET /ok/<token>` is answered at once, `GET
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
