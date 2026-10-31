defmodule Apiary.StagesFixtures do
  @moduledoc """
  Work items placed by the stage runner (`Apiary.Stages`), with the workflow model on: a
  take in of a Backlog ticket, and the end of a run as its projection settles it.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @doc """
  With the workflow model on, saves the workspace's process with Explore running
  `workflow` in a loop of 3 rounds, as the Workflow page's saved workflow ran before the
  process replaced it; nothing with the model off. For tests of the saved workflow that
  hold in both.
  """
  def explore_runs!(%Scope{} = scope, workflow) do
    if Apiary.Stages.on?() do
      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [%{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => workflow}]}}],
        "outputs" => [%{"type" => "proposal", "required" => true}],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      current = Apiary.Processes.current(scope.workspace)

      # Written as a save writes it, whoever the scope's person is: the test is of the
      # saved workflow, not of who may edit the process.
      if current.document != document do
        {_count, _rows} =
          Repo.update_all(
            from(v in Apiary.Processes.Version,
              where: v.workspace_id == ^scope.workspace.id and v.status == :current
            ),
            set: [status: :past, updated_at: DateTime.utc_now()]
          )

        Repo.insert!(%Apiary.Processes.Version{
          organisation_id: scope.workspace.organisation_id,
          workspace_id: scope.workspace.id,
          public_id: Apiary.PublicId.generate("pv"),
          number: current.number + 1,
          status: :current,
          document: document,
          based_on_id: current.id
        })
      end
    end

    :ok
  end

  @doc "A ticket of the scope's Backlog taken in: the work item as it is after the take in."
  def taken_in_fixture(%Scope{} = scope) do
    ticket = Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    Repo.get!(WorkItem, work_item.id)
  end

  @doc "A work item at Explore's gate: taken in, its run ended with a proposal."
  def explore_gate_fixture(%Scope{} = scope),
    do: scope |> taken_in_fixture() |> end_run!(Apiary.WorkItemsFixtures.understood_result())

  @doc "A work item at Shape's gate: Explore's proposal confirmed."
  def shape_gate_fixture(%Scope{} = scope) do
    work_item = explore_gate_fixture(scope)
    {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
    Repo.get!(WorkItem, work_item.id)
  end

  @doc "The newest run of the queue of the work item."
  def newest_run(%WorkItem{id: id}) do
    Repo.one(
      from r in DispatchRun,
        where: r.work_item_id == ^id,
        order_by: [desc: r.take_in, desc: r.attempt],
        limit: 1
    )
  end

  @doc """
  Ends the newest run of the work item by its exit, with `result` as its explore result
  (nil for none), settles it as the projection does (`Apiary.Dispatches.Settle.settle/1`)
  and tells what changed. The work item as it is after.
  """
  def end_run!(%WorkItem{} = work_item, result) do
    run = newest_run(work_item)
    now = DateTime.utc_now()

    run
    |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
    |> Repo.update!()

    registered =
      %Run{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        node_run_id: run.run_id,
        dispatch_run_id: run.id
      }
      |> Ecto.Changeset.change(%{
        state: "completed",
        exit_state: "completed",
        started_at: DateTime.add(now, -90, :second),
        exited_at: DateTime.add(now, -60, :second),
        outcome_state: "succeeded",
        outcome_time: DateTime.add(now, -60, :second),
        outcome_received_at: DateTime.add(now, -700, :second),
        outcome_digest: :crypto.strong_rand_bytes(32)
      })
      |> Repo.insert!()

    if result do
      Apiary.WorkItemsFixtures.result_event!(registered, 7, %{
        "is_error" => false,
        "result" => Jason.encode!(result)
      })
    end

    run.id |> Settle.settle() |> Apiary.Dispatches.broadcast()
    Repo.get!(WorkItem, work_item.id)
  end
end
