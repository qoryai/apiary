defmodule Apiary.AuditChanges do
  @moduledoc """
  AuditChanges is the core's module of changes of the audit test (`Apiary.AuditCase`):
  each audited action of the core made the way the product makes it, what it needs
  first, then the trail as it is (`before`), then the change; and the same change
  refused, `{the trail before the attempt, the attempt's answer}`.
  """

  import Apiary.AccessKeysFixtures
  import Apiary.AccountsFixtures, only: [unique_user_email: 0, valid_user_attributes: 1]
  import Apiary.AuditCase, only: [entries: 0, old!: 1, refuse_as_member: 4]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Ecto.Query

  alias Apiary.{
    Access,
    AccessKeys,
    Accounts,
    Audit,
    Deletion,
    Nodes,
    Organisations,
    Policy,
    Repo,
    Retention,
    Runs,
    Secrets,
    Variables
  }

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation, Workspace}

  @doc "actions/0 is the core's audited actions, each made and refused below."
  @spec actions() :: [Access.action()]
  def actions do
    [
      :"organisation.create",
      :"organisation.rename",
      :"organisation.delete",
      :"organisation.restore",
      :"member.invite",
      :"member.change_level",
      :"member.remove",
      :"invitation.revoke",
      :"invitation.accept",
      :"member.suspend",
      :"member.activate",
      :"instance_admin.grant",
      :"instance_admin.revoke",
      :"audit.prune",
      :"workspace.create",
      :"workspace.rename",
      :"workspace.delete",
      :"workspace.restore",
      :"workspace.purge",
      :"access_key.create_code",
      :"access_key.cancel_code",
      :"access_key.add",
      :"access_key.approve",
      :"access_key.reject",
      :"access_key.revoke",
      :"node.create",
      :"node.edit",
      :"node.delete",
      :"node.clear_instance",
      :"run.close",
      :"retention.edit",
      :"security_policy.edit",
      :"security_policy.lock",
      :"security_policy.set_mode",
      :"secret.write",
      :"variable.edit",
      :"connection.write"
    ]
  end

  @doc """
  make/2 makes `action` the way the product makes it, in the context `Apiary.AuditCase`
  gives: what it needs first, then the trail as it is, then the change.
  """
  @spec make(Access.action(), map) :: map
  def make(:"organisation.create", _ctx) do
    before = entries()

    # A later sign-up, whether or not the edition opens one.
    {:ok, %{user: user, organisation: organisation} = signed_up} =
      Organisations.sign_up_user(valid_user_attributes(%{}), nil, open: true)

    scope = %Scope{user: user, organisation: organisation, workspace: signed_up.workspace}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  def make(:"organisation.rename", %{scope: scope}) do
    before = entries()
    {:ok, _} = Organisations.update_organisation(scope, %{name: "Renamed"})
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  def make(:"member.invite", %{scope: scope}) do
    before = entries()
    %{invitation: invitation} = invitation_fixture(scope)
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"member.change_level", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.set_member_level(scope, membership.id, :owner)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  def make(:"member.remove", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.remove_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  def make(:"invitation.revoke", %{scope: scope}) do
    %{invitation: invitation} = invitation_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.revoke_invitation(scope, invitation.id)
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"invitation.accept", %{scope: scope}) do
    %{invitation: invitation, token: token} = invitation_fixture(scope)
    %{user: user} = sign_up_fixture()
    before = entries()
    {:ok, _membership} = Organisations.accept_invitation(Scope.for_user(user), token)
    accepted = %Scope{user: user, organisation: scope.organisation}
    %{scope: accepted, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"member.suspend", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()
    {:ok, _} = Organisations.suspend_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  def make(:"member.activate", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    {:ok, _} = Organisations.suspend_member(scope, membership.id)
    before = entries()
    {:ok, _} = Organisations.activate_member(scope, membership.id)
    %{scope: scope, subject: {"membership", membership.id}, before: before}
  end

  # A release command, by the instance, in the trail of the instance's organisation.
  def make(:"instance_admin.grant", _ctx) do
    %{user: user} = sign_up_fixture()
    before = entries()
    {:ok, %{membership: membership}} = Organisations.grant_instance_admin(user)
    instance = Scope.for_instance(instance_organisation())
    %{scope: instance, actor: :instance, subject: {"membership", membership.id}, before: before}
  end

  # What an edition records beside the revocation, in actions of its own, is not the one
  # looked for: the edition's test pins it.
  def make(:"instance_admin.revoke", _ctx) do
    %{user: user} = sign_up_fixture()
    {:ok, %{membership: membership}} = Organisations.grant_instance_admin(user)
    before = entries()
    {:ok, _member} = Organisations.revoke_instance_admin(user)

    %{
      scope: Scope.for_instance(instance_organisation()),
      actor: :instance,
      subject: {"membership", membership.id},
      before: before ++ of_the_edition(entries() -- before)
    }
  end

  def make(:"audit.prune", %{owner: %{organisation: organisation}}) do
    old!(organisation)
    before = entries()
    instance = Scope.for_instance(organisation)
    {:ok, 1} = Audit.prune(instance)
    # The pruned entry is gone from the trail: it is not the one looked for.
    %{
      scope: instance,
      actor: :instance,
      subject: {"organisation", organisation.id},
      before: Enum.filter(before, &(&1 in entries()))
    }
  end

  # The core's edition allows one workspace in use: the organisation's first is marked
  # for deletion, as a fixture marks it, before the owner creates another.
  def make(:"workspace.create", %{scope: scope}) do
    scope = mark_only_workspace(scope)
    before = entries()
    {:ok, workspace} = Organisations.create_workspace(scope, %{"name" => "Data"})
    %{scope: scope, subject: {"workspace", workspace.id}, before: before}
  end

  def make(:"workspace.rename", %{scope: scope}) do
    before = entries()
    {:ok, _} = Organisations.update_workspace(scope, %{name: "Renamed"})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"access_key.create_code", %{scope: scope}) do
    node = node_fixture(scope)
    before = entries()
    {:ok, _row, code} = AccessKeys.create_enrolment_code(scope, node, %{allow_secrets: true})
    %{scope: scope, subject: {"node", node.id}, secret: code, before: before}
  end

  def make(:"access_key.cancel_code", %{scope: scope}) do
    node = node_fixture(scope)
    {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
    before = entries()
    {:ok, _} = AccessKeys.cancel_code(scope, row)
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"access_key.add", %{scope: scope}) do
    node = node_fixture(scope)
    before = entries()
    %{access_key: key} = node_key_fixture(scope, node)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  def make(:"access_key.approve", %{scope: scope}) do
    %{access_key: key} = pending_key_fixture(scope, node_fixture(scope))
    before = entries()
    {:ok, _} = AccessKeys.approve(scope, key)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  def make(:"access_key.reject", %{scope: scope}) do
    %{access_key: key} = pending_key_fixture(scope, node_fixture(scope))
    before = entries()
    {:ok, _} = AccessKeys.reject(scope, key)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  def make(:"access_key.revoke", %{scope: scope}) do
    %{access_key: key} = node_key_fixture(scope, node_fixture(scope))
    before = entries()
    {:ok, _} = AccessKeys.revoke_access_key(scope, key)
    %{scope: scope, subject: {"access_key", key.id}, before: before}
  end

  def make(:"node.create", %{scope: scope}) do
    before = entries()
    {:ok, node} = Nodes.create_node(scope, %{kind: "pool", name: "spot-runners"})
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"node.edit", %{scope: scope}) do
    node = pool_fixture(scope)
    before = entries()
    {:ok, _} = Nodes.update_node(scope, node, %{name: "spot-runners", instance_limit: 10})
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"node.delete", %{scope: scope}) do
    node = node_fixture(scope)
    before = entries()
    {:ok, _} = Nodes.delete_node(scope, node)
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"node.clear_instance", %{scope: scope}) do
    node = node_fixture(scope)
    instance = instance_fixture(node, name: "build-01.example.com")
    node_run_fixture(node, instance.instance_id)
    before = entries()
    {:ok, _} = Nodes.clear_instance(scope, node, instance.instance_id)
    %{scope: scope, subject: {"node", node.id}, before: before}
  end

  def make(:"run.close", %{scope: scope}) do
    run = run_fixture(scope)
    before = entries()
    {:ok, _} = Runs.close_run(scope, run)
    %{scope: scope, subject: {"run", run.id}, before: before}
  end

  def make(:"retention.edit", %{scope: scope}) do
    before = entries()
    {:ok, _} = Retention.update_retention(scope, %{events_retention_days: 30})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"security_policy.edit", %{scope: scope}) do
    before = entries()
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"security_policy.lock", %{scope: scope}) do
    {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
    before = entries()
    {:ok, _} = Policy.lock(scope, rule)
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"security_policy.set_mode", %{scope: scope}) do
    before = entries()
    {:ok, _} = Policy.set_mode(scope, "enforce")
    %{scope: scope, subject: {"workspace", scope.workspace.id}, before: before}
  end

  def make(:"secret.write", %{scope: scope}) do
    before = entries()
    value = "s3cr3t-audit-value"
    {:ok, secret} = Secrets.create_secret(scope, %{name: "API_TOKEN", value: value})
    %{scope: scope, subject: {"secret", secret.id}, before: before, secret: value}
  end

  def make(:"variable.edit", %{scope: scope}) do
    before = entries()
    value = "plain-audit-value"

    {:ok, variable} =
      Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: value})

    %{scope: scope, subject: {"variable", variable.id}, before: before, secret: value}
  end

  def make(:"connection.write", %{scope: scope}) do
    before = entries()
    {:ok, connection} = Apiary.Connections.create_service(scope, %{service: "sentry"})
    %{scope: scope, subject: {"connection", connection.id}, before: before}
  end

  def make(:"organisation.delete", %{scope: scope}) do
    before = entries()
    {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  def make(:"organisation.restore", %{scope: scope}) do
    {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
    before = entries()
    {:ok, _} = Deletion.restore_organisation(scope, scope.organisation.id)
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before}
  end

  def make(:"workspace.delete", %{scope: scope}) do
    workspace = workspace_fixture(scope.organisation)
    before = entries()
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    %{scope: scope, subject: {"workspace", workspace.id}, before: before}
  end

  def make(:"workspace.restore", %{scope: scope}) do
    workspace = workspace_fixture(scope.organisation)
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    before = entries()
    {:ok, _} = Deletion.restore_workspace(scope, workspace.id)
    %{scope: scope, subject: {"workspace", workspace.id}, before: before}
  end

  def make(:"workspace.purge", %{scope: scope}) do
    workspace = due_workspace(scope)
    before = entries()
    instance = Scope.for_instance(scope.organisation, workspace)
    {:ok, :purged} = Deletion.purge_workspace(instance)
    # The workspace's own entries are purged with it: not the one looked for.
    %{
      scope: instance,
      actor: :instance,
      subject: {"workspace", workspace.id},
      before: Enum.filter(before, &(&1 in entries()))
    }
  end

  @doc """
  refuse/2 makes `action` refused or rolled back, in the context `Apiary.AuditCase` gives:
  `{the trail before the attempt, the attempt's answer}`.
  """
  @spec refuse(Access.action(), map) :: {list, term}
  def refuse(:"organisation.create", _ctx) do
    before = entries()

    {before,
     Organisations.sign_up_user(%{email: "not an address", organisation_name: "Acme"}, nil,
       open: true
     )}
  end

  def refuse(:"invitation.accept", %{scope: scope}) do
    %{token: token} = invitation_fixture(scope)
    # Accepted once already: the second finds no pending invitation.
    %{user: first} = sign_up_fixture()
    {:ok, _} = Organisations.accept_invitation(first, token)
    %{user: user} = sign_up_fixture()
    before = entries()
    {before, Organisations.accept_invitation(Scope.for_user(user), token)}
  end

  # An account deleted is made nobody's admin.
  def refuse(:"instance_admin.grant", _ctx) do
    user = Apiary.AccountsFixtures.user_fixture()
    {:ok, _} = Accounts.delete_user(%Scope{user: user})
    before = entries()
    {before, Organisations.grant_instance_admin(user)}
  end

  # The instance's last admin, the suite's first user, stays one.
  def refuse(:"instance_admin.revoke", _ctx) do
    [admin] =
      Repo.all(
        from m in Membership,
          where:
            m.organisation_id == ^Apiary.Edition.instance_organisation_id() and
              m.level == ^Access.instance_admin_level(),
          preload: :user
      )

    before = entries()
    {before, Organisations.revoke_instance_admin(admin.user)}
  end

  def refuse(:"audit.prune", %{scope: scope, owner: %{organisation: organisation}}) do
    old!(organisation)
    before = entries()
    {before, Audit.prune(scope)}
  end

  # Anyone but the instance, here an owner, may not purge.
  def refuse(:"workspace.purge", %{scope: scope}) do
    workspace = due_workspace(scope)
    before = entries()
    {before, Deletion.purge_workspace(%{scope | workspace: workspace})}
  end

  # A member where the change is an owner's or an admin's; where every member may make it,
  # a person who was a member when the scope was loaded and is no longer.
  def refuse(action, ctx),
    do: refuse_as_member(action, ctx, &prepare(action, &1), &attempt(action, &1, &2))

  defp prepare(:"member.change_level", %{scope: scope}), do: member_fixture(scope).membership
  defp prepare(:"member.remove", %{scope: scope}), do: member_fixture(scope).membership
  defp prepare(:"invitation.revoke", %{scope: scope}), do: invitation_fixture(scope).invitation
  defp prepare(:"member.suspend", %{scope: scope}), do: member_fixture(scope).membership

  defp prepare(:"member.activate", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    {:ok, suspended} = Organisations.suspend_member(scope, membership.id)
    suspended
  end

  defp prepare(:"access_key.create_code", %{scope: scope}), do: node_fixture(scope)

  defp prepare(:"access_key.cancel_code", %{scope: scope}) do
    {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node_fixture(scope), %{})
    row
  end

  defp prepare(:"access_key.add", %{scope: scope}), do: node_fixture(scope)

  defp prepare(action, %{scope: scope})
       when action in [:"access_key.approve", :"access_key.reject"],
       do: pending_key_fixture(scope, node_fixture(scope)).access_key

  defp prepare(:"access_key.revoke", %{scope: scope}),
    do: node_key_fixture(scope, node_fixture(scope)).access_key

  defp prepare(:"run.close", %{scope: scope}), do: run_fixture(scope)
  defp prepare(:"node.edit", %{scope: scope}), do: node_fixture(scope)
  defp prepare(:"node.delete", %{scope: scope}), do: node_fixture(scope)

  defp prepare(:"node.clear_instance", %{scope: scope}) do
    node = node_fixture(scope)
    {node, instance_fixture(node).instance_id}
  end

  defp prepare(:"organisation.restore", %{scope: scope}) do
    {:ok, organisation} = Deletion.delete_organisation(scope, scope.organisation.slug)
    organisation
  end

  defp prepare(:"workspace.delete", %{scope: scope}), do: workspace_fixture(scope.organisation)

  defp prepare(:"workspace.restore", %{scope: scope}) do
    workspace = workspace_fixture(scope.organisation)
    {:ok, workspace} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)
    workspace
  end

  defp prepare(:"security_policy.lock", %{scope: scope}) do
    {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
    rule
  end

  defp prepare(_action, _ctx), do: nil

  defp attempt(:"organisation.rename", scope, _),
    do: Organisations.update_organisation(scope, %{name: "Renamed"})

  defp attempt(:"organisation.delete", scope, _),
    do: Deletion.delete_organisation(scope, scope.organisation.slug)

  defp attempt(:"organisation.restore", scope, organisation),
    do: Deletion.restore_organisation(scope, organisation.id)

  defp attempt(:"workspace.create", scope, _),
    do: Organisations.create_workspace(scope, %{"name" => "Data"})

  defp attempt(:"workspace.delete", scope, workspace),
    do: Deletion.delete_workspace(scope, workspace.id, workspace.slug)

  defp attempt(:"workspace.restore", scope, workspace),
    do: Deletion.restore_workspace(scope, workspace.id)

  defp attempt(:"member.invite", scope, _) do
    Organisations.invite_member(
      scope,
      %{"email" => unique_user_email()},
      &"http://localhost/invitations/#{&1}"
    )
  end

  defp attempt(:"member.change_level", scope, membership),
    do: Organisations.set_member_level(scope, membership.id, :owner)

  defp attempt(:"member.remove", scope, membership),
    do: Organisations.remove_member(scope, membership.id)

  defp attempt(:"invitation.revoke", scope, invitation),
    do: Organisations.revoke_invitation(scope, invitation.id)

  defp attempt(:"member.suspend", scope, membership),
    do: Organisations.suspend_member(scope, membership.id)

  defp attempt(:"member.activate", scope, membership),
    do: Organisations.activate_member(scope, membership.id)

  defp attempt(:"workspace.rename", scope, _),
    do: Organisations.update_workspace(scope, %{name: "Renamed"})

  defp attempt(:"access_key.revoke", scope, key), do: AccessKeys.revoke_access_key(scope, key)

  defp attempt(:"access_key.create_code", scope, node),
    do: AccessKeys.create_enrolment_code(scope, node, %{})

  defp attempt(:"access_key.cancel_code", scope, code), do: AccessKeys.cancel_code(scope, code)

  defp attempt(:"access_key.add", scope, node),
    do:
      AccessKeys.add_access_key(scope, node, %{
        label: "build-01",
        public_key: ed25519_key_pair().encoded
      })

  defp attempt(:"access_key.approve", scope, key), do: AccessKeys.approve(scope, key)
  defp attempt(:"access_key.reject", scope, key), do: AccessKeys.reject(scope, key)

  defp attempt(:"node.create", scope, _),
    do: Nodes.create_node(scope, %{kind: "node", name: "build-01"})

  defp attempt(:"node.edit", scope, node), do: Nodes.update_node(scope, node, %{name: "build-02"})
  defp attempt(:"node.delete", scope, node), do: Nodes.delete_node(scope, node)

  defp attempt(:"node.clear_instance", scope, {node, instance_id}),
    do: Nodes.clear_instance(scope, node, instance_id)

  defp attempt(:"run.close", scope, run), do: Runs.close_run(scope, run)

  defp attempt(:"secret.write", scope, _),
    do: Secrets.create_secret(scope, %{name: "API_TOKEN", value: "s3cr3t-audit-value"})

  defp attempt(:"variable.edit", scope, _),
    do: Variables.create_variable(scope, :workspace, %{name: "NODE_ENV", value: "test"})

  defp attempt(:"connection.write", scope, _),
    do: Apiary.Connections.create_service(scope, %{service: "sentry"})

  defp attempt(:"retention.edit", scope, _),
    do: Retention.update_retention(scope, %{events_retention_days: 30})

  defp attempt(:"security_policy.edit", scope, _),
    do: Policy.allow(scope, nil, %{host: "api.example"})

  defp attempt(:"security_policy.lock", scope, rule), do: Policy.lock(scope, rule)
  defp attempt(:"security_policy.set_mode", scope, _), do: Policy.set_mode(scope, "enforce")

  # The scope's workspace, the organisation's only one, marked for deletion directly, and
  # the scope loaded again, with no workspace in use: the product does not delete an
  # organisation's last workspace, and the core's edition lets another be created only in
  # its place.
  defp mark_only_workspace(%Scope{workspace: %Workspace{} = workspace} = scope) do
    now = DateTime.utc_now()

    workspace
    |> Ecto.Changeset.change(
      deletion_marked_at: now,
      purge_after: DateTime.add(now, 30, :day),
      purge_trigger: "grace_period"
    )
    |> Repo.update!()

    Organisations.load_scope(Scope.for_user(scope.user), scope.organisation.id)
  end

  # The instance's own organisation (`c:Apiary.Edition.instance_organisation_id/0`).
  defp instance_organisation,
    do: Repo.get!(Organisation, Apiary.Edition.instance_organisation_id())

  # The entries of `entries` of the edition's own actions (`Apiary.Edition.actions/0`).
  defp of_the_edition(entries) do
    names = Enum.map(Apiary.Edition.actions(), &Atom.to_string(&1.name))
    Enum.filter(entries, &(&1.action in names))
  end

  # A second workspace of the scope's organisation, deleted and past its grace period.
  defp due_workspace(scope) do
    workspace = workspace_fixture(scope.organisation)
    {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

    Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    workspace
  end
end
