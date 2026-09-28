defmodule Apiary.AccountDeletionTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Accounts, Deletion, Organisations}
  alias Apiary.Accounts.{User, UserToken}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Organisations.{Invitation, Membership}

  describe "delete_user/2" do
    test "leaves a tombstone: the id stays, the personal data goes" do
      %{scope: owner} = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner)
      user = set_password(user)
      _session = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.update_user_preferences(user, %{time_zone: "Europe/Berlin"})
      %{access_key: key} = access_key_fixture(scope)

      assert {:ok, {tombstone, tokens}} = Accounts.delete_user(scope)
      assert [_ | _] = tokens

      assert %User{
               id: id,
               email: nil,
               hashed_password: nil,
               confirmed_at: nil,
               time_zone: "Etc/UTC",
               language: "en",
               skin: "standard",
               deleted_at: %DateTime{}
             } = Repo.get!(User, user.id)

      assert id == tombstone.id
      assert Repo.all(from t in UserToken, where: t.user_id == ^user.id) == []
      assert Repo.all(from m in Membership, where: m.user_id == ^user.id) == []

      # What the person made stays with the workspace, and names the tombstone.
      assert %AccessKey{created_by_id: ^id, revoked_at: nil} = Repo.get!(AccessKey, key.id)
    end

    test "sign-in, a log-in link and a session never find a tombstone" do
      %{scope: owner} = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner)
      user = set_password(user)
      session = Accounts.generate_user_session_token(user)
      {magic, _hashed} = generate_user_magic_link_token(user)

      {:ok, _} = Accounts.delete_user(scope)

      assert Accounts.get_user_by_email(user.email) == nil
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password()) == nil
      assert Accounts.get_user_by_session_token(session) == nil
      assert Accounts.get_user_by_magic_link_token(magic) == nil
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(magic)
    end

    test "the address is free for a new account at once" do
      %{scope: owner} = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner)
      {:ok, _} = Accounts.delete_user(scope)

      assert {:ok, %{user: again}} =
               Organisations.sign_up_user(
                 %{email: user.email, organisation_name: "Again"},
                 nil,
                 open: true
               )

      assert again.id != user.id
      assert Accounts.get_user_by_email(user.email).id == again.id
    end

    test "is refused while the person is the only owner of an organisation" do
      %{scope: scope, user: user, organisation: organisation} = sign_up_fixture()
      %{scope: member} = member_fixture(scope)

      assert [%{id: id}] = Organisations.sole_owned_organisations(user)
      assert id == organisation.id
      assert {:error, :last_owner} = Accounts.delete_user(scope)
      assert Repo.get!(User, user.id).email == user.email

      # Another owner, and it may go.
      {:ok, _} = Organisations.set_member_level(scope, member.membership.id, :owner)
      assert Organisations.sole_owned_organisations(user) == []
      assert {:ok, _} = Accounts.delete_user(scope)
      assert [_] = Organisations.list_memberships(member.user)
    end

    test "an organisation marked for deletion does not hold the person back" do
      %{scope: scope, user: user} = sign_up_fixture()
      {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)

      assert Organisations.sole_owned_organisations(user) == []
      assert {:ok, _} = Accounts.delete_user(scope)
    end

    test "an account deleted already is not found" do
      %{scope: owner} = sign_up_fixture()
      %{scope: scope, user: user} = member_fixture(owner)
      {:ok, _} = Accounts.delete_user(scope)

      assert {:error, :not_found} = Accounts.delete_user(scope)
      assert {:error, :not_found} = Accounts.delete_user(user)
    end

    test "a membership's end is announced to the person's open pages" do
      %{scope: owner} = sign_up_fixture()
      %{scope: scope, user: user} = member_fixture(owner)
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(user.id))

      {:ok, _} = Accounts.delete_user(scope)
      assert_receive {:membership_changed, %{organisation_id: organisation_id}}
      assert organisation_id == owner.organisation.id
    end

    test "a deleted account accepts no invitation" do
      %{scope: owner} = sign_up_fixture()
      %{token: token, invitation: invitation} = invitation_fixture(owner)
      user = user_fixture()
      scope = Apiary.Accounts.Scope.for_user(user)

      {:ok, _} = Accounts.delete_user(scope)

      assert {:error, :invalid} = Organisations.accept_invitation(scope, token)
      assert {:error, :invalid} = Organisations.accept_invitation(user, token)
      assert Repo.get!(Invitation, invitation.id)
      assert Repo.all(from m in Membership, where: m.user_id == ^user.id) == []
    end

    test "a deleted account never counts as the owner who remains" do
      %{scope: scope, organisation: organisation, membership: membership} = sign_up_fixture()
      tombstone = user_fixture()
      {:ok, _} = Accounts.delete_user(Apiary.Accounts.Scope.for_user(tombstone))

      # A membership no path leaves a deleted account, written as it is, to show the
      # counts ask the account.
      Repo.insert!(%Membership{
        organisation_id: organisation.id,
        user_id: tombstone.id,
        level: :owner
      })

      assert {:error, :last_owner} =
               Organisations.set_member_level(scope, membership.id, :member)

      assert [%{id: id}] = Organisations.sole_owned_organisations(scope.user)
      assert id == organisation.id
    end

    test "an invitation sent by the person stays, and names the tombstone" do
      %{scope: owner} = sign_up_fixture()
      %{scope: scope, user: user} = member_fixture(owner, :owner)
      %{invitation: invitation} = invitation_fixture(scope)

      {:ok, _} = Accounts.delete_user(scope)
      assert Repo.get!(Invitation, invitation.id).invited_by_id == user.id
    end
  end

  describe "the release command" do
    test "deletes by address, as the instance, and refuses the only owner" do
      %{scope: owner, user: founder} = sign_up_fixture()
      %{user: user} = member_fixture(owner)

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, id} = Apiary.Release.delete_account(user.email)
        assert id == user.id
        assert {:error, :not_found} = Apiary.Release.delete_account(user.email)
        assert {:error, :last_owner} = Apiary.Release.delete_account(founder.email)
      end)

      assert Repo.get!(User, user.id).deleted_at
      assert Repo.get!(User, founder.id).email == founder.email
    end
  end

  describe "the schema" do
    test "only a deleted account may be without an address" do
      user = user_fixture()

      assert_raise Ecto.ConstraintError, ~r/users_email_unless_deleted/, fn ->
        user |> Ecto.Changeset.change(email: nil) |> Repo.update()
      end

      assert {:ok, _} = user |> User.delete_changeset() |> Repo.update()
      assert %User{email: nil} = Repo.get!(User, user.id)
    end

    test "any number of deleted accounts, none with an address" do
      for _ <- 1..2 do
        %{scope: owner} = sign_up_fixture()
        %{scope: scope} = member_fixture(owner)
        {:ok, _} = Accounts.delete_user(scope)
      end

      assert Repo.aggregate(from(u in User, where: is_nil(u.email)), :count) == 2
    end
  end
end
