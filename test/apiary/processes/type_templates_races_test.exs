defmodule Apiary.Processes.TypeTemplatesRacesTest do
  # First reads of a workspace type at once, each on a connection apart, outside the SQL
  # sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test (`Apiary.Processes.TypeTemplates`, § Locks): the versions of one
  # type are made one at a time, under the type's advisory lock. The unique index on
  # `{type, number}` alone keeps one row of a number, so only the second test fails
  # without the lock.
  #
  # Reads only: a save commits an audit entry, which nothing may delete, and
  # `Apiary.Processes.TypeTemplatesTest` expects none. The type is `qory.example`, since
  # sign-ups outside the sandbox commit versions of `qory.software`.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.Races

  alias Apiary.Processes.{TypeTemplate, TypeTemplates}
  alias Apiary.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @type_key "qory.example"

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    delete_versions()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      delete_versions()
      Sandbox.checkin(Repo)
    end)
  end

  defp delete_versions do
    Repo.delete_all(from t in TypeTemplate, where: t.type == ^@type_key)
    :ok
  end

  defp numbers do
    Repo.all(
      from t in TypeTemplate, where: t.type == ^@type_key, order_by: t.number, select: t.number
    )
  end

  test "several first reads at once insert one row" do
    for _round <- 1..10 do
      delete_versions()

      versions = together(for _ <- 1..sides(6), do: fn -> TypeTemplates.newest(@type_key) end)

      assert [%TypeTemplate{number: 1, release: 2}] = Enum.uniq_by(versions, & &1.id)
      assert numbers() == [1]
    end
  end

  test "a read of a later release's default waits for a first read, and adds its version" do
    {first, first_pid} = hold(fn -> TypeTemplates.newest(@type_key) end)
    assert %TypeTemplate{number: 1, release: 2} = first.result

    second = start(fn -> TypeTemplates.newest(@type_key, 3) end)

    # The second waits with no row to read. Without the lock it waits on the first's
    # insert instead, its version 1 conflicts, and it adds no version 2.
    await_blocked(second.backend, first_pid)
    commit(first)

    assert %TypeTemplate{number: 2, release: 3} = Task.await(second.task)
    assert numbers() == [1, 2]
  end
end
