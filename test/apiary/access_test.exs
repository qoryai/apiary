defmodule Apiary.AccessTest do
  # Not async: the rows of a feature switched off switch the features of the whole node.
  # Who may take each of the core's actions is the core's rows (`Apiary.AccessRows`),
  # asked by `Apiary.AccessCase` with the rows of the edition's kit where the edition
  # changes what the core's actors may; what follows asks what the rows do not.
  use Apiary.AccessCase, rows: [Apiary.AccessRows], covers: :core

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  # The core's rows as the edition answers them: what the tests below expect of the
  # core's actors.
  @answering Apiary.AccessCase.answering([Apiary.AccessRows])
  @table Apiary.AccessCase.rows(@answering)

  test "an action that is none raises" do
    assert_raise ArgumentError, fn -> Access.can?(nil, :"no.such_action", nil) end
    assert_raise ArgumentError, fn -> Access.authorize(nil, :"no.such_action", nil) end
    assert_raise ArgumentError, fn -> Access.action(:"no.such_action") end
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

  describe "marked for deletion" do
    # A scope loaded before the marking, asked after it: every action is not found, as for
    # an organisation or a workspace that is gone, but cancelling the deletion and the
    # purge, which answer as the table does. An access key of a marked organisation or
    # workspace is refused at its verification, on every request, and asks nothing here.
    @marked_actors [:member, :admin, :owner, :instance]

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

    for mark <- [:organisation, :workspace],
        {action, row} <- @table,
        action in Apiary.AccessCase.actions(:core) do
      @tag mark: mark, action: action, yes: row[:yes]
      test "a marked #{mark}: #{action} is #{if action in Access.on_marked() or Access.action(action).asked_of == :new_organisation, do: "as the table says", else: "not found"}",
           ctx do
        %{mark: mark, action: action, yes: yes} = ctx

        case mark do
          :organisation ->
            {:ok, _} =
              Apiary.Deletion.delete_organisation(ctx.owner, ctx.organisation.slug)

          :workspace ->
            {:ok, _} =
              Apiary.Deletion.delete_workspace(ctx.owner, ctx.workspace.id, ctx.workspace.slug)
        end

        subject = subject(ctx, action)

        for actor <- @marked_actors do
          answer = Access.authorize(ctx.scopes[actor], action, subject)

          cond do
            # A person's own action is asked of no place, marked or not.
            action not in Access.on_marked() and not own?(action) ->
              assert answer == {:error, :not_found}, "#{actor}: #{inspect(answer)}"

            actor in yes ->
              assert answer == :ok, "#{actor}: #{inspect(answer)}"

            true ->
              refusal = Apiary.AccessCase.refusal(@answering, action, actor, subject)
              assert answer == {:error, refusal}, "#{actor}: #{inspect(answer)}"
          end
        end
      end
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
      {:invitation, [:"invitation.revoke"]}
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

      for action <- [:"member.invite", :"invitation.revoke"] do
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
      for action <- [:"member.invite", :"invitation.revoke"] do
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

    test "an admin reaches none of the core's owner-only actions", ctx do
      owner_only =
        Enum.filter(
          Access.roles().owner -- Access.roles().admin,
          &(&1 in Apiary.AccessCase.actions(:core))
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

  # What an action is asked of in `place`, as the rows say: the organisation, the
  # workspace, or a new organisation.
  defp subject(place, action) do
    {^action, row} = List.keyfind(@table, action, 0)

    case Keyword.get(row, :on, Access.action(action).asked_of) do
      :workspace -> place.workspace
      :new_organisation -> %Organisation{}
      _organisation -> place.organisation
    end
  end

  # A person's own action, asked of no place.
  defp own?(action), do: Access.action(action).asked_of == :new_organisation
end
