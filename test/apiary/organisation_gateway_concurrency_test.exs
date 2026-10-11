defmodule Apiary.OrganisationGatewayConcurrencyTest do
  # Real transactions on real connections, as in `Apiary.GatewayDeleteConcurrencyTest`: a
  # change of an organisation-level gateway and a change at a workspace it may serve take
  # turns on the organisation's row (`Apiary.Gateways.lock/1`). Each test holds one side's
  # transaction open, uncommitted, until the other side waits on a lock, then commits it.
  # What the test commits goes with its organisations and their users when it ends.
  use ExUnit.Case, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Edition, EditionStubs, Gateways, Nodes, Repo}
  alias Apiary.Nodes.Node
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    %{scope: scope, user: user} = sign_up_fixture()
    %{scope: other, user: other_user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      ids = [scope.organisation.id, other.organisation.id]
      Repo.delete_all(from o in Apiary.Organisations.Organisation, where: o.id in ^ids)

      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id in ^[user.id, other_user.id])

      Sandbox.mode(Repo, :manual)
    end)

    %{scope: scope, other: other}
  end

  defp reload(node), do: Repo.get!(Node, node.id)

  # The deletion of `gateway` from `scope`, in a transaction held open until told to commit.
  defp held_deletion(scope, gateway) do
    test = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        assert {:ok, _deleted} = Nodes.delete_node(scope, gateway)
        send(test, :held)
        receive do: (:commit -> :ok)
      end)
    end)
  end

  defp new_node(scope),
    do: Task.async(fn -> Nodes.create_node(scope, %{kind: "node", name: unique_node_name()}) end)

  defp commit(task) do
    send(task.pid, :commit)
    Task.await(task, 10_000)
  end

  test "a node made while the organisation's gateway is deleted does not start on it",
       %{scope: scope} do
    gateway = organisation_gateway_fixture(scope)
    deletion = held_deletion(scope, gateway)
    assert_receive :held, 10_000

    # Read as committed, the gateway is the organisation's default; the node's creation
    # waits for the organisation's row, held by the deletion.
    creation = new_node(scope)
    await_lock_wait(1)
    assert {:ok, :ok} = commit(deletion)

    assert {:ok, %Node{gateway_choice: :direct}} = Task.await(creation, 10_000)
    assert reload(gateway).deleted_at
  end

  test "a deletion that waits on a node's creation finds the node on the default",
       %{scope: scope} do
    gateway = organisation_gateway_fixture(scope)
    test = self()

    creation =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, %Node{gateway_choice: :default} = node} =
                   Nodes.create_node(scope, %{kind: "node", name: unique_node_name()})

          send(test, :held)
          receive do: (:commit -> node)
        end)
      end)

    assert_receive :held, 10_000

    deletion = Task.async(fn -> Nodes.delete_node(scope, gateway) end)
    await_lock_wait(1)
    assert {:ok, %Node{id: id}} = commit(creation)

    assert {:error, {:gateway_in_use, %{nodes: [%Node{id: ^id}], runs: []}}} =
             Task.await(deletion, 10_000)

    assert reload(gateway).deleted_at == nil
  end

  test "a workspace's gateway made while the organisation's first is made is not a second default",
       %{scope: scope} do
    test = self()

    organisation =
      Task.async(fn ->
        Repo.transaction(fn ->
          gateway = organisation_gateway_fixture(scope)
          assert gateway.default_gateway
          send(test, :held)
          receive do: (:commit -> gateway)
        end)
      end)

    assert_receive :held, 10_000

    workspace =
      Task.async(fn ->
        Nodes.create_node(scope, %{
          kind: "gateway",
          name: unique_node_name(),
          url: "https://gateway.example"
        })
      end)

    await_lock_wait(1)
    assert {:ok, %Node{id: id}} = commit(organisation)

    assert {:ok, %Node{default_gateway: false}} = Task.await(workspace, 10_000)
    assert Gateways.default_gateway_for(scope.workspace).id == id
  end

  test "two of the organisation's gateways made at once: one default", %{scope: scope} do
    test = self()

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          gateway = organisation_gateway_fixture(scope)
          send(test, :held)
          receive do: (:commit -> gateway)
        end)
      end)

    assert_receive :held, 10_000
    second = Task.async(fn -> organisation_gateway_fixture(scope) end)
    await_lock_wait(1)

    assert {:ok, %Node{default_gateway: true}} = commit(first)
    assert %Node{default_gateway: false} = Task.await(second, 10_000)
  end

  describe "across organisations, through the edition's seams" do
    setup %{scope: scope, other: other} do
      Edition.put_test_stub(EditionStubs.ServesAcross)
      EditionStubs.ServesAcross.put([{other.organisation.id, scope.organisation.id}])
      :ok
    end

    test "a node made while a serving organisation's gateway is deleted does not start on it",
         %{scope: scope, other: other} do
      gateway = organisation_gateway_fixture(other)
      deletion = held_deletion(other, gateway)
      assert_receive :held, 10_000

      creation = new_node(scope)
      await_lock_wait(1)
      assert {:ok, :ok} = commit(deletion)

      assert {:ok, %Node{gateway_choice: :direct}} = Task.await(creation, 10_000)
    end

    test "a deletion that waits on a served workspace's node finds it", %{
      scope: scope,
      other: other
    } do
      gateway = organisation_gateway_fixture(other)
      test = self()

      creation =
        Task.async(fn ->
          Repo.transaction(fn ->
            assert {:ok, %Node{gateway_choice: :default} = node} =
                     Nodes.create_node(scope, %{kind: "node", name: unique_node_name()})

            send(test, :held)
            receive do: (:commit -> node)
          end)
        end)

      assert_receive :held, 10_000

      deletion = Task.async(fn -> Nodes.delete_node(other, gateway) end)
      await_lock_wait(1)
      assert {:ok, %Node{id: id}} = commit(creation)

      assert {:error, {:gateway_in_use, %{nodes: [%Node{id: ^id}]}}} =
               Task.await(deletion, 10_000)
    end
  end

  # Until `count` backends of this database wait on a lock: the sides held by the others.
  defp await_lock_wait(count, tries \\ 400)

  defp await_lock_wait(count, 0), do: flunk("#{count} backends never waited on a lock")

  defp await_lock_wait(count, tries) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    if waiting >= count do
      :ok
    else
      Process.sleep(25)
      await_lock_wait(count, tries - 1)
    end
  end
end
