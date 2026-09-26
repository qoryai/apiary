defmodule Apiary.Policy do
  @moduledoc """
  The security policy of a hive and of its targets, the run configurations rendered
  from it, and the history of both. Pages call this module and nothing under it.

  ## The model

  The contract's policy document says a mode, the hosts denied, the hosts allowed, the
  paths a host is held to, the credentials of the machine's a run may use. The hive has a
  mode (`get_mode/1`, `set_mode/2`) and a baseline of rules; a target has rules of its
  own on top, and follows the hive's mode unless it sets its own (`get_mode/2`,
  `set_mode/3`). The mode and the rules are apart: a locked rule of the hive holds in a
  target's document whatever the target's mode, and a deny holds in either mode:
  `egress.deny` is decided by the runner first, so under `observe` a host a deny names is
  denied and everything else is let through and recorded, and the document's `allow`
  says what `enforce` would reach. A rule (`Apiary.Policy.Rule`) allows or denies a host
  or a credential. A deny is written to the document and takes the allow entries it
  covers out of it, so a target can disable a host of the hive, and a **locked** rule
  of the hive holds against every target. How the rules come to one policy is
  `Apiary.Policy.Resolution`'s to say.

  ## Writes

  Every write is one transaction: the rule, a `policy_changes` row, and the render of the
  baseline and of every target that has rules (or has had a configuration) of its own.
  A render is validated against the contract's schema before it is stored; a change whose
  render the schema or the resolution refuses is rolled back and answered with a sentence.
  A render that gives the same bytes as the version in force writes no new version. After
  the commit `{:policy_changed, %{hive_id:, target_id:, action:}}` goes out on
  `topic/1`, `"policy:<hive_id>"`.

  Members edit rules. Only an owner changes the mode (in either direction), and only an
  owner locks, unlocks, changes or removes a locked rule.

  ## Returns

  Reads return what they read. Everything that can be refused returns `{:ok, value}` or
  `{:error, %Apiary.Policy.Error{}}`, whose `message` is a sentence for the page.

  A holder is whose rules, mode and run configurations a call is about: `nil` or `:hive`
  for the hive's baseline, or an `Apiary.Runs.Target` of the scope's hive. Another
  hive's target, rule or configuration is not found.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations
  alias Apiary.Organisations.{Hive, Membership, Organisation}
  alias Apiary.Policy.{Activity, Change, Effective, Error, Export, Grammar, Render, Resolution}
  alias Apiary.Policy.{Rule, RunConfiguration, Schema, Suggestions}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Target, Run}

  @modes ~w(observe enforce)
  @page_size 25
  # The most rules one list holds (the baseline's, or a target's). With at most
  # `Grammar.paths_max/0` paths a rule, it bounds a change's `before` and `after`, which
  # repeat the list, and so the history's growth: quadratic in the rules, up to this.
  @rules_max 500
  @nobody "00000000-0000-0000-0000-000000000000"

  @type holder :: nil | :hive | Target.t()
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
  policy. The first change anywhere counts, a target's rule or a target's mode
  included: it starts serving every target of the hive, the others the baseline. For the pages: "machines use their own policy until the first change here".
  """
  @spec managed?(Scope.t()) :: boolean
  def managed?(%Scope{hive: %Hive{id: hive_id}}), do: managed_hive?(hive_id)

  @doc false
  def managed_hive?(hive_id) do
    Repo.exists?(from c in Change, where: c.hive_id == ^hive_id)
  end

  @doc """
  What the sidebar shows of the policy, in one query: whether the hive's policy is
  managed (`managed?/1`), the hive's mode, and the modes the hive's targets set for
  themselves, one per target that has one, in no particular order: `%{managed?:,
  mode:, own_modes:}`.
  """
  @spec mode_summary(Scope.t()) :: %{
          managed?: boolean,
          mode: String.t(),
          own_modes: [String.t()]
        }
  def mode_summary(%Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}}) do
    {mode, managed?, own_modes} =
      Repo.one!(
        from h in Hive,
          as: :hive,
          where: h.id == ^hive_id and h.organisation_id == ^org_id,
          select:
            {h.egress_mode, exists(from(c in Change, where: c.hive_id == parent_as(:hive).id)),
             fragment(
               "ARRAY(SELECT p.egress_mode FROM targets p WHERE p.hive_id = ? AND p.egress_mode IS NOT NULL)",
               h.id
             )}
      )

    %{managed?: managed?, mode: mode, own_modes: own_modes}
  end

  ## Targets

  @doc """
  The hive's targets, by system and path, each with `rule_count`, how many rules of
  its own it has (a virtual count on the map, not the struct), `own_mode`, the mode it
  set for itself or nil when it follows the hive, and `mode`, the one in force for it:
  `[%{target: …, rule_count: n, own_mode: … | nil, mode: …}]`. At most 500.
  """
  @spec list_targets(Scope.t()) :: [
          %{
            target: Target.t(),
            rule_count: integer,
            own_mode: String.t() | nil,
            mode: String.t()
          }
        ]
  def list_targets(
        %Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}} = scope
      ) do
    hive_mode = get_mode(scope)

    Repo.all(
      from p in Target,
        where: p.hive_id == ^hive_id and p.organisation_id == ^org_id,
        left_join: r in Rule,
        on: r.target_id == p.id,
        group_by: p.id,
        order_by: [asc: p.system, asc: p.path],
        limit: 500,
        select: %{target: p, rule_count: count(r.id)}
    )
    |> Enum.map(fn %{target: target} = row ->
      Map.merge(row, %{
        own_mode: target.egress_mode,
        mode: target.egress_mode || hive_mode
      })
    end)
  end

  @doc "One target of the scope's hive by id."
  @spec get_target(Scope.t(), String.t()) :: {:ok, Target.t()} | refusal
  def get_target(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Target{} = target <- Repo.one(from p in targets(scope), where: p.id == ^id) do
      {:ok, target}
    else
      _ -> {:error, not_found(gettext("This hive has no such target."))}
    end
  end

  ## Mode

  @doc "Every mode: `observe` records and denies only what a deny rule names, `enforce` denies what no rule allows as well."
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

  @typedoc "A target's mode: the one in force, its own (nil when it follows the hive) and the hive's."
  @type target_mode :: %{mode: String.t(), own: String.t() | nil, hive: String.t()}

  @doc """
  With `nil` or `:hive`, `get_mode/1`: the hive's mode, a string. With a target,
  `%{mode:, own:, hive:}`: the mode in force for it, the mode it set for itself (nil when
  it follows the hive, the default) and the hive's. A target that is not the hive's
  follows the hive.
  """
  @spec get_mode(Scope.t(), holder) :: String.t() | target_mode
  def get_mode(%Scope{} = scope, holder) when holder in [nil, :hive], do: get_mode(scope)

  def get_mode(%Scope{} = scope, holder) do
    hive = get_mode(scope)

    own =
      case holder_id(scope, holder) do
        {:ok, id} ->
          Repo.one(from p in targets(scope), where: p.id == ^id, select: p.egress_mode)

        {:error, _not_found} ->
          nil
      end

    %{mode: own || hive, own: own, hive: hive}
  end

  @doc """
  Sets the mode of the hive: `set_mode(scope, nil, mode)`. An owner's act in either
  direction; a member is refused with a sentence. The hive's mode is the default of its
  targets: a change renders the baseline and every target that follows the hive
  again, and a target with a mode of its own keeps it.
  """
  @spec set_mode(Scope.t(), String.t()) :: {:ok, String.t()} | refusal
  def set_mode(%Scope{} = scope, mode), do: set_mode(scope, nil, mode)

  @doc """
  Sets the mode of the hive (`nil` or `:hive`: `{:ok, mode}`) or of a target
  (`{:ok, %{mode:, own:, hive:}}`). A target takes `"observe"`, `"enforce"`, or
  `:inherit` (also `"inherit"`) to follow the hive again, which is what every target
  does until somebody says otherwise. An owner's act, like the hive's. It is a change of
  the target's policy (`mode_changed`, with the target's own mode, or
  `"inherit"`, before and after) and renders the target's configuration: a
  target with nothing but a mode of its own has a configuration of its own.
  """
  @spec set_mode(Scope.t(), holder, String.t() | :inherit) ::
          {:ok, String.t() | target_mode} | refusal
  def set_mode(%Scope{} = scope, holder, mode) when holder in [nil, :hive] and mode in @modes do
    with {:ok, membership} <- member(scope),
         :ok <- owner(membership, mode_is_an_owners()) do
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

  def set_mode(%Scope{} = scope, %Target{} = target, mode)
      when mode in @modes or mode in [:inherit, "inherit"] do
    own = if mode in @modes, do: mode

    with {:ok, membership} <- member(scope),
         :ok <- owner(membership, mode_is_an_owners()),
         {:ok, target_id} <- holder_id(scope, target) do
      write(scope, target_id, fn hive ->
        Repo.update_all(from(p in Target, where: p.id == ^target_id),
          set: [egress_mode: own, updated_at: DateTime.utc_now()]
        )

        {:ok, %{mode: own || hive.egress_mode, own: own, hive: hive.egress_mode}, "mode_changed",
         nil}
      end)
    end
  end

  def set_mode(%Scope{}, holder, _mode) when holder in [nil, :hive] do
    {:error, Error.new(:invalid, gettext("The mode is observe or enforce."), :mode)}
  end

  def set_mode(%Scope{}, _holder, _mode) do
    {:error,
     Error.new(:invalid, gettext("A target's mode is observe, enforce, or the hive's."), :mode)}
  end

  ## Rules

  @doc "The rules of the baseline (`nil`) or of a target, hosts first, by host and name."
  @spec list_rules(Scope.t(), holder) :: [Rule.t()]
  def list_rules(%Scope{} = scope, holder) do
    case holder_id(scope, holder) do
      {:ok, target_id} -> rules(scope.hive.id, target_id)
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
      _ -> {:error, not_found(gettext("This hive has no such rule."))}
    end
  end

  @doc """
  The policy in force for the baseline (`nil`) or for a target: every rule that takes
  part as an `Apiary.Policy.Entry` (where it came from, whether it is in force, what
  overrode it, what it overrides), the `allow`, `paths` and `credentials` the document
  says, and the `mode` in force with where it came from (`mode_source`, `:hive` or
  `:target`). A target that is not the hive's gets the baseline.
  """
  @spec effective(Scope.t(), holder) :: Effective.t()
  def effective(%Scope{} = scope, holder) do
    target_id =
      case holder_id(scope, holder) do
        {:ok, target_id} -> target_id
        {:error, _not_found} -> nil
      end

    hive_rules = rules(scope.hive.id, nil)
    own = if target_id, do: rules(scope.hive.id, target_id), else: []

    %{mode: mode, own: own_mode, hive: hive_mode} =
      case target_id do
        nil -> %{mode: get_mode(scope), own: nil, hive: get_mode(scope)}
        id -> get_mode(scope, %Target{id: id})
      end

    case Resolution.resolve_for(hive_mode, own_mode, hive_rules, own, target_id) do
      {:ok, effective} ->
        effective

      # No write leaves rules that do not resolve; should one be there all the same, the
      # page shows the mode and nothing allowed rather than raise.
      {:error, _error} ->
        %Effective{
          mode: mode,
          mode_source: if(own_mode, do: :target, else: :hive),
          target_id: target_id
        }
    end
  end

  @doc """
  Allows a host or a credential in the holder, replacing the holder's rule for the same
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
  @spec allow(Scope.t(), holder, map) :: {:ok, Rule.t()} | refusal
  def allow(%Scope{} = scope, holder, attrs), do: put_rule(scope, holder, "allow", attrs)

  @doc """
  Denies a host or a credential in the holder, as `allow/3` allows one. A deny takes the
  whole host: `paths` is not read. A deny holds in either mode, and a deny of a host below
  an allowed `*.` suffix stands beside the allow: the runner decides `deny` first.
  """
  @spec deny(Scope.t(), holder, map) :: {:ok, Rule.t()} | refusal
  def deny(%Scope{} = scope, holder, attrs), do: put_rule(scope, holder, "deny", attrs)

  @doc """
  Adds `path` to the paths `host` is held to in the holder. The paths in force for the
  holder are taken as the start, so a target that adds a path keeps the hive's and
  from then on has a list of its own. Refused when the host is already reached on every
  path, and in a target when the hive's rule for the host is locked.
  """
  @spec allow_path(Scope.t(), holder, String.t(), String.t()) :: {:ok, Rule.t()} | refusal
  def allow_path(%Scope{} = scope, holder, host, path),
    do: put_path(scope, holder, host, path, :allow)

  @doc """
  Takes `path` out of the paths `host` is held to in the holder. Refused when the host is
  reached on every path (the document cannot allow every path but one) and when the path
  is allowed by a pattern rather than by itself.
  """
  @spec deny_path(Scope.t(), holder, String.t(), String.t()) :: {:ok, Rule.t()} | refusal
  def deny_path(%Scope{} = scope, holder, host, path),
    do: put_path(scope, holder, host, path, :deny)

  @doc "Removes a rule, given itself or its id. A locked rule is an owner's to remove."
  @spec remove_rule(Scope.t(), Rule.t() | String.t()) :: {:ok, Rule.t()} | refusal
  def remove_rule(%Scope{} = scope, rule_or_id) do
    with {:ok, membership} <- member(scope),
         {:ok, rule} <- get_rule(scope, rule_id(rule_or_id)) do
      # Who may remove it is decided on the rule as it is under the hive's lock.
      write(scope, rule.target_id, fn hive ->
        with {:ok, rule} <- reread(hive, rule),
             :ok <- may_change(membership, rule) do
          Repo.delete_all(from r in Rule, where: r.id == ^rule.id)
          {:ok, rule, "rule_removed", Rule.subject(rule)}
        end
      end)
    end
  end

  @doc "Locks a rule of the hive, so no target overrides it. Owners only."
  @spec lock(Scope.t(), Rule.t() | String.t()) :: {:ok, Rule.t()} | refusal
  def lock(%Scope{} = scope, rule_or_id), do: set_locked(scope, rule_or_id, true)

  @doc "Unlocks a rule of the hive. Owners only."
  @spec unlock(Scope.t(), Rule.t() | String.t()) :: {:ok, Rule.t()} | refusal
  def unlock(%Scope{} = scope, rule_or_id), do: set_locked(scope, rule_or_id, false)

  @doc """
  The rule a connection's row asks for (C4, C5): allow or deny its host, in the run's
  target (`:target`) or in the hive (`:hive`). When the host is held to paths in
  the holder and the connection names a path, the path is added to or taken out of those
  paths instead. The connection is one of the scope's hive.
  """
  @spec rule_from_connection(Scope.t(), Connection.t(), :allow | :deny, :target | :hive) ::
          {:ok, Rule.t()} | refusal
  def rule_from_connection(%Scope{} = scope, %Connection{} = connection, action, level)
      when action in [:allow, :deny] and level in [:target, :hive] do
    with {:ok, _membership} <- member(scope),
         {:ok, host} <- connection_host(scope, connection),
         {:ok, holder} <- connection_holder(scope, connection, level) do
      held = effective(scope, holder).paths

      key =
        if Map.has_key?(held, host),
          do: host,
          else: Enum.find(Map.keys(held), &Grammar.covers?(&1, host))

      cond do
        key && connection.path not in [nil, ""] ->
          put_path(scope, holder, key, connection.path, action)

        key && action == :allow ->
          {:error,
           Error.new(
             :invalid,
             gettext(
               "%{host} is held to paths, and this connection names no path, so there is no path to add. Allowing the host from here would open every path of it: change the rule's paths on the policy page instead.",
               host: key
             ),
             :paths
           )}

        action == :allow ->
          allow(scope, holder, %{host: host})

        true ->
          deny(scope, holder, %{host: host})
      end
    end
  end

  ## What the record says about the rules

  @typedoc "A destination enforce would start denying: see `uncovered/2`."
  @type uncovered :: %{
          host: String.t(),
          path: String.t() | nil,
          attempts: non_neg_integer,
          tool: String.t() | nil,
          runs: non_neg_integer,
          last_seen_at: DateTime.t(),
          targets: [%{id: Ecto.UUID.t(), system: String.t(), path: String.t()}]
        }

  @doc """
  The destinations that were let through since `since` and that today's rules do not
  cover: what enforce would start denying. A destination is a host, and a path as well
  where the host is held to paths. Each connection is held to the effective policy of
  its own run's target (the baseline for a run without one), matched as the runner
  matches. Each destination says its allowed `attempts`, how many `runs` made them, when
  it was last seen and in which `targets`, and `tool`, the tool whose host it is, whenever
  a request to it in the range named one, handed to the tool or refused by a path rule
  before it reached the tool (nil otherwise); the 50 with the most attempts, most first.

  Read from `connections` by the hive and when they were last seen, at most
  20,000 rows (`Apiary.Policy.Activity.cap/0`): beyond that the answer is `:unavailable`, never a
  count of a part. A connection counts whole when it was last seen since `since`.
  """
  @spec uncovered(Scope.t(), DateTime.t()) :: {:ok, [uncovered]} | :unavailable
  def uncovered(%Scope{hive: %Hive{}} = scope, %DateTime{} = since),
    do: Activity.uncovered(scope, nil, since)

  @doc """
  `uncovered/2` for a holder. For the hive (`nil`, `:hive`) it is `uncovered/2`: what
  enforcing the hive would start denying, so only the runs of targets that follow the
  hive's mode count, and the runs that name no target; a target with a mode of
  its own would not change. For a target: what enforcing that target would start
  denying, from its own runs under its own effective rules, whatever its mode is now.
  A target that is not the hive's has nothing.
  """
  @spec uncovered(Scope.t(), holder, DateTime.t()) :: {:ok, [uncovered]} | :unavailable
  def uncovered(%Scope{hive: %Hive{}} = scope, holder, %DateTime{} = since) do
    case holder_id(scope, holder) do
      {:ok, target_id} -> Activity.uncovered(scope, target_id, since)
      {:error, _not_found} -> {:ok, []}
    end
  end

  @doc """
  How many attempts were denied since `since`, and to how many destinations (host, port
  and path): the enforce card's fact line. Bounded as `uncovered/2` is.
  """
  @spec denied_summary(Scope.t(), DateTime.t()) ::
          {:ok, %{denied: non_neg_integer, destinations: non_neg_integer}} | :unavailable
  def denied_summary(%Scope{hive: %Hive{}} = scope, %DateTime{} = since),
    do: Activity.denied_summary(scope, since)

  @typedoc "A denied destination today's rules still do not allow: see `denied_destinations/2`."
  @type denied_destination :: %{
          host: String.t(),
          port: non_neg_integer,
          path: String.t(),
          held: boolean,
          locked: String.t() | nil,
          denied: pos_integer,
          tool: String.t() | nil,
          runs: pos_integer,
          last_seen_at: DateTime.t(),
          targets: [%{id: Ecto.UUID.t(), system: String.t(), path: String.t()}]
        }

  @doc """
  The destinations (host, port and path) that were denied since `since` and that today's
  effective policy still does not allow: what a member can act on, each held to the
  policy of its own run's target as `uncovered/2` holds them. A destination allowed
  since is left out: the record says it was denied, the rules say it no longer would be.
  `held` is true when the host is allowed and the path is what no rule covers; `locked`
  names the locked hive deny that covers the host, when one does, so a page can say that
  only an owner changes it; `tool` names the tool whose host it is, whenever a request to
  it in the range named one: a request to a tool that a path rule refused is a denied
  request to that tool. The 50 with the most denials, most first, with the
  targets whose runs were denied. Bounded as `uncovered/2` is, `:unavailable` beyond
  the cap.
  """
  @spec denied_destinations(Scope.t(), DateTime.t()) :: {:ok, [denied_destination]} | :unavailable
  def denied_destinations(%Scope{hive: %Hive{}} = scope, %DateTime{} = since),
    do: Activity.denied_destinations(scope, since)

  @doc """
  What the hive overview reads of the connections in one bounded read: `denied`, the
  denied destinations of `denied_destinations/2` since `since`; `uncovered`, what
  `uncovered/2` answers for the same moment; and `denied_destinations`, how many distinct
  destinations (host, port and path) were denied since `window`, an earlier moment, for
  the strip's "to 3 destinations". One read of `connections` since `window`, capped as
  `uncovered/2` is; `:unavailable` beyond the cap, for all three at once.
  """
  @spec overview_activity(Scope.t(), DateTime.t(), DateTime.t()) ::
          {:ok,
           %{
             denied: [denied_destination],
             uncovered: [uncovered],
             denied_destinations: non_neg_integer
           }}
          | :unavailable
  def overview_activity(%Scope{hive: %Hive{}} = scope, %DateTime{} = since, %DateTime{} = window),
    do: Activity.overview(scope, since, window)

  @doc """
  Per rule id, the attempts allowed and denied since `since`: `%{rule_id => %{allowed: n,
  denied: n}}`, a rule nothing reached being absent. For the baseline (`nil`) every
  connection of the hive is read, for a target those of its runs; each is held to the
  effective policy of its run's target and counted on the rule the runner would
  report: the first entry of `allow` that matches (names before `*.` suffixes), else the
  deny in force that covers the host; and on the credential rule the connection named.
  So a target's page may name rules of the hive, and the hive's page counts a hive
  rule wherever it decided. Bounded as `uncovered/2` is.
  """
  @spec rule_activity(Scope.t(), holder, DateTime.t()) ::
          {:ok,
           %{optional(Ecto.UUID.t()) => %{allowed: non_neg_integer, denied: non_neg_integer}}}
          | :unavailable
  def rule_activity(%Scope{hive: %Hive{}} = scope, holder, %DateTime{} = since) do
    case holder_id(scope, holder) do
      {:ok, target_id} -> Activity.rule_activity(scope, target_id, since)
      {:error, _not_found} -> {:ok, %{}}
    end
  end

  ## Suggestions

  @typedoc """
  A declared host no rule covers or denies. `allowed` and `denied` are the attempts to it
  in the target's runs since the window's start, nil when they could not be counted
  within the bound.
  """
  @type suggestion :: %{
          host: String.t(),
          runs: pos_integer,
          last_seen_at: DateTime.t(),
          allowed: non_neg_integer | nil,
          denied: non_neg_integer | nil
        }

  @doc """
  The hosts the target's harness declared (`harness_hosts` of its runs' policy
  applied events, the newest runs first) that the target's effective policy neither
  covers nor denies: `[%{host:, runs:, last_seen_at:, allowed:, denied:}]`, at most 50.
  `allowed` and `denied` count the attempts to the host in the target's runs since
  `since` (the last seven days by default), from `connections`, bounded: nil when there
  are more connections in the window than one answer reads. Hosts that are not in the
  contract's grammar are left out.
  """
  @spec suggestions(Scope.t(), Target.t(), DateTime.t() | nil) :: [suggestion]
  def suggestions(%Scope{} = scope, %Target{} = target, since \\ nil),
    do: declared_hosts(scope, target, since).suggested

  @doc """
  How many declared hosts across the hive's targets no rule covers or denies, counted
  and not listed, for a card that says "3 to review in 2 repositories":
  `%{hosts: n, targets: n}`. Read from the policy applied events of the newest runs
  since `since` (the last fourteen days by default), bounded at every step
  (`Apiary.Policy.Suggestions`): the 100 most recent runs with a target and
  300 of their events, then each target's effective policy resolved once from the
  hive's rules, read once. Two bounded reads and the hive's mode, however many
  targets the hive has; no attempts are counted, so nothing here can be unavailable.
  """
  @spec suggestion_counts(Scope.t(), DateTime.t() | nil) :: %{
          hosts: non_neg_integer,
          targets: non_neg_integer
        }
  def suggestion_counts(%Scope{hive: %Hive{} = hive}, since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -14, :day)
    Suggestions.counts(hive, since)
  end

  @doc """
  The declared hosts shown against the rules (S5): `%{suggested: [suggestion], covered:
  [%{host:, by:, source:, rule_id:}]}`. `suggested` is `suggestions/3`. `covered` is the
  declared hosts a rule already allows, at most 20, by host: `by` is the entry of `allow`
  that covers the host as a runner would report it (the host itself, or a `*.` suffix),
  `source` is `:hive` or `:target`, where that rule was written, and `rule_id` its id.
  A target that is not the hive's has neither.
  """
  @spec declared_hosts(Scope.t(), Target.t(), DateTime.t() | nil) :: %{
          suggested: [suggestion],
          covered: [
            %{
              host: String.t(),
              by: String.t(),
              source: :hive | :target,
              rule_id: Ecto.UUID.t()
            }
          ]
        }
  def declared_hosts(%Scope{} = scope, %Target{} = target, since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -7, :day)

    case holder_id(scope, target) do
      {:ok, target_id} ->
        Suggestions.report(scope.hive.id, target_id, effective(scope, target), since)

      {:error, _not_found} ->
        %{suggested: [], covered: []}
    end
  end

  ## Run configurations

  @doc """
  The run configuration in force for the baseline (`nil`) or for a target: the highest
  version. A target that never had rules of its own is served the baseline's, and the
  row says so by its `target_id`. A hive nobody has changed yet (`managed?/1` is
  false) has none: `{:error, %Error{reason: :unmanaged}}`, and nothing is rendered or
  stored by asking. The first version is written by the first change alone.
  """
  @spec current_configuration(Scope.t(), holder) :: {:ok, RunConfiguration.t()} | refusal
  def current_configuration(%Scope{hive: %Hive{} = hive} = scope, holder) do
    with {:ok, target_id} <- holder_id(scope, holder) do
      in_force(hive.organisation_id, hive.id, target_id)
    end
  end

  @doc "One version of the baseline's (`nil`) or of a target's run configurations."
  @spec get_configuration(Scope.t(), holder, pos_integer | String.t()) ::
          {:ok, RunConfiguration.t()} | refusal
  def get_configuration(%Scope{} = scope, holder, version) do
    with {:ok, target_id} <- holder_id(scope, holder),
         {:ok, version} <- version(version),
         %RunConfiguration{} = configuration <-
           Repo.one(
             from c in configurations(scope.hive.id, target_id), where: c.version == ^version
           ) do
      {:ok, configuration}
    else
      _ -> {:error, not_found(gettext("There is no such version of this run configuration."))}
    end
  end

  @doc """
  The run configuration a digest names, as a run reported it: the target's own
  version with that digest when it has one, the baseline's otherwise; the newest when the
  same bytes were in force more than once.
  """
  @spec configuration_for_digest(Scope.t(), holder, String.t() | nil) ::
          {:ok, RunConfiguration.t()} | refusal
  def configuration_for_digest(%Scope{} = scope, holder, digest) when is_binary(digest) do
    with {:ok, target_id} <- holder_id(scope, holder),
         %RunConfiguration{} = configuration <-
           by_digest(scope.hive.id, target_id, digest) ||
             (target_id && by_digest(scope.hive.id, nil, digest)) do
      {:ok, configuration}
    else
      _ -> {:error, not_found(gettext("This hive served no run configuration with that digest."))}
    end
  end

  def configuration_for_digest(%Scope{}, _holder, _digest),
    do: {:error, not_found(gettext("This hive served no run configuration with that digest."))}

  @doc "The versions of the baseline (`nil`) or of a target, newest first, a page of #{@page_size}."
  @spec list_configurations(Scope.t(), holder, pos_integer) :: page(RunConfiguration.t())
  def list_configurations(%Scope{} = scope, holder, page \\ 1) do
    case holder_id(scope, holder) do
      {:ok, target_id} ->
        configurations(scope.hive.id, target_id)
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
  `applied` is what its last policy applied event named; `in_force` is nil for a hive
  nobody has changed, which serves no configuration. `drift` is true when the run
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
      case in_force(hive.organisation_id, hive_id, run.target_id) do
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

  def digests(%Scope{}, %Run{}), do: {:error, not_found(gettext("This hive has no such run."))}

  ## Bulk reads, for a page that lists

  @bulk_max 500
  @configuration_fields [
    :id,
    :version,
    :digest,
    :rendered_at,
    :organisation_id,
    :hive_id,
    :target_id,
    :changed_by_id,
    :policy_change_id
  ]
  @change_fields [
    :id,
    :action,
    :subject,
    :version_after,
    :inserted_at,
    :organisation_id,
    :hive_id,
    :target_id,
    :changed_by_id
  ]

  @doc """
  The newest version of each holder's own run configurations, in one query and without
  the documents (`document` is nil): `%{key => %RunConfiguration{}}`, the key being the
  target's id, or nil for the baseline. `holders` holds `nil` or `:hive` for the
  baseline, targets, or target ids; at most #{@bulk_max} are read. A holder with no
  configuration of its own (a target served the baseline's, another hive's, an id that
  is none) has no key.
  """
  @spec newest_versions(Scope.t(), [holder | Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t() | nil) => RunConfiguration.t()
        }
  def newest_versions(%Scope{hive: %Hive{id: hive_id}}, holders) when is_list(holders) do
    {ids, baseline?} = holder_keys(holders)

    Repo.all(
      from c in RunConfiguration,
        where: c.hive_id == ^hive_id,
        where: c.target_id in ^ids or (^baseline? and is_nil(c.target_id)),
        distinct: c.target_id,
        order_by: [asc: c.target_id, desc: c.version],
        select: struct(c, ^@configuration_fields)
    )
    |> Map.new(&{&1.target_id, &1})
  end

  @doc """
  The run configuration versions each change made, in one query and without the
  documents: `%{change_id => [%RunConfiguration{}]}`, the baseline's first and then by
  target. A change of the hive may have rendered the baseline and several
  targets; one that rendered the same bytes made none and has no key, and neither
  has another hive's change. At most #{@bulk_max} ids are read.
  """
  @spec configurations_for_changes(Scope.t(), [Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => [RunConfiguration.t()]
        }
  def configurations_for_changes(%Scope{hive: %Hive{id: hive_id}}, change_ids)
      when is_list(change_ids) do
    ids = uuids(change_ids)

    Repo.all(
      from c in RunConfiguration,
        where: c.hive_id == ^hive_id and c.policy_change_id in ^ids,
        order_by: [asc_nulls_first: c.target_id, asc: c.version],
        select: struct(c, ^@configuration_fields)
    )
    |> Enum.group_by(& &1.policy_change_id)
  end

  @doc """
  The last change of each holder, in one query: `%{key => %Change{}}`, keyed like
  `newest_versions/2`, `changed_by` preloaded, without the rule sets (`before` and
  `after` are nil: `get_change/2` reads one whole). `holders` as in `newest_versions/2`.
  A holder nobody has changed, or another hive's, has no key.
  """
  @spec last_changes(Scope.t(), [holder | Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t() | nil) => Change.t()
        }
  def last_changes(%Scope{hive: %Hive{id: hive_id}}, holders) when is_list(holders) do
    {ids, baseline?} = holder_keys(holders)

    Repo.all(
      from c in Change,
        where: c.hive_id == ^hive_id,
        where: c.target_id in ^ids or (^baseline? and is_nil(c.target_id)),
        distinct: c.target_id,
        order_by: [asc: c.target_id, desc: c.inserted_at, desc: c.id],
        select: struct(c, ^@change_fields),
        preload: [:changed_by]
    )
    |> Map.new(&{&1.target_id, &1})
  end

  defp holder_keys(holders) do
    holders = Enum.take(holders, @bulk_max)
    baseline? = Enum.any?(holders, &(&1 in [nil, :hive]))

    ids =
      uuids(
        for holder <- holders, holder not in [nil, :hive] do
          case holder do
            %Target{id: id} -> id
            id -> id
          end
        end
      )

    {ids, baseline?}
  end

  defp uuids(ids) do
    for id <- Enum.take(ids, @bulk_max), is_binary(id), {:ok, id} <- [Ecto.UUID.cast(id)], do: id
  end

  ## History

  @doc """
  The changes of the baseline (`nil`) or of a target, newest first, a page of
  #{@page_size}, `changed_by` preloaded. `:all` as the holder lists every change of the hive,
  `target` preloaded.
  """
  @spec list_changes(Scope.t(), holder | :all, pos_integer) :: page(Change.t())
  def list_changes(%Scope{hive: %Hive{id: hive_id}} = scope, holder, page \\ 1) do
    query =
      from c in Change, where: c.hive_id == ^hive_id, order_by: [desc: c.inserted_at, desc: c.id]

    case holder do
      :all ->
        query |> preload([:changed_by, :target]) |> paginate(page)

      holder ->
        case holder_id(scope, holder) do
          {:ok, nil} ->
            query |> where([c], is_nil(c.target_id)) |> preload(:changed_by) |> paginate(page)

          {:ok, target_id} ->
            query
            |> where([c], c.target_id == ^target_id)
            |> preload(:changed_by)
            |> paginate(page)

          {:error, _not_found} ->
            empty_page()
        end
    end
  end

  @doc "One change of the scope's hive by id, `changed_by` and `target` preloaded."
  @spec get_change(Scope.t(), String.t()) :: {:ok, Change.t()} | refusal
  def get_change(%Scope{hive: %Hive{id: hive_id}}, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Change{} = change <-
           Repo.one(
             from c in Change,
               where: c.id == ^id and c.hive_id == ^hive_id,
               preload: [:changed_by, :target]
           ) do
      {:ok, change}
    else
      _ -> {:error, not_found(gettext("This hive has no such change."))}
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
  @spec export(Scope.t(), holder) ::
          {:ok, %{runner_file: String.t(), policy_file: String.t() | nil, notes: [String.t()]}}
  def export(%Scope{} = scope, holder), do: {:ok, Export.text(effective(scope, holder))}

  ## Writes, inside

  defp put_rule(scope, holder, action, attrs) do
    with {:ok, attrs} <- attrs(attrs),
         {:ok, membership} <- member(scope),
         {:ok, target_id} <- holder_id(scope, holder),
         {:ok, candidate} <- candidate(action, attrs),
         :ok <- lock_is_the_hives(target_id, candidate.locked) do
      write(scope, target_id, fn hive ->
        put(hive, scope.user, membership, target_id, candidate, attrs)
      end)
    end
  end

  defp candidate(action, attrs) do
    %Rule{} |> Rule.changeset(Map.put(attrs, "action", action)) |> applied()
  end

  # Under the hive's lock: the rule already there is read here, so two writers of one
  # host meet as an add and a change, never as two adds, and who may change it is
  # decided on the row as it is now.
  defp put(hive, user, membership, target_id, candidate, attrs) do
    existing = existing(hive.id, target_id, candidate)

    with :ok <- may_change(membership, existing),
         :ok <- may_lock(membership, existing, attrs),
         :ok <- room(hive.id, target_id, existing) do
      store(hive, user, target_id, existing, candidate, attrs)
    end
  end

  defp room(_hive_id, _target_id, %Rule{}), do: :ok

  defp room(hive_id, target_id, nil) do
    if length(rules(hive_id, target_id)) < @rules_max do
      :ok
    else
      {:error,
       Error.new(
         :invalid,
         gettext(
           "There are %{max} rules here already, which is the most one list holds. Remove one, or say several hosts with a *. suffix.",
           max: @rules_max
         )
       )}
    end
  end

  defp store(hive, user, target_id, nil, candidate, _attrs) do
    rule =
      Repo.insert!(%{
        candidate
        | organisation_id: hive.organisation_id,
          hive_id: hive.id,
          target_id: target_id,
          created_by_id: user_id(user)
      })

    {:ok, rule, "rule_added", Rule.subject(rule)}
  end

  # What the caller did not name stays: the lock, and the paths and the argument of an
  # allow. Opening a host held to paths to every path takes `paths: nil`, said.
  defp store(_hive, _user, _target_id, %Rule{} = existing, candidate, attrs) do
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
  defp put_path(scope, holder, host, path, action) do
    host = host |> to_string() |> String.trim() |> String.downcase()

    with {:ok, membership} <- member(scope),
         {:ok, target_id} <- holder_id(scope, holder),
         :ok <- a_path(path) do
      write(scope, target_id, fn hive ->
        effective = effective(scope, holder)

        with :ok <- not_locked_above(effective, target_id, host),
             {:ok, paths} <- paths_after(effective, host, path, action),
             attrs = %{"host" => host, "paths" => paths},
             {:ok, candidate} <- candidate("allow", attrs) do
          put(hive, scope.user, membership, target_id, candidate, attrs)
        end
      end)
    end
  end

  # A request's path as a rule: itself, never a pattern a request happened to spell.
  defp a_path(path) do
    if Grammar.path?(path) and not String.contains?(path, "*"),
      do: :ok,
      else:
        {:error,
         Error.new(:invalid, gettext("This path cannot be written as a path rule."), :paths)}
  end

  defp not_locked_above(_effective, nil, _host), do: :ok

  defp not_locked_above(%Effective{entries: entries}, _target_id, host) do
    if Enum.any?(
         entries,
         &(&1.kind == :host and &1.host == host and &1.source == :hive and &1.locked)
       ) do
      {:error,
       Error.new(
         :locked,
         gettext(
           "The hive's rule for %{host} is locked, so a target cannot change its paths. An owner changes it in the hive.",
           host: host
         ),
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
          do:
            {:error,
             Error.new(
               :invalid,
               gettext("%{host} is already reached on every path.", host: host),
               :paths
             )},
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
               gettext(
                 "%{path} is allowed by the pattern %{pattern}. The document cannot take one path out of a pattern: replace %{pattern} with the paths that are needed.",
                 path: path,
                 pattern: pattern
               ),
               :paths
             )}

          true ->
            {:error,
             Error.new(
               :invalid,
               gettext(
                 "%{path} is not among the paths %{host} is held to, so it is denied already.",
                 path: path,
                 host: host
               ),
               :paths
             )}
        end

      _ ->
        if host in effective.allow do
          {:error,
           Error.new(
             :invalid,
             gettext(
               "%{host} is reached on every path, and the document cannot allow every path but one. Hold %{host} to the paths it needs, and this one is denied by not being among them.",
               host: host
             ),
             :paths
           )}
        else
          {:error,
           Error.new(
             :invalid,
             gettext("%{host} is not allowed, so none of its paths is.", host: host),
             :paths
           )}
        end
    end
  end

  defp set_locked(scope, rule_or_id, locked) do
    with {:ok, membership} <- member(scope),
         :ok <- owner(membership, gettext("Only an owner locks or unlocks a rule.")),
         {:ok, rule} <- get_rule(scope, rule_id(rule_or_id)),
         :ok <- lock_is_the_hives(rule.target_id, true) do
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
      nil -> {:error, not_found(gettext("This rule is gone: somebody removed it a moment ago."))}
    end
  end

  # One write: the hive's row is locked first, so writes of one hive happen one after
  # another and versions count without gaps. `FOR NO KEY UPDATE`, not `FOR UPDATE`: every
  # insert of an event or a run takes `FOR KEY SHARE` on its hive through the foreign
  # key, and a policy write must never make the receiver wait; then the change, its row in the history and
  # the renders. Whatever refuses rolls everything back.
  defp write(%Scope{hive: %Hive{} = hive, user: user}, target_id, fun) do
    result =
      Repo.transact(fn ->
        hive = Repo.one!(from h in Hive, where: h.id == ^hive.id, lock: "FOR NO KEY UPDATE")
        before = snapshot(hive, target_id)

        with {:ok, value, action, subject} <- fun.(hive) do
          hive = Repo.one!(from h in Hive, where: h.id == ^hive.id)
          after_ = snapshot(hive, target_id)

          if before == after_ do
            {:ok, {value, nil}}
          else
            change = insert_change(hive, user, target_id, action, subject, before, after_)

            with :ok <- render_all(hive, change), do: {:ok, {value, change}}
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
           %{hive_id: hive.id, target_id: change.target_id, action: change.action}}
        )

        {:ok, value}

      {:error, %Error{}} = refusal ->
        refusal
    end
  end

  # The mode is the holder's own: the hive's for the baseline, and for a target the
  # one it set or "inherit", so its history shows its own changes and not the hive's.
  defp snapshot_mode(%Hive{} = hive, nil), do: hive.egress_mode

  defp snapshot_mode(%Hive{}, target_id) do
    Repo.one(from p in Target, where: p.id == ^target_id, select: p.egress_mode) ||
      "inherit"
  end

  defp snapshot(%Hive{} = hive, target_id) do
    %{
      "mode" => snapshot_mode(hive, target_id),
      "rules" =>
        for rule <- rules(hive.id, target_id) do
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

  defp insert_change(hive, user, target_id, action, subject, before, after_) do
    Repo.insert!(%Change{
      organisation_id: hive.organisation_id,
      hive_id: hive.id,
      target_id: target_id,
      action: action,
      subject: subject,
      before: before,
      after: after_,
      changed_by_id: user_id(user),
      inserted_at: DateTime.utc_now()
    })
  end

  @doc """
  Renders the documents of every managed hive again through today's resolution, in the
  hive's lock, for `mix apiary.policy.rerender`: a holder whose bytes change gets a new
  version and a `rerendered` change (no change of the rules: `before` equals `after`),
  and unchanged bytes write nothing. What an upgrade that changed what a render says
  (a release that put `deny` in the document) needs once. `%{hives: n, versions: m}`,
  the hives visited and the versions written.
  """
  @spec rerender_all() :: %{hives: non_neg_integer, versions: non_neg_integer}
  def rerender_all do
    Repo.all(from c in Change, distinct: true, select: c.hive_id)
    |> Enum.reduce(%{hives: 0, versions: 0}, fn hive_id, totals ->
      case rerender(hive_id) do
        {:ok, versions} -> %{hives: totals.hives + 1, versions: totals.versions + versions}
        {:error, _error} -> totals
      end
    end)
  end

  @doc false
  # One hive: in its lock, as any write. Nothing is announced when nothing was written.
  def rerender(hive_id) do
    result =
      Repo.transact(fn ->
        hive = Repo.one!(from h in Hive, where: h.id == ^hive_id, lock: "FOR NO KEY UPDATE")

        if managed_hive?(hive.id) do
          render_holders(hive, fn target_id, rendered, store ->
            with {:ok, document} <- rendered do
              digest = Render.digest(document)

              case Repo.one(newest(hive.id, target_id)) do
                %RunConfiguration{digest: ^digest} ->
                  {:ok, 0}

                nil ->
                  {:ok, 0}

                %RunConfiguration{} = current ->
                  snapshot = snapshot(hive, target_id)

                  change =
                    insert_change(hive, nil, target_id, "rerendered", nil, snapshot, snapshot)

                  configuration = store.(change)

                  Repo.update_all(from(c in Change, where: c.id == ^change.id),
                    set: [version_after: configuration.version]
                  )

                  Logger.info(
                    "policy rerendered hive=#{hive.id} target=#{target_id || "baseline"} " <>
                      "version=#{current.version}->#{configuration.version}"
                  )

                  {:ok, 1}
              end
            end
          end)
        else
          {:ok, 0}
        end
      end)

    case result do
      {:ok, 0} ->
        {:ok, 0}

      {:ok, versions} ->
        Phoenix.PubSub.broadcast(
          Apiary.PubSub,
          topic(hive_id),
          {:policy_changed, %{hive_id: hive_id, target_id: nil, action: "rerendered"}}
        )

        {:ok, versions}

      {:error, %Error{} = error} ->
        Logger.warning("policy rerender refused hive=#{hive_id}: #{error.message}")
        {:error, error}
    end
  end

  # The baseline, and every target that has rules or a mode of its own or has had a
  # configuration of its own. A target with a mode of its own renders the same bytes
  # when the hive's mode changes, so it gets no new version; one that follows the hive does.
  # The rest: a target whose last rule went keeps its versions, and
  # its next one says what the baseline says.
  defp render_all(%Hive{} = hive, change) do
    render_holders(hive, fn target_id, rendered, store ->
      case rendered do
        {:ok, _document} ->
          configuration = store.(change)

          if change && change.target_id == target_id do
            Repo.update_all(from(c in Change, where: c.id == ^change.id),
              set: [version_after: configuration.version]
            )
          end

          :ok

        {:error, error} ->
          {:error, elsewhere(error, hive, change, target_id)}
      end
    end)
    |> case do
      {:ok, _count} -> :ok
      {:error, _error} = refusal -> refusal
    end
  end

  # Every holder of the hive, each handed `fun.(target_id, rendered, store)`:
  # `rendered` is `{:ok, document}` or the refusal, and `store.(change)` keeps the document
  # under the change (or nil) and answers the configuration in force, the one that was
  # there when the bytes are the same. `fun` answers `:ok` or `{:ok, count}` to go on, or
  # `{:error, _}` to stop: `{:ok, sum}` or the first refusal.
  defp render_holders(%Hive{} = hive, fun) do
    hive_rules = rules(hive.id, nil)

    own =
      Repo.all(from r in Rule, where: r.hive_id == ^hive.id and not is_nil(r.target_id))
      |> Enum.group_by(& &1.target_id)

    rendered =
      Repo.all(
        from c in RunConfiguration,
          where: c.hive_id == ^hive.id and not is_nil(c.target_id),
          distinct: true,
          select: c.target_id
      )

    modes =
      Repo.all(
        from p in Target,
          where: p.hive_id == ^hive.id and not is_nil(p.egress_mode),
          select: {p.id, p.egress_mode}
      )
      |> Map.new()

    holders = [nil | Enum.uniq(Map.keys(own) ++ rendered ++ Map.keys(modes))]

    Enum.reduce_while(holders, {:ok, 0}, fn target_id, {:ok, count} ->
      rules = Map.get(own, target_id, [])
      rendered = document(hive, target_id, modes[target_id], hive_rules, rules)

      store = fn change ->
        {:ok, document} = rendered
        store(hive, change, target_id, document)
      end

      case fun.(target_id, rendered, store) do
        :ok -> {:cont, {:ok, count}}
        {:ok, n} -> {:cont, {:ok, count + n}}
        {:error, _error} = refusal -> {:halt, refusal}
      end
    end)
  end

  defp document(hive, target_id, own_mode, hive_rules, own) do
    with {:ok, effective} <-
           Resolution.resolve_for(hive.egress_mode, own_mode, hive_rules, own, target_id),
         document = Render.document(effective),
         :ok <- small(document),
         :ok <- valid(document) do
      {:ok, document}
    end
  end

  defp store(hive, change, target_id, document) do
    digest = Render.digest(document)

    case Repo.one(newest(hive.id, target_id)) do
      %RunConfiguration{digest: ^digest} = current ->
        current

      current ->
        Repo.insert!(%RunConfiguration{
          organisation_id: hive.organisation_id,
          hive_id: hive.id,
          target_id: target_id,
          version: if(current, do: current.version + 1, else: 1),
          document: document,
          digest: digest,
          rendered_at: DateTime.utc_now(),
          changed_by_id: change && change.changed_by_id,
          policy_change_id: change && change.id
        })
    end
  end

  # The most a runner reads of a document (its `MaxDocument`): a larger one is no run.
  @document_max 1_048_576
  defp small(document) when byte_size(document) <= @document_max, do: :ok

  defp small(_document) do
    {:error,
     Error.new(
       :invalid_document,
       gettext(
         "The change was not made: the run configuration it renders is over 1 MiB, more than a runner reads. Say the paths with fewer, shorter patterns (a final * matches everything below)."
       )
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
           gettext(
             "The change was not made: the run configuration it renders is not one the runner's contract accepts."
           )
         )}
    end
  end

  # A refusal that comes from another holder than the one being changed says which.
  defp elsewhere(%Error{} = error, _hive, %Change{target_id: id}, id), do: error
  defp elsewhere(%Error{} = error, _hive, nil, _target_id), do: error

  defp elsewhere(%Error{} = error, _hive, %Change{}, nil),
    do: %{
      error
      | message: gettext("In the hive's baseline: %{refusal}", refusal: error.message)
    }

  defp elsewhere(%Error{} = error, hive, %Change{}, target_id) do
    case Repo.one(from p in Target, where: p.id == ^target_id and p.hive_id == ^hive.id) do
      %Target{system: system, path: path} ->
        %{
          error
          | message:
              gettext("In the target %{target}, which has rules of its own: %{refusal}",
                target: "#{system}/#{path}",
                refusal: error.message
              )
        }

      nil ->
        error
    end
  end

  ## In force, for this module and for the wire (`Apiary.Policy.Serving`)

  @doc false
  # The configuration in force for a target of the hive, or the baseline's: a read,
  # and nothing but a read. A hive nobody has changed has no baseline row, and none is
  # made here: the first version is written by the first change and by nothing else
  # (`render_all/3`), so what a page shows as version 1 is what the first change made.
  def in_force(_organisation_id, hive_id, target_id) do
    own = target_id && Repo.one(newest(hive_id, target_id))

    case own || Repo.one(newest(hive_id, nil)) do
      %RunConfiguration{} = configuration -> {:ok, configuration}
      nil -> {:error, unmanaged()}
    end
  end

  defp unmanaged do
    Error.new(
      :unmanaged,
      gettext(
        "Nobody has made this hive's policy yet: its machines run under their own, and there is no version until the first change here."
      )
    )
  end

  @doc false
  # The newest version of one holder, read from `run_configurations_version_index`.
  def newest(hive_id, target_id) do
    from c in configurations(hive_id, target_id), order_by: [desc: c.version], limit: 1
  end

  # The expression is the index's own, constant and all (`run_configurations_version_index`):
  # as a parameter it would match only under a custom plan, and a prepared statement
  # goes generic after a few runs.
  defp configurations(hive_id, target_id) do
    from c in RunConfiguration,
      where:
        c.hive_id == ^hive_id and
          fragment(
            "COALESCE(?, '00000000-0000-0000-0000-000000000000'::uuid)",
            c.target_id
          ) == type(^(target_id || @nobody), Ecto.UUID)
  end

  defp by_digest(hive_id, target_id, digest) do
    Repo.one(
      from c in configurations(hive_id, target_id),
        where: c.digest == ^digest,
        order_by: [desc: c.version],
        limit: 1
    )
  end

  ## Helpers

  defp rules(hive_id, nil) do
    Repo.all(
      from r in Rule,
        where: r.hive_id == ^hive_id and is_nil(r.target_id),
        order_by: [desc: r.kind, asc: r.host, asc: r.name]
    )
  end

  defp rules(hive_id, target_id) do
    Repo.all(
      from r in Rule,
        where: r.hive_id == ^hive_id and r.target_id == ^target_id,
        order_by: [desc: r.kind, asc: r.host, asc: r.name]
    )
  end

  defp targets(%Scope{hive: %Hive{id: hive_id}, organisation: %Organisation{id: org_id}}) do
    from p in Target, where: p.hive_id == ^hive_id and p.organisation_id == ^org_id
  end

  # The target's id when it is one of the scope's hive, nil for the baseline.
  defp holder_id(%Scope{}, holder) when holder in [nil, :hive], do: {:ok, nil}

  defp holder_id(%Scope{} = scope, %Target{id: id}) when is_binary(id) do
    case Repo.one(from p in targets(scope), where: p.id == ^id, select: p.id) do
      nil -> {:error, not_found(gettext("This hive has no such target."))}
      id -> {:ok, id}
    end
  end

  defp holder_id(%Scope{}, _holder),
    do: {:error, not_found(gettext("This hive has no such target."))}

  defp existing(hive_id, target_id, %Rule{kind: kind} = candidate) do
    subject = Rule.subject(candidate)

    Enum.find(rules(hive_id, target_id), &(&1.kind == kind and Rule.subject(&1) == subject))
  end

  defp member(%Scope{} = scope) do
    case Organisations.fetch_membership(scope) do
      {:ok, %Membership{} = membership} ->
        {:ok, membership}

      {:error, _unauthorized} ->
        {:error,
         Error.new(
           :unauthorized,
           gettext("Only a member of this hive changes its security policy.")
         )}
    end
  end

  defp mode_is_an_owners,
    do: gettext("Only an owner changes the mode: it decides what runs are denied.")

  defp owner(%Membership{level: :owner}, _message), do: :ok
  defp owner(%Membership{}, message), do: {:error, Error.new(:unauthorized, message)}

  defp may_change(_membership, nil), do: :ok
  defp may_change(_membership, %Rule{locked: false}), do: :ok

  defp may_change(membership, %Rule{locked: true} = rule) do
    owner(
      membership,
      gettext(
        "The rule for %{subject} is locked. Only an owner changes or removes a locked rule.",
        subject: Rule.subject(rule)
      )
    )
  end

  # `locked` is true or false by now (`attrs/1`): what is compared is what is stored.
  defp may_lock(membership, existing, %{"locked" => wanted}) do
    now = if existing, do: existing.locked, else: false

    if wanted == now,
      do: :ok,
      else: owner(membership, gettext("Only an owner locks or unlocks a rule."))
  end

  defp may_lock(_membership, _existing, _attrs), do: :ok

  defp lock_is_the_hives(nil, _locked), do: :ok

  defp lock_is_the_hives(_target_id, true) do
    {:error,
     Error.new(
       :invalid,
       gettext(
         "Only a rule of the hive can be locked: a lock is what holds it against the targets."
       )
     )}
  end

  defp lock_is_the_hives(_target_id, _locked), do: :ok

  # The changeset's errors as the first sentence, or the rule it describes.
  defp applied(%Ecto.Changeset{valid?: true} = changeset),
    do: {:ok, Ecto.Changeset.apply_changes(changeset)}

  defp applied(%Ecto.Changeset{errors: [{field, {message, meta}} | _]}) do
    {:error,
     Error.new(:invalid, Gettext.dgettext(ApiaryWeb.Gettext, "errors", message, meta), field)}
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
      else:
        {:error, Error.new(:invalid, gettext("A rule is locked or it is not: true or false."))}
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
           gettext(
             "This host cannot be named in a policy: a rule takes a host name, not an address of this form."
           ),
           :host
         )}
  end

  defp connection_host(%Scope{}, _connection),
    do: {:error, not_found(gettext("This hive has no such connection."))}

  defp connection_holder(_scope, _connection, :hive), do: {:ok, nil}

  defp connection_holder(%Scope{} = scope, %Connection{run_id: run_id}, :target) do
    target =
      Repo.one(
        from p in targets(scope),
          join: r in Run,
          on: r.target_id == p.id,
          where: r.id == ^run_id and r.hive_id == ^scope.hive.id
      )

    case target do
      %Target{} = target ->
        {:ok, target}

      nil ->
        {:error,
         Error.new(
           :not_found,
           gettext("This run names no target, so the rule has nowhere to go but the hive.")
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
