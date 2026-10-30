defmodule Apiary.Dispatches.RunEndTest do
  # The end of a run a workspace's queue handed over (`Apiary.Dispatches.RunEnd`): by its
  # exit, whatever its state, or by the lost-run check, at its gateway's `attach_by`, at its
  # backstop, or after 600 s without a heartbeat. Each ends the run of the queue and its
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

  # The last good build, as the setup kept it.
  defp assert_build_kept(%{record: record}) do
    kept = [:image, :size, :commit, :built_at, :reported_ref, :built_ref]
    assert Map.take(record!(record), kept) == Map.take(record, kept)
  end

  # No run of the queue for the collection but the prebuild that was handed over.
  defp assert_nothing_queued(%{collection: collection, handed: handed}) do
    assert Repo.all(
             from r in DispatchRun, where: r.source_collection_id == ^collection.id, select: r.id
           ) == [handed.dispatch_run.id]
  end

  # A first loss of the collection's `environment_ref`: the record has it as `lost_ref`,
  # and one more prebuild of it waits for the pool (`Apiary.Environments.build_failed/6`).
  defp assert_queued_again(%{collection: collection, handed: handed, record: record}) do
    assert %Record{lost_ref: "env-1"} = Repo.get!(Record, record.id)

    assert [%DispatchRun{state: :waiting, environment_ref: "env-1", pool_id: pool_id}] =
             Repo.all(
               from r in DispatchRun,
                 where: r.source_collection_id == ^collection.id,
                 where: r.id != ^handed.dispatch_run.id
             )

    assert pool_id == handed.dispatch_run.pool_id
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

  # The registered run heard at `at`, as its last heartbeat.
  defp beat!(%Run{id: id}, at) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id), set: [last_heartbeat_at: at])

    :ok
  end

  describe "backstop_seconds/1" do
    test "is 87,300 for explore, 4500 for prebuild, and Explore's for a step it does not name" do
      assert Dispatches.backstop_seconds("explore") == 87_300
      assert Dispatches.backstop_seconds("prebuild") == 4500
      assert Dispatches.backstop_seconds("another_step") == 87_300
      assert Dispatches.backstop_seconds(nil) == 87_300
    end

    test "the silence is 600 s" do
      assert RunEnd.silence_seconds() == 600
    end
  end

  describe "the backstop" do
    test "a run beating still is lost 87,300 s after its attach, and its dispatch ends lost",
         ctx do
      handed = handed_over!(ctx)
      backstop_at = handed.run.backstop_at
      assert DateTime.diff(backstop_at, handed.run.attached_at) == 87_300

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

    test "a run silent and lost before it keeps that loss; its dispatch ends at 600 s of silence",
         ctx do
      beat = DateTime.add(DateTime.utc_now(), -300)
      # Attached before its last heartbeat, so the silence counts from the heartbeat.
      handed = handed_over!(ctx, %{last_heartbeat_at: beat, attached_at: DateTime.add(beat, -60)})
      now = DateTime.utc_now()

      assert [%Run{state: "lost"}] = Liveness.check(now)
      assert_live(handed)

      later = DateTime.add(beat, 601, :second)
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
      beat!(handed.run, DateTime.add(handed.run.backstop_at, -1, :second))

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

  describe "the silence" do
    test "an attached run 600 s without a heartbeat is lost for good, and its dispatch ends lost",
         ctx do
      handed = handed_over!(ctx)
      beat = handed.run.last_heartbeat_at
      silence_end = DateTime.add(beat, 600, :second)

      # 600 s after its last heartbeat: lost by the liveness rules, its dispatch still live.
      Liveness.check(silence_end)
      assert run!(handed.run).state == "lost"
      lost_at = run!(handed.run).lost_at
      assert_live(handed)

      after_it = DateTime.add(silence_end, 1, :microsecond)
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)
      :ok = Apiary.Runs.subscribe(ctx.scope)

      assert Liveness.check(after_it) == []
      assert_ended(handed, :lost)
      assert dispatch!(handed.dispatch).slot_freed_at == after_it
      assert Slots.held(ctx.pool.id) == 0
      assert_received {Dispatches, :changed}
      assert_received {:run_changed, %Run{state: "lost"}}

      # The loss is kept, and the deadline for its end is the end of its silence.
      assert %Run{
               state: "lost",
               lost_at: ^lost_at,
               backstop_at: ^silence_end,
               silenced_at: ^after_it
             } = run!(handed.run)

      # A heartbeat that arrives after it brings the run back no more.
      event_fixture(handed.run, 2, "run.heartbeat", %{"elapsed_seconds" => 700},
        time: after_it,
        received_at: DateTime.add(after_it, 1, :second)
      )

      assert {:ok, %Run{state: "lost", lost_at: ^lost_at}} = Projector.project(handed.run)
      assert_ended(handed, :lost)
    end

    test "a running run its interval keeps alive is set lost at the end of its silence", ctx do
      # Beats every 300 s: three intervals are 900 s, so the liveness rules have not lost it.
      handed =
        handed_over!(ctx, %{
          registration_interval_seconds: 300,
          attach_interval_seconds: 300
        })

      after_it = DateTime.add(handed.run.last_heartbeat_at, 601, :second)

      assert Liveness.check(after_it) == []
      assert_ended(handed, :lost)

      assert %Run{
               state: "lost",
               lost_at: ^after_it,
               backstop_at: backstop_at,
               silenced_at: ^after_it
             } = run!(handed.run)

      assert backstop_at == DateTime.add(handed.run.last_heartbeat_at, 600, :second)
    end

    test "a run without a heartbeat is measured from its attach", ctx do
      handed = handed_over!(ctx, %{last_heartbeat_at: nil})
      silence_end = DateTime.add(handed.run.attached_at, 600, :second)

      Liveness.check(silence_end)
      assert_live(handed)

      Liveness.check(DateTime.add(silence_end, 1, :microsecond))
      assert_ended(handed, :lost)
      assert run!(handed.run).backstop_at == silence_end
    end

    test "a heartbeat within 600 s keeps the dispatch", ctx do
      # Beats every 300 s: three intervals are 900 s, so the liveness rules keep it running.
      handed =
        handed_over!(ctx, %{registration_interval_seconds: 300, attach_interval_seconds: 300})

      at = DateTime.add(handed.run.attached_at, 3600, :second)
      beat!(handed.run, DateTime.add(at, -599, :second))

      assert Liveness.check(at) == []
      assert_live(handed)
      assert run!(handed.run).state == "running"
    end

    test "a heartbeat that arrived in time and is not yet folded keeps the dispatch", ctx do
      # Beats every 300 s, so the liveness rules keep it running through the check.
      handed =
        handed_over!(ctx, %{registration_interval_seconds: 300, attach_interval_seconds: 300})

      beat = handed.run.last_heartbeat_at
      silence_end = DateTime.add(beat, 600, :second)
      arrived = DateTime.add(silence_end, -5, :second)

      event_fixture(handed.run, 2, "run.heartbeat", %{"elapsed_seconds" => 600},
        time: arrived,
        received_at: arrived
      )

      # The sweep projects events older than ten seconds only: this one waits.
      assert Liveness.check(DateTime.add(silence_end, 1, :second)) == []
      assert_live(handed)
      assert %Run{silenced_at: nil, backstop_at: backstop_at} = run!(handed.run)
      assert backstop_at == handed.run.backstop_at

      assert {:ok, %Run{state: "running"}} = Projector.project(handed.run)
      assert Liveness.check(DateTime.add(arrived, 599, :second)) == []
      assert_live(handed)
    end

    test "a heartbeat that arrived before its end and is folded after it leaves the run lost",
         ctx do
      handed = handed_over!(ctx)
      silence_end = DateTime.add(handed.run.last_heartbeat_at, 600, :second)
      Liveness.check(DateTime.add(silence_end, 1, :second))
      assert_ended(handed, :lost)
      assert %Run{state: "lost", silenced_at: %DateTime{}} = run!(handed.run)

      # Stored once the end was written, as a store that committed late is.
      arrived = DateTime.add(silence_end, -5, :second)

      event_fixture(handed.run, 2, "run.heartbeat", %{"elapsed_seconds" => 600},
        time: arrived,
        received_at: arrived
      )

      event_fixture(handed.run, 3, "run.started", started_data(),
        time: arrived,
        received_at: arrived
      )

      assert {:ok, %Run{state: "lost"}} = Projector.project(handed.run)
      assert_ended(handed, :lost)
    end

    test "an exit that arrives after its end still changes the record", ctx do
      handed = handed_over!(ctx)
      after_it = DateTime.add(handed.run.last_heartbeat_at, 601, :second)
      Liveness.check(after_it)
      assert_ended(handed, :lost)

      event_fixture(handed.run, 9, "run.exited", %{"state" => "failed", "exit_code" => 1},
        time: after_it,
        received_at: DateTime.add(after_it, 1, :second)
      )

      assert {:ok, %Run{state: "failed", exit_code: 1}} = Projector.project(handed.run)
      assert_ended(handed, :lost)
    end

    test "the pool's outcome after its end is refused, not found, and changes nothing", ctx do
      handed = handed_over!(ctx)
      Liveness.check(DateTime.add(handed.run.last_heartbeat_at, 601, :second))
      assert_ended(handed, :lost)
      lost = run!(handed.run)

      assert give_outcome(ctx.key, handed.run, "failed", "no_longer_needed") ==
               {:error, :not_found}

      assert run!(handed.run) == lost
      assert_ended(handed, :lost)
    end

    test "a run whose exit came ends as its exit, however long it was silent", ctx do
      handed = handed_over!(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^handed.run.id),
        set: [state: "completed", exit_state: "completed", exited_at: DateTime.utc_now()]
      )

      Liveness.check(DateTime.add(handed.run.last_heartbeat_at, 3600, :second))
      assert_ended(handed, :run_ended)
      assert %Run{silenced_at: nil, backstop_at: backstop_at} = run!(handed.run)
      assert backstop_at == handed.run.backstop_at
    end

    test "a run silent past its backstop keeps the backstop, and no silence end", ctx do
      handed = handed_over!(ctx)
      backstop_at = handed.run.backstop_at
      beat!(handed.run, DateTime.add(backstop_at, -300, :second))

      Liveness.check(DateTime.add(backstop_at, 301, :second))
      assert_ended(handed, :lost)

      assert %Run{state: "lost", backstop_at: ^backstop_at, silenced_at: nil} =
               run!(handed.run)
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
      assert DateTime.diff(run.backstop_at, run.attached_at, :microsecond) == 87_300 * 1_000_000

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
          image: @image,
          size: 734_003_200,
          commit: "9c1e4a7b",
          built_at: DateTime.utc_now(),
          reported_ref: "env-1",
          built_ref: "env-1"
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

    test "its attach sets its backstop 4500 s, 1 hour and 15 minutes, after it", ctx do
      assert {:ok, %{run: run}} = ctx.attach.()
      assert DateTime.diff(run.backstop_at, run.attached_at, :microsecond) == 4500 * 1_000_000
    end

    test "lost at its run key's attach_by records the build failed, lost, and queues it again",
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
      assert_queued_again(ctx)
    end

    test "ended by its backstop records the build failed, timed_out, queues nothing and ends the held runs",
         ctx do
      held = [held!(ctx)]

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
      beat!(run, DateTime.add(run.backstop_at, -100, :second))

      # Heard 100 s before its backstop, the registered run is lost by the liveness rules
      # at its backstop; the run of the queue waits for the backstop to pass.
      Liveness.check(run.backstop_at)
      assert_live(ctx.handed)
      assert record!(ctx.record) == failed

      after_it = DateTime.add(run.backstop_at, 1, :microsecond)
      Liveness.check(after_it)
      assert_ended(ctx.handed, :lost)

      assert %Record{
               failure_cause: :timed_out,
               failure_reason: nil,
               failed_at: ^after_it,
               lost_ref: nil
             } = record!(ctx.record)

      # A build past its backstop failed: it is not queued again, and the runs held for
      # it end.
      assert_build_kept(ctx)
      assert_nothing_queued(ctx)
      assert_held_ended(held)

      # A second check changes nothing.
      ended = record!(ctx.record)
      assert Liveness.check(DateTime.add(after_it, 60, :second)) == []
      assert record!(ctx.record) == ended
    end

    test "silent 600 s after its attach records the build failed, lost, and queues it again",
         ctx do
      assert {:ok, %{run: run}} = ctx.attach.()
      after_it = DateTime.add(run.attached_at, 601, :second)

      Liveness.check(after_it)
      assert_ended(ctx.handed, :lost)

      assert %Record{failure_cause: :lost, failure_reason: nil, failed_at: ^after_it} =
               record!(ctx.record)

      assert %Run{state: "lost"} = run!(ctx.handed.run)
      assert_build_kept(ctx)
      assert_queued_again(ctx)
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

        # A lost build is queued once more; a failed one is not.
        if cause == :lost, do: assert_queued_again(ctx), else: assert_nothing_queued(ctx)
        assert Slots.held(ctx.place.pool.id) == 0

        # The lost-run check changes nothing of the queue or the record, and the pool's
        # outcome is refused.
        assert Liveness.check(DateTime.add(ctx.handed.run.attach_by, 3600, :second)) == []
        assert give_outcome(ctx.place.key, ctx.handed.run, "failed") == {:error, :not_found}
        assert_ended(ctx.handed, :run_ended)
        assert record!(ctx.record) == failed
      end
    end

    # A waiting run of a fresh work item in Explore with the collection's target, held
    # for the pool's build of it.
    defp held!(ctx) do
      work_item =
        work_item_fixture(ctx.scope, %{
          target_system: ctx.collection.target_system,
          target_path: ctx.collection.target_path
        })

      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      run
    end

    # The runs held for the build, ended `build_failed` with the outcome `error`, never
    # dispatched.
    defp assert_held_ended(runs) do
      for run <- runs do
        assert %DispatchRun{state: :ended, end_cause: :build_failed, result_outcome: :error} =
                 queue_run!(run)

        assert Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^run.id) == []
      end
    end

    defp assert_held_waiting(runs),
      do: for(run <- runs, do: assert(%DispatchRun{state: :waiting} = queue_run!(run)))

    test "its failed exit ends the runs held for its build build_failed, with the outcome error",
         ctx do
      held = [held!(ctx), held!(ctx)]

      other =
        work_item_fixture(ctx.scope, %{
          target_system: "code.example.com",
          target_path: "acme/other"
        })

      {:ok, unheld} = Repo.transact(fn -> Dispatches.queue(other, 1) end)

      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx, %{"state" => "failed", "exit_code" => 1})

      assert %Record{failure_cause: :failed, lost_ref: nil} = record!(ctx.record)
      assert_held_ended(held)
      assert_nothing_queued(ctx)
      assert %DispatchRun{state: :waiting} = queue_run!(unheld)
    end

    @tag needs: [:factory, :security]
    test "its failed exit ends no run whose target's run configuration names an image",
         ctx do
      held = [held!(ctx)]
      document = ~s({"version":1,"security_policy":{"version":1,"image":"with-docker"}})

      Repo.insert!(%Apiary.Policy.RunConfiguration{
        organisation_id: ctx.scope.organisation.id,
        workspace_id: ctx.scope.workspace.id,
        version: 1,
        document: document,
        digest: Apiary.Policy.Render.digest(document),
        rendered_at: DateTime.utc_now()
      })

      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx, %{"state" => "failed", "exit_code" => 1})

      assert %Record{failure_cause: :failed} = record!(ctx.record)
      assert_held_waiting(held)
    end

    test "a first loss queues the build once more and the held runs wait; a second loss ends them",
         ctx do
      held = [held!(ctx)]
      attach_by = ctx.handed.run.attach_by
      assert [%Run{state: "lost"}] = Liveness.check(DateTime.add(attach_by, 1, :microsecond))

      assert_queued_again(ctx)
      assert_held_waiting(held)

      # The build queued again is claimed past the held run, and lost too.
      %{dispatch: dispatch, registered: run} = dispatched!(ctx.place.key)

      assert Liveness.check(DateTime.add(run.attach_by, 1, :microsecond)) != []
      assert %Dispatch{end_cause: :lost} = dispatch!(dispatch)
      assert %Record{failure_cause: :lost, lost_ref: nil} = record!(ctx.record)
      assert_held_ended(held)
    end

    test "a failed build ends no held run while another pool has the image for the target",
         ctx do
      held = [held!(ctx)]
      other = pool_fixture(ctx.scope)

      %Record{} = record = ctx.record

      Repo.insert!(%{
        record
        | id: nil,
          pool_id: other.id,
          built_target_system: ctx.collection.target_system,
          built_target_path: ctx.collection.target_path
      })

      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx, %{"state" => "failed", "exit_code" => 1})

      assert %Record{failure_cause: :failed} = record!(ctx.record)
      assert_held_waiting(held)
    end

    for deleted? <- [false, true] do
      test "a failed build ends the held runs while another pool's build waits (that pool deleted: #{deleted?})",
           ctx do
        held = [held!(ctx)]
        other = pool_fixture(ctx.scope)

        {:ok, waiting} =
          Repo.transact(fn -> Dispatches.queue_prebuild(ctx.collection, other, "env-1") end)

        if unquote(deleted?) do
          {1, _rows} =
            Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^other.id),
              set: [deleted_at: DateTime.utc_now()]
            )
        end

        assert {:ok, %{run: _run}} = ctx.attach.()
        exited!(ctx, %{"state" => "failed", "exit_code" => 1})
        assert_held_ended(held)
        assert %DispatchRun{state: :waiting} = queue_run!(waiting)
      end
    end

    test "two pools whose builds fail one after the other: the first failure ends the held runs, once",
         ctx do
      held = [held!(ctx)]
      second = handover_place_fixture(ctx.scope)

      {:ok, _queued} =
        Repo.transact(fn -> Dispatches.queue_prebuild(ctx.collection, second.pool, "env-1") end)

      %{run: other_build, registered: registered, run_code: code} = dispatched!(second.key)
      assert other_build.pool_id == second.pool.id

      assert {:ok, %{run: _run}} = ctx.attach.()
      exited!(ctx, %{"state" => "failed", "exit_code" => 1})
      assert_held_ended(held)
      ended = Enum.map(held, &queue_run!/1)

      # The second pool's build attaches through the gateway its claim resolved to, and
      # fails: the held runs keep the end they have.
      {gateway_key, _seed} =
        Enum.find_value([ctx.place, second], fn place ->
          if place.gateway.id == registered.gateway_id, do: place.gateway_key
        end)

      {:ok, body} = Attach.parse(attach_body(redeemed_run_key!(code)))

      assert {:ok, %{run: _run}} =
               Attach.attach(gateway_key, other_build.run_id, body, %{instance_id: instance_id()})

      event_fixture(registered, 9, "run.exited", %{"state" => "failed", "exit_code" => 1})
      assert {:ok, %Run{state: "failed"}} = Projector.project(registered)

      assert %DispatchRun{state: :ended, end_cause: :run_ended} = queue_run!(other_build)

      assert %Record{failure_cause: :failed} =
               Repo.get_by!(Record,
                 source_collection_id: ctx.collection.id,
                 pool_id: second.pool.id
               )

      assert Enum.map(held, &queue_run!/1) == ended
    end

    test "a failed or lost build of a ref its collection no longer has ends nothing and queues nothing",
         ctx do
      held = [held!(ctx)]

      {1, _rows} =
        Repo.update_all(
          from(c in Apiary.Adapters.Collection, where: c.id == ^ctx.collection.id),
          set: [environment_ref: "env-2"]
        )

      assert [%Run{state: "lost"}] =
               Liveness.check(DateTime.add(ctx.handed.run.attach_by, 1, :microsecond))

      assert %Record{failure_cause: :lost, lost_ref: nil} = record!(ctx.record)
      assert_nothing_queued(ctx)
      assert_held_waiting(held)
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
        image: @image,
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: DateTime.utc_now(),
        reported_ref: "env-1",
        built_ref: "env-1"
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
