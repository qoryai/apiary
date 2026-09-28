defmodule Apiary.Organisations.OldInvitationsJob do
  @moduledoc """
  Deletes one organisation's invitations expired for 30 days
  (`Apiary.Organisations.delete_old_invitations/2`), as the instance, each an
  `invitation.revoke` in its trail with the reason `expired`.
  `Apiary.Organisations.InvitationSweep` enqueues one a day for every organisation.

  Unique while it waits, runs or is retried, so a sweep run again does not enqueue a
  second one for the same organisation; one that has completed does not stop the next
  day's. Run twice, the second finds nothing to delete and records nothing.
  """
  use Apiary.Job,
    scope: :organisation,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, states: :incomplete]

  alias Apiary.Accounts.Scope

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{}) do
    case Apiary.Organisations.delete_old_invitations(scope) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
