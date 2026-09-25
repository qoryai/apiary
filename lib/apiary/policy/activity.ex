defmodule Apiary.Policy.Activity do
  @moduledoc """
  What the recorded connections say about the rules: see `Apiary.Policy.uncovered/2`,
  `denied_summary/2`, `denied_destinations/2` and `rule_activity/3`.

  One read serves all four: the hive's connections last seen since a moment, through the
  index `connections (hive_id, last_seen_at)`, a few small columns a row and at most
  `cap/0` rows. A hive with more than that in the range gets `:unavailable`: a count of a
  part would read as a count of the whole. A connection's counters are those of its run,
  so a connection counts whole when it was last seen in the range.

  `uncovered` for the hive counts only the runs of targets that follow the hive's
  mode, and the runs that name no target: a target with a mode of its own is not
  changed by the hive's. For a target it counts that target's runs, whatever its
  mode is now: what enforcing it would start denying.

  A connection is held to the effective policy of its own run's target, its mode
  included (the baseline
  for a run that names none), resolved once per target, and matched as the runner's
  proxy matches: the host against `deny` first and then against `allow`, each in the
  rendered order, first match; then, on a host held to paths, the path against that
  host's list. A host a deny covers is denied in either mode, so it is not what enforce
  would start denying, though it is still a denied destination the rules do not allow.
  Hosts and paths are a runner's words: compared, never made atoms of, and what is not a
  host is no rule's.

  A destination enforce would start denying carries `tool`, the tool its most recently seen
  tool invocation was handed to (`Apiary.Runs.tool_invocation?/2`; nil when none was), so a
  page names it as a call to the tool. A denied destination carries `tool`, the tool whose
  host its most recently seen connection was for (nil when it named none): a request a
  path rule refused never reached the tool and is no tool invocation, so a page names the
  tool only as the one whose host it was.
  """

  import Ecto.Query, warn: false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Hive
  alias Apiary.Policy.{Effective, Grammar, Resolution, Rule}
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Target, Run}

  @default_cap 20_000
  @top 50

  @doc """
  The most connections one answer reads; beyond it the answer is `:unavailable`.
  #{@default_cap} unless `config :apiary, Apiary.Policy.Activity, cap: n` says otherwise, read
  at each call, so a test can set it (`Application.put_env/3`, in a module that is not
  async) and see the answer a large hive gets.
  """
  def cap, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :cap, @default_cap)

  @doc false
  def uncovered(%Scope{hive: %Hive{} = hive}, target_id, since, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, target_id, since, opts) do
      {:ok, uncovered_from(hive, rows, policies(hive, rows), target_id)}
    end
  end

  defp uncovered_from(%Hive{id: hive_id}, rows, policies, target_id) do
    rows
    |> Enum.filter(&(&1.allowed > 0))
    # Enforcing the hive changes nothing for a target with a mode of its own.
    |> Enum.filter(&(target_id != nil or policies[&1.target_id].follows_hive))
    |> Enum.flat_map(fn row ->
      case cover(policies[row.target_id], row) do
        {:uncovered, path} -> [{{row.host, path}, row}]
        # Covered, or denied by a rule that holds in either mode: enforce changes nothing.
        _decided -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{host, path}, rows} ->
      %{
        host: host,
        path: path,
        attempts: rows |> Enum.map(& &1.allowed) |> Enum.sum(),
        tool: invoked_tool(rows),
        runs: rows |> Enum.map(& &1.run_id) |> Enum.uniq() |> length(),
        last_seen_at: rows |> Enum.map(& &1.last_seen_at) |> Enum.max(DateTime),
        target_ids: rows |> Enum.map(& &1.target_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(&{-&1.attempts, &1.host, &1.path})
    |> Enum.take(@top)
    |> then(&with_targets(hive_id, &1))
  end

  @doc false
  def denied_destinations(%Scope{hive: %Hive{} = hive}, since, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, nil, since, opts) do
      {:ok, denied_from(hive, rows, policies(hive, rows))}
    end
  end

  @doc false
  # What the overview's attention list and strip need of the connections, from one read
  # over the wider window: the denied destinations held to today's rules and what enforce
  # would deny, both since `since`, and how many destinations were denied since `window`
  # (the earlier moment). See `Apiary.Policy.overview_activity/3`.
  def overview(%Scope{hive: %Hive{} = hive}, since, window, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, nil, window, opts) do
      recent = Enum.filter(rows, &(DateTime.compare(&1.last_seen_at, since) != :lt))
      policies = policies(hive, recent)

      {:ok,
       %{
         denied: denied_from(hive, recent, policies),
         uncovered: uncovered_from(hive, recent, policies, nil),
         denied_destinations:
           rows
           |> Enum.filter(&(&1.denied > 0))
           |> Enum.map(&{&1.host, &1.port, &1.path})
           |> Enum.uniq()
           |> length()
       }}
    end
  end

  defp denied_from(%Hive{id: hive_id}, rows, policies) do
    rows
    |> Enum.filter(&(&1.denied > 0))
    |> Enum.flat_map(fn row ->
      policy = policies[row.target_id]

      case cover(policy, row) do
        # Allowed since: nothing to offer.
        :covered -> []
        # A deny rule holds it: still not allowed, and the page says which rule.
        :denied -> [{{row.host, row.port, row.path || ""}, {row, nil, policy}}]
        {:uncovered, path} -> [{{row.host, row.port, row.path || ""}, {row, path, policy}}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{host, port, path}, hits} ->
      rows = Enum.map(hits, &elem(&1, 0))
      # The path is what no rule covers when the host itself is allowed somewhere.
      held? = Enum.any?(hits, fn {_row, uncovered_path, _policy} -> uncovered_path != nil end)

      locked =
        Enum.find_value(hits, fn {row, _path, policy} ->
          first_match(policy.locked_denies, row.host)
        end)

      %{
        host: host,
        port: port,
        path: path,
        held: held?,
        locked: locked,
        denied: rows |> Enum.map(& &1.denied) |> Enum.sum(),
        tool: host_tool(rows),
        runs: rows |> Enum.map(& &1.run_id) |> Enum.uniq() |> length(),
        last_seen_at: rows |> Enum.map(& &1.last_seen_at) |> Enum.max(DateTime),
        target_ids: rows |> Enum.map(& &1.target_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(&{-&1.denied, &1.host, &1.port, &1.path})
    |> Enum.take(@top)
    |> then(&with_targets(hive_id, &1))
  end

  # The tool whose host the most recently seen of a destination's rows was for, whatever
  # became of the request: nil when it named none.
  defp host_tool(rows), do: rows |> Enum.max_by(& &1.last_seen_at, DateTime) |> Map.get(:tool)

  # The tool the most recently seen of a destination's rows whose last attempt was a tool
  # invocation was handed to: nil when none was.
  defp invoked_tool(rows) do
    case Enum.filter(rows, &Runs.tool_invocation?(&1.tool, &1.decision)) do
      [] -> nil
      invocations -> host_tool(invocations)
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
  def rule_activity(%Scope{hive: %Hive{} = hive}, target_id, since, opts \\ []) do
    with {:ok, rows} <- rows(hive.id, target_id, since, opts) do
      policies = policies(hive, rows)

      counts =
        Enum.reduce(rows, %{}, fn row, counts ->
          policy = policies[row.target_id]

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
  defp rows(hive_id, target_id, since, opts) do
    cap = Keyword.get(opts, :cap, cap())

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
          tool: c.last_tool,
          decision: c.last_decision,
          last_seen_at: c.last_seen_at,
          run_id: c.run_id,
          target_id: r.target_id
        }

    query =
      if target_id, do: where(query, [_c, r], r.target_id == ^target_id), else: query

    case Repo.all(query) do
      rows when length(rows) > cap -> :unavailable
      rows -> {:ok, rows}
    end
  end

  ## The policies the rows are held to

  # target id (nil for the baseline) => what matching needs of its effective policy.
  defp policies(%Hive{id: hive_id}, rows) do
    mode = Repo.one!(from h in Hive, where: h.id == ^hive_id, select: h.egress_mode)

    modes =
      Repo.all(
        from p in Target,
          where: p.hive_id == ^hive_id and not is_nil(p.egress_mode),
          select: {p.id, p.egress_mode}
      )
      |> Map.new()

    rules = Repo.all(from r in Rule, where: r.hive_id == ^hive_id)
    {hive_rules, own} = Enum.split_with(rules, &is_nil(&1.target_id))
    own = Enum.group_by(own, & &1.target_id)

    [nil | Enum.map(rows, & &1.target_id)]
    |> Enum.uniq()
    |> Map.new(fn target_id ->
      rules = Map.get(own, target_id, [])

      case Resolution.resolve_for(mode, modes[target_id], hive_rules, rules, target_id) do
        {:ok, effective} -> {target_id, policy(effective)}
        {:error, _error} -> {target_id, policy(%Effective{})}
      end
    end)
  end

  defp policy(%Effective{} = effective) do
    in_force = Enum.filter(effective.entries, & &1.in_force)

    by_host =
      for %{kind: :host, rule: %Rule{id: id}} = entry <- in_force,
          into: %{},
          do: {{entry.action, entry.host}, id}

    locked = for %{kind: :host, action: :deny, locked: true, host: host} <- in_force, do: host

    %{
      mode: effective.mode,
      locked_denies: Enum.sort_by(locked, &{Grammar.wildcard?(&1), &1}),
      follows_hive: effective.mode_source == :hive,
      allow: effective.allow,
      paths: effective.paths,
      # The document's own list, names before suffixes as `allow` is: what the runner
      # decides first, and the most exact entry is the one it names.
      denies: effective.deny,
      by_host: by_host,
      credentials:
        for(
          %{kind: :credential, action: :allow, rule: %Rule{id: id}} = entry <- in_force,
          into: %{},
          do: {entry.name, id}
        )
    }
  end

  # `:covered`, `:denied` (a deny entry names the host: decided first, in either mode), or
  # `{:uncovered, path}` with the path when it is the path that no rule covers and nil
  # when it is the host.
  defp cover(policy, row) do
    cond do
      first_match(policy.denies, row.host) ->
        :denied

      is_nil(first_match(policy.allow, row.host)) ->
        {:uncovered, nil}

      true ->
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

  # The rule the runner reports: the first of `deny`, then the first of `allow`.
  defp host_rule(policy, host) do
    cond do
      entry = first_match(policy.denies, host) -> policy.by_host[{:deny, entry}]
      entry = first_match(policy.allow, host) -> policy.by_host[{:allow, entry}]
      true -> nil
    end
  end

  defp credential_rule(_policy, credential) when credential in [nil, ""], do: nil
  defp credential_rule(policy, credential), do: policy.credentials[credential]

  defp first_match(entries, host) when is_binary(host) do
    if String.valid?(host), do: Enum.find(entries, &Grammar.matches?([&1], host))
  end

  defp first_match(_entries, _host), do: nil

  defp with_targets(hive_id, destinations) do
    ids = destinations |> Enum.flat_map(& &1.target_ids) |> Enum.uniq()

    targets =
      Repo.all(
        from p in Target,
          where: p.hive_id == ^hive_id and p.id in ^ids,
          select: {p.id, %{id: p.id, system: p.system, path: p.path}}
      )
      |> Map.new()

    for destination <- destinations do
      {ids, destination} = Map.pop(destination, :target_ids)

      targets =
        ids
        |> Enum.map(&targets[&1])
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{&1.system, &1.path})

      Map.put(destination, :targets, targets)
    end
  end
end
