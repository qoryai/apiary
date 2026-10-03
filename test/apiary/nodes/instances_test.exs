defmodule Apiary.Nodes.InstancesTest do
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Nodes
  alias Apiary.Nodes.{Instance, Node, Throttle}
  alias Apiary.Runs
  alias Apiary.Runs.{Delivery, Run}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp ago(seconds, now \\ DateTime.utc_now()), do: DateTime.add(now, -seconds, :second)
  defp instances(node), do: Repo.all(from i in Instance, where: i.node_id == ^node.id)
  defp reload(%Node{id: id}), do: Repo.get!(Node, id)
  defp state(%Run{id: id}), do: Repo.get!(Run, id).state

  describe "the columns that name a node and an instance" do
    test "every run and delivery today names neither", %{scope: scope} do
      run = Apiary.RunEventsFixtures.run_fixture(scope)
      assert %Run{node_id: nil, instance_id: nil} = Repo.get!(Run, run.id)
      assert %Delivery{}.instance_id == nil
    end

    test "placement/2 is the node and the instance a run records", %{scope: scope} do
      node = node_fixture(scope)

      assert Nodes.placement(nil, "i_1") == %{node_id: nil, instance_id: nil}
      assert Nodes.placement(node, "i_1") == %{node_id: node.id, instance_id: "i_1"}
      assert Nodes.placement(node, "") == %{node_id: node.id, instance_id: nil}
      assert Nodes.placement(node, "a\nb") == %{node_id: node.id, instance_id: nil}

      assert Nodes.placement(node, String.duplicate("i", 129)) ==
               %{node_id: node.id, instance_id: nil}
    end

    test "a run cannot name a node of another workspace", %{scope: scope} do
      other = workspace_scope(scope.user, workspace_fixture(scope.organisation))
      node = node_fixture(other)

      assert_raise Ecto.ConstraintError, ~r/runs_node_id_fkey/, fn ->
        Apiary.RunEventsFixtures.run_fixture(scope, %{node_id: node.id})
      end
    end

    test "an instance row holds its id, its name and its times to their rules", %{
      scope: scope
    } do
      node = node_fixture(scope)
      instance = instance_fixture(node)

      for {assignments, constraint} <- [
            {"instance_id = ''", "node_instances_instance_id_check"},
            {"name = '-build'", "node_instances_name_check"},
            {"last_seen_at = first_seen_at - interval '1 second'", "node_instances_seen_check"},
            {"cleared_by_id = $2", "node_instances_cleared_check"}
          ] do
        assert_raise Postgrex.Error, ~r/#{constraint}/, fn ->
          Repo.transact(fn ->
            Repo.query!(
              "UPDATE node_instances SET #{assignments} WHERE id = $1",
              [Ecto.UUID.dump!(instance.id)] ++
                if(String.contains?(assignments, "$2"),
                  do: [Ecto.UUID.dump!(scope.user.id)],
                  else: []
                )
            )

            {:ok, nil}
          end)
        end
      end

      assert_raise Ecto.ConstraintError, fn ->
        instance_fixture(node, instance_id: instance.instance_id)
      end
    end

    test "a node's instances are not reachable from another organisation", %{scope: scope} do
      node = node_fixture(scope)
      instance = instance_fixture(node)
      %{scope: stranger} = sign_up_fixture()

      assert Nodes.get_instance(scope, node, instance.instance_id).id == instance.id
      assert Nodes.get_instance(stranger, node, instance.instance_id) == nil
      assert Nodes.activity(stranger, [node]) == %{node.id => %{running: [], last: nil}}
      assert Nodes.names(stranger, [node.id]) == %{}
    end
  end

  describe "seen/3" do
    test "records a new instance, then brings it up to date", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = access_key_fixture(scope)
      Nodes.subscribe(scope)
      workspace_id = scope.workspace.id
      t = ~U[2026-10-01 12:00:00.000000Z]

      assert :ok =
               Nodes.seen(
                 node,
                 %{
                   instance_id: "i_1",
                   name: "build-01.example.com",
                   access_key_id: key.id,
                   runner_version: "0.7.0",
                   contract_version: 1
                 },
                 t
               )

      assert_receive {:nodes_touched, ^workspace_id}

      assert [
               %Instance{
                 instance_id: "i_1",
                 name: "build-01.example.com",
                 first_seen_at: ^t,
                 last_seen_at: ^t,
                 last_runner_version: "0.7.0",
                 last_contract_version: 1
               } = instance
             ] = instances(node)

      assert instance.access_key_id == key.id

      # Within the window nothing is written; after it, the row moves on and a name that
      # is no name leaves the one it had.
      later = DateTime.add(t, 5, :second)
      assert :ok = Nodes.seen(node, %{instance_id: "i_1", runner_version: "0.7.1"}, later)
      assert [%Instance{last_seen_at: ^t, last_runner_version: "0.7.0"}] = instances(node)

      later = DateTime.add(t, 20, :second)

      assert :ok =
               Nodes.seen(
                 node,
                 %{instance_id: "i_1", name: "no spaces", runner_version: "0.7.1"},
                 later
               )

      assert [
               %Instance{
                 first_seen_at: ^t,
                 last_seen_at: ^later,
                 name: "build-01.example.com",
                 last_runner_version: "0.7.1"
               }
             ] = instances(node)
    end

    test "an instance id that cannot be kept is ignored, and nothing makes it fail", %{
      scope: scope
    } do
      node = node_fixture(scope)

      assert :ok = Nodes.seen(node, %{instance_id: ""})
      assert :ok = Nodes.seen(node, %{instance_id: "a\u0000b"})
      assert :ok = Nodes.seen(node, %{name: "build-01"})
      assert instances(node) == []

      # A key that is no key's row: the write fails, the request does not.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Nodes.seen(node, %{instance_id: "i_2", access_key_id: Ecto.UUID.generate()})
        end)

      assert log =~ "an instance could not be recorded"
      assert instances(node) == []
    end

    test "an instance is one per node, whichever of its keys it uses", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: first} = access_key_fixture(scope)
      %{access_key: second} = access_key_fixture(scope)
      t = ~U[2026-10-01 12:00:00.000000Z]

      Nodes.seen(node, %{instance_id: "i_1", access_key_id: first.id}, t)
      Nodes.seen(node, %{instance_id: "i_1", access_key_id: second.id}, DateTime.add(t, 16))

      assert [%Instance{access_key_id: key_id}] = instances(node)
      assert key_id == second.id
    end

    test "records at most 256 new instances of a node a day, and counts the rest", %{
      scope: scope
    } do
      node = node_fixture(scope)
      now = DateTime.utc_now()

      Repo.insert_all(
        Instance,
        for n <- 1..256 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: node.organisation_id,
            workspace_id: node.workspace_id,
            node_id: node.id,
            instance_id: "i_#{n}",
            first_seen_at: ago(60, now),
            last_seen_at: ago(60, now)
          }
        end
      )

      assert :ok = Nodes.seen(node, %{instance_id: "i_over"}, now)
      assert length(instances(node)) == 256
      assert %Node{instance_ids_over_bound: 1, instance_ids_over_bound_at: ^now} = reload(node)

      # One already recorded is still seen.
      assert :ok = Nodes.seen(node, %{instance_id: "i_1"}, now)

      assert %Instance{last_seen_at: ^now} =
               Repo.one!(
                 from i in Instance, where: i.node_id == ^node.id and i.instance_id == "i_1"
               )

      # A day on, the bound has room again.
      Repo.update_all(from(i in Instance, where: i.node_id == ^node.id),
        set: [first_seen_at: ago(86_401, now)]
      )

      assert :ok = Nodes.seen(node, %{instance_id: "i_new"}, DateTime.add(now, 1))
      assert length(instances(node)) == 257
    end

    test "the throttle lets one write a window through for each node and instance" do
      t = ~U[2026-10-01 12:00:00.000000Z]
      key = {Ecto.UUID.generate(), "i_1"}

      assert Throttle.due?(key, t)
      refute Throttle.due?(key, DateTime.add(t, 14, :second))
      refute Throttle.due?(key, DateTime.add(t, 14_999, :millisecond))
      assert Throttle.due?(key, DateTime.add(t, 15, :second))
      assert Throttle.due?({Ecto.UUID.generate(), "i_1"}, t)
    end
  end

  describe "the instance limit" do
    test "a node admits one instance at a time; the same one is already counted", %{
      scope: scope
    } do
      node = node_fixture(scope)
      now = DateTime.utc_now()

      check = fn instance_id ->
        {:ok, answer} =
          Repo.transact(fn -> {:ok, Nodes.check_instance_limit(node, instance_id, now)} end)

        answer
      end

      assert check.("i_1") == :ok
      node_run_fixture(node, "i_1")
      assert check.("i_1") == :already_counted
      assert check.("i_2") == {:error, :instance_limit}
    end

    test "a pool admits up to its limit, and any number without one", %{scope: scope} do
      pool = pool_fixture(scope, instance_limit: 2)
      unlimited = pool_fixture(scope)
      now = DateTime.utc_now()

      check = fn node, instance_id ->
        {:ok, answer} =
          Repo.transact(fn -> {:ok, Nodes.check_instance_limit(node, instance_id, now)} end)

        answer
      end

      node_run_fixture(pool, "i_1")
      node_run_fixture(pool, "i_1")
      assert check.(pool, "i_2") == :ok
      node_run_fixture(pool, "i_2")
      assert check.(pool, "i_3") == {:error, :instance_limit}

      for n <- 1..5, do: node_run_fixture(unlimited, "i_#{n}")
      assert check.(unlimited, "i_6") == :ok
    end

    test "only runs alive by the lost-run check's rule count", %{scope: scope} do
      node = node_fixture(scope)
      other = node_fixture(scope)
      now = DateTime.utc_now()

      # Ended, lost, silent past three intervals, of another node, or of no instance.
      node_run_fixture(node, "i_1", %{state: "succeeded"})
      node_run_fixture(node, "i_2", %{state: "lost"})
      node_run_fixture(node, "i_3", %{state: "pending", inserted_at: ago(91, now)})

      node_run_fixture(node, "i_4", %{
        state: "running",
        inserted_at: ago(600, now),
        last_heartbeat_at: ago(91, now)
      })

      node_run_fixture(other, "i_5")
      node_run_fixture(node, nil)

      assert {:ok, :ok} =
               Repo.transact(fn -> {:ok, Nodes.check_instance_limit(node, "i_9", now)} end)

      node_run_fixture(node, "i_6", %{
        state: "running",
        inserted_at: ago(600, now),
        last_heartbeat_at: ago(30, now)
      })

      assert {:ok, {:error, :instance_limit}} =
               Repo.transact(fn -> {:ok, Nodes.check_instance_limit(node, "i_9", now)} end)
    end

    test "a limit raised to none since the node was read admits", %{scope: scope} do
      pool = pool_fixture(scope, instance_limit: 1)
      node_run_fixture(pool, "i_1")
      {:ok, _} = Nodes.update_node(scope, pool, %{instance_limit: ""})

      assert {:ok, :ok} =
               Repo.transact(fn ->
                 {:ok, Nodes.check_instance_limit(pool, "i_2", DateTime.utc_now())}
               end)
    end

    test "the check is the batch's transaction's, and admit/4 is the transaction", %{
      scope: scope
    } do
      node = node_fixture(scope)

      assert_raise ArgumentError, fn ->
        Nodes.check_instance_limit(node, "i_1", DateTime.utc_now())
      end

      assert_raise ArgumentError, fn ->
        Repo.transact(fn -> Nodes.admit(node, "i_1", fn -> {:ok, nil} end) end)
      end
    end

    test "admit/4 stores what it is given when admitted, and nothing when refused", %{
      scope: scope
    } do
      node = node_fixture(scope)
      now = DateTime.utc_now()

      assert {:ok, %Run{instance_id: "i_1"}} =
               Nodes.admit(node, "i_1", fn -> {:ok, node_run_fixture(node, "i_1")} end, now)

      assert %Node{instance_limit_refused: 0, instance_limit_refused_at: nil} = reload(node)

      assert {:ok, %Run{}} =
               Nodes.admit(node, "i_1", fn -> {:ok, node_run_fixture(node, "i_1")} end, now)

      assert {:error, :instance_limit} =
               Nodes.admit(node, "i_2", fn -> {:ok, node_run_fixture(node, "i_2")} end, now)

      assert Repo.aggregate(from(r in Run, where: r.instance_id == "i_2"), :count) == 0
      assert %Node{instance_limit_refused: 1, instance_limit_refused_at: ^now} = reload(node)

      # The store's own error rolls back what it stored, and is no refusal.
      pool = pool_fixture(scope, instance_limit: 5)

      assert {:error, :unavailable} =
               Nodes.admit(pool, "i_3", fn ->
                 node_run_fixture(pool, "i_3")
                 {:error, :unavailable}
               end)

      assert Repo.aggregate(from(r in Run, where: r.node_id == ^pool.id), :count) == 0
      assert %Node{instance_limit_refused: 0} = reload(pool)
    end
  end

  describe "Clear instance" do
    test "marks the instance's open runs lost, so another can start at once", %{scope: scope} do
      node = node_fixture(scope)
      instance = instance_fixture(node, instance_id: "i_1", name: "build-01.example.com")
      open = node_run_fixture(node, "i_1", %{state: "running", started_at: ago(30)})
      pending = node_run_fixture(node, "i_1")
      ended = node_run_fixture(node, "i_1", %{state: "succeeded"})
      other = node_run_fixture(node, "i_2")
      Runs.subscribe(scope)
      Nodes.subscribe(scope)
      workspace_id = scope.workspace.id

      assert {:ok, %{instance_id: "i_1", instance: cleared, runs: runs}} =
               Nodes.clear_instance(scope, node, "i_1")

      assert Enum.sort(Enum.map(runs, & &1.id)) == Enum.sort([open.id, pending.id])
      assert Enum.map([open, pending, ended, other], &state/1) == ~w(lost lost succeeded pending)
      assert cleared.id == instance.id
      assert cleared.cleared_by_id == scope.user.id
      assert %DateTime{} = cleared.cleared_at

      assert_receive {:run_changed, %Run{state: "lost"}}
      assert_receive {:nodes_touched, ^workspace_id}

      assert [%Entry{action: "node.clear_instance", details: details}] =
               Repo.all(
                 from e in Entry,
                   where: e.subject_id == ^node.id and e.action == "node.clear_instance"
               )

      assert details == %{"instance_id" => "i_1", "name" => "build-01.example.com", "runs" => 2}

      # The node's one slot is i_2's until it is cleared too.
      assert {:ok, {:error, :instance_limit}} =
               Repo.transact(fn ->
                 {:ok, Nodes.check_instance_limit(node, "i_3", DateTime.utc_now())}
               end)

      assert {:ok, %{instance: nil}} = Nodes.clear_instance(scope, node, "i_2")

      assert {:ok, :ok} =
               Repo.transact(fn ->
                 {:ok, Nodes.check_instance_limit(node, "i_3", DateTime.utc_now())}
               end)
    end

    test "clears an instance that has open runs and no row", %{scope: scope} do
      node = node_fixture(scope)
      run = node_run_fixture(node, "i_1")

      assert {:ok, %{instance: nil, runs: [%Run{id: id}]}} =
               Nodes.clear_instance(scope, node, "i_1")

      assert id == run.id
    end

    test "is not found for an instance the node never had", %{scope: scope} do
      node = node_fixture(scope)
      other = node_fixture(scope)
      instance_fixture(other, instance_id: "i_1")

      assert Nodes.clear_instance(scope, node, "i_1") == {:error, :not_found}
      assert Nodes.clear_instance(scope, node, "") == {:error, :not_found}
    end

    test "is owners' and admins'", %{scope: owner} do
      node = node_fixture(owner)
      instance_fixture(node, instance_id: "i_1")
      run = node_run_fixture(node, "i_1")
      %{scope: member} = member_fixture(owner, :member)
      %{scope: admin} = member_fixture(owner, :admin)

      assert Nodes.clear_instance(member, node, "i_1") == {:error, :forbidden}
      assert state(run) == "pending"
      assert {:ok, _} = Nodes.clear_instance(admin, node, "i_1")
      assert state(run) == "lost"
    end

    test "of another organisation's node is not found", %{scope: scope} do
      node = node_fixture(scope)
      instance_fixture(node, instance_id: "i_1")
      %{scope: stranger} = sign_up_fixture()

      assert Nodes.clear_instance(stranger, node, "i_1") == {:error, :not_found}
    end
  end

  describe "activity/3" do
    test "a node's running instances, oldest first, and the one seen last", %{scope: scope} do
      pool = pool_fixture(scope, instance_limit: 10)
      idle = node_fixture(scope)
      never = node_fixture(scope)
      now = DateTime.utc_now()

      instance_fixture(pool, instance_id: "i_1", name: "spot-1", seen_at: ago(5, now))
      instance_fixture(pool, instance_id: "i_2", seen_at: ago(1, now))
      instance_fixture(idle, instance_id: "i_3", seen_at: ago(7200, now))
      instance_fixture(idle, instance_id: "i_4", seen_at: ago(3600, now))

      first = node_run_fixture(pool, "i_1", %{inserted_at: ago(50, now)})

      newest =
        node_run_fixture(pool, "i_1", %{
          state: "running",
          started_at: ago(20, now),
          last_heartbeat_at: ago(5, now),
          runner_version: "0.7.1"
        })

      node_run_fixture(pool, "i_2", %{inserted_at: ago(10, now)})
      node_run_fixture(pool, "i_5", %{state: "failed"})

      activity = Nodes.activity(scope, [pool, idle, never], now)

      assert %{running: [one, two], last: %Instance{instance_id: "i_2"}} = activity[pool.id]

      assert %{instance_id: "i_1", name: "spot-1", runner_version: "0.7.1"} = one
      assert one.since == first.inserted_at
      assert one.run_id == newest.run_id
      assert %{instance_id: "i_2", name: nil} = two

      assert %{running: [], last: %Instance{instance_id: "i_4"}} = activity[idle.id]
      assert activity[never.id] == %{running: [], last: nil}
    end
  end
end
