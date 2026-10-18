defmodule Apiary.Dispatches.RunEndTest do
  # The end of a run a workspace's queue handed over (`Apiary.Dispatches.RunEnd`): by its
  # starter's outcome or its exit, by its starter's release after the handover, or by the
  # lost-run check, at its gateway's `attach_by` or at its backstop. Each ends the run of
  # the queue and its dispatch once and frees the slot once; the first end decides the
  # cause, and the registered run still takes its starter's later outcome. Runs that were
  # not handed over keep the lost-run check as it was.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun, RunEnd, Slots}
  alias Apiary.Environments.Record
  alias Apiary.Runs.{Attach, Batch, Event, Fold, Ingest, Liveness, Outcome, Projector, Run}

  @moduletag needs: :factory

  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})
  @image "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)

  setup do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{scope: scope, pool: pool, key: key}
  end

  defp handed_over!(ctx, attrs \\ %{}), do: handed_over_fixture(ctx.scope, ctx.key, attrs)

  defp queue_run!(%DispatchRun{id: id}), do: Repo.get!(DispatchRun, id)
  defp dispatch!(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)
  defp run!(%Run{id: id}), do: Repo.get!(Run, id)

  defp release(%DispatchRun{id: id}, now \\ Dispatches.now()),
    do: Repo.transact(fn -> Dispatches.end_run_released(id, now) end)

  # The run of the queue and its dispatch as an end leaves them.
  defp assert_ended(%{dispatch_run: dispatch_run, dispatch: dispatch}, cause) do
    assert %DispatchRun{state: :ended, end_cause: ^cause} = queue_run!(dispatch_run)

    assert %Dispatch{end_cause: ^cause, ended_at: %DateTime{}, slot_freed_at: %DateTime{}} =
             dispatch!(dispatch)
  end

  defp assert_live(%{dispatch_run: dispatch_run, dispatch: dispatch}) do
    assert %DispatchRun{state: :handed_over, end_cause: nil} = queue_run!(dispatch_run)
    assert %Dispatch{ended_at: nil, end_cause: nil, slot_freed_at: nil} = dispatch!(dispatch)
  end

  describe "backstop_seconds/1" do
    test "is 1200 for explore, 2100 for prebuild, and Explore's for a step it does not name" do
      assert Dispatches.backstop_seconds("explore") == 1200
      assert Dispatches.backstop_seconds("prebuild") == 2100
      assert Dispatches.backstop_seconds("another_step") == 1200
      assert Dispatches.backstop_seconds(nil) == 1200
    end
  end

  describe "the backstop" do
    test "a run beating still is lost 1200 s after its attach, and its dispatch ends lost",
         ctx do
      handed = handed_over!(ctx)
      backstop_at = handed.run.backstop_at
      assert DateTime.diff(backstop_at, handed.run.attached_at) == 1200

      # Heard a second ago, at the backstop: nothing yet.
      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [last_heartbeat_at: DateTime.add(backstop_at, -1, :second)]
      )

      assert Liveness.check(backstop_at) == []
      assert run!(handed.run).state == "running"
      assert_live(handed)

      # A microsecond after it: lost, however recently it beat.
      after_it = DateTime.add(backstop_at, 1, :microsecond)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert [%Run{state: "lost", lost_at: ^after_it}] = Liveness.check(after_it)
      assert_ended(handed, :lost)
      assert dispatch!(handed.dispatch).ended_at == after_it
      assert dispatch!(handed.dispatch).slot_freed_at == after_it
      assert Slots.held(ctx.pool.id) == 0
      assert_received {Dispatches, :changed}
    end

    test "a second check changes nothing, and frees nothing again", ctx do
      handed = handed_over!(ctx)
      first = DateTime.add(handed.run.backstop_at, 1, :second)
      Liveness.check(first)
      before = dispatch!(handed.dispatch)

      assert Liveness.check(DateTime.add(first, 60, :second)) == []
      assert dispatch!(handed.dispatch) == before
      assert queue_run!(handed.dispatch_run).end_cause == :lost
    end

    test "no heartbeat or start that arrives after it brings the run back", ctx do
      handed = handed_over!(ctx)
      lost_at = DateTime.add(handed.run.backstop_at, 1, :second)
      Liveness.check(lost_at)

      event_fixture(handed.run, 2, "run.started", started_data(),
        time: lost_at,
        received_at: DateTime.add(lost_at, 1, :second)
      )

      event_fixture(handed.run, 3, "run.heartbeat", %{"elapsed_seconds" => 1},
        time: lost_at,
        received_at: DateTime.add(lost_at, 2, :second)
      )

      assert {:ok, %Run{state: "lost", lost_at: ^lost_at}} = Projector.project(handed.run)
      assert_ended(handed, :lost)
    end

    test "a run silent and lost before it keeps that loss; its dispatch ends at the backstop",
         ctx do
      handed = handed_over!(ctx, %{last_heartbeat_at: DateTime.add(DateTime.utc_now(), -600)})
      now = DateTime.utc_now()

      assert [%Run{state: "lost"}] = Liveness.check(now)
      assert_live(handed)

      later = DateTime.add(handed.run.backstop_at, 1, :second)
      assert Liveness.check(later) == []
      assert run!(handed.run).lost_at == now
      assert_ended(handed, :lost)
    end

    test "the starter's later outcome is taken and may set the run failed; the end stays lost",
         ctx do
      handed = handed_over!(ctx)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))
      freed = dispatch!(handed.dispatch).slot_freed_at

      assert {:ok, %{run: %Run{state: "failed", lost_at: nil}, repeated: false}} =
               give_outcome(ctx.key, handed.run, "failed", "no_longer_needed")

      assert %Run{outcome_state: "failed", reason: "no_longer_needed"} = run!(handed.run)
      assert_ended(handed, :lost)
      assert dispatch!(handed.dispatch).slot_freed_at == freed
    end

    test "an exit stored before it and not yet folded ends the run as its exit", ctx do
      handed = handed_over!(ctx)
      at = DateTime.add(handed.run.backstop_at, 1, :second)

      event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0},
        time: handed.run.backstop_at,
        received_at: DateTime.add(at, -5, :second)
      )

      # The sweep projects events older than ten seconds only: this one waits.
      Liveness.check(at)
      assert_live(handed)

      assert {:ok, %Run{state: "completed"}} = Projector.project(handed.run)
      assert_ended(handed, :run_ended)
    end

    test "an exit its projection skipped unfolded ends the run as its exit, never held", ctx do
      handed = handed_over!(ctx)

      exited =
        event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

      # Marked projected as a pass that raised on it leaves it: the run never folded it.
      Repo.update_all(from(e in Event, where: e.id == ^exited.id),
        set: [projected_at: DateTime.utc_now()]
      )

      assert %Run{exited_at: nil, exit_state: nil} = run!(handed.run)

      Liveness.check(handed.run.backstop_at)
      assert_live(handed)

      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))
      assert_ended(handed, :run_ended)
      freed = dispatch!(handed.dispatch).slot_freed_at

      Liveness.check(DateTime.add(handed.run.backstop_at, 2, :second))
      assert dispatch!(handed.dispatch).slot_freed_at == freed
    end

    test "a run its gateway never attached is lost at its attach_by, and its dispatch with it",
         ctx do
      handed = handed_over!(ctx, unattached())
      attach_by = handed.run.attach_by

      assert Liveness.check(attach_by) == []
      assert_live(handed)

      after_it = DateTime.add(attach_by, 1, :microsecond)
      assert [%Run{state: "lost"}] = Liveness.check(after_it)
      assert_ended(handed, :lost)
    end

    test "a run that is not handed over keeps the lost-run check as it was", ctx do
      # Through a gateway, attached a day ago, as a run handed over would be.
      now = DateTime.utc_now()
      hand_written = run_fixture(ctx.scope, gateway_run_attrs(DateTime.add(now, -86_400)))
      assert hand_written.backstop_at == nil
      later = DateTime.add(now, 3600, :second)
      beating = DateTime.add(later, -5, :second)

      Repo.update_all(from(r in Run, where: r.id == ^hand_written.id),
        set: [last_heartbeat_at: beating]
      )

      assert Liveness.check(later) == []
      assert run!(hand_written).state == "running"

      assert [%Run{id: id}] = Liveness.check(DateTime.add(beating, 91, :second))
      assert id == hand_written.id
    end

    test "alive/2 holds a run past its backstop as not alive", ctx do
      handed = handed_over!(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [last_heartbeat_at: DateTime.add(handed.run.backstop_at, -1, :second)]
      )

      alive = fn at ->
        Repo.all(Liveness.alive(from(r in Run, as: :run, where: r.id == ^handed.run.id), at))
      end

      assert [%Run{}] = alive.(handed.run.backstop_at)
      assert alive.(DateTime.add(handed.run.backstop_at, 1, :microsecond)) == []
    end
  end

  describe "the attach" do
    # A run registered through a gateway and linked to a run of the queue handed over, as
    # its handover leaves it, before its gateway attaches it.
    setup ctx do
      gateway = gateway_fixture(ctx.scope)
      %{access_key: gateway_key} = contract_key_fixture(ctx.scope, node: gateway)
      %{access_key: node_key} = contract_key_fixture(ctx.scope)
      run_id = Ecto.UUID.generate()

      assert {:ok, %{run_key: run_key}} =
               register_run(node_key, gateway_registration(run_id), instance_id())

      work_item = work_item_fixture(ctx.scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
        set: [run_id: run_id, state: :handed_over]
      )

      Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
        set: [dispatch_run_id: queued.id]
      )

      {:ok, body} = Attach.parse(attach_body(run_key))

      %{
        gateway_key: gateway_key,
        run_id: run_id,
        body: body,
        dispatch_run: queued,
        attach: fn -> Attach.attach(gateway_key, run_id, body, %{instance_id: instance_id()}) end
      }
    end

    test "sets the backstop from the attach and the step; a run not handed over has none",
         ctx do
      assert {:ok, %{run: run}} = ctx.attach.()
      assert DateTime.diff(run.backstop_at, run.attached_at, :microsecond) == 1200 * 1_000_000

      %{access_key: node_key} = contract_key_fixture(ctx.scope)
      other = Ecto.UUID.generate()

      {:ok, %{run_key: run_key}} =
        register_run(node_key, gateway_registration(other), instance_id())

      {:ok, body} = Attach.parse(attach_body(run_key))

      assert {:ok, %{run: %Run{backstop_at: nil}}} =
               Attach.attach(ctx.gateway_key, other, body, %{})
    end

    test "is refused 410 gone once the run was released, before or after it attached", ctx do
      assert {:ok, %{run: run}} = ctx.attach.()
      assert {:ok, _released} = release(ctx.dispatch_run)

      # A repeat of the attach, by the instance that attached it.
      assert ctx.attach.() == {:error, :gone}
      assert run!(run).state == "cancelled"
    end

    test "of a run released before its gateway attached it is 410 gone", ctx do
      assert {:ok, %{run: %Run{state: "cancelled"}}} = release(ctx.dispatch_run)
      assert ctx.attach.() == {:error, :gone}
    end
  end

  describe "a prebuild after its handover" do
    # A collection, the pool's environment record of it, `env-1` queued and a good build
    # kept, and a prebuild of it queued for a pool with a gateway, claimed at revision 2,
    # said started and handed over: its registered run, its gateway not yet attached.
    setup ctx do
      place = handover_place_fixture(ctx.scope)
      collection = collection_fixture(ctx.scope)

      record =
        Repo.insert!(%Record{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          pool_id: place.pool.id,
          source_collection_id: collection.id,
          queued_ref: "env-1",
          queued_at: DateTime.utc_now(),
          image: @image,
          size: 734_003_200,
          commit: "9c1e4a7b",
          built_at: DateTime.utc_now(),
          reported_ref: "env-1"
        })

      {:ok, queued} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, place.pool, "env-1") end)

      %{dispatch: dispatch} = dispatched!(place.key, 2)

      {:ok, %{run: run, run_key: run_key}} =
        Dispatches.handover(place.key, dispatch.public_id, %{revision: 2, body: @body})

      {gateway_key, _seed} = place.gateway_key
      {:ok, body} = Attach.parse(attach_body(run_key))

      %{
        place: place,
        collection: collection,
        record: record,
        handed: %{dispatch_run: queue_run!(queued), dispatch: dispatch!(dispatch), run: run},
        attach: fn ->
          Attach.attach(gateway_key, queued.run_id, body, %{instance_id: instance_id()})
        end
      }
    end

    test "its attach sets its backstop 2100 s after it", ctx do
      assert {:ok, %{run: run}} = ctx.attach.()
      assert DateTime.diff(run.backstop_at, run.attached_at, :microsecond) == 2100 * 1_000_000
    end
  end

  describe "end_run_released/2" do
    test "records the run cancelled, released, with no outcome; the dispatch ends released",
         ctx do
      handed = handed_over!(ctx)
      now = Dispatches.now()
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert {:ok, %{run: run, changed: [workspace_id]}} = release(handed.dispatch_run, now)
      assert workspace_id == ctx.scope.workspace.id

      assert %Run{
               state: "cancelled",
               reason: "released",
               released_at: ^now,
               outcome_state: nil,
               outcome_reason: nil,
               lost_at: nil
             } = run

      assert run!(handed.run) == run
      assert_ended(handed, :released)
      assert dispatch!(handed.dispatch).slot_freed_at == now
      assert Slots.held(ctx.pool.id) == 0
      # Told by the caller once its transaction commits, not here.
      refute_received {Dispatches, :changed}
    end

    test "a second release, or one after any end, is :ended and changes nothing", ctx do
      handed = handed_over!(ctx)
      {:ok, _released} = release(handed.dispatch_run)
      before = {run!(handed.run), dispatch!(handed.dispatch)}

      assert release(handed.dispatch_run) == {:error, :ended}
      assert {run!(handed.run), dispatch!(handed.dispatch)} == before

      lost = handed_over!(ctx)
      Liveness.check(DateTime.add(lost.run.backstop_at, 1, :second))
      assert release(lost.dispatch_run) == {:error, :ended}
      assert run!(lost.run).state == "lost"
      assert_ended(lost, :lost)
    end

    test "a run waiting or claimed is :not_handed_over, an unknown one :not_found", ctx do
      work_item = work_item_fixture(ctx.scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      assert release(queued) == {:error, :not_handed_over}

      {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
      assert release(queued) == {:error, :not_handed_over}
      assert %Dispatch{ended_at: nil, slot_freed_at: nil} = dispatch!(dispatch)

      assert release(%DispatchRun{id: Ecto.UUID.generate()}) == {:error, :not_found}
    end

    test "runs only inside the caller's transaction", ctx do
      handed = handed_over!(ctx)

      assert_raise ArgumentError, fn ->
        Dispatches.end_run_released(handed.dispatch_run.id, Dispatches.now())
      end
    end

    test "the starter's later outcome is taken, never outcome_given, and may set failed",
         ctx do
      handed = handed_over!(ctx)
      {:ok, _released} = release(handed.dispatch_run)
      freed = dispatch!(handed.dispatch).slot_freed_at

      assert {:ok, %{run: %Run{state: "failed", reason: "crashed"}, repeated: false}} =
               give_outcome(ctx.key, handed.run, "failed", "crashed")

      assert %Run{outcome_state: "failed", released_at: %DateTime{}} = run!(handed.run)
      assert_ended(handed, :released)
      assert dispatch!(handed.dispatch).slot_freed_at == freed
    end

    test "the release decides over an exit, and a rebuild gives the same run", ctx do
      handed = handed_over!(ctx)
      {:ok, _released} = release(handed.dispatch_run)

      event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

      assert {:ok,
              %Run{
                state: "cancelled",
                reason: "released",
                exit_state: "completed",
                exited_at: %DateTime{}
              }} = Projector.project(handed.run)

      assert {:ok, %Run{state: "cancelled", reason: "released", released_at: %DateTime{}}} =
               Projector.rebuild(run!(handed.run))

      assert_ended(handed, :released)
    end

    test "a stale dispatch of the run ends with it, run_ended; the live one released", ctx do
      work_item = work_item_fixture(ctx.scope)
      {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      {:ok, %{dispatch: first}} = Dispatches.claim(ctx.key, Dispatches.now())

      # Its lease lapses: stale, its slot freed, and the run waits again.
      Repo.transact(fn -> {:ok, Slots.free(ctx.pool.id, first.lease_until)} end)
      assert %Dispatch{stale_at: %DateTime{}, ended_at: nil} = dispatch!(first)

      handed = handed_over(ctx.scope, ctx.key, queue_run!(queued), %{})
      first_freed = dispatch!(first).slot_freed_at

      {:ok, _released} = release(handed.dispatch_run)

      assert_ended(handed, :released)
      assert %Dispatch{end_cause: :run_ended, ended_at: %DateTime{}} = dispatch!(first)
      assert dispatch!(first).slot_freed_at == first_freed
    end

    test "after the run's exit folded, its end not yet written, is :ended and changes nothing",
         ctx do
      handed = handed_over!(ctx)

      # The projection committed the exit's fold and has not written its end yet.
      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      folded = run!(handed.run)

      assert release(handed.dispatch_run) == {:error, :ended}
      assert run!(handed.run) == folded
      assert_live(handed)

      # The end the projection writes next is the exit's, and frees the slot once.
      assert [_workspace_id] = RunEnd.run_ended(folded)
      assert_ended(handed, :run_ended)
      freed = dispatch!(handed.dispatch).slot_freed_at

      assert release(handed.dispatch_run) == {:error, :ended}
      assert RunEnd.run_ended(folded) == []
      assert Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second)) == []
      assert %Run{state: "completed", released_at: nil, reason: nil} = run!(handed.run)
      assert_ended(handed, :run_ended)
      assert dispatch!(handed.dispatch).slot_freed_at == freed
      assert Slots.held(ctx.pool.id) == 0
    end

    test "after an exit its projection skipped unfolded, is :ended and changes nothing",
         ctx do
      handed = handed_over!(ctx)

      exited =
        event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

      # Marked projected as a pass that raised on it leaves it: the run never folded it.
      Repo.update_all(from(e in Event, where: e.id == ^exited.id),
        set: [projected_at: DateTime.utc_now()]
      )

      unfolded = run!(handed.run)
      assert %Run{exited_at: nil, exit_state: nil, released_at: nil} = unfolded

      assert release(handed.dispatch_run) == {:error, :ended}
      assert run!(handed.run) == unfolded
      assert_live(handed)

      # The lost-run check ends it as its exit, as without the release, and frees the slot.
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))
      assert_ended(handed, :run_ended)
      assert %Run{released_at: nil} = run!(handed.run)
      assert Slots.held(ctx.pool.id) == 0
    end

    test "sends no end; the starter's outcome after it does", ctx do
      gateway = gateway_fixture(ctx.scope)
      %{access_key: gateway_key} = contract_key_fixture(ctx.scope, node: gateway)
      handed = handed_over!(ctx, %{gateway_id: gateway.id, gateway_instance_id: instance_id()})
      {:ok, _released} = release(handed.dispatch_run)

      batch = fn sequence ->
        {:ok, batch} =
          [
            wire_event(handed.run.node_run_id, sequence, "run.heartbeat", %{
              "elapsed_seconds" => 1
            })
          ]
          |> Jason.encode!()
          |> Batch.parse()

        Ingest.ingest(gateway_key, batch, %{contract_version: 1, instance_id: instance_id()})
      end

      assert {:ok, %{status: 202, end: nil}} = batch.(2)

      {:ok, _given} = give_outcome(ctx.key, handed.run, "failed")
      assert {:ok, %{status: 202, end: %{state: "failed", reason: nil}}} = batch.(3)
    end
  end

  describe "the run's outcome or exit" do
    test "the outcome ends the run of the queue, run_ended, and frees the slot once", ctx do
      handed = handed_over!(ctx)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert {:ok, %{repeated: false}} = give_outcome(ctx.key, handed.run, "succeeded")
      assert_ended(handed, :run_ended)
      assert_received {Dispatches, :changed}
      freed = dispatch!(handed.dispatch).slot_freed_at

      # A repeat, then the backstop and a release: nothing moves.
      assert {:ok, %{repeated: true}} = give_outcome(ctx.key, handed.run, "succeeded")
      assert Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second)) == []
      assert release(handed.dispatch_run) == {:error, :ended}
      assert_ended(handed, :run_ended)
      assert dispatch!(handed.dispatch).slot_freed_at == freed
      assert run!(handed.run).state == "completed"
    end

    test "the exit, once folded, ends it run_ended", ctx do
      handed = handed_over!(ctx)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      event_fixture(handed.run, 9, "run.exited", %{"state" => "failed", "exit_code" => 1})
      assert {:ok, %Run{state: "failed"}} = Projector.project(handed.run)

      assert_ended(handed, :run_ended)
      assert_received {Dispatches, :changed}
    end

    test "an end its projection did not write is written by the lost-run check", ctx do
      handed = handed_over!(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      Liveness.check(DateTime.utc_now())
      assert_ended(handed, :run_ended)
    end

    test "a starter's outcome that gives the reason released has it dropped" do
      body = %{"version" => 1, "time" => "2026-10-17T12:00:00Z", "state" => "cancelled"}

      assert {:ok, %Outcome{state: "cancelled", reason: nil}} =
               Outcome.parse(Map.put(body, "reason", "released"))

      assert "released" in Outcome.reserved_reasons()
    end
  end

  describe "settle/1" do
    test "a release is cancelled, released, over an exit and a loss; an outcome decides over it" do
      released = %{
        state: "completed",
        reason: nil,
        lost_at: ~U[2026-10-17 12:00:00Z],
        released_at: ~U[2026-10-17 12:00:00Z],
        outcome_state: nil,
        outcome_reason: nil
      }

      assert %{state: "cancelled", reason: "released", lost_at: nil} = Fold.settle(released)

      assert %{state: "failed", reason: "crashed"} =
               Fold.settle(%{released | outcome_state: "failed", outcome_reason: "crashed"})

      assert Fold.settle(%{released | released_at: nil}) == %{released | released_at: nil}
    end
  end

  test "the backstop's lose/1 runs nothing for a run of the queue with no registered run",
       ctx do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id),
      set: [state: :handed_over]
    )

    assert RunEnd.lose(DateTime.add(DateTime.utc_now(), 86_400, :second)) == []
    assert queue_run!(queued).state == :handed_over
  end
end
