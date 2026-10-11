defmodule Apiary.LevelRefusalRacesTest do
  # Changes of level made at once, asked of a stub of an edition that holds a row as it
  # answers (`c:Apiary.Edition.level_refusal/4`, `Apiary.EditionStubs`). Under a stub that
  # keeps the lock order, holding only a row of its own, two changes that each hold what
  # the edition holds at the same moment both finish: in one organisation, and in two whose
  # people change each other's level. A stub that holds a membership of another
  # organisation, which the order forbids, makes the second case a deadlock, which is why
  # the order forbids it. Each side runs on a connection of its own, outside the SQL
  # sandbox; not async, as what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{EditionStubs, Organisations, Repo}
  alias Apiary.Organisations.Membership

  setup_all :clean_up_leftovers
  setup :setup_races

  # An organisation of an owner and two more people at `level`, each of whom is also a
  # member of another organisation.
  defp organisation_with(level) do
    %{scope: owner} = sign_up()
    %{scope: elsewhere} = sign_up()
    one = member(owner, level)
    other = member(owner, level)

    for %{user: user} <- [one, other],
        do: Apiary.OrganisationsFixtures.join_fixture(elsewhere, user)

    %{owner: owner, one: one, other: other}
  end

  # Two organisations, each owned by one person who is an admin in the other's.
  defp crossed do
    x = sign_up()
    y = sign_up()
    x_in_y = admin_in(y, x)
    y_in_x = admin_in(x, y)
    %{x: x, y: y, x_in_y: x_in_y, y_in_x: y_in_x}
  end

  defp admin_in(%{scope: owner}, %{user: user}) do
    %{membership: membership} = Apiary.OrganisationsFixtures.join_fixture(owner, user)
    {:ok, admin} = Organisations.set_member_level(owner, membership.id, :admin)
    admin
  end

  defp level(%Membership{id: id}), do: Repo.get!(Membership, id).level
  defp level(%{membership: membership}), do: level(membership)

  # Starts each change, waits until each holds what the edition holds, then lets them go
  # on together: their answers, a deadlock as `{:deadlock, message}`.
  defp each_holding(changes) do
    sides =
      for change <- changes do
        start(fn ->
          try do
            change.()
          rescue
            error in Postgrex.Error ->
              if error.postgres[:code] == :deadlock_detected,
                do: {:deadlock, Exception.message(error)},
                else: reraise(error, __STACKTRACE__)
          end
        end)
      end

    held =
      for _side <- sides do
        assert_receive {:level_refusal_held, pid}, 5_000
        pid
      end

    for pid <- held, do: send(pid, :level_refusal_go)
    for side <- sides, do: Task.await(side.task, 10_000)
  end

  test "two admins changing each other's level, each holding its rows at once, both finish" do
    %{owner: owner, one: one, other: other} = organisation_with(:admin)

    # No owner's membership is left to lock (`Apiary.Organisations.lock_owners/1`), as in
    # an organisation an edition gives its owner another way: nothing else orders the two.
    {1, _} =
      Repo.update_all(
        from(m in Membership, where: m.id == ^owner.membership.id),
        set: [level: :admin]
      )

    :ok = Apiary.Edition.put_test_stub(EditionStubs.AdminsChangeLevels)
    Process.put(:level_refusal_rendezvous, true)

    for _round <- 1..3 do
      answers =
        each_holding([
          fn -> Organisations.set_member_level(one.scope, other.membership.id, :member) end,
          fn -> Organisations.set_member_level(other.scope, one.membership.id, :member) end
        ])

      assert [{:ok, %Membership{level: :member}}, {:ok, %Membership{level: :member}}] = answers

      for person <- [one, other] do
        {:ok, _} = Organisations.set_member_level(owner, person.membership.id, :admin)
        assert level(person) == :admin
      end
    end
  end

  test "two owners of one organisation demoting each other at once: exactly one is made" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksItsOwn)

    for _round <- 1..5 do
      %{one: one, other: other} = organisation_with(:owner)

      answers =
        together([
          fn -> Organisations.set_member_level(one.scope, other.membership.id, :admin) end,
          fn -> Organisations.set_member_level(other.scope, one.membership.id, :admin) end
        ])

      assert Enum.count(answers, &match?({:ok, %Membership{level: :admin}}, &1)) == 1
      assert Enum.count(answers, &(&1 == {:error, :forbidden})) == 1
    end
  end

  test "owners demoting each other in each other's organisation at once both finish" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksItsOwn)
    Process.put(:level_refusal_rendezvous, true)

    for _round <- 1..5 do
      %{x: x, y: y, x_in_y: x_in_y, y_in_x: y_in_x} = crossed()

      answers =
        each_holding([
          fn -> Organisations.set_member_level(x.scope, y_in_x.id, :member) end,
          fn -> Organisations.set_member_level(y.scope, x_in_y.id, :member) end
        ])

      assert [{:ok, %Membership{level: :member}}, {:ok, %Membership{level: :member}}] = answers
      assert level(x_in_y) == :member
      assert level(y_in_x) == :member
    end
  end

  test "an edition that holds a membership of another organisation makes that a deadlock" do
    # The lock order forbids it (`c:Apiary.Edition.level_refusal/4`): each change holds its
    # owners, then the other organisation's membership the other change writes.
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksAMembership)
    Process.put(:level_refusal_rendezvous, true)
    %{x: x, y: y, x_in_y: x_in_y, y_in_x: y_in_x} = crossed()

    answers =
      each_holding([
        fn -> Organisations.set_member_level(x.scope, y_in_x.id, :member) end,
        fn -> Organisations.set_member_level(y.scope, x_in_y.id, :member) end
      ])

    assert Enum.count(answers, &match?({:deadlock, _message}, &1)) == 1
    assert Enum.count(answers, &match?({:ok, %Membership{level: :member}}, &1)) == 1
  end
end
