defmodule Apiary.WorkItems.NumberTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.WorkItems.Number

  defp counter(workspace) do
    %{rows: rows} =
      Repo.query!(
        "SELECT organisation_id, last_number FROM work_item_counters WHERE workspace_id = $1",
        [Ecto.UUID.dump!(workspace.id)]
      )

    rows
  end

  test "a workspace's numbers start at 1 and go up by one" do
    %{workspace: workspace} = sign_up_fixture()

    assert counter(workspace) == []
    assert Enum.map(1..3, fn _ -> Number.next(workspace) end) == [1, 2, 3]
    assert [[organisation_id, 3]] = counter(workspace)
    assert Ecto.UUID.load!(organisation_id) == workspace.organisation_id
  end

  test "each workspace counts apart from the others" do
    %{workspace: workspace, organisation: organisation} = sign_up_fixture()
    second = workspace_fixture(organisation)
    %{workspace: elsewhere} = sign_up_fixture()

    assert Number.next(workspace) == 1
    assert Number.next(workspace) == 2
    assert Number.next(second) == 1
    assert Number.next(elsewhere) == 1
    assert Number.next(workspace) == 3
  end

  test "a number taken in a transaction that rolls back is given back" do
    %{workspace: workspace} = sign_up_fixture()
    assert Number.next(workspace) == 1

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               assert Number.next(workspace) == 2
               Repo.rollback(:rolled_back)
             end)

    assert Number.next(workspace) == 2
  end
end
