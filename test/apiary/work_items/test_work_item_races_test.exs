defmodule Apiary.WorkItems.TestWorkItemRacesTest do
  # Two take ins of a test in one workspace at once (`Apiary.WorkItems.take_in_test/2`).
  # Each side runs on a separate connection, outside the SQL sandbox, so each commits and
  # each waits on the other's locks as it would in production. Not async: what these
  # tests commit is visible to every other test while they run, and they delete it again
  # before they end.
  #
  # The rules under test: a workspace has one live test work item. The second take in of a
  # test waits for the first, then is refused, `:test_running`, by the index on live test
  # work items, whether there was no test work item before or one whose runs had ended or
  # still waited, which the first closes. A take in of a test and a claim of the earlier
  # one's waiting run take turns on the run's row: a claim first leaves the run claimed
  # and the take in refused; a take in first ends the run, and the claim skips it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.Races

  alias Apiary.{Dispatches, Repo, WorkItems}
  alias Apiary.AccessKeys.{AccessKey, PublicKey}
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Organisations.Organisation
  alias Apiary.WorkItems.WorkItem
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  # Wide, so a slow machine fails no race by its clock.
  @await 60_000

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    %{scope: scope}
  end

  defp take_in_test(ctx, line), do: fn -> WorkItems.take_in_test(ctx.scope, line) end
  defp await(%{task: task}), do: Task.await(task, @await)

  defp runs(work_item),
    do: Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

  defp work_items(ctx),
    do:
      Repo.all(
        from w in WorkItem,
          where: w.organisation_id == ^ctx.scope.organisation.id,
          order_by: w.number
      )

  test "with no test work item, the second waits, then is refused; one is made", ctx do
    {first, first_pid} = hold(take_in_test(ctx, "First line"))
    assert {:ok, %WorkItem{id: id}} = first.result

    second = start(take_in_test(ctx, "Second line"))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:error, :test_running}
    assert [%WorkItem{id: ^id, state: :exploring}] = work_items(ctx)
  end

  test "with one whose runs ended, the first closes it, and the second waits, then is refused",
       ctx do
    {:ok, last} = take_in_test(ctx, "Last line").()

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^last.id),
        set: [state: :ended, end_cause: :lost, updated_at: DateTime.utc_now()]
      )

    {first, first_pid} = hold(take_in_test(ctx, "First line"))
    assert {:ok, %WorkItem{id: id}} = first.result

    second = start(take_in_test(ctx, "Second line"))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:error, :test_running}
    last_id = last.id

    assert [%WorkItem{id: ^last_id, state: :closed}, %WorkItem{id: ^id, state: :exploring}] =
             work_items(ctx)
  end

  test "with one whose run still waits, the first ends the run and closes it, and the second waits, then is refused",
       ctx do
    {:ok, last} = take_in_test(ctx, "Last line").()
    [waiting] = runs(last)

    {first, first_pid} = hold(take_in_test(ctx, "First line"))
    assert {:ok, %WorkItem{id: id}} = first.result

    second = start(take_in_test(ctx, "Second line"))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:error, :test_running}
    assert %DispatchRun{state: :ended, end_cause: :closed} = Repo.reload!(waiting)
    last_id = last.id

    assert [%WorkItem{id: ^last_id, state: :closed}, %WorkItem{id: ^id, state: :exploring}] =
             work_items(ctx)
  end

  test "many at once: one stays live, and each other is refused or closed the one before",
       ctx do
    answers = together(List.duplicate(take_in_test(ctx, "A line"), sides(4)))

    made = for {:ok, %WorkItem{id: id}} <- answers, do: id
    assert made != []
    assert Enum.count(answers, &(&1 == {:error, :test_running})) == length(answers) - length(made)

    # The one made last is live; each made before it was closed by the next.
    assert [live_id] = for(%WorkItem{state: :exploring, id: id} <- work_items(ctx), do: id)
    assert live_id in made
    assert length(work_items(ctx)) == length(made)
  end

  describe "a claim of the earlier one's waiting run" do
    setup ctx do
      gateway = workspace_gateway!(ctx.scope)
      %{access_key: key, pair: pair} = enrolled_key_fixture(ctx.scope, pool_fixture(ctx.scope))

      gateway_key =
        Repo.one!(from k in AccessKey, where: k.node_id == ^gateway.id, select: k.public_key)

      # Before the clean up of `setup_races`: the organisation, then the keys' public
      # halves, which outlive it.
      on_exit(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        Repo.delete_all(from o in Organisation, where: o.id == ^ctx.scope.organisation.id)

        Repo.delete_all(
          from p in PublicKey, where: p.public_key in ^[gateway_key, pair.public_key]
        )

        Sandbox.checkin(Repo)
      end)

      {:ok, last} = take_in_test(ctx, "Last line").()
      [waiting] = runs(last)
      %{key: key, last: last, waiting: waiting}
    end

    defp claim(ctx), do: fn -> Dispatches.claim(ctx.key, Dispatches.now()) end

    defp dispatches(run),
      do: Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^run.id)

    test "the claim first: the take in waits, then is refused, and the run stays claimed",
         ctx do
      {first, first_pid} = hold(claim(ctx))
      assert {:ok, %{run: %DispatchRun{id: run_id}}} = first.result
      assert run_id == ctx.waiting.id

      second = start(take_in_test(ctx, "Once more"))
      await_blocked(second.backend, first_pid)
      commit(first)

      assert await(second) == {:error, :test_running}
      assert %DispatchRun{state: :claimed, end_cause: nil} = Repo.reload!(ctx.waiting)
      assert [_dispatch] = dispatches(ctx.waiting)
      assert [%WorkItem{state: :exploring}] = work_items(ctx)
    end

    test "the take in first: the run ends closed, and the claim does not take it", ctx do
      {first, _first_pid} = hold(take_in_test(ctx, "Once more"))
      assert {:ok, %WorkItem{id: id}} = first.result

      # The claim skips the run the take in holds, and cannot see the new one yet.
      assert Task.await(start(claim(ctx)).task, @await) == {:ok, :none}
      commit(first)

      assert %DispatchRun{state: :ended, end_cause: :closed} = Repo.reload!(ctx.waiting)
      assert dispatches(ctx.waiting) == []
      last_id = ctx.last.id

      assert [%WorkItem{id: ^last_id, state: :closed}, %WorkItem{id: ^id, state: :exploring}] =
               work_items(ctx)
    end
  end
end
