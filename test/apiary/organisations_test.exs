defmodule Apiary.OrganisationsTest do
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations
  alias Apiary.Organisations.{Invitation, Membership, Organisation}

  describe "sign_up_user/2" do
    test "creates the user, an organisation named from the email, a Main hive and an owner membership" do
      {:ok, %{user: user, organisation: organisation, hive: hive, membership: membership}} =
        Organisations.sign_up_user(%{email: "alice@example.com"})

      assert user.email == "alice@example.com"
      assert organisation.name == "alice"
      assert hive.name == "Main"
      assert hive.organisation_id == organisation.id
      assert membership.level == :owner
      assert membership.user_id == user.id
      assert membership.organisation_id == organisation.id
      assert membership.hive_id == hive.id
    end

    test "returns the user changeset when the email is invalid, creating nothing" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.sign_up_user(%{email: "nope"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
      assert Repo.aggregate(Organisation, :count) == 0
    end

    test "with a valid invitation token creates no organisation and accepts the invitation" do
      %{scope: scope, organisation: organisation, hive: hive} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope, %{"level" => "member"})
      count = Repo.aggregate(Organisation, :count)

      {:ok, result} = Organisations.sign_up_user(%{email: invitation.email}, token)

      assert result.organisation.id == organisation.id
      assert result.hive.id == hive.id
      assert result.membership.level == :member
      assert Repo.aggregate(Organisation, :count) == count
      assert Repo.get!(Invitation, invitation.id).accepted_at
      assert Organisations.get_invitation_by_token(token) == nil
    end

    test "with an invalid token behaves as without a token" do
      {:ok, %{organisation: organisation, membership: membership}} =
        Organisations.sign_up_user(%{email: unique_user_email()}, "not-a-token")

      assert organisation.name
      assert membership.level == :owner
    end
  end

  describe "load_scope/2 and list_memberships/1" do
    test "loads the earliest membership by default and a named organisation on request" do
      %{user: user, organisation: first} = sign_up_fixture()
      %{scope: other_scope, organisation: second} = sign_up_fixture()
      %{token: token} = invitation_fixture(other_scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      scope = Organisations.load_scope(Scope.for_user(user))
      assert scope.organisation.id == first.id
      assert scope.hive.organisation_id == first.id
      assert scope.membership.level == :owner

      scope = Organisations.load_scope(Scope.for_user(user), second.id)
      assert scope.organisation.id == second.id
      assert scope.membership.level == :member

      assert [first.id, second.id] ==
               user |> Organisations.list_memberships() |> Enum.map(& &1.organisation.id)
    end

    test "leaves the scope unchanged for a user without memberships, and nil for no user" do
      user = user_fixture()
      scope = Scope.for_user(user)
      assert Organisations.load_scope(scope) == scope
      assert Organisations.load_scope(nil) == nil
    end
  end

  describe "settings" do
    test "owners rename the organisation and the hive; members cannot" do
      %{scope: owner_scope} = sign_up_fixture()
      %{scope: member_scope} = member_fixture(owner_scope, :member)

      assert {:ok, %Organisation{name: "Acme"}} =
               Organisations.update_organisation(owner_scope, %{name: "Acme"})

      assert {:ok, %{name: "Platform"}} =
               Organisations.update_hive(owner_scope, %{name: "Platform"})

      assert {:error, :unauthorized} =
               Organisations.update_organisation(member_scope, %{name: "X"})

      assert {:error, :unauthorized} = Organisations.update_hive(member_scope, %{name: "X"})

      assert {:error, %Ecto.Changeset{}} =
               Organisations.update_organisation(owner_scope, %{name: ""})

      assert %Ecto.Changeset{} = Organisations.change_organisation(%Organisation{})
    end
  end

  describe "members" do
    test "list_members/1 puts owners first, then by insertion" do
      %{scope: scope, user: owner} = sign_up_fixture()
      %{user: member} = member_fixture(scope, :member)
      %{user: second_owner} = member_fixture(scope, :owner)

      assert [owner.id, second_owner.id, member.id] ==
               scope |> Organisations.list_members() |> Enum.map(& &1.user.id)
    end

    test "set_member_level/3 promotes and demotes, owners only, never the last owner" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{scope: member_scope, membership: membership} = member_fixture(scope, :member)

      assert {:error, :unauthorized} =
               Organisations.set_member_level(member_scope, owner_membership.id, :member)

      assert {:error, :last_owner} =
               Organisations.set_member_level(scope, owner_membership.id, "member")

      assert {:ok, %Membership{level: :owner}} =
               Organisations.set_member_level(scope, membership.id, "owner")

      assert {:ok, %Membership{level: :member}} =
               Organisations.set_member_level(scope, owner_membership.id, :member)

      assert {:error, :not_found} =
               Organisations.set_member_level(scope, Ecto.UUID.generate(), :member)
    end

    test "remove_member/2 removes members, owners only, never the last owner" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      %{scope: member_scope, membership: membership} = member_fixture(scope, :member)
      %{scope: other_scope} = sign_up_fixture()

      assert {:error, :unauthorized} = Organisations.remove_member(member_scope, membership.id)
      assert {:error, :last_owner} = Organisations.remove_member(scope, owner_membership.id)
      assert {:error, :not_found} = Organisations.remove_member(other_scope, membership.id)
      assert {:ok, %Membership{}} = Organisations.remove_member(scope, membership.id)
      assert Repo.get(Membership, membership.id) == nil
    end

    test "an owner may remove themselves when another owner exists" do
      %{scope: scope, membership: owner_membership} = sign_up_fixture()
      _second_owner = member_fixture(scope, :owner)

      assert {:ok, %Membership{}} = Organisations.remove_member(scope, owner_membership.id)
    end
  end

  describe "invitations" do
    test "invite_member/3 stores a hash, emails the URL, and lists pending; owners only" do
      %{scope: scope, user: inviter, organisation: organisation} = sign_up_fixture()

      assert {:ok, invitation} =
               Organisations.invite_member(
                 scope,
                 %{"email" => "Bob@Example.com", "level" => "member"},
                 &"http://localhost/invitations/#{&1}"
               )

      assert invitation.email == "bob@example.com"
      assert invitation.level == :member
      assert invitation.invited_by_id == inviter.id
      assert invitation.hive_id == scope.hive.id
      assert byte_size(invitation.token_hash) == 32
      assert DateTime.diff(invitation.expires_at, DateTime.utc_now(), :day) in 6..7

      assert_receive {:email, %Swoosh.Email{to: [{"", "bob@example.com"}]} = email}
      assert email.subject =~ organisation.name
      assert email.text_body =~ inviter.email
      assert email.text_body =~ "http://localhost/invitations/"
      refute email.text_body =~ Base.encode16(invitation.token_hash)

      assert [%Invitation{id: id}] = Organisations.list_invitations(scope)
      assert id == invitation.id

      %{scope: member_scope} = member_fixture(scope, :member)

      assert {:error, :unauthorized} =
               Organisations.invite_member(member_scope, %{"email" => "x@example.com"}, & &1)

      assert Organisations.list_invitations(member_scope) |> length() == 1
    end

    test "invite_member/3 refuses an existing member and a duplicate pending invitation" do
      %{scope: scope, user: owner} = sign_up_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => owner.email}, & &1)

      assert %{email: ["is already a member of this organisation"]} = errors_on(changeset)

      assert {:ok, _} = Organisations.invite_member(scope, %{"email" => "c@example.com"}, & &1)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => "c@example.com"}, & &1)

      assert %{email: ["has already been invited"]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.invite_member(scope, %{"email" => "bad"}, & &1)

      assert %{email: [_]} = errors_on(changeset)
    end

    test "get_invitation_by_token/1 returns only pending invitations" do
      %{scope: scope} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)

      assert %Invitation{id: id, organisation: %Organisation{}, hive: %{}} =
               Organisations.get_invitation_by_token(token)

      assert id == invitation.id
      assert Organisations.get_invitation_by_token("nope") == nil
      assert Organisations.get_invitation_by_token(nil) == nil

      Repo.update!(change(invitation, expires_at: DateTime.add(DateTime.utc_now(), -1, :second)))
      assert Organisations.get_invitation_by_token(token) == nil
      assert Organisations.list_invitations(scope) == []

      # The expired invitation no longer blocks a new one for the same address.
      assert {:ok, _} = Organisations.invite_member(scope, %{"email" => invitation.email}, & &1)
    end

    test "accept_invitation/2 joins at the invitation's level, once" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope, %{"level" => "owner"})
      user = user_fixture()

      assert {:ok, %Membership{level: :owner} = membership} =
               Organisations.accept_invitation(user, token)

      assert membership.organisation_id == organisation.id
      assert {:error, :invalid} = Organisations.accept_invitation(user, token)

      %{token: token} = invitation_fixture(scope)
      assert {:error, :already_member} = Organisations.accept_invitation(user, token)
      assert {:error, :invalid} = Organisations.accept_invitation(user, "garbage")
    end

    test "revoke_invitation/2 deletes the row; owners only" do
      %{scope: scope} = sign_up_fixture()
      %{scope: member_scope} = member_fixture(scope, :member)
      %{invitation: invitation, token: token} = invitation_fixture(scope)

      assert {:error, :unauthorized} =
               Organisations.revoke_invitation(member_scope, invitation.id)

      assert {:error, :not_found} = Organisations.revoke_invitation(scope, Ecto.UUID.generate())
      assert {:ok, %Invitation{}} = Organisations.revoke_invitation(scope, invitation.id)
      assert Organisations.get_invitation_by_token(token) == nil
    end

    test "change_invitation/2 downcases the email" do
      changeset = Organisations.change_invitation(%Invitation{}, %{"email" => "A@B.example"})
      assert get_change(changeset, :email) == "a@b.example"
    end
  end
end
