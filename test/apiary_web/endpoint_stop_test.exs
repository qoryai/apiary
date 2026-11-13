defmodule ApiaryWeb.EndpointStopTest do
  # On a stop, the endpoint's listeners wait 20 s for open requests, and Oban then waits
  # 15 s for running jobs: 35 s, under the 40 s stop grace period that
  # guides/upgrading.md asks an install to give the container.
  use ExUnit.Case, async: true

  alias ApiaryWeb.Endpoint

  # The listeners Bandit's adapter makes of a configuration: their child specs, built
  # without starting anything.
  defp listeners(config) do
    for %{id: {Endpoint, scheme}, start: {Bandit, :start_link, [opts]}} <-
          Bandit.PhoenixAdapter.child_specs(Endpoint, [otp_app: :apiary] ++ config),
        do: {scheme, opts}
  end

  defp shutdown_timeout(opts), do: opts[:thousand_island_options][:shutdown_timeout]

  test "the http listener waits 20 s for open requests on a stop" do
    assert shutdown_timeout(Endpoint.config(:http)) == 20_000

    assert [http: opts] = listeners(Application.get_env(:apiary, Endpoint))
    assert shutdown_timeout(opts) == 20_000
  end

  test "an https listener waits the same, beside the options its `https:` sets" do
    https = [port: 4443, thousand_island_options: [num_acceptors: 10]]
    config = Endpoint.bound_https(Application.get_env(:apiary, Endpoint) ++ [https: https])

    assert [http: http, https: opts] = listeners(config)
    assert shutdown_timeout(http) == 20_000
    assert opts[:thousand_island_options] == [shutdown_timeout: 20_000, num_acceptors: 10]

    # A wait the `https:` sets is kept.
    https = [port: 4443, thousand_island_options: [shutdown_timeout: 5_000]]
    assert shutdown_timeout(Endpoint.bound_https(https: https)[:https]) == 5_000
  end

  test "Oban waits 15 s for running jobs on a stop" do
    assert Application.fetch_env!(:apiary, Oban)[:shutdown_grace_period] == 15_000
    assert Oban.config(Oban).shutdown_grace_period == 15_000
  end

  describe "a request open when its listener stops" do
    # A listener with the endpoint's `http:` options, on a free port of the loopback
    # address, whose wait on a stop is `wait`, in place of 20 s, so the test stays short.
    # It serves `ApiaryWeb.EndpointStopTest.Slow`.
    defp start_listener(wait) do
      opts =
        Endpoint.config(:http)
        |> Keyword.merge(ip: {127, 0, 0, 1}, port: 0)
        |> Keyword.update!(:thousand_island_options, &Keyword.put(&1, :shutdown_timeout, wait))

      spec = {Bandit, [plug: {__MODULE__.Slow, self()}] ++ opts}
      pid = start_supervised!(Supervisor.child_spec(spec, id: :listener))
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      port
    end

    # The response to a GET of `path`, as the raw bytes read until the connection closes.
    defp request(port, path) do
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        :ok =
          :gen_tcp.send(
            socket,
            "GET #{path} HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"
          )

        read_all(socket, "")
      end)
    end

    defp read_all(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_all(socket, acc <> data)
        {:error, :closed} -> acc
      end
    end

    test "finishes within the wait, and the stop waits for it" do
      port = start_listener(2_000)
      response = request(port, "/sleep/300")
      assert_receive {:in_flight, _handler}, 2_000

      {micros, :ok} = :timer.tc(fn -> stop_supervised(:listener) end)

      assert "HTTP/1.1 200 OK\r\n" <> _ = reply = Task.await(response)
      assert String.ends_with?(reply, "slept 300 ms")
      assert micros < 2_000_000
    end

    test "is cut when it outlasts the wait" do
      port = start_listener(100)
      response = request(port, "/sleep/60000")
      assert_receive {:in_flight, handler}, 2_000
      ref = Process.monitor(handler)

      :ok = stop_supervised(:listener)

      assert_receive {:DOWN, ^ref, :process, ^handler, :killed}, 2_000
      assert Task.await(response) == ""
    end
  end

  defmodule Slow do
    # Answers `GET /sleep/<ms>` after `ms` milliseconds, once it has told the test which
    # process handles the request.
    @behaviour Plug

    @impl Plug
    def init(test), do: test

    @impl Plug
    def call(%Plug.Conn{path_info: ["sleep", ms]} = conn, test) do
      send(test, {:in_flight, self()})
      Process.sleep(String.to_integer(ms))
      Plug.Conn.send_resp(conn, 200, "slept #{ms} ms")
    end
  end
end
