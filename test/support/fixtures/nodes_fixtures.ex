defmodule Apiary.NodesFixtures do
  @moduledoc "Test helpers for nodes and node pools, their instances and their runs."

  alias Apiary.Nodes
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Repo
  alias Apiary.Runs.Run

  def unique_node_name, do: "build-#{System.unique_integer([:positive])}"

  @doc """
  A node of the scope's workspace, made by the scope's person, who must be an owner or
  an admin: kind `node` unless `attrs` says `pool`.
  """
  def node_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{kind: "node", name: unique_node_name()})
    {:ok, node} = Nodes.create_node(scope, attrs)
    node
  end

  @doc "A node pool of the scope's workspace, with no instance limit unless `attrs` sets one."
  def pool_fixture(scope, attrs \\ %{}),
    do: node_fixture(scope, Enum.into(attrs, %{kind: "pool", name: unique_node_name()}))

  @doc """
  An instance of `node` as `Apiary.Nodes.seen/3` leaves it, written straight into the
  table: `instance_id` (a fresh one unless given), `name`, and seen first and last at
  `seen_at` (now unless given), or at `first_seen_at` and `last_seen_at`.
  """
  def instance_fixture(%Node{} = node, attrs \\ %{}) do
    attrs = Map.new(attrs)
    seen = Map.get(attrs, :seen_at, DateTime.utc_now())

    Repo.insert!(%Instance{
      organisation_id: node.organisation_id,
      workspace_id: node.workspace_id,
      node_id: node.id,
      instance_id: Map.get(attrs, :instance_id, unique_instance_id()),
      name: Map.get(attrs, :name),
      first_seen_at: Map.get(attrs, :first_seen_at, seen),
      last_seen_at: Map.get(attrs, :last_seen_at, seen),
      last_forager_version: Map.get(attrs, :last_forager_version, "0.7.0")
    })
  end

  @doc "A fresh instance id, as Forager would claim one."
  def unique_instance_id, do: "i_#{System.unique_integer([:positive])}"

  @doc """
  A run of `node` claimed by `instance_id`, written straight into the table as the
  receiver will create it: pending, first heard of now, unless `attrs` says otherwise
  (`state`, `inserted_at`, `started_at`, `last_heartbeat_at`, …).
  """
  def node_run_fixture(%Node{} = node, instance_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    %Run{
      organisation_id: node.organisation_id,
      workspace_id: node.workspace_id,
      run_id: Ecto.UUID.generate(),
      node_id: node.id,
      instance_id: instance_id,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change(Map.new(attrs))
    |> Repo.insert!()
  end
end
