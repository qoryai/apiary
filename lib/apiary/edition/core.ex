defmodule Apiary.Edition.Core do
  @moduledoc """
  The core edition, and the default (`Apiary.Edition`): one organisation with one
  workspace, which the instance's first sign-up creates and whose owners run the instance;
  later people join by invitation. The instance's features are those switched on at launch,
  in every organisation and workspace alike. Nothing is added to the core's actions,
  roles, tables, features, jobs or migrations, and nothing is left out of a query.

  An edition that `use`s `Apiary.Edition` answers as this module does for every callback it
  does not override.
  """

  @behaviour Apiary.Edition

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
  def above_workspace(_workspace), do: nil

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
  def accepting(_repo, _invitation, _user), do: {:ok, :member}

  @impl true
  def accepted(_repo, _scope, _invitation, _membership), do: :ok

  @impl true
  def membership_changed(_repo, _scope, _event, _old, _new), do: :ok

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
  def features_of(_organisation, _workspace, enabled), do: enabled

  @impl true
  def subject_kinds, do: %{}

  @impl true
  def release_token(_scope, _source), do: nil

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
