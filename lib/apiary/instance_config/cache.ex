defmodule Apiary.InstanceConfig.Cache do
  @moduledoc """
  Each node's copy of the settings an instance admin saved in Instance settings ›
  Configuration (`Apiary.InstanceConfig.stored/0`), so the audit trail's job, a deletion
  or an invitation reads no row to know them.

  It reads the row when it starts, after the migrator and the key check and before
  anything serves, and again whenever an admin saves: the node that saved broadcasts
  `changed/0` on `Apiary.PubSub`, which every node of the cluster hears, itself included.
  A node that misses the broadcast keeps the values it had until it starts again.

  The copy is a `:persistent_term`, written only when the settings change. Without this
  process, as under `bin/apiary eval` and in the tests
  (`config :apiary, Apiary.InstanceConfig.Cache, enabled: false`), `Apiary.InstanceConfig`
  reads the row each time it is asked.
  """
  use GenServer

  alias Apiary.InstanceConfig

  @key {__MODULE__, :stored}
  @topic "instance_config"

  @doc "Starts the cache, named after its module."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "enabled?/0 is whether the application starts the cache: true unless configured off."
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc """
  cached/0 is the settings the cache holds, `{:ok, stored}` as
  `Apiary.InstanceConfig.stored/0` answers, or `:error` when no cache runs on this node.
  """
  @spec cached() :: {:ok, InstanceConfig.stored()} | :error
  def cached do
    case :persistent_term.get(@key, nil) do
      nil -> :error
      stored -> {:ok, stored}
    end
  end

  @doc """
  changed/0 tells every node's cache that the settings changed, so each reads them again.
  Called once the change is committed.
  """
  @spec changed() :: :ok
  def changed, do: Phoenix.PubSub.broadcast(Apiary.PubSub, @topic, {__MODULE__, :changed})

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, @topic)
    load()
    {:ok, nil}
  end

  @impl true
  def handle_info({__MODULE__, :changed}, state) do
    load()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Gone, the node reads the row again rather than keep a copy nothing refreshes.
  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@key)
    :ok
  end

  # Reads the row and keeps it, writing the term only when it changed: every write of a
  # `:persistent_term` makes each process that read it copy it.
  defp load do
    stored = InstanceConfig.load()
    if :persistent_term.get(@key, nil) != stored, do: :persistent_term.put(@key, stored)
    :ok
  end
end
