defmodule Apiary.Runs.PushedCommitRacesTest do
  # Reports of pushed commits racing each other (`Apiary.Runs.PushedCommit.record/3`), each
  # on a separate connection, outside the SQL sandbox, so each commits and each waits on
  # the other's lock as it would in production. Not async: what these tests commit is
  # visible to every other test while they run, and they delete it again before they end.
  #
  # The rule under test: a report takes the work item's row `FOR UPDATE` before it reads
  # the run's list, so two reports of one run take turns. The second reads what the first
  # stored: the positions run 1, 2, ... with no gap, and a commit that both send is stored
  # once, with no unique-index error.
  use ExUnit.Case, async: false

  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.Repo
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{PushedCommit, Run}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)
  @c String.duplicate("c", 64)

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    work_item = work_item_fixture(scope)

    # Before the clean up of `setup_races`: the organisation, then the adapter that
    # outlives it.
    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from k in AccessKey, where: k.node_id == ^work_item.adapter_id)
      Repo.delete_all(from c in EnrolmentCode, where: c.node_id == ^work_item.adapter_id)
      Repo.delete_all(from n in Node, where: n.id == ^work_item.adapter_id)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    queued =
      Repo.insert!(%DispatchRun{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        work_item_id: work_item.id,
        run_id: Ecto.UUID.generate(),
        step: "build",
        take_in: 1,
        attempt: 1,
        of: 1,
        queued_at: Apiary.Dispatches.now()
      })

    run =
      Apiary.RunEventsFixtures.run_fixture(scope, %{
        dispatch_run_id: queued.id,
        state: "running",
        started_at: DateTime.utc_now()
      })

    %{work_item: work_item, run: run}
  end

  defp report(commit, path \\ "acme/shop"), do: [%{system: "forge", path: path, commit: commit}]

  defp rows(run) do
    Repo.all(
      from c in PushedCommit,
        where: c.run_id == ^run.id,
        order_by: c.sequence,
        select: {c.sequence, c.commit}
    )
  end

  # Holds the work item's lock in a transaction on a separate connection, starts one report
  # for each of `reports` on a connection each, waits until each waits in the queue for
  # that lock, then lets the lock go and returns the answers.
  defp race(ctx, reports) do
    {held, held_backend} =
      hold(fn ->
        Repo.one!(
          from w in WorkItem, where: w.id == ^ctx.work_item.id, lock: "FOR UPDATE", select: 1
        )
      end)

    # Each side starts after the one before it waits: the first waits on the held
    # transaction, each next one on the side before it, which holds the row's tuple lock.
    {sides, _blocker} =
      Enum.map_reduce(reports, held_backend, fn repositories, blocker ->
        side = start(fn -> PushedCommit.record(ctx.work_item, ctx.run, repositories) end)
        await_blocked(side.backend, blocker)
        {side, side.backend}
      end)

    commit(held)
    for side <- sides, do: Task.await(side.task, 10_000)
  end

  test "two reports of different commits take turns: positions 1 and 2, no gap", ctx do
    assert [:ok, :ok] = race(ctx, [report(@a), report(@b)])

    assert [{1, first}, {2, second}] = rows(ctx.run)
    assert Enum.sort([first, second]) == [@a, @b]
  end

  test "two reports of one commit store it once, and neither fails", ctx do
    assert [:ok, :ok] = race(ctx, [report(@c), report(@c)])
    assert rows(ctx.run) == [{1, @c}]
  end

  test "overlapping reports store each commit once, in positions without a gap", ctx do
    assert [:ok, :ok, :ok] =
             race(ctx, [
               [hd(report(@a)), hd(report(@b))],
               [hd(report(@b)), hd(report(@c))],
               report(@a)
             ])

    assert [{1, _}, {2, _}, {3, _}] = rows = rows(ctx.run)
    assert rows |> Enum.map(&elem(&1, 1)) |> Enum.sort() == Enum.sort([@a, @b, @c])
  end

  test "a report racing the end of the run is stored or refused, never half stored", ctx do
    queued_id = ctx.run.dispatch_run_id

    {held, held_backend} =
      hold(fn ->
        Repo.one!(
          from w in WorkItem, where: w.id == ^ctx.work_item.id, lock: "FOR UPDATE", select: 1
        )
      end)

    side = start(fn -> PushedCommit.record(ctx.work_item, ctx.run, report(@a)) end)
    await_blocked(side.backend, held_backend)

    # The run's end, as the end of a run writes it under the work item's lock.
    {1, _rows} =
      continue(held, fn ->
        Repo.update_all(from(d in DispatchRun, where: d.id == ^queued_id),
          set: [state: :ended, end_cause: :run_ended]
        )
      end)

    commit(held)

    assert {:error, :run_ended} = Task.await(side.task, 10_000)
    assert rows(ctx.run) == []
    assert %Run{} = Repo.get!(Run, ctx.run.id)
  end
end
