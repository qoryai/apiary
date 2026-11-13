defmodule ApiaryPro.Edition do
  @moduledoc """
  The edition (`Apiary.Edition`): what it adds to the core, each callback answered by
  the context of `ApiaryPro` that owns it.
  """

  use Apiary.Edition
  use Gettext, backend: ApiaryProWeb.Gettext

  # --- Access, suspension, places, invitations -----------------------------------------

  @impl true
  def actions, do: ApiaryPro.Access.actions()

  @impl true
  def roles, do: ApiaryPro.Access.roles()

  @impl true
  def check(scope, action, subject), do: ApiaryPro.Access.check(scope, action, subject)

  @impl true
  def reach(scope), do: ApiaryPro.Reach.reach(scope)

  @impl true
  def put_organisation(organisation), do: ApiaryPro.Tenants.put(organisation)

  @impl true
  def role(scope), do: ApiaryPro.Access.role(scope)

  @impl true
  def reload(scope, opts), do: ApiaryPro.Reach.reload(scope, opts)

  @impl true
  def places_to_lock(organisation), do: ApiaryPro.Reach.places_to_lock(organisation)

  @impl true
  def lock_rows(about), do: ApiaryPro.Tenants.lock_rows(about)

  @impl true
  def every_workspace_levels, do: ApiaryPro.Reach.every_workspace_levels()

  @impl true
  def reaches_workspace?(scope, workspace_id, opts),
    do: ApiaryPro.Reach.reaches_workspace?(scope, workspace_id, opts)

  @impl true
  def reached_workspaces(query, scope), do: ApiaryPro.Reach.reached_workspaces(query, scope)

  @impl true
  def active_accounts(query, binding), do: ApiaryPro.Suspensions.active_accounts(query, binding)

  @impl true
  def active_organisations(query, binding),
    do: ApiaryPro.Suspensions.active_organisations(query, binding)

  @impl true
  def account_refusal(user), do: ApiaryPro.Suspensions.account_refusal(user)

  @impl true
  def places(user), do: ApiaryPro.Places.places(user)

  @impl true
  def serving_organisations(organisation_id),
    do: ApiaryPro.Gateways.serving_organisations(organisation_id)

  @impl true
  def served_organisations(organisation_id),
    do: ApiaryPro.Gateways.served_organisations(organisation_id)

  @impl true
  def accepting(repo, invitation, user),
    do: ApiaryPro.Invitations.accepting(repo, invitation, user)

  @impl true
  def accepted(repo, scope, invitation, membership),
    do: ApiaryPro.Invitations.accepted(repo, scope, invitation, membership)

  # A person made a member keeps a workspace; an owner who may act again takes back what
  # the arbiter offered. While `ApiaryPro.Flags.operator_infrastructure?/0` is on, nobody
  # in a client is made an owner: the operator owns it, and the change is rolled back.
  @impl true
  def membership_changed(repo, scope, :level, old, new) do
    if ApiaryPro.Flags.operator_infrastructure?() and new.level == :owner and
         ApiaryPro.Tenants.client?(%Apiary.Organisations.Organisation{id: new.organisation_id}),
       do: {:error, :forbidden},
       else: ApiaryPro.WorkspaceAccess.level_changed(repo, scope, old, new)
  end

  def membership_changed(_repo, _scope, :activated, _old, new),
    do: ApiaryPro.Transfers.membership_activated(new)

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, owner is not given in a
  # client, by anyone: the operator owns it. Asked inside a change (`lock:`), the client's
  # tenant is read again as the database has it, without a lock; a page asks the one its
  # scope carries. `membership_changed/5` still rolls back a change that makes an owner.
  @impl true
  def level_refusal(_scope, organisation, :owner, opts) do
    if ApiaryPro.Flags.operator_infrastructure?() and client_now?(organisation, opts),
      do: :operator_owns
  end

  def level_refusal(_scope, _organisation, _level, _opts), do: nil

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, an entry made in a client by
  # a person who acts there through its operator keeps the operator they acted through,
  # `via_operator_id`, which the Activity page names beside them
  # (`ApiaryProWeb.Edition`'s `activity_actor/2`). From the scope, without a read.
  @impl true
  def audit_details(
        %Apiary.Accounts.Scope{
          organisation: %Apiary.Organisations.Organisation{id: id},
          reach: {:operator, %Apiary.Organisations.Membership{organisation_id: operator_id}}
        } = scope,
        id,
        details
      ) do
    if ApiaryPro.Flags.operator_infrastructure?() and ApiaryPro.Access.through_operator?(scope),
      do: Map.put(details, "via_operator_id", operator_id),
      else: details
  end

  # An entry a person of the operator writes in its client from the operator's pages
  # (`ApiaryPro.Reach.in_client/2`) keeps the operator by the same rule; their membership in
  # the client is read, without a lock, only while the flag is on.
  def audit_details(
        %Apiary.Accounts.Scope{
          organisation: %Apiary.Organisations.Organisation{id: id},
          reach: nil,
          edition: %{acted_from: %Apiary.Organisations.Membership{organisation_id: operator_id}}
        } = scope,
        id,
        details
      ) do
    if ApiaryPro.Flags.operator_infrastructure?() and
         ApiaryPro.Reach.acted_through_operator?(scope),
       do: Map.put(details, "via_operator_id", operator_id),
       else: details
  end

  def audit_details(_scope, _organisation_id, details), do: details

  defp client_now?(%Apiary.Organisations.Organisation{id: id} = organisation, opts) do
    if Keyword.has_key?(opts, :lock),
      do: ApiaryPro.Tenants.client?(%Apiary.Organisations.Organisation{id: id}),
      else: ApiaryPro.Tenants.client?(organisation)
  end

  # The chain of model choices that resolves for a client's runs: "operator" while
  # `ApiaryPro.Flags.operator_infrastructure?/0` is on and the client's switch is
  # `:operator` (`ApiaryPro.Operators.set_model_chain/3`), "organisation" for every other
  # organisation. Asked without a lock, once per resolution: one statement reads the
  # switch of the organisation's tenant, only while the flag is on.
  @impl true
  def model_choice_chain(organisation_id) do
    if ApiaryPro.Flags.operator_infrastructure?() and
         ApiaryPro.Tenants.model_chain_of(organisation_id) == :operator,
       do: "operator",
       else: "organisation"
  end

  # The operator whose model providers and choices resolve for a client's runs: the
  # client's `operator_id` while `ApiaryPro.Flags.operator_infrastructure?/0` is on and the
  # client's switch is `:operator` (`ApiaryPro.Operators.set_model_chain/3`), nil for every
  # other organisation. Asked without a lock: one statement reads the tenant, only while
  # the flag is on.
  @impl true
  def operator_chain_organisation(organisation_id) do
    if ApiaryPro.Flags.operator_infrastructure?(),
      do: ApiaryPro.Tenants.operator_on_chain_of(organisation_id)
  end

  # Whether the person of `scope` writes the operator's chain in the scope's organisation:
  # while `ApiaryPro.Flags.operator_infrastructure?/0` is on, an owner or an admin of an
  # operator through their membership there. Not a person who reaches it another way (an
  # instance admin, or a person of its operator), not an access key, and not a member.
  # The organisation and the membership are those the scope carries.
  @impl true
  def operator_chain_writer?(%Apiary.Accounts.Scope{
        user: %Apiary.Accounts.User{id: user_id},
        access_key: nil,
        reach: reach,
        organisation: %Apiary.Organisations.Organisation{id: organisation_id} = organisation,
        membership: %Apiary.Organisations.Membership{
          user_id: user_id,
          organisation_id: organisation_id,
          suspended_at: nil,
          level: level
        }
      })
      when reach in [nil, :membership] and level in [:owner, :admin] do
    ApiaryPro.Flags.operator_infrastructure?() and ApiaryPro.Tenants.operator?(organisation)
  end

  def operator_chain_writer?(_scope), do: false

  # Who creates a client's first workspace: its owners and admins, and, while the operator
  # owns its clients, the operator's owners (`ApiaryPro.Access`). The core's line for an
  # organisation that is no client. The overview and the dead end of New workspace show it.
  @impl true
  def first_workspace_waiting_line(%Apiary.Organisations.Organisation{} = organisation) do
    if ApiaryPro.Tenants.client?(organisation) do
      case operator_owning(organisation) do
        %Apiary.Organisations.Organisation{name: operator} ->
          gettext(
            "An owner or an admin of %{organisation}, or an owner of %{operator}, creates the first workspace.",
            organisation: organisation.name,
            operator: operator
          )

        nil ->
          gettext("An owner or an admin of %{organisation} creates the first workspace.",
            organisation: organisation.name
          )
      end
    else
      Apiary.Edition.Core.first_workspace_waiting_line(organisation)
    end
  end

  # Who finishes the set-up, for a person who may not take the next step's action. While the
  # operator owns its clients, only its owners and admins hold Machines and Harness in a
  # client (`@operator_held` in `ApiaryPro.Access`), and Model while the client's model switch
  # is `:operator` (`@chain_held`); they also reach every other step. On `:organisation` the
  # Model step follows the usual rules, so the core's line is true. The core's line too for
  # any organisation that is no client of an operator.
  @impl true
  def set_up_finishers_line(
        %Apiary.Accounts.Scope{organisation: %Apiary.Organisations.Organisation{} = organisation} =
          scope,
        step_id
      ) do
    with %Apiary.Organisations.Organisation{name: operator} <- operator_owning(organisation),
         who when who != :core <- finishers(organisation, step_id) do
      case who do
        :operator ->
          gettext("Owners and admins of %{operator} finish the set-up.", operator: operator)

        :both ->
          gettext("Owners and admins of %{organisation} and of %{operator} finish the set-up.",
            organisation: organisation.name,
            operator: operator
          )
      end
    else
      _core -> Apiary.Edition.Core.set_up_finishers_line(scope, step_id)
    end
  end

  def set_up_finishers_line(scope, step_id),
    do: Apiary.Edition.Core.set_up_finishers_line(scope, step_id)

  defp finishers(_organisation, step_id) when step_id in [:machines, :harness], do: :operator

  defp finishers(organisation, :model) do
    if ApiaryPro.Tenants.model_chain(organisation) == :operator, do: :operator, else: :core
  end

  defp finishers(_organisation, _step_id), do: :both

  # The operator of the client `organisation` while the operator owns its clients.
  defp operator_owning(organisation) do
    if ApiaryPro.Flags.operator_infrastructure?(),
      do: ApiaryPro.Operators.operator_of(%Apiary.Accounts.Scope{organisation: organisation})
  end

  # Who connects a system for a client while the operator owns its clients: the operator's
  # owners and admins (`@operator_held` in `ApiaryPro.Access`, `adapter.connect`), on both
  # steps. Nil, the core's sentence, for any other organisation.
  @impl true
  def connects_line(%Apiary.Organisations.Organisation{} = organisation, step)
      when step in [:sources, :destinations] do
    with %Apiary.Organisations.Organisation{name: operator} <- operator_owning(organisation) do
      gettext("Owners and admins of %{operator} connect it once for %{client}.",
        operator: operator,
        client: organisation.name
      )
    end
  end

  @impl true
  def set_up_steps(scope, steps), do: ApiaryPro.SetUp.steps(scope, steps)

  @impl true
  def set_up_title(scope, step), do: Apiary.Edition.Core.set_up_title(scope, step)

  @impl true
  def set_up_context(scope, step_id), do: Apiary.Edition.Core.set_up_context(scope, step_id)

  # A client is operated whether or not `operator_infrastructure` is on: its runs hide the
  # text of their stack's harness (`Apiary.Stacks.Resolution`).
  @impl true
  def operated?(%Apiary.Organisations.Organisation{} = organisation),
    do: ApiaryPro.Tenants.client?(organisation)

  # While `operator_infrastructure` is on, a person of a client who does not reach it
  # through its operator is not shown the operator's model provider in a run's records
  # (`ApiaryPro.ClientReads`).
  @impl true
  def client_reads(scope, kind, run, subject),
    do: ApiaryPro.ClientReads.client_reads(scope, kind, run, subject)

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, a harness document that a
  # person of an operator saves in one of its clients is owned by the operator
  # (`harness_owner/1`, hidden from the documentation): the scope reaches the client
  # through the person's membership in the operator, and the client's tenant names that
  # operator. Any other scope, and every scope while the flag is off, gets the core's
  # answer: a person of another operator saves nothing in the client, and no other scope
  # gets an owner that the core would not give it.
  @impl true
  def harness_owner(
        %Apiary.Accounts.Scope{
          organisation: %Apiary.Organisations.Organisation{} = organisation,
          reach: {:operator, %Apiary.Organisations.Membership{organisation_id: operator_id}}
        } = scope
      ) do
    if ApiaryPro.Flags.operator_infrastructure?() and
         ApiaryPro.Tenants.operator_id(organisation) == operator_id,
       do: operator_id,
       else: Apiary.Edition.Core.harness_owner(scope)
  end

  def harness_owner(scope), do: Apiary.Edition.Core.harness_owner(scope)

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, a run of a client may use the
  # links of its operator for a harness source (`harness_source_allowed?/3`, hidden from
  # the documentation) that an assignment of the operator to the client covers exactly, or
  # that a harness document the operator owns in the client lists exactly
  # (`ApiaryPro.HarnessAssignments`). The client is read now, from its tenant, which must
  # name `owner_organisation_id` as its operator. Any other run, and every run while the
  # flag is off, gets the core's answer, false. The core asks only after the core's checks
  # refuse, so this never shadows the instance's assignments.
  @impl true
  def harness_source_allowed?(run_organisation_id, owner_organisation_id, source),
    do:
      ApiaryPro.HarnessAssignments.source_allowed?(
        run_organisation_id,
        owner_organisation_id,
        source
      )

  # The instance's organisation is the instance organisation, whose owners are the
  # instance admins (`Apiary.Access.instance_admin?/1`).
  @impl true
  def instance_organisation_id, do: ApiaryPro.Reach.instance_organisation_id()

  # --- Limits, sign-up, deletion, registries, runtime ------------------------------------

  @impl true
  def limits, do: %{organisations: :unlimited, workspaces: :unlimited}

  @impl true
  def sign_up_open?, do: ApiaryPro.SignUp.kinds() != []

  # The set-up page's line names the kind the set-up makes: an operator with
  # `managed_organisations`.
  @impl true
  def first_sign_up_line, do: ApiaryPro.SignUp.first_sign_up_line()

  @impl true
  def organisation_created(multi, how), do: ApiaryPro.Tenants.organisation_created(multi, how)

  # A new workspace's owners and admins reach it as they reach every workspace, a member
  # once added to it (`ApiaryPro.WorkspaceAccess`), and it has its organisation's
  # features (`ApiaryPro.Features`). Where the organisation has a policy, the workspace's
  # first version is rendered under it.
  @impl true
  def workspace_created(repo, workspace, scope),
    do: ApiaryPro.OrganisationPolicy.workspace_created(repo, workspace, scope)

  # The organisation's level above every workspace of it: its policy, where one is in
  # force, carrying its variables; its variables alone, `policy: false`, where it has
  # variables and no policy in force; nil where it has neither. The policy's callers
  # (its link, a new workspace's page and render) ask `OrganisationPolicy` directly.
  @impl true
  def above_workspace(workspace) do
    case ApiaryPro.OrganisationPolicy.above_workspace(workspace) do
      %Apiary.Policy.Above{} = above ->
        %{above | variables: ApiaryPro.OrganisationVariables.for_above(workspace)}

      nil ->
        ApiaryPro.OrganisationVariables.above_without_policy(workspace)
    end
  end

  # The organisation's secrets, which the core keeps: who reads, changes and links them,
  # where the organisation has the feature, and, asked with no scope, whether the instance
  # seals them (`ApiaryPro.OrganisationSecrets`).
  @impl true
  def organisation_secrets(scope, verb), do: ApiaryPro.OrganisationSecrets.may(scope, verb)

  @impl true
  def audit_retention_max_days, do: 90

  @impl true
  def deletion_refusal(what, subject), do: ApiaryPro.Deletion.refusal(what, subject)

  @impl true
  def deletion_changed(repo, event, subject, scope),
    do: ApiaryPro.Deletion.changed(repo, event, subject, scope)

  @impl true
  def deletion_tables, do: ApiaryPro.Deletion.Tables.tables()

  @impl true
  def features, do: ApiaryPro.Features.features()

  @impl true
  def config_features, do: ApiaryPro.Flags.config_features()

  @impl true
  def hidden(scope), do: ApiaryPro.Features.hidden(scope)

  # An organisation has several workspaces: each Add form of a model provider, a
  # runtime, an integration or a service shows the setting "Available to every workspace",
  # off by default. The edition stores nothing of it: the core keeps the reach.
  @impl true
  def scope_setting?(_scope), do: true

  @impl true
  def subject_kinds do
    %{
      ApiaryPro.WorkspaceAccess.Row => "workspace_access",
      ApiaryPro.Transfers.Transfer => "transfer",
      ApiaryPro.PolicyRequests.Request => "policy_request",
      ApiaryPro.PolicyRequests.Answer => "policy_request_answer",
      ApiaryPro.OrganisationVariables.Variable => "organisation_variable"
    }
  end

  @impl true
  def boot! do
    ApiaryPro.SignUp.boot!()
    :ok
  end

  # Each node's copy of who may sign up, after the migrator, which makes its table.
  @impl true
  def children,
    do: if(ApiaryPro.SignUp.Cache.enabled?(), do: [ApiaryPro.SignUp.Cache], else: [])

  # An instance whose organisations were made before it had tenants is adopted.
  @impl true
  def after_migrate, do: ApiaryPro.Adoption.run()
end
