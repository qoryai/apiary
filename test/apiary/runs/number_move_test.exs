defmodule Apiary.Runs.NumberMoveTest do
  # A work item that moves to another workspace by a Take in again
  # (`Apiary.WorkItems.take_in_again/3`) raises the target's run counter past its highest
  # run number (`Apiary.Runs.Number.raise_past/2`), so all the runs of one work item have
  # different numbers. A document of the work item refers to a run by its number, so the
  # question of a run of the old workspace does not count as one of a new run.
  # Not async: a process saved here is read by its stage runner, as `Apiary.StagesTest`.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Explore.Questions
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    there = workspace_scope(scope.user, workspace_fixture(scope.organisation))

    %{scope: scope, connection: connection, ticket: ticket, work_item: work_item, there: there}
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp move(ctx, there),
    do: moved_work_item_fixture(ctx.scope, ctx.work_item, ctx.ticket, ctx.connection, there)

  # `count` registered runs of `work_item`, ended, in its workspace, their numbers. A take
  # in has at most three runs, so each run here has a take in that no other run has.
  defp runs!(work_item, count) do
    for _ <- 1..count do
      take_in = System.unique_integer([:positive])
      explore_run_fixture(reload(work_item), take_in: take_in, settle: false).run.number
    end
  end

  defp counter(scope) do
    Repo.one(
      from c in "run_counters",
        where: c.workspace_id == ^Ecto.UUID.dump!(scope.workspace.id),
        select: c.last_number
    )
  end

  defp numbers(work_item) do
    Repo.all(
      from r in Run,
        join: d in DispatchRun,
        on: d.id == r.dispatch_run_id,
        where: d.work_item_id == ^work_item.id,
        order_by: r.inserted_at,
        select: r.number
    )
  end

  test "the next run in a fresh target goes on from the work item's highest number", ctx do
    assert List.last(runs!(ctx.work_item, 5)) == 5
    assert counter(ctx.there) == nil

    %{work_item: moved} = move(ctx, ctx.there)
    assert counter(ctx.there) == 5

    assert runs!(moved, 1) == [6]
    assert run_fixture(ctx.there).number == 7

    # The workspace it left goes on from its count.
    assert run_fixture(ctx.scope).number == 6
  end

  test "a target already past the highest number does not change", ctx do
    runs!(ctx.work_item, 2)
    for _ <- 1..9, do: run_fixture(ctx.there)
    assert counter(ctx.there) == 9

    %{work_item: moved} = move(ctx, ctx.there)

    assert counter(ctx.there) == 9
    assert runs!(moved, 1) == [10]
  end

  test "a work item with no runs raises nothing, and makes no counter", ctx do
    assert numbers(ctx.work_item) == []

    move(ctx, ctx.there)

    assert counter(ctx.there) == nil
    assert run_fixture(ctx.there).number == 1
  end

  test "a take in again in the same workspace changes no counter", ctx do
    runs!(ctx.work_item, 2)
    before = counter(ctx.scope)

    Repo.update_all(from(d in DispatchRun, where: d.work_item_id == ^ctx.work_item.id),
      set: [state: :ended, end_cause: :run_ended]
    )

    {:ok, _closed} = WorkItems.close(ctx.scope, reload(ctx.work_item))
    {:ok, _again} = WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id)

    assert counter(ctx.scope) == before
  end

  test "two moves in a row keep the numbers of the work item's runs different", ctx do
    runs!(ctx.work_item, 1)

    %{work_item: there, ticket: record} = move(ctx, ctx.there)
    runs!(there, 2)

    # The workspace it comes back to has a counter, lower than the work item's highest.
    assert counter(ctx.scope) == 1

    %{work_item: back} =
      moved_work_item_fixture(ctx.there, there, record, ctx.connection, ctx.scope)

    assert back.workspace_id == ctx.scope.workspace.id
    assert counter(ctx.scope) == 3
    runs!(back, 2)

    assert Enum.sort(numbers(back)) == [1, 2, 3, 4, 5]
  end

  test "a workspace with no moved work item starts at Run 1", ctx do
    runs!(ctx.work_item, 3)
    assert run_fixture(ctx.there).number == 1
  end

  test "with a question left open in the old workspace, a proposal of the new one goes to the gate",
       ctx do
    # The first run, in the old workspace, writes a question, which stays open.
    asking = end_run!(reload(ctx.work_item), questions_result(["Which basket?"]))
    assert numbers(asking) == [1]
    assert asking.stage_state == :waiting_answers

    %{work_item: moved} = move(ctx, ctx.there)

    # The next run in the fresh workspace proposes, and the work item stands at the gate.
    proposed = end_run!(moved, understood_result())
    assert numbers(proposed) == [1, 2]

    {:ok, {_version, document}} = Questions.current(proposed)
    runs = Questions.take_in_runs(proposed.id, 2)
    assert Questions.open(document) != []
    assert Questions.open_in_take_in(document, runs) == []

    assert proposed.stage_state == :at_gate
    assert %{take_in: 2, status: :confirm} = WorkItems.explore(ctx.there, proposed)
  end
end
