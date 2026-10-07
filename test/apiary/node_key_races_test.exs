defmodule Apiary.NodeKeyRacesTest do
  # Two pastes racing each other, each on a connection of its own, outside the SQL
  # sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end; the ledger, which outlives an
  # organisation, by the public keys they made.
  #
  # The rules under test (`Apiary.AccessKeys.add_access_key/4`): a paste locks the node's
  # row `FOR UPDATE` before it counts the node's keys, so two pastes on one node take
  # turns, and the second counts the first; a public key enters the ledger by its unique
  # key, so two pastes of one key on two nodes wait on each other there, and the second
  # finds the first's row.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{AccessKeys, Nodes, Repo}
  alias Apiary.AccessKeys.{AccessKey, PublicKey}

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: owner} = sign_up()
    {:ok, keys} = Agent.start(fn -> [] end)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      public_keys = Agent.get(keys, & &1)
      Repo.delete_all(from p in PublicKey, where: p.public_key in ^public_keys)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    %{owner: owner, keys: keys}
  end

  defp node(owner, name) do
    {:ok, node} = Nodes.create_node(owner, %{kind: "node", name: name})
    node
  end

  defp fresh_key(ctx) do
    {public, _secret} = :crypto.generate_key(:eddsa, :ed25519)
    Agent.update(ctx.keys, &[public | &1])
    Base.url_encode64(public, padding: false)
  end

  defp paste(owner, node, label, public_key),
    do: AccessKeys.add_access_key(owner, node, %{label: label, public_key: public_key})

  defp live_keys(node) do
    Repo.aggregate(
      from(k in AccessKey, where: k.node_id == ^node.id and is_nil(k.revoked_at)),
      :count
    )
  end

  test "two pastes on a node with room for one: the second waits, and is refused", ctx do
    %{owner: owner} = ctx
    node = node(owner, "build-01")
    {:ok, _first} = paste(owner, node, "build-01-a", fresh_key(ctx))

    {first, first_pid} = hold(fn -> paste(owner, node, "build-01-b", fresh_key(ctx)) end)
    assert {:ok, %AccessKey{}} = first.result

    second = start(fn -> paste(owner, node, "build-01-c", fresh_key(ctx)) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, :key_limit}
    assert live_keys(node) == 2
  end

  test "one public key pasted on two nodes at once: the second waits, and is refused", ctx do
    %{owner: owner} = ctx
    node_a = node(owner, "build-01")
    node_b = node(owner, "build-02")
    public_key = fresh_key(ctx)

    {first, first_pid} = hold(fn -> paste(owner, node_a, "build-01", public_key) end)
    assert {:ok, %AccessKey{} = key} = first.result

    second = start(fn -> paste(owner, node_b, "build-02", public_key) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, %Ecto.Changeset{} = changeset} = Task.await(second.task)
    assert {"this key cannot be used", _} = changeset.errors[:public_key]

    assert live_keys(node_a) == 1
    assert live_keys(node_b) == 0
    {:ok, raw} = Base.url_decode64(public_key, padding: false)
    assert %PublicKey{state: :current, key_id: key_id} = Repo.get(PublicKey, raw)
    assert key_id == key.key_id
  end
end
