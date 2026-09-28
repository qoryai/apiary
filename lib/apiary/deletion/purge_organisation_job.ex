defmodule Apiary.Deletion.PurgeOrganisationJob do
  @moduledoc """
  Purges one organisation marked for deletion whose grace period is over
  (`Apiary.Deletion.purge_organisation/1`), as the instance, and leaves the instance's
  line of it. `Apiary.Deletion.PurgeSweep` enqueues it.

  Unique while it waits, runs or is retried, so a sweep run again does not enqueue a
  second one for the same organisation. A purge stopped half way is retried and goes on
  where it stopped; one whose organisation is gone already, whose line was written with
  its deletion, has nothing left to do and completes (`c:Apiary.Job.scope_gone/1`). One
  whose organisation was restored meanwhile completes and deletes nothing.
  """
  use Apiary.Job,
    scope: :organisation,
    queue: :default,
    max_attempts: 20,
    unique: [period: :infinity, states: :incomplete]

  alias Apiary.Accounts.Scope

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{}) do
    case Apiary.Deletion.purge_organisation(scope) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Apiary.Job
  def scope_gone(%Oban.Job{}), do: :ok
end
