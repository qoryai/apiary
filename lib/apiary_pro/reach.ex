defmodule ApiaryPro.Reach do
  @moduledoc """
  Reach is how the edition lets a person into an organisation beyond their membership
  there, and which workspaces a member reaches. What `Apiary.Access` asks of the edition
  about reach is answered here (`c:Apiary.Edition.reach/1`, `reload/2`,
  `places_to_lock/1`, `every_workspace_levels/0`, `reaches_workspace?/3`,
  `reached_workspaces/2`, `reaches_all_workspaces?/1`).

  A person reaches an organisation in one of three ways, which the scope's `reach`
  carries:

  1. **Their membership there**, at its level (`reach` nil): what they may change there is
     its role's.
  2. **Their membership in the operator of some of its workspaces**
     (`{:operator, operated}`, `operated` a map of each such workspace's id to their
     membership in its operator, `ApiaryPro.WorkspaceOperators`): an operator operates
     single workspaces of an organisation, and its people reach those workspaces alone,
     at any level they hold in the operator, and no other workspace of it. What they may
     there is `ApiaryPro.Access`'s answer. A person of the operator who holds a membership
     in the organisation too reaches the workspaces that membership reaches besides.
  3. **As an instance admin** (`:instance`), in an organisation other than the instance
     organisation they reach neither way: the role `reader`, in every workspace. They
     change another organisation only by the instance actions, in the instance
     organisation, whatever its kind. An instance admin who reaches some workspaces of it
     through their operators, with no membership there, keeps both: the reach
     `{:operator, operated}`, and `instance_reach: true` in the scope's `edition` map, so
     they read every workspace (`instance_reach?/1`).

  A suspended operator's people reach none of its workspaces, and a suspended membership
  in the operator, or a suspended account, is no source of reach.

  **Workspace access.** An owner and an admin reach every workspace of their organisation
  (`every_workspace_levels/0`); a member reaches the workspaces they were added to, each a
  row of workspace access (`ApiaryPro.WorkspaceAccess.Row`), which the scope
  carries for its workspace in its `edition` map, under `:workspace_access`
  (`ApiaryPro.WorkspaceAccess.of/1`). A reader reaches every workspace.

  `reload/2` reads each source again, and fails closed: a person removed from the operator
  reaches its workspaces no more, and a workspace whose link ended is reached by the
  operator's people no more.
  """

  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.{Suspensions, Tenants, WorkspaceAccess, WorkspaceOperators}
  alias ApiaryPro.Operators.WorkspaceOperator
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
  (`c:Apiary.Edition.reach/1`): their membership in the operators of some of its
  workspaces, which wins over a membership there for what they read in those workspaces;
  their membership there alone; or, with neither, as an instance admin, in an organisation
  other than the instance organisation. An instance admin with no membership there keeps
  that reach beside the reach through the operators, as `instance_reach: true` in the
  scope's `edition` map. The organisation put into the scope has its tenant
  (`ApiaryPro.Tenants.put/1`), the links of its workspaces
  (`ApiaryPro.WorkspaceOperators.put/1`) and, in its `edition` under `:owner_suspended`,
  whether no owner of it may act (`ApiaryPro.Suspensions.owner_suspended?/1`). `:error`
  when they reach it no way.
  """
  @spec reach(Scope.t()) :: {:ok, Scope.t()} | :error
  def reach(%Scope{user: %User{id: user_id}, organisation: %Organisation{}} = scope) do
    organisation = scope.organisation |> Tenants.put() |> WorkspaceOperators.put()
    own = scope.membership
    via = operator_memberships(organisation, user_id, preload: true)

    reach =
      cond do
        via != %{} ->
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
        scope = %{scope | organisation: organisation, membership: own, reach: reach}
        {:ok, put_instance_reach(scope, via != %{} and is_nil(own) and instance_admin?(scope))}
    end
  end

  def reach(_scope), do: :error

  # Whether the person is an instance admin in an organisation other than the instance
  # organisation. In this order: `Apiary.Access.instance_admin?/1` calls `reach/1` again,
  # for the instance organisation, where the first test stops it.
  defp instance_admin?(%Scope{organisation: organisation} = scope),
    do: not Tenants.instance_organisation?(organisation) and Apiary.Access.instance_admin?(scope)

  # The scope with `instance_reach` in its `edition` map set, or removed.
  defp put_instance_reach(%Scope{edition: edition} = scope, true),
    do: %{scope | edition: Map.put(edition || %{}, :instance_reach, true)}

  defp put_instance_reach(%Scope{edition: edition} = scope, false),
    do: %{scope | edition: Map.delete(edition || %{}, :instance_reach)}

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
  tenant, its kind, whether it is the instance organisation, its suspension and the links
  of its workspaces, which under `lock: :share` the organisation's row, held `FOR SHARE`
  already, keeps as they are read (`ApiaryPro.Tenants`, Locks;
  `ApiaryPro.WorkspaceOperators`, Locks); the reach, for an organisation with operated
  workspaces or a person without a membership there, from each source: their memberships
  in the operators of its workspaces, read without a lock, and under `lock: :share` once
  the operators' people locks are held `FOR SHARE` (`ApiaryPro.Tenants.lock_rows/1`), so a
  change of an operator's people waits for the write, or came first and is read here; and
  with neither membership whether they are an instance admin; and their workspace access
  to the scope's workspace, where their level needs one, `FOR SHARE` under `lock: :share`,
  which a removal from the workspace waits for.
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
          scope.organisation
          |> Tenants.put_tenant(tenant || %Tenant{organisation_id: id})
          |> WorkspaceOperators.put()

        %{scope | organisation: organisation}
        |> reach_now()
        |> workspace_access_now(lock?)
    end
  end

  def reload(scope, _opts), do: scope

  # An organisation with no operated workspace, reached through a membership alone, has
  # no reach of the edition's to read again.
  defp reach_now(%Scope{user: %User{id: user_id}, organisation: organisation} = scope) do
    if is_nil(scope.reach) and match?(%Membership{}, scope.membership) and
         WorkspaceOperators.operated(organisation) == %{} do
      scope
    else
      via = operator_memberships(organisation, user_id)

      reach =
        cond do
          via != %{} -> {:operator, via}
          scope.membership -> nil
          Apiary.Access.instance_admin?(scope) -> :instance
          true -> nil
        end

      scope = %{scope | reach: reach}

      put_instance_reach(
        scope,
        via != %{} and is_nil(scope.membership) and instance_admin?(scope)
      )
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

  # operator_memberships/3 is the person's memberships in the operators of the
  # organisation's workspaces, by the id of each workspace such an operator operates
  # (`ApiaryPro.WorkspaceOperators`), where the operator is an operator, in use and not
  # suspended, while neither the membership nor the account is suspended: a suspended
  # operator's people reach none of its workspaces. Read without a lock: under
  # `lock: :share` the operators' people locks cover it (`reload/2`).
  @doc false
  @spec operator_memberships(%Organisation{}, Ecto.UUID.t(), keyword) :: %{
          Ecto.UUID.t() => %Membership{}
        }
  def operator_memberships(%Organisation{id: organisation_id} = organisation, user_id, opts \\ []) do
    if is_nil(organisation_id) or WorkspaceOperators.operated(organisation) == %{} do
      %{}
    else
      query =
        from l in WorkspaceOperator,
          join: m in Membership,
          on: m.organisation_id == l.operator_id,
          join: o in Organisation,
          as: :operator,
          on: o.id == m.organisation_id,
          join: t in Tenant,
          on: t.organisation_id == o.id,
          join: u in User,
          as: :account,
          on: u.id == m.user_id,
          where: l.organisation_id == ^organisation_id and m.user_id == ^user_id,
          where: t.kind == :operator and is_nil(o.deletion_marked_at),
          where: is_nil(m.suspended_at),
          select: {l.workspace_id, m, o}

      query
      |> Suspensions.active_organisations(:operator)
      |> Suspensions.active_accounts(:account)
      |> Repo.all()
      |> Map.new(fn {workspace_id, membership, operator} ->
        {workspace_id,
         if(opts[:preload], do: %{membership | organisation: operator}, else: membership)}
      end)
    end
  end

  # operator_membership/3 is one of the person's memberships in the operators of the
  # organisation's workspaces (`operator_memberships/3`), the first by its operator's id;
  # nil where they have none. For `ApiaryPro.Features`, which asks whether there is one.
  @doc false
  @spec operator_membership(%Organisation{}, Ecto.UUID.t(), keyword) :: %Membership{} | nil
  def operator_membership(organisation, user_id, opts \\ []) do
    organisation
    |> operator_memberships(user_id, opts)
    |> Map.values()
    |> Enum.min_by(& &1.organisation_id, fn -> nil end)
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
  (`c:Apiary.Edition.places_to_lock/1`), in the lock order: the organisation, then the
  operators of its workspaces, read now, in the order of their ids: an organisation
  before the operators of its workspaces.
  """
  @spec places_to_lock(%Organisation{}) :: [Ecto.UUID.t()]
  def places_to_lock(%Organisation{id: id}),
    do: [id | WorkspaceOperators.operator_ids_of(id)]

  @doc """
  reaches_workspace?/3 says whether the scope's person, a member, reaches the workspace
  `workspace_id` (`c:Apiary.Edition.reaches_workspace?/3`), from the scope as it is: through
  the operator of that workspace, or by the row of workspace access the scope has for
  it, which must be theirs, in this organisation.
  """
  @spec reaches_workspace?(Scope.t(), Ecto.UUID.t(), keyword) :: boolean
  def reaches_workspace?(scope, workspace_id, _opts),
    do: operator_level(scope, workspace_id) != nil or access?(scope, workspace_id)

  @doc """
  reached_workspaces/2 narrows a query over the workspaces to those the person reaches
  (`c:Apiary.Edition.reached_workspaces/2`). Asked for a membership at member, the
  workspaces it was added to, with the row of workspace access merged into each under
  `:workspace_access`, and, for a scope that reaches workspaces through their operators,
  those workspaces too, with the row where there is one. Asked with no membership, for a
  scope that reaches the organisation through the operators of some of its workspaces,
  those workspaces alone; for any other such scope, every workspace.
  """
  @spec reached_workspaces(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Query.t()
  def reached_workspaces(query, scope) do
    query = Ecto.Queryable.to_query(query)
    operated = limited_to(scope)

    cond do
      not has_named_binding?(query, :membership) and operated == nil ->
        query

      not has_named_binding?(query, :membership) ->
        from [workspace: w] in query, where: w.id in ^operated

      operated == nil ->
        from [workspace: w, membership: m] in query,
          join: a in ApiaryPro.WorkspaceAccess.Row,
          as: :workspace_access,
          on:
            a.organisation_id == w.organisation_id and a.workspace_id == w.id and
              a.user_id == m.user_id,
          select_merge: %{workspace_access: a}

      true ->
        from [workspace: w, membership: m] in query,
          left_join: a in ApiaryPro.WorkspaceAccess.Row,
          as: :workspace_access,
          on:
            a.organisation_id == w.organisation_id and a.workspace_id == w.id and
              a.user_id == m.user_id,
          where: not is_nil(a.user_id) or w.id in ^operated,
          select_merge: %{workspace_access: a}
    end
  end

  @doc """
  reaches_all_workspaces?/1 says whether the reach in the scope, without a membership
  that reaches them all, lets its person into every workspace of the organisation
  (`c:Apiary.Edition.reaches_all_workspaces?/1`): an instance admin's does; the reach
  through the operators of some of its workspaces does not.
  """
  @spec reaches_all_workspaces?(Scope.t() | nil) :: boolean
  def reaches_all_workspaces?(scope), do: limited_to(scope) == nil

  # The ids of the workspaces the scope's reach is limited to: those it reaches through
  # their operators, but for an instance admin's, who reaches every workspace; nil for a
  # reach limited to none.
  defp limited_to(scope) do
    if instance_reach?(scope), do: nil, else: operated_ids(scope)
  end

  # The ids of the workspaces the scope reaches through their operators, for a scope that
  # has that reach for its organisation; nil for any other.

  defp operated_ids(%Scope{
         organisation: %Organisation{},
         reach: {:operator, operated}
       })
       when is_map(operated),
       do: Map.keys(operated)

  defp operated_ids(_scope), do: nil

  @doc """
  operator_membership/1 is the scope's person's membership in the operator of the scope's
  workspace, through which they reach it; nil where the scope has no such reach for
  its workspace, or has no workspace.
  """
  @spec operator_membership(Scope.t() | nil) :: %Membership{} | nil
  def operator_membership(%Scope{workspace: %Workspace{id: workspace_id}} = scope),
    do: operator_membership_for(scope, workspace_id)

  def operator_membership(_scope), do: nil

  @doc """
  operator_level/1 is the level of the scope's person in the operator of the scope's
  workspace, through which they reach it; nil where the scope has no such reach for
  its workspace, or has no workspace. It counts only inside the operator.
  """
  @spec operator_level(Scope.t() | nil) :: Membership.level() | nil
  def operator_level(scope) do
    case operator_membership(scope) do
      %Membership{level: level} -> level
      nil -> nil
    end
  end

  @doc """
  operator_level/2 is `operator_level/1` for the workspace `workspace_id` of the scope's
  organisation; nil for nil.
  """
  @spec operator_level(Scope.t() | nil, Ecto.UUID.t() | nil) :: Membership.level() | nil
  def operator_level(scope, workspace_id) do
    case operator_membership_for(scope, workspace_id) do
      %Membership{level: level} -> level
      nil -> nil
    end
  end

  @doc """
  operator_reach?/1 says whether the scope has a reach through the operators of some
  workspaces of its organisation, whatever its workspace.
  """
  @spec operator_reach?(Scope.t() | nil) :: boolean
  def operator_reach?(scope), do: operated_ids(scope) not in [nil, []]

  # The person's membership in the operator of the workspace `workspace_id`, as it is in
  # the scope: theirs, and in the operator that operates it as the scope's organisation
  # has its links.
  defp operator_membership_for(
         %Scope{
           user: %User{id: user_id},
           organisation: %Organisation{} = organisation,
           reach: {:operator, operated}
         },
         workspace_id
       )
       when is_map(operated) and is_binary(workspace_id) do
    with %Membership{user_id: ^user_id, organisation_id: via_id} = via <-
           Map.get(operated, workspace_id),
         ^via_id <- WorkspaceOperators.operator_id(organisation, workspace_id) do
      via
    else
      _none -> nil
    end
  end

  defp operator_membership_for(_scope, _workspace_id), do: nil

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
  instance_reach?/1 says whether the scope has an instance admin's reach, in an
  organisation other than the instance organisation where they have no membership:
  `:instance`, or the reach through the operators of some of its workspaces with
  `instance_reach: true` in the scope's `edition` map.
  """
  @spec instance_reach?(Scope.t() | nil) :: boolean
  def instance_reach?(%Scope{
        user: %User{},
        reach: :instance,
        organisation: %Organisation{} = organisation
      }),
      do: not Tenants.instance_organisation?(organisation)

  def instance_reach?(%Scope{
        user: %User{},
        reach: {:operator, _operated},
        edition: %{instance_reach: true},
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
