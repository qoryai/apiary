defmodule Apiary.ProductName.Cache do
  @moduledoc """
  Each node's copy of the product's name an instance admin set
  (`Apiary.ProductName.get/0`), so a page or an email that shows the name reads no row.

  It reads the row when it starts, after the migrator and before anything serves, and
  again whenever an admin renames the instance: the node that renamed it broadcasts
  `changed/0` on `Apiary.PubSub`, which every node of the cluster hears, itself included.
  A node that misses the broadcast keeps the name it had until it starts again.

  The copy is a `:persistent_term`, written only when the name changes. Without this
  process, as under `bin/apiary eval` and in the tests
  (`config :apiary, Apiary.ProductName.Cache, enabled: false`), `Apiary.ProductName` reads
  the row each time it is asked.
  """
  use GenServer

  alias Apiary.ProductName

  @key {__MODULE__, :name}
  @topic "instance_product_name"

  @doc "Starts the cache, named after its module."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "enabled?/0 is whether the application starts the cache: true unless set off."
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc """
  cached/0 is the name the cache holds, `{:ok, name}`, nil for none, as
  `Apiary.ProductName.get/0` answers, or `:error` when no cache runs on this node.
  """
  @spec cached() :: {:ok, String.t() | nil} | :error
  def cached do
    case :persistent_term.get(@key, :error) do
      {:name, name} -> {:ok, name}
      :error -> :error
    end
  end

  @doc """
  changed/0 tells every node's cache that the name changed, so each reads it again.
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
    held = {:name, ProductName.load()}
    if :persistent_term.get(@key, :error) != held, do: :persistent_term.put(@key, held)
    :ok
  end
end
