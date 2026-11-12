defmodule Apiary.AccessTest do
  # Not async: a test of a feature switched off switches the features of the whole node.
  # These tests cover the rules of `Apiary.Access.can?/3` and `authorize/3` once each, with
  # the refusal: the role of each level, a node's key and the instance; the feature; the
  # edition; the place; the workspaces a person reaches; the marks for deletion; leaving
  # one's membership, what a person wrote, and whom an action over people is over. The
  # rules of the pool, gateway and adapter keys and the dispatch actions are tested in
  # test/apiary/pool_key_role_test.exs, gateways_instance_test.exs, adapters_test.exs and
  # adapters/connections_test.exs; the approvers in access_approvers_test.exs.
  # `Apiary.AccessCase` checks that every core action has a row of `Apiary.AccessRows`.
  use Apiary.AccessCase, rows: [Apiary.AccessRows], covers: :core

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  # An edition that sends its process the scope of an invitation's acceptance
  # (`c:Apiary.Edition.accepted/4`).
  defmodule SendsAcceptedScope do
    def accepted(repo, scope, invitation, membership) do
      send(self(), {:accepted_in, scope})
      Apiary.Edition.module().accepted(repo, scope, invitation, membership)
    end
  end

  test "an action that is none raises" do
    assert_raise ArgumentError, fn -> Access.can?(nil, :"no.such_action", nil) end
    assert_raise ArgumentError, fn -> Access.authorize(nil, :"no.such_action", nil) end
    assert_raise ArgumentError, fn -> Access.action(:"no.such_action") end
  end

  # Every page calls a review comment a "comment"; so do the action's words in the
  # permission table and its audit note. The action's name stays work_item.review_comment.
  test "work_item.review_comment is described with comment, the word the pages use" do
    %{what: what, audited: {:not, note}} = Access.action(:"work_item.review_comment")

    assert what =~ "write a comment on a stage's outputs or round for a work item, reply to one,"
    assert note =~ "a comment, a reply and a send each leave the entry of work_item.answer"
    refute what =~ "review comment"
    refute note =~ "review comment"
  end

  test "the approvers' step says comments in the moduledoc and in docs/access.md" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Access)

    assert moduledoc =~ "proposal and the comments on a stage's outputs or round (`gate.approve`"

    assert File.read!("docs/access.md") =~
             "the comments on a stage's outputs or round (`work_item.review_comment`)"
  end

  describe "each actor" do
    setup do: Apiary.AccessCase.setup_actors([Apiary.AccessRows])

    test "reaches as the table says", ctx do
      for level <- [:member, :admin, :owner] do
        assert Access.reach(ctx.scopes[level]) == :membership
        assert Access.reader(ctx.scopes[level]) == nil
        assert Access.level(ctx.scopes[level]) == level
      end

      # The gateway and the instance act in a role of their own, at no level.
      for actor <- [:access_key, :instance] do
        assert Access.reach(ctx.scopes[actor]) == nil
        assert Access.reader(ctx.scopes[actor]) == nil
        assert Access.level(ctx.scopes[actor]) == nil
      end
    end
  end

  describe "the role" do
    # One action of each role, asked of the role that holds it and of one that does not:
    # an action the role does not hold is forbidden.
    setup do
      %{scope: owner} = sign_up_fixture()

      %{
        owner: owner,
        admin: member_fixture(owner, :admin).scope,
        member: member_fixture(owner, :member).scope,
        instance: Scope.for_instance(owner.organisation, owner.workspace)
      }
    end

    test "a member's action: every level takes it, the instance does not", ctx do
      for level <- [:member, :admin, :owner] do
        assert Access.can?(ctx[level], :"node.read", ctx.owner.workspace)
        assert Access.authorize(ctx[level], :"node.read", ctx.owner.workspace) == :ok
      end

      refute Access.can?(ctx.instance, :"node.read", ctx.owner.workspace)

      assert Access.authorize(ctx.instance, :"node.read", ctx.owner.workspace) ==
               {:error, :forbidden}
    end

    test "an admin's action: an admin and an owner take it, a member does not", ctx do
      for level <- [:admin, :owner] do
        assert Access.authorize(ctx[level], :"workspace.rename", ctx.owner.workspace) == :ok
      end

      refute Access.can?(ctx.member, :"workspace.rename", ctx.owner.workspace)

      assert Access.authorize(ctx.member, :"workspace.rename", ctx.owner.workspace) ==
               {:error, :forbidden}
    end

    test "an owner's action: an owner takes it, an admin does not", ctx do
      organisation = ctx.owner.organisation
      assert Access.authorize(ctx.owner, :"organisation.delete", organisation) == :ok

      refute Access.can?(ctx.admin, :"organisation.delete", organisation)

      assert Access.authorize(ctx.admin, :"organisation.delete", organisation) ==
               {:error, :forbidden}
    end

    test "the instance's action: the instance takes it, an owner does not", ctx do
      organisation = ctx.owner.organisation
      assert Access.authorize(ctx.instance, :"audit.prune", organisation) == :ok

      refute Access.can?(ctx.owner, :"audit.prune", organisation)
      assert Access.authorize(ctx.owner, :"audit.prune", organisation) == {:error, :forbidden}
    end

    test "a node's key: it takes its role's action and no person's, and no person takes its",
         ctx do
      %{access_key: key} = access_key_fixture(ctx.owner)
      key = Scope.for_access_key(key)
      workspace = ctx.owner.workspace

      assert Access.role(key) == :access_key
      assert Access.authorize(key, :"run.post_events", workspace) == :ok
      assert Access.authorize(key, :"node.read", workspace) == {:error, :forbidden}
      assert Access.authorize(ctx.owner, :"run.post_events", workspace) == {:error, :forbidden}
    end
  end

  describe "a feature that is off" do
    # Every feature but `secrets` and the features that need it.
    @without_secrets Enum.reject(
                       Apiary.Features.all(),
                       &(&1 == :secrets or :secrets in Apiary.Features.needs(&1))
                     )

    @tag with_features: @without_secrets
    test "its action is not found to anyone whose role holds it; an action of none answers" do
      %{scope: owner} = sign_up_fixture()
      member = member_fixture(owner, :member).scope

      for scope <- [owner, member] do
        refute Access.can?(scope, :"secret.read", scope.workspace)
        assert Access.authorize(scope, :"secret.read", scope.workspace) == {:error, :not_found}
        assert Access.authorize(scope, :"node.read", scope.workspace) == :ok
      end
    end

    test "with the feature on, its action answers as the role does" do
      %{scope: owner} = sign_up_fixture()
      member = member_fixture(owner, :member).scope

      for scope <- [owner, member] do
        assert Access.authorize(scope, :"secret.read", scope.workspace) == :ok
      end
    end
  end

  describe "the edition" do
    # The edition is asked before the core's steps (`Apiary.Edition.check/3`): its answer
    # stands, a yes the role would not give and a no the role would not; `:continue`
    # leaves the answer to the core.
    setup do
      %{scope: owner} = sign_up_fixture()
      %{owner: owner, admin: member_fixture(owner, :admin).scope}
    end

    test "its no stands where the role allows", ctx do
      workspace = ctx.owner.workspace
      assert Access.authorize(ctx.owner, :"node.read", workspace) == :ok

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReadsNoMachines)

      refute Access.can?(ctx.owner, :"node.read", workspace)
      assert Access.authorize(ctx.owner, :"node.read", workspace) == {:error, :forbidden}
      # Every other action is left to the core.
      assert Access.authorize(ctx.owner, :"workspace.rename", workspace) == :ok
    end

    test "its yes stands where the role refuses", ctx do
      %{membership: membership} = member_fixture(ctx.owner, :admin)

      assert Access.authorize(ctx.admin, :"member.change_level", membership) ==
               {:error, :forbidden}

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.AdminsChangeLevels)

      assert Access.can?(ctx.admin, :"member.change_level", membership)
      assert Access.authorize(ctx.admin, :"member.change_level", membership) == :ok
    end
  end

  describe "a reader" do
    # `reader/1` names the edition's way in only for a role that changes nothing, asked
    # with `reads_only?/1` of the actions the role holds: a stub role an edition might
    # give, with the core's actions.
    test "a role that holds only reads changes nothing, one with a change does" do
      assert Access.reads_only?([])

      reads = [:"node.read", :"run.read", :"secret.read", :"audit.read", :"connection.read"]
      assert Access.reads_only?(reads)

      for change <- [:"workspace.rename", :"node.edit", :"security_policy.edit", :"member.invite"] do
        refute Access.reads_only?(reads ++ [change]), "#{change} is a change"
        refute Access.reads_only?([change])
      end
    end

    test "every level of the core holds a change, so none is a reader" do
      for level <- [:owner, :admin, :member] do
        refute Access.reads_only?(Map.fetch!(Access.roles(), level)), "#{level} changes nothing"
      end
    end

    test "an action that is none raises" do
      assert_raise ArgumentError, fn -> Access.reads_only?([:"no.such_action"]) end
    end
  end

  describe "marked for deletion" do
    # A scope loaded before the marking, asked after it: an action is not found, as for an
    # organisation or a workspace that is gone, but cancelling the deletion and the purge,
    # which answer as the role does. An access key of a marked organisation or workspace is
    # refused at its verification, on every request, and asks nothing here.

    setup do
      signed_up = sign_up_fixture()
      owner = signed_up.scope
      staging = workspace_fixture(signed_up.organisation, "Staging")
      there = workspace_scope(signed_up.user, staging)
      member = member_fixture(there, :member).user
      admin = member_fixture(there, :admin).user

      %{
        owner: owner,
        organisation: signed_up.organisation,
        workspace: staging,
        scopes: %{
          member: workspace_scope(member, staging),
          admin: workspace_scope(admin, staging),
          owner: there,
          instance: Scope.for_instance(signed_up.organisation, staging)
        }
      }
    end

    test "a marked organisation: an action is not found, but cancelling and the purge", ctx do
      %{scopes: scopes, organisation: organisation, workspace: workspace} = ctx

      for actor <- [:owner, :admin, :member] do
        assert Access.authorize(scopes[actor], :"node.read", workspace) == :ok
      end

      assert Access.authorize(scopes.instance, :"audit.prune", organisation) == :ok

      {:ok, _} = Apiary.Deletion.delete_organisation(ctx.owner, organisation.slug)

      for actor <- [:owner, :admin, :member] do
        assert Access.authorize(scopes[actor], :"node.read", workspace) == {:error, :not_found}
      end

      # The instance's scope, loaded before the marking, reads the marks again too.
      assert Access.authorize(scopes.instance, :"audit.prune", organisation) ==
               {:error, :not_found}

      assert Access.authorize(scopes.owner, :"organisation.rename", organisation) ==
               {:error, :not_found}

      # Cancelling the deletion and the purge answer as the role does.
      assert Access.authorize(scopes.owner, :"organisation.restore", organisation) == :ok

      assert Access.authorize(scopes.admin, :"organisation.restore", organisation) ==
               {:error, :forbidden}

      assert Access.authorize(scopes.instance, :"organisation.purge", organisation) == :ok

      assert Access.authorize(scopes.owner, :"organisation.purge", organisation) ==
               {:error, :forbidden}
    end

    test "a marked workspace: an action there is not found, but cancelling and the purge",
         ctx do
      %{scopes: scopes, organisation: organisation, workspace: workspace} = ctx

      for actor <- [:owner, :admin, :member] do
        assert Access.authorize(scopes[actor], :"node.read", workspace) == :ok
      end

      assert Access.authorize(scopes.instance, :"audit.prune", organisation) == :ok

      {:ok, _} =
        Apiary.Deletion.delete_workspace(ctx.owner, workspace.id, workspace.slug)

      for actor <- [:owner, :admin, :member] do
        assert Access.authorize(scopes[actor], :"node.read", workspace) == {:error, :not_found}
      end

      # The instance's scope at the workspace, loaded before the marking, reads the marks
      # again: no action the instance holds is of a workspace but the purge, so it is
      # checked with one of the organisation, from that scope.
      assert Access.authorize(scopes.instance, :"audit.prune", organisation) ==
               {:error, :not_found}

      assert Access.authorize(scopes.owner, :"workspace.rename", workspace) ==
               {:error, :not_found}

      # Cancelling the deletion and the purge answer as the role does.
      assert Access.authorize(scopes.owner, :"workspace.restore", organisation) == :ok
      assert Access.authorize(scopes.admin, :"workspace.restore", organisation) == :ok

      assert Access.authorize(scopes.member, :"workspace.restore", organisation) ==
               {:error, :forbidden}

      assert Access.authorize(scopes.instance, :"workspace.purge", workspace) == :ok

      # The organisation's other workspace is not marked.
      assert Access.authorize(ctx.owner, :"node.read", ctx.owner.workspace) == :ok
    end

    test "can?/3 answers from the marks the scope carries, without a read", ctx do
      {:ok, _} = Apiary.Deletion.delete_organisation(ctx.owner, ctx.organisation.slug)
      stale = ctx.scopes.owner
      assert Access.can?(stale, :"node.read", stale.workspace)

      fresh = Access.reload(stale)
      refute Access.can?(fresh, :"node.read", fresh.workspace)
      assert Access.can?(fresh, :"organisation.restore", fresh.organisation)
    end
  end

  describe "a suspended membership" do
    setup do
      %{scope: owner} = sign_up_fixture()
      %{owner: owner, member: member_fixture(owner, :member)}
    end

    test "answers as no membership", ctx do
      scope = ctx.member.scope
      assert Access.authorize(scope, :"node.read", scope.workspace) == :ok

      {:ok, _} = Apiary.Organisations.suspend_member(ctx.owner, ctx.member.membership.id)

      assert Access.reload(scope).membership == nil

      assert Access.authorize(scope, :"node.read", scope.workspace) ==
               {:error, :forbidden}

      assert Access.authorize(scope, :"run.read", scope.workspace) == {:error, :forbidden}
      # The scope as loaded still carries it: a page follows by the broadcast.
      assert Access.can?(scope, :"node.read", scope.workspace)

      {:ok, _} = Apiary.Organisations.activate_member(ctx.owner, ctx.member.membership.id)
      assert Access.authorize(scope, :"node.read", scope.workspace) == :ok
    end
  end

  describe "a row of another organisation" do
    # Each action whose subject can be a row, asked by an owner of one organisation of a row
    # of another's: not found, and yes for that organisation's own owner.
    @rows [
      {:run, [:"run.read", :"run.read_log"]},
      {:rule, [:"security_policy.edit", :"security_policy.lock"]},
      {:node, [:"access_key.create_code", :"access_key.add"]},
      {:node_key, [:"access_key.revoke"]},
      {:code, [:"access_key.cancel_code"]},
      {:membership, [:"member.change_level", :"member.remove"]},
      {:invitation, [:"invitation.revoke", :"invitation.renew"]}
    ]

    setup do
      %{scope: owner} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      {:ok, rule} = Apiary.Policy.allow(other, nil, %{host: "api.example"})
      node = node_fixture(other)
      {:ok, code, _} = Apiary.AccessKeys.create_enrolment_code(other, node, %{})

      %{
        owner: owner,
        other: other,
        rows: %{
          run: run_fixture(other),
          rule: rule,
          node: node,
          node_key: enrolled_key_fixture(other, node).access_key,
          code: code,
          membership: member_fixture(other).membership,
          invitation: invitation_fixture(other).invitation
        }
      }
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
    # Who an owner and an admin may take the actions over people on: an owner on anyone, an
    # admin on members only. Asked of the membership, whose level decides, or of the
    # invitation, which is at member: its person joins as one.
    setup do
      %{scope: owner} = sign_up_fixture()
      %{scope: admin} = member_fixture(owner, :admin)

      memberships = %{
        owner: member_fixture(owner, :owner).membership,
        admin: member_fixture(owner, :admin).membership,
        member: member_fixture(owner, :member).membership
      }

      %{
        owner: owner,
        admin: admin,
        memberships: memberships,
        invitation: invitation_fixture(owner).invitation
      }
    end

    test "an owner takes them on anyone", ctx do
      for {_level, membership} <- ctx.memberships,
          action <- [:"member.change_level", :"member.remove"] do
        assert Access.authorize(ctx.owner, action, membership) == :ok
      end

      for action <- [:"member.invite", :"invitation.revoke", :"invitation.renew"] do
        assert Access.authorize(ctx.owner, action, ctx.invitation) == :ok
      end
    end

    test "an admin takes them on members only, and changes no level", ctx do
      for {level, membership} <- ctx.memberships do
        expected = if level == :member, do: :ok, else: {:error, :forbidden}
        assert Access.authorize(ctx.admin, :"member.remove", membership) == expected, "#{level}"
        assert Access.can?(ctx.admin, :"member.remove", membership) == (expected == :ok)
      end

      for {_level, membership} <- ctx.memberships do
        assert Access.authorize(ctx.admin, :"member.change_level", membership) ==
                 {:error, :forbidden}
      end

      # An invitation makes a member, whoever sent it.
      for action <- [:"member.invite", :"invitation.revoke", :"invitation.renew"] do
        assert Access.authorize(ctx.admin, action, ctx.invitation) == :ok
      end
    end

    test "anyone with a membership may remove their own, and only their own", ctx do
      %{scope: member, membership: own} = member_fixture(ctx.owner, :member)
      assert Access.own() == [:"member.remove"]

      assert Access.authorize(member, :"member.remove", own) == :ok
      assert Access.authorize(ctx.admin, :"member.remove", ctx.admin.membership) == :ok

      for {_level, other} <- ctx.memberships do
        assert Access.authorize(member, :"member.remove", other) == {:error, :forbidden}
      end

      # Leaving is removing; it is not changing one's own level.
      assert Access.authorize(member, :"member.change_level", own) == {:error, :forbidden}

      # Nor may a membership of another organisation be passed off as one's own.
      %{membership: elsewhere} = sign_up_fixture()
      assert Access.authorize(member, :"member.remove", elsewhere) == {:error, :not_found}
    end

    test "suspending and activating: an owner on admins and members, an admin on members, nobody on an owner or their own",
         ctx do
      for action <- [:"member.suspend", :"member.activate"] do
        for {level, membership} <- ctx.memberships do
          expected = if level == :owner, do: {:error, :forbidden}, else: :ok
          assert Access.authorize(ctx.owner, action, membership) == expected, "#{action} #{level}"
          expected = if level == :member, do: :ok, else: {:error, :forbidden}
          assert Access.authorize(ctx.admin, action, membership) == expected, "#{action} #{level}"
        end

        assert Access.authorize(ctx.owner, action, ctx.owner.membership) == {:error, :forbidden}
        assert Access.authorize(ctx.admin, action, ctx.admin.membership) == {:error, :forbidden}

        %{scope: member, membership: own} = member_fixture(ctx.owner, :member)
        assert Access.authorize(member, action, own) == {:error, :forbidden}
      end
    end

    test "an invitation is the organisation's, whichever workspace it grants", ctx do
      platform = workspace_fixture(ctx.owner.organisation, "Platform")
      from_platform = workspace_scope(ctx.owner.user, platform)
      %{invitation: invitation} = invitation_fixture(from_platform)

      # Asked from Main, of an invitation granting Platform.
      assert ctx.owner.workspace.id != platform.id
      assert Access.authorize(ctx.owner, :"invitation.revoke", invitation) == :ok
      assert Access.authorize(ctx.admin, :"invitation.revoke", invitation) == :ok
    end

    # The instance actions are left out: they are the instance admins', owners of the
    # instance's organisation, which the rows ask (`Apiary.AccessRows`).
    test "an admin reaches none of the core's owner-only actions", ctx do
      owner_only =
        Enum.filter(
          Access.roles().owner -- Access.roles().admin,
          &(&1 in Apiary.AccessCase.actions(:core) and not Access.action(&1).instance)
        )

      assert Enum.sort(owner_only) ==
               Enum.sort([
                 :"member.change_level",
                 :"organisation.delete",
                 :"organisation.restore",
                 :"security_policy.lock",
                 :"workspace.create"
               ])

      for action <- owner_only do
        assert Access.authorize(ctx.admin, action, ctx.admin.workspace) == {:error, :forbidden}
      end
    end
  end

  describe "the workspaces a person reaches" do
    setup do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{user: admin} = member_fixture(owner, :admin)
      %{owner: owner, second: workspace_fixture(organisation, "Platform"), admin: admin}
    end

    test "a member finds nothing of a workspace until they are added to it", ctx do
      %{user: member, scope: main, membership: membership} = member_fixture(ctx.owner, :member)
      # The member's scope moved to a workspace they were not added to.
      there = %{main | workspace: ctx.second}
      admin = workspace_scope(ctx.admin, ctx.second)

      assert workspace_scope(member, ctx.second) == nil
      assert Access.authorize(there, :"node.read", ctx.second) == {:error, :not_found}
      assert Access.authorize(admin, :"node.read", ctx.second) == :ok

      {:ok, _} = ApiaryPro.WorkspaceAccess.add(ctx.owner, membership.id, ctx.second.id)
      assert Access.authorize(there, :"node.read", ctx.second) == :ok

      assert Access.authorize(workspace_scope(member, ctx.second), :"node.read", ctx.second) ==
               :ok
    end

    test "an owner and an admin reach every workspace", ctx do
      for user <- [ctx.owner.user, ctx.admin] do
        scope = workspace_scope(user, ctx.second)
        assert Access.reaches_every_workspace?(scope.membership.level)
        assert Access.authorize(scope, :"run.read", ctx.second) == :ok
        assert Access.authorize(scope, :"node.read", ctx.second) == :ok
      end
    end
  end

  describe "authorize/3" do
    test "reads the membership again; can?/3 answers from the scope as loaded" do
      %{scope: owner} = sign_up_fixture()
      %{scope: stale, membership: membership} = member_fixture(owner, :owner)

      {:ok, _} = Apiary.Organisations.set_member_level(owner, membership.id, :member)

      assert Access.can?(stale, :"workspace.rename", stale.workspace)
      assert Access.authorize(stale, :"workspace.rename", stale.workspace) == {:error, :forbidden}
      assert Access.authorize(stale, :"node.read", stale.workspace) == :ok

      {:ok, _} = Apiary.Organisations.remove_member(owner, membership.id)

      assert Access.authorize(stale, :"node.read", stale.workspace) ==
               {:error, :forbidden}
    end

    test "reload/1 reads once; check/3 answers from what it read" do
      %{scope: owner} = sign_up_fixture()
      %{scope: stale, membership: membership} = member_fixture(owner, :owner)
      {:ok, _} = Apiary.Organisations.set_member_level(owner, membership.id, :member)

      fresh = Access.reload(stale)
      assert fresh.membership.level == :member
      assert Access.check(fresh, :"workspace.rename", fresh.workspace) == {:error, :forbidden}
      assert Access.check(fresh, :"node.read", fresh.workspace) == :ok
    end

    test "a scope without a user reads no membership and may nothing a role allows" do
      %{scope: owner} = sign_up_fixture()
      userless = %{owner | user: nil}

      assert Access.reload(userless).membership == nil

      assert Access.authorize(userless, :"workspace.rename", userless.workspace) ==
               {:error, :forbidden}

      assert Access.authorize(userless, :"node.read", userless.workspace) ==
               {:error, :forbidden}
    end

    test "a scope without a person may nothing unless it is the instance's" do
      %{scope: owner} = sign_up_fixture()
      nobody = %Scope{organisation: owner.organisation, workspace: owner.workspace}
      instance = Scope.for_instance(owner.organisation, owner.workspace)

      assert Access.reload(instance) == instance
      assert Access.authorize(instance, :"audit.prune", owner.organisation) == :ok
      assert Access.authorize(nobody, :"audit.prune", owner.organisation) == {:error, :forbidden}

      # The mark alone, on a scope that has a person, is no instance.
      marked = %{owner | instance: true}
      assert Access.authorize(marked, :"audit.prune", owner.organisation) == {:error, :forbidden}

      for action <- Access.actions() -- Access.roles().instance do
        refute Access.can?(instance, action, owner.workspace), "the instance may #{action}"
      end
    end

    test "without a scope, nothing" do
      for action <- Access.actions() do
        refute Access.can?(nil, action, nil)
        assert {:error, _reason} = Access.authorize(nil, action, nil)
      end
    end
  end

  describe "the instance's admins" do
    # The instance actions, answered in their order: the feature, asked of the instance;
    # the instance step; the edition; the place; the role.
    setup do
      admin = instance_admin_scope()
      %{scope: owner} = sign_up_fixture()

      %{
        admin: admin,
        instance: admin.organisation,
        owner: owner,
        inner_admin: member_fixture(admin, :admin).scope,
        # The instance admin, asking from an organisation they joined.
        elsewhere: join_fixture(owner, admin.user).scope
      }
    end

    test "outside the instance's organisation, not found; inside it without the role, forbidden",
         ctx do
      action = :"instance.rename"

      assert Access.authorize(ctx.owner, action, ctx.owner.organisation) == {:error, :not_found}
      assert Access.authorize(ctx.owner, action, ctx.instance) == {:error, :not_found}
      assert Access.authorize(ctx.elsewhere, action, ctx.instance) == {:error, :not_found}
      assert Access.authorize(ctx.inner_admin, action, ctx.instance) == {:error, :forbidden}
      assert Access.authorize(ctx.admin, action, ctx.instance) == :ok

      # Asked of anything but the instance's organisation, not found.
      assert Access.authorize(ctx.admin, action, ctx.admin.workspace) == {:error, :not_found}
      assert Access.authorize(ctx.admin, action, ctx.owner.organisation) == {:error, :not_found}
    end

    test "the instance's organisation marked for deletion is not found", ctx do
      organisation = %{ctx.instance | deletion_marked_at: DateTime.utc_now(:second)}
      marked = %{ctx.admin | organisation: organisation}
      assert Access.check(marked, :"instance.rename", marked.organisation) == {:error, :not_found}
    end

    test "the feature is asked of the instance, never what is hidden from the person", ctx do
      hidden = %{ctx.admin | hidden: [:factory, :observability]}
      assert Access.check(hidden, :"instance.read_factory", ctx.instance) == :ok
      assert Access.check(hidden, :"instance.read_observability", ctx.instance) == :ok
    end

    test "the instance's scope makes a password link of an account in use, and nothing else",
         ctx do
      instance = Scope.for_instance(ctx.instance)
      account = ctx.owner.user

      assert Access.authorize(instance, :"account.password_link", account) == :ok
      assert Access.authorize(ctx.admin, :"account.password_link", account) == :ok

      deleted = %{account | deleted_at: DateTime.utc_now(:second)}

      assert Access.authorize(instance, :"account.password_link", deleted) ==
               {:error, :not_found}

      assert Access.authorize(instance, :"instance.rename", ctx.instance) == {:error, :forbidden}
    end

    test "only the instance admin who saved the mail settings resends their test link or turns mail on",
         ctx do
      settings = %Apiary.Mail.Settings{mail_saved_by_id: ctx.admin.user.id}
      %{scope: second} = member_fixture(ctx.admin, :owner)
      instance = Scope.for_instance(ctx.instance)

      for action <- [:"instance.mail_resend", :"instance.mail_on"] do
        assert Access.authorize(ctx.admin, action, settings) == :ok
        assert Access.authorize(second, action, settings) == {:error, :not_saver}

        assert Access.authorize(ctx.admin, action, %Apiary.Mail.Settings{}) ==
                 {:error, :not_saver}

        # The role, the instance step and the place answer first.
        assert Access.authorize(ctx.inner_admin, action, settings) == {:error, :forbidden}
        assert Access.authorize(instance, action, settings) == {:error, :forbidden}
        assert Access.authorize(ctx.owner, action, settings) == {:error, :not_found}
        assert Access.authorize(ctx.elsewhere, action, settings) == {:error, :not_found}
        assert Access.authorize(ctx.admin, action, ctx.instance) == {:error, :not_found}
      end
    end

    test "nobody makes a password link of the account they are signed in with; the instance may",
         ctx do
      %{scope: second} = member_fixture(ctx.admin, :owner)
      action = :"account.password_link"

      assert Access.authorize(ctx.admin, action, ctx.admin.user) == {:error, :own_account}
      assert Access.check(ctx.admin, action, ctx.admin.user) == {:error, :own_account}
      assert Access.authorize(second, action, ctx.admin.user) == :ok
      assert Access.authorize(Scope.for_instance(ctx.instance), action, ctx.admin.user) == :ok

      # The role answers first.
      assert Access.authorize(ctx.inner_admin, action, ctx.inner_admin.user) ==
               {:error, :forbidden}
    end

    test "in_instance/1 and instance_scope/1 move a person into the instance's organisation",
         ctx do
      moved = Access.in_instance(ctx.elsewhere)
      assert moved.organisation.id == ctx.instance.id
      assert moved.workspace == nil
      assert Access.authorize(moved, :"instance.rename", ctx.instance) == :ok

      assert {:ok, %Scope{organisation: %Organisation{id: id}}} =
               Access.instance_scope(ctx.elsewhere)

      assert id == ctx.instance.id

      # Someone who does not reach the instance's organisation is moved nowhere.
      assert %Scope{organisation: nil, membership: nil} = Access.in_instance(ctx.owner)
      assert Access.instance_scope(ctx.owner) == :error
      assert Access.instance_scope(ctx.inner_admin) == :error
      assert Access.instance_scope(nil) == :error
      assert Access.in_instance(nil) == nil
    end

    test "instance_admin?/1 answers as instance.read in the instance's organisation, now",
         ctx do
      assert Access.instance_admin?(ctx.admin)
      assert Access.instance_admin?(ctx.elsewhere)
      refute Access.instance_admin?(ctx.inner_admin)
      refute Access.instance_admin?(ctx.owner)
      refute Access.instance_admin?(Scope.for_instance(ctx.instance))
      refute Access.instance_admin?(nil)

      # A second owner, an instance admin until made a member.
      %{scope: second, membership: membership} = member_fixture(ctx.admin, :owner)
      assert Access.instance_admin?(second)

      {:ok, _} = Apiary.Organisations.set_member_level(ctx.admin, membership.id, :member)
      refute Access.instance_admin?(second)
      # The scope as loaded still carries owner: a page follows by the broadcast.
      assert Access.can?(second, :"instance.rename", ctx.instance)
      assert Access.authorize(second, :"instance.rename", ctx.instance) == {:error, :forbidden}
    end

    test "can?/3 on an instance action runs no query in the scope of in_instance/1", ctx do
      moved = Access.in_instance(ctx.elsewhere)
      assert moved.instance_organisation_id == ctx.instance.id

      {:ok, page} = Access.instance_scope(ctx.elsewhere)
      assert page.instance_organisation_id == ctx.instance.id

      assert queries_during(fn ->
               for scope <- [moved, moved, page, page] do
                 assert Access.can?(scope, :"instance.read", ctx.instance)
               end

               refute Access.can?(moved, :"instance.read", ctx.owner.organisation)
             end) == []
    end

    test "can?/3 on an instance action reads the id once in any other scope", ctx do
      assert ctx.admin.instance_organisation_id == nil

      assert [_read] =
               queries_during(fn ->
                 assert Access.can?(ctx.admin, :"instance.read", ctx.instance)
               end)
    end

    test "authorize/3 compares with the instance organisation's id read now", ctx do
      subject = ctx.owner.organisation

      # As if the owner's organisation had been the instance's when the scope was loaded.
      moved_away = %{ctx.owner | instance_organisation_id: subject.id}
      assert Access.can?(moved_away, :"instance.read", subject)
      assert Access.authorize(moved_away, :"instance.read", subject) == {:error, :not_found}

      # As if the instance's organisation had been another when the scope was loaded.
      moved_here = %{ctx.admin | instance_organisation_id: subject.id}
      refute Access.can?(moved_here, :"instance.read", ctx.instance)
      assert Access.authorize(moved_here, :"instance.read", ctx.instance) == :ok
    end

    test "reload/2 clears the id in every scope it returns", ctx do
      id = ctx.instance.id
      %{access_key: key} = access_key_fixture(ctx.admin)

      for scope <- [
            ctx.admin,
            Scope.for_instance(ctx.instance),
            Scope.for_user(ctx.admin.user),
            Scope.for_access_key(key)
          ] do
        stale = %{scope | instance_organisation_id: id}
        assert Access.reload(stale).instance_organisation_id == nil

        assert {:ok, %Scope{instance_organisation_id: nil}} =
                 Apiary.Repo.transact(fn -> {:ok, Access.reload(stale, lock: :share)} end)
      end
    end

    test "a held scope keeps the id after another organisation becomes the instance's", ctx do
      organisation = ctx.owner.organisation

      # The owner's organisation made the instance's, by its tenant's flag, then the
      # suite's again.
      Apiary.EditionKit.module().hide_instance_organisation(ctx.instance.id)
      Apiary.EditionKit.show_instance_organisation(organisation.id)
      {:ok, held} = Access.instance_scope(ctx.owner)
      assert held.instance_organisation_id == organisation.id

      Apiary.EditionKit.module().hide_instance_organisation(organisation.id)
      Apiary.EditionKit.show_instance_organisation(ctx.instance.id)
      assert Apiary.Edition.instance_organisation_id() == ctx.instance.id

      assert Access.can?(held, :"instance.read", held.organisation)
      assert Access.authorize(held, :"instance.read", held.organisation) == {:error, :not_found}
      assert Access.instance_scope(ctx.owner) == :error
    end

    test "a scope moved to another organisation has no id", ctx do
      moved = Access.in_instance(ctx.elsewhere)
      assert moved.instance_organisation_id == ctx.instance.id
      elsewhere = ctx.owner.organisation

      assert {:ok, reached} = Apiary.Organisations.put_reach(moved, elsewhere)
      assert reached.organisation.id == elsewhere.id
      assert reached.instance_organisation_id == nil

      assert Scope.in_organisation(moved, elsewhere).instance_organisation_id == nil

      loaded = Apiary.Organisations.load_scope(moved, elsewhere.id)
      assert loaded.organisation.id == elsewhere.id
      assert loaded.instance_organisation_id == nil
    end

    test "an invitation's acceptance passes the edition a scope with no id", ctx do
      moved = Access.in_instance(ctx.elsewhere)
      assert moved.instance_organisation_id == ctx.instance.id

      %{scope: inviter, organisation: organisation} = sign_up_fixture()
      %{token: token} = invitation_fixture(inviter, %{"email" => moved.user.email})
      :ok = Apiary.Edition.put_test_stub(SendsAcceptedScope)

      assert {:ok, _membership} = Apiary.Organisations.accept_invitation(moved, token)

      assert_received {:accepted_in, %Scope{instance_organisation_id: nil} = here}
      assert here.organisation.id == organisation.id
    end

    test "a person in another organisation takes no instance action", ctx do
      action = :"instance.read"
      elsewhere = ctx.owner.organisation

      refute Access.can?(ctx.owner, action, ctx.instance)
      refute Access.can?(ctx.owner, action, elsewhere)

      # Not reached: no place and no id, whatever the scope had before.
      stale = %{ctx.owner | instance_organisation_id: elsewhere.id}
      assert %Scope{organisation: nil, instance_organisation_id: nil} = Access.in_instance(stale)
      refute Access.can?(Access.in_instance(stale), action, ctx.instance)

      # An instance admin's scope moved out of the instance's organisation.
      {:ok, moved} = Apiary.Organisations.put_reach(Access.in_instance(ctx.elsewhere), elsewhere)
      refute Access.can?(moved, action, ctx.instance)
      refute Access.can?(moved, action, elsewhere)

      # Inside the organisation, the role still decides.
      refute Access.can?(Access.in_instance(ctx.inner_admin), action, ctx.instance)
    end
  end

  describe "a part of a feature" do
    test "run.read_log belongs to the run's Terminal, a part of observability" do
      assert %Apiary.Access.Action{feature: :observability, part: :"observability.terminal"} =
               Access.action(:"run.read_log")

      for action <- Access.actions(), %{part: part} = Access.action(action), part do
        assert Apiary.Features.feature_of(part) == Access.feature(action), inspect(action)
      end
    end

    test "hidden, it hides its actions and no other of the feature; its hidden feature too" do
      %{scope: owner} = sign_up_fixture()
      run = run_fixture(owner)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)

      for {hidden, read_log, read} <- [
            {[], :ok, :ok},
            {[:"observability.terminal"], {:error, :not_found}, :ok},
            {[:observability], {:error, :not_found}, {:error, :not_found}}
          ] do
        :ok = Apiary.EditionStubs.HidesNamed.put(hidden)
        scope = Access.reload(owner)

        assert Access.check(scope, :"run.read_log", run) == read_log, inspect(hidden)
        assert Access.authorize(owner, :"run.read_log", run) == read_log, inspect(hidden)
        assert Access.can?(scope, :"run.read_log", run) == (read_log == :ok)
        assert Access.check(scope, :"run.read", run) == read, inspect(hidden)
      end

      # An access key, and the instance, are never asked what is hidden.
      :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])
      instance = Scope.for_instance(owner.organisation, owner.workspace)
      assert Access.check(instance, :"run.read_log", run) == {:error, :forbidden}
    end

    test "the registry refuses an action whose part is not one of its feature's" do
      action = &Apiary.Access.Action.new(:"report.read", "read a report", &1)

      assert %{names: names} =
               Access.build_registry(
                 [action.(feature: :observability, part: :"observability.terminal")],
                 %{}
               )

      assert :"report.read" in names

      for opts <- [
            [feature: :security, part: :"observability.terminal"],
            [part: :"observability.terminal"],
            [feature: :observability, part: :terminal],
            [feature: :observability, part: :observability]
          ] do
        assert_raise ArgumentError, ~r/report.read belongs to the part/, fn ->
          Access.build_registry([action.(opts)], %{})
        end
      end

      assert_raise ArgumentError, ~r/report.read's part is "terminal"/, fn ->
        action.(feature: :observability, part: "terminal")
      end
    end
  end

  describe "the part of no feature, nodes" do
    @nodes_actions [
      :"access_key.create_code",
      :"access_key.cancel_code",
      :"access_key.add",
      :"access_key.revoke",
      :"node.read",
      :"node.create",
      :"node.edit",
      :"node.set_limit",
      :"node.delete",
      :"node.clear_instance"
    ]

    test "every action of the nodes and their access keys belongs to it, and no other" do
      for action <- Access.actions() do
        if action in @nodes_actions do
          assert %Apiary.Access.Action{feature: nil, part: :nodes} = Access.action(action)
          assert Access.shown_as(action) == :nodes
        else
          refute Access.action(action).part == :nodes, inspect(action)
        end
      end

      assert Access.shown_as(:"run.read_log") == :"observability.terminal"
      assert Access.shown_as(:"run.read") == :observability
      assert Access.shown_as(:"workspace.rename") == nil
    end

    test "hidden from a person, its actions are not found and nothing else is" do
      %{scope: owner} = sign_up_fixture()
      %{access_key: key, node: node} = access_key_fixture(owner)
      run = run_fixture(owner)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)

      subjects = [owner.workspace, owner.organisation, node, key]

      :ok = Apiary.EditionStubs.HidesNamed.put([])
      shown = Access.reload(owner)

      answers =
        for a <- @nodes_actions, s <- subjects, into: %{}, do: {{a, s}, Access.check(shown, a, s)}

      assert answers[{:"node.read", owner.workspace}] == :ok
      assert answers[{:"access_key.revoke", key}] == :ok

      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      scope = Access.reload(owner)
      assert scope.hidden == [:nodes]

      for action <- @nodes_actions, subject <- subjects do
        assert Access.check(scope, action, subject) == {:error, :not_found}, inspect(action)
        assert Access.authorize(owner, action, subject) == {:error, :not_found}
        refute Access.can?(scope, action, subject)
      end

      assert Access.check(scope, :"run.read", run) == :ok
      assert Access.check(scope, :"run.read_log", run) == :ok
      assert Access.check(scope, :"workspace.rename", owner.workspace) == :ok

      # Shown again, every answer is as it was.
      :ok = Apiary.EditionStubs.HidesNamed.put([])
      shown = Access.reload(owner)

      for {{action, subject}, answer} <- answers,
          do: assert(Access.check(shown, action, subject) == answer)

      # An access key, and the instance, are never asked what is hidden.
      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])
      instance = Scope.for_instance(owner.organisation, owner.workspace)
      key_scope = Scope.for_access_key(key)

      for action <- @nodes_actions do
        assert Access.check(%{instance | hidden: [:nodes]}, action, owner.workspace) ==
                 Access.check(instance, action, owner.workspace)

        assert Access.check(%{key_scope | hidden: [:nodes]}, action, owner.workspace) ==
                 Access.check(key_scope, action, owner.workspace)
      end

      assert Access.check(key_scope, :"run.post_events", owner.workspace) == :ok
      assert Access.check(key_scope, :"run_configuration.fetch", owner.workspace) == :ok
    end

    test "check_code_maker/2 answers as check/3 but never asks what is shown" do
      %{scope: owner} = sign_up_fixture()
      member = member_fixture(owner, :member).scope
      node = node_fixture(owner)
      {:ok, code, _secret} = Apiary.AccessKeys.create_enrolment_code(owner, node, %{})
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:nodes])

      owner = Access.reload(owner)
      member = Access.reload(member)
      other = Access.reload(sign_up_fixture().scope)

      assert Access.check(owner, :"access_key.create_code", code) == {:error, :not_found}
      assert Access.check_code_maker(owner, code) == :ok
      assert Access.check_code_maker(member, code) == {:error, :forbidden}
      assert Access.check_code_maker(other, code) == {:error, :not_found}
    end

    test "the registry takes the part of no feature only on an action of no feature" do
      action = &Apiary.Access.Action.new(:"report.read", "read a report", &1)

      assert %{names: names} = Access.build_registry([action.(part: :nodes)], %{})
      assert :"report.read" in names

      for opts <- [
            [feature: :observability, part: :nodes],
            [feature: :security, part: :nodes]
          ] do
        assert_raise ArgumentError, ~r/report.read belongs to the part :nodes/, fn ->
          Access.build_registry([action.(opts)], %{})
        end
      end

      assert_raise ArgumentError,
                   ~r/report.read belongs to the part :"observability.terminal", no part an action of no feature may have/,
                   fn ->
                     Access.build_registry([action.(part: :"observability.terminal")], %{})
                   end
    end
  end

  describe "a comment's author" do
    # Deleting a comment on a work item: an owner or an admin deletes any, and its author
    # theirs, while they may still comment. Asked of the comment, a row of the workspace
    # with its author.
    @describetag needs: :factory

    setup do
      %{scope: owner} = sign_up_fixture()
      author = member_fixture(owner, :member)
      other = member_fixture(owner, :member)
      admin = member_fixture(owner, :admin)
      %{owner: owner, author: author, other: other, admin: admin}
    end

    defp comment(scope, author_id) do
      %{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        author_id: author_id
      }
    end

    test "deletes their comment, and nobody else's", ctx do
      theirs = comment(ctx.owner, ctx.author.user.id)
      others = comment(ctx.owner, ctx.other.user.id)

      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", theirs) == :ok

      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", others) ==
               {:error, :forbidden}

      # A member deletes no comment asked of the workspace alone: the role answers.
      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", ctx.owner.workspace) ==
               {:error, :forbidden}

      for scope <- [ctx.owner, ctx.admin.scope] do
        assert Access.authorize(scope, :"work_item.comment_delete", others) == :ok
      end
    end

    test "deletes it no more once they may not comment", ctx do
      theirs = comment(ctx.owner, ctx.author.user.id)
      {:ok, _} = Apiary.Organisations.remove_member(ctx.owner, ctx.author.membership.id)

      refute Access.authorize(ctx.author.scope, :"work_item.comment_delete", theirs) == :ok
    end

    test "a comment of another organisation is not found, even with their id on it", ctx do
      %{scope: elsewhere} = sign_up_fixture()
      theirs = comment(elsewhere, ctx.author.user.id)

      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", theirs) ==
               {:error, :not_found}
    end

    test "a comment row is where its workspace is, and of another workspace is not found",
         ctx do
      %{organisation: %{id: organisation_id}, workspace: %{id: workspace_id}} = ctx.owner

      row = %Apiary.WorkItems.Comment{
        organisation_id: organisation_id,
        workspace_id: workspace_id,
        author_id: ctx.author.user.id
      }

      assert Access.place(row) == {organisation_id, workspace_id}
      assert Access.check_place(ctx.owner, :"work_item.comment_delete", row) == :ok
      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", row) == :ok

      elsewhere = workspace_fixture(ctx.owner.organisation)
      there = %{row | workspace_id: elsewhere.id}

      assert Access.check_place(ctx.author.scope, :"work_item.comment_delete", there) ==
               {:error, :not_found}

      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", there) ==
               {:error, :not_found}
    end

    test "where the feature is hidden from them, it is not found", ctx do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])
      theirs = comment(ctx.owner, ctx.author.user.id)

      assert Access.authorize(ctx.author.scope, :"work_item.comment_delete", theirs) ==
               {:error, :not_found}
    end
  end

  # The queries this process runs during `fun`, counted on the repo's telemetry event.
  defp queries_during(fun) do
    handler = "access-queries-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == parent, do: send(parent, {:access_query, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_queries([])
  end

  defp collect_queries(acc) do
    receive do
      {:access_query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
