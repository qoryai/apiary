defmodule Apiary.NodesRacesTest do
  # Two starts racing for a node's last slot. Each side runs on a connection of its own,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other test
  # while they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Nodes.check_instance_limit/3`, `admit/4`): the check locks
  # the node's row `FOR UPDATE` before it counts, and the run the admitted side creates in
  # the same transaction is the reservation. So a second check for the last slot waits for
  # the first side's transaction, then counts its committed run, and is refused.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Nodes, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Registration, Run}

  setup_all :clean_up_leftovers
  setup :setup_races

  # A run of `instance_id` on `node`, as the batch that creates it stores it.
  defp start_run(node, instance_id), do: {:ok, node_run_fixture(node, instance_id)}

  defp runs(node),
    do: Repo.all(from r in Run, where: r.node_id == ^node.id, select: r.instance_id)

  test "the second start for a node's one slot waits for the first, and is refused" do
    %{scope: scope} = sign_up()
    node = node_fixture(scope, name: "build-01")
    now = DateTime.utc_now()

    # The first side has counted and reserved, and holds its transaction open.
    {first, first_pid} =
      hold(fn ->
        :ok = Nodes.check_instance_limit(node, "i_1", now)
        start_run(node, "i_1")
      end)

    assert {:ok, %Run{}} = first.result

    second = start(fn -> Nodes.admit(node, "i_2", fn -> start_run(node, "i_2") end, now) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:error, :instance_limit}
    assert runs(node) == ["i_1"]
    assert %Node{instance_limit_refused: 1} = Repo.get!(Node, node.id)
  end

  test "of two starts at once for a pool's last slot, one is admitted" do
    %{scope: scope} = sign_up()
    pool = pool_fixture(scope, name: "spot-runners", instance_limit: 2)
    node_run_fixture(pool, "i_0")

    answers =
      together([
        fn -> Nodes.admit(pool, "i_1", fn -> start_run(pool, "i_1") end) end,
        fn -> Nodes.admit(pool, "i_2", fn -> start_run(pool, "i_2") end) end
      ])

    assert Enum.count(answers, &match?({:ok, %Run{}}, &1)) == 1
    assert Enum.count(answers, &(&1 == {:error, :instance_limit})) == 1
    assert length(runs(pool)) == 2
    assert %Node{instance_limit_refused: 1} = Repo.get!(Node, pool.id)
  end

  # A run's registration, as `Apiary.Runs.Registration.register/3` takes it, from
  # `instance_id` under `key`.
  defp register(key, run_id, instance_id) do
    body =
      Jason.encode!(%{
        "version" => 1,
        "run_id" => run_id,
        "labels" => %{},
        "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "forager_version" => "0.8.0",
        "contract_version" => 1,
        "interval_seconds" => 30,
        "events" => ["*"]
      })

    {:ok, registration} = Registration.parse(Jason.decode!(body))
    meta = %{body: body, contract_version: 1, instance_id: instance_id}
    fn -> Registration.register(key, registration, meta) end
  end

  test "of two registrations at once for a pool's last slot, one is admitted" do
    %{scope: scope} = sign_up()
    pool = pool_fixture(scope, name: "spot-runners", instance_limit: 2)
    %{access_key: key} = Apiary.AccessKeysFixtures.access_key_fixture(scope, node: pool)
    node_run_fixture(pool, "i_0")

    answers =
      together([
        register(key, Ecto.UUID.generate(), "i_1"),
        register(key, Ecto.UUID.generate(), "i_2")
      ])

    assert Enum.count(answers, &match?({:ok, %{run: %Run{}}}, &1)) == 1
    assert Enum.count(answers, &(&1 == {:error, :instance_limit})) == 1
    assert length(runs(pool)) == 2
    assert %Node{instance_limit_refused: 1} = Repo.get!(Node, pool.id)
  end

  test "the same registration twice at once is one run, stored once and answered twice" do
    %{scope: scope} = sign_up()
    node = node_fixture(scope, name: "build-01")
    %{access_key: key} = Apiary.AccessKeysFixtures.access_key_fixture(scope, node: node)
    same = register(key, Ecto.UUID.generate(), "i_1")

    answers = together([same, same])

    assert [false, true] ==
             answers |> Enum.map(fn {:ok, %{repeated: repeated}} -> repeated end) |> Enum.sort()

    assert runs(node) == ["i_1"]
    assert %Node{instance_limit_refused: 0} = Repo.get!(Node, node.id)
  end
end
