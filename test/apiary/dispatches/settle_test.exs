defmodule Apiary.Dispatches.SettleTest do
  # What a run of the queue gave, kept on its row (`Apiary.Dispatches.Settle`), read from
  # the artifacts the run pushed (`Apiary.Explore.Outcome`), through the writers that
  # store it: the end of the run by its exit, or by an outcome given before a run of the
  # queue was refused one (`Apiary.Dispatches.RunEnd`), a projection that folded an exit
  # (`Apiary.Runs.Projector`), and the sweep of the lost-run check
  # (`Apiary.Runs.Liveness`); and the handover's error (`Apiary.Dispatches.Handover`).
  # Only a run that is not a prebuild and ended `run_ended`, or `lost` with questions left
  # open, is settled; `updated_at` never changes; `result` is never written; and what the
  # pages read once the run's events are pruned comes from the artifacts.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, WorkItems}
  alias Apiary.Dispatches.{DispatchRun, RunEnd, Settle}
  alias Apiary.Runs.{Event, Liveness, Projector, Run}
  alias Apiary.WorkItems.{Confirmation, Explore, WorkItem}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{scope: scope, pool: pool, key: key}
  end

  defp handed_over!(ctx), do: handed_over_fixture(ctx.scope, ctx.key)

  defp queue_run!(%{dispatch_run: %DispatchRun{id: id}}), do: Repo.get!(DispatchRun, id)
  defp run!(%{run: %Run{id: id}}), do: Repo.get!(Run, id)
  defp work_item!(%{dispatch_run: %DispatchRun{work_item_id: id}}), do: Repo.get!(WorkItem, id)

  # What the row holds: the outcome, and `result`, which no writer writes.
  defp stored(handed) do
    %DispatchRun{result_outcome: outcome, result: result} = queue_run!(handed)
    {outcome, result}
  end

  # What the run pushes through the run API: a proposal, or questions.
  defp proposal!(handed),
    do: push_result!(queue_run!(handed), run!(handed), understood_result())

  defp questions!(handed, texts \\ ["Which basket?", "Which sale?"]),
    do: push_result!(queue_run!(handed), run!(handed), questions_result(texts))

  defp exited!(handed, sequence, state \\ "succeeded"),
    do:
      event_fixture(handed.run, sequence, "run.exited", %{
        "state" => state,
        "exit_code" => if(state == "succeeded", do: 0, else: 1)
      })

  # An outcome given before a run of the queue was refused one, as the rows written then
  # hold it: stored on the run, and the run of the queue ended `run_ended` by it in the
  # same transaction, as the outcome's write ended it then (`RunEnd.finish/5`). The pool's
  # outcome today is refused, not found.
  defp outcome!(ctx, handed) do
    assert give_outcome(ctx.key, handed.run, "succeeded") == {:error, :not_found}
    now = DateTime.utc_now()

    {:ok, changed} =
      Repo.transact(fn ->
        dispatch_run = RunEnd.lock(handed.dispatch_run.id)

        {1, _rows} =
          Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
            set: [
              outcome_state: "succeeded",
              outcome_time: DateTime.truncate(now, :second),
              outcome_received_at: now,
              outcome_digest: :crypto.hash(:sha256, "succeeded"),
              state: "completed",
              updated_at: now
            ]
          )

        run = Repo.one!(from r in Run, where: r.id == ^handed.run.id, lock: "FOR UPDATE")
        {:ok, RunEnd.finish(dispatch_run, run, :run_ended, now, nil)}
      end)

    Dispatches.broadcast(changed)
    run!(handed)
  end

  defp project!(handed), do: assert({:ok, %Run{}} = Projector.project(handed.run))

  defp subscribe!(ctx),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))

  # The run's events gone and marked so, as retention leaves them.
  defp prune!(handed) do
    Repo.delete_all(from e in Event, where: e.run_id == ^handed.run.id)

    Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
      set: [events_pruned_at: DateTime.utc_now()]
    )
  end

  describe "the end and a projection" do
    test "the outcome's end stores the proposal the run pushed, and tells", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      subscribe!(ctx)
      outcome!(ctx, handed)

      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(handed)
      assert stored(handed) == {:proposal, nil}
      public_id = work_item!(handed).public_id
      assert_receive {:work_items_changed, [^public_id]}

      # The exit's fold that follows finds it stored, and changes nothing.
      ended_at = queue_run!(handed).updated_at
      exited!(handed, 9)
      project!(handed)
      assert stored(handed) == {:proposal, nil}
      assert queue_run!(handed).updated_at == ended_at
    end

    test "the exit first: stored by its end, with no artifact an outcome of none", ctx do
      handed = handed_over!(ctx)
      exited!(handed, 9)
      project!(handed)

      assert %DispatchRun{end_cause: :run_ended, updated_at: ended_at} = queue_run!(handed)
      assert stored(handed) == {:none, nil}

      # The pool's outcome that follows is refused, and changes nothing of it.
      assert give_outcome(ctx.key, handed.run, "succeeded") == {:error, :not_found}
      assert stored(handed) == {:none, nil}
      assert queue_run!(handed).updated_at == ended_at
    end

    test "open questions come before a proposal, and before a run that failed", ctx do
      asked = handed_over!(ctx)
      proposal!(asked)
      questions!(asked)
      exited!(asked, 9)
      project!(asked)
      assert stored(asked) == {:questions, nil}

      failed = handed_over!(ctx)
      questions!(failed)
      exited!(failed, 9, "failed")
      project!(failed)
      assert stored(failed) == {:questions, nil}
    end

    test "a proposal from a run that failed: none", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      exited!(handed, 9, "failed")
      project!(handed)
      assert stored(handed) == {:none, nil}
    end

    test "a proposal of an earlier run of the take in counts; answered questions do not",
         ctx do
      handed = handed_over!(ctx)
      questions!(handed, ["Which basket?"])
      exited!(handed, 9)
      project!(handed)
      assert stored(handed) == {:questions, nil}
      work_item = work_item!(handed)

      assert {:ok, _answered} =
               WorkItems.answer(ctx.scope, work_item, 1, %{"1" => "The small one."})

      %DispatchRun{} = queued = Repo.get_by!(DispatchRun, work_item_id: work_item.id, attempt: 2)
      second = handed_over(ctx.scope, ctx.key, queued, %{})
      proposal!(second)
      exited!(second, 9)
      project!(second)
      assert stored(second) == {:proposal, nil}

      # A run of another workflow reads its artifacts itself: none.
      Repo.update_all(from(d in DispatchRun, where: d.id == ^second.dispatch_run.id),
        set: [result_outcome: nil, workflow: "review"]
      )

      assert [_] = Settle.sweep(Dispatches.now())
      assert stored(second) == {:none, nil}
    end

    test "the exit folded, its end not yet written: the outcome's end stores it", ctx do
      handed = handed_over!(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      outcome!(ctx, handed)
      assert stored(handed) == {:none, nil}
    end

    test "an answer after the run ended changes no outcome stored", ctx do
      handed = handed_over!(ctx)
      questions!(handed)
      exited!(handed, 9)
      project!(handed)
      assert stored(handed) == {:questions, nil}

      assert {:ok, _answered} =
               WorkItems.answer(ctx.scope, work_item!(handed), 1, %{
                 "1" => "The small one.",
                 "2" => "The spring sale."
               })

      # A later settle of the same run, as a projection's, reads the questions answered,
      # and keeps what the run gave.
      assert Settle.settle(handed.dispatch_run.id) == []
      assert stored(handed) == {:questions, nil}
    end
  end

  describe "the sweep" do
    test "stores what a run ended with no outcome stored gave, once, and tells", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      exited!(handed, 9)
      project!(handed)
      ended_at = queue_run!(handed).updated_at

      # A row ended before outcomes were read from artifacts, or whose settle failed.
      Repo.update_all(from(d in DispatchRun, where: d.id == ^handed.dispatch_run.id),
        set: [result_outcome: nil]
      )

      subscribe!(ctx)
      Liveness.check(Dispatches.now())
      assert stored(handed) == {:proposal, nil}
      assert queue_run!(handed).updated_at == ended_at
      public_id = work_item!(handed).public_id
      assert_receive {:work_items_changed, [^public_id]}

      # Settled, it is not read again.
      assert Settle.sweep(DateTime.add(Dispatches.now(), 700, :second)) == []
    end

    test "a run whose events were pruned is settled from its artifacts", ctx do
      handed = handed_over!(ctx)
      questions!(handed)
      outcome!(ctx, handed)
      prune!(handed)

      Repo.update_all(from(d in DispatchRun, where: d.id == ^handed.dispatch_run.id),
        set: [result_outcome: nil]
      )

      assert [_] = Settle.sweep(Dispatches.now())
      assert stored(handed) == {:questions, nil}
    end
  end

  describe "a run lost by the check" do
    test "with questions left open: stored as questions", ctx do
      handed = handed_over!(ctx)
      questions!(handed)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))

      assert %DispatchRun{end_cause: :lost, result_outcome: :questions} = queue_run!(handed)
    end

    test "with a proposal and no open question: nothing stored", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))

      assert %DispatchRun{end_cause: :lost, result_outcome: nil} = queue_run!(handed)
      assert Settle.settle(handed.dispatch_run.id) == []
    end
  end

  describe "what is never settled" do
    test "a prebuild, whatever ends it", ctx do
      place = handover_place_fixture(ctx.scope)
      handed = prebuild_handed_over!(ctx.scope, place.key)
      event_fixture(handed.run, 9, "run.exited", %{"state" => "failed", "exit_code" => 1})
      project!(handed)

      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(handed)
      assert stored(handed) == {nil, nil}
      assert Settle.settle(handed.dispatch_run.id) == []
      assert Settle.sweep(DateTime.add(Dispatches.now(), 3600, :second)) == []
      assert stored(handed) == {nil, nil}
    end

    test "a run closed or undone, and one lost by the check with nothing open", ctx do
      lost = handed_over!(ctx)
      Liveness.check(DateTime.add(lost.run.backstop_at, 1, :second))
      assert %DispatchRun{end_cause: :lost} = queue_run!(lost)

      closed = work_item_fixture(ctx.scope)
      undone = work_item_fixture(ctx.scope)

      {:ok, {closed_run, undone_run}} =
        Repo.transact(fn ->
          {:ok, closed_run} = Dispatches.queue(closed, 1)
          {:ok, undone_run} = Dispatches.queue(undone, 1)
          {:ok, _changed} = Dispatches.cancel_for_close([closed.id], Dispatches.now())
          :ok = Dispatches.cancel_for_undo(undone)
          {:ok, {closed_run, undone_run}}
        end)

      later = DateTime.add(Dispatches.now(), 3600, :second)
      assert Settle.sweep(later) == []

      for {handed, cause} <- [
            {lost, :lost},
            {%{dispatch_run: closed_run}, :closed},
            {%{dispatch_run: undone_run}, :undone}
          ] do
        assert %DispatchRun{end_cause: ^cause, result_outcome: nil, result: nil} =
                 queue_run!(handed)

        assert Settle.settle(handed.dispatch_run.id) == []
      end
    end
  end

  describe "clear/1, for a settle that failed" do
    test "clears what the row holds, and the sweep stores it again", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      exited!(handed, 9)
      project!(handed)
      assert stored(handed) == {:proposal, nil}

      subscribe!(ctx)
      assert [{:work_item, _, public_id}] = Settle.clear(handed.dispatch_run.id)
      assert public_id == work_item!(handed).public_id
      assert stored(handed) == {nil, nil}
      assert Settle.clear(handed.dispatch_run.id) == []

      assert [_] = Settle.sweep(Dispatches.now())
      assert stored(handed) == {:proposal, nil}
    end

    test "leaves a run its handover could not form as it is", ctx do
      %{dispatch_run: dispatch_run} =
        explore_run_fixture(work_item_fixture(ctx.scope), end_cause: :ticket_gone)

      assert Settle.clear(dispatch_run.id) == []
      assert %DispatchRun{result_outcome: :error} = Repo.get!(DispatchRun, dispatch_run.id)
    end
  end

  describe "what the pages read" do
    # Where the page, Explore.current/2 and the status in SQL put the run, at `at`.
    defp reads(ctx, handed, at) do
      work_item = work_item!(handed)
      page = WorkItems.explore(ctx.scope, work_item, at)

      %{
        status: Explore.current(work_item, at).status,
        page: {page.status, page.run.place, page.run.outcome},
        sql: Map.fetch!(Explore.statuses([work_item.id]), work_item.id)
      }
    end

    test "a proposal, its events pruned: the gate, and confirmed", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      exited!(handed, 9)
      project!(handed)
      prune!(handed)
      work_item = work_item!(handed)

      assert reads(ctx, handed, Dispatches.now()) == %{
               status: :confirm,
               page: {:confirm, :proposal, :proposal},
               sql: :confirm
             }

      assert %{run: %{proposal: %{message: "## What this is" <> _}}} =
               WorkItems.explore(ctx.scope, work_item)

      assert [_ | _] = WorkItems.explore_thread(ctx.scope, work_item)
      assert {:ok, _confirmed} = WorkItems.confirm(ctx.scope, work_item, 1)

      assert %Confirmation{result: %{"proposal_version" => 1}} =
               Repo.get_by!(Confirmation, work_item_id: work_item.id)
    end

    test "questions, its events pruned: the questions, and answered", ctx do
      handed = handed_over!(ctx)
      questions!(handed)
      exited!(handed, 9)
      project!(handed)
      prune!(handed)
      work_item = work_item!(handed)

      assert reads(ctx, handed, Dispatches.now()) == %{
               status: :questions,
               page: {:questions, :questions, :questions},
               sql: :questions
             }

      assert %{run: %{questions: [%{text: "Which basket?"}, %{text: "Which sale?"}]}} =
               WorkItems.explore(ctx.scope, work_item)

      assert [_ | _] = WorkItems.explore_thread(ctx.scope, work_item)

      assert {:ok, _answered} =
               WorkItems.answer(ctx.scope, work_item, 1, %{
                 "1" => "The small one.",
                 "2" => "The spring sale."
               })
    end

    test "a proposal, then the run lost: lost", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      at = DateTime.add(handed.run.backstop_at, 1, :second)
      Liveness.check(at)

      assert %DispatchRun{end_cause: :lost} = queue_run!(handed)

      assert %{stored: {nil, nil}, status: :lost, page: {:lost, :lost, nil}, sql: :lost} =
               Map.put(reads(ctx, handed, at), :stored, stored(handed))
    end
  end
end
