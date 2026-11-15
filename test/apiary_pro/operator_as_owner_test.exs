defmodule ApiaryPro.OperatorAsOwnerTest do
  # What the operator's people and the organisation's people may do in a workspace the
  # operator operates, with the flag on for this process and those it starts
  # (`ApiaryPro.Flags.put_operator_infrastructure/1`), once the world is made with it off.
  # The operator operates Main, and not Platform; what each actor may of each action is in
  # `ApiaryPro.OperatorAsOwnerAccessTest`.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Organisations}
  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    operated = operated_fixture(operator.scope)
    platform = workspace_fixture(operated.organisation, "Platform")
    operator_admin = member_fixture(operator.scope, :admin)
    operator_member = member_fixture(operator.scope, :member)

    Flags.put_operator_infrastructure(true)

    %{
      operator: operator,
      operated: operated,
      platform: platform,
      organisation_admin: organisation_member_fixture(operated, :admin),
      organisation_member: organisation_member_fixture(operated, :member),
      invitation: invitation_fixture(operated.owner.scope).invitation,
      operator_admin: operator_admin,
      operator_member: operator_member,
      as_owner: operated.scope,
      as_admin: scope_in(operator_admin.user, operated.organisation, operated.workspace),
      as_member: scope_in(operator_member.user, operated.organisation, operated.workspace)
    }
  end

  @changes_in_operated [
    {:"organisation.rename", :organisation},
    {:"organisation.delete", :organisation},
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
    {:"member.change_level", :organisation_member},
    {:"member.remove", :organisation_member},
    {:"member.suspend", :organisation_member},
    {:"member.activate", :organisation_member},
    {:"workspace_access.add", :organisation_member},
    {:"workspace_access.remove", :organisation_member}
  ]

  describe "the role" do
    test "is the level of the operator's owners and admins, and a reader's for its members",
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
      for as <- [ctx.as_owner, ctx.as_admin, ctx.organisation_admin.scope] do
        assert Access.reader(as) == nil
        refute Access.reads_only?(Map.fetch!(Access.roles(), Access.role(as)))
      end

      assert Access.role(ctx.organisation_admin.scope) == :admin

      # The operator's members read only.
      assert Access.reads_only?(Map.fetch!(Access.roles(), Access.role(ctx.as_member)))
      assert Access.reader(ctx.as_member) == :operator

      # With the flag off, every one of the operator's people reads.
      Flags.put_operator_infrastructure(false)

      for as <- [ctx.as_owner, ctx.as_admin, ctx.as_member],
          do: assert(Access.reader(as) == :operator)

      assert Access.reader(ctx.organisation_admin.scope) == nil
    end

    test "an instance admin still reads", ctx do
      admin = suite_instance_admin()
      scope = scope_in(admin.user, ctx.operated.organisation, ctx.operated.workspace)
      assert Access.role(scope) == :reader

      assert Access.authorize(scope, :"organisation.rename", ctx.operated.organisation) ==
               {:error, :forbidden}
    end
  end

  describe "the operator's people in an operated workspace" do
    test "its members read everything and change nothing", ctx do
      scope = ctx.as_member
      assert Access.authorize(scope, :"run.read", ctx.operated.workspace) == :ok
      # Nothing the organisation owns as a whole, its policy among it.
      assert Access.authorize(scope, :"organisation_policy.read", ctx.operated.organisation) ==
               {:error, :not_found}

      assert Access.authorize(scope, :"audit.read", ctx.operated.organisation) ==
               {:error, :not_found}

      for {action, on} <- @changes_in_operated do
        refute Access.can?(scope, action, on(ctx, on)), "#{action}"
        assert {:error, _refused} = Access.authorize(scope, action, on(ctx, on)), "#{action}"
      end
    end

    test "its owners and admins change what the operator changes in Main, and nothing the organisation owns",
         ctx do
      for as <- [ctx.as_owner, ctx.as_admin] do
        for {action, on} <- [
              {:"retention.edit", :workspace},
              {:"time_limit.edit", :workspace},
              {:"node.create", :workspace},
              {:"process.edit", :workspace},
              {:"artifact_type.edit", :workspace},
              {:"model_choice.write", :workspace}
            ] do
          assert Access.authorize(as, action, on(ctx, on)) == :ok, "#{action}"
        end

        for {action, on} <- [
              {:"security_policy.lock", :workspace},
              {:"security_policy.edit", :workspace},
              {:"secret.write", :workspace},
              {:"workspace.rename", :workspace}
            ] do
          assert Access.authorize(as, action, on(ctx, on)) == {:error, :forbidden}, "#{action}"
        end

        for {action, on} <- [
              {:"harness.save", :workspace},
              {:"organisation.rename", :organisation},
              {:"connection.write", :organisation},
              {:"provider.write", :organisation},
              {:"member.invite", :invitation},
              {:"member.change_level", :organisation_member},
              {:"member.remove", :organisation_member}
            ] do
          assert Access.authorize(as, action, on(ctx, on)) == {:error, :not_found}, "#{action}"
        end
      end

      # Platform, which the operator does not operate, they do not reach.
      assert scope_in(ctx.operator.user, ctx.operated.organisation, ctx.platform) == nil
    end

    test "authorize/3 fails closed once they are removed from the operator", ctx do
      scope = ctx.as_admin
      assert Access.can?(scope, :"node.create", ctx.operated.workspace)

      {:ok, _} = Organisations.remove_member(ctx.operator.scope, ctx.operator_admin.membership.id)

      assert Access.can?(scope, :"node.create", ctx.operated.workspace)
      assert {:error, _refused} = Access.authorize(scope, :"node.create", ctx.operated.workspace)
    end

    test "authorize/3 fails closed once they are made a member of the operator", ctx do
      scope = ctx.as_admin

      {:ok, _} =
        Organisations.set_member_level(
          ctx.operator.scope,
          ctx.operator_admin.membership.id,
          :member
        )

      assert Access.can?(scope, :"node.create", ctx.operated.workspace)

      # What the operator sets is not there for its members.
      assert Access.authorize(scope, :"node.create", ctx.operated.workspace) ==
               {:error, :not_found}

      assert Access.authorize(scope, :"run.read", ctx.operated.workspace) == :ok
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
                 Access.authorize(scope, :"node.create", ctx.operated.workspace)
      end
    end
  end

  describe "someone in both acts at the higher of their two levels" do
    test "an owner of the operator who is a member of the organisation acts as an owner in Main on what the operator changes",
         ctx do
      %{user: user} = member_fixture(ctx.operator.scope, :owner)
      Flags.put_operator_infrastructure(false)
      join_fixture(ctx.operated.owner.scope, user)
      Flags.put_operator_infrastructure(true)

      in_main = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)
      assert Access.level(in_main) == :member

      assert Access.authorize(in_main, :"node.create", ctx.operated.workspace) == :ok

      # Anything else at their level in the organisation.
      assert Access.authorize(in_main, :"security_policy.lock", ctx.operated.workspace) ==
               {:error, :forbidden}

      admin = ctx.organisation_admin.membership

      assert Access.authorize(in_main, :"member.change_level", admin) == {:error, :forbidden}

      # With the flag off, their membership decides.
      Flags.put_operator_infrastructure(false)

      assert Access.authorize(in_main, :"node.create", ctx.operated.workspace) ==
               {:error, :forbidden}
    end

    test "a member of the operator who is an admin of the organisation acts as an admin", ctx do
      user = ctx.operator_member.user
      Flags.put_operator_infrastructure(false)
      %{membership: joined} = join_fixture(ctx.operated.owner.scope, user)
      {:ok, _} = Organisations.set_member_level(ctx.operated.owner.scope, joined.id, :admin)
      Flags.put_operator_infrastructure(true)

      scope = scope_in(user, ctx.operated.organisation, ctx.platform)
      assert Access.level(scope) == :admin
      assert Access.authorize(scope, :"security_policy.set_mode", ctx.platform) == :ok
      assert Access.authorize(scope, :"member.remove", ctx.organisation_member.membership) == :ok

      assert Access.authorize(scope, :"security_policy.lock", ctx.platform) ==
               {:error, :forbidden}
    end

    test "an admin of the operator who is an owner of the organisation acts as its owner", ctx do
      user = ctx.operator_admin.user
      Flags.put_operator_infrastructure(false)
      %{membership: joined} = join_fixture(ctx.operated.owner.scope, user)
      {:ok, _} = Organisations.set_member_level(ctx.operated.owner.scope, joined.id, :owner)
      Flags.put_operator_infrastructure(true)

      scope = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)
      assert Access.level(scope) == :owner
      admin = ctx.organisation_admin.membership
      assert Access.authorize(scope, :"member.change_level", admin) == :ok

      # A rule's lock and the organisation's policy too: they are the organisation's owners'.
      for {action, on} <- [
            {:"security_policy.lock", ctx.operated.workspace},
            {:"organisation_policy.edit", ctx.operated.organisation}
          ] do
        assert Access.authorize(scope, action, on) == :ok, "#{action}"
      end
    end
  end

  describe "what the organisation decides" do
    @own_to_decide [
      :"organisation.withdraw_transfer",
      :"organisation.delete"
    ]

    test "is not found for the operator's people, and refused to one who is a member of the organisation",
         ctx do
      %{user: user} = member_fixture(ctx.operator.scope, :owner)
      Flags.put_operator_infrastructure(false)
      join_fixture(ctx.operated.owner.scope, user)
      Flags.put_operator_infrastructure(true)
      in_both = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      for scope <- [ctx.as_owner, ctx.as_admin, ctx.as_member], action <- @own_to_decide do
        assert Access.authorize(scope, action, ctx.operated.organisation) == {:error, :not_found},
               "#{action}"
      end

      for action <- @own_to_decide do
        assert Access.authorize(in_both, action, ctx.operated.organisation) ==
                 {:error, :forbidden},
               "#{action}"
      end

      # With the flag off, likewise.
      Flags.put_operator_infrastructure(false)

      assert Access.authorize(ctx.as_owner, :"organisation.delete", ctx.operated.organisation) ==
               {:error, :not_found}
    end

    test "stays the organisation's owners', an admin of the operator among them", ctx do
      user = ctx.operator_admin.user
      Flags.put_operator_infrastructure(false)
      %{membership: joined} = join_fixture(ctx.operated.owner.scope, user)
      {:ok, _} = Organisations.set_member_level(ctx.operated.owner.scope, joined.id, :owner)
      Flags.put_operator_infrastructure(true)
      in_both = scope_in(user, ctx.operated.organisation, ctx.operated.workspace)

      for scope <- [ctx.operated.owner.scope, in_both], action <- @own_to_decide do
        assert Access.authorize(scope, action, ctx.operated.organisation) == :ok, "#{action}"
      end
    end

    test "is answered at the organisation's level on a tie, and refused where the operator's is higher",
         ctx do
      # An admin of both acts at their level in the organisation: the tie is not through the
      # operator.
      admin_of_both = ctx.operator_admin.user
      # An owner of the operator who is an admin of the organisation acts through the operator,
      # whose level is higher.
      %{user: owner_and_admin} = member_fixture(ctx.operator.scope, :owner)
      # A member of the operator who is an admin of the organisation acts at its level there.
      member_and_admin = ctx.operator_member.user

      Flags.put_operator_infrastructure(false)

      for user <- [admin_of_both, owner_and_admin, member_and_admin] do
        %{membership: joined} = join_fixture(ctx.operated.owner.scope, user)
        {:ok, _} = Organisations.set_member_level(ctx.operated.owner.scope, joined.id, :admin)
      end

      Flags.put_operator_infrastructure(true)
      in_main = &scope_in(&1, ctx.operated.organisation, ctx.operated.workspace)
      organisation = ctx.operated.organisation

      for action <- @own_to_decide do
        assert Access.authorize(in_main.(owner_and_admin), action, organisation) ==
                 {:error, :forbidden},
               "#{action}"
      end

      # The admin of both is no owner of the organisation: what only an owner decides stays
      # out of their reach, at their level in the organisation.
      assert Access.authorize(in_main.(admin_of_both), :"organisation.delete", organisation) ==
               {:error, :forbidden}
    end

    test "a deletion is cancelled by the organisation's owners, not the operator's", ctx do
      marked = %{ctx.operated.organisation | deletion_marked_at: DateTime.utc_now()}
      owner = %{ctx.operated.owner.scope | organisation: marked}
      assert Access.can?(owner, :"organisation.restore", marked)
      refute Access.can?(%{ctx.as_owner | organisation: marked}, :"organisation.restore", marked)
    end
  end

  describe "the organisation's people" do
    test "an owner of the operator finds none of the organisation's people", ctx do
      owner = ctx.as_owner
      admin = ctx.organisation_admin.membership

      assert {:error, :not_found} = Organisations.set_member_level(owner, admin.id, :member)
      assert {:error, :not_found} = Organisations.suspend_member(owner, admin.id)
      assert {:error, :not_found} = Organisations.remove_member(owner, admin.id)
    end
  end

  describe "the organisation's workspaces" do
    test "are made by its owners, deleted and brought back by its owners and admins, and not found for the operator's people",
         ctx do
      organisation = ctx.operated.organisation

      for {as, create, delete} <- [
            {ctx.as_owner, {:error, :not_found}, {:error, :not_found}},
            {ctx.as_admin, {:error, :not_found}, {:error, :not_found}},
            {ctx.as_member, {:error, :not_found}, {:error, :not_found}},
            {ctx.operated.owner.scope, :ok, :ok},
            {ctx.organisation_admin.scope, {:error, :forbidden}, :ok}
          ] do
        assert Access.authorize(as, :"workspace.create", organisation) == create
        assert Access.authorize(as, :"workspace.delete", organisation) == delete
        assert Access.authorize(as, :"workspace.restore", organisation) == delete

        assert Access.authorize(as, :"workspace.rename", ctx.operated.workspace) !=
                 {:error, :not_found}
      end

      # Renaming is as before: the organisation's owner and admins rename.
      admin = ctx.organisation_admin.scope
      assert Access.authorize(admin, :"workspace.rename", ctx.operated.workspace) == :ok

      # In the operator itself, and with the flag off, nothing changes.
      assert Access.authorize(ctx.operator.scope, :"workspace.create", ctx.operator.organisation) ==
               :ok

      Flags.put_operator_infrastructure(false)
      assert Access.authorize(ctx.operated.owner.scope, :"workspace.create", organisation) == :ok
      assert Access.authorize(admin, :"workspace.delete", organisation) == :ok
    end

    test "are not found for the operator's people without a membership in the organisation, with the flag off",
         ctx do
      Flags.put_operator_infrastructure(false)

      for as <- [ctx.as_owner, ctx.as_admin, ctx.as_member] do
        assert Access.authorize(as, :"workspace.create", ctx.operated.organisation) ==
                 {:error, :not_found}
      end
    end
  end

  describe "what the operator sets in an operated workspace" do
    # Each action with what it is asked of: in Main, which the operator operates. The
    # organisation's model providers and runtimes, the model choices and the harness
    # documents are not among them.
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
      {:"time_limit.edit", :workspace},
      {:"retention.edit", :workspace}
    ]

    test "is held by the operator's owners and admins, and not there for anyone else",
         ctx do
      for as <- [ctx.as_owner, ctx.as_admin], {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == :ok, "#{action}"
      end

      for as <- [
            ctx.as_member,
            ctx.operated.owner.scope,
            ctx.organisation_admin.scope,
            ctx.organisation_member.scope
          ],
          {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == {:error, :not_found}, "#{action}"
      end
    end

    test "is the organisation's with the flag off, and the operator's people read", ctx do
      Flags.put_operator_infrastructure(false)

      for as <- [ctx.operated.owner.scope, ctx.organisation_admin.scope],
          {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == :ok, "#{action}"
      end

      for as <- [ctx.as_owner, ctx.as_admin], {action, on} <- @operator_held do
        assert Access.authorize(as, action, on(ctx, on)) == {:error, :forbidden}, "#{action}"
      end
    end

    test "leaves reading, and the organisation's policy, variables, secrets and work, with it",
         ctx do
      workspace = ctx.operated.workspace

      for as <- [ctx.as_member, ctx.operated.owner.scope, ctx.organisation_member.scope],
          do: assert(Access.authorize(as, :"node.read", workspace) == :ok)

      for as <- [ctx.operated.owner.scope, ctx.organisation_admin.scope],
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

  defp on(ctx, :workspace), do: ctx.operated.workspace
  defp on(ctx, :organisation), do: ctx.operated.organisation
  defp on(ctx, :invitation), do: ctx.invitation
  defp on(ctx, :organisation_member), do: ctx.organisation_member.membership
end
