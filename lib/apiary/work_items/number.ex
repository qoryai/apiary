defmodule Apiary.WorkItems.Number do
  # Number gives a workspace's work items their numbers: 1 for the first, then one more
  # for each, never the same number twice in a workspace.
  #
  # The workspace's last number is kept in one row of `work_item_counters`, made with its
  # first work item. `next/1` takes the next number with one upsert that adds one, and
  # must run inside the transaction that writes the work item: the row stays locked until
  # that transaction ends, so a second work item of the workspace waits for the first and
  # takes the number after it, and a work item rolled back gives its number back.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Organisations.Workspace
  alias Apiary.Repo

  # next/1 is the next number of `workspace`'s work items, taken inside the caller's
  # transaction.
  @doc false
  @spec next(%Workspace{}) :: pos_integer
  def next(%Workspace{id: id, organisation_id: organisation_id}) do
    row = %{
      workspace_id: Ecto.UUID.dump!(id),
      organisation_id: Ecto.UUID.dump!(organisation_id),
      last_number: 1
    }

    {1, [number]} =
      Repo.insert_all("work_item_counters", [row],
        on_conflict: from(c in "work_item_counters", update: [inc: [last_number: 1]]),
        conflict_target: [:workspace_id],
        returning: [:last_number]
      )

    Map.fetch!(number, :last_number)
  end
end
