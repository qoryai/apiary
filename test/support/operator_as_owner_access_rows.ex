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
  # The operator operates Main. In Main, the operator's owners and admins act at their
  # level on what the operator changes there (`ApiaryPro.Access`'s `@operator_in_workspace`):
  # its nodes, a pool's limit and keys, its time limits and retention, the harness saved in
  # it, its process and artifact types, and, on the operator's providers, its model
  # choices; someone in both at the higher of their two levels. Everything else in Main they
  # read. Of what the client owns as a whole, a person of the operator with no membership
  # there reads its policy alone, and finds nothing else. What the operator sets in Main is
  # not there for anyone else, the client's owners and admins among them. The client's
  # people act in it, by their membership, as in any organisation. Policy requests are not
  # there for anyone.

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

  # A person of the operator with no membership in the client.
  @operator_only [:operator_owner, :operator_admin, :operator_member]
  # Everyone with a membership in the client.
  @in_client @all -- @operator_only
  # An owner of the client.
  @own_owners [:client_owner, :admin_and_client_owner]
  # An owner or an admin of the client.
  @own_admins @own_owners ++ [:client_admin, :member_and_client_admin]
  # The operator's owners and admins, whatever their level in the client.
  @operator_owners_admins [
    :operator_owner,
    :operator_admin,
    :owner_and_client_member,
    :admin_and_client_owner
  ]

  # What the operator sets in Main, whatever the switch: the operator's owners and admins
  # hold each, and it is not there for anyone else.
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
    :"time_limit.edit",
    :"retention.edit",
    :"harness.save"
  ]

  # What the operator changes in Main beside what it sets: the client's owners and admins
  # change it too.
  @operator_changes [:"process.edit", :"artifact_type.edit"]

  # What the client's switch decides: its model providers and runtimes, and the model
  # choices of its workspaces and targets.
  @chain_held [:"provider.write", :"runtime.write", :"model_choice.write"]

  # Who holds them on the client's providers: its owners and admins, and a person of the
  # operator who is one of them in the client at an equal or higher level there. Someone
  # who acts there through the operator, with no membership or a lower level, reads only.
  @chain_on_organisation @own_admins

  # Core's instance actions: not found in a client, for everyone.
  @instance_only [
    :"account.password_link",
    :"instance.mail_save",
    :"instance.mail_resend",
    :"instance.mail_on",
    :"instance.rename",
    :"instance.support_save",
    :"instance.features_save",
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
      {:"organisation.rename", yes: @own_admins},
      {:"organisation.delete", yes: @own_owners},
      {:"organisation.restore", yes: @own_owners},
      {:"organisation.purge", yes: []},
      {:"member.read", yes: @in_client},
      {:"member.invite", yes: @own_admins, on: :workspace},
      {:"member.change_level", yes: @own_owners, on: :workspace},
      {:"member.remove", yes: @own_admins, on: :workspace},
      {:"invitation.revoke", yes: @own_admins},
      {:"invitation.renew", yes: @own_admins},
      {:"invitation.accept", yes: []},
      {:"member.suspend", yes: @own_admins, on: :workspace},
      {:"member.activate", yes: @own_admins, on: :workspace},
      {:"instance_admin.grant", yes: []},
      {:"instance_admin.revoke", yes: []},
      {:"audit.read", yes: @own_admins},
      {:"audit.prune", yes: []},
      {:"workspace.create", yes: @own_admins},
      {:"workspace.rename", yes: @own_admins},
      {:"workspace.delete", yes: @own_admins},
      {:"workspace.restore", yes: @own_admins},
      {:"workspace.purge", yes: []},
      {:"node.read", yes: @all},
      {:"run.read", yes: @all},
      {:"run.read_log", yes: @all},
      {:"run.cancel", yes: @in_client},
      {:"security_policy.read", yes: @all},
      {:"security_policy.edit", yes: @in_client},
      {:"security_policy.lock", yes: @own_owners},
      {:"security_policy.set_mode", yes: @own_admins},
      {:"secret.read", yes: @in_client},
      {:"secret.write", yes: @own_admins},
      {:"secret.use", yes: @own_admins},
      {:"variable.read", yes: @in_client},
      {:"variable.edit", yes: @own_admins},
      {:"connection.read", yes: @in_client},
      {:"connection.write", yes: @own_admins},
      {:"adapter.connect", yes: @own_admins},
      {:"run.post_events", yes: []},
      {:"run_configuration.fetch", yes: []},
      {:"run.read_diagnostics", yes: [], on: :run},
      {:"run.list_instance", yes: [], on: :run},
      {:"secret.seal", yes: []},
      {:"run_credential.issue", yes: []},
      {:"workspace_access.add", yes: @own_admins},
      {:"workspace_access.remove", yes: @own_admins},
      {:"organisation.transfer", yes: @own_owners},
      {:"organisation.withdraw_transfer", yes: @own_owners},
      {:"organisation.accept_transfer", yes: []},
      {:"organisation.leave_operator", yes: @own_owners},
      {:"organisation_policy.read", yes: @own_admins},
      {:"organisation_policy.edit", yes: @own_owners},
      {:"organisation_policy.set_floor", yes: @own_owners},
      {:"organisation_policy.set_switch", yes: @own_owners},
      {:"organisation_variable.read", yes: @own_admins},
      {:"organisation_variable.edit", yes: @own_admins},
      {:"organisation_secret.read", yes: @own_admins},
      {:"organisation_secret.write", yes: @own_admins},
      {:"organisation_secret.use", yes: @own_admins},
      {:"adapter.read", yes: @in_client},
      {:"collection.assign", yes: @own_admins},
      {:"collection.set_backlog", yes: @own_admins},
      # The instance's alone, by itself: refused to every person in the client.
      {:"adapter.install", yes: []},
      {:"node.install", yes: []},
      {:"collection.move", yes: []},
      {:"work_item.read", yes: @all},
      {:"work_item.take_in", yes: @in_client},
      {:"work_item.undo", yes: @in_client},
      {:"work_item.close", yes: @in_client},
      {:"work_item.answer", yes: @in_client},
      {:"work_item.review_comment", yes: @in_client},
      {:"work_item.confirm", yes: @in_client},
      {:"work_item.explore_again", yes: @in_client},
      {:"work_item.comment", yes: @in_client},
      {:"work_item.comment_delete", yes: @own_admins},
      {:"gate.approve", yes: @in_client},
      {:"artifact.write", yes: @in_client},
      {:"target.set_further_repositories", yes: @own_admins},
      {:"target.rebuild_environment", yes: @in_client}
    ] ++
      Enum.map(@operator_held, &{&1, yes: @operator_owners_admins, on: :workspace}) ++
      Enum.map(
        @operator_changes,
        &{&1, yes: Enum.uniq(@own_admins ++ @operator_owners_admins)}
      ) ++
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
  def refusal(action, actor, subject) do
    cond do
      action in (@not_here ++ @adapter_keys ++ @instance_only) ->
        :not_found

      # The operator's people find nothing the organisation owns as a whole, and no
      # action asked of it, but what the operator changes in the workspace.
      actor in @operator_only and
          (match?(%Apiary.Organisations.Organisation{id: id} when is_binary(id), subject) or
             (Apiary.Access.action(action).asked_of == :organisation and
                action not in @operator_held)) ->
        :not_found

      action in @operator_held and actor not in @operator_owners_admins ->
        :not_found

      # The workspace's secrets and variables are not there for the operator's people.
      actor in @operator_only and action in [:"secret.read", :"variable.read"] ->
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
  # and their keys, and its members read them. At the client's place, where the operator
  # operates a workspace and not the client, the client's owners and admins do, and its
  # members read them; a person of the operator with no membership in the client finds
  # nothing there, and one in both acts at their level in the client.

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

  @operator_only [:operator_owner, :operator_admin, :operator_member]

  @own_admins [:client_owner, :client_admin, :member_and_client_admin, :admin_and_client_owner]

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
       yes:
         [:at_operator_owner, :at_operator_admin, :at_operator_member] ++
           (@at_client -- @operator_only),
       on: :organisation}
    ] ++
      Enum.map(
        @writes,
        &{&1, yes: [:at_operator_owner, :at_operator_admin | @own_admins], on: :organisation}
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
  def refusal(_action, actor, _subject) do
    cond do
      actor in [:client_owner_at_operator, :client_admin_at_operator, :client_member_at_operator] ->
        :not_found

      actor in @operator_only ->
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
  # Main's model choices are the operator's owners' and admins', and not there for anyone
  # else. The client's model providers and runtimes, which the client owns as a whole, are
  # not there for anyone: a level in the operator counts in Main alone. The time limits and
  # the retention, which the operator holds whatever the switch, beside them.

  alias ApiaryPro.OperatorAsOwnerAccessRows, as: Rows

  @in_main [:"model_choice.write", :"time_limit.edit", :"retention.edit"]
  @of_client [:"provider.write", :"runtime.write"]
  @asked @in_main ++ @of_client

  @doc false
  def actions, do: @asked

  @doc false
  defdelegate actors, to: Rows

  @doc false
  def rows do
    Enum.map(@in_main, &{&1, yes: Rows.operator_owners_admins()}) ++
      Enum.map(@of_client, &{&1, yes: []})
  end

  @doc false
  def setup(made), do: Rows.setup(made, :operator)

  @doc false
  defdelegate place(action, actor), to: Rows

  @doc false
  def refusal(_action, _actor, _subject), do: :not_found
end
