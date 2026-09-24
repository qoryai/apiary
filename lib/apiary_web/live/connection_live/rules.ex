defmodule ApiaryWeb.ConnectionLive.Rules do
  @moduledoc """
  What a connection's row may ask of the policy (`docs/design/brief-policy.md`, pd8), for
  the run's connections tab and for the hive's connections page.

  A row's **standing** is derived from the effective policy the page holds, never by a
  query per row: whether the row can ask for an allow or a deny, whether a locked rule of
  the hive decides its host, whether the wall refused it (no rule changes that), or
  whether a rule now in force already answers what the row recorded. The record is never
  rewritten: a row that was denied stays denied, and a rule that answers it is said on a
  line of its own (`after_line/3`).

  Everything a row carries is a runner's input. A host is put through the policy's own
  grammar before it is compared with a rule, and nothing here becomes an atom.
  """

  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Policy
  alias Apiary.Policy.{Effective, Entry, Grammar}

  ## Paths of the policy pages

  @doc "The page of one version of the baseline (`nil`) or of a target."
  def version_path(target_id, n, query \\ %{})

  def version_path(nil, n, query), do: ~p"/hive/policy/versions/#{n}?#{query}"

  def version_path(target_id, n, query),
    do: ~p"/hive/policy/targets/#{target_id}/versions/#{n}?#{query}"

  @doc "The rule of `host` on the hive's policy page (`nil`) or on a target's."
  def rule_path(nil, host), do: ~p"/hive/policy?#{%{"rule" => host}}"

  def rule_path(target_id, host),
    do: ~p"/hive/policy/targets/#{target_id}?#{%{"rule" => host}}"

  @doc "A target's policy page."
  def target_policy_path(target_id), do: ~p"/hive/policy/targets/#{target_id}"

  ## Versions

  @doc """
  The version a digest names for the target (or the baseline, `nil`): `%{n, digest,
  scope, target_id, label, path, rendered_at}`, or nil when this hive rendered nothing
  with that digest. One indexed read.
  """
  def version(_scope, _target, digest) when not is_binary(digest), do: nil

  def version(scope, target, digest) do
    case Policy.configuration_for_digest(scope, target, digest) do
      {:ok, configuration} -> version_of(configuration, target)
      _ -> nil
    end
  end

  @doc """
  A run configuration as the pages here name a version. Versions count per holder, the
  baseline's apart from each target's, so every version is named with its `label`:
  "hive baseline", or the target's system and path when `target` is the one the
  configuration is of.
  """
  def version_of(configuration, target \\ nil) do
    %{
      n: configuration.version,
      digest: configuration.digest,
      scope: if(configuration.target_id, do: :target, else: :hive),
      target_id: configuration.target_id,
      label: version_label(configuration.target_id, target),
      rendered_at: configuration.rendered_at,
      path: version_path(configuration.target_id, configuration.version)
    }
  end

  @doc "The words that say whose numbering a version is in."
  def version_label(nil, _target), do: gettext("hive baseline")
  def version_label(id, %{id: id, system: system, path: path}), do: "#{system}/#{path}"
  def version_label(_id, _target), do: gettext("target")

  @doc """
  `Policy.digests/2`, whatever shape it answers in, as `%{in_force, reported, applied,
  drift}`; every value nil and no drift when the domain refuses.
  """
  def digests(scope, run) do
    case Policy.digests(scope, run) do
      %{in_force: _} = digests -> digests
      _refused -> %{in_force: nil, reported: nil, applied: nil, drift: false}
    end
  end

  ## Standing

  @doc """
  What the row's slot holds: `%{standing:, host:, entry:}` with `standing` one of
  `:can_allow`, `:can_deny`, `:locked_deny`, `:locked_allow`, `:wall`, `:unnameable`,
  `{:rule_added, :allow | :deny}`. `entry` is the rule in force that decides the host,
  when one does. A `:can_allow` row carries `deny: true` when no rule decides its host:
  a host let through under observe, or denied by default under enforce, can be denied
  outright as well, so the policy is written while the record is read. `page` is `:run` or `:hive`: on the hive's page a row allowed by a rule
  the baseline does not hold (a target's own) can still be denied.

  `own` matters on the hive's page, where the rows stand against the baseline alone: the
  hosts targets have rules of their own for (`own_hosts/1`), or `:unknown`. There a
  baseline rule is said to answer a row only when no target's own rule could be what
  decides it; otherwise the row keeps its button, since the baseline is not the whole
  answer.
  """
  def standing(row, effective, page \\ :run, own \\ [])

  def standing(row, %Effective{} = effective, page, own) do
    c = read(row)
    host = host(c.host)

    cond do
      wall?(c) ->
        %{standing: :wall, host: host, entry: nil}

      is_nil(host) ->
        %{standing: :unnameable, host: nil, entry: nil}

      needs_allow?(c) ->
        wants_allow(effective, host, c.path, own_touches?(own, host, page))

      true ->
        wants_deny(effective, host, c.path, page, own_touches?(own, host, page))
    end
  end

  def standing(_row, _effective, _page, _own),
    do: %{standing: :unnameable, host: nil, entry: nil}

  defp wants_allow(effective, host, path, own?) do
    cond do
      allowed_now?(effective, host, path) and not own? ->
        %{standing: {:rule_added, :allow}, host: host, entry: allow_entry(effective, host)}

      entry = locked(effective, host, :deny) ->
        %{standing: :locked_deny, host: host, entry: entry}

      entry = locked(effective, host, :allow) ->
        %{standing: :locked_allow, host: host, entry: entry}

      true ->
        # A deny rule that agrees with the record still decides the host: the row keeps
        # its Allow, so the decision can be turned, and no second deny is offered.
        entry = deny_entry(effective, host)
        %{standing: :can_allow, host: host, entry: entry, deny: is_nil(entry)}
    end
  end

  defp wants_deny(effective, host, path, page, own?) do
    cond do
      (entry = deny_entry(effective, host)) && not own? ->
        %{standing: {:rule_added, :deny}, host: host, entry: entry}

      entry = locked(effective, host, :allow) ->
        %{standing: :locked_allow, host: host, entry: entry}

      allowed_now?(effective, host, path) or page == :hive ->
        %{standing: :can_deny, host: host, entry: allow_entry(effective, host)}

      true ->
        %{standing: :can_allow, host: host, entry: nil, deny: true}
    end
  end

  @doc "Whether a target's own rule could be what decides `host`, from `own_hosts/1`."
  def own_touches?(own, host, page \\ :hive)
  def own_touches?(_own, _host, :run), do: false
  def own_touches?(_own, nil, _page), do: false
  def own_touches?(:unknown, _host, :hive), do: true

  def own_touches?(own, host, :hive) when is_list(own),
    do: Enum.any?(own, &(Grammar.covers?(&1, host) or Grammar.covers?(host, &1)))

  def own_touches?(_own, _host, _page), do: false

  @doc """
  The hosts the hive's targets have rules of their own for, from the rules of every
  target that has any: one read for the list and one a target with rules, fifty
  of them at most. `:unknown` past that, and past the five hundred targets the list
  holds: then nothing is claimed of a row from the baseline alone.
  """
  def own_hosts(scope) do
    listed = Policy.list_targets(scope)
    with_rules = Enum.filter(listed, &(&1.rule_count > 0))

    if length(listed) >= 500 or length(with_rules) > 50 do
      :unknown
    else
      for %{target: target} <- with_rules,
          %{kind: "host", host: host} <- Policy.list_rules(scope, target),
          uniq: true,
          do: host
    end
  end

  @doc """
  What `Apiary.Policy.rule_from_connection/4` will make of a row in a holder whose
  effective policy is `effective`: `%{kind: :path, paths: held}` when the host is held to
  paths there and the row names a path (the path is added to them, or taken out), else
  `%{kind: :host, paths: held}`. The popover says this for the scope chosen, never for
  another.
  """
  def what(%Effective{} = effective, host, path) do
    held = held_paths(effective, host)
    %{kind: if(held && path not in [nil, ""], do: :path, else: :host), paths: held}
  end

  def what(_effective, _host, _path), do: nil

  @doc "Whether the target of this effective policy has a rule of its own that touches the host."
  def own_rule?(%Effective{entries: entries}, host) when is_binary(host) do
    Enum.any?(
      entries,
      &(&1.kind == :host and &1.source == :target and
          (Grammar.covers?(&1.host, host) or Grammar.covers?(host, &1.host)))
    )
  end

  def own_rule?(_effective, _host), do: false

  @doc """
  Every rule of the effective policy that touches the host, in force or not, as plain
  terms: what a popover saw when it opened. When it is not the same at the moment of
  sending, the policy changed under the reader, and nothing is sent.
  """
  def seen(%Effective{entries: entries}, host) when is_binary(host) do
    for entry <- entries,
        entry.kind == :host,
        Grammar.covers?(entry.host, host) or Grammar.covers?(host, entry.host) do
      {entry.source, entry.action, entry.host, entry.paths, entry.locked, entry.in_force}
    end
    |> Enum.sort()
  end

  def seen(_effective, _host), do: []

  @doc """
  A row that was denied and is now allowed by a rule added lately is a row a rule
  answered: once the run reloads, its last attempt is allowed by that rule and the record
  says so, and the line after must still say "In force in this run" with the link to the
  rule, not offer to deny it. So `:can_deny` on a row with denials becomes
  `{:rule_added, :allow}` while the rule's change is on the newest page of its history.
  """
  def answered(%{standing: :can_deny, entry: %Entry{} = entry} = standing, row, changes) do
    denied = Map.get(row, :denied) || 0

    if denied > 0 and change_for(entry, changes) != nil,
      do: %{standing | standing: {:rule_added, :allow}},
      else: standing
  end

  # The mirror: a row let through with no rule (observe) that a deny rule added lately
  # now decides is a row that rule answered, and its line says so, with the link to the
  # rule. A row that was denied already gains no line from a deny that agrees with it.
  def answered(
        %{standing: :can_allow, entry: %Entry{action: :deny} = entry} = standing,
        row,
        changes
      ) do
    if read(row).decision == "allowed" and change_for(entry, changes) != nil,
      do: %{standing | standing: {:rule_added, :deny}},
      else: standing
  end

  def answered(standing, _row, _changes), do: standing

  @doc """
  The words of the toast, from the rule the domain made. `where` is the holder the rule
  went to: `:hive`, `:this_target`, or `{:target, label}` for a target named by its label
  (`version_label/2`).
  """
  def toast(rule, action, host, path, where) do
    pathed? = is_list(rule.paths) and path not in [nil, ""] and rule.action == "allow"

    cond do
      pathed? and action == :allow -> path_allowed(where, path, host)
      pathed? -> path_no_longer_allowed(where, path, host)
      rule.action == "deny" -> host_denied(where, host)
      true -> host_allowed(where, host)
    end
  end

  defp path_allowed(:hive, path, host),
    do: gettext("%{path} on %{host} is allowed for the hive.", path: path, host: host)

  defp path_allowed(:this_target, path, host),
    do: gettext("%{path} on %{host} is allowed for this target.", path: path, host: host)

  defp path_allowed({:target, label}, path, host),
    do:
      gettext("%{path} on %{host} is allowed for %{label}.", path: path, host: host, label: label)

  defp path_no_longer_allowed(:hive, path, host),
    do: gettext("%{path} on %{host} is no longer allowed for the hive.", path: path, host: host)

  defp path_no_longer_allowed(:this_target, path, host),
    do:
      gettext("%{path} on %{host} is no longer allowed for this target.", path: path, host: host)

  defp path_no_longer_allowed({:target, label}, path, host),
    do:
      gettext("%{path} on %{host} is no longer allowed for %{label}.",
        path: path,
        host: host,
        label: label
      )

  defp host_denied(:hive, host), do: gettext("%{host} is denied for the hive.", host: host)

  defp host_denied(:this_target, host),
    do: gettext("%{host} is denied for this target.", host: host)

  defp host_denied({:target, label}, host),
    do: gettext("%{host} is denied for %{label}.", host: host, label: label)

  defp host_allowed(:hive, host), do: gettext("%{host} is allowed for the hive.", host: host)

  defp host_allowed(:this_target, host),
    do: gettext("%{host} is allowed for this target.", host: host)

  defp host_allowed({:target, label}, host),
    do: gettext("%{host} is allowed for %{label}.", host: host, label: label)

  # A row wants an allow when its last attempt was denied, or was let through with no rule.
  defp needs_allow?(%{decision: "denied"}), do: true
  defp needs_allow?(%{decision: "allowed", rule: rule}) when rule in [nil, ""], do: true
  defp needs_allow?(_c), do: false

  defp wall?(%{rule: "wall:" <> _}), do: true
  defp wall?(%{path_rule: "wall:" <> _}), do: true
  defp wall?(_c), do: false

  @doc "The mode of the row's last attempt, from either page's row shape, or nil."
  def mode(row), do: Map.get(row, :mode) || Map.get(row, :last_mode)

  @doc "A row's host as a rule would name it, or nil when no rule can."
  def host(host) when is_binary(host) and byte_size(host) <= 255 do
    host = host |> String.downcase() |> String.trim_trailing(".")
    if Grammar.host?(host) and not Grammar.wildcard?(host), do: host
  end

  def host(_host), do: nil

  @doc "The paths the host is held to in the policy, or nil when it is reached on every path."
  def held_paths(%Effective{paths: paths}, host) when is_binary(host) do
    case Enum.find(paths, fn {key, _paths} -> Grammar.covers?(key, host) end) do
      {_key, held} -> held
      nil -> nil
    end
  end

  def held_paths(_effective, _host), do: nil

  # As the runner decides: `deny` first, in either mode, then `allow`, then the paths.
  defp allowed_now?(%Effective{allow: allow, deny: deny} = effective, host, path) do
    not Grammar.matches?(deny, host) and Grammar.matches?(allow, host) and
      case held_paths(effective, host) do
        nil -> true
        held -> path in [nil, ""] or Enum.any?(held, &Grammar.path_matches?(&1, path))
      end
  end

  defp hosts(%Effective{entries: entries}),
    do: Enum.filter(entries, &(&1.kind == :host and &1.in_force))

  defp allow_entry(effective, host) do
    allows = Enum.filter(hosts(effective), &(&1.action == :allow))

    Enum.find(allows, &(&1.host == host)) ||
      Enum.find(allows, &Grammar.covers?(&1.host, host))
  end

  defp deny_entry(effective, host) do
    denies = Enum.filter(hosts(effective), &(&1.action == :deny))

    Enum.find(denies, &(&1.host == host)) ||
      Enum.find(denies, &Grammar.covers?(&1.host, host))
  end

  defp locked(effective, host, action) do
    Enum.find(
      hosts(effective),
      &(&1.locked and &1.source == :hive and &1.action == action and
          Grammar.covers?(&1.host, host))
    )
  end

  # Both spellings of a connection (see `ApiaryWeb.RunComponents.connection_row/1`).
  defp read(row) do
    %{
      host: Map.get(row, :host),
      path: Map.get(row, :path) || "",
      decision: Map.get(row, :decision) || Map.get(row, :last_decision),
      rule: Map.get(row, :rule) || Map.get(row, :last_rule),
      path_rule: Map.get(row, :path_rule) || Map.get(row, :last_path_rule)
    }
  end

  ## The line after

  @doc """
  The change that made the rule of `entry`, from the newest page of the history of the
  entry's own scope: `%{version:, by:, by_id:, at:}` or nil when it is further back. Handed
  the pages already read, so a page of rows costs one read a scope.
  """
  def change_for(%Entry{} = entry, changes) when is_map(changes) do
    key = if entry.source == :target, do: :target, else: :hive

    changes
    |> Map.get(key, [])
    |> Enum.find(
      &(&1.subject == entry.host and &1.action in ~w(rule_added rule_changed) and
          host_rule?(&1, entry.host))
    )
    |> case do
      nil ->
        nil

      change ->
        %{
          version: change.version_after,
          by: change.changed_by && change.changed_by.email,
          by_id: change.changed_by_id,
          at: change.inserted_at
        }
    end
  end

  def change_for(_entry, _changes), do: nil

  # A credential may be named like a host; its change says nothing of the host's rule.
  defp host_rule?(%{after: %{"rules" => rules}}, host) when is_list(rules),
    do: Enum.any?(rules, &(&1["kind"] == "host" and &1["host"] == host))

  defp host_rule?(_change, _host), do: false

  @doc """
  The newest page of changes of each scope the entries of these standings were written
  in: `%{hive: [...], target: [...]}`. At most two reads, and none when no row has a
  rule to speak of.
  """
  def changes(scope, target, standings) do
    sources =
      for %{standing: standing, entry: %Entry{source: source}} <- standings,
          match?({:rule_added, _}, standing) or standing in [:can_deny, :can_allow],
          uniq: true,
          do: source

    for source <- sources, into: %{} do
      holder = if source == :target, do: target, else: nil
      key = if source == :target, do: :target, else: :hive

      {key, Policy.list_changes(scope, holder, 1).items}
    end
  end
end
