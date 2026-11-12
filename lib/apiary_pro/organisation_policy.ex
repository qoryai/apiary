defmodule ApiaryPro.OrganisationPolicy do
  @moduledoc """
  The organisation's policy: the level above its workspaces' security policy
  (`Apiary.Policy.Above`, which the core resolves, renders and shows without knowing
  whose it is). Its host rules reach every workspace of the organisation; its two
  settings hold over every workspace and target:

  - the **floor**, `enforce_everywhere`: on, no workspace or target may observe, and
    their mode reads `enforce`, required by the organisation;
  - the **switch**, `own_allows`: on by default; off, only the organisation's allows grant
    a host, and a workspace's or a target's allow is listed but not in force. Denies still
    apply.

  Its denies hold everywhere: no lower rule allows the host. Its allows reach every
  workspace, and a workspace or a target may still deny one, never widen it: how they
  meet is `Apiary.Policy.Resolution`'s to say.

  ## Who

  The feature `organisation_policy` (which needs `security`); where the organisation does
  not have it, nothing here is found, and where the instance does not have it, no level
  holds above the workspaces either. Reading is
  `organisation_policy.read` (owners, admins and readers); the rules are changed by owners
  (`organisation_policy.edit`), the floor (`organisation_policy.set_floor`) and the switch
  (`organisation_policy.set_switch`) by owners too. Every function takes an
  `Apiary.Accounts.Scope` in the organisation.

  The policy holds above every workspace while the instance has the feature, whatever
  features the organisation is granted: granting the feature or taking it away shows or
  hides the organisation's pages only, and renders nothing again.

  ## A write

  Every write is one transaction, in the lock order of docs/access.md: the organisation
  and its operator `FOR SHARE`, then every workspace of the organisation in use, in the
  order of their ids `FOR NO KEY UPDATE` (`Apiary.Policy.lock_workspaces/2`, as a write
  of one workspace's policy takes that workspace's), then the person's membership and account
  `FOR SHARE`, the action asked again of what they hold; then the policy's row
  `FOR NO KEY UPDATE`, written on the first change. The rules are checked as the core's
  are (`Apiary.Policy.Rule`'s grammar, one rule per host, at most #{500} of them, and
  the organisation's rules resolved among themselves), then every workspace is rendered
  again under the policy as it is now (`Apiary.Policy.rerender_in/3` with
  `action: "above_changed"`): each holder whose bytes change gets a new version and a
  separate change in the workspace's history, naming this change as its cause; a
  workspace with no version yet gets its version 1, so a deny holds there too. A render
  the resolution refuses rolls everything back, said with the workspace's name. The
  entry is the organisation's (`Apiary.Audit`, the organisation its subject), with the
  rules before and after and, in `details`, the kind of change, its subject and
  `rendered`, the version each workspace was left at (nil where its bytes stayed the
  same). After the commit the workspaces' pages are told (`Apiary.Policy.announce/1`),
  and the organisation's (`topic/1`).

  So a write of a workspace's policy and a write of the organisation's wait for each
  other: both hold the organisation, and both take the workspace in the same order
  (`test/apiary_pro/organisation_policy_races_test.exs`).
  """

  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Organisations, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.{Above, Error, Resolution}
  alias ApiaryPro.OrganisationPolicy.Rule

  @feature :organisation_policy
  @rules_max 500
  @page_size 50
  @actions ~w(organisation_policy.edit organisation_policy.set_floor organisation_policy.set_switch)

  @typedoc "A change of the organisation's policy, as its History lists it."
  @type change :: %{
          id: Ecto.UUID.t(),
          action: Access.action(),
          change: String.t() | nil,
          subject: String.t() | nil,
          before: map | nil,
          after: map | nil,
          rendered: %{optional(Ecto.UUID.t()) => pos_integer | nil},
          changed_by_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t()
        }

  @typedoc "A page of changes."
  @type page :: %{items: [change], page: pos_integer, pages: pos_integer, total: non_neg_integer}

  @typedoc "One workspace under the organisation's policy, for the Workspaces tab."
  @type summary :: %{
          workspace: %Workspace{},
          mode: String.t(),
          own_mode: String.t(),
          targets_observing: non_neg_integer,
          own_rules: non_neg_integer,
          own_allows: non_neg_integer,
          allows_off: non_neg_integer,
          version: pos_integer | nil
        }

  @doc "rules_max/0 is the most rules the organisation's policy holds."
  @spec rules_max() :: pos_integer
  def rules_max, do: @rules_max

  ## Topics

  @doc "topic/1 is the topic of the organisation's policy: `\"organisation_policy:<organisation_id>\"`."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(organisation_id), do: "organisation_policy:#{organisation_id}"

  @doc """
  subscribe/1 subscribes the caller to the policy of the scope's organisation: after each
  write, `{:organisation_policy_changed, %{organisation_id:, action:}}`.
  """
  @spec subscribe(Scope.t()) :: :ok
  def subscribe(%Scope{organisation: %Organisation{id: id}}),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(id))

  ## Reading

  @doc """
  get/1 is the policy of the scope's organisation (`organisation_policy.read`): the row
  of its settings, nil until the first change, and its rules, by host, each as the core
  shapes a rule (`ApiaryPro.OrganisationPolicy.Rule.to_core_rule/1`).
  `{:ok, %{policy:, rules:}}`; `Apiary.Access`'s answer otherwise, `{:error, :not_found}`
  where the feature is off.
  """
  @spec get(Scope.t()) ::
          {:ok, %{policy: __MODULE__.Policy.t() | nil, rules: [Apiary.Policy.Rule.t()]}}
          | {:error, Access.reason()}
  def get(%Scope{organisation: %Organisation{id: id} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"organisation_policy.read", organisation) do
      {:ok, %{policy: policy(id), rules: Enum.map(rules(id), &Rule.to_core_rule/1)}}
    end
  end

  def get(_scope), do: {:error, :not_found}

  @doc """
  get_rule/2 is one rule of the scope's organisation by id, as the core shapes it
  (`organisation_policy.read`). `{:error, %Apiary.Policy.Error{}}` for one that is not
  there, or not the organisation's.
  """
  @spec get_rule(Scope.t(), String.t()) :: {:ok, Apiary.Policy.Rule.t()} | {:error, Error.t()}
  def get_rule(%Scope{organisation: %Organisation{id: id} = organisation} = scope, rule_id) do
    with :ok <- authorized(scope, :"organisation_policy.read", organisation),
         {:ok, rule} <- find(id, rule_id) do
      {:ok, Rule.to_core_rule(rule)}
    end
  end

  def get_rule(_scope, _rule_id), do: {:error, not_found()}

  @doc """
  above_workspace/1 is the policy that holds above `workspace`: its organisation's
  policy as an `Apiary.Policy.Above`, with its host rules, its floor and its switch; nil
  where the organisation has no policy yet, or the instance does not have the feature.
  The feature is read from the instance alone (`Apiary.Features.on?/1`): an organisation
  that does not have it still has its policy held above every workspace. The edition's
  answer (`c:Apiary.Edition.above_workspace/1`, `ApiaryPro.Edition`) is this, carrying the organisation's variables, or the variables
  alone where this is nil (`ApiaryPro.OrganisationVariables.above_without_policy/1`).
  """
  @spec above_workspace(%Workspace{}) :: Above.t() | nil
  def above_workspace(%Workspace{organisation_id: organisation_id}) do
    row =
      Repo.one(
        from p in __MODULE__.Policy,
          join: o in Organisation,
          on: o.id == p.organisation_id,
          where: p.organisation_id == ^organisation_id,
          select: {p, o}
      )

    with {policy, organisation} <- row,
         true <- Apiary.Features.on?(@feature) do
      %Above{
        id: organisation.id,
        name: organisation.name,
        slug: organisation.slug,
        rules: organisation_id |> rules() |> Enum.map(&Rule.to_core_rule/1),
        floor: policy.enforce_everywhere,
        own_allows: policy.own_allows
      }
    else
      _none -> nil
    end
  end

  @doc """
  workspaces_summary/1 is every workspace of the scope's organisation in use, by name,
  under its policy (`organisation_policy.read`): the mode in force for its baseline, the
  mode it set for itself (`own_mode`, which holds where the floor does not) and how many
  of its targets set observe for themselves (`targets_observing`), how many workspace
  rules it has, how many of them are allows and how many of them are not in
  force (the switch off, or the organisation's deny over them), and the version its
  baseline serves: what the floor's and the switch's confirms say they change. One
  resolution and one read of the modes per workspace.
  """
  @spec workspaces_summary(Scope.t()) :: {:ok, [summary]} | {:error, Access.reason()}
  def workspaces_summary(%Scope{organisation: %Organisation{} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"organisation_policy.read", organisation) do
      {:ok, Enum.map(Organisations.list_workspaces(scope), &summary(scope, &1))}
    end
  end

  defp summary(scope, %Workspace{} = workspace) do
    there = %{scope | workspace: workspace}
    effective = Policy.effective(there, nil)

    own =
      for %{kind: :host, source: source} = entry <- effective.entries,
          source != :organisation,
          do: entry

    allows = Enum.filter(own, &(&1.action == :allow))

    version =
      case Policy.current_configuration(there, nil) do
        {:ok, configuration} -> configuration.version
        _none -> nil
      end

    modes = Policy.mode_summary(there)

    %{
      workspace: workspace,
      mode: effective.mode,
      own_mode: modes.mode,
      targets_observing: Enum.count(modes.own_modes, &(&1 == "observe")),
      own_rules: length(own),
      own_allows: length(allows),
      allows_off: Enum.count(allows, &(not &1.in_force)),
      version: version
    }
  end

  @doc """
  rule_activity/2 is the use of the organisation's rules since `since`, over every
  workspace of the organisation: `%{rule id => %{allowed:, denied:}}`, the sums of each
  workspace's (`Apiary.Policy.rule_activity/3`, a bounded read each). `:unavailable`
  when any workspace's could not be counted, so a count is never partial.
  """
  @spec rule_activity(Scope.t(), DateTime.t()) ::
          {:ok, %{Ecto.UUID.t() => %{allowed: non_neg_integer, denied: non_neg_integer}}}
          | :unavailable
  def rule_activity(%Scope{organisation: %Organisation{id: id} = organisation} = scope, since) do
    with :ok <- Access.authorize(scope, :"organisation_policy.read", organisation) do
      ids = MapSet.new(rules(id), & &1.id)

      Enum.reduce_while(Organisations.list_workspaces(scope), {:ok, %{}}, fn workspace,
                                                                             {:ok, acc} ->
        case Policy.rule_activity(%{scope | workspace: workspace}, nil, since) do
          {:ok, counts} ->
            {:cont,
             {:ok,
              counts
              |> Enum.filter(fn {rule_id, _n} -> MapSet.member?(ids, rule_id) end)
              |> Enum.reduce(acc, fn {rule_id, n}, acc ->
                Map.update(
                  acc,
                  rule_id,
                  n,
                  &%{allowed: &1.allowed + n.allowed, denied: &1.denied + n.denied}
                )
              end)}}

          _unavailable ->
            {:halt, :unavailable}
        end
      end)
    else
      _refused -> :unavailable
    end
  end

  @doc """
  list_changes/2 is a page of #{@page_size} changes of the scope's organisation's policy,
  newest first (`organisation_policy.read`): its entries in the audit trail, each with
  the kind of change, its subject, the rules before and after, the versions it left
  each workspace at (`rendered`) and who made it.
  """
  @spec list_changes(Scope.t(), pos_integer) :: {:ok, page} | {:error, Access.reason()}
  def list_changes(%Scope{organisation: %Organisation{id: id} = organisation} = scope, page) do
    with :ok <- Access.authorize(scope, :"organisation_policy.read", organisation) do
      query =
        from e in Entry,
          where: e.organisation_id == ^id and e.subject_kind == "organisation",
          where: e.action in ^@actions

      total = Repo.aggregate(query, :count)
      pages = max(ceil(total / @page_size), 1)
      page = if is_integer(page), do: page |> max(1) |> min(pages), else: 1

      items =
        Repo.all(
          from e in query,
            order_by: [desc: e.inserted_at, desc: e.id],
            limit: @page_size,
            offset: ^((page - 1) * @page_size)
        )
        |> Enum.map(&change/1)

      {:ok, %{items: items, page: page, pages: pages, total: total}}
    end
  end

  defp change(%Entry{} = entry) do
    details = entry.details || %{}

    %{
      id: entry.id,
      action: String.to_existing_atom(entry.action),
      change: details["change"],
      subject: details["subject"],
      before: entry.before,
      after: entry.after,
      rendered: details["rendered"] || %{},
      changed_by_id: if(entry.actor_kind == :person, do: entry.actor_id),
      inserted_at: entry.inserted_at
    }
  end

  ## Writing

  @doc """
  allow/2 allows a host in the organisation's policy (`organisation_policy.edit`),
  replacing the organisation's rule for the same host when there is one. `attrs`, with
  atom or string keys: `host`, and `paths`, a list of the paths the host is held to
  (`nil` for every path, which a new rule is on; `[]` for no path at all). What `attrs`
  does not name stays as the rule has it. `{:ok, rule}`, the rule as the core shapes it;
  `{:error, %Apiary.Policy.Error{}}` with the first sentence of what is wrong: the host's
  or a path's grammar, too many rules, two rules that cannot both hold, or a workspace
  whose rules the policy as it would be cannot resolve with, said with the workspace's
  name; `Apiary.Access`'s answer otherwise, asked before anything is locked and again
  under the locks.
  """
  @spec allow(Scope.t(), map) :: {:ok, Apiary.Policy.Rule.t()} | {:error, Error.t()}
  def allow(%Scope{} = scope, attrs) when is_map(attrs), do: put_rule(scope, "allow", attrs)

  @doc "deny/2 denies a host in the organisation's policy, as `allow/2` allows one: a deny has no paths."
  @spec deny(Scope.t(), map) :: {:ok, Apiary.Policy.Rule.t()} | {:error, Error.t()}
  def deny(%Scope{} = scope, attrs) when is_map(attrs), do: put_rule(scope, "deny", attrs)

  @doc """
  remove_rule/2 removes a rule of the organisation's policy, by the rule or its id
  (`organisation_policy.edit`). `{:ok, rule}`, as it was; `{:error, %Apiary.Policy.Error{}}`
  for one that is not there, or a workspace the policy without it cannot resolve with.
  """
  @spec remove_rule(Scope.t(), Apiary.Policy.Rule.t() | Rule.t() | String.t()) ::
          {:ok, Apiary.Policy.Rule.t()} | {:error, Error.t()}
  def remove_rule(%Scope{} = scope, %{id: id}) when is_binary(id), do: remove_rule(scope, id)

  def remove_rule(%Scope{organisation: %Organisation{id: organisation_id}} = scope, rule_id) do
    write(scope, :"organisation_policy.edit", fn _policy, _scope ->
      with {:ok, rule} <- find(organisation_id, rule_id) do
        Repo.delete!(rule)
        {:ok, Rule.to_core_rule(rule), "rule_removed", rule.host}
      end
    end)
  end

  @doc """
  set_floor/2 requires `enforce` in every workspace of the organisation, or stops
  requiring it (`organisation_policy.set_floor`): every workspace is rendered again, and
  no workspace or target may observe while it holds. `{:ok, policy}`; nothing is written
  when it holds already.
  """
  @spec set_floor(Scope.t(), boolean) :: {:ok, __MODULE__.Policy.t()} | {:error, Error.t()}
  def set_floor(%Scope{} = scope, on?) when is_boolean(on?) do
    write(scope, :"organisation_policy.set_floor", fn policy, _scope ->
      if policy.enforce_everywhere == on?,
        do: {:ok, policy, nil, nil},
        else:
          {:ok, policy |> Ecto.Changeset.change(enforce_everywhere: on?) |> Repo.update!(),
           "floor_changed", nil}
    end)
  end

  @doc """
  set_switch/2 lets workspaces allow more hosts, or allows only the
  organisation's (`organisation_policy.set_switch`): every workspace is rendered again,
  and, off, a workspace's or a target's allow is listed but not in force. `{:ok, policy}`;
  nothing is written when it holds already.
  """
  @spec set_switch(Scope.t(), boolean) :: {:ok, __MODULE__.Policy.t()} | {:error, Error.t()}
  def set_switch(%Scope{} = scope, on?) when is_boolean(on?) do
    write(scope, :"organisation_policy.set_switch", fn policy, _scope ->
      if policy.own_allows == on?,
        do: {:ok, policy, nil, nil},
        else:
          {:ok, policy |> Ecto.Changeset.change(own_allows: on?) |> Repo.update!(),
           "switch_changed", nil}
    end)
  end

  @doc """
  workspace_created/3 renders the first version of a workspace just created, inside the
  creation's transaction (`c:Apiary.Edition.workspace_created/3`), when its organisation
  has a policy: so a deny of the organisation's holds in it from its first run. The mode the
  workspace sets stays `observe`; the floor makes it `enforce` in force. `:ok`, or the render's
  refusal, which rolls the creation back.
  """
  @spec workspace_created(Ecto.Repo.t(), %Workspace{}, Scope.t()) :: :ok | {:error, Error.t()}
  def workspace_created(_repo, %Workspace{} = workspace, %Scope{} = scope) do
    if above_workspace(workspace) do
      with {:ok, _changes} <-
             Policy.rerender_in(workspace, scope, action: "above_changed", all: true),
           do: :ok
    else
      :ok
    end
  end

  ## Every organisation at once

  @doc """
  render_all/0 renders again every workspace in use of every organisation that has a
  policy, for `ApiaryPro.Release.render_organisation_policies/0`, through today's
  resolution and the level above it: the unmanaged ones too, as a write of the policy
  renders them (`Apiary.Policy.rerender_in/3` with `all: true`), so the organisation's
  policy holds in each of them. A holder whose bytes change gets a new version and a
  `rerendered` change by nobody, the instance's; unchanged bytes write nothing, so a
  second run writes nothing. Each organisation is one transaction, in the lock order of
  a write of its policy: its rows `FOR SHARE`, then its workspaces in use in the order of
  their ids `FOR NO KEY UPDATE`, as the instance, so no people lock; their pages are told
  after the commit. An organisation one of whose workspaces cannot be rendered is left as
  it was, and logged. Nothing where the instance does not have the feature, and nothing
  of an organisation marked for deletion. `%{workspaces: n, versions: m}`, the workspaces
  rendered and the versions written.
  """
  @spec render_all() :: %{workspaces: non_neg_integer, versions: non_neg_integer}
  def render_all do
    if Apiary.Features.on?(@feature) do
      Repo.all(
        from p in __MODULE__.Policy,
          join: o in Organisation,
          on: o.id == p.organisation_id,
          where: is_nil(o.deletion_marked_at) and is_nil(o.purge_started_at),
          order_by: o.id,
          select: o
      )
      |> Enum.reduce(%{workspaces: 0, versions: 0}, fn organisation, totals ->
        case render_organisation(organisation) do
          {:ok, workspaces, versions} ->
            %{workspaces: totals.workspaces + workspaces, versions: totals.versions + versions}

          {:error, _reason} ->
            totals
        end
      end)
    else
      %{workspaces: 0, versions: 0}
    end
  end

  # Every workspace of the organisation in use, rendered in one transaction under the
  # rows a write of its policy holds. `{:ok, workspaces, versions}`, or why it was left.
  defp render_organisation(%Organisation{} = organisation) do
    scope = Scope.for_instance(organisation)

    Repo.transact(fn ->
      with {:ok, workspaces} <- lock_in_use(scope, 3),
           {:ok, changes} <- render_each(workspaces, scope),
           do: {:ok, {length(workspaces), changes}}
    end)
    |> case do
      {:ok, {workspaces, changes}} ->
        Policy.announce(changes)
        {:ok, workspaces, length(changes)}

      {:error, %Error{message: message}} = refused ->
        Logger.warning(
          "organisation policy render refused organisation=#{organisation.id}: #{message}"
        )

        refused

      {:error, reason} = refused ->
        Logger.warning(
          "organisation policy render left organisation=#{organisation.id}: #{inspect(reason)}"
        )

        refused
    end
  end

  defp render_each(workspaces, scope) do
    Enum.reduce_while(workspaces, {:ok, []}, fn workspace, {:ok, all} ->
      case Policy.rerender_in(workspace, scope, all: true) do
        {:ok, made} -> {:cont, {:ok, all ++ made}}
        {:error, _error} = refusal -> {:halt, refusal}
      end
    end)
  end

  # The organisation's rows, then every workspace of it in use, by id; none with no
  # workspace. A workspace marked for deletion between the read and the lock is read
  # again, `attempts` times in all, and `{:error, :busy}` after.
  defp lock_in_use(%Scope{organisation: %Organisation{id: id}} = scope, attempts) do
    ids =
      Repo.all(
        from w in Workspace,
          where: w.organisation_id == ^id and is_nil(w.deletion_marked_at),
          order_by: w.id,
          select: w.id
      )

    case ids == [] || Policy.lock_workspaces(scope, ids) do
      true -> {:ok, []}
      {:ok, workspaces} -> {:ok, workspaces}
      {:error, :not_found} when attempts > 1 -> lock_in_use(scope, attempts - 1)
      {:error, :not_found} -> {:error, :busy}
    end
  end

  ## Inside

  defp put_rule(%Scope{organisation: %Organisation{id: organisation_id}} = scope, action, attrs) do
    attrs = attrs(attrs)

    with {:ok, candidate} <- candidate(action, attrs) do
      write(scope, :"organisation_policy.edit", fn _policy, scope ->
        case Enum.find(rules(organisation_id), &(&1.host == candidate.host)) do
          nil ->
            with :ok <- room(organisation_id) do
              rule =
                Repo.insert!(%{
                  candidate
                  | organisation_id: organisation_id,
                    created_by_id: scope.user && scope.user.id
                })

              {:ok, Rule.to_core_rule(rule), "rule_added", rule.host}
            end

          %Rule{} = existing ->
            paths =
              cond do
                candidate.action == "deny" -> nil
                Map.has_key?(attrs, "paths") -> candidate.paths
                true -> existing.paths
              end

            rule =
              existing
              |> Ecto.Changeset.change(action: candidate.action, paths: paths)
              |> Repo.update!()

            {:ok, Rule.to_core_rule(rule), "rule_changed", rule.host}
        end
      end)
    end
  end

  # The rule as the changeset checks it: the host's and the paths' grammar, with the
  # core's sentences.
  defp candidate(action, attrs) do
    changeset = Rule.changeset(%Rule{}, Map.put(attrs, "action", action))

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {field, {message, meta}} = hd(changeset.errors)

      {:error,
       Error.new(:invalid, Gettext.dgettext(ApiaryProWeb.Gettext, "errors", message, meta), field)}
    end
  end

  # The attributes a caller names, as strings: a host trimmed and lower-cased, paths as a
  # list or a text of one path a line.
  defp attrs(attrs) do
    for {key, value} <- attrs,
        key = to_string(key),
        key in ~w(host paths),
        into: %{} do
      case {key, value} do
        {"host", host} when is_binary(host) ->
          {key, host |> String.trim() |> String.downcase()}

        {"paths", paths} when is_binary(paths) ->
          {key, paths |> String.split(~r/[\s,]+/, trim: true)}

        {"paths", paths} when is_list(paths) or is_nil(paths) ->
          {key, paths}

        {key, value} ->
          {key, value}
      end
    end
  end

  defp room(organisation_id) do
    if length(rules(organisation_id)) < @rules_max do
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

  # One write: the action asked, then, in the lock order, the organisation's rows and
  # every workspace in use, the person's membership and account, the action again, the
  # policy's row; `fun.(policy, scope)` makes the change and answers
  # `{:ok, value, change, subject}` (`change` nil when nothing changed); then every
  # workspace is rendered again and the entry written. After the commit, the pages.
  defp write(%Scope{organisation: %Organisation{} = organisation} = scope, action, fun) do
    with :ok <- authorized(scope, action, organisation) do
      result =
        Repo.transact(fn ->
          with {:ok, workspaces} <- lock_workspaces(scope),
               scope = Access.reload(%{scope | workspace: nil}, lock: :share),
               :ok <- checked(scope, action, scope.organisation),
               policy = lock_policy(scope),
               before = snapshot(policy),
               {:ok, value, change, subject} <- fun.(policy, scope) do
            if change do
              commit_change(scope, action, workspaces, before, change, subject, value)
            else
              {:ok, {value, []}}
            end
          end
        end)

      case result do
        {:ok, {value, changes}} ->
          Policy.announce(changes)
          broadcast(organisation.id, action, changes != [])
          {:ok, value}

        {:error, _reason} = refusal ->
          refusal
      end
    end
  end

  defp commit_change(scope, action, workspaces, before, change, subject, value) do
    organisation = scope.organisation
    policy = policy(organisation.id)
    after_ = snapshot(policy)
    id = Ecto.UUID.generate(version: 7, precision: :monotonic)

    with :ok <- resolves(policy),
         {:ok, changes, rendered} <- rerender(workspaces, scope, id),
         {:ok, _entry} <-
           Audit.record(
             Repo,
             scope,
             action,
             organisation,
             %{
               before: before,
               after: after_,
               details: %{change: change, subject: subject, rendered: rendered}
             },
             id: id
           ) do
      {:ok, {value, changes}}
    end
  end

  # The organisation's rules resolved among themselves, as the core resolves a
  # workspace's: two that cannot both hold refuse the write, with the core's sentence,
  # whether or not the organisation has a workspace to render.
  defp resolves(%__MODULE__.Policy{organisation_id: id}) do
    rules = id |> rules() |> Enum.map(&Rule.to_core_rule/1)

    with {:ok, _effective} <- Resolution.resolve("enforce", rules), do: :ok
  end

  # Every workspace rendered again under the policy as it is now, each handing back its
  # changes, the baseline's first; a refusal is said with the workspace's name.
  defp rerender(workspaces, scope, cause) do
    Enum.reduce_while(workspaces, {:ok, [], %{}}, fn workspace, {:ok, changes, rendered} ->
      case Policy.rerender_in(workspace, scope, action: "above_changed", cause: cause, all: true) do
        {:ok, made} ->
          version =
            Enum.find_value(made, fn change ->
              if is_nil(change.target_id), do: change.version_after
            end)

          {:cont, {:ok, changes ++ made, Map.put(rendered, workspace.id, version)}}

        {:error, %Error{} = error} ->
          {:halt,
           {:error,
            %{
              error
              | message:
                  gettext("In %{workspace}: %{reason}",
                    workspace: workspace.name,
                    reason: error.message
                  )
            }}}
      end
    end)
  end

  # The lock order: the organisation's rows, then every workspace in use, in the order
  # of their ids; with no workspace, the organisation's rows alone.
  defp lock_workspaces(scope) do
    case Enum.map(Organisations.list_workspaces(scope), & &1.id) do
      [] ->
        :ok = Access.lock_places(scope)
        {:ok, []}

      ids ->
        Policy.lock_workspaces(scope, ids)
    end
  end

  # The policy's row, under the locks above, written on the first change.
  defp lock_policy(%Scope{organisation: %Organisation{id: id}} = scope) do
    Repo.one(
      from p in __MODULE__.Policy,
        where: p.organisation_id == ^id,
        lock: "FOR NO KEY UPDATE"
    ) ||
      Repo.insert!(%__MODULE__.Policy{
        organisation_id: id,
        created_by_id: scope.user && scope.user.id
      })
  end

  defp snapshot(%__MODULE__.Policy{organisation_id: id} = policy) do
    %{
      "enforce_everywhere" => policy.enforce_everywhere,
      "own_allows" => policy.own_allows,
      "rules" =>
        for rule <- rules(id) do
          %{
            "kind" => "host",
            "action" => rule.action,
            "host" => rule.host,
            "paths" => rule.paths,
            "locked" => false
          }
        end
    }
  end

  defp broadcast(organisation_id, action, rendered?) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(organisation_id),
      {:organisation_policy_changed,
       %{organisation_id: organisation_id, action: action, rendered: rendered?}}
    )
  end

  defp policy(organisation_id),
    do: Repo.get_by(__MODULE__.Policy, organisation_id: organisation_id)

  defp rules(organisation_id) do
    Repo.all(
      from r in Rule,
        where: r.organisation_id == ^organisation_id,
        order_by: [asc: r.host, asc: r.id]
    )
  end

  defp find(organisation_id, rule_id) do
    with {:ok, id} <- Ecto.UUID.cast(rule_id),
         %Rule{} = rule <- Repo.get_by(Rule, id: id, organisation_id: organisation_id) do
      {:ok, rule}
    else
      _none -> {:error, not_found()}
    end
  end

  defp not_found,
    do: Error.new(:not_found, gettext("The organisation's policy has no such rule."))

  # `Apiary.Access`'s answer as the page takes it: a refusal is an error of the policy's,
  # with a sentence, so the rule form shows it as it shows any other. `authorized/3` reads
  # the scope again first (`Apiary.Access.authorize/3`); `checked/3` asks of the scope as
  # it is, read under the write's locks.
  defp authorized(scope, action, subject), do: checked(Access.reload(scope), action, subject)

  defp checked(scope, action, subject) do
    case Access.check(scope, action, subject) do
      :ok ->
        :ok

      {:error, :forbidden} ->
        {:error, Error.new(:forbidden, forbidden(scope, action))}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, gettext("The organisation's policy is not found here."))}
    end
  end

  defp forbidden(_scope, :"organisation_policy.read"),
    do: gettext("Only an owner or an admin reads the organisation's policy.")

  # In a client whose operator owns it, a change is the operator's owners' alone
  # (`ApiaryPro.Access`): the refusal names them, and the client.
  defp forbidden(scope, _action) do
    case owning_operator(scope) do
      %Organisation{name: operator} ->
        gettext("Only owners of %{operator}, the operator of %{name}, change its policy.",
          operator: operator,
          name: scope.organisation.name
        )

      nil ->
        gettext("Only an owner changes the organisation's policy.")
    end
  end

  # owning_operator/1 is the operator of the scope's organisation, a client, while the
  # operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), whose owners
  # alone change the client's policy; nil otherwise. For the refusals here and the lines
  # of the organisation's policy page.
  @doc false
  @spec owning_operator(Scope.t() | nil) :: %Organisation{} | nil
  def owning_operator(%Scope{organisation: %Organisation{} = organisation} = scope) do
    if ApiaryPro.Flags.operator_infrastructure?() and ApiaryPro.Tenants.client?(organisation),
      do: ApiaryPro.Operators.operator_of(scope)
  end

  def owning_operator(_scope), do: nil
end
