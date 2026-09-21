defmodule Apiary.Policy.Resolution do
  @moduledoc """
  What the rules of a hive and of one repository come to. Pure: rules in, an
  `Apiary.Policy.Effective` out, or the sentence that says why the rules cannot be
  rendered.

  The contract's document says what is denied and what is allowed: `egress.deny` is
  decided by the runner first and holds in either mode, `egress.allow` decides after it and
  only under `enforce`. So a deny rule is written to the document, which is how a
  repository disables a host of the hive, how a locked deny of the hive holds against a
  repository, and how a host is denied while the mode is still `observe`.

  1. **Precedence.** A locked rule of the hive, then the repository's rule, then an unlocked
     rule of the hive. Rules meet on the same host string (or the same credential name),
     and the one that wins decides the host whole: action and paths.
  2. **A `*.` deny** also takes out every allow entry it covers (`*.example` covers
     `api.example` and `*.eu.example`), unless the allow has the higher precedence. The
     runner would deny those hosts by the deny anyway, deny being decided first; they are
     taken out of `allow` all the same so the document lists what is reachable and nothing
     else, and the page's count of hosts allowed is the truth.
  3. **A deny below a `*.` allow** stands beside it when it does not lose to that allow by
     precedence: `allow: ["*.example"], deny: ["tracker.example"]` denies `tracker.example`
     and reaches `api.example`, in either mode. When the allow outranks it (a locked
     `*.example` of the hive over a repository's deny) the deny is overridden. The one
     shape the document cannot say is the mirror: a `*.` deny with an allow below it that
     outranks the deny (the hive's unlocked `*.example` deny, a repository's own
     `api.example` allow). The allow wins by precedence and is rendered; the deny still
     takes out the allow entries it does outrank, but is **not written to `deny`**, since
     an entry there would deny the winning host too. Under `enforce` the hosts it covers
     are denied by having no allow, as before; under `observe` they are reached and
     recorded with no rule.
  4. **What the document cannot say is refused**: a `*.` suffix held to paths above another
     allowed entry (the runner holds a host to the path list of whichever entry of `paths`
     it finds first).
  5. A host held to paths is rendered in `allow` and in `paths`: the runner's proxy decides
     the connection by `deny`, then by `allow`, and only then the request by `paths`
     (`docs/contract-assumptions.md`). A denied host is never reached, so its paths and a
     credential for it never apply.

  `allow` and `deny` are sorted with names before `*.` suffixes, each alphabetically, so
  the rule a runner reports for a connection is the most exact one; `paths` and
  `credentials` are sorted by host and by name. The same rules always give the same
  effective policy.
  """

  alias Apiary.Policy.{Effective, Entry, Error, Grammar, Rule}

  @locked 3
  @repository 2
  @hive 1

  @doc """
  Resolves a repository's policy from the hive's mode and the repository's own, nil
  when it follows the hive: the repository's own mode wins, and the effective policy says
  which it was in `mode_source`. The rules resolve as in `resolve/4`, whatever the mode:
  a locked rule of the hive holds in a repository's document under either mode: its
  `deny` is denied under `observe` as under `enforce`, and its `allow` says what `enforce`
  would reach.
  """
  @spec resolve_for(String.t(), String.t() | nil, [Rule.t()], [Rule.t()], Ecto.UUID.t() | nil) ::
          {:ok, Effective.t()} | {:error, Error.t()}
  def resolve_for(hive_mode, own_mode, hive_rules, repository_rules, repository_id) do
    {mode, source} =
      if own_mode in ["observe", "enforce"] and not is_nil(repository_id),
        do: {own_mode, :repository},
        else: {hive_mode, :hive}

    with {:ok, effective} <- resolve(mode, hive_rules, repository_rules, repository_id) do
      {:ok, %{effective | mode_source: source}}
    end
  end

  @doc """
  Resolves the rules. `repository_rules` is `[]` for the baseline and for a repository
  with no rules of its own.
  """
  @spec resolve(String.t(), [Rule.t()], [Rule.t()], Ecto.UUID.t() | nil) ::
          {:ok, Effective.t()} | {:error, Error.t()}
  def resolve(mode, hive_rules, repository_rules \\ [], repository_id \\ nil)
      when mode in ["observe", "enforce"] do
    entries =
      (Enum.map(hive_rules, &entry(&1, :hive)) ++
         Enum.map(repository_rules, &entry(&1, :repository)))
      |> Enum.with_index()
      |> Map.new(fn {entry, index} -> {index, entry} end)

    entries = entries |> same_subject() |> covered_by_deny() |> under_allow()

    with :ok <- one_path_list(entries) do
      {:ok, effective(mode, repository_id, entries)}
    end
  end

  defp entry(%Rule{} = rule, source) do
    %Entry{
      rule: rule,
      kind: String.to_existing_atom(rule.kind),
      action: String.to_existing_atom(rule.action),
      host: rule.host,
      paths: rule.paths,
      name: rule.name,
      argument: rule.argument,
      source: source,
      locked: source == :hive and rule.locked
    }
  end

  defp rank(%Entry{source: :hive, locked: true}), do: @locked
  defp rank(%Entry{source: :repository}), do: @repository
  defp rank(%Entry{}), do: @hive

  # Rules that meet on the same host or name: the highest precedence decides it whole.
  defp same_subject(entries) do
    entries
    |> Enum.group_by(fn {_index, entry} -> {entry.kind, entry.host || entry.name} end)
    |> Enum.reduce(entries, fn {_subject, group}, entries ->
      {winner, _entry} = Enum.max_by(group, fn {_index, entry} -> rank(entry) end)

      Enum.reduce(group, entries, fn
        {^winner, _entry}, entries -> entries
        {loser, _entry}, entries -> override(entries, loser, winner)
      end)
    end)
  end

  # A `*.` deny removes the allow entries it covers, unless the allow outranks it.
  defp covered_by_deny(entries) do
    denies = for {index, %{action: :deny} = entry} <- in_force(entries, :host), do: {index, entry}

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{action: :allow} = allow}, entries ->
        denies
        |> Enum.filter(fn {_index, deny} ->
          deny.host != allow.host and Grammar.covers?(deny.host, allow.host) and
            rank(deny) >= rank(allow)
        end)
        |> Enum.max_by(fn {_index, deny} -> rank(deny) end, fn -> nil end)
        |> case do
          nil -> entries
          {deny, _entry} -> override(entries, index, deny)
        end

      _deny, entries ->
        entries
    end)
  end

  # A deny below an allowed `*.` suffix is lost to the allow when the allow outranks it (a
  # locked allow of the hive over a repository's deny); otherwise the two stand, the deny
  # decided first by the runner.
  defp under_allow(entries) do
    allows =
      for {index, %{action: :allow} = entry} <- in_force(entries, :host),
          Grammar.wildcard?(entry.host),
          do: {index, entry}

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{action: :deny} = deny}, entries ->
        allows
        |> Enum.filter(fn {_index, allow} ->
          allow.host != deny.host and Grammar.covers?(allow.host, deny.host) and
            rank(allow) > rank(deny)
        end)
        |> Enum.max_by(fn {_index, allow} -> rank(allow) end, fn -> nil end)
        |> case do
          nil -> entries
          {allow, _entry} -> override(entries, index, allow)
        end

      _allow, entries ->
        entries
    end)
  end

  defp one_path_list(entries) do
    allows = for {_index, %{action: :allow} = entry} <- in_force(entries, :host), do: entry

    conflict =
      for %{paths: paths} = above when is_list(paths) <- allows,
          Grammar.wildcard?(above.host),
          below <- allows,
          below.host != above.host and Grammar.covers?(above.host, below.host),
          do: {above, below}

    case conflict do
      [] ->
        :ok

      [{above, below} | _] ->
        {:error,
         Error.new(
           :conflict,
           "#{above.host} #{where(above)} is held to paths, and #{below.host} below it has a rule " <>
             "of its own #{where(below)}. A runner holds a host to one list of paths and cannot tell " <>
             "which of the two applies. Put the paths on the hosts by name, or remove the rule " <>
             "for #{below.host}.",
           :host
         )}
    end
  end

  defp where(%Entry{source: :hive, locked: true}), do: "in the hive (locked)"
  defp where(%Entry{source: :hive}), do: "in the hive"
  defp where(%Entry{source: :repository}), do: "in the repository"

  defp in_force(entries, kind) do
    entries
    |> Enum.filter(fn {_index, entry} -> entry.in_force and entry.kind == kind end)
    |> Enum.sort_by(fn {index, _entry} -> index end)
  end

  defp override(entries, loser, winner) do
    bare = fn entry -> %{entry | overridden_by: nil, overrides: []} end

    entries
    |> Map.update!(loser, &%{&1 | in_force: false, overridden_by: bare.(entries[winner])})
    |> Map.update!(winner, &%{&1 | overrides: &1.overrides ++ [bare.(entries[loser])]})
  end

  defp effective(mode, repository_id, entries) do
    hosts = for {_index, %{action: :allow} = entry} <- in_force(entries, :host), do: entry
    denies = for {_index, %{action: :deny} = entry} <- in_force(entries, :host), do: entry

    # A deny with an allow in force below it (one that outranks the deny, or it would have
    # been taken out) cannot be written: the runner would deny the winning host too.
    said =
      Enum.reject(denies, fn deny ->
        Enum.any?(hosts, &(&1.host != deny.host and Grammar.covers?(deny.host, &1.host)))
      end)

    credentials =
      for {_index, %{action: :allow} = entry} <- in_force(entries, :credential) do
        if entry.argument,
          do: %{name: entry.name, argument: entry.argument},
          else: %{name: entry.name}
      end

    %Effective{
      mode: mode,
      repository_id: repository_id,
      entries:
        entries
        |> Map.values()
        |> Enum.sort_by(&{&1.kind != :host, sort_key(&1.host || &1.name), &1.source != :hive}),
      allow: hosts |> Enum.map(& &1.host) |> Enum.sort_by(&sort_key/1),
      deny: said |> Enum.map(& &1.host) |> Enum.sort_by(&sort_key/1),
      paths:
        for(
          %{paths: paths} = entry when is_list(paths) <- hosts,
          into: %{},
          do: {entry.host, Enum.sort(Enum.uniq(paths))}
        ),
      credentials: Enum.sort_by(credentials, & &1.name)
    }
  end

  # Names before `*.` suffixes, each alphabetically.
  defp sort_key(host), do: {Grammar.wildcard?(host), host}
end
