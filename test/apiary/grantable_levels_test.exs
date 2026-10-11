defmodule Apiary.GrantableLevelsTest do
  @moduledoc """
  The levels the edition refuses to give in an organisation
  (`Apiary.Access.level_refusal/4`, `Apiary.Access.grantable_levels/1`), which every way the
  core gives a level asks: under an edition that refuses none, and under stubs of one that
  refuses some (`Apiary.EditionStubs`), each in the test's own processes.
  """
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Organisations}
  alias Apiary.Accounts.User
  alias Apiary.Audit.Entry
  alias Apiary.EditionStubs
  alias Apiary.Organisations.{Invitation, Membership}

  defp entries(organisation),
    do: Repo.aggregate(from(e in Entry, where: e.organisation_id == ^organisation.id), :count)

  defp url(token), do: "http://localhost/invitations/#{token}"

  test "an organisation the edition refuses nothing in offers every level" do
    %{scope: scope, organisation: organisation} = sign_up_fixture()
    assert Access.grantable_levels(scope) == [:owner, :admin, :member]
    assert Access.level_refusal(scope, organisation, :owner) == nil
    assert Access.grantable_levels(nil) == []
  end

  describe "where nobody is made an owner" do
    setup do
      %{scope: owner} = sign_up_fixture()
      %{membership: member} = member_fixture(owner, :member)
      %{membership: second_owner} = member_fixture(owner, :owner)
      :ok = Apiary.Edition.put_test_stub(EditionStubs.NoOwner)
      %{owner: owner, member: member, second_owner: second_owner}
    end

    test "admin and member are offered, owner refused with the edition's reason", %{
      owner: owner
    } do
      assert Access.grantable_levels(owner) == [:admin, :member]
      assert Access.level_refusal(owner, owner.organisation, :owner) == :no_owner
    end

    test "a change of level to owner is refused, and changes and records nothing", ctx do
      before = entries(ctx.owner.organisation)

      assert {:error, {:level_refused, :no_owner}} =
               Organisations.set_member_level(ctx.owner, ctx.member.id, :owner)

      assert Repo.reload!(ctx.member).level == :member
      assert entries(ctx.owner.organisation) == before

      # The levels it does not refuse are given as before.
      assert {:ok, %Membership{level: :admin}} =
               Organisations.set_member_level(ctx.owner, ctx.member.id, "admin")
    end

    test "an owner keeps their level, and is not made one again once demoted", ctx do
      assert {:ok, %Membership{level: :owner}} =
               Organisations.set_member_level(ctx.owner, ctx.second_owner.id, :owner)

      assert {:ok, %Membership{level: :admin}} =
               Organisations.set_member_level(ctx.owner, ctx.second_owner.id, :admin)

      assert {:error, {:level_refused, :no_owner}} =
               Organisations.set_member_level(ctx.owner, ctx.second_owner.id, :owner)

      assert Repo.reload!(ctx.second_owner).level == :admin
    end

    test "an invitation, at member, is sent and accepted as before", %{owner: owner} do
      user = user_fixture()
      %{token: token} = invitation_fixture(owner, %{"email" => user.email})

      assert {:ok, %Membership{level: :member}} = Organisations.accept_invitation(user, token)
    end
  end

  describe "where nobody is made an owner, and an invitation would make one" do
    setup do
      %{scope: owner} = sign_up_fixture()
      %{owner: owner}
    end

    test "accepting it is refused as an invitation no longer valid, and makes nothing",
         %{owner: owner} do
      user = user_fixture()

      %{invitation: invitation, token: token} =
        invitation_fixture(owner, %{"email" => user.email})

      before = entries(owner.organisation)
      :ok = Apiary.Edition.put_test_stub(EditionStubs.NoOwnerInvitedAsOwner)

      assert {:error, :invalid} = Organisations.accept_invitation(user, token)

      refute Repo.get_by(Membership, organisation_id: owner.organisation.id, user_id: user.id)
      assert Repo.get(Invitation, invitation.id)
      assert entries(owner.organisation) == before
    end

    test "a sign-up with it is refused on its address, and makes no account", %{owner: owner} do
      email = unique_user_email()
      %{invitation: invitation, token: token} = invitation_fixture(owner, %{"email" => email})
      :ok = Apiary.Edition.put_test_stub(EditionStubs.NoOwnerInvitedAsOwner)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organisations.sign_up_user(valid_user_attributes(%{email: email}), token)

      assert "was invited, but the invitation is no longer valid" in errors_on(changeset).email
      refute Repo.get_by(User, email: email)
      assert Repo.get(Invitation, invitation.id)
    end
  end

  describe "where nobody is made a member" do
    test "an invitation, whose person joins as a member, is refused and not written" do
      %{scope: owner} = sign_up_fixture()
      before = entries(owner.organisation)
      :ok = Apiary.Edition.put_test_stub(EditionStubs.NoMember)

      assert {:error, {:level_refused, :no_member}} =
               Organisations.invite_member(owner, %{"email" => "invitee@example.com"}, &url/1)

      assert Organisations.list_invitations(owner) == []
      assert entries(owner.organisation) == before
    end
  end
end
