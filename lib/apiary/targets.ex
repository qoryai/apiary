defmodule Apiary.Targets do
  @moduledoc """
  The workspace's targets as the console reads them: the index of them, one target's
  page, and the targets a person pinned.

  A target is what the workspace's runs change, in the system it lives in
  (`Apiary.Runs.Target`), created by the projector when a run first names it; nothing
  here creates one. Every function takes the caller's scope first and reads only the
  scope's workspace.

  **Pins.** A person pins the targets they work in, in a workspace whose runs they read
  (`run.read`), and the sidebar lists the first of them in the order they were pinned. A
  pin is the person's own reading preference, not a change to what the organisation
  holds, so it leaves no audit entry; it goes with its target and with its workspace.

  **The notation.** A target is written as its path, with its system before it only where
  the same path is in more than one system of the workspace
  (`Apiary.Runs.shared_paths/2`), and on the target's own page.

  **The index** (`page/3`) is read in one query, bounded by a window of fourteen days:
  the runs of the window grouped by target and day, which a range of the runs list's
  index yields, and each target's last run, one probe of the index of a target's runs by
  when they started (`runs_workspace_id_target_id_started_index`). Days are UTC days, as
  every count per day is (`docs/lingo.md`). The views' counts (`view_counts/2`) are the
  workspace's, whatever the query.
  """

  import Ecto.Query, warn: false

  alias Apiary.Access
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Run, Target}
  alias Apiary.Targets.Pin

  @page_size 50
  @window_days 14
  @views ~w(all active never)a
  @sorts ~w(last_run name runs denials)a
  @modes ~w(follows observes enforces)a
  @activities ~w(quiet_30 quiet_90)a

  @typedoc "A pinned target as the sidebar lists it."
  @type pinned :: %{id: Ecto.UUID.t(), system: String.t(), path: String.t(), shared: boolean}

  @typedoc """
  What the index asks for (`page/3`): the view (`:all`, `:active`, ran in the last seven
  days, `:never`, no run at all), `text` found anywhere in `system/path`, the `systems`
  and the policy `modes` (`:follows`, `:observes`, `:enforces`, the target's own) to keep,
  `activity` (`:quiet_30`, `:quiet_90`: ran, but not in that many days), `pinned` (the
  person's pins only), the `sort` (`:last_run`, `:name`, `:runs`, most runs in fourteen
  days, `:denials`, most denied attempts in fourteen) and the `page`.
  """
  @type query :: %{
          optional(:view) => :all | :active | :never,
          optional(:text) => String.t() | nil,
          optional(:systems) => [String.t()],
          optional(:modes) => [:follows | :observes | :enforces],
          optional(:activity) => :quiet_30 | :quiet_90 | nil,
          optional(:pinned) => boolean,
          optional(:sort) => :last_run | :name | :runs | :denials,
          optional(:page) => pos_integer
        }

  @typedoc """
  A row of the index: the target, its last run (`state`, `at`, `run_id`) or nil, its runs
  a day over fourteen days (oldest first, today last), how many of those ended well and
  badly, its denied attempts in those fourteen days, and whether its path is in another system too.
  """
  @type row :: %{
          target: Target.t(),
          last: %{state: String.t(), at: DateTime.t(), run_id: Ecto.UUID.t()} | nil,
          days: [non_neg_integer],
          runs: non_neg_integer,
          ended_well: non_neg_integer,
          ended_badly: non_neg_integer,
          denied: non_neg_integer,
          shared: boolean
        }

  @doc "How many targets a page of the index holds."
  def page_size, do: @page_size

  @doc "The views, sorts, policy modes and activities `page/3` takes, in the order shown."
  def views, do: @views
  def sorts, do: @sorts
  def modes, do: @modes
  def activities, do: @activities

  ## One target

  @doc """
  get/3 is the target of the scope's workspace with this system and path, or nil: one
  indexed read.
  """
  @spec get(Scope.t(), String.t(), String.t()) :: Target.t() | nil
  def get(%Scope{} = scope, system, path) when is_binary(system) and is_binary(path) do
    Repo.one(from t in in_scope(scope), where: t.system == ^system and t.path == ^path)
  end

  def get(%Scope{}, _system, _path), do: nil

  @doc "get_by_id/2 is the target of the scope's workspace with this row id, or nil."
  @spec get_by_id(Scope.t(), String.t()) :: Target.t() | nil
  def get_by_id(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from t in in_scope(scope), where: t.id == ^id)
      :error -> nil
    end
  end

  @doc "shared?/2 says whether the target's path is also a path in another system of its workspace."
  @spec shared?(Scope.t(), String.t()) :: boolean
  def shared?(%Scope{} = scope, path) when is_binary(path),
    do: MapSet.member?(Apiary.Runs.shared_paths(scope, [path]), path)

  def shared?(%Scope{}, _path), do: false

  ## The index

  @doc """
  page/3 is a page of the workspace's targets under `query` (`t:query/0`), each a
  `t:row/0`: `%{rows:, page:, pages:, total:}`. A page past the end is the last one.
  """
  @spec page(Scope.t(), query, DateTime.t()) :: %{
          rows: [row],
          page: pos_integer,
          pages: pos_integer,
          total: non_neg_integer
        }
  def page(%Scope{} = scope, query, now \\ DateTime.utc_now()) do
    query = normalise(query)
    {from, day0} = window(now)
    week = DateTime.add(now, -7 * 86_400, :second)
    pinned = if query.pinned, do: MapSet.to_list(pinned_ids(scope)), else: []

    base =
      from t in in_scope(scope),
        as: :target,
        left_join: s in subquery(window_stats(scope, from, day0)),
        as: :stats,
        on: s.target_id == t.id,
        left_lateral_join: l in subquery(last_run()),
        as: :last,
        on: true,
        where: ^filters(query, now, week, pinned)

    read = fn page ->
      Repo.all(
        from [target: t, stats: s, last: l] in base,
          order_by: ^order(query.sort),
          limit: @page_size,
          offset: ^((page - 1) * @page_size),
          select: %{
            target: t,
            last_state: l.state,
            last_at: l.at,
            last_run_id: l.run_id,
            runs: s.runs,
            ended_well: s.ended_well,
            ended_badly: s.ended_badly,
            denied: s.denied,
            days: s.days,
            total: over(count()),
            shared:
              fragment(
                "EXISTS (SELECT 1 FROM targets o WHERE o.workspace_id = ? AND o.path = ? AND o.id <> ?)",
                t.workspace_id,
                t.path,
                t.id
              )
          }
      )
    end

    {page, found} =
      case {query.page, read.(query.page)} do
        {page, [_ | _] = found} ->
          {page, found}

        {1, []} ->
          {1, []}

        # A page past the end says nothing of how many there are: count, and read the last.
        {_beyond, []} ->
          total = Repo.one(from t in subquery(base), select: count())
          last = max(ceil(total / @page_size), 1)
          {last, read.(last)}
      end

    total =
      case found do
        [%{total: total} | _] -> total
        [] -> 0
      end

    %{
      rows: Enum.map(found, &row(&1, day0)),
      page: page,
      pages: max(ceil(total / @page_size), 1),
      total: total
    }
  end

  @doc """
  view_counts/2 is how many targets the workspace has in each view, whatever the query:
  `%{all:, active:, never:}`, active being those that ran in the last seven days.
  """
  @spec view_counts(Scope.t(), DateTime.t()) :: %{
          all: non_neg_integer,
          active: non_neg_integer,
          never: non_neg_integer
        }
  def view_counts(%Scope{} = scope, now \\ DateTime.utc_now()) do
    week = DateTime.add(now, -7 * 86_400, :second)

    Repo.one(
      from t in in_scope(scope),
        as: :target,
        left_lateral_join: l in subquery(last_run()),
        on: true,
        select: %{
          all: count(t.id),
          active: filter(count(t.id), l.at >= ^week),
          never: filter(count(t.id), is_nil(l.run_id))
        }
    )
  end

  @doc """
  systems/1 is the systems the workspace's targets are in, with how many targets each
  holds, the most first: what the index filters by.
  """
  @spec systems(Scope.t()) :: [{String.t(), pos_integer}]
  def systems(%Scope{} = scope) do
    Repo.all(
      from t in in_scope(scope),
        group_by: t.system,
        order_by: [desc: count(t.id), asc: t.system],
        select: {t.system, count(t.id)}
    )
  end

  defp normalise(query) do
    query = Map.new(query)

    %{
      view: if(query[:view] in @views, do: query[:view], else: :all),
      text: Apiary.Runs.like(query[:text] || ""),
      systems: for(system <- List.wrap(query[:systems]), is_binary(system), do: system),
      modes: for(mode <- List.wrap(query[:modes]), mode in @modes, do: mode),
      activity: if(query[:activity] in @activities, do: query[:activity]),
      pinned: query[:pinned] == true,
      sort: if(query[:sort] in @sorts, do: query[:sort], else: :last_run),
      page: if(is_integer(query[:page]) and query[:page] > 0, do: query[:page], else: 1)
    }
  end

  # The window: from the start of the UTC day thirteen days before `now`'s, so that its
  # fourteen days end with today.
  defp window(now) do
    day0 = now |> DateTime.to_date() |> Date.add(1 - @window_days)
    {DateTime.new!(day0, ~T[00:00:00.000000], "Etc/UTC"), day0}
  end

  # The window's runs of each target: in all, ended well and badly, their denied attempts
  # (over the same fourteen days, so the columns count one window), and the runs of each day as `[day, runs]` pairs, day 0 the
  # window's first. Two levels, by target and day and then by target, over the range of
  # the runs list's index the window is.
  defp window_stats(scope, from, day0) do
    by_day =
      from r in Run,
        where: r.organisation_id == ^scope.organisation.id,
        where: r.workspace_id == ^scope.workspace.id,
        where: coalesce(r.started_at, r.inserted_at) >= ^from,
        where: not is_nil(r.target_id),
        group_by: [r.target_id, selected_as(:day)],
        select: %{
          target_id: r.target_id,
          day:
            selected_as(
              fragment("(?)::date", coalesce(r.started_at, r.inserted_at)),
              :day
            ),
          runs: count(r.id),
          ended_well:
            filter(count(r.id), r.state in ^Run.with_old_names(Run.ended_well_states())),
          ended_badly: filter(count(r.id), r.state in ^Run.ended_badly_states()),
          denied: sum(r.denied_count)
        }

    from d in subquery(by_day),
      group_by: d.target_id,
      select: %{
        target_id: d.target_id,
        runs: type(sum(d.runs), :integer),
        ended_well: type(sum(d.ended_well), :integer),
        ended_badly: type(sum(d.ended_badly), :integer),
        denied: type(coalesce(sum(d.denied), 0), :integer),
        days:
          fragment(
            "array_agg(ARRAY[(? - ?::date), ?::integer])",
            d.day,
            type(^day0, :date),
            d.runs
          )
      }
  end

  # A target's last run, for a lateral join on `:target`: one probe of the index of a
  # target's runs by when they started.
  defp last_run do
    from r in Run,
      where: r.workspace_id == parent_as(:target).workspace_id,
      where: r.target_id == parent_as(:target).id,
      order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
      limit: 1,
      select: %{
        state: r.state,
        at: type(coalesce(r.started_at, r.inserted_at), :utc_datetime_usec),
        run_id: r.run_id
      }
  end

  defp filters(query, now, week, pinned) do
    [
      view_filter(query.view, week),
      text_filter(query.text),
      query.systems != [] && dynamic([target: t], t.system in ^query.systems),
      mode_filter(query.modes),
      activity_filter(query.activity, now),
      query.pinned && dynamic([target: t], t.id in type(^pinned, {:array, :binary_id}))
    ]
    |> Enum.filter(& &1)
    |> Enum.reduce(dynamic(true), &dynamic(^&2 and ^&1))
  end

  defp view_filter(:all, _week), do: nil
  defp view_filter(:active, week), do: dynamic([last: l], l.at >= ^week)
  defp view_filter(:never, _week), do: dynamic([last: l], is_nil(l.run_id))

  defp text_filter(nil), do: nil

  defp text_filter(pattern),
    do: dynamic([target: t], ilike(fragment("? || '/' || ?", t.system, t.path), ^pattern))

  defp mode_filter([]), do: nil

  defp mode_filter(modes) do
    modes
    |> Enum.map(fn
      :follows -> dynamic([target: t], is_nil(t.egress_mode))
      :observes -> dynamic([target: t], t.egress_mode == "observe")
      :enforces -> dynamic([target: t], t.egress_mode == "enforce")
    end)
    |> Enum.reduce(&dynamic(^&2 or ^&1))
  end

  defp activity_filter(nil, _now), do: nil

  defp activity_filter(activity, now) do
    days = if activity == :quiet_30, do: 30, else: 90
    cut = DateTime.add(now, -days * 86_400, :second)
    dynamic([last: l], l.at < ^cut)
  end

  # Every order ends on the path and the system, so a page holds still between reads.
  defp order(:last_run),
    do: [desc_nulls_last: dynamic([last: l], l.at)] ++ by_name()

  defp order(:name), do: by_name()

  defp order(:runs),
    do:
      [desc: dynamic([stats: s], coalesce(s.runs, 0)), desc_nulls_last: dynamic([last: l], l.at)] ++
        by_name()

  defp order(:denials),
    do:
      [
        desc: dynamic([stats: s], coalesce(s.denied, 0)),
        desc_nulls_last: dynamic([last: l], l.at)
      ] ++ by_name()

  defp by_name,
    do: [asc: dynamic([target: t], t.path), asc: dynamic([target: t], t.system)]

  defp row(found, _day0) do
    %{
      target: found.target,
      last:
        found.last_run_id &&
          %{state: found.last_state, at: found.last_at, run_id: found.last_run_id},
      days: days(found.days),
      runs: found.runs || 0,
      ended_well: found.ended_well || 0,
      ended_badly: found.ended_badly || 0,
      denied: found.denied || 0,
      shared: found.shared
    }
  end

  # `[day, runs]` pairs as the runs of each of the window's days, oldest first.
  defp days(nil), do: List.duplicate(0, @window_days)

  defp days(pairs) do
    counts = Map.new(pairs, fn [day, runs] -> {day, runs} end)
    for day <- 0..(@window_days - 1), do: Map.get(counts, day, 0)
  end

  ## A target's page

  @doc """
  summary/3 is what a target's header and its About say of it: how many runs it has
  (`runs`), its first and its last run (`first`, `last`: `%{state:, at:, run_id:}` or
  nil), and the fourteen days of the window as `page/3` counts them (`days`, `window`:
  runs, ended well and badly, denied attempts, over the fourteen days).
  """
  @spec summary(Scope.t(), Target.t(), DateTime.t()) :: map
  def summary(%Scope{} = scope, %Target{} = target, now \\ DateTime.utc_now()) do
    {from, day0} = window(now)
    runs = target_runs(scope, target)

    edge = fn direction ->
      Repo.one(
        from r in runs,
          order_by: [
            {^direction, coalesce(r.started_at, r.inserted_at)},
            {^direction, r.id}
          ],
          limit: 1,
          select: %{
            state: r.state,
            at: type(coalesce(r.started_at, r.inserted_at), :utc_datetime_usec),
            run_id: r.run_id
          }
      )
    end

    by_day =
      Repo.all(
        from r in runs,
          where: coalesce(r.started_at, r.inserted_at) >= ^from,
          group_by: selected_as(:day),
          select: %{
            day:
              selected_as(
                fragment("(?)::date", coalesce(r.started_at, r.inserted_at)),
                :day
              ),
            runs: count(r.id),
            ended_well:
              filter(count(r.id), r.state in ^Run.with_old_names(Run.ended_well_states())),
            ended_badly: filter(count(r.id), r.state in ^Run.ended_badly_states()),
            denied: coalesce(sum(r.denied_count), 0)
          }
      )

    counts = Map.new(by_day, &{Date.diff(&1.day, day0), &1.runs})

    %{
      runs: Repo.aggregate(runs, :count),
      first: edge.(:asc),
      last: edge.(:desc),
      days: for(day <- 0..(@window_days - 1), do: Map.get(counts, day, 0)),
      window: %{
        runs: Enum.sum_by(by_day, & &1.runs),
        ended_well: Enum.sum_by(by_day, & &1.ended_well),
        ended_badly: Enum.sum_by(by_day, & &1.ended_badly),
        denied: Enum.sum_by(by_day, &to_integer(&1.denied))
      }
    }
  end

  @doc """
  recent_runs/3 is the target's runs, newest first by when they started, at most
  `limit`: one range of the index of a target's runs.
  """
  @spec recent_runs(Scope.t(), Target.t(), pos_integer) :: [Run.t()]
  def recent_runs(%Scope{} = scope, %Target{} = target, limit \\ 5) do
    Repo.all(
      from r in target_runs(scope, target),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^min(max(limit, 1), 200)
    )
  end

  @doc """
  denied_destinations/4 is the destinations the target's runs were denied since `since`,
  one per host, port and path as Network access counts them, the most attempts first, at
  most `limit`: `%{host:, port:, path:, attempts:, runs:, last_at:}`, and in all,
  `%{destinations:, attempts:}`, the number the target's Network access tab shows under
  Denied for the same window. Read from the workspace's connections last seen in that
  time, so the window bounds it.
  """
  @spec denied_destinations(Scope.t(), Target.t(), DateTime.t(), pos_integer) :: %{
          rows: [map],
          destinations: non_neg_integer,
          attempts: non_neg_integer
        }
  def denied_destinations(%Scope{} = scope, %Target{} = target, since, limit \\ 6) do
    grouped =
      from c in Connection,
        join: r in Run,
        on: r.id == c.run_id and r.workspace_id == c.workspace_id,
        where: c.organisation_id == ^scope.organisation.id,
        where: c.workspace_id == ^scope.workspace.id,
        where: c.last_seen_at >= ^since and c.denied > 0,
        where: r.target_id == ^target.id,
        group_by: [c.host, c.port, c.path],
        select: %{
          host: c.host,
          port: c.port,
          path: c.path,
          attempts: type(sum(c.denied), :integer),
          runs: count(c.run_id, :distinct),
          last_at: max(c.last_seen_at)
        }

    rows =
      Repo.all(
        from d in subquery(grouped),
          order_by: [desc: d.attempts, desc: d.last_at, asc: d.host, asc: d.port, asc: d.path],
          limit: ^limit,
          select: %{
            host: d.host,
            port: d.port,
            path: d.path,
            attempts: d.attempts,
            runs: d.runs,
            last_at: d.last_at,
            destinations: over(count()),
            all_attempts: type(over(sum(d.attempts)), :integer)
          }
      )

    case rows do
      [first | _] ->
        %{
          rows: Enum.map(rows, &Map.drop(&1, [:destinations, :all_attempts])),
          destinations: first.destinations,
          attempts: first.all_attempts
        }

      [] ->
        %{rows: [], destinations: 0, attempts: 0}
    end
  end

  @doc """
  machines/2 is the hosts the target's runs ran on, with how many runs each, the most
  first, at most 8; runtimes/2 the same of the runtimes, with their versions.
  """
  @spec machines(Scope.t(), Target.t()) :: [{String.t(), pos_integer}]
  def machines(%Scope{} = scope, %Target{} = target) do
    Repo.all(
      from r in target_runs(scope, target),
        where: not is_nil(r.host),
        group_by: r.host,
        order_by: [desc: count(r.id), asc: r.host],
        limit: 8,
        select: {r.host, count(r.id)}
    )
  end

  @spec runtimes(Scope.t(), Target.t()) :: [{String.t(), pos_integer}]
  def runtimes(%Scope{} = scope, %Target{} = target) do
    Repo.all(
      from r in target_runs(scope, target),
        where: not is_nil(r.runtime),
        group_by: [r.runtime, r.runtime_version],
        order_by: [desc: count(r.id), asc: r.runtime, asc: r.runtime_version],
        limit: 8,
        select: {r.runtime, r.runtime_version, count(r.id)}
    )
    |> Enum.map(fn
      {runtime, nil, n} -> {runtime, n}
      {runtime, version, n} -> {"#{runtime} #{version}", n}
    end)
  end

  @doc """
  elsewhere/2 is the other targets of the workspace with the target's path, in other
  systems, with how many runs each has: `[{target, runs}]`, by system.
  """
  @spec elsewhere(Scope.t(), Target.t()) :: [{Target.t(), non_neg_integer}]
  def elsewhere(%Scope{} = scope, %Target{} = target) do
    Repo.all(
      from t in in_scope(scope),
        as: :target,
        where: t.path == ^target.path and t.id != ^target.id,
        order_by: [asc: t.system],
        select:
          {t,
           fragment(
             "(SELECT count(*) FROM runs r WHERE r.workspace_id = ? AND r.target_id = ?)",
             t.workspace_id,
             t.id
           )}
    )
  end

  @doc """
  count_by_workspace/1 is how many targets each workspace of the scope's organisation has,
  by the workspace's id, for a reader who may list the organisation's workspaces
  (`workspace.delete`, asked of the organisation): the Workspaces section of its settings.
  A workspace with none is absent; anyone else gets an empty map.
  """
  @spec count_by_workspace(Scope.t()) :: %{Ecto.UUID.t() => non_neg_integer}
  def count_by_workspace(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope
      ) do
    if Access.can?(scope, :"workspace.delete", organisation) do
      from(t in Target,
        where: t.organisation_id == ^organisation_id,
        group_by: t.workspace_id,
        select: {t.workspace_id, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()
    else
      %{}
    end
  end

  @doc "count_runs/2 is how many runs the target has."
  @spec count_runs(Scope.t(), Target.t()) :: non_neg_integer
  def count_runs(%Scope{} = scope, %Target{} = target),
    do: Repo.aggregate(target_runs(scope, target), :count)

  defp target_runs(scope, %Target{id: id}) do
    from r in Run,
      where: r.organisation_id == ^scope.organisation.id,
      where: r.workspace_id == ^scope.workspace.id,
      where: r.target_id == ^id
  end

  defp to_integer(%Decimal{} = n), do: Decimal.to_integer(n)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(nil), do: 0

  ## Pins

  @doc """
  pin/2 pins `target` for the scope's person, after the ones pinned before. Pinning one
  already pinned changes nothing. `{:error, :not_found}` for a target of another
  workspace, one the person does not read and a scope without a person.
  """
  @spec pin(Scope.t(), Target.t()) :: :ok | {:error, :not_found | :forbidden}
  def pin(%Scope{user: %User{id: user_id}} = scope, %Target{} = target) do
    with :ok <- Access.authorize(scope, :"run.read", target) do
      Repo.insert_all(
        Pin,
        [
          %{
            id: Ecto.UUID.generate(),
            organisation_id: target.organisation_id,
            workspace_id: target.workspace_id,
            user_id: user_id,
            target_id: target.id,
            inserted_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:organisation_id, :user_id, :target_id]
      )

      :ok
    end
  end

  def pin(%Scope{}, _target), do: {:error, :not_found}

  @doc """
  unpin/2 takes `target` out of the scope's person's pins; unpinning one that is not
  pinned changes nothing. Refused as `pin/2` is.
  """
  @spec unpin(Scope.t(), Target.t()) :: :ok | {:error, :not_found | :forbidden}
  def unpin(%Scope{user: %User{id: user_id}} = scope, %Target{} = target) do
    with :ok <- Access.authorize(scope, :"run.read", target) do
      Repo.delete_all(
        from p in Pin,
          where: p.organisation_id == ^target.organisation_id,
          where: p.user_id == ^user_id and p.target_id == ^target.id
      )

      :ok
    end
  end

  def unpin(%Scope{}, _target), do: {:error, :not_found}

  @doc """
  list_pins/2 is the targets the scope's person pinned in its workspace, in the order they
  were pinned, at most `limit`, each with whether its path is also in another system
  (`shared`). None for a scope without a person or a workspace.
  """
  @spec list_pins(Scope.t(), pos_integer) :: [pinned]
  def list_pins(scope, limit \\ 7)

  def list_pins(
        %Scope{
          user: %User{id: user_id},
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        limit
      ) do
    pins =
      Repo.all(
        from p in Pin,
          join: t in Target,
          on: t.id == p.target_id and t.workspace_id == p.workspace_id,
          where: p.organisation_id == ^organisation_id and p.workspace_id == ^workspace_id,
          where: p.user_id == ^user_id,
          order_by: [asc: p.inserted_at, asc: p.id],
          limit: ^limit,
          select: %{
            id: t.id,
            system: t.system,
            path: t.path,
            shared:
              fragment(
                "EXISTS (SELECT 1 FROM targets o WHERE o.workspace_id = ? AND o.path = ? AND o.id <> ?)",
                t.workspace_id,
                t.path,
                t.id
              )
          }
      )

    pins
  end

  def list_pins(%Scope{}, _limit), do: []

  @doc "pinned_ids/1 is the ids of the targets the scope's person pinned in its workspace."
  @spec pinned_ids(Scope.t()) :: MapSet.t(Ecto.UUID.t())
  def pinned_ids(%Scope{user: %User{id: user_id}} = scope) do
    from(p in pins_in_scope(scope), where: p.user_id == ^user_id, select: p.target_id)
    |> Repo.all()
    |> MapSet.new()
  end

  def pinned_ids(%Scope{}), do: MapSet.new()

  @doc "pinned?/2 says whether the scope's person pinned `target`."
  @spec pinned?(Scope.t(), Target.t()) :: boolean
  def pinned?(%Scope{user: %User{id: user_id}} = scope, %Target{id: id}) do
    Repo.exists?(
      from p in pins_in_scope(scope), where: p.user_id == ^user_id, where: p.target_id == ^id
    )
  end

  def pinned?(%Scope{}, _target), do: false

  ## Helpers

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from t in Target,
      where: t.organisation_id == ^organisation_id and t.workspace_id == ^workspace_id
  end

  defp pins_in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from p in Pin,
      where: p.organisation_id == ^organisation_id and p.workspace_id == ^workspace_id
  end
end
