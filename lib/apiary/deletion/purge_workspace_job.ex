defmodule Apiary.Deletion.PurgeWorkspaceJob do
  @moduledoc """
  Purges one workspace marked for deletion whose grace period is over
  (`Apiary.Deletion.purge_workspace/1`), as the instance. `Apiary.Deletion.PurgeSweep`
  enqueues it.

  Unique while it waits, runs or is retried, so a sweep run again does not enqueue a
  second one for the same workspace. A purge stopped half way, by a crash or its
  timeout, is retried and goes on where it stopped; one whose workspace is gone already,
  purged by an earlier attempt or with its organisation, has nothing left to do and
  completes (`c:Apiary.Job.scope_gone/1`). One whose workspace was restored meanwhile
  completes and deletes nothing.
  """
  use Apiary.Job,
    scope: :workspace,
    queue: :default,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete]

  alias Apiary.Accounts.Scope

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{}) do
    case Apiary.Deletion.purge_workspace(scope) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Apiary.Job
  def scope_gone(%Oban.Job{}), do: :ok
end
