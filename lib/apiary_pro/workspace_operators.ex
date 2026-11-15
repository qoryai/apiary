defmodule ApiaryPro.WorkspaceOperators do
  @moduledoc """
  WorkspaceOperators is the link between a workspace and the operator that operates it,
  one row per operated workspace (`ApiaryPro.Operators.WorkspaceOperator`): at most one
  operator per workspace, and an organisation may have a different operator on each of
  its workspaces. A workspace without a row has no operator. No code in the product
  starts or ends a link.

  **On the organisation.** The links of an organisation's workspaces are in its
  `edition` map under `:operated`, a map of each operated workspace's id to its
  operator's id: `put/1` reads them into it, and the functions after it (`operated/1`,
  `operator_id/2`, `operated?/2`, `operator_ids/1`) return them from that map, or read
  them from the database when the organisation has no such map.

  **Locks.** A write that holds the organisation `FOR SHARE`
  (`Apiary.Access.lock_places/1`) holds the operators of its workspaces with it
  (`ApiaryPro.Reach.places_to_lock/1`), in the lock order: an organisation before the
  operators of its workspaces. Code that writes a link must lock the organisation's row
  `FOR NO KEY UPDATE` first, so that it waits for such a write.
  """

  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Organisations.{Organisation, Workspace}
  alias ApiaryPro.Operators.WorkspaceOperator

  @typedoc "Each operated workspace's id, with its operator's id."
  @type operated :: %{Ecto.UUID.t() => Ecto.UUID.t()}

  ## On the organisation

  @doc """
  operated/1 is the links of `organisation`'s workspaces, each operated workspace's id
  with its operator's id, as they are in the organisation's `edition` map, or read now
  when that map has none. Empty for an organisation not inserted yet.
  """
  @spec operated(%Organisation{}) :: operated
  def operated(%Organisation{edition: %{operated: operated}}) when is_map(operated), do: operated
  def operated(%Organisation{id: nil}), do: %{}
  def operated(%Organisation{id: id}), do: read(id)

  @doc """
  put/1 is `organisation` with the links of its workspaces, as the database has them now,
  in its `edition` map (`operated/1`).
  """
  @spec put(%Organisation{}) :: %Organisation{}
  def put(%Organisation{id: nil} = organisation), do: put_operated(organisation, %{})
  def put(%Organisation{id: id} = organisation), do: put_operated(organisation, read(id))

  defp put_operated(%Organisation{edition: edition} = organisation, operated),
    do: %{organisation | edition: Map.put(edition || %{}, :operated, operated)}

  defp read(organisation_id) do
    Repo.all(
      from l in WorkspaceOperator,
        where: l.organisation_id == ^organisation_id,
        select: {l.workspace_id, l.operator_id}
    )
    |> Map.new()
  end

  @doc """
  operator_id/2 is the id of the operator of the workspace `workspace` of `organisation`,
  given as a workspace or its id; nil for a workspace with none, and for nil.
  """
  @spec operator_id(%Organisation{}, %Workspace{} | Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def operator_id(_organisation, nil), do: nil
  def operator_id(organisation, %Workspace{id: id}), do: operator_id(organisation, id)
  def operator_id(organisation, workspace_id), do: Map.get(operated(organisation), workspace_id)

  @doc "operated?/2 says whether the workspace `workspace` of `organisation` has an operator."
  @spec operated?(%Organisation{}, %Workspace{} | Ecto.UUID.t() | nil) :: boolean
  def operated?(organisation, workspace), do: is_binary(operator_id(organisation, workspace))

  @doc """
  operator_ids/1 is the ids of the operators of `organisation`'s workspaces, each once, in
  the order of their ids.
  """
  @spec operator_ids(%Organisation{}) :: [Ecto.UUID.t()]
  def operator_ids(organisation),
    do: organisation |> operated() |> Map.values() |> Enum.uniq() |> Enum.sort()

  @doc """
  operator_ids_of/1 is `operator_ids/1` of the organisation `organisation_id`, read now
  with one statement and no lock.
  """
  @spec operator_ids_of(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def operator_ids_of(organisation_id) do
    Repo.all(
      from l in WorkspaceOperator,
        where: l.organisation_id == ^organisation_id,
        distinct: true,
        order_by: l.operator_id,
        select: l.operator_id
    )
  end

  @doc """
  operates_workspaces?/1 says whether the organisation is the operator of any workspace,
  one marked for deletion included, as the database has it now.
  """
  @spec operates_workspaces?(%Organisation{}) :: boolean
  def operates_workspaces?(%Organisation{id: id}),
    do: Repo.exists?(from l in WorkspaceOperator, where: l.operator_id == ^id)

  @doc """
  has_operated_workspaces?/1 says whether any workspace of the organisation has an
  operator, one marked for deletion included, as the database has it now.
  """
  @spec has_operated_workspaces?(%Organisation{}) :: boolean
  def has_operated_workspaces?(%Organisation{id: id}),
    do: Repo.exists?(from l in WorkspaceOperator, where: l.organisation_id == ^id)
end
