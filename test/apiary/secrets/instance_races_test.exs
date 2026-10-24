defmodule Apiary.Secrets.InstanceRacesTest do
  # Two adapters' first secrets, written at once, each on a connection apart, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Secrets.Instance`): the instance has one data key, made
  # with its first secret. Two adapters' writes hold different rows, so both may reach the
  # key at once: the primary key of `instance_data_keys` keeps one row, `ON CONFLICT DO
  # NOTHING` leaves the first's, and the read after takes it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{PublicId, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Secrets.{Instance, InstanceDataKey, InstanceSecretValue}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  setup :setup_races

  setup do
    assert Repo.all(InstanceDataKey) == [], "an instance data key was left by another test"
    adapters = [adapter!(), adapter!()]

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      ids = Enum.map(adapters, & &1.id)
      # The instance secrets go with their nodes (`ON DELETE CASCADE`).
      Repo.delete_all(from n in Node, where: n.id in ^ids)
      Repo.delete_all(InstanceDataKey)
      Sandbox.checkin(Repo)
    end)

    %{adapters: adapters}
  end

  # An adapter of the instance, committed: the row alone, which is all a write needs.
  defp adapter! do
    Repo.insert!(%Node{
      kind: :adapter,
      name: "Races adapter #{System.unique_integer([:positive])}",
      public_id: PublicId.generate("na"),
      gateway_choice: :direct
    })
  end

  defp put(adapter, value),
    do: Instance.put_app_values(adapter, [%InstanceSecretValue{value_id: "key", value: value}])

  test "two adapters' first secrets at once make one data key", %{adapters: [one, two]} do
    {first, first_pid} = hold(fn -> put(one, "one value") end)
    assert {:ok, %{revision: 1}} = first.result

    second = start(fn -> put(two, "two value") end)

    # The second's insert of the key waits on the first's, not yet committed.
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %{revision: 1}} = Task.await(second.task)
    assert [%InstanceDataKey{}] = Repo.all(InstanceDataKey)

    for {adapter, value} <- [{one, "one value"}, {two, "two value"}] do
      assert {:ok, %{values: [%InstanceSecretValue{value: ^value}]}} =
               Instance.reveal_app_values_for_sealing(adapter)
    end
  end
end
