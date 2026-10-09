defmodule Apiary.Policy.Resolution do
  @moduledoc """
  What the rules of a workspace and of one target come to. Pure: rules in, an
  `Apiary.Policy.Effective` out, or the sentence that says why the rules cannot be
  rendered.

  The contract's document says what is denied and what is allowed: `egress.deny` is
  decided by the gateway first and holds in either mode, `egress.allow` decides after it and
  only under `enforce`. So a deny rule is written to the document, which is how a
  target disables a host of the workspace, how a locked deny of the workspace holds
  against a target, and how a host is denied while the mode is still `observe`.

  1. **Precedence.** A rule of the level above the workspace, where the edition keeps one
     (`Apiary.Policy.Above`, source `:organisation`), then a locked rule of the workspace,
     then the target's rule, then an unlocked rule of the workspace. Rules meet on the
     same host string, and the one that wins decides the host whole: action and paths.
     The level above is not one rank: its **deny** is above everything (nothing below
     allows the host), and its **allow** reaches every workspace but may be narrowed: a
     lower deny on the same host, or a lower `*.` deny that covers it, beats it; against
     lower allows on the same host it holds, paths included, so its allow is never
     widened. An allow of the workspace or of the target is struck without a winner
     (`Apiary.Policy.Entry`'s `reason: :only_above_allows`) where the level above allows
     only its own hosts (`own_allows` off); denies still count. Where it requires
     `enforce` (`floor`), the mode in force is `enforce` whatever the workspace or the
     target set, `mode_source: :organisation`.
  2. **A `*.` deny** also takes out every allow entry it covers (`*.example` covers
     `api.example` and `*.eu.example`), unless the allow has the higher precedence. The
     gateway would deny those hosts by the deny anyway, deny being decided first; they are
     taken out of `allow` all the same so the document lists what is reachable and nothing
     else, and the page's count of hosts allowed is the truth.
  3. **A deny below a `*.` allow** stands beside it when it does not lose to that allow by
     precedence: `allow: ["*.example"], deny: ["tracker.example"]` denies `tracker.example`
     and reaches `api.example`, in either mode. When the allow outranks it (a locked
     `*.example` of the workspace over a target's deny) the deny is overridden. The one
     shape the document cannot say is the mirror: a `*.` deny with an allow below it that
     outranks the deny (the workspace's unlocked `*.example` deny, a target's own
     `api.example` allow). The allow wins by precedence and is rendered; the deny still
     takes out the allow entries it does outrank, but is **not written to `deny`**, since
     an entry there would deny the winning host too. Under `enforce` the hosts it covers
     are denied by having no allow, as before; under `observe` they are reached and
     recorded with no rule.
  4. **What the document cannot say is refused**: a `*.` suffix held to paths above another
     allowed entry (the gateway holds a host to the path list of whichever entry of `paths`
     it finds first). A `*.` allow of the level above held to paths overrides every lower
     allow it covers instead, whatever its rank: the level above is never refused for a
     rule below it.
  5. A host held to paths is rendered in `allow` and in `paths`: the gateway decides
     the connection by `deny`, then by `allow`, and only then the request by `paths`
     (`docs/contract-assumptions.md`). A denied host is never reached, so its paths never
     apply.

  `allow` and `deny` are sorted with names before `*.` suffixes, each alphabetically, so
  the rule the gateway reports for a connection is the most exact one; `paths` is sorted by
  host. The same rules always give the same effective policy.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Policy.{Above, Effective, Entry, Error, Grammar, Rule}

  @above_deny 5
  @above_allow 0
  @locked 3
  @target 2
  @workspace 1
  @above_among_allows 4

  @doc """
  Resolves a target's policy from the workspace's mode and the target's own, nil
  when it follows the workspace: the target's own mode wins, and the effective policy says
  which it was in `mode_source`; where the level above requires `enforce` (`above`'s
  `floor`), that is the mode, from `:organisation`. The rules resolve as in `resolve/5`,
  whatever the mode: a locked rule of the workspace holds in a target's document under
  either mode: its `deny` is denied under `observe` as under `enforce`, and its `allow`
  says what `enforce` would reach.
  """
  @spec resolve_for(
          String.t(),
          String.t() | nil,
          [Rule.t()],
          [Rule.t()],
          Ecto.UUID.t() | nil,
          Above.t() | nil
        ) ::
          {:ok, Effective.t()} | {:error, Error.t()}
  def resolve_for(
        workspace_mode,
        own_mode,
        workspace_rules,
        target_rules,
        target_id,
        above \\ nil
      ) do
    above = Above.for_policy(above)

    {mode, source} =
      cond do
        match?(%Above{floor: true}, above) -> {"enforce", :organisation}
        own_mode in ["observe", "enforce"] and not is_nil(target_id) -> {own_mode, :target}
        true -> {workspace_mode, :workspace}
      end

    with {:ok, effective} <- resolve(mode, workspace_rules, target_rules, target_id, above) do
      {:ok, %{effective | mode_source: source}}
    end
  end

  @doc """
  Resolves the rules. `target_rules` is `[]` for the baseline and for a target
  with no rules of its own; `above` is the level above the workspace, with its rules,
  or nil where the edition keeps none. A level that carries variables only
  (`Apiary.Policy.Above`'s `policy: false`) resolves as nil, here and in `resolve_for/6`.
  """
  @spec resolve(String.t(), [Rule.t()], [Rule.t()], Ecto.UUID.t() | nil, Above.t() | nil) ::
          {:ok, Effective.t()} | {:error, Error.t()}
  def resolve(mode, workspace_rules, target_rules \\ [], target_id \\ nil, above \\ nil)
      when mode in ["observe", "enforce"] do
    above = Above.for_policy(above)

    entries =
      (Enum.map(above_rules(above), &entry(&1, :organisation)) ++
         Enum.map(workspace_rules, &entry(&1, :workspace)) ++
         Enum.map(target_rules, &entry(&1, :target)))
      |> Enum.with_index()
      |> Map.new(fn {entry, index} -> {index, entry} end)

    entries =
      entries
      |> only_above_allows(above)
      |> same_subject()
      |> covered_by_deny()
      |> under_allow()
      |> under_above_allow()

    with :ok <- one_path_list(entries, above) do
      {:ok, effective(mode, target_id, entries, above)}
    end
  end

  defp above_rules(%Above{rules: rules}), do: Enum.filter(rules, &(&1.kind == "host"))
  defp above_rules(nil), do: []

  defp entry(%Rule{} = rule, source) do
    %Entry{
      rule: rule,
      kind: String.to_existing_atom(rule.kind),
      action: String.to_existing_atom(rule.action),
      host: rule.host,
      paths: rule.paths,
      source: source,
      locked: source == :workspace and rule.locked
    }
  end

  # The precedence is not one rank. Against a deny, the level above's deny is above
  # everything and its allow below everything: a lower deny narrows it, and its own `*.`
  # allow never overrides a lower deny. Among allows alone, the level above holds, paths
  # included: its allow is never widened.
  defp rank_vs_deny(%Entry{source: :organisation, action: :deny}), do: @above_deny
  defp rank_vs_deny(%Entry{source: :organisation}), do: @above_allow
  defp rank_vs_deny(%Entry{source: :workspace, locked: true}), do: @locked
  defp rank_vs_deny(%Entry{source: :target}), do: @target
  defp rank_vs_deny(%Entry{}), do: @workspace

  defp rank_among_allows(%Entry{source: :organisation}), do: @above_among_allows
  defp rank_among_allows(%Entry{source: :workspace, locked: true}), do: @locked
  defp rank_among_allows(%Entry{source: :target}), do: @target
  defp rank_among_allows(%Entry{}), do: @workspace

  # Where the level above allows only its own hosts, every host allow below it is struck
  # before anything meets: nothing beat it, and the page says why.
  defp only_above_allows(entries, %Above{own_allows: false}) do
    Map.new(entries, fn
      {index, %Entry{kind: :host, action: :allow, source: source} = entry}
      when source != :organisation ->
        {index, %{entry | in_force: false, reason: :only_above_allows}}

      pair ->
        pair
    end)
  end

  defp only_above_allows(entries, _above), do: entries

  # Rules that meet on the same host: the highest precedence decides it whole.
  defp same_subject(entries) do
    entries
    |> in_force(:host)
    |> Enum.group_by(fn {_index, entry} -> entry.host end)
    |> Enum.reduce(entries, fn {_subject, group}, entries ->
      {winner, _entry} = winner(group)

      Enum.reduce(group, entries, fn
        {^winner, _entry}, entries -> entries
        {loser, _entry}, entries -> override(entries, loser, winner)
      end)
    end)
  end

  # The one that decides a subject: the deny that outranks every allow, else the allow of
  # the highest rank among allows.
  defp winner(group) do
    {denies, allows} = Enum.split_with(group, fn {_index, entry} -> entry.action == :deny end)
    deny = Enum.max_by(denies, fn {_index, entry} -> rank_vs_deny(entry) end, fn -> nil end)

    allow =
      Enum.max_by(allows, fn {_index, entry} -> rank_vs_deny(entry) end, fn -> nil end)

    cond do
      allow == nil ->
        deny

      deny == nil ->
        Enum.max_by(allows, fn {_index, entry} -> rank_among_allows(entry) end)

      rank_vs_deny(elem(deny, 1)) >= rank_vs_deny(elem(allow, 1)) ->
        deny

      true ->
        Enum.max_by(allows, fn {_index, entry} -> rank_among_allows(entry) end)
    end
  end

  # A `*.` deny removes the allow entries it covers, unless the allow outranks it.
  defp covered_by_deny(entries) do
    denies = for {index, %{action: :deny} = entry} <- in_force(entries, :host), do: {index, entry}

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{action: :allow} = allow}, entries ->
        denies
        |> Enum.filter(fn {_index, deny} ->
          deny.host != allow.host and Grammar.covers?(deny.host, allow.host) and
            rank_vs_deny(deny) >= rank_vs_deny(allow)
        end)
        |> Enum.max_by(fn {_index, deny} -> rank_vs_deny(deny) end, fn -> nil end)
        |> case do
          nil -> entries
          {deny, _entry} -> override(entries, index, deny)
        end

      _deny, entries ->
        entries
    end)
  end

  # A deny below an allowed `*.` suffix is lost to the allow when the allow outranks it (a
  # locked allow of the workspace over a target's deny); otherwise the two stand, the deny
  # decided first by the gateway.
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
            rank_vs_deny(allow) > rank_vs_deny(deny)
        end)
        |> Enum.max_by(fn {_index, allow} -> rank_vs_deny(allow) end, fn -> nil end)
        |> case do
          nil -> entries
          {allow, _entry} -> override(entries, index, allow)
        end

      _allow, entries ->
        entries
    end)
  end

  # A `*.` allow of the level above held to paths overrides every lower allow it covers,
  # whatever its rank: the document cannot hold both, and the level above is never
  # refused for a rule below it. The lower allow is narrowed to the level's paths.
  defp under_above_allow(entries) do
    held =
      for {index, %{action: :allow, source: :organisation, paths: paths} = entry}
          when is_list(paths) <- in_force(entries, :host),
          Grammar.wildcard?(entry.host),
          do: {index, entry}

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{action: :allow, source: source} = allow}, entries when source != :organisation ->
        held
        |> Enum.filter(fn {_index, above} ->
          above.host != allow.host and Grammar.covers?(above.host, allow.host)
        end)
        |> List.first()
        |> case do
          nil -> entries
          {above, _entry} -> override(entries, index, above)
        end

      _entry, entries ->
        entries
    end)
  end

  defp one_path_list(entries, above_level) do
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
           Enum.join(
             [
               held_and_below(
                 where(above),
                 where(below),
                 above.host,
                 below.host,
                 above_name(above_level)
               ),
               pgettext(
                 "plain",
                 "The gateway holds a host to one list of paths and cannot tell which of the two applies."
               ),
               gettext("Put the paths on the hosts by name, or remove the rule for %{host}.",
                 host: below.host
               )
             ],
             " "
           ),
           :host
         )}
    end
  end

  defp where(%Entry{source: :organisation}), do: :organisation
  defp where(%Entry{source: :workspace, locked: true}), do: :locked
  defp where(%Entry{source: :workspace}), do: :workspace
  defp where(%Entry{source: :target}), do: :target

  defp above_name(%Above{name: name}), do: name
  defp above_name(nil), do: nil

  # Where each of the two rules is, as whole sentences; the level above is named by its
  # name, which is the one word the core says of it.
  defp held_and_below(where_above, where_below, above, below, name)

  defp held_and_below(:organisation, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a rule of its own in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:organisation, :locked, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a rule of its own in the workspace (locked).",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:organisation, :workspace, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a rule of its own in the workspace.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:organisation, :target, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a rule of its own in the target.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:locked, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a rule of its own in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:workspace, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a rule of its own in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:target, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a rule of its own in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:locked, :locked, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a rule of its own in the workspace (locked).",
        above: above,
        below: below
      )

  defp held_and_below(:locked, :workspace, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a rule of its own in the workspace.",
        above: above,
        below: below
      )

  defp held_and_below(:locked, :target, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a rule of its own in the target.",
        above: above,
        below: below
      )

  defp held_and_below(:workspace, :locked, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a rule of its own in the workspace (locked).",
        above: above,
        below: below
      )

  defp held_and_below(:workspace, :workspace, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a rule of its own in the workspace.",
        above: above,
        below: below
      )

  defp held_and_below(:workspace, :target, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a rule of its own in the target.",
        above: above,
        below: below
      )

  defp held_and_below(:target, :locked, above, below, _name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a rule of its own in the workspace (locked).",
        above: above,
        below: below
      )

  defp held_and_below(:target, :workspace, above, below, _name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a rule of its own in the workspace.",
        above: above,
        below: below
      )

  defp held_and_below(:target, :target, above, below, _name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a rule of its own in the target.",
        above: above,
        below: below
      )

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

  defp effective(mode, target_id, entries, above) do
    hosts = for {_index, %{action: :allow} = entry} <- in_force(entries, :host), do: entry
    denies = for {_index, %{action: :deny} = entry} <- in_force(entries, :host), do: entry

    # A deny with an allow in force below it (one that outranks the deny, or it would have
    # been taken out) cannot be written: the gateway would deny the winning host too.
    said =
      Enum.reject(denies, fn deny ->
        Enum.any?(hosts, &(&1.host != deny.host and Grammar.covers?(deny.host, &1.host)))
      end)

    %Effective{
      mode: mode,
      target_id: target_id,
      above: above,
      entries:
        entries
        |> Map.values()
        |> Enum.sort_by(&{sort_key(&1.host), source_order(&1.source)}),
      allow: hosts |> Enum.map(& &1.host) |> Enum.sort_by(&sort_key/1),
      deny: said |> Enum.map(& &1.host) |> Enum.sort_by(&sort_key/1),
      paths:
        for(
          %{paths: paths} = entry when is_list(paths) <- hosts,
          into: %{},
          do: {entry.host, Enum.sort(Enum.uniq(paths))}
        )
    }
  end

  # Names before `*.` suffixes, each alphabetically.
  defp sort_key(host), do: {Grammar.wildcard?(host), host}

  # On one subject, the level above's entry first, then the workspace's, then the target's.
  defp source_order(:organisation), do: 0
  defp source_order(:workspace), do: 1
  defp source_order(:target), do: 2
end
