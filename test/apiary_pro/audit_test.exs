defmodule ApiaryPro.AuditTest do
  # Not async: the changes are made on an instance with every feature, which is the node's
  # (`Apiary.AuditCase`).
  use Apiary.AuditCase, changes: [Apiary.AuditChanges, ApiaryPro.AuditChanges]

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Audit, Organisations}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias ApiaryPro.{Transfers, WorkspaceAccess}

  # Every action, the core's and the edition's, made and refused by the case: the core's changes
  # again, under the edition, and the edition's.

  describe "what the edition records beside a change of the core" do
    test "an instance admin made a member in no workspace is added to one, an entry of its own; one in a workspace already is added to none" do
      instance = instance_organisation()
      [workspace | _] = Organisations.list_workspaces(Scope.for_instance(instance))

      %{user: placed} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(placed)

      Repo.insert!(%WorkspaceAccess.Row{
        organisation_id: instance.id,
        workspace_id: workspace.id,
        user_id: placed.id
      })

      before = entries()
      {:ok, member} = Organisations.revoke_instance_admin(placed)

      assert [%Entry{action: "instance_admin.revoke", actor_kind: :instance} = revoked] =
               entries() -- before

      assert revoked.subject_id == member.id
      assert revoked.organisation_id == instance.id

      %{user: unplaced} = sign_up_fixture()
      {:ok, _} = Organisations.grant_instance_admin(unplaced)
      before = entries()
      {:ok, member} = Organisations.revoke_instance_admin(unplaced)

      # One transaction: the two are ordered by their actions.
      assert [%Entry{action: "instance_admin.revoke"} = revoked, added] =
               Enum.sort_by(entries() -- before, & &1.action)

      assert revoked.subject_id == member.id

      assert %Entry{
               action: "workspace_access.add",
               subject_kind: "workspace_access",
               actor_kind: :instance,
               details: %{"reason" => "demoted", "user_id" => user_id}
             } = added

      assert user_id == unplaced.id
      assert added.organisation_id == instance.id
      assert added.workspace_id == workspace.id
      refute_personal(added, nil)
    end
  end

  describe "before and after" do
    test "a workspace access's entries are its workspace's" do
      %{scope: scope} = sign_up_fixture()
      %{membership: membership, user: user} = member_fixture(scope)

      {:ok, _} = Organisations.set_member_level(scope, membership.id, :admin)
      {:ok, _} = WorkspaceAccess.add(scope, membership.id, scope.workspace.id)
      {:ok, _} = Organisations.set_member_level(scope, membership.id, :member)
      second = workspace_fixture(scope.organisation)
      {:ok, access} = WorkspaceAccess.add(scope, membership.id, second.id)

      assert %Entry{
               action: "workspace_access.add",
               subject_kind: "workspace_access",
               details: %{"user_id" => user_id}
             } = entry = last()

      assert entry.subject_id == access.id
      assert entry.workspace_id == second.id
      assert user_id == user.id
    end
  end

  describe "reading the trail" do
    test "an operator in its client's trail, and the client in its operator's, are named as they are now" do
      operator = operator_fixture()
      offered = sign_up_fixture()
      {:ok, _} = Transfers.offer_to_operator(offered.scope, operator.organisation.slug)
      {:ok, client} = Transfers.accept_client(operator.scope, offered.organisation.id)
      {:ok, _} = Organisations.update_organisation(operator.scope, %{name: "Renamed operator"})

      # Each trail names the other organisation by id; the other is not the reader's.
      client_scope = scope_in(offered.user, client)
      {:ok, %{entries: entries}} = Audit.list_entries(client_scope)

      assert Audit.names(client_scope, entries).organisations[operator.organisation.id] ==
               "Renamed operator"

      {:ok, %{entries: entries}} = Audit.list_entries(operator.scope)

      assert Audit.names(operator.scope, entries).organisations[client.id] ==
               offered.organisation.name
    end
  end
end
