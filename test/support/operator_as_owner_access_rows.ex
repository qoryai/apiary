defmodule ApiaryPro.OperatorAsOwnerAccessRows do
  @moduledoc false
  # The rows of the access test (`Apiary.AccessCase`) while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`): every action, asked in a client by its
  # own people, by the operator's and by people in both. A table of its own, asked by
  # `ApiaryPro.OperatorAsOwnerAccessTest`, not merged into the core's and the edition's, which ask
  # with the flag off. The actors, each asking in the client's workspace Main:
  #
  #     client_owner             an owner of the client, made before the flag was on
  #     client_admin             an admin of the client
  #     client_member            a member of the client
  #     operator_owner           an owner of the operator, with no membership in the client
  #     operator_admin           an admin of the operator, likewise
  #     operator_member          a member of the operator, likewise: read-only
  #     owner_and_client_member  an owner of the operator who is a member of the client
  #     member_and_client_admin  a member of the operator who is an admin of the client
  #     admin_and_client_owner   an admin of the operator who is an owner of the client
  #
  # The operator's owners and admins act at their level; someone in both at the higher of
  # their two levels. What is the client's own to decide (deleting it, offering it,
  # leaving the operator) is refused to anyone who acts there through the operator: with
  # no membership in the client, or a level in the operator strictly higher than theirs in
  # the client. Workspaces are made by the client's owners and admins and by the operator's
  # owners, and deleted and brought back by the operator's owners and admins. What the
  # operator sets is theirs, and not there for anyone
  # else: nodes, a pool's limit and keys, time limits, a workspace's retention
  # and the harness documents saved at the client's levels. Model providers, runtimes and
  # model choices are the operator's too while the client's switch is on the operator's
  # (`ApiaryPro.OperatorAsOwnerOperatorChainAccessRows` asks that); on the client's
  # providers, the default here, they are the client's owners' and admins', and a person
  # who acts there through the operator reads only. The client keeps its integrations and
  # services (`connection.write`). A rule's lock and the organisation's policy are the
  # operator's owners' alone, refused to its admins and to the client's owners. Policy
  # requests are not there for anyone.

  import ApiaryPro.OperatorsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  @all [
    :client_owner,
    :client_admin,
    :client_member,
    :operator_owner,
    :operator_admin,
    :operator_member,
    :owner_and_client_member,
    :member_and_client_admin,
    :admin_and_client_owner
  ]

  # At the owner's level, whichever way they reach it.
  @owners [:client_owner, :operator_owner, :owner_and_client_member, :admin_and_client_owner]
  # At the admin's level or above.
  @admins @owners ++ [:client_admin, :operator_admin, :member_and_client_admin]
  # Everyone but the operator's member, who reads only.
  @writers @admins ++ [:client_member]
  # The operator's owners and admins, whatever their level in the client.
  @operator_owners_admins [
    :operator_owner,
    :operator_admin,
    :owner_and_client_member,
    :admin_and_client_owner
  ]
  # The operator's owners, whatever their level in the client.
  @operator_owners [:operator_owner, :owner_and_client_member]
  # An owner of the client's own.
  @own_owners [:client_owner, :admin_and_client_owner]

  # What the operator sets in the client, whatever the switch: the operator's owners and
  # admins hold each, and it is not there for anyone else.
  @operator_held [
    :"node.create",
    :"node.edit",
    :"node.set_limit",
    :"node.delete",
    :"node.clear_instance",
    :"access_key.create_code",
    :"access_key.cancel_code",
    :"access_key.add",
    :"access_key.revoke",
    :"adapter.connect",
    :"time_limit.edit",
    :"retention.edit",
    :"harness.save"
  ]

  # What the client's switch decides: its model providers and runtimes, and the model
  # choices of its workspaces and targets.
  @chain_held [:"provider.write", :"runtime.write", :"model_choice.write"]

  # Who holds them on the client's providers: its owners and admins, and a person of the
  # operator who is one of them in the client at an equal or higher level there. Someone
  # who acts there through the operator, with no membership or a lower level, reads only.
  @chain_on_organisation [
    :client_owner,
    :client_admin,
    :member_and_client_admin,
    :admin_and_client_owner
  ]

  # Core's instance actions: not found in a client, for everyone.
  @instance_only [
    :"account.password_link",
    :"instance.mail_save",
    :"instance.mail_resend",
    :"instance.mail_on",
    :"instance.rename",
    :"instance.support_save",
    :"instance.configure",
    :"instance.read_factory",
    :"instance.read_observability",
    :"instance.read_machine",
    :"instance.review_connections",
    :"diagnostics_key.create",
    :"diagnostics_key.revoke",
    :"node.set_instance_limit",
    :"adapter.create",
    :"adapter.edit",
    :"adapter.set_interval",
    :"adapter.delete",
    :"adapter.setup",
    :"harness.assigned",
    :"harness.unassigned",
    :"workspace_type.edit",
    :"machine_type.rekey"
  ]

  # An adapter's key alone, asked of the adapter, which is no client's: not found.
  @adapter_keys [
    :"adapter.declare",
    :"adapter.app_values_set",
    :"adapter.app_values_seal",
    :"source_item.post",
    :"work_item.read_changes",
    :"adapter.disconnect",
    :"adapter.report_grant",
    :"adapter.end_grant",
    :"adapter.read_grants"
  ]

  # A node pool's key alone, asked of the client's workspace, its queue: no person takes
  # them, whatever their level, so they are refused to everyone in the client.
  @pool_keys [
    :"dispatch.claim",
    :"dispatch.dispatched",
    :"dispatch.release",
    :"dispatch.machine_log",
    :"dispatch.machine_end"
  ]

  # Not found in a client: an operator's actions, the instance's and the policy requests.
  @not_here [
    :"client.read",
    :"client.create",
    :"client.invite_owner",
    :"client.revoke_owner_invitation",
    :"client.renew_owner_invitation",
    :"client.invite_admin",
    :"client.revoke_admin_invitation",
    :"client.renew_admin_invitation",
    :"client.accept",
    :"client.grant_features",
    :"client.drop",
    :"client.set_model_chain",
    :"client.delete",
    :"instance.read",
    :"instance.create_organisation",
    :"instance.create_operator",
    :"instance.change_kind",
    :"instance.purge_organisation",
    :"instance.suspend_account",
    :"instance.activate_account",
    :"instance.suspend_organisation",
    :"instance.activate_organisation",
    :"instance.transfer",
    :"instance.grant_features",
    :"instance.change_sign_up",
    :"instance.adopt",
    :"policy_request.send",
    :"policy_request.withdraw",
    :"policy_request.accept",
    :"policy_request.decline"
  ]

  @doc false
  def actors, do: @all

  @doc false
  def rows do
    [
      {:"organisation.create", yes: @all},
      {:"organisation.rename", yes: @admins},
      {:"organisation.delete", yes: @own_owners},
      {:"organisation.restore", yes: @owners},
      {:"organisation.purge", yes: []},
      {:"member.read", yes: @all},
      {:"member.invite", yes: @admins, on: :workspace},
      {:"member.change_level", yes: @owners, on: :workspace},
      {:"member.remove", yes: @admins, on: :workspace},
      {:"invitation.revoke", yes: @admins},
      {:"invitation.renew", yes: @admins},
      {:"invitation.accept", yes: []},
      {:"member.suspend", yes: @admins, on: :workspace},
      {:"member.activate", yes: @admins, on: :workspace},
      {:"instance_admin.grant", yes: []},
      {:"instance_admin.revoke", yes: []},
      {:"audit.read", yes: @all -- [:client_member]},
      {:"audit.prune", yes: []},
      {:"workspace.create", yes: @owners ++ [:client_admin, :member_and_client_admin]},
      {:"workspace.rename", yes: @admins},
      {:"workspace.delete", yes: @operator_owners_admins},
      {:"workspace.restore", yes: @operator_owners_admins},
      {:"workspace.purge", yes: []},
      {:"node.read", yes: @all},
      {:"run.read", yes: @all},
      {:"run.read_log", yes: @all},
      {:"security_policy.read", yes: @all},
      {:"security_policy.edit", yes: @writers},
      {:"security_policy.lock", yes: @operator_owners},
      {:"security_policy.set_mode", yes: @admins},
      {:"secret.read", yes: @all},
      {:"secret.write", yes: @admins},
      {:"secret.use", yes: @admins},
      {:"variable.read", yes: @all},
      {:"variable.edit", yes: @admins},
      {:"connection.read", yes: @all},
      {:"connection.write", yes: @admins},
      {:"run.post_events", yes: []},
      {:"run_configuration.fetch", yes: []},
      {:"run.read_diagnostics", yes: [], on: :run},
      {:"run.list_instance", yes: [], on: :run},
      {:"secret.seal", yes: []},
      {:"run_credential.issue", yes: []},
      {:"workspace_access.add", yes: @admins},
      {:"workspace_access.remove", yes: @admins},
      {:"organisation.transfer", yes: @own_owners},
      {:"organisation.withdraw_transfer", yes: @own_owners},
      {:"organisation.accept_transfer", yes: []},
      {:"organisation.leave_operator", yes: @own_owners},
      {:"organisation_policy.read", yes: @all -- [:client_member]},
      {:"organisation_policy.edit", yes: @operator_owners},
      {:"organisation_policy.set_floor", yes: @operator_owners},
      {:"organisation_policy.set_switch", yes: @operator_owners},
      {:"organisation_variable.read", yes: @all -- [:client_member]},
      {:"organisation_variable.edit", yes: @admins},
      {:"organisation_secret.read", yes: @all -- [:client_member]},
      {:"organisation_secret.write", yes: @admins},
      {:"organisation_secret.use", yes: @admins},
      {:"adapter.read", yes: @all},
      {:"collection.assign", yes: @admins},
      {:"collection.set_backlog", yes: @admins},
      # The instance's alone, by itself: refused to every person in the client.
      {:"adapter.install", yes: []},
      {:"node.install", yes: []},
      {:"collection.move", yes: []},
      {:"work_item.read", yes: @all},
      {:"work_item.take_in", yes: @writers},
      {:"work_item.undo", yes: @writers},
      {:"work_item.close", yes: @writers},
      {:"work_item.answer", yes: @writers},
      {:"work_item.review_comment", yes: @writers},
      {:"work_item.confirm", yes: @writers},
      {:"work_item.explore_again", yes: @writers},
      {:"work_item.comment", yes: @writers},
      {:"work_item.comment_delete", yes: @admins},
      {:"process.edit", yes: @admins},
      {:"gate.approve", yes: @writers},
      {:"artifact.write", yes: @writers},
      {:"artifact_type.edit", yes: @admins},
      {:"target.set_further_repositories", yes: @admins},
      {:"target.rebuild_environment", yes: @writers}
    ] ++
      Enum.map(@operator_held, &{&1, yes: @operator_owners_admins}) ++
      Enum.map(@chain_held, &{&1, yes: @chain_on_organisation}) ++
      Enum.map(@adapter_keys, &{&1, yes: [], on: :adapter}) ++
      Enum.map(@pool_keys, &{&1, yes: []}) ++
      Enum.map(@instance_only ++ @not_here, &{&1, yes: []})
  end

  @doc false
  def operator_held, do: @operator_held

  @doc false
  def chain_held, do: @chain_held

  @doc false
  def operator_owners_admins, do: @operator_owners_admins

  @doc false
  # The client made while the flag is off, with its owner, then the flag on, on the
  # client's providers: the actors, `member` for what is asked of an account, and the core's
  # `instance_admin`, who saved the mail settings that some actions are asked of.
  def setup(made), do: setup(made, :organisation)

  @doc false
  # As `setup/1`, with the client's switch set to `chain` by its operator.
  def setup(_made, chain) do
    ApiaryPro.Flags.put_transfers(true)
    ApiaryPro.Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    owner = client.owner.scope

    operator_admin = member_fixture(operator.scope, :admin).user
    operator_member = member_fixture(operator.scope, :member).user
    owner_and_member = member_fixture(operator.scope, :owner).user
    member_and_admin = member_fixture(operator.scope, :member).user
    admin_and_owner = member_fixture(operator.scope, :admin).user

    join_fixture(owner, owner_and_member)
    joined(owner, member_and_admin, :admin)
    joined(owner, admin_and_owner, :owner)

    ApiaryPro.Flags.put_operator_infrastructure(true)

    client = model_chain_fixture(operator.scope, client, chain)
    owner = client.owner.scope

    client_admin = client_member_fixture(client, :admin)
    client_member = client_member_fixture(client, :member)
    in_client = &scope_in(&1, client.organisation, client.workspace)

    %{
      # An adapter of the instance beside the client: what an adapter's key is asked of.
      places: %{client: Map.put(client, :adapter, Apiary.NodesFixtures.adapter_fixture())},
      scopes: %{
        member: client_member.scope,
        instance_admin: instance_admin_scope(),
        client_owner: owner,
        client_admin: client_admin.scope,
        client_member: client_member.scope,
        operator_owner: client.scope,
        operator_admin: in_client.(operator_admin),
        operator_member: in_client.(operator_member),
        owner_and_client_member: in_client.(owner_and_member),
        member_and_client_admin: in_client.(member_and_admin),
        admin_and_client_owner: in_client.(admin_and_owner)
      }
    }
  end

  defp joined(owner, user, level) do
    %{membership: membership} = join_fixture(owner, user)
    {:ok, _} = Organisations.set_member_level(owner, membership.id, level)
  end

  @doc false
  def place(_action, actor) when actor in @all, do: :client
  def place(_action, _actor), do: nil

  @doc false
  def refusal(action, actor, _subject) do
    cond do
      action in (@not_here ++ @adapter_keys ++ @instance_only) ->
        :not_found

      action in @operator_held and actor not in @operator_owners_admins ->
        :not_found

      true ->
        :forbidden
    end
  end
end

defmodule ApiaryPro.OperatorAsOwnerGatewayAccessRows do
  @moduledoc false
  # The rows of the access test for the organisation-level gateways while the operator
  # owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`): the nodes' and the
  # access keys' actions, asked at an organisation's place, of the operator and of its
  # client, where those gateways live with no workspace (`Apiary.Gateways`). Asked by
  # `ApiaryPro.OperatorAsOwnerAccessTest` beside `ApiaryPro.OperatorAsOwnerAccessRows`,
  # whose actors ask in the client, at its organisation's place. The operator's own
  # actors:
  #
  #     at_operator_owner          an owner of the operator, asking there
  #     at_operator_admin          an admin of the operator, likewise
  #     at_operator_member         a member of the operator, likewise: reads
  #     client_owner_at_operator   an owner of the client, whose scope is the client's,
  #     client_admin_at_operator   an admin, and a member of the client, asking of the
  #     client_member_at_operator  operator's place, which they do not reach: not found
  #
  # At the operator's place its owners and admins make, change and delete its gateways
  # and their keys, and its members read them. At the client's place only the operator's
  # owners and admins do, whatever their level in the client; everyone else in the client
  # reads, and finds nothing to change.

  import ApiaryPro.OperatorsFixtures
  import Apiary.OrganisationsFixtures

  @at_operator [
    :at_operator_owner,
    :at_operator_admin,
    :at_operator_member,
    :client_owner_at_operator,
    :client_admin_at_operator,
    :client_member_at_operator
  ]

  @at_client ApiaryPro.OperatorAsOwnerAccessRows.actors()

  @operator_owners_admins [
    :operator_owner,
    :operator_admin,
    :owner_and_client_member,
    :admin_and_client_owner
  ]

  @writes [
    :"node.create",
    :"node.edit",
    :"node.set_limit",
    :"node.delete",
    :"node.clear_instance",
    :"access_key.create_code",
    :"access_key.cancel_code",
    :"access_key.add",
    :"access_key.revoke"
  ]

  @doc false
  def actions, do: [:"node.read" | @writes]

  @doc false
  def actors, do: @at_operator ++ @at_client

  @doc false
  def rows do
    [
      {:"node.read",
       yes: [:at_operator_owner, :at_operator_admin, :at_operator_member | @at_client],
       on: :organisation}
    ] ++
      Enum.map(
        @writes,
        &{&1,
         yes: [:at_operator_owner, :at_operator_admin | @operator_owners_admins],
         on: :organisation}
      )
  end

  @doc false
  # The operator's people, and the client's, the client made while the flag is off, with
  # its owner, then the flag on, as `ApiaryPro.OperatorAsOwnerAccessRows` makes them; the
  # operator a place of its own.
  def setup(%{places: %{client: client}, scopes: scopes}) do
    ApiaryPro.Flags.put_operator_infrastructure(false)
    operator_id = ApiaryPro.Tenants.operator_id(client.organisation)
    operator = Apiary.Repo.get!(Apiary.Organisations.Organisation, operator_id)
    owner = scope_in(scopes.operator_owner.user, operator)
    admin = scope_in(member_fixture(owner, :admin).user, operator)
    member = scope_in(member_fixture(owner, :member).user, operator)
    ApiaryPro.Flags.put_operator_infrastructure(true)

    %{
      places: %{operator: %{organisation: operator, workspace: nil}},
      scopes: %{
        at_operator_owner: owner,
        at_operator_admin: admin,
        at_operator_member: member,
        client_owner_at_operator: scopes.client_owner,
        client_admin_at_operator: scopes.client_admin,
        client_member_at_operator: scopes.client_member
      }
    }
  end

  @doc false
  def place(_action, actor) when actor in @at_operator, do: :operator
  def place(_action, actor) when actor in @at_client, do: :client
  def place(_action, _actor), do: nil

  @doc false
  def refusal(action, actor, _subject) do
    cond do
      actor in [:client_owner_at_operator, :client_admin_at_operator, :client_member_at_operator] ->
        :not_found

      actor in @at_client and action in @writes and actor not in @operator_owners_admins ->
        :not_found

      true ->
        :forbidden
    end
  end
end

defmodule ApiaryPro.OperatorAsOwnerOperatorChainAccessRows do
  @moduledoc false
  # The rows of the access test for what the client's switch decides, while the operator
  # owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`) and the switch is on the
  # operator's providers, `ApiaryPro.OperatorAsOwnerAccessRows`'s actors asking as there:
  # the model providers and runtimes, and the model choices, are the operator's owners' and
  # admins', and not there for anyone else. The time limits and the retention, which the
  # operator holds whatever the switch, beside them.

  alias ApiaryPro.OperatorAsOwnerAccessRows, as: Rows

  @asked Rows.chain_held() ++ [:"time_limit.edit", :"retention.edit"]

  @doc false
  def actions, do: @asked

  @doc false
  defdelegate actors, to: Rows

  @doc false
  def rows, do: Enum.map(@asked, &{&1, yes: Rows.operator_owners_admins()})

  @doc false
  def setup(made), do: Rows.setup(made, :operator)

  @doc false
  defdelegate place(action, actor), to: Rows

  @doc false
  def refusal(_action, _actor, _subject), do: :not_found
end
