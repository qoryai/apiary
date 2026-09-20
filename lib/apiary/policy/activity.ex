defmodule Apiary.Policy.Activity do
  @moduledoc """
  What the recorded connections say about the rules: see `Apiary.Policy.uncovered/2`,
  `denied_summary/2` and `rule_activity/3`.

  One read serves all three: the hive's connections last seen since a moment, through the
  index `connections (hive_id, last_seen_at)`, a few small columns a row and at most
  `cap/0` rows. A hive with more than that in the range gets `:unavailable`: a count of a
  part would read as a count of the whole. A connection's counters are those of its run,
  so a connection counts whole when it was last seen in the range.

  A connection is held to the effective policy of its own run's repository (the baseline
  for a run that names none), resolved once per repository, and matched as the runner's
  proxy matches: the host against `allow` in the rendered order, first match; then, on a
  host held to paths, the path against that host's list. Hosts and paths are a runner's
  words: compared, never made atoms of, and what is not a host is no rule's.
  """

  import Ecto.Query, warn: false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Hive
  alias Apiary.Policy.{Effective, Grammar, Resolution, Rule}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Repository, Run}

  @cap 20_000
  @top 50

  @doc "The most connections one answer reads; beyond it the answer is `:unavailable`."
  def cap, do: @cap

  @doc false
  def uncovered(%Scope{hive: %Hive{} = hive}, since, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, nil, since, opts) do
      policies = policies(hive, rows)

      destinations =
        rows
        |> Enum.filter(&(&1.allowed > 0))
        |> Enum.flat_map(fn row ->
          case cover(policies[row.repository_id], row) do
            {:uncovered, path} -> [{{row.host, path}, row}]
            _covered -> []
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.map(fn {{host, path}, rows} ->
          %{
            host: host,
            path: path,
            attempts: rows |> Enum.map(& &1.allowed) |> Enum.sum(),
            runs: rows |> Enum.map(& &1.run_id) |> Enum.uniq() |> length(),
            last_seen_at: rows |> Enum.map(& &1.last_seen_at) |> Enum.max(DateTime),
            repository_ids:
              rows |> Enum.map(& &1.repository_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
          }
        end)
        |> Enum.sort_by(&{-&1.attempts, &1.host, &1.path})
        |> Enum.take(@top)

      {:ok, with_repositories(hive.id, destinations)}
    end
  end

  @doc false
  def denied_summary(%Scope{hive: %Hive{} = hive}, since, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, nil, since, opts) do
      denied = Enum.filter(rows, &(&1.denied > 0))

      {:ok,
       %{
         denied: denied |> Enum.map(& &1.denied) |> Enum.sum(),
         destinations: denied |> Enum.map(&{&1.host, &1.port, &1.path}) |> Enum.uniq() |> length()
       }}
    end
  end

  @doc false
  def rule_activity(%Scope{hive: %Hive{} = hive}, repository_id, since, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, repository_id, since, opts) do
      policies = policies(hive, rows)

      counts =
        Enum.reduce(rows, %{}, fn row, counts ->
          policy = policies[row.repository_id]

          [host_rule(policy, row.host), credential_rule(policy, row.credential)]
          |> Enum.reject(&is_nil/1)
          |> Enum.reduce(counts, fn rule_id, counts ->
            Map.update(
              counts,
              rule_id,
              %{allowed: row.allowed, denied: row.denied},
              &%{allowed: &1.allowed + row.allowed, denied: &1.denied + row.denied}
            )
          end)
        end)

      {:ok, counts}
    end
  end

  ## The read

  # Newest first through `connections (hive_id, last_seen_at)`; one row over the cap says
  # there is more than is read.
  # `cap:` is for the tests, which cannot afford the real one.
  defp rows(hive_id, repository_id, since, opts) do
    cap = Keyword.get(opts, :cap, @cap)

    query =
      from c in Connection,
        join: r in Run,
        on: r.id == c.run_id,
        where: c.hive_id == ^hive_id and c.last_seen_at >= ^since,
        order_by: [desc: c.last_seen_at],
        limit: ^(cap + 1),
        select: %{
          host: c.host,
          port: c.port,
          path: c.path,
          allowed: c.allowed,
          denied: c.denied,
          credential: c.last_credential,
          last_seen_at: c.last_seen_at,
          run_id: c.run_id,
          repository_id: r.repository_id
        }

    query =
      if repository_id, do: where(query, [_c, r], r.repository_id == ^repository_id), else: query

    case Repo.all(query) do
      rows when length(rows) > cap -> :unavailable
      rows -> {:ok, rows}
    end
  end

  ## The policies the rows are held to

  # repository id (nil for the baseline) => what matching needs of its effective policy.
  defp policies(%Hive{id: hive_id}, rows) do
    mode = Repo.one!(from h in Hive, where: h.id == ^hive_id, select: h.egress_mode)
    rules = Repo.all(from r in Rule, where: r.hive_id == ^hive_id)
    {hive_rules, own} = Enum.split_with(rules, &is_nil(&1.repository_id))
    own = Enum.group_by(own, & &1.repository_id)

    [nil | Enum.map(rows, & &1.repository_id)]
    |> Enum.uniq()
    |> Map.new(fn repository_id ->
      case Resolution.resolve(mode, hive_rules, Map.get(own, repository_id, []), repository_id) do
        {:ok, effective} -> {repository_id, policy(effective)}
        {:error, _error} -> {repository_id, policy(%Effective{})}
      end
    end)
  end

  defp policy(%Effective{} = effective) do
    in_force = Enum.filter(effective.entries, & &1.in_force)

    by_host =
      for %{kind: :host, rule: %Rule{id: id}} = entry <- in_force,
          into: %{},
          do: {{entry.action, entry.host}, id}

    denies = for %{kind: :host, action: :deny, host: host} <- in_force, do: host

    %{
      allow: effective.allow,
      paths: effective.paths,
      # Names before suffixes, as `allow` is: the most exact deny is the one named.
      denies: Enum.sort_by(denies, &{Grammar.wildcard?(&1), &1}),
      by_host: by_host,
      credentials:
        for(
          %{kind: :credential, action: :allow, rule: %Rule{id: id}} = entry <- in_force,
          into: %{},
          do: {entry.name, id}
        )
    }
  end

  # `:covered`, or `{:uncovered, path}` with the path when it is the path that no rule
  # covers and nil when it is the host.
  defp cover(policy, row) do
    case first_match(policy.allow, row.host) do
      nil ->
        {:uncovered, nil}

      _entry ->
        case held(policy.paths, row.host) do
          nil ->
            :covered

          _paths when row.path in [nil, ""] ->
            :covered

          paths ->
            if Enum.any?(paths, &Grammar.path_matches?(&1, row.path)),
              do: :covered,
              else: {:uncovered, row.path}
        end
    end
  end

  defp held(paths, host) do
    case paths do
      %{^host => list} ->
        list

      _ ->
        Enum.find_value(paths, fn {key, list} -> if Grammar.matches?([key], host), do: list end)
    end
  end

  defp host_rule(policy, host) do
    cond do
      entry = first_match(policy.allow, host) -> policy.by_host[{:allow, entry}]
      entry = first_match(policy.denies, host) -> policy.by_host[{:deny, entry}]
      true -> nil
    end
  end

  defp credential_rule(_policy, credential) when credential in [nil, ""], do: nil
  defp credential_rule(policy, credential), do: policy.credentials[credential]

  defp first_match(entries, host) when is_binary(host) do
    if String.valid?(host), do: Enum.find(entries, &Grammar.matches?([&1], host))
  end

  defp first_match(_entries, _host), do: nil

  defp with_repositories(hive_id, destinations) do
    ids = destinations |> Enum.flat_map(& &1.repository_ids) |> Enum.uniq()

    repositories =
      Repo.all(
        from p in Repository,
          where: p.hive_id == ^hive_id and p.id in ^ids,
          select: {p.id, %{id: p.id, forge: p.forge, path: p.path}}
      )
      |> Map.new()

    for destination <- destinations do
      {ids, destination} = Map.pop(destination, :repository_ids)

      repositories =
        ids
        |> Enum.map(&repositories[&1])
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{&1.forge, &1.path})

      Map.put(destination, :repositories, repositories)
    end
  end
end
