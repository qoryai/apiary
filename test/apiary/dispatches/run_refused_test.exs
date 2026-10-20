defmodule Apiary.Dispatches.RunRefusedTest do
  # The end of a run of the queue by its gateway's refusal (`dev.qory.run.refused`,
  # `Apiary.Dispatches.RunEnd.refused/1`): the first refusal folded ends the run
  # `run_refused` and keeps its code as `end_detail`, the run is not queued again, a
  # refusal after any other end changes nothing, and every other end keeps its cause.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, WorkItems}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunEnd, Slots}
  alias Apiary.Runs.{Liveness, Projector, Run}

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # A work item with its run queued, then claimed and handed over.
  defp handed_over!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = dispatched!(ctx.key)

    assert {:ok, %{run: run}} = Dispatches.handover(ctx.key, dispatch.public_id, %{body: @body})
    %{work_item: work_item, queued: queued, dispatch: dispatch, run: run}
  end

  defp refuse!(run, code, sequence \\ 1),
    do: event_fixture(run, sequence, "run.refused", %{"code" => code, "names" => ["MODEL_KEY"]})

  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp run!(%Run{id: id}), do: Repo.get!(Run, id)

  defp runs_of(%{id: id}),
    do: Repo.all(from r in DispatchRun, where: r.work_item_id == ^id, order_by: r.attempt)

  defp assert_ended(handed, cause, detail \\ nil) do
    assert %DispatchRun{state: :ended, end_cause: ^cause, end_detail: ^detail} =
             queue_run!(handed.queued)

    assert %Dispatch{end_cause: ^cause, ended_at: %DateTime{}, slot_freed_at: %DateTime{}} =
             dispatch!(handed.dispatch)
  end

  describe "the first refusal" do
    test "ends the run of the queue and its dispatch run_refused, with the code as detail",
         ctx do
      handed = handed_over!(ctx)
      assert Slots.held(ctx.pool.id) == 1
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)
      :ok = WorkItems.subscribe(ctx.scope)

      refuse!(handed.run, "model_key_missing")

      assert {:ok, %Run{state: "failed", reason: "model_key_missing"}} =
               Projector.project(handed.run)

      assert_ended(handed, :run_refused, "model_key_missing")
      assert Slots.held(ctx.pool.id) == 0
      assert %DispatchRun{result_outcome: nil, result: nil} = queue_run!(handed.queued)
      assert_received {Dispatches, :changed}

      public_id = handed.work_item.public_id
      assert_received {:work_items_changed, [^public_id]}
    end

    test "is not queued again: the starter's release finds it gone, nothing waits, nothing is claimed",
         ctx do
      handed = handed_over!(ctx)
      refuse!(handed.run, "image_user_root")
      {:ok, _run} = Projector.project(handed.run)

      assert {:error, :gone} =
               Dispatches.release(ctx.key, handed.dispatch.public_id, %{
                 reason: "The job could not start.",
                 retry: true
               })

      assert [%DispatchRun{attempt: 1, end_cause: :run_refused}] = runs_of(handed.work_item)
      assert {:ok, :none} = Dispatches.claim(ctx.key, Dispatches.now())
      assert Slots.held(ctx.pool.id) == 0
    end

    test "is ended by the lost-run check when the end after the projection did not run", ctx do
      handed = handed_over!(ctx)
      now = Dispatches.now()

      # The pass committed the refusal on the run; the end that follows it never ran.
      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "failed", reason: "mount_mode_conflict", refused_at: now]
      )

      assert_live(handed)
      Liveness.check(now)
      assert_ended(handed, :run_refused, "mount_mode_conflict")
      assert Liveness.check(DateTime.add(now, 60, :second)) == []
    end

    test "folded and not yet ended, is not queued again by the starter's release", ctx do
      handed = handed_over!(ctx)
      now = Dispatches.now()

      # The pass committed the refusal on the run; the end that follows it has not run yet.
      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "failed", reason: "model_key_missing", refused_at: now]
      )

      assert {:error, :gone} =
               Dispatches.release(ctx.key, handed.dispatch.public_id, %{
                 reason: "The job could not start.",
                 retry: true
               })

      assert_live(handed)
      Liveness.check(now)
      assert_ended(handed, :run_refused, "model_key_missing")
      assert [%DispatchRun{attempt: 1, end_cause: :run_refused}] = runs_of(handed.work_item)
    end

    test "keeps the code when the starter's outcome later replaces the run's reason", ctx do
      handed = handed_over!(ctx)
      refuse!(handed.run, "variable_reserved")
      {:ok, _run} = Projector.project(handed.run)

      assert {:ok, %{run: %Run{state: "failed"}}} =
               give_outcome(ctx.key, handed.run, "failed", "job_failed")

      assert %Run{reason: "job_failed", refused_at: %DateTime{}} = run!(handed.run)
      assert_ended(handed, :run_refused, "variable_reserved")
    end

    test "of a run with no valid code ends it with no detail", ctx do
      handed = handed_over!(ctx)
      refuse!(handed.run, "Not A Code")
      {:ok, _run} = Projector.project(handed.run)

      assert_ended(handed, :run_refused, nil)
    end

    test "of a prebuild ends nothing of the queue", ctx do
      handed = prebuild_handed_over!(ctx.scope, ctx.key)
      refuse!(handed.run, "model_key_missing")
      {:ok, _run} = Projector.project(handed.run)

      assert %DispatchRun{state: :handed_over, end_cause: nil, end_detail: nil} =
               queue_run!(handed.dispatch_run)

      assert [] = RunEnd.refused(run!(handed.run))
      assert %DispatchRun{state: :handed_over} = queue_run!(handed.dispatch_run)
    end
  end

  describe "a refusal after the end" do
    test "of a release changes nothing, and the run queued next stays waiting", ctx do
      handed = handed_over!(ctx)

      assert :ok =
               Dispatches.release(ctx.key, handed.dispatch.public_id, %{
                 reason: "The job could not start.",
                 retry: true
               })

      assert [_first, %DispatchRun{state: :waiting, attempt: 2} = next] =
               runs_of(handed.work_item)

      before = dispatch!(handed.dispatch)

      refuse!(handed.run, "model_key_missing")
      {:ok, _run} = Projector.project(handed.run)

      assert_ended(handed, :released)
      assert dispatch!(handed.dispatch) == before
      assert queue_run!(next).state == :waiting
      assert length(runs_of(handed.work_item)) == 2
    end

    test "of an outcome changes nothing: the run stays ended run_ended", ctx do
      handed = handed_over!(ctx)
      assert {:ok, _given} = give_outcome(ctx.key, handed.run, "succeeded")
      assert_ended(handed, :run_ended)

      refuse!(handed.run, "model_key_missing")
      {:ok, _run} = Projector.project(handed.run)

      assert_ended(handed, :run_ended)
    end

    test "of a second refusal changes nothing", ctx do
      handed = handed_over!(ctx)
      refuse!(handed.run, "image_user_root")
      {:ok, _run} = Projector.project(handed.run)
      before = {queue_run!(handed.queued), dispatch!(handed.dispatch)}

      refuse!(handed.run, "model_key_missing", 2)
      {:ok, _run} = Projector.project(handed.run)

      assert {queue_run!(handed.queued), dispatch!(handed.dispatch)} == before
      assert_ended(handed, :run_refused, "image_user_root")
    end

    test "with an exit in the same pass is decided by the exit: run_ended", ctx do
      handed = handed_over!(ctx)
      refuse!(handed.run, "model_key_missing", 1)
      event_fixture(handed.run, 2, "run.exited", %{"state" => "failed", "exit_code" => 1})

      assert {:ok, %Run{refused_at: nil, exited_at: %DateTime{}}} = Projector.project(handed.run)
      assert_ended(handed, :run_ended)
    end
  end

  describe "every other end" do
    test "a run that fails after it started ends run_ended", ctx do
      handed = handed_over!(ctx)
      event_fixture(handed.run, 1, "run.started", started_data())

      event_fixture(handed.run, 2, "run.exited", %{
        "state" => "failed",
        "reason" => "runtime_failed",
        "exit_code" => 1
      })

      assert {:ok, %Run{state: "failed", refused_at: nil}} = Projector.project(handed.run)
      assert_ended(handed, :run_ended)
    end

    test "a run cancelled by its starter's outcome ends run_ended", ctx do
      handed = handed_over!(ctx)
      assert {:ok, _given} = give_outcome(ctx.key, handed.run, "cancelled", "stopped")
      assert_ended(handed, :run_ended)
    end

    test "a lost run ends lost", ctx do
      handed = handed_over_fixture(ctx.scope, ctx.key)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))

      assert %DispatchRun{state: :ended, end_cause: :lost, end_detail: nil} =
               queue_run!(handed.dispatch_run)

      assert %Dispatch{end_cause: :lost} = dispatch!(handed.dispatch)
    end

    test "a run released by its starter ends released", ctx do
      handed = handed_over!(ctx)

      assert :ok =
               Dispatches.release(ctx.key, handed.dispatch.public_id, %{
                 reason: "The job could not start.",
                 retry: false
               })

      assert_ended(handed, :released)
    end
  end

  defp assert_live(handed) do
    assert %DispatchRun{state: :handed_over, end_cause: nil, end_detail: nil} =
             queue_run!(handed.queued)

    assert %Dispatch{ended_at: nil, end_cause: nil} = dispatch!(handed.dispatch)
  end
end
