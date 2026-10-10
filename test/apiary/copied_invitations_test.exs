defmodule Apiary.CopiedInvitationsTest do
  @moduledoc """
  Without mail, an invitation is kept and its link is handed back to copy, once; with
  mail it is emailed, as before. A lost link is replaced with `renew_invitation/4`: the
  same invitation, a new link, the old one dead at once; with `action:`, for a caller that
  asked `Apiary.Access` itself, its token is handed back for `send_invitation/4`. The
  limits are `Apiary.InvitationLimitTest`'s.
  """
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Apiary.{Mail, Organisations}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Invitation, Membership, Organisation}

  @url "http://localhost/invitations/"

  defp url_fun, do: &(@url <> &1)

  defp token_of({:link, @url <> token}), do: token

  defp entries(invitation, action) do
    Repo.all(
      from e in Entry,
        where: e.subject_id == ^invitation.id and e.action == ^action,
        order_by: [asc: e.inserted_at]
    )
  end

  # An invitation insert_invitation/3 counted against `allowance`, and its token.
  defp insert!(scope, email, allowance) do
    {:ok, {invitation, token}} =
      Repo.transact(fn ->
        with {:ok, invitation, token} <-
               Organisations.insert_invitation(scope, %{"email" => email}, allowance: allowance) do
          {:ok, {invitation, token}}
        end
      end)

    {invitation, token}
  end

  # An expiry long ago enough that a renewal's is plainly new.
  defp age!(invitation) do
    {1, _} =
      Repo.update_all(
        from(i in Invitation, where: i.id == ^invitation.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)]
      )

    :ok
  end

  # What a fixture makes with mail on: it confirms its accounts by email.
  defp mailed(fun) do
    Mail.put_test_source(:env)
    result = fun.()
    flush_emails()
    Mail.put_test_source(:none)
    result
  end

  # The emails a fixture sent before the test's own.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  describe "without mail" do
    setup do
      %{scope: scope} = sign_up_fixture()
      Mail.put_test_source(:none)
      flush_emails()
      %{scope: scope}
    end

    test "invite_member/3 keeps the invitation and hands its link back, sending nothing",
         %{scope: scope} do
      log =
        capture_log(fn ->
          assert {:ok, %Invitation{} = invitation, {:link, url} = link} =
                   Organisations.invite_member(scope, %{"email" => "dana@example.com"}, url_fun())

          send(self(), {:invited, invitation, link, url})
        end)

      assert_received {:invited, invitation, link, url}
      token = token_of(link)

      # Kept, pending and listed; the token is never stored, only its hash.
      assert [%Invitation{id: id}] = Organisations.list_invitations(scope)
      assert id == invitation.id
      assert Repo.get!(Invitation, id).token_hash == Invitation.hash_token(token)
      assert %Invitation{id: ^id} = Organisations.get_invitation_by_token(token)

      # Nothing mailed, nothing withdrawn, and the link in no log line.
      assert_no_email_sent()
      assert [%Entry{}] = entries(invitation, "member.invite")
      assert entries(invitation, "invitation.revoke") == []
      refute log =~ token
      refute log =~ url

      # The link accepts.
      assert {:ok, %Membership{level: :member}} =
               Organisations.accept_invitation(mailed(&user_fixture/0), token)
    end

    test "an inviter whose account is not confirmed may make a link: nothing is mailed for them",
         %{scope: scope} do
      unconfirmed = %{scope | user: %{scope.user | confirmed_at: nil}}

      assert {:ok, %Invitation{}, {:link, _url}} =
               Organisations.invite_member(
                 unconfirmed,
                 %{"email" => "dana@example.com"},
                 url_fun()
               )

      assert {:ok, {%Invitation{}, token}} =
               Repo.transact(fn ->
                 with {:ok, invitation, token} <-
                        Organisations.insert_invitation(unconfirmed, %{
                          "email" => "eli@example.com"
                        }) do
                   {:ok, {invitation, token}}
                 end
               end)

      assert is_binary(token)
      assert_no_email_sent()
    end

    test "send_invitation/4 hands the link back for an invitation insert_invitation/3 wrote",
         %{scope: scope} do
      {:ok, {invitation, token}} =
        Repo.transact(fn ->
          with {:ok, invitation, token} <-
                 Organisations.insert_invitation(scope, %{"email" => "dana@example.com"}) do
            {:ok, {invitation, token}}
          end
        end)

      assert {:ok, ^invitation, {:link, url}} =
               Organisations.send_invitation(scope, invitation, token, url_fun())

      assert url == @url <> token
      assert_no_email_sent()
      assert Organisations.get_invitation_by_token(token)
    end

    test "renew_invitation/3: the same invitation, a new link, the old one dead at once, 7 days again",
         %{scope: scope} do
      {:ok, invitation, old} =
        Organisations.invite_member(scope, %{"email" => "dana@example.com"}, url_fun())

      old = token_of(old)
      age!(invitation)

      assert {:ok, %Invitation{id: id} = renewed, {:link, url}} =
               Organisations.renew_invitation(scope, invitation.id, url_fun())

      new = token_of({:link, url})
      assert id == invitation.id
      assert new != old

      # The old link finds nothing, and accepts nobody; the new one does.
      assert Organisations.get_invitation_by_token(old) == nil
      assert {:error, _} = Organisations.accept_invitation(mailed(&user_fixture/0), old)
      assert %Invitation{id: ^id} = Organisations.get_invitation_by_token(new)

      # Seven days from now again.
      assert DateTime.diff(renewed.expires_at, DateTime.utc_now(), :hour) in 167..168
      assert [%Invitation{id: ^id}] = Organisations.list_invitations(scope)

      # Its entry, counted against the allowance the invitation was counted against.
      assert [%Entry{details: details} = entry] = entries(invitation, "invitation.renew")
      assert details == %{"allowance_id" => scope.organisation.id}
      assert entry.organisation_id == scope.organisation.id
      assert entry.actor_id == scope.user.id
      assert_no_email_sent()

      assert {:ok, %Membership{}} = Organisations.accept_invitation(mailed(&user_fixture/0), new)
    end

    test "renew_invitation/3 by an unconfirmed owner: a link, as an invitation would be",
         %{scope: scope} do
      %{invitation: invitation} = invitation_fixture(scope)
      unconfirmed = %{scope | user: %{scope.user | confirmed_at: nil}}

      assert {:ok, %Invitation{}, {:link, _url}} =
               Organisations.renew_invitation(unconfirmed, invitation.id, url_fun())
    end

    test "renew_invitation/3 charges the allowance the invitation was counted against",
         %{scope: scope} do
      %{scope: other} = mailed(&sign_up_fixture/0)

      {:ok, {invitation, _token}} =
        Repo.transact(fn ->
          with {:ok, invitation, token} <-
                 Organisations.insert_invitation(scope, %{"email" => "dana@example.com"},
                   allowance: other.organisation
                 ) do
            {:ok, {invitation, token}}
          end
        end)

      assert {:ok, _renewed, {:link, _url}} =
               Organisations.renew_invitation(scope, invitation.id, url_fun())

      # And again: each renewal names the same allowance.
      assert {:ok, _renewed, {:link, _url}} =
               Organisations.renew_invitation(scope, invitation.id, url_fun())

      assert [first, second] = entries(invitation, "invitation.renew")
      assert first.details == %{"allowance_id" => other.organisation.id}
      assert second.details == %{"allowance_id" => other.organisation.id}
      # In the invitation's own organisation's trail.
      assert first.organisation_id == scope.organisation.id
    end

    test "renew_invitation/3 refuses a member, another organisation's invitation, and one no longer pending",
         %{scope: scope} do
      %{invitation: invitation, token: token} = invitation_fixture(scope)
      %{scope: member} = mailed(fn -> member_fixture(scope, :member) end)

      assert {:error, :forbidden} =
               Organisations.renew_invitation(member, invitation.id, url_fun())

      %{scope: other} = mailed(&sign_up_fixture/0)

      assert {:error, :not_found} =
               Organisations.renew_invitation(other, invitation.id, url_fun())

      assert {:error, :not_found} = Organisations.renew_invitation(scope, "nope", url_fun())

      # Refused, nothing changed: the link still works, and no entry was written.
      assert Organisations.get_invitation_by_token(token)
      assert entries(invitation, "invitation.renew") == []

      # Expired.
      {1, _} =
        Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)]
        )

      assert {:error, :not_found} =
               Organisations.renew_invitation(scope, invitation.id, url_fun())

      # Accepted.
      %{invitation: accepted, token: token} = invitation_fixture(scope)
      {:ok, _} = Organisations.accept_invitation(mailed(&user_fixture/0), token)

      assert {:error, :not_found} =
               Organisations.renew_invitation(scope, accepted.id, url_fun())
    end

    test "renew_invitation/4 with action: hands the token back; send_invitation/4 makes the link",
         %{scope: scope} do
      %{invitation: invitation, token: old} = invitation_fixture(scope)
      id = invitation.id

      assert {:ok, %Invitation{id: ^id} = renewed, token} =
               Organisations.renew_invitation(scope, id, url_fun(), action: :"member.invite")

      assert is_binary(token)
      assert Organisations.get_invitation_by_token(old) == nil
      assert_no_email_sent()

      assert {:ok, ^renewed, {:link, url}} =
               Organisations.send_invitation(scope, renewed, token, url_fun())

      assert url == @url <> token
      assert %Invitation{id: ^id} = Organisations.get_invitation_by_token(token)
      assert_no_email_sent()
    end

    test "renew_invitation/4 with action: inside a transaction that holds the allowance already",
         %{scope: scope} do
      %{scope: other} = mailed(&sign_up_fixture/0)
      {invitation, _old} = insert!(scope, "dana@example.com", other.organisation)

      assert {:ok, {%Invitation{} = renewed, token}} =
               Repo.transact(fn ->
                 # As an edition's renewal holds it, before it asks.
                 Repo.one!(
                   from o in Organisation,
                     where: o.id == ^other.organisation.id,
                     select: o.id,
                     lock: "FOR NO KEY UPDATE"
                 )

                 with {:ok, renewed, token} <-
                        Organisations.renew_invitation(scope, invitation.id, url_fun(),
                          action: :"member.invite"
                        ) do
                   {:ok, {renewed, token}}
                 end
               end)

      assert renewed.id == invitation.id
      assert %Invitation{} = Organisations.get_invitation_by_token(token)

      assert [_invited, %Entry{details: details}] = entries(invitation, "member.invite")
      assert details == %{"allowance_id" => other.organisation.id}
    end

    test "an admin renews too; the instance does not", %{scope: scope} do
      %{invitation: invitation} = invitation_fixture(scope)
      %{scope: admin} = mailed(fn -> member_fixture(scope, :admin) end)

      assert {:ok, _renewed, {:link, _url}} =
               Organisations.renew_invitation(admin, invitation.id, url_fun())

      instance = Scope.for_instance(scope.organisation, scope.workspace)

      assert {:error, :forbidden} =
               Organisations.renew_invitation(instance, invitation.id, url_fun())
    end
  end

  describe "with mail" do
    setup do
      %{scope: scope} = sign_up_fixture()
      flush_emails()
      %{scope: scope}
    end

    test "invite_member/3 emails the link and answers the invitation alone", %{scope: scope} do
      assert {:ok, %Invitation{}} =
               Organisations.invite_member(scope, %{"email" => "dana@example.com"}, url_fun())

      assert_email_sent(fn email -> email.to == [{"", "dana@example.com"}] end)
    end

    test "an inviter whose account is not confirmed invites nobody", %{scope: scope} do
      unconfirmed = %{scope | user: %{scope.user | confirmed_at: nil}}

      assert {:error, :unconfirmed} =
               Organisations.invite_member(
                 unconfirmed,
                 %{"email" => "dana@example.com"},
                 url_fun()
               )

      assert {:error, :unconfirmed} =
               Repo.transact(fn ->
                 Organisations.insert_invitation(unconfirmed, %{"email" => "dana@example.com"})
               end)

      %{invitation: invitation} = invitation_fixture(scope)

      assert {:error, :unconfirmed} =
               Organisations.renew_invitation(unconfirmed, invitation.id, url_fun())

      assert entries(invitation, "invitation.renew") == []
    end

    test "renew_invitation/3 emails the new link; the old one is dead", %{scope: scope} do
      %{invitation: invitation, token: old} = invitation_fixture(scope)
      assert_email_sent()

      assert {:ok, %Invitation{id: id}} =
               Organisations.renew_invitation(scope, invitation.id, url_fun())

      assert id == invitation.id
      assert Organisations.get_invitation_by_token(old) == nil

      assert_email_sent(fn email ->
        [_, token] = Regex.run(~r{/invitations/([A-Za-z0-9_-]+)}, email.text_body)
        assert %Invitation{id: ^id} = Organisations.get_invitation_by_token(token)
        assert email.to == [{"", invitation.email}]
      end)
    end

    test "renew_invitation/4 with action: a member renews, recorded as the action, mailing nothing",
         %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      {invitation, old} = insert!(scope, "dana@example.com", other.organisation)
      %{scope: member} = member_fixture(scope, :member)
      flush_emails()
      id = invitation.id

      # Refused by the core's own question, allowed with the caller's.
      assert {:error, :forbidden} = Organisations.renew_invitation(member, id, url_fun())

      assert {:ok, %Invitation{id: ^id} = renewed, token} =
               Organisations.renew_invitation(member, id, url_fun(), action: :"member.invite")

      assert is_binary(token)
      assert_no_email_sent()

      # The old link is dead at once; the new one is the token handed back.
      assert Organisations.get_invitation_by_token(old) == nil
      assert %Invitation{id: ^id} = Organisations.get_invitation_by_token(token)

      # Its entry is the action given, by the member, charged to the recorded allowance.
      assert entries(invitation, "invitation.renew") == []
      assert [_invited, %Entry{} = entry] = entries(invitation, "member.invite")
      assert entry.details == %{"allowance_id" => other.organisation.id}
      assert entry.actor_id == member.user.id
      assert entry.organisation_id == scope.organisation.id

      # Then the caller sends it.
      assert {:ok, ^renewed} = Organisations.send_invitation(member, renewed, token, url_fun())

      assert_email_sent(fn email ->
        assert email.to == [{"", invitation.email}]
        assert email.text_body =~ @url <> token
      end)
    end
  end
end
