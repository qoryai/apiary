defmodule Apiary.LevelRefusalRacesTest do
  # Changes of people made at once under stubs of an edition that locks rows of its own
  # (`c:Apiary.Edition.lock_rows/1`, `Apiary.EditionStubs`). Under a stub that keeps the
  # lock order, taking its rows at the one point a change has and none later, two changes
  # of level that each hold their first rows at the same moment both finish, in one
  # organisation and in two whose owners change each other's level, and an account's
  # deletion in two organisations finishes beside changes of level in both. Stubs that
  # break the order make the crossed changes of level a deadlock: one that takes a row
  # when asked for the level and another once the membership is written, and one that
  # holds a membership of another organisation. That is why the order forbids both. Each
  # side runs on a connection of its own, outside the SQL sandbox; not async, as what these
  # tests commit is visible to every other test while they run, and they delete it again
  # before they end.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Accounts, EditionStubs, Organisations, Repo}
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

  # Starts each change, waits until each holds its first rows, then lets them go on
  # together: their answers, a deadlock as `{:deadlock, message}`.
  defp each_holding(changes) do
    sides = for change <- changes, do: start(fn -> deadlock_as_answer(change) end)

    held =
      for _side <- sides do
        assert_receive {:level_refusal_held, pid}, 5_000
        pid
      end

    for pid <- held, do: send(pid, :level_refusal_go)
    for side <- sides, do: Task.await(side.task, 10_000)
  end

  defp deadlock_as_answer(change) do
    change.()
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :deadlock_detected,
        do: {:deadlock, Exception.message(error)},
        else: reraise(error, __STACKTRACE__)
  end

  # Owners X and Y demote each other in each other's organisation, at once.
  defp demote_crossed(%{x: x, y: y, x_in_y: x_in_y, y_in_x: y_in_x}) do
    each_holding([
      fn -> Organisations.set_member_level(x.scope, y_in_x.id, :member) end,
      fn -> Organisations.set_member_level(y.scope, x_in_y.id, :member) end
    ])
  end

  test "two admins demoting each other, each holding its first rows at once: one is made, the other refused" do
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

      # The edition's rows of the organisation's people take turns: the second asks its
      # level once the first has made it a member, and is refused.
      assert Enum.count(answers, &match?({:ok, %Membership{level: :member}}, &1)) == 1
      assert Enum.count(answers, &(&1 == {:error, :forbidden})) == 1

      for person <- [one, other] do
        {:ok, _} = Organisations.set_member_level(owner, person.membership.id, :admin)
        assert level(person) == :admin
      end
    end
  end

  test "two owners of one organisation demoting each other at once: exactly one is made" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksItsRows)

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
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksItsRows)
    Process.put(:level_refusal_rendezvous, true)

    for _round <- 1..5 do
      %{x_in_y: x_in_y, y_in_x: y_in_x} = crossed = crossed()

      assert [{:ok, %Membership{level: :member}}, {:ok, %Membership{level: :member}}] =
               demote_crossed(crossed)

      assert level(x_in_y) == :member
      assert level(y_in_x) == :member
    end
  end

  test "an account deleted while its levels change in two organisations: all finish" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksItsRows)

    for _round <- 1..5 do
      a = sign_up()
      b = sign_up()
      z = member(a.scope, :admin)
      z_in_a = z.membership
      z_in_b = admin_in(b, z)

      [deleted, in_a, in_b] =
        together([
          fn -> Accounts.delete_user(z.scope) end,
          fn -> Organisations.set_member_level(a.scope, z_in_a.id, :member) end,
          fn -> Organisations.set_member_level(b.scope, z_in_b.id, :member) end
        ])

      assert {:ok, _deleted} = deleted

      for answer <- [in_a, in_b],
          do: assert(match?({:ok, _}, answer) or answer == {:error, :not_found})

      refute Repo.exists?(from m in Membership, where: m.user_id == ^z.user.id)
    end
  end

  test "an edition that takes a row later in the change makes crossed demotions a deadlock" do
    # Each change holds its own row, shared, then wants the other's, exclusive, once its
    # membership is written: each waits on the other. Taking every row at one point, in one
    # order, before the first write (`c:Apiary.Edition.lock_rows/1`) is what rules it out.
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksTwice)
    Process.put(:level_refusal_rendezvous, true)

    answers = demote_crossed(crossed())

    assert Enum.count(answers, &match?({:deadlock, _message}, &1)) == 1
    assert Enum.count(answers, &match?({:ok, %Membership{level: :member}}, &1)) == 1
  end

  test "an edition that holds a membership of another organisation makes that a deadlock" do
    # The lock order forbids it (`c:Apiary.Edition.lock_rows/1`): each change holds its
    # owners, then the other organisation's membership the other change writes.
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksAMembership)
    Process.put(:level_refusal_rendezvous, true)

    answers = demote_crossed(crossed())

    assert Enum.count(answers, &match?({:deadlock, _message}, &1)) == 1
    assert Enum.count(answers, &match?({:ok, %Membership{level: :member}}, &1)) == 1
  end
end
