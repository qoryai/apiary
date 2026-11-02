defmodule Apiary.ArtifactsRacesTest do
  # Pushes to one work item racing each other, each on a connection of its own, outside
  # the SQL sandbox, so each commits and each waits on the others' locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Artifacts.push/5`): a push locks its work item
  # `FOR UPDATE` before it finds or makes the artifact and counts its versions, so pushes
  # to one work item take turns, and the numbers of an artifact are 1, 2, … with no gap.
  # Before that lock, a push of a standard type a workspace can hide takes the workspace
  # `FOR SHARE`, the core's lock order; a push of an always-on type takes no such lock.
  # A switch of a standard type (`Apiary.Artifacts.switch_type/4`) holds the workspace
  # `FOR NO KEY UPDATE`, so it runs before or after such a push or a change of the
  # process.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo}
  alias Apiary.Artifacts.{Artifact, Type, Version}
  alias Apiary.Organisations.Workspace
  alias Apiary.WorkItems.WorkItem

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

    %{scope: scope, work_item: work_item, run: run}
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

  # What a process change holds (`Apiary.Processes`): the workspace `FOR NO KEY UPDATE`.
  defp hold_workspace(%WorkItem{workspace_id: id}) do
    hold(fn ->
      Repo.one!(from w in Workspace, where: w.id == ^id, select: w.id, lock: "FOR NO KEY UPDATE")
    end)
  end

  test "a push of a type a workspace can hide waits on the workspace before the work item",
       %{work_item: work_item, run: run} do
    {held, holder} = hold_workspace(work_item)

    push =
      start(fn ->
        Artifacts.push({:run, run}, work_item, "explainer", [
          %{filename: "plan.md", content_type: "text/markdown", binary: "# Plan"}
        ])
      end)

    await_blocked(push.backend, holder)

    # The holder writes the work item, as a process change does. A push that took the work
    # item first would wait on the holder here, and the holder on the push.
    assert {1, nil} =
             continue(held, fn ->
               Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
                 set: [updated_at: DateTime.utc_now()]
               )
             end)

    commit(held)
    assert {:ok, %Version{}} = Task.await(push.task, 15_000)
  end

  test "a push of an always-on type goes past a held workspace", %{
    work_item: work_item,
    run: run
  } do
    {held, _holder} = hold_workspace(work_item)

    push =
      start(fn ->
        Artifacts.push({:run, run}, work_item, "verdict", [
          %{
            filename: "verdict.json",
            content_type: "application/json",
            binary: ~s({"verdict":"passed"})
          }
        ])
      end)

    assert {:ok, %Version{}} = Task.await(push.task, 15_000)
    commit(held)
  end

  defp plan, do: [%{filename: "plan.md", content_type: "text/markdown", binary: "# Plan"}]

  @tag needs: :workflow_model
  test "a push that comes after a switch off waits for it, and then finds the type hidden",
       %{scope: scope, work_item: work_item, run: run} do
    {held, holder} =
      hold(fn -> Artifacts.switch_type(scope, scope.workspace, "explainer", false) end)

    assert {:ok, %Type{shown: false}} = held.result

    push = start(fn -> Artifacts.push({:run, run}, work_item, "explainer", plan()) end)

    await_blocked(push.backend, holder)
    commit(held)

    assert {:error, {:unknown_type, "explainer"}} = Task.await(push.task, 15_000)
    assert Repo.all(from a in Artifact, where: a.work_item_id == ^work_item.id) == []
  end

  @tag needs: :workflow_model
  test "a switch off that comes after a push waits for it, and then finds the artifact",
       %{scope: scope, work_item: work_item, run: run} do
    {held, holder} =
      hold(fn -> Artifacts.push({:run, run}, work_item, "explainer", plan()) end)

    assert {:ok, %Version{}} = held.result

    switch = start(fn -> Artifacts.switch_type(scope, scope.workspace, "explainer", false) end)

    await_blocked(switch.backend, holder)
    commit(held)

    assert {:error, :has_artifacts} = Task.await(switch.task, 15_000)
    assert Repo.get!(Workspace, scope.workspace.id).shown_standard_types == nil
  end

  @tag needs: :workflow_model
  test "a switch off that comes after a process save waits for it, and then finds the type",
       %{scope: scope} do
    document = Processes.default_document("software")
    [first | rest] = document["stages"]
    output = %{"type" => "explainer", "required" => true}
    first = Map.update!(first, "outputs", &(&1 ++ [output]))

    {held, holder} =
      hold(fn ->
        Processes.save(scope, scope.workspace, %{document | "stages" => [first | rest]})
      end)

    assert {:ok, %Processes.Version{}} = held.result

    switch = start(fn -> Artifacts.switch_type(scope, scope.workspace, "explainer", false) end)

    await_blocked(switch.backend, holder)
    commit(held)

    assert {:error, :current_process} = Task.await(switch.task, 15_000)
  end
end
