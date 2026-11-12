defmodule ApiaryPro.OperatorAsOwnerTest do
  # The operator owns its clients for this process and those it starts
  # (`ApiaryPro.Flags.put_operator_infrastructure/1`), once the world is made as it was
  # before: the client's owner is a legacy owner. The test of the instance's arbiter is in
  # `ApiaryPro.OperatorAsOwnerArbiterTest`.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Organisations}
  alias ApiaryPro.{Flags, Operators}

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    platform = workspace_fixture(client.organisation, "Platform")
    operator_admin = member_fixture(operator.scope, :admin)
    operator_member = member_fixture(operator.scope, :member)

    Flags.put_operator_infrastructure(true)

    # On the operator's providers: what the operator sets in the client includes its model
    # providers, runtimes and model choices.
    client = model_chain_fixture(operator.scope, client, :operator)

    %{
      operator: operator,
      client: client,
      platform: platform,
      client_admin: client_member_fixture(client, :admin),
      client_member: client_member_fixture(client, :member),
      invitation: invitation_fixture(client.owner.scope).invitation,
      operator_admin: operator_admin,
      operator_member: operator_member,
      as_owner: client.scope,
      as_admin: scope_in(operator_admin.user, client.organisation, client.workspace),
      as_member: scope_in(operator_member.user, client.organisation, client.workspace)
    }
  end

  @changes_in_client [
    {:"organisation.rename", :organisation},
    {:"organisation.delete", :organisation},
    {:"organisation.transfer", :organisation},
    {:"organisation.leave_operator", :organisation},
    {:"workspace.rename", :workspace},
    {:"workspace.delete", :organisation},
    {:"retention.edit", :workspace},
    {:"node.create", :workspace},
    {:"connection.write", :organisation},
    {:"security_policy.edit", :workspace},
    {:"security_policy.lock", :workspace},
    {:"security_policy.set_mode", :workspace},
    {:"member.invite", :invitation},
    {:"invitation.revoke", :invitation},
    {:"member.change_level", :client_member},
    {:"member.remove", :client_member},
    {:"member.suspend", :client_member},
    {:"member.activate", :client_member},
    {:"workspace_access.add", :client_member},
    {:"workspace_access.remove", :client_member}
  ]

  describe "the role" do
    test "is the operator's owner's and admin's own level, and a reader's for its members",
         ctx do
      assert Access.role(ctx.as_owner) == :owner
      assert Access.role(ctx.as_admin) == :admin
      assert Access.role(ctx.as_member) == :reader

      # With the flag off, every level reads.
      Flags.put_operator_infrastructure(false)

      for as <- [:as_owner, :as_admin, :as_member],
          do: assert(Access.role(ctx[as]) == :reader)
    end

    test "is a writer's for the operator's owners and admins: none of them is a reader", ctx do
      # The core's `reader/1` names the reach only for a role that changes nothing
      # (`Apiary.Access.reads_only?/1`): the write powers come from the role, not from
      # `check/3`.
      for as <- [ctx.as_owner, ctx.as_admin, ctx.client_admin.scope] do
        assert Access.reader(as) == nil
        refute Access.reads_only?(Map.fetch!(Access.roles(), Access.role(as)))
      end

      assert Access.role(ctx.client_admin.scope) == :admin

      # The operator's members read only.
      assert Access.reads_only?(Map.fetch!(Access.roles(), Access.role(ctx.as_member)))
      assert Access.reader(ctx.as_member) == :operator

      # With the flag off, every one of the operator's people reads.
      Flags.put_operator_infrastructure(false)

      for as <- [ctx.as_owner, ctx.as_admin, ctx.as_member],
          do: assert(Access.reader(as) == :operator)

      assert Access.reader(ctx.client_admin.scope) == nil
    end

    test "an instance admin still reads", ctx do
      admin = suite_instance_admin()
      scope = scope_in(admin.user, ctx.client.organisation, ctx.client.workspace)
      assert Access.role(scope) == :reader

      assert Access.authorize(scope, :"organisation.rename", ctx.client.organisation) ==
               {:error, :forbidden}
    end
  end

  describe "the operator's people in a client" do
    test "its members read everything and change nothing", ctx do
      scope = ctx.as_member
      assert Access.authorize(scope, :"run.read", ctx.client.workspace) == :ok
      assert Access.authorize(scope, :"audit.read", ctx.client.organisation) == :ok

      for {action, on} <- @changes_in_client do
        refute Access.can?(scope, action, on(ctx, on)), "#{action}"
        assert {:error, _refused} = Access.authorize(scope, action, on(ctx, on)), "#{action}"
      end
    end

    test "its owners take an owner's changes, over anyone in the client", ctx do
      owner = ctx.as_owner

      for {action, on} <- [
            {:"organisation.rename", :organisation},
            {:"security_policy.lock", :workspace},
            {:"security_policy.set_mode", :workspace},
            {:"connection.write", :organisation},
            {:"provider.write", :organisation},
            {:"runtime.write", :organisation},
            {:"retention.edit", :workspace},
            {:"member.invite", :invitation},
            {:"member.change_level", :client_member},
            {:"member.remove", :client_member},
            {:"member.suspend", :client_member}
          ] do
        assert Access.authorize(owner, action, on(ctx, on)) == :ok, "#{action}"
      end

      assert Access.authorize(owner, :"member.change_level", ctx.client_admin.membership) == :ok
      assert Access.authorize(owner, :"member.remove", ctx.client.owner.membership) == :ok

      # Every workspace, the ones they were not added to among them.
      in_platform = scope_in(ctx.operator.user, ctx.client.organisation, ctx.platform)
      assert Access.authorize(in_platform, :"security_policy.edit", ctx.platform) == :ok
    end

    test "its admins take an admin's changes, over the client's members", ctx do
      admin = ctx.as_admin

      for {action, on} <- [
            {:"organisation.rename", :organisation},
            {:"security_policy.set_mode", :workspace},
            {:"connection.write", :organisation},
            {:"provider.write", :organisation},
            {:"runtime.write", :organisation},
            {:"member.invite", :invitation},
            {:"member.remove", :client_member},
            {:"member.suspend", :client_member}
          ] do
        assert Access.authorize(admin, action, on(ctx, on)) == :ok, "#{action}"
      end

      for {action, on} <- [
            {:"security_policy.lock", :workspace},
            {:"organisation.delete", :organisation}
          ] do
        assert Access.authorize(admin, action, on(ctx, on)) == {:error, :forbidden},
               "#{action}"
      end

      assert Access.authorize(admin, :"member.remove", ctx.client.owner.membership) ==
               {:error, :forbidden}
    end

    test "authorize/3 fails closed once they are removed from the operator", ctx do
      scope = ctx.as_admin
      assert Access.can?(scope, :"organisation.rename", ctx.client.organisation)

      {:ok, _} = Organisations.remove_member(ctx.operator.scope, ctx.operator_admin.membership.id)

      assert Access.can?(scope, :"organisation.rename", ctx.client.organisation)

      assert Access.authorize(scope, :"organisation.rename", ctx.client.organisation) ==
               {:error, :forbidden}
    end

    test "authorize/3 fails closed once they are made a member of the operator", ctx do
      scope = ctx.as_admin

      {:ok, _} =
        Organisations.set_member_level(
          ctx.operator.scope,
          ctx.operator_admin.membership.id,
          :member
        )

      assert Access.can?(scope, :"organisation.rename", ctx.client.organisation)

      assert Access.authorize(scope, :"organisation.rename", ctx.client.organisation) ==
               {:error, :forbidden}

      assert Access.authorize(scope, :"run.read", ctx.client.workspace) == :ok
    end

    test "authorize/3 fails closed once the operator is suspended", ctx do
      admin = suite_instance_admin()

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(
          admin.instance_scope,
          ctx.operator.organisation.id
        )

      for scope <- [ctx.as_owner, ctx.as_admin] do
        assert {:error, _refused} =
                 Access.authorize(scope, :"organisation.rename", ctx.client.organisation)
      end
    end
  end

  describe "someone in both acts at the higher of their two levels" do
    test "an owner of the operator who is a member of the client acts as an owner", ctx do
      %{user: user} = member_fixture(ctx.operator.scope, :owner)
      Flags.put_operator_infrastructure(false)
      join_fixture(ctx.client.owner.scope, user)
      Flags.put_operator_infrastructure(true)

      in_main = scope_in(user, ctx.client.organisation, ctx.client.workspace)
      in_platform = scope_in(user, ctx.client.organisation, ctx.platform)
      assert Access.level(in_main) == :member

      # In a workspace their membership in the client does not reach.
      assert Access.authorize(in_platform, :"node.create", ctx.platform) == :ok
      assert Access.authorize(in_platform, :"security_policy.lock", ctx.platform) == :ok
      assert Access.authorize(in_main, :"member.change_level", ctx.client_admin.membership) == :ok

      # With the flag off, their membership decides.
      Flags.put_operator_infrastructure(false)

      assert Access.authorize(in_platform, :"security_policy.lock", ctx.platform) ==
               {:error, :forbidden}
    end

    test "a member of the operator who is an admin of the client acts as an admin", ctx do
      user = ctx.operator_member.user
      Flags.put_operator_infrastructure(false)
      %{membership: joined} = join_fixture(ctx.client.owner.scope, user)
      {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, joined.id, :admin)
      Flags.put_operator_infrastructure(true)

      scope = scope_in(user, ctx.client.organisation, ctx.platform)
      assert Access.level(scope) == :admin
      assert Access.authorize(scope, :"security_policy.set_mode", ctx.platform) == :ok
      assert Access.authorize(scope, :"member.remove", ctx.client_member.membership) == :ok

      assert Access.authorize(scope, :"security_policy.lock", ctx.platform) ==
               {:error, :forbidden}
    end

    test "an admin of the operator who is an owner of the client acts as its owner", ctx do
      user = ctx.operator_admin.user
      Flags.put_operator_infrastructure(false)
      %{membership: joined} = join_fixture(ctx.client.owner.scope, user)
      {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, joined.id, :owner)
      Flags.put_operator_infrastructure(true)

      scope = scope_in(user, ctx.client.organisation, ctx.client.workspace)
      assert Access.level(scope) == :owner
      assert Access.authorize(scope, :"member.change_level", ctx.client_admin.membership) == :ok

      # But for a rule's lock and the organisation's policy, the operator's owners' alone.
      for {action, on} <- [
            {:"security_policy.lock", ctx.client.workspace},
            {:"organisation_policy.edit", ctx.client.organisation}
          ] do
        assert Access.authorize(scope, action, on) == {:error, :forbidden}, "#{action}"
      end
    end
  end

  describe "what is the client's own to decide" do
    @own_to_decide [
      :"organisation.leave_operator",
      :"organisation.transfer",
      :"organisation.withdraw_transfer",
      :"organisation.delete"
    ]

    test "is refused to anyone who reaches it through the operator", ctx do
      %{user: user} = member_fixture(ctx.operator.scope, :owner)
      Flags.put_operator_infrastructure(false)
      join_fixture(ctx.client.owner.scope, user)
      Flags.put_operator_infrastructure(true)
      in_both = scope_in(user, ctx.client.organisation, ctx.client.workspace)

      for scope <- [ctx.as_owner, ctx.as_admin, ctx.as_member, in_both],
          action <- @own_to_decide do
        assert Access.authorize(scope, action, ctx.client.organisation) == {:error, :forbidden},
               "#{action}"
      end

      # With the flag off, the operator's owner reads, and is refused all the same.
      Flags.put_operator_infrastructure(false)

      assert Access.authorize(ctx.as_owner, :"organisation.delete", ctx.client.organisation) ==
               {:error, :forbidden}
    end

    test "stays the client's owners', an admin of the operator among them", ctx do
      user = ctx.operator_admin.user
      Flags.put_operator_infrastructure(false)
      %{membership: joined} = join_fixture(ctx.client.owner.scope, user)
      {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, joined.id, :owner)
      Flags.put_operator_infrastructure(true)
      in_both = scope_in(user, ctx.client.organisation, ctx.client.workspace)

      for scope <- [ctx.client.owner.scope, in_both], action <- @own_to_decide do
        assert Access.authorize(scope, action, ctx.client.organisation) == :ok, "#{action}"
      end
    end

    test "is answered at the client's level on a tie, and refused where the operator's is higher",
         ctx do
      # An admin of both acts at their level in the client: the tie is not through the
      # operator.
      admin_of_both = ctx.operator_admin.user
      # An owner of the operator who is an admin of the client acts through the operator,
      # whose level is higher.
      %{user: owner_and_admin} = member_fixture(ctx.operator.scope, :owner)
      # A member of the operator who is an admin of the client acts at the client's level.
      member_and_admin = ctx.operator_member.user

      Flags.put_operator_infrastructure(false)

      for user <- [admin_of_both, owner_and_admin, member_and_admin] do
        %{membership: joined} = join_fixture(ctx.client.owner.scope, user)
        {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, joined.id, :admin)
      end

      Flags.put_operator_infrastructure(true)
      in_client = &scope_in(&1, ctx.client.organisation, ctx.client.workspace)
      organisation = ctx.client.organisation

      # Policy requests are not there, for anyone.
      for user <- [admin_of_both, member_and_admin, owner_and_admin],
          action <- [:"policy_request.accept", :"policy_request.decline"] do
        assert Access.authorize(in_client.(user), action, organisation) == {:error, :not_found},
               "#{action}"
      end

      for action <- @own_to_decide do
        assert Access.authorize(in_client.(owner_and_admin), action, organisation) ==
                 {:error, :forbidden},
               "#{action}"
      end

      # The admin of both is no owner of the client: what only an owner decides stays out
      # of their reach, at their level in the client.
      assert Access.authorize(in_client.(admin_of_both), :"organisation.delete", organisation) ==
               {:error, :forbidden}
    end

    test "a deletion is cancelled by the operator's owners", ctx do
      marked = %{ctx.client.organisation | deletion_marked_at: DateTime.utc_now()}
      scope = %{ctx.as_owner | organisation: marked}
      assert Access.can?(scope, :"organisation.restore", marked)
      refute Access.can?(%{ctx.as_member | organisation: marked}, :"organisation.restore", marked)
    end
  end

  describe "a client's first person" do
    test "is invited as its first admin, who joins as one, and the other invitations go",
         ctx do
      email = Apiary.AccountsFixtures.unique_user_email()

      {%{organisation: client}, token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => email})

      assert [%{action: "client.invite_admin"}] =
               entries(client) |> Enum.filter(&(&1.action =~ "client.invite"))

      {:ok, second} =
        Operators.invite_admin(
          ctx.operator.scope,
          client.id,
          %{"email" => Apiary.AccountsFixtures.unique_user_email()},
          &"http://localhost/invitations/#{&1}"
        )

      {:ok, rows} = Operators.list_clients(ctx.operator.scope)
      row = Enum.find(rows, &(&1.organisation.id == client.id))
      assert row.owners == [] and row.admins == []
      assert length(row.owner_invitations) == 2

      first = sign_up_fixture(%{email: email, invitation_token: token})
      assert first.membership.level == :admin

      revoked = Enum.find(entries(client), &(&1.action == "invitation.revoke"))
      assert revoked.subject_id == second.id
      assert revoked.details == %{"reason" => "admin_joined"}

      {:ok, rows} = Operators.list_clients(ctx.operator.scope)
      row = Enum.find(rows, &(&1.organisation.id == client.id))
      assert Enum.map(row.admins, & &1.id) == [first.user.id]
      assert row.owner_invitations == []

      # The client has an admin now, who invites its people.
      assert Operators.invite_admin(
               ctx.operator.scope,
               client.id,
               %{"email" => Apiary.AccountsFixtures.unique_user_email()},
               &"http://localhost/invitations/#{&1}"
             ) == {:error, :has_admin}
    end

    test "a pending invitation of a first owner makes an admin once the flag is on", ctx do
      Flags.put_operator_infrastructure(false)
      email = Apiary.AccountsFixtures.unique_user_email()

      {%{organisation: _client}, token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => email})

      Flags.put_operator_infrastructure(true)
      assert sign_up_fixture(%{email: email, invitation_token: token}).membership.level == :admin
    end

    test "is refused while the client has a legacy owner", ctx do
      {:ok, rows} = Operators.list_clients(ctx.operator.scope)
      assert Enum.find(rows, &(&1.organisation.id == ctx.client.organisation.id)).admins != []

      assert Operators.invite_admin(
               ctx.operator.scope,
               ctx.client.organisation.id,
               %{"email" => Apiary.AccountsFixtures.unique_user_email()},
               &"http://localhost/invitations/#{&1}"
             ) == {:error, :has_admin}
    end

    test "its invitation is revoked and renewed by the operator's owners and admins", ctx do
      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Acme",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      [invitation] = pending(ctx, client)
      Apiary.Mail.put_test_source(:none)

      assert {:ok, _, {:link, _}} =
               Operators.renew_admin_invitation(
                 ctx.operator_admin.scope,
                 client.id,
                 invitation.id,
                 &"http://localhost/invitations/#{&1}"
               )

      assert Operators.revoke_admin_invitation(
               ctx.operator_member.scope,
               client.id,
               invitation.id
             ) == {:error, :forbidden}

      assert {:ok, _} =
               Operators.revoke_admin_invitation(ctx.operator.scope, client.id, invitation.id)

      actions = Enum.map(entries(client), & &1.action)
      assert "client.renew_admin_invitation" in actions
      assert "client.revoke_admin_invitation" in actions
    end

    test "the first owner's actions are not found while the flag is on, and the first admin's while it is off",
         ctx do
      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Acme",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      [invitation] = pending(ctx, client)
      url = &"http://localhost/invitations/#{&1}"
      attrs = %{"email" => Apiary.AccountsFixtures.unique_user_email()}

      assert Operators.invite_owner(ctx.operator.scope, client.id, attrs, url) ==
               {:error, :not_found}

      assert Operators.revoke_owner_invitation(ctx.operator.scope, client.id, invitation.id) ==
               {:error, :not_found}

      assert Operators.renew_owner_invitation(ctx.operator.scope, client.id, invitation.id, url) ==
               {:error, :not_found}

      Flags.put_operator_infrastructure(false)

      assert Operators.invite_admin(ctx.operator.scope, client.id, attrs, url) ==
               {:error, :not_found}

      assert Operators.revoke_admin_invitation(ctx.operator.scope, client.id, invitation.id) ==
               {:error, :not_found}

      assert Operators.renew_admin_invitation(ctx.operator.scope, client.id, invitation.id, url) ==
               {:error, :not_found}
    end
  end

  describe "a client's admins" do
    test "invite, remove admins and members, and never act on an owner", ctx do
      admin = ctx.client_admin.scope
      other = client_member_fixture(ctx.client, :admin)

      assert Access.authorize(admin, :"member.invite", ctx.invitation) == :ok
      assert Access.authorize(admin, :"member.remove", ctx.client_member.membership) == :ok
      assert {:ok, _} = Organisations.remove_member(admin, other.membership.id)

      assert Organisations.remove_member(admin, ctx.client.owner.membership.id) ==
               {:error, :forbidden}

      assert Access.authorize(admin, :"member.change_level", ctx.client.owner.membership) ==
               {:error, :forbidden}

      # With the flag off, an admin acts on members only.
      Flags.put_operator_infrastructure(false)
      other = client_member_fixture(ctx.client, :admin)

      assert Access.authorize(admin, :"member.remove", other.membership) ==
               {:error, :forbidden}
    end

    test "change levels between admin and member, never to owner", ctx do
      admin = ctx.client_admin.scope
      member = ctx.client_member.membership

      assert {:ok, %{level: :admin}} = Organisations.set_member_level(admin, member.id, :admin)
      assert {:ok, %{level: :member}} = Organisations.set_member_level(admin, member.id, :member)

      # Nobody makes an owner in a client: the level is refused before it is written.
      before = length(entries(ctx.client.organisation))

      for scope <- [admin, ctx.as_owner, ctx.client.owner.scope] do
        assert Organisations.set_member_level(scope, member.id, :owner) ==
                 {:error, {:level_refused, :operator_owns}}
      end

      assert Apiary.Repo.reload!(member).level == :member
      assert length(entries(ctx.client.organisation)) == before

      # With the flag off, the client's owner makes owners, as anywhere.
      Flags.put_operator_infrastructure(false)

      assert {:ok, %{level: :owner}} =
               Organisations.set_member_level(ctx.client.owner.scope, member.id, :owner)
    end

    test "an owner of the operator keeps every power over the client's people", ctx do
      owner = ctx.as_owner
      admin = ctx.client_admin.membership

      assert {:ok, %{level: :member}} = Organisations.set_member_level(owner, admin.id, :member)
      assert {:ok, _} = Organisations.suspend_member(owner, admin.id)
      assert {:ok, _} = Organisations.remove_member(owner, admin.id)
    end

    test "the refusal of an owner is a client's alone: the operator makes its own", ctx do
      %{membership: member} = member_fixture(ctx.operator.scope, :member)

      assert {:ok, %{level: :owner}} =
               Organisations.set_member_level(ctx.operator.scope, member.id, :owner)
    end
  end

  describe "a client nobody has joined" do
    test "is deleted while only invitations are pending, its entry saying so", ctx do
      {%{organisation: client}, _token} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Acme",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      assert {:ok, _} = ApiaryPro.Deletion.delete_client(ctx.operator.scope, client.id, "Acme")

      entry = Enum.find(entries(ctx.operator.organisation), &(&1.action == "client.delete"))
      assert entry.details["guard"] == "no_people"
      assert entry.details["organisation_id"] == client.id
    end

    test "is not deleted once anyone has joined, a legacy owner or a first admin", ctx do
      email = Apiary.AccountsFixtures.unique_user_email()

      {%{organisation: client}, token} =
        create_client_fixture(ctx.operator.scope, %{"name" => "Acme", "email" => email})

      sign_up_fixture(%{email: email, invitation_token: token})

      assert ApiaryPro.Deletion.delete_client(ctx.operator.scope, client.id, "Acme") ==
               {:error, :has_people}

      legacy = ctx.client.organisation

      assert ApiaryPro.Deletion.delete_client(ctx.operator.scope, legacy.id, legacy.name) ==
               {:error, :has_people}

      # With the flag off, an admin of its own is no owner, and the client is deleted.
      Flags.put_operator_infrastructure(false)

      assert {:ok, _} = ApiaryPro.Deletion.delete_client(ctx.operator.scope, client.id, "Acme")

      entry = Enum.find(entries(ctx.operator.organisation), &(&1.action == "client.delete"))
      refute Map.has_key?(entry.details, "guard")
    end
  end

  describe "a client's workspaces" do
    test "are made by the client's owners and admins and the operator's owners, and deleted and brought back by the operator's owners and admins",
         ctx do
      organisation = ctx.client.organisation

      for {as, create, delete} <- [
            {ctx.as_owner, :ok, :ok},
            {ctx.as_admin, {:error, :forbidden}, :ok},
            {ctx.as_member, {:error, :forbidden}, {:error, :forbidden}},
            {ctx.client.owner.scope, :ok, {:error, :forbidden}},
            {ctx.client_admin.scope, :ok, {:error, :forbidden}}
          ] do
        assert Access.authorize(as, :"workspace.create", organisation) == create
        assert Access.authorize(as, :"workspace.delete", organisation) == delete
        assert Access.authorize(as, :"workspace.restore", organisation) == delete

        assert Access.authorize(as, :"workspace.rename", ctx.client.workspace) !=
                 {:error, :not_found}
      end

      # Renaming is as before: the client's owner and admins rename.
      assert Access.authorize(ctx.client_admin.scope, :"workspace.rename", ctx.client.workspace) ==
               :ok

      # In the operator itself, and with the flag off, nothing changes.
      assert Access.authorize(ctx.operator.scope, :"workspace.create", ctx.operator.organisation) ==
               :ok

      Flags.put_operator_infrastructure(false)
      assert Access.authorize(ctx.client.owner.scope, :"workspace.create", organisation) == :ok
      assert Access.authorize(ctx.client_admin.scope, :"workspace.delete", organisation) == :ok
    end
  end

  describe "a client's admin creating a workspace" do
    test "is allowed with the flag on and off", ctx do
      organisation = ctx.client.organisation

      for on? <- [true, false] do
        Flags.put_operator_infrastructure(on?)
        assert Access.authorize(ctx.client_admin.scope, :"workspace.create", organisation) == :ok
      end

      # A member of the client never may.
      assert Access.authorize(ctx.client_member.scope, :"workspace.create", organisation) ==
               {:error, :forbidden}
    end

    test "is allowed to a person who owns the operator and is an admin of the client, with the flag on and off",
         ctx do
      organisation = ctx.client.organisation
      person = member_fixture(ctx.operator.scope, :owner)
      %{membership: membership} = join_fixture(ctx.client.owner.scope, person.user)
      {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, membership.id, :admin)
      scope = scope_in(person.user, organisation, ctx.client.workspace)

      # With the flag on they act through the operator, as its owner; with it off the
      # operator gives them nothing to change, and they act as the client's admin.
      for on? <- [true, false] do
        Flags.put_operator_infrastructure(on?)
        assert Access.authorize(scope, :"workspace.create", organisation) == :ok
      end
    end

    test "is refused to the operator's owner without a membership in the client, with the flag off",
         ctx do
      Flags.put_operator_infrastructure(false)

      for as <- [ctx.as_owner, ctx.as_admin, ctx.as_member] do
        assert Access.authorize(as, :"workspace.create", ctx.client.organisation) ==
                 {:error, :forbidden}
      end
    end
  end

  describe "what the operator sets in a client" do
    # Each action with what it is asked of.
    @operator_held [
      {:"node.create", :workspace},
      {:"node.edit", :workspace},
      {:"node.set_limit", :workspace},
      {:"node.delete", :workspace},
      {:"node.clear_instance", :workspace},
      {:"access_key.create_code", :workspace},
      {:"access_key.cancel_code", :workspace},
      {:"access_key.add", :workspace},
      {:"access_key.revoke", :workspace},
      {:"provider.write", :organisation},
      {:"runtime.write", :organisation},
      {:"model_choice.write", :workspace},
      {:"time_limit.edit", :workspace},
      {:"retention.edit", :workspace},
      {:"harness.save", :organisation}
    ]

    test "is held by the operator's owners and admins, and not there for anyone else",
         ctx do
      for as <- [ctx.as_owner, ctx.as_admin], {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == :ok, "#{action}"
      end

      for as <- [
            ctx.as_member,
            ctx.client.owner.scope,
            ctx.client_admin.scope,
            ctx.client_member.scope
          ],
          {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == {:error, :not_found}, "#{action}"
      end
    end

    test "is the client's with the flag off, and the operator's people read", ctx do
      Flags.put_operator_infrastructure(false)

      for as <- [ctx.client.owner.scope, ctx.client_admin.scope],
          {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == :ok, "#{action}"
      end

      for as <- [ctx.as_owner, ctx.as_admin], {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == {:error, :forbidden}, "#{action}"
      end
    end

    test "leaves reading, and the client's policy, variables, secrets and work, with it",
         ctx do
      workspace = ctx.client.workspace

      for as <- [ctx.as_member, ctx.client.owner.scope, ctx.client_member.scope],
          do: assert(Access.authorize(as, :"node.read", workspace) == :ok)

      for as <- [ctx.client.owner.scope, ctx.client_admin.scope],
          {action, on} <- [
            {:"connection.write", :organisation},
            {:"security_policy.edit", :workspace},
            {:"variable.edit", :workspace},
            {:"secret.write", :workspace},
            {:"organisation_variable.edit", :organisation},
            {:"collection.assign", :workspace},
            {:"target.set_further_repositories", :workspace}
          ] do
        assert Access.authorize(as, action, on(ctx, on)) == :ok, "#{action}"
      end
    end

    test "is the operator's in the operator itself, as before", ctx do
      assert Access.authorize(ctx.operator.scope, :"node.create", ctx.operator.workspace) == :ok
    end
  end

  defp on(ctx, :workspace), do: ctx.client.workspace
  defp on(ctx, :organisation), do: ctx.client.organisation
  defp on(ctx, :invitation), do: ctx.invitation
  defp on(ctx, :client_member), do: ctx.client_member.membership

  defp entries(organisation) do
    Apiary.Repo.all(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp pending(ctx, client) do
    {:ok, rows} = Operators.list_clients(ctx.operator.scope)
    Enum.find(rows, &(&1.organisation.id == client.id)).owner_invitations
  end
end
