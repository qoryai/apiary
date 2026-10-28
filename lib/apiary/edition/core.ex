defmodule Apiary.Edition.Core do
  @moduledoc """
  The core edition, and the default (`Apiary.Edition`): one organisation, which the
  instance's first sign-up creates and whose owners run the instance, with one workspace:
  Main, which the sign-up by release command creates, or which an owner creates on the
  workspace set-up page after a set-up by link. Later people join by invitation. The
  instance's features are those switched on at launch, shown to every person in every
  organisation and workspace alike. Nothing is added to the
  core's actions, roles, tables, features, jobs or migrations, and nothing is left out of a
  query.

  An edition that `use`s `Apiary.Edition` answers as this module does for every callback it
  does not override.
  """

  @behaviour Apiary.Edition

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations
  alias Apiary.Organisations.{Membership, Organisation}
  alias Apiary.Repo

  @impl true
  def limits, do: %{organisations: 1, workspaces: 1}

  @impl true
  def sign_up_open?, do: false

  @impl true
  def organisation_created(multi, _how), do: multi

  @impl true
  def workspace_created(_repo, _workspace, _scope), do: :ok

  # The oldest organisation in use: the only one the core creates, and the first sign-up's
  # on an instance that has more.
  @impl true
  def instance_organisation_id do
    Repo.one(
      from o in Organisation,
        where: is_nil(o.deletion_marked_at),
        order_by: [asc: o.inserted_at, asc: o.id],
        limit: 1,
        select: o.id
    )
  end

  @impl true
  def first_sign_up_line, do: gettext("Your account and your organisation.")

  @impl true
  def first_workspace_line(_organisation),
    do:
      gettext("%{workspace} is this instance's only workspace.",
        workspace: Organisations.default_workspace_name()
      )

  @impl true
  def first_workspace_waiting_line(_organisation),
    do: gettext("An owner sets up this organisation's first workspace.")

  @impl true
  def set_up_steps(_scope, steps), do: steps

  @impl true
  def set_up_title(_scope, _step), do: gettext("Set up your workspace")

  @impl true
  def set_up_context(_scope, _step_id), do: nil

  @impl true
  def machines_who_may(_scope, _workspace, :instance),
    do: gettext("Only an instance admin checks the instance's pool and gateway.")

  def machines_who_may(_scope, _workspace, :workspace),
    do: gettext("Only owners and admins connect a node.")

  @impl true
  def above_workspace(_workspace), do: nil

  # The core has no operator: an organisation's runs take its own chain of model choices.
  @impl true
  def model_choice_chain(_organisation_id), do: "organisation"

  # The core has no operator: no organisation's chain is an operator's.
  @impl true
  def operator_chain_organisation(_organisation_id), do: nil

  # The core has no operator: no person writes an operator's chain.
  @impl true
  def operator_chain_writer?(_scope), do: false

  # The core has no operator: no organisation is a client of one.
  @impl true
  def operated?(_organisation), do: false

  # The core has no operator: a member owns what they save in their organisation, and an
  # instance admin who saves any other way saves for the instance's organisation.
  @impl true
  def harness_owner(scope) do
    with nil <- Apiary.Stacks.saved_by(scope) do
      if Apiary.Access.instance_admin?(scope), do: Apiary.Edition.instance_organisation_id()
    end
  end

  # The core has no operator: a run uses another organisation's links for its harness only
  # under an instance assignment.
  @impl true
  def harness_source_allowed?(_run_organisation_id, _owner_organisation_id, _source),
    do: false

  # The set-up's rules count what the workspace and its organisation have, and the
  # instance's pool and gateway.
  @impl true
  def work_source_ready(workspace), do: Apiary.WorkspaceSetup.work_source(workspace)

  @impl true
  def machines_ready(workspace), do: Apiary.WorkspaceSetup.machines(workspace)

  @impl true
  def model_key_ready?(workspace), do: Apiary.WorkspaceSetup.model_key?(workspace)

  @impl true
  def test_run_passed?(workspace), do: Apiary.WorkspaceSetup.test_passed?(workspace)

  @impl true
  def client_reads(_scope, _kind, _run, subject), do: subject

  # The core keeps no secret at an organisation.
  @impl true
  def organisation_secrets(_scope, _verb), do: {:error, :not_found}

  @impl true
  def audit_retention_max_days, do: 90

  @impl true
  def attribution?, do: true

  @impl true
  def actions, do: []

  @impl true
  def roles, do: %{}

  @impl true
  def check(_scope, _action, _subject), do: :continue

  @impl true
  def reach(%Scope{membership: %Membership{}} = scope), do: {:ok, scope}
  def reach(_scope), do: :error

  @impl true
  def role(_scope), do: nil

  @impl true
  def reload(scope, _opts), do: scope

  @impl true
  def places_to_lock(%Organisation{id: id}), do: [id]

  @impl true
  def lock_rows(_about), do: :ok

  @impl true
  def every_workspace_levels, do: [:owner, :admin, :member]

  @impl true
  def reaches_workspace?(_scope, _workspace, _opts), do: false

  @impl true
  def reached_workspaces(query, _scope), do: Ecto.Queryable.to_query(query)

  @impl true
  def active_accounts(query, _binding), do: Ecto.Queryable.to_query(query)

  @impl true
  def active_organisations(query, _binding), do: Ecto.Queryable.to_query(query)

  @impl true
  def account_refusal(_user), do: nil

  @impl true
  def places(user), do: Organisations.list_memberships(user)

  @impl true
  def serving_organisations(_organisation_id), do: []

  @impl true
  def served_organisations(_organisation_id), do: []

  @impl true
  def accepting(_repo, _invitation, _user), do: {:ok, :member}

  @impl true
  def accepted(_repo, _scope, _invitation, _membership), do: :ok

  @impl true
  def membership_changed(_repo, _scope, _event, _old, _new), do: :ok

  @impl true
  def level_refusal(_scope, _organisation, _level, _opts), do: nil

  @impl true
  def deletion_refusal(_what, %Organisation{id: id}) do
    if id == Apiary.Edition.instance_organisation_id(), do: :instance_organisation
  end

  def deletion_refusal(_what, _workspace), do: nil

  @impl true
  def deletion_changed(_repo, _event, _subject, _scope), do: :ok

  @impl true
  def deletion_tables, do: []

  @impl true
  def features, do: []

  @impl true
  def hidden(_scope), do: []

  # The core has one workspace: what a person adds reaches it alone, and no form shows the
  # setting.
  @impl true
  def scope_setting?(_scope), do: false

  @impl true
  def audit_details(_scope, _organisation_id, details), do: details

  @impl true
  def subject_kinds, do: %{}

  @impl true
  def boot!, do: :ok

  @impl true
  def children, do: []

  @impl true
  def crontab, do: []

  @impl true
  def migrations_paths, do: [Application.app_dir(:apiary, "priv/repo/migrations")]

  @impl true
  def after_migrate, do: :ok
end
