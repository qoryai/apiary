defmodule ApiaryPro.Edition do
  @moduledoc """
  The edition (`Apiary.Edition`): what it adds to the core, each callback answered by
  the context of `ApiaryPro` that owns it.
  """

  use Apiary.Edition

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
  def put_organisation(organisation),
    do: organisation |> ApiaryPro.Tenants.put() |> ApiaryPro.WorkspaceOperators.put()

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
  def reaches_all_workspaces?(scope), do: ApiaryPro.Reach.reaches_all_workspaces?(scope)

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
  def accepted(repo, scope, invitation, membership),
    do: ApiaryPro.Invitations.accepted(repo, scope, invitation, membership)

  # A person made a member keeps a workspace; an owner who may act again takes back what
  # the arbiter offered.
  @impl true
  def membership_changed(repo, scope, :level, old, new),
    do: ApiaryPro.WorkspaceAccess.level_changed(repo, scope, old, new)

  def membership_changed(_repo, _scope, :activated, _old, new),
    do: ApiaryPro.Transfers.membership_activated(new)

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, an entry made in a workspace
  # by a person who acts there through its operator keeps the operator they acted through,
  # `via_operator_id`, which the Activity page names beside them
  # (`ApiaryProWeb.Edition`'s `activity_actor/2`). From the scope, without a read.
  @impl true
  def audit_details(
        %Apiary.Accounts.Scope{
          organisation: %Apiary.Organisations.Organisation{id: id},
          reach: {:operator, _operated}
        } = scope,
        id,
        details
      ) do
    with true <- ApiaryPro.Flags.operator_infrastructure?(),
         true <- ApiaryPro.Access.through_operator?(scope),
         %Apiary.Organisations.Membership{organisation_id: operator_id} <-
           ApiaryPro.Reach.operator_membership(scope) do
      Map.put(details, "via_operator_id", operator_id)
    else
      _not_through -> details
    end
  end

  def audit_details(_scope, _organisation_id, details), do: details

  @impl true
  def set_up_steps(scope, steps), do: ApiaryPro.SetUp.steps(scope, steps)

  @impl true
  def set_up_title(scope, step), do: Apiary.Edition.Core.set_up_title(scope, step)

  @impl true
  def set_up_context(scope, step_id), do: Apiary.Edition.Core.set_up_context(scope, step_id)

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
