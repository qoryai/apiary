defmodule Apiary.RetentionResultsTest do
  # The result a run of the queue keeps (`Apiary.Dispatches.Settle`), cleared by the
  # retention job (`Apiary.Retention`) once the run registered for it is past the events
  # cut-off and its take in no longer waits for a member: answered, confirmed, declined,
  # closed, undone, or run again or taken in again. While the take in waits the result
  # stays, past the setting; the outcome stays either way, and the pages read a cleared
  # run as one whose events were pruned.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Retention, WorkItems}
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()

    Repo.update_all(from(h in Workspace, where: h.id == ^scope.workspace.id),
      set: [events_retention_days: 30]
    )

    %{scope: scope, workspace: Repo.get!(Workspace, scope.workspace.id)}
  end

  # A work item whose run gave `result`, stored, its registered run last heard `days` ago.
  defp ran!(scope, result, days \\ 60) do
    work_item = work_item_fixture(scope)
    %{dispatch_run: dispatch_run, run: run} = explore_run_fixture(work_item, result: result)
    Settle.settle(dispatch_run.id)

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [last_event_at: DateTime.add(DateTime.utc_now(), -days, :day)]
    )

    %{work_item: work_item, dispatch_run: dispatch_run}
  end

  defp prune!(workspace, opts \\ []), do: Retention.prune_workspace(workspace, opts)

  defp kept(%{dispatch_run: %DispatchRun{id: id}}) do
    %DispatchRun{result_outcome: outcome, result: result} = Repo.get!(DispatchRun, id)
    {outcome, result}
  end

  defp current(%{work_item: %WorkItem{id: id}}), do: Repo.get!(WorkItem, id)

  @answers %{"1" => "The small one.", "2" => "The spring sale."}

  test "clears the result once the take in no longer waits, for each way, the outcome kept",
       ctx do
    answered = ran!(ctx.scope, questions_result())
    {:ok, _} = WorkItems.answer(ctx.scope, current(answered), 1, @answers)

    confirmed = ran!(ctx.scope, understood_result())
    {:ok, _} = WorkItems.confirm(ctx.scope, current(confirmed), 1)

    declined = ran!(ctx.scope, questions_result())
    {:ok, _} = WorkItems.decline(ctx.scope, current(declined))

    closed = ran!(ctx.scope, understood_result())
    {:ok, _} = WorkItems.close(ctx.scope, current(closed))

    undone = ran!(ctx.scope, understood_result())
    {:ok, _} = WorkItems.undo(ctx.scope, current(undone))

    # A later run of the take in, as a run of Explore again queues it.
    run_again = ran!(ctx.scope, questions_result())
    explore_run_fixture(current(run_again), state: :waiting)

    # Taken in again: the work item's take in is later than the run's.
    taken_again = ran!(ctx.scope, understood_result())

    Repo.update_all(from(w in WorkItem, where: w.id == ^taken_again.work_item.id),
      set: [take_in: 2]
    )

    prune!(ctx.workspace)

    for {ran, outcome} <- [
          {answered, :questions},
          {confirmed, :proposal},
          {declined, :questions},
          {closed, :proposal},
          {undone, :proposal},
          {run_again, :questions},
          {taken_again, :proposal}
        ] do
      assert kept(ran) == {outcome, nil}
    end
  end

  test "an answer of the run alone, or a confirmation alone, ends the wait", ctx do
    answered = ran!(ctx.scope, questions_result())
    confirmed = ran!(ctx.scope, understood_result())
    work_item = current(answered)

    Repo.insert!(%WorkItems.Answer{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      take_in: 1,
      attempt: 1,
      position: 1,
      question: "Which basket?",
      answer: "The small one.",
      answered_at: DateTime.utc_now()
    })

    work_item = current(confirmed)

    Repo.insert!(%WorkItems.Confirmation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      take_in: 1,
      attempt: 1,
      result: understood_result(),
      confirmed_at: DateTime.utc_now()
    })

    prune!(ctx.workspace)
    assert kept(answered) == {:questions, nil}
    assert kept(confirmed) == {:proposal, nil}
  end

  test "keeps the result while the take in waits, past the setting", ctx do
    proposal = ran!(ctx.scope, understood_result())
    questions = ran!(ctx.scope, questions_result())

    # Run again after its first questions were answered: the answers of attempt 1 end the
    # wait of attempt 1 alone, and attempt 2 waits.
    again = ran!(ctx.scope, questions_result())
    work_item = current(again)
    %{dispatch_run: second, run: run} = explore_run_fixture(work_item, result: questions_result())
    Settle.settle(second.id)

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [last_event_at: DateTime.add(DateTime.utc_now(), -60, :day)]
    )

    Repo.insert!(%WorkItems.Answer{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      take_in: 1,
      attempt: 1,
      position: 1,
      question: "Which basket?",
      answer: "The small one.",
      answered_at: DateTime.utc_now()
    })

    prune!(ctx.workspace)

    assert {:proposal, %{"verdict" => "understood"}} = kept(proposal)
    assert {:questions, %{"verdict" => "not_understood"}} = kept(questions)
    assert kept(again) == {:questions, nil}
    assert {:questions, %{"verdict" => "not_understood"}} = kept(%{dispatch_run: second})

    # The pages still read them, their events pruned.
    assert %{status: :confirm} = WorkItems.explore(ctx.scope, current(proposal))
    assert %{status: :questions} = WorkItems.explore(ctx.scope, current(questions))
    assert %{status: :questions} = WorkItems.explore(ctx.scope, current(again))
  end

  test "keeps the result of a run not past the setting, without a setting, or on a dry run",
       ctx do
    recent = ran!(ctx.scope, understood_result(), 10)
    {:ok, _} = WorkItems.close(ctx.scope, current(recent))

    old = ran!(ctx.scope, understood_result())
    {:ok, _} = WorkItems.close(ctx.scope, current(old))

    prune!(ctx.workspace, dry_run: true)
    assert {:proposal, %{}} = kept(old)

    prune!(%{ctx.workspace | events_retention_days: nil})
    assert {:proposal, %{}} = kept(old)

    prune!(ctx.workspace)
    assert {:proposal, %{}} = kept(recent)
    assert kept(old) == {:proposal, nil}
  end

  test "clears across several batches, `:batch` rows at a time", ctx do
    closed =
      for _ <- 1..5 do
        ran = ran!(ctx.scope, understood_result())
        {:ok, _} = WorkItems.close(ctx.scope, current(ran))
        ran
      end

    prune!(ctx.workspace, batch: 2)
    for ran <- closed, do: assert(kept(ran) == {:proposal, nil})
  end

  test "the pages read a cleared run as one whose events were pruned", ctx do
    asked = ran!(ctx.scope, questions_result())
    {:ok, _} = WorkItems.answer(ctx.scope, current(asked), 1, @answers)

    closed = ran!(ctx.scope, understood_result())
    {:ok, _} = WorkItems.close(ctx.scope, current(closed))

    prune!(ctx.workspace)

    for ran <- [asked, closed] do
      work_item = current(ran)
      assert %{} = WorkItems.explore(ctx.scope, work_item)
      assert [_ | _] = WorkItems.explore_thread(ctx.scope, work_item)
    end

    assert %{run: %{place: :no_result, outcome: :none, proposal: nil}} =
             WorkItems.explore(ctx.scope, current(closed))
  end
end
