defmodule ApiaryPro.AccessRows do
  @moduledoc """
  AccessRows is the edition's rows of the access test (`Apiary.AccessCase`), merged
  into the core's (`Apiary.AccessRows`): every action the edition adds, and what its actors may of
  the core's. The actors:

      unreached_member    a member of the organisation, not added to the workspace
      client_owner        an owner of a client of an operator, in the client: an owner as
                          anywhere, who may also leave the operator
      operator_owner      an owner of an operator, in a client of it, through the operator:
                          read-only
      operator_admin      an admin of that operator, in the same client: read-only
      operator_member     a member of that operator, in the same client: read-only
      operator_elsewhere  an owner of an operator, on an organisation it does not manage
      instance_reader     an instance admin, without a membership in the organisation:
                          read-only
      instance_owner      an instance admin, in the instance organisation, where the
                          instance actions are asked: of the instance organisation; to
                          change a kind, purge, suspend, activate or transfer, of the
                          organisation; to suspend or activate an account, of the member's;
                          of the mail settings, which the core's `instance_admin` saved

  The core's `instance_admin` and `instance_org_admin` ask in the instance organisation,
  of it, made an operator here.

  A client owns its people: its owner acts there as an owner anywhere. An operator's
  people read everything in its clients at every level, and change nothing there; an
  instance admin reads every organisation they reach neither way, and changes it only by
  the instance actions. Both are the role `reader`. An operator's actions over its
  clients are asked in an operator, the instance organisation among them, which the
  world makes one as the first sign-up of an instance with `managed_organisations` does;
  leaving an operator in a client; the instance actions in the instance organisation
  alone. Creating an
  organisation is a person's own, asked of the new organisation, of a kind the suite's
  configuration opens: everyone signed in may, wherever they ask from.
  """

  import ApiaryPro.OperatorsFixtures
  import Apiary.OrganisationsFixtures

  @operators [:operator_owner, :operator_admin, :operator_member]
  @readers @operators ++ [:instance_reader]
  @people [
            :member,
            :unreached_member,
            :admin,
            :owner,
            :client_owner,
            :other_owner,
            :operator_elsewhere,
            :instance_owner,
            :instance_admin,
            :instance_org_admin
          ] ++ @readers
  @owners [:client_owner, :instance_owner, :instance_admin]
  # The instance actions the edition adds, by whether they are taken of the instance organisation
  # itself, which the core's instance admin asks of, and whether they have a feature: the
  # feature's rows take it away (`feature_off`), and no edition hides an instance action
  # (`hidden`).
  @instance_itself [:instance_owner, :instance_admin, :feature_off, :hidden]
  @instance_itself_of_feature [:instance_owner, :instance_admin, :hidden]
  # An admin of an operator, in the instance organisation, which is one here.
  @operator_admins [:instance_owner, :instance_admin, :instance_org_admin]
  # Who asks in the instance organisation.
  @in_instance_organisation @operator_admins ++ [:feature_off, :hidden]

  # The actions an operator takes over its clients: asked where they are not, in an
  # organisation of another kind, they are not found.
  @placed [
    :"client.read",
    :"client.create",
    :"client.invite_owner",
    :"client.revoke_owner_invitation",
    :"client.renew_owner_invitation",
    :"client.accept",
    :"client.grant_features",
    :"client.drop",
    :"client.delete",
    :"policy_request.send",
    :"policy_request.withdraw"
  ]

  # The first admin's invitation, not found for everyone while the operator does not own
  # its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), as in this table.
  @admin_invitations [
    :"client.invite_admin",
    :"client.revoke_admin_invitation",
    :"client.renew_admin_invitation"
  ]

  # The operator's choice of the model providers a client uses, not found for everyone
  # while the operator does not own its clients, as in this table.
  @needs_operator_infrastructure [:"client.set_model_chain"]

  # The actions of a client over its place: asked in an organisation with no operator,
  # they are not found.
  @in_clients [
    :"organisation.leave_operator",
    :"policy_request.accept",
    :"policy_request.decline"
  ]

  # The instance actions asked of another organisation than the instance organisation.
  @on_another [
    :"instance.change_kind",
    :"instance.purge_organisation",
    :"instance.suspend_organisation",
    :"instance.activate_organisation",
    :"instance.transfer",
    :"instance.grant_features"
  ]

  @doc "actors/0 is the edition's actors."
  @spec actors() :: [atom]
  def actors do
    [
      :unreached_member,
      :client_owner,
      :operator_owner,
      :operator_admin,
      :operator_member,
      :operator_elsewhere,
      :instance_reader,
      :instance_owner
    ]
  end

  @doc "readers/0 is the actors who read an organisation they have no membership in."
  @spec readers() :: [atom]
  def readers, do: @readers

  @doc """
  rows/0 is the edition's rows: every action the edition adds, with the actors that may, the
  core's among them, and, for the core's actions, those of the edition's actors that may
  too.
  """
  @spec rows() :: [{atom, keyword}]
  def rows do
    [
      # What the edition's actors may of the core's actions.
      {:"organisation.create",
       yes: @people ++ [:member, :admin, :owner, :other_owner, :feature_off, :hidden]},
      {:"account.password_link", yes: [:instance_owner]},
      {:"instance.mail_save", yes: [:instance_owner]},
      # Asked of the mail settings, which the core's `instance_admin` saved: only that
      # person may, and any other instance admin gets `:not_saver`.
      {:"instance.mail_resend", yes: []},
      {:"instance.mail_on", yes: []},
      {:"instance.rename", yes: [:instance_owner]},
      {:"instance.configure", yes: [:instance_owner]},
      {:"instance.support_save", yes: [:instance_owner]},
      {:"instance.review_connections", yes: [:instance_owner]},
      {:"instance.read_factory", yes: [:instance_owner]},
      {:"instance.read_observability", yes: [:instance_owner]},
      {:"instance.read_machine", yes: [:instance_owner]},
      {:"diagnostics_key.create", yes: [:instance_owner]},
      {:"diagnostics_key.revoke", yes: [:instance_owner]},
      {:"node.set_instance_limit", yes: [:instance_owner]},
      {:"organisation.rename", yes: @owners},
      {:"organisation.delete", yes: [:client_owner]},
      {:"organisation.restore", yes: @owners},
      {:"member.read", yes: [:unreached_member] ++ @owners ++ @readers},
      {:"member.invite", yes: @owners},
      {:"member.change_level", yes: @owners},
      {:"member.remove", yes: @owners},
      {:"invitation.revoke", yes: @owners},
      {:"invitation.renew", yes: @owners},
      {:"member.suspend", yes: @owners},
      {:"member.activate", yes: @owners},
      {:"audit.read", yes: @owners ++ @readers},
      {:"workspace.create", yes: @owners},
      {:"workspace.rename", yes: @owners},
      {:"workspace.delete", yes: @owners},
      {:"workspace.restore", yes: @owners},
      {:"access_key.create_code", yes: @owners},
      {:"access_key.cancel_code", yes: @owners},
      {:"access_key.add", yes: @owners},
      {:"access_key.revoke", yes: @owners},
      {:"node.read", yes: @owners ++ @readers},
      {:"node.create", yes: @owners},
      {:"node.edit", yes: @owners},
      {:"node.set_limit", yes: @owners},
      {:"node.delete", yes: @owners},
      {:"node.clear_instance", yes: @owners},
      {:"run.read", yes: @owners ++ @readers},
      {:"run.read_log", yes: @owners ++ @readers},
      # Only a diagnostics key may, in the core's rows: none of the edition's actors.
      {:"run.read_diagnostics", yes: []},
      {:"run.list_instance", yes: []},
      {:"retention.edit", yes: @owners},
      {:"security_policy.read", yes: @owners ++ @readers},
      {:"security_policy.edit", yes: @owners},
      {:"security_policy.lock", yes: @owners},
      {:"security_policy.set_mode", yes: @owners},
      {:"secret.read", yes: @owners ++ @readers},
      {:"secret.write", yes: @owners},
      {:"secret.use", yes: @owners},
      {:"variable.read", yes: @owners ++ @readers},
      {:"variable.edit", yes: @owners},
      # Asked of the organisation: a member not added to the workspace reads them too.
      {:"connection.read", yes: [:unreached_member] ++ @owners ++ @readers},
      {:"connection.write", yes: @owners},
      {:"provider.write", yes: @owners},
      {:"runtime.write", yes: @owners},
      {:"model_choice.write", yes: @owners},
      {:"time_limit.edit", yes: @owners},
      {:"adapter.read", yes: [:unreached_member] ++ @owners ++ @readers},
      {:"adapter.create", yes: [:instance_owner]},
      {:"adapter.edit", yes: [:instance_owner]},
      {:"adapter.set_interval", yes: [:instance_owner]},
      {:"adapter.delete", yes: [:instance_owner]},
      # The instance's alone, by itself.
      {:"adapter.install", yes: []},
      {:"adapter.setup", yes: [:instance_owner]},
      {:"adapter.connect", yes: @owners},
      {:"collection.assign", yes: @owners},
      {:"collection.set_backlog", yes: @owners},
      # The instance's alone, by itself.
      {:"collection.move", yes: []},
      {:"workspace_type.edit", yes: [:instance_owner]},
      {:"machine_type.rekey", yes: [:instance_owner]},
      {:"work_item.read", yes: @owners ++ @readers},
      {:"work_item.take_in", yes: @owners},
      {:"work_item.undo", yes: @owners},
      {:"work_item.close", yes: @owners},
      {:"work_item.answer", yes: @owners},
      {:"work_item.review_comment", yes: @owners},
      {:"work_item.confirm", yes: @owners},
      {:"work_item.explore_again", yes: @owners},
      {:"work_item.comment", yes: @owners},
      {:"work_item.comment_delete", yes: @owners},
      {:"process.edit", yes: @owners},
      {:"gate.approve", yes: @owners},
      {:"artifact.write", yes: @owners},
      {:"artifact_type.edit", yes: @owners},
      {:"target.set_further_repositories", yes: @owners},
      {:"target.rebuild_environment", yes: @owners},
      {:"harness.save", yes: @owners},
      {:"harness.assigned", yes: [:instance_owner]},
      {:"harness.unassigned", yes: [:instance_owner]},
      # An adapter's key alone, asked of the adapter: none of the edition's actors.
      {:"adapter.declare", yes: []},
      {:"adapter.app_values_set", yes: []},
      {:"adapter.app_values_seal", yes: []},
      {:"source_item.post", yes: []},
      {:"work_item.read_changes", yes: []},
      {:"adapter.disconnect", yes: []},
      # A node pool's key alone, asked of the workspace, its queue: none of the edition's actors.
      {:"dispatch.claim", yes: []},
      {:"dispatch.dispatched", yes: []},
      {:"dispatch.release", yes: []},
      {:"dispatch.machine_log", yes: []},
      {:"dispatch.machine_end", yes: []},
      # The edition's actions.
      {:"workspace_access.add",
       yes: [:owner, :admin, :instance_org_admin, :feature_off, :hidden] ++ @owners},
      {:"workspace_access.remove",
       yes: [:owner, :admin, :instance_org_admin, :feature_off, :hidden] ++ @owners},
      {:"organisation.transfer", yes: [:owner, :client_owner, :feature_off, :hidden]},
      {:"organisation.withdraw_transfer", yes: [:owner, :client_owner, :feature_off, :hidden]},
      {:"organisation.accept_transfer", yes: []},
      {:"organisation.leave_operator", yes: [:client_owner]},
      {:"client.read", yes: @operator_admins},
      {:"client.create", yes: @operator_admins},
      {:"client.invite_owner", yes: @operator_admins},
      {:"client.revoke_owner_invitation", yes: @operator_admins},
      {:"client.renew_owner_invitation", yes: @operator_admins},
      {:"client.invite_admin", yes: []},
      {:"client.revoke_admin_invitation", yes: []},
      {:"client.renew_admin_invitation", yes: []},
      {:"client.accept", yes: [:instance_owner, :instance_admin]},
      {:"client.grant_features", yes: [:instance_owner, :instance_admin]},
      {:"client.drop", yes: [:instance_owner, :instance_admin]},
      {:"client.set_model_chain", yes: []},
      {:"client.delete", yes: [:instance_owner, :instance_admin]},
      {:"instance.read", yes: [:instance_owner]},
      {:"instance.create_organisation", yes: @instance_itself},
      {:"instance.create_operator", yes: @instance_itself_of_feature},
      {:"instance.change_kind", yes: @instance_itself_of_feature},
      # Asked of another organisation, as the instance owner asks: never of the instance
      # organisation itself, which the core's instance admin asks of.
      {:"instance.purge_organisation", yes: [:instance_owner]},
      {:"instance.suspend_account", yes: @instance_itself},
      {:"instance.activate_account", yes: @instance_itself},
      {:"instance.suspend_organisation", yes: [:instance_owner]},
      {:"instance.activate_organisation", yes: [:instance_owner]},
      {:"instance.transfer", yes: [:instance_owner]},
      {:"instance.grant_features", yes: [:instance_owner]},
      {:"instance.change_sign_up", yes: @instance_itself},
      # Taken after the migrations, by the instance, which no role takes.
      {:"instance.adopt", yes: []},
      {:"policy_request.send", yes: @operator_admins},
      {:"policy_request.withdraw", yes: @operator_admins},
      {:"policy_request.accept", yes: [:client_owner]},
      {:"policy_request.decline", yes: [:client_owner]},
      # The organisation's policy: read by its owners and admins and by the readers,
      # changed by its owners.
      {:"organisation_policy.read",
       yes: [:owner, :admin, :instance_org_admin] ++ @owners ++ @readers},
      {:"organisation_policy.edit", yes: [:owner] ++ @owners},
      {:"organisation_policy.set_floor", yes: [:owner] ++ @owners},
      {:"organisation_policy.set_switch", yes: [:owner] ++ @owners},
      # The organisation's variables: read by its owners and admins and by the readers,
      # changed by its owners and admins. A client is shown them as its operator is
      # granted them: `secrets`, which they need, is no grant's and shown to both.
      {:"organisation_variable.read",
       yes: [:owner, :admin, :instance_org_admin] ++ @owners ++ @readers},
      {:"organisation_variable.edit", yes: [:owner, :admin, :instance_org_admin] ++ @owners},
      # The organisation's secrets: read by its owners and admins and by the readers, as
      # its variables are; changed and linked by its owners and admins.
      {:"organisation_secret.read",
       yes: [:owner, :admin, :instance_org_admin] ++ @owners ++ @readers},
      {:"organisation_secret.write", yes: [:owner, :admin, :instance_org_admin] ++ @owners},
      {:"organisation_secret.use", yes: [:owner, :admin, :instance_org_admin] ++ @owners}
    ]
  end

  @doc """
  setup/1 makes the edition's places, `client`, a client of an operator, and
  `instance_organisation`, the suite's instance organisation as an instance admin sees it,
  made an operator, and the scopes of the edition's actors, given the core's `home`. The core's
  `instance_admin` and `instance_org_admin` ask in that organisation as an operator.
  """
  @spec setup(map) :: %{places: map, scopes: map}
  def setup(%{places: %{home: home}, scopes: %{owner: owner} = core}) do
    %{scope: unreached, membership: unreached_membership} = member_fixture(owner, :member)

    {:ok, _} = ApiaryPro.WorkspaceAccess.remove(owner, unreached_membership.id, home.workspace.id)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    operator_admin = member_fixture(operator.scope, :admin).user
    operator_member = member_fixture(operator.scope, :member).user
    admin = instance_admin_fixture()
    # The instance organisation an operator, as the first sign-up of an instance with
    # `managed_organisations`, which the access test runs with, makes it: its owners take
    # an operator's actions there as the instance's. Made one inside the test's sandbox
    # where the suite's first sign-up made it an organisation.
    instance_scope = make_instance_organisation_an_operator(admin)

    %{
      # The core's adapter, the instance's, beside each place: what an adapter's key is
      # asked of, wherever the edition's actors ask.
      places: %{
        client: Map.put(client, :adapter, home.adapter),
        instance_organisation: Map.put(instance_scope, :adapter, home.adapter)
      },
      scopes: %{
        # Asking in the workspace all the same, as a page loaded before they were removed
        # from it would, without the workspace access it no longer has.
        unreached_member: ApiaryPro.WorkspaceAccess.put(unreached, nil),
        client_owner: client.owner.scope,
        # The operator's people, in its client: through the relationship, not a
        # membership there.
        operator_owner: client.scope,
        operator_admin: scope_in(operator_admin, client.organisation, client.workspace),
        operator_member: scope_in(operator_member, client.organisation, client.workspace),
        # An operator's owner, asking in the operator of an organisation it does not
        # manage.
        operator_elsewhere: operator.scope,
        instance_reader: scope_in(admin.user, home.organisation, home.workspace),
        instance_owner: instance_scope,
        # The core's, as the instance organisation is now, an operator.
        instance_admin: again_in(core.instance_admin, instance_scope.organisation),
        instance_org_admin: again_in(core.instance_org_admin, instance_scope.organisation)
      }
    }
  end

  defp again_in(scope, organisation), do: scope_in(scope.user, organisation, scope.workspace)

  @doc """
  place/2 is where the edition's actors ask: the client's people and the operator's in the client;
  an instance admin in the instance organisation, of it, or of the organisation, `home`,
  for the instance actions taken on another; everyone else at home.
  """
  @spec place(atom, atom) :: atom | nil
  def place(_action, actor) when actor in [:client_owner | @operators], do: :client
  def place(action, :instance_owner) when action in @on_another, do: :home
  def place(_action, :instance_owner), do: :instance_organisation
  def place(_action, actor), do: if(actor in actors(), do: :home)

  @doc """
  refusal/3 is why the edition's answer is no where it is not the role: an organisation the
  operator does not manage, a workspace the member was not added to, an operator's
  action where there is no operator, a client's where there is no client, an instance
  action outside the instance organisation, all not found; an action of a person, with no
  place, forbidden; an instance action in the instance organisation, without the role or
  of what is not taken on the instance organisation itself, forbidden. On the mail
  settings, `instance_owner`, who did not save them, is `:not_saver`, and the instance's
  scope, which passes the instance step and holds no role there, is forbidden.
  """
  @spec refusal(atom, atom, term) :: :not_found | :forbidden | :not_saver | nil
  def refusal(action, actor, subject) do
    cond do
      action == :"organisation.create" ->
        :forbidden

      action in @admin_invitations or action in @needs_operator_infrastructure ->
        :not_found

      # An instance action, in the core's order: its feature, then the instance step, then
      # the role and the edition's rules. `feature_off` and `hidden` ask as the core's
      # instance admin.
      Apiary.Access.action(action).instance and actor == :feature_off and
          Apiary.Access.feature(action) != nil ->
        :not_found

      actor == :instance_owner and match?(%Apiary.Mail.Settings{}, subject) ->
        :not_saver

      actor == :instance and match?(%Apiary.Mail.Settings{}, subject) ->
        :forbidden

      Apiary.Access.action(action).instance ->
        if actor in @in_instance_organisation, do: :forbidden, else: :not_found

      actor == :operator_elsewhere ->
        :not_found

      actor == :unreached_member and
          (match?(%Apiary.Organisations.Workspace{}, subject) or
             match?(%Apiary.Runs.Run{}, subject)) ->
        :not_found

      action in @placed and actor not in @operator_admins ->
        :not_found

      action in @in_clients and actor not in [:client_owner | @operators] ->
        :not_found

      true ->
        nil
    end
  end
end

defmodule ApiaryPro.CoreAccessRows do
  @moduledoc false
  # The core's rows of the access test (`Apiary.AccessRows`), with the edition's results.
  # The core's table gives its instance admin every owner's action, asked of the instance
  # organisation. The edition forbids deleting that organisation for every role
  # (`ApiaryPro.Access`'s `@not_on_instance_organisation`), and a row of a later module only
  # adds to `yes:`, so the one entry goes here.

  alias Apiary.AccessRows

  defdelegate actors, to: AccessRows
  defdelegate setup(made), to: AccessRows
  defdelegate place(action, actor), to: AccessRows
  defdelegate refusal(action, actor, subject), to: AccessRows

  def rows do
    Enum.map(AccessRows.rows(), fn
      {:"organisation.delete", row} ->
        {:"organisation.delete", Keyword.update!(row, :yes, &(&1 -- [:instance_admin]))}

      row ->
        row
    end)
  end
end
