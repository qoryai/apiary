defmodule Apiary.NodesFixtures do
  @moduledoc "Test helpers for nodes and node pools."

  alias Apiary.Nodes

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
end
