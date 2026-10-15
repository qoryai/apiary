defmodule Apiary.WorkItems.NumberRacesTest do
  # Work items of one workspace numbered at the same time. Each side runs on a connection
  # of its own, outside the SQL sandbox, so each commits and each waits on the other's
  # locks as it would in production. Not async: what these tests commit is visible to
  # every other test while they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.WorkItems.Number.next/1`): the upsert that takes a number
  # locks the workspace's counter until its transaction ends, the row made by the first
  # number included. So a second number waits for the first side's transaction, then
  # takes the one after it, and no two work items of a workspace share a number.
  use ExUnit.Case, async: false

  import Apiary.Races

  alias Apiary.Repo
  alias Apiary.WorkItems.Number

  setup_all :clean_up_leftovers
  setup :setup_races

  defp take(workspace), do: fn -> Repo.transact(fn -> {:ok, Number.next(workspace)} end) end

  test "the second number of a workspace waits for the first, and takes the next one" do
    %{workspace: workspace} = sign_up()

    # The first side made the counter's row and holds its transaction open.
    {first, first_pid} = hold(fn -> Number.next(workspace) end)
    assert first.result == 1

    second = start(take(workspace))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:ok, 2}
  end

  test "the wait holds once the counter's row is there too" do
    %{workspace: workspace} = sign_up()
    assert {:ok, 1} = take(workspace).()

    {first, first_pid} = hold(fn -> Number.next(workspace) end)
    assert first.result == 2

    second = start(take(workspace))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:ok, 3}
  end

  test "of many numbers taken at once in one workspace, each is taken once" do
    %{workspace: workspace} = sign_up()

    answers = together(for _ <- 1..12, do: take(workspace))

    assert Enum.sort(answers) == Enum.map(1..12, &{:ok, &1})
  end

  # On a connection outside the sandbox, as every test here: there, a call outside a
  # transaction is one, which the sandbox's transaction would hide.
  test "a number is refused outside a transaction, and none is taken" do
    %{workspace: workspace} = sign_up()

    assert_raise ArgumentError, ~r/inside the transaction/, fn -> Number.next(workspace) end
    assert {:ok, 1} = take(workspace).()
  end
end
