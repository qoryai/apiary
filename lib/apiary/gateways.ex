defmodule Apiary.Gateways do
  @moduledoc """
  Gateways answers where a gateway stands and which gateway a node's or a node pool's runs
  go through.

  A **gateway** is a node of kind `:gateway` (`Apiary.Nodes.Node`, `ng_…`): it holds an
  access key of its own, enrols as a node does, and runs nothing itself. It lives at a
  **level**, the place it belongs to and serves everything below. In this release every
  gateway lives at a workspace's level and serves that workspace alone; the functions here
  take the levels most specific first (`levels/1`), so a gateway of a wider level answers
  through them unchanged.

  A node or a node pool **chooses** how its runs reach Qory Apiary (`gateway_choice`):
  `:direct`; `:default`, the default gateway of its workspace as it resolves at each
  registration; or `:named`, one gateway it names (`gateway_id`). A change of choice, or
  of a default, applies to the registrations after it.

  - `may_serve?/2` says whether a gateway may serve a workspace: a gateway of the
    workspace's level, in use.
  - `default_gateway_for/1` is the workspace's default gateway: the default of the most
    specific level that has one, or none.
  - `resolve/1` is where a node's next run goes: directly, through a gateway, or nowhere,
    with the reason.
  - `serves/1` is the workspaces a gateway may serve, the list its discovery document names.
  - `gateway_choices/1` is the gateways a node of a workspace may name.
  - `delete_blockers/1` is what stops a gateway from being deleted.

  **The default mark.** Each level marks at most one of its own gateways as its default
  (`default_gateway`, a partial unique index per workspace). A gateway becomes its level's
  default by itself only when no default resolves for the workspace it serves at all, so
  making a second gateway never moves a node; otherwise a person marks one, and the mark
  moves (`Apiary.Nodes.make_default_gateway/2`). A gateway is deleted only when nothing
  points to it (`delete_blockers/1`): no node names it, and no node on `:default` resolves
  to it now. After a deletion no node moves; when no default
  resolves for a workspace any more and gateways remain that may serve it, the oldest of
  them at the deleted gateway's level becomes the default (`oldest_at/2`).

  **The lock.** The gateways of a workspace, their default mark and the choices of its
  nodes change under one lock per workspace (`lock/1`), taken first in the transaction,
  before any row lock: a choice is checked against the gateways as they are, and a
  deletion against the nodes as they are.

  Every question about a gateway's access key goes through
  `Apiary.AccessKeys.active_key?/1`, which keeps to the keys a verified request could use.
  """

  import Ecto.Query, warn: false

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}

  @typedoc """
  A level a gateway may live at, most specific first: a workspace, or an organisation.
  """
  @type level :: {:workspace, Ecto.UUID.t()} | {:organisation, Ecto.UUID.t()}

  @typedoc """
  Where a node's next run goes (`resolve/1`): directly, through a gateway, or nowhere:

  - `:no_default_gateway`: the node chose the default, and none resolves for its workspace;
  - `:gateway_not_serving`: the gateway it names may no longer serve its workspace, is
    deleted, or is gone;
  - `:gateway_without_key`: the gateway it goes through has no active access key;
  - `:gateway_key`: the node is a gateway, which goes through none.
  """
  @type resolution ::
          :direct
          | {:gateway, Node.t()}
          | {:error,
             :no_default_gateway | :gateway_not_serving | :gateway_without_key | :gateway_key}

  @typedoc """
  What stops a gateway from being deleted (`delete_blockers/1`): the nodes that point to
  it, by name or by the default.
  """
  @type blockers :: %{nodes: [Node.t()]}

  ## Levels

  @doc """
  levels/1 is the levels a gateway serving `workspace` may live at, most specific first:
  the workspace's, then its organisation's.
  """
  @spec levels(%Workspace{}) :: [level, ...]
  def levels(%Workspace{id: id, organisation_id: organisation_id}),
    do: [{:workspace, id}, {:organisation, organisation_id}]

  @doc "level/1 is the level `gateway` lives at."
  @spec level(Node.t()) :: level
  def level(%Node{kind: :gateway, workspace_id: workspace_id}) when is_binary(workspace_id),
    do: {:workspace, workspace_id}

  @doc """
  lock/1 takes the lock of the gateways of `workspace` and the choices of its nodes, for
  the rest of the transaction. Taken first, before any row lock.
  """
  @spec lock(%Workspace{} | Ecto.UUID.t()) :: :ok
  def lock(%Workspace{id: id}), do: lock(id)

  def lock(workspace_id) when is_binary(workspace_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "apiary:gateways:" <> workspace_id
    ])

    :ok
  end

  ## What a gateway may serve

  @doc """
  may_serve?/2 says whether `gateway` may serve `workspace`: a gateway in use, at the
  workspace's level. Asked when a node's choice is saved and when a run registers.
  """
  @spec may_serve?(Node.t(), %Workspace{}) :: boolean
  def may_serve?(
        %Node{kind: :gateway, deleted_at: nil} = gateway,
        %Workspace{organisation_id: organisation_id} = workspace
      ) do
    gateway.organisation_id == organisation_id and level(gateway) in levels(workspace)
  end

  def may_serve?(_node, _workspace), do: false

  @doc """
  serves/1 is the workspaces `gateway` may serve, the list its discovery document names: a
  workspace-level gateway's own workspace. None for a gateway that is deleted, or a node
  that is not a gateway.
  """
  @spec serves(Node.t()) :: [%Workspace{}]
  def serves(%Node{kind: :gateway, deleted_at: nil} = gateway) do
    {:workspace, workspace_id} = level(gateway)

    from(w in Workspace,
      where: w.id == ^workspace_id and w.organisation_id == ^gateway.organisation_id
    )
    |> Repo.all()
  end

  def serves(%Node{}), do: []

  @doc """
  gateway_choices/1 is the gateways a node of the scope's workspace may name: every gateway
  in use that may serve the workspace (`may_serve?/2`), by name.
  """
  @spec gateway_choices(Scope.t()) :: [Node.t()]
  def gateway_choices(%Scope{
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{organisation_id: organisation_id} = workspace
      }) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace.id,
      where: n.kind == :gateway and is_nil(n.deleted_at),
      order_by: [asc: n.name, asc: n.id]
    )
    |> Repo.all()
    |> Enum.filter(&may_serve?(&1, workspace))
  end

  ## The default

  @doc """
  default_gateway_for/1 is the default gateway of `workspace`, most specific level first:
  the workspace's own default, else its organisation's. Nil when no level has one.
  """
  @spec default_gateway_for(%Workspace{}) :: Node.t() | nil
  def default_gateway_for(%Workspace{} = workspace),
    do: Enum.find_value(levels(workspace), &default_at(&1, workspace))

  @doc "default_at/2 is the default gateway `level` marks for `workspace`, or nil."
  @spec default_at(level, %Workspace{}) :: Node.t() | nil
  def default_at({:workspace, workspace_id}, %Workspace{organisation_id: organisation_id}) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: n.kind == :gateway and n.default_gateway and is_nil(n.deleted_at)
    )
    |> Repo.one()
  end

  # No gateway lives at an organisation's level in this release.
  def default_at({:organisation, _organisation_id}, %Workspace{}), do: nil

  @doc """
  oldest_at/2 is the oldest gateway in use at `level` that may serve `workspace`, the one
  that becomes the level's default when none resolves for the workspace; nil when none.
  """
  @spec oldest_at(level, %Workspace{}) :: Node.t() | nil
  def oldest_at({:workspace, workspace_id}, %Workspace{organisation_id: organisation_id}) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: n.kind == :gateway and is_nil(n.deleted_at),
      order_by: [asc: n.inserted_at, asc: n.id],
      limit: 1
    )
    |> Repo.one()
  end

  def oldest_at({:organisation, _organisation_id}, %Workspace{}), do: nil

  ## Resolution

  @doc """
  resolve/1 is where the next run of `node` goes, from the node's record as it is now
  (`t:resolution/0`): `:direct`; `{:gateway, gateway}`, the gateway it names or its
  workspace's default, when that gateway may serve the node's workspace and has an active
  access key; or `{:error, reason}`. A gateway's own key registers no run through another
  (`:gateway_key`).
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
  in use that name it, and those on `:default` whose default resolves to it now, by name.
  Nothing stops it when there are none.
  """
  @spec delete_blockers(Node.t()) :: blockers
  def delete_blockers(%Node{kind: :gateway, id: id} = gateway) do
    defaulting =
      for workspace <- serves(gateway),
          match?(%Node{id: ^id}, default_gateway_for(workspace)),
          do: workspace.id

    nodes =
      from(n in Node,
        where: is_nil(n.deleted_at),
        where:
          (n.gateway_choice == :named and n.gateway_id == ^id) or
            (n.gateway_choice == :default and n.workspace_id in ^defaulting),
        order_by: [asc: n.name, asc: n.id]
      )
      |> Repo.all()

    %{nodes: nodes}
  end
end
