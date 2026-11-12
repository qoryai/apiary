defmodule ApiaryPro.Reach do
  @moduledoc """
  Reach is how the edition lets a person into an organisation beyond their membership
  there, and which workspaces a member reaches. What `Apiary.Access` asks of the edition
  about reach is answered here (`c:Apiary.Edition.reach/1`, `reload/2`,
  `places_to_lock/1`, `every_workspace_levels/0`, `reaches_workspace?/3`,
  `reached_workspaces/2`).

  A person reaches an organisation in one of three ways, which the scope's `reach`
  carries:

  1. **Their membership there**, at its level (`reach` nil): what they may change there is
     its role's.
  2. **Their membership in its operator**, when it is a client (`{:operator, membership}`,
     with their membership in the operator): an operator provides a harness its clients
     run, and keeps it working, so its people read everything in each client, at any
     level they hold in the operator: every workspace, the runs, their terminals, the
     policy and the trail. They change nothing there: the role `reader`
     (`ApiaryPro.Access`). A person of the operator who holds a membership in the client
     too changes what that membership's role allows, in the workspaces it reaches, and
     reads every workspace besides.
  3. **As an instance admin** (`:instance`), in an organisation other than the instance
     organisation they reach neither way: the role `reader` too. They change another
     organisation only by the instance actions, in the instance organisation, whatever
     its kind.

  A suspended operator's people do not read its clients, and a suspended membership in
  the operator, or a suspended account, is no source of reach.

  **Workspace access.** An owner and an admin reach every workspace of their organisation
  (`every_workspace_levels/0`); a member reaches the workspaces they were added to, each a
  row of workspace access (`ApiaryPro.WorkspaceAccess.Row`), which the scope
  carries for its workspace in its `edition` map, under `:workspace_access`
  (`ApiaryPro.WorkspaceAccess.of/1`). A reader reaches every workspace.

  `reload/2` reads each source again, and fails closed: a person removed from the operator
  reads its clients no more, and a client that was dropped is read by its people no more.
  """

  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Suspensions, Tenants, WorkspaceAccess}
  alias ApiaryPro.Tenants.Tenant

  @every_workspace [:owner, :admin]

  @doc """
  every_workspace_levels/0 is the levels that reach every workspace of their
  organisation with no workspace access: owner and admin. A member reaches the workspaces
  they were added to.
  """
  @spec every_workspace_levels() :: [Membership.level()]
  def every_workspace_levels, do: @every_workspace

  @doc """
  reach/1 finds how the scope's person reaches the organisation just put into the scope
  (`c:Apiary.Edition.reach/1`): their membership in its operator when it is a client, which
  wins over a membership there for what they read; their membership there alone; or, with
  neither, as an instance admin, in an organisation other than the instance organisation.
  The organisation is put in carrying its tenant (`ApiaryPro.Tenants.put/1`) and, in its
  `edition` under `:owner_suspended`, whether no owner of it may act
  (`ApiaryPro.Suspensions.owner_suspended?/1`). `:error` when they reach it no way.
  """
  @spec reach(Scope.t()) :: {:ok, Scope.t()} | :error
  def reach(%Scope{user: %User{id: user_id}, organisation: %Organisation{}} = scope) do
    organisation = Tenants.put(scope.organisation)
    own = scope.membership
    via = operator_membership(organisation, user_id, preload: true)

    reach =
      cond do
        via ->
          {:operator, via}

        own ->
          nil

        # In this order: `instance_admin?/1` calls this function again, for the instance
        # organisation, where the first test stops it.
        not Tenants.instance_organisation?(organisation) and Apiary.Access.instance_admin?(scope) ->
          :instance

        true ->
          :unreached
      end

    case reach do
      :unreached ->
        :error

      reach ->
        organisation =
          put_owner_suspended(organisation, Suspensions.owner_suspended?(organisation))

        own = own && %{own | organisation: organisation}
        {:ok, %{scope | organisation: organisation, membership: own, reach: reach}}
    end
  end

  def reach(_scope), do: :error

  @doc """
  owner_suspended?/1 says whether no owner may act in `organisation`, as `reach/1` put it
  on the organisation it carries into the scope; false for one it did not.
  """
  @spec owner_suspended?(%Organisation{} | nil) :: boolean
  def owner_suspended?(%Organisation{edition: %{owner_suspended: true}}), do: true
  def owner_suspended?(_organisation), do: false

  defp put_owner_suspended(%Organisation{edition: edition} = organisation, suspended?),
    do: %{organisation | edition: Map.put(edition, :owner_suspended, suspended?)}

  @doc """
  reload/2 reads again what the edition put on the scope (`c:Apiary.Edition.reload/2`), after
  `Apiary.Access.reload/2` has read the membership and the marks: the organisation's
  tenant, its kind, whether it is the instance organisation, its operator and its
  suspension, which under `lock: :share` the organisation's row, held `FOR SHARE` already,
  keeps as it is read (`ApiaryPro.Tenants`, Locks); the reach, for a client or a person
  without a membership there, from each source: their membership in the operator, read
  without a lock, and under `lock: :share` once the operator's people lock is held
  `FOR SHARE` (`ApiaryPro.Tenants.lock_rows/1`), so a change of the operator's people
  waits for the write, or came first and is read here; and with neither membership
  whether they are an instance admin; and their workspace access to the scope's
  workspace, where their level needs one, `FOR SHARE` under `lock: :share`, which a
  removal from the workspace waits for.
  """
  @spec reload(Scope.t(), keyword) :: Scope.t()
  def reload(%Scope{user: %User{}, organisation: %Organisation{id: id}} = scope, opts) do
    lock? = opts[:lock] == :share

    case Repo.one(
           from o in Organisation,
             left_join: t in Tenant,
             on: t.organisation_id == o.id,
             where: o.id == ^id,
             select: {o.id, t}
         ) do
      nil ->
        WorkspaceAccess.put(%{scope | reach: nil}, nil)

      {_id, tenant} ->
        organisation =
          Tenants.put_tenant(scope.organisation, tenant || %Tenant{organisation_id: id})

        %{scope | organisation: organisation}
        |> reach_now()
        |> workspace_access_now(lock?)
    end
  end

  def reload(scope, _opts), do: scope

  # An organisation with no operator, reached through a membership alone, has no reach of
  # the edition's to read again.
  defp reach_now(%Scope{user: %User{id: user_id}, organisation: organisation} = scope) do
    if is_nil(scope.reach) and match?(%Membership{}, scope.membership) and
         not Tenants.client?(organisation) do
      scope
    else
      via = operator_membership(organisation, user_id)

      reach =
        cond do
          via -> {:operator, via}
          scope.membership -> nil
          Apiary.Access.instance_admin?(scope) -> :instance
          true -> nil
        end

      %{scope | reach: reach}
    end
  end

  # The person's access to the scope's workspace, where their level needs one.
  defp workspace_access_now(scope, lock?) do
    row =
      case {Apiary.Access.level(scope), scope.workspace} do
        {level, %{id: workspace_id}} when not is_nil(level) and level not in @every_workspace ->
          from(a in ApiaryPro.WorkspaceAccess.Row,
            where:
              a.organisation_id == ^scope.organisation.id and a.workspace_id == ^workspace_id and
                a.user_id == ^scope.user.id
          )
          |> share(lock?)
          |> Repo.one()

        _every_or_none ->
          nil
      end

    WorkspaceAccess.put(scope, row)
  end

  defp share(query, true), do: lock(query, "FOR SHARE")
  defp share(query, false), do: query

  # operator_membership/3 is the person's membership in the organisation's operator, when
  # it is a client, and the operator is an operator, in use and not suspended, while
  # neither the membership nor the account is suspended: a suspended operator's people
  # reach none of its clients. Read without a lock: under `lock: :share` the operator's
  # people lock covers it (`reload/2`). For `ApiaryPro.Features.hidden/1` too, which asks
  # it of a scope that carries no reach.
  @doc false
  @spec operator_membership(%Organisation{}, Ecto.UUID.t(), keyword) :: %Membership{} | nil
  def operator_membership(organisation, user_id, opts \\ []) do
    case Tenants.operator_id(organisation) do
      nil -> nil
      operator_id -> operator_membership_in(operator_id, user_id, opts)
    end
  end

  defp operator_membership_in(operator_id, user_id, opts) do
    query =
      from m in Membership,
        join: o in Organisation,
        as: :operator,
        on: o.id == m.organisation_id,
        join: t in Tenant,
        on: t.organisation_id == o.id,
        join: u in User,
        as: :account,
        on: u.id == m.user_id,
        where: m.organisation_id == ^operator_id and m.user_id == ^user_id,
        where: t.kind == :operator and is_nil(o.deletion_marked_at),
        where: is_nil(m.suspended_at)

    query =
      if opts[:preload],
        do: from([m, operator: o] in query, preload: [organisation: o]),
        else: query

    query
    |> Suspensions.active_organisations(:operator)
    |> Suspensions.active_accounts(:account)
    |> Repo.one()
  end

  @doc """
  instance_organisation_id/0 is the id of the instance organisation, whose owners are the
  instance admins, of either kind (`c:Apiary.Edition.instance_organisation_id/0`); nil
  before the instance's first sign-up.
  """
  @spec instance_organisation_id() :: Ecto.UUID.t() | nil
  def instance_organisation_id, do: Tenants.instance_organisation_id()

  @doc """
  places_to_lock/1 is the organisations a write in `organisation` holds `FOR SHARE`
  (`c:Apiary.Edition.places_to_lock/1`), in the lock order: the organisation, then its
  operator when it is a client, a client before its operator.
  """
  @spec places_to_lock(%Organisation{}) :: [Ecto.UUID.t()]
  def places_to_lock(%Organisation{id: id} = organisation) do
    case Tenants.operator_id(organisation) do
      nil -> [id]
      operator_id -> [id, operator_id]
    end
  end

  @doc """
  reaches_workspace?/3 says whether the scope's person, a member, reaches the workspace
  `workspace_id` (`c:Apiary.Edition.reaches_workspace?/3`), as the scope carries it: through
  the organisation's operator, which reads every workspace, or by the row of workspace
  access the scope carries for it, which must be theirs, in this organisation.
  """
  @spec reaches_workspace?(Scope.t(), Ecto.UUID.t(), keyword) :: boolean
  def reaches_workspace?(scope, workspace_id, _opts),
    do: operator_level(scope) != nil or access?(scope, workspace_id)

  @doc """
  reached_workspaces/2 narrows a query over the workspaces, each asked for a membership
  at member (`c:Apiary.Edition.reached_workspaces/2`), to those it was added to, with the row
  of workspace access merged into each under `:workspace_access`; for a scope that reads
  every workspace through the organisation's operator, every workspace stays, with the
  row where there is one.
  """
  @spec reached_workspaces(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Query.t()
  def reached_workspaces(query, scope) do
    if operator_level(scope) do
      from [workspace: w, membership: m] in query,
        left_join: a in ApiaryPro.WorkspaceAccess.Row,
        as: :workspace_access,
        on:
          a.organisation_id == w.organisation_id and a.workspace_id == w.id and
            a.user_id == m.user_id,
        select_merge: %{workspace_access: a}
    else
      from [workspace: w, membership: m] in query,
        join: a in ApiaryPro.WorkspaceAccess.Row,
        as: :workspace_access,
        on:
          a.organisation_id == w.organisation_id and a.workspace_id == w.id and
            a.user_id == m.user_id,
        select_merge: %{workspace_access: a}
    end
  end

  @doc """
  operator_level/1 is the level of the scope's person in the operator of the scope's
  organisation, a client, through which they read it; nil where the scope carries no such
  reach. It counts only inside the operator.
  """
  @spec operator_level(Scope.t() | nil) :: Membership.level() | nil
  def operator_level(%Scope{
        user: %User{id: user_id},
        organisation: %Organisation{} = organisation,
        reach: {:operator, %Membership{organisation_id: via_id, user_id: user_id} = via}
      }) do
    if via_id == Tenants.operator_id(organisation), do: via.level
  end

  def operator_level(_scope), do: nil

  # in_client/2 is `Apiary.Accounts.Scope.in_organisation/2` for an entry the scope's
  # person writes in `client` from its operator's pages: the membership they act from goes
  # with it, in the scope's `edition` under `:acted_from`, for the entry to say they acted
  # through the operator (`acted_through_operator?/1`). A scope already moved into the
  # client keeps the one it carries.
  @doc false
  @spec in_client(Scope.t(), %Organisation{}) :: Scope.t()
  def in_client(%Scope{} = scope, %Organisation{} = client) do
    acted_from = scope.membership || scope.edition[:acted_from]
    scoped = Scope.in_organisation(scope, client)

    case acted_from do
      %Membership{} -> %{scoped | edition: %{acted_from: acted_from}}
      nil -> scoped
    end
  end

  # acted_through_operator?/1 says whether the person of a scope `in_client/2` made acted
  # in the client through its operator (`ApiaryPro.Access.through_operator?/1`): from the
  # membership in the operator they acted from and their membership in the client, read
  # without a lock, none where they have none or it is suspended. False for any other
  # scope, and for a membership in another organisation than the client's operator. It
  # reads the two levels alone, so no scope with the operator's reach leaves it.
  @doc false
  @spec acted_through_operator?(Scope.t()) :: boolean
  def acted_through_operator?(%Scope{
        user: %User{id: user_id},
        organisation: %Organisation{id: client_id} = client,
        membership: nil,
        reach: nil,
        edition: %{acted_from: %Membership{user_id: user_id, organisation_id: via_id} = via}
      }) do
    if is_binary(via_id) and via_id == Tenants.operator_id(client) do
      own =
        Repo.one(
          from m in Membership,
            where: m.organisation_id == ^client_id and m.user_id == ^user_id,
            where: is_nil(m.suspended_at),
            select: m.level
        )

      ApiaryPro.Access.through_operator_at?(via.level, own)
    else
      false
    end
  end

  def acted_through_operator?(_scope), do: false

  @doc """
  instance_reach?/1 says whether the scope carries an instance admin's reach, in an
  organisation other than the instance organisation, which they reach neither through a
  membership there nor through its operator.
  """
  @spec instance_reach?(Scope.t() | nil) :: boolean
  def instance_reach?(%Scope{
        user: %User{},
        reach: :instance,
        organisation: %Organisation{} = organisation
      }),
      do: not Tenants.instance_organisation?(organisation)

  def instance_reach?(_scope), do: false

  @doc """
  own_reaches?/2 says whether the person's membership reaches the workspace of
  `subject`: always, for what the organisation owns; for a workspace's, when their level
  reaches every workspace, or the scope carries their access to it. True without a
  membership, where the role answers.
  """
  @spec own_reaches?(Scope.t(), Apiary.Access.subject() | nil) :: boolean
  def own_reaches?(scope, subject) do
    case Apiary.Access.place(subject) do
      {_organisation_id, workspace_id} when is_binary(workspace_id) ->
        case Apiary.Access.level(scope) do
          nil -> true
          level -> level in @every_workspace or access?(scope, workspace_id)
        end

      _organisation_or_nowhere ->
        true
    end
  end

  # The person's row of workspace access the scope carries, for this workspace of this
  # organisation.
  defp access?(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           membership: %Membership{user_id: user_id}
         } = scope,
         workspace_id
       ) do
    match?(
      %ApiaryPro.WorkspaceAccess.Row{
        organisation_id: ^organisation_id,
        workspace_id: ^workspace_id,
        user_id: ^user_id
      },
      WorkspaceAccess.of(scope)
    )
  end

  defp access?(_scope, _workspace_id), do: false
end
