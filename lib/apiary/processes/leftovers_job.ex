defmodule Apiary.Processes.LeftoversJob do
  @moduledoc """
  Deletes the overrides of one workspace that are no longer kept, its workflows' model
  choices and time limits (Apiary.Processes.delete_leftovers_now/1), as the instance.
  A close or an undo of a work item, or the end of a run of a workflow that has an
  override, enqueues it in its transaction, so it runs once that commits, under the
  workspace's row: the change holds the work item's row or the run's, which come after
  the workspace's in the lock order (docs/access.md).

  Each such change enqueues one job, which reads the work items and the runs when it
  runs. A second run of a job finds nothing more to delete. A job whose workspace is gone
  has nothing to do and completes (`c:Apiary.Job.scope_gone/1`); one whose workspace or
  organisation is marked for deletion deletes nothing and is cancelled, as `Apiary.Job`
  cancels such a job.
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
  def perform(%Scope{} = scope, %Oban.Job{}), do: Apiary.Processes.delete_leftovers_now(scope)

  @impl Apiary.Job
  def scope_gone(%Oban.Job{}), do: :ok
end
