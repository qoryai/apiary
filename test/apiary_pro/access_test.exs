defmodule ApiaryPro.AccessTest do
  # Most of the edition's rules of `Apiary.Access`; docs/access.md lists the rules other
  # files test. `Apiary.AccessCase` checks that every action has a row. Not async: the
  # features are set for the whole node.
  use Apiary.AccessCase, rows: [ApiaryPro.CoreAccessRows, ApiaryPro.AccessRows]

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures, only: [adapter_fixture: 0]
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.Tenants
  alias ApiaryPro.Tenants.Tenant

  test "the reader's reads are only reads" do
    assert Enum.all?(ApiaryPro.Access.reads(), &(not Apiary.Audit.audited?(&1)))
    assert Enum.all?(Access.roles().reader, &(&1 in ApiaryPro.Access.reads()))
  end

  test "hidden?/1 is what a flag hides now, and check/3 returns not found for it" do
    alias ApiaryPro.Flags

    hides = fn on, off ->
      for action <- on do
        assert ApiaryPro.Access.hidden?(action), "#{action}"
        assert ApiaryPro.Access.check(nil, action, nil) == {:error, :not_found}, "#{action}"
      end

      for action <- off, do: refute(ApiaryPro.Access.hidden?(action), "#{action}")
    end

    transfers = [
      :"organisation.transfer",
      :"organisation.withdraw_transfer",
      :"organisation.leave_operator",
      :"client.accept"
    ]

    while_on = [:"client.drop", :"client.invite_owner", :"policy_request.send"]
    while_off = [:"client.invite_admin", :"client.set_model_chain"]

    Flags.put_transfers(false)
    hides.(transfers, [:"organisation.rename"])

    Flags.put_transfers(true)
    hides.([], transfers)

    Flags.put_operator_infrastructure(true)
    hides.(while_on, while_off)

    Flags.put_operator_infrastructure(false)
    hides.(while_off, while_on)
  end

  describe "an operator's reach" do
    test "its people read in the organisations it operates, and reach no other" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      other = sign_up_fixture()

      for user <- [
            operator.user,
            member_fixture(operator.scope, :admin).user,
            member_fixture(operator.scope, :member).user
          ] do
        in_client = scope_in(user, client.organisation, client.workspace)
        assert Access.reach(in_client) == :operator
        assert Access.reader(in_client) == :operator
        assert Access.level(in_client) == nil
        assert Access.authorize(in_client, :"run.read", client.workspace) == :ok

        assert scope_in(user, other.organisation, other.workspace) == nil
      end

      assert Access.authorize(operator.scope, :"run.read", other.workspace) ==
               {:error, :not_found}
    end
  end

  describe "an instance admin's reach" do
    test "they read an organisation they have no membership in; anyone else reaches none" do
      %{user: admin} = instance_admin_fixture()
      other = sign_up_fixture()

      scope = scope_in(admin, other.organisation, other.workspace)
      assert Access.reach(scope) == :instance
      assert Access.reader(scope) == :instance
      assert Access.level(scope) == nil
      assert Access.authorize(scope, :"run.read", other.workspace) == :ok
      assert Access.authorize(scope, :"audit.read", other.organisation) == :ok

      %{user: nobody} = sign_up_fixture()
      assert scope_in(nobody, other.organisation, other.workspace) == nil

      # The reach is read again: a scope loaded before the grant was revoked reads nothing.
      {:ok, _} = Apiary.Organisations.revoke_instance_admin(admin)
      assert Access.authorize(scope, :"run.read", other.workspace) == {:error, :forbidden}
    end
  end

  describe "an operated client's owner" do
    test "acts there as an owner anywhere, and leaves the operator; the operator's people do not" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      owner = client.owner.scope

      assert Access.reach(owner) == :membership
      assert Access.level(owner) == :owner
      assert Access.reader(owner) == nil

      for {action, subject} <- [
            {:"node.create", client.workspace},
            {:"organisation.rename", client.organisation},
            {:"organisation.leave_operator", client.organisation}
          ] do
        assert Access.authorize(owner, action, subject) == :ok, "#{action}"
        assert Access.authorize(client.scope, action, subject) == {:error, :forbidden}
      end

      # An operator's actions over its clients are not there in a client.
      assert Access.authorize(owner, :"client.create", client.organisation) ==
               {:error, :not_found}
    end
  end

  describe "marked for deletion" do
    # A scope loaded before the marking, asked after it: the edition's actions are not found, as
    # for an organisation or a workspace that is gone (`Apiary.Access.check_place/3`).
    setup do
      signed_up = sign_up_fixture()
      staging = workspace_fixture(signed_up.organisation, "Staging")

      %{
        owner: signed_up.scope,
        organisation: signed_up.organisation,
        workspace: staging,
        there: workspace_scope(signed_up.user, staging),
        admin: workspace_scope(member_fixture(signed_up.scope, :admin).user, staging)
      }
    end

    test "a marked organisation: the edition's actions in it are not found", ctx do
      asked = [
        {ctx.there, :"organisation_policy.edit"},
        {ctx.admin, :"organisation_variable.edit"},
        {ctx.admin, :"workspace_access.add"}
      ]

      for {scope, action} <- asked do
        assert Access.authorize(scope, action, ctx.organisation) == :ok, "#{action}"
      end

      {:ok, _} = Apiary.Deletion.delete_organisation(ctx.owner, ctx.organisation.slug)

      for {scope, action} <- asked do
        assert Access.authorize(scope, action, ctx.organisation) == {:error, :not_found},
               "#{action}"
      end
    end

    test "a marked workspace: the edition's actions asked from it are not found, from another allowed",
         ctx do
      assert Access.authorize(ctx.there, :"organisation_policy.edit", ctx.organisation) == :ok

      {:ok, _} =
        Apiary.Deletion.delete_workspace(ctx.owner, ctx.workspace.id, ctx.workspace.slug)

      assert Access.authorize(ctx.there, :"organisation_policy.edit", ctx.organisation) ==
               {:error, :not_found}

      assert Access.authorize(ctx.admin, :"organisation_variable.edit", ctx.organisation) ==
               {:error, :not_found}

      # From the organisation's other workspace, which is not marked.
      assert Access.authorize(ctx.owner, :"organisation_policy.edit", ctx.organisation) == :ok
    end
  end

  describe "suspended" do
    # An access key of a suspended organisation is refused at its verification, on every
    # request, so no test here uses one.
    setup do
      signed_up = sign_up_fixture()
      owner = signed_up.scope
      staging = workspace_fixture(signed_up.organisation, "Staging")
      there = workspace_scope(signed_up.user, staging)
      member = member_fixture(there, :member)
      admin = member_fixture(there, :admin)

      %{
        owner: owner,
        organisation: signed_up.organisation,
        workspace: staging,
        instance_admin: instance_admin_fixture().instance_scope,
        member: member,
        scopes: %{
          member: member.scope,
          admin: workspace_scope(admin.user, staging),
          owner: there,
          instance: Scope.for_instance(signed_up.organisation, staging)
        }
      }
    end

    test "a suspended organisation is read-only for every level; the instance's jobs go on",
         ctx do
      open!([:organisation])
      %{scopes: scopes, workspace: workspace, organisation: organisation} = ctx

      # Two changes of the core's and two of the edition's, each allowed before the suspension.
      changes = [
        {:member, :"security_policy.edit", workspace},
        {:admin, :"organisation_variable.edit", organisation},
        {:owner, :"node.create", workspace},
        {:owner, :"organisation_policy.edit", organisation}
      ]

      # The reads, creating an organisation, which is asked of no organisation, and the
      # instance's jobs.
      unchanged =
        for(level <- [:member, :admin, :owner], do: {level, :"run.read", workspace}) ++
          [
            {:owner, :"audit.read", organisation},
            {:owner, :"organisation.create", Tenants.new(:organisation)},
            {:instance, :"audit.prune", organisation},
            {:instance, :"invitation.revoke", organisation}
          ]

      for {actor, action, subject} <- changes ++ unchanged do
        assert Access.authorize(scopes[actor], action, subject) == :ok, "#{actor} #{action}"
      end

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(ctx.instance_admin, organisation.id)

      for {actor, action, subject} <- changes do
        assert Access.authorize(scopes[actor], action, subject) == {:error, :forbidden},
               "#{actor} #{action}"
      end

      for {actor, action, subject} <- unchanged do
        assert Access.authorize(scopes[actor], action, subject) == :ok, "#{actor} #{action}"
      end
    end

    test "can?/3 answers from the scope as loaded; reload/2 sees the suspension", ctx do
      stale = ctx.scopes.owner
      refute ApiaryPro.Access.suspended?(stale)

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(ctx.instance_admin, ctx.organisation.id)

      assert Access.can?(stale, :"node.create", stale.workspace)

      fresh = Access.reload(stale)
      assert ApiaryPro.Access.suspended?(fresh)
      refute Access.can?(fresh, :"node.create", fresh.workspace)
      assert Access.can?(fresh, :"run.read", fresh.workspace)
      assert Access.check(fresh, :"workspace.rename", fresh.workspace) == {:error, :forbidden}

      # Activated, it is what it was.
      {:ok, _} =
        ApiaryPro.Suspensions.activate_organisation(ctx.instance_admin, ctx.organisation.id)

      assert Access.authorize(stale, :"node.create", stale.workspace) == :ok
      refute ApiaryPro.Access.suspended?(Access.reload(stale))
    end

    test "a suspended account answers as no membership, in every organisation", ctx do
      scope = ctx.scopes.member
      elsewhere = sign_up_fixture()
      %{scope: other_scope} = join_fixture(elsewhere.scope, ctx.member.user)

      {:ok, _} = ApiaryPro.Suspensions.suspend_account(ctx.instance_admin, ctx.member.user.id)

      for scope <- [scope, other_scope] do
        assert Access.reload(scope).membership == nil

        assert Access.authorize(scope, :"security_policy.edit", scope.workspace) ==
                 {:error, :forbidden}

        assert Access.authorize(scope, :"run.read", scope.workspace) == {:error, :forbidden}
      end

      {:ok, _} = ApiaryPro.Suspensions.activate_account(ctx.instance_admin, ctx.member.user.id)
      assert Access.authorize(scope, :"security_policy.edit", scope.workspace) == :ok
      assert Access.authorize(other_scope, :"security_policy.edit", other_scope.workspace) == :ok
    end

    test "a suspended operator's people read its client no more; the client's owner still acts",
         ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      assert Access.authorize(client.scope, :"run.read", client.workspace) == :ok

      {:ok, _} =
        ApiaryPro.Suspensions.suspend_organisation(ctx.instance_admin, operator.organisation.id)

      assert Access.authorize(client.scope, :"run.read", client.workspace) == {:error, :forbidden}
      assert Access.reload(client.scope).reach == nil

      for action <- [:"node.create", :"run.read"] do
        assert Access.authorize(client.owner.scope, action, client.workspace) == :ok
      end

      # The operator itself is read-only for its own people.
      assert Access.authorize(operator.scope, :"run.read", operator.scope.workspace) == :ok

      assert Access.authorize(operator.scope, :"node.create", operator.scope.workspace) ==
               {:error, :forbidden}

      {:ok, _} =
        ApiaryPro.Suspensions.activate_organisation(ctx.instance_admin, operator.organisation.id)

      assert Access.authorize(client.scope, :"run.read", client.workspace) == :ok
    end
  end

  describe "an operator's people in a client" do
    # An operator's people read everything in its clients, at every level they hold in the
    # operator, and change nothing there: the client owns its people and its policy.
    setup do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      operator_admin = member_fixture(operator.scope, :admin).user
      operator_member = member_fixture(operator.scope, :member).user

      %{
        client: client,
        client_admin: client_member_fixture(client, :admin),
        client_member: client_member_fixture(client, :member),
        invitation: invitation_fixture(client.owner.scope).invitation,
        as_owner: client.scope,
        as_admin: scope_in(operator_admin, client.organisation, client.workspace),
        as_member: scope_in(operator_member, client.organisation, client.workspace),
        operator_admin: operator_admin,
        operator_member: operator_member,
        operator: operator
      }
    end

    @reads_in_client [
      {:"run.read", :workspace},
      {:"run.read_log", :workspace},
      {:"security_policy.read", :workspace},
      {:"audit.read", :organisation},
      {:"node.read", :workspace},
      {:"connection.read", :organisation}
    ]

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
      {:"provider.write", :organisation},
      {:"runtime.write", :organisation},
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

    test "at every level, they read everything and change nothing", ctx do
      for as <- [:as_owner, :as_admin, :as_member] do
        scope = ctx[as]
        assert Access.level(scope) == nil
        assert Access.reader(scope) == :operator

        for {action, on} <- @reads_in_client do
          assert Access.authorize(scope, action, on(ctx, on)) == :ok, "#{as} #{action}"
        end

        for {action, on} <- @changes_in_client do
          refute Access.can?(scope, action, on(ctx, on)), "#{as} #{action}"

          assert Access.authorize(scope, action, on(ctx, on)) == {:error, :forbidden},
                 "#{as} #{action}"
        end
      end
    end

    test "the client's owner and admin manage their own people", ctx do
      owner = ctx.client.owner.scope
      admin = ctx.client_admin.scope

      for scope <- [owner, admin],
          action <- [:"member.remove", :"member.suspend", :"workspace_access.add"] do
        assert Access.authorize(scope, action, ctx.client_member.membership) == :ok
      end

      assert Access.authorize(admin, :"member.invite", ctx.invitation) == :ok
      assert Access.authorize(owner, :"member.change_level", ctx.client_admin.membership) == :ok
      assert Access.authorize(owner, :"security_policy.lock", ctx.client.workspace) == :ok

      assert Access.authorize(owner, :"organisation.leave_operator", ctx.client.organisation) ==
               :ok

      assert Access.authorize(admin, :"organisation.leave_operator", ctx.client.organisation) ==
               {:error, :forbidden}
    end

    test "with a membership in the client too, it decides what they change, and the operator's reach adds every workspace",
         ctx do
      platform = workspace_fixture(ctx.client.organisation, "Platform")

      # A member of the operator who is a member of the client, added to Main only.
      %{membership: joined} = join_fixture(ctx.client.owner.scope, ctx.operator_member)
      in_main = scope_in(ctx.operator_member, ctx.client.organisation, ctx.client.workspace)
      in_platform = scope_in(ctx.operator_member, ctx.client.organisation, platform)

      assert Access.reach(in_main) == :operator
      assert Access.level(in_main) == :member
      assert Access.reader(in_main) == nil

      assert Access.authorize(in_main, :"security_policy.edit", ctx.client.workspace) == :ok
      assert Access.authorize(in_platform, :"run.read", platform) == :ok

      assert Access.authorize(in_platform, :"security_policy.edit", platform) ==
               {:error, :forbidden}

      assert Access.authorize(in_main, :"member.remove", ctx.client_member.membership) ==
               {:error, :forbidden}

      assert Access.authorize(in_main, :"audit.read", ctx.client.organisation) == :ok

      # Made an admin of the client, they reach every workspace and act on its members.
      {:ok, _} = Apiary.Organisations.set_member_level(ctx.client.owner.scope, joined.id, :admin)
      in_platform = scope_in(ctx.operator_member, ctx.client.organisation, platform)
      assert Access.authorize(in_platform, :"security_policy.edit", platform) == :ok

      assert Access.authorize(in_platform, :"member.remove", ctx.client_member.membership) ==
               :ok
    end

    defp on(ctx, :workspace), do: ctx.client.workspace
    defp on(ctx, :organisation), do: ctx.client.organisation
    defp on(ctx, :invitation), do: ctx.invitation
    defp on(ctx, :client_member), do: ctx.client_member.membership
  end

  describe "an operator's actions over its clients" do
    setup do
      operator = operator_fixture()

      %{
        operator: operator,
        admin: member_fixture(operator.scope, :admin).scope,
        member: member_fixture(operator.scope, :member).scope
      }
    end

    test "its owners and admins create clients and invite, renew and revoke their first owners' invitations; its owners drop and delete them",
         ctx do
      operator = ctx.operator.organisation

      for action <- [:"client.delete"] do
        assert Access.authorize(ctx.operator.scope, action, operator) == :ok
        assert Access.authorize(ctx.admin, action, operator) == {:error, :forbidden}
        assert Access.authorize(ctx.member, action, operator) == {:error, :forbidden}
      end

      for action <- [
            :"client.create",
            :"client.invite_owner",
            :"client.renew_owner_invitation",
            :"client.revoke_owner_invitation"
          ] do
        assert Access.authorize(ctx.operator.scope, action, operator) == :ok
        assert Access.authorize(ctx.admin, action, operator) == :ok
        assert Access.authorize(ctx.member, action, operator) == {:error, :forbidden}
      end

      assert Access.authorize(ctx.operator.scope, :"client.drop", operator) == :ok
      assert Access.authorize(ctx.admin, :"client.drop", operator) == {:error, :forbidden}
      assert Access.authorize(ctx.member, :"client.drop", operator) == {:error, :forbidden}
      assert Access.authorize(ctx.member, :"client.read", operator) == :ok
    end

    test "its owners and admins send and withdraw policy requests, its members do not", ctx do
      operator = ctx.operator.organisation

      for action <- [:"policy_request.send", :"policy_request.withdraw"] do
        assert Access.authorize(ctx.operator.scope, action, operator) == :ok
        assert Access.authorize(ctx.admin, action, operator) == :ok
        assert Access.authorize(ctx.member, action, operator) == {:error, :forbidden}
      end
    end
  end

  # The instance actions never taken on the instance organisation itself.
  @not_on_itself [
    :"instance.purge_organisation",
    :"instance.suspend_organisation",
    :"instance.activate_organisation",
    :"instance.transfer",
    :"instance.grant_features"
  ]

  # Asked in the instance organisation, of it: a change of its kind, and nothing else.
  defp only_its_kind_changes!(scope) do
    here = scope.organisation
    kind = Tenants.kind(here)
    assert Tenants.instance_organisation?(here)
    assert Access.authorize(scope, :"instance.change_kind", here) == :ok, "#{kind}"
    assert Access.can?(scope, :"instance.change_kind", here)

    for action <- @not_on_itself do
      assert Access.authorize(scope, action, here) == {:error, :forbidden}, "#{action} #{kind}"
      refute Access.can?(scope, action, here)
    end
  end

  describe "the instance actions on the instance organisation itself" do
    test "of either kind, its kind is changed as any other's, and nothing else is taken on it" do
      admin = instance_admin_fixture()
      operator = make_instance_organisation_an_operator(admin)
      only_its_kind_changes!(operator)

      {:ok, _} =
        ApiaryPro.Operators.change_kind(operator, operator.organisation.id, :organisation)

      only_its_kind_changes!(scope_in(admin.user, instance_organisation()))
    end
  end

  describe "the instance step" do
    setup do
      admin = instance_admin_fixture()
      %{admin: admin, instance: admin.instance_scope, other: sign_up_fixture()}
    end

    test "the core's instance action reaches the core's place and role steps", ctx do
      assert Access.authorize(ctx.instance, :"account.password_link", ctx.other.user) == :ok

      by_itself = Scope.for_instance(ctx.other.organisation, ctx.other.scope.workspace)
      assert Access.authorize(by_itself, :"account.password_link", ctx.other.user) == :ok
    end

    test "the edition's instance action is not found for an instance admin in another organisation",
         ctx do
      assert Access.authorize(
               ctx.admin.scope,
               :"instance.create_organisation",
               ctx.admin.scope.organisation
             ) ==
               {:error, :not_found}
    end

    test "the edition's instance action is forbidden to an admin of the instance organisation",
         ctx do
      %{scope: admin} = member_fixture(ctx.instance, :admin)

      assert Access.authorize(admin, :"instance.create_organisation", admin.organisation) ==
               {:error, :forbidden}
    end

    test "the edition's instance action is not found in a scope whose workspace is marked", ctx do
      staging = workspace_fixture(ctx.instance.organisation, "Staging")
      there = workspace_scope(ctx.admin.user, staging)
      subject = ctx.instance.organisation

      assert Access.authorize(there, :"instance.create_organisation", subject) == :ok

      {:ok, _} = Apiary.Deletion.delete_workspace(ctx.instance, staging.id, staging.slug)

      assert Access.authorize(there, :"instance.create_organisation", subject) ==
               {:error, :not_found}
    end

    test "the edition's instance action is forbidden to an adapter's key narrowed to the instance organisation",
         ctx do
      %{access_key: key} = enrolled_key_fixture(instance_admin_scope(), adapter_fixture())
      organisation = ctx.instance.organisation

      narrowed =
        Scope.for_connection(
          Scope.for_access_key(key),
          %Apiary.Adapters.Connection{adapter_id: key.node_id, organisation: organisation}
        )

      assert Access.authorize(narrowed, :"instance.create_organisation", organisation) ==
               {:error, :forbidden}
    end

    test "instance.read of a workspace of the instance organisation is not found", ctx do
      staging = workspace_fixture(ctx.instance.organisation, "Staging")

      assert Access.authorize(ctx.instance, :"instance.read", staging) == {:error, :not_found}
    end

    test "the edition's instance action is not found for the instance's scope in another organisation",
         ctx do
      by_itself = Scope.for_instance(ctx.other.organisation, ctx.other.scope.workspace)

      assert Access.authorize(by_itself, :"instance.create_organisation", ctx.other.organisation) ==
               {:error, :not_found}
    end
  end

  describe "a client's policy requests" do
    # Whoever writes the client's policy answers its operator's requests, at every level;
    # the operator's people read them there and answer none.
    @describetag needs: :managed_organisations

    setup do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      %{
        client: client,
        admin: client_member_fixture(client, :admin).scope,
        member: client_member_fixture(client, :member).scope,
        operator_admin:
          scope_in(
            member_fixture(operator.scope, :admin).user,
            client.organisation,
            client.workspace
          )
      }
    end

    test "every level of the client answers; the operator's people do not", ctx do
      organisation = ctx.client.organisation

      for action <- [:"policy_request.accept", :"policy_request.decline"] do
        for scope <- [ctx.client.owner.scope, ctx.admin, ctx.member] do
          assert Access.authorize(scope, action, organisation) == :ok
        end

        for scope <- [ctx.client.scope, ctx.operator_admin] do
          assert Access.authorize(scope, action, organisation) == {:error, :forbidden}
        end
      end
    end
  end

  describe "the offer of an organisation's ownership" do
    setup do
      %{scope: owner, organisation: organisation, user: owner_user} = sign_up_fixture()
      recipient = member_fixture(owner, :admin)
      other = member_fixture(owner, :admin)
      %{instance_scope: arbiter} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(arbiter, owner_user.id)

      {:ok, offer} =
        ApiaryPro.Transfers.arbitrate(
          arbiter,
          organisation.id,
          recipient.membership.id,
          "The owner is away."
        )

      %{
        arbiter: arbiter,
        offer: offer,
        organisation: organisation,
        recipient: recipient,
        other: other
      }
    end

    test "the recipient admin may", ctx do
      assert Access.authorize(ctx.recipient.scope, :"organisation.accept_transfer", ctx.offer) ==
               :ok
    end

    test "another admin does not find it", ctx do
      assert Access.authorize(ctx.other.scope, :"organisation.accept_transfer", ctx.offer) ==
               {:error, :not_found}
    end

    test "the recipient made a member is forbidden", ctx do
      Apiary.Repo.update!(Ecto.Changeset.change(ctx.recipient.membership, level: :member))

      assert Access.authorize(ctx.recipient.scope, :"organisation.accept_transfer", ctx.offer) ==
               {:error, :forbidden}
    end

    test "the recipient does not find it from another organisation", ctx do
      # Dana is an admin of Acme, and the offer is for Web shop with Dana as its recipient.
      %{organisation: acme} = sign_up_fixture()
      dana = ctx.recipient.user

      Apiary.Repo.insert!(%Apiary.Organisations.Membership{
        user_id: dana.id,
        organisation_id: acme.id,
        level: :admin
      })

      assert Access.authorize(scope_in(dana, acme), :"organisation.accept_transfer", ctx.offer) ==
               {:error, :not_found}
    end

    test "the recipient whose membership is suspended is forbidden", ctx do
      Apiary.Repo.update!(
        Ecto.Changeset.change(ctx.recipient.membership,
          suspended_at: DateTime.utc_now()
        )
      )

      assert Access.authorize(ctx.recipient.scope, :"organisation.accept_transfer", ctx.offer) ==
               {:error, :forbidden}
    end

    test "in a suspended organisation the recipient may, and the context returns :suspended",
         ctx do
      {:ok, _} = ApiaryPro.Suspensions.suspend_organisation(ctx.arbiter, ctx.organisation.id)

      assert Access.authorize(ctx.recipient.scope, :"organisation.accept_transfer", ctx.offer) ==
               :ok

      assert ApiaryPro.Transfers.accept(ctx.recipient.scope) == {:error, :suspended}
    end
  end

  describe "a row of another organisation" do
    # A member's workspace access, asked by an owner of one organisation of a membership of
    # another's: not found, and yes for that organisation's own owner. The core's actions
    # on a row are asked in the core's access test.
    @rows [
      {:membership, [:"workspace_access.add", :"workspace_access.remove"]}
    ]

    setup do
      %{scope: owner} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()

      %{owner: owner, other: other, rows: %{membership: member_fixture(other).membership}}
    end

    for {row, actions} <- @rows, action <- actions do
      @tag row: row, action: action
      test "#{action} of another organisation's #{row} is not found", ctx do
        %{row: row, action: action, owner: owner, other: other} = ctx
        subject = Map.fetch!(ctx.rows, row)

        refute Access.can?(owner, action, subject)
        assert Access.authorize(owner, action, subject) == {:error, :not_found}

        assert Access.can?(other, action, subject)
        assert Access.authorize(other, action, subject) == :ok
      end
    end
  end

  describe "over people" do
    # Who an owner and an admin may change a member's workspace access for: an owner
    # anyone's, an admin a member's only, as the core's actions over people go.
    setup do
      %{scope: owner} = sign_up_fixture()
      %{scope: admin} = member_fixture(owner, :admin)

      memberships = %{
        owner: member_fixture(owner, :owner).membership,
        admin: member_fixture(owner, :admin).membership,
        member: member_fixture(owner, :member).membership
      }

      %{owner: owner, admin: admin, memberships: memberships}
    end

    test "an owner changes anyone's workspace access", ctx do
      for {_level, membership} <- ctx.memberships,
          action <- [:"workspace_access.add", :"workspace_access.remove"] do
        assert Access.authorize(ctx.owner, action, membership) == :ok
      end
    end

    test "an admin changes a member's workspace access only", ctx do
      for {level, membership} <- ctx.memberships,
          action <- [:"workspace_access.add", :"workspace_access.remove"] do
        expected = if level == :member, do: :ok, else: {:error, :forbidden}
        assert Access.authorize(ctx.admin, action, membership) == expected, "#{action} #{level}"
        assert Access.can?(ctx.admin, action, membership) == (expected == :ok)
      end
    end

    test "an admin reaches none of the edition's owner-only actions", ctx do
      owner_only =
        (Access.roles().owner -- Access.roles().admin) -- Apiary.AccessCase.actions(:core)

      # The instance actions are an owner's too, of the instance organisation alone.
      instance = [
        :"instance.change_kind",
        :"instance.create_operator",
        :"instance.create_organisation",
        :"instance.purge_organisation",
        :"instance.suspend_account",
        :"instance.activate_account",
        :"instance.suspend_organisation",
        :"instance.activate_organisation",
        :"instance.transfer",
        :"instance.grant_features",
        :"instance.change_sign_up"
      ]

      # So are accepting an organisation offered to an operator, granting a client its
      # features and dropping one, asked in an operator, and leaving an operator, asked in
      # a client.
      placed = [
        :"client.accept",
        :"client.grant_features",
        :"client.drop",
        :"client.delete",
        :"organisation.leave_operator" | instance
      ]

      assert Enum.sort(owner_only) ==
               Enum.sort(
                 [
                   :"organisation.transfer",
                   :"organisation.withdraw_transfer",
                   :"organisation_policy.edit",
                   :"organisation_policy.set_floor",
                   :"organisation_policy.set_switch"
                 ] ++ placed
               )

      for action <- owner_only -- placed do
        assert Access.authorize(ctx.admin, action, ctx.admin.workspace) == {:error, :forbidden}
      end

      # Asked in an organisation that is neither the instance organisation nor an
      # operator, they are not there.
      for action <- placed do
        assert Access.authorize(ctx.admin, action, ctx.admin.organisation) == {:error, :not_found}
      end
    end
  end

  describe "the workspaces a person reaches" do
    # A member reaches the workspaces they were added to; an owner and an admin reach every
    # workspace, as in the core's access test.
    setup do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      %{user: member, membership: membership} = member_fixture(owner, :member)

      %{owner: owner, second: second, member: member, membership: membership}
    end

    test "a member reaches the workspaces they were added to", ctx do
      refute Access.reaches_every_workspace?(:member)
      assert scope = workspace_scope(ctx.member, ctx.owner.workspace)
      assert Access.authorize(scope, :"run.read", ctx.owner.workspace) == :ok

      # A scope in a workspace they were not added to, however it was built, finds nothing.
      crafted = ApiaryPro.WorkspaceAccess.put(%{scope | workspace: ctx.second}, nil)

      for action <- [:"run.read", :"security_policy.edit"] do
        refute Access.can?(crafted, action, ctx.second)
        assert Access.authorize(crafted, action, ctx.second) == {:error, :not_found}
      end

      # Another member's workspace access, carried into their scope, reaches nothing.
      %{scope: other} = member_fixture(ctx.owner, :member)

      borrowed =
        ApiaryPro.WorkspaceAccess.put(crafted, %{
          ApiaryPro.WorkspaceAccess.of(other)
          | workspace_id: ctx.second.id
        })

      refute Access.can?(borrowed, :"run.read", ctx.second)
    end

    test "authorize/3 reads the workspace access again, and fails closed", ctx do
      scope = workspace_scope(ctx.member, ctx.owner.workspace)

      {:ok, _} =
        ApiaryPro.WorkspaceAccess.remove(
          ctx.owner,
          ctx.membership.id,
          ctx.owner.workspace.id
        )

      # The page's scope still carries the row; the database does not.
      assert Access.can?(scope, :"run.read", ctx.owner.workspace)
      assert Access.authorize(scope, :"run.read", ctx.owner.workspace) == {:error, :not_found}

      fresh = Access.reload(scope)
      assert ApiaryPro.WorkspaceAccess.of(fresh) == nil
      assert fresh.membership.level == :member

      assert Access.check(fresh, :"security_policy.edit", ctx.owner.workspace) ==
               {:error, :not_found}

      # What the organisation owns needs no workspace: the role answers.
      assert Access.check(fresh, :"organisation.rename", scope.organisation) ==
               {:error, :forbidden}
    end

    test "a member demoted from owner is read at their new level, with their access", ctx do
      %{scope: stale, membership: membership} = member_fixture(ctx.owner, :owner)
      stale_in_second = workspace_scope(stale.user, ctx.second)
      {:ok, _} = Apiary.Organisations.set_member_level(ctx.owner, membership.id, :member)

      # Kept in the workspace the demotion was made from, and in no other.
      assert Access.authorize(stale, :"run.read", ctx.owner.workspace) == :ok

      assert Access.authorize(stale_in_second, :"run.read", ctx.second) ==
               {:error, :not_found}
    end
  end

  describe "a person's own: creating an organisation" do
    setup do
      %{home: sign_up_fixture()}
    end

    test "follows the instance's sign-up settings, kind by kind", %{home: home} do
      for open <- [[], [:organisation], [:operator], [:organisation, :operator]] do
        open!(open)

        for kind <- Tenants.kinds() do
          expected = if kind in open, do: :ok, else: {:error, :forbidden}
          subject = Tenants.new(kind)

          assert Access.authorize(home.scope, :"organisation.create", subject) == expected,
                 "#{kind} with #{inspect(open)} open"

          assert Access.can?(home.scope, :"organisation.create", subject) == (expected == :ok)
        end
      end
    end

    test "is asked of no place: without an organisation, or from one marked for deletion",
         %{home: home} do
      open!([:organisation])
      new = Tenants.new(:organisation)

      assert Access.authorize(Scope.for_user(home.user), :"organisation.create", new) == :ok

      {:ok, _} = Apiary.Deletion.delete_organisation(home.scope, home.organisation.slug)
      assert Access.authorize(home.scope, :"organisation.create", new) == :ok
    end

    test "is of a new organisation, of no operator, only", %{home: home} do
      open!([:organisation, :operator])

      for subject <- [
            home.organisation,
            home.workspace,
            Tenants.put_tenant(%Organisation{}, %Tenant{operator_id: home.organisation.id}),
            Tenants.put_tenant(%Organisation{}, %Tenant{
              kind: :operator,
              instance_organisation: true
            }),
            Tenants.put_tenant(%Organisation{}, %Tenant{kind: nil}),
            nil
          ] do
        assert Access.authorize(home.scope, :"organisation.create", subject) ==
                 {:error, :forbidden},
               inspect(subject)
      end
    end

    test "is nobody's without a person, or with a deleted account", %{home: home} do
      open!([:organisation, :operator])
      new = Tenants.new(:organisation)
      %{access_key: key} = access_key_fixture(home.scope)
      deleted = %{home.scope | user: %{home.user | deleted_at: DateTime.utc_now(:second)}}

      for scope <- [
            Scope.for_instance(home.organisation, home.workspace),
            Scope.for_access_key(key),
            %Scope{},
            deleted
          ] do
        refute Access.can?(scope, :"organisation.create", new)
        assert Access.authorize(scope, :"organisation.create", new) == {:error, :forbidden}
      end
    end

    # A suspended account has no session, so no scope a page loads carries one; one loaded
    # before its suspension creates nothing, since the creation reads the suspension again
    # under the account's lock.
    test "creates nothing for an account suspended since its scope was loaded", %{home: home} do
      %{instance_scope: admin} = instance_admin_fixture()
      {:ok, _} = ApiaryPro.Suspensions.suspend_account(admin, home.user.id)
      open!([:organisation, :operator])

      assert ApiaryPro.Organisations.create_organisation(home.scope, %{
               "name" => "Second",
               "kind" => "organisation"
             }) == {:error, :forbidden}
    end
  end
end
