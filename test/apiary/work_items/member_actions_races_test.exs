defmodule Apiary.WorkItems.MemberActionsRacesTest do
  # What a member gives Explore, racing the same action or a decline of the same work
  # item. Each side runs on a separate connection, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they
  # delete it again before they end; the adapter, which outlives an organisation, by what
  # it made.
  #
  # The rule under test (`Apiary.WorkItems.Moves`): an answer, a confirmation and a run
  # asked again hold the work item `FOR UPDATE` before they read where Explore stands, so
  # a second side waits for the first, then reads what the first left: the run it named
  # no longer the latest, the take in confirmed, or the work item ended.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.WorkItems.{Answer, Confirmation, WorkItem, WorkItemEvent}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  # Wide, so a slow machine fails no race by its clock: a side that never ends fails the
  # test only after this long.
  @await 60_000

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    work_item = work_item_fixture(scope)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # organisation and its rows first, then the adapter.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      Repo.delete_all(from c in Connection, where: c.adapter_id == ^work_item.adapter_id)
      Repo.delete_all(from k in AccessKey, where: k.node_id == ^work_item.adapter_id)
      Repo.delete_all(from n in Node, where: n.id == ^work_item.adapter_id)
      Sandbox.checkin(Repo)
    end)

    %{scope: scope, work_item: work_item}
  end

  defp answer(ctx),
    do: fn -> WorkItems.answer(ctx.scope, ctx.work_item, 1, %{"1" => "At checkout."}) end

  defp confirm(ctx), do: fn -> WorkItems.confirm(ctx.scope, ctx.work_item, 1) end
  defp explore_again(ctx), do: fn -> WorkItems.explore_again(ctx.scope, ctx.work_item, 1) end
  defp decline(ctx), do: fn -> WorkItems.decline(ctx.scope, ctx.work_item) end

  defp await(%{task: task}), do: Task.await(task, @await)

  defp asked!(ctx),
    do: explore_run_fixture(ctx.work_item, result: questions_result(["Which basket?"]))

  defp proposed!(ctx), do: explore_run_fixture(ctx.work_item, result: understood_result())

  defp count(schema, ctx),
    do: Repo.aggregate(from(r in schema, where: r.work_item_id == ^ctx.work_item.id), :count)

  defp kinds(ctx),
    do:
      Repo.all(
        from e in WorkItemEvent,
          where: e.work_item_id == ^ctx.work_item.id,
          order_by: [asc: e.at, asc: e.id],
          select: e.kind
      )

  defp runs(ctx),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^ctx.work_item.id,
          order_by: r.attempt,
          select: {r.attempt, r.state}
      )

  # Two sides of `fun`: the first holds the work item, the second waits on it, then
  # answers once the first commits.
  defp twice(fun) do
    {first, first_pid} = hold(fun)
    second = start(fun)
    await_blocked(second.backend, first_pid)
    commit(first)
    {first.result, await(second)}
  end

  test "two answers to one run: the second waits, then finds the run no longer the latest", ctx do
    asked!(ctx)

    assert {{:ok, %WorkItem{}}, {:error, :stale}} = twice(answer(ctx))

    assert count(Answer, ctx) == 1
    assert kinds(ctx) == [:taken_in, :answered]
    assert runs(ctx) == [{1, :ended}, {2, :waiting}]
  end

  test "two runs asked again: the second waits, then finds the run no longer the latest", ctx do
    explore_run_fixture(ctx.work_item)

    assert {{:ok, %WorkItem{}}, {:error, :stale}} = twice(explore_again(ctx))

    assert kinds(ctx) == [:taken_in, :explore_again]
    assert runs(ctx) == [{1, :ended}, {2, :waiting}]
  end

  test "two confirmations of one proposal: the second waits, then finds it confirmed", ctx do
    proposed!(ctx)

    assert {{:ok, %WorkItem{}}, {:error, :not_waiting}} = twice(confirm(ctx))

    assert count(Confirmation, ctx) == 1
    assert kinds(ctx) == [:taken_in, :confirmed]
  end

  test "an answer beside a decline: it waits, then finds the work item declined", ctx do
    asked!(ctx)

    {declined, declined_pid} = hold(decline(ctx))
    assert {:ok, %WorkItem{state: :declined}} = declined.result
    answering = start(answer(ctx))
    await_blocked(answering.backend, declined_pid)
    commit(declined)

    assert {:error, :not_live} = await(answering)
    assert count(Answer, ctx) == 0
    assert kinds(ctx) == [:taken_in, :declined]
  end

  test "a decline beside an answer: it waits, then finds the run the answer queued", ctx do
    asked!(ctx)

    {answered, answered_pid} = hold(answer(ctx))
    assert {:ok, %WorkItem{}} = answered.result
    declining = start(decline(ctx))
    await_blocked(declining.backend, answered_pid)
    commit(answered)

    assert {:error, :running} = await(declining)
    assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
  end

  test "a decline beside a confirmation: it waits, then finds the take in confirmed", ctx do
    proposed!(ctx)

    {confirmed, confirmed_pid} = hold(confirm(ctx))
    assert {:ok, %WorkItem{}} = confirmed.result
    declining = start(decline(ctx))
    await_blocked(declining.backend, confirmed_pid)
    commit(confirmed)

    assert {:error, :confirmed} = await(declining)
    assert %WorkItem{state: :exploring} = Repo.get!(WorkItem, ctx.work_item.id)
  end
end
