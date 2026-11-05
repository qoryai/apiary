defmodule Apiary.Runs.NumberRacesTest do
  # Runs of one workspace numbered at the same time. Each side runs on a separate
  # connection, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Runs.Number.next/1`): the upsert that takes a number locks
  # the workspace's counter until its transaction ends, the row made by the first number
  # included. So a second number waits for the first side's transaction, then takes the one
  # after it, and no two runs of a workspace have one number.
  #
  # The order of two locks under test (`Apiary.Runs.Number.next/2`): a run on a node locks
  # the node, then the counter, as `Apiary.Nodes.admit/4` does.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Ingest, Number, Registration, Run}

  setup_all :clean_up_leftovers
  setup :setup_races

  defp take(workspace), do: fn -> Repo.transact(fn -> {:ok, Number.next(workspace)} end) end

  defp insert(workspace) do
    fn ->
      Repo.transact(fn ->
        {:ok,
         Repo.insert!(%Run{
           number: Number.next(workspace),
           public_id: Run.new_public_id(),
           organisation_id: workspace.organisation_id,
           workspace_id: workspace.id,
           node_run_id: Ecto.UUID.generate()
         }).number}
      end)
    end
  end

  defp insert_no_number(workspace) do
    fn ->
      Repo.transact(fn ->
        {:ok,
         Repo.insert!(%Run{
           public_id: Run.new_public_id(),
           organisation_id: workspace.organisation_id,
           workspace_id: workspace.id,
           node_run_id: Ecto.UUID.generate()
         }).number}
      end)
    end
  end

  test "the second number of a workspace waits for the first, and takes the next one" do
    %{workspace: workspace} = sign_up()

    {first, first_pid} = hold(fn -> Number.next(workspace) end)
    assert first.result == 1

    second = start(take(workspace))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:ok, 2}
  end

  # Twelve at most, and no more than the pool has beside the test's connection: each
  # side keeps its connection until all are let go.
  test "of many runs inserted at once in one workspace, each has a different number" do
    %{workspace: workspace} = sign_up()
    count = sides(12)

    answers = together(for _ <- 1..count, do: insert(workspace))

    assert Enum.sort(answers) == Enum.map(1..count, &{:ok, &1})
  end

  describe "a run on a node whose row an instance limit check locked" do
    # The first side locks the node's row `FOR UPDATE`, as
    # `Apiary.Nodes.check_instance_limit/3` does. The second side waits for the node with
    # the counter free, so the first takes its number and commits. A second side that took
    # the counter first ends in `deadlock_detected`.
    defp locks_the_node(second) do
      %{scope: scope} = sign_up()
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = access_key_fixture(scope, node: node)

      {first, first_pid} =
        hold(fn ->
          Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE", select: n.id)
        end)

      waiting = start(second.(key))
      await_blocked(waiting.backend, first_pid)

      assert continue(first, fn -> Number.next(scope.workspace) end) == 1
      commit(first)

      Task.await(waiting.task)
    end

    test "a first batch waits for the node, then takes the next number" do
      batch = fn key ->
        fn ->
          subject = Ecto.UUID.generate()
          event = wire_event(subject, 3, "run.heartbeat", %{"elapsed_seconds" => 30})
          {:ok, batch} = [event] |> Jason.encode!() |> Batch.parse()
          Ingest.ingest(key, batch, %{contract_version: 1})
        end
      end

      assert {:ok, %{run: %Run{number: 2}}} = locks_the_node(batch)
    end

    test "a registration with no instance id waits for the node, then takes the next number" do
      registration = fn key ->
        fn ->
          body =
            Jason.encode!(%{
              "version" => 1,
              "run_id" => Ecto.UUID.generate(),
              "labels" => %{},
              "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
              "forager_version" => "0.8.0",
              "contract_version" => 1,
              "interval_seconds" => 30,
              "events" => ["*"]
            })

          {:ok, parsed} = Registration.parse(Jason.decode!(body))
          Registration.register(key, parsed, %{body: body, contract_version: 1})
        end
      end

      assert {:ok, %{run: %Run{number: 2}}} = locks_the_node(registration)
    end
  end

  # The trigger `runs_number_from_counter` numbers an insert with no number, as the previous
  # release writes it, from the same row of the counter.
  test "inserts with and without a number at once have different numbers, 1 to N" do
    %{workspace: workspace} = sign_up()
    count = sides(12)

    answers =
      together(
        for side <- 1..count do
          if rem(side, 2) == 0, do: insert(workspace), else: insert_no_number(workspace)
        end
      )

    assert Enum.sort(answers) == Enum.map(1..count, &{:ok, &1})
  end

  test "a number outside a transaction raises, and none is taken" do
    %{workspace: workspace} = sign_up()

    assert_raise ArgumentError, ~r/inside the transaction/, fn -> Number.next(workspace) end
    assert {:ok, 1} = take(workspace).()
  end
end
