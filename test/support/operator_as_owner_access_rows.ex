defmodule ApiaryPro.OperatorAsOwnerAccessRows do
  @moduledoc false
  # The rows of the access test (`Apiary.AccessCase`) while
  # `ApiaryPro.Flags.operator_infrastructure?/0` is on: every action, asked in an
  # organisation whose workspace Main an operator operates, by the organisation's people, by
  # the operator's and by people in both. A table apart, asked by
  # `ApiaryPro.OperatorAsOwnerAccessTest`, not merged into the core's and the edition's, which ask
  # with the flag off. Each actor asks in Main:
  #
  #     operated_owner             an owner of the organisation, made before the flag was on
  #     operated_admin             an admin of the organisation
  #     operated_member            a member of the organisation
  #     operator_owner             an owner of the operator, with no membership in the organisation
  #     operator_admin             an admin of the operator, likewise
  #     operator_member            a member of the operator, likewise: read-only
  #     owner_and_operated_member  an owner of the operator who is a member of the organisation
  #     member_and_operated_admin  a member of the operator who is an admin of the organisation
  #     admin_and_operated_owner   an admin of the operator who is an owner of the organisation
  #
  # The operator operates Main. In Main, the operator's owners and admins act at their
  # level on what the operator changes there (`ApiaryPro.Access`'s `@operator_in_workspace`):
  # its time limits and retention, its process and artifact types, and its model choices;
  # someone in both at the higher of their two levels. Everything else in Main they read,
  # and change no node, access key or harness document there: the organisation's owners
  # and admins change those. Of what the organisation has as a whole, a person of the
  # operator with no membership there finds nothing. The organisation's people act in
  # Main, by their membership, as in any organisation, on everything the operator changes
  # there too but the time limits, which only a person acting through the operator sets
  # (`ApiaryPro.Access`'s `@operator_alone`).

  import ApiaryPro.OperatorsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  @all [
    :operated_owner,
    :operated_admin,
    :operated_member,
    :operator_owner,
    :operator_admin,
    :operator_member,
    :owner_and_operated_member,
    :member_and_operated_admin,
    :admin_and_operated_owner
  ]

  # A person of the operator with no membership in the organisation.
  @operator_only [:operator_owner, :operator_admin, :operator_member]
  # Everyone with a membership in the organisation.
  @in_operated @all -- @operator_only
  # An owner of the organisation.
  @own_owners [:operated_owner, :admin_and_operated_owner]
  # An owner or an admin of the organisation.
  @own_admins @own_owners ++ [:operated_admin, :member_and_operated_admin]
  # The operator's owners and admins, whatever their level in the organisation.
  @operator_owners_admins [
    :operator_owner,
    :operator_admin,
    :owner_and_operated_member,
    :admin_and_operated_owner
  ]

  # The nodes and access keys of Main: the organisation's owners and admins change them,
  # at their level there, and a level in the operator counts for nothing there. A person
  # of the operator with no membership in the organisation is forbidden them.
  @nodes_and_keys [
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

  # What the operator changes in Main: the organisation's owners and admins change it too.
  @operator_changes [
    :"retention.edit",
    :"process.edit",
    :"artifact_type.edit",
    :"model_choice.write"
  ]

  # What the operator alone changes in Main: the time limits.
  @operator_alone [:"time_limit.edit"]

  # The people who act in Main through the operator: the operator's owners and admins with
  # no membership in the organisation, and an owner of the operator who is a member there.
  # A member of the operator who is an admin of the organisation, and an admin of the
  # operator who is an owner there, act at their level in the organisation.
  @through_operator [:operator_owner, :operator_admin, :owner_and_operated_member]

  # The organisation's model providers and runtimes, which it owns as a whole: its owners
  # and admins change them, and a level in the operator counts for nothing there.
  @organisation_models [:"provider.write", :"runtime.write"]

  # Core's instance actions: not found in the organisation, for everyone.
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

  # An adapter's key alone, asked of the adapter, which is no organisation's: not found.
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

  # A node pool's key alone, asked of the organisation's workspace, its queue: no person
  # takes them, whatever their level, so they are refused to everyone in the organisation.
  @pool_keys [
    :"dispatch.claim",
    :"dispatch.dispatched",
    :"dispatch.release",
    :"dispatch.machine_log",
    :"dispatch.machine_end"
  ]

  # Not found in the organisation: the instance's actions.
  @not_here [
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
    :"instance.adopt"
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
      {:"member.read", yes: @in_operated},
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
      {:"workspace.create", yes: @own_owners},
      {:"workspace.rename", yes: @own_admins},
      {:"workspace.delete", yes: @own_admins},
      {:"workspace.restore", yes: @own_admins},
      {:"workspace.purge", yes: []},
      {:"node.read", yes: @all},
      {:"run.read", yes: @all},
      {:"run.read_log", yes: @all},
      {:"run.cancel", yes: @in_operated},
      {:"security_policy.read", yes: @all},
      {:"security_policy.edit", yes: @in_operated},
      {:"security_policy.lock", yes: @own_owners},
      {:"security_policy.set_mode", yes: @own_admins},
      {:"secret.read", yes: @in_operated},
      {:"secret.write", yes: @own_admins},
      {:"secret.use", yes: @own_admins},
      {:"variable.read", yes: @in_operated},
      {:"variable.edit", yes: @own_admins},
      {:"connection.read", yes: @in_operated},
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
      {:"organisation.withdraw_transfer", yes: @own_owners},
      {:"organisation.accept_transfer", yes: []},
      {:"organisation_policy.read", yes: @own_admins},
      {:"organisation_policy.edit", yes: @own_owners},
      {:"organisation_policy.set_floor", yes: @own_owners},
      {:"organisation_policy.set_switch", yes: @own_owners},
      {:"organisation_variable.read", yes: @own_admins},
      {:"organisation_variable.edit", yes: @own_admins},
      {:"organisation_secret.read", yes: @own_admins},
      {:"organisation_secret.write", yes: @own_admins},
      {:"organisation_secret.use", yes: @own_admins},
      {:"adapter.read", yes: @in_operated},
      {:"collection.assign", yes: @own_admins},
      {:"collection.set_backlog", yes: @own_admins},
      # The instance's alone, by itself: refused to every person in the organisation.
      {:"adapter.install", yes: []},
      {:"node.install", yes: []},
      {:"collection.move", yes: []},
      {:"model_key.refresh", yes: []},
      {:"work_item.read", yes: @all},
      {:"work_item.take_in", yes: @in_operated},
      {:"work_item.undo", yes: @in_operated},
      {:"work_item.close", yes: @in_operated},
      {:"work_item.answer", yes: @in_operated},
      {:"work_item.review_comment", yes: @in_operated},
      {:"work_item.confirm", yes: @in_operated},
      {:"work_item.explore_again", yes: @in_operated},
      {:"work_item.comment", yes: @in_operated},
      {:"work_item.comment_delete", yes: @own_admins},
      {:"gate.approve", yes: @in_operated},
      {:"artifact.write", yes: @in_operated},
      {:"target.set_further_repositories", yes: @own_admins},
      {:"target.rebuild_environment", yes: @in_operated},
      # The harness documents saved in Main: the organisation's owners and admins save
      # them, and a level in the operator counts for nothing there.
      {:"harness.save", yes: @own_admins}
    ] ++
      Enum.map(@nodes_and_keys, &{&1, yes: @own_admins, on: :workspace}) ++
      Enum.map(
        @operator_changes,
        &{&1, yes: Enum.uniq(@own_admins ++ @operator_owners_admins)}
      ) ++
      Enum.map(@operator_alone, &{&1, yes: @through_operator}) ++
      Enum.map(@organisation_models, &{&1, yes: @own_admins}) ++
      Enum.map(@adapter_keys, &{&1, yes: [], on: :adapter}) ++
      Enum.map(@pool_keys, &{&1, yes: []}) ++
      Enum.map(@instance_only ++ @not_here, &{&1, yes: []})
  end

  @doc false
  # The organisation made while the flag is off, with its owner, then the flag on: the
  # actors, `member` for what is asked of an account, and the core's `instance_admin`, who
  # saved the mail settings that some actions are asked of. The place `:operated` has the
  # operator's organisation under `:operator`.
  def setup(_made) do
    ApiaryPro.Flags.put_transfers(true)
    ApiaryPro.Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    operated = operated_fixture(operator.scope)
    owner = operated.owner.scope

    operator_admin = member_fixture(operator.scope, :admin).user
    operator_member = member_fixture(operator.scope, :member).user
    owner_and_member = member_fixture(operator.scope, :owner).user
    member_and_admin = member_fixture(operator.scope, :member).user
    admin_and_owner = member_fixture(operator.scope, :admin).user

    join_fixture(owner, owner_and_member)
    joined(owner, member_and_admin, :admin)
    joined(owner, admin_and_owner, :owner)

    ApiaryPro.Flags.put_operator_infrastructure(true)

    operated_admin = organisation_member_fixture(operated, :admin)
    operated_member = organisation_member_fixture(operated, :member)
    in_operated = &scope_in(&1, operated.organisation, operated.workspace)

    %{
      # An adapter of the instance beside the organisation: what an adapter's key is asked
      # of.
      places: %{
        operated:
          operated
          |> Map.put(:adapter, Apiary.NodesFixtures.adapter_fixture())
          |> Map.put(:operator, operator.organisation)
      },
      scopes: %{
        member: operated_member.scope,
        instance_admin: instance_admin_scope(),
        operated_owner: owner,
        operated_admin: operated_admin.scope,
        operated_member: operated_member.scope,
        operator_owner: operated.scope,
        operator_admin: in_operated.(operator_admin),
        operator_member: in_operated.(operator_member),
        owner_and_operated_member: in_operated.(owner_and_member),
        member_and_operated_admin: in_operated.(member_and_admin),
        admin_and_operated_owner: in_operated.(admin_and_owner)
      }
    }
  end

  defp joined(owner, user, level) do
    %{membership: membership} = join_fixture(owner, user)
    {:ok, _} = Organisations.set_member_level(owner, membership.id, level)
  end

  @doc false
  def place(_action, actor) when actor in @all, do: :operated
  def place(_action, _actor), do: nil

  @doc false
  def refusal(action, actor, subject) do
    cond do
      action in (@not_here ++ @adapter_keys ++ @instance_only) ->
        :not_found

      # The operator's people find nothing the organisation has as a whole, and no
      # action asked of it, but what the operator changes in the workspace.
      actor in @operator_only and
          (match?(%Apiary.Organisations.Organisation{id: id} when is_binary(id), subject) or
             (Apiary.Access.action(action).asked_of == :organisation and
                action not in (@operator_changes ++ @operator_alone))) ->
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
  # The rows of the access test for the organisation-level gateways while
  # `ApiaryPro.Flags.operator_infrastructure?/0` is on: the nodes' and the access keys'
  # actions, asked at the place of the operator and at the place of the organisation whose
  # workspace Main it operates, where those gateways are, in no workspace
  # (`Apiary.Gateways`). Asked by `ApiaryPro.OperatorAsOwnerAccessTest` beside
  # `ApiaryPro.OperatorAsOwnerAccessRows`, whose actors ask at the organisation's place.
  # The actors this module adds:
  #
  #     at_operator_owner            an owner of the operator, asking there
  #     at_operator_admin            an admin of the operator, likewise
  #     at_operator_member           a member of the operator, likewise: reads
  #     operated_owner_at_operator   an owner, an admin and a member of the organisation,
  #     operated_admin_at_operator   each with the organisation's scope, asking of the
  #     operated_member_at_operator  operator's place, which they do not reach: not found
  #
  # At the operator's place its owners and admins make, change and delete its gateways
  # and their keys, and its members read them. At the organisation's place the
  # organisation's owners and admins do, and its members read them; a person of the
  # operator with no membership in the organisation finds nothing there, and one in both
  # acts at their level in the organisation.

  import ApiaryPro.OperatorsFixtures
  import Apiary.OrganisationsFixtures

  @at_operator [
    :at_operator_owner,
    :at_operator_admin,
    :at_operator_member,
    :operated_owner_at_operator,
    :operated_admin_at_operator,
    :operated_member_at_operator
  ]

  @at_operated ApiaryPro.OperatorAsOwnerAccessRows.actors()

  @operator_only [:operator_owner, :operator_admin, :operator_member]

  @own_admins [
    :operated_owner,
    :operated_admin,
    :member_and_operated_admin,
    :admin_and_operated_owner
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
  def actors, do: @at_operator ++ @at_operated

  @doc false
  def rows do
    [
      {:"node.read",
       yes:
         [:at_operator_owner, :at_operator_admin, :at_operator_member] ++
           (@at_operated -- @operator_only),
       on: :organisation}
    ] ++
      Enum.map(
        @writes,
        &{&1, yes: [:at_operator_owner, :at_operator_admin | @own_admins], on: :organisation}
      )
  end

  @doc false
  # The operator's people and the organisation's, the organisation made while the flag is
  # off, with its owner, then the flag on, as `ApiaryPro.OperatorAsOwnerAccessRows` makes
  # them; the operator is the place `:operator`.
  def setup(%{places: %{operated: operated}, scopes: scopes}) do
    ApiaryPro.Flags.put_operator_infrastructure(false)
    operator = operated.operator
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
        operated_owner_at_operator: scopes.operated_owner,
        operated_admin_at_operator: scopes.operated_admin,
        operated_member_at_operator: scopes.operated_member
      }
    }
  end

  @doc false
  def place(_action, actor) when actor in @at_operator, do: :operator
  def place(_action, actor) when actor in @at_operated, do: :operated
  def place(_action, _actor), do: nil

  @doc false
  def refusal(_action, actor, _subject) do
    cond do
      actor in [
        :operated_owner_at_operator,
        :operated_admin_at_operator,
        :operated_member_at_operator
      ] ->
        :not_found

      actor in @operator_only ->
        :not_found

      true ->
        :forbidden
    end
  end
end
