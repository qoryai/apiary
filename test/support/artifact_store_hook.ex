defmodule Apiary.ArtifactStoreHook do
  @moduledoc """
  An artifact store for tests that need something to happen during a push: the volume
  store (`Apiary.Artifacts.Store.Volume`), with a function that runs once, at the first
  commit of a file. That moment comes after a caller's read of the work item and before
  the push locks it. The store adapter is an application setting, so a test that uses
  this is not async.
  """

  @behaviour Apiary.Artifacts.Store

  alias Apiary.Artifacts.Store
  alias Apiary.Artifacts.Store.Volume

  @doc "on_commit/1 sets the store for this test, and `fun` to run at the next commit."
  def on_commit(fun) when is_function(fun, 0) do
    previous = Application.get_env(:apiary, Store)
    Application.put_env(:apiary, Store, adapter: __MODULE__)
    Application.put_env(:apiary, __MODULE__, fun)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:apiary, __MODULE__)

      if previous,
        do: Application.put_env(:apiary, Store, previous),
        else: Application.delete_env(:apiary, Store)
    end)
  end

  @impl true
  defdelegate stage(source, limit), to: Volume
  @impl true
  defdelegate discard(staged), to: Volume
  @impl true
  defdelegate open(store_key), to: Volume

  @impl true
  def commit(staged) do
    case Application.get_env(:apiary, __MODULE__) do
      nil ->
        :ok

      fun ->
        Application.delete_env(:apiary, __MODULE__)
        fun.()
    end

    Volume.commit(staged)
  end
end
