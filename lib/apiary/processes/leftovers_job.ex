defmodule Apiary.Processes.LeftoversJob do
  @moduledoc """
  Deletes the overrides of one workspace that are no longer kept, its workflows' model
  choices and time limits (Apiary.Processes.delete_leftovers_now/1), as the instance.
  A close or an undo of a work item, or its take in onto the current version while it is
  on another, enqueues it in its transaction, so it runs once that commits, under the
  workspace's row: the change holds the work item's row, which comes after the
  workspace's in the lock order (docs/access.md).

  Each such change enqueues one job, which reads the work items when it runs. A second
  run of a job finds nothing more to delete. A job whose workspace is gone has nothing
  to do and completes (`c:Apiary.Job.scope_gone/1`).
  """
  use Apiary.Job,
    scope: :workspace,
    queue: :default,
    max_attempts: 20

  alias Apiary.Accounts.Scope

  @doc """
  The job for the workspace with the id `workspace_id` of the organisation with the id
  `organisation_id`, to insert in the transaction of the change.
  """
  @spec for_workspace(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def for_workspace(organisation_id, workspace_id),
    do: new(%{"organisation_id" => organisation_id, "workspace_id" => workspace_id})

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{}) do
    case Apiary.Processes.delete_leftovers_now(scope) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Apiary.Job
  def scope_gone(%Oban.Job{}), do: :ok
end
