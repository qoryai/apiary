defmodule Apiary.Runs.Number do
  # Number takes the numbers of a workspace's runs from one counter: 1 for the first, then
  # one more for each, never the same number twice in a workspace, a deleted run's number
  # included. The counter is apart from the one of the workspace's work items
  # (`Apiary.WorkItems.Number`), so a workspace can have Run 3 and work item #3.
  #
  # The workspace's last number is kept in one row of `run_counters`, made with its first
  # run. `next/1` takes the next number with one upsert that adds one, and must run inside
  # the transaction that writes the run: the row stays locked until that transaction ends,
  # so a second run of the workspace waits for the first and takes the number after it, and
  # a run rolled back returns its number to the counter. Take the number as the last step
  # before the insert, because every other run of the workspace waits while the row is
  # locked. The trigger `runs_number_from_counter` is a second writer, which takes the
  # counter's next number under the same row lock for an insert with no number.
  #
  # A run on a node takes its number with `next/2`, which locks the node first. Every path
  # in this release's code then takes the node's row, then the counter, so none deadlocks
  # with `Apiary.Nodes.admit/4`, which locks the node `FOR UPDATE` and then takes a number.
  # The trigger takes the counter first, and the insert's foreign key then locks the node,
  # so an insert on a node with no number, as the previous release writes it, can deadlock
  # with `admit/4`. Postgres then aborts one side.
  #
  # A work item moves between workspaces and its runs stay where they ran, and a document
  # of the work item refers to a run by its number. So a move raises the target's counter
  # past the work item's highest number (`raise_past/2`), and all the runs of one work item
  # have different numbers. The target's numbers then jump. Runs of a work item moved before
  # the counters existed may still repeat a number
  # (`priv/repo/migrations/20261105090000_number_runs_per_workspace.exs`).
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Repo
  alias Apiary.Runs.Run

  # next/1 is the next number of `workspace`'s runs, taken inside the caller's transaction.
  # Raises `ArgumentError` outside one: a number taken there would be committed at once,
  # and lost should the run not be written.
  @doc false
  @spec next(%Workspace{}) :: pos_integer
  def next(%Workspace{} = workspace), do: block(workspace, 1).first

  # next/2 is `next/1` for a run on `node`, nil for a run on no node. The node's row is
  # locked `FOR KEY SHARE` first, the lock the run's foreign key takes at the insert: while
  # the counter is locked, the insert does not wait for a node. Where the node is gone, that
  # foreign key's check fails.
  @doc false
  @spec next(%Workspace{}, Node.t() | nil) :: pos_integer
  def next(%Workspace{} = workspace, nil), do: next(workspace)

  def next(%Workspace{} = workspace, %Node{id: id}) do
    in_transaction!("next/2")
    Repo.one(from n in Node, where: n.id == ^id, lock: "FOR KEY SHARE", select: n.id)
    next(workspace)
  end

  # block/2 is the next `count` numbers of `workspace`'s runs, taken inside the caller's
  # transaction, as a range: for a task that writes many runs at once.
  @doc false
  @spec block(%Workspace{}, pos_integer) :: Range.t()
  def block(%Workspace{id: id, organisation_id: organisation_id}, count)
      when is_integer(count) and count >= 1 do
    in_transaction!("block/2")

    row = %{
      workspace_id: Ecto.UUID.dump!(id),
      organisation_id: Ecto.UUID.dump!(organisation_id),
      last_number: count
    }

    {1, [%{last_number: last}]} =
      Repo.insert_all("run_counters", [row],
        on_conflict: from(c in "run_counters", update: [inc: [last_number: ^count]]),
        conflict_target: [:workspace_id],
        returning: [:last_number]
      )

    (last - count + 1)..last
  end

  # raise_past/2 sets the counter of `workspace` to the highest number of the runs of the
  # work item `work_item_id`, unless the counter is past it, and makes the counter's row
  # where there is none. A work item with no runs changes nothing. Call it in the
  # transaction that moves the work item, after that transaction locks the work item's row,
  # as the last step: the counter stays locked until the transaction ends.
  @doc false
  @spec raise_past(%Workspace{}, Ecto.UUID.t()) :: :ok
  def raise_past(%Workspace{id: id, organisation_id: organisation_id}, work_item_id) do
    in_transaction!("raise_past/2")

    highest =
      Repo.one(
        from r in Run,
          join: d in DispatchRun,
          on: d.id == r.dispatch_run_id,
          where: d.work_item_id == ^work_item_id,
          select: max(r.number)
      )

    if highest do
      row = %{
        workspace_id: Ecto.UUID.dump!(id),
        organisation_id: Ecto.UUID.dump!(organisation_id),
        last_number: highest
      }

      Repo.insert_all("run_counters", [row],
        on_conflict:
          from(c in "run_counters",
            update: [
              set: [last_number: fragment("GREATEST(?, EXCLUDED.last_number)", c.last_number)]
            ]
          ),
        conflict_target: [:workspace_id]
      )
    end

    :ok
  end

  # give_back/1 undoes the `next/1` of this transaction, for an insert that wrote no row
  # because the run is already there. The row is still locked by this transaction, so no
  # other run took a number after it, and no row has the number given back.
  @doc false
  @spec give_back(%Workspace{}) :: :ok
  def give_back(%Workspace{id: id}) do
    in_transaction!("give_back/1")

    {1, _rows} =
      Repo.update_all(
        from(c in "run_counters", where: c.workspace_id == ^Ecto.UUID.dump!(id)),
        inc: [last_number: -1]
      )

    :ok
  end

  defp in_transaction!(function) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "Call Apiary.Runs.Number.#{function} inside the transaction that writes the run"
    end
  end
end
