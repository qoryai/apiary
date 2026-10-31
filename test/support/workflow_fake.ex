defmodule ApiaryWeb.WorkflowFake do
  @moduledoc """
  A test-only read of the harness on the work item page: `read/2` gives what
  `check_result/2` put for the workspace, in place of the harness sources
  `Apiary.Stages.check_workflows/2` reads. `ApiaryWeb.WorkItemLive.Workflow` calls whatever
  `install/0` puts in the application's environment.

  `install/0` changes the whole node, so a test module that calls it is not async, and
  puts the environment back with `uninstall/1` when it ends.
  """

  @key ApiaryWeb.WorkItemLive.Workflow

  @doc "Puts the read in the application's environment: what was there before."
  def install do
    case Agent.start(fn -> %{} end, name: __MODULE__.Reads) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    previous = Application.get_env(:apiary, @key)
    Application.put_env(:apiary, @key, harness_read: &__MODULE__.read/2)
    previous
  end

  @doc "Puts back what `install/0` found."
  def uninstall(nil), do: Application.delete_env(:apiary, @key)
  def uninstall(previous), do: Application.put_env(:apiary, @key, previous)

  @doc """
  What the read of the harness gives for `workspace`: `{:ok, names}`, the workflow names
  the harness lists, `{:error, reason}` as `Apiary.Stacks.Sources.read/2` gives it, or a
  function of no arguments that gives one of those.
  """
  def check_result(workspace, result),
    do: Agent.update(__MODULE__.Reads, &Map.put(&1, workspace.id, result))

  @doc "The read of the harness: what `check_result/2` put, else `{:ok, []}`."
  def read(_scope, workspace) do
    case Agent.get(__MODULE__.Reads, &Map.get(&1, workspace.id, {:ok, []})) do
      fun when is_function(fun, 0) -> fun.()
      result -> result
    end
  end
end
