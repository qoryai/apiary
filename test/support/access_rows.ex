defmodule Apiary.AccessRows do
  @moduledoc """
  AccessRows is the core's rows of the access test (`Apiary.AccessCase`): every action of
  the core, and which of the core's actors may take it on a workspace of one
  organisation, the place `home`. The actors:

      member        a member of the organisation
      admin         an admin of the organisation
      owner         an owner of the organisation
      other_owner   an owner of another organisation
      access_key    a runner, with an access key of the workspace
      instance      the instance itself, in a job no person enqueued
      feature_off   whoever the action is for, an owner, an access key or the instance, on
                    an instance without the action's feature

  Accepting an invitation is taken on the strength of the token, which no role is, and
  granting and revoking an instance admin on the strength of a release command run on the
  instance's machine: nobody's row says yes. Creating an organisation is a sign-up's, which
  asks nothing, in the core; an edition may let a signed-in person create one. Creating,
  deleting and restoring a workspace are asked of the organisation: an owner creates one,
  an owner or an admin deletes any workspace of it; purging is the instance's, once a
  deletion's grace period is over. The actions over people are asked of the workspace, as
  a page asks whether to show them.
  """

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope

  @owners [:owner]

  @doc "actors/0 is the core's actors."
  @spec actors() :: [atom]
  def actors, do: [:member, :admin, :owner, :other_owner, :access_key, :instance, :feature_off]

  @doc "rows/0 is the core's rows: every action of the core, with the actors that may."
  @spec rows() :: [{atom, keyword}]
  def rows do
    [
      {:"organisation.create", yes: []},
      {:"organisation.rename", yes: @owners ++ [:admin, :feature_off]},
      {:"organisation.delete", yes: @owners ++ [:feature_off]},
      {:"organisation.restore", yes: @owners ++ [:feature_off]},
      {:"organisation.purge", yes: [:instance, :feature_off]},
      {:"member.invite", yes: @owners ++ [:admin, :feature_off], on: :workspace},
      {:"member.change_level", yes: @owners ++ [:feature_off], on: :workspace},
      {:"member.remove", yes: @owners ++ [:admin, :feature_off], on: :workspace},
      {:"invitation.revoke", yes: @owners ++ [:admin, :instance, :feature_off]},
      {:"invitation.accept", yes: []},
      {:"member.suspend", yes: @owners ++ [:admin, :feature_off], on: :workspace},
      {:"member.activate", yes: @owners ++ [:admin, :feature_off], on: :workspace},
      {:"instance_admin.grant", yes: []},
      {:"instance_admin.revoke", yes: []},
      {:"audit.read", yes: @owners ++ [:admin, :feature_off]},
      {:"audit.prune", yes: [:instance, :feature_off]},
      {:"workspace.create", yes: @owners ++ [:feature_off]},
      {:"workspace.rename", yes: @owners ++ [:admin, :feature_off]},
      {:"workspace.delete", yes: @owners ++ [:admin, :feature_off]},
      {:"workspace.restore", yes: @owners ++ [:admin, :feature_off]},
      {:"workspace.purge", yes: [:instance, :feature_off]},
      {:"access_key.create", yes: @owners ++ [:member, :admin, :feature_off]},
      {:"access_key.rotate", yes: @owners ++ [:member, :admin, :feature_off]},
      {:"access_key.revoke", yes: @owners ++ [:member, :admin, :feature_off]},
      {:"run.read", yes: @owners ++ [:member, :admin]},
      {:"run.read_log", yes: @owners ++ [:member, :admin]},
      {:"run.close", yes: @owners ++ [:member, :admin]},
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
      {:"run.post_events", yes: [:access_key]},
      {:"run_configuration.fetch", yes: [:access_key]}
    ]
  end

  @doc """
  setup/1 makes the core's place, `home`, an organisation with its workspace, and the
  scopes of the core's actors in it.
  """
  @spec setup(map) :: %{places: map, scopes: map}
  def setup(_made) do
    home = sign_up_fixture()
    owner = home.scope
    %{access_key: key} = access_key_fixture(owner)

    %{
      places: %{home: home},
      scopes: %{
        member: member_fixture(owner, :member).scope,
        admin: member_fixture(owner, :admin).scope,
        owner: owner,
        other_owner: sign_up_fixture().scope,
        access_key: Scope.for_access_key(key),
        instance: Scope.for_instance(home.organisation, home.workspace)
      }
    }
  end

  @doc "place/2 is where the core's actors ask: at home."
  @spec place(atom, atom) :: atom | nil
  def place(_action, actor), do: if(actor in actors(), do: :home)

  @doc """
  refusal/3 is why the core's answer is no where it is not the role: a feature that is off
  is not found, and so is anything of another organisation, and an organisation that does
  not exist yet, which is no place.
  """
  @spec refusal(atom, atom, term) :: :not_found | nil
  def refusal(action, actor, _subject) do
    cond do
      actor == :feature_off and Apiary.Access.feature(action) != nil -> :not_found
      actor == :other_owner -> :not_found
      Apiary.Access.action(action).asked_of == :new_organisation -> :not_found
      true -> nil
    end
  end
end
