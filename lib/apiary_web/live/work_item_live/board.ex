defmodule ApiaryWeb.WorkItemLive.Board do
  # The rows of the board under the workflow model (`ApiaryWeb.WorkItemLive.Workflow`):
  # each live work item of the scope's workspace with its process version and its stage
  # (the columns `process_version_id`, `stage_id` and `stage_state` of `work_items`),
  # most recently updated first, at most `@max` of them. The page that calls it has
  # checked `work_item.read` on the workspace (`ApiaryWeb.Access`); it reads nothing else.
  #
  # The columns come with the workflow model's process versions, so the board calls this
  # only where the feature `workflow_model` is on.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.Accounts.Scope
  alias Apiary.Repo
  alias Apiary.WorkItems.WorkItem

  @max 500

  @doc false
  # rows/1 is the board's work items of the scope's workspace.
  @spec rows(Scope.t()) :: [map]
  def rows(%Scope{workspace: %{id: workspace_id}}) do
    Repo.all(
      from w in WorkItem,
        where: w.workspace_id == ^workspace_id and w.state == :exploring,
        order_by: [desc: w.updated_at, desc: w.public_id],
        limit: @max,
        select: %{
          id: w.public_id,
          number: w.number,
          title: w.title,
          test: w.test,
          process_version_id: field(w, :process_version_id),
          stage_id: field(w, :stage_id),
          stage_state: field(w, :stage_state)
        }
    )
  end
end
