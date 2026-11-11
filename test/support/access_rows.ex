defmodule Apiary.AccessRows do
  @moduledoc """
  AccessRows is the core's rows of the access test (`Apiary.AccessCase`): every action of
  the core, and which of the core's actors may take it on a workspace of one
  organisation, the place `home`. The actors:

      member        a member of the organisation
      admin         an admin of the organisation
      owner         an owner of the organisation
      other_owner   an owner of another organisation
      access_key    a node, with an access key of the workspace
      pool_key      a node pool, with an access key of the workspace, asked of that
                    workspace: its queue
      adapter_key   an adapter of the instance, with an access key enrolled on it,
                    asked of that adapter
      diagnostics_key
                    a diagnostics key of the instance, asked of a run of the place
      instance      the instance itself, in a job no person enqueued
      instance_admin
                    an instance admin: an owner of the instance's organisation
                    (`Apiary.Edition.instance_organisation_id/0`), asking in that
                    organisation's scope, the place `instance`
      instance_org_admin
                    an admin of the instance's organisation, asking there: no instance
                    admin
      feature_off   whoever the action is for, an owner, a key or the instance, on
                    an instance without the action's feature
      hidden        whoever the action is for, as feature_off, where the edition hides the
                    action's feature from people, or the part the action belongs to, of
                    its feature or of none, as the nodes' and their access keys' part
                    `nodes`: a person meets it as not found, and an access key and the
                    instance are never asked what is hidden

  Accepting an invitation is taken on the strength of the token, which no role is, and
  granting and revoking an instance admin on the strength of a release command run on the
  instance's machine: nobody's row says yes.

  The instance actions (`Apiary.Access.Action`'s `instance: true`) are the instance
  admin's: the instance step refuses anyone outside the instance's organisation, not
  found, the owner of `home` among them, and the role anyone else there, forbidden, as the
  admin of the instance's organisation. Their feature is asked of the instance, so the
  `hidden` actor, which hides it from people, may. A password link is the instance's too,
  asked of the member's account, as a release command makes one. Sending the mail
  settings' test link again and turning mail on are asked of the mail settings, which the
  instance admin saved: there the instance's scope passes the instance step, and its role
  is forbidden. On every other action
  the instance admin answers as an owner, and the admin of the instance's organisation as
  an admin, in the place `instance` (`rows/0`).
  Creating an organisation is a sign-up's, which asks nothing, in the core; an edition may
  let a signed-in person create one. Creating, deleting and restoring a workspace are
  asked of the organisation: an owner creates one, an owner or an admin deletes any
  workspace of it; purging is the instance's, once a deletion's grace period is over. The
  actions over people are asked of the workspace, as a page asks whether to show them.
  """

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node

  @owners [:owner]
  # An instance action of no feature, and one of a feature, which is asked of the instance:
  # the `hidden` actor, which hides it from people, may all the same.
  @instance_admins [:instance_admin, :feature_off, :hidden]
  @instance_admins_of_feature [:instance_admin, :hidden]

  @doc "actors/0 is the core's actors."
  @spec actors() :: [atom]
  def actors,
    do: [
      :member,
      :admin,
      :owner,
      :other_owner,
      :access_key,
      :pool_key,
      :adapter_key,
      :diagnostics_key,
      :instance,
      :feature_off,
      :hidden,
      :instance_admin,
      :instance_org_admin
    ]

  @doc """
  rows/0 is the core's rows: every action of the core, with the actors that may. On an
  action that is no instance action, the instance admin may what an owner may, and the
  admin of the instance's organisation what an admin may.
  """
  @spec rows() :: [{atom, keyword}]
  def rows do
    Enum.map(table(), fn {action, row} ->
      if Apiary.Access.action(action).instance,
        do: {action, row},
        else: {action, Keyword.update!(row, :yes, &in_instance_organisation/1)}
    end)
  end

  defp in_instance_organisation(yes) do
    yes ++
      if(:owner in yes, do: [:instance_admin], else: []) ++
      if :admin in yes, do: [:instance_org_admin], else: []
  end

  defp table do
    [
      {:"organisation.create", yes: []},
      {:"organisation.rename", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"organisation.delete", yes: @owners ++ [:feature_off, :hidden]},
      {:"organisation.restore", yes: @owners ++ [:feature_off, :hidden]},
      {:"organisation.purge", yes: [:instance, :feature_off, :hidden]},
      {:"member.read", yes: @owners ++ [:member, :admin, :feature_off, :hidden]},
      {:"member.invite", yes: @owners ++ [:admin, :feature_off, :hidden], on: :workspace},
      {:"member.change_level", yes: @owners ++ [:feature_off, :hidden], on: :workspace},
      {:"member.remove", yes: @owners ++ [:admin, :feature_off, :hidden], on: :workspace},
      {:"invitation.revoke", yes: @owners ++ [:admin, :instance, :feature_off, :hidden]},
      {:"invitation.renew", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"invitation.accept", yes: []},
      {:"member.suspend", yes: @owners ++ [:admin, :feature_off, :hidden], on: :workspace},
      {:"member.activate", yes: @owners ++ [:admin, :feature_off, :hidden], on: :workspace},
      {:"instance_admin.grant", yes: []},
      {:"instance_admin.revoke", yes: []},
      {:"account.password_link", yes: [:instance_admin, :instance, :feature_off, :hidden]},
      {:"instance.mail_save", yes: @instance_admins},
      {:"instance.mail_resend", yes: @instance_admins},
      {:"instance.mail_on", yes: @instance_admins},
      {:"instance.rename", yes: @instance_admins},
      {:"instance.configure", yes: @instance_admins},
      {:"instance.support_save", yes: @instance_admins},
      {:"instance.read", yes: @instance_admins},
      {:"instance.read_machine", yes: @instance_admins},
      {:"instance.review_connections", yes: @instance_admins},
      {:"audit.read", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"audit.prune", yes: [:instance, :feature_off, :hidden]},
      {:"workspace.create", yes: @owners ++ [:feature_off, :hidden]},
      {:"workspace.rename", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"workspace.delete", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"workspace.restore", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"workspace.purge", yes: [:instance, :feature_off, :hidden]},
      {:"access_key.create_code", yes: @owners ++ [:admin, :feature_off]},
      {:"access_key.cancel_code", yes: @owners ++ [:admin, :feature_off]},
      {:"access_key.add", yes: @owners ++ [:admin, :feature_off]},
      {:"access_key.revoke", yes: @owners ++ [:admin, :feature_off]},
      {:"instance.read_observability", yes: @instance_admins_of_feature},
      {:"diagnostics_key.create", yes: @instance_admins_of_feature},
      {:"diagnostics_key.revoke", yes: @instance_admins_of_feature},
      {:"node.read", yes: @owners ++ [:member, :admin, :feature_off]},
      {:"node.create", yes: @owners ++ [:admin, :feature_off]},
      {:"node.edit", yes: @owners ++ [:admin, :feature_off]},
      {:"node.set_limit", yes: @owners ++ [:admin, :feature_off]},
      {:"node.delete", yes: @owners ++ [:admin, :feature_off]},
      {:"node.clear_instance", yes: @owners ++ [:admin, :feature_off]},
      {:"run.read", yes: @owners ++ [:member, :admin]},
      {:"run.read_log", yes: @owners ++ [:member, :admin]},
      {:"retention.edit", yes: @owners ++ [:admin]},
      {:"security_policy.read", yes: @owners ++ [:member, :admin]},
      {:"security_policy.edit", yes: @owners ++ [:member, :admin]},
      {:"security_policy.lock", yes: @owners},
      {:"security_policy.set_mode", yes: @owners ++ [:admin]},
      {:"secret.read", yes: @owners ++ [:member, :admin]},
      {:"secret.write", yes: @owners ++ [:admin]},
      {:"secret.use", yes: @owners ++ [:admin]},
      {:"variable.read", yes: @owners ++ [:member, :admin]},
      {:"variable.edit", yes: @owners ++ [:admin]},
      {:"connection.read", yes: @owners ++ [:member, :admin]},
      {:"connection.write", yes: @owners ++ [:admin]},
      {:"provider.write", yes: @owners ++ [:admin]},
      {:"runtime.write", yes: @owners ++ [:admin]},
      {:"model_choice.write", yes: @owners ++ [:admin]},
      {:"time_limit.edit", yes: @owners ++ [:admin]},
      {:"run.post_events", yes: [:access_key, :pool_key, :hidden]},
      {:"run_configuration.fetch", yes: [:access_key, :pool_key, :hidden]},
      {:"run.read_diagnostics", yes: [:diagnostics_key, :hidden], on: :run},
      {:"run.list_instance", yes: [:diagnostics_key, :hidden], on: :run},
      {:"secret.seal", yes: [:access_key, :hidden]},
      {:"run_credential.issue", yes: [:access_key, :hidden]},
      {:"adapter.read", yes: @owners ++ [:member, :admin]},
      {:"instance.read_factory", yes: @instance_admins_of_feature},
      {:"adapter.create", yes: @instance_admins_of_feature},
      {:"adapter.edit", yes: @instance_admins_of_feature},
      {:"adapter.set_interval", yes: @instance_admins_of_feature},
      {:"adapter.delete", yes: @instance_admins_of_feature},
      {:"adapter.install", yes: [:instance, :hidden]},
      {:"node.install", yes: [:instance, :hidden]},
      {:"adapter.setup", yes: @instance_admins_of_feature},
      {:"node.set_instance_limit", yes: @instance_admins_of_feature},
      {:"adapter.connect", yes: @owners ++ [:admin]},
      {:"collection.assign", yes: @owners ++ [:admin]},
      {:"collection.set_backlog", yes: @owners ++ [:admin]},
      {:"collection.move", yes: [:instance, :hidden]},
      {:"work_item.read", yes: @owners ++ [:member, :admin]},
      {:"work_item.take_in", yes: @owners ++ [:member, :admin]},
      {:"work_item.undo", yes: @owners ++ [:member, :admin]},
      {:"work_item.close", yes: @owners ++ [:member, :admin]},
      {:"work_item.answer", yes: @owners ++ [:member, :admin]},
      {:"work_item.review_comment", yes: @owners ++ [:member, :admin]},
      {:"work_item.confirm", yes: @owners ++ [:member, :admin]},
      {:"work_item.explore_again", yes: @owners ++ [:member, :admin]},
      {:"work_item.comment", yes: @owners ++ [:member, :admin]},
      # Asked of the workspace, as a page asks whether to show the button at all: the role
      # alone answers. A comment's author is asked of the comment (`test/apiary/access_test.exs`).
      {:"work_item.comment_delete", yes: @owners ++ [:admin]},
      {:"process.edit", yes: @owners ++ [:admin]},
      {:"gate.approve", yes: @owners ++ [:member, :admin]},
      {:"artifact.write", yes: @owners ++ [:member, :admin]},
      {:"artifact_type.edit", yes: @owners ++ [:admin]},
      {:"workspace_type.edit", yes: @instance_admins_of_feature},
      {:"machine_type.rekey", yes: @instance_admins_of_feature},
      {:"adapter.declare", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.app_values_set", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.app_values_seal", yes: [:adapter_key, :hidden], on: :adapter},
      {:"source_item.post", yes: [:adapter_key, :hidden], on: :adapter},
      {:"work_item.read_changes", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.disconnect", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.report_grant", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.end_grant", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.read_grants", yes: [:adapter_key, :hidden], on: :adapter},
      {:"harness.save", yes: @owners ++ [:admin]},
      {:"harness.assigned", yes: @instance_admins_of_feature},
      {:"harness.unassigned", yes: @instance_admins_of_feature},
      {:"dispatch.claim", yes: [:pool_key, :hidden]},
      {:"dispatch.dispatched", yes: [:pool_key, :hidden]},
      {:"dispatch.release", yes: [:pool_key, :hidden]},
      {:"target.set_further_repositories", yes: @owners ++ [:admin]},
      {:"dispatch.machine_log", yes: [:pool_key, :hidden]},
      {:"dispatch.machine_end", yes: [:pool_key, :hidden]},
      {:"target.rebuild_environment", yes: @owners ++ [:member, :admin]}
    ]
  end

  @doc """
  setup/1 makes the core's place, `home`, an organisation with its workspace, beside an
  adapter of the instance (`adapter`), and the scopes of the core's actors in it. The
  adapter's key, `adapter_key`, is a key enrolled on it by an instance admin, its scope
  that of the server contract (`Apiary.Accounts.Scope.for_access_key/1`): no organisation,
  and no workspace. The pool's key, `pool_key`, is a key of a node pool of the workspace.
  """
  @spec setup(map) :: %{places: map, scopes: map}
  def setup(_made) do
    home = sign_up_fixture()
    owner = home.scope
    %{access_key: key} = access_key_fixture(owner)
    pool = Apiary.NodesFixtures.pool_fixture(owner)
    %{access_key: pool_key} = access_key_fixture(owner, node: pool)
    adapter = Apiary.NodesFixtures.adapter_fixture()
    instance_admin = instance_admin_scope()
    %{access_key: adapter_key} = enrolled_key_fixture(instance_admin, adapter)

    instance = %{
      organisation: instance_admin.organisation,
      workspace: instance_admin.workspace,
      adapter: adapter
    }

    %{
      places: %{home: Map.put(home, :adapter, adapter), instance: instance},
      scopes: %{
        member: member_fixture(owner, :member).scope,
        admin: member_fixture(owner, :admin).scope,
        owner: owner,
        other_owner: sign_up_fixture().scope,
        access_key: Scope.for_access_key(key),
        pool_key: Scope.for_access_key(pool_key),
        adapter_key: Scope.for_access_key(adapter_key),
        diagnostics_key: Scope.for_access_key(diagnostics_key()),
        instance: Scope.for_instance(home.organisation, home.workspace),
        instance_admin: instance_admin,
        instance_org_admin: member_fixture(instance_admin, :admin).scope
      }
    }
  end

  # A diagnostics key as the signed request carries it: `Apiary.Access` reads its node's
  # kind and its place, and no row.
  defp diagnostics_key do
    id = Ecto.UUID.generate()
    %AccessKey{node_id: id, node: %Node{id: id, kind: :diagnostics}}
  end

  @doc """
  place/2 is where the core's actors ask: the instance admin and the admin of the
  instance's organisation in the instance's organisation, the place `instance`; the
  others at home.
  """
  @spec place(atom, atom) :: atom | nil
  def place(_action, actor) when actor in [:instance_admin, :instance_org_admin], do: :instance
  def place(_action, actor), do: if(actor in actors(), do: :home)

  @doc """
  refusal/3 is why the core's answer is no where it is not the role: an instance action is
  not found outside the instance's organisation, and forbidden to anyone there but an
  instance admin, and to the instance's scope on the mail settings; a feature that is off or hidden is not found, and so is a hidden part, anything of another organisation, an
  organisation that does not exist yet, which is no place, an adapter, which is the
  instance's, to anyone but its key, to an adapter's key, anything but that adapter, to a
  diagnostics key, anything but the diagnostics of a run, and, to a node pool's key,
  anything but its workspace: it is asked of no node here, and the organisation is beyond
  its workspace. A run of its workspace is in its place, and the role refuses it.
  """
  @spec refusal(atom, atom, term) :: :not_found | :forbidden | nil
  def refusal(action, actor, subject) do
    cond do
      # An instance action: its feature, then the instance step, then the role.
      Apiary.Access.action(action).instance and actor == :feature_off ->
        :not_found

      Apiary.Access.action(action).instance ->
        if actor == :instance_org_admin or
             (actor == :instance and match?(%Apiary.Mail.Settings{}, subject)),
           do: :forbidden,
           else: :not_found

      actor == :feature_off and Apiary.Access.feature(action) != nil ->
        :not_found

      actor == :hidden and Apiary.Access.shown_as(action) != nil ->
        :not_found

      actor == :other_owner ->
        :not_found

      Apiary.Access.action(action).asked_of == :new_organisation ->
        :not_found

      actor == :adapter_key and not match?(%Apiary.Nodes.Node{kind: :adapter}, subject) ->
        :not_found

      actor == :diagnostics_key ->
        :not_found

      actor == :pool_key and match?(%Apiary.Runs.Run{}, subject) ->
        :forbidden

      actor == :pool_key and not match?(%Apiary.Organisations.Workspace{}, subject) ->
        :not_found

      actor != :adapter_key and
          match?(%Apiary.Nodes.Node{kind: :adapter, organisation_id: nil}, subject) ->
        :not_found

      true ->
        nil
    end
  end
end
