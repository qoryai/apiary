defmodule ApiaryWeb.EndpointDeadline do
  @moduledoc """
  Cuts the requests still open when a stop of the endpoint has lasted `timeout`
  milliseconds, so that every listener of the endpoint, together, stops within that time.

  Thousand Island, the server under Bandit, stops the acceptors of a listener one after
  the other and waits up to its `shutdown_timeout` for the connections of each, so a stop
  without this process can last that time once per acceptor that has a slow connection.
  Over a connection that is kept alive, a client can also send new requests until the
  acceptor of that connection is stopped.

  The application starts this process after the endpoint (lib/apiary/application.ex), so
  a stop reaches it first. It then closes the port of each listener of the endpoint
  (`ThousandIsland.suspend/1`), takes the connections that are open, and kills each one
  still open `timeout` milliseconds later: its client sees the connection closed. A
  connection that ends before that is not touched. An endpoint that serves no listener,
  as in the tests, is left as it is.
  """

  use GenServer

  @doc """
  Starts the process for the endpoint module `:endpoint`, whose stop it cuts after
  `:timeout` milliseconds.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(
      __MODULE__,
      {Keyword.fetch!(opts, :endpoint), Keyword.fetch!(opts, :timeout)}
    )
  end

  @impl GenServer
  def init(state) do
    # So that a stop of the supervisor runs `terminate/2`.
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  # Only a stop cuts the connections; after a crash, the supervisor starts this process
  # again and the listeners go on accepting.
  @impl GenServer
  def terminate(:shutdown, state), do: cut(state)
  def terminate({:shutdown, _reason}, state), do: cut(state)
  def terminate(_crash, _state), do: :ok

  defp cut({endpoint, timeout}) do
    connections = Enum.flat_map([:http, :https], &suspend(endpoint, &1))

    # Not linked, so it outlives this process and the endpoint's stop.
    spawn(fn ->
      Process.sleep(timeout)
      Enum.each(connections, &Process.exit(&1, :kill))
    end)

    :ok
  end

  # The connections open on the listener of `scheme`, once it accepts no more; none when
  # the endpoint has no such listener or is not running.
  defp suspend(endpoint, scheme) do
    with {:ok, server} when is_pid(server) <- Bandit.PhoenixAdapter.bandit_pid(endpoint, scheme),
         :ok <- ThousandIsland.suspend(server),
         {:ok, connections} <- ThousandIsland.connection_pids(server) do
      connections
    else
      _none -> []
    end
  catch
    :exit, _not_running -> []
  end
end
