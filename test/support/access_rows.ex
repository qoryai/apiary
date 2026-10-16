defmodule Apiary.AccessRows do
  @moduledoc """
  AccessRows is the core's rows of the access test (`Apiary.AccessCase`): every action of
  the core, and which of the core's actors may take it on a workspace of one
  organisation, the place `home`. The actors:

      member        a member of the organisation
      admin         an admin of the organisation
      owner         an owner of the organisation
      other_owner   an owner of another organisation
      access_key    a gateway, with an access key of the workspace
      adapter_key   an adapter of the instance, with an access key enrolled on it,
                    asked of that adapter
      instance      the instance itself, in a job no person enqueued
      feature_off   whoever the action is for, an owner, an access key or the instance, on
                    an instance without the action's feature
      hidden        whoever the action is for, as feature_off, where the edition hides the
                    action's feature from people, or the part the action belongs to, of
                    its feature or of none, as the nodes' and their access keys' part
                    `nodes`: a person meets it as not found, and an access key and the
                    instance are never asked what is hidden

  Accepting an invitation is taken on the strength of the token, which no role is, and
  granting and revoking an instance admin on the strength of a release command run on the
  instance's machine: nobody's row says yes. Nor for a password link, which an instance
  admin makes, as `Apiary.Accounts.build_password_link/3` asks, or a release command, nor
  for saving the instance's mail settings and turning them on, an instance admin's, as
  `Apiary.Mail.save_settings/3` and `turn_on/2` ask, nor for setting the product's name,
  an instance admin's too, as `Apiary.ProductName.rename/2` asks, nor for changing the
  instance's settings, an instance admin's after a recent sign-in, as
  `Apiary.InstanceConfig.save/3` asks, nor for making, renaming and deleting an adapter of
  the instance, an instance admin's, as `Apiary.Adapters` asks. Creating an organisation
  is a sign-up's, which asks nothing, in the core; an edition may let a signed-in person
  create one. Creating, deleting and restoring a workspace are asked of the organisation:
  an owner creates one, an owner or an admin deletes any workspace of it; purging is the
  instance's, once a deletion's grace period is over. The actions over people are asked of
  the workspace, as a page asks whether to show them.
  """

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope

  @owners [:owner]

  @doc "actors/0 is the core's actors."
  @spec actors() :: [atom]
  def actors,
    do: [
      :member,
      :admin,
      :owner,
      :other_owner,
      :access_key,
      :adapter_key,
      :instance,
      :feature_off,
      :hidden
    ]

  @doc "rows/0 is the core's rows: every action of the core, with the actors that may."
  @spec rows() :: [{atom, keyword}]
  def rows do
    [
      {:"organisation.create", yes: []},
      {:"organisation.rename", yes: @owners ++ [:admin, :feature_off, :hidden]},
      {:"organisation.delete", yes: @owners ++ [:feature_off, :hidden]},
      {:"organisation.restore", yes: @owners ++ [:feature_off, :hidden]},
      {:"organisation.purge", yes: [:instance, :feature_off, :hidden]},
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
      {:"account.password_link", yes: []},
      {:"instance.mail_save", yes: []},
      {:"instance.mail_on", yes: []},
      {:"instance.rename", yes: []},
      {:"instance.configure", yes: []},
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
      {:"run.post_events", yes: [:access_key, :hidden]},
      {:"run_configuration.fetch", yes: [:access_key, :hidden]},
      {:"adapter.read", yes: @owners ++ [:member, :admin]},
      {:"adapter.create", yes: []},
      {:"adapter.edit", yes: []},
      {:"adapter.delete", yes: []},
      {:"adapter.connect", yes: @owners ++ [:admin]},
      {:"collection.assign", yes: @owners ++ [:admin]},
      {:"work_item.read", yes: @owners ++ [:member, :admin]},
      {:"work_item.take_in", yes: @owners ++ [:member, :admin]},
      {:"work_item.undo", yes: @owners ++ [:member, :admin]},
      {:"work_item.close", yes: @owners ++ [:member, :admin]},
      {:"work_item.comment", yes: @owners ++ [:member, :admin]},
      # Asked of the workspace, as a page asks whether to show the button at all: the role
      # alone answers. A comment's author is asked of the comment (`test/apiary/access_test.exs`).
      {:"work_item.comment_delete", yes: @owners ++ [:admin]},
      {:"source_item.post", yes: [:adapter_key, :hidden], on: :adapter},
      {:"work_item.read_changes", yes: [:adapter_key, :hidden], on: :adapter},
      {:"adapter.disconnect", yes: [:adapter_key, :hidden], on: :adapter}
    ]
  end

  @doc """
  setup/1 makes the core's place, `home`, an organisation with its workspace, beside an
  adapter of the instance (`adapter`), and the scopes of the core's actors in it. The
  adapter's key, `adapter_key`, is a key enrolled on it by an instance admin, its scope
  that of the server contract (`Apiary.Accounts.Scope.for_access_key/1`): no organisation,
  and no workspace.
  """
  @spec setup(map) :: %{places: map, scopes: map}
  def setup(_made) do
    home = sign_up_fixture()
    owner = home.scope
    %{access_key: key} = access_key_fixture(owner)
    adapter = Apiary.NodesFixtures.adapter_fixture()
    %{access_key: adapter_key} = enrolled_key_fixture(instance_admin_scope(), adapter)

    %{
      places: %{home: Map.put(home, :adapter, adapter)},
      scopes: %{
        member: member_fixture(owner, :member).scope,
        admin: member_fixture(owner, :admin).scope,
        owner: owner,
        other_owner: sign_up_fixture().scope,
        access_key: Scope.for_access_key(key),
        adapter_key: Scope.for_access_key(adapter_key),
        instance: Scope.for_instance(home.organisation, home.workspace)
      }
    }
  end

  @doc "place/2 is where the core's actors ask: at home."
  @spec place(atom, atom) :: atom | nil
  def place(_action, actor), do: if(actor in actors(), do: :home)

  @doc """
  refusal/3 is why the core's answer is no where it is not the role: a feature that is off
  or hidden is not found, and so is a hidden part, anything of another organisation, an
  organisation that does not exist yet, which is no place, an adapter, which is the
  instance's, to anyone but its key, and, to an adapter's key, anything but that adapter.
  """
  @spec refusal(atom, atom, term) :: :not_found | nil
  def refusal(action, actor, subject) do
    cond do
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

      actor != :adapter_key and
          match?(%Apiary.Nodes.Node{kind: :adapter, organisation_id: nil}, subject) ->
        :not_found

      true ->
        nil
    end
  end
end
