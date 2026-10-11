defmodule Apiary.InvitationLimitTest do
  @moduledoc """
  An organisation sends at most `INVITATIONS_PER_DAY` invitations in 24 hours, counted
  from the audit trail, so an invitation accepted, revoked or deleted since still counts.
  Two at once are `Apiary.SignUpRacesTest`'s.
  """
  # Not async: the limit is the node's setting.
  use Apiary.DataCase, async: false

  import Apiary.AccountsFixtures
  import Ecto.Query
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Invitation

  @limit 3

  setup do
    previous = Application.fetch_env!(:apiary, :invitations_per_day)
    Application.put_env(:apiary, :invitations_per_day, @limit)
    on_exit(fn -> Application.put_env(:apiary, :invitations_per_day, previous) end)
    %{scope: sign_up_fixture().scope}
  end

  defp invite(scope),
    do: Organisations.invite_member(scope, %{"email" => unique_user_email()}, & &1)

  defp refused_for_the_day?({:error, %Ecto.Changeset{} = changeset}) do
    errors_on(changeset).email == [
      "was not invited: this organisation has made #{@limit} invitations in the last 24 hours, as many as it may. Try again later."
    ]
  end

  defp refused_for_the_day?(_result), do: false

  defp renew(scope, invitation, opts \\ []),
    do: Organisations.renew_invitation(scope, invitation.id, & &1, opts)

  # The organisation's `member.invite` entries, moved `hours` back.
  defp age_invitations!(scope, hours) do
    Repo.query!(
      """
      UPDATE audit_entries SET inserted_at = inserted_at - make_interval(hours => $2)
      WHERE organisation_id = $1 AND action = 'member.invite'
      """,
      [Ecto.UUID.dump!(scope.organisation.id), hours]
    )
  end

  test "the Nth of the day is sent, the N+1th refused with how many are allowed", %{scope: scope} do
    for _ <- 1..@limit, do: assert({:ok, %Invitation{}} = invite(scope))

    result = invite(scope)
    assert refused_for_the_day?(result)

    # Refused, nothing was written, and nothing sent.
    assert Repo.aggregate(
             from(i in Invitation, where: i.organisation_id == ^scope.organisation.id),
             :count
           ) ==
             @limit

    assert Repo.aggregate(
             from(e in Entry,
               where: e.organisation_id == ^scope.organisation.id and e.action == "member.invite"
             ),
             :count
           ) == @limit
  end

  test "an invitation revoked, accepted or deleted since still counts", %{scope: scope} do
    %{invitation: revoked} = invitation_fixture(scope)
    %{token: token} = invitation_fixture(scope)
    %{invitation: expired} = invitation_fixture(scope)

    {:ok, _} = Organisations.revoke_invitation(scope, revoked.id)
    {:ok, _} = Organisations.accept_invitation(user_fixture(), token)
    Repo.delete_all(from i in Invitation, where: i.id == ^expired.id)

    assert Organisations.list_invitations(scope) == []
    assert refused_for_the_day?(invite(scope))
  end

  test "an invitation withdrawn because its email was not delivered does not count",
       %{scope: scope} do
    previous = Application.fetch_env!(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)

    for _ <- 1..(@limit + 2),
        do: assert({:error, :delivery_failed} = invite(scope))

    Application.put_env(:apiary, Apiary.Mailer, previous)

    # No mail was sent: the day's invitations are all still to send.
    for _ <- 1..@limit, do: assert({:ok, %Invitation{}} = invite(scope))
    assert refused_for_the_day?(invite(scope))
  end

  test "a renewal withdrawn because its email was not delivered un-counts itself alone",
       %{scope: scope} do
    # Two delivered.
    assert {:ok, %Invitation{} = first} = invite(scope)
    assert {:ok, %Invitation{}} = invite(scope)

    # The edition's renewal of the first, whose email is then not delivered: withdrawn.
    assert {:ok, renewed, token} = renew(scope, first, action: :"member.invite")

    previous = Application.fetch_env!(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)

    assert {:error, :delivery_failed} =
             Organisations.send_invitation(scope, renewed, token, & &1)

    Application.put_env(:apiary, Apiary.Mailer, previous)

    # The withdrawal names the renewal's entry, the one it undoes.
    [_invited, renewal] =
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^first.id and e.action == "member.invite",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

    assert [%Entry{details: details}] =
             Repo.all(
               from e in Entry,
                 where: e.subject_id == ^first.id and e.action == "invitation.revoke"
             )

    assert details == %{"reason" => "undelivered", "entry_id" => renewal.id}

    # Two mails delivered: one more of the day's three, not two.
    assert {:ok, %Invitation{}} = invite(scope)
    assert refused_for_the_day?(invite(scope))
  end

  test "a withdrawal written before withdrawals named their entry un-counts its invitation",
       %{scope: scope} do
    assert {:ok, %Invitation{} = invitation} = invite(scope)

    # Its shape then: the reason alone.
    {:ok, _entry} =
      Apiary.Audit.record(Repo, scope, :"invitation.revoke", invitation, %{
        details: %{reason: "undelivered"}
      })

    for _ <- 1..@limit, do: assert({:ok, %Invitation{}} = invite(scope))
    assert refused_for_the_day?(invite(scope))
  end

  test "every invitation tried, delivered or not, counts against three times the day's",
       %{scope: scope} do
    previous = Application.fetch_env!(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)

    # One delivered, and undelivered ones up to the ceiling of 3 × @limit tries.
    Application.put_env(:apiary, Apiary.Mailer, previous)
    assert {:ok, %Invitation{}} = invite(scope)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)

    for _ <- 2..(3 * @limit), do: assert({:error, :delivery_failed} = invite(scope))

    # Only one was sent, far from the day's limit; the tries are at the ceiling.
    Application.put_env(:apiary, Apiary.Mailer, previous)
    assert {:error, %Ecto.Changeset{} = changeset} = invite(scope)

    assert errors_on(changeset).email == [
             "was not invited: this organisation has tried to send #{3 * @limit} invitations in the last 24 hours, delivered or not, as many as it may. Try again later."
           ]

    # A day later, both counts start again.
    age_invitations!(scope, 25)
    assert {:ok, %Invitation{}} = invite(scope)
  end

  test "the day's limit answers first when both are reached", %{scope: scope} do
    for _ <- 1..@limit, do: {:ok, _} = invite(scope)

    Repo.query!(
      """
      INSERT INTO audit_entries (id, organisation_id, actor_kind, action, subject_kind,
                                 subject_id, inserted_at)
      SELECT gen_random_uuid(), $1, 'instance', 'member.invite', 'invitation',
             gen_random_uuid(), timezone('UTC', now())
      FROM generate_series(1, $2)
      """,
      [Ecto.UUID.dump!(scope.organisation.id), 3 * @limit]
    )

    assert refused_for_the_day?(invite(scope))
  end

  test "the day is the last 24 hours, by the database's clock", %{scope: scope} do
    for _ <- 1..@limit, do: {:ok, _} = invite(scope)

    # Just inside the window, they count.
    age_invitations!(scope, 23)
    assert refused_for_the_day?(invite(scope))

    # Past it, they do not.
    age_invitations!(scope, 2)
    assert {:ok, %Invitation{}} = invite(scope)
  end

  test "each organisation has a day of its own", %{scope: scope} do
    for _ <- 1..@limit, do: {:ok, _} = invite(scope)
    assert refused_for_the_day?(invite(scope))

    assert {:ok, %Invitation{}} = invite(sign_up_fixture().scope)
  end

  test "at the default of 20 a day, the 21st is refused" do
    Application.put_env(:apiary, :invitations_per_day, 20)
    %{scope: scope} = sign_up_fixture()

    for _ <- 1..20, do: assert({:ok, %Invitation{}} = invite(scope))
    assert {:error, %Ecto.Changeset{} = changeset} = invite(scope)
    assert [message] = errors_on(changeset).email
    assert message =~ "has made 20 invitations in the last 24 hours"
  end

  test "a new link with action: counts, and is refused as one without", %{scope: scope} do
    {:ok, invitation} = invite(scope)
    renew = fn -> renew(scope, invitation, action: :"member.invite") end

    for _ <- 2..@limit, do: assert({:ok, %Invitation{}, "" <> _token} = renew.())

    assert refused_for_the_day?(renew.())
    assert refused_for_the_day?(invite(scope))
  end

  describe "without mail" do
    setup %{scope: scope} do
      Apiary.Mail.put_test_source(:none)
      %{scope: scope}
    end

    test "a copied link counts as a mailed one does", %{scope: scope} do
      for _ <- 1..@limit, do: assert({:ok, %Invitation{}, {:link, _url}} = invite(scope))
      assert refused_for_the_day?(invite(scope))
    end

    test "a new link counts, and is refused with the same reason and words", %{scope: scope} do
      {:ok, invitation, {:link, _url}} = invite(scope)

      for _ <- 2..@limit,
          do: assert({:ok, %Invitation{}, {:link, _url}} = renew(scope, invitation))

      result = renew(scope, invitation)
      assert refused_for_the_day?(result)
      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert {_message, opts} = changeset.errors[:email]
      assert opts[:validation] == :invitations_per_day
      assert opts[:limit] == @limit

      # Refused, the link it had still works, and nothing was written.
      assert [%Invitation{} = pending] = Organisations.list_invitations(scope)
      assert pending.token_hash == Repo.get!(Invitation, invitation.id).token_hash

      assert Repo.aggregate(
               from(e in Entry, where: e.action == "invitation.renew"),
               :count
             ) == @limit - 1

      # And the new invitations too.
      assert refused_for_the_day?(invite(scope))
    end

    test "a new link counts against the allowance the invitation was counted against",
         %{scope: scope} do
      # Its owner confirmed by email, then mail off again.
      Apiary.Mail.put_test_source(:env)
      %{scope: other} = sign_up_fixture()
      Apiary.Mail.put_test_source(:none)

      {:ok, {invitation, _token}} =
        Repo.transact(fn ->
          with {:ok, invitation, token} <-
                 Organisations.insert_invitation(scope, %{"email" => unique_user_email()},
                   allowance: other.organisation
                 ) do
            {:ok, {invitation, token}}
          end
        end)

      # The other organisation's day is spent: one by the invitation, the rest its own.
      for _ <- 2..@limit, do: {:ok, _, _} = invite(other)
      assert refused_for_the_day?(invite(other))

      assert refused_for_the_day?(renew(scope, invitation))

      # The scope's own day is untouched.
      assert {:ok, %Invitation{}, {:link, _url}} = invite(scope)
    end
  end
end
