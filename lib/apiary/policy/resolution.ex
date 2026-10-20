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
     The level above is not one rank: its **deny** is above every rule (no rule below
     allows the host; an integration's host is above it, point 7), and its **allow**
     reaches every workspace but may be narrowed: a lower deny on the same host, or a
     lower `*.` deny that covers it, beats it; against lower allows on the same host it
     holds, paths included, so its allow is never widened. An allow of the workspace or
     of the target is struck without a winner
     (`Apiary.Policy.Entry`'s `reason: :only_above_allows`) where the level above allows
     only the hosts on its list (`own_allows` off); denies still count. Where it requires
     `enforce` (`floor`), the mode in force is `enforce` whatever the workspace or the
     target set, `mode_source: :organisation`.
  2. **A `*.` deny** also takes out every allow entry it covers (`*.example` covers
     `api.example` and `*.eu.example`), unless the allow has the higher precedence or its
     host is an integration's host (point 7). The
     gateway would deny those hosts by the deny anyway, deny being decided first; they are
     taken out of `allow` all the same so the document lists what is reachable and nothing
     else, and the page's count of hosts allowed is the truth.
  3. **A deny below a `*.` allow** stands beside it when it does not lose to that allow by
     precedence: `allow: ["*.example"], deny: ["tracker.example"]` denies `tracker.example`
     and reaches `api.example`, in either mode. When the allow outranks it (a locked
     `*.example` of the workspace over a target's deny) the deny is overridden. The one
     shape the document cannot say is the mirror: a `*.` deny with an allow below it that
     outranks the deny (the workspace's unlocked `*.example` deny, a target's
     `api.example` allow). The allow wins by precedence and is rendered; the deny still
     takes out the allow entries it does outrank, but is **not written to `deny`**, since
     an entry there would deny the winning host too. Under `enforce` the hosts it covers
     are denied by having no allow, as before; under `observe` they are reached and
     recorded with no rule.
  4. **A `*.` suffix held to paths above another allowed entry is refused**: Qory Apiary
     doesn't let a `*.` suffix with paths cover another allowed host. The gateway holds a
     host to the path list of its most specific entry of `paths`: its name itself, else the
     `*.` entry with the longest suffix. A `*.` allow of the level above held to paths
     overrides every lower allow it covers instead, whatever its rank: the level above is
     never refused for a rule below it.
  5. **A rule whose host the grammar refuses** (`Apiary.Policy.Grammar.host?/1`), stored
     before the grammar refused it, such as the address `127.1`, is not in force
     (`Apiary.Policy.Entry`'s `reason: :out_of_grammar`) and is left out of the document:
     the gateway would refuse the whole document for it.
  6. A host held to paths is rendered in `allow` and in `paths`: the gateway decides
     the connection by `deny`, then by `allow`, and only then the request by `paths`
     (`docs/contract-assumptions.md`). A denied host is never reached, so its paths never
     apply.
  7. **An integration's host** (source `:integration`, `integrations` of `resolve/6`) is
     an exact host (`Apiary.Policy.Grammar.exact_host?/1`; any other is left out),
     allowed on every path, and no deny takes it out: it beats a deny of any rank on the
     same host, the level above's included, and a `*.` deny that covers it takes out
     neither its entry nor an allow of a rule on the same host. `allow_first` lists every
     integration's host, sorted, each once, and the document writes it to
     `egress.allow_first` (`Apiary.Policy.Render.allow_first/2`), which the gateway
     decides before `deny` and `allow`, in either mode. An integration's host is not in
     `allow`, unless a rule's allow on the same host is in force. A `*.` deny that covers
     an integration's host stays in force, is written to `deny`, takes out the other
     allows it covers (point 2), and is in the integration's entry's `overrides`: the
     gateway reaches the integration's host and denies every other host the deny covers.
     Among allows an integration's host has the lowest rank: an allow of the workspace,
     of a target or of the level above on the same host decides the host, paths included,
     and the integration's entry is overridden. Two integrations that list one host stay
     in force together. Where the level above allows only the hosts on its list, an
     integration's host is not struck. A `*.` allow held to paths, of any level, leaves
     it on every path: the document has the host in `paths` with `/*`.

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
  @integration_vs_deny 6
  @integration_among_allows 0

  @doc """
  Resolves a target's policy from the workspace's mode and the target's override, nil
  when it follows the workspace: the override wins, and the effective policy says
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
          Above.t() | nil,
          [integration_host]
        ) ::
          {:ok, Effective.t()} | {:error, Error.t()}
  def resolve_for(
        workspace_mode,
        own_mode,
        workspace_rules,
        target_rules,
        target_id,
        above \\ nil,
        integrations \\ []
      ) do
    above = Above.for_policy(above)

    {mode, source} =
      cond do
        match?(%Above{floor: true}, above) -> {"enforce", :organisation}
        own_mode in ["observe", "enforce"] and not is_nil(target_id) -> {own_mode, :target}
        true -> {workspace_mode, :workspace}
      end

    with {:ok, effective} <-
           resolve(mode, workspace_rules, target_rules, target_id, above, integrations) do
      {:ok, %{effective | mode_source: source}}
    end
  end

  @typedoc """
  A host an integration requires, as `Apiary.Connections.egress_hosts/1` reads it: the
  host, and the connection whose description lists it.
  """
  @type integration_host :: %{
          host: String.t(),
          connection: %{id: Ecto.UUID.t(), public_id: String.t(), name: String.t()}
        }

  @doc """
  Resolves the rules. `target_rules` is `[]` for the baseline and for a target
  with no rules; `above` is the level above the workspace, with its rules,
  or nil where the edition keeps none. A level that carries variables only
  (`Apiary.Policy.Above`'s `policy: false`) resolves as nil, here and in `resolve_for/7`.
  `integrations` is the hosts the integrations that reach the workspace require, each
  an entry with source `:integration`.
  """
  @spec resolve(
          String.t(),
          [Rule.t()],
          [Rule.t()],
          Ecto.UUID.t() | nil,
          Above.t() | nil,
          [integration_host]
        ) ::
          {:ok, Effective.t()} | {:error, Error.t()}
  def resolve(
        mode,
        workspace_rules,
        target_rules \\ [],
        target_id \\ nil,
        above \\ nil,
        integrations \\ []
      )
      when mode in ["observe", "enforce"] do
    above = Above.for_policy(above)

    entries =
      (Enum.map(above_rules(above), &entry(&1, :organisation)) ++
         Enum.map(workspace_rules, &entry(&1, :workspace)) ++
         Enum.map(target_rules, &entry(&1, :target)) ++
         for(
           %{host: host} = integration <- integrations,
           Grammar.exact_host?(host),
           do: integration_entry(integration)
         ))
      |> Enum.with_index()
      |> Map.new(fn {entry, index} -> {index, entry} end)

    entries =
      entries
      |> only_above_allows(above)
      |> out_of_grammar()
      |> same_subject()
      |> covered_by_deny()
      |> under_allow()
      |> under_above_allow()
      |> integration_under_deny()

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

  defp integration_entry(%{host: host, connection: connection}) do
    %Entry{
      kind: :host,
      action: :allow,
      host: host,
      source: :integration,
      connection: connection
    }
  end

  defp integration?(%Entry{source: source}), do: source == :integration

  # The precedence is not one rank. Against a deny, the level above's deny is above
  # every rule and its allow below every rule: a lower deny narrows it, and its `*.`
  # allow never overrides a lower deny. An integration's host is above every deny. Among
  # allows alone, the level above holds, paths included: its allow is never widened; and
  # an integration's host is below every rule's allow.
  defp rank_vs_deny(%Entry{source: :integration}), do: @integration_vs_deny
  defp rank_vs_deny(%Entry{source: :organisation, action: :deny}), do: @above_deny
  defp rank_vs_deny(%Entry{source: :organisation}), do: @above_allow
  defp rank_vs_deny(%Entry{source: :workspace, locked: true}), do: @locked
  defp rank_vs_deny(%Entry{source: :target}), do: @target
  defp rank_vs_deny(%Entry{}), do: @workspace

  defp rank_among_allows(%Entry{source: :integration}), do: @integration_among_allows
  defp rank_among_allows(%Entry{source: :organisation}), do: @above_among_allows
  defp rank_among_allows(%Entry{source: :workspace, locked: true}), do: @locked
  defp rank_among_allows(%Entry{source: :target}), do: @target
  defp rank_among_allows(%Entry{}), do: @workspace

  # Where the level above allows only the hosts on its list, every host allow below it is
  # struck before anything meets: nothing beat it, and the page says why. An
  # integration's host is not struck.
  defp only_above_allows(entries, %Above{own_allows: false}) do
    Map.new(entries, fn
      {index, %Entry{kind: :host, action: :allow, source: source} = entry}
      when source not in [:organisation, :integration] ->
        {index, %{entry | in_force: false, reason: :only_above_allows}}

      pair ->
        pair
    end)
  end

  defp only_above_allows(entries, _above), do: entries

  # A rule stored before the grammar refused its host (an address such as `127.1`, which
  # the gateway refuses the whole document for) is struck before anything meets: it is in
  # no list, covers nothing, and the page says why.
  defp out_of_grammar(entries) do
    Map.new(entries, fn {index, entry} ->
      if Grammar.host?(entry.host),
        do: {index, entry},
        else: {index, %{entry | in_force: false, reason: :out_of_grammar}}
    end)
  end

  # Rules that meet on the same host: the highest precedence decides it whole. Where an
  # integration's host decides it, the entries of other integrations on that host stay in
  # force beside it.
  defp same_subject(entries) do
    entries
    |> in_force(:host)
    |> Enum.group_by(fn {_index, entry} -> entry.host end)
    |> Enum.reduce(entries, fn {_subject, group}, entries ->
      {winner, winning} = winner(group)

      Enum.reduce(group, entries, fn
        {^winner, _entry}, entries ->
          entries

        {loser, losing}, entries ->
          if integration?(winning) and integration?(losing),
            do: entries,
            else: override(entries, loser, winner)
      end)
    end)
  end

  # The one that decides a subject: the deny that outranks every rule's allow, else the
  # allow of the highest rank among allows. A deny that outranks every rule's allow loses
  # to an integration's host, the first on the subject.
  defp winner(group) do
    {denies, allows} = Enum.split_with(group, fn {_index, entry} -> entry.action == :deny end)
    {integrations, rules} = Enum.split_with(allows, fn {_index, entry} -> integration?(entry) end)
    deny = Enum.max_by(denies, fn {_index, entry} -> rank_vs_deny(entry) end, fn -> nil end)
    allow = Enum.max_by(rules, fn {_index, entry} -> rank_vs_deny(entry) end, fn -> nil end)

    cond do
      allows == [] ->
        deny

      deny == nil ->
        Enum.max_by(allows, fn {_index, entry} -> rank_among_allows(entry) end)

      allow != nil and rank_vs_deny(elem(allow, 1)) > rank_vs_deny(elem(deny, 1)) ->
        Enum.max_by(allows, fn {_index, entry} -> rank_among_allows(entry) end)

      integrations != [] ->
        hd(integrations)

      true ->
        deny
    end
  end

  # A `*.` deny removes the allow entries it covers, unless the allow outranks it, or its
  # host is an integration's host: no deny takes that host out (point 7).
  defp covered_by_deny(entries) do
    denies = for {index, %{action: :deny} = entry} <- in_force(entries, :host), do: {index, entry}
    integration_hosts = integration_hosts(entries)

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{action: :allow} = allow}, entries ->
        if MapSet.member?(integration_hosts, allow.host),
          do: entries,
          else: covered(entries, denies, index, allow)

      _deny, entries ->
        entries
    end)
  end

  defp covered(entries, denies, index, allow) do
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
  end

  # The hosts of every integration entry, in force or not.
  defp integration_hosts(entries) do
    for {_index, %Entry{source: :integration, host: host}} <- entries,
        into: MapSet.new(),
        do: host
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
  # whatever its rank: the level above's allow is never widened, and the level above is
  # never refused for a rule below it. The lower allow is narrowed to the level's paths.
  defp under_above_allow(entries) do
    held =
      for {index, %{action: :allow, source: :organisation, paths: paths} = entry}
          when is_list(paths) <- in_force(entries, :host),
          Grammar.wildcard?(entry.host),
          do: {index, entry}

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{action: :allow, source: source} = allow}, entries
      when source not in [:organisation, :integration] ->
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

  # A `*.` deny that covers an integration's host stays in force and is written to
  # `deny`. The integration's entry lists it in `overrides`: the host is in
  # `allow_first` (point 7).
  defp integration_under_deny(entries) do
    denies =
      for {index, %{action: :deny} = entry} <- in_force(entries, :host),
          Grammar.wildcard?(entry.host),
          do: {index, entry}

    bare = fn entry -> %{entry | overridden_by: nil, overrides: []} end

    Enum.reduce(in_force(entries, :host), entries, fn
      {index, %{source: :integration} = allow}, entries ->
        covering =
          for {_index, deny} <- denies,
              deny.host != allow.host and Grammar.covers?(deny.host, allow.host),
              do: bare.(deny)

        Map.update!(entries, index, &%{&1 | overrides: &1.overrides ++ covering})

      _entry, entries ->
        entries
    end)
  end

  # An integration's host is on every path, whatever `*.` allow held to paths covers it
  # (`effective/4` writes it in `paths` with `/*`), so it is never in a conflict.
  defp one_path_list(entries, above_level) do
    allows = for {_index, %{action: :allow} = entry} <- in_force(entries, :host), do: entry

    conflict =
      for %{paths: paths} = above when is_list(paths) <- allows,
          Grammar.wildcard?(above.host),
          below <- allows,
          not integration?(below),
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
                 "Qory Apiary doesn't let a *. suffix with paths cover another allowed host."
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
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a separate rule in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:organisation, :locked, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a separate rule in the workspace (locked).",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:organisation, :workspace, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a separate rule in the workspace.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:organisation, :target, above, below, name),
    do:
      gettext(
        "%{above} in %{name}'s policy is held to paths, and %{below} below it has a separate rule in the target.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:locked, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a separate rule in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:workspace, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a separate rule in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:target, :organisation, above, below, name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a separate rule in %{name}'s policy.",
        above: above,
        below: below,
        name: name
      )

  defp held_and_below(:locked, :locked, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a separate rule in the workspace (locked).",
        above: above,
        below: below
      )

  defp held_and_below(:locked, :workspace, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a separate rule in the workspace.",
        above: above,
        below: below
      )

  defp held_and_below(:locked, :target, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace (locked) is held to paths, and %{below} below it has a separate rule in the target.",
        above: above,
        below: below
      )

  defp held_and_below(:workspace, :locked, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a separate rule in the workspace (locked).",
        above: above,
        below: below
      )

  defp held_and_below(:workspace, :workspace, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a separate rule in the workspace.",
        above: above,
        below: below
      )

  defp held_and_below(:workspace, :target, above, below, _name),
    do:
      gettext(
        "%{above} in the workspace is held to paths, and %{below} below it has a separate rule in the target.",
        above: above,
        below: below
      )

  defp held_and_below(:target, :locked, above, below, _name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a separate rule in the workspace (locked).",
        above: above,
        below: below
      )

  defp held_and_below(:target, :workspace, above, below, _name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a separate rule in the workspace.",
        above: above,
        below: below
      )

  defp held_and_below(:target, :target, above, below, _name),
    do:
      gettext(
        "%{above} in the target is held to paths, and %{below} below it has a separate rule in the target.",
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
    allow_first = entries |> integration_hosts() |> Enum.sort()

    # A deny with an allow in force below it (one that outranks the deny, or it would have
    # been taken out) cannot be written: the gateway would deny the winning host too. An
    # integration's host below a `*.` deny does not keep the deny out of `deny`: the host
    # is in `allow_first` (point 7).
    said =
      Enum.reject(denies, fn deny ->
        Enum.any?(
          hosts,
          &(&1.host != deny.host and &1.host not in allow_first and
              Grammar.covers?(deny.host, &1.host))
        )
      end)

    held =
      for %{paths: paths} = entry when is_list(paths) <- hosts,
          into: %{},
          do: {entry.host, Enum.sort(Enum.uniq(paths))}

    # An integration's host that a `*.` allow held to paths covers would be held to that
    # allow's paths: `/*` keeps it on every path.
    every_path =
      for %{source: :integration, host: host} <- hosts,
          not Map.has_key?(held, host),
          Enum.any?(Map.keys(held), &(&1 != host and Grammar.covers?(&1, host))),
          into: %{},
          do: {host, ["/*"]}

    %Effective{
      mode: mode,
      target_id: target_id,
      above: above,
      entries:
        entries
        |> Enum.sort_by(fn {index, _entry} -> index end)
        |> Enum.map(fn {_index, entry} -> entry end)
        |> Enum.sort_by(&{sort_key(&1.host), source_order(&1.source)}),
      allow:
        hosts
        |> Enum.reject(&integration?/1)
        |> Enum.map(& &1.host)
        |> Enum.uniq()
        |> Enum.sort_by(&sort_key/1),
      deny: said |> Enum.map(& &1.host) |> Enum.sort_by(&sort_key/1),
      paths: Map.merge(held, every_path),
      allow_first: allow_first
    }
  end

  # Names before `*.` suffixes, each alphabetically.
  defp sort_key(host), do: {Grammar.wildcard?(host), host}

  # On one subject, the level above's entry first, then the workspace's, then the
  # target's, then the integrations'.
  defp source_order(:organisation), do: 0
  defp source_order(:workspace), do: 1
  defp source_order(:target), do: 2
  defp source_order(:integration), do: 3
end
