defmodule ApiaryPro.Access do
  alias Apiary.Access
  alias Apiary.Access.Action
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{Flags, Reach, Tenants}
  alias ApiaryPro.Transfers.Transfer

  @owners [:owner]
  @admins [:owner, :admin]
  @members [:owner, :admin, :member]
  @read "a read changes nothing"

  # Every action the edition adds, named once, as `Apiary.Access` names the core's actions: the
  # feature it belongs to, what it is, the roles that hold it, whether it leaves an audit
  # entry, and what it is asked of.
  @actions [
    # Who reaches which workspace.
    Action.new(:"workspace_access.add", "add a member to a workspace",
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(:"workspace_access.remove", "remove a member from a workspace",
      roles: @admins,
      asked_of: :organisation
    ),
    # The organisation's operator.
    Action.new(
      :"organisation.transfer",
      "offer the organisation to an operator, whose client it becomes once an owner of the operator accepts",
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation.withdraw_transfer",
      "withdraw the pending offer of the organisation's ownership",
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation.accept_transfer",
      "accept the ownership the instance admins offered you, an admin of the organisation: the offer allows it, and no role",
      asked_of: :organisation
    ),
    Action.new(
      :"organisation.leave_operator",
      "leave the organisation's operator at once: it is an organisation with no operator from then on",
      roles: @owners,
      asked_of: :organisation
    ),
    # An operator's clients.
    Action.new(:"client.read", "list an operator's clients, with their status: its Clients page",
      feature: :managed_organisations,
      roles: @members ++ [:reader],
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(
      :"client.create",
      "create a client organisation of the operator, with no workspace, and invite its first owner to it",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.invite_owner",
      "invite the first owner of a client of the operator that has no owner yet, against the operator's invitations",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.revoke_owner_invitation",
      "revoke a pending invitation of the first owner of a client of the operator that has no owner yet",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.renew_owner_invitation",
      "make a new link for a pending invitation of the first owner of a client of the operator that has no owner yet, against the operator's invitations",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.invite_admin",
      "invite the first admin of a client of the operator that has no owner or admin yet, against the operator's invitations",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.revoke_admin_invitation",
      "revoke a pending invitation of the first admin of a client of the operator that has no owner or admin yet",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.renew_admin_invitation",
      "make a new link for a pending invitation of the first admin of a client of the operator that has no owner or admin yet, against the operator's invitations",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.accept",
      "accept an organisation offered to the operator, which becomes its client",
      feature: :managed_organisations,
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"client.grant_features",
      "show or hide features for a client of the operator, of those the operator is shown",
      feature: :managed_organisations,
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"client.drop",
      "drop a client of the operator at once: it is an organisation with no operator from then on",
      feature: :managed_organisations,
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"client.set_model_chain",
      "set whether the runs of a client of the operator use the operator's model providers or the client's",
      feature: :managed_organisations,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"client.delete",
      "delete a client of the operator that has no owner yet: mark it for purging after the grace period",
      feature: :managed_organisations,
      roles: @owners,
      asked_of: :organisation
    ),
    # The instance: the instance organisation's owners, on Instance settings' pages.
    Action.new(
      :"instance.create_organisation",
      "create an organisation on the instance, of which the instance admin is the first owner",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.create_operator",
      "create an operator on the instance, of which the instance admin is the first owner",
      feature: :managed_organisations,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.change_kind",
      "make an organisation that is no client an operator, or an operator without clients an organisation",
      feature: :managed_organisations,
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.purge_organisation",
      "purge an organisation at once, on an erasure request, with its slug typed",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.suspend_account",
      "suspend a person's account: it signs in nowhere and acts nowhere until it is activated",
      roles: @owners,
      asked_of: :account,
      instance: true
    ),
    Action.new(:"instance.activate_account", "end the suspension of a person's account",
      roles: @owners,
      asked_of: :account,
      instance: true
    ),
    Action.new(
      :"instance.suspend_organisation",
      "suspend an organisation or an operator: read-only, its access keys refused, until it is activated",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.activate_organisation",
      "end the suspension of an organisation or an operator",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.transfer",
      "the arbiter: offer the ownership of an organisation whose owners are all suspended to one of its admins",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.grant_features",
      "show or hide features for an operator, or for an organisation with no operator, of those the instance has",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.change_sign_up",
      "change who may sign up on the instance: organisations and operators",
      roles: @owners,
      asked_of: :organisation,
      instance: true
    ),
    Action.new(
      :"instance.adopt",
      "adopt an organisation created before the instance had tenants: taken after the migrations (`ApiaryPro.Adoption`), which no role takes",
      asked_of: :organisation,
      instance: true
    ),
    # An operator's requests for changes to its clients' security policy.
    Action.new(
      :"policy_request.send",
      "send an operator's clients a request for changes to their security policy, with a note saying why its harness needs them",
      feature: :security,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"policy_request.withdraw",
      "withdraw an operator's policy request from the clients that have not answered it",
      feature: :security,
      roles: @admins,
      asked_of: :organisation
    ),
    Action.new(
      :"policy_request.accept",
      "accept a policy request of the client's operator: its changes made in the workspaces chosen, as a write of the policy by the person who accepts",
      feature: :security,
      roles: @members,
      asked_of: :organisation
    ),
    Action.new(
      :"policy_request.decline",
      "decline a policy request of the client's operator, with a reason or none",
      feature: :security,
      roles: @members,
      asked_of: :organisation
    ),
    # The organisation's policy, above its workspaces' (`ApiaryPro.OrganisationPolicy`).
    Action.new(
      :"organisation_policy.read",
      "read the organisation's policy: the rules every workspace follows, the floor and the switch",
      feature: :organisation_policy,
      roles: @admins ++ [:reader],
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(
      :"organisation_policy.edit",
      "add, change and remove the organisation's rules, which every workspace is rendered again under",
      feature: :organisation_policy,
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation_policy.set_floor",
      "require enforce in every workspace of the organisation, or stop requiring it",
      feature: :organisation_policy,
      roles: @owners,
      asked_of: :organisation
    ),
    Action.new(
      :"organisation_policy.set_switch",
      "let workspaces allow more hosts, or allow only the hosts on the organisation's list",
      feature: :organisation_policy,
      roles: @owners,
      asked_of: :organisation
    ),
    # The organisation's variables, above its workspaces' (`ApiaryPro.OrganisationVariables`).
    Action.new(
      :"organisation_variable.read",
      "read the organisation's variables, their values and locks, and how many workspaces and repositories set each",
      feature: :organisation_variables,
      roles: @admins ++ [:reader],
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(
      :"organisation_variable.edit",
      "create, change, lock, unlock and delete the organisation's variables, which every workspace inherits",
      feature: :organisation_variables,
      roles: @admins,
      asked_of: :organisation
    ),
    # The organisation's secrets, beside its workspaces'
    # (`ApiaryPro.OrganisationSecrets`): the core keeps them (`Apiary.Secrets`) and asks
    # the edition who may (`c:Apiary.Edition.organisation_secrets/2`). Read as the
    # organisation's variables are: by its owners, its admins and the readers.
    Action.new(
      :"organisation_secret.read",
      "read the organisation's secrets: their names, notes and value IDs, never a value",
      feature: :organisation_variables,
      roles: @admins ++ [:reader],
      asked_of: :organisation,
      audited: {:not, @read}
    ),
    Action.new(
      :"organisation_secret.write",
      "create a secret of the organisation, change its name, note and values, and delete it",
      feature: :organisation_variables,
      roles: @admins,
      asked_of: :organisation,
      audited: {:not, "the core writes the change's `secret.write` entry, on the secret"}
    ),
    Action.new(
      :"organisation_secret.use",
      "link a stored secret to what uses it",
      feature: :organisation_variables,
      roles: @admins,
      asked_of: :organisation,
      audited:
        {:not,
         "a link is part of the change to what uses the secret, and that change leaves the entry"}
    )
  ]

  @roles [
    # One who reaches an organisation with no membership there: a person of its operator,
    # at any level there, in one of its clients, or an instance admin in an organisation
    # they reach no other way.
    reader:
      "an instance admin anywhere, or an operator's person in its clients: reads everything in every workspace, changes nothing",
    # Anyone signed in, whose account is neither deleted nor suspended.
    person:
      "anyone signed in, in any organisation or none, for a kind of organisation the instance opens"
  ]

  # What is read, and changes nothing: all a reader may, and all a suspended organisation
  # still allows.
  @reads [
    :"member.read",
    :"run.read",
    :"run.read_log",
    :"security_policy.read",
    :"secret.read",
    :"variable.read",
    :"connection.read",
    :"audit.read",
    :"node.read",
    :"client.read",
    :"organisation_policy.read",
    :"organisation_variable.read",
    :"organisation_secret.read",
    :"adapter.read",
    :"work_item.read"
  ]

  # The reads the moduledoc lists: all but those of a feature the documentation does not
  # differ by, which no doc names.
  @documented_reads @reads -- [:"adapter.read", :"work_item.read"]

  # The actions hidden while `ApiaryPro.Flags.transfers?/0` is off: not found for everyone,
  # and left out of the table of actions below.
  @flagged_transfers [
    :"organisation.transfer",
    :"organisation.withdraw_transfer",
    :"organisation.leave_operator",
    :"client.accept"
  ]

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the client's decisions,
  # which nobody takes in a client through its operator, whatever their level there: its
  # leaving, its offer to another operator and the offer's withdrawal, its deletion, and
  # the answers to its operator's policy requests.
  @not_through_operator [
    :"organisation.leave_operator",
    :"organisation.transfer",
    :"organisation.withdraw_transfer",
    :"organisation.delete",
    :"policy_request.accept",
    :"policy_request.decline"
  ]

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, a client's first person is
  # invited as its admin, and the actions of the first owner's invitation, and a client's
  # drop, are not found; while it is off, the first admin's are, and they are left out of
  # the table of actions below.
  @owner_invitations [
    :"client.invite_owner",
    :"client.revoke_owner_invitation",
    :"client.renew_owner_invitation"
  ]
  @admin_invitations [
    :"client.invite_admin",
    :"client.revoke_admin_invitation",
    :"client.renew_admin_invitation"
  ]
  # Not found while `ApiaryPro.Flags.operator_infrastructure?/0` is off, and left out of the
  # table of actions below: the operator's choice of the model providers a client uses.
  @needs_operator_infrastructure [:"client.set_model_chain"]
  # An operator's policy requests, and its clients' answers to them, are not found while it
  # is on either.
  @policy_requests [
    :"policy_request.send",
    :"policy_request.withdraw",
    :"policy_request.accept",
    :"policy_request.decline"
  ]
  @hidden_while_operator_owns [:"client.drop" | @owner_invitations ++ @policy_requests]

  # The actions over a client's people a client's admin takes on its admins as on its
  # members while the flag is on: nobody in a client is an owner but those who were.
  @over_admins [:"member.remove", :"member.change_level"]

  # What the operator sets in a client, which, while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), only the operator's owners and admins
  # hold: for anyone else in the client, its owners and admins among them, it is not
  # there. They are the client's nodes, a pool's instance limit and the access keys, the
  # time limits of its workspaces and targets, a workspace's retention, and the harness
  # documents saved at its levels. Reading any of these is not among them; the client
  # reads it. The client keeps its integrations and services
  # (`connection.write`). Its model providers and runtimes and the model choices of its
  # workspaces and targets follow its switch (`@chain_held`).
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

  # What a client's model providers decide: its providers and runtimes, and the model
  # choices of its workspaces and targets. While the flag is on, they are held by the
  # operator's owners and admins when the client's switch is `:operator`
  # (`ApiaryPro.Tenants.model_chain/1`), and not there for anyone else in the client. While
  # it is `:organisation`, they follow the usual rules, as in a client with no operator:
  # the client's owners and admins hold them, and a person who acts in the client through
  # its operator reads only.
  @chain_held [:"provider.write", :"runtime.write", :"model_choice.write"]

  # While the operator owns its clients, a client's workspace rule locks, and its
  # organisation's policy, are the operator's owners' alone: locking and unlocking a rule,
  # changing or removing a locked one, and the organisation's rules, floor and switch.
  @operator_owners_in_client [
    :"security_policy.lock",
    :"organisation_policy.edit",
    :"organisation_policy.set_floor",
    :"organisation_policy.set_switch"
  ]

  @instance_actions for %Action{name: name, instance: true} <- @actions, do: name

  # What nobody may do to the instance organisation: it holds the instance admins, and an
  # instance without it would give its next sign-up the instance.
  @not_on_instance_organisation [
    :"organisation.delete",
    :"organisation.purge",
    :"organisation.transfer",
    :"organisation.withdraw_transfer"
  ]

  @moduledoc """
  Access is what the edition adds to `Apiary.Access`: its actions, its roles, and its
  part of the answer (`check/3`), which `c:Apiary.Edition.check/3` asks
  once a feature is on and before the core looks at the place.

  What it answers:

  1. **The instance actions** (`instance: true`) are the instance organisation's owners'.
     `Apiary.Access` checks the feature and the instance step first: a person's scope
     outside the instance organisation, or in it while it is marked for deletion, is not
     found. For the edition's instance actions, `check/3` then checks the role, the subject and
     the edition's rules; for the core's it returns `:continue`, and the core checks the place and
     the role. Listing is checked on the instance organisation itself, and creating on it or
     a workspace of it; changing a kind, purging at once, suspending, activating,
     transferring and granting features on the organisation acted on. Of these only a change
     of kind is taken on the instance organisation itself, which may be of either kind; the
     rest are refused for it: it is never purged, suspended or transferred, and has every
     feature the instance has.
     Suspending and activating an account are asked of the account, never the asker's account.
     A kind is not changed, and an organisation not transferred or granted features, once
     it is marked for deletion.
  2. **A person's action, asked of no place**: creating an organisation later, as a person
     who has an account (`organisation.create`,
     `ApiaryPro.Organisations.create_organisation/2`), is the role `person`'s, and asked of
     no place: of the new organisation, an
     `%Apiary.Organisations.Organisation{}` not inserted yet, with the kind asked for.
     Anyone signed in may, whose account is neither deleted nor suspended, for a kind the
     instance's sign-up settings open (`ApiaryPro.SignUp.kinds/0`). A kind whose
     setting is closed, and anything but a new organisation of no operator, is
     `{:error, :forbidden}`; so is every scope without a person.
  3. Once the place is known (`Apiary.Access.check_place/3`), for every other action:
     - **the organisation's secrets**: `organisation_secret.read`,
       `organisation_secret.write` and `organisation_secret.use` are not found, for every
       role, in an organisation that does not have the feature `organisation_variables`
       (`ApiaryPro.Features.of/2`);
     - **what kind of organisation it is**: an operator's actions over its clients
       (`client.*`, `policy_request.send`, `policy_request.withdraw`) are asked in an
       operator, and not found in an organisation of another kind; answering its policy
       requests (`policy_request.accept`, `policy_request.decline`) is asked in a client,
       and not found in an organisation with no operator;
     - **the instance organisation**: #{Enum.map_join(@not_on_instance_organisation -- @flagged_transfers, ", ", &"`#{&1}`")}
       are forbidden on it, for every role, the instance's included (`Apiary.Access.refused_on?/2`);
     - **suspension**: a suspended organisation (`suspended?/1`) is read-only, every
       action but the reads (`reads/0`) forbidden there for every role but
       the instance's jobs;
     - **the reader**: one who reaches the organisation through its operator, or as an
       instance admin, reads everything in every workspace (`reads/0`); a person of the
       operator who holds a membership there too changes only what that membership
       allows, in the workspaces it reaches;
     - **workspace access**: adding a person to a workspace and removing them from one are
       over people, as the core's are (`Apiary.Access.acts_on?/2`).

  The rest is the core's: its role table, which the edition's actions join through their
  `roles`, and the membership's rules.

  ## Actions

  | Action | What | Feature |
  |---|---|---|
  #{@actions |> Enum.reject(&(&1.name in (@flagged_transfers ++ @admin_invitations ++ @needs_operator_infrastructure))) |> Enum.map_join("\n", fn action -> "| `#{action.name}` | #{action.what} | #{if action.feature, do: "`#{action.feature}`", else: "every instance"} |" end)}

  ## Roles

  | Role | Who |
  |---|---|
  #{Enum.map_join(@roles, "\n", fn {role, who} -> "| `#{role}` | #{who} |" end)}

  The reader holds every read, among them
  #{Enum.map_join(@documented_reads, ", ", &"`#{&1}`")}; the person holds
  `organisation.create`, which `check/3` answers for them. The edition's actions are held by the
  core's levels too, as each one's `roles` say.
  """

  # The actions of an operator over its clients, asked in the operator: in an organisation
  # of another kind they are not found, as a page that is not there.
  @operator_actions [
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
    :"policy_request.send",
    :"policy_request.withdraw"
  ]

  # The actions of a client over its place, asked in the client: in an organisation with
  # no operator they are not found.
  @client_actions [
    :"organisation.leave_operator",
    :"policy_request.accept",
    :"policy_request.decline"
  ]

  # The instance actions asked of the organisation acted on: a change of kind, and what is
  # never taken on the instance organisation itself, which holds the instance admins, so
  # it is never purged, suspended or transferred, and has every feature the instance has.
  # Its kind is changed as any other organisation's.
  @instance_actions_not_on_itself [
    :"instance.purge_organisation",
    :"instance.suspend_organisation",
    :"instance.activate_organisation",
    :"instance.transfer",
    :"instance.grant_features"
  ]
  @instance_actions_on_organisations [:"instance.change_kind" | @instance_actions_not_on_itself]
  # The instance actions asked of a person's account, which is no organisation's.
  @instance_actions_on_accounts [:"instance.suspend_account", :"instance.activate_account"]

  @workspace_access [:"workspace_access.add", :"workspace_access.remove"]

  # The organisation's secrets, not found in an organisation that does not have their
  # feature. A place rule and not only the actions' feature: `Apiary.Features.visible?/2`
  # shows an instance admin and an operator's people what the organisation they ask in may
  # not have, while `ApiaryPro.Flags.feature_visibility?/0` is on.
  @organisation_secrets [
    :"organisation_secret.read",
    :"organisation_secret.write",
    :"organisation_secret.use"
  ]

  @doc """
  actions/0 is the edition's actions, each an `Apiary.Access.Action`, in the order of the
  table.
  """
  @spec actions() :: [Apiary.Access.Action.t()]
  def actions, do: @actions

  @doc "roles/0 is the edition's roles, `reader` and `person`, with who holds each."
  @spec roles() :: %{atom => String.t()}
  def roles, do: Map.new(@roles)

  @doc """
  reads/0 is the actions that read and change nothing: all a reader may, and all a
  suspended organisation still allows.
  """
  @spec reads() :: [Access.action()]
  def reads, do: @reads

  @doc """
  suspended?/1 says whether the scope's organisation is suspended (`ApiaryPro.Suspensions`),
  as the scope carries it: read-only, for everyone in it. A page says so, and shows no
  control that changes something, since `Apiary.Access.can?/3` answers no for each.
  """
  @spec suspended?(Scope.t() | nil) :: boolean
  def suspended?(%Scope{organisation: %Organisation{} = organisation}),
    do: Tenants.suspended?(organisation)

  def suspended?(_scope), do: false

  @doc """
  check/3 is the edition's part of `Apiary.Access.check/3` (`c:Apiary.Edition.check/3`): the
  result for the edition's instance actions and for a person's action with no place, and,
  once the place is known, the refusals and the reads above; `:continue` leaves the rest to
  the core. With no scope, what the subject refuses whoever asks: the instance
  organisation's deletion, purge and transfer.
  """
  @spec check(Scope.t() | nil, Access.action(), Access.subject() | nil) ::
          :continue | :ok | {:error, Access.reason()}
  # Before all of it, what a flag hides is not found, for everyone (`hidden?/2`).
  # `ApiaryPro.Flags.operator_infrastructure?/0` is read once here and passed to `hidden?/2`
  # and the steps of `answer/4`. It is read again elsewhere for the same question: by
  # `role/1`, which the core calls after `:continue`, and by the check the core runs again
  # when someone in both acts at their level in the operator.
  def check(scope, action, subject) do
    on? = Flags.operator_infrastructure?()

    if hidden?(action, on?),
      do: {:error, :not_found},
      else: answer(scope, action, subject, on?)
  end

  # hidden?/1 is true when a flag hides `action` now, as a path that does not exist: the
  # actions `ApiaryPro.Flags.transfers?/0` gates while it is off; the first owner's
  # invitation, a client's drop and the policy requests while
  # `ApiaryPro.Flags.operator_infrastructure?/0` is on; the first admin's invitation and
  # the operator's choice of a client's model providers while it is off. `check/3` calls
  # `hidden?/2` first, and a page that is not there while a flag hides its action calls
  # `hidden?/1`. Not in the published documentation: what a flag hides is not named there
  # (`ApiaryPro.Flags`).
  @doc false
  @spec hidden?(Access.action()) :: boolean
  def hidden?(action), do: hidden?(action, Flags.operator_infrastructure?())

  defp hidden?(action, on?) do
    cond do
      action in @flagged_transfers -> not Flags.transfers?()
      action in @hidden_while_operator_owns -> on?
      action in @admin_invitations or action in @needs_operator_infrastructure -> not on?
      true -> false
    end
  end

  defp answer(nil, action, subject, _on?) do
    if action in @not_on_instance_organisation and instance_organisation?(subject),
      do: {:error, :forbidden},
      else: :continue
  end

  defp answer(scope, action, subject, _on?) when action in @instance_actions,
    do: check_instance(scope, action, subject)

  defp answer(scope, :"organisation.create", subject, _on?), do: check_person(scope, subject)

  # An offer of the ownership, which allows the action where no role does: anyone but the
  # person it is offered to gets `:not_found`, and that person gets `:forbidden` once they
  # are no admin in use. Before the suspension rule (`check_in_place/5`): the page shows a pending
  # offer in a suspended organisation, and `ApiaryPro.Transfers.accept/1` returns
  # `:suspended` there.
  defp answer(scope, :"organisation.accept_transfer" = action, %Transfer{} = offer, _on?) do
    with :ok <- Access.check_place(scope, action, offer) do
      cond do
        not recipient?(scope, offer) -> {:error, :not_found}
        Access.level(scope) != :admin -> {:error, :forbidden}
        true -> :ok
      end
    end
  end

  # Every other action. An instance action goes to the core with `:continue`, and the core
  # checks its place and role. Any other action gets `Access.check_place/3` here, which
  # returns `:not_found` for an account as the subject, whatever the scope, then
  # `check_in_place/5`.
  defp answer(scope, action, subject, on?) do
    if Access.action(action).instance do
      :continue
    else
      with :ok <- Access.check_place(scope, action, subject) do
        check_in_place(scope, action, subject, scope_role(scope, on?), on?)
      end
    end
  end

  defp recipient?(%Scope{user: %User{id: id}}, %Transfer{kind: :to_admin, recipient_id: id}),
    do: true

  defp recipient?(_scope, _offer), do: false

  # The role the scope acts in, as `Apiary.Access.role/1` gives it, with the flag as this
  # answer read it: a person who reaches the organisation through its operator alone
  # takes the role of their level there (`operator_role/2`); anyone else's is the core's,
  # which asks `role/1` only where there is no operator's level to read the flag for.
  defp scope_role(scope, on?) do
    case {Access.level(scope), Reach.operator_level(scope)} do
      {nil, via} when not is_nil(via) -> operator_role(via, on?)
      _own_or_none -> Access.role(scope)
    end
  end

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the operator's owners act in
  # its clients as owners and its admins as admins; its members, and everyone while it is
  # off, read.
  defp operator_role(level, true) when level in [:owner, :admin], do: level
  defp operator_role(_level, _on?), do: :reader

  # A person in both, while the flag is on, whose level in the operator is an owner's or an
  # admin's and higher than their level in the client: they act at the higher of their two
  # levels, through the operator.
  defp higher_through_operator?(scope, via) do
    own = Access.level(scope)

    not is_nil(own) and via in [:owner, :admin] and higher?(via, own)
  end

  @doc """
  through_operator?/1 says whether the person of `scope` acts in its organisation, a
  client, through the client's operator: they have a level in the operator and either no
  membership in the client, or a level in the operator strictly higher than theirs in the
  client. As the scope carries it.
  """
  @spec through_operator?(Scope.t() | nil) :: boolean
  def through_operator?(scope), do: through_operator?(scope, Reach.operator_level(scope))

  # Whether the person acts in the client through its operator: they have a level in the
  # operator and either no membership in the client, or a level in the operator strictly
  # higher than theirs in the client. On a tie they act at their level in the client.
  defp through_operator?(_scope, nil), do: false
  defp through_operator?(scope, via), do: through_operator_at?(via, Access.level(scope))

  # through_operator_at?/2 is the same answer from the two levels alone: `via`, the
  # person's in the operator, and `own`, theirs in the client, nil for none. For
  # `ApiaryPro.Reach.acted_through_operator?/1`, which has no scope to ask with.
  @doc false
  @spec through_operator_at?(Membership.level() | nil, Membership.level() | nil) :: boolean
  def through_operator_at?(nil, _own), do: false
  def through_operator_at?(_via, nil), do: true
  def through_operator_at?(via, own), do: higher?(via, own)

  defp higher?(via, own), do: rank(via) > rank(own)

  defp rank(:owner), do: 3
  defp rank(:admin), do: 2
  defp rank(:member), do: 1

  defp check_in_place(scope, action, subject, role, on?) do
    via = Reach.operator_level(scope)

    cond do
      action in @organisation_secrets and not has_organisation_secrets?(subject) ->
        {:error, :not_found}

      action in @operator_actions and not operator?(scope) ->
        {:error, :not_found}

      action in @client_actions and not client?(scope) ->
        {:error, :not_found}

      action in @not_on_instance_organisation and instance_organisation?(subject) ->
        {:error, :forbidden}

      role != :instance and suspended?(scope) and action not in @reads ->
        {:error, :forbidden}

      # A reader, and a person of the operator whatever their membership there, reads
      # everything.
      action in @reads and (role == :reader or via != nil) ->
        :ok

      # While the flag is on, what the operator sets in a client is held by the operator's
      # owners and admins: for anyone else, the client's owners and admins among them, it
      # is not there.
      on? and action in @operator_held and client?(scope) and via not in [:owner, :admin] ->
        {:error, :not_found}

      # While the flag is on and the client's switch is `:operator`, the model providers
      # are the operator's owners' and admins': for anyone else in the client it is not
      # there. On `:organisation` the person who acts there through the operator reads only.
      on? and action in @chain_held and client?(scope) and operator_chain?(scope) and
          via not in [:owner, :admin] ->
        {:error, :not_found}

      on? and action in @chain_held and client?(scope) and not operator_chain?(scope) and
          through_operator?(scope, via) ->
        {:error, :forbidden}

      # While the flag is on, a client's rule locks and its organisation's policy are the
      # operator's owners' alone: anyone else is refused, the client's owners among them.
      on? and action in @operator_owners_in_client and client?(scope) and via != :owner ->
        {:error, :forbidden}

      # While the flag is on, the client's decisions are refused to anyone who acts in it
      # through its operator (`through_operator?/2`), the check run again for
      # someone in both with no membership among them; anyone else answers at their level
      # in the client.
      on? and action in @not_through_operator and through_operator?(scope, via) ->
        {:error, :forbidden}

      # While the flag is on, a client's workspaces are deleted and brought back by the
      # operator's owners and admins: whatever their level in the client, as the
      # operator's level says, not the role.
      on? and action in [:"workspace.delete", :"workspace.restore"] and client?(scope) and
          via not in [:owner, :admin] ->
        {:error, :forbidden}

      # While the flag is on, a person in both whose level in the operator is higher acts
      # at it, as though they had no membership in the client.
      on? and higher_through_operator?(scope, via) ->
        Access.check(%{scope | membership: nil}, action, subject)

      # A person of the operator who is a member of the client too reads every workspace
      # through the operator, and changes only where their membership in the client
      # reaches. While the flag is on, the operator's owners and admins reach every
      # workspace.
      via != nil and operator_role(via, on?) == :reader and
          not Reach.own_reaches?(scope, subject) ->
        {:error, :forbidden}

      # While the flag is on, a client's admins act on its admins as on its members: they
      # remove them and change their level, between admin and member
      # (`ApiaryPro.Edition`'s `membership_changed/5` refuses an owner). An admin never
      # acts on an owner.
      on? and role == :admin and action in @over_admins and client?(scope) and
          match?(%Membership{level: level} when level in [:admin, :member], subject) ->
        :ok

      # A client's admins create its workspaces as its owners do, with the flag on or off.
      # The core gives the action to owners alone. While the flag is on, a person who acts
      # through the operator has the operator's role instead, which the core answers. While
      # it is off, the operator's level gives nothing to change, so a person who is an
      # admin of the client and an owner of its operator acts as the client's admin.
      action == :"workspace.create" and role == :admin and client?(scope) and
          not (on? and through_operator?(scope, via)) ->
        :ok

      action in @workspace_access and not over?(role, subject) ->
        {:error, :forbidden}

      true ->
        :continue
    end
  end

  # Whether the organisation acted on has the feature of its secrets. Any other subject is
  # false, so it is not found: every caller passes the organisation.
  defp has_organisation_secrets?(%Organisation{} = organisation),
    do: :organisation_variables in ApiaryPro.Features.of(organisation)

  defp has_organisation_secrets?(_subject), do: false

  # Adding to and removing from a workspace is over people: an owner over anyone, an admin
  # over members, asked of the membership; asked of anything else the role alone answers.
  defp over?(role, %Membership{level: level}), do: Access.acts_on?(role, level)
  defp over?(_role, _subject), do: true

  # An instance action of the edition, once the core's instance step passed the scope: asked
  # by an owner of the instance organisation. Creating is checked on the instance
  # organisation, or a workspace of it, as its page does; changing a kind, purging and the
  # rest on the organisation acted on, which is the instance organisation itself only for a
  # change of kind; and a kind is not changed on an organisation marked for deletion, which
  # is gone but for its purge.
  #
  # The core's step passes the instance's scope in any organisation, and reads neither that
  # scope's marks nor a workspace's mark: the first two steps here keep those not found.
  defp check_instance(scope, action, subject) do
    cond do
      Access.role(scope) == :instance and not instance_organisation?(scope.organisation) ->
        {:error, :not_found}

      marked?(scope) ->
        {:error, :not_found}

      Access.role(scope) not in Access.action(action).roles ->
        {:error, :forbidden}

      not instance_subject?(scope, action, subject) ->
        {:error, :not_found}

      action in @instance_actions_not_on_itself and instance_organisation?(subject) ->
        {:error, :forbidden}

      action in @instance_actions_on_accounts and own_account?(scope, subject) ->
        {:error, :forbidden}

      action in [:"instance.change_kind", :"instance.transfer", :"instance.grant_features"] and
          marked?(subject) ->
        {:error, :not_found}

      true ->
        :ok
    end
  end

  defp instance_subject?(_scope, action, %Organisation{})
       when action in @instance_actions_on_organisations,
       do: true

  defp instance_subject?(_scope, action, _subject)
       when action in @instance_actions_on_organisations,
       do: false

  defp instance_subject?(_scope, action, subject) when action in @instance_actions_on_accounts,
    do: match?(%User{deleted_at: nil}, subject)

  defp instance_subject?(scope, _action, subject), do: Access.within?(scope, subject)

  # An instance admin does not suspend or activate the account they are signed in with.
  defp own_account?(%Scope{user: %User{id: id}}, %User{id: id}), do: true
  defp own_account?(_scope, _subject), do: false

  # A person's action, asked of no place: no level, whatever organisation the scope is in.
  defp check_person(scope, subject) do
    cond do
      not person?(scope) -> {:error, :forbidden}
      not new_organisation?(subject) -> {:error, :forbidden}
      Tenants.kind(subject) not in ApiaryPro.SignUp.kinds() -> {:error, :forbidden}
      true -> :ok
    end
  end

  # A person signed in: a suspended account has no session, and a creation reads the
  # account's suspension again inside its transaction
  # (`ApiaryPro.Organisations.create_organisation/2`).
  defp person?(%Scope{user: %User{deleted_at: nil}, access_key: nil, instance: false}),
    do: true

  defp person?(_scope), do: false

  defp new_organisation?(%Organisation{id: nil} = organisation) do
    tenant = Tenants.tenant(organisation)

    tenant.kind in Tenants.kinds() and not tenant.instance_organisation and
      is_nil(tenant.operator_id)
  end

  defp new_organisation?(_subject), do: false

  @doc """
  role/1 is the role the edition gives the scope's person through its reach
  (`c:Apiary.Edition.role/1`): `:reader` for a person of a client's operator, reaching it
  through their membership in the operator, and for an instance admin in an organisation
  other than the instance organisation; nil for anyone else. As the scope carries it.
  """
  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the operator's owners and
  # admins take the role of their level instead (`operator_role/2`). The flag is read only
  # where there is an operator's level.
  @spec role(Scope.t() | nil) :: Access.role() | nil
  def role(scope) do
    case Reach.operator_level(scope) do
      nil -> if Reach.instance_reach?(scope), do: :reader
      via -> operator_role(via, Flags.operator_infrastructure?())
    end
  end

  defp operator?(%Scope{organisation: %Organisation{} = organisation}),
    do: Tenants.operator?(organisation)

  defp operator?(_scope), do: false

  defp client?(%Scope{organisation: %Organisation{} = organisation}),
    do: Tenants.client?(organisation)

  defp client?(_scope), do: false

  defp operator_chain?(%Scope{organisation: %Organisation{} = organisation}),
    do: Tenants.model_chain(organisation) == :operator

  defp instance_organisation?(subject), do: Tenants.instance_organisation?(subject)

  # Whether the scope's organisation or workspace is marked for deletion, as it carries
  # them, or a subject that is one.
  defp marked?(%Scope{organisation: organisation, workspace: workspace}),
    do: marked?(organisation) or marked?(workspace)

  defp marked?(%Organisation{deletion_marked_at: %DateTime{}}), do: true
  defp marked?(%Workspace{deletion_marked_at: %DateTime{}}), do: true
  defp marked?(_row), do: false
end
