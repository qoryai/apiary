defmodule Apiary.DeletionRacesTest do
  # Two changes at once, each on a connection of its own and outside the SQL sandbox, so
  # that each commits and each waits on the other's locks as it would in production. Not
  # async: what these tests commit is visible to every other test while they run, and they
  # delete it again before they end.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Accounts, Deletion, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation}

  setup_all :clean_up_leftovers
  setup :setup_races

  test "of two owners deleting their accounts at once, exactly one is let go" do
    for _round <- 1..5 do
      %{scope: first, organisation: organisation} = sign_up()
      %{scope: second} = member(first, :owner)

      results = together(for scope <- [first, second], do: fn -> Accounts.delete_user(scope) end)

      assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, :last_owner}] = Enum.filter(results, &match?({:error, _}, &1))

      # The organisation keeps an owner, a person.
      assert [%Membership{level: :owner, user_id: user_id}] =
               Repo.all(from m in Membership, where: m.organisation_id == ^organisation.id)

      assert %User{deleted_at: nil} = Repo.get!(User, user_id)
    end
  end

  test "a purge due while a cancelling holds the row waits for it, and then does nothing" do
    %{scope: scope, organisation: organisation} = sign_up()
    {:ok, _} = Deletion.delete_organisation(scope, organisation.slug)

    # Due in a moment: the cancelling is still in its grace period, the purge is not.
    Repo.query!(
      "UPDATE organisations " <>
        "SET purge_after = (clock_timestamp() AT TIME ZONE 'UTC') + interval '1500 milliseconds' " <>
        "WHERE id = $1",
      [Ecto.UUID.dump!(organisation.id)]
    )

    {restore, restore_backend} =
      hold(fn -> Deletion.restore_organisation(scope, organisation.id) end)

    assert {:ok, _} = restore.result

    # The database's clock past the purge's time, while the cancelling has not committed.
    Repo.query!(
      "SELECT pg_sleep(0.05 + GREATEST(0, EXTRACT(EPOCH FROM purge_after - " <>
        "(clock_timestamp() AT TIME ZONE 'UTC')))) FROM organisations WHERE id = $1",
      [Ecto.UUID.dump!(organisation.id)]
    )

    purge = start(fn -> Deletion.purge_organisation(Scope.for_instance(organisation)) end)

    # The purge's claim waits on the row the cancelling holds.
    await_blocked(purge.backend, restore_backend)
    commit(restore)

    assert {:ok, :not_due} = Task.await(purge.task)

    assert %Organisation{deletion_marked_at: nil, purge_started_at: nil} =
             Repo.get!(Organisation, organisation.id)
  end

  test "a person deleting their account and their organisation at once, in two tabs, ends" do
    for _round <- 1..5 do
      %{scope: scope, organisation: organisation} = sign_up()
      # Another owner, so the account may go whichever is first.
      member(scope, :owner)

      [account, marked] =
        together([
          fn -> Accounts.delete_user(scope) end,
          fn -> Deletion.delete_organisation(scope, organisation.slug) end
        ])

      # Neither waits on the other for ever: the account goes, and the organisation is
      # marked, or refused as the person's who is no longer a member.
      assert {:ok, _} = account
      assert match?({:ok, %Organisation{}}, marked) or marked == {:error, :forbidden}
    end
  end

  test "a cancelling after a purge claimed the organisation is refused, and the purge ends" do
    %{scope: scope, organisation: organisation} = sign_up()
    {:ok, _} = Deletion.delete_organisation(scope, organisation.slug)

    Repo.update_all(from(o in Organisation, where: o.id == ^organisation.id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, :purged} = Deletion.purge_organisation(Scope.for_instance(organisation))
    assert {:error, :not_found} = Deletion.restore_organisation(scope, organisation.id)
    assert Repo.get(Organisation, organisation.id) == nil
  end
end
