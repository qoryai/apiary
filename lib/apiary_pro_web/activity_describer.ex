defmodule ApiaryProWeb.ActivityDescriber do
  @moduledoc """
  The edition's words for the audit log (`ApiaryWeb.Activity.Describer`), which the page asks
  before the core's (`c:ApiaryWeb.Edition.activity_describer/0`): an operator's clients
  and their parting, the instance's actions, changes of ownership and the instance's
  arbiter, the features granted down the chain, a member's workspace
  access, policy requests, the organisation's policy and its variables, which are said by
  name, never by value. It also says the core's invitation revoked for a reason of the edition's:
  its first owner joined, or its client was deleted; and the entries of an action no
  longer taken, features taken away from a workspace, as they were said.

  A change of ownership and a policy request are said in both organisations' trails,
  each naming the other as it is called now, and without its name once it is gone. The
  instance's actions are offered in the Action filter on the instance organisation's
  page, to those who take them; elsewhere their entries show, and the filter does not
  name them. A change of the organisation's variables is offered in the filter only where
  the organisation has them (`organisation_variables`); its entries show everywhere.
  """

  @behaviour ApiaryWeb.Activity.Describer

  use Gettext, backend: ApiaryProWeb.Gettext

  import ApiaryWeb.Activity.Describer, only: [text: 1, from_to: 2]
  import ApiaryWeb.RichText, only: [rich_gettext: 2]

  alias Apiary.{Access, Features}
  alias ApiaryPro.Flags
  alias ApiaryProWeb.FeatureComponents
  alias ApiaryWeb.Format

  @impl true
  def label(:"workspace_access.add"), do: gettext("Member added to a workspace")
  def label(:"workspace_access.remove"), do: gettext("Member removed from a workspace")
  def label(:"client.create"), do: gettext("Client created")
  def label(:"client.invite_owner"), do: gettext("Client's owner invited")
  def label(:"client.drop"), do: gettext("Client dropped")

  def label(:"client.revoke_owner_invitation"),
    do: gettext("Client's owner invitation revoked")

  def label(:"client.renew_owner_invitation"),
    do: gettext("Client's owner invitation renewed")

  def label(:"client.invite_admin"), do: gettext("Client's first admin invited")

  def label(:"client.revoke_admin_invitation"),
    do: gettext("Client's admin invitation revoked")

  def label(:"client.renew_admin_invitation"),
    do: gettext("Client's admin invitation renewed")

  def label(:"client.delete"), do: gettext("Client deleted")
  def label(:"client.set_model_chain"), do: gettext("Client's model providers changed")
  def label(:"organisation.leave_operator"), do: gettext("Operator left")

  def label(:"instance.create_organisation"),
    do: gettext("Organisation created")

  def label(:"instance.create_operator"), do: gettext("Operator created")
  def label(:"instance.change_kind"), do: gettext("Kind changed")

  def label(:"instance.purge_organisation"),
    do: gettext("Organisation purged on an erasure request")

  def label(:"organisation.transfer"), do: gettext("Offered to an operator")
  def label(:"organisation.withdraw_transfer"), do: gettext("Offer withdrawn")
  def label(:"organisation.accept_transfer"), do: gettext("Ownership accepted")
  def label(:"client.accept"), do: gettext("Organisation accepted as a client")
  # While features are shown by who asks (`ApiaryPro.Flags.feature_visibility?/0`), a
  # change of features is said as a change of what is shown.
  def label(:"client.grant_features") do
    if Flags.feature_visibility?(),
      do: gettext("Client's shown features changed"),
      else: gettext("Client's features changed")
  end

  def label(:"instance.suspend_account"), do: gettext("Account suspended")
  def label(:"instance.activate_account"), do: gettext("Account activated")

  def label(:"instance.suspend_organisation"),
    do: gettext("Organisation suspended")

  def label(:"instance.activate_organisation"),
    do: gettext("Organisation activated")

  def label(:"instance.transfer"), do: gettext("Ownership offered")

  def label(:"instance.grant_features") do
    if Flags.feature_visibility?(),
      do: gettext("Shown features changed"),
      else: gettext("Features changed")
  end

  def label(:"instance.change_sign_up"), do: gettext("Sign-up changed")
  def label(:"instance.adopt"), do: gettext("Adopted at the upgrade")
  def label(:"workspace.narrow_features"), do: gettext("Workspace's features changed")
  def label(:"policy_request.send"), do: gettext("Policy request sent")
  def label(:"policy_request.withdraw"), do: gettext("Policy request withdrawn")
  def label(:"policy_request.accept"), do: gettext("Policy request accepted")
  def label(:"policy_request.decline"), do: gettext("Policy request declined")
  def label(:"organisation_policy.edit"), do: gettext("Organisation's policy changed")
  def label(:"organisation_policy.set_floor"), do: gettext("Enforce required or not")
  def label(:"organisation_policy.set_switch"), do: gettext("Workspace allows turned on or off")
  def label(:"organisation_variable.edit"), do: gettext("Organisation variable changed")
  def label(_action), do: nil

  # The instance actions are offered as a filter in the instance organisation's audit log,
  # to those who take them; elsewhere their entries show, and the filter does not name
  # them. The organisation's variables are offered only where they are, as the core's
  # stored secrets and variables are: they ask
  # `visible?(scope, :organisation_variables)`, and their entries still show, by their
  # labels.
  @impl true
  def offered?(scope, :"organisation_variable.edit"),
    do: Features.visible?(scope, :organisation_variables)

  # An offer to an operator, its acceptance and a client's leaving are offered only while
  # they may be made (`ApiaryPro.Flags.transfers?/0`); their entries show all the same. A
  # withdrawal is offered always: the instance withdraws offers whatever the flag says.
  def offered?(_scope, action)
      when action in [
             :"organisation.transfer",
             :"client.accept",
             :"organisation.leave_operator"
           ],
      do: Flags.transfers?()

  # The first admin's invitation is offered only while it may be made
  # (`ApiaryPro.Flags.operator_infrastructure?/0`); its entries show all the same.
  def offered?(_scope, action)
      when action in [
             :"client.invite_admin",
             :"client.revoke_admin_invitation",
             :"client.renew_admin_invitation"
           ],
      do: Flags.operator_infrastructure?()

  # The choice of a client's model providers is offered only while it may be made
  # (`ApiaryPro.Flags.operator_infrastructure?/0`); its entries show all the same.
  def offered?(_scope, :"client.set_model_chain"), do: Flags.operator_infrastructure?()

  # Policy requests are offered only while they may be sent and answered, while the
  # operator does not own its clients; their entries show all the same.
  def offered?(_scope, action)
      when action in [
             :"policy_request.send",
             :"policy_request.withdraw",
             :"policy_request.accept",
             :"policy_request.decline"
           ],
      do: not Flags.operator_infrastructure?()

  def offered?(scope, action) do
    not String.starts_with?(Atom.to_string(action), "instance.") or
      Access.can?(scope, :"instance.read", scope.organisation)
  end

  # The actions no longer taken whose entries the trail keeps, by the name they were
  # recorded under: `Apiary.Audit.action/1` finds no action for them, so the page asks with
  # none, and they are said as they were. An owner took features away from a workspace
  # until a workspace had its organisation's (`workspace.narrow_features`).
  @retired %{"workspace.narrow_features" => :"workspace.narrow_features"}

  @impl true
  def sentence(nil, %{action: name} = entry, names) when is_map_key(@retired, name),
    do: sentence(Map.fetch!(@retired, name), entry, names)

  def sentence(action, entry, names),
    do: named(action, entry, names) || said(action, entry.details || %{}, entry.actor_kind)

  # A change of ownership in words that name the other organisation, as it is called now;
  # nil where it is gone, for the sentence without its name.
  defp named(:"client.accept", %{after: %{"operator_id" => id}}, names) when is_binary(id) do
    with name when is_binary(name) <- names.organisations[id],
         do:
           gettext("%{operator} became its operator, accepted by an owner of %{operator}",
             operator: name
           )
  end

  defp named(:"client.accept", %{details: %{"organisation_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Accepted %{organisation} as a client", organisation: name)
  end

  defp named(:"organisation.leave_operator", %{before: %{"operator_id" => id}}, names)
       when is_binary(id) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Left %{operator}: it has no operator now", operator: name)
  end

  defp named(:"organisation.leave_operator", %{details: %{"organisation_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("%{organisation} left as a client", organisation: name)
  end

  defp named(:"client.drop", %{before: %{"operator_id" => id}}, names) when is_binary(id) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("%{operator} dropped it as a client: it has no operator now", operator: name)
  end

  defp named(
         :"client.delete",
         %{details: %{"organisation_id" => id, "guard" => "no_people"}},
         names
       ) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Deleted %{organisation}, which nobody had joined yet", organisation: name)
  end

  defp named(:"client.delete", %{details: %{"organisation_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Deleted %{organisation}, which had no owner yet", organisation: name)
  end

  defp named(:"client.drop", %{details: %{"organisation_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Dropped %{organisation} as a client", organisation: name)
  end

  # A policy request, in the operator's trail naming the client, and in the client's naming
  # the operator.
  defp named(:"policy_request.send", %{details: %{"operator_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("%{operator} sent a policy request", operator: name)
  end

  defp named(:"policy_request.accept", %{details: %{"operator_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Accepted a policy request of %{operator}", operator: name)
  end

  defp named(:"policy_request.accept", %{details: %{"organisation_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("%{organisation} accepted a policy request", organisation: name)
  end

  defp named(:"policy_request.decline", %{details: %{"operator_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("Declined a policy request of %{operator}", operator: name)
  end

  defp named(:"policy_request.decline", %{details: %{"organisation_id" => id}}, names) do
    with name when is_binary(name) <- names.organisations[id],
         do: gettext("%{organisation} declined a policy request", organisation: name)
  end

  defp named(:"policy_request.withdraw", %{details: %{"operator_id" => id} = details}, names) do
    with name when is_binary(name) <- names.organisations[id] do
      case details["reason"] do
        "left" ->
          gettext("Left %{operator}: its pending policy request was withdrawn", operator: name)

        "dropped" ->
          gettext("Dropped by %{operator}: its pending policy request was withdrawn",
            operator: name
          )

        "deleted" ->
          gettext("Deleted by %{operator}: its pending policy request was withdrawn",
            operator: name
          )

        _withdrawn ->
          gettext("%{operator} withdrew a policy request", operator: name)
      end
    end
  end

  defp named(
         :"policy_request.withdraw",
         %{details: %{"organisation_id" => id} = details},
         names
       ) do
    with name when is_binary(name) <- names.organisations[id] do
      case details["reason"] do
        "left" ->
          gettext("%{organisation} left: a pending policy request to it was withdrawn",
            organisation: name
          )

        "dropped" ->
          gettext(
            "Dropped %{organisation}: a pending policy request to it was withdrawn",
            organisation: name
          )

        _deleted ->
          gettext(
            "Deleted %{organisation}: a pending policy request to it was withdrawn",
            organisation: name
          )
      end
    end
  end

  defp named(_action, _entry, _names), do: nil

  # What was done, one whole sentence an action, and one a kind of change where an action
  # takes several.
  defp said(:"workspace_access.add", %{"reason" => "demoted"}, _actor),
    do: gettext("Kept a member in a workspace, changing their level")

  defp said(:"workspace_access.add", _details, _actor),
    do: gettext("Added a member to a workspace")

  defp said(:"workspace_access.remove", _details, _actor),
    do: gettext("Removed a member from a workspace")

  defp said(:"invitation.revoke", %{"reason" => "owner_joined"}, _actor),
    do: gettext("Withdrew another invitation of an owner: the first owner joined")

  defp said(:"invitation.revoke", %{"reason" => "admin_joined"}, _actor),
    do: gettext("Withdrew another invitation of an admin: the first admin joined")

  defp said(:"invitation.revoke", %{"reason" => "client_deleted"}, _actor),
    do: gettext("Withdrew an invitation: its organisation was deleted")

  defp said(:"client.create", _details, _actor),
    do: gettext("Created the organisation as a client of its operator")

  defp said(:"instance.create_organisation", _details, _actor),
    do: gettext("Created the organisation")

  defp said(:"instance.create_operator", _details, _actor),
    do: gettext("Created the operator")

  defp said(:"instance.change_kind", _details, _actor),
    do: gettext("Changed the organisation's kind")

  defp said(:"instance.purge_organisation", _details, _actor),
    do: gettext("Purged an organisation at once, on an erasure request")

  defp said(:"organisation.transfer", _details, _actor),
    do: gettext("Offered the organisation to an operator")

  defp said(:"organisation.withdraw_transfer", %{"reason" => "operator_suspended"}, _actor),
    do: gettext("Withdrew an offer of ownership: the operator is suspended")

  defp said(
         :"organisation.withdraw_transfer",
         %{"reason" => "operator_made_organisation"},
         _actor
       ),
       do: gettext("Withdrew an offer of ownership: the operator is no operator any more")

  defp said(:"organisation.withdraw_transfer", %{"reason" => "owner_activated"}, _actor),
    do: gettext("Withdrew an offer of ownership: an owner can act again")

  defp said(:"organisation.withdraw_transfer", _details, _actor),
    do: gettext("Withdrew an offer of ownership")

  defp said(:"organisation.accept_transfer", _details, _actor),
    do: gettext("Accepted the organisation's ownership")

  defp said(:"client.accept", %{"organisation_id" => _}, _actor),
    do: gettext("Accepted an organisation as a client")

  defp said(:"client.accept", _details, _actor),
    do: gettext("An operator became its operator, accepted by an owner of it")

  # An entry of a change of what is shown (`shown: true`, `ApiaryPro.Grants`) is said in
  # those words while features are shown by who asks; any other in the words it was
  # written under.
  defp said(:"client.grant_features", %{"shown" => true}, _actor) do
    if Flags.feature_visibility?(),
      do: gettext("Changed the features its operator shows it"),
      else: gettext("Changed the features its operator grants it")
  end

  defp said(:"client.grant_features", _details, _actor),
    do: gettext("Changed the features its operator grants it")

  defp said(:"client.invite_owner", _details, _actor),
    do: gettext("Invited its first owner, for its operator")

  defp said(:"client.invite_admin", _details, _actor),
    do: gettext("Invited its first admin, for its operator")

  defp said(:"client.revoke_admin_invitation", _details, _actor),
    do: gettext("Revoked an invitation of its first admin, for its operator")

  defp said(:"client.renew_admin_invitation", _details, _actor),
    do: gettext("Made a new link for an invitation of its first admin, for its operator")

  defp said(:"client.revoke_owner_invitation", _details, _actor),
    do: gettext("Revoked an invitation of its first owner, for its operator")

  defp said(:"client.renew_owner_invitation", _details, _actor),
    do: gettext("Made a new link for an invitation of its first owner, for its operator")

  defp said(:"client.delete", %{"guard" => "no_people"}, _actor),
    do: gettext("Deleted a client nobody had joined yet")

  defp said(:"client.delete", _details, _actor),
    do: gettext("Deleted a client that had no owner yet")

  defp said(:"client.set_model_chain", _details, _actor),
    do: gettext("Changed whose model providers a client uses")

  defp said(:"client.drop", %{"organisation_id" => _}, _actor),
    do: gettext("Dropped a client")

  defp said(:"client.drop", _details, _actor),
    do: gettext("Its operator dropped it as a client: it has no operator now")

  defp said(:"organisation.leave_operator", %{"organisation_id" => _}, _actor),
    do: gettext("A client left")

  defp said(:"organisation.leave_operator", _details, _actor),
    do: gettext("Left its operator: it has no operator now")

  defp said(:"instance.suspend_account", _details, _actor),
    do: gettext("Suspended an account")

  defp said(:"instance.activate_account", _details, _actor),
    do: gettext("Activated an account")

  defp said(:"instance.suspend_organisation", _details, _actor),
    do: gettext("Suspended the organisation")

  defp said(:"instance.activate_organisation", _details, _actor),
    do: gettext("Activated the organisation")

  defp said(:"instance.transfer", _details, _actor),
    do: gettext("Offered the organisation's ownership to an admin, as support")

  defp said(:"instance.grant_features", %{"shown" => true}, _actor) do
    if Flags.feature_visibility?(),
      do: gettext("Changed the features the organisation is shown"),
      else: gettext("Changed the organisation's features")
  end

  defp said(:"instance.grant_features", _details, _actor),
    do: gettext("Changed the organisation's features")

  defp said(:"instance.change_sign_up", _details, _actor),
    do: gettext("Changed who may sign up")

  defp said(:"instance.adopt", %{"instance_organisation" => true}, _actor),
    do: gettext("Adopted as the main organisation at the upgrade")

  defp said(:"instance.adopt", _details, _actor),
    do: gettext("Adopted at the upgrade: its members keep every workspace they reached")

  defp said(:"workspace.narrow_features", _details, _actor),
    do: gettext("Changed the workspace's features")

  defp said(:"policy_request.send", %{"clients" => n}, _actor) when is_integer(n),
    do:
      ngettext(
        "Sent a policy request to %{number} client",
        "Sent a policy request to %{number} clients",
        n,
        number: Format.number(n)
      )

  defp said(:"policy_request.send", _details, _actor),
    do: gettext("Its operator sent a policy request")

  defp said(:"policy_request.accept", %{"organisation_id" => _}, _actor),
    do: gettext("A client accepted a policy request")

  defp said(:"policy_request.accept", _details, _actor),
    do: gettext("Accepted a policy request of its operator")

  defp said(:"policy_request.decline", %{"organisation_id" => _}, _actor),
    do: gettext("A client declined a policy request")

  defp said(:"policy_request.decline", _details, _actor),
    do: gettext("Declined a policy request of its operator")

  defp said(:"policy_request.withdraw", %{"organisation_id" => _}, _actor),
    do: gettext("Withdrew a pending policy request from a client that parted")

  defp said(:"policy_request.withdraw", %{"operator_id" => _}, _actor),
    do: gettext("A pending policy request of its operator was withdrawn")

  defp said(:"policy_request.withdraw", _details, _actor),
    do: gettext("Withdrew a policy request")

  defp said(:"organisation_policy.edit", %{"change" => "rule_added"}, _actor),
    do: gettext("Added a rule to the organisation's policy, for every workspace")

  defp said(:"organisation_policy.edit", %{"change" => "rule_changed"}, _actor),
    do: gettext("Changed a rule of the organisation's policy, for every workspace")

  defp said(:"organisation_policy.edit", %{"change" => "rule_removed"}, _actor),
    do: gettext("Removed a rule from the organisation's policy, for every workspace")

  defp said(:"organisation_policy.edit", _details, _actor),
    do: gettext("Changed the organisation's policy, for every workspace")

  defp said(:"organisation_policy.set_floor", _details, _actor),
    do: gettext("Changed whether enforce is required in every workspace")

  defp said(:"organisation_policy.set_switch", _details, _actor),
    do: gettext("Changed whether workspaces may allow more hosts")

  defp said(:"organisation_variable.edit", %{"change" => "created"}, _actor),
    do: gettext("Set a variable of the organisation, for every workspace")

  defp said(:"organisation_variable.edit", %{"change" => "locked"}, _actor),
    do: gettext("Locked a variable of the organisation against every workspace")

  defp said(:"organisation_variable.edit", %{"change" => "unlocked"}, _actor),
    do: gettext("Unlocked a variable of the organisation")

  defp said(:"organisation_variable.edit", %{"change" => "deleted"}, _actor),
    do: gettext("Removed a variable of the organisation")

  defp said(:"organisation_variable.edit", _details, _actor),
    do: gettext("Changed a variable of the organisation")

  defp said(_action, _details, _actor), do: nil

  # What was acted on, as it is called now.
  @impl true
  def subject(entry, action, names, _scope, _workspace) do
    case entry.subject_kind do
      "organisation" when action == :"instance.purge_organisation" ->
        text(gettext("A purged organisation"))

      # An account's suspension is the instance organisation's entry, and names the
      # account.
      "organisation"
      when action in [:"instance.suspend_account", :"instance.activate_account"] ->
        person(entry, names)

      "transfer" ->
        details = entry.details || %{}

        case {names.users[details["user_id"]], details["kind"]} do
          {nil, "to_operator"} -> text(gettext("An operator"))
          {nil, _kind} -> text(gettext("An offer of ownership"))
          {email, _kind} -> text(email)
        end

      "workspace_access" ->
        person(entry, names)

      kind when kind in ["policy_request", "policy_request_answer"] ->
        text(gettext("A policy request"))

      # A variable of the organisation, by the name the entry holds, as the core says a
      # workspace's.
      "organisation_variable" ->
        case (entry.details || %{})["name"] do
          name when is_binary(name) -> %{text: name, mono: true, href: nil}
          _none -> text(gettext("A variable of the organisation"))
        end

      _other ->
        nil
    end
  end

  defp person(entry, names) do
    case names.users[(entry.details || %{})["user_id"]] do
      nil -> text(gettext("Former member"))
      email -> text(email)
    end
  end

  # The change in a few words: what was, and what is.
  @impl true
  def change(:"instance.change_kind", %{"kind" => from}, %{"kind" => to}, _details),
    do: from_to(kind(from), kind(to))

  def change(:"instance.purge_organisation", _before, _after, %{"organisation_id" => id})
      when is_binary(id),
      do: [{:m, id}]

  def change(:"policy_request.decline", _before, _after, %{"reason" => reason})
      when is_binary(reason),
      do: gettext("Reason: %{reason}", reason: reason)

  def change(:"policy_request.accept", _before, _after, %{"workspace_ids" => [_ | _] = ids}),
    do:
      ngettext("In %{number} workspace", "In %{number} workspaces", length(ids),
        number: Format.number(length(ids))
      )

  # The arbiter's reason, as they wrote it.
  def change(:"instance.transfer", _before, _after, %{"reason" => reason})
      when is_binary(reason),
      do: gettext("Reason: %{reason}", reason: reason)

  def change(action, %{"features" => from}, %{"features" => to}, _details)
      when action in [
             :"instance.grant_features",
             :"client.grant_features",
             :"workspace.narrow_features"
           ],
      do: from_to(features(from), features(to))

  # A retired action's entry (`@retired`) that names features before and after: a
  # workspace's, which the page asks about with no action.
  def change(nil, %{"features" => from}, %{"features" => to}, _details),
    do: from_to(features(from), features(to))

  def change(:"organisation_policy.edit", _before, _after, %{"subject" => host})
      when is_binary(host),
      do: [{:m, host}]

  def change(:"organisation_variable.edit", %{"name" => from}, %{"name" => to}, _details)
      when from != to,
      do: from_to(from, to)

  def change(:"organisation_policy.set_floor", _before, %{"enforce_everywhere" => on?}, _details),
    do: if(on?, do: gettext("Enforce required"), else: gettext("Enforce not required"))

  def change(:"organisation_policy.set_switch", _before, %{"own_allows" => on?}, _details),
    do:
      if(on?,
        do: gettext("Workspace allows in force"),
        else: gettext("Only the organisation's allows")
      )

  def change(:"instance.adopt", _before, %{"kind" => to}, _details), do: kind(to)

  # One line for each setting that changed, as it was and as it is.
  def change(:"instance.change_sign_up", before, after_, _details) do
    for {field, label} <- [
          {"organisations", gettext("Organisations")},
          {"operators", gettext("Operators")}
        ],
        Map.has_key?(after_, field) do
      rich_gettext("%{what}: %{from} → %{to}",
        what: label,
        from: sign_up_setting(before[field]),
        to: sign_up_setting(after_[field])
      )
    end
  end

  def change(:"instance.suspend_account", _before, _after, _details), do: gettext("Suspended")
  def change(:"instance.activate_account", _before, _after, _details), do: gettext("Active")
  def change(_action, _before, _after, _details), do: nil

  # A sign-up setting as the Configuration page says it.
  defp sign_up_setting("open"), do: gettext("Open")
  defp sign_up_setting(_closed), do: gettext("Closed")

  # The features an entry names, as a page names them: the built ones, which are all a
  # grant's entry records, and, as the core's Configuration page lists them, an opt-in one
  # where the instance has it on, which an entry written before it was opt-in may name. A
  # feature without a label of the edition's is not named. A part of a feature is named after it,
  # as an entry written while features are shown by who asks lists it, and the nodes, a
  # part of no feature, after the features, as a client's entry lists them.
  defp features([]), do: gettext("None")

  defp features(names) when is_list(names) do
    named =
      Features.built() ++ Enum.filter(Features.opt_in(), &Features.on?/1) ++ Features.parts()

    known = Map.new(named, &{Atom.to_string(&1), &1})

    names
    |> Enum.flat_map(&List.wrap(known[&1]))
    |> Enum.flat_map(&List.wrap(FeatureComponents.label(&1)))
    |> case do
      [] -> gettext("None")
      labels -> Enum.join(labels, ", ")
    end
  end

  defp features(_names), do: nil

  defp kind("organisation"), do: gettext("Organisation")
  defp kind("operator"), do: gettext("Operator")
  defp kind(other), do: other
end
