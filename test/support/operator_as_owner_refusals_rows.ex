defmodule ApiaryProWeb.OperatorAsOwnerRefusalsRows do
  @moduledoc false
  # The refusals test's rows while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), after the core's and the edition's
  # (`ApiaryWeb.RefusalsRows`, `ApiaryProWeb.RefusalsRows`), whose world they use: the
  # client, its owner, made while the flag was off, its admin and its member, a pool with
  # a limit, a rule and a locked rule, the operator's people, and its policy request to
  # the client. Its setup comes
  # last and turns the flag on last, so the client keeps the owner it had; then the
  # operator's owner adds a gateway at the operator and one at the client. Sent by
  # `ApiaryProWeb.OperatorAsOwnerRefusalsTest`, which asks these rows alone: the flag-off
  # rows cover every action already.

  @behaviour ApiaryWeb.RefusalsCase

  import Apiary.OrganisationsFixtures

  @client_owner_email %{"client_id" => :client_id, "owner" => %{"email" => "owner@example.com"}}
  @dropped %{"client_id" => :client_id, "confirm" => %{"name" => :client_name}}
  @sneaky_gateway %{"node" => %{"name" => "sneaky", "url" => "https://sneaky.example"}}

  @impl true
  def actors, do: []

  @impl true
  def rows do
    [
      # A client's admin acts on its admins and members, never on an owner, and makes
      # nobody an owner.
      {:"member.change_level", :client_admin, "/:client/settings/people", "set_level",
       %{"membership_id" => :client_member_membership, "level" => "owner"}},
      {:"member.change_level", :client_admin, "/:client/settings/people", "set_level",
       %{"membership_id" => :client_owner_membership, "level" => "member"}},
      # Nor does its owner, made before the flag was on, nor the operator's owner.
      {:"member.change_level", :client_owner, "/:client/settings/people", "set_level",
       %{"membership_id" => :client_admin_membership, "level" => "owner"}},
      {:"member.change_level", :operator_owner, "/:client/settings/people", "set_level",
       %{"membership_id" => :client_admin_membership, "level" => "owner"}},
      {:"member.remove", :client_admin,
       "/:client/settings/people/:client_owner_membership/remove", "remove", %{},
       answer: :refused_at_mount},

      # What is the client's own to decide: refused to the operator's owner.
      {:"organisation.delete", :operator_owner, "/:client/settings", "delete_organisation",
       %{"confirm" => %{"slug" => :client}}},
      {:"organisation.leave_operator", :operator_owner, "/:client/settings/ownership",
       "leave_operator", %{"confirm" => %{"name" => :operator_name}}},

      # Its workspaces are the operator's: its own admin and owner neither delete nor bring
      # one back.
      {:"workspace.delete", :client_admin,
       "/:client/settings/workspaces/:client_platform_id/delete", "delete_workspace",
       %{"confirm" => %{"slug" => :client_platform}}, answer: :refused_at_mount},
      {:"workspace.delete", :client_owner,
       "/:client/settings/workspaces/:client_platform_id/delete", "delete_workspace",
       %{"confirm" => %{"slug" => :client_platform}}, answer: :refused_at_mount},
      {:"workspace.restore", :client_admin, "/:client/settings", "restore_workspace",
       %{"id" => :client_marked_id}},

      # Its nodes are the operator's: not there for its own people.
      {:"node.create", :client_owner, "/:client/:client_ws/machines", "create",
       %{"node" => %{"name" => "sneaky"}}},
      {:"node.create", :client_admin, "/:client/:client_ws/machines/new", "create",
       %{"node" => %{"name" => "sneaky"}}, answer: :refused_at_mount},

      # Its gateways at the organisation are the operator's too: its own people neither
      # add one nor change one the operator's owner added.
      {:"node.create", :client_admin, "/:client/gateways/new", "create", @sneaky_gateway,
       answer: :refused_at_mount},
      {:"node.create", :client_owner, "/:client/gateways", "create", @sneaky_gateway},
      {:"node.edit", :client_admin, "/:client/gateways/:client_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}},
      {:"node.delete", :client_owner, "/:client/gateways/:client_gateway/settings/delete",
       "delete", %{}, answer: :refused_at_mount},

      # The operator's gateways are not there for the client's people, and its members
      # read them.
      {:"node.create", :client_admin, "/:operator/gateways/new", "create", @sneaky_gateway,
       answer: :not_found_at_mount},
      {:"node.edit", :client_owner, "/:operator/gateways/:operator_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}, answer: :not_found_at_mount},
      {:"node.create", :operator_member, "/:operator/gateways", "create", @sneaky_gateway},
      {:"node.edit", :operator_member, "/:operator/gateways/:operator_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}},

      # A pool's limit and a workspace's retention are the operator's: the client's owner
      # and admin are refused them.
      {:"node.set_limit", :client_admin, "/:client/:client_ws/machines/:client_pool/settings",
       "save", %{"node" => %{"instance_limit" => "3"}}},
      {:"retention.edit", :client_owner, "/:client/:client_ws/settings", "save_retention",
       %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}}},
      {:"retention.edit", :client_admin, "/:client/:client_ws/settings", "save_retention",
       %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}}},

      # A rule's lock is the operator's owners': the client's owner, made before the flag
      # was on, and the operator's admin neither lock, unlock nor change a locked rule.
      {:"security_policy.lock", :client_owner, "/:client/:client_ws/policy", "lock_toggle",
       %{"id" => :client_rule_open}},
      {:"security_policy.lock", :client_owner, "/:client/:client_ws/policy", "lock_toggle",
       %{"id" => :client_rule_locked}},
      {:"security_policy.lock", :client_owner, "/:client/:client_ws/policy", "change_action",
       %{"id" => :client_rule_locked}},
      {:"security_policy.lock", :client_owner, "/:client/:client_ws/policy", "remove_confirm",
       %{}, prelude: [{"remove", %{"id" => :client_rule_locked}}]},
      {:"security_policy.lock", :operator_admin, "/:client/:client_ws/policy", "lock_toggle",
       %{"id" => :client_rule_open}},

      # So is the organisation's policy: the client's owner reads it and changes nothing.
      {:"organisation_policy.edit", :client_owner, "/:client/policy/rules/new", "rule_save", %{},
       answer: :refused_at_mount, needs: :organisation_policy},
      {:"organisation_policy.edit", :client_owner, "/:client/policy", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}],
       needs: :organisation_policy},
      {:"organisation_policy.edit", :operator_admin, "/:client/policy", "rule_save", %{},
       prelude: [{"rule_validate", %{"rule" => %{"host" => "new.example", "paths" => ""}}}],
       needs: :organisation_policy},
      {:"organisation_policy.set_floor", :client_owner, "/:client/policy", "mode_open", %{},
       needs: :organisation_policy},
      {:"organisation_policy.set_floor", :client_owner, "/:client/policy", "mode_set", %{},
       needs: :organisation_policy},
      {:"organisation_policy.set_switch", :client_owner, "/:client/policy", "switch_ask", %{},
       needs: :organisation_policy},

      # Policy requests are not there: their pages are not found as they open.
      {:"policy_request.send", :operator_owner, "/:operator/clients/requests/new", "send",
       %{"request" => %{"note" => "Sneaky", "mode" => "enforce"}}, answer: :not_found_at_mount},
      {:"policy_request.withdraw", :operator_owner,
       "/:operator/clients/requests/:request_id/withdraw", "withdraw", %{"id" => :request_id},
       answer: :not_found_at_mount},
      {:"policy_request.accept", :client_owner, "/:client/policy-requests", "accept",
       %{"answer_id" => :client_answer, "workspaces" => [:client_workspace_id]},
       answer: :not_found_at_mount},
      {:"policy_request.decline", :client_owner,
       "/:client/policy-requests/:client_answer/decline", "decline",
       %{"answer_id" => :client_answer, "decline" => %{"reason" => "Sneaky"}},
       answer: :not_found_at_mount},

      # The first owner's invitation and the drop are not there; the first admin's is
      # refused where the client has someone already.
      {:"client.invite_owner", :operator_owner, "/:operator/clients", "invite_owner",
       @client_owner_email, answer: :not_found},
      {:"client.invite_owner", :operator_owner, "/:operator/clients/:client_id/owner",
       "invite_owner", @client_owner_email, answer: :not_found_at_mount},
      {:"client.drop", :operator_owner, "/:operator/clients", "drop_client", @dropped,
       answer: :not_found},
      {:"client.drop", :operator_owner, "/:operator/clients/:client_id/drop", "drop_client",
       @dropped, answer: :not_found_at_mount},
      {:"client.invite_admin", :operator_owner, "/:operator/clients", "invite_admin",
       @client_owner_email},
      {:"client.invite_admin", :operator_member, "/:operator/clients", "invite_admin",
       @client_owner_email}
    ]
  end

  @impl true
  def exempt, do: %{}

  @impl true
  def setup(%{client: client, client_owner: owner, operator: operator} = world) do
    platform = workspace_fixture(client, "Platform")
    marked = workspace_fixture(client, "Marked")
    {:ok, _} = Apiary.Deletion.delete_workspace(owner.scope, marked.id, marked.slug)
    pool = Apiary.NodesFixtures.pool_fixture(owner.scope, instance_limit: 5)

    # A rule of the client's workspace, and a locked one, made by its owner.
    {:ok, open} = Apiary.Policy.allow(owner.scope, nil, %{host: "cdn.example"})
    {:ok, locked} = Apiary.Policy.deny(owner.scope, nil, %{host: "vault.example", locked: true})

    ApiaryPro.Flags.put_operator_infrastructure(true)

    # A gateway of the operator's, and one its owner added at the client.
    operator_owner = world.operator_owner.user

    operator_gateway =
      Apiary.NodesFixtures.organisation_gateway_fixture(
        ApiaryPro.OperatorsFixtures.scope_in(operator_owner, operator),
        name: "edge-operator"
      )

    client_gateway =
      Apiary.NodesFixtures.organisation_gateway_fixture(
        ApiaryPro.OperatorsFixtures.scope_in(operator_owner, client),
        name: "edge-client"
      )

    %{
      client_platform: platform,
      client_marked: marked,
      client_pool: pool,
      client_rule_open: open,
      client_rule_locked: locked,
      operator_gateway: operator_gateway,
      client_gateway: client_gateway
    }
  end

  @impl true
  def value(:client_platform, world), do: world.client_platform.slug
  def value(:client_platform_id, world), do: {:id, world.client_platform.id}
  def value(:client_marked_id, world), do: {:id, world.client_marked.id}
  def value(:client_pool, world), do: {:id, world.client_pool.public_id}
  def value(:client_rule_open, world), do: {:id, world.client_rule_open.id}
  def value(:client_rule_locked, world), do: {:id, world.client_rule_locked.id}
  def value(:operator_gateway, world), do: {:id, world.operator_gateway.public_id}
  def value(:client_gateway, world), do: {:id, world.client_gateway.public_id}
  def value(:client_owner_membership, world), do: {:id, world.client_owner.membership.id}
  def value(_name, _world), do: nil

  @impl true
  def watched(world), do: [world.operator, world.client]

  @impl true
  def before_page(_step, _world), do: nil

  @impl true
  def meanwhile(_step, _world), do: nil
end
