defmodule Apiary.Mail.Cache do
  @moduledoc """
  Each node's copy of the mail settings an instance admin saved (`Apiary.Mail.stored/0`),
  so sending an email, or asking whether mail is set, reads no row. It holds the settings
  as stored, the password encrypted, and their state; the password is decrypted only
  when an email is sent (`Apiary.Mail.mailer_config/0`).

  It reads the row when it starts, after the migrator and the key check and before
  anything serves, and again whenever a save or a followed test link changes it: the node
  that changed it broadcasts `changed/0` on `Apiary.PubSub`, which every node of the
  cluster hears, itself included. A node that misses the broadcast keeps the settings it
  had until it starts again. Once it has read the row it says, once, at `info`, that no
  mail is set when none is (`Apiary.Mail.boot/0`), and at `warning` when the stored
  password cannot be read (`unreadable_message/0`).

  The copy is a `:persistent_term`, written only when the settings change. Without this
  process, as under `bin/apiary eval` and in the tests
  (`config :apiary, Apiary.Mail.Cache, enabled: false`), `Apiary.Mail` reads the row each
  time it is asked.
  """
  use GenServer

  require Logger

  alias Apiary.Mail

  @key {__MODULE__, :stored}
  @topic "instance_mail"

  @unreadable "The SMTP password saved in Instance settings › Mail cannot be read, so mail is off. An instance admin enters it again there."

  @doc "Starts the cache, named after its module."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "enabled?/0 is whether the application starts the cache: true unless configured off."
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc """
  cached/0 is the settings the cache holds, `{:ok, stored}` as `Apiary.Mail.stored/0`
  answers, or `:error` when no cache runs on this node.
  """
  @spec cached() :: {:ok, Mail.stored()} | :error
  def cached do
    case :persistent_term.get(@key, nil) do
      nil -> :error
      stored -> {:ok, stored}
    end
  end

  @doc """
  changed/0 tells every node's cache that the mail settings changed, so each reads them
  again. Called once the change is committed.
  """
  @spec changed() :: :ok
  def changed, do: Phoenix.PubSub.broadcast(Apiary.PubSub, @topic, {__MODULE__, :changed})

  @doc "unreadable_message/0 is what the log says when the stored password cannot be read."
  @spec unreadable_message() :: String.t()
  def unreadable_message, do: @unreadable

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, @topic)
    load()
    Mail.boot()
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
    {state, _settings} = stored = Mail.load()

    if state == :unreadable and Apiary.Features.on?(:instance_mail),
      do: Logger.warning(@unreadable)

    if :persistent_term.get(@key, nil) != stored, do: :persistent_term.put(@key, stored)
    :ok
  end
end
