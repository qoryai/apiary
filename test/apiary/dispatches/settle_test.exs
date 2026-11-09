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
  alias Apiary.Artifacts.ArtifactFile
  alias Apiary.Dispatches.{DispatchRun, RunEnd, Settle}
  alias Apiary.Runs.{Event, Liveness, Projector, Run}
  alias Apiary.Stages.Escalation
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

  # The verdict `escalate` of the run, with one point of `text`, as the run API stores it:
  # the version.
  defp escalate!(handed, text \\ "The ticket describes two baskets.") do
    dispatch_run = queue_run!(handed)

    {:ok, version} =
      Apiary.Stages.Artifacts.push_json(
        {:run, dispatch_run},
        work_item!(handed),
        "verdict",
        %{"verdict" => "escalate", "points" => [%{"text" => text, "action" => "run_again"}]},
        stage_id: dispatch_run.stage_id
      )

    version
  end

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

  # The stored copy of the newest questions file of the run's work item moved away until
  # the test ends, as a store that cannot read it: the stored copy's path.
  defp unreadable!(handed) do
    {version, _document} = Apiary.Explore.Questions.newest(work_item!(handed))
    [file] = version.files
    {:ok, path} = Apiary.Artifacts.open_file(file)
    File.rename!(path, path <> ".away")
    on_exit(fn -> File.rename(path <> ".away", path) end)
    path
  end

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

    test "a proposal under a name other than main: none, as Explore reads main alone", ctx do
      handed = handed_over!(ctx)
      dispatch_run = queue_run!(handed)

      {:ok, _version} =
        Apiary.Artifacts.push(
          {:run, dispatch_run},
          work_item!(handed),
          "proposal",
          [%{filename: "draft.md", content_type: "text/markdown", binary: "A draft."}],
          name: "draft",
          stage_id: dispatch_run.stage_id
        )

      exited!(handed, 9)
      project!(handed)
      assert stored(handed) == {:none, nil}
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

      # A run of another workflow, queued as such, reads its artifacts itself: none.
      Repo.update_all(from(d in DispatchRun, where: d.id == ^second.dispatch_run.id),
        set: [result_outcome: nil, workflow: "review", explore: false]
      )

      assert [_] = Settle.sweep(Dispatches.now())
      assert stored(second) == {:none, nil}
    end

    test "the verdict escalate: none, after open questions", ctx do
      escalated = handed_over!(ctx)
      proposal!(escalated)
      escalate!(escalated)
      exited!(escalated, 9)
      project!(escalated)
      assert stored(escalated) == {:none, nil}

      asked = handed_over!(ctx)
      questions!(asked)
      escalate!(asked)
      exited!(asked, 9)
      project!(asked)
      assert stored(asked) == {:questions, nil}
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

    test "a run whose newest questions cannot be read is left unset, and settled once they can",
         ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      # A question no other test asks, so no other test stores the same file.
      questions!(handed, ["Which basket #{System.unique_integer([:positive])}?"])

      {version, _document} = Apiary.Explore.Questions.newest(work_item!(handed))
      [file] = version.files
      {:ok, path} = Apiary.Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      # The end reads no open question it can trust: no proposal or none is kept for good.
      exited!(handed, 9)
      log = ExUnit.CaptureLog.capture_log(fn -> project!(handed) end)
      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(handed)
      assert stored(handed) == {nil, nil}

      assert log =~
               "run outcome not stored, newest questions unreadable " <>
                 "dispatch_run=#{handed.dispatch_run.id} " <>
                 "work_item=#{work_item!(handed).public_id} questions_version=#{version.public_id}"

      # The sweep reads it again within the hour, in the same process: no second line.
      log = ExUnit.CaptureLog.capture_log(fn -> assert Settle.sweep(Dispatches.now()) == [] end)
      refute log =~ "dispatch_run=#{handed.dispatch_run.id}"
      assert stored(handed) == {nil, nil}

      File.rename!(path <> ".away", path)
      assert [_] = Settle.sweep(Dispatches.now())
      assert stored(handed) == {:questions, nil}
      assert Apiary.Runs.StuckLog.lines() == %{}
    end

    test "a run whose verdict the store cannot read is left unset, and settled once it can",
         ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      # A point no other test writes, so no other test stores the same file.
      escalate!(handed, "Which basket #{System.unique_integer([:positive])}?")

      version = Apiary.Stages.Artifacts.newest_of_run(queue_run!(handed), "verdict", "main")
      [file] = version.files
      {:ok, path} = Apiary.Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      # The end cannot read the verdict: no proposal is kept for good.
      exited!(handed, 9)
      log = ExUnit.CaptureLog.capture_log(fn -> project!(handed) end)
      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(handed)
      assert stored(handed) == {nil, nil}

      assert log =~
               "run outcome not stored, newest verdict unreadable " <>
                 "dispatch_run=#{handed.dispatch_run.id} " <>
                 "work_item=#{work_item!(handed).public_id} verdict_version=#{version.public_id}"

      refute log =~ "newest questions unreadable"

      File.rename!(path <> ".away", path)
      assert [_] = Settle.sweep(Dispatches.now())
      assert stored(handed) == {:none, nil}
    end

    test "reads after where the sweep before stopped, so runs left unset fill no batch",
         ctx do
      # Two runs ended with questions, their outcome unset; the first by id cannot have its
      # questions read.
      [first, second] =
        [handed_over!(ctx), handed_over!(ctx)]
        |> Enum.map(fn handed ->
          questions!(handed, ["Which basket #{System.unique_integer([:positive])}?"])
          exited!(handed, 9)
          project!(handed)

          Repo.update_all(from(d in DispatchRun, where: d.id == ^handed.dispatch_run.id),
            set: [result_outcome: nil]
          )

          handed
        end)
        |> Enum.sort_by(& &1.dispatch_run.id)

      unreadable!(first)
      now = Dispatches.now()

      # One run a sweep: the first is read and stays unset.
      {result, log} = ExUnit.CaptureLog.with_log(fn -> Settle.sweep(now, nil, 1) end)
      assert {[], next} = result
      assert next == first.dispatch_run.id
      assert log =~ "dispatch_run=#{first.dispatch_run.id}"
      assert stored(first) == {nil, nil}
      assert stored(second) == {nil, nil}

      # The next sweep reads after it, and settles the second.
      assert {[_], next} = Settle.sweep(now, next, 1)
      assert next == second.dispatch_run.id
      assert stored(second) == {:questions, nil}

      # Fewer than the limit read: the sweep after starts from the first id again.
      assert {[], nil} = Settle.sweep(now, next, 1)

      # The process's tick keeps the id the sweep stopped at.
      Repo.update_all(from(d in DispatchRun, where: d.id == ^second.dispatch_run.id),
        set: [result_outcome: nil]
      )

      state = %{interval: :timer.hours(1), cursors: %{settle: first.dispatch_run.id}}
      assert {:noreply, %{cursors: %{settle: nil}}} = Liveness.handle_info(:tick, state)
      assert stored(second) == {:questions, nil}
      assert stored(first) == {nil, nil}
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

    # The stage runner reads the questions at the end (`Apiary.Stages`): it raises, the
    # end's transaction rolls back, and the next check ends the run again.
    @tag needs: [:factory, :workflow_model]
    test "with its newest questions unreadable: not ended, then ended at a check after",
         ctx do
      handed = handed_over!(ctx)
      questions!(handed, ["Which basket #{System.unique_integer([:positive])}?"])
      path = unreadable!(handed)
      lost_at = DateTime.add(handed.run.backstop_at, 1, :second)
      id = handed.dispatch_run.id

      # Two reads of the questions, one line each: Settle's, then the stage runner's.
      log = ExUnit.CaptureLog.capture_log(fn -> Liveness.check(lost_at) end)
      assert log =~ "run outcome not stored, newest questions unreadable dispatch_run=#{id} "
      assert log =~ "run end failed dispatch_run=#{id} error=Apiary.Stages.QuestionsUnreadable"
      assert %DispatchRun{state: :handed_over, result_outcome: nil} = queue_run!(handed)
      assert %WorkItem{stage_state: :running} = work_item!(handed)

      # The next tick, within the hour, reads the run again and writes neither line.
      log = ExUnit.CaptureLog.capture_log(fn -> Liveness.check(lost_at) end)
      refute log =~ "dispatch_run=#{id}"
      assert %DispatchRun{state: :handed_over} = queue_run!(handed)

      File.rename!(path <> ".away", path)
      Liveness.check(lost_at)

      assert %DispatchRun{state: :ended, end_cause: :lost, result_outcome: :questions} =
               queue_run!(handed)

      assert %WorkItem{stage_state: :waiting_answers} = work_item!(handed)
      # Ended and settled, the run is no longer kept for its lines.
      assert Apiary.Runs.StuckLog.lines() == %{}
    end

    # The stage runner reads the verdict of a run of a workflow other than Explore at its
    # exit (`Apiary.Stages`), in the transaction that ends and settles the run: it raises,
    # the exit's transaction rolls back, and the lost-run check ends the run again at each
    # tick.
    @tag needs: [:factory, :workflow_model]
    test "with its verdict unreadable: the exit not stored, then ended at a check after", ctx do
      {:ok, _version} =
        Apiary.Processes.save(ctx.scope, ctx.scope.workspace, %{
          "schema" => "qory.process/v1",
          "machine" => "default",
          "stages" => [
            %{
              "id" => "st_r79kph11eg",
              "name" => "Explore",
              "inputs" => [],
              "sequence" => [%{"workflow" => "capture-demo"}],
              "outputs" => [],
              "gate" => %{"kind" => "person", "approvers" => "members"}
            }
          ]
        })

      handed = handed_over!(ctx)
      dispatch_run = queue_run!(handed)
      assert %DispatchRun{workflow: "capture-demo", explore: false} = dispatch_run
      id = dispatch_run.id

      # A point no other test writes, so no other test stores the same file.
      text = "The demo skips step #{System.unique_integer([:positive])}."

      {:ok, version} =
        Apiary.Stages.Artifacts.push_json(
          {:run, dispatch_run},
          work_item!(handed),
          "verdict",
          %{"verdict" => "escalate", "points" => [%{"text" => text, "action" => "run_again"}]},
          stage_id: dispatch_run.stage_id
        )

      [file] = version.files
      {:ok, path} = Apiary.Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      assert_raise Apiary.Stages.VerdictUnreadable, fn -> RunEnd.run_ended(run!(handed)) end
      assert %DispatchRun{state: :handed_over, result_outcome: nil} = queue_run!(handed)
      assert %WorkItem{stage_state: :running} = work_item!(handed)

      now = Dispatches.now()
      log = ExUnit.CaptureLog.capture_log(fn -> RunEnd.lose(now) end)
      assert log =~ "run end failed dispatch_run=#{id} error=Apiary.Stages.VerdictUnreadable"
      assert %DispatchRun{state: :handed_over, result_outcome: nil} = queue_run!(handed)
      assert %WorkItem{stage_state: :running} = work_item!(handed)

      File.rename!(path <> ".away", path)
      RunEnd.lose(now)

      assert %DispatchRun{state: :ended, end_cause: :run_ended, result_outcome: :none} =
               queue_run!(handed)

      assert %WorkItem{stage_state: :escalated} = work_item!(handed)

      assert %Escalation{cause: :escalate, points: [%{"text" => ^text}]} =
               Repo.one(
                 from(e in Escalation,
                   where:
                     e.work_item_id == ^handed.dispatch_run.work_item_id and is_nil(e.resolved_at)
                 )
               )

      assert Apiary.Runs.StuckLog.lines() == %{}
    end

    # As the test before, with the verdict `passed`: once the file reads again, the stage
    # reaches its gate. Every run that passes stores the same file, so the version's row
    # points at a key the store does not have, in place of a rename of the shared file.
    @tag needs: [:factory, :workflow_model]
    test "with its verdict passed unreadable: the exit not stored, then at the gate after",
         ctx do
      {:ok, _version} =
        Apiary.Processes.save(ctx.scope, ctx.scope.workspace, %{
          "schema" => "qory.process/v1",
          "machine" => "default",
          "stages" => [
            %{
              "id" => "st_r79kph11eg",
              "name" => "Explore",
              "inputs" => [],
              "sequence" => [%{"workflow" => "capture-demo"}],
              "outputs" => [],
              "gate" => %{"kind" => "person", "approvers" => "members"}
            }
          ]
        })

      handed = handed_over!(ctx)
      dispatch_run = queue_run!(handed)
      assert %DispatchRun{workflow: "capture-demo", explore: false} = dispatch_run
      id = dispatch_run.id

      {:ok, version} =
        Apiary.Stages.Artifacts.push_json(
          {:run, dispatch_run},
          work_item!(handed),
          "verdict",
          %{"verdict" => "passed"},
          stage_id: dispatch_run.stage_id
        )

      [file] = version.files
      away = :sha256 |> :crypto.hash("away #{id}") |> Base.encode16(case: :lower)

      key = fn key ->
        Repo.update_all(from(f in ArtifactFile, where: f.id == ^file.id), set: [store_key: key])
      end

      {1, _rows} = key.(away)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      assert_raise Apiary.Stages.VerdictUnreadable, fn -> RunEnd.run_ended(run!(handed)) end
      assert %DispatchRun{state: :handed_over, result_outcome: nil} = queue_run!(handed)
      assert %WorkItem{stage_state: :running} = work_item!(handed)

      now = Dispatches.now()
      log = ExUnit.CaptureLog.capture_log(fn -> RunEnd.lose(now) end)
      assert log =~ "run end failed dispatch_run=#{id} error=Apiary.Stages.VerdictUnreadable"
      assert %DispatchRun{state: :handed_over, result_outcome: nil} = queue_run!(handed)
      assert %WorkItem{stage_state: :running} = work_item!(handed)

      {1, _rows} = key.(file.store_key)
      RunEnd.lose(now)

      assert %DispatchRun{state: :ended, end_cause: :run_ended, result_outcome: :none} =
               queue_run!(handed)

      assert %WorkItem{stage_state: :at_gate} = work_item!(handed)

      refute Repo.exists?(
               from(e in Escalation, where: e.work_item_id == ^dispatch_run.work_item_id)
             )

      assert Apiary.Runs.StuckLog.lines() == %{}
    end

    # A lost run the stage runner does not read, as its stage is not running: Settle's
    # read alone logs, and the run ends with no outcome.
    @tag needs: [:factory, :workflow_model]
    test "with its newest questions unreadable and its stage not running: ended, one line",
         ctx do
      handed = handed_over!(ctx)
      questions!(handed, ["Which basket #{System.unique_integer([:positive])}?"])
      unreadable!(handed)
      id = handed.dispatch_run.id

      Repo.update_all(from(w in WorkItem, where: w.id == ^handed.dispatch_run.work_item_id),
        set: [stage_state: :waiting_answers]
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))
        end)

      assert log =~ "run outcome not stored, newest questions unreadable dispatch_run=#{id} "
      refute log =~ "run end failed dispatch_run=#{id}"

      assert %DispatchRun{state: :ended, end_cause: :lost, result_outcome: nil} =
               queue_run!(handed)
    end

    # Runs whose end raises at every tick, more than one batch of them, keep no run after
    # them from its end: each call reads after where the call before stopped, and logs one
    # line per run it read.
    @tag needs: [:factory, :workflow_model]
    test "runs whose questions stay unreadable keep no later run from its end", ctx do
      runs =
        for _n <- 1..4 do
          handed = handed_over!(ctx)
          questions!(handed, ["Which basket #{System.unique_integer([:positive])}?"])
          handed
        end
        |> Enum.sort_by(& &1.dispatch_run.id)

      # The first three by id are stuck; the last can be ended.
      [one, two, three, last] = runs
      Enum.each([one, two, three], &unreadable!/1)
      # Past every run's deadline for its exit, so each is lost.
      lost_at =
        runs |> Enum.map(& &1.run.backstop_at) |> Enum.max(DateTime) |> DateTime.add(1, :second)

      lines = fn log, handed ->
        log
        |> String.split("run end failed dispatch_run=#{handed.dispatch_run.id}")
        |> length()
        |> Kernel.-(1)
      end

      # A batch of two: the first two, both stuck.
      {{[], next}, log} = ExUnit.CaptureLog.with_log(fn -> RunEnd.lose(lost_at, nil, 2) end)
      assert next == two.dispatch_run.id
      assert {lines.(log, one), lines.(log, two), lines.(log, three)} == {1, 1, 0}
      assert queue_run!(last).state == :handed_over

      # After them: the third, stuck, and the last, which ends.
      {{[_ | _], next_after}, log} =
        ExUnit.CaptureLog.with_log(fn -> RunEnd.lose(lost_at, next, 2) end)

      assert next_after == last.dispatch_run.id
      assert {lines.(log, three), lines.(log, last)} == {1, 0}

      assert %DispatchRun{state: :ended, end_cause: :lost, result_outcome: :questions} =
               queue_run!(last)

      # Fewer than two after the last: the next call starts from the first id again.
      assert {[], nil} = RunEnd.lose(lost_at, next_after, 2)
      assert Enum.all?([one, two, three], &(queue_run!(&1).state == :handed_over))

      # The process's tick keeps the id the call stopped at.
      state = %{interval: :timer.hours(1), cursors: %{lose: two.dispatch_run.id}}

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:noreply, %{cursors: %{lose: nil}}} = Liveness.handle_info(:tick, state)
      end)
    end

    test "with a proposal and no open question: nothing stored", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))

      assert %DispatchRun{end_cause: :lost, result_outcome: nil} = queue_run!(handed)
      assert Settle.settle(handed.dispatch_run.id) == []
    end

    test "with the verdict escalate and no open question: nothing stored", ctx do
      handed = handed_over!(ctx)
      proposal!(handed)
      escalate!(handed)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))

      assert %DispatchRun{end_cause: :lost, result_outcome: nil} = queue_run!(handed)
      assert Settle.settle(handed.dispatch_run.id) == []
      assert stored(handed) == {nil, nil}
    end
  end

  describe "what is never settled" do
    @tag needs: [:factory, :registry]
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

    test "the verdict escalate after a proposal of an earlier run: no result, no confirm",
         ctx do
      first = handed_over!(ctx)
      proposal!(first)
      questions!(first, ["Which basket?"])
      exited!(first, 9)
      project!(first)
      work_item = work_item!(first)

      assert {:ok, _answered} =
               WorkItems.answer(ctx.scope, work_item, 1, %{"1" => "The small one."})

      %DispatchRun{} = queued = Repo.get_by!(DispatchRun, work_item_id: work_item.id, attempt: 2)
      second = handed_over(ctx.scope, ctx.key, queued, %{})
      escalate!(second)
      exited!(second, 9)
      project!(second)
      assert stored(second) == {:none, nil}

      assert reads(ctx, second, Dispatches.now()) == %{
               status: :no_result,
               page: {:no_result, :no_result, :none},
               sql: :no_result
             }

      assert WorkItems.confirm(ctx.scope, work_item!(second), 2) == {:error, :not_waiting}
      refute Repo.get_by(Confirmation, work_item_id: work_item.id)
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
