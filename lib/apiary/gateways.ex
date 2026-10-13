defmodule Apiary.Gateways do
  @moduledoc """
  Gateways answers where a gateway stands, and which gateway a node's or a node pool's
  recorded choice resolves to.

  A **gateway** is a node of kind `:gateway` (`Apiary.Nodes.Node`, `ng_…`): it holds a
  separate access key and enrols as a node does. It lives at a **level** (`level/1`):

  - at a workspace, `{:workspace, id}`: it may serve that workspace alone;
  - at an organisation, `{:organisation, id}`, with no workspace: it may serve every
    workspace of its organisation, and every workspace of the organisations an edition
    names (`c:Apiary.Edition.served_organisations/1`). The core's edition names none.

  A workspace's levels, most specific first (`levels/1`), are the workspace's, its
  organisation's, then those of the organisations whose gateways an edition lets serve it
  (`c:Apiary.Edition.serving_organisations/1`), in the edition's order. Nothing here
  assumes that an organisation-level gateway serves its organisation's workspaces
  alone: each question asks the two seams.

  A node or a node pool records a **choice** (`gateway_choice`): `:direct`; `:default`,
  the default gateway its workspace resolves (`default_gateway_for/1`); or `:named`, one
  gateway it names (`gateway_id`). The choice is checked when it is saved
  (`Apiary.Nodes`), and `resolve/1` answers where it leads from the records as they are
  when it is asked. A run's registration asks it (`Apiary.Runs.Registration`): the run
  goes directly, or through the gateway it resolves to, which then attaches the run
  (`Apiary.Runs.Attach`). A change of choice applies to the registrations after it; a
  run already registered keeps its gateway.

  - `may_serve?/2` says whether a gateway may serve a workspace: a gateway in use at one
    of the workspace's levels.
  - `default_gateway_for/1` is the workspace's default gateway: the default of the most
    specific level that has one, or none.
  - `resolve/1` is where a node's choice leads now: directly, to a gateway, or nowhere,
    with the reason.
  - `chosen/1` is the gateway a node's choice names now, whether or not it holds an
    active key: the one a page names beside the node.
  - `serves/1` is the workspaces a gateway may serve.
  - `gateway_choices/1` is the gateways a node of a workspace may name, by level.
  - `delete_blockers/1` is what stops a gateway from being deleted.

  **The default mark.** Each level marks at most one of its gateways as its default
  (`default_gateway`, a partial unique index per workspace and one per organisation). A
  gateway becomes its level's default by itself, as it is made, only when no default
  resolves for it at its level or after it (`default_resolves?/1`): for a
  workspace-level gateway, no default resolves for its workspace at all; for an
  organisation-level one, its organisation has none, and no workspace it may serve
  resolves a default at a level after its organisation. So making a gateway never moves
  a node. Otherwise a person marks one, and the mark moves
  (`Apiary.Nodes.make_default_gateway/2`).

  A gateway is deleted only when nothing points to it and no run goes through it
  (`delete_blockers/1`): no node names it, wherever the node is; no node on `:default`
  resolves to it now, in any workspace it may serve; and no run through it is live or
  waiting. After a deletion no node moves; when a workspace it served resolves no default
  any more and gateways remain at the deleted gateway's level, the oldest of them becomes
  the level's default (`needs_default_after_deletion?/1`, `oldest_at/2`).

  **The runs that hold a gateway.** A run goes through the gateway its registration
  resolved to (`gateway_id` of `Apiary.Runs.Run`), and holds it while it is:

  - **live**: attached (`attached_at` set) and not ended. A run has ended when its state
    is completed, failed, cancelled or lost; when its exit arrived (`exited_at`); when its
    starter gave its outcome (`outcome_state`); or when retention pruned its events
    (`events_pruned_at`);
  - **waiting**: registered for the gateway and not attached (`attached_at` nil), not
    ended as above, not lost, and its attach window still open (`attach_by` not before
    now).

  These are the rules by which an attach finds a run ended or its window closed
  (`Apiary.Runs.Attach`). A lost run holds nothing, though a later heartbeat through the
  gateway would bring it back while the gateway is in use. A deletion revokes the
  gateway's keys, so no request through it is verified once the deletion commits; one
  verified before may still be stored, and a run it brings back is found lost again by
  the lost-run check (`Apiary.Runs.Liveness`), as nothing follows it.

  **The locks.** A change of the gateways, of their default marks, or of a node's choice
  takes its locks first in the transaction, before any other row lock (`lock/1`), at one
  point, through `Apiary.Organisations.lock_organisations/2`:

  - a change at a workspace (a workspace-level gateway, or a node or node pool, whose
    choice is checked against the gateways of every level of its workspace) holds its
    organisation and the organisations that serve it (`serving_organisations/1`)
    `FOR SHARE`, then the workspace's row `FOR NO KEY UPDATE`;
  - a change of an organisation-level gateway holds its organisation
    `FOR NO KEY UPDATE`, and the organisations it serves (`served_organisations/1`)
    `FOR SHARE`.

  So two changes at one workspace take turns on its row, and a change at an organisation
  takes turns with every change at a workspace it may serve: a choice is checked against
  the gateways as they are, and a deletion against the nodes as they are. Then a change
  of a node holds the node's row `FOR UPDATE`. A deletion holds the gateway's row
  `FOR UPDATE` while it reads the runs that hold it; a registration through the gateway
  and an attach by it read the gateway's row `FOR SHARE` before they store anything, and
  refuse a gateway that is deleted. So the two take turns on the row: either the deletion
  finds the run, or the registration or attach finds the gateway deleted.

  Every question about a gateway's access key goes through
  `Apiary.AccessKeys.active_key?/1`, which keeps to the keys a verified request could use.
  """

  import Ecto.Query, warn: false

  alias Apiary.{AccessKeys, Edition, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run

  @typedoc """
  A level (`levels/1`): a workspace, or an organisation.
  """
  @type level :: {:workspace, Ecto.UUID.t()} | {:organisation, Ecto.UUID.t()}
  @typedoc """
  Where a node's choice leads (`resolve/1`): directly, to a gateway, or nowhere:

  - `:no_default_gateway`: the node chose the default, and none resolves for its workspace;
  - `:gateway_not_serving`: the gateway it names may no longer serve its workspace, is
    deleted, or is gone;
  - `:gateway_without_key`: the gateway it goes through has no active access key;
  - `:gateway_key`: the node is a gateway, which chooses none.
  """
  @type resolution ::
          :direct
          | {:gateway, Node.t()}
          | {:error,
             :no_default_gateway | :gateway_not_serving | :gateway_without_key | :gateway_key}

  @typedoc """
  What stops a gateway from being deleted (`delete_blockers/1`): the nodes that point to
  it, by name or by the default, and the runs through it that are live or waiting.
  """
  @type blockers :: %{nodes: [Node.t()], runs: [Run.t()]}

  ## Levels

  @doc """
  levels/1 is the levels of `workspace` whose default its nodes resolve to, most specific
  first: the workspace's, its organisation's, then those of the organisations an edition
  names whose organisation-level gateways may serve it
  (`c:Apiary.Edition.serving_organisations/1`), in its order.
  """
  @spec levels(%Workspace{}) :: [level, ...]
  def levels(%Workspace{id: id, organisation_id: organisation_id}) do
    [{:workspace, id} | Enum.map(chain(organisation_id), &{:organisation, &1})]
  end

  @doc "level/1 is the level `gateway` lives at: its workspace, or its organisation."
  @spec level(Node.t()) :: level
  def level(%Node{kind: :gateway, workspace_id: workspace_id}) when is_binary(workspace_id),
    do: {:workspace, workspace_id}

  def level(%Node{kind: :gateway, workspace_id: nil, organisation_id: organisation_id})
      when is_binary(organisation_id),
      do: {:organisation, organisation_id}

  @doc """
  serving_organisations/1 is the other organisations whose organisation-level gateways
  may serve the workspaces of `organisation_id`, in the order their defaults resolve
  (`c:Apiary.Edition.serving_organisations/1`); none in the core's edition.
  """
  @spec serving_organisations(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def serving_organisations(organisation_id),
    do: organisation_id |> Edition.serving_organisations() |> others(organisation_id)

  @doc """
  served_organisations/1 is the other organisations whose workspaces the
  organisation-level gateways of `organisation_id` may serve
  (`c:Apiary.Edition.served_organisations/1`); none in the core's edition.
  """
  @spec served_organisations(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def served_organisations(organisation_id),
    do: organisation_id |> Edition.served_organisations() |> others(organisation_id)

  # The edition never names the organisation itself; should it, it is left out.
  defp others(ids, organisation_id),
    do: ids |> Enum.reject(&(&1 == organisation_id)) |> Enum.uniq()

  # The organisations whose defaults a workspace of `organisation_id` resolves through,
  # in order: its own, then those that serve it.
  defp chain(organisation_id), do: [organisation_id | serving_organisations(organisation_id)]

  ## The locks

  @doc """
  lock/1 takes the locks of a change of gateways, default marks or nodes' choices, for
  the rest of the transaction, first, before any other row lock (see the moduledoc): for
  a change at `workspace`, its organisation and those that serve it `FOR SHARE`, then the
  workspace's row `FOR NO KEY UPDATE`; for a change of an organisation-level gateway,
  `{:organisation, organisation_id}`, the organisation `FOR NO KEY UPDATE` and those it
  serves `FOR SHARE`. The organisation rows are taken in one statement
  (`Apiary.Organisations.lock_organisations/2`). Raises, the transaction usable, when
  Postgres refuses the lock.
  """
  @spec lock(%Workspace{} | {:organisation, Ecto.UUID.t()}) :: :ok
  def lock(%Workspace{id: id, organisation_id: organisation_id}) do
    hold(chain(organisation_id), :share)

    Repo.one(from w in Workspace, where: w.id == ^id, select: w.id, lock: "FOR NO KEY UPDATE")

    :ok
  end

  def lock({:organisation, organisation_id}) when is_binary(organisation_id) do
    hold([organisation_id | served_organisations(organisation_id)], fn
      ^organisation_id -> :no_key_update
      _served -> :share
    end)
  end

  @doc """
  lock_for/2 is `lock/1` for a change of `node`, from the page of `scope`: the node's
  organisation for an organisation-level gateway, else the scope's workspace.
  """
  @spec lock_for(Scope.t(), Node.t()) :: :ok
  def lock_for(%Scope{}, %Node{kind: :gateway, workspace_id: nil} = gateway),
    do: lock(level(gateway))

  def lock_for(%Scope{workspace: %Workspace{} = workspace}, %Node{}), do: lock(workspace)

  defp hold(ids, mode) do
    case Organisations.lock_organisations(ids, mode) do
      {:ok, _held} -> :ok
      {:error, error} -> raise error
    end
  end

  ## What a gateway may serve

  @doc """
  may_serve?/2 says whether `gateway` may serve `workspace`: a gateway in use at one of
  the workspace's levels (`levels/1`). Asked when a node's choice is saved, by
  `resolve/1`, and by a run's registration and attach.
  """
  @spec may_serve?(Node.t(), %Workspace{}) :: boolean
  def may_serve?(%Node{kind: :gateway, deleted_at: nil} = gateway, %Workspace{} = workspace) do
    case level(gateway) do
      {:workspace, id} ->
        id == workspace.id and gateway.organisation_id == workspace.organisation_id

      {:organisation, organisation_id} ->
        organisation_id == workspace.organisation_id or
          organisation_id in serving_organisations(workspace.organisation_id)
    end
  end

  def may_serve?(_node, _workspace), do: false

  @doc """
  serves/1 is the workspaces `gateway` may serve, by name: a workspace-level gateway's
  workspace; an organisation-level gateway's every workspace of its organisation and of
  the organisations it serves (`served_organisations/1`). None for a gateway that is
  deleted, or a node that is not a gateway. It is never on the wire: a gateway's
  discovery document lists no workspaces (`ApiaryWeb.Contract.Configuration`).
  """
  @spec serves(Node.t()) :: [%Workspace{}]
  def serves(%Node{kind: :gateway, deleted_at: nil} = gateway) do
    gateway
    |> serves_query()
    |> order_by([w], asc: w.name, asc: w.id)
    |> Repo.all()
  end

  def serves(%Node{}), do: []

  defp serves_query(gateway) do
    case level(gateway) do
      {:workspace, id} ->
        from w in Workspace, where: w.id == ^id and w.organisation_id == ^gateway.organisation_id

      {:organisation, organisation_id} ->
        ids = [organisation_id | served_organisations(organisation_id)]
        from w in Workspace, where: w.organisation_id in ^ids
    end
  end

  @doc """
  gateway_choices/1 is the gateways a node of the scope's workspace may name: every
  gateway in use that may serve the workspace (`may_serve?/2`), by level, most specific
  first (`levels/1`), then by name.
  """
  @spec gateway_choices(Scope.t()) :: [Node.t()]
  def gateway_choices(%Scope{
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{organisation_id: organisation_id} = workspace
      }) do
    levels = levels(workspace)
    organisations = for {:organisation, id} <- levels, do: id

    from(n in Node,
      where:
        (n.organisation_id == ^organisation_id and n.workspace_id == ^workspace.id) or
          (is_nil(n.workspace_id) and n.organisation_id in ^organisations),
      where: n.kind == :gateway and is_nil(n.deleted_at),
      order_by: [asc: n.name, asc: n.id]
    )
    |> Repo.all()
    |> Enum.sort_by(&Enum.find_index(levels, fn level -> level == level(&1) end))
  end

  ## The default

  @doc """
  default_gateway_for/1 is the default gateway of `workspace`, most specific level first
  (`levels/1`): the workspace's default, else its organisation's, else that of each
  organisation that serves it, in turn. Nil when no level has one.
  """
  @spec default_gateway_for(%Workspace{}) :: Node.t() | nil
  def default_gateway_for(%Workspace{id: id, organisation_id: organisation_id} = workspace) do
    levels = levels(workspace)
    organisations = for {:organisation, organisation} <- levels, do: organisation

    defaults =
      from(n in Node,
        where:
          (n.organisation_id == ^organisation_id and n.workspace_id == ^id) or
            (is_nil(n.workspace_id) and n.organisation_id in ^organisations),
        where: n.kind == :gateway and n.default_gateway and is_nil(n.deleted_at)
      )
      |> Repo.all()

    Enum.find_value(levels, fn level -> Enum.find(defaults, &(level(&1) == level)) end)
  end

  @doc """
  default_at/2 is the default gateway `level` marks, or nil; `workspace` is the workspace
  a workspace's level is of.
  """
  @spec default_at(level, %Workspace{} | nil) :: Node.t() | nil
  def default_at({:workspace, workspace_id}, %Workspace{organisation_id: organisation_id}) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: n.kind == :gateway and n.default_gateway and is_nil(n.deleted_at)
    )
    |> Repo.one()
  end

  def default_at({:organisation, organisation_id}, _workspace) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and is_nil(n.workspace_id),
      where: n.kind == :gateway and n.default_gateway and is_nil(n.deleted_at)
    )
    |> Repo.one()
  end

  @doc """
  oldest_at/2 is the oldest gateway in use at `level`, the one that becomes the level's
  default when a workspace it serves resolves none; nil when none. `workspace` is the
  workspace a workspace's level is of.
  """
  @spec oldest_at(level, %Workspace{} | nil) :: Node.t() | nil
  def oldest_at({:workspace, workspace_id}, %Workspace{organisation_id: organisation_id}) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: n.kind == :gateway and is_nil(n.deleted_at),
      order_by: [asc: n.inserted_at, asc: n.id],
      limit: 1
    )
    |> Repo.one()
  end

  def oldest_at({:organisation, organisation_id}, _workspace) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and is_nil(n.workspace_id),
      where: n.kind == :gateway and is_nil(n.deleted_at),
      order_by: [asc: n.inserted_at, asc: n.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  default_resolves?/1 says whether a default resolves for a new gateway at `level`, at
  that level or after it, so that marking it would move a node: for a workspace's level,
  whether any default resolves for the workspace (`default_gateway_for/1`); for an
  organisation's, whether the organisation has a default, or a workspace it serves (the
  organisation's, or one of `served_organisations/1`) resolves one at a level after
  it, with no default before it. A gateway made at `level` is made its default only when
  none does (`Apiary.Nodes`).
  """
  @spec default_resolves?(level | {:workspace, %Workspace{}}) :: boolean
  def default_resolves?({:workspace, %Workspace{} = workspace}),
    do: default_gateway_for(workspace) != nil

  def default_resolves?({:organisation, organisation_id}) do
    served = [organisation_id | served_organisations(organisation_id)]
    chains = Map.new(served, &{&1, chain(&1)})
    defaults = with_default(chains |> Map.values() |> List.flatten())

    MapSet.member?(defaults, organisation_id) or
      Enum.any?(chains, fn {_served, chain} ->
        case Enum.split_while(chain, &(&1 != organisation_id)) do
          {before, [_level | later]} ->
            not Enum.any?(before, &MapSet.member?(defaults, &1)) and
              Enum.any?(later, &MapSet.member?(defaults, &1))

          {_chain, []} ->
            false
        end
      end)
  end

  @doc """
  needs_default_after_deletion?/1 says whether, once `gateway` is deleted, a workspace it
  served resolves no default any more while another gateway remains at its level: then
  the oldest gateway left at the level becomes its default (`oldest_at/2`,
  `Apiary.Nodes.delete_node/2`). Asked of the records as they are after the deletion,
  under the deletion's locks.
  """
  @spec needs_default_after_deletion?(Node.t()) :: boolean
  def needs_default_after_deletion?(%Node{kind: :gateway} = gateway) do
    case level(gateway) do
      {:workspace, workspace_id} ->
        workspace = Repo.get(Workspace, workspace_id)
        workspace != nil and default_gateway_for(workspace) == nil

      {:organisation, organisation_id} ->
        served = [organisation_id | served_organisations(organisation_id)]
        chains = Map.new(served, &{&1, chain(&1)})
        defaults = with_default(chains |> Map.values() |> List.flatten())

        Enum.any?(chains, fn {served, chain} ->
          not Enum.any?(chain, &MapSet.member?(defaults, &1)) and
            has_workspace_without_default?(served)
        end)
    end
  end

  # The organisations of `ids` that have an organisation-level default in use.
  defp with_default(ids) do
    from(n in Node,
      where: is_nil(n.workspace_id) and n.organisation_id in ^Enum.uniq(ids),
      where: n.kind == :gateway and n.default_gateway and is_nil(n.deleted_at),
      select: n.organisation_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The workspaces that mark a default of their own.
  defp own_defaults do
    from d in Node,
      where: not is_nil(d.workspace_id),
      where: d.kind == :gateway and d.default_gateway and is_nil(d.deleted_at),
      select: d.workspace_id
  end

  defp has_workspace_without_default?(organisation_id) do
    from(w in Workspace,
      where: w.organisation_id == ^organisation_id,
      where: w.id not in subquery(own_defaults())
    )
    |> Repo.exists?()
  end

  ## Resolution

  @doc """
  resolve/1 is where the choice of `node` leads, from the records as they are now
  (`t:resolution/0`): `:direct`; `{:gateway, gateway}`, the gateway it names or its
  workspace's default, when that gateway may serve the node's workspace and has an active
  access key; or `{:error, reason}`. A gateway chooses none (`:gateway_key`).
  """
  @spec resolve(Node.t()) :: resolution
  def resolve(%Node{kind: :gateway}), do: {:error, :gateway_key}
  def resolve(%Node{gateway_choice: :direct}), do: :direct
  def resolve(%Node{gateway_choice: :named, gateway_id: nil}), do: {:error, :gateway_not_serving}

  def resolve(%Node{gateway_choice: :named, gateway_id: gateway_id} = node) do
    gateway = Repo.get(Node, gateway_id)

    if gateway && may_serve?(gateway, workspace_of(node)),
      do: with_key(gateway),
      else: {:error, :gateway_not_serving}
  end

  def resolve(%Node{gateway_choice: :default} = node) do
    case default_gateway_for(workspace_of(node)) do
      nil -> {:error, :no_default_gateway}
      gateway -> with_key(gateway)
    end
  end

  @doc """
  chosen/1 is the gateway the choice of `node` names now, from the records as they are:
  the gateway it names, when that gateway may serve the node's workspace, or its
  workspace's default gateway; nil for a node that goes direct, a choice that leads to
  no gateway, and a gateway. Unlike `resolve/1`, it asks nothing of the gateway's access
  key: a gateway not yet connected is still the one the node's runs go through.
  """
  @spec chosen(Node.t()) :: Node.t() | nil
  def chosen(%Node{kind: :gateway}), do: nil
  def chosen(%Node{gateway_choice: :direct}), do: nil
  def chosen(%Node{gateway_choice: :named, gateway_id: nil}), do: nil

  def chosen(%Node{gateway_choice: :named, gateway_id: gateway_id} = node) do
    gateway = Repo.get(Node, gateway_id)
    if gateway && may_serve?(gateway, workspace_of(node)), do: gateway
  end

  def chosen(%Node{gateway_choice: :default} = node),
    do: default_gateway_for(workspace_of(node))

  defp with_key(gateway) do
    if AccessKeys.active_key?(gateway),
      do: {:gateway, gateway},
      else: {:error, :gateway_without_key}
  end

  defp workspace_of(%Node{workspace: %Workspace{} = workspace}), do: workspace
  defp workspace_of(%Node{workspace_id: id}), do: Repo.get!(Workspace, id)

  ## Deleting

  @doc """
  delete_blockers/1 is what stops `gateway` from being deleted (`t:blockers/0`): the nodes
  in use that name it, wherever they are, and those on `:default` whose default resolves
  to it now, in any workspace it may serve (`serves/1`), by name; and the runs through it
  that are live or waiting as of `now`, the clock unless given (see the moduledoc), in
  the order they registered, then by run id. Nothing stops it when there are none.
  """
  @spec delete_blockers(Node.t(), DateTime.t()) :: blockers
  def delete_blockers(
        %Node{kind: :gateway, id: id} = gateway,
        %DateTime{} = now \\ DateTime.utc_now()
      ) do
    nodes =
      gateway
      |> using_query()
      |> order_by([n], asc: n.name, asc: n.id)
      |> Repo.all()

    %{nodes: nodes, runs: holding_runs(id, now)}
  end

  @doc """
  workspaces_using/1 is the workspaces whose nodes or node pools use `gateway` now: name
  it, or are on `:default` and resolve to it, as `delete_blockers/1` finds them; each with
  its organisation, by the organisation's name, then the workspace's. A gateway's page says
  who uses it from them, naming only the workspaces its reader reaches.
  """
  @spec workspaces_using(Node.t()) :: [%Workspace{}]
  def workspaces_using(%Node{kind: :gateway} = gateway) do
    ids = gateway |> using_query() |> select([n], n.workspace_id) |> distinct(true)

    from(w in Workspace,
      join: o in assoc(w, :organisation),
      where: w.id in subquery(ids),
      order_by: [asc: o.name, asc: w.name, asc: w.id],
      preload: [organisation: o]
    )
    |> Repo.all()
  end

  def workspaces_using(%Node{}), do: []

  # The nodes in use that name `gateway`, or are on `:default` and resolve to it now.
  defp using_query(%Node{id: id} = gateway) do
    from(n in Node,
      where: is_nil(n.deleted_at),
      where:
        ^dynamic(
          [n],
          (n.gateway_choice == :named and n.gateway_id == ^id) or ^defaulting(gateway)
        )
    )
  end

  # The nodes on `:default` whose default resolves to `gateway` now: none unless it is its
  # level's default. A workspace-level default holds its workspace's nodes, when the
  # workspace resolves it. An organisation-level default holds the nodes of each workspace
  # it serves that marks no default of its own, in each organisation whose chain of
  # defaults reaches it first.
  defp defaulting(%Node{default_gateway: false}), do: dynamic(false)

  defp defaulting(%Node{id: id, deleted_at: nil} = gateway) do
    case level(gateway) do
      {:workspace, workspace_id} ->
        workspace = Repo.get(Workspace, workspace_id)

        if workspace && match?(%Node{id: ^id}, default_gateway_for(workspace)),
          do: dynamic([n], n.gateway_choice == :default and n.workspace_id == ^workspace_id),
          else: dynamic(false)

      {:organisation, organisation_id} ->
        served = [organisation_id | served_organisations(organisation_id)]
        chains = Map.new(served, &{&1, chain(&1)})
        defaults = with_default(chains |> Map.values() |> List.flatten())

        reached =
          for {served, chain} <- chains,
              Enum.find(chain, &MapSet.member?(defaults, &1)) == organisation_id,
              do: served

        dynamic(
          [n],
          n.gateway_choice == :default and n.organisation_id in ^reached and
            n.workspace_id not in subquery(own_defaults())
        )
    end
  end

  defp defaulting(%Node{}), do: dynamic(false)

  # The runs through the gateway that are live or waiting as of `now`: not ended and not
  # lost, and attached or within their attach window.
  defp holding_runs(gateway_id, now) do
    from(r in Run,
      where: r.gateway_id == ^gateway_id,
      where: r.state not in ~w(completed failed cancelled lost),
      where: is_nil(r.exited_at) and is_nil(r.outcome_state) and is_nil(r.events_pruned_at),
      where: not is_nil(r.attached_at) or r.attach_by >= ^now,
      order_by: [asc: r.registered_at, asc: r.run_id]
    )
    |> Repo.all()
  end
end
