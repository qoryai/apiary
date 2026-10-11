defmodule Apiary.LevelRefusalRacesTest do
  # Two changes of level, each by a person on the other, asked of an edition that holds the
  # asker's memberships in their other organisations `FOR SHARE` as it answers
  # (`c:Apiary.Edition.level_refusal/4`, `Apiary.EditionStubs`). The core asks it where the
  # lock order puts it: after the organisation rows and the owners, before the membership
  # changed is written. So neither change waits on the other's edition rows while holding
  # what the other needs: both finish, and none is a deadlock. Each side runs on a
  # connection of its own, outside the SQL sandbox; not async, as what these tests commit
  # is visible to every other test while they run, and they delete it again before they
  # end.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{EditionStubs, Organisations, Repo}
  alias Apiary.Organisations.Membership

  setup_all :clean_up_leftovers
  setup :setup_races

  # An organisation of an owner and two more people at `level`, each of whom is also a
  # member of another organisation, whose membership the edition holds.
  defp organisation_with(level) do
    %{scope: owner} = sign_up()
    %{scope: elsewhere} = sign_up()
    one = member(owner, level)
    other = member(owner, level)

    for %{user: user} <- [one, other],
        do: Apiary.OrganisationsFixtures.join_fixture(elsewhere, user)

    %{owner: owner, one: one, other: other}
  end

  defp level(%{membership: %Membership{id: id}}), do: Repo.get!(Membership, id).level

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
      sides = [
        start(fn -> Organisations.set_member_level(one.scope, other.membership.id, :member) end),
        start(fn -> Organisations.set_member_level(other.scope, one.membership.id, :member) end)
      ]

      # Each holds what the edition holds, and waits there, before either writes.
      held =
        for _side <- sides do
          assert_receive {:level_refusal_held, pid}, 5_000
          pid
        end

      for pid <- held, do: send(pid, :level_refusal_go)

      for side <- sides,
          do: assert({:ok, %Membership{level: :member}} = Task.await(side.task, 10_000))

      for person <- [one, other] do
        {:ok, _} = Organisations.set_member_level(owner, person.membership.id, :admin)
        assert level(person) == :admin
      end
    end
  end

  test "two owners demoting each other at once: exactly one is made, and neither waits forever" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.LocksElsewhere)

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
end
