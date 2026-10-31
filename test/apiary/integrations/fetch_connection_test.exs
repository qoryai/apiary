defmodule Apiary.Integrations.Fetch.ConnectionTest do
  # The connection of `Apiary.Integrations.Fetch` (`Apiary.Integrations.Fetch.Connection`)
  # against a TLS server on 127.0.0.1 that this test starts, with a certificate for
  # git.example.com: one connection per request, closed when it ends, and nothing left
  # behind. Not async: it counts the node's atoms, ports and Req's Finch pools.
  use ExUnit.Case, async: false

  alias Apiary.Integrations.Fetch.Connection

  @host "git.example.com"

  setup do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"git.example.com"}]}
    rsa = {:rsa, 2048, 65_537}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: rsa], peer: [key: rsa, extensions: [san]]},
        client_chain: %{root: [], peer: []}
      })

    server = Keyword.take(server, [:cert, :key])

    {:ok, listen} =
      :ssl.listen(
        0,
        server ++ [active: false, mode: :binary, reuseaddr: true, ip: {127, 0, 0, 1}]
      )

    on_exit(fn -> :ssl.close(listen) end)
    {:ok, {_address, port}} = :ssl.sockname(listen)
    %{listen: listen, port: port, cacerts: client[:cacerts]}
  end

  # Accepts `n` connections, each answered by `answer` (`:ok`, or `:silent` for none),
  # and sends the test `{:closed, i}` once the client closed connection `i`.
  defp serve(listen, n, answer) do
    test = self()

    spawn_link(fn ->
      for i <- 1..n do
        {:ok, socket} = :ssl.transport_accept(listen)

        # The socket closes with the process that owns it, so this loop hands it over.
        worker =
          spawn(fn ->
            receive do
              :go -> :ok
            end

            with {:ok, socket} <- :ssl.handshake(socket, 5_000),
                 {:ok, _request} <- :ssl.recv(socket, 0, 5_000) do
              if answer == :ok,
                do:
                  :ssl.send(
                    socket,
                    "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nhello"
                  )

              {:error, _closed} = :ssl.recv(socket, 0, 5_000)
            end

            send(test, {:closed, i})
          end)

        :ok = :ssl.controlling_process(socket, worker)
        send(worker, :go)
      end
    end)
  end

  defp request(port, hostname, cacerts, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 2_000)

    Req.new(
      url: "https://127.0.0.1:#{port}/acme/harness/info/refs",
      method: :get,
      headers: [{"host", "#{hostname}:#{port}"}, {"user-agent", "test"}],
      adapter: Connection,
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: false,
      raw: true,
      into: Keyword.get(opts, :into)
    )
    |> Req.Request.put_private(:fetch_connection, {{127, 0, 0, 1}, hostname, deadline})
    |> Req.Request.put_private(:fetch_transport_opts, cacerts: cacerts)
    |> Req.request()
  end

  test "reads the answer over one connection to the address, checked for the host, then closes it",
       ctx do
    serve(ctx.listen, 1, :ok)

    assert {:ok, %Req.Response{status: 200, body: "hello"} = response} =
             request(ctx.port, @host, ctx.cacerts)

    assert response.headers["content-type"] == ["text/plain"]
    assert_receive {:closed, 1}, 5_000
  end

  test "a body read through `into` stops where it halts", ctx do
    serve(ctx.listen, 1, :ok)

    into = fn {:data, data}, {request, response} ->
      {:halt, {request, %{response | body: data}}}
    end

    assert {:ok, %Req.Response{status: 200, body: "hello"}} =
             request(ctx.port, @host, ctx.cacerts, into: into)

    assert_receive {:closed, 1}, 5_000
  end

  test "a certificate for another name fails, and the connection is closed", ctx do
    serve(ctx.listen, 1, :ok)

    assert {:error, %Mint.TransportError{reason: {:tls_alert, _alert}}} =
             request(ctx.port, "other.example.com", ctx.cacerts)

    assert_receive {:closed, 1}, 5_000
  end

  test "an answer that does not come by the deadline is a timeout, and the connection is closed",
       ctx do
    serve(ctx.listen, 1, :silent)

    assert {:error, %Mint.TransportError{reason: :timeout}} =
             request(ctx.port, @host, ctx.cacerts, timeout: 300)

    assert_receive {:closed, 1}, 5_000
  end

  test "many requests to distinct names, with distinct deadlines, leave no pool, atom or socket behind",
       ctx do
    n = 60
    serve(ctx.listen, n + 2, :ok)

    # A request that succeeds and one that fails first, so the modules both load are
    # loaded before the count.
    {:ok, _response} = request(ctx.port, @host, ctx.cacerts)
    {:error, _error} = request(ctx.port, "h0.example.com", ctx.cacerts)
    assert_receive {:closed, 1}, 5_000
    assert_receive {:closed, 2}, 5_000

    pools = DynamicSupervisor.count_children(Req.FinchSupervisor)
    atoms = :erlang.system_info(:atom_count)
    ports = length(Port.list())

    for i <- 1..n do
      hostname = if rem(i, 2) == 0, do: @host, else: "h#{i}.example.com"
      request(ctx.port, hostname, ctx.cacerts, timeout: 2_000 + i)
    end

    for i <- 3..(n + 2), do: assert_receive({:closed, ^i}, 5_000)

    assert DynamicSupervisor.count_children(Req.FinchSupervisor) == pools
    assert :erlang.system_info(:atom_count) - atoms < 5
    assert eventually(fn -> length(Port.list()) <= ports end)
  end

  # Whether `check` holds within a second: a server's socket closes just after it saw
  # the client close.
  defp eventually(check, tries \\ 20) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end
end
