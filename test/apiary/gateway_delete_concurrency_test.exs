defmodule Apiary.GatewayDeleteConcurrencyTest do
  # Real transactions on real connections: the sandbox would run the deletion and the
  # registration one after the other on one connection and prove nothing. Each test holds
  # one side's transaction open, uncommitted, until the other side waits on a lock, then
  # commits it. What the test commits goes with its organisation and its user when it ends.
  use ExUnit.Case, async: false

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Nodes, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    %{scope: scope, user: user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    gateway = gateway_fixture(scope)
    contract_key_fixture(scope, node: gateway)
    node = node_fixture(scope, gateway_choice: "named", gateway_id: gateway.id)
    %{access_key: key} = contract_key_fixture(scope, node: node)

    %{scope: scope, gateway: Repo.get!(Node, gateway.id), node: node, key: key}
  end

  test "a registration that resolved the gateway before its deletion committed is refused",
       %{scope: scope, gateway: gateway, node: node, key: key} do
    test = self()

    # The deletion's transaction: the node turns direct, so nothing else points to the
    # gateway, and the gateway is deleted; it holds the node's row and the gateway's until
    # told to commit.
    deletion =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Nodes.update_node(scope, node, %{gateway_choice: "direct"})
          assert {:ok, _deleted} = Nodes.delete_node(scope, gateway)
          send(test, :deleted)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :deleted, 10_000

    # The registration reads the node and the gateway as committed: the gateway, in use. It
    # then waits for the node's row, held by the deletion's transaction.
    run_id = Ecto.UUID.generate()

    registration =
      Task.async(fn -> register_run(key, gateway_registration(run_id), instance_id()) end)

    await_lock_wait(1)
    send(deletion.pid, :commit)
    assert {:ok, :ok} = Task.await(deletion, 10_000)

    assert {:error, :gateway_not_serving} = Task.await(registration, 10_000)
    assert Repo.get!(Node, gateway.id).deleted_at
    refute Repo.exists?(from r in Run, where: r.run_id == ^run_id)
  end

  test "a deletion that waits on a registration's commit finds its run",
       %{scope: scope, gateway: gateway, node: node, key: key} do
    test = self()
    run_id = Ecto.UUID.generate()

    # The node turns direct after its key was verified, so the registration still goes
    # through the gateway, and only its run will hold it.
    {:ok, _} = Nodes.update_node(scope, node, %{gateway_choice: "direct"})

    # A row of the same run id, inserted and not committed: the registration's insert waits
    # for it, with the gateway's row held `FOR SHARE`, until it rolls back.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.insert!(%Run{
            organisation_id: scope.organisation.id,
            workspace_id: scope.workspace.id,
            run_id: run_id
          })

          send(test, :held)
          receive do: (:release -> Repo.rollback(:released))
        end)
      end)

    assert_receive :held, 10_000

    registration =
      Task.async(fn -> register_run(key, gateway_registration(run_id), instance_id()) end)

    await_lock_wait(1)

    # The deletion waits for the gateway's row, held by the registration.
    deletion = Task.async(fn -> Nodes.delete_node(scope, gateway) end)

    await_lock_wait(2)
    send(holder.pid, :release)
    assert {:error, :released} = Task.await(holder, 10_000)

    assert {:ok, %{run: %Run{id: id}, repeated: false}} = Task.await(registration, 10_000)

    assert {:error, {:gateway_in_use, %{nodes: [], runs: [%Run{id: ^id}]}}} =
             Task.await(deletion, 10_000)

    assert Repo.get!(Node, gateway.id).deleted_at == nil
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
