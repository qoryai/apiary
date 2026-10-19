defmodule ApiaryWeb.Activity.Describer.Core do
  @moduledoc """
  The core's words for the Activity page (`ApiaryWeb.Activity.Describer`): the actions of
  the organisation, its members and invitations, its workspaces, their access keys, nodes,
  runs, retention, security policy, stored secrets and variables, model choices, the trail's pruning
  and the instance's commands. The page asks it after the edition's describer, and it says
  nil for an action it does not know, as it does for the edition's.
  """

  @behaviour ApiaryWeb.Activity.Describer

  use Gettext, backend: ApiaryWeb.Gettext
  use ApiaryWeb, :verified_routes

  import ApiaryWeb.RichText, only: [rich_gettext: 2, rich_ngettext: 4]
  import ApiaryWeb.Activity.Describer, only: [text: 1, from_to: 2]

  alias Apiary.{Access, Adapters, Features}
  alias ApiaryWeb.{Format, SourceComponents}

  @impl true
  def label(:"organisation.create"), do: gettext("Organisation created")
  def label(:"organisation.rename"), do: gettext("Organisation renamed")
  def label(:"organisation.delete"), do: gettext("Organisation deleted")
  def label(:"organisation.restore"), do: gettext("Organisation's deletion cancelled")
  def label(:"member.invite"), do: gettext("Member invited")
  def label(:"member.change_level"), do: gettext("Member's level changed")
  def label(:"member.remove"), do: gettext("Member removed")
  def label(:"invitation.revoke"), do: gettext("Invitation revoked")
  def label(:"invitation.renew"), do: gettext("Invitation renewed")
  def label(:"invitation.accept"), do: gettext("Invitation accepted")
  def label(:"instance_admin.grant"), do: gettext("Owner made on Qory Apiary")
  def label(:"instance_admin.revoke"), do: gettext("Owner made a member on Qory Apiary")
  def label(:"account.password_link"), do: gettext("Password link made")
  def label(:"instance.mail_save"), do: gettext("Mail settings saved")
  def label(:"instance.mail_on"), do: gettext("Mail turned on")
  def label(:"instance.rename"), do: gettext("Instance renamed")
  def label(:"instance.configure"), do: gettext("Configuration changed")
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
  def label(:"retention.edit"), do: gettext("Retention changed")
  def label(:"security_policy.edit"), do: gettext("Policy rules changed")
  def label(:"security_policy.lock"), do: gettext("Policy rule locked or unlocked")
  def label(:"security_policy.set_mode"), do: gettext("Policy mode changed")
  def label(:"secret.write"), do: gettext("Stored secret changed")
  def label(:"variable.edit"), do: gettext("Variable changed")
  def label(:"connection.write"), do: gettext("Integration changed")
  def label(:"model_choice.write"), do: gettext("Model choice changed")
  def label(:"collection.assign"), do: assign_label(nil)

  def label(:"collection.set_backlog"), do: backlog_label(nil)

  def label(:"target.set_further_repositories"), do: gettext("Also read")
  def label(:"work_item.take_in"), do: gettext("Work item taken in")
  def label(:"work_item.undo"), do: gettext("Take in undone")
  def label(:"work_item.decline"), do: gettext("Work item declined")
  def label(:"work_item.close"), do: gettext("Work item closed")
  def label(:"work_item.answer"), do: gettext("Work item questions answered")
  def label(:"work_item.confirm"), do: gettext("Work item proposal confirmed")
  def label(:"work_item.explore_again"), do: gettext("Work item explored again")
  def label(:"work_item.comment"), do: gettext("Work item comment added")
  def label(:"work_item.comment_delete"), do: gettext("Work item comment deleted")
  def label(:"dispatch.handover"), do: gettext("Runs handed over")
  def label(:"dispatch.release"), do: gettext("Runs given back")
  def label(:"dispatch.prebuilt"), do: gettext("Images recorded")
  def label(:"target.rebuild_environment"), do: gettext("Builds asked for")
  def label(:"adapter.install"), do: gettext("Adapter installed")
  def label(:"adapter.setup"), do: gettext("Adapter set-up started")
  def label(_action), do: nil

  # Turning a target's Backlog on or off names the items of the organisation's sources:
  # the words they share (`Apiary.Adapters.organisation_item_noun/1`), else tickets.
  @impl true
  def label(:"collection.set_backlog", scope),
    do: backlog_label(Adapters.organisation_item_noun(scope))

  # Assigning collections names the collections of the organisation's sources: the words
  # they share (`Apiary.Adapters.organisation_collection_noun/1`), else "collections".
  def label(:"collection.assign", scope),
    do: assign_label(Adapters.organisation_collection_noun(scope))

  def label(action, _scope), do: label(action)

  defp assign_label(collection_noun),
    do:
      gettext("Assigned %{collections}",
        collections: SourceComponents.collections(collection_noun)
      )

  defp backlog_label(item_noun),
    do:
      gettext("Taking %{items} into the Backlog turned on or off",
        items: SourceComponents.items(item_noun)
      )

  # The core offers every action it has in the filter, but the stored secrets', variables'
  # and integrations' only where the reader is shown them, and the nodes' and their access
  # keys' likewise: their actions belong to the `secrets` feature, or to the part `nodes`
  # (`Apiary.Access.shown_as/1`), and they ask `visible?/2` of it. Their entries still
  # show, by their labels. Of the feature `factory`'s actions only those of a person on the
  # work items (a take in, its undo, a decline, a close, an answer to Qory's questions, a
  # confirmation of its proposal, a run of Explore again and the comments), the assigning
  # of collections, the turning of a target's Backlog on or off, the handover of a claimed
  # run, its release, the image a prebuild built, the choosing of what a target's runs also
  # read, the setting of a model choice of a workspace or a target, a build of a target's
  # environment asked for, the installing of an adapter and the start of its set-up have
  # labels yet, so the filter offers those alone, where the reader is shown the feature
  # (the page asks it); the others' entries show as any change.
  @impl true
  def offered?(scope, action) do
    case Access.shown_as(action) do
      :factory ->
        action in [
          :"work_item.take_in",
          :"work_item.undo",
          :"work_item.decline",
          :"work_item.close",
          :"work_item.answer",
          :"work_item.confirm",
          :"work_item.explore_again",
          :"work_item.comment",
          :"work_item.comment_delete",
          :"model_choice.write",
          :"collection.assign",
          :"collection.set_backlog",
          :"dispatch.handover",
          :"dispatch.release",
          :"dispatch.prebuilt",
          :"target.set_further_repositories",
          :"target.rebuild_environment",
          :"adapter.install",
          :"adapter.setup"
        ]

      shown_as when shown_as in [:secrets, :nodes] ->
        Features.visible?(scope, shown_as)

      _shown_as ->
        true
    end
  end

  # A collection's Backlog turned on or off: the entry is the collection's, and names it
  # by the title it had then (`name`), in the words of the source behind its connection
  # (`Apiary.Audit.names/2`'s `item_nouns` and `collection_nouns`), else tickets and
  # collection. The title is its adapter's, shown as an external system's text is
  # (`Apiary.ExternalText.line/1`).
  @impl true
  def sentence(
        :"collection.set_backlog",
        %{subject_kind: "collection", details: %{"backlog" => on, "name" => name}} = entry,
        names
      )
      when is_boolean(on) and is_binary(name) do
    name = Apiary.ExternalText.line(name)
    items = SourceComponents.items(names[:item_nouns][entry.subject_id])
    collection = SourceComponents.collection(names[:collection_nouns][entry.subject_id])

    if on,
      do:
        gettext("Turned on taking %{items} into the Backlog from %{collection} %{name}",
          items: items,
          collection: collection,
          name: name
        ),
      else:
        gettext("Turned off taking %{items} into the Backlog from %{collection} %{name}",
          items: items,
          collection: collection,
          name: name
        )
  end

  # A target's Backlog turned on or off, for its collections: the entry is the target's,
  # and names its sources' items (`Apiary.Audit.names/2`'s `item_nouns`), else tickets.
  def sentence(:"collection.set_backlog", %{details: %{"backlog" => on}} = entry, names)
      when is_boolean(on) do
    items = SourceComponents.items(names[:item_nouns][entry.subject_id])

    if on,
      do: gettext("Turned on taking a collection's %{items} into the Backlog", items: items),
      else: gettext("Turned off taking a collection's %{items} into the Backlog", items: items)
  end

  # A collection ended because its adapter now lists it under another connection: the
  # entry is the collection's, in the trail of the organisation it left, and names it by
  # the title it had then (`name`), shown as an external system's text is
  # (`Apiary.ExternalText.line/1`), and the adapter by its name then (`integration`).
  def sentence(
        :"collection.move",
        %{details: %{"name" => name, "integration" => integration}},
        _names
      )
      when is_binary(name) and is_binary(integration) do
    gettext(
      "%{collection} left this organisation's Backlog: %{integration} now lists it under another connection.",
      collection: Apiary.ExternalText.line(name),
      integration: integration
    )
  end

  # Collections assigned to a workspace, or unassigned from theirs (the entry of an
  # unassign names no workspace, `"workspace_id"` nil), in the words of the source behind
  # the connection the entry names (`Apiary.Audit.names/2`'s
  # `connection_collection_nouns`), else "collection" and "collections".
  def sentence(
        :"collection.assign",
        %{details: %{"count" => count, "workspace_id" => workspace_id} = details},
        names
      )
      when is_integer(count) and (is_binary(workspace_id) or is_nil(workspace_id)) do
    noun = names[:connection_collection_nouns][details["connection_id"]]

    words = [
      collection: SourceComponents.collection(noun),
      collections: SourceComponents.collections(noun)
    ]

    case workspace_id do
      id when is_binary(id) ->
        ngettext(
          "Assigned %{count} %{collection} to a workspace",
          "Assigned %{count} %{collections} to a workspace",
          count,
          words
        )

      nil ->
        ngettext(
          "Unassigned %{count} %{collection} from its workspace",
          "Unassigned %{count} %{collections} from their workspaces",
          count,
          words
        )
    end
  end

  # What a target's runs also read, the list as it is after the change, joined as a list
  # is on a page; the entry is the target's, which the subject names.
  def sentence(
        :"target.set_further_repositories",
        %{after: %{"further_repositories" => paths}},
        _names
      )
      when is_list(paths) do
    case paths do
      [] ->
        gettext("Set its runs to read no other target")

      paths ->
        gettext("Changed what its runs read: %{paths}", paths: Enum.join(paths, ", "))
    end
  end

  # A ticket taken in names the items of the work item's source (`Apiary.Audit.names/2`'s
  # `item_nouns`), else tickets; a take in again is the work item's.
  def sentence(:"work_item.take_in", %{details: %{"again" => true}}, _names),
    do: gettext("Took a work item in again")

  def sentence(:"work_item.take_in", entry, names) do
    items = SourceComponents.items(names[:item_nouns][entry.subject_id])
    gettext("Took in one of the Backlog's %{items} as a work item", items: items)
  end

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

  defp said(:"invitation.renew", _details, _actor),
    do: gettext("Made a new link for an invitation")

  defp said(:"invitation.accept", _details, _actor), do: gettext("Accepted an invitation")

  defp said(:"instance_admin.grant", _details, _actor),
    do: gettext("Made a person an owner, by a command run on Qory Apiary")

  defp said(:"instance_admin.revoke", _details, _actor),
    do: gettext("Made an owner a member, by a command run on Qory Apiary")

  defp said(:"account.password_link", _details, :instance),
    do: gettext("Made a password link, by a command run on Qory Apiary")

  defp said(:"account.password_link", _details, _actor),
    do: gettext("Made a password link for a person")

  defp said(:"instance.mail_save", _details, _actor),
    do: gettext("Saved the mail settings, which sent a test link")

  defp said(:"instance.mail_on", _details, _actor),
    do: gettext("Turned mail on, by the test link")

  defp said(:"instance.rename", _details, _actor), do: gettext("Renamed the instance")

  defp said(:"instance.configure", _details, _actor),
    do: gettext("Changed the instance's configuration")

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

  # An adapter installed with Qory Apiary: the instance gives it its first code, and the
  # first once it has none, and cancels the codes it no longer needs.
  defp said(:"access_key.create_code", %{"installed" => true}, _actor),
    do: gettext("Gave an installed adapter a new one-time code")

  defp said(:"access_key.create_code", _details, _actor),
    do: gettext("Made a command to connect a node")

  defp said(:"access_key.cancel_code", _details, :instance),
    do: gettext("Cancelled an adapter's code it no longer needs")

  defp said(:"access_key.cancel_code", _details, _actor),
    do: gettext("Cancelled a command to connect a node")

  defp said(:"adapter.install", _details, _actor),
    do: gettext("Added an adapter installed with Qory Apiary")

  defp said(:"adapter.setup", _details, _actor), do: gettext("Started setting up an adapter")

  defp said(:"access_key.add", _details, _actor), do: gettext("Added an access key to a node")

  defp said(:"access_key.revoke", %{"reason" => "node_deleted"}, _actor),
    do: gettext("Revoked an access key with its deleted node")

  defp said(:"access_key.revoke", _details, _actor), do: gettext("Revoked an access key")
  defp said(:"node.create", _details, _actor), do: gettext("Created a node")
  defp said(:"node.edit", _details, _actor), do: gettext("Changed a node")
  defp said(:"node.delete", _details, _actor), do: gettext("Deleted a node")

  defp said(:"node.clear_instance", _details, _actor),
    do: gettext("Cleared an instance of a node")

  defp said(:"retention.edit", _details, _actor),
    do: gettext("Changed how long runs are kept")

  defp said(:"secret.write", %{"change" => change}, _actor), do: said_secret(change)
  defp said(:"variable.edit", %{"change" => change}, _actor), do: said_variable(change)
  defp said(:"connection.write", %{"change" => change}, _actor), do: said_connection(change)
  defp said(:"model_choice.write", %{"change" => change}, _actor), do: said_choice(change)

  defp said(:"work_item.undo", _details, _actor),
    do: gettext("Undid a take in, before a run started")

  defp said(:"work_item.decline", _details, _actor), do: gettext("Declined a work item")
  defp said(:"work_item.close", _details, _actor), do: gettext("Closed a work item")

  # The count of questions answered, one where the entry says none.
  defp said(:"work_item.answer", details, _actor) do
    count =
      case details["count"] do
        count when is_integer(count) and count >= 1 -> count
        _none -> 1
      end

    ngettext(
      "Answered Qory's question on a work item",
      "Answered Qory's %{count} questions on a work item",
      count
    )
  end

  defp said(:"work_item.confirm", %{"changed" => [_ | _]}, _actor),
    do: gettext("Changed Qory's proposal for a work item and confirmed it")

  defp said(:"work_item.confirm", _details, _actor),
    do: gettext("Confirmed Qory's proposal for a work item")

  defp said(:"work_item.explore_again", _details, _actor),
    do: gettext("Asked Qory to explore a work item again")

  defp said(:"work_item.comment", _details, _actor), do: gettext("Commented on a work item")

  defp said(:"work_item.comment_delete", _details, _actor),
    do: gettext("Deleted a comment on a work item")

  defp said(:"dispatch.handover", _details, _actor),
    do: gettext("Handed a claimed run over to the machine that runs it")

  # A run given back before its handover, or after it; the starter's reason is not shown.
  defp said(:"dispatch.release", %{"handed_over" => false}, _actor),
    do: gettext("Gave a claimed run back")

  defp said(:"dispatch.release", %{"handed_over" => true}, _actor),
    do: gettext("Gave back a run handed over to its machine")

  # The image a prebuild built, recorded; the entry is the run's.
  defp said(:"dispatch.prebuilt", _details, _actor),
    do: gettext("Recorded the image a prebuild built")

  # A build of a target's environment asked for; the entry is the target's.
  defp said(:"target.rebuild_environment", _details, _actor),
    do: gettext("Asked for a build of its environment")

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
  defp said_connection("workspace_added"), do: gettext("Changed where an integration is used")
  defp said_connection("workspace_removed"), do: gettext("Changed where an integration is used")
  defp said_connection("release_requested"), do: gettext("Looked up an integration's release")
  defp said_connection("definition_created"), do: gettext("Wrote a service definition")
  defp said_connection("definition_updated"), do: gettext("Changed a service definition")
  defp said_connection("definition_deleted"), do: gettext("Deleted a service definition")
  defp said_connection("provider_created"), do: gettext("Added a model provider")
  defp said_connection("provider_deleted"), do: gettext("Removed a model provider")

  defp said_connection("provider_address_changed"),
    do: gettext("Changed a model provider's address")

  defp said_connection("provider_default_key_changed"),
    do: gettext("Changed a model provider's default key")

  defp said_connection("provider_keys_changed"), do: gettext("Changed a model provider's keys")

  defp said_connection("provider_model_added"), do: gettext("Added a model to a model provider")

  defp said_connection("provider_model_changed"),
    do: gettext("Changed a model of a model provider")

  defp said_connection("provider_model_removed"),
    do: gettext("Removed a model from a model provider")

  defp said_connection("provider_default_model_changed"),
    do: gettext("Changed a model provider's default model")

  # The organisation's default model choice is written under `connection.write`.
  defp said_connection("choice_" <> _ = change), do: said_choice(change)
  defp said_connection(_change), do: gettext("Changed an integration")

  defp said_choice("choice_set"), do: gettext("Set a model choice")
  defp said_choice("choice_changed"), do: gettext("Changed a model choice")
  defp said_choice("choice_removed"), do: gettext("Removed a model choice")
  defp said_choice("choice_locked"), do: gettext("Locked a model choice")
  defp said_choice("choice_unlocked"), do: gettext("Unlocked a model choice")
  defp said_choice(_change), do: gettext("Changed a model choice")

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

          public_id ->
            href =
              workspace && Features.visible?(scope, :observability) &&
                ~p"/#{scope.organisation}/#{workspace}/runs/#{public_id}"

            %{text: String.slice(public_id, 0, 11), mono: true, href: href || nil}
        end

      "target" ->
        case names.targets[id] do
          nil -> text(gettext("A target"))
          target -> %{text: target, mono: true, href: nil}
        end

      # A source's collection, by its title as it is now, as a target's name is shown; the
      # source's word for it once its row is gone.
      "collection" ->
        case names[:collections][id] do
          title when is_binary(title) ->
            %{text: title, mono: true, href: nil}

          nil ->
            collection = SourceComponents.collection(names[:collection_nouns][id])
            text(gettext("Deleted %{collection}", collection: collection))
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

      # A model choice, by the place it was set at: the workspace or the target as it is
      # called now, else as the entry named it, and the organisation for its default.
      "model_choice" ->
        details = entry.details || %{}

        case details["level"] do
          6 ->
            text(
              gettext("%{name}'s default model choice",
                name: details["name"] || scope.organisation.name
              )
            )

          level when level in [2, 3] ->
            text(
              gettext("%{name}'s model choice",
                name: names.targets[details["target_id"]] || details["name"] || gettext("n/a")
              )
            )

          _workspace ->
            text(
              gettext("%{name}'s model choice",
                name: names.workspaces[entry.workspace_id] || details["name"] || gettext("n/a")
              )
            )
        end

      # An integration, a release and a service definition are named in the entry itself.
      kind when kind in ["connection", "integration_release", "service_definition"] ->
        case (entry.details || %{})["name"] do
          name when is_binary(name) ->
            %{text: name, mono: kind == "integration_release", href: nil}

          _none ->
            text(gettext("An integration"))
        end

      # A work item is not named yet: the page its stable address opens has no route, so
      # the entry shows its sentence and no subject until that page comes.
      _other ->
        nil
    end
  end

  # The change in a few words: what was, and what is.
  @impl true
  def change(action, before, after_, _details)
      when action in [:"organisation.rename", :"workspace.rename"],
      do: from_to(before["name"], after_["name"])

  # A name set or emptied: an empty name shows as the edition's (`Apiary.ProductName`).
  def change(:"instance.rename", before, after_, _details),
    do:
      from_to(
        before["name"] || Apiary.ProductName.edition_name(),
        after_["name"] || Apiary.ProductName.edition_name()
      )

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

  def change(action, _before, _after, %{"relay" => relay, "port" => port})
      when action in [:"instance.mail_save", :"instance.mail_on"] and is_binary(relay),
      do: [{:m, "#{relay}:#{port}"}]

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
      [{:m, Apiary.ExternalText.sent(id)}],
      rich_ngettext("%{number} open run marked lost", "%{number} open runs marked lost", runs,
        number: Format.number(runs)
      )
    ]
  end

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

  # The instance's settings, each by its row on Instance settings › Configuration, as it
  # was and as it is: a number of days, or of invitations.
  def change(:"instance.configure", before, after_, _details) do
    for {field, label} <- [
          {"audit_retention_days", gettext("Audit log entries")},
          {"audit_address_retention_days", gettext("IP addresses in the audit log")},
          {"deletion_grace_days", gettext("Grace period")},
          {"invitations_per_day", gettext("Invitations a day")}
        ],
        Map.has_key?(after_, field) do
      rich_gettext("%{what}: %{from} → %{to}",
        what: label,
        from: configured(field, before[field]),
        to: configured(field, after_[field])
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

  # A model choice at a run kind, levels 2 and 4: the run kind, in a line. The
  # organisation's default is written under `connection.write`, the rest under
  # `model_choice.write`.
  def change(action, _before, _after, %{"level" => level, "run_kind" => kind})
      when action in [:"model_choice.write", :"connection.write"] and level in [2, 4] and
             is_binary(kind),
      do: gettext("%{kind} runs", kind: kind)

  # A model provider's change: the host, the key's value ID or the model ID before and
  # after, or the key's value ID or the model's ID.
  def change(:"connection.write", before, after_, %{"change" => "provider_keys_changed"} = d),
    do: from_to(before["value_id"], after_["value_id"]) || value_id(d["value_id"])

  def change(:"connection.write", before, after_, %{"change" => "provider_address_changed"}),
    do: from_to(before["host"], after_["host"])

  def change(:"connection.write", before, after_, %{"change" => "provider_default_key_changed"}),
    do: from_to(before["default_value_id"], after_["default_value_id"])

  def change(:"connection.write", before, after_, %{"change" => "provider_default_model_changed"}),
      do: from_to(before["default_model_id"], after_["default_model_id"])

  def change(:"connection.write", _before, _after, %{
        "change" => "provider_model_" <> _,
        "model_id" => id
      })
      when is_binary(id),
      do: [{:m, id}]

  def change(_policy, before, after_, %{"change" => "mode_changed"} = details),
    do: Enum.reject([from_to(before["mode"], after_["mode"]), version(details)], &is_nil/1)

  def change(_policy, _before, _after, %{"change" => _change, "subject" => subject} = details)
      when is_binary(subject),
      do: Enum.reject([[{:m, subject}], version(details)], &is_nil/1)

  def change(_policy, _before, _after, %{"change" => _change} = details), do: version(details)

  def change(_action, _before, _after, _details), do: nil

  defp value_id(id) when is_binary(id), do: [{:m, id}]
  defp value_id(_id), do: nil

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
  defp kind_word("gateway"), do: gettext("Gateway")
  defp kind_word(_node), do: gettext("Node")

  defp limit_or_name("instance_limit", nil), do: gettext("No limit")
  defp limit_or_name("instance_limit", n) when is_integer(n), do: Format.number(n)
  defp limit_or_name(_field, value), do: to_string(value)

  defp configured("invitations_per_day", n) when is_integer(n), do: Format.number(n)
  defp configured("invitations_per_day", _other), do: gettext("n/a")
  defp configured(_days, n), do: days(n)

  defp days(nil), do: gettext("Forever")

  defp days(n) when is_integer(n),
    do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))

  defp days(_other), do: gettext("n/a")
end
