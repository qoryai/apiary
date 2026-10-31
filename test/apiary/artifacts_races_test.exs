defmodule Apiary.ArtifactsRacesTest do
  # Pushes to one work item racing each other, each on a connection of its own, outside
  # the SQL sandbox, so each commits and each waits on the others' locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Artifacts.push/5`): a push locks its work item
  # `FOR UPDATE` before it finds or makes the artifact and counts its versions, so pushes
  # to one work item take turns, and the numbers of an artifact are 1, 2, … with no gap.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Repo}
  alias Apiary.Artifacts.{Artifact, Version}

  @moduletag :tmp_dir

  setup_all :clean_up

  # What a stopped run left behind: its organisations, then the adapters of the instance
  # its people made, which outlive their organisations, then what `clean_up_leftovers/1`
  # deletes.
  defp clean_up(context) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    Repo.delete_all(from o in Apiary.Organisations.Organisation, where: like(o.name, "Races %"))

    Repo.delete_all(
      from n in Apiary.Nodes.Node,
        join: u in Apiary.Accounts.User,
        on: u.id == n.created_by_id,
        where: n.kind == :adapter and is_nil(n.organisation_id) and like(u.email, "%@races.test")
    )

    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    clean_up_leftovers(context)
  end

  setup :setup_races

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{scope: scope, organisation: organisation} = sign_up()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item)

    # The work item's ticket comes through an adapter of the instance, which outlives the
    # organisation: it goes after the organisation, before `setup_races` deletes the
    # person who made it.
    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^organisation.id
      )

      Repo.delete_all(from n in Apiary.Nodes.Node, where: n.id == ^work_item.adapter_id)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    %{work_item: work_item, run: run}
  end

  test "pushes at once to an artifact that is not there yet number its versions with no gap",
       %{work_item: work_item, run: run} do
    sides = sides(6)

    results =
      together(
        for n <- 1..sides do
          fn ->
            Artifacts.push({:run, run}, work_item, "explainer", [
              %{filename: "v#{n}.md", content_type: "text/markdown", binary: "# Version #{n}"}
            ])
          end
        end
      )

    assert Enum.all?(results, &match?({:ok, %Version{}}, &1))

    assert results |> Enum.map(fn {:ok, v} -> v.number end) |> Enum.sort() ==
             Enum.to_list(1..sides)

    assert [%Artifact{id: artifact_id}] =
             Repo.all(from a in Artifact, where: a.work_item_id == ^work_item.id)

    assert Repo.all(
             from v in Version,
               where: v.artifact_id == ^artifact_id,
               order_by: v.number,
               select: v.number
           ) == Enum.to_list(1..sides)
  end
end
