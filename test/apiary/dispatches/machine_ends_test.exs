defmodule Apiary.Dispatches.MachineEndsTest do
  # What a node pool's starter reports about the removal of a dispatch's machine
  # (`Apiary.Dispatches.MachineEnds`): every accepted report replaces the state and its
  # time, `gone` is final, a dispatch that ended takes a report, the refusals write
  # nothing, the audit trail keeps three entries of a dispatch at most, and a message goes
  # out on the run's topic. The route's answers are tested in
  # `ApiaryWeb.Contract.MachineEndControllerTest`. Not async: one test alters the
  # dispatches' table inside its transaction.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Repo, Runs}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, Slots}

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    scope |> handover_place_fixture() |> Map.put(:scope, scope)
  end

  # A dispatch of a fresh work item, claimed and its job started.
  defp dispatch!(ctx) do
    {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
    dispatched!(ctx.key)
  end

  defp report(ctx, %Dispatch{public_id: id}, state, key \\ nil),
    do: Dispatches.report_machine_end(key || ctx.key, id, %{state: state})

  defp reload(%Dispatch{id: id}), do: Repo.get!(Dispatch, id)

  defp entries,
    do:
      Repo.all(
        from e in Entry,
          where: e.action == "dispatch.machine_end",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  describe "a report" do
    test "keeps the state and its time, and each later one replaces it", ctx do
      %{dispatch: dispatch} = dispatch!(ctx)
      assert %Dispatch{machine_end_state: nil, machine_end_at: nil} = reload(dispatch)

      before = DateTime.utc_now()
      assert report(ctx, dispatch, :deleting) == :ok
      assert %Dispatch{machine_end_state: :deleting, machine_end_at: first} = reload(dispatch)
      assert DateTime.compare(first, before) != :lt

      assert report(ctx, dispatch, :delete_failed) == :ok

      assert %Dispatch{machine_end_state: :delete_failed, machine_end_at: second} =
               reload(dispatch)

      assert DateTime.compare(second, first) != :lt

      assert report(ctx, dispatch, :deleting) == :ok
      assert %Dispatch{machine_end_state: :deleting} = reload(dispatch)

      assert report(ctx, dispatch, :gone) == :ok
      assert %Dispatch{machine_end_state: :gone} = reload(dispatch)
    end

    test "gone is final: a later report changes nothing and is still :ok", ctx do
      %{dispatch: dispatch} = dispatch!(ctx)
      assert report(ctx, dispatch, :gone) == :ok
      %Dispatch{machine_end_at: at} = reload(dispatch)

      for state <- [:deleting, :delete_failed, :gone] do
        assert report(ctx, dispatch, state) == :ok
        assert %Dispatch{machine_end_state: :gone, machine_end_at: ^at} = reload(dispatch)
      end
    end

    test "is taken for a dispatch handed over, one released and one whose lease lapsed", ctx do
      %{dispatch: handed_over} = handed_over_fixture(ctx.scope, ctx.key)
      assert report(ctx, handed_over, :gone) == :ok
      assert %Dispatch{machine_end_state: :gone} = reload(handed_over)

      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)

      {:ok, %{dispatch: released}} =
        Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      :ok = Dispatches.release(ctx.key, released.public_id, %{reason: "stopped"})
      assert %Dispatch{ended_at: %DateTime{}} = reload(released)
      assert report(ctx, released, :deleting) == :ok
      assert %Dispatch{machine_end_state: :deleting} = reload(released)

      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)

      {:ok, %{dispatch: lapsed}} =
        Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())

      now = DateTime.utc_now()

      {1, _rows} =
        Repo.update_all(from(d in Dispatch, where: d.id == ^lapsed.id),
          set: [
            claimed_at: DateTime.add(now, -700, :second),
            lease_until: %{
              DateTime.truncate(DateTime.add(now, -60, :second), :second)
              | microsecond: {0, 6}
            }
          ]
        )

      assert report(ctx, lapsed, :delete_failed) == :ok
      assert %Dispatch{machine_end_state: :delete_failed} = reload(lapsed)
    end
  end

  describe "the slot" do
    # The dispatch ended, as its run's end ends it.
    defp end!(%Dispatch{id: id}) do
      {1, _rows} =
        Repo.update_all(from(d in Dispatch, where: d.id == ^id),
          set: [ended_at: Dispatches.now(), end_cause: :run_ended]
        )

      {:ok, _freed} = Repo.transact(fn -> {:ok, Slots.free(:all, Dispatches.now())} end)
    end

    test "a gone with no deleting before it is taken, and frees the slot of a dispatch that ended",
         ctx do
      %{dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      end!(dispatch)
      assert Slots.held(ctx.pool.id) == 1
      :ok = Dispatches.subscribe(ctx.scope.workspace.id)

      assert report(ctx, dispatch, :gone) == :ok
      assert %Dispatch{machine_end_state: :gone, slot_freed_at: %DateTime{}} = reload(dispatch)
      assert Slots.held(ctx.pool.id) == 0
      assert_receive {Dispatches, :changed}
      assert [%{"state" => "gone"}] = Enum.map(entries(), & &1.details)
    end

    test "deleting and delete_failed keep the slot of a dispatch that ended", ctx do
      %{dispatch: dispatch} = handed_over_fixture(ctx.scope, ctx.key)
      end!(dispatch)

      for state <- [:deleting, :delete_failed] do
        assert report(ctx, dispatch, state) == :ok
        assert %Dispatch{slot_freed_at: nil} = reload(dispatch)
      end

      assert report(ctx, dispatch, :gone) == :ok
      assert Slots.held(ctx.pool.id) == 0
    end

    test "a gone with no dispatched frees the slot at the release, and holds nothing after",
         ctx do
      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
      {:ok, %{dispatch: dispatch}} = walked_claim(ctx.key, Dispatches.now())

      # The machine never came up: the claim still holds its slot until it ends.
      assert report(ctx, dispatch, :gone) == :ok
      assert %Dispatch{machine_end_state: :gone, slot_freed_at: nil} = reload(dispatch)

      :ok = Dispatches.release(ctx.key, dispatch.public_id, %{reason: "no capacity"})
      assert %Dispatch{slot_freed_at: %DateTime{} = freed_at} = reload(dispatch)

      # A late dispatched or report takes nothing back.
      assert {:error, :gone} =
               Dispatches.dispatched(ctx.key, dispatch.public_id, %{external: nil})

      assert report(ctx, dispatch, :deleting) == :ok
      assert %Dispatch{machine_end_state: :gone, slot_freed_at: ^freed_at} = reload(dispatch)
      assert Slots.held(ctx.pool.id) == 0
    end

    test "a deleting after a release with no machine takes the slot back until gone", ctx do
      {:ok, _run} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(ctx.scope), 1) end)
      {:ok, %{dispatch: dispatch}} = walked_claim(ctx.key, Dispatches.now())

      :ok = Dispatches.release(ctx.key, dispatch.public_id, %{reason: "no capacity"})
      assert Slots.held(ctx.pool.id) == 0

      assert report(ctx, dispatch, :deleting) == :ok
      assert Slots.held(ctx.pool.id) == 1

      assert report(ctx, dispatch, :gone) == :ok
      assert Slots.held(ctx.pool.id) == 0
    end
  end

  describe "the refusals write nothing" do
    test "an id not of a dispatch's shape, an unknown dispatch and another pool's are forbidden",
         ctx do
      %{dispatch: dispatch} = dispatch!(ctx)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      assert Dispatches.report_machine_end(ctx.key, "../x", %{state: :gone}) ==
               {:error, :forbidden}

      assert Dispatches.report_machine_end(ctx.key, "dp_0000000000000000", %{state: :gone}) ==
               {:error, :forbidden}

      assert report(ctx, dispatch, :gone, other) == {:error, :forbidden}
      assert %Dispatch{machine_end_state: nil} = reload(dispatch)
      assert entries() == []
    end

    test "a key revoked since is unauthorized", ctx do
      %{dispatch: dispatch} = dispatch!(ctx)
      {:ok, _revoked} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)

      assert report(ctx, dispatch, :gone) == {:error, :unauthorized}
      assert %Dispatch{machine_end_state: nil} = reload(dispatch)
      assert entries() == []
    end

    test "a report that cannot be stored is unavailable, logged by its module alone", ctx do
      %{dispatch: dispatch} = dispatch!(ctx)

      Repo.query!(
        "ALTER TABLE dispatches ADD CONSTRAINT refuse_machine_end " <>
          "CHECK (machine_end_state IS NULL) NOT VALID"
      )

      log =
        capture_log(fn ->
          assert report(ctx, dispatch, :gone) == {:error, :unavailable}
        end)

      assert log =~ "a machine end could not be stored: Postgrex.Error"
      refute log =~ "refuse_machine_end"
      assert %Dispatch{machine_end_state: nil} = reload(dispatch)
      assert entries() == []
    end
  end

  describe "the audit trail" do
    test "one entry for the first report, the first delete_failed and gone, and no more",
         ctx do
      %{dispatch: dispatch} = dispatch!(ctx)

      for state <-
            [:deleting, :deleting, :delete_failed, :deleting, :delete_failed] ++
              [:deleting, :gone, :deleting, :gone] do
        assert report(ctx, dispatch, state) == :ok
      end

      {:ok, key} = AccessKeys.fetch_for_verification(ctx.key.key_id)

      assert [
               %{"dispatch_id" => id, "state" => "deleting"},
               %{"state" => "delete_failed"},
               %{"state" => "gone"}
             ] = Enum.map(entries(), & &1.details)

      assert id == dispatch.public_id

      for entry <- entries() do
        assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
        assert {entry.subject_kind, entry.subject_id} == {"node", key.node_id}
        assert entry.organisation_id == dispatch.organisation_id
      end
    end

    test "a first report of delete_failed is one entry, and a later one writes none", ctx do
      %{dispatch: dispatch} = dispatch!(ctx)

      for state <- [:delete_failed, :deleting, :delete_failed] do
        assert report(ctx, dispatch, state) == :ok
      end

      assert [%{"state" => "delete_failed"}] = Enum.map(entries(), & &1.details)
    end

    test "a first report of gone is one entry", ctx do
      %{dispatch: dispatch} = dispatch!(ctx)
      assert report(ctx, dispatch, :gone) == :ok
      assert report(ctx, dispatch, :gone) == :ok
      assert [%{"state" => "gone"}] = Enum.map(entries(), & &1.details)
    end

    test "the entries of one dispatch do not bound another's", ctx do
      %{dispatch: first} = dispatch!(ctx)
      %{dispatch: second} = dispatch!(ctx)

      assert report(ctx, first, :delete_failed) == :ok
      assert report(ctx, second, :deleting) == :ok
      assert report(ctx, second, :delete_failed) == :ok

      assert [
               {first.public_id, "delete_failed"},
               {second.public_id, "deleting"},
               {second.public_id, "delete_failed"}
             ] == Enum.map(entries(), &{&1.details["dispatch_id"], &1.details["state"]})
    end
  end

  describe "the run's topic" do
    test "a change tells the run registered at the claim; a kept gone tells nothing", ctx do
      %{dispatch: dispatch, run: run} = handed_over_fixture(ctx.scope, ctx.key)
      :ok = Runs.subscribe(ctx.scope, run)
      run_id = run.id

      assert report(ctx, dispatch, :deleting) == :ok
      assert_receive {:machine_end_changed, %Apiary.Runs.Run{id: ^run_id}}

      assert report(ctx, dispatch, :gone) == :ok
      assert_receive {:machine_end_changed, %Apiary.Runs.Run{id: ^run_id}}

      assert report(ctx, dispatch, :deleting) == :ok
      refute_receive {:machine_end_changed, _run}, 50
    end

    test "a refusal tells nothing", ctx do
      %{dispatch: dispatch, run: run} = handed_over_fixture(ctx.scope, ctx.key)
      %{access_key: other} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))
      :ok = Runs.subscribe(ctx.scope, run)

      assert report(ctx, dispatch, :gone, other) == {:error, :forbidden}
      refute_receive {:machine_end_changed, _run}, 50
    end
  end
end
