defmodule Apiary.Runs.Cancel do
  # A member's cancel of a running run (`Apiary.Runs.cancel/2`): from the press, the run
  # changes nothing more.
  #
  # The cancel writes the mark on the run, `cancel_requested_at` and
  # `cancel_requested_by_id` (`Apiary.Runs.Run.cancel_requested?/1`), and the audit entry
  # `run.cancel`. From that commit:
  #
  #   * each signed `202` to the run's batches has `end`, `cancelled` with the reason
  #     `cancelled_by_member` (`Apiary.Runs.Run.cancel_reason/0`), until the run's exit
  #     arrives (`Apiary.Runs.Ingest`): its gateway ends the run;
  #   * the run's pushes of artifacts and its verdict get `409` `run_ended`, read before
  #     and under the work item's lock (`Apiary.Artifacts.push/5`); a direct run's outcome
  #     gets `409` `outcome_given` (`Apiary.Runs.Outcome`). Its gateway's secrets
  #     request stays `200` while the run is live (`Apiary.Runs.SecretsRequest`), so a
  #     run that opens after the press reaches its next batch and the `end` there;
  #   * what the run gave does not count for its stage, whatever its exit: its open
  #     questions, its verdict, its outputs and its proposal (`Apiary.Stages`,
  #     `Apiary.Explore.Outcome`). The stage escalates `run_stopped`, and a paused run
  #     queues no continuation (`Apiary.Dispatches.RunEnd`). Its artifacts stay, marked.
  #
  # The run's state still comes from its exit. The mark is not folded: a rebuild keeps it.
  #
  # Locks: one transaction, in the order the run's end locks
  # (`Apiary.Dispatches.RunEnd`): the rows `Apiary.Dispatches.RunEnd.hold/1` locks, the
  # work item among them; then the run of the queue (`Apiary.Dispatches.RunEnd.lock/1`);
  # then the run's row `FOR UPDATE`. A push locks the same work item and reads the mark
  # under it, so it commits first or reads the mark; a batch locks the run's row, so it
  # commits first or its `202` has `end`. A direct run has no run of the queue: its row
  # alone.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{DispatchRun, RunEnd}
  alias Apiary.Runs.Run

  @typedoc "Why a cancel fails."
  @type refusal :: :forbidden | :not_found | :not_running

  @doc """
  Cancels `run`, of the scope's workspace, for the scope's person: `{:ok, run}` with the
  mark set, also for a run a member cancelled before, which keeps its first mark and
  writes no second entry. `{:error, :forbidden}` for a person who may not
  (`run.cancel`); `{:error, :not_found}` for a run the workspace does not have;
  `{:error, :not_running}` for a run that is not running (`cancellable?/1`): queued,
  claimed and not started, ended, with its exit or its starter's outcome; or whose run of
  the queue ended.
  """
  @spec cancel(Scope.t(), Run.t()) :: {:ok, Run.t()} | {:error, refusal}
  def cancel(%Scope{} = scope, %Run{} = run) do
    with :ok <- Access.authorize(scope, :"run.cancel", run),
         {:ok, {cancelled, written?}} <- Repo.transact(fn -> locked(scope, run) end) do
      if written?, do: told(cancelled)
      {:ok, cancelled}
    end
  end

  defp locked(scope, %Run{id: id, dispatch_run_id: dispatch_run_id}) do
    _held = RunEnd.hold(dispatch_run_id)
    dispatch_run = RunEnd.lock(dispatch_run_id)

    held =
      Repo.one(
        from r in Run,
          where: r.id == ^id,
          where:
            r.organisation_id == ^scope.organisation.id and
              r.workspace_id == ^scope.workspace.id,
          lock: "FOR UPDATE"
      )

    cond do
      is_nil(held) -> {:error, :not_found}
      Run.cancel_requested?(held) -> {:ok, {held, false}}
      not running?(held, dispatch_run) -> {:error, :not_running}
      true -> mark(scope, held)
    end
  end

  # Running, as a member can cancel it (`cancellable?/1`), and its run of the queue, where
  # it has one, not ended.
  defp running?(%Run{} = run, dispatch_run),
    do: cancellable?(run) and not match?(%DispatchRun{state: :ended}, dispatch_run)

  @doc """
  Whether a member can cancel `run`, as the pages read it: running, with no exit, no
  outcome and no mark. A run that waits in the queue, or that a claim registered and that
  has not started, is not running. `cancel/2` also reads its run of the queue, under the
  lock.
  """
  @spec cancellable?(Run.t()) :: boolean
  def cancellable?(%Run{} = run) do
    not Run.queued?(run) and run.state == "running" and is_nil(run.exited_at) and
      is_nil(run.exit_state) and is_nil(run.outcome_state) and not Run.cancel_requested?(run)
  end

  @doc """
  Whether `run` is cancelling at `at`: a member cancelled it (`Run.cancel_requested?/1`)
  and it has not ended (`ended?/2`). Every page that shows the run's state shows
  "Cancelling" in its place then, and the runs list's state filter finds it under
  Cancelling (`cancelling_condition/1`). A map that is not a whole run needs the fields
  `ended?/2` reads.
  """
  @spec cancelling?(map, DateTime.t()) :: boolean
  def cancelling?(run, at \\ DateTime.utc_now()),
    do: Run.cancel_requested?(run) and not ended?(run, at)

  @doc """
  `cancelling?/2` as a query's condition on the run, bound as `:run` and as the query's
  first binding, at `at`: the mark is set, no exit arrived, and the run has not ended
  (`Apiary.Runs.Run.not_ended/1`). Keep the two together: a test compares them on the
  same runs. The states a run that has not ended can have (pending, running or lost) are
  named too, so that the query can read an index on the state.
  """
  @spec cancelling_condition(DateTime.t()) :: Ecto.Query.dynamic_expr()
  def cancelling_condition(%DateTime{} = at) do
    Ecto.Query.dynamic(
      [run: r],
      r.state in ~w(pending running lost) and not is_nil(r.cancel_requested_at) and
        is_nil(r.exit_state) and ^Run.not_ended(at)
    )
  end

  @doc """
  Whether a run has ended at `at`, as a cancel reads it: its exit arrived, or it ended by
  `Apiary.Runs.Run.ended?/2`, a lost run only once it is lost for good. A lost run that
  may still attach again has not ended.
  """
  @spec ended?(map, DateTime.t()) :: boolean
  def ended?(run, at \\ DateTime.utc_now())
  def ended?(%{exit_state: exit}, _at) when is_binary(exit), do: true
  def ended?(run, at), do: Run.ended?(run, at)

  @doc """
  Whether `run` writes changes that its end pushes: a run of a software workspace
  (`workspace`) whose harness has write access (`Apiary.Harnesses.RunHarness`).
  """
  @spec write_run?(Apiary.Organisations.Workspace.t(), Run.t()) :: boolean
  def write_run?(%{domain: "software"}, %Run{dispatch_run_id: id}) when is_binary(id) do
    Repo.exists?(
      from h in Apiary.Harnesses.RunHarness,
        where: h.dispatch_run_id == ^id and h.access_level == :write
    )
  end

  def write_run?(_workspace, _run), do: false

  defp mark(scope, held) do
    now = DateTime.utc_now()

    marked =
      held
      |> Ecto.Changeset.change(
        cancel_requested_at: now,
        cancel_requested_by_id: scope.user.id,
        updated_at: now
      )
      |> Repo.update!()

    with {:ok, _entry} <-
           Audit.record(Repo, scope, :"run.cancel", marked, %{
             details: %{"number" => marked.number}
           }),
         do: {:ok, {marked, true}}
  end

  # The run's pages, and its work item's, read it again.
  defp told(%Run{dispatch_run_id: dispatch_run_id} = run) do
    Apiary.Runs.broadcast_changed(run)

    work_item_id =
      dispatch_run_id &&
        Repo.one(from d in DispatchRun, where: d.id == ^dispatch_run_id, select: d.work_item_id)

    Apiary.Dispatches.broadcast(Apiary.Dispatches.Settle.told(work_item_id))
  end

  @doc """
  Whether a member cancelled the registered run of the run of the queue `dispatch_run`
  (`Apiary.Runs.Run.cancel_requested?/1`), read without a lock.
  """
  @spec dispatch_run_cancelled?(DispatchRun.t() | Ecto.UUID.t() | nil) :: boolean
  def dispatch_run_cancelled?(%DispatchRun{id: id}), do: dispatch_run_cancelled?(id)
  def dispatch_run_cancelled?(nil), do: false

  def dispatch_run_cancelled?(id) when is_binary(id),
    do:
      Repo.exists?(
        from r in Run, where: r.dispatch_run_id == ^id and not is_nil(r.cancel_requested_at)
      )

  @doc """
  The member's cancel of the registered run of the run of the queue `dispatch_run`, read
  without a lock: the registered run, with its mark, or nil for none.
  """
  @spec cancelled_run(DispatchRun.t()) :: Run.t() | nil
  def cancelled_run(%DispatchRun{id: id}) do
    Repo.one(
      from r in Run,
        where: r.dispatch_run_id == ^id and not is_nil(r.cancel_requested_at),
        select: struct(r, [:id, :number, :cancel_requested_at, :cancel_requested_by_id])
    )
  end

  @doc """
  The name of the member who cancelled `run`, as a stored text has it, in any reader's
  words: the local part of their address, "Former member" once their account is
  deleted. Nil for a run with no mark.
  """
  @spec canceller(Run.t() | map()) :: String.t() | nil
  def canceller(%{cancel_requested_at: %DateTime{}} = run) do
    case Map.get(run, :cancel_requested_by_id) do
      nil ->
        ApiaryWeb.People.former_member()

      id ->
        id
        |> List.wrap()
        |> ApiaryWeb.People.accounts()
        |> ApiaryWeb.People.account(id)
        |> ApiaryWeb.People.short()
    end
  end

  def canceller(_run), do: nil
end
