defmodule Apiary.WorkItems.TakeInRacesTest do
  # What a person does to a ticket and its work item, racing another change of the same
  # rows. Each side runs on a separate connection, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they
  # delete it again before they end; the adapters and the keys' public halves, which
  # outlive an organisation, by what they made.
  #
  # The rules under test (`Apiary.WorkItems.Moves`): the lock order, the ticket's
  # connection and collection `FOR SHARE`, then the work item, then the workspace's
  # counter, then the runs of the queue, then the adapter's feed counter, so that every
  # race ends with each side answered and no deadlock; two take ins of one ticket, of
  # which one makes the work item; a take in beside an assign that moves the collection,
  # or a Backlog switch, each waiting for the other; an undo or a decline beside a claim;
  # and a take in again beside an undo.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures, only: [workspace_fixture: 1]
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, WorkItems}
  alias Apiary.AccessKeys.{AccessKey, PublicKey}
  alias Apiary.Adapters.{Collection, Collections, Connection}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  # Wide, so a slow machine fails no race by its clock: a side that never ends fails the
  # test only after this long.
  @await 60_000

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    pool = pool_fixture(scope)
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, pool)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # organisation and its rows first, then the adapter and the key's public half.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      Repo.delete_all(from c in Connection, where: c.adapter_id == ^connection.adapter_id)
      Repo.delete_all(from k in AccessKey, where: k.node_id == ^connection.adapter_id)
      Repo.delete_all(from n in Node, where: n.id == ^connection.adapter_id)
      Repo.delete_all(from p in PublicKey, where: p.public_key == ^pair.public_key)
      Sandbox.checkin(Repo)
    end)

    %{scope: scope, connection: connection, ticket: ticket, key: key}
  end

  defp take_in(ctx), do: fn -> WorkItems.take_in(ctx.scope, ctx.ticket.public_id) end
  defp take_in_again(ctx), do: fn -> WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id) end
  defp undo(ctx, work_item), do: fn -> WorkItems.undo(ctx.scope, work_item) end
  defp decline(ctx, work_item), do: fn -> WorkItems.decline(ctx.scope, work_item) end
  defp claim(ctx), do: fn -> Dispatches.claim(ctx.key, Dispatches.now()) end

  defp move(ctx, workspace) do
    fn ->
      Collections.assign_collections(
        ctx.scope,
        ctx.connection,
        [ctx.ticket.collection_id],
        workspace
      )
    end
  end

  defp backlog_off(ctx, target), do: fn -> Collections.set_backlog(ctx.scope, target, false) end

  defp await(%{task: task}), do: Task.await(task, @await)

  defp taken_in!(ctx) do
    {:ok, work_item} = take_in(ctx).()
    work_item
  end

  defp work_items(ctx),
    do: Repo.all(from w in WorkItem, where: w.organisation_id == ^ctx.scope.organisation.id)

  # The target of the ticket's collection in the scope's workspace, as an assign makes it.
  defp target!(ctx) do
    collection = Repo.get!(Collection, ctx.ticket.collection_id)

    :ok =
      Target.insert_new(ctx.scope.organisation.id, ctx.scope.workspace.id, [
        %{system: collection.target_system, path: collection.target_path}
      ])

    Repo.get_by!(Target,
      workspace_id: ctx.scope.workspace.id,
      system: collection.target_system,
      path: collection.target_path
    )
  end

  describe "two take ins of one ticket" do
    test "the second waits, then finds the work item the first made", ctx do
      {first, first_pid} = hold(take_in(ctx))
      assert {:ok, %WorkItem{id: id}} = first.result

      second = start(take_in(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:error, {:taken, %WorkItem{id: ^id}}} = await(second)
      assert [%WorkItem{id: ^id, number: 1}] = work_items(ctx)
    end

    test "many at once: one makes the work item, and each other finds it", ctx do
      answers = together(List.duplicate(take_in(ctx), sides(4)))

      assert [{:ok, %WorkItem{id: id}}] = Enum.filter(answers, &match?({:ok, _}, &1))

      assert Enum.all?(answers, fn
               {:ok, %WorkItem{id: ^id}} -> true
               {:error, {:taken, %WorkItem{id: ^id}}} -> true
               _other -> false
             end)

      assert [%WorkItem{id: ^id}] = work_items(ctx)
    end
  end

  describe "a take in and an assign that moves the collection" do
    test "the assign waits for the take in, then moves the collection; the work item stays",
         ctx do
      elsewhere = workspace_fixture(ctx.scope.organisation)

      {first, first_pid} = hold(take_in(ctx))
      assert {:ok, %WorkItem{} = work_item} = first.result

      second = start(move(ctx, elsewhere))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert await(second) == {:ok, 1}
      assert %WorkItem{workspace_id: workspace_id} = Repo.get!(WorkItem, work_item.id)
      assert workspace_id == ctx.scope.workspace.id
      assert %Collection{workspace_id: moved} = Repo.get!(Collection, ctx.ticket.collection_id)
      assert moved == elsewhere.id
    end

    test "the take in waits for the assign, then finds the ticket gone from the Backlog", ctx do
      elsewhere = workspace_fixture(ctx.scope.organisation)

      {first, first_pid} = hold(move(ctx, elsewhere))
      assert first.result == {:ok, 1}

      second = start(take_in(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert await(second) == {:error, :not_found}
      assert work_items(ctx) == []
    end
  end

  describe "a take in and a Backlog switch" do
    test "the switch waits for the take in, then turns the Backlog off", ctx do
      target = target!(ctx)

      {first, first_pid} = hold(take_in(ctx))
      assert {:ok, %WorkItem{}} = first.result

      second = start(backlog_off(ctx, target))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert await(second) == {:ok, 1}
      assert [%WorkItem{state: :exploring}] = work_items(ctx)
    end

    test "the take in waits for the switch, then finds the collection not linked", ctx do
      target = target!(ctx)

      {first, first_pid} = hold(backlog_off(ctx, target))
      assert first.result == {:ok, 1}

      second = start(take_in(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert await(second) == {:error, :not_linked}
      assert work_items(ctx) == []
    end
  end

  describe "an undo and a claim" do
    test "the undo waits for the claim, then is refused", ctx do
      work_item = taken_in!(ctx)

      {first, first_pid} = hold(claim(ctx))
      assert {:ok, %{dispatch: _dispatch}} = first.result

      second = start(undo(ctx, work_item))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert await(second) == {:error, :claimed}
      assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, work_item.id)
    end

    test "a claim beside an undo claims nothing once the undo commits", ctx do
      work_item = taken_in!(ctx)

      {first, _first_pid} = hold(undo(ctx, work_item))
      assert {:ok, %WorkItem{state: :undone}} = first.result

      second = start(claim(ctx))
      commit(first)

      assert await(second) == {:ok, :none}
      assert %WorkItem{state: :undone} = Repo.get!(WorkItem, work_item.id)
    end
  end

  test "a decline waits for a claim, then is refused", ctx do
    work_item = taken_in!(ctx)

    {first, first_pid} = hold(claim(ctx))
    assert {:ok, %{dispatch: _dispatch}} = first.result

    second = start(decline(ctx, work_item))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:error, :running}
    assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, work_item.id)
  end

  describe "a take in again and an undo" do
    test "the take in again waits for the undo, then brings the work item back", ctx do
      work_item = taken_in!(ctx)

      {first, first_pid} = hold(undo(ctx, work_item))
      assert {:ok, %WorkItem{state: :undone}} = first.result

      second = start(take_in_again(ctx))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %WorkItem{state: :exploring, take_in: 2}} = await(second)
    end

    test "an undo waits for the take in again, then undoes it", ctx do
      work_item = taken_in!(ctx)
      {:ok, undone} = undo(ctx, work_item).()

      {first, first_pid} = hold(take_in_again(ctx))
      assert {:ok, %WorkItem{take_in: 2}} = first.result

      second = start(undo(ctx, undone))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:ok, %WorkItem{state: :undone, take_in: 2}} = await(second)
    end
  end
end
