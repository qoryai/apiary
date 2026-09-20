defmodule Apiary.Policy.Suggestions do
  @moduledoc """
  The hosts a repository's harness declared and its policy does not cover (S5).

  A run's `ai.qory.run.policy_applied` events report `harness_hosts`, the hosts the
  harness's modules declared; they decide nothing. Read here from the repository's newest
  runs, bounded at every step: the events are a runner's, so a host that is not in the
  contract's grammar is left out and nothing becomes an atom.
  """

  import Ecto.Query, warn: false

  alias Apiary.Policy.{Effective, Grammar}
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}

  @policy_applied "ai.qory.run.policy_applied"
  @runs 20
  @events 100
  @hosts_per_event 200
  @limit 50

  @doc false
  def list(hive_id, repository_id, %Effective{allow: allow}) do
    runs =
      from r in Run,
        where: r.hive_id == ^hive_id and r.repository_id == ^repository_id,
        order_by: [desc: r.inserted_at],
        limit: @runs,
        select: r.id

    Repo.all(
      from(e in Event,
        where: e.hive_id == ^hive_id and e.run_id in subquery(runs) and e.type == @policy_applied,
        order_by: [desc: e.received_at],
        limit: @events,
        select: {e.run_id, e.data, e.received_at}
      ),
      log: false
    )
    |> Enum.flat_map(fn {run_id, data, received_at} ->
      for host <- hosts(data), do: {host, run_id, received_at}
    end)
    |> Enum.reject(fn {host, _run_id, _received_at} -> Grammar.covers_any?(allow, host) end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {host, seen} ->
      %{
        host: host,
        runs: seen |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length(),
        last_seen_at: seen |> Enum.map(&elem(&1, 2)) |> Enum.max(DateTime)
      }
    end)
    |> Enum.sort_by(&{-&1.runs, &1.host})
    |> Enum.take(@limit)
  end

  defp hosts(%{"harness_hosts" => hosts}) when is_list(hosts) do
    hosts |> Enum.take(@hosts_per_event) |> Enum.filter(&Grammar.host?/1) |> Enum.uniq()
  end

  defp hosts(_data), do: []
end
