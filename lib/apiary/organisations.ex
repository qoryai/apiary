defmodule Apiary.Organisations do
  @moduledoc """
  Organisations, their workspaces, memberships and invitations.

  A membership is the organisation's, once per person, and carries their level: owner,
  admin or member. The levels of `c:Apiary.Edition.every_workspace_levels/0` reach every
  workspace of the organisation, in the core's edition all three; the edition says which
  workspaces another level reaches (`Apiary.Access.reaches_every_workspace?/1`). An
  invitation is sent from a workspace.

  An organisation and a workspace each get a slug from their name when they are created
  (`Apiary.Organisations.Slug`), a workspace's as the form that creates it says
  (`create_workspace/2`); a page's path names them by it, and `resolve_scope/4`
  loads them for a person who reaches the organisation and the workspace only: through
  their membership there, or as the edition lets them in (`c:Apiary.Edition.reach/1`,
  `Apiary.Access`, Reach).

  Every function that acts on behalf of a caller takes an `Apiary.Accounts.Scope`
  loaded with `load_scope/2`. The scope says who is calling; every mutation asks
  `Apiary.Access.authorize/3` first, which reads the caller's membership again rather
  than trust the one the scope carries, which may be as old as the LiveView that holds
  it.

  A level change, a removal and a suspension are announced on the `Apiary.PubSub` topic
  `membership_topic(user_id)` so the user's open pages reload their scope.

  An organisation or a workspace marked for deletion (`Apiary.Deletion`) is gone from
  what this module finds for a person: a scope, the memberships of the switcher, a
  workspace of the list, an invitation's token; the sweeps over every organisation and
  workspace leave it out too. A job still reaches it (`job_scope/3`), since its purge is
  a job, and `Apiary.Access` answers what may be done to it. What the edition stops, an
  account or an organisation out of use (`c:Apiary.Edition.active_accounts/2`,
  `c:Apiary.Edition.active_organisations/2`), is left out the same way.
  """

  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Edition, Features, Instance, Mail, Repo}
  alias Apiary.Accounts.{Scope, User, UserNotifier}

  alias Apiary.Organisations.{
    Invitation,
    LastWorkspace,
    Membership,
    Organisation,
    Slug,
    Workspace
  }

  @default_workspace_name "Main"
  @max_pending_invitations 50
  # Every invitation tried in 24 hours, delivered or not, counts against this many times
  # the day's invitations (`Apiary.Instance.invitations_per_day/0`).
  @attempts_per_invitation 3

  @typedoc """
  A workspace a person reaches, with what the edition says of their reach there, which
  goes on the scope's `edition` when they open it (`c:Apiary.Edition.reached_workspaces/2`).
  """
  @type place :: {%Workspace{}, map}

  ## Scope

  @doc """
  load_scope/2 loads the user's membership in `organisation_id` when given and held,
  otherwise the user's earliest, into the scope: its organisation, and the oldest workspace
  of it the user reaches. One who reaches no workspace yet gets the organisation
  and the membership, and no workspace. A user without a membership gets the scope
  unchanged.
  """
  @spec load_scope(Scope.t() | nil, Ecto.UUID.t() | nil) :: Scope.t() | nil
  def load_scope(scope, organisation_id \\ nil)

  def load_scope(%Scope{user: %User{} = user} = scope, organisation_id) do
    membership =
      (organisation_id &&
         membership_query(user) |> where(organisation_id: ^organisation_id) |> Repo.one()) ||
        membership_query(user) |> limit(1) |> Repo.one()

    case membership do
      %Membership{} = membership -> put_place(scope, membership, home_workspace(membership, nil))
      nil -> scope
    end
  end

  def load_scope(scope, _organisation_id), do: scope

  @doc """
  resolve_scope/4 loads the organisation whose slug is `organisation_slug`, how the user
  reaches it, and the workspace whose slug is `workspace_slug` in it, into the scope:
  `{:ok, scope}` when the user reaches the organisation and the workspace.

  The user reaches an organisation through their membership there, or as the edition lets
  them in (`put_reach/2`). Through a membership, the levels of
  `c:Apiary.Edition.every_workspace_levels/0` reach every workspace; another level the
  workspaces the edition says (`c:Apiary.Edition.reached_workspaces/2`). What each may do
  there is `Apiary.Access`'s answer.

  Without a workspace slug, for an organisation's own page and the switcher's link to the
  organisation, the workspace is the one `last_workspace:` names, the workspace the
  session remembers as last opened, while the user reaches it and it is in this
  organisation; otherwise the one they last used in this organisation
  (`remember_workspace/1`), while they reach it; otherwise the oldest they reach; none for
  one who reaches no workspace yet, who still gets `{:ok, scope}`.

  `:error` when a slug names nothing and when it names an organisation the user does not
  reach or a workspace they do not reach: one answer for all, so a slug does not tell
  whether it exists.
  """
  @spec resolve_scope(Scope.t(), String.t(), String.t() | nil, keyword) ::
          {:ok, Scope.t()} | :error
  def resolve_scope(scope, organisation_slug, workspace_slug \\ nil, opts \\ [])

  def resolve_scope(
        %Scope{user: %User{}} = scope,
        organisation_slug,
        workspace_slug,
        opts
      )
      when is_binary(organisation_slug) do
    organisation =
      Repo.one(
        from o in Organisation,
          where: o.slug == ^organisation_slug and is_nil(o.deletion_marked_at)
      )

    with %Organisation{} <- organisation,
         {:ok, scope} <- put_reach(scope, organisation),
         {:ok, place} <- resolve_workspace(scope, workspace_slug, opts[:last_workspace]) do
      {:ok, put_place(scope, place)}
    else
      _unreached -> :error
    end
  end

  def resolve_scope(_scope, _organisation_slug, _workspace_slug, _opts), do: :error

  @doc """
  put_reach/2 puts `organisation` into the scope with how the scope's person reaches it:
  their membership there, while neither it nor their account is out of use, and what the
  edition says (`c:Apiary.Edition.reach/1`), which may let them in without one
  (`resolve_scope/4`). No workspace. `:error` when they do not reach it. `organisation` is
  taken as it is given, marked for deletion or not: a caller that serves only
  organisations in use loads it so.
  """
  @spec put_reach(Scope.t(), %Organisation{}) :: {:ok, Scope.t()} | :error
  def put_reach(%Scope{user: %User{id: user_id}} = scope, %Organisation{} = organisation) do
    own = active_membership(organisation.id, user_id)

    Edition.reach(%{
      scope
      | organisation: organisation,
        membership: own && %{own | organisation: organisation},
        reach: nil,
        workspace: nil,
        edition: %{}
    })
  end

  def put_reach(_scope, _organisation), do: :error

  # The person's membership in the organisation, while it is not suspended and their
  # account is in use: a suspended one reaches nothing.
  defp active_membership(organisation_id, user_id) do
    from(m in Membership,
      join: u in assoc(m, :user),
      as: :account,
      where: m.organisation_id == ^organisation_id and m.user_id == ^user_id,
      where: is_nil(m.suspended_at)
    )
    |> Edition.active_accounts(:account)
    |> Repo.one()
  end

  defp resolve_workspace(scope, workspace_slug, _last) when is_binary(workspace_slug) do
    case scope
         |> reached_query()
         |> where([workspace: w], w.slug == ^workspace_slug)
         |> Repo.one() do
      %{workspace: %Workspace{}} = row -> {:ok, place(row)}
      nil -> :error
    end
  end

  defp resolve_workspace(scope, nil, last_workspace_id),
    do: {:ok, home_workspace(scope, last_workspace_id)}

  # The workspace of an organisation's page: the one the person opened last, while they
  # reach it; else, asked with a scope, the one they last used in this organisation
  # (`remember_workspace/1`), while they reach it; else the oldest they reach.
  # `{workspace, what the edition says}`, or nil.
  defp home_workspace(scope_or_membership, last_workspace_id) do
    reached = reached_query(scope_or_membership)

    row =
      reached_by_id(reached, last_workspace_id) || last_used(reached, scope_or_membership) ||
        reached |> oldest() |> Repo.one()

    row && place(row)
  end

  defp reached_by_id(query, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> query |> where([workspace: w], w.id == ^id) |> Repo.one()
      :error -> nil
    end
  end

  # The reached workspace the scope's person last used in the organisation. The query
  # leaves out a workspace marked for deletion, as it leaves out one they no longer reach.
  defp last_used(query, %Scope{user: %User{id: user_id}}) do
    from([workspace: w] in query,
      join: l in LastWorkspace,
      on: l.workspace_id == w.id and l.organisation_id == w.organisation_id,
      where: l.user_id == ^user_id
    )
    |> exclude(:order_by)
    |> Repo.one()
  end

  defp last_used(_query, %Membership{}), do: nil

  @doc """
  remember_workspace/1 records the scope's workspace as the one its person last used in
  its organisation (`Apiary.Organisations.LastWorkspace`), which the organisation's page
  opens while they reach it (`resolve_scope/4`): one row per person and organisation,
  changed only when the workspace differs. A scope without a person or a workspace records
  nothing.
  """
  @spec remember_workspace(Scope.t() | nil) :: :ok
  def remember_workspace(%Scope{
        user: %User{id: user_id},
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{id: workspace_id}
      }) do
    now = DateTime.utc_now()

    Repo.insert_all(
      LastWorkspace,
      [
        %{
          user_id: user_id,
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          updated_at: now
        }
      ],
      on_conflict:
        from(l in LastWorkspace,
          where: l.workspace_id != ^workspace_id,
          update: [set: [workspace_id: ^workspace_id, updated_at: ^now]]
        ),
      conflict_target: [:user_id, :organisation_id]
    )

    :ok
  end

  def remember_workspace(_scope), do: :ok

  # The one workspace of the query that was created first: where the person has opened
  # none yet, an organisation's pages open its oldest, the one it was made with while it
  # is there, whatever the names of the others.
  defp oldest(query) do
    query
    |> exclude(:order_by)
    |> order_by([workspace: w], asc: w.inserted_at, asc: w.id)
    |> limit(1)
  end

  defp oldest_of([]), do: nil
  # By the instant, not the struct: terms compare a DateTime field by field, the
  # microseconds before the seconds.
  defp oldest_of(workspaces),
    do: Enum.min_by(workspaces, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})

  defp place(row), do: {row.workspace, Map.delete(row, :workspace)}

  # The workspaces of the organisation a scope, or a membership, reaches, by name, each as a
  # map with the workspace under `:workspace`: every one where the reach takes them all,
  # and those the edition says otherwise (`c:Apiary.Edition.reached_workspaces/2`), with
  # what it says of each. One the edition lets in without a membership reads every
  # workspace. `in_use: false` keeps those marked for deletion too, as a job's scope does.
  defp reached_query(scope_or_membership, opts \\ [])

  defp reached_query(
         %Scope{organisation: %Organisation{id: organisation_id}, membership: membership} = scope,
         opts
       ) do
    case membership do
      %Membership{organisation_id: ^organisation_id} ->
        organisation_id |> workspaces_query(opts) |> refine_reached(membership, scope)

      _none ->
        workspaces_query(organisation_id, opts)
    end
  end

  defp reached_query(%Membership{organisation_id: organisation_id} = membership, opts),
    do: organisation_id |> workspaces_query(opts) |> refine_reached(membership, nil)

  # A level that reaches every workspace reads them all; another, what the edition says,
  # asked with the membership bound.
  defp refine_reached(query, %Membership{id: membership_id, level: level}, scope) do
    if Access.reaches_every_workspace?(level) do
      query
    else
      from([workspace: w] in query,
        join: m in Membership,
        as: :membership,
        on: m.id == ^membership_id and m.organisation_id == w.organisation_id
      )
      |> Edition.reached_workspaces(scope)
    end
  end

  defp workspaces_query(organisation_id, opts) do
    query =
      from w in Workspace,
        as: :workspace,
        where: w.organisation_id == ^organisation_id,
        order_by: [asc: w.name, asc: w.id],
        select: %{workspace: w}

    if Keyword.get(opts, :in_use, true),
      do: where(query, [workspace: w], is_nil(w.deletion_marked_at)),
      else: query
  end

  @doc """
  home_membership/2 is the membership a signed-in user is sent into: the one whose
  organisation holds `workspace_id`, the workspace the session remembers as last opened,
  while the user reaches it; otherwise the user's earliest. Nil without a membership.
  Loaded as `list_memberships/1` loads it, with the workspaces it reaches.
  """
  @spec home_membership(%User{}, String.t() | nil) :: %Membership{} | nil
  def home_membership(%User{} = user, workspace_id \\ nil) do
    memberships = list_memberships(user)

    Enum.find(memberships, fn membership ->
      Enum.any?(membership.workspaces, &(&1.id == workspace_id))
    end) || List.first(memberships)
  end

  @doc """
  load_home_scope/2 loads `home_membership/2` into the scope, with its organisation, and
  the workspace `workspace_id` when the membership reaches it, else the oldest it reaches:
  for a page of the user's own that shows the workspace beside it, and for where `/` sends
  them. A user without a membership gets the scope unchanged; one who reaches no
  workspace yet gets no workspace.
  """
  @spec load_home_scope(Scope.t() | nil, String.t() | nil) :: Scope.t() | nil
  def load_home_scope(%Scope{user: %User{} = user} = scope, workspace_id) do
    case home_membership(user, workspace_id) do
      %Membership{workspaces: workspaces} = membership ->
        workspace = Enum.find(workspaces, &(&1.id == workspace_id)) || oldest_of(workspaces)

        # What the edition says of the person there, read for a level that needs it.
        place =
          cond do
            is_nil(workspace) -> nil
            Access.reaches_every_workspace?(membership.level) -> {workspace, %{}}
            true -> home_workspace(membership, workspace.id)
          end

        put_place(scope, membership, place)

      nil ->
        scope
    end
  end

  def load_home_scope(scope, _workspace_id), do: scope

  @doc """
  job_scope/3 is the scope a job acts under (`Apiary.Job`), built from the
  ids its arguments carry: the organisation, the workspace in it when `workspace_id` is not
  nil, and the person whose action enqueued the job when `user_id` is not nil, as they
  reach the organisation now (`put_reach/2`), with what the edition says of the
  workspace. Without a person the scope is the instance's
  (`Apiary.Accounts.Scope.for_instance/2`): the instance acts, as its role in
  `Apiary.Access` allows. Without an organisation the scope is the instance's alone.

  `:error` when the organisation, the workspace in it or the person no longer exists.
  """
  @spec job_scope(Ecto.UUID.t() | nil, Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          {:ok, Scope.t()} | :error
  def job_scope(organisation_id, workspace_id, user_id) do
    with {:ok, user} <- fetch_job_user(user_id),
         {:ok, organisation} <- fetch_job_organisation(organisation_id),
         {:ok, workspace} <- fetch_job_workspace(organisation, workspace_id) do
      case user do
        nil ->
          {:ok, Scope.for_instance(organisation, workspace)}

        %User{} ->
          scope = job_person_scope(user, organisation, workspace)
          {:ok, %{scope | features: Features.of(organisation, workspace)}}
      end
    end
  end

  defp fetch_job_user(nil), do: {:ok, nil}

  defp fetch_job_user(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> {:ok, user}
      nil -> :error
    end
  end

  defp fetch_job_organisation(nil), do: {:ok, nil}

  defp fetch_job_organisation(organisation_id) do
    case Repo.get(Organisation, organisation_id) do
      %Organisation{} = organisation -> {:ok, organisation}
      nil -> :error
    end
  end

  defp fetch_job_workspace(_organisation, nil), do: {:ok, nil}
  defp fetch_job_workspace(nil, _workspace_id), do: :error

  defp fetch_job_workspace(%Organisation{id: organisation_id}, workspace_id) do
    case Repo.get_by(Workspace, id: workspace_id, organisation_id: organisation_id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> :error
    end
  end

  # The person as they reach the organisation now, as a page's path finds them
  # (`put_reach/2`); without a reach, the scope carries no membership, and `Apiary.Access`
  # refuses what a role would allow. The workspace is the job's, marked for deletion or
  # not, with what the edition says of the person there.
  defp job_person_scope(user, nil, workspace),
    do: %Scope{user: user, workspace: workspace}

  defp job_person_scope(user, %Organisation{} = organisation, workspace) do
    case put_reach(Scope.for_user(user), organisation) do
      {:ok, scope} ->
        %{
          scope
          | workspace: workspace,
            edition: Map.merge(scope.edition, job_extras(scope, workspace))
        }

      :error ->
        %Scope{user: user, organisation: organisation, workspace: workspace}
    end
  end

  # What the edition says of the person in the job's workspace, where their level does not
  # reach every workspace.
  defp job_extras(%Scope{membership: %Membership{level: level}} = scope, %Workspace{id: id}) do
    if Access.reaches_every_workspace?(level) do
      %{}
    else
      case scope
           |> reached_query(in_use: false)
           |> where([workspace: w], w.id == ^id)
           |> Repo.one() do
        %{workspace: _workspace} = row -> row |> place() |> elem(1)
        nil -> %{}
      end
    end
  end

  defp job_extras(_scope, _workspace), do: %{}

  @doc """
  marked?/1 says whether an organisation or a workspace is marked for deletion
  (`Apiary.Deletion`), as the database has it now: false for one that is gone, and for
  nil.
  """
  @spec marked?(%Organisation{} | %Workspace{} | nil) :: boolean
  def marked?(%schema{id: id}) when schema in [Organisation, Workspace] do
    Repo.exists?(from r in schema, where: r.id == ^id and not is_nil(r.deletion_marked_at))
  end

  def marked?(nil), do: false

  @typedoc "Where a page of ids ends: the id of its last row; nil before the first page."
  @type page_cursor :: Ecto.UUID.t() | nil

  @doc """
  One page of the ids of every organisation on the instance in use, in the order of their
  ids: at most `limit` after `cursor`, and the cursor the next page starts after. For work
  done once per organisation (`Apiary.Job.insert_per_organisation/3`); each page is one
  short query on the primary key's index, so nothing is held open between pages. An
  organisation marked for deletion is left out: nothing is done to it but its purge.
  """
  @spec page_organisation_ids(page_cursor(), pos_integer()) ::
          {[Ecto.UUID.t()], page_cursor()}
  def page_organisation_ids(cursor, limit) do
    from(o in Organisation, where: is_nil(o.deletion_marked_at), select: {o.id, o.id})
    |> page_ids(cursor, limit)
  end

  @doc """
  One page of the organisation and workspace ids of every workspace on the instance in
  use, in the order of the workspaces' ids, as `page_organisation_ids/2` pages
  organisations, leaving out a workspace, or one of an organisation, marked for deletion.
  For work done once per workspace (`Apiary.Job.insert_per_workspace/3`).
  """
  @spec page_workspace_ids(page_cursor(), pos_integer()) ::
          {[{Ecto.UUID.t(), Ecto.UUID.t()}], page_cursor()}
  def page_workspace_ids(cursor, limit) do
    from(w in Workspace,
      join: o in assoc(w, :organisation),
      where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at),
      select: {w.id, {w.organisation_id, w.id}}
    )
    |> page_ids(cursor, limit)
  end

  # Keyset pages on the primary key: a sweep needs every row once, in no particular order.
  defp page_ids(query, cursor, limit) do
    query = if cursor, do: where(query, [r], r.id > ^cursor), else: query
    rows = query |> order_by([r], asc: r.id) |> limit(^limit) |> Repo.all()

    case List.last(rows) do
      nil -> {[], cursor}
      {id, _ids} -> {Enum.map(rows, &elem(&1, 1)), id}
    end
  end

  # A membership's own place: its organisation, no reach beyond it, and nothing the
  # edition said of another place.
  defp put_place(scope, %Membership{} = membership, place) do
    put_place(
      %{
        scope
        | organisation: membership.organisation,
          membership: membership,
          reach: nil,
          edition: %{}
      },
      place
    )
  end

  # The workspace, what the edition says of the person there, and what the organisation
  # and the workspace have (`Apiary.Features.of/2`), which `Apiary.Features.on?/2` answers
  # from.
  defp put_place(scope, place) do
    {workspace, extras} = place || {nil, %{}}

    %{
      scope
      | workspace: workspace,
        edition: Map.merge(scope.edition, extras),
        features: Features.of(scope.organisation, workspace)
    }
  end

  @doc """
  list_memberships/1 is the user's memberships in use, oldest first, each with its
  organisation and `workspaces`, the workspaces of the organisation it reaches, by name,
  with what the edition says of each (`c:Apiary.Edition.reached_workspaces/2`) in the
  membership's `edition`, a list under each of its keys. A few reads, however many there are. An
  organisation or a workspace marked for deletion is left out, and so is a membership
  suspended, or of an account out of use.
  """
  @spec list_memberships(%User{}) :: [%Membership{}]
  def list_memberships(%User{} = user) do
    user |> membership_query() |> Repo.all() |> load_reach()
  end

  @doc """
  list_places/1 is every organisation the user reaches from the switcher and their
  organisations page (`c:Apiary.Edition.places/1`): their memberships, as
  `list_memberships/1` has them, and whatever else the edition lets them reach.
  """
  @spec list_places(%User{}) :: [Edition.place()]
  def list_places(%User{} = user), do: Edition.places(user)

  # The person's memberships in use: none suspended, and none of an account out of use.
  defp membership_query(%User{id: user_id}) do
    from(m in Membership,
      join: o in assoc(m, :organisation),
      join: u in assoc(m, :user),
      as: :account,
      where: m.user_id == ^user_id and is_nil(o.deletion_marked_at),
      where: is_nil(m.suspended_at),
      order_by: [asc: m.inserted_at, asc: m.id],
      preload: [organisation: o]
    )
    |> Edition.active_accounts(:account)
  end

  @doc """
  list_suspended_memberships/1 is the user's suspended memberships, oldest first, each
  with its organisation, none marked for deletion: the organisations they cannot act in
  until an owner or an admin there activates them, which their organisations page says.
  """
  @spec list_suspended_memberships(%User{}) :: [%Membership{}]
  def list_suspended_memberships(%User{id: user_id}) do
    Repo.all(
      from m in Membership,
        join: o in assoc(m, :organisation),
        where: m.user_id == ^user_id and is_nil(o.deletion_marked_at),
        where: not is_nil(m.suspended_at),
        order_by: [asc: m.inserted_at, asc: m.id],
        preload: [organisation: o]
    )
  end

  @doc """
  suspended_membership/2 is the user's suspended membership in the organisation whose
  slug is `organisation_slug`, with it, or nil: for a page that answers a path the user
  no longer reaches, and tells them why rather than that it does not exist.
  """
  @spec suspended_membership(%User{}, String.t()) :: %Membership{} | nil
  def suspended_membership(%User{id: user_id}, organisation_slug)
      when is_binary(organisation_slug) do
    Repo.one(
      from m in Membership,
        join: o in assoc(m, :organisation),
        where: m.user_id == ^user_id and o.slug == ^organisation_slug,
        where: is_nil(o.deletion_marked_at) and not is_nil(m.suspended_at),
        preload: [organisation: o]
    )
  end

  def suspended_membership(_user, _slug), do: nil

  # `workspaces` of each membership, and what the edition says of each workspace it
  # reaches in its `edition`, a list under each of its keys: one read of the
  # organisations' workspaces, and one more for the memberships at a level that does not
  # reach every workspace, which the edition narrows (`c:Apiary.Edition.reached_workspaces/2`).
  defp load_reach([]), do: []

  defp load_reach(memberships) do
    organisation_ids = memberships |> Enum.map(& &1.organisation_id) |> Enum.uniq()

    workspaces =
      Repo.all(
        from w in Workspace,
          where: w.organisation_id in ^organisation_ids and is_nil(w.deletion_marked_at),
          order_by: [asc: w.name, asc: w.id]
      )

    narrowed = for m <- memberships, not Access.reaches_every_workspace?(m.level), do: m.id

    reached =
      if narrowed == [] do
        %{}
      else
        from(w in Workspace,
          as: :workspace,
          join: m in Membership,
          as: :membership,
          on: m.organisation_id == w.organisation_id,
          where: m.id in ^narrowed and is_nil(w.deletion_marked_at),
          order_by: [asc: w.name, asc: w.id],
          select: %{workspace: w, membership_id: m.id}
        )
        |> Edition.reached_workspaces(nil)
        |> Repo.all()
        |> Enum.group_by(& &1.membership_id)
      end

    Enum.map(memberships, fn membership ->
      case Map.fetch(reached, membership.id) do
        {:ok, rows} ->
          extras =
            rows
            |> Enum.flat_map(&Map.keys(Map.drop(&1, [:workspace, :membership_id])))
            |> Enum.uniq()

          edition =
            Map.new(extras, fn key ->
              {key, rows |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)}
            end)

          %{membership | workspaces: Enum.map(rows, & &1.workspace), edition: edition}

        :error ->
          workspaces =
            if Access.reaches_every_workspace?(membership.level),
              do: Enum.filter(workspaces, &(&1.organisation_id == membership.organisation_id)),
              else: []

          %{membership | workspaces: workspaces}
      end
    end)
  end

  ## Sign-up

  @sign_up_types %{email: :string, organisation_name: :string}
  # The password and its confirmation are checked on the form (`change_sign_up/2`) and
  # hashed into the account (`sign_up_user/3`); never kept in the form's changes, and never
  # handed to the edition.
  @sign_up_fields Enum.map(Map.keys(@sign_up_types), &Atom.to_string/1) ++
                    ~w(password password_confirmation)

  @doc """
  sign_up_offer/1 is what a sign-up without an invitation may do on this instance now:
  `:not_set_up` while the instance has no organisation of its own
  (`c:Apiary.Edition.instance_organisation_id/0`), which only its set-up link makes
  (`Apiary.Setup`), so nobody signs up before it; `:open`, a sign-up that creates an
  organisation, where the edition opens one (`c:Apiary.Edition.sign_up_open?/0`);
  `:closed`, where sign-up is by invitation only. The sign-up page asks it on mount, and
  `sign_up_user/3` asks again, inside its transaction, before it creates anything.
  `open:`, a boolean, stands in for the edition's answer, for tests.
  """
  @spec sign_up_offer(keyword) :: :not_set_up | :open | :closed
  def sign_up_offer(opts \\ []) do
    cond do
      not instance_claimed?() -> :not_set_up
      open?(opts) -> :open
      true -> :closed
    end
  end

  @doc """
  sign_up_offered?/0 says whether a sign-up without an invitation is offered at all: on
  an instance that is set up, where the edition opens one.
  """
  @spec sign_up_offered?() :: boolean
  def sign_up_offered?, do: sign_up_offer() == :open

  defp open?(opts), do: Keyword.get_lazy(opts, :open, &Edition.sign_up_open?/0)

  defp instance_claimed?, do: not is_nil(Edition.instance_organisation_id())

  @doc """
  change_sign_up/2 is the changeset of the sign-up form: `email`, checked as an account's
  address is, and, for a sign-up without an invitation, `organisation_name`, the name of
  the organisation it creates, checked as an organisation's name is. `invited: true` for a
  sign-up with an invitation, which creates no organisation and asks for no name;
  `validate_unique: false` leaves out the read of whether the address is taken, as the
  form does while it is typed in. An edition whose sign-up page asks more checks it on
  this changeset, and is given it when the organisation is created
  (`c:Apiary.Edition.organisation_created/2`, `sign_up_user/3`).

  **The password.** `password` and `password_confirmation` are checked as an account's
  password is (`Apiary.Accounts.User.password_changeset/3`: 12 to 72 characters, and
  72 bytes at most, the confirmation the same), with their errors on those fields. They
  are never kept in the changeset's changes. `password: :required` asks for one, as a
  person's sign-up does while the instance sends no email (`Apiary.Mail.configured?/0`);
  `password: :none` leaves them out, as a person's sign-up does once the instance sends
  email; `password: :optional` checks one only when it is given, as the instance's own
  sign-up does. The default is the person's, by the instance's mail.
  """
  @spec change_sign_up(map, keyword) :: Ecto.Changeset.t()
  def change_sign_up(attrs \\ %{}, opts \\ []) do
    unique? = Keyword.get(opts, :validate_unique, true)
    user = User.email_changeset(%User{}, attrs, validate_unique: unique?)

    form =
      {%{}, @sign_up_types}
      |> Ecto.Changeset.cast(attrs, Map.keys(@sign_up_types))
      |> Ecto.Changeset.update_change(:organisation_name, &String.trim/1)
      |> copy_errors(user)
      |> check_password(attrs, Keyword.get_lazy(opts, :password, &password_rule/0))

    if Keyword.get(opts, :invited, false) do
      form
    else
      name = Ecto.Changeset.get_field(form, :organisation_name)
      copy_errors(form, Organisation.changeset(%Organisation{}, %{name: name}))
    end
  end

  # The errors of the account's or the organisation's changeset, on the form's fields: the
  # address on `email`, the password and its confirmation on theirs, the organisation's
  # name and slug on `organisation_name`, and anything else on `email`, which is where the
  # form says it could not sign up.
  defp copy_errors(form, %Ecto.Changeset{errors: errors}) do
    Enum.reduce(errors, form, fn {field, {message, keys}}, form ->
      field =
        cond do
          field in [:name, :slug] -> :organisation_name
          field in [:password, :password_confirmation] -> field
          true -> :email
        end

      Ecto.Changeset.add_error(form, field, message, keys)
    end)
  end

  # Whether a person's sign-up takes a password: while the instance sends no email, a
  # password is the account's only way in; once it sends email, the address is confirmed
  # by a link before the account has any, so none is taken.
  defp password_rule, do: if(Apiary.Mail.configured?(), do: :none, else: :required)

  # The password's errors on the form, checked on an account's password changeset without
  # hashing it, with the 72 bytes the hashing checks; an optional one only when it is
  # given, and none at all for `:none`.
  defp check_password(form, _attrs, :none), do: form

  defp check_password(form, attrs, rule) do
    if rule == :required or password_given?(attrs),
      do: copy_errors(form, checked_password(attrs)),
      else: form
  end

  defp checked_password(attrs) do
    changeset = User.password_changeset(%User{}, password_attrs(attrs), hash_password: false)

    if changeset.valid?,
      do: Ecto.Changeset.validate_length(changeset, :password, max: 72, count: :bytes),
      else: changeset
  end

  defp password_given?(attrs),
    do: Enum.any?(Map.values(password_attrs(attrs)), &(is_binary(&1) and &1 != ""))

  # The password and its confirmation, of a form's string keys or a caller's atom keys.
  defp password_attrs(attrs) do
    for field <- [:password, :password_confirmation],
        value = Map.get(attrs, field, Map.get(attrs, Atom.to_string(field))),
        not is_nil(value),
        into: %{},
        do: {field, value}
  end

  @doc """
  Registers a user and places them in an organisation, in one transaction.

  Without an invitation token the user gets a new organisation named `organisation_name`,
  with a slug made from that name, a workspace named "#{@default_workspace_name}" and an
  owner membership (`build_organisation/2`): nothing is made from the address. Whether it
  may, is `sign_up_offer/1`'s answer, asked again inside the transaction:

  - **The instance's first sign-up** creates the instance's own organisation, whose
    owners run the instance (`Apiary.Access.instance_admin?/1`): its owner is the
    instance's first admin. The edition is told so (`:first_sign_up`). It is the
    set-up's (`Apiary.Setup.set_up/3`) or a release command's, with `first_only: true`
    and `actor: :instance`; any other sign-up before it is refused with
    `{:error, :not_set_up}`. It marks the set-up code used, in its transaction
    (`Apiary.Setup`); with `setup_code:`, the set-up's, it checks that code
    first, under the row's lock, and is `{:error, :invalid_code}` when it is not the
    stored one. Of two first sign-ups at once, one takes the instance's first-sign-up
    lock and creates it; the other waits for the lock, finds it, and is
    `{:error, :instance_claimed}`.
  - **A later sign-up** creates an organisation where the edition opens one, and the
    edition is told so, with what the form sent beyond the core's fields, with string
    keys (`{:sign_up, extra}`): an edition may ask more of the form, and refuse it on
    one of its fields. With none open it is refused on `email`: sign-up is by
    invitation only.

  With a valid pending token the invitation is accepted instead: no organisation is
  created, no name is asked for, and the person joins at the level the invitation gives,
  a member unless the edition says otherwise (`accept_invitation/2`). An invalid or
  expired token behaves as no token.

  A refusal is `{:error, changeset}`, the changeset of the sign-up form
  (`change_sign_up/2`), with its errors on `email` and `organisation_name`, and on the
  field of the edition's that refused.

  The invitation may also be given as the struct `get_invitation_by_token/1`
  returned earlier. Either way it is claimed inside the transaction: when someone
  else accepted it in the meantime, nothing is created and the changeset carries
  an error on `:email`. So it does when every slug picked for the new organisation was
  taken by a concurrent sign-up before the insert, a few times over.

  The audit trail has the sign-up, by the new user: `organisation.create` for a new
  organisation, with `details.sign_up` true, `invitation.accept` for an invitation, from
  `origin:` (see `Apiary.Accounts.Scope.put_origin/2`), the request's address and client.

  **The password.** `password`, with `password_confirmation`, is the account's password,
  checked as `change_sign_up/2` checks it and hashed into the account. A person's sign-up
  needs one while the instance sends no email (`Apiary.Mail.configured?/0`), since it is
  then the account's only way in. Once the instance sends email, a person's sign-up takes
  none, and drops one sent all the same: the address is confirmed by a link before the
  account can sign in. `actor: :instance` needs none, and keeps one given, mail or not.
  `password: :required` asks for one whatever the mail, as the set-up page does.
  Either way the account is unconfirmed until a log-in link sent to its address is
  followed (`Apiary.Accounts.login_user_by_magic_link/1`). Without mail, an invited
  sign-up takes the invitation's address, whatever `email` says: the link is the
  inviter's word for it.

  `first_only: true` creates the instance's organisation or nothing, for
  `Apiary.Setup.set_up/3` and `Apiary.Release.grant_instance_admin/2` on an instance
  that is not set up: `{:error, :instance_claimed}` once the instance has one, a set-up
  that came first included. `actor: :instance` records the sign-up as the instance's,
  from `origin:`, rather than the new user's: the set-up or a release command made it.
  The entry names the user by id either way.

  `opts` is also for tests: `pick_slug: fun`, given the organisation's name, stands in for
  the pick of a free slug, and `open:`, a boolean, for the edition's answer to whether a
  later sign-up is open.
  """
  @spec sign_up_user(map, %Invitation{} | String.t() | nil, keyword) ::
          {:ok,
           %{
             user: %User{},
             organisation: %Organisation{},
             workspace: %Workspace{},
             membership: %Membership{}
           }}
          | {:error, Ecto.Changeset.t() | :instance_claimed | :not_set_up | :invalid_code}
  def sign_up_user(attrs, invitation_or_token \\ nil, opts \\ []) do
    invitation = pending_invitation(invitation_or_token)

    # Before set-up the one sign-up is the instance's first, its set-up's or a release
    # command's; asked again inside the transaction.
    if match?(%Invitation{}, invitation) or setting_up?(opts) or instance_claimed?(),
      do: sign_up(attrs, invitation, opts),
      else: {:error, :not_set_up}
  end

  defp sign_up(attrs, invitation, opts) do
    origin = Keyword.get(opts, :origin)
    invited? = match?(%Invitation{}, invitation)
    mail? = Apiary.Mail.configured?()

    offered? =
      invited? or Keyword.get(opts, :first_only, false) or sign_up_offer(opts) != :closed

    # The instance's own sign-up (a release command's, the set-up's) takes a password
    # when it is given one. A person's needs one while the instance sends no email, and
    # takes none once it does: its address is confirmed by a link first, so a password
    # sent all the same is dropped. `password:` says otherwise, as the set-up page does.
    password =
      Keyword.get_lazy(opts, :password, fn ->
        cond do
          Keyword.get(opts, :actor, :person) == :instance -> :optional
          mail? -> :none
          true -> :required
        end
      end)

    attrs =
      if password == :none,
        do:
          Map.drop(attrs, [:password, :password_confirmation | ~w(password password_confirmation)]),
        else: attrs

    # Without mail, the invitation's link is the inviter's word for its address: the
    # account takes it, whatever the form sent.
    attrs = if invited? and not mail?, do: put_email(attrs, invitation.email), else: attrs

    form =
      attrs
      |> change_sign_up(invited: invited?, validate_unique: false, password: password)
      |> refuse_closed_sign_up(offered?)

    if form.valid? do
      email = Ecto.Changeset.get_field(form, :email)

      user_changeset =
        %User{}
        |> User.email_changeset(%{email: email})
        |> put_password(attrs)

      multi =
        if invited?,
          do: invited_sign_up_multi(user_changeset, invitation, origin),
          else:
            fresh_sign_up_multi(
              user_changeset,
              Ecto.Changeset.get_field(form, :organisation_name),
              extra(attrs),
              opts
            )

      case Repo.transaction(multi) do
        {:ok, %{user: user} = changes} ->
          %{organisation: organisation, workspace: workspace, membership: membership} =
            Map.get(changes, :created, changes)

          {:ok,
           %{user: user, organisation: organisation, workspace: workspace, membership: membership}}

        {:error, :how, reason, _changes} when reason in [:instance_claimed, :not_set_up] ->
          {:error, reason}

        {:error, :set_up, :invalid_code, _changes} ->
          {:error, :invalid_code}

        {:error, :organisation, :slug_taken, _changes} ->
          {:error,
           form
           |> Ecto.Changeset.add_error(
             :email,
             dgettext_noop("errors", "could not be signed up just now; please try again")
           )
           |> Map.put(:action, :insert)}

        # A refusal of the sign-up's, or of the edition's steps, on a field of the form.
        {:error, _step, {field, message}, _changes} when is_atom(field) and is_binary(message) ->
          {:error, form |> Ecto.Changeset.add_error(field, message) |> Map.put(:action, :insert)}

        {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, form |> copy_errors(changeset) |> Map.put(:action, :insert)}
      end
    else
      {:error, Map.put(form, :action, :insert)}
    end
  end

  # The address of the form's attributes, under the key kind they use.
  defp put_email(attrs, email) do
    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: attrs |> Map.delete("email") |> Map.put(:email, email),
      else: Map.put(attrs, "email", email)
  end

  # The password, hashed into the account, once the form has checked it; none when none
  # was given.
  defp put_password(user_changeset, attrs) do
    if password_given?(attrs),
      do: User.password_changeset(user_changeset, password_attrs(attrs)),
      else: user_changeset
  end

  defp refuse_closed_sign_up(form, true), do: form

  defp refuse_closed_sign_up(form, false),
    do: Ecto.Changeset.add_error(form, :email, closed_sign_up())

  defp closed_sign_up,
    do:
      dgettext_noop(
        "errors",
        "cannot sign up here without an invitation: ask an owner or an admin of your organisation to invite you"
      )

  # What the form sent beyond the core's fields, for the edition, with string keys.
  defp extra(attrs) do
    for {key, value} <- attrs,
        key = to_string(key),
        key not in @sign_up_fields,
        into: %{},
        do: {key, value}
  end

  defp fresh_sign_up_multi(user_changeset, name, extra, opts) do
    origin = Keyword.get(opts, :origin)
    actor = Keyword.get(opts, :actor, :person)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:how, fn _repo, _changes -> sign_up_how(extra, opts) end)
    # The instance's first sign-up uses its set-up code: the link's, which it checks, or
    # whatever code is stored, for a release command's (`Apiary.Setup.use_code/2`).
    |> Ecto.Multi.run(:set_up, fn repo, %{how: how} ->
      if how == :first_sign_up,
        do: Apiary.Setup.use_code(repo, Keyword.get(opts, :setup_code)),
        else: {:ok, nil}
    end)
    |> Ecto.Multi.insert(:user, user_changeset)
    |> build_organisation(
      name: name,
      how: & &1.how,
      scope: &sign_up_scope(&1, origin, actor),
      details: %{sign_up: true},
      pick_slug: Keyword.get(opts, :pick_slug)
    )
  end

  # What the sign-up is, decided inside its transaction: the instance's first while the
  # instance has no organisation of its own, read again under the first-sign-up lock, so
  # of two first sign-ups one creates it, and only for its set-up or a release command
  # (`setting_up?/1`); a later one where the edition opens one. The instance's
  # organisation stays, so one seen without the lock is there.
  defp sign_up_how(extra, opts) do
    cond do
      not instance_claimed?() and setting_up?(opts) -> first_sign_up_how()
      not instance_claimed?() -> {:error, :not_set_up}
      Keyword.get(opts, :first_only, false) -> {:error, :instance_claimed}
      true -> later_sign_up_how(extra, opts)
    end
  end

  # The instance's first-sign-up lock, for the transaction, then a second look: of two
  # first sign-ups at once, one creates the instance's organisation and the other sees it.
  defp first_sign_up_how do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('apiary:first-sign-up', 0))")

    if instance_claimed?(), do: {:error, :instance_claimed}, else: {:ok, :first_sign_up}
  end

  # The instance's first sign-up is its set-up's (`Apiary.Setup.set_up/3`) or a release
  # command's: the instance's, and that sign-up only.
  defp setting_up?(opts),
    do: Keyword.get(opts, :first_only, false) and Keyword.get(opts, :actor) == :instance

  defp later_sign_up_how(extra, opts) do
    if open?(opts),
      do: {:ok, {:sign_up, extra}},
      else: {:error, {:email, closed_sign_up()}}
  end

  # The new user, acting in the organisation they signed up into; or the instance, when a
  # release command signed them up.
  defp sign_up_scope(changes, origin, actor \\ :person)

  defp sign_up_scope(%{organisation: organisation, workspace: workspace}, origin, :instance),
    do: organisation |> Scope.for_instance(workspace) |> Scope.put_origin(origin)

  defp sign_up_scope(
         %{user: user, organisation: organisation, workspace: workspace},
         origin,
         :person
       ) do
    %Scope{user: user, organisation: organisation, workspace: workspace, origin: origin}
  end

  # The edition first, which may hold the organisation more strongly, then the
  # organisation, as the lock order has it (`lock_open_organisation/1`): its marking, and
  # what the edition stops, wait for the sign-up, or came first and refuse it.
  defp invited_sign_up_multi(user_changeset, %Invitation{} = invitation, origin) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:level, fn repo, _changes ->
      with {:ok, level} <- Edition.accepting(repo, invitation, nil),
           :ok <- lock_open_organisation(invitation) do
        {:ok, level}
      else
        {:error, _reason} -> no_longer_valid(user_changeset)
      end
    end)
    |> Ecto.Multi.insert(:user, user_changeset)
    |> Ecto.Multi.put(:organisation, invitation.organisation)
    |> Ecto.Multi.put(:workspace, invitation.workspace)
    |> Ecto.Multi.run(:invitation, fn _repo, %{user: user} ->
      # Lost to a concurrent accept: an error on the form rather than a second
      # membership from one invitation.
      with {:error, :invalid} <- lock_person_then_claim(user, invitation),
           do: no_longer_valid(user_changeset)
    end)
    |> Ecto.Multi.insert(:membership, fn %{user: user, level: level} ->
      membership_changeset(invitation.organisation, user, level)
    end)
    |> Ecto.Multi.run(:accepted, fn repo, %{user: user, membership: membership} ->
      scope =
        sign_up_scope(
          %{user: user, organisation: invitation.organisation, workspace: nil},
          origin
        )

      with :ok <- Edition.accepted(repo, scope, invitation, membership), do: {:ok, nil}
    end)
    |> Ecto.Multi.delete(:claimed, fn %{invitation: claimed} -> claimed end)
    |> Audit.record(
      &sign_up_scope(&1, origin),
      :"invitation.accept",
      invitation,
      &accepted(&1.membership)
    )
  end

  defp no_longer_valid(user_changeset) do
    {:error,
     user_changeset
     |> Ecto.Changeset.add_error(
       :email,
       dgettext_noop("errors", "was invited, but the invitation is no longer valid")
     )
     |> Map.put(:action, :insert)}
  end

  # An accepted invitation: the level its person joined at, and the membership it became;
  # never the address it was sent to. The entry is in the invitation's workspace.
  defp accepted(%Membership{id: id, level: level}),
    do: %{after: %{level: level}, details: %{membership_id: id}}

  defp membership_changeset(%Organisation{} = organisation, %User{} = user, level) do
    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
  end

  ## Creating an organisation

  @slug_attempts 5

  @doc """
  build_organisation/2 adds to `multi` the steps that create an organisation: the one way
  an organisation is created, by the instance's first sign-up and a later one
  (`sign_up_user/3`), by each of the edition's ways, and by the tests' organisations.
  The caller runs `multi` in its transaction, having asked `Apiary.Access` what it must
  first; nothing is asked here. The steps, in order, after the caller's own:

  - `:organisation`, the organisation named `name:`, with a slug made from its name
    (`Apiary.Organisations.Slug`); `{:error, changeset}` for a name the organisation's
    changeset refuses, and `{:error, :slug_taken}` when every slug picked was taken by a
    concurrent creation, a few times over;
  - `:workspace`, its workspace "#{@default_workspace_name}";
  - `:membership`, its first owner, the person of the caller's change `owner:` names,
    `:user` unless it names another; nil with `owner: nil`, for an organisation whose
    first owner joins later;
  - the edition's steps (`c:Apiary.Edition.organisation_created/2`), told `how:`, a term
    or a function of the caller's changes that gives it. One of them may leave
    `:organisation_entry`, a map of `before`, `after` and `details`, which the entry
    carries beside the core's;
  - the entry that begins the organisation's trail, of `action:`, `organisation.create`
    unless it names one of the edition's, by the scope `scope:` gives, a function of the
    changes, the caller's among them: it names the workspace, and the membership and its
    person by id, with `details:` beside;
  - `:created`, a map of the organisation as the database has it once the edition's steps
    are done, its workspace and its membership.

  `pick_slug:`, given the name, stands in for the pick of a free slug, for tests.
  """
  @spec build_organisation(Ecto.Multi.t(), keyword) :: Ecto.Multi.t()
  def build_organisation(%Ecto.Multi{} = multi, opts) do
    name = Keyword.fetch!(opts, :name)
    how = Keyword.fetch!(opts, :how)
    scope = Keyword.fetch!(opts, :scope)
    owner = Keyword.get(opts, :owner, :user)
    action = Keyword.get(opts, :action, :"organisation.create")
    details = Keyword.get(opts, :details, %{})
    pick = Keyword.get(opts, :pick_slug) || (&organisation_slug/1)

    # The caller's changes are given to the steps that need them: the edition's see the
    # organisation's own.
    Ecto.Multi.merge(multi, fn outer ->
      how = if is_function(how, 1), do: how.(outer), else: how
      user = owner && Map.fetch!(outer, owner)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:organisation, fn _repo, _changes -> insert_organisation(name, pick) end)
      |> Ecto.Multi.insert(:workspace, &main_workspace(&1.organisation))
      |> Ecto.Multi.run(:membership, fn repo, %{organisation: organisation} ->
        if user,
          do: repo.insert(membership_changeset(organisation, user, :owner)),
          else: {:ok, nil}
      end)
      |> Edition.organisation_created(how)
      |> Audit.record(
        &scope.(Map.merge(outer, &1)),
        action,
        & &1.organisation,
        &organisation_entry(&1, details)
      )
      |> Ecto.Multi.run(:created, fn repo, changes ->
        {:ok,
         %{
           organisation: repo.get!(Organisation, changes.organisation.id),
           workspace: changes.workspace,
           membership: changes.membership
         }}
      end)
    end)
  end

  # The entry of a new organisation: its workspace, its first owner's membership and
  # person, the caller's details, and what the edition's steps said of it.
  defp organisation_entry(changes, details) do
    edition = Map.get(changes, :organisation_entry) || %{}

    owner =
      case changes.membership do
        %Membership{id: id, user_id: user_id} -> %{membership_id: id, user_id: user_id}
        nil -> %{}
      end

    %{
      before: edition[:before],
      after: edition[:after],
      details:
        %{workspace_id: changes.workspace.id}
        |> Map.merge(owner)
        |> Map.merge(details)
        |> Map.merge(edition[:details] || %{})
    }
  end

  # Inserts a new organisation with a slug `pick` makes from its name. The slug is picked
  # by asking which are taken, so two creations may pick the same one at once. The insert
  # does nothing on the unique index instead of failing, which would abort the
  # transaction; the organisation is then not there, and a new slug is picked, as often
  # as `@slug_attempts`. `{:error, :slug_taken}` when every attempt lost. A name the
  # organisation refuses is refused before a slug is made of it.
  defp insert_organisation(name, pick, attempts \\ @slug_attempts)

  defp insert_organisation(_name, _pick, 0), do: {:error, :slug_taken}

  defp insert_organisation(name, pick, attempts) do
    case Organisation.changeset(%Organisation{}, %{name: name}) do
      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, changeset}

      changeset ->
        with {:ok, %Organisation{id: id} = organisation} <-
               changeset
               |> Organisation.put_slug(pick.(name))
               |> Repo.insert(on_conflict: :nothing, conflict_target: :slug) do
          if Repo.exists?(from o in Organisation, where: o.id == ^id),
            do: {:ok, organisation},
            else: insert_organisation(name, pick, attempts - 1)
        end
    end
  end

  defp main_workspace(%Organisation{} = organisation) do
    %Workspace{organisation_id: organisation.id}
    |> Workspace.create_changeset(%{
      name: @default_workspace_name,
      domain: Apiary.Lingo.Domain.default().name()
    })
    |> Workspace.put_slug(workspace_slug(organisation, @default_workspace_name))
  end

  defp organisation_slug(name) do
    name
    |> Slug.from_name("organisation")
    |> Slug.pick(ApiaryWeb.ReservedSlugs.organisation(), fn slug ->
      Repo.exists?(from o in Organisation, where: o.slug == ^slug)
    end)
  end

  defp workspace_slug(%Organisation{id: organisation_id}, name) do
    name
    |> Slug.from_name("workspace")
    |> Slug.pick(ApiaryWeb.ReservedSlugs.workspace(), fn slug ->
      Repo.exists?(
        from w in Workspace, where: w.organisation_id == ^organisation_id and w.slug == ^slug
      )
    end)
  end

  ## Settings

  def change_organisation(%Organisation{} = organisation, attrs \\ %{}) do
    Organisation.changeset(organisation, attrs)
  end

  @doc "Renames the scope's organisation (`organisation.rename`), with its audit entry."
  def update_organisation(%Scope{organisation: %Organisation{} = organisation} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"organisation.rename", organisation),
           {:ok, renamed} <- organisation |> Organisation.changeset(attrs) |> Repo.update(),
           :ok <- record_edit(scope, :"organisation.rename", organisation, renamed, [:name]) do
        {:ok, renamed}
      end
    end)
  end

  def change_workspace(%Workspace{} = workspace, attrs \\ %{}) do
    Workspace.changeset(workspace, attrs)
  end

  @doc "Renames the scope's workspace (`workspace.rename`), with its audit entry."
  def update_workspace(%Scope{workspace: %Workspace{} = workspace} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"workspace.rename", workspace),
           {:ok, renamed} <- workspace |> Workspace.changeset(attrs) |> Repo.update(),
           :ok <- record_edit(scope, :"workspace.rename", workspace, renamed, [:name]) do
        {:ok, renamed}
      end
    end)
  end

  # The entry of an edit, when it changed one of `fields`; an edit that changed nothing
  # has nothing to record.
  defp record_edit(scope, action, old, new, fields) do
    case Audit.changed(old, new, fields) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, action, new, changes), do: :ok
    end
  end

  ## Creating a workspace

  @doc """
  change_new_workspace/2 is the changeset of a workspace the scope's organisation would
  get from `attrs`, for the form that creates one (`create_workspace/2`): its name, and
  its slug as `attrs` gives it, or made from the name where it gives none
  (`suggest_workspace_slug/2`).
  """
  @spec change_new_workspace(Scope.t(), map) :: Ecto.Changeset.t()
  def change_new_workspace(%Scope{organisation: %Organisation{} = organisation}, attrs \\ %{}),
    do: new_workspace_changeset(organisation, attrs)

  @doc """
  suggest_workspace_slug/2 is the slug a workspace named `name` would get in the scope's
  organisation: made from the name (`Apiary.Organisations.Slug.from_name/2`), then the
  first of it and its numbered variants that no workspace of the organisation holds and
  no page of the organisation takes.
  """
  @spec suggest_workspace_slug(Scope.t(), String.t() | nil) :: String.t()
  def suggest_workspace_slug(%Scope{organisation: %Organisation{} = organisation}, name),
    do: workspace_slug(organisation, name || "")

  @doc """
  create_workspace/2 creates a workspace of the scope's organisation (`workspace.create`,
  an owner's, asked of the organisation), named `attrs["name"]`, at the slug
  `attrs["slug"]` or one made from the name, in the default domain and with nothing in it:
  no key, no run, its policy in observe. The organisation's row is locked while its
  workspaces in use are counted against the edition's limit
  (`c:Apiary.Edition.limits/0`), the entry is written in the organisation's trail, and
  the edition is told (`c:Apiary.Edition.workspace_created/3`), all in one transaction.

  `{:ok, workspace}`; `{:error, changeset}` for a name or a slug the workspace refuses,
  one another workspace of the organisation holds included; `{:error, :limit}` where the
  organisation has as many workspaces as the edition allows; `Apiary.Access`'s answer.
  """
  @spec create_workspace(Scope.t(), map) ::
          {:ok, %Workspace{}} | {:error, Ecto.Changeset.t() | :limit | Access.reason()}
  def create_workspace(%Scope{organisation: %Organisation{} = organisation} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"workspace.create", organisation),
           :ok <- lock_allowance(organisation),
           :ok <- ensure_within_limit(organisation),
           {:ok, workspace} <- organisation |> new_workspace_changeset(attrs) |> Repo.insert(),
           {:ok, _entry} <-
             Audit.record(
               Repo,
               scope,
               :"workspace.create",
               workspace,
               %{after: %{name: workspace.name, slug: workspace.slug}},
               place: :organisation
             ),
           :ok <- Edition.workspace_created(Repo, workspace, scope) do
        {:ok, workspace}
      end
    end)
  end

  # Whether the organisation may have one more workspace: as many in use as the edition
  # allows is as many as it may have. Counted under the organisation's lock
  # (`lock_allowance/1`), so two creations are counted one after the other.
  defp ensure_within_limit(%Organisation{id: organisation_id}) do
    case Edition.limits().workspaces do
      :unlimited ->
        :ok

      limit when is_integer(limit) ->
        in_use =
          Repo.aggregate(
            from(w in Workspace,
              where: w.organisation_id == ^organisation_id and is_nil(w.deletion_marked_at)
            ),
            :count
          )

        if in_use < limit, do: :ok, else: {:error, :limit}
    end
  end

  # A new workspace of the organisation: its name, as the form gives it, and its slug, the
  # form's where it gives one, else one made from the name. The slug goes through the
  # params too, so the form knows the field was used and shows what is wrong with it.
  defp new_workspace_changeset(%Organisation{id: organisation_id} = organisation, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    name = attrs["name"]

    slug =
      case attrs["slug"] do
        given when is_binary(given) and given != "" -> String.trim(given)
        _none -> workspace_slug(organisation, if(is_binary(name), do: name, else: ""))
      end

    %Workspace{organisation_id: organisation_id}
    |> Workspace.create_changeset(%{
      name: name,
      slug: slug,
      domain: Apiary.Lingo.Domain.default().name()
    })
    |> Workspace.put_slug(slug)
  end

  @doc """
  list_workspaces/1 is the workspaces of the scope's organisation in use, by name: none
  marked for deletion (`Apiary.Deletion.list_marked_workspaces/1` lists those).
  """
  @spec list_workspaces(Scope.t()) :: [%Workspace{}]
  def list_workspaces(%Scope{organisation: %Organisation{id: organisation_id}}) do
    Repo.all(
      from w in Workspace,
        where: w.organisation_id == ^organisation_id and is_nil(w.deletion_marked_at),
        order_by: [asc: w.name, asc: w.id]
    )
  end

  ## Members

  @doc """
  list_members/1 is the memberships of the scope's organisation, each with its user:
  owners first, then admins, then members, each by when they joined. Each carries
  `workspaces`, the workspaces it reaches, by name, of those the scope's own membership
  reaches: a reader is not told of a workspace they do not reach.
  """
  @spec list_members(Scope.t()) :: [%Membership{}]
  def list_members(%Scope{organisation: %Organisation{id: organisation_id}} = scope) do
    members =
      Repo.all(
        from m in Membership,
          where: m.organisation_id == ^organisation_id,
          order_by: [
            asc: fragment("CASE ? WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END", m.level),
            asc: m.inserted_at,
            asc: m.id
          ],
          preload: [:user]
      )
      |> load_reach()

    case readers_reach(scope, members) do
      nil ->
        members

      within ->
        Enum.map(members, fn member ->
          %{member | workspaces: Enum.filter(member.workspaces, &MapSet.member?(within, &1.id))}
        end)
    end
  end

  @doc """
  list_workspace_members/1 is the memberships that reach the scope's workspace and act in
  it, in `list_members/1`'s order and as it gives them: each at a level that reaches every
  workspace, or one the edition lets into this one (`c:Apiary.Edition.reached_workspaces/2`);
  a suspended membership acts nowhere, and is not one. None without a workspace.
  """
  @spec list_workspace_members(Scope.t()) :: [%Membership{}]
  def list_workspace_members(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    for member <- list_members(scope),
        is_nil(member.suspended_at),
        Enum.any?(member.workspaces, &(&1.id == workspace_id)),
        do: member
  end

  def list_workspace_members(%Scope{}), do: []

  # The workspaces the scope's person reaches: nil, every one, as the edition lets them in
  # or at a level that reaches them all; else those of the membership among `members` that
  # is theirs; none without a membership.
  defp readers_reach(%Scope{} = scope, members) do
    cond do
      Access.reaches_every_workspace_in?(scope) ->
        nil

      reader = scope.membership && Enum.find(members, &(&1.id == scope.membership.id)) ->
        MapSet.new(reader.workspaces, & &1.id)

      true ->
        MapSet.new()
    end
  end

  @doc """
  set_member_level/3 changes a person's level (`member.change_level`), which only an owner
  may: to owner, admin or member. Demoting the organisation's last owner is refused,
  `{:error, :last_owner}`. The edition is told, inside the transaction, once the entry is
  written (`c:Apiary.Edition.membership_changed/5`, `:level`).
  """
  @spec set_member_level(Scope.t(), Ecto.UUID.t(), Membership.level() | String.t()) ::
          {:ok, %Membership{}} | {:error, :not_found | :forbidden | :last_owner | term}
  def set_member_level(%Scope{} = scope, membership_id, level) do
    level = normalise_level(level)

    with true <- level in Membership.levels() || {:error, :not_found} do
      fn ->
        with :ok <- lock_owners(scope),
             {:ok, membership} <- get_member(scope, membership_id),
             :ok <- Access.authorize(scope, :"member.change_level", membership),
             :ok <- ensure_not_last_owner(membership, level),
             {:ok, changed} <-
               membership |> Membership.changeset(%{level: level}) |> Repo.update(),
             :ok <- record_member(scope, :"member.change_level", membership, changed),
             :ok <- Edition.membership_changed(Repo, scope, :level, membership, changed) do
          {:ok, changed}
        end
      end
      |> Repo.transact()
      |> broadcast_membership_change()
    end
  end

  @doc """
  remove_member/2 removes a person from the organisation (`member.remove`), and with their
  membership what hangs from it. An owner removes anyone, an admin members only, and
  anyone may remove themselves, leaving the organisation. The last owner cannot be
  removed, `{:error, :last_owner}`, nor leave. The pending invitations the person sent
  stay, as the organisation's: each makes a member, whoever sent it.
  """
  @spec remove_member(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %Membership{}} | {:error, :not_found | :forbidden | :last_owner | term}
  def remove_member(%Scope{} = scope, membership_id) do
    fn ->
      with :ok <- lock_owners(scope),
           {:ok, membership} <- get_member(scope, membership_id),
           :ok <- Access.authorize(scope, :"member.remove", membership),
           :ok <- ensure_not_last_owner(membership, :removed),
           {:ok, removed} <- Repo.delete(membership),
           :ok <- record_member(scope, :"member.remove", membership, nil) do
        {:ok, removed}
      end
    end
    |> Repo.transact()
    |> broadcast_membership_change()
  end

  @doc """
  suspend_member/2 suspends the membership `membership_id` of the scope's organisation
  (`member.suspend`): its person acts there no more, as if they had no membership, and
  is told so when they open it, until it is activated (`activate_member/2`). Nothing is
  removed: what their membership reaches, the invitations they sent, what they made. An owner
  suspends admins and members, never another owner, and an admin members only; nobody
  suspends themselves. The last owner who may act is not suspended,
  `{:error, :last_owner}`. An entry of `member.suspend`, which names the person by user
  id; one suspended already changes nothing and leaves none. Their open pages follow
  (`membership_topic/1`).

  The membership is updated in the transaction that asked, so a change of theirs that
  holds it `FOR SHARE` (`Apiary.Access.reload/2`) is written first, and one asked after
  sees it.
  """
  @spec suspend_member(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %Membership{}} | {:error, :not_found | :forbidden | :last_owner | term}
  def suspend_member(%Scope{} = scope, membership_id) do
    fn ->
      with :ok <- lock_owners(scope),
           {:ok, membership} <- get_member(scope, membership_id),
           :ok <- Access.authorize(scope, :"member.suspend", membership) do
        if membership.suspended_at do
          {:ok, membership}
        else
          with :ok <- ensure_not_last_owner(membership, :suspended),
               {:ok, suspended} <-
                 membership
                 |> Ecto.Changeset.change(
                   suspended_at: DateTime.utc_now(),
                   suspended_by_id: scope.user.id
                 )
                 |> Repo.update(),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"member.suspend", suspended, %{
                   before: %{suspended_at: nil},
                   after: %{suspended_at: suspended.suspended_at},
                   details: %{user_id: suspended.user_id, level: suspended.level}
                 }) do
            {:ok, suspended}
          end
        end
      end
    end
    |> Repo.transact()
    |> broadcast_membership_change()
  end

  @doc """
  activate_member/2 ends the suspension of the membership `membership_id` of the scope's
  organisation (`member.activate`): its person acts there again at their level, reaching
  what they reached. An owner activates anyone else, an admin members only. An
  entry of `member.activate`; one not suspended changes nothing and leaves none. The
  edition is told, inside the transaction, once the entry is written
  (`c:Apiary.Edition.membership_changed/5`, `:activated`).
  """
  @spec activate_member(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %Membership{}} | {:error, :not_found | :forbidden | term}
  def activate_member(%Scope{} = scope, membership_id) do
    fn ->
      with {:ok, membership} <- get_member(scope, membership_id),
           :ok <- Access.authorize(scope, :"member.activate", membership) do
        if is_nil(membership.suspended_at) do
          {:ok, membership}
        else
          with {:ok, active} <-
                 membership
                 |> Ecto.Changeset.change(suspended_at: nil, suspended_by_id: nil)
                 |> Repo.update(),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"member.activate", active, %{
                   before: %{suspended_at: membership.suspended_at},
                   after: %{suspended_at: nil},
                   details: %{user_id: active.user_id, level: active.level}
                 }),
               :ok <- Edition.membership_changed(Repo, scope, :activated, membership, active) do
            {:ok, active}
          end
        end
      end
    end
    |> Repo.transact()
    |> broadcast_membership_change()
  end

  # A membership's entry names its person by their user id, in `details`, since the
  # membership of a removed member is gone.
  defp record_member(scope, :"member.remove" = action, %Membership{} = membership, nil) do
    data = %{before: %{level: membership.level}, details: %{user_id: membership.user_id}}
    with {:ok, _entry} <- Audit.record(Repo, scope, action, membership, data), do: :ok
  end

  defp record_member(scope, action, %Membership{} = old, %Membership{} = new) do
    case Audit.changed(old, new, [:level]) do
      nil ->
        :ok

      changes ->
        data = Map.put(changes, :details, %{user_id: new.user_id})
        with {:ok, _entry} <- Audit.record(Repo, scope, action, new, data), do: :ok
    end
  end

  @doc """
  lock_owners/1 holds the scope's organisation, with what the edition holds beside it,
  `FOR SHARE` (`Apiary.Access.lock_places/1`), then locks the organisation's owners' memberships
  `FOR UPDATE`, in the order of their ids: the lock order of docs/access.md, organisation
  rows before memberships. For a caller inside a transaction that counts the owners who
  remain, as a change of a level, a removal and a suspension do, so two of them cannot
  both see a second owner. `:ok`.
  """
  @spec lock_owners(Scope.t()) :: :ok
  # The caller is authorized after the lock, so a concurrent demotion of the caller is seen
  # too.
  def lock_owners(%Scope{organisation: %Organisation{id: organisation_id}} = scope) do
    :ok = Access.lock_places(scope)

    Repo.all(
      from m in Membership,
        where: m.organisation_id == ^organisation_id and m.level == :owner,
        order_by: [asc: m.id],
        select: m.id,
        lock: "FOR UPDATE"
    )

    :ok
  end

  def lock_owners(_scope), do: :ok

  defp get_member(scope, membership_id, opts \\ [])

  defp get_member(
         %Scope{organisation: %Organisation{id: organisation_id}},
         membership_id,
         opts
       ) do
    with {:ok, membership_id} <- Ecto.UUID.cast(membership_id),
         query =
           from(m in Membership,
             where: m.id == ^membership_id and m.organisation_id == ^organisation_id
           ),
         query = if(opts[:lock] == :share, do: lock(query, "FOR SHARE"), else: query),
         %Membership{} = membership <- Repo.one(query) do
      {:ok, membership}
    else
      _ -> {:error, :not_found}
    end
  end

  defp get_member(_scope, _membership_id, _opts), do: {:error, :not_found}

  @doc "The PubSub topic that announces changes to a user's memberships and their reach."
  def membership_topic(user_id), do: "membership:#{user_id}"

  defp broadcast_membership_change({:ok, %Membership{} = membership} = result) do
    announce(membership.user_id, membership.organisation_id)
    result
  end

  defp broadcast_membership_change(result), do: result

  defp announce(user_id, organisation_id) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      membership_topic(user_id),
      {:membership_changed, %{organisation_id: organisation_id}}
    )
  end

  # A deleted account holds no membership, so an owner here is a person; the account is
  # asked all the same, so a tombstone never counts as the owner who remains. Nor does a
  # suspended membership, or an account out of use: the one who remains must be able to act.
  defp ensure_not_last_owner(%Membership{level: :owner} = membership, new_level)
       when new_level != :owner do
    if other_active_owner?(membership), do: :ok, else: {:error, :last_owner}
  end

  defp ensure_not_last_owner(%Membership{}, _new_level), do: :ok

  @doc """
  other_active_owner?/1 says whether the organisation of `membership` has an owner other
  than its person who may act: whose membership is not suspended and whose account is in
  use, neither deleted nor stopped by the edition (`c:Apiary.Edition.active_accounts/2`).
  The last-owner rule asks it, as the database has it now; a caller that must keep the
  answer true locks the owners first (`set_member_level/3` does).
  """
  @spec other_active_owner?(%Membership{}) :: boolean
  def other_active_owner?(%Membership{} = membership) do
    from(m in Membership,
      join: u in assoc(m, :user),
      as: :account,
      where:
        m.organisation_id == ^membership.organisation_id and m.level == :owner and
          m.id != ^membership.id,
      where: is_nil(u.deleted_at) and is_nil(m.suspended_at)
    )
    |> Edition.active_accounts(:account)
    |> Repo.exists?()
  end

  @doc """
  sole_owned_organisations/2 is the organisations in use of which `user` is the only
  owner who may act: no other person, whose membership is not suspended and whose account
  is in use, is an owner there. The account
  page names them, and `Apiary.Accounts.delete_user/2` refuses while there is one, as
  `set_member_level/3` and `remove_member/2` refuse to leave an organisation without an
  owner. An organisation marked for deletion is not counted: it goes, owner or not.

  `lock: true`, for a caller inside a transaction, first holds every organisation the user
  owns `FOR SHARE`, then locks the owners' memberships of them, in the order of their ids,
  as a change of a level locks them (`lock_owners/1`): a concurrent demotion or removal of another owner waits, and what was
  counted stays true until the caller commits.
  """
  @spec sole_owned_organisations(%User{}, keyword) :: [%Organisation{}]
  def sole_owned_organisations(%User{id: user_id}, opts \\ []) do
    owned =
      from m in Membership,
        where: m.user_id == ^user_id and m.level == :owner,
        select: m.organisation_id

    # The lock order (docs/access.md): the organisations `FOR SHARE`, in the order of
    # `lock_order/1`; then their owners.
    if Keyword.get(opts, :lock, false) do
      order = Repo.all(from o in Organisation, where: o.id in subquery(owned)) |> lock_order()

      Repo.all(
        from o in Organisation,
          where: o.id in ^order,
          order_by: fragment("array_position(?, ?)", type(^order, {:array, Ecto.UUID}), o.id),
          select: o.id,
          lock: "FOR SHARE"
      )

      Repo.all(
        from m in Membership,
          where: m.level == :owner and m.organisation_id in subquery(owned),
          order_by: [asc: m.id],
          select: m.id,
          lock: "FOR UPDATE"
      )
    end

    others =
      from(m in Membership,
        join: u in assoc(m, :user),
        as: :account,
        where: m.organisation_id == parent_as(:organisation).id,
        where: m.level == :owner and m.user_id != ^user_id and is_nil(u.deleted_at),
        where: is_nil(m.suspended_at)
      )
      |> Edition.active_accounts(:account)

    Repo.all(
      from o in Organisation,
        as: :organisation,
        where: o.id in subquery(owned) and is_nil(o.deletion_marked_at),
        where: not exists(others),
        order_by: [asc: o.name, asc: o.id]
    )
  end

  # Several organisations in the lock order (docs/access.md): those the edition holds
  # another organisation after (`c:Apiary.Edition.places_to_lock/1`) first, so each comes
  # before the ones it holds, then the rest, each in the order of their ids.
  defp lock_order(organisations) do
    organisations
    |> Enum.sort_by(&{match?([_own], Edition.places_to_lock(&1)), &1.id})
    |> Enum.map(& &1.id)
  end

  @doc """
  marked_sole_owned_organisations/1 is the organisations marked for deletion of which
  `user` is the only owner: deleting their account leaves nobody who may cancel the
  deletion, which the account page says before it is done.
  """
  @spec marked_sole_owned_organisations(%User{}) :: [%Organisation{}]
  def marked_sole_owned_organisations(%User{id: user_id}) do
    others =
      from(m in Membership,
        join: u in assoc(m, :user),
        as: :account,
        where: m.organisation_id == parent_as(:organisation).id,
        where: m.level == :owner and m.user_id != ^user_id and is_nil(u.deleted_at),
        where: is_nil(m.suspended_at)
      )
      |> Edition.active_accounts(:account)

    Repo.all(
      from o in Organisation,
        as: :organisation,
        join: m in Membership,
        on: m.organisation_id == o.id and m.user_id == ^user_id and m.level == :owner,
        where: not is_nil(o.deletion_marked_at),
        where: not exists(others),
        order_by: [asc: o.name, asc: o.id]
    )
  end

  @doc """
  lock_memberships/1 locks every membership of `user` `FOR UPDATE`, in the order of their
  ids: for a caller inside a transaction that ends them, before it locks the account, as
  the lock order of docs/access.md has memberships before accounts. `:ok`.
  """
  @spec lock_memberships(%User{}) :: :ok
  def lock_memberships(%User{id: user_id}) do
    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id,
        order_by: [asc: m.id],
        select: m.id,
        lock: "FOR UPDATE"
    )

    :ok
  end

  @doc """
  end_memberships/2 deletes every membership of `user`, whose account is being deleted,
  and with each what hangs from it, each with its entry in its organisation's trail:
  `member.remove`, its level before, and in `details` the person's user id and the
  reason, `account_deleted`. `actor` gives the scope that acts in an organisation: the
  person's own, or the instance's for a release command. For
  `Apiary.Accounts.delete_user/2`, inside its transaction, which has checked
  `sole_owned_organisations/2` first; nobody is asked of `Apiary.Access`, since the
  account is the person's own. `{:ok, memberships}`, as they were, for
  `broadcast_membership_changes/1` once the transaction commits.
  """
  @spec end_memberships(%User{}, (%Organisation{} -> Scope.t())) ::
          {:ok, [%Membership{}]} | {:error, term}
  def end_memberships(%User{id: user_id}, actor) when is_function(actor, 1) do
    memberships =
      Repo.all(
        from m in Membership,
          where: m.user_id == ^user_id,
          order_by: [asc: m.id],
          preload: [:organisation],
          lock: "FOR UPDATE"
      )

    Enum.reduce_while(memberships, {:ok, memberships}, fn membership, ok ->
      data = %{
        before: %{level: membership.level},
        details: %{user_id: user_id, reason: "account_deleted"}
      }

      with {:ok, _deleted} <- Repo.delete(membership),
           {:ok, _entry} <-
             Audit.record(
               Repo,
               actor.(membership.organisation),
               :"member.remove",
               membership,
               data
             ) do
        {:cont, ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  broadcast_membership_changes/1 tells each membership's person that it changed, on
  `membership_topic/1`, so their open pages load their scope again, and leave a page they
  may no longer see. After the transaction that changed them has committed.
  """
  @spec broadcast_membership_changes([%Membership{}]) :: :ok
  def broadcast_membership_changes(memberships) do
    Enum.each(memberships, &broadcast_membership_change({:ok, &1}))
  end

  ## The instance's admins

  @doc """
  grant_instance_admin/2 makes `user` an owner of the instance's organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), an instance admin, for
  `Apiary.Release.grant_instance_admin/2`: a membership at
  `Apiary.Access.instance_admin_level/0` when they have none, their level made that when
  they have another, and an `instance_admin.grant` entry in that organisation's trail, by
  the instance, from `origin`, that names them by user id. Whoever runs a
  release command controls the instance, so no role is asked; whether the membership
  makes an instance admin is `Apiary.Access.instance_admin_membership?/1`'s answer.
  Nothing changes, and nothing is recorded, for an instance admin already.

  `{:ok, %{membership: membership, was: level, granted?: boolean}}`, `was` the level they
  had, nil for none, and `granted?` false when nothing changed;
  `{:error, :no_instance_organisation}` before the instance's first sign-up, and
  `{:error, :not_found}` for an account deleted meanwhile.
  """
  @spec grant_instance_admin(%User{}, Scope.origin()) ::
          {:ok, %{membership: %Membership{}, was: Membership.level() | nil, granted?: boolean}}
          | {:error, :no_instance_organisation | :not_found | term}
  def grant_instance_admin(%User{id: user_id}, origin \\ nil) do
    fn ->
      with {:ok, scope} <- instance_scope(origin),
           :ok <- lock_owners(scope),
           :ok <- lock_person(user_id) do
        admin = Access.instance_admin_level()

        membership = instance_membership(scope, user_id)

        cond do
          is_nil(membership) ->
            with {:ok, membership} <-
                   Repo.insert(
                     membership_changeset(scope.organisation, %User{id: user_id}, admin)
                   ),
                 {:ok, _entry} <-
                   Audit.record(Repo, scope, :"instance_admin.grant", membership, %{
                     after: %{level: admin},
                     details: %{user_id: user_id}
                   }),
                 do: {:ok, %{membership: membership, was: nil, granted?: true}}

          Access.instance_admin_membership?(membership) ->
            {:ok, %{membership: membership, was: membership.level, granted?: false}}

          true ->
            with {:ok, granted} <-
                   membership |> Membership.changeset(%{level: admin}) |> Repo.update(),
                 {:ok, _entry} <-
                   Audit.record(Repo, scope, :"instance_admin.grant", granted, %{
                     before: %{level: membership.level},
                     after: %{level: admin},
                     details: %{user_id: user_id}
                   }),
                 do: {:ok, %{membership: granted, was: membership.level, granted?: true}}
        end
      end
    end
    |> Repo.transact()
    |> tap(fn
      {:ok, %{membership: membership}} -> broadcast_membership_change({:ok, membership})
      _refused -> :ok
    end)
  end

  @doc """
  revoke_instance_admin/2 makes an instance admin a member of the instance's organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), for
  `Apiary.Release.revoke_instance_admin/1`: they are no instance admin any more, and stay
  in the organisation, where an owner removes them if they should leave. An
  `instance_admin.revoke` entry in its trail, by the instance, from `origin`, names them by
  user id; the edition is told, as of a demotion (`set_member_level/3`,
  `c:Apiary.Edition.membership_changed/5`). No role is asked; whether the membership makes an
  instance admin is `Apiary.Access.instance_admin_membership?/1`'s answer.

  `{:ok, membership}`; `{:error, :last_owner}` for its last owner, whose account is not
  deleted: the instance keeps an admin. `{:error, :not_owner}` for an account that is not
  an owner of it, and `{:error, :no_instance_organisation}` before the instance's first
  sign-up.
  """
  @spec revoke_instance_admin(%User{}, Scope.origin()) ::
          {:ok, %Membership{}}
          | {:error, :no_instance_organisation | :not_owner | :last_owner | term}
  def revoke_instance_admin(%User{id: user_id}, origin \\ nil) do
    fn ->
      with {:ok, scope} <- instance_scope(origin),
           :ok <- lock_owners(scope),
           membership = instance_membership(scope, user_id),
           true <- Access.instance_admin_membership?(membership) || {:error, :not_owner},
           :ok <- ensure_not_last_owner(membership, :member),
           {:ok, member} <- membership |> Membership.changeset(%{level: :member}) |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"instance_admin.revoke", member, %{
               before: %{level: membership.level},
               after: %{level: member.level},
               details: %{user_id: user_id}
             }),
           :ok <- Edition.membership_changed(Repo, scope, :level, membership, member) do
        {:ok, member}
      end
    end
    |> Repo.transact()
    |> broadcast_membership_change()
  end

  # The person's membership of the instance's organisation, with it, as
  # `Apiary.Access.instance_admin_membership?/1` asks it; nil without one.
  defp instance_membership(%Scope{organisation: organisation}, user_id) do
    case Repo.get_by(Membership, organisation_id: organisation.id, user_id: user_id) do
      %Membership{} = membership -> %{membership | organisation: organisation}
      nil -> nil
    end
  end

  # The instance, acting in its organisation, as a release command does.
  defp instance_scope(origin) do
    with id when is_binary(id) <- Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, organisation |> Scope.for_instance() |> Scope.put_origin(origin)}
    else
      _none -> {:error, :no_instance_organisation}
    end
  end

  # The person, while their account is not deleted, held `FOR SHARE`, as an acceptance
  # holds them: the deletion of the account waits, or is seen.
  defp lock_person(user_id) do
    if Repo.one(
         from u in User,
           where: u.id == ^user_id and is_nil(u.deleted_at),
           select: u.id,
           lock: "FOR SHARE"
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp normalise_level(level) when is_atom(level), do: level

  defp normalise_level(level) when is_binary(level) do
    Enum.find(Membership.levels(), level, &(Atom.to_string(&1) == level))
  end

  ## Invitations

  # An invitation holds the address of someone who has agreed to nothing, so it is kept
  # no longer than it is needed: it is deleted when it is accepted, once the membership it
  # became exists, in the same transaction; when it is revoked, or withdrawn because it
  # could not be delivered; when a new invitation to its address replaces it after it
  # expired; and by the daily sweep once it has been expired for 30 days
  # (`delete_old_invitations/2`). A row with `accepted_at` set is one an earlier release
  # kept after it was accepted, which the sweep deletes.

  @doc """
  The organisation's pending invitations (not accepted, not expired), newest first, each
  with the workspace it grants.
  """
  def list_invitations(%Scope{organisation: %Organisation{id: organisation_id}}) do
    now = DateTime.utc_now()

    Repo.all(
      from i in Invitation,
        where:
          i.organisation_id == ^organisation_id and is_nil(i.accepted_at) and i.expires_at > ^now,
        order_by: [desc: i.inserted_at, desc: i.id],
        preload: [:workspace]
    )
  end

  def change_invitation(invitation \\ %Invitation{}, attrs \\ %{}) do
    Invitation.changeset(invitation, attrs)
  end

  @doc """
  Invites an email address to the scope's workspace (`member.invite`), with the link built
  by `url_fun.(token)`: the invitation is sent from the workspace, and grants it. An
  invitation is the address and nothing else: its person joins as a member, and an owner
  changes their level afterwards; `attrs` gives `email` and nothing else is read. An owner
  or an admin invites; `{:error, :forbidden}` for a member.

  **With mail** (`Apiary.Mail.configured?/0`) the link is emailed, `{:ok, invitation}`, and
  the inviter's account is confirmed, as signing in with a mailed link confirms it:
  `{:error, :unconfirmed}` otherwise. **Without mail** nothing is sent: the invitation is
  kept, and its link is handed back for the inviter to copy and send themselves,
  `{:ok, invitation, {:link, url}}`, whether or not their account is confirmed, since no
  mail goes out in their name. The token is in that link and nowhere else: only its hash
  is stored, so the link cannot be shown again; `renew_invitation/4` makes a new one.

  Refused with an error on `:email`: an address that already belongs to a member of the
  organisation; an address with a pending invitation; an organisation with
  #{@max_pending_invitations} pending invitations; and an organisation that has made
  `Apiary.Instance.invitations_per_day/0` invitations in the last 24 hours, which says how
  many it may. That count is of the entries of the invitations counted against its
  allowance (`details.allowance_id`), a link copied, or made again with
  `renew_invitation/4`, as much as one emailed, in a rolling window by the database's
  clock, so an invitation accepted, revoked or deleted since still counts; one withdrawn
  because its email could not be delivered does not, as no mail was sent. Every invitation
  tried in those 24 hours, delivered or not, counts against #{@attempts_per_invitation}
  times as many, refused the same way when they are reached. Each organisation has its own
  allowance; an invitation the edition sends from another organisation counts against
  the one it names (`insert_invitation/3`). The organisation's row is locked while the
  invitation is counted and written, so two at once cannot both be the last one
  allowed.

  The invitation and its audit entry (`member.invite`) are committed first, and the email
  is sent after, so no transaction waits on the mail relay. An invitation that could not
  be delivered is then withdrawn, `{:error, :delivery_failed}`: deleted, in a second
  transaction, with an entry of `invitation.revoke` by the same person, its reason
  `undelivered`, when it is still pending then. One the invitee accepted meanwhile (the
  relay took the message and failed after) is kept and returned, `{:ok, invitation}`: it
  arrived. One an owner revoked meanwhile is gone already; neither writes an entry.
  Should the withdrawal itself fail, the invitation stays pending, undelivered:
  `{:error, :delivery_failed_pending}`, for an owner to revoke.

  An expired invitation to the same address, which would hold its pending place, is
  deleted with the new one's, an `invitation.revoke` entry each, their reason `expired`.
  The entries name an invitation, never the address.
  """
  @spec invite_member(Scope.t(), map, (String.t() -> String.t())) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :forbidden
             | :unconfirmed
             | :delivery_failed
             | :delivery_failed_pending}
  def invite_member(%Scope{} = scope, attrs, url_fun) when is_function(url_fun, 1) do
    %Scope{user: inviter, organisation: organisation, workspace: workspace} = scope
    {changeset, token} = new_invitation(scope, attrs)
    mail? = Mail.configured?()

    # Asked of the invitation as it would be: its workspace. An organisation's page without
    # a workspace has none to send it from.
    with %Workspace{} <- workspace || {:error, :not_found},
         :ok <-
           Access.authorize(scope, :"member.invite", Ecto.Changeset.apply_changes(changeset)),
         :ok <- ensure_confirmed(inviter, mail?),
         {:ok, invitation} <-
           Repo.transact(fn ->
             write_invitation(scope, changeset, :"member.invite", organisation)
           end) do
      hand_over(scope, invitation, token, url_fun, mail?)
    end
  end

  @doc """
  insert_invitation/3 writes an invitation to the scope's workspace, as `invite_member/3`
  does, for a caller inside a transaction that asked `Apiary.Access` itself, and sends it
  once it has committed (`send_invitation/4`). Options: `action:`, the action its entry
  records, `member.invite` unless the edition's; `allowance:`, the organisation whose
  allowance of invitations it counts against, the scope's unless another, whose row is
  locked `FOR NO KEY UPDATE` while it is counted, and which refuses while it is out of use
  (`c:Apiary.Edition.active_organisations/2`). With mail (`Apiary.Mail.configured?/0`) the
  inviter's account is confirmed, `{:error, :unconfirmed}` otherwise; without mail it
  need not be, as `invite_member/3` says. The entry names the allowance,
  `details.allowance_id`, which `renew_invitation/4` charges again.

  `{:ok, invitation, token}`, the token for `send_invitation/4` once the transaction has
  committed; `{:error, changeset}` for the refusals of `invite_member/3`, and
  `{:error, :forbidden}` for an allowance out of use.
  """
  @spec insert_invitation(Scope.t(), map, keyword) ::
          {:ok, %Invitation{}, String.t()}
          | {:error, Ecto.Changeset.t() | :not_found | :forbidden | :unconfirmed | term}
  def insert_invitation(%Scope{} = scope, attrs, opts \\ []) do
    action = Keyword.get(opts, :action, :"member.invite")
    allowance = Keyword.get(opts, :allowance) || scope.organisation
    {changeset, token} = new_invitation(scope, attrs)

    with %Workspace{} <- scope.workspace || {:error, :not_found},
         :ok <- ensure_confirmed(scope.user, Mail.configured?()),
         {:ok, invitation} <- write_invitation(scope, changeset, action, allowance) do
      {:ok, invitation, token}
    end
  end

  @doc """
  send_invitation/4 hands over `invitation`, written by `invite_member/3` or
  `insert_invitation/3`, with the link built by `url_fun.(token)`, once its transaction has
  committed, so no transaction waits on the mail relay. With mail
  (`Apiary.Mail.configured?/0`, asked as it is sent) the link is emailed:
  `{:ok, invitation}` when it was sent. One that could not be delivered is withdrawn, as
  `invite_member/3` says: `{:error, :delivery_failed}`, or
  `{:error, :delivery_failed_pending}` should the withdrawal fail too; one accepted
  meanwhile is `{:ok, invitation}`. Mail needs the inviter's account confirmed, asked as
  it is sent too, since mail may have been set after the invitation was written: one
  that is not gets `{:error, :unconfirmed}`, nothing is sent, and the invitation is
  withdrawn the same way. Without mail nothing is sent and nothing withdrawn:
  `{:ok, invitation, {:link, url}}`, the link for the inviter to copy, which the caller
  shows once and keeps nowhere else.
  """
  @spec send_invitation(Scope.t(), %Invitation{}, String.t(), (String.t() -> String.t())) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:error, :unconfirmed | :delivery_failed | :delivery_failed_pending}
  def send_invitation(%Scope{} = scope, %Invitation{} = invitation, token, url_fun)
      when is_function(url_fun, 1),
      do: hand_over(scope, invitation, token, url_fun, Mail.configured?())

  # The invitation emailed, with mail, or its link handed back, without.
  defp hand_over(_scope, invitation, token, url_fun, false = _mail?),
    do: {:ok, invitation, {:link, url_fun.(token)}}

  # Mailed, it needs a confirmed inviter, asked as it is sent: mail may have been set
  # since the invitation was written without it (`insert_invitation/3`). Refused, it is
  # withdrawn as one undelivered is, as nothing was sent.
  defp hand_over(scope, invitation, token, url_fun, true = _mail?) do
    with :ok <- ensure_confirmed(scope.user, true),
         :ok <- deliver_invitation(invitation, scope.organisation, url_fun.(token)) do
      {:ok, invitation}
    else
      refused_or_undelivered ->
        # An invitation nobody received must not occupy the pending slot.
        case withdraw_undelivered(scope, invitation) do
          {:ok, {:accepted, accepted}} -> {:ok, accepted}
          {:ok, _withdrawn_or_gone} -> undelivered(refused_or_undelivered, :delivery_failed)
          {:error, _reason} -> undelivered(refused_or_undelivered, :delivery_failed_pending)
        end
    end
  end

  defp undelivered({:error, :unconfirmed} = refused, _reason), do: refused
  defp undelivered(:error, reason), do: {:error, reason}

  @doc """
  renew_invitation/4 makes a new link for the pending invitation `invitation_id` of the
  scope's organisation (`invitation.renew`), for one whose link was lost: the same
  invitation, a new token and #{Invitation.validity_days()} days again from now. Only the
  new token's hash is stored, so the old link stops working at once. An owner or an admin
  renews any pending invitation of the organisation, whoever sent it and whichever
  workspace it grants; the edition may let others (`c:Apiary.Edition.check/3`).

  It counts as an invitation made: against the allowance the invitation was counted
  against when it was made, the one its latest entry names (`details.allowance_id`),
  whichever organisation the scope's person acts from, and refused as `invite_member/3`
  refuses one over the day's limit, `{:error, changeset}` with the same error on
  `:email`. Its entry is an `invitation.renew` in the invitation's organisation's trail,
  by the scope's person, naming that allowance. The allowance's organisation row is
  locked `FOR NO KEY UPDATE` first, then the invitation's `FOR UPDATE`.

  Then the link is handed over as `send_invitation/4` hands over an invitation's: without
  mail, `{:ok, invitation, {:link, url}}`, the link built by `url_fun.(token)`, to show
  once. With mail it is emailed, `{:ok, invitation}`, the inviter's account confirmed,
  `{:error, :unconfirmed}` otherwise; one that could not be delivered stays pending, as
  the old link is gone already: `{:error, :delivery_failed_pending}`, for an owner to
  renew again or revoke. `{:error, :not_found}` for an invitation that is not a pending
  one of the organisation, accepted, revoked or expired meanwhile included;
  `{:error, :forbidden}` for whom `Apiary.Access` refuses, and for an allowance out of use.

  **With `action:`**, for a caller that asked `Apiary.Access` itself, as
  `insert_invitation/3`'s does: `invitation.renew` is not asked, and the entry records
  `action` in its place, in the same trail, by the same person, naming the same
  allowance. The renewal is still charged to the allowance the invitation was counted
  against; there is no `allowance:`. The inviter's account is confirmed with mail, and
  the day's limit refuses, as without. Nothing is sent: `{:ok, invitation, token}`, the
  token for `send_invitation/4` once the caller's transaction has committed, so no
  transaction waits on the mail relay. Should `send_invitation/4` then fail to deliver
  it, it withdraws the invitation as it withdraws a new one, `{:error, :delivery_failed}`;
  without `action:` an undelivered renewal stays pending instead. Called inside the
  caller's own `Repo.transact/2`, it joins that transaction, and the caller may hold the
  allowance's organisation row already; a refusal then rolls the caller's back.
  """
  @spec renew_invitation(Scope.t(), term, (String.t() -> String.t()), keyword) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:ok, %Invitation{}, String.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :forbidden
             | :unconfirmed
             | :delivery_failed_pending}
  def renew_invitation(scope, invitation_id, url_fun, opts \\ [])

  def renew_invitation(
        %Scope{organisation: %Organisation{}} = scope,
        invitation_id,
        url_fun,
        opts
      )
      when is_function(url_fun, 1) and is_list(opts) do
    action = Keyword.get(opts, :action)
    {token, token_hash} = Invitation.build_token()
    mail? = Mail.configured?()

    Repo.transact(fn ->
      # The lock order (docs/access.md): the allowance's organisation row first, then the
      # invitation's. Read once, without a lock, to find the allowance, then again under
      # its lock.
      with %Invitation{} = found <-
             Repo.one(pending_invitation_query(scope, invitation_id, false)) ||
               {:error, :not_found},
           :ok <- authorize_renewal(scope, action, found),
           :ok <- ensure_confirmed(scope.user, mail?),
           %Organisation{} = allowance <- allowance_of(found),
           :ok <- lock_allowance(allowance),
           %Invitation{} = invitation <-
             Repo.one(pending_invitation_query(scope, found.id)) || {:error, :not_found},
           true <- Invitation.pending?(invitation) || {:error, :not_found},
           %Ecto.Changeset{valid?: true} <-
             invitation |> Ecto.Changeset.change() |> refuse_over_daily_limit(allowance),
           {:ok, renewed} <-
             invitation
             |> Ecto.Changeset.change(
               token_hash: token_hash,
               expires_at: DateTime.add(DateTime.utc_now(), Invitation.validity_days(), :day)
             )
             |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, action || :"invitation.renew", renewed, %{
               details: %{allowance_id: allowance.id}
             }) do
        {:ok, renewed}
      else
        %Ecto.Changeset{} = changeset -> {:error, %{changeset | action: :update}}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      # The caller hands it over once its transaction has committed.
      {:ok, renewed} when not is_nil(action) -> {:ok, renewed, token}
      {:ok, renewed} -> hand_over_renewed(scope, renewed, token, url_fun, mail?)
      {:error, _reason} = error -> error
    end
  end

  def renew_invitation(_scope, _invitation_id, _url_fun, _opts), do: {:error, :not_found}

  # Asked of `Apiary.Access` here, unless the caller asked it for an action of its own.
  defp authorize_renewal(scope, nil = _action, invitation),
    do: Access.authorize(scope, :"invitation.renew", invitation)

  defp authorize_renewal(_scope, _action, _invitation), do: :ok

  # A renewed invitation's new link, handed over as a new invitation's. Emailed and
  # undelivered, it is not withdrawn: its old link is gone, and it stays pending for an
  # owner to renew again or revoke.
  defp hand_over_renewed(scope, renewed, token, url_fun, true = _mail?) do
    case deliver_invitation(renewed, scope.organisation, url_fun.(token)) do
      :ok -> {:ok, renewed}
      :error -> {:error, :delivery_failed_pending}
    end
  end

  defp hand_over_renewed(scope, renewed, token, url_fun, false = mail?),
    do: hand_over(scope, renewed, token, url_fun, mail?)

  # The organisation whose allowance the invitation was counted against: the one its
  # latest entry that names one says, `member.invite`, the edition's, or a renewal's, in
  # the invitation's organisation's trail; the invitation's own organisation should the
  # trail no longer hold one.
  defp allowance_of(%Invitation{organisation_id: organisation_id} = invitation) do
    allowance_id =
      Repo.one(
        counted_entries(invitation)
        |> select([e], fragment("?->>'allowance_id'", e.details))
        |> limit(1)
      ) || organisation_id

    Repo.get(Organisation, allowance_id) || {:error, :forbidden}
  end

  # The invitation's entries that counted it against an allowance, each naming the one it
  # was counted against: the latest first.
  defp counted_entries(%Invitation{id: id, organisation_id: organisation_id}) do
    from e in Apiary.Audit.Entry,
      where: e.organisation_id == ^organisation_id and e.subject_id == ^id,
      where: e.subject_kind == "invitation",
      where: fragment("? \\? 'allowance_id'", e.details),
      order_by: [desc: e.inserted_at, desc: e.id]
  end

  # A new invitation to the scope's workspace, by the scope's person, and its URL token.
  defp new_invitation(
         %Scope{user: inviter, organisation: organisation, workspace: workspace},
         attrs
       ) do
    {token, token_hash} = Invitation.build_token()

    changeset =
      %Invitation{
        organisation_id: organisation.id,
        workspace_id: workspace && workspace.id,
        invited_by_id: inviter && inviter.id,
        token_hash: token_hash,
        expires_at: DateTime.add(DateTime.utc_now(), Invitation.validity_days(), :day)
      }
      |> Invitation.changeset(attrs)

    {changeset, token}
  end

  # The invitation and its entry, counted against `allowance`, inside the caller's
  # transaction.
  defp write_invitation(%Scope{organisation: organisation} = scope, changeset, action, allowance) do
    with %Ecto.Changeset{valid?: true} = changeset <-
           refuse_existing_member(changeset, organisation),
         :ok <- lock_allowance(allowance),
         %Ecto.Changeset{valid?: true} = changeset <-
           changeset
           |> refuse_over_daily_limit(allowance)
           |> refuse_over_pending_cap(organisation),
         :ok <- delete_expired_invitations(scope, Ecto.Changeset.get_field(changeset, :email)),
         {:ok, invitation} <- Repo.insert(changeset),
         {:ok, _entry} <-
           Audit.record(Repo, scope, action, invitation, %{
             details: %{allowance_id: allowance.id}
           }) do
      {:ok, invitation}
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      {:error, _reason} = error -> error
    end
  end

  # The invitation, as it is now, locked: a revocation or an acceptance of it waits, and
  # one that came first is seen. Still pending, it is deleted, and the trail says why: its
  # inviter revoked nothing, the mail relay refused it. Accepted meanwhile, the email did
  # arrive, whatever the relay answered: the invitation stands, and is gone, deleted by
  # its acceptance, whose entry in the trail says so. Revoked meanwhile, it is gone, and
  # its revocation is in the trail already. Not asked of
  # `Apiary.Access`: it undoes the caller's own invitation, which it was allowed a moment
  # ago. A withdrawal the database refuses leaves the invitation pending, and is logged;
  # `invite_member/3` says so, `{:error, :delivery_failed_pending}`.
  defp withdraw_undelivered(%Scope{} = scope, %Invitation{id: id} = invitation) do
    Repo.transact(fn ->
      case Repo.one(from i in Invitation, where: i.id == ^id, lock: "FOR UPDATE") do
        nil ->
          case accepted_at(invitation) do
            %DateTime{} = at -> {:ok, {:accepted, %{invitation | accepted_at: at}}}
            nil -> {:ok, :gone}
          end

        %Invitation{accepted_at: %DateTime{}} = accepted ->
          {:ok, {:accepted, accepted}}

        %Invitation{} = pending ->
          with {:ok, _deleted} <- Repo.delete(pending),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"invitation.revoke", pending, %{
                   details: undelivered_details(pending)
                 }) do
            {:ok, :withdrawn}
          end
      end
    end)
    |> case do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, _reason} = error ->
        Logger.error("invitation not withdrawn after a failed delivery invitation=#{id}")
        error
    end
  rescue
    # The database is away, or a statement failed: the kind of failure only.
    error ->
      Logger.error(
        "invitation not withdrawn after a failed delivery invitation=#{id} " <>
          "error=#{inspect(error.__struct__)}"
      )

      {:error, :not_withdrawn}
  end

  # A withdrawal's reason, and the entry it undoes, `entry_id`: the one that counted the
  # invitation's latest sending, which sent nothing (`refuse_over_daily_limit/2`).
  defp undelivered_details(invitation) do
    case Repo.one(counted_entries(invitation) |> select([e], e.id) |> limit(1)) do
      nil -> %{reason: "undelivered"}
      entry_id -> %{reason: "undelivered", entry_id: entry_id}
    end
  end

  # When the invitation was accepted, by its entry in the trail: an accepted invitation is
  # deleted, and the entry of its acceptance is what is left of it.
  defp accepted_at(%Invitation{id: id, organisation_id: organisation_id}) do
    Repo.one(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation_id and e.subject_id == ^id,
        where: e.subject_kind == "invitation" and e.action == "invitation.accept",
        select: e.inserted_at,
        limit: 1
    )
  end

  defp deliver_invitation(%Invitation{email: email}, organisation, url) do
    case UserNotifier.deliver_invitation(email, organisation, url) do
      {:ok, _email} -> :ok
      _error -> :error
    end
  rescue
    # The reason may quote the message, which carries the link: not logged.
    _exception -> :error
  end

  # Signing in with a mailed link confirms an account; an invitation emailed is mail the
  # instance sends for the inviter, so it needs one whose address is confirmed. Without
  # mail nothing is sent for them, and an unconfirmed account makes a link to copy.
  defp ensure_confirmed(_inviter, false = _mail?), do: :ok
  defp ensure_confirmed(%User{confirmed_at: %DateTime{}}, true = _mail?), do: :ok
  defp ensure_confirmed(_inviter, true = _mail?), do: {:error, :unconfirmed}

  # The organisation whose allowance the invitation counts against, or whose workspaces a
  # creation counts, its row locked `FOR NO KEY UPDATE`: two invitations of one allowance,
  # or two workspaces of one limit, are counted and written one after the other, while a
  # row that only references it, which takes `FOR KEY SHARE`, does not wait. Out of use
  # since it was asked (`c:Apiary.Edition.active_organisations/2`), it sends nothing, as it
  # would have been refused: read once the lock is held, in a statement of its own, since
  # what the edition stops it may keep in a table of its own, written under the
  # organisation's lock.
  defp lock_allowance(%Organisation{id: id}) do
    Repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR NO KEY UPDATE")

    if in_use?(id), do: :ok, else: {:error, :forbidden}
  end

  # Whether the organisation is there and in use as the edition says
  # (`c:Apiary.Edition.active_organisations/2`), as the database has it now.
  defp in_use?(id) do
    from(o in Organisation, as: :organisation, where: o.id == ^id, select: o.id)
    |> Edition.active_organisations(:organisation)
    |> Repo.exists?()
  end

  # The invitations counted against the allowance in the last 24 hours, by the database's
  # clock: the entries that sent them, each naming the allowance it was counted against,
  # `details.allowance_id`, whatever action and whatever organisation's trail it is in.
  # They outlive the invitations, deleted when they are accepted, revoked or long expired.
  # One withdrawn as undelivered sent no mail and is not counted against the day's
  # invitations; every attempt is counted against a ceiling of #{@attempts_per_invitation}
  # times as many, so an organisation cannot send to addresses that bounce without end.
  # The trail keeps an entry for 30 days at the least, far longer than the window.
  defp refuse_over_daily_limit(changeset, %Organisation{id: allowance_id}) do
    limit = Instance.invitations_per_day()
    attempts_limit = limit * @attempts_per_invitation

    # Its withdrawal, in the invitation's workspace and after it: on the trail's index of
    # `(workspace_id, subject_id, inserted_at)`. A withdrawal names the entry it undoes,
    # `details.entry_id`, and undoes that one alone: an invitation sent, then renewed and
    # withdrawn, still counts once. One written before withdrawals named it undoes every
    # earlier entry of its invitation.
    undelivered =
      from r in Apiary.Audit.Entry,
        where: r.workspace_id == parent_as(:invite).workspace_id,
        where: r.subject_id == parent_as(:invite).subject_id,
        where: r.inserted_at >= parent_as(:invite).inserted_at,
        where: r.organisation_id == parent_as(:invite).organisation_id,
        where: r.action == "invitation.revoke",
        where: fragment("?->>'reason'", r.details) == "undelivered",
        where:
          fragment(
            "NOT (? \\? 'entry_id') OR ?->>'entry_id' = ?::text",
            r.details,
            r.details,
            parent_as(:invite).id
          )

    # Only an invitation's entry names an allowance: the index of the entries that do
    # answers the count.
    {attempts, sent} =
      Repo.one(
        from e in Apiary.Audit.Entry,
          as: :invite,
          where: fragment("? \\? 'allowance_id'", e.details),
          where: e.inserted_at > fragment("timezone('UTC', now()) - interval '24 hours'"),
          where: fragment("?->>'allowance_id'", e.details) == ^allowance_id,
          select: {count(e.id), filter(count(e.id), not exists(undelivered))}
      )

    cond do
      sent >= limit ->
        Ecto.Changeset.add_error(
          changeset,
          :email,
          dgettext_noop(
            "errors",
            "was not invited: this organisation has made %{limit} invitations in the last 24 hours, as many as it may. Try again later."
          ),
          limit: limit,
          validation: :invitations_per_day
        )

      attempts >= attempts_limit ->
        Ecto.Changeset.add_error(
          changeset,
          :email,
          dgettext_noop(
            "errors",
            "was not invited: this organisation has tried to send %{limit} invitations in the last 24 hours, delivered or not, as many as it may. Try again later."
          ),
          limit: attempts_limit,
          validation: :invitation_attempts_per_day
        )

      true ->
        changeset
    end
  end

  defp refuse_over_pending_cap(%Ecto.Changeset{valid?: false} = changeset, _organisation),
    do: changeset

  defp refuse_over_pending_cap(changeset, %Organisation{id: organisation_id}) do
    now = DateTime.utc_now()

    pending =
      Repo.aggregate(
        from(i in Invitation,
          where:
            i.organisation_id == ^organisation_id and is_nil(i.accepted_at) and
              i.expires_at > ^now
        ),
        :count
      )

    if pending >= @max_pending_invitations,
      do:
        Ecto.Changeset.add_error(
          changeset,
          :email,
          dgettext_noop("errors", "too many pending invitations")
        ),
      else: changeset
  end

  defp refuse_existing_member(changeset, %Organisation{id: organisation_id}) do
    case Ecto.Changeset.get_field(changeset, :email) do
      nil ->
        changeset

      email ->
        member? =
          Repo.exists?(
            from m in Membership,
              join: u in assoc(m, :user),
              where: m.organisation_id == ^organisation_id and u.email == ^email
          )

        if member?,
          do:
            Ecto.Changeset.add_error(
              changeset,
              :email,
              dgettext_noop(
                "errors",
                "is already a member of this organisation"
              )
            ),
          else: changeset
    end
  end

  # An expired invitation still occupies the pending slot for its email; a new
  # invitation replaces it. Each deleted is an entry of the trail, by the person whose
  # invitation replaced it, as they asked for the deletion.
  defp delete_expired_invitations(
         %Scope{organisation: %Organisation{id: organisation_id}} = scope,
         email
       ) do
    now = DateTime.utc_now()

    {_count, expired} =
      Repo.delete_all(
        from i in Invitation,
          where:
            i.organisation_id == ^organisation_id and i.email == ^email and
              is_nil(i.accepted_at) and i.expires_at <= ^now,
          select: i
      )

    Enum.reduce_while(expired, :ok, fn invitation, :ok ->
      case Audit.record(Repo, scope, :"invitation.revoke", invitation, %{
             details: %{reason: "expired"}
           }) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Deletes a pending invitation (`invitation.revoke`): an owner's or an admin's, whoever
  sent it.
  """
  def revoke_invitation(%Scope{organisation: %Organisation{}} = scope, invitation_id) do
    Repo.transact(fn ->
      with %Invitation{} = invitation <- Repo.one(pending_invitation_query(scope, invitation_id)),
           :ok <- Access.authorize(scope, :"invitation.revoke", invitation),
           {:ok, revoked} <- Repo.delete(invitation),
           {:ok, _entry} <- Audit.record(Repo, scope, :"invitation.revoke", invitation) do
        {:ok, revoked}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  # The organisation's invitation `id`, not accepted, locked `FOR UPDATE` unless `lock?` is
  # false.
  defp pending_invitation_query(
         %Scope{organisation: %Organisation{id: organisation_id}},
         id,
         lock? \\ true
       ) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        query =
          from i in Invitation,
            where: i.id == ^id and i.organisation_id == ^organisation_id and is_nil(i.accepted_at)

        if lock?, do: lock(query, "FOR UPDATE"), else: query

      :error ->
        from i in Invitation, where: false
    end
  end

  @doc """
  The pending invitation behind a URL token, preloaded with organisation and workspace, or
  nil: nil too for an invitation into an organisation or a workspace marked for deletion,
  or into an organisation out of use (`c:Apiary.Edition.active_organisations/2`), which
  accepts no one.
  """
  @spec get_invitation_by_token(term) :: %Invitation{} | nil
  def get_invitation_by_token(token) when is_binary(token) do
    token_hash = Invitation.hash_token(token)
    now = DateTime.utc_now()

    from(i in Invitation,
      join: o in assoc(i, :organisation),
      as: :organisation,
      join: w in assoc(i, :workspace),
      where: i.token_hash == ^token_hash and is_nil(i.accepted_at) and i.expires_at > ^now,
      where: is_nil(o.deletion_marked_at) and is_nil(w.deletion_marked_at),
      preload: [organisation: o, workspace: w]
    )
    |> Edition.active_organisations(:organisation)
    |> Repo.one()
  end

  def get_invitation_by_token(_token), do: nil

  defp pending_invitation(%Invitation{} = invitation),
    do: Repo.preload(invitation, [:organisation, :workspace])

  defp pending_invitation(token), do: get_invitation_by_token(token)

  @doc """
  Accepts an invitation on behalf of a signed-in user, the scope's: a membership at the
  level the edition gives (`c:Apiary.Edition.accepting/3`), a member unless it says
  otherwise, which it may refuse, `{:error, :invalid}`; what the edition adds once the
  membership exists (`c:Apiary.Edition.accepted/4`); the invitation deleted; and the audit
  entry of `invitation.accept`, by the user, in the workspace it was sent from, which
  names the membership it became. Takes the URL token or the invitation
  `get_invitation_by_token/1` returned earlier; the invitation is claimed inside the
  transaction, so it makes one membership however many callers hold it: the others get
  `{:error, :invalid}`, and so does an account deleted meanwhile, or an invitation whose
  organisation or workspace was marked for deletion, or whose organisation the edition
  stopped, or that was renewed since it was found, whose old link no longer works. The token is the check: nobody's role is asked. A user alone, not a scope, is
  accepted as a scope without an origin.
  """
  @spec accept_invitation(%User{} | Scope.t(), %Invitation{} | String.t()) ::
          {:ok, %Membership{}} | {:error, :invalid | :already_member | term}
  def accept_invitation(%User{} = user, invitation_or_token),
    do: accept_invitation(Scope.for_user(user), invitation_or_token)

  def accept_invitation(%Scope{user: %User{} = user} = scope, invitation_or_token) do
    case pending_invitation(invitation_or_token) do
      nil ->
        {:error, :invalid}

      %Invitation{} = invitation ->
        Repo.transact(fn ->
          if Repo.exists?(
               from m in Membership,
                 where: m.organisation_id == ^invitation.organisation_id and m.user_id == ^user.id
             ) do
            {:error, :already_member}
          else
            here = %{
              scope
              | organisation: invitation.organisation,
                workspace: invitation.workspace
            }

            # The lock order (docs/access.md): the edition, which may hold the organisation
            # more strongly, then the organisation, which its marking waits for, or came
            # first and is seen; then the account, then the invitation.
            with {:ok, level} <- Edition.accepting(Repo, invitation, user),
                 :ok <- lock_open_organisation(invitation),
                 {:ok, claimed} <- lock_person_then_claim(user, invitation),
                 {:ok, membership} <-
                   Repo.insert(membership_changeset(invitation.organisation, user, level)),
                 :ok <- Edition.accepted(Repo, here, invitation, membership),
                 {:ok, _deleted} <- Repo.delete(claimed),
                 {:ok, _entry} <-
                   Audit.record(
                     Repo,
                     here,
                     :"invitation.accept",
                     invitation,
                     accepted(membership)
                   ) do
              {:ok, membership}
            end
          end
        end)
    end
  end

  # The invitation's organisation, while it is in use: `FOR SHARE`, which its marking and
  # what the edition stops wait for, then whether it is in use, read under the lock. Gone
  # or stopped, the invitation is `{:error, :invalid}`, as an expired one is.
  defp lock_open_organisation(%Invitation{organisation_id: id}) do
    Repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR SHARE")

    if in_use?(id), do: :ok, else: {:error, :invalid}
  end

  # The person who accepts, while their account is not deleted, held `FOR SHARE`: the
  # deletion of the account takes it `FOR NO KEY UPDATE`, so the two are one after the
  # other, and
  # a deleted account never becomes a member. Then the invitation.
  defp lock_person_then_claim(%User{id: user_id}, %Invitation{} = invitation) do
    case lock_person(user_id) do
      :ok -> claim_invitation(invitation)
      {:error, :not_found} -> {:error, :invalid}
    end
  end

  # One invitation makes one membership: the row is claimed by locking it while it is
  # still pending, and its organisation and workspace are not marked for deletion, so of
  # two concurrent accepts exactly one finds it. The other waits on the lock, and finds
  # nothing once the first has deleted it. A revocation, and the withdrawal of an
  # undelivered invitation, lock the same row. The organisation is held already
  # (`lock_open_organisation/1`), so its marking, and what the edition stops, wait for the
  # claim, or came first and are seen; the workspace's `FOR KEY SHARE` holds it against
  # its purge's deletion, and its marking is read as the claim finds it. It is claimed by
  # the token it was found by: renewed since (`renew_invitation/4`), it has another, and
  # the old link claims nothing.
  defp claim_invitation(%Invitation{id: id, token_hash: token_hash}) do
    now = DateTime.utc_now()

    claim =
      from(i in Invitation,
        join: o in assoc(i, :organisation),
        as: :organisation,
        join: w in assoc(i, :workspace),
        where: i.id == ^id and i.token_hash == ^token_hash,
        where: is_nil(i.accepted_at) and i.expires_at > ^now,
        where: is_nil(o.deletion_marked_at) and is_nil(w.deletion_marked_at),
        lock: fragment("FOR UPDATE OF ? FOR KEY SHARE OF ?, ?", i, o, w)
      )
      |> Edition.active_organisations(:organisation)

    case Repo.one(claim) do
      %Invitation{} = claimed -> {:ok, claimed}
      nil -> {:error, :invalid}
    end
  end

  @expired_days 30

  @doc """
  delete_old_invitations/2 deletes the scope's organisation's invitations that have been
  expired for #{@expired_days} days, each with an entry of `invitation.revoke`, the
  reason `expired`, by the instance, in one transaction; and the rows an
  earlier release kept of accepted invitations, whose acceptance is their entry already.
  `{:ok, count}`, the invitations deleted. The daily sweep's
  (`Apiary.Organisations.InvitationSweep`), whose scope is the instance's; nobody else
  may, `{:error, :forbidden}`.

  Options: `now:`, the time the period is counted back from, for tests.
  """
  @spec delete_old_invitations(Scope.t(), keyword) :: {:ok, non_neg_integer} | {:error, term}
  def delete_old_invitations(scope, opts \\ [])

  def delete_old_invitations(
        %Scope{instance: true, organisation: %Organisation{id: organisation_id} = organisation} =
          scope,
        opts
      ) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cutoff = DateTime.add(now, -@expired_days * 86_400, :second)

    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"invitation.revoke", organisation) do
        {_count, expired} =
          Repo.delete_all(
            from i in Invitation,
              where:
                i.organisation_id == ^organisation_id and is_nil(i.accepted_at) and
                  i.expires_at <= ^cutoff,
              select: i
          )

        {accepted, _} =
          Repo.delete_all(
            from i in Invitation,
              where: i.organisation_id == ^organisation_id and not is_nil(i.accepted_at)
          )

        Enum.reduce_while(expired, {:ok, length(expired) + accepted}, fn invitation, ok ->
          case Audit.record(Repo, scope, :"invitation.revoke", invitation, %{
                 details: %{reason: "expired"}
               }) do
            {:ok, _entry} -> {:cont, ok}
            {:error, _changeset} = error -> {:halt, error}
          end
        end)
      end
    end)
  end

  def delete_old_invitations(%Scope{}, _opts), do: {:error, :forbidden}
end
