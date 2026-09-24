defmodule Apiary.Policy.Suggestions do
  @moduledoc """
  The hosts a target's harness declared and its policy neither covers nor denies (S5).

  A run's `dev.qory.run.policy_applied` events report `harness_hosts`, the hosts the
  harness's modules declared; they decide nothing. Read here from the target's newest
  runs, bounded at every step: the events are a runner's, so a host that is not in the
  contract's grammar is left out and nothing becomes an atom.

  Each suggestion is shown against the record: the attempts to the host that the
  target's runs were allowed and denied since a moment, from `connections`, capped
  like `Apiary.Policy.Activity`'s read (nil, not a part's count, beyond the cap). The
  declared hosts that a rule already covers come beside them, with the entry that covers
  each and whether it is the hive's or the target's, at most 20.
  """

  import Ecto.Query, warn: false

  alias Apiary.Organisations.Hive
  alias Apiary.Policy.{Effective, Grammar, Resolution, Rule}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Event, Target, Run}

  @policy_applied "dev.qory.run.policy_applied"
  @runs 20
  @events 100
  @hosts_per_event 200
  @limit 50
  @covered 20
  @attempts_cap 20_000
  @count_runs 100
  @count_events 300

  @doc false
  def list(hive_id, target_id, %Effective{} = effective, since),
    do: report(hive_id, target_id, effective, since).suggested

  @doc false
  def report(hive_id, target_id, %Effective{allow: allow, entries: entries}, since) do
    # A host somebody denied is not covered on purpose: suggesting it would be noise.
    denied = for %{kind: :host, action: :deny, in_force: true, host: host} <- entries, do: host

    sources =
      for %{kind: :host, action: :allow, in_force: true} = entry <- entries,
          into: %{},
          do: {entry.host, entry}

    declared = declared(hive_id, target_id)

    {covered, open} =
      declared
      |> Enum.reject(fn {host, _seen} -> Grammar.covers_any?(denied, host) end)
      |> Enum.split_with(fn {host, _seen} -> Grammar.covers_any?(allow, host) end)

    attempts = attempts(hive_id, target_id, since)

    suggested =
      open
      |> Enum.map(fn {host, seen} ->
        {allowed, denied} = attempt_counts(attempts, host)

        %{
          host: host,
          runs: seen |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
          last_seen_at: seen |> Enum.map(&elem(&1, 1)) |> Enum.max(DateTime),
          allowed: allowed,
          denied: denied
        }
      end)
      |> Enum.sort_by(&{-&1.runs, &1.host})
      |> Enum.take(@limit)

    covered =
      covered
      |> Enum.map(fn {host, _seen} ->
        # The entry a runner would report: the first of `allow`, names before suffixes.
        by = Enum.find(allow, &Grammar.covers?(&1, host))
        entry = sources[by]
        %{host: host, by: by, source: entry && entry.source, rule_id: entry && entry.rule.id}
      end)
      |> Enum.sort_by(& &1.host)
      |> Enum.take(@covered)

    %{suggested: suggested, covered: covered}
  end

  @doc false
  # See `Apiary.Policy.suggestion_counts/2`. One read of the events joined to their runs
  # and targets (the hosts declared, and each target's own mode), one read of the
  # hive's rules, and the hive's mode; each target's effective policy is resolved once.
  def counts(%Hive{id: hive_id}, since) do
    runs =
      from r in Run,
        where: r.hive_id == ^hive_id and not is_nil(r.target_id),
        where: coalesce(r.started_at, r.inserted_at) >= ^since,
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: @count_runs,
        select: r.id

    declared =
      Repo.all(
        from(e in Event,
          join: r in Run,
          on: r.id == e.run_id,
          join: p in Target,
          on: p.id == r.target_id,
          where:
            e.hive_id == ^hive_id and e.run_id in subquery(runs) and e.type == @policy_applied,
          order_by: [desc: e.received_at],
          limit: @count_events,
          select: {r.target_id, p.egress_mode, e.data}
        ),
        log: false
      )

    if declared == [] do
      %{hosts: 0, targets: 0}
    else
      mode = Repo.one!(from h in Hive, where: h.id == ^hive_id, select: h.egress_mode)
      rules = Repo.all(from r in Rule, where: r.hive_id == ^hive_id)
      {hive_rules, own} = Enum.split_with(rules, &is_nil(&1.target_id))
      own = Enum.group_by(own, & &1.target_id)

      per_target =
        declared
        |> Enum.group_by(fn {target_id, own_mode, _data} -> {target_id, own_mode} end)
        |> Enum.map(fn {{target_id, own_mode}, rows} ->
          hosts = rows |> Enum.flat_map(fn {_id, _mode, data} -> hosts(data) end) |> Enum.uniq()

          effective =
            case Resolution.resolve_for(
                   mode,
                   own_mode,
                   hive_rules,
                   Map.get(own, target_id, []),
                   target_id
                 ) do
              {:ok, effective} -> effective
              {:error, _error} -> %Effective{}
            end

          hosts |> open_hosts(effective) |> length()
        end)
        |> Enum.filter(&(&1 > 0))

      %{hosts: Enum.sum(per_target), targets: length(per_target)}
    end
  end

  # The declared hosts the policy neither covers nor denies, as `report/4` picks them.
  defp open_hosts(hosts, %Effective{allow: allow, entries: entries}) do
    denied = for %{kind: :host, action: :deny, in_force: true, host: host} <- entries, do: host

    hosts
    |> Enum.reject(&Grammar.covers_any?(denied, &1))
    |> Enum.reject(&Grammar.covers_any?(allow, &1))
  end

  # host => [{run id, received at}], from the newest runs' policy applied events.
  defp declared(hive_id, target_id) do
    runs =
      from r in Run,
        where: r.hive_id == ^hive_id and r.target_id == ^target_id,
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
      for host <- hosts(data), do: {host, {run_id, received_at}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The attempts of the target's runs since `since`, as `{host, allowed, denied}`, read
  # through `connections (hive_id, last_seen_at)`; nil beyond the cap, and the counts with
  # it: a count of a part would read as the whole.
  defp attempts(hive_id, target_id, since) do
    rows =
      Repo.all(
        from c in Connection,
          join: r in Run,
          on: r.id == c.run_id,
          where:
            c.hive_id == ^hive_id and c.last_seen_at >= ^since and
              r.target_id == ^target_id,
          order_by: [desc: c.last_seen_at],
          limit: ^(@attempts_cap + 1),
          select: {c.host, c.allowed, c.denied}
      )

    if length(rows) <= @attempts_cap, do: rows
  end

  defp attempt_counts(nil, _host), do: {nil, nil}

  defp attempt_counts(rows, host) do
    Enum.reduce(rows, {0, 0}, fn {reached, allowed, denied}, {a, d} ->
      if is_binary(reached) and String.valid?(reached) and Grammar.matches?([host], reached),
        do: {a + allowed, d + denied},
        else: {a, d}
    end)
  end

  defp hosts(%{"harness_hosts" => hosts}) when is_list(hosts) do
    hosts |> Enum.take(@hosts_per_event) |> Enum.filter(&Grammar.host?/1) |> Enum.uniq()
  end

  defp hosts(_data), do: []
end
