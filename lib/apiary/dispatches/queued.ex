defmodule Apiary.Dispatches.Queued do
  @moduledoc false

  # The run record (`Apiary.Runs.Run`) of a run of the queue (`Apiary.Dispatches.DispatchRun`)
  # from the moment it is queued, so the Runs list and the run page show a run that waits
  # for a machine.
  #
  # `insert!/1` writes the record when the run of the queue is written, in the same
  # transaction: `pending`, with no node, no registration and no start, its `rn_` id, the
  # next number of its workspace (`Apiary.Runs.Number`), `dispatch_run_id` the run of the
  # queue, `node_run_id` the run of the queue's `run_id`, and `inserted_at` the time it was
  # queued. The pages show such a run as queued (`Apiary.Runs.Run.queued?/1`). The claim
  # that takes the run of the queue updates the record (`Apiary.Dispatches.Handover`); it
  # keeps its number and its id.
  #
  # `requeue!/2` writes a new record for each run of the queue that waits again and has
  # none, after a failed start ended its record (`Apiary.Dispatches.Handover.fail_start/3`):
  # the retry takes the next number, and its `inserted_at` is when it went back to waiting.
  #
  # `ended/2` ends the record of each run of the queue that ended before its handover:
  # `cancelled` when its work item was closed or undone, or a prebuild was superseded or
  # its pool deleted (`closed`, `undone`, `superseded`, `lost`); `failed` for any other
  # cause. The reason is the run of the queue's end cause, and the record keeps its
  # number. Only a record that never attached and whose run code was never redeemed
  # ends here: a run that started ends by its exit.
  #
  # The number is taken last in `insert!/1`, as `Apiary.Runs.Number` asks: the counter of
  # the workspace stays locked until the transaction ends.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{PublicId, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Number, Run}

  # The end causes of a run of the queue whose record ends cancelled.
  @cancelled ~w(closed undone superseded lost)

  # insert!/1 writes the queued run record of `dispatch_run`, inside the caller's
  # transaction (the moduledoc).
  @doc false
  @spec insert!(DispatchRun.t()) :: Run.t()
  def insert!(%DispatchRun{queued_at: queued_at} = dispatch_run),
    do: insert!(dispatch_run, queued_at)

  defp insert!(dispatch_run, queued_at) do
    %{
      id: id,
      run_id: run_id,
      organisation_id: organisation_id,
      workspace_id: workspace_id
    } = dispatch_run

    %Run{
      public_id: Run.new_public_id(),
      organisation_id: organisation_id,
      workspace_id: workspace_id,
      node_run_id: run_id,
      state: "pending",
      dispatch_run_id: id,
      inserted_at: queued_at,
      updated_at: queued_at
    }
    |> Map.put(
      :number,
      Number.next(%Workspace{id: workspace_id, organisation_id: organisation_id})
    )
    |> PublicId.Insert.insert!()
  end

  # requeue!/2 writes a queued run record, at `now`, for each of the runs of the queue
  # `dispatch_run_ids` that waits and has no record, inside the caller's transaction,
  # which holds them, in the order they were queued (the moduledoc).
  @doc false
  @spec requeue!([Ecto.UUID.t()], DateTime.t()) :: [Run.t()]
  def requeue!([], %DateTime{}), do: []

  def requeue!(dispatch_run_ids, %DateTime{} = now) when is_list(dispatch_run_ids) do
    Repo.all(
      from d in DispatchRun,
        as: :queued,
        where: d.id in ^dispatch_run_ids and d.state == :waiting,
        where: not exists(from r in Run, where: r.dispatch_run_id == parent_as(:queued).id),
        order_by: [asc: d.queued_at, asc: d.id]
    )
    |> Enum.map(&insert!(&1, now))
  end

  # ended/2 ends, at `now`, the record of each of the runs of the queue
  # `dispatch_run_ids` that ended before its handover, inside the caller's transaction,
  # which ended them (the moduledoc). The ids of the records it ended.
  @doc false
  @spec ended([Ecto.UUID.t()], DateTime.t()) :: [Ecto.UUID.t()]
  def ended([], %DateTime{}), do: []

  def ended(dispatch_run_ids, %DateTime{} = now) when is_list(dispatch_run_ids) do
    {_count, ids} =
      Repo.update_all(
        from(r in Run,
          join: d in DispatchRun,
          on: d.id == r.dispatch_run_id,
          where: r.dispatch_run_id in ^dispatch_run_ids and r.state == "pending",
          where: d.state == :ended and not is_nil(d.end_cause),
          where: is_nil(r.attached_at) and is_nil(r.run_code_public_key),
          select: r.id,
          update: [
            set: [
              state:
                fragment(
                  "CASE WHEN ? = ANY(?) THEN 'cancelled' ELSE 'failed' END",
                  d.end_cause,
                  ^@cancelled
                ),
              reason: d.end_cause,
              run_documents: nil,
              updated_at: ^now
            ]
          ]
        ),
        []
      )

    ids
  end

  # cancelled/0 is the end causes of a run of the queue whose record ends cancelled.
  @doc false
  @spec cancelled() :: [String.t()]
  def cancelled, do: @cancelled
end
