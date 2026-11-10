defmodule Apiary.Runs.NumberTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]

  alias Apiary.Runs.Number
  alias Apiary.Runs.Run

  defp next(workspace), do: Repo.transact(fn -> {:ok, Number.next(workspace)} end) |> elem(1)

  defp counter(workspace) do
    %{rows: rows} =
      Repo.query!(
        "SELECT organisation_id, last_number FROM run_counters WHERE workspace_id = $1",
        [Ecto.UUID.dump!(workspace.id)]
      )

    rows
  end

  test "a workspace's numbers start at 1 and go up by one" do
    %{workspace: workspace} = sign_up_fixture()

    assert counter(workspace) == []
    assert Enum.map(1..3, fn _ -> next(workspace) end) == [1, 2, 3]
    assert [[organisation_id, 3]] = counter(workspace)
    assert Ecto.UUID.load!(organisation_id) == workspace.organisation_id
  end

  test "a run inserted with no number has the number the trigger set" do
    %{workspace: workspace} = sign_up_fixture()

    run =
      Repo.insert!(%Run{
        public_id: Run.new_public_id(),
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        node_run_id: Ecto.UUID.generate()
      })

    assert run.number == 1
    assert next(workspace) == 2
  end

  test "each workspace counts apart from the others" do
    %{workspace: workspace, organisation: organisation} = sign_up_fixture()
    second = workspace_fixture(organisation)
    %{workspace: elsewhere} = sign_up_fixture()

    assert next(workspace) == 1
    assert next(workspace) == 2
    assert next(second) == 1
    assert next(elsewhere) == 1
    assert next(workspace) == 3
  end

  test "a first run in a new workspace is Run 1, and two workspaces both have Run 1" do
    %{scope: first} = sign_up_fixture()
    %{scope: second} = sign_up_fixture()

    assert run_fixture(first).number == 1
    assert run_fixture(second).number == 1
    assert run_fixture(first).number == 2
  end

  test "a run's number and a work item's number count apart" do
    %{workspace: workspace} = sign_up_fixture()

    assert Repo.transact(fn -> {:ok, Apiary.WorkItems.Number.next(workspace)} end) == {:ok, 1}
    assert next(workspace) == 1
  end

  test "no two runs of a workspace have one number" do
    %{scope: scope} = sign_up_fixture()
    run = run_fixture(scope)

    assert_raise Ecto.ConstraintError, ~r/runs_workspace_id_number_index/, fn ->
      Repo.insert!(%Run{
        number: run.number,
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        node_run_id: Ecto.UUID.generate(),
        public_id: Run.new_public_id()
      })
    end
  end

  # The previous release sets no number, and runs on this schema.
  test "an insert with no number takes the next one from the counter" do
    %{scope: scope} = sign_up_fixture()
    assert run_fixture(scope).number == 1

    assert %{rows: [[2]]} =
             Repo.query!(
               "INSERT INTO runs (id, organisation_id, workspace_id, node_run_id, state, " <>
                 "public_id, inserted_at, updated_at) " <>
                 "VALUES ($1, $2, $3, $4, 'pending', run_public_id(), now(), now()) " <>
                 "RETURNING number",
               [
                 Ecto.UUID.dump!(Ecto.UUID.generate()),
                 Ecto.UUID.dump!(scope.organisation.id),
                 Ecto.UUID.dump!(scope.workspace.id),
                 Ecto.UUID.dump!(Ecto.UUID.generate())
               ]
             )

    assert run_fixture(scope).number == 3
  end

  test "a deleted run's number stays unused" do
    %{scope: scope} = sign_up_fixture()
    run_fixture(scope)
    deleted = run_fixture(scope)
    Repo.delete!(deleted)

    assert run_fixture(scope).number == deleted.number + 1
  end

  test "a number taken in a transaction that rolls back is given back" do
    %{workspace: workspace} = sign_up_fixture()
    assert next(workspace) == 1

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               assert next(workspace) == 2
               Repo.rollback(:rolled_back)
             end)

    assert next(workspace) == 2
  end

  test "give_back/1 undoes the number of an insert that wrote no row" do
    %{workspace: workspace} = sign_up_fixture()

    assert {:ok, 1} =
             Repo.transact(fn ->
               number = Number.next(workspace)
               Number.give_back(workspace)
               {:ok, number}
             end)

    assert [[_organisation_id, 0]] = counter(workspace)
    assert next(workspace) == 1
  end

  test "block/2 takes numbers in a row" do
    %{workspace: workspace} = sign_up_fixture()
    assert next(workspace) == 1

    assert Repo.transact(fn -> {:ok, Number.block(workspace, 3)} end) == {:ok, 2..4}
    assert next(workspace) == 5
  end

  test "outside a transaction, taking a number raises" do
    %{workspace: workspace} = sign_up_fixture()

    assert_raise ArgumentError, ~r/inside the transaction/, fn -> Number.next(workspace) end
    assert_raise ArgumentError, ~r/inside the transaction/, fn -> Number.give_back(workspace) end
  end
end
