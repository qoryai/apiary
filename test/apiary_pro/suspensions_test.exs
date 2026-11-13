defmodule ApiaryPro.SuspensionsTest do
  # A suspension pauses and removes nothing: an account and an organisation, by an instance
  # admin; and what the edition keeps of a membership's suspension, the core's
  # (`Apiary.SuspensionsTest`): its workspace access, and an owner whose account is
  # suspended.
  # Not async: its tests write through the suite's instance organisation, committed once
  # outside the sandbox, whose row and owners they lock (docs/conventions.md, Tests).
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Swoosh.TestAssertions
  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures, only: [generate_user_magic_link_token: 1, unique_user_email: 0]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, AccessKeys, Accounts, Audit, Nodes, Organisations}
  alias Apiary.Accounts.{User, UserToken}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Suspensions, WorkspaceAccess}
  alias ApiaryPro.Suspensions.AccountSuspension
  alias ApiaryPro.Tenants.Tenant

  describe "a membership's suspension" do
    setup do
      %{scope: owner} = signed_up = sign_up_fixture()

      %{
        signed_up: signed_up,
        owner: owner,
        member: member_fixture(owner, :member),
        other_owner: member_fixture(owner, :owner)
      }
    end

    test "an owner whose account is suspended is not the owner who remains", ctx do
      assert Organisations.other_active_owner?(ctx.owner.membership)
      admin = instance_admin_fixture()
      {:ok, _} = Suspensions.suspend_account(admin.instance_scope, ctx.other_owner.user.id)
      refute Organisations.other_active_owner?(ctx.owner.membership)

      assert {:error, :last_owner} =
               Organisations.remove_member(ctx.owner, ctx.owner.membership.id)

      # Nor is their own account deleted, beside a co-owner who may not act.
      assert [%Organisation{}] = Organisations.sole_owned_organisations(ctx.owner.user)
      assert {:error, :last_owner} = Accounts.delete_user(ctx.owner)
    end

    @tag needs: :security
    test "its workspace access stays: activated, they reach the workspaces they were added to",
         ctx do
      platform = workspace_fixture(ctx.owner.organisation, "Platform")

      {:ok, _} = WorkspaceAccess.add(ctx.owner, ctx.member.membership.id, platform.id)

      in_platform = workspace_scope(ctx.member.user, platform)

      {:ok, _} = Organisations.suspend_member(ctx.owner, ctx.member.membership.id)

      assert Repo.aggregate(
               from(a in WorkspaceAccess.Row, where: a.user_id == ^ctx.member.user.id),
               :count
             ) == 2

      assert workspace_scope(ctx.member.user, platform) == nil

      {:ok, _} = Organisations.activate_member(ctx.owner, ctx.member.membership.id)

      assert Access.authorize(in_platform, :"security_policy.edit", platform) == :ok
      assert workspace_scope(ctx.member.user, platform)
    end
  end

  describe "an account's suspension" do
    setup do
      %{scope: owner, user: user} = signed_up = sign_up_fixture()
      admin = instance_admin_fixture()
      %{signed_up: signed_up, owner: owner, user: user, admin: admin.instance_scope}
    end

    test "its sessions are deleted and returned, and it signs in nowhere", ctx do
      token = Accounts.generate_user_session_token(ctx.user)
      assert {%User{}, _at} = Accounts.get_user_by_session_token(token)

      assert {:ok, %{user: %User{id: id} = user, tokens: tokens}} =
               Suspensions.suspend_account(ctx.admin, ctx.user.id)

      assert %AccountSuspension{suspended_at: %DateTime{}, suspended_by_id: by} =
               Repo.get!(AccountSuspension, id)

      assert by == ctx.admin.user.id
      assert tokens != [] and Enum.all?(tokens, &(&1.context == "session"))

      assert Repo.all(
               from t in UserToken, where: t.user_id == ^ctx.user.id and t.context == "session"
             ) == []

      assert Accounts.get_user_by_session_token(token) == nil

      # A session made anyhow is no session, and a login link logs nobody in.
      assert Accounts.get_user_by_session_token(Accounts.generate_user_session_token(user)) ==
               nil

      {encoded, _token} = generate_user_magic_link_token(user)
      assert {:error, :suspended} = Accounts.login_user_by_magic_link(encoded)

      # Suspended already: nothing changes, no entry.
      count = count()
      assert {:ok, %{tokens: []}} = Suspensions.suspend_account(ctx.admin, ctx.user.id)
      assert count() == count

      assert {:ok, %User{}} = Suspensions.activate_account(ctx.admin, ctx.user.id)
      refute Suspensions.account_suspended?(ctx.user.id)

      token = Accounts.generate_user_session_token(ctx.user)
      assert {%User{}, _at} = Accounts.get_user_by_session_token(token)
    end

    test "its memberships count as none, and the keys of its workspaces keep working", ctx do
      %{access_key: key, node: node} = access_key_fixture(ctx.owner)
      elsewhere = sign_up_fixture()
      %{scope: there} = join_fixture(elsewhere.scope, ctx.user)
      assert length(Organisations.list_memberships(ctx.user)) == 2

      {:ok, _} = Suspensions.suspend_account(ctx.admin, ctx.user.id)

      assert Organisations.list_memberships(ctx.user) == []
      assert workspace_scope(ctx.user, ctx.owner.workspace) == nil

      assert {:error, :forbidden} =
               Organisations.update_organisation(ctx.owner, %{name: "Renamed"})

      assert {:error, :forbidden} = AccessKeys.add_access_key(ctx.owner, node, new_key())
      assert workspace_scope(ctx.user, there.workspace) == nil
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)

      # Nothing was removed.
      assert Repo.aggregate(from(m in Membership, where: m.user_id == ^ctx.user.id), :count) == 2

      {:ok, _} = Suspensions.activate_account(ctx.admin, ctx.user.id)
      assert length(Organisations.list_memberships(ctx.user)) == 2
      assert {:ok, _} = Organisations.update_organisation(ctx.owner, %{name: "Renamed"})
    end

    test "the entries are the instance organisation's, and name the account by id", ctx do
      {:ok, _} = Suspensions.suspend_account(ctx.admin, ctx.user.id)

      assert %Entry{action: "instance.suspend_account", details: %{"user_id" => id}} =
               entry =
               last()

      assert id == ctx.user.id
      assert entry.organisation_id == ctx.admin.organisation.id
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.admin.user.id}

      {:ok, _} = Suspensions.activate_account(ctx.admin, ctx.user.id)
      assert %Entry{action: "instance.activate_account", details: %{"user_id" => ^id}} = last()

      # Not suspended: activating changes nothing, and leaves no entry.
      count = count()

      assert {:ok, %User{}} = Suspensions.activate_account(ctx.admin, ctx.user.id)
      refute Suspensions.account_suspended?(ctx.user.id)
      assert count() == count
    end

    test "an instance admin suspends no account of their own, and none but on Instance settings › Accounts",
         ctx do
      assert {:error, :forbidden} = Suspensions.suspend_account(ctx.admin, ctx.admin.user.id)
      assert {:error, :not_found} = Suspensions.suspend_account(ctx.owner, ctx.user.id)
      assert {:error, :not_found} = Suspensions.suspend_account(ctx.admin, Ecto.UUID.generate())
      assert {:error, :not_found} = Suspensions.suspend_account(ctx.admin, "not-an-id")

      # A member of the instance organisation is no instance admin.
      %{scope: member} = member_fixture(ctx.admin, :member)
      assert {:error, :forbidden} = Suspensions.suspend_account(member, ctx.user.id)

      deleted = Apiary.AccountsFixtures.user_fixture()
      {:ok, _} = Accounts.delete_user(%Apiary.Accounts.Scope{user: deleted})
      assert {:error, :not_found} = Suspensions.suspend_account(ctx.admin, deleted.id)
    end

    test "the instance keeps an admin who may act: a suspended one suspends nobody", ctx do
      other = instance_admin_fixture()
      {:ok, _} = Suspensions.suspend_account(ctx.admin, other.user.id)

      assert {:error, :forbidden} =
               Suspensions.suspend_account(other.instance_scope, ctx.admin.user.id)

      refute Access.instance_admin?(other.instance_scope)
      assert Access.instance_admin?(ctx.admin)
    end
  end

  describe "an organisation's suspension" do
    setup do
      %{scope: owner} = signed_up = sign_up_fixture()
      admin = member_fixture(owner, :admin)
      member = member_fixture(owner, :member)
      %{access_key: key, node: node} = access_key_fixture(owner)

      %{
        signed_up: signed_up,
        owner: owner,
        admin: admin,
        member: member,
        key: key,
        node: node,
        instance_admin: instance_admin_fixture().instance_scope
      }
    end

    test "it is read-only for every level, and its reads work", ctx do
      {:ok, %Organisation{} = suspended} =
        Suspensions.suspend_organisation(ctx.instance_admin, ctx.owner.organisation.id)

      assert %Tenant{suspended_at: %DateTime{}, suspended_by_id: by} = tenant_of(suspended)
      assert by == ctx.instance_admin.user.id

      assert {:error, :forbidden} =
               Organisations.update_organisation(ctx.owner, %{name: "Renamed"})

      assert {:error, :forbidden} = Organisations.update_workspace(ctx.admin.scope, %{name: "B"})

      assert {:error, :forbidden} =
               AccessKeys.add_access_key(ctx.admin.scope, ctx.node, new_key())

      assert {:error, :forbidden} =
               Organisations.suspend_member(ctx.owner, ctx.member.membership.id)

      # Its people still sign in to it, and read.
      assert %{} = workspace_scope(ctx.member.user, ctx.owner.workspace)
      assert {:ok, %{entries: [_ | _]}} = Audit.list_entries(ctx.owner)
      assert Access.authorize(ctx.member.scope, :"run.read", ctx.owner.workspace) == :ok
      assert ApiaryPro.Access.suspended?(workspace_scope(ctx.owner.user, ctx.owner.workspace))

      {:ok, %Organisation{edition: %{tenant: %Tenant{suspended_at: nil}}}} =
        Suspensions.activate_organisation(ctx.instance_admin, ctx.owner.organisation.id)

      assert {:ok, _} = Organisations.update_organisation(ctx.owner, %{name: "Renamed"})
      assert {:ok, _} = AccessKeys.add_access_key(ctx.admin.scope, ctx.node, new_key())
    end

    test "its access keys are refused at verification until it is activated", ctx do
      assert {:ok, _} = AccessKeys.fetch_for_verification(ctx.key.key_id)
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, ctx.owner.organisation.id)
      assert AccessKeys.fetch_for_verification(ctx.key.key_id) == :error
      {:ok, _} = Suspensions.activate_organisation(ctx.instance_admin, ctx.owner.organisation.id)
      assert {:ok, _} = AccessKeys.fetch_for_verification(ctx.key.key_id)
    end

    test "it sends no invitation, and an invitation's token accepts no one", ctx do
      %{token: token} = invitation_fixture(ctx.owner)
      flush_emails()

      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, ctx.owner.organisation.id)

      assert {:error, :forbidden} =
               Organisations.invite_member(
                 ctx.owner,
                 %{"email" => unique_user_email()},
                 &"http://localhost/invitations/#{&1}"
               )

      assert_no_email_sent()
      assert Organisations.get_invitation_by_token(token) == nil
      %{user: user} = sign_up_fixture()
      assert {:error, :invalid} = Organisations.accept_invitation(user, token)

      {:ok, _} = Suspensions.activate_organisation(ctx.instance_admin, ctx.owner.organisation.id)
      assert {:ok, %Membership{}} = Organisations.accept_invitation(user, token)
    end

    test "each suspension and activation is the organisation's entry; one that changes nothing is none",
         ctx do
      id = ctx.owner.organisation.id
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, id)

      assert %Entry{
               action: "instance.suspend_organisation",
               subject_kind: "organisation",
               before: %{"suspended_at" => nil},
               workspace_id: nil
             } = entry = last()

      assert entry.organisation_id == id
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.instance_admin.user.id}
      count = count()

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{suspended_at: %DateTime{}}}}} =
               Suspensions.suspend_organisation(ctx.instance_admin, id)

      assert count() == count

      {:ok, _} = Suspensions.activate_organisation(ctx.instance_admin, id)

      assert %Entry{action: "instance.activate_organisation", after: %{"suspended_at" => nil}} =
               last()

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{suspended_at: nil}}}} =
               Suspensions.activate_organisation(ctx.instance_admin, id)

      assert count() == count + 1
    end

    test "it is suspended only on Instance settings › Organisations, and not once marked for deletion",
         ctx do
      id = ctx.owner.organisation.id
      assert {:error, :not_found} = Suspensions.suspend_organisation(ctx.owner, id)

      assert {:error, :not_found} =
               Suspensions.suspend_organisation(ctx.instance_admin, Ecto.UUID.generate())

      %{scope: instance_member} = member_fixture(ctx.instance_admin, :admin)
      assert {:error, :forbidden} = Suspensions.suspend_organisation(instance_member, id)

      {:ok, _} = Apiary.Deletion.delete_organisation(ctx.owner, ctx.owner.organisation.slug)
      assert {:error, :not_found} = Suspensions.suspend_organisation(ctx.instance_admin, id)
    end

    test "the instance organisation is never suspended" do
      admin = instance_admin_fixture()
      instance = instance_organisation()

      assert {:error, :forbidden} =
               Suspensions.suspend_organisation(admin.instance_scope, instance.id)

      assert %Tenant{suspended_at: nil} = tenant_of(instance)

      # Nor does the database let it be.
      assert_raise Postgrex.Error, ~r/tenants_instance_organisation_not_suspended/, fn ->
        Repo.update_all(from(t in Tenant, where: t.organisation_id == ^instance.id),
          set: [suspended_at: DateTime.utc_now()]
        )
      end
    end
  end

  describe "an operator's suspension" do
    @describetag needs: :managed_organisations

    setup do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      client_admin = client_member_fixture(client)
      %{access_key: client_key, node: client_node} = access_key_fixture(client_admin.scope)
      %{access_key: operator_key} = access_key_fixture(operator.scope)

      %{
        operator: operator,
        client: client,
        client_admin: client_admin,
        client_key: client_key,
        client_node: client_node,
        operator_key: operator_key,
        instance_admin: instance_admin_fixture().instance_scope
      }
    end

    test "its people read its clients no more, which keep working, their owners with them",
         ctx do
      refute ApiaryPro.Suspensions.owner_suspended?(ctx.client.organisation)

      {:ok, _} =
        Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      # The operator's owner reaches the client no more.
      assert scope_in(ctx.operator.user, ctx.client.organisation) == nil

      refute Enum.any?(
               Organisations.list_places(ctx.operator.user),
               &(&1.organisation_id == ctx.client.organisation.id)
             )

      assert {:error, :forbidden} =
               Nodes.create_node(ctx.client.scope, %{"kind" => "node", "name" => "build-01"})

      # The client's own admin works, and its keys verify; the operator's own do not.
      assert {:ok, _} =
               AccessKeys.add_access_key(ctx.client_admin.scope, ctx.client_node, new_key())

      assert {:ok, _} = AccessKeys.fetch_for_verification(ctx.client_key.key_id)
      assert AccessKeys.fetch_for_verification(ctx.operator_key.key_id) == :error

      # Its owners are its own: they may act, and nothing of theirs waits.
      refute ApiaryPro.Suspensions.owner_suspended?(ctx.client.organisation)

      refute ApiaryPro.Reach.owner_suspended?(
               scope_in(ctx.client_admin.user, ctx.client.organisation).organisation
             )

      {:ok, _} =
        Suspensions.activate_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      # Activated, its people read the client again, and change nothing there.
      assert %{} =
               scope = scope_in(ctx.operator.user, ctx.client.organisation, ctx.client.workspace)

      assert {:error, :forbidden} =
               Nodes.create_node(scope, %{"kind" => "node", "name" => "build-03"})

      assert {:ok, _} = AccessKeys.fetch_for_verification(ctx.operator_key.key_id)
    end
  end

  describe "owner_suspended?/1" do
    test "an organisation whose owners' accounts are all suspended runs below the owner level" do
      %{organisation: organisation, user: owner, scope: scope} = sign_up_fixture()
      %{user: second} = member_fixture(scope, :owner)
      admin = instance_admin_fixture()

      {:ok, _} = Suspensions.suspend_account(admin.instance_scope, second.id)
      refute ApiaryPro.Suspensions.owner_suspended?(organisation)

      {:ok, _} = Suspensions.suspend_account(admin.instance_scope, owner.id)
      assert ApiaryPro.Suspensions.owner_suspended?(organisation)

      {:ok, _} = Suspensions.activate_account(admin.instance_scope, owner.id)
      refute ApiaryPro.Suspensions.owner_suspended?(organisation)
    end

    @tag needs: :managed_organisations
    test "a client runs below the owner level by its own owners alone, not its operator's" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      admin = instance_admin_fixture()

      {:ok, _} = Suspensions.suspend_account(admin.instance_scope, operator.user.id)
      refute ApiaryPro.Suspensions.owner_suspended?(client.organisation)

      {:ok, _} = Suspensions.suspend_account(admin.instance_scope, client.owner.user.id)
      assert ApiaryPro.Suspensions.owner_suspended?(client.organisation)
    end
  end

  describe "left_without_owner/1" do
    @describetag needs: :managed_organisations

    test "names what an account's suspension leaves without an owner who may act" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      %{scope: shared_scope, organisation: shared} = sign_up_fixture()
      %{membership: joined} = join_fixture(shared_scope, operator.user)
      {:ok, _} = Organisations.set_member_level(shared_scope, joined.id, :owner)

      names = operator.user.id |> Suspensions.left_without_owner() |> Enum.map(& &1.id)

      assert operator.organisation.id in names
      # Its operator's clients have owners of their own.
      refute client.organisation.id in names
      # An organisation it owns beside an owner who may act is not.
      refute shared.id in names

      assert [only] = Suspensions.left_without_owner(client.owner.user.id)
      assert only.id == client.organisation.id
    end
  end

  describe "the arbiter's offer, once an owner may act again" do
    setup do
      %{organisation: organisation, user: owner, scope: scope} = sign_up_fixture()
      %{membership: admin_membership, user: admin_user} = member_fixture(scope, :admin)
      admin = instance_admin_fixture()
      {:ok, _} = Suspensions.suspend_account(admin.instance_scope, owner.id)

      {:ok, _} =
        ApiaryPro.Transfers.arbitrate(
          admin.instance_scope,
          organisation.id,
          admin_membership.id,
          "Its owner is away."
        )

      %{
        organisation: organisation,
        owner: owner,
        admin_user: admin_user,
        instance_admin: admin
      }
    end

    test "the owner's account activated withdraws it, by the instance admin who did", ctx do
      {:ok, _} = Suspensions.activate_account(ctx.instance_admin.instance_scope, ctx.owner.id)

      refute Repo.get_by(ApiaryPro.Transfers.Transfer, organisation_id: ctx.organisation.id)

      assert %Entry{
               actor_id: actor_id,
               details: %{"reason" => "owner_activated", "arbitrated" => true}
             } =
               Repo.one(
                 from e in Entry,
                   where: e.organisation_id == ^ctx.organisation.id,
                   where: e.action == "organisation.withdraw_transfer"
               )

      assert actor_id == ctx.instance_admin.user.id
    end

    test "an owner who may act again is not overruled by an acceptance either", ctx do
      # The account activated without the withdrawal, as a race could leave it.
      Repo.delete_all(from s in AccountSuspension, where: s.user_id == ^ctx.owner.id)

      admin_scope = scope_in(ctx.admin_user, ctx.organisation)
      assert {:error, :has_owner} = ApiaryPro.Transfers.accept(admin_scope)
    end
  end

  defp last, do: Repo.one(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)
  defp count, do: Repo.aggregate(Entry, :count)

  # A node's key as Generate a key sends it from an owner's or an admin's browser: a label
  # and the public half of a fresh key.
  defp new_key, do: %{"label" => "build-01", "public_key" => ed25519_key_pair().encoded}

  # The emails the fixtures sent, taken out of the mailbox.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
