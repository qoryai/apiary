defmodule Apiary.Dispatches.SettleTest do
  # What a run of the queue gave, kept on its row (`Apiary.Dispatches.Settle`), through
  # the writers that store it: the end of the run by its outcome or its exit
  # (`Apiary.Dispatches.RunEnd`), a projection that folded an exit or a result event
  # (`Apiary.Runs.Projector`), and the sweep of the lost-run check (`Apiary.Runs.Liveness`);
  # and the handover's error (`Apiary.Dispatches.Handover`). Only a run that is not a
  # prebuild and ended `run_ended` is settled; `updated_at` never changes; a result that
  # comes later replaces what was stored; and the result kept is what the pages read once
  # the run's events are pruned.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, WorkItems}
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Runs.{Event, Liveness, Projector, Run}
  alias Apiary.WorkItems.{Confirmation, WorkItem}

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

  defp stored(handed) do
    %DispatchRun{result_outcome: outcome, result: result} = queue_run!(handed)
    {outcome, result}
  end

  defp result!(handed, sequence, document),
    do:
      result_event!(handed.run, sequence, %{
        "is_error" => false,
        "result" => Jason.encode!(document)
      })

  defp exited!(handed, sequence),
    do:
      event_fixture(handed.run, sequence, "run.exited", %{
        "state" => "succeeded",
        "exit_code" => 0
      })

  defp outcome!(ctx, handed) do
    assert {:ok, %{repeated: false}} = give_outcome(ctx.key, handed.run, "succeeded")
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
    test "the outcome first, then the exit's fold: stored by the projection, and told", ctx do
      handed = handed_over!(ctx)
      outcome!(ctx, handed)

      # Ended by its outcome, no result yet and not settled: nothing stored.
      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(handed)
      assert stored(handed) == {nil, nil}
      ended_at = queue_run!(handed).updated_at

      subscribe!(ctx)
      result!(handed, 8, understood_result())
      exited!(handed, 9)
      project!(handed)

      assert {:proposal, %{"verdict" => "understood"}} = stored(handed)
      assert queue_run!(handed).updated_at == ended_at
      public_id = work_item!(handed).public_id
      assert_receive {:work_items_changed, [^public_id]}
    end

    test "a result folded before the outcome: stored by the outcome's end", ctx do
      handed = handed_over!(ctx)
      result!(handed, 8, questions_result())
      project!(handed)
      assert stored(handed) == {nil, nil}

      outcome!(ctx, handed)
      assert {:questions, %{"questions" => ["Which basket?", "Which sale?"]}} = stored(handed)
    end

    test "the exit first: stored by its end, with no result an outcome of none", ctx do
      handed = handed_over!(ctx)
      exited!(handed, 9)
      project!(handed)

      assert %DispatchRun{end_cause: :run_ended, updated_at: ended_at} = queue_run!(handed)
      assert stored(handed) == {:none, nil}

      # The outcome that follows changes nothing of it.
      outcome!(ctx, handed)
      assert stored(handed) == {:none, nil}
      assert queue_run!(handed).updated_at == ended_at
    end

    test "the exit folded, its end not yet written: the outcome's end stores it", ctx do
      handed = handed_over!(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      outcome!(ctx, handed)
      assert stored(handed) == {:none, nil}
    end

    test "a result event that says an error, or that the check refuses", ctx do
      errored = handed_over!(ctx)
      result_event!(errored.run, 8, %{"is_error" => true, "result" => "{}"})
      exited!(errored, 9)
      project!(errored)
      assert stored(errored) == {:error, nil}

      refused = handed_over!(ctx)
      result_event!(refused.run, 8, %{"is_error" => false, "result" => "not json"})
      exited!(refused, 9)
      project!(refused)
      assert stored(refused) == {:refused, nil}
    end
  end

  describe "the sweep" do
    test "no exit: nothing until 600 s after the outcome, then the sweep stores none", ctx do
      handed = handed_over!(ctx)
      %Run{outcome_received_at: received_at} = outcome!(ctx, handed)
      ended_at = queue_run!(handed).updated_at

      assert Settle.sweep(DateTime.add(received_at, 599, :second)) == []
      assert stored(handed) == {nil, nil}

      subscribe!(ctx)
      Liveness.check(DateTime.add(received_at, 600, :second))
      assert stored(handed) == {:none, nil}
      assert queue_run!(handed).updated_at == ended_at
      public_id = work_item!(handed).public_id
      assert_receive {:work_items_changed, [^public_id]}

      # Settled, it is not read again.
      assert Settle.sweep(DateTime.add(received_at, 700, :second)) == []
    end

    test "a run lost, or whose events were pruned, is settled at once", ctx do
      lost = handed_over!(ctx)
      outcome!(ctx, lost)

      Repo.update_all(from(r in Run, where: r.id == ^lost.run.id),
        set: [state: "lost", lost_at: DateTime.utc_now()]
      )

      pruned = handed_over!(ctx)
      outcome!(ctx, pruned)
      prune!(pruned)

      assert [_, _] = Settle.sweep(Dispatches.now())
      assert stored(lost) == {:none, nil}
      assert stored(pruned) == {:none, nil}
    end
  end

  describe "what is never settled" do
    test "a prebuild, whatever ends it", ctx do
      place = handover_place_fixture(ctx.scope)
      handed = prebuild_handed_over!(ctx.scope, place.key)
      result!(handed, 8, understood_result())
      exited!(handed, 9)
      project!(handed)
      outcome!(%{ctx | key: place.key}, handed)

      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(handed)
      assert stored(handed) == {nil, nil}
      assert Settle.settle(handed.dispatch_run.id) == []
      assert Settle.sweep(DateTime.add(Dispatches.now(), 3600, :second)) == []
      assert stored(handed) == {nil, nil}
    end

    test "a run released, closed or undone, and one lost by the check", ctx do
      released = handed_over!(ctx)

      {:ok, _released} =
        Repo.transact(fn ->
          Dispatches.end_run_released(released.dispatch_run.id, Dispatches.now())
        end)

      result!(released, 8, understood_result())
      exited!(released, 9)
      project!(released)

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
            {released, :released},
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

  describe "a result that comes later" do
    test "replaces what was stored, and an error after it clears the result", ctx do
      handed = handed_over!(ctx)
      exited!(handed, 9)
      project!(handed)
      assert stored(handed) == {:none, nil}

      result!(handed, 10, understood_result())
      project!(handed)
      assert {:proposal, %{"verdict" => "understood"}} = stored(handed)

      result!(handed, 11, questions_result(["Which shelf?"]))
      project!(handed)
      assert {:questions, %{"questions" => ["Which shelf?"]}} = stored(handed)

      result_event!(handed.run, 12, %{"is_error" => true})
      project!(handed)
      assert stored(handed) == {:error, nil}
    end
  end

  describe "the result kept" do
    test "a proposal reads from the run once its events are pruned, and is confirmed", ctx do
      handed = handed_over!(ctx)
      result!(handed, 8, understood_result())
      exited!(handed, 9)
      project!(handed)
      prune!(handed)
      work_item = work_item!(handed)

      assert %{status: :confirm, run: %{place: :proposal, proposal: %{understanding: _}}} =
               WorkItems.explore(ctx.scope, work_item)

      assert [_ | _] = WorkItems.explore_thread(ctx.scope, work_item)
      assert {:ok, _confirmed} = WorkItems.confirm(ctx.scope, work_item, 1)

      assert %Confirmation{result: %{"verdict" => "understood"}} =
               Repo.get_by!(Confirmation, work_item_id: work_item.id)
    end

    test "questions read from the run once its events are pruned, and are answered", ctx do
      handed = handed_over!(ctx)
      result!(handed, 8, questions_result())
      exited!(handed, 9)
      project!(handed)
      prune!(handed)
      work_item = work_item!(handed)

      assert %{
               status: :questions,
               run: %{questions: [%{text: "Which basket?"}, %{text: "Which sale?"}]}
             } = WorkItems.explore(ctx.scope, work_item)

      assert [_ | _] = WorkItems.explore_thread(ctx.scope, work_item)

      assert {:ok, _answered} =
               WorkItems.answer(ctx.scope, work_item, 1, %{
                 "1" => "The small one.",
                 "2" => "The spring sale."
               })
    end
  end
end
