defmodule ApiaryPro.OrganisationsTest do
  # What the edition's workspace access changes of the core's organisations
  # (`Apiary.OrganisationsTest`): a member reaches the workspaces they were added to, from
  # the invitation's on, and no other; an owner and an admin reach every workspace, with
  # no row.
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Membership
  alias ApiaryPro.WorkspaceAccess

  describe "sign_up_user/2" do
    test "an owner who signed up reaches every workspace, and is added to none" do
      %{user: user} = sign_up_fixture()
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)
    end

    test "with a valid invitation token adds the member to the workspace it was sent from" do
      %{scope: scope, workspace: workspace} = sign_up_fixture()
      %{invitation: invitation, token: token} = invitation_fixture(scope)

      {:ok, result} = Organisations.sign_up_user(%{email: invitation.email}, token)

      # The invitation was sent from the workspace, and grants it.
      assert [%WorkspaceAccess.Row{workspace_id: workspace_id}] =
               Repo.all(from a in WorkspaceAccess.Row, where: a.user_id == ^result.user.id)

      assert workspace_id == workspace.id
    end
  end

  describe "load_scope/2 of a member" do
    test "loads the workspace the member was added to, with their workspace access" do
      %{scope: owner_scope} = sign_up_fixture()
      %{scope: scope, user: user} = member_fixture(owner_scope, :member)

      assert scope.workspace.id == owner_scope.workspace.id

      assert %WorkspaceAccess.Row{user_id: user_id, workspace_id: workspace_id} =
               WorkspaceAccess.of(scope)

      assert user_id == user.id
      assert workspace_id == owner_scope.workspace.id
    end

    test "loads no workspace for a member added to none" do
      %{scope: owner_scope} = sign_up_fixture()
      %{user: user, membership: membership} = member_fixture(owner_scope, :member)

      {:ok, _} =
        WorkspaceAccess.remove(
          owner_scope,
          membership.id,
          owner_scope.workspace.id
        )

      scope = Organisations.load_scope(Scope.for_user(user))
      assert scope.organisation.id == owner_scope.organisation.id
      assert scope.membership.id == membership.id
      assert scope.workspace == nil
      assert WorkspaceAccess.of(scope) == nil
    end
  end

  describe "resolve_scope/4 and the workspaces a member reaches" do
    setup do
      %{scope: owner_scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      %{user: member, membership: membership} = member_fixture(owner_scope, :member)
      %{user: admin} = reaching_every_workspace(owner_scope, :admin)

      %{
        owner: owner_scope.user,
        owner_scope: owner_scope,
        organisation: organisation,
        first: owner_scope.workspace,
        second: second,
        member: member,
        membership: membership,
        admin: admin
      }
    end

    test "an owner and an admin reach every workspace, with no workspace access", ctx do
      for user <- [ctx.owner, ctx.admin], workspace <- [ctx.first, ctx.second] do
        assert {:ok, scope} =
                 Organisations.resolve_scope(
                   Scope.for_user(user),
                   ctx.organisation.slug,
                   workspace.slug
                 )

        assert scope.workspace.id == workspace.id
        assert WorkspaceAccess.of(scope) == nil
      end

      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^ctx.admin.id)
    end

    test "a member reaches the workspaces they were added to, and no other", ctx do
      assert {:ok, scope} =
               Organisations.resolve_scope(
                 Scope.for_user(ctx.member),
                 ctx.organisation.slug,
                 ctx.first.slug
               )

      assert WorkspaceAccess.of(scope).workspace_id == ctx.first.id

      # One answer for a workspace they do not reach and one that does not exist.
      assert :error =
               Organisations.resolve_scope(
                 Scope.for_user(ctx.member),
                 ctx.organisation.slug,
                 ctx.second.slug
               )

      assert {:ok, _access} =
               WorkspaceAccess.add(
                 ctx.owner_scope,
                 ctx.membership.id,
                 ctx.second.id
               )

      assert {:ok, %{workspace: %{id: id}}} =
               Organisations.resolve_scope(
                 Scope.for_user(ctx.member),
                 ctx.organisation.slug,
                 ctx.second.slug
               )

      assert id == ctx.second.id
    end

    test "a member is not sent to a workspace they do not reach, whatever the session says",
         ctx do
      assert {:ok, %{workspace: %{id: member_id}}} =
               Organisations.resolve_scope(Scope.for_user(ctx.member), ctx.organisation.slug, nil,
                 last_workspace: ctx.second.id
               )

      assert member_id == ctx.first.id
    end

    test "a member added to no workspace opens the organisation, with no workspace", ctx do
      {:ok, _} =
        WorkspaceAccess.remove(ctx.owner_scope, ctx.membership.id, ctx.first.id)

      assert {:ok, scope} =
               Organisations.resolve_scope(Scope.for_user(ctx.member), ctx.organisation.slug)

      assert scope.organisation.id == ctx.organisation.id
      assert scope.membership.id == ctx.membership.id
      assert scope.workspace == nil

      assert :error =
               Organisations.resolve_scope(
                 Scope.for_user(ctx.member),
                 ctx.organisation.slug,
                 ctx.first.slug
               )
    end

    test "list_memberships/1 carries the workspaces a member reaches, with their workspace access",
         ctx do
      assert [%Membership{workspaces: [only], edition: %{workspace_access: [access]}}] =
               Organisations.list_memberships(ctx.member)

      assert only.id == ctx.first.id
      assert access.workspace_id == ctx.first.id
    end
  end

  describe "members" do
    test "list_members/1 names only the workspaces the reader reaches" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      %{membership: added} = member_fixture(scope, :member)
      %{scope: reader_scope} = member_fixture(scope, :member)
      {:ok, _} = WorkspaceAccess.add(scope, added.id, second.id)

      as_owner = scope |> Organisations.list_members() |> Enum.find(&(&1.id == added.id))
      assert Enum.map(as_owner.workspaces, & &1.id) == [scope.workspace.id, second.id]

      as_member = reader_scope |> Organisations.list_members() |> Enum.find(&(&1.id == added.id))
      assert Enum.map(as_member.workspaces, & &1.id) == [scope.workspace.id]
    end

    test "a member's workspace access goes with their membership" do
      %{scope: scope} = sign_up_fixture()
      %{membership: membership} = member_fixture(scope, :member)
      assert Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^membership.user_id)

      assert {:ok, %Membership{}} = Organisations.remove_member(scope, membership.id)
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^membership.user_id)
    end
  end

  describe "demotion" do
    test "an owner made a member keeps the workspace access they have" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      %{membership: promoted, user: user} = member_fixture(scope, :member)
      {:ok, _} = Organisations.set_member_level(scope, promoted.id, :owner)
      # Added while an owner, a row that changes nothing until they are demoted.
      {:ok, _} = WorkspaceAccess.add(scope, promoted.id, second.id)

      {:ok, _} = Organisations.set_member_level(scope, promoted.id, :member)

      assert [scope.workspace.id, second.id] |> Enum.sort() ==
               Repo.all(
                 from a in WorkspaceAccess.Row,
                   where: a.user_id == ^user.id,
                   select: a.workspace_id
               )
               |> Enum.sort()

      refute Repo.exists?(
               from e in Entry,
                 where:
                   e.action == "workspace_access.add" and
                     fragment("?->>'reason'", e.details) == "demoted"
             )
    end

    test "an owner or an admin made a member without workspace access is added to the workspace it was made from" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      owner_scope_in_second = workspace_scope(scope.user, second)

      for level <- [:owner, :admin] do
        %{membership: membership, user: user} = reaching_every_workspace(scope, level)
        refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)

        {:ok, _} = Organisations.set_member_level(owner_scope_in_second, membership.id, :member)

        assert [%WorkspaceAccess.Row{workspace_id: workspace_id} = access] =
                 Repo.all(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)

        assert workspace_id == second.id

        assert [entry] =
                 Repo.all(
                   from e in Entry,
                     where: e.action == "workspace_access.add" and e.subject_id == ^access.id
                 )

        assert entry.workspace_id == second.id
        assert entry.details == %{"user_id" => user.id, "reason" => "demoted"}

        # They reach it, and not the other.
        assert workspace_scope(user, second)
        refute workspace_scope(user, scope.workspace)
      end
    end

    test "an owner made an admin keeps reaching every workspace, with no row added" do
      %{scope: scope} = sign_up_fixture()
      %{membership: membership, user: user} = reaching_every_workspace(scope, :owner)

      {:ok, _} = Organisations.set_member_level(scope, membership.id, :admin)
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)
      assert workspace_scope(user, scope.workspace)
    end
  end

  describe "workspace access" do
    setup do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      %{membership: membership, user: user} = member_fixture(scope, :member)
      %{scope: admin_scope, membership: admin} = member_fixture(scope, :admin)
      %{scope: member_scope} = member_fixture(scope, :member)

      %{
        scope: scope,
        second: second,
        membership: membership,
        user: user,
        admin_scope: admin_scope,
        admin: admin,
        member_scope: member_scope
      }
    end

    test "an owner adds a member to a workspace and removes them, each with an entry", ctx do
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(ctx.user.id))
      organisation_id = ctx.scope.organisation.id

      assert {:ok, %WorkspaceAccess.Row{} = added} =
               WorkspaceAccess.add(ctx.scope, ctx.membership.id, ctx.second.id)

      assert added.workspace_id == ctx.second.id
      assert added.user_id == ctx.user.id
      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}
      assert workspace_scope(ctx.user, ctx.second)

      assert [entry] = Repo.all(from e in Entry, where: e.action == "workspace_access.add")
      assert entry.actor_id == ctx.scope.user.id
      assert entry.subject_kind == "workspace_access"
      assert entry.subject_id == added.id
      assert entry.workspace_id == ctx.second.id
      assert entry.details == %{"user_id" => ctx.user.id}

      # Added again, nothing changes and nothing is recorded.
      assert {:ok, %WorkspaceAccess.Row{id: id}} =
               WorkspaceAccess.add(ctx.scope, ctx.membership.id, ctx.second.id)

      assert id == added.id

      assert Repo.aggregate(from(e in Entry, where: e.action == "workspace_access.add"), :count) ==
               1

      assert {:ok, %WorkspaceAccess.Row{}} =
               WorkspaceAccess.remove(ctx.scope, ctx.membership.id, ctx.second.id)

      assert_receive {:membership_changed, %{organisation_id: ^organisation_id}}
      refute workspace_scope(ctx.user, ctx.second)
      # Still a member of the organisation, in the workspace they were invited to.
      assert Repo.get(Membership, ctx.membership.id)
      assert workspace_scope(ctx.user, ctx.scope.workspace)

      assert [entry] = Repo.all(from e in Entry, where: e.action == "workspace_access.remove")
      assert entry.subject_id == added.id
      assert entry.workspace_id == ctx.second.id
      assert entry.details == %{"user_id" => ctx.user.id}

      assert {:error, :not_found} =
               WorkspaceAccess.remove(ctx.scope, ctx.membership.id, ctx.second.id)
    end

    test "an admin adds and removes members, and neither an owner nor an admin", ctx do
      assert {:ok, _} =
               WorkspaceAccess.add(
                 ctx.admin_scope,
                 ctx.membership.id,
                 ctx.second.id
               )

      assert {:ok, _} =
               WorkspaceAccess.remove(
                 ctx.admin_scope,
                 ctx.membership.id,
                 ctx.second.id
               )

      %{membership: owner} = sign_up_owner(ctx.scope)

      for target <- [owner, ctx.admin] do
        assert {:error, :forbidden} =
                 WorkspaceAccess.add(ctx.admin_scope, target.id, ctx.second.id)

        assert {:error, :forbidden} =
                 WorkspaceAccess.remove(ctx.admin_scope, target.id, ctx.second.id)
      end
    end

    test "adding a person who has left is not found, and nothing is written", ctx do
      {:ok, _} = Organisations.remove_member(ctx.scope, ctx.membership.id)

      assert {:error, :not_found} =
               WorkspaceAccess.add(ctx.scope, ctx.membership.id, ctx.second.id)

      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^ctx.user.id)
    end

    test "adding reads the membership FOR SHARE, so its removal waits for the row", ctx do
      handler = "membership-share-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent, do: send(parent, {:query, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} = WorkspaceAccess.add(ctx.scope, ctx.membership.id, ctx.second.id)

      queries = collect_queries()
      [first_membership_read | _] = Enum.filter(queries, &(&1 =~ ~s(FROM "memberships")))
      assert first_membership_read =~ "FOR SHARE"
    end

    test "a member adds and removes nobody", ctx do
      assert {:error, :forbidden} =
               WorkspaceAccess.add(
                 ctx.member_scope,
                 ctx.membership.id,
                 ctx.second.id
               )

      assert {:error, :forbidden} =
               WorkspaceAccess.remove(
                 ctx.member_scope,
                 ctx.membership.id,
                 ctx.scope.workspace.id
               )

      refute workspace_scope(ctx.user, ctx.second)
      refute Repo.exists?(from e in Entry, where: like(e.action, "workspace_access.%"))
    end

    test "a membership or a workspace of another organisation is not found", ctx do
      %{scope: other_scope, membership: other_membership, workspace: other_workspace} =
        sign_up_fixture()

      assert {:error, :not_found} =
               WorkspaceAccess.add(
                 ctx.scope,
                 ctx.membership.id,
                 other_workspace.id
               )

      assert {:error, :not_found} =
               WorkspaceAccess.add(ctx.scope, other_membership.id, ctx.second.id)

      assert {:error, :not_found} =
               WorkspaceAccess.add(ctx.scope, ctx.membership.id, "not-a-uuid")

      # A row of this organisation is not reachable through a scope of another.
      assert {:error, :not_found} =
               WorkspaceAccess.remove(
                 other_scope,
                 ctx.membership.id,
                 ctx.scope.workspace.id
               )

      assert workspace_scope(ctx.user, ctx.scope.workspace)
    end

    test "a workspace access row names a member of its own organisation only", ctx do
      %{user: stranger, workspace: other_workspace} = sign_up_fixture()

      # No membership of the stranger in this organisation: the key refuses the row.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%WorkspaceAccess.Row{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.second.id,
          user_id: stranger.id
        })
      end

      # Nor may a row name a workspace of another organisation.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%WorkspaceAccess.Row{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: other_workspace.id,
          user_id: ctx.user.id
        })
      end
    end
  end

  describe "invitations" do
    test "accept_invitation/2 adds a member to the workspace the invitation was sent from" do
      %{scope: scope} = sign_up_fixture()
      %{token: token} = invitation_fixture(scope)
      user = user_fixture()

      assert {:ok, %Membership{level: :member}} = Organisations.accept_invitation(user, token)

      assert [%WorkspaceAccess.Row{workspace_id: workspace_id}] =
               Repo.all(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)

      assert workspace_id == scope.workspace.id
    end

    test "accepting an invitation sent from a workspace grants a member that workspace" do
      %{scope: scope, organisation: organisation} = sign_up_fixture()
      second = workspace_fixture(organisation, "Platform")
      from_second = workspace_scope(scope.user, second)
      %{token: token, invitation: invitation} = invitation_fixture(from_second)
      assert invitation.workspace_id == second.id
      user = user_fixture()

      assert {:ok, %Membership{level: :member}} = Organisations.accept_invitation(user, token)

      assert [%WorkspaceAccess.Row{workspace_id: workspace_id}] =
               Repo.all(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)

      assert workspace_id == second.id
      assert workspace_scope(user, second)
      refute workspace_scope(user, scope.workspace)

      assert [entry] = Repo.all(from e in Entry, where: e.action == "invitation.accept")
      assert entry.workspace_id == second.id
    end
  end

  # A person invited, and made `level`, which reaches every workspace, then removed from
  # the workspace they joined through the invitation: they hold no workspace access, as an
  # owner who signed up holds none.
  defp reaching_every_workspace(scope, level) do
    signed_up = member_fixture(scope, level)

    {:ok, _} =
      WorkspaceAccess.remove(scope, signed_up.membership.id, scope.workspace.id)

    signed_up
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A second owner of the scope's organisation, invited as one.
  defp sign_up_owner(scope), do: member_fixture(scope, :owner)
end
