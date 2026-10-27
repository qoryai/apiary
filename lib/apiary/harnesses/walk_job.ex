defmodule Apiary.Harnesses.WalkJob do
  # The harness walk of one explore run of the queue (`Apiary.Harnesses.Walk`), as the
  # instance, in the queue `harness`. `queue/2` writes the run's row of `run_harnesses`
  # (`Apiary.Harnesses.RunHarness`) in the transaction that queues the run
  # (`Apiary.Dispatches`), and the job where the run has a workflow
  # (`Apiary.Stacks.workflow_for/2`). A run with no workflow gets a row resolved with
  # origin `:none` and no job: nothing is read for it. A test work item's run gets a row
  # resolved with the built-in harness (`Apiary.Harnesses.Builtin`), origin `:builtin`,
  # and no job: the workspace's levels are not read for it, and no adapter is called.
  #
  # The job walks the run's harness while the row is pending and the run waits, and
  # writes the result on the row, the row held `FOR UPDATE`. A walk that failed ends the
  # run before it starts, `harness_unresolved` (`fail/3`); a claim takes no run whose walk
  # has not resolved (`Apiary.Dispatches.waiting_query/1`). A walk that timed out or
  # reached no adapter is tried again after 10 seconds, then after 30; after the third
  # attempt it fails `adapter_unavailable`. A refusal is not tried again. A job that
  # raises is tried again, and on its last attempt it fails `walk_error` before it raises,
  # so its run ends and does not wait for ever. Run twice, the second finds the row no
  # longer pending and does nothing.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Apiary.Job,
    queue: :harness,
    max_attempts: 3,
    timeout: 120_000,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:organisation_id, :workspace_id, :dispatch_run_id]
    ]

  import Ecto.Query

  alias Apiary.{Dispatches, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Calls
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Settle}
  alias Apiary.Harnesses.{Builtin, RunHarness, Walk}
  alias Apiary.Organisations.Workspace
  alias Apiary.WorkItems.WorkItem

  @doc false
  # queue/2 writes the row of `run`, a run of the queue just inserted, and its job where
  # it has a workflow, inside the caller's transaction. `target` is the work item's
  # `%{system, path}`, nil for none, or `:test` for a test work item's run. `{:ok, row}`
  # or `{:error, reason}`.
  @spec queue(DispatchRun.t(), %{system: String.t(), path: String.t()} | nil | :test) ::
          {:ok, RunHarness.t()} | {:error, term}
  def queue(%DispatchRun{} = run, :test),
    do: Repo.insert(struct!(RunHarness, [dispatch_run_id: run.id] ++ Builtin.walked()))

  def queue(%DispatchRun{} = run, target) do
    workspace = Repo.get!(Workspace, run.workspace_id)

    case Stacks.workflow_for(workspace, target) do
      nil ->
        Repo.insert(%RunHarness{dispatch_run_id: run.id, state: :resolved, origin: :none})

      workflow ->
        with {:ok, row} <-
               Repo.insert(%RunHarness{
                 dispatch_run_id: run.id,
                 state: :pending,
                 workflow: workflow
               }),
             {:ok, _job} <-
               %{
                 "organisation_id" => run.organisation_id,
                 "workspace_id" => run.workspace_id,
                 "dispatch_run_id" => run.id
               }
               |> new()
               |> Oban.insert() do
          {:ok, row}
        end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: 1}), do: 10
  def backoff(%Oban.Job{}), do: 30

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{args: %{"dispatch_run_id" => id}} = job) do
    walk(scope, id, job)
  rescue
    exception ->
      if job.attempt >= job.max_attempts do
        failure = %{failure: :walk_error, source: nil, rule: nil, adapter: nil, call_failure: nil}
        fail(id, failure, job.attempt)
      end

      reraise exception, __STACKTRACE__
  end

  defp walk(scope, id, job) do
    case pending(id) do
      nil ->
        :ok

      {row, target} ->
        input = %{
          organisation: scope.organisation,
          workspace: scope.workspace,
          target: target,
          workflow: row.workflow
        }

        case Walk.run(input) do
          {:ok, walked} ->
            write(id, resolved(walked, job.attempt))

          {:failed, failure} ->
            fail(id, failure, job.attempt)

          {:retry, failure} when job.attempt >= job.max_attempts ->
            fail(id, failure, job.attempt)

          {:retry, _failure} ->
            write(id, attempts: job.attempt)
            {:error, :adapter_unavailable}
        end
    end
  end

  # The pending row of the run `id` while the run waits, and the run's target; nil for
  # none.
  defp pending(id) do
    Repo.one(
      from h in RunHarness,
        join: r in DispatchRun,
        on: r.id == h.dispatch_run_id,
        join: w in WorkItem,
        on: w.id == r.work_item_id,
        where: h.dispatch_run_id == ^id and h.state == :pending and r.state == :waiting,
        select: {h, %{system: w.target_system, path: w.target_path}}
    )
    |> case do
      {row, %{system: system, path: path} = target} when is_binary(system) and is_binary(path) ->
        {row, target}

      {row, _no_target} ->
        {row, nil}

      nil ->
        nil
    end
  end

  defp resolved(walked, attempt) do
    [
      state: :resolved,
      origin: walked.origin,
      access_level: walked.access_level,
      target_version: walked.target_version,
      document: walked.document,
      stack_id: walked.stack_id,
      owner_organisation_id: walked.owner_organisation_id,
      harness_hidden: walked.harness_hidden,
      pins: walked.pins,
      harness_links: walked.harness_links,
      attempts: attempt
    ]
  end

  defp failed(failure, attempt) do
    [
      state: :failed,
      failure: to_string(failure.failure),
      failed_source: failure.source,
      failure_rule: failure.rule,
      failure_adapter: failure.adapter,
      attempts: attempt
    ]
  end

  # `changes` on the run's row, held `FOR UPDATE`, while it is pending; the workspace is
  # told of a walk that resolved.
  defp write(id, changes) do
    Repo.transact(fn ->
      case pending_row(id) do
        nil -> {:ok, nil}
        row -> row |> Ecto.Changeset.change(changes) |> Repo.update()
      end
    end)
    |> case do
      {:ok, %RunHarness{state: :resolved, dispatch_run_id: run_id}} ->
        case Repo.one(from r in DispatchRun, where: r.id == ^run_id, select: r.workspace_id) do
          nil -> :ok
          workspace_id -> Dispatches.broadcast([workspace_id])
        end

      _pending_or_gone ->
        :ok
    end
  end

  # The walk failed: its row written failed and, while the run waits, the run ended
  # `harness_unresolved` with the outcome `error` and the failure code as `end_detail`,
  # with any stale dispatch of it (`run_ended`), and the call it stopped at
  # (`Apiary.Adapters.Calls.record_failure/3`), in one transaction that holds the run,
  # then the row, `FOR UPDATE`. The workspace and the work item are told.
  defp fail(id, failure, attempt) do
    now = DateTime.utc_now()

    Repo.transact(fn ->
      run = Repo.one(from r in DispatchRun, where: r.id == ^id, lock: "FOR UPDATE")

      case {run, pending_row(id)} do
        {%DispatchRun{} = run, %RunHarness{} = row} ->
          {:ok, _row} = row |> Ecto.Changeset.change(failed(failure, attempt)) |> Repo.update()
          {:ok, end_run(run, failure, now)}

        _gone ->
          {:ok, []}
      end
    end)
    |> case do
      {:ok, told} -> Dispatches.broadcast(told)
    end
  end

  defp end_run(%DispatchRun{state: :waiting} = run, failure, now) do
    {:ok, _run} =
      run
      |> Ecto.Changeset.change(
        state: :ended,
        end_cause: :harness_unresolved,
        end_detail: to_string(failure.failure),
        result_outcome: :error,
        updated_at: now
      )
      |> Repo.update()

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^run.id,
          where: not is_nil(d.stale_at) and is_nil(d.ended_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    if failure.call_failure, do: :ok = Calls.record_failure(Repo, run, failure.call_failure)

    [run.workspace_id | Settle.told(run.work_item_id)]
  end

  # A run that no longer waits keeps its end; only its row records the failure.
  defp end_run(%DispatchRun{workspace_id: workspace_id}, _failure, _now), do: [workspace_id]

  defp pending_row(id) do
    Repo.one(
      from h in RunHarness,
        where: h.dispatch_run_id == ^id and h.state == :pending,
        lock: "FOR UPDATE"
    )
  end
end
