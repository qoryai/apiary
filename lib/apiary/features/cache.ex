defmodule Apiary.Features.Cache do
  @moduledoc """
  Each node's copy of the features in force (`Apiary.Features.Saved`), so a gate reads no
  row to know them: the application's environment under `:features`, which
  `Apiary.Features.enabled/0` reads.

  It reads the list when it starts, after the migrator and the key check and before the
  job queue and the endpoint (`Apiary.Features.Saved.boot/0`), and again whenever an admin
  saves: the node that saved broadcasts `changed/0` on `Apiary.PubSub`, which every node
  of the cluster receives, itself included.

  A node can miss that broadcast: it was cut off from the cluster, or it joined it after
  the save. So the cache also reads the list again when a node joins the cluster
  (`:nodeup`), and every 30 seconds it reads the saved list's version
  (`Apiary.Features.Saved.version/0`) and reads the list again where the version differs
  from the one it last read. 30 seconds keeps a node that missed a save at most that long
  behind the others, for one read of one row by its primary key per node every 30 seconds.

  A read that fails because the database cannot be reached (`DBConnection.ConnectionError`
  or `Postgrex.Error`) leaves the copy as it is: the node keeps the features in force, logs
  one warning for the outage, `Features: reading the saved features failed (<error>). This
  node keeps the features in force and reads them again in 30 seconds.`, where `<error>`
  is `connection error` or `database error`, and reads them at the next check. So the
  cache, and the application with it, does not stop while the database is down, and a
  cache that starts again then, as after a restart, starts with the copy the node has.
  Where the read at the start failed, the next read that succeeds is the start's
  (`Apiary.Features.Saved.boot/0`), so the work it does at each start is not skipped.

  Without this process, as under `bin/apiary eval` and in the tests
  (`config :apiary, Apiary.Features.Cache, enabled: false`), the copy is the one
  `Apiary.Features.boot!/0` wrote, and a save writes it on the node that saves.
  """
  use GenServer

  require Logger

  alias Apiary.Features.Saved

  @topic "instance_features"
  @written "instance_features:written"

  # How often the cache compares the saved list's version, in milliseconds.
  @interval :timer.seconds(30)

  @doc """
  Starts the cache, named after its module. Options, for a test: `interval:`, the
  milliseconds between two reads of the version, 30 seconds unless given; `saved:`, the
  module the cache reads with, `Apiary.Features.Saved` unless given.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "enabled?/0 is whether the application starts the cache: true unless configured off."
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc """
  changed/0 sends every node's cache a message that the saved features changed, so each
  reads them again. Called once the change is committed.
  """
  @spec changed() :: :ok
  def changed, do: Phoenix.PubSub.broadcast(Apiary.PubSub, @topic, {__MODULE__, :changed})

  @doc """
  subscribe/0 subscribes the calling process to the writes of this node's copy: each time
  the copy changes, it receives `{Apiary.Features.Cache, :written, features}`, the
  features now in force, once the copy has them.
  """
  @spec subscribe() :: :ok | {:error, term}
  def subscribe, do: Phoenix.PubSub.subscribe(Apiary.PubSub, @written)

  @doc false
  # written/1 sends the processes of this node that subscribed (`subscribe/0`) a message
  # that its copy changed to `features`.
  @spec written([Apiary.Features.feature()]) :: :ok
  def written(features),
    do: Phoenix.PubSub.local_broadcast(Apiary.PubSub, @written, {__MODULE__, :written, features})

  @impl true
  def init(opts) do
    :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, @topic)
    :ok = :net_kernel.monitor_nodes(true)
    interval = Keyword.get(opts, :interval, @interval)
    saved = Keyword.get(opts, :saved, Saved)
    state = %{interval: interval, saved: saved, version: nil, booted?: false, failing?: false}
    schedule(interval)
    {:ok, refresh(state)}
  end

  @impl true
  def handle_info({__MODULE__, :changed}, state), do: {:noreply, refresh(state)}

  def handle_info({:nodeup, _node}, state), do: {:noreply, refresh(state)}

  def handle_info(:check, state) do
    schedule(state.interval)
    {:noreply, check(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp check(%{saved: saved, version: version} = state) do
    if state.booted? and saved.version() == version,
      do: %{state | failing?: false},
      else: refresh(state)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> failed(state, error)
  end

  # The start's read until one succeeds, then a read of the list.
  defp refresh(%{saved: saved, booted?: false} = state), do: read(state, &saved.boot/0)
  defp refresh(%{saved: saved} = state), do: read(state, &saved.refresh/0)

  # The version first: a save between the two reads is read again at the next check. The
  # version is kept only once the list is read, so a failed read is made again.
  defp read(%{saved: saved} = state, read) do
    version = saved.version()
    read.()
    %{state | version: version, booted?: true, failing?: false}
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> failed(state, error)
  end

  # One warning for each outage: the first failed read logs it, the next ones do not, until
  # a read succeeds. The error's kind alone, never its message, which can contain a row.
  defp failed(%{failing?: true} = state, _error), do: state

  defp failed(state, error) do
    Logger.warning(
      "Features: reading the saved features failed (#{kind(error)}). This node keeps the " <>
        "features in force and reads them again in #{div(state.interval, 1000)} seconds."
    )

    %{state | failing?: true}
  end

  defp kind(%DBConnection.ConnectionError{}), do: "connection error"
  defp kind(%Postgrex.Error{}), do: "database error"

  defp schedule(interval), do: Process.send_after(self(), :check, interval)
end
