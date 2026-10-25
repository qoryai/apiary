defmodule Apiary.Harnesses.WalkJob do
  # The harness walk of one explore run of the queue (`Apiary.Harnesses.Walk`), as the
  # instance, in the queue `harness`. `queue/2` writes the run's row of `run_harnesses`
  # (`Apiary.Harnesses.RunHarness`) in the transaction that queues the run
  # (`Apiary.Dispatches`), and the job where the run has a workflow
  # (`Apiary.Stacks.workflow_for/2`). A run with no workflow gets a row resolved with
  # origin `:none` and no job: nothing is read for it.
  #
  # The job walks the run's harness while the row is pending and the run waits, and
  # writes the result on the row, the row held `FOR UPDATE`. A walk that timed out or
  # reached no adapter is tried again after 10 seconds, then after 30; after the third
  # attempt it fails `adapter_unavailable`. A refusal is not tried again. Run twice, the
  # second finds the row no longer pending and does nothing.
  #
  # The feature is hidden from the documentation, so the module is too.
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
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{RunHarness, Walk}
  alias Apiary.Organisations.Workspace
  alias Apiary.WorkItems.WorkItem

  @doc false
  # queue/2 writes the row of `run`, a run of the queue just inserted, and its job where
  # it has a workflow, inside the caller's transaction. `target` is the work item's
  # `%{system, path}`, nil for none. `{:ok, row}` or `{:error, reason}`.
  @spec queue(DispatchRun.t(), %{system: String.t(), path: String.t()} | nil) ::
          {:ok, RunHarness.t()} | {:error, term}
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
            write(id, failed(failure, job.attempt))

          {:retry, failure} when job.attempt >= job.max_attempts ->
            write(id, failed(failure, job.attempt))

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
  # told of a walk that ended.
  defp write(id, changes) do
    Repo.transact(fn ->
      case Repo.one(
             from h in RunHarness,
               where: h.dispatch_run_id == ^id and h.state == :pending,
               lock: "FOR UPDATE"
           ) do
        nil ->
          {:ok, nil}

        row ->
          row |> Ecto.Changeset.change(changes) |> Repo.update()
      end
    end)
    |> case do
      {:ok, %RunHarness{state: state, dispatch_run_id: run_id}} when state != :pending ->
        told(run_id)

      _pending_or_gone ->
        :ok
    end
  end

  defp told(run_id) do
    case Repo.one(from r in DispatchRun, where: r.id == ^run_id, select: r.workspace_id) do
      nil -> :ok
      workspace_id -> Dispatches.broadcast([workspace_id])
    end
  end
end
