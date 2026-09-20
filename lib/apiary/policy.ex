defmodule Apiary.Policy do
  @moduledoc """
  The security policy of a hive and of its repositories, the run configurations rendered
  from it, and the history of both. Pages call this module and nothing under it.

  ## The model

  The contract's policy document can only allow: a mode, the hosts allowed, the paths a
  host is held to, the credentials of the machine's a run may use. The hive has a mode
  (`get_mode/1`, `set_mode/2`) and a baseline of rules; a repository has rules of its own
  on top. A rule (`Apiary.Policy.Rule`) allows or denies a host or a credential. A deny is
  the apiary's own notion: it takes entries out of what is rendered, so a repository can
  disable a host of the hive, and a **locked** rule of the hive holds against every
  repository. How the rules come to one policy is `Apiary.Policy.Resolution`'s to say.

  ## Writes

  Every write is one transaction: the rule, a `policy_changes` row, and the render of the
  baseline and of every repository that has rules (or has had a configuration) of its own.
  A render is validated against the contract's schema before it is stored; a change whose
  render the schema or the resolution refuses is rolled back and answered with a sentence.
  A render that gives the same bytes as the version in force writes no new version. After
  the commit `{:policy_changed, %{hive_id:, repository_id:, action:}}` goes out on
  `topic/1`, `"policy:<hive_id>"`.

  Members edit rules. Only an owner changes the mode (in either direction), and only an
  owner locks, unlocks, changes or removes a locked rule.

  ## Returns

  Reads return what they read. Everything that can be refused returns `{:ok, value}` or
  `{:error, %Apiary.Policy.Error{}}`, whose `message` is a sentence for the page.

  A target is `nil` or `:hive` for the hive's baseline, or an `Apiary.Runs.Repository` of
  the scope's hive. Another hive's repository, rule or configuration is not found.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations
  alias Apiary.Organisations.{Hive, Membership, Organisation}
  alias Apiary.Policy.{Activity, Change, Effective, Error, Export, Grammar, Render, Resolution}
  alias Apiary.Policy.{Rule, RunConfiguration, Schema, Suggestions}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Repository, Run}

  @modes ~w(observe enforce)
  @page_size 25
  # The most rules one list holds (the baseline's, or a repository's). With at most
  # `Grammar.paths_max/0` paths a rule, it bounds a change's `before` and `after`, which
  # repeat the list, and so the history's growth: quadratic in the rules, up to this.
  @rules_max 500
  @nobody "00000000-0000-0000-0000-000000000000"

  @type target :: nil | :hive | Repository.t()
  @type refusal :: {:error, Error.t()}
  @type page(item) :: %{
          items: [item],
          page: pos_integer,
          pages: pos_integer,
          total: non_neg_integer
        }

  ## Topics

  @doc "The topic of a hive's policy: `\"policy:<hive_id>\"`."
  def topic(hive_id), do: "policy:#{hive_id}"

  @doc "Subscribes the caller to the policy of the scope's hive."
  def subscribe(%Scope{hive: %Hive{id: hive_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(hive_id))
  end

  ## Managed

  @doc """
  Whether somebody has made the hive's policy: there is a change in its history, the
  first rule or the first change of mode. Until then the hive serves no run
  configuration at all (discovery names no `run` section, the endpoint answers `404`, the
  answers to batches name no digest of one), so its machines use the policy of their own
  `runner.yaml`: an upgrade, or a hive nobody has looked at, takes no machine's
  enforcement away. From the first change on, every run of the hive takes the hive's
  policy. For the pages: "machines use their own policy until the first change here".
  """
  @spec managed?(Scope.t()) :: boolean
  def managed?(%Scope{hive: %Hive{id: hive_id}}), do: managed_hive?(hive_id)

  @doc false
  def managed_hive?(hive_id) do
    Repo.exists?(from c in Change, where: c.hive_id == ^hive_id)
  end

  ## Repositories

  @doc """
  The hive's repositories, by forge and path, each with `rule_count`, how many rules of
  its own it has (a virtual count on the map, not the struct): `[%{repository: …,
  rule_count: n}]`. At most 500.
  """
  @spec list_repositories(Scope.t()) :: [%{repository: Repository.t(), rule_count: integer}]
  def list_repositories(%Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}}) do
    Repo.all(
      from p in Repository,
        where: p.hive_id == ^hive_id and p.organisation_id == ^org_id,
        left_join: r in Rule,
        on: r.repository_id == p.id,
        group_by: p.id,
        order_by: [asc: p.forge, asc: p.path],
        limit: 500,
        select: %{repository: p, rule_count: count(r.id)}
    )
  end

  @doc "One repository of the scope's hive by id."
  @spec get_repository(Scope.t(), String.t()) :: {:ok, Repository.t()} | refusal
  def get_repository(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Repository{} = repository <- Repo.one(from p in repositories(scope), where: p.id == ^id) do
      {:ok, repository}
    else
      _ -> {:error, not_found("This hive has no such repository.")}
    end
  end

  ## Mode

  @doc "Every mode: `observe` records and denies nothing, `enforce` denies what no rule allows."
  def modes, do: @modes

  @doc "The mode of the hive's policy, `\"observe\"` or `\"enforce\"`, as it is now."
  @spec get_mode(Scope.t()) :: String.t()
  def get_mode(%Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}}) do
    Repo.one!(
      from h in Hive,
        where: h.id == ^hive_id and h.organisation_id == ^org_id,
        select: h.egress_mode
    )
  end

  @doc """
  Sets the mode of the hive, in either direction an owner's act: a member is refused
  with a sentence. The mode is the hive's alone: a repository has none of its own.
  """
  @spec set_mode(Scope.t(), String.t()) :: {:ok, String.t()} | refusal
  def set_mode(%Scope{} = scope, mode) when mode in @modes do
    with {:ok, membership} <- member(scope),
         :ok <-
           owner(
             membership,
             "Only an owner changes the mode: it decides what every run of the hive is denied."
           ) do
      write(scope, nil, fn hive ->
        if hive.egress_mode != mode do
          Repo.update_all(from(h in Hive, where: h.id == ^hive.id),
            set: [egress_mode: mode, updated_at: DateTime.utc_now()]
          )
        end

        {:ok, mode, "mode_changed", nil}
      end)
    end
  end

  def set_mode(%Scope{}, _mode) do
    {:error, Error.new(:invalid, "The mode is observe or enforce.", :mode)}
  end

  ## Rules

  @doc "The rules of the baseline (`nil`) or of a repository, hosts first, by host and name."
  @spec list_rules(Scope.t(), target) :: [Rule.t()]
  def list_rules(%Scope{} = scope, target) do
    case target_id(scope, target) do
      {:ok, repository_id} -> rules(scope.hive.id, repository_id)
      {:error, _not_found} -> []
    end
  end

  @doc "One rule of the scope's hive by id."
  @spec get_rule(Scope.t(), String.t()) :: {:ok, Rule.t()} | refusal
  def get_rule(%Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Rule{} = rule <-
           Repo.one(
             from r in Rule,
               where: r.id == ^id and r.hive_id == ^hive_id and r.organisation_id == ^org_id
           ) do
      {:ok, rule}
    else
      _ -> {:error, not_found("This hive has no such rule.")}
    end
  end

  @doc """
  The policy in force for the baseline (`nil`) or for a repository: every rule that takes
  part as an `Apiary.Policy.Entry` (where it came from, whether it is in force, what
  overrode it, what it overrides), and the `allow`, `paths` and `credentials` the document
  says. A repository that is not the hive's gets the baseline.
  """
  @spec effective(Scope.t(), target) :: Effective.t()
  def effective(%Scope{} = scope, target) do
    repository_id =
      case target_id(scope, target) do
        {:ok, repository_id} -> repository_id
        {:error, _not_found} -> nil
      end

    hive_rules = rules(scope.hive.id, nil)
    own = if repository_id, do: rules(scope.hive.id, repository_id), else: []

    case Resolution.resolve(get_mode(scope), hive_rules, own, repository_id) do
      {:ok, effective} -> effective
      # No write leaves rules that do not resolve; should one be there all the same, the
      # page shows the hive's mode and nothing allowed rather than raise.
      {:error, _error} -> %Effective{mode: get_mode(scope), repository_id: repository_id}
    end
  end

  @doc """
  Allows a host or a credential in the target, replacing the target's rule for the same
  host or name when there is one.

  `attrs`, with atom or string keys: `kind` (`"host"`, the default, or `"credential"`);
  for a host `host` and `paths` (a list, or a text of one path a line, for the paths the
  host is held to; `[]` for no path at all; `nil` for every path); for a credential
  `name` and `argument`; `locked`, `true` or `false` and nothing else (the hive's rules
  only, owners only).

  What `attrs` does not name stays as the rule there has it: the lock, the paths, the
  argument. So allowing a host that is held to paths does not open it: every path takes
  the key, `paths: nil`. A paths text with no path in it (a form's empty field) names
  nothing. A new rule without `paths` is on every path. At most #{@rules_max} rules a list
  and #{Grammar.paths_max()} paths a rule.
  """
  @spec allow(Scope.t(), target, map) :: {:ok, Rule.t()} | refusal
  def allow(%Scope{} = scope, target, attrs), do: put_rule(scope, target, "allow", attrs)

  @doc """
  Denies a host or a credential in the target, as `allow/3` allows one. A deny takes the
  whole host: `paths` is not read. A deny of a host below an allowed `*.` suffix is
  refused with a sentence, since the document could not say it.
  """
  @spec deny(Scope.t(), target, map) :: {:ok, Rule.t()} | refusal
  def deny(%Scope{} = scope, target, attrs), do: put_rule(scope, target, "deny", attrs)

  @doc """
  Adds `path` to the paths `host` is held to in the target. The paths in force for the
  target are taken as the start, so a repository that adds a path keeps the hive's and
  from then on has a list of its own. Refused when the host is already reached on every
  path, and in a repository when the hive's rule for the host is locked.
  """
  @spec allow_path(Scope.t(), target, String.t(), String.t()) :: {:ok, Rule.t()} | refusal
  def allow_path(%Scope{} = scope, target, host, path),
    do: put_path(scope, target, host, path, :allow)

  @doc """
  Takes `path` out of the paths `host` is held to in the target. Refused when the host is
  reached on every path (the document cannot allow every path but one) and when the path
  is allowed by a pattern rather than by itself.
  """
  @spec deny_path(Scope.t(), target, String.t(), String.t()) :: {:ok, Rule.t()} | refusal
  def deny_path(%Scope{} = scope, target, host, path),
    do: put_path(scope, target, host, path, :deny)

  @doc "Removes a rule, given itself or its id. A locked rule is an owner's to remove."
  @spec remove_rule(Scope.t(), Rule.t() | String.t()) :: {:ok, Rule.t()} | refusal
  def remove_rule(%Scope{} = scope, rule_or_id) do
    with {:ok, membership} <- member(scope),
         {:ok, rule} <- get_rule(scope, rule_id(rule_or_id)) do
      # Who may remove it is decided on the rule as it is under the hive's lock.
      write(scope, rule.repository_id, fn hive ->
        with {:ok, rule} <- reread(hive, rule),
             :ok <- may_change(membership, rule) do
          Repo.delete_all(from r in Rule, where: r.id == ^rule.id)
          {:ok, rule, "rule_removed", Rule.subject(rule)}
        end
      end)
    end
  end

  @doc "Locks a rule of the hive, so no repository overrides it. Owners only."
  @spec lock(Scope.t(), Rule.t() | String.t()) :: {:ok, Rule.t()} | refusal
  def lock(%Scope{} = scope, rule_or_id), do: set_locked(scope, rule_or_id, true)

  @doc "Unlocks a rule of the hive. Owners only."
  @spec unlock(Scope.t(), Rule.t() | String.t()) :: {:ok, Rule.t()} | refusal
  def unlock(%Scope{} = scope, rule_or_id), do: set_locked(scope, rule_or_id, false)

  @doc """
  The rule a connection's row asks for (C4, C5): allow or deny its host, in the run's
  repository (`:repository`) or in the hive (`:hive`). When the host is held to paths in
  the target and the connection names a path, the path is added to or taken out of those
  paths instead. The connection is one of the scope's hive.
  """
  @spec rule_from_connection(Scope.t(), Connection.t(), :allow | :deny, :repository | :hive) ::
          {:ok, Rule.t()} | refusal
  def rule_from_connection(%Scope{} = scope, %Connection{} = connection, action, level)
      when action in [:allow, :deny] and level in [:repository, :hive] do
    with {:ok, _membership} <- member(scope),
         {:ok, host} <- connection_host(scope, connection),
         {:ok, target} <- connection_target(scope, connection, level) do
      held = effective(scope, target).paths

      key =
        if Map.has_key?(held, host),
          do: host,
          else: Enum.find(Map.keys(held), &Grammar.covers?(&1, host))

      cond do
        key && connection.path not in [nil, ""] ->
          put_path(scope, target, key, connection.path, action)

        key && action == :allow ->
          {:error,
           Error.new(
             :invalid,
             "#{key} is held to paths, and this connection names no path, so there is no path to add. Allowing the host from here would open every path of it: change the rule's paths on the policy page instead.",
             :paths
           )}

        action == :allow ->
          allow(scope, target, %{host: host})

        true ->
          deny(scope, target, %{host: host})
      end
    end
  end

  ## What the record says about the rules

  @typedoc "A destination enforce would start denying: see `uncovered/2`."
  @type uncovered :: %{
          host: String.t(),
          path: String.t() | nil,
          attempts: non_neg_integer,
          runs: non_neg_integer,
          last_seen_at: DateTime.t(),
          repositories: [%{id: Ecto.UUID.t(), forge: String.t(), path: String.t()}]
        }

  @doc """
  The destinations that were let through since `since` and that today's rules do not
  cover: what enforce would start denying. A destination is a host, and a path as well
  where the host is held to paths. Each connection is held to the effective policy of
  its own run's repository (the baseline for a run without one), matched as the runner
  matches. Each destination says its allowed `attempts`, how many `runs` made them, when
  it was last seen and in which `repositories`; the 50 with the most attempts, most first.

  Read from `connections` by the hive and when they were last seen, at most
  #{Apiary.Policy.Activity.cap()} rows: beyond that the answer is `:unavailable`, never a
  count of a part. A connection counts whole when it was last seen since `since`.
  """
  @spec uncovered(Scope.t(), DateTime.t()) :: {:ok, [uncovered]} | :unavailable
  def uncovered(%Scope{hive: %Hive{}} = scope, %DateTime{} = since),
    do: Activity.uncovered(scope, since)

  @doc """
  How many attempts were denied since `since`, and to how many destinations (host, port
  and path): the enforce card's fact line. Bounded as `uncovered/2` is.
  """
  @spec denied_summary(Scope.t(), DateTime.t()) ::
          {:ok, %{denied: non_neg_integer, destinations: non_neg_integer}} | :unavailable
  def denied_summary(%Scope{hive: %Hive{}} = scope, %DateTime{} = since),
    do: Activity.denied_summary(scope, since)

  @doc """
  Per rule id, the attempts allowed and denied since `since`: `%{rule_id => %{allowed: n,
  denied: n}}`, a rule nothing reached being absent. For the baseline (`nil`) every
  connection of the hive is read, for a repository those of its runs; each is held to the
  effective policy of its run's repository and counted on the rule the runner would
  report: the first entry of `allow` that matches (names before `*.` suffixes), else the
  deny in force that covers the host; and on the credential rule the connection named.
  So a repository's page may name rules of the hive, and the hive's page counts a hive
  rule wherever it decided. Bounded as `uncovered/2` is.
  """
  @spec rule_activity(Scope.t(), target, DateTime.t()) ::
          {:ok,
           %{optional(Ecto.UUID.t()) => %{allowed: non_neg_integer, denied: non_neg_integer}}}
          | :unavailable
  def rule_activity(%Scope{hive: %Hive{}} = scope, target, %DateTime{} = since) do
    case target_id(scope, target) do
      {:ok, repository_id} -> Activity.rule_activity(scope, repository_id, since)
      {:error, _not_found} -> {:ok, %{}}
    end
  end

  ## Suggestions

  @doc """
  The hosts the repository's harness declared (`harness_hosts` of its runs' policy
  applied events, the newest runs first) that the repository's effective policy neither
  covers nor denies: `[%{host:, runs:, last_seen_at:}]`, at most 50. Hosts that are not in the
  contract's grammar are left out.
  """
  @spec suggestions(Scope.t(), Repository.t()) :: [
          %{host: String.t(), runs: pos_integer, last_seen_at: DateTime.t()}
        ]
  def suggestions(%Scope{} = scope, %Repository{} = repository) do
    case target_id(scope, repository) do
      {:ok, repository_id} ->
        Suggestions.list(scope.hive.id, repository_id, effective(scope, repository))

      {:error, _not_found} ->
        []
    end
  end

  ## Run configurations

  @doc """
  The run configuration in force for the baseline (`nil`) or for a repository: the highest
  version. A repository that never had rules of its own is served the baseline's, and the
  row says so by its `repository_id`. For a hive nobody has changed yet (`managed?/1` is
  false) this renders what the baseline would be, `observe` with nothing allowed, so a
  page has something to show; no runner is served it until the hive is managed.
  """
  @spec current_configuration(Scope.t(), target) :: {:ok, RunConfiguration.t()} | refusal
  def current_configuration(%Scope{hive: %Hive{} = hive} = scope, target) do
    with {:ok, repository_id} <- target_id(scope, target) do
      in_force(hive.organisation_id, hive.id, repository_id)
    end
  end

  @doc "One version of the baseline's (`nil`) or of a repository's run configurations."
  @spec get_configuration(Scope.t(), target, pos_integer | String.t()) ::
          {:ok, RunConfiguration.t()} | refusal
  def get_configuration(%Scope{} = scope, target, version) do
    with {:ok, repository_id} <- target_id(scope, target),
         {:ok, version} <- version(version),
         %RunConfiguration{} = configuration <-
           Repo.one(
             from c in configurations(scope.hive.id, repository_id), where: c.version == ^version
           ) do
      {:ok, configuration}
    else
      _ -> {:error, not_found("There is no such version of this run configuration.")}
    end
  end

  @doc """
  The run configuration a digest names, as a run reported it: the repository's own
  version with that digest when it has one, the baseline's otherwise; the newest when the
  same bytes were in force more than once.
  """
  @spec configuration_for_digest(Scope.t(), target, String.t() | nil) ::
          {:ok, RunConfiguration.t()} | refusal
  def configuration_for_digest(%Scope{} = scope, target, digest) when is_binary(digest) do
    with {:ok, repository_id} <- target_id(scope, target),
         %RunConfiguration{} = configuration <-
           by_digest(scope.hive.id, repository_id, digest) ||
             (repository_id && by_digest(scope.hive.id, nil, digest)) do
      {:ok, configuration}
    else
      _ -> {:error, not_found("This hive served no run configuration with that digest.")}
    end
  end

  def configuration_for_digest(%Scope{}, _target, _digest),
    do: {:error, not_found("This hive served no run configuration with that digest.")}

  @doc "The versions of the baseline (`nil`) or of a repository, newest first, a page of #{@page_size}."
  @spec list_configurations(Scope.t(), target, pos_integer) :: page(RunConfiguration.t())
  def list_configurations(%Scope{} = scope, target, page \\ 1) do
    case target_id(scope, target) do
      {:ok, repository_id} ->
        configurations(scope.hive.id, repository_id)
        |> order_by([c], desc: c.version)
        |> preload(:changed_by)
        |> paginate(page)

      {:error, _not_found} ->
        empty_page()
    end
  end

  @doc """
  The digest in force for a run and what the run last reported, for the run's header:
  `%{in_force:, reported:, applied:, drift:}`. `in_force` is read now, never stored;
  `reported` is the `X-Qory-Run-Configuration` of the run's last batch that carried one;
  `applied` is what its last policy applied event named. `drift` is true when the run
  reported a digest other than the one in force, which is a run that has not reloaded
  yet, and false when it reported none: such a run holds no fetched configuration. A run of another hive is a
  refusal, `{:error, %Apiary.Policy.Error{reason: :not_found}}`, not a map.
  """
  @spec digests(Scope.t(), Run.t()) ::
          %{
            in_force: String.t() | nil,
            reported: String.t() | nil,
            applied: String.t() | nil,
            drift: boolean
          }
          | refusal
  def digests(%Scope{hive: %Hive{id: hive_id} = hive}, %Run{hive_id: hive_id} = run) do
    in_force =
      case in_force(hive.organisation_id, hive_id, run.repository_id) do
        {:ok, configuration} -> configuration.digest
        {:error, _error} -> nil
      end

    reported = run.reported_run_configuration_digest

    %{
      in_force: in_force,
      reported: reported,
      applied: run.run_configuration_digest,
      drift: is_binary(reported) and is_binary(in_force) and reported != in_force
    }
  end

  def digests(%Scope{}, %Run{}), do: {:error, not_found("This hive has no such run.")}

  ## History

  @doc """
  The changes of the baseline (`nil`) or of a repository, newest first, a page of
  #{@page_size}, `changed_by` preloaded. `:all` as the target lists every change of the hive,
  `repository` preloaded.
  """
  @spec list_changes(Scope.t(), target | :all, pos_integer) :: page(Change.t())
  def list_changes(%Scope{hive: %Hive{id: hive_id}} = scope, target, page \\ 1) do
    query =
      from c in Change, where: c.hive_id == ^hive_id, order_by: [desc: c.inserted_at, desc: c.id]

    case target do
      :all ->
        query |> preload([:changed_by, :repository]) |> paginate(page)

      target ->
        case target_id(scope, target) do
          {:ok, nil} ->
            query |> where([c], is_nil(c.repository_id)) |> preload(:changed_by) |> paginate(page)

          {:ok, repository_id} ->
            query
            |> where([c], c.repository_id == ^repository_id)
            |> preload(:changed_by)
            |> paginate(page)

          {:error, _not_found} ->
            empty_page()
        end
    end
  end

  @doc "One change of the scope's hive by id, `changed_by` and `repository` preloaded."
  @spec get_change(Scope.t(), String.t()) :: {:ok, Change.t()} | refusal
  def get_change(%Scope{hive: %Hive{id: hive_id}}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Change{} = change <-
           Repo.one(
             from c in Change,
               where: c.id == ^id and c.hive_id == ^hive_id,
               preload: [:changed_by, :repository]
           ) do
      {:ok, change}
    else
      _ -> {:error, not_found("This hive has no such change.")}
    end
  end

  @doc """
  What a change changed: `%{mode: nil | {from, to}, added: [rule], removed: [rule],
  changed: [{before, after}]}`, the rules as the JSON maps the change holds (`"kind"`,
  `"action"`, `"host"`, `"paths"`, `"name"`, `"argument"`, `"locked"`).
  """
  @spec diff(Change.t()) :: %{
          mode: nil | {String.t(), String.t()},
          added: [map],
          removed: [map],
          changed: [{map, map}]
        }
  def diff(%Change{before: before, after: after_}) do
    key = fn rule -> {rule["kind"], rule["host"] || rule["name"]} end
    old = Map.new(before["rules"] || [], &{key.(&1), &1})
    new = Map.new(after_["rules"] || [], &{key.(&1), &1})

    %{
      mode: if(before["mode"] != after_["mode"], do: {before["mode"], after_["mode"]}),
      added: for({k, rule} <- Enum.sort(new), not Map.has_key?(old, k), do: rule),
      removed: for({k, rule} <- Enum.sort(old), not Map.has_key?(new, k), do: rule),
      changed: for({k, rule} <- Enum.sort(new), old[k] not in [nil, rule], do: {old[k], rule})
    }
  end

  ## Export

  @doc """
  The effective policy as text for a node without a server (S7): `runner_file`, the
  `egress` section of `~/.config/qory/runner.yaml`, which holds the mode and the hosts;
  and `policy_file`, a document in the contract's policy format for `qory run --policy`,
  when the policy holds paths or credentials, which the runner file's section cannot say
  (nil otherwise). `notes` are sentences for the page.
  """
  @spec export(Scope.t(), target) ::
          {:ok, %{runner_file: String.t(), policy_file: String.t() | nil, notes: [String.t()]}}
  def export(%Scope{} = scope, target), do: {:ok, Export.text(effective(scope, target))}

  ## Writes, inside

  defp put_rule(scope, target, action, attrs) do
    with {:ok, attrs} <- attrs(attrs),
         {:ok, membership} <- member(scope),
         {:ok, repository_id} <- target_id(scope, target),
         {:ok, candidate} <- candidate(action, attrs),
         :ok <- lock_is_the_hives(repository_id, candidate.locked) do
      write(scope, repository_id, fn hive ->
        put(hive, scope.user, membership, repository_id, candidate, attrs)
      end)
    end
  end

  defp candidate(action, attrs) do
    %Rule{} |> Rule.changeset(Map.put(attrs, "action", action)) |> applied()
  end

  # Under the hive's lock: the rule already there is read here, so two writers of one
  # host meet as an add and a change, never as two adds, and who may change it is
  # decided on the row as it is now.
  defp put(hive, user, membership, repository_id, candidate, attrs) do
    existing = existing(hive.id, repository_id, candidate)

    with :ok <- may_change(membership, existing),
         :ok <- may_lock(membership, existing, attrs),
         :ok <- room(hive.id, repository_id, existing) do
      store(hive, user, repository_id, existing, candidate, attrs)
    end
  end

  defp room(_hive_id, _repository_id, %Rule{}), do: :ok

  defp room(hive_id, repository_id, nil) do
    if length(rules(hive_id, repository_id)) < @rules_max do
      :ok
    else
      {:error,
       Error.new(
         :invalid,
         "There are #{@rules_max} rules here already, which is the most one list holds. Remove one, or say several hosts with a *. suffix."
       )}
    end
  end

  defp store(hive, user, repository_id, nil, candidate, _attrs) do
    rule =
      Repo.insert!(%{
        candidate
        | organisation_id: hive.organisation_id,
          hive_id: hive.id,
          repository_id: repository_id,
          created_by_id: user_id(user)
      })

    {:ok, rule, "rule_added", Rule.subject(rule)}
  end

  # What the caller did not name stays: the lock, and the paths and the argument of an
  # allow. Opening a host held to paths to every path takes `paths: nil`, said.
  defp store(_hive, _user, _repository_id, %Rule{} = existing, candidate, attrs) do
    keep = fn key, given, held ->
      cond do
        candidate.action == "deny" -> nil
        Map.has_key?(attrs, key) -> given
        true -> held
      end
    end

    locked = if Map.has_key?(attrs, "locked"), do: candidate.locked, else: existing.locked

    rule =
      existing
      |> Ecto.Changeset.change(
        action: candidate.action,
        paths: keep.("paths", candidate.paths, existing.paths),
        argument: keep.("argument", candidate.argument, existing.argument),
        locked: locked
      )
      |> Repo.update!()

    {:ok, rule, "rule_changed", Rule.subject(rule)}
  end

  # The paths in force are read under the hive's lock, so a path added here is added to
  # what is there now and not to what was there when the page was drawn.
  defp put_path(scope, target, host, path, action) do
    host = host |> to_string() |> String.trim() |> String.downcase()

    with {:ok, membership} <- member(scope),
         {:ok, repository_id} <- target_id(scope, target),
         :ok <- a_path(path) do
      write(scope, repository_id, fn hive ->
        effective = effective(scope, target)

        with :ok <- not_locked_above(effective, repository_id, host),
             {:ok, paths} <- paths_after(effective, host, path, action),
             attrs = %{"host" => host, "paths" => paths},
             {:ok, candidate} <- candidate("allow", attrs) do
          put(hive, scope.user, membership, repository_id, candidate, attrs)
        end
      end)
    end
  end

  # A request's path as a rule: itself, never a pattern a request happened to spell.
  defp a_path(path) do
    if Grammar.path?(path) and not String.contains?(path, "*"),
      do: :ok,
      else: {:error, Error.new(:invalid, "This path cannot be written as a path rule.", :paths)}
  end

  defp not_locked_above(_effective, nil, _host), do: :ok

  defp not_locked_above(%Effective{entries: entries}, _repository_id, host) do
    if Enum.any?(
         entries,
         &(&1.kind == :host and &1.host == host and &1.source == :hive and &1.locked)
       ) do
      {:error,
       Error.new(
         :locked,
         "The hive's rule for #{host} is locked, so a repository cannot change its paths. An owner changes it in the hive.",
         :host
       )}
    else
      :ok
    end
  end

  defp paths_after(%Effective{} = effective, host, path, :allow) do
    case effective.paths do
      %{^host => paths} ->
        {:ok, Enum.uniq(paths ++ [path])}

      _ ->
        if host in effective.allow,
          do: {:error, Error.new(:invalid, "#{host} is already reached on every path.", :paths)},
          else: {:ok, [path]}
    end
  end

  defp paths_after(%Effective{} = effective, host, path, :deny) do
    case effective.paths do
      %{^host => paths} ->
        cond do
          path in paths ->
            {:ok, paths -- [path]}

          pattern = Enum.find(paths, &Grammar.path_matches?(&1, path)) ->
            {:error,
             Error.new(
               :invalid,
               "#{path} is allowed by the pattern #{pattern}. The document cannot take one path out of a pattern: replace #{pattern} with the paths that are needed.",
               :paths
             )}

          true ->
            {:error,
             Error.new(
               :invalid,
               "#{path} is not among the paths #{host} is held to, so it is denied already.",
               :paths
             )}
        end

      _ ->
        if host in effective.allow do
          {:error,
           Error.new(
             :invalid,
             "#{host} is reached on every path, and the document cannot allow every path but one. Hold #{host} to the paths it needs, and this one is denied by not being among them.",
             :paths
           )}
        else
          {:error,
           Error.new(:invalid, "#{host} is not allowed, so none of its paths is.", :paths)}
        end
    end
  end

  defp set_locked(scope, rule_or_id, locked) do
    with {:ok, membership} <- member(scope),
         :ok <- owner(membership, "Only an owner locks or unlocks a rule."),
         {:ok, rule} <- get_rule(scope, rule_id(rule_or_id)),
         :ok <- lock_is_the_hives(rule.repository_id, true) do
      write(scope, nil, fn hive ->
        with {:ok, rule} <- reread(hive, rule) do
          rule = rule |> Ecto.Changeset.change(locked: locked) |> Repo.update!()
          {:ok, rule, if(locked, do: "rule_locked", else: "rule_unlocked"), Rule.subject(rule)}
        end
      end)
    end
  end

  # The rule as it is under the hive's lock: one removed in the meantime is not found.
  defp reread(%Hive{id: hive_id}, %Rule{id: id}) do
    case Repo.one(from r in Rule, where: r.id == ^id and r.hive_id == ^hive_id) do
      %Rule{} = rule -> {:ok, rule}
      nil -> {:error, not_found("This rule is gone: somebody removed it a moment ago.")}
    end
  end

  # One write: the hive's row is locked first, so writes of one hive happen one after
  # another and versions count without gaps. `FOR NO KEY UPDATE`, not `FOR UPDATE`: every
  # insert of an event or a run takes `FOR KEY SHARE` on its hive through the foreign
  # key, and a policy write must never make the receiver wait; then the change, its row in the history and
  # the renders. Whatever refuses rolls everything back.
  defp write(%Scope{hive: %Hive{} = hive, user: user}, repository_id, fun) do
    result =
      Repo.transact(fn ->
        hive = Repo.one!(from h in Hive, where: h.id == ^hive.id, lock: "FOR NO KEY UPDATE")
        before = snapshot(hive, repository_id)

        with {:ok, value, action, subject} <- fun.(hive) do
          hive = Repo.one!(from h in Hive, where: h.id == ^hive.id)
          after_ = snapshot(hive, repository_id)

          if before == after_ do
            {:ok, {value, nil}}
          else
            change = insert_change(hive, user, repository_id, action, subject, before, after_)

            with :ok <- render_all(hive, user, change), do: {:ok, {value, change}}
          end
        end
      end)

    case result do
      {:ok, {value, nil}} ->
        {:ok, value}

      {:ok, {value, %Change{} = change}} ->
        Phoenix.PubSub.broadcast(
          Apiary.PubSub,
          topic(hive.id),
          {:policy_changed,
           %{hive_id: hive.id, repository_id: change.repository_id, action: change.action}}
        )

        {:ok, value}

      {:error, %Error{}} = refusal ->
        refusal
    end
  end

  defp snapshot(%Hive{} = hive, repository_id) do
    %{
      "mode" => hive.egress_mode,
      "rules" =>
        for rule <- rules(hive.id, repository_id) do
          %{
            "kind" => rule.kind,
            "action" => rule.action,
            "host" => rule.host,
            "paths" => rule.paths,
            "name" => rule.name,
            "argument" => rule.argument,
            "locked" => rule.locked
          }
        end
    }
  end

  defp insert_change(hive, user, repository_id, action, subject, before, after_) do
    Repo.insert!(%Change{
      organisation_id: hive.organisation_id,
      hive_id: hive.id,
      repository_id: repository_id,
      action: action,
      subject: subject,
      before: before,
      after: after_,
      changed_by_id: user_id(user),
      inserted_at: DateTime.utc_now()
    })
  end

  # The baseline, and every repository that has rules of its own or has had a
  # configuration of its own: a repository whose last rule went keeps its versions, and
  # its next one says what the baseline says.
  defp render_all(%Hive{} = hive, user, change) do
    hive_rules = rules(hive.id, nil)

    own =
      Repo.all(from r in Rule, where: r.hive_id == ^hive.id and not is_nil(r.repository_id))
      |> Enum.group_by(& &1.repository_id)

    rendered =
      Repo.all(
        from c in RunConfiguration,
          where: c.hive_id == ^hive.id and not is_nil(c.repository_id),
          distinct: true,
          select: c.repository_id
      )

    targets = [nil | Enum.uniq(Map.keys(own) ++ rendered)]

    Enum.reduce_while(targets, :ok, fn repository_id, :ok ->
      case render(hive, user, change, repository_id, hive_rules, Map.get(own, repository_id, [])) do
        {:ok, configuration} ->
          if change && change.repository_id == repository_id do
            Repo.update_all(from(c in Change, where: c.id == ^change.id),
              set: [version_after: configuration.version]
            )
          end

          {:cont, :ok}

        {:error, error} ->
          {:halt, {:error, elsewhere(error, hive, change, repository_id)}}
      end
    end)
  end

  defp render(hive, user, change, repository_id, hive_rules, own) do
    with {:ok, effective} <- Resolution.resolve(hive.egress_mode, hive_rules, own, repository_id),
         document = Render.document(effective),
         :ok <- small(document),
         :ok <- valid(document) do
      digest = Render.digest(document)

      case Repo.one(newest(hive.id, repository_id)) do
        %RunConfiguration{digest: ^digest} = current ->
          {:ok, current}

        current ->
          {:ok,
           Repo.insert!(%RunConfiguration{
             organisation_id: hive.organisation_id,
             hive_id: hive.id,
             repository_id: repository_id,
             version: if(current, do: current.version + 1, else: 1),
             document: document,
             digest: digest,
             rendered_at: DateTime.utc_now(),
             changed_by_id: user_id(user),
             policy_change_id: change && change.id
           })}
      end
    end
  end

  # The most a runner reads of a document (its `MaxDocument`): a larger one is no run.
  @document_max 1_048_576
  defp small(document) when byte_size(document) <= @document_max, do: :ok

  defp small(_document) do
    {:error,
     Error.new(
       :invalid_document,
       "The change was not made: the run configuration it renders is over 1 MiB, more than a runner reads. Say the paths with fewer, shorter patterns (a final * matches everything below)."
     )}
  end

  defp valid(document) do
    case Schema.validate(document) do
      :ok ->
        :ok

      {:error, reason} ->
        # The document holds hosts, paths and names of credentials, never a secret.
        Logger.error(
          "a rendered run configuration was refused by the contract's schema: #{inspect(reason, limit: 20)}"
        )

        {:error,
         Error.new(
           :invalid_document,
           "The change was not made: the run configuration it renders is not one the runner's contract accepts."
         )}
    end
  end

  # A refusal that comes from another target than the one being changed says which.
  defp elsewhere(%Error{} = error, _hive, %Change{repository_id: id}, id), do: error
  defp elsewhere(%Error{} = error, _hive, nil, _repository_id), do: error

  defp elsewhere(%Error{} = error, _hive, %Change{}, nil),
    do: %{error | message: "In the hive's baseline: " <> error.message}

  defp elsewhere(%Error{} = error, hive, %Change{}, repository_id) do
    case Repo.one(from p in Repository, where: p.id == ^repository_id and p.hive_id == ^hive.id) do
      %Repository{forge: forge, path: path} ->
        %{
          error
          | message:
              "In the repository #{forge}/#{path}, which has rules of its own: " <> error.message
        }

      nil ->
        error
    end
  end

  ## In force, for this module and for the wire (`Apiary.Policy.Serving`)

  @doc false
  # The configuration in force for a repository of the hive, or the baseline's: read, and
  # the baseline rendered when the hive has none yet.
  def in_force(organisation_id, hive_id, repository_id) do
    own = repository_id && Repo.one(newest(hive_id, repository_id))

    case own || Repo.one(newest(hive_id, nil)) do
      %RunConfiguration{} = configuration -> {:ok, configuration}
      nil -> first_baseline(organisation_id, hive_id)
    end
  end

  defp first_baseline(organisation_id, hive_id) do
    Repo.transact(fn ->
      hive =
        Repo.one(
          from h in Hive,
            where: h.id == ^hive_id and h.organisation_id == ^organisation_id,
            lock: "FOR NO KEY UPDATE"
        )

      cond do
        is_nil(hive) -> {:error, not_found("There is no such hive.")}
        configuration = Repo.one(newest(hive_id, nil)) -> {:ok, configuration}
        true -> render(hive, nil, nil, nil, rules(hive_id, nil), [])
      end
    end)
  end

  @doc false
  # The newest version of one target, read from `run_configurations_version_index`.
  def newest(hive_id, repository_id) do
    from c in configurations(hive_id, repository_id), order_by: [desc: c.version], limit: 1
  end

  # The expression is the index's own, constant and all (`run_configurations_version_index`):
  # as a parameter it would match only under a custom plan, and a prepared statement
  # goes generic after a few runs.
  defp configurations(hive_id, repository_id) do
    from c in RunConfiguration,
      where:
        c.hive_id == ^hive_id and
          fragment(
            "COALESCE(?, '00000000-0000-0000-0000-000000000000'::uuid)",
            c.repository_id
          ) == type(^(repository_id || @nobody), Ecto.UUID)
  end

  defp by_digest(hive_id, repository_id, digest) do
    Repo.one(
      from c in configurations(hive_id, repository_id),
        where: c.digest == ^digest,
        order_by: [desc: c.version],
        limit: 1
    )
  end

  ## Helpers

  defp rules(hive_id, nil) do
    Repo.all(
      from r in Rule,
        where: r.hive_id == ^hive_id and is_nil(r.repository_id),
        order_by: [desc: r.kind, asc: r.host, asc: r.name]
    )
  end

  defp rules(hive_id, repository_id) do
    Repo.all(
      from r in Rule,
        where: r.hive_id == ^hive_id and r.repository_id == ^repository_id,
        order_by: [desc: r.kind, asc: r.host, asc: r.name]
    )
  end

  defp repositories(%Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}}) do
    from p in Repository, where: p.hive_id == ^hive_id and p.organisation_id == ^org_id
  end

  # The repository's id when it is one of the scope's hive, nil for the baseline.
  defp target_id(%Scope{}, target) when target in [nil, :hive], do: {:ok, nil}

  defp target_id(%Scope{} = scope, %Repository{id: id}) when is_binary(id) do
    case Repo.one(from p in repositories(scope), where: p.id == ^id, select: p.id) do
      nil -> {:error, not_found("This hive has no such repository.")}
      id -> {:ok, id}
    end
  end

  defp target_id(%Scope{}, _target), do: {:error, not_found("This hive has no such repository.")}

  defp existing(hive_id, repository_id, %Rule{kind: kind} = candidate) do
    subject = Rule.subject(candidate)

    Enum.find(rules(hive_id, repository_id), &(&1.kind == kind and Rule.subject(&1) == subject))
  end

  defp member(%Scope{} = scope) do
    case Organisations.fetch_membership(scope) do
      {:ok, %Membership{} = membership} ->
        {:ok, membership}

      {:error, _unauthorized} ->
        {:error,
         Error.new(:unauthorized, "Only a member of this hive changes its security policy.")}
    end
  end

  defp owner(%Membership{level: :owner}, _message), do: :ok
  defp owner(%Membership{}, message), do: {:error, Error.new(:unauthorized, message)}

  defp may_change(_membership, nil), do: :ok
  defp may_change(_membership, %Rule{locked: false}), do: :ok

  defp may_change(membership, %Rule{locked: true} = rule) do
    owner(
      membership,
      "The rule for #{Rule.subject(rule)} is locked. Only an owner changes or removes a locked rule."
    )
  end

  # `locked` is true or false by now (`attrs/1`): what is compared is what is stored.
  defp may_lock(membership, existing, %{"locked" => wanted}) do
    now = if existing, do: existing.locked, else: false
    if wanted == now, do: :ok, else: owner(membership, "Only an owner locks or unlocks a rule.")
  end

  defp may_lock(_membership, _existing, _attrs), do: :ok

  defp lock_is_the_hives(nil, _locked), do: :ok

  defp lock_is_the_hives(_repository_id, true) do
    {:error,
     Error.new(
       :invalid,
       "Only a rule of the hive can be locked: a lock is what holds it against the repositories."
     )}
  end

  defp lock_is_the_hives(_repository_id, _locked), do: :ok

  # The changeset's errors as the first sentence, or the rule it describes.
  defp applied(%Ecto.Changeset{valid?: true} = changeset),
    do: {:ok, Ecto.Changeset.apply_changes(changeset)}

  defp applied(%Ecto.Changeset{errors: [{field, {message, _meta}} | _]}) do
    {:error, Error.new(:invalid, message, field)}
  end

  # What a form or a caller gives, reduced to the known keys as strings. No atom is made
  # from input.
  @keys ~w(kind host paths name argument locked)
  defp attrs(attrs) when is_map(attrs) do
    attrs =
      for key <- @keys,
          {:ok, value} <- [fetch(attrs, key)],
          {:ok, value} <- [present(normalise(key, value))],
          into: %{},
          do: {key, value}

    # Ecto would cast "1" and 1 to true; a lock is said as true or false and nothing else,
    # so what is authorised is exactly what is stored.
    if Map.get(attrs, "locked", false) in [true, false],
      do: {:ok, attrs},
      else: {:error, Error.new(:invalid, "A rule is locked or it is not: true or false.")}
  end

  defp present(:absent), do: :absent
  defp present(value), do: {:ok, value}

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, String.to_existing_atom(key))
    end
  end

  defp normalise("host", host) when is_binary(host),
    do: host |> String.trim() |> String.downcase()

  defp normalise("name", name) when is_binary(name), do: String.trim(name)
  defp normalise("kind", kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)

  defp normalise("argument", argument) when is_binary(argument) do
    case String.trim(argument) do
      "" -> nil
      argument -> argument
    end
  end

  defp normalise("locked", locked) when locked in [true, "true"], do: true
  defp normalise("locked", locked) when locked in [false, "false"], do: false

  # A text of paths, one a line (or separated by commas or spaces). A text with no path
  # in it says nothing about the paths: it is a form's empty field, never "every path",
  # which takes `paths: nil`.
  defp normalise("paths", paths) when is_binary(paths) do
    case String.split(paths, ~r/[\s,]+/u, trim: true) do
      [] -> :absent
      paths -> Enum.uniq(paths)
    end
  end

  defp normalise("paths", paths) when is_list(paths), do: Enum.uniq(paths)
  defp normalise(_key, value), do: value

  defp connection_host(%Scope{hive: %Hive{id: hive_id}}, %Connection{hive_id: hive_id, host: host})
       when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    if Grammar.host?(host) and not Grammar.wildcard?(host),
      do: {:ok, host},
      else:
        {:error,
         Error.new(
           :invalid,
           "This host cannot be named in a policy: a rule takes a host name, not an address of this form.",
           :host
         )}
  end

  defp connection_host(%Scope{}, _connection),
    do: {:error, not_found("This hive has no such connection.")}

  defp connection_target(_scope, _connection, :hive), do: {:ok, nil}

  defp connection_target(%Scope{} = scope, %Connection{run_id: run_id}, :repository) do
    repository =
      Repo.one(
        from p in repositories(scope),
          join: r in Run,
          on: r.repository_id == p.id,
          where: r.id == ^run_id and r.hive_id == ^scope.hive.id
      )

    case repository do
      %Repository{} = repository ->
        {:ok, repository}

      nil ->
        {:error,
         Error.new(
           :not_found,
           "This run names no repository, so the rule has nowhere to go but the hive."
         )}
    end
  end

  defp rule_id(%Rule{id: id}), do: id
  defp rule_id(id), do: id

  defp user_id(%User{id: id}), do: id
  defp user_id(_user), do: nil

  defp version(version) when is_integer(version) and version > 0, do: {:ok, version}

  defp version(version) when is_binary(version) and byte_size(version) <= 9 do
    case Integer.parse(version) do
      {version, ""} when version > 0 -> {:ok, version}
      _ -> :error
    end
  end

  defp version(_version), do: :error

  defp paginate(query, page) do
    total = Repo.aggregate(exclude(query, :preload) |> exclude(:order_by), :count)
    pages = max(ceil(total / @page_size), 1)
    page = if is_integer(page), do: page |> max(1) |> min(pages), else: 1

    items = Repo.all(from q in query, limit: @page_size, offset: ^((page - 1) * @page_size))
    %{items: items, page: page, pages: pages, total: total}
  end

  defp empty_page, do: %{items: [], page: 1, pages: 1, total: 0}

  defp not_found(message), do: Error.new(:not_found, message)
end
