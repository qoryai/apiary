defmodule Apiary.Audit.PruneJob do
  @moduledoc """
  Deletes one organisation's audit entries older than the instance keeps them
  (`Apiary.Audit.prune/2`), as the instance. `Apiary.Audit.PruneSweep` enqueues one a day
  for every organisation.

  Unique while it waits, runs or is retried, so a sweep run again does not enqueue a
  second one for the same organisation; one that has completed does not stop the next
  day's. Run twice, the second finds nothing older and records nothing.
  """
  use Apiary.Job,
    scope: :organisation,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete]

  alias Apiary.Accounts.Scope

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{}) do
    case Apiary.Audit.prune(scope) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
