defmodule Apiary.Dispatches.RunEndTest do
  # The end of a run a workspace's queue handed over (`Apiary.Dispatches.RunEnd`): by its
  # exit, whatever its state, or by the lost-run check, at its
  # gateway's `attach_by` or at its backstop. Each ends the run of the queue and its
  # dispatch once and frees the slot once; the first end decides the cause. The pool's
  # outcome is refused, not found, and ends nothing. Runs that were not handed over keep
  # the lost-run check as it was.
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
  alias Apiary.Runs.{Attach, Event, Fold, Liveness, Outcome, Projector, Run}

  @moduletag needs: :factory

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
  defp record!(%Record{id: id}), do: Repo.get!(Record, id)

  # The last good build and what was queued, as the setup kept them.
  defp assert_build_kept(%{record: record}) do
    kept = [:image, :size, :commit, :built_at, :reported_ref, :queued_ref, :queued_at]
    assert Map.take(record!(record), kept) == Map.take(record, kept)
    assert record!(record).retired_at == nil
  end

  # No run of the queue for the collection but the prebuild that was handed over.
  defp assert_nothing_queued(%{collection: collection, handed: handed}) do
    assert Repo.all(
             from r in DispatchRun, where: r.source_collection_id == ^collection.id, select: r.id
           ) == [handed.dispatch_run.id]
  end

  # The registered run of `dispatch_run` cancelled, `released`, as a release after the
  # handover recorded it before such a release was refused `machine_exists`.
  defp released_before!(%DispatchRun{id: id}) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.dispatch_run_id == ^id),
        set: [released_at: Dispatches.now(), state: "cancelled", reason: "released"]
      )
  end

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

    test "the pool's outcome after the loss is refused, not found, and changes nothing", ctx do
      handed = handed_over!(ctx)
      Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second))
      lost = run!(handed.run)

      assert give_outcome(ctx.key, handed.run, "failed", "no_longer_needed") ==
               {:error, :not_found}

      assert run!(handed.run) == lost
      assert_ended(handed, :lost)
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
      released_before!(ctx.dispatch_run)

      # A repeat of the attach, by the instance that attached it.
      assert ctx.attach.() == {:error, :gone}
      assert run!(run).state == "cancelled"
    end

    test "of a run released before its gateway attached it is 410 gone", ctx do
      released_before!(ctx.dispatch_run)
      assert ctx.attach.() == {:error, :gone}
    end
  end

  describe "a prebuild after its handover" do
    # A collection, the pool's environment record of it, `env-1` queued and a good build
    # kept, and a prebuild of it queued for a pool with a gateway, claimed, said started
    # and handed over: its registered run, its gateway not yet attached.
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

      %{dispatch: dispatch, registered: run, run_code: code} = dispatched!(place.key)
      run_key = redeemed_run_key!(code)
      run = Repo.get!(Run, run.id)

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

    test "lost at its run key's attach_by records the build failed, lost, and queues nothing",
         ctx do
      attach_by = ctx.handed.run.attach_by

      assert Liveness.check(attach_by) == []
      assert_live(ctx.handed)
      assert record!(ctx.record) == ctx.record

      after_it = DateTime.add(attach_by, 1, :microsecond)
      assert [%Run{state: "lost"}] = Liveness.check(after_it)
      assert_ended(ctx.handed, :lost)

      assert %Record{failure_cause: :lost, failure_reason: nil, failed_at: ^after_it} =
               record!(ctx.record)

      assert_build_kept(ctx)
      assert_nothing_queued(ctx)
    end

    test "ended by its backstop records the build failed, timed_out, and queues nothing", ctx do
      # A release failed the build before: its reason goes with the new failure.
      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.id == ^ctx.record.id),
          set: [
            failure_cause: :released,
            failure_reason: "The job could not start.",
            failed_at: DateTime.utc_now()
          ]
        )

      assert {:ok, %{run: run}} = ctx.attach.()
      failed = record!(ctx.record)

      # Silent since its attach, the registered run is lost by the liveness rules at its
      # backstop; the run of the queue waits for the backstop to pass.
      Liveness.check(run.backstop_at)
      assert_live(ctx.handed)
      assert record!(ctx.record) == failed

      after_it = DateTime.add(run.backstop_at, 1, :microsecond)
      Liveness.check(after_it)
      assert_ended(ctx.handed, :lost)

      assert %Record{failure_cause: :timed_out, failure_reason: nil, failed_at: ^after_it} =
               record!(ctx.record)

      assert_build_kept(ctx)
      assert_nothing_queued(ctx)

      # A second check changes nothing.
      ended = record!(ctx.record)
      assert Liveness.check(DateTime.add(after_it, 60, :second)) == []
      assert record!(ctx.record) == ended
    end

    # Its fetch's exit, stored and folded onto the registered run.
    defp exited!(ctx) do
      event_fixture(ctx.handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})

      assert {:ok, %Run{state: "completed", exited_at: %DateTime{}}} =
               Projector.project(ctx.handed.run)
    end

    # Its exit with `data`, stored and folded onto the registered run.
    defp exited!(ctx, data) do
      event_fixture(ctx.handed.run, 9, "run.exited", data)
      assert {:ok, %Run{exited_at: %DateTime{}} = run} = Projector.project(ctx.handed.run)
      run
    end

    for {state, data} <- [
          {"failed", %{"state" => "failed", "exit_code" => 1}},
          {"lost", %{"state" => "failed", "reason" => "session_lost"}}
        ] do
      test "its #{state} exit, once folded, ends it run_ended and records the build failed, #{state}",
           ctx do
        assert {:ok, %{run: _run}} = ctx.attach.()
        assert %Run{exit_state: unquote(state)} = exited!(ctx, unquote(Macro.escape(data)))
        assert_ended(ctx.handed, :run_ended)
        cause = String.to_existing_atom(unquote(state))

        assert %Record{failure_cause: ^cause, failure_reason: nil, failed_at: %DateTime{}} =
                 failed = record!(ctx.record)

        assert_build_kept(ctx)
        assert_nothing_queued(ctx)
        assert Slots.held(ctx.place.pool.id) == 0

        # The lost-run check changes nothing of the queue or the record, and the pool's
        # outcome is refused.
        assert Liveness.check(DateTime.add(ctx.handed.run.attach_by, 3600, :second)) == []
        assert give_outcome(ctx.place.key, ctx.handed.run, "failed") == {:error, :not_found}
        assert_ended(ctx.handed, :run_ended)
        assert record!(ctx.record) == failed
      end
    end

    test "its cancelled exit ends it run_ended and records no failure", ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()
      assert %Run{exit_state: "cancelled"} = exited!(ctx, %{"state" => "cancelled"})
      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == ctx.record
      assert Slots.held(ctx.place.pool.id) == 0
    end

    test "its failed exit whose end was not written: the lost-run check ends it run_ended, failed",
         ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()

      # The exit folded, and the projection stopped before the end of the run of the queue.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.handed.run.id),
          set: [state: "failed", exit_state: "failed", exited_at: DateTime.utc_now()]
        )

      assert_live(ctx.handed)
      Liveness.check(DateTime.add(ctx.handed.run.attach_by, 60, :second))
      assert_ended(ctx.handed, :run_ended)
      assert %Record{failure_cause: :failed, failure_reason: nil} = record!(ctx.record)
      assert_build_kept(ctx)
      assert_nothing_queued(ctx)
    end

    test "its failed exit records nothing when the record's image is of a newer ref", ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()

      # The image on the record was built by a prebuild that took its ref after this one.
      newer = DateTime.add(ctx.handed.dispatch_run.environment_ref_at, 60, :second)

      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.id == ^ctx.record.id),
          set: [built_queued_at: newer]
        )

      kept = record!(ctx.record)
      exited!(ctx, %{"state" => "failed", "exit_code" => 1})
      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == kept
    end

    test "its starter's outcome is refused, not found, and ends nothing", ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()
      assert give_outcome(ctx.place.key, ctx.handed.run, "failed") == {:error, :not_found}
      assert %Run{outcome_state: nil} = run!(ctx.handed.run)
      assert_live(ctx.handed)
      assert record!(ctx.record) == ctx.record
    end

    test "its succeeded exit, once folded, ends it run_ended, frees its slot and records no failure",
         ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx)
      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == ctx.record
      assert Slots.held(ctx.place.pool.id) == 0
      assert_nothing_queued(ctx)
    end

    test "its succeeded exit whose end was not written: the lost-run check ends it run_ended, no failure",
         ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()

      # The exit folded, and the projection stopped before the end of the run of the queue.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.handed.run.id),
          set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
        )

      assert_live(ctx.handed)
      Liveness.check(DateTime.add(ctx.handed.run.attach_by, 60, :second))
      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == ctx.record
    end

    test "after its exit, its release is gone and records nothing", ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx)

      assert Dispatches.release(ctx.place.key, ctx.handed.dispatch.public_id, %{
               reason: "The build failed."
             }) == {:error, :gone}

      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == ctx.record
    end

    test "after its exit, its starter's outcome is refused and records nothing", ctx do
      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx)

      assert give_outcome(ctx.place.key, ctx.handed.run, "failed") == {:error, :not_found}
      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == ctx.record
    end

    test "after its succeeded exit, the lost-run check past its backstop changes nothing",
         ctx do
      assert {:ok, %{run: run}} = ctx.attach.()
      exited!(ctx)
      assert_ended(ctx.handed, :run_ended)

      assert Liveness.check(DateTime.add(run.backstop_at, 1, :second)) == []
      assert_ended(ctx.handed, :run_ended)
      assert record!(ctx.record) == ctx.record

      # The registered run keeps its exit's fold.
      assert %Run{state: "completed"} = run!(ctx.handed.run)
      assert_build_kept(ctx)
    end

    test "a record that is not there is not made", ctx do
      Repo.delete!(ctx.record)

      Liveness.check(DateTime.add(ctx.handed.run.attach_by, 1, :microsecond))
      assert_ended(ctx.handed, :lost)
      assert Repo.all(from r in Record, where: r.source_collection_id == ^ctx.collection.id) == []
    end
  end

  test "an explore run's end, lost or by its backstop, touches no environment record", ctx do
    record =
      Repo.insert!(%Record{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        pool_id: ctx.pool.id,
        source_collection_id: collection_fixture(ctx.scope).id,
        queued_ref: "env-1",
        queued_at: DateTime.utc_now(),
        image: @image,
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1"
      })

    unattached = handed_over!(ctx, unattached())
    Liveness.check(DateTime.add(unattached.run.attach_by, 1, :microsecond))
    assert_ended(unattached, :lost)

    attached = handed_over!(ctx)
    Liveness.check(DateTime.add(attached.run.backstop_at, 1, :microsecond))
    assert_ended(attached, :lost)

    assert record!(record) == record
  end

  describe "the run's exit, and no outcome" do
    test "the pool's outcome is refused, not found, and ends nothing; the exit ends it once",
         ctx do
      handed = handed_over!(ctx)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert give_outcome(ctx.key, handed.run, "succeeded") == {:error, :not_found}
      assert %Run{outcome_state: nil} = run!(handed.run)
      assert_live(handed)
      refute_received {Dispatches, :changed}

      event_fixture(handed.run, 9, "run.exited", %{"state" => "succeeded", "exit_code" => 0})
      assert {:ok, %Run{state: "completed"}} = Projector.project(handed.run)
      assert_ended(handed, :run_ended)
      assert_received {Dispatches, :changed}
      freed = dispatch!(handed.dispatch).slot_freed_at

      # The backstop and a release: nothing moves.
      assert Liveness.check(DateTime.add(handed.run.backstop_at, 1, :second)) == []

      assert Dispatches.release(ctx.key, handed.dispatch.public_id, %{reason: "stopped"}) ==
               {:error, :gone}

      assert_ended(handed, :run_ended)
      assert dispatch!(handed.dispatch).slot_freed_at == freed
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

    test "an outcome that gives the reason released or image_missing has it dropped" do
      body = %{"version" => 1, "time" => "2026-10-17T12:00:00Z", "state" => "cancelled"}

      for reason <- ["released", "image_missing"] do
        assert {:ok, %Outcome{state: "cancelled", reason: nil}} =
                 Outcome.parse(Map.put(body, "reason", reason))

        assert reason in Outcome.reserved_reasons()
      end
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
