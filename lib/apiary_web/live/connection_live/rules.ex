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

  alias Apiary.Policy
  alias Apiary.Policy.{Effective, Entry, Grammar}

  ## Paths of the policy pages

  @doc "The page of one version of the baseline (`nil`) or of a repository."
  def version_path(repository_id, n, query \\ %{})

  def version_path(nil, n, query), do: with_query("/hive/policy/versions/#{n}", query)

  def version_path(repository_id, n, query),
    do: with_query("/hive/policy/repositories/#{repository_id}/versions/#{n}", query)

  @doc "The rule of `host` on the hive's policy page (`nil`) or on a repository's."
  def rule_path(nil, host), do: with_query("/hive/policy", %{"rule" => host})

  def rule_path(repository_id, host),
    do: with_query("/hive/policy/repositories/#{repository_id}", %{"rule" => host})

  @doc "A repository's policy page."
  def repository_path(repository_id), do: "/hive/policy/repositories/#{repository_id}"

  defp with_query(path, query) when map_size(query) == 0, do: path
  defp with_query(path, query), do: path <> "?" <> URI.encode_query(query)

  ## Versions

  @doc """
  The version a digest names for the repository (or the baseline, `nil`): `%{n, digest,
  scope, repository_id, path, rendered_at}`, or nil when this hive rendered nothing with
  that digest. One indexed read.
  """
  def version(_scope, _repository, digest) when not is_binary(digest), do: nil

  def version(scope, repository, digest) do
    case Policy.configuration_for_digest(scope, repository, digest) do
      {:ok, configuration} -> version_of(configuration)
      _ -> nil
    end
  end

  @doc "A run configuration as the pages here name a version."
  def version_of(configuration) do
    %{
      n: configuration.version,
      digest: configuration.digest,
      scope: if(configuration.repository_id, do: :repository, else: :hive),
      repository_id: configuration.repository_id,
      rendered_at: configuration.rendered_at,
      path: version_path(configuration.repository_id, configuration.version)
    }
  end

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
  when one does. `page` is `:run` or `:hive`: on the hive's page a row allowed by a rule
  the baseline does not hold (a repository's own) can still be denied.
  """
  def standing(row, effective, page \\ :run)

  def standing(row, %Effective{} = effective, page) do
    c = read(row)
    host = host(c.host)

    cond do
      wall?(c) ->
        %{standing: :wall, host: host, entry: nil}

      is_nil(host) ->
        %{standing: :unnameable, host: nil, entry: nil}

      needs_allow?(c) ->
        wants_allow(effective, host, c.path)

      true ->
        wants_deny(effective, host, c.path, page)
    end
  end

  def standing(_row, _effective, _page), do: %{standing: :unnameable, host: nil, entry: nil}

  defp wants_allow(effective, host, path) do
    cond do
      allowed_now?(effective, host, path) ->
        %{standing: {:rule_added, :allow}, host: host, entry: allow_entry(effective, host)}

      entry = locked(effective, host, :deny) ->
        %{standing: :locked_deny, host: host, entry: entry}

      entry = locked(effective, host, :allow) ->
        %{standing: :locked_allow, host: host, entry: entry}

      true ->
        %{standing: :can_allow, host: host, entry: nil}
    end
  end

  defp wants_deny(effective, host, path, page) do
    cond do
      entry = deny_entry(effective, host) ->
        %{standing: {:rule_added, :deny}, host: host, entry: entry}

      entry = locked(effective, host, :allow) ->
        %{standing: :locked_allow, host: host, entry: entry}

      allowed_now?(effective, host, path) or page == :hive ->
        %{standing: :can_deny, host: host, entry: allow_entry(effective, host)}

      true ->
        %{standing: :can_allow, host: host, entry: nil}
    end
  end

  # A row wants an allow when its last attempt was denied, or was let through with no rule.
  defp needs_allow?(%{decision: "denied"}), do: true
  defp needs_allow?(%{decision: "allowed", rule: rule}) when rule in [nil, ""], do: true
  defp needs_allow?(_c), do: false

  defp wall?(%{rule: "wall:" <> _}), do: true
  defp wall?(%{path_rule: "wall:" <> _}), do: true
  defp wall?(_c), do: false

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

  defp allowed_now?(%Effective{allow: allow} = effective, host, path) do
    Grammar.matches?(allow, host) and
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
    key = if entry.source == :repository, do: :repository, else: :hive

    changes
    |> Map.get(key, [])
    |> Enum.find(&(&1.subject == entry.host and &1.action in ~w(rule_added rule_changed)))
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

  @doc """
  The newest page of changes of each scope the entries of these standings were written
  in: `%{hive: [...], repository: [...]}`. At most two reads, and none when no row has a
  rule to speak of.
  """
  def changes(scope, repository, standings) do
    sources =
      for %{standing: {:rule_added, _}, entry: %Entry{source: source}} <- standings,
          uniq: true,
          do: source

    for source <- sources, into: %{} do
      target = if source == :repository, do: repository, else: nil
      key = if source == :repository, do: :repository, else: :hive
      {key, Policy.list_changes(scope, target, 1).items}
    end
  end
end
