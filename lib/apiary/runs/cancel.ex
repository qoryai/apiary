defmodule Apiary.Runs.Cancel do
  # A member's cancel of a running run, or of a lost run that may still attach again
  # (`Apiary.Runs.cancel/2`, `cancellable?/1`): from the press, the run changes nothing
  # more.
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
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Run

  @typedoc "Why a cancel fails."
  @type refusal :: :forbidden | :not_found | :not_running

  @doc """
  Cancels `run`, of the scope's workspace, for the scope's person: `{:ok, run}` with the
  mark set, also for a run a member cancelled before, which keeps its first mark and
  writes no second entry. `{:error, :forbidden}` for a person who may not
  (`run.cancel`); `{:error, :not_found}` for a run the workspace does not have;
  `{:error, :not_running}` for a run that is neither running nor lost and not ended
  (`cancellable?/1`): queued, claimed and not started, ended, lost for good, with its exit
  or its starter's outcome; or whose run of the queue ended.
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

  # Running, or lost and not ended, as a member can cancel it (`cancellable?/1`), and its
  # run of the queue, where it has one, not ended.
  defp running?(%Run{} = run, dispatch_run),
    do: cancellable?(run) and not match?(%DispatchRun{state: :ended}, dispatch_run)

  @doc """
  Whether a member can cancel `run`, as the pages read it: running, or lost and not ended
  (`ended?/2`), so that its gateway may still attach it again; with no exit, no outcome
  and no mark. A run that waits in the queue, or that a claim registered and that has not
  started, is not running; a lost run that is lost for good has ended. `cancel/2` also
  reads its run of the queue, under the lock: the lost-run check ends that row `lost`
  only once the run is lost for good (`Apiary.Dispatches.RunEnd`), so a lost run that
  has not ended has its row still handed over.
  """
  @spec cancellable?(Run.t()) :: boolean
  def cancellable?(%Run{} = run) do
    not Run.queued?(run) and alive?(run) and is_nil(run.exited_at) and
      is_nil(run.exit_state) and is_nil(run.outcome_state) and not Run.cancel_requested?(run)
  end

  defp alive?(%Run{state: "running"}), do: true
  defp alive?(%Run{state: "lost"} = run), do: not ended?(run)
  defp alive?(%Run{}), do: false

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
  first binding, at `at`: the mark is set, no exit arrived, its events are not pruned,
  and the run has not ended (`Apiary.Runs.Run.not_ended/1`). Keep the two together: a
  test compares them on the same runs. The states a run that has not ended can have
  (pending, running or lost) are named too, so that the query can read an index on the
  state.
  """
  @spec cancelling_condition(DateTime.t()) :: Ecto.Query.dynamic_expr()
  def cancelling_condition(%DateTime{} = at) do
    Ecto.Query.dynamic(
      [run: r],
      r.state in ~w(pending running lost) and not is_nil(r.cancel_requested_at) and
        is_nil(r.exit_state) and is_nil(r.events_pruned_at) and ^Run.not_ended(at)
    )
  end

  @doc """
  Whether a run has ended at `at`, as a cancel reads it: its exit arrived, its events
  are pruned (`events_pruned_at`), so that no route serves it any more
  (`Apiary.Runs.Sender.live?/2`), or it ended by `Apiary.Runs.Run.ended?/2`, a lost run
  only once it is lost for good. A lost run that may still attach again has not ended.
  """
  @spec ended?(map, DateTime.t()) :: boolean
  def ended?(run, at \\ DateTime.utc_now())
  def ended?(%{exit_state: exit}, _at) when is_binary(exit), do: true
  def ended?(%{events_pruned_at: %DateTime{}}, _at), do: true
  def ended?(run, at), do: Run.ended?(run, at)

  @doc """
  Whether `run` writes changes that its end pushes: a run of a workspace (`workspace`)
  whose domain pushes (`Apiary.Lingo.Domain.pushes?/1`), whose access level is `write`
  (`write_access?/1`).
  """
  @spec write_run?(Workspace.t(), Run.t()) :: boolean
  def write_run?(%Workspace{} = workspace, %Run{} = run),
    do: Domain.pushes?(workspace) and write_access?(run)

  def write_run?(_workspace, _run), do: false

  @doc """
  Whether the access level of `run` is `write`, as its claim recorded it, in a workspace
  of any domain. The level is `write` where one of the run's credential entries
  (`Apiary.Runs.RunCredential`) has access `write`, which its push entry has, `read` where
  it has entries and none writes, which a run has only where its adapter declares apply
  items; else the top-level `access` of the documents the claim sent the run
  (`runs.run_documents`); else, for a run with neither, the level the claim computes
  (`Apiary.Runs.RunCredentials.run_access/1`): the level of its harness walk
  (`Apiary.Harnesses.RunHarness`) lowered by its stage entry, or for a run of a stage that
  shares one run the highest of its entries' levels (`Apiary.Stages.run_access/2`), and
  `read` for a run with no walk or with the built-in harness. False for a run with no
  dispatch run.
  """
  @spec write_access?(Run.t()) :: boolean
  def write_access?(%Run{id: run_id, dispatch_run_id: id}) when is_binary(id) do
    case recorded_access(run_id) do
      nil -> computed_access(id) == :write
      access -> access == "write"
    end
  end

  def write_access?(%Run{}), do: false

  # The run's level as its claim recorded it: `write` for a run with an entry whose access
  # is `write`, `read` for one with entries that read, else its documents' `access`; nil
  # for a run with none. A run's work entry reads at every level: only a push entry has
  # access `write`.
  defp recorded_access(run_id) do
    accesses =
      Repo.all(
        from c in Apiary.Runs.RunCredential,
          where: c.run_id == ^run_id and c.purpose in [:work, :push],
          select: c.access
      )

    cond do
      :write in accesses -> "write"
      accesses != [] -> "read"
      true -> sent_access(run_id)
    end
  end

  # Decoded here: Postgres raises an error on a JSON text with the escape of a NUL,
  # `\u0000`, in both `json` and `jsonb`, and a text of the documents may have one.
  defp sent_access(run_id) do
    documents =
      Repo.one(from r in Run, where: r.id == ^run_id, select: r.run_documents)

    with documents when is_binary(documents) <- documents,
         {:ok, %{"access" => access}} when is_binary(access) <- Jason.decode(documents) do
      access
    else
      _none -> nil
    end
  end

  defp computed_access(id) do
    case Repo.get(DispatchRun, id) do
      %DispatchRun{} = dispatch_run -> Apiary.Runs.RunCredentials.run_access(dispatch_run)
      nil -> :read
    end
  end

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
