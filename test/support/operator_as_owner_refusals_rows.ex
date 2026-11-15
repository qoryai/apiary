defmodule ApiaryProWeb.OperatorAsOwnerRefusalsRows do
  @moduledoc false
  # The refusals test's rows while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), after the core's and the edition's
  # (`ApiaryWeb.RefusalsRows`, `ApiaryProWeb.RefusalsRows`), whose world they use: the
  # client, its owner, made while the flag was off, its admin and its member, a pool with
  # a limit, a rule and a locked rule, and the operator's people. Its setup comes last and turns the flag on last, so the client keeps the
  # owner it had; then the operator's owner adds a gateway at the operator, and the
  # client's owner one at the client. Sent by
  # `ApiaryProWeb.OperatorAsOwnerRefusalsTest`, which asks these rows alone: the flag-off
  # rows cover every action already.

  @behaviour ApiaryWeb.RefusalsCase

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
      # The People page is not found for the operator's owner.
      {:"member.change_level", :operator_owner, "/:client/settings/people", "set_level",
       %{"membership_id" => :client_admin_membership, "level" => "owner"},
       answer: :not_found_at_mount},
      {:"member.remove", :client_admin,
       "/:client/settings/people/:client_owner_membership/remove", "remove", %{},
       answer: :refused_at_mount},

      # What is the client's own to decide: refused to the operator's owner.
      {:"organisation.delete", :operator_owner, "/:client/settings", "delete_organisation",
       %{"confirm" => %{"slug" => :client}}},
      {:"organisation.leave_operator", :operator_owner, "/:client/settings/ownership",
       "leave_operator", %{"confirm" => %{"name" => :operator_name}}},

      # The nodes of the workspace the operator operates are the operator's: not there for
      # the client's people.
      {:"node.create", :client_owner, "/:client/:client_ws/machines", "create",
       %{"node" => %{"name" => "sneaky"}}},
      {:"node.create", :client_admin, "/:client/:client_ws/machines/new", "create",
       %{"node" => %{"name" => "sneaky"}}, answer: :refused_at_mount},

      # Its gateways at the organisation are the client's: their pages are not found for
      # the operator's people, who reach the workspace it operates alone.
      {:"node.create", :operator_owner, "/:client/gateways", "create", @sneaky_gateway,
       answer: :not_found_at_mount},
      {:"node.edit", :operator_admin, "/:client/gateways/:client_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}, answer: :not_found_at_mount},

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

      # A workspace's policy and the organisation's are the client's: the operator's people
      # neither lock a rule nor change the organisation's policy.
      {:"security_policy.lock", :operator_owner, "/:client/:client_ws/policy", "lock_toggle",
       %{"id" => :client_rule_open}},
      {:"security_policy.lock", :operator_admin, "/:client/:client_ws/policy", "lock_toggle",
       %{"id" => :client_rule_open}},
      # The organisation's policy page is not found for them.
      {:"organisation_policy.edit", :operator_owner, "/:client/policy", "rule_save", %{},
       answer: :not_found_at_mount, needs: :organisation_policy},
      {:"organisation_policy.edit", :operator_admin, "/:client/policy", "rule_save", %{},
       answer: :not_found_at_mount, needs: :organisation_policy},

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
  def setup(%{client_owner: owner, operator: operator} = world) do
    pool = Apiary.NodesFixtures.pool_fixture(owner.scope, instance_limit: 5)

    # A rule of the client's workspace, and a locked one, made by its owner.
    {:ok, open} = Apiary.Policy.allow(owner.scope, nil, %{host: "cdn.example"})
    {:ok, locked} = Apiary.Policy.deny(owner.scope, nil, %{host: "vault.example", locked: true})

    ApiaryPro.Flags.put_operator_infrastructure(true)

    # A gateway of the operator's, and one the client's owner added at the client.
    operator_owner = world.operator_owner.user

    operator_gateway =
      Apiary.NodesFixtures.organisation_gateway_fixture(
        ApiaryPro.OperatorsFixtures.scope_in(operator_owner, operator),
        name: "edge-operator"
      )

    client_gateway =
      Apiary.NodesFixtures.organisation_gateway_fixture(owner.scope, name: "edge-client")

    %{
      client_pool: pool,
      client_rule_open: open,
      client_rule_locked: locked,
      operator_gateway: operator_gateway,
      client_gateway: client_gateway
    }
  end

  @impl true
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
