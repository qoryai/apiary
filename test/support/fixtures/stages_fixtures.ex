defmodule Apiary.StagesFixtures do
  @moduledoc """
  Work items placed by the stage runner (`Apiary.Stages`), with the workflow model on: a
  take in of a Backlog ticket, and the end of a run as its projection settles it.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Processes, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @doc "A ticket of the scope's Backlog taken in: the work item as it is after the take in."
  def taken_in_fixture(%Scope{} = scope) do
    ticket = Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    Repo.get!(WorkItem, work_item.id)
  end

  @doc """
  Gives the work item a version of its questions with one open question no other test
  asks, asked by the registered run whose number is `asked_run`, written as a member's
  action, then moves the stored copy of its file away until the test ends, as a store
  that cannot read it. Returns the stored copy's path. A question counts once the file
  can be read again where `asked_run` is a run of the work item's take in
  (`Apiary.Explore.Questions.open_in_take_in/2`, `asked_before!/1`).
  """
  def unreadable_questions!(%Scope{} = scope, %WorkItem{} = work_item, asked_run)
      when is_integer(asked_run) do
    question = %{
      "id" => "q1",
      "question" => "Which basket #{System.unique_integer([:positive])}?",
      "options" => [],
      "state" => "open",
      "asked" => %{"run" => asked_run, "at" => "2026-11-04T10:00:00Z"}
    }

    {:ok, version} =
      Apiary.Artifacts.push({:member_action, scope}, work_item, "questions", [
        Apiary.Explore.Questions.file(%{"questions" => [question]})
      ])

    [file] = version.files
    {:ok, path} = Apiary.Artifacts.open_file(file)
    File.rename!(path, path <> ".away")
    ExUnit.Callbacks.on_exit(fn -> File.rename(path <> ".away", path) end)
    path
  end

  @doc """
  Makes `dispatch_run`, the first run of its take in and not ended, the second, after
  a first run of the same take in that registered, ended by its exit and was settled,
  as after a run that asked and a send while its questions wait. Returns the number of the first run's
  registered run, the run that asked, for `unreadable_questions!/3`.
  """
  def asked_before!(%DispatchRun{attempt: 1, state: state} = dispatch_run)
      when state != :ended do
    {1, _rows} =
      Repo.update_all(from(d in DispatchRun, where: d.id == ^dispatch_run.id),
        set: [attempt: 2, of: max(dispatch_run.of, 2)]
      )

    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)

    %{run: %Run{number: number}} =
      Apiary.WorkItemsFixtures.explore_run_fixture(work_item,
        take_in: dispatch_run.take_in,
        attempt: 1
      )

    number
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

  @doc """
  The process of the scope's workspace saved with one stage, Explore, at a person's gate:
  a confirmation there finishes the work item's last stage.
  """
  def one_stage_process_fixture(%Scope{} = scope) do
    {:ok, version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          %{
            "id" => "st_r79kph11eg",
            "name" => "Explore",
            "inputs" => [],
            "sequence" => [%{"workflow" => "explore-a-ticket"}],
            "outputs" => [%{"type" => "proposal", "required" => true}],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          }
        ]
      })

    version
  end

  @doc """
  The ticket `ticket` of the scope's Backlog taken in and taken through its one stage
  (`one_stage_process_fixture/1`): the work item as it is once it finished.
  """
  def finished_fixture(%Scope{} = scope, ticket) do
    one_stage_process_fixture(scope)
    {:ok, taken} = WorkItems.take_in(scope, ticket.public_id)

    work_item =
      end_run!(Repo.get!(WorkItem, taken.id), Apiary.WorkItemsFixtures.understood_result())

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
  Ends the newest run of the work item by its exit, with `result` what the run pushed
  during the run, before it ended (`Apiary.WorkItemsFixtures.push_result!/3`, nil for
  nothing, or a function of the run of the queue and the registered run that pushes it), and the
  registered run's columns `run_changes` changes, settles it as the projection does (`Apiary.Dispatches.Settle.settle/1`)
  and tells what changed. The work item as it is after.
  """
  def end_run!(%WorkItem{} = work_item, result, run_changes \\ %{}) do
    run = newest_run(work_item)
    now = DateTime.utc_now()

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
      |> Ecto.Changeset.change(run_changes)
      |> Repo.insert!()

    # What the run pushes, it pushes while it is live (`Apiary.Artifacts.push/5` refuses a
    # run that ended); then it ends.
    cond do
      is_function(result, 2) -> result.(run, registered)
      result -> Apiary.WorkItemsFixtures.push_result!(run, registered, result)
      true -> nil
    end

    run
    |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
    |> Repo.update!()

    run.id |> Settle.settle() |> Apiary.Dispatches.broadcast()
    Repo.get!(WorkItem, work_item.id)
  end
end
