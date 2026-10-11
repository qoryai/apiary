defmodule Apiary.RenewalLockTest do
  # The organisation row a renewal locks (`Apiary.Organisations.renew_invitation/4`) is the
  # one `Apiary.Organisations.allowance_of/1` answers, `FOR NO KEY UPDATE`: the renewal is
  # held open on a connection of its own, outside the SQL sandbox, and the test asks for
  # each organisation's row in that mode without waiting. Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  use ExUnit.Case, async: false

  import Apiary.Races
  import Ecto.Query

  alias Apiary.{Organisations, Repo}
  alias Apiary.Organisations.{Invitation, Organisation}

  setup_all :clean_up_leftovers
  setup :setup_races

  # Whether the organisation's row is free to lock `FOR NO KEY UPDATE` now, without waiting.
  defp free?(%Organisation{id: id}) do
    case Repo.query(
           "SELECT id FROM organisations WHERE id = $1 FOR NO KEY UPDATE NOWAIT",
           [Ecto.UUID.dump!(id)]
         ) do
      {:ok, _result} -> true
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> false
    end
  end

  defp renewing(scope, invitation) do
    hold(fn ->
      Organisations.renew_invitation(scope, invitation.id, & &1, action: :"invitation.renew")
    end)
  end

  test "an expired invitation: refused before any lock of its allowance's row" do
    %{scope: scope, organisation: organisation} = sign_up()
    %{organisation: other} = sign_up()
    Apiary.Mail.put_test_source(:none)

    {:ok, invitation} =
      Repo.transact(fn ->
        with {:ok, invitation, _token} <-
               Organisations.insert_invitation(scope, %{"email" => email()}, allowance: other),
             do: {:ok, invitation}
      end)

    {1, _} =
      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)]
      )

    {renewal, _backend} = renewing(scope, invitation)
    assert renewal.result == {:error, :not_found}

    # Held open after the refusal: neither row was locked.
    assert free?(other)
    assert free?(organisation)

    # The refusal rolled the held transaction back.
    send(renewal.pid, :commit)
    assert {:error, :rollback} = Task.await(renewal.task)
  end

  test "an invitation is pending for less time than the audit trail keeps an entry" do
    # What keeps `allowance_of/1`'s answer for a pending invitation: the entry that names
    # its allowance is not pruned while it is pending.
    assert {:error, _reason} =
             Apiary.Audit.parse_retention_days(Integer.to_string(Invitation.validity_days()))
  end

  test "an invitation counted against its own organisation: that row" do
    %{scope: scope, organisation: organisation} = sign_up()
    # Without mail: the invitations are links, and nothing waits on a relay.
    Apiary.Mail.put_test_source(:none)

    {:ok, invitation, {:link, _url}} =
      Organisations.invite_member(scope, %{"email" => email()}, & &1)

    assert {:ok, %Organisation{id: id}} = Organisations.allowance_of(invitation)
    assert id == organisation.id

    {renewal, _backend} = renewing(scope, invitation)
    assert {:ok, _renewed, _token} = renewal.result

    refute free?(organisation)
    commit(renewal)
    assert free?(organisation)
  end

  test "an invitation an edition counted against another organisation: that row alone" do
    %{scope: scope, organisation: organisation} = sign_up()
    %{organisation: other} = sign_up()
    Apiary.Mail.put_test_source(:none)

    {:ok, invitation} =
      Repo.transact(fn ->
        with {:ok, invitation, _token} <-
               Organisations.insert_invitation(scope, %{"email" => email()}, allowance: other),
             do: {:ok, invitation}
      end)

    assert {:ok, %Organisation{id: id}} = Organisations.allowance_of(invitation)
    assert id == other.id

    {renewal, _backend} = renewing(scope, invitation)
    assert {:ok, _renewed, _token} = renewal.result

    refute free?(other)
    assert free?(organisation)
    commit(renewal)
    assert free?(other)
  end
end
