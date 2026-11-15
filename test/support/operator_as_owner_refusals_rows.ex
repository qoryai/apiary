defmodule ApiaryProWeb.OperatorAsOwnerRefusalsRows do
  @moduledoc false
  # The refusals test's rows while `ApiaryPro.Flags.operator_infrastructure?/0` is on,
  # after the core's and the edition's (`ApiaryWeb.RefusalsRows`,
  # `ApiaryProWeb.RefusalsRows`), whose world they use: the organisation whose workspace
  # the operator operates (`:operated` in the paths), its owner, made while the flag was off,
  # its admin and its member, a pool with a limit, a rule and a locked rule, and the
  # operator's people. Its setup comes last and turns the flag on last; then the operator's
  # owner adds a gateway at the operator, and the organisation's owner one at the
  # organisation. Sent by
  # `ApiaryProWeb.OperatorAsOwnerRefusalsTest`, which asks these rows alone: the flag-off
  # rows cover every action already.

  @behaviour ApiaryWeb.RefusalsCase

  @sneaky_gateway %{"node" => %{"name" => "sneaky", "url" => "https://sneaky.example"}}

  @impl true
  def actors, do: []

  @impl true
  def rows do
    [
      # What the organisation decides as a whole: refused to the operator's owner.
      {:"organisation.delete", :operator_owner, "/:operated/settings", "delete_organisation",
       %{"confirm" => %{"slug" => :operated}}},

      # The nodes of the workspace the operator operates: the organisation's owners and
      # admins change them, and the operator's owner and admin are refused.
      {:"node.create", :operator_owner, "/:operated/:operated_ws/machines", "create",
       %{"node" => %{"name" => "sneaky"}}},
      {:"node.create", :operator_admin, "/:operated/:operated_ws/machines/new", "create",
       %{"node" => %{"name" => "sneaky"}}, answer: :refused_at_mount},

      # The organisation's gateways: their pages are not found for the operator's people,
      # who reach the workspace the operator operates alone.
      {:"node.create", :operator_owner, "/:operated/gateways", "create", @sneaky_gateway,
       answer: :not_found_at_mount},
      {:"node.edit", :operator_admin, "/:operated/gateways/:operated_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}, answer: :not_found_at_mount},

      # The operator's gateways are not found for the organisation's people, and the
      # operator's members read them.
      {:"node.create", :operated_admin, "/:operator/gateways/new", "create", @sneaky_gateway,
       answer: :not_found_at_mount},
      {:"node.edit", :operated_owner, "/:operator/gateways/:operator_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}, answer: :not_found_at_mount},
      {:"node.create", :operator_member, "/:operator/gateways", "create", @sneaky_gateway},
      {:"node.edit", :operator_member, "/:operator/gateways/:operator_gateway/settings", "save",
       %{"node" => %{"name" => "sneaky"}}},

      # A pool's limit: the operator's owner and admin are refused it. The workspace's
      # retention: the operator's member is refused it; the operator's owners and admins
      # set it.
      {:"node.set_limit", :operator_owner,
       "/:operated/:operated_ws/machines/:operated_pool/settings", "save",
       %{"node" => %{"instance_limit" => "3"}}},
      {:"node.set_limit", :operator_admin,
       "/:operated/:operated_ws/machines/:operated_pool/settings", "save",
       %{"node" => %{"instance_limit" => "3"}}},
      {:"retention.edit", :operator_member, "/:operated/:operated_ws/settings", "save_retention",
       %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}}},

      # A workspace's policy and the organisation's: the operator's people neither lock a
      # rule nor change the organisation's policy.
      {:"security_policy.lock", :operator_owner, "/:operated/:operated_ws/policy", "lock_toggle",
       %{"id" => :operated_rule_open}},
      {:"security_policy.lock", :operator_admin, "/:operated/:operated_ws/policy", "lock_toggle",
       %{"id" => :operated_rule_open}},
      # The organisation's policy page is not found for them.
      {:"organisation_policy.edit", :operator_owner, "/:operated/policy", "rule_save", %{},
       answer: :not_found_at_mount, needs: :organisation_policy},
      {:"organisation_policy.edit", :operator_admin, "/:operated/policy", "rule_save", %{},
       answer: :not_found_at_mount, needs: :organisation_policy}
    ]
  end

  @impl true
  def exempt, do: %{}

  @impl true
  def setup(%{operated_owner: owner, operator: operator} = world) do
    pool = Apiary.NodesFixtures.pool_fixture(owner.scope, instance_limit: 5)

    # A rule of the organisation's workspace, and a locked one, made by its owner.
    {:ok, open} = Apiary.Policy.allow(owner.scope, nil, %{host: "cdn.example"})
    {:ok, locked} = Apiary.Policy.deny(owner.scope, nil, %{host: "vault.example", locked: true})

    ApiaryPro.Flags.put_operator_infrastructure(true)

    # A gateway of the operator, and one the organisation's owner added at the
    # organisation.
    operator_owner = world.operator_owner.user

    operator_gateway =
      Apiary.NodesFixtures.organisation_gateway_fixture(
        ApiaryPro.OperatorsFixtures.scope_in(operator_owner, operator),
        name: "edge-operator"
      )

    operated_gateway =
      Apiary.NodesFixtures.organisation_gateway_fixture(owner.scope, name: "edge-operated")

    %{
      operated_pool: pool,
      operated_rule_open: open,
      operated_rule_locked: locked,
      operator_gateway: operator_gateway,
      operated_gateway: operated_gateway
    }
  end

  @impl true
  def value(:operated_pool, world), do: {:id, world.operated_pool.public_id}
  def value(:operated_rule_open, world), do: {:id, world.operated_rule_open.id}
  def value(:operated_rule_locked, world), do: {:id, world.operated_rule_locked.id}
  def value(:operator_gateway, world), do: {:id, world.operator_gateway.public_id}
  def value(:operated_gateway, world), do: {:id, world.operated_gateway.public_id}
  def value(:operated_owner_membership, world), do: {:id, world.operated_owner.membership.id}
  def value(_name, _world), do: nil

  @impl true
  def watched(world), do: [world.operator, world.operated]

  @impl true
  def before_page(_step, _world), do: nil

  @impl true
  def meanwhile(_step, _world), do: nil
end
