defmodule Apiary.WorkItems.OpenQuestionsTakeInTest do
  # The open questions that count for Explore are those of the current take in
  # (`Apiary.Explore.Questions.open_in_take_in/2`): a question left open in an earlier
  # take in stays open in the work item's one questions document, and counts neither at a
  # run's end (`Apiary.Explore.Outcome`, `Apiary.Stages`), for a run ended by its exit or
  # lost, nor for the answers by position or by id (`Apiary.WorkItems.answer/4`). One
  # that a run of the current take in reopened counts.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Dispatches.{DispatchRun, RunEnd}
  alias Apiary.Explore.Questions
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  @at "2026-11-04T10:00:00Z"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  # The questions of the newest version, by id: `{state, answer}`.
  defp states(work_item) do
    {_version, document} = Questions.newest(reload(work_item))
    Map.new(document["questions"], &{&1["id"], {&1["state"], &1["answer"]}})
  end

  # Take in 1's first run asks `asked`, then `answer`, if given, answers by position at
  # it; the work item is closed and taken in again. The work item in take in 2, its first
  # run queued.
  defp again!(scope, asked, answer \\ nil) do
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    work_item = work_item |> reload() |> end_run!(questions_result(asked))

    if answer do
      {:ok, _} = WorkItems.answer(scope, work_item, 1, answer)
      # The answer queued run 2 of take in 1; it ends with no result.
      end_run!(reload(work_item), nil)
    end

    {:ok, _closed} = WorkItems.close(scope, reload(work_item))

    {:ok, _again} =
      WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

    work_item = reload(work_item)
    assert work_item.take_in == 2
    work_item
  end

  describe "a run's end" do
    test "a proposal of take in 2 goes to the gate while take in 1's question stays open",
         %{scope: scope} do
      work_item = again!(scope, ["Which basket?"]) |> end_run!(understood_result())

      assert %{"q1" => {"open", nil}} = states(work_item)
      assert %DispatchRun{take_in: 2, result_outcome: :proposal} = newest_run(work_item)
      assert work_item.stage_state == :at_gate
      assert %{take_in: 2, status: :confirm} = WorkItems.explore(scope, work_item)
      assert {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
    end

    test "a question of take in 2 waits beside take in 1's", %{scope: scope} do
      work_item = again!(scope, ["Which basket?"]) |> end_run!(questions_result(["Which sale?"]))

      assert %DispatchRun{take_in: 2, result_outcome: :questions} = newest_run(work_item)
      assert work_item.stage_state == :waiting_answers
      assert %{status: :questions} = WorkItems.explore(scope, work_item)
    end

    test "a question of take in 1 that a run of take in 2 reopened counts", %{scope: scope} do
      work_item = again!(scope, ["Which basket?"], %{"1" => "The main one"})
      assert %{"q1" => {"answered", %{"option" => nil}}} = states(work_item)

      work_item =
        end_run!(work_item, fn run, registered ->
          push_result!(run, registered, understood_result())
          reopen!(run, registered, "q1")
        end)

      assert %DispatchRun{take_in: 2, result_outcome: :questions} = newest_run(work_item)
      assert work_item.stage_state == :waiting_answers
      assert %{status: :questions} = WorkItems.explore(scope, work_item)

      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The other one"})

      assert %{"q1" => {"answered", %{"note" => "The other one"}}} = states(work_item)
    end

    test "a lost run of take in 2 reads by the same rule", %{scope: scope} do
      # Take in 1's question alone is open: the lost run stores no outcome, and escalates
      # as a lost run.
      work_item = again!(scope, ["Which basket?"]) |> lose_run!(understood_result())

      assert %DispatchRun{take_in: 2, end_cause: :lost, result_outcome: nil} =
               newest_run(work_item)

      assert work_item.stage_state == :escalated

      # A question of take in 2 left open: stored as questions, and the stage waits.
      work_item = again!(scope, ["Which basket?"]) |> lose_run!(questions_result(["Which sale?"]))

      assert %DispatchRun{take_in: 2, end_cause: :lost, result_outcome: :questions} =
               newest_run(work_item)

      assert work_item.stage_state == :waiting_answers
    end
  end

  describe "an answer" do
    test "by position answers the open questions of take in 2 alone", %{scope: scope} do
      work_item = again!(scope, ["Which basket?"]) |> end_run!(questions_result(["Which sale?"]))

      # Position 1 is take in 2's q2; there is no position 2.
      assert WorkItems.answer(scope, work_item, 1, %{"2" => "Spring"}) ==
               {:error, {:invalid, :form}}

      assert {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "Spring"})

      assert %{"q1" => {"open", nil}, "q2" => {"answered", %{"note" => "Spring"}}} =
               states(work_item)
    end

    test "by id refuses take in 1's open question as one that is not open", %{scope: scope} do
      work_item = again!(scope, ["Which basket?"]) |> end_run!(questions_result(["Which sale?"]))

      assert WorkItems.answer(scope, work_item, 1, [%{"id" => "q1", "note" => "The main one"}]) ==
               {:error, {:invalid, %{"q1" => :not_open}}}

      assert WorkItems.answer(scope, work_item, 1, [
               %{"id" => "q1", "note" => "The main one"},
               %{"id" => "q2", "note" => "Spring"}
             ]) == {:error, {:invalid, %{"q1" => :not_open}}}

      assert %{"q1" => {"open", nil}, "q2" => {"open", nil}} = states(work_item)

      assert {:ok, _} =
               WorkItems.answer(scope, work_item, 1, [%{"id" => "q2", "note" => "Spring"}])

      assert %{"q1" => {"open", nil}, "q2" => {"answered", %{"note" => "Spring"}}} =
               states(work_item)
    end
  end

  # Pushes, as the run `registered` of the run of the queue `run`, the newest questions
  # with the answered question `id` reopened by the run: its answer moved to the end of
  # its history.
  defp reopen!(%DispatchRun{} = run, %Run{} = registered, id) do
    work_item = Repo.get!(WorkItem, run.work_item_id)
    {_version, document} = Questions.newest(work_item)

    questions =
      Enum.map(document["questions"], fn
        %{"id" => ^id, "answer" => answer} = question ->
          reopened = Map.put(answer, "reopened", %{"run" => registered.number, "at" => @at})

          question
          |> Map.delete("answer")
          |> Map.put("state", "open")
          |> Map.put("history", (question["history"] || []) ++ [reopened])

        question ->
          question
      end)

    {:ok, _version} =
      Apiary.Artifacts.push(
        {:run, run},
        work_item,
        "questions",
        [Questions.file(%{"questions" => questions})],
        name: "main",
        stage_id: run.stage_id
      )
  end

  # The newest run of the work item, handed over and registered, pushes `result`, then is
  # lost, as the lost-run check ends it (`Apiary.Dispatches.RunEnd.finish/5`). The work
  # item as it is after.
  defp lose_run!(%WorkItem{} = work_item, result) do
    run =
      work_item
      |> newest_run()
      |> Ecto.Changeset.change(state: :handed_over)
      |> Repo.update!()

    now = DateTime.utc_now()

    registered =
      %Run{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        node_run_id: run.run_id,
        dispatch_run_id: run.id
      }
      |> Ecto.Changeset.change(state: "running", started_at: DateTime.add(now, -30, :second))
      |> Repo.insert!()

    push_result!(run, registered, result)

    {:ok, _told} =
      Repo.transact(fn ->
        :ok = Apiary.Stages.hold_work_item(run.id)
        held = RunEnd.lock(run.id)
        registered = Repo.one(from r in Run, where: r.id == ^registered.id, lock: "FOR UPDATE")
        {:ok, RunEnd.finish(held, registered, :lost, now, nil)}
      end)

    reload(work_item)
  end
end
