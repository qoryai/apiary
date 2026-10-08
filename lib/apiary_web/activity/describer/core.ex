defmodule ApiaryWeb.Activity.Describer.Core do
  @moduledoc """
  The core's words for the Activity page (`ApiaryWeb.Activity.Describer`): the actions of
  the organisation, its members and invitations, its workspaces, their access keys, nodes,
  runs, retention, security policy, stored secrets and variables, the trail's own pruning
  and the instance's commands. The page asks it after the edition's describer, and it says
  nil for an action it does not know, as it does for the edition's.
  """

  @behaviour ApiaryWeb.Activity.Describer

  use Gettext, backend: ApiaryWeb.Gettext
  use ApiaryWeb, :verified_routes

  import ApiaryWeb.RichText, only: [rich_gettext: 2, rich_ngettext: 4]
  import ApiaryWeb.Activity.Describer, only: [text: 1, from_to: 2]

  alias Apiary.Features
  alias ApiaryWeb.{Format, RunComponents}

  @impl true
  def label(:"organisation.create"), do: gettext("Organisation created")
  def label(:"organisation.rename"), do: gettext("Organisation renamed")
  def label(:"organisation.delete"), do: gettext("Organisation deleted")
  def label(:"organisation.restore"), do: gettext("Organisation's deletion cancelled")
  def label(:"member.invite"), do: gettext("Member invited")
  def label(:"member.change_level"), do: gettext("Member's level changed")
  def label(:"member.remove"), do: gettext("Member removed")
  def label(:"invitation.revoke"), do: gettext("Invitation revoked")
  def label(:"invitation.accept"), do: gettext("Invitation accepted")
  def label(:"instance_admin.grant"), do: gettext("Owner made on the server")
  def label(:"instance_admin.revoke"), do: gettext("Owner made a member on the server")
  def label(:"member.suspend"), do: gettext("Member suspended")
  def label(:"member.activate"), do: gettext("Member activated")
  def label(:"audit.prune"), do: gettext("Activity pruned")
  def label(:"workspace.create"), do: gettext("Workspace created")
  def label(:"workspace.rename"), do: gettext("Workspace renamed")
  def label(:"workspace.delete"), do: gettext("Workspace deleted")
  def label(:"workspace.restore"), do: gettext("Workspace's deletion cancelled")
  def label(:"workspace.purge"), do: gettext("Workspace purged")
  def label(:"access_key.create_code"), do: gettext("Command made")
  def label(:"access_key.cancel_code"), do: gettext("Command cancelled")
  def label(:"access_key.add"), do: gettext("Access key added")
  def label(:"access_key.revoke"), do: gettext("Access key revoked")
  def label(:"node.create"), do: gettext("Node created")
  def label(:"node.edit"), do: gettext("Node changed")
  def label(:"node.delete"), do: gettext("Node deleted")
  def label(:"node.clear_instance"), do: gettext("Instance cleared")
  def label(:"run.close"), do: gettext("Run closed")
  def label(:"retention.edit"), do: gettext("Retention changed")
  def label(:"security_policy.edit"), do: gettext("Policy rules changed")
  def label(:"security_policy.lock"), do: gettext("Policy rule locked or unlocked")
  def label(:"security_policy.set_mode"), do: gettext("Policy mode changed")
  def label(:"secret.write"), do: gettext("Stored secret changed")
  def label(:"variable.edit"), do: gettext("Variable changed")
  def label(:"connection.write"), do: gettext("Integration changed")
  def label(_action), do: nil

  # The core offers every action it has in the filter.
  @impl true
  def offered?(_scope, _action), do: true

  @impl true
  def sentence(action, entry, _names) do
    details = entry.details || %{}

    if left?(entry, action, details),
      do: gettext("Left the organisation"),
      else: said(action, details, entry.actor_kind)
  end

  # A person who removed their own membership left: the removal names them in `details`.
  defp left?(%{actor_kind: :person, actor_id: id}, :"member.remove", %{"user_id" => id} = details)
       when is_binary(id),
       do: details["reason"] != "account_deleted"

  defp left?(_entry, _action, _details), do: false

  # What was done, one whole sentence an action, and one a kind of change where an action
  # takes several. Created by a person who had an account already, from the organisation
  # switcher; a sign-up's entry says it signed up.
  defp said(:"organisation.create", %{"sign_up" => false}, _actor),
    do: gettext("Created the organisation")

  defp said(:"organisation.create", _details, _actor),
    do: gettext("Signed up and created the organisation")

  defp said(:"organisation.rename", _details, _actor), do: gettext("Renamed the organisation")

  defp said(:"organisation.delete", _details, _actor),
    do: gettext("Deleted the organisation, to be purged after the grace period")

  defp said(:"organisation.restore", _details, _actor),
    do: gettext("Cancelled the organisation's deletion")

  defp said(:"member.invite", _details, _actor), do: gettext("Invited a member")
  defp said(:"member.change_level", _details, _actor), do: gettext("Changed a member's level")

  defp said(:"member.remove", %{"reason" => "account_deleted"}, :person),
    do: gettext("Deleted their account, which ended their membership")

  defp said(:"member.remove", %{"reason" => "account_deleted"}, _actor),
    do: gettext("Ended the membership of a deleted account")

  defp said(:"member.remove", _details, _actor), do: gettext("Removed a member")

  defp said(:"invitation.revoke", %{"reason" => "expired"}, :instance),
    do: gettext("Deleted an invitation that had been expired for 30 days")

  defp said(:"invitation.revoke", %{"reason" => "expired"}, _actor),
    do: gettext("Removed an expired invitation, sending a new one")

  defp said(:"invitation.revoke", %{"reason" => "undelivered"}, _actor),
    do: gettext("Withdrew an invitation that could not be delivered")

  defp said(:"invitation.revoke", _details, _actor), do: gettext("Revoked an invitation")
  defp said(:"invitation.accept", _details, _actor), do: gettext("Accepted an invitation")

  defp said(:"instance_admin.grant", _details, _actor),
    do: gettext("Made a person an owner, by a command run on the server")

  defp said(:"instance_admin.revoke", _details, _actor),
    do: gettext("Made an owner a member, by a command run on the server")

  defp said(:"member.suspend", _details, _actor), do: gettext("Suspended a member")
  defp said(:"member.activate", _details, _actor), do: gettext("Activated a member")

  defp said(:"audit.prune", _details, _actor),
    do: gettext("Deleted the activity older than the instance keeps")

  defp said(:"workspace.create", _details, _actor), do: gettext("Created the workspace")
  defp said(:"workspace.rename", _details, _actor), do: gettext("Renamed the workspace")

  defp said(:"workspace.delete", _details, _actor),
    do: gettext("Deleted a workspace, to be purged after the grace period")

  defp said(:"workspace.restore", _details, _actor),
    do: gettext("Cancelled a workspace's deletion")

  defp said(:"workspace.purge", _details, _actor),
    do: gettext("Purged a deleted workspace and everything in it")

  defp said(:"access_key.create_code", _details, _actor),
    do: gettext("Made a command to connect a node")

  defp said(:"access_key.cancel_code", _details, _actor),
    do: gettext("Cancelled a command to connect a node")

  defp said(:"access_key.add", _details, _actor), do: gettext("Added an access key to a node")

  defp said(:"access_key.revoke", %{"reason" => "node_deleted"}, _actor),
    do: gettext("Revoked an access key with its deleted node")

  defp said(:"access_key.revoke", _details, _actor), do: gettext("Revoked an access key")
  defp said(:"node.create", _details, _actor), do: gettext("Created a node")
  defp said(:"node.edit", _details, _actor), do: gettext("Changed a node")
  defp said(:"node.delete", _details, _actor), do: gettext("Deleted a node")

  defp said(:"node.clear_instance", _details, _actor),
    do: gettext("Cleared an instance of a node")

  defp said(:"run.close", _details, _actor), do: gettext("Closed a run")

  defp said(:"retention.edit", _details, _actor),
    do: gettext("Changed how long runs are kept")

  defp said(:"secret.write", %{"change" => change}, _actor), do: said_secret(change)
  defp said(:"variable.edit", %{"change" => change}, _actor), do: said_variable(change)
  defp said(:"connection.write", %{"change" => change}, _actor), do: said_connection(change)

  defp said(_policy, %{"change" => "rule_added"}, _actor), do: gettext("Added a policy rule")

  defp said(_policy, %{"change" => "rule_changed"}, _actor),
    do: gettext("Changed a policy rule")

  defp said(_policy, %{"change" => "rule_removed"}, _actor),
    do: gettext("Removed a policy rule")

  defp said(_policy, %{"change" => "rule_locked"}, _actor),
    do: gettext("Locked a policy rule")

  defp said(_policy, %{"change" => "rule_unlocked"}, _actor),
    do: gettext("Unlocked a policy rule")

  defp said(_policy, %{"change" => "mode_changed"}, _actor),
    do: gettext("Changed the policy's mode")

  defp said(_policy, %{"change" => "rerendered"}, _actor),
    do: gettext("Rendered the run configurations again")

  defp said(:"security_policy.edit", _details, _actor), do: gettext("Changed the policy")
  defp said(:"secret.write", _details, _actor), do: gettext("Changed a stored secret")
  defp said(:"variable.edit", _details, _actor), do: gettext("Changed a variable")
  defp said(:"connection.write", _details, _actor), do: gettext("Changed an integration")
  defp said(_action, _details, _actor), do: nil

  defp said_secret("created"), do: gettext("Created a stored secret")
  defp said_secret("updated"), do: gettext("Changed a stored secret")
  defp said_secret("value_set"), do: gettext("Replaced a stored secret's value")
  defp said_secret("value_added"), do: gettext("Added a value to a stored secret")
  defp said_secret("value_renamed"), do: gettext("Renamed a value ID of a stored secret")
  defp said_secret("value_deleted"), do: gettext("Deleted a value of a stored secret")
  defp said_secret("deleted"), do: gettext("Deleted a stored secret")
  defp said_secret(_change), do: gettext("Changed a stored secret")

  defp said_variable("created"), do: gettext("Set a variable")
  defp said_variable("locked"), do: gettext("Locked a variable")
  defp said_variable("unlocked"), do: gettext("Unlocked a variable")
  defp said_variable("deleted"), do: gettext("Removed a variable")
  defp said_variable(_change), do: gettext("Changed a variable")

  defp said_connection("created"), do: gettext("Added an integration")
  defp said_connection("deleted"), do: gettext("Removed an integration")
  defp said_connection("release_changed"), do: gettext("Moved an integration to another version")
  defp said_connection("target_set"), do: gettext("Changed where an integration is used")
  defp said_connection("target_removed"), do: gettext("Changed where an integration is used")
  defp said_connection("release_requested"), do: gettext("Looked up an integration's release")
  defp said_connection("definition_created"), do: gettext("Wrote a service definition")
  defp said_connection("definition_updated"), do: gettext("Changed a service definition")
  defp said_connection("definition_deleted"), do: gettext("Deleted a service definition")
  defp said_connection(_change), do: gettext("Changed an integration")

  # What was acted on, as it is called now.
  @impl true
  def subject(entry, action, names, scope, workspace) do
    id = entry.subject_id

    case entry.subject_kind do
      "organisation" ->
        text(scope.organisation.name)

      "workspace"
      when action in [
             :"security_policy.edit",
             :"security_policy.lock",
             :"security_policy.set_mode"
           ] ->
        text(
          gettext("%{workspace}'s policy",
            workspace: names.workspaces[id] || gettext("n/a")
          )
        )

      "workspace" ->
        text(names.workspaces[id] || gettext("A deleted workspace"))

      "membership" ->
        case names.users[(entry.details || %{})["user_id"]] do
          nil -> text(gettext("Former member"))
          email -> text(email)
        end

      "invitation" ->
        text(gettext("An invitation"))

      "access_key" ->
        case names.access_keys[id] do
          %{label: label} when is_binary(label) and label != "" -> text(label)
          %{key_id: key_id} -> %{text: key_id, mono: true, href: nil}
          nil -> text(gettext("An access key"))
        end

      "node" ->
        text(names.nodes[id] || gettext("A node"))

      "run" ->
        case names.runs[id] do
          nil ->
            text(gettext("A run"))

          run_id ->
            href =
              workspace && Features.on?(scope, :observability) &&
                ~p"/#{scope.organisation}/#{workspace}/runs/#{run_id}"

            %{text: String.slice(run_id, 0, 8), mono: true, href: href || nil}
        end

      "target" ->
        case names.targets[id] do
          nil -> text(gettext("A target"))
          target -> %{text: target, mono: true, href: nil}
        end

      "rule" ->
        text(gettext("A policy rule"))

      # A secret and a variable are named in the entry itself: by name, never by value.
      kind when kind in ["secret", "variable"] ->
        case (entry.details || %{})["name"] do
          name when is_binary(name) -> %{text: name, mono: true, href: nil}
          _none when kind == "secret" -> text(gettext("A stored secret"))
          _none -> text(gettext("A variable"))
        end

      # An integration, a release and a service definition are named in the entry itself.
      kind when kind in ["connection", "integration_release", "service_definition"] ->
        case (entry.details || %{})["name"] do
          name when is_binary(name) ->
            %{text: name, mono: kind == "integration_release", href: nil}

          _none ->
            text(gettext("An integration"))
        end

      _other ->
        nil
    end
  end

  # The change in a few words: what was, and what is.
  @impl true
  def change(action, before, after_, _details)
      when action in [:"organisation.rename", :"workspace.rename"],
      do: from_to(before["name"], after_["name"])

  def change(action, before, after_, _details)
      when action in [:"member.change_level", :"instance_admin.grant", :"instance_admin.revoke"] and
             is_map_key(before, "level"),
      do: from_to(level(before["level"]), level(after_["level"]))

  def change(:"instance_admin.grant", _before, %{"level" => level}, _details),
    do: as_level(level)

  def change(action, _before, _after, %{"purge_after" => at})
      when action in [:"workspace.delete", :"organisation.delete"] do
    case DateTime.from_iso8601(to_string(at)) do
      {:ok, at, _offset} -> gettext("Purged on %{date}", date: Format.date(at))
      _other -> nil
    end
  end

  def change(:"member.suspend", _before, _after, _details), do: gettext("Suspended")
  def change(:"member.activate", _before, _after, _details), do: gettext("Active")

  def change(:"invitation.accept", _before, %{"level" => level}, _details),
    do: as_level(level)

  def change(:"member.remove", %{"level" => level}, _after, _details), do: as_level(level)

  def change(:"access_key.add", _before, %{"key_id" => key_id}, _details),
    do: [{:m, key_id}]

  def change(:"node.create", _before, %{"kind" => kind, "public_id" => id}, _details),
    do: [[kind_word(kind), " ", {:m, id}]]

  def change(:"node.edit", before, after_, _details) do
    for {field, label} <- [
          {"name", gettext("Name")},
          {"instance_limit", gettext("Instance limit")}
        ],
        Map.has_key?(after_, field) do
      rich_gettext("%{what}: %{from} → %{to}",
        what: label,
        from: limit_or_name(field, before[field]),
        to: limit_or_name(field, after_[field])
      )
    end
  end

  def change(:"node.clear_instance", _before, _after, %{"instance_id" => id} = details)
      when is_binary(id) do
    runs = if is_integer(details["runs"]), do: details["runs"], else: 0

    [
      [{:m, id}],
      rich_ngettext("%{number} open run marked lost", "%{number} open runs marked lost", runs,
        number: Format.number(runs)
      )
    ]
  end

  def change(:"run.close", before, after_, _details),
    do: from_to(state(before["state"]), state(after_["state"]))

  def change(:"retention.edit", before, after_, _details) do
    for {field, label} <- [
          {"events_retention_days", gettext("Events")},
          {"log_retention_days", gettext("Log output")}
        ],
        Map.has_key?(after_, field) or Map.has_key?(before, field) do
      rich_gettext("%{what}: %{from} → %{to}",
        what: label,
        from: days(before[field]),
        to: days(after_[field])
      )
    end
  end

  def change(:"audit.prune", _before, _after, %{"removed" => removed} = details) do
    rich_ngettext(
      "%{number} entry older than %{days}",
      "%{number} entries older than %{days}",
      removed,
      number: Format.number(removed),
      days: days(details["retention_days"])
    )
  end

  def change(:"secret.write", %{"value_id" => from}, %{"value_id" => to}, _details),
    do: from_to(from, to)

  def change(:"secret.write", _before, _after, %{"value_id" => value_id})
      when is_binary(value_id),
      do: [{:m, value_id}]

  def change(:"variable.edit", %{"name" => from}, %{"name" => to}, _details) when from != to,
    do: from_to(from, to)

  def change(action, _before, _after, _details)
      when action in [:"secret.write", :"variable.edit"],
      do: nil

  def change(_policy, before, after_, %{"change" => "mode_changed"} = details),
    do: Enum.reject([from_to(before["mode"], after_["mode"]), version(details)], &is_nil/1)

  def change(_policy, _before, _after, %{"change" => _change, "subject" => subject} = details)
      when is_binary(subject),
      do: Enum.reject([[{:m, subject}], version(details)], &is_nil/1)

  def change(_policy, _before, _after, %{"change" => _change} = details), do: version(details)

  def change(_action, _before, _after, _details), do: nil

  # The version of the run configuration the change left in force.
  defp version(%{"version" => version}) when is_integer(version),
    do: gettext("Now v%{version}", version: version)

  defp version(_details), do: nil

  defp as_level("owner"), do: gettext("As an owner")
  defp as_level("admin"), do: gettext("As an admin")
  defp as_level("member"), do: gettext("As a member")
  defp as_level(_level), do: nil

  defp level("owner"), do: gettext("Owner")
  defp level("admin"), do: gettext("Admin")
  defp level("member"), do: gettext("Member")
  defp level(other), do: other

  defp kind_word("pool"), do: gettext("Node pool")
  defp kind_word(_node), do: gettext("Node")

  defp limit_or_name("instance_limit", nil), do: gettext("No limit")
  defp limit_or_name("instance_limit", n) when is_integer(n), do: Format.number(n)
  defp limit_or_name(_field, value), do: to_string(value)

  defp state(nil), do: nil
  defp state(state), do: RunComponents.state_label(state)

  defp days(nil), do: gettext("Forever")

  defp days(n) when is_integer(n),
    do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))

  defp days(_other), do: gettext("n/a")
end
