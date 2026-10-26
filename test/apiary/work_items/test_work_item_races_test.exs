defmodule Apiary.WorkItems.TestWorkItemRacesTest do
  # Two take ins of a test in one workspace at once (`Apiary.WorkItems.take_in_test/2`).
  # Each side runs on a separate connection, outside the SQL sandbox, so each commits and
  # each waits on the other's locks as it would in production. Not async: what these
  # tests commit is visible to every other test while they run, and they delete it again
  # before they end.
  #
  # The rule under test: a workspace has one live test work item. The second take in of a
  # test waits for the first, then is refused, `:test_running`, by the index on live test
  # work items, whether there was no test work item before or one whose runs had ended,
  # which the first closes.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItem

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

  test "many at once: one is made, and each other is refused", ctx do
    answers = together(List.duplicate(take_in_test(ctx, "A line"), sides(4)))

    assert [{:ok, %WorkItem{id: id}}] = Enum.filter(answers, &match?({:ok, _}, &1))
    assert Enum.count(answers, &(&1 == {:error, :test_running})) == length(answers) - 1
    assert [%WorkItem{id: ^id}] = work_items(ctx)
  end
end
