defmodule Apiary.Connections.Overlap do
  @moduledoc """
  Overlap finds the connections of a workspace that one would collide with where both
  apply: the same runtime, the same integration by name, or a host in common, one host
  pattern covering another (`Apiary.Kinds.Hosts.overlap?/2`), since a host gets its value
  from one connection only.

  Where a connection applies is its **reach**: every repository (`applies_to` `all`), or
  the repositories its targets name (`selected`), none of them when it names none. Two
  connections overlap where their reaches meet.
  """

  alias Apiary.Kinds.Hosts

  @typedoc """
  What a connection is to the check: its `id`, its identity (`{"runtime", name}` or
  `{"integration", name}`, nil for a service), its host patterns, and its reach.
  """
  @type entry :: %{
          id: term,
          identity: {String.t(), String.t()} | nil,
          hosts: [String.t()],
          reach: :all | MapSet.t()
        }

  @doc "conflicts/2 is the entries of `others` that `entry` collides with, by id."
  @spec conflicts(entry, [entry]) :: [term]
  def conflicts(entry, others) do
    for other <- others,
        other.id != entry.id,
        meet?(entry.reach, other.reach),
        same?(entry, other),
        do: other.id
  end

  defp same?(a, b) do
    (a.identity != nil and a.identity == b.identity) or
      Enum.any?(a.hosts, fn host -> Enum.any?(b.hosts, &Hosts.overlap?(host, &1)) end)
  end

  defp meet?(:all, :all), do: true
  defp meet?(:all, set), do: MapSet.size(set) > 0
  defp meet?(set, :all), do: MapSet.size(set) > 0
  defp meet?(a, b), do: not MapSet.disjoint?(a, b)
end
