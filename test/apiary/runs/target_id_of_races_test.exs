defmodule Apiary.Runs.TargetIdOfRacesTest do
  # A target's row read or made (`Apiary.Runs.Target.id_of/3`) while another
  # transaction makes the same row. Each side runs on a separate connection, outside the
  # SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.NodesFixtures, only: [bare_adapter_fixture: 0]
  import Apiary.Races

  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.Target

  setup_all :clean_up_leftovers
  setup :setup_races

  # The adapter has no organisation, so the organisation's deletion leaves it: its rows
  # go first, then the adapter, on a connection given back for the organisation's
  # deletion after it.
  setup do
    adapter = bare_adapter_fixture()

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from t in Target, where: t.adapter_id == ^adapter.id)
      Repo.delete_all(from n in Node, where: n.id == ^adapter.id)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    %{adapter: adapter}
  end

  defp target(adapter, path),
    do: %{
      adapter_id: adapter.id,
      collection_external_ref: "C_1",
      system: "code.example.com",
      path: path
    }

  test "a row made between the read and the insert is the one returned, at its address",
       %{adapter: adapter} do
    %{organisation: organisation, workspace: workspace} = sign_up()
    org = organisation.id
    ws = workspace.id

    # The first side makes the row and keeps its transaction open, so the second side's
    # read finds no row and its insert waits on the row's key.
    {first, first_pid} =
      hold(fn -> :ok = Target.insert_new(org, ws, [target(adapter, "acme/shop")]) end)

    second = start(fn -> Target.id_of(org, ws, target(adapter, "acme/web")) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    id = Task.await(second.task)

    assert [%Target{id: ^id, path: "acme/shop"}] =
             Repo.all(from t in Target, where: t.workspace_id == ^ws)
  end
end
