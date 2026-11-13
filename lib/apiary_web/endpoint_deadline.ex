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
  a stop reaches it first. It first starts a timer, a process that is not linked to it.
  Then it closes the port of each listener of the endpoint (`ThousandIsland.suspend/1`);
  a failure there leaves the timer running. When `timeout` milliseconds have passed, the
  timer kills each connection still open under the endpoint: its client sees the
  connection closed. A connection that ends before that is not touched. An endpoint that
  is not running, or serves no listener, as in the tests, is left as it is.
  """

  use GenServer

  @doc """
  Starts the process for the endpoint module `:endpoint`, whose stop it cuts after
  `:timeout` milliseconds.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    # `:suspend` replaces `ThousandIsland.suspend/1` in a test.
    suspend = Keyword.get(opts, :suspend, &ThousandIsland.suspend/1)

    GenServer.start_link(
      __MODULE__,
      {Keyword.fetch!(opts, :endpoint), Keyword.fetch!(opts, :timeout), suspend}
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

  # The timer first, so that a failure after it, or a kill of this process, leaves the
  # stop bounded.
  defp cut({endpoint, timeout, suspend}) do
    root = Process.whereis(endpoint)
    # The supervisor of this process and of the endpoint.
    [parent | _] = Process.get(:"$ancestors")

    # Not linked, so it outlives this process and the endpoint's stop.
    spawn(fn ->
      Process.sleep(timeout)
      Enum.each(connections(root, endpoint, parent), &Process.exit(&1, :kill))
    end)

    for scheme <- [:http, :https], do: suspend(endpoint, scheme, suspend)
    :ok
  end

  # Closes the port of the listener of `scheme`, when the endpoint has one.
  defp suspend(endpoint, scheme, suspend) do
    case Bandit.PhoenixAdapter.bandit_pid(endpoint, scheme) do
      {:ok, server} when is_pid(server) -> suspend.(server)
      _none -> :ok
    end
  rescue
    _error -> :error
  catch
    :exit, _not_running -> :error
  end

  # The connections under `root`, the endpoint's supervisor, registered as `endpoint`
  # and started by `parent`. The supervisors between them are stopping by then: they take
  # no calls, and each unlinks a child as it stops it. So every process is read for its
  # label and its `$ancestors`, which contain `root` or the name `endpoint`, and `parent`.
  defp connections(nil, _endpoint, _parent), do: []

  defp connections(root, endpoint, parent) do
    for pid <- Process.list(), connection?(pid), under?(pid, root, endpoint, parent), do: pid
  end

  defp under?(pid, root, endpoint, parent) do
    case :erlang.process_info(pid, {:dictionary, :"$ancestors"}) do
      {_item, ancestors} when is_list(ancestors) ->
        parent in ancestors and (root in ancestors or endpoint in ancestors)

      _ended_or_none ->
        false
    end
  end

  # A process that Thousand Island labels as the handler of one connection.
  defp connection?(pid), do: match?({:thousand_island, :connection, _}, :proc_lib.get_label(pid))
end
