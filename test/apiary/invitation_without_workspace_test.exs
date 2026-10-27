defmodule Apiary.InvitationWithoutWorkspaceTest do
  # An invitation sent while its organisation has no workspace (`workspace_id` nil): sent,
  # listed, renewed, revoked, withdrawn, swept and accepted, and refused from a scope
  # without a workspace once the organisation has one. Two at once are
  # `Apiary.InvitationWithoutWorkspaceRaceTest`'s. Not async: some tests set the mailer's
  # adapter and the day's limit, which are application configuration.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations
  alias Apiary.Organisations.{Invitation, Membership, OldInvitationsJob, Organisation}

  defp url(token), do: "http://localhost/invitations/#{token}"

  # The owner of a fresh organisation with no workspace, confirmed as a person who signed
  # up has been by the time they invite, at the organisation alone.
  defp without_workspace do
    {:ok, %{user: user, workspace: nil}} =
      Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: unique_organisation_name()},
        nil,
        open: true,
        workspace: false
      )

    token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
    {:ok, {user, _expired}} = Accounts.login_user_by_magic_link(token)
    assert %Scope{workspace: nil} = scope = Organisations.load_scope(Scope.for_user(user))
    scope
  end

  # A person of `level` in the scope's organisation, joined with no invitation.
  defp joined_scope(%Scope{organisation: organisation}, level) do
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
    |> Repo.insert!()

    Organisations.load_scope(Scope.for_user(user), organisation.id)
  end

  defp entry!(%Invitation{id: id}, action) do
    Repo.one!(from e in Entry, where: e.subject_id == ^id and e.action == ^action)
  end

  defp count_invitations(%Scope{organisation: %{id: id}}),
    do: Repo.aggregate(from(i in Invitation, where: i.organisation_id == ^id), :count)

  test "invited and accepted: the person joins the organisation, which has no workspace still" do
    scope = without_workspace()
    organisation = scope.organisation

    %{invitation: invitation, token: token} = invitation_fixture(scope)
    assert invitation.workspace_id == nil
    assert invitation.organisation_id == organisation.id

    # The email is the organisation's, as with a workspace.
    email = invitation.email
    assert_receive {:email, %Swoosh.Email{to: [{"", ^email}]} = mail}
    assert mail.text_body =~ "“#{organisation.name}”"

    assert %Invitation{workspace: nil, organisation: %{id: organisation_id}} =
             Organisations.get_invitation_by_token(token)

    assert organisation_id == organisation.id
    assert [%Invitation{workspace: nil}] = Organisations.list_invitations(scope)

    # Its entry is the organisation's, and names the allowance it counts against.
    assert %Entry{workspace_id: nil, details: %{"allowance_id" => allowance_id}} =
             entry!(invitation, "member.invite")

    assert allowance_id == organisation.id

    user = user_fixture(%{email: invitation.email})

    assert {:ok, %Membership{level: :member} = membership} =
             Organisations.accept_invitation(user, token)

    assert membership.organisation_id == organisation.id
    assert Repo.get(Invitation, invitation.id) == nil
    refute Organisations.has_workspace?(organisation)

    # The new member is at the organisation alone.
    assert %Scope{workspace: nil, membership: %{id: membership_id}} =
             Organisations.load_scope(Scope.for_user(user), organisation.id)

    assert membership_id == membership.id

    assert %Entry{workspace_id: nil, details: details, after: %{"level" => "member"}} =
             entry!(invitation, "invitation.accept")

    assert details["membership_id"] == membership.id
  end

  test "an owner and an admin invite with no workspace; a member does not" do
    scope = without_workspace()

    assert {:ok, %Invitation{workspace_id: nil}} =
             scope
             |> joined_scope(:admin)
             |> Organisations.invite_member(%{"email" => unique_user_email()}, &url/1)

    assert {:error, :forbidden} =
             scope
             |> joined_scope(:member)
             |> Organisations.invite_member(%{"email" => unique_user_email()}, &url/1)

    assert count_invitations(scope) == 1
  end

  test "a scope without a workspace is refused once the organisation has one, as before" do
    %{scope: scope} = sign_up_fixture()
    at_organisation = %{scope | workspace: nil}

    assert {:error, :not_found} =
             Organisations.invite_member(at_organisation, %{"email" => "x@example.com"}, &url/1)

    assert {:error, :not_found} =
             Repo.transact(fn ->
               Organisations.insert_invitation(at_organisation, %{"email" => "x@example.com"})
             end)

    assert count_invitations(scope) == 0
    refute Repo.exists?(from e in Entry, where: e.action == "member.invite")
  end

  test "pending while the organisation gets a workspace: accepted after, the person reaches it" do
    scope = without_workspace()
    %{invitation: invitation, token: token} = invitation_fixture(scope)

    assert {:ok, main} = Organisations.create_first_workspace(scope, %{"domain" => "software"})

    # Another one without a workspace is refused now, from the scope as it was loaded.
    assert {:error, :not_found} =
             Organisations.invite_member(scope, %{"email" => unique_user_email()}, &url/1)

    assert [%Invitation{workspace: nil}] = Organisations.list_invitations(scope)

    user = user_fixture(%{email: invitation.email})
    assert {:ok, %Membership{level: :member}} = Organisations.accept_invitation(user, token)

    # A member of the organisation, who reaches its workspace as every member does.
    assert workspace_scope(user, main)
    assert %Entry{workspace_id: nil} = entry!(invitation, "invitation.accept")
  end

  test "invited sign-up: the account joins the organisation, at no workspace" do
    scope = without_workspace()
    %{invitation: invitation, token: token} = invitation_fixture(scope)

    assert {:ok,
            %{user: user, organisation: organisation, workspace: nil, membership: membership}} =
             Organisations.sign_up_user(%{email: invitation.email}, token)

    assert organisation.id == scope.organisation.id
    assert %Membership{level: :member, user_id: user_id} = membership
    assert user_id == user.id
    assert Repo.get(Invitation, invitation.id) == nil

    assert %Entry{workspace_id: nil, actor_id: actor_id, details: details} =
             entry!(invitation, "invitation.accept")

    assert actor_id == user.id
    assert details["membership_id"] == membership.id
  end

  test "a new link: the same invitation, the old link ends, the entry is the organisation's" do
    scope = without_workspace()
    %{invitation: invitation, token: token} = invitation_fixture(scope)

    assert {:ok, %Invitation{workspace_id: nil} = renewed} =
             Organisations.renew_invitation(scope, invitation.id, &url/1)

    assert renewed.id == invitation.id
    assert renewed.token_hash != invitation.token_hash
    assert Organisations.get_invitation_by_token(token) == nil

    assert %Entry{workspace_id: nil, details: %{"allowance_id" => allowance_id}} =
             entry!(invitation, "invitation.renew")

    assert allowance_id == scope.organisation.id
  end

  test "a new link after the organisation got a workspace ends the validity period from now" do
    scope = without_workspace()
    %{invitation: invitation} = invitation_fixture(scope)

    # The invitation ends in a day, so a renewal that does not set a new end shows.
    Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), 1, :day)]
    )

    {:ok, main} = Organisations.create_first_workspace(scope, %{"domain" => "software"})
    at_main = workspace_scope(scope.user, main)

    before = DateTime.utc_now()

    assert {:ok, %Invitation{workspace_id: nil}} =
             Organisations.renew_invitation(at_main, invitation.id, &url/1)

    %Invitation{expires_at: expires_at} = Repo.get!(Invitation, invitation.id)
    from_now = DateTime.add(before, Invitation.validity_days(), :day)
    assert DateTime.diff(expires_at, from_now, :second) in 0..5

    # Renewed from the scope as it was loaded, at no workspace, too.
    assert {:ok, %Invitation{}} = Organisations.renew_invitation(scope, invitation.id, &url/1)

    # A member renews nothing.
    member = joined_scope(at_main, :member)

    assert {:error, :forbidden} =
             Organisations.renew_invitation(member, invitation.id, &url/1)
  end

  test "revoked: the row goes, and the entry is the organisation's" do
    scope = without_workspace()
    %{invitation: invitation, token: token} = invitation_fixture(scope)

    assert {:ok, %Invitation{}} = Organisations.revoke_invitation(scope, invitation.id)
    assert Organisations.get_invitation_by_token(token) == nil
    assert %Entry{workspace_id: nil} = entry!(invitation, "invitation.revoke")
  end

  describe "an email that could not be delivered" do
    setup do
      # The organisation's owner is confirmed by email first, on the real adapter.
      scope = without_workspace()
      previous_mailer = Application.fetch_env!(:apiary, Apiary.Mailer)
      previous_limit = Application.fetch_env!(:apiary, :invitations_per_day)
      Application.put_env(:apiary, :invitations_per_day, 2)

      on_exit(fn ->
        Application.put_env(:apiary, Apiary.Mailer, previous_mailer)
        Application.put_env(:apiary, :invitations_per_day, previous_limit)
      end)

      %{scope: scope, previous_mailer: previous_mailer}
    end

    test "withdraws the invitation, which is not counted against the day's", %{
      scope: scope,
      previous_mailer: previous_mailer
    } do
      Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)

      for _ <- 1..3 do
        assert {:error, :delivery_failed} =
                 Organisations.invite_member(scope, %{"email" => unique_user_email()}, &url/1)
      end

      assert count_invitations(scope) == 0

      assert [%Entry{workspace_id: nil, details: %{"reason" => "undelivered"}} | _] =
               withdrawals =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^scope.organisation.id and
                       e.action == "invitation.revoke"
               )

      assert length(withdrawals) == 3

      # No mail was sent: the day's two are still to send, and a third is refused.
      Application.put_env(:apiary, Apiary.Mailer, previous_mailer)

      for _ <- 1..2 do
        assert {:ok, %Invitation{workspace_id: nil}} =
                 Organisations.invite_member(scope, %{"email" => unique_user_email()}, &url/1)
      end

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => unique_user_email()}, &url/1)

      assert {_message, opts} = changeset.errors[:email]
      assert opts[:validation] == :invitations_per_day
    end
  end

  test "the sweep deletes one expired for 30 days, an entry of the organisation's" do
    scope = without_workspace()
    organisation = scope.organisation
    %{invitation: old} = invitation_fixture(scope)
    %{invitation: pending} = invitation_fixture(scope)

    Repo.update_all(from(i in Invitation, where: i.id == ^old.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)]
    )

    assert :ok =
             perform_job(OldInvitationsJob, %{
               "organisation_id" => organisation.id,
               "workspace_id" => nil
             })

    assert Repo.get(Invitation, old.id) == nil
    assert Repo.get(Invitation, pending.id)

    assert %Entry{workspace_id: nil, actor_kind: :instance, details: %{"reason" => "expired"}} =
             entry!(old, "invitation.revoke")
  end

  describe "insert_invitation/3" do
    test "writes one with no workspace, counted against another organisation's allowance" do
      scope = without_workspace()
      %{organisation: other} = sign_up_fixture()

      assert {:ok, {%Invitation{workspace_id: nil} = invitation, token}} =
               Repo.transact(fn ->
                 with {:ok, invitation, token} <-
                        Organisations.insert_invitation(
                          scope,
                          %{"email" => unique_user_email()},
                          allowance: other
                        ),
                      do: {:ok, {invitation, token}}
               end)

      assert %Entry{workspace_id: nil, details: %{"allowance_id" => allowance_id}} =
               entry!(invitation, "member.invite")

      assert allowance_id == other.id
      assert {:ok, %Organisation{id: ^allowance_id}} = Organisations.allowance_of(invitation)

      assert {:ok, %Invitation{}} =
               Organisations.send_invitation(scope, invitation, token, &url/1)

      assert %Invitation{workspace: nil} = Organisations.get_invitation_by_token(token)
    end

    test "refuses one with no workspace once the organisation has one, whatever the allowance" do
      scope = without_workspace()
      %{organisation: other} = sign_up_fixture()
      {:ok, _main} = Organisations.create_first_workspace(scope, %{"domain" => "software"})

      assert {:error, :not_found} =
               Repo.transact(fn ->
                 Organisations.insert_invitation(scope, %{"email" => unique_user_email()},
                   allowance: other
                 )
               end)

      assert count_invitations(scope) == 0
    end
  end
end
