defmodule ApiaryPro.InstanceAdminTest do
  @moduledoc """
  The instance admins are the owners of the instance organisation:
  `Apiary.Access.instance_admin?/1` says who is one, and the release commands grant and
  revoke one. The command's claim of an instance nobody has signed up to is the core's
  test (`Apiary.InstanceAdminTest`), whatever the edition; here, only that on this
  instance the claim creates the instance organisation, of the kind the instance's
  features give its first sign-up.
  """
  # Not async: the release commands act on the suite's instance organisation, which every
  # test shares.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureIO
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Organisations, Release}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Membership
  alias ApiaryPro.WorkspaceAccess

  defp instance, do: ApiaryPro.Organisations.instance_organisation()

  defp membership(user),
    do: Repo.get_by(Membership, organisation_id: instance().id, user_id: user.id)

  defp entries(action) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^instance().id and e.action == ^action,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp quietly(fun) do
    send(self(), {:result, nil})
    capture_io(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, nil}
    assert_received {:result, result}
    result
  end

  describe "instance_admin?/1" do
    test "an owner of the instance organisation is one; an owner of any other organisation is not" do
      %{scope: scope, user: user} = sign_up_fixture()
      refute Access.instance_admin?(scope)

      {:ok, _} = Organisations.grant_instance_admin(user)
      # Whatever organisation the scope is in.
      assert Access.instance_admin?(scope)
      assert Access.instance_admin?(Scope.for_user(user))

      {:ok, _} = Organisations.revoke_instance_admin(user)
      refute Access.instance_admin?(scope)

      refute Access.instance_admin?(nil)
      refute Access.instance_admin?(Scope.for_instance(instance()))
    end

    test "nobody deletes the instance organisation, its owners included" do
      %{user: user} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(user)
      {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), instance().slug)

      refute Access.can?(scope, :"organisation.delete", scope.organisation)
      assert {:error, :forbidden} = Apiary.Deletion.delete_organisation(scope, instance().slug)
      assert Access.can?(scope, :"organisation.rename", scope.organisation)
    end
  end

  describe "the instance organisation is never purged" do
    test "not at once, and not by the sweep, even marked behind the product's back" do
      instance = instance()

      assert {:error, :instance_organisation} = Apiary.Deletion.purge_now(instance)

      assert %{deletion_marked_at: nil} =
               Repo.get!(Apiary.Organisations.Organisation, instance.id)

      Repo.query!(
        """
        UPDATE organisations
        SET deletion_marked_at = now() - interval '40 days', purge_after = now() - interval '1 day',
            purge_trigger = 'grace_period'
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(instance.id)]
      )

      marked = Repo.get!(Apiary.Organisations.Organisation, instance.id)
      {due, _cursor} = Apiary.Deletion.page_organisations_due(nil, 10_000)
      refute instance.id in due

      assert {:error, :forbidden} =
               Apiary.Deletion.purge_organisation(Scope.for_instance(marked))

      assert Repo.get(Apiary.Organisations.Organisation, instance.id)
      refute Access.can?(Scope.for_instance(marked), :"organisation.purge", marked)
      assert Access.refused_on?(:"organisation.purge", marked)
      assert Access.refused_on?(:"organisation.delete", marked)
      refute Access.refused_on?(:"organisation.rename", marked)
    end
  end

  describe "grant_instance_admin/1" do
    test "makes an account an owner of the instance organisation, with an entry by the instance" do
      %{user: user} = sign_up_fixture()

      assert {:ok, %Membership{level: :owner}} =
               quietly(fn -> Release.grant_instance_admin(" #{user.email} ") end)

      assert %Membership{level: :owner} = membership(user)
      # An owner reaches every workspace, with no workspace access.
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)

      assert [entry] = entries("instance_admin.grant")
      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      assert entry.worker == "Apiary.Release.grant_instance_admin/2"
      assert entry.after == %{"level" => "owner"}
      assert entry.details == %{"user_id" => user.id}
    end

    test "makes a member an owner, and changes nothing for an owner" do
      %{user: user} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(user)
      {:ok, _} = Organisations.revoke_instance_admin(user)
      assert %Membership{level: :member} = membership(user)

      assert {:ok, %{was: :member}} = Organisations.grant_instance_admin(user)
      assert %Membership{level: :owner} = membership(user)

      assert [_, entry] = entries("instance_admin.grant")
      assert entry.before == %{"level" => "member"}

      assert {:ok, %Membership{level: :owner}} =
               quietly(fn -> Release.grant_instance_admin(user.email) end)

      assert [_, _] = entries("instance_admin.grant")
    end

    test "refuses an address that no account has" do
      assert {:error, :not_found} =
               quietly(fn -> Release.grant_instance_admin("nobody@example.com") end)
    end
  end

  describe "grant_instance_admin/2 on an instance nobody has signed up to" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      assert instance() == nil
      :ok
    end

    test "claims it with the instance organisation, of the first sign-up's kind, the account its owner" do
      assert {:ok, :created} =
               quietly(fn ->
                 Release.grant_instance_admin("claim@example.com", "Acme Hosting")
               end)

      assert %{name: "Acme Hosting"} = organisation = instance()
      assert ApiaryPro.Tenants.kind(organisation) == ApiaryPro.Tenants.first_sign_up_kind()
      assert ApiaryPro.Tenants.instance_organisation?(organisation)
      assert instance().id == Apiary.Edition.instance_organisation_id()
      user = Apiary.Accounts.get_user_by_email("claim@example.com")
      assert %Membership{level: :owner} = membership(user)
    end
  end

  describe "the instance organisation's own members" do
    test "an owner made in the product is an instance admin, and a demotion ends it" do
      %{user: founder} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(founder)
      {:ok, founder_scope} = Organisations.resolve_scope(Scope.for_user(founder), instance().slug)

      # Invited into the instance organisation, the person joins as a member: no instance
      # admin.
      %{user: user, membership: membership} = member_fixture(founder_scope, :member)
      refute Access.instance_admin?(Scope.for_user(user))

      {:ok, _} = Organisations.set_member_level(founder_scope, membership.id, :owner)
      assert Access.instance_admin?(Scope.for_user(user))

      {:ok, _} = Organisations.set_member_level(founder_scope, membership.id, :admin)
      refute Access.instance_admin?(Scope.for_user(user))

      {:ok, _} = Organisations.set_member_level(founder_scope, membership.id, :member)
      refute Access.instance_admin?(Scope.for_user(user))
    end

    test "an admin of the instance organisation makes nobody an owner, themselves included" do
      %{user: founder} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(founder)
      {:ok, founder_scope} = Organisations.resolve_scope(Scope.for_user(founder), instance().slug)

      %{membership: admin, user: admin_user} = member_fixture(founder_scope, :admin)

      %{membership: member, user: member_user} = member_fixture(founder_scope, :member)

      {:ok, admin_scope} =
        Organisations.resolve_scope(Scope.for_user(admin_user), instance().slug)

      assert admin_scope.membership.level == :admin

      for target <- [admin, member] do
        assert {:error, :forbidden} =
                 Organisations.set_member_level(admin_scope, target.id, :owner)
      end

      refute Access.instance_admin?(admin_scope)
      refute Access.instance_admin?(Scope.for_user(member_user))
    end
  end

  describe "revoke_instance_admin/1" do
    test "makes an owner a member, with an entry by the instance, and keeps them in a workspace" do
      %{user: user} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(user)

      assert {:ok, %Membership{level: :member}} =
               quietly(fn -> Release.revoke_instance_admin(user.email) end)

      refute Access.instance_admin?(Scope.for_user(user))

      assert [entry] = entries("instance_admin.revoke")
      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      assert entry.before == %{"level" => "owner"}
      assert entry.after == %{"level" => "member"}

      # Made a member without workspace access, they are added to the first workspace.
      assert [%WorkspaceAccess.Row{}] =
               Repo.all(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)
    end

    test "refuses the last owner, and an account that is not an owner" do
      [owner] =
        Repo.all(
          from m in Membership,
            where: m.organisation_id == ^instance().id and m.level == :owner,
            preload: :user
        )

      assert {:error, :last_owner} =
               quietly(fn -> Release.revoke_instance_admin(owner.user.email) end)

      assert %Membership{level: :owner} = Repo.get!(Membership, owner.id)

      %{user: stranger} = sign_up_fixture()

      assert {:error, :not_owner} =
               quietly(fn -> Release.revoke_instance_admin(stranger.email) end)

      assert entries("instance_admin.revoke") == []

      # With a second owner, the first may go.
      {:ok, _} = Organisations.grant_instance_admin(stranger)
      assert {:ok, _} = Organisations.revoke_instance_admin(owner.user)
      assert {:error, :last_owner} = Organisations.revoke_instance_admin(stranger)
    end
  end
end
