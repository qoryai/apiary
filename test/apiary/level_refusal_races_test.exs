defmodule Apiary.LevelRefusalRacesTest do
  # Changes made at once under stubs of an edition that locks rows of its own
  # (`c:Apiary.Edition.lock_rows/1`, `Apiary.EditionStubs`). Under stubs that keep the lock
  # order, taking their rows at the one point a change has and none later, these all
  # finish: changes of level whose points stand at the same moment, in one organisation and
  # in two whose owners change each other's level; two changes of people in one
  # organisation whose edition row a write holds shared; an account's deletion beside
  # changes of level in two of its organisations, beside the edition's own change that
  # holds one of them `FOR UPDATE`, beside an acceptance that does, beside the
  # organisation's purge, and beside the edition's own change in an organisation the
  # account joined while the deletion stood, which it holds none of. Stubs that break the
  # order make crossed changes of level a deadlock: one that takes a row when asked for the
  # level and another once the membership is written, and one that holds a membership of
  # another organisation. That is why the order forbids both. Each side runs on a connection of its own, outside the
  # SQL sandbox; not async, as what these tests commit is visible to every other test
  # while they run, and they delete it again before they end.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Accounts, Deletion, EditionStubs, Organisations, Repo}
  alias Apiary.Organisations.{Membership, Organisation}

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

  # How long each change may take to answer once let go. A deadlock is found after the
  # database's `deadlock_timeout`, a second, and the change that remains then commits;
  # on a loaded CI machine one has taken longer than ten seconds to answer.
  @answer_ms 30_000

  # Starts each change, waits until each holds its first rows, then lets them go on
  # together: their answers, a deadlock as `{:deadlock, message}`. A change's first rows
  # are waited for as long as the change waits for its go
  # (`Apiary.EditionStubs.rendezvous/0`), five seconds.
  defp each_holding(changes) do
    sides = for change <- changes, do: start(fn -> deadlock_as_answer(change) end)

    held =
      for _side <- sides do
        assert_receive {:level_refusal_held, pid}, 5_000
        pid
      end

    for pid <- held, do: send(pid, :level_refusal_go)
    for side <- sides, do: Task.await(side.task, @answer_ms)
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
    :ok = Apiary.Edition.put_test_stub(EditionStubs.PausesAfterAccount)
    Process.put(:level_refusal_rendezvous, true)

    for _round <- 1..5 do
      a = sign_up()
      b = sign_up()
      z = member(a.scope, :admin)
      z_in_a = z.membership
      z_in_b = admin_in(b, z)

      # The deletion holding its rows, and each change of level about to take its own.
      [deleted, in_a, in_b] =
        each_holding([
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

  test "two changes of people in one organisation, whose edition row a write holds shared, both finish" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.OrganisationRow)
    Process.put(:level_refusal_rendezvous, true)
    %{scope: owner} = sign_up()
    one = member(owner, :member)
    other = member(owner, :member)

    answers =
      each_holding([
        fn -> Organisations.set_member_level(owner, one.membership.id, :admin) end,
        fn -> Organisations.set_member_level(owner, other.membership.id, :admin) end
      ])

    assert [{:ok, %Membership{level: :admin}}, {:ok, %Membership{level: :admin}}] = answers
  end

  # An account's deletion, paused once it holds its rows, then `other` started beside it,
  # which waits on it; then the deletion goes on: both answers.
  defp beside_deletion(%{scope: deleting}, other) do
    deletion = start(fn -> deadlock_as_answer(fn -> Accounts.delete_user(deleting) end) end)
    assert_receive {:level_refusal_held, pid}, 5_000

    beside = start(fn -> deadlock_as_answer(other) end)
    await_blocked(beside.backend, deletion.backend)
    send(pid, :level_refusal_go)

    [Task.await(deletion.task, 10_000), Task.await(beside.task, 10_000)]
  end

  test "an account's deletion beside the edition's own change that holds an organisation FOR UPDATE" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.PausesAfterAccount)
    Process.put(:level_refusal_rendezvous, true)
    %{scope: owner, organisation: organisation} = sign_up()
    deleting = member(owner, :admin)

    # A change of the edition's own: the organisation `FOR UPDATE`, then its row of it.
    answers =
      beside_deletion(deleting, fn ->
        Repo.transact(fn ->
          Repo.one(
            from o in Organisation,
              where: o.id == ^organisation.id,
              select: o.id,
              lock: "FOR UPDATE"
          )

          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "apiary-edition-stub:organisation:#{organisation.id}"
          ])

          {:ok, :changed}
        end)
      end)

    assert [{:ok, _deleted}, {:ok, :changed}] = answers
  end

  test "an account's deletion beside an acceptance that holds the organisation FOR UPDATE" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.AcceptingLocksTheOrganisation)
    Process.put(:level_refusal_rendezvous, true)
    %{scope: owner} = sign_up()
    deleting = member(owner, :admin)
    joining = sign_up()

    %{token: token} =
      Apiary.OrganisationsFixtures.invitation_fixture(owner, %{"email" => joining.user.email})

    answers =
      beside_deletion(deleting, fn -> Organisations.accept_invitation(joining.user, token) end)

    assert [{:ok, _deleted}, {:ok, %Membership{}}] = answers
  end

  test "an account's deletion beside the purge of one of its organisations" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.PausesAfterAccount)
    Process.put(:level_refusal_rendezvous, true)
    %{scope: owner, organisation: organisation} = sign_up()
    deleting = member(owner, :admin)

    answers = beside_deletion(deleting, fn -> Deletion.purge_now(organisation) end)

    assert [{:ok, _deleted}, {:ok, :purged}] = answers
    refute Repo.get(Organisation, organisation.id)
  end

  test "an organisation the account joins while its deletion stands is not the edition's to hold" do
    :ok = Apiary.Edition.put_test_stub(EditionStubs.PausesAroundAccount)
    %{scope: owner} = sign_up()
    deleting = member(owner, :admin)
    %{scope: other_owner, organisation: joined} = sign_up()

    %{token: token} =
      Apiary.OrganisationsFixtures.invitation_fixture(other_owner, %{
        "email" => deleting.user.email
      })

    Process.put(:level_refusal_rendezvous, true)

    deletion =
      start(fn -> deadlock_as_answer(fn -> Accounts.delete_user(deleting.scope) end) end)

    assert_receive {:level_refusal_held, pid}, 5_000

    # The person joins another organisation once the deletion has held theirs, before it
    # takes its rows: the organisation is not among those it held.
    Process.delete(:level_refusal_rendezvous)
    acceptance = start(fn -> Organisations.accept_invitation(deleting.user, token) end)
    assert {:ok, %Membership{}} = Task.await(acceptance.task, 10_000)
    Process.put(:level_refusal_rendezvous, true)

    send(pid, :level_refusal_go)
    assert_receive {:level_refusal_held, ^pid}, 5_000

    # A change of the edition's own in the organisation joined, `FOR UPDATE` then its row
    # of it, which the deletion took none of: it does not wait on the deletion.
    changed =
      start(fn ->
        deadlock_as_answer(fn ->
          Repo.transact(fn ->
            Repo.one(
              from o in Organisation,
                where: o.id == ^joined.id,
                select: o.id,
                lock: "FOR UPDATE"
            )

            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              "apiary-edition-stub:organisation:#{joined.id}"
            ])

            {:ok, :changed}
          end)
        end)
      end)

    assert {:ok, :changed} = Task.await(changed.task, 10_000)

    send(pid, :level_refusal_go)
    assert {:ok, _deleted} = Task.await(deletion.task, 10_000)
    refute Repo.exists?(from m in Membership, where: m.user_id == ^deleting.user.id)
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
