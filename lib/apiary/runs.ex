defmodule Apiary.Runs do
  @moduledoc """
  The runs of a workspace, as the console reads them.

  Events come in through `Apiary.Runs.Ingest`, are folded by `Apiary.Runs.Projector` and
  watched by `Apiary.Runs.Liveness`; this module is what pages call. Every function takes
  the caller's scope first and reads only the scope's workspace. Two read more:
  `closed?/2`, for the receiver, which has an access key's workspace and no user, and
  `workspace_facts/3`, for the organisation's overview, which reads the workspaces of the
  scope's organisation it is given.

  Changes are announced on two topics of `Apiary.PubSub`:

    * `topic(workspace_id)`, `"runs:<workspace_id>"`: `{:run_changed, %Run{}}` whenever a
      run of the workspace was projected, found lost or closed;
    * `topic(workspace_id, run_id)`, `"run:<workspace_id>:<run_id>"` (`run_id` is the
      row's id): `{:run_projected, %Run{}, first_sequence, last_sequence}` after a
      projection, with the lowest and highest sequence it folded, and
      `{:run_changed, %Run{}}` as above.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.{Access, Audit}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Workspace, Organisation}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Filters, Target, Run}

  @default_limit 50
  @max_limit 200
  @page_size 50
  @hits_page 10

  ## Topics

  def topic(workspace_id), do: "runs:#{workspace_id}"
  def topic(workspace_id, run_id), do: "run:#{workspace_id}:#{run_id}"

  @doc """
  The topic of the sidebar's alive count: `{:runs_touched, workspace_id}` whenever a run
  of the workspace changed, and nothing else, so every page of the workspace can follow it
  without taking the messages of `topic/1`.
  """
  def touched_topic(workspace_id), do: "runs:#{workspace_id}:touched"

  @doc "Subscribes the caller to `touched_topic/1` of the scope's workspace."
  def subscribe_touched(%Scope{workspace: %Workspace{id: workspace_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, touched_topic(workspace_id))
  end

  @doc "Subscribes the caller to the scope's workspace."
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))
  end

  @doc "Subscribes the caller to one run of the scope's workspace."
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}, %Run{
        id: id,
        workspace_id: workspace_id
      }) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id, id))
  end

  @doc false
  def broadcast_changed(%Run{} = run) do
    broadcast_touched(run)
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.workspace_id), {:run_changed, run})
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.workspace_id, run.id), {:run_changed, run})
  end

  @doc false
  def broadcast_projected(%Run{} = run, first_sequence, last_sequence) do
    broadcast_touched(run)
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.workspace_id), {:run_changed, run})

    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(run.workspace_id, run.id),
      {:run_projected, run, first_sequence, last_sequence}
    )
  end

  defp broadcast_touched(%Run{workspace_id: workspace_id}) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      touched_topic(workspace_id),
      {:runs_touched, workspace_id}
    )
  end

  ## Reads

  @doc "How many runs of the workspace are alive now: pending or running."
  def count_alive(%Scope{} = scope) do
    # Tagged, so that what measures a page's own reads can tell the sidebar's timed count
    # from them (`metadata.options[:sidebar]` of the repo's telemetry event).
    Repo.aggregate(from(r in in_scope(scope), where: r.state in ^Run.alive_states()), :count,
      telemetry_options: [sidebar: true]
    )
  end

  @doc "One run of the scope's workspace by its row id; raises when the workspace has none such."
  def get_run!(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one!(from r in in_scope(scope), where: r.id == ^id)
      :error -> raise Ecto.NoResultsError, queryable: Run
    end
  end

  @doc """
  One run of the scope's workspace by its subject, the id the runner prints and the run's
  URL carries; raises `Ecto.NoResultsError` when the workspace has none such, which a run
  of another workspace and a malformed id both are.
  """
  def get_run_by_run_id!(%Scope{} = scope, run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, run_id} -> Repo.one!(from r in in_scope(scope), where: r.run_id == ^run_id)
      :error -> raise Ecto.NoResultsError, queryable: Run
    end
  end

  @doc "The workspace's runs, newest first. `limit:` defaults to #{@default_limit}, at most #{@max_limit}."
  def list_runs(%Scope{} = scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)

    Repo.all(
      from r in in_scope(scope), order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit
    )
  end

  ## The runs list

  @doc """
  A page of the workspace's runs under the filters, in their order (`sort`: newest first by
  when they started, a run that has only pinged placed by when its ping arrived; oldest
  first; the longest first, by the duration its exit gave or else the time it reported
  elapsed; the most denials first), `per` to a page. Returns the page's runs, the page it
  is (the last one, when the filters asked for one beyond it), the total, the pages and
  the page size.
  """
  def page_runs(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = filtered(scope, filters, now)
    total = Repo.aggregate(query, :count)
    pages = max(ceil(total / filters.per), 1)
    page = min(filters.page, pages)

    runs = Repo.all(page_query(query, filters, page))

    %{runs: runs, page: page, total: total, pages: pages, per: filters.per}
  end

  # Newest and oldest first are the order of the index
  # `runs_workspace_id_started_or_first_heard_index`, expression included, read forwards or
  # backwards, so a page is read from the index and never sorted.
  defp page_query(query, %Filters{sort: sort, per: per}, page) do
    from r in sorted(query, sort),
      limit: ^per,
      offset: ^((page - 1) * per)
  end

  defp sorted(query, "oldest"),
    do: order_by(query, [r], asc: coalesce(r.started_at, r.inserted_at), asc: r.id)

  defp sorted(query, "longest"),
    do:
      order_by(query, [r],
        desc_nulls_last:
          fragment("COALESCE(?, ?::bigint * 1000)", r.duration_ms, r.elapsed_seconds),
        desc: coalesce(r.started_at, r.inserted_at),
        desc: r.id
      )

  defp sorted(query, "denials"),
    do:
      order_by(query, [r],
        desc: r.denied_count,
        desc: coalesce(r.started_at, r.inserted_at),
        desc: r.id
      )

  defp sorted(query, _newest),
    do: order_by(query, [r], desc: coalesce(r.started_at, r.inserted_at), desc: r.id)

  @doc false
  def page_runs_query(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()),
    do: scope |> filtered(filters, now) |> page_query(filters, filters.page)

  @doc """
  The page of the list, under the filters and in their order, that holds the first run
  started on or before the end of `date`, a UTC day, as the filters' dates are: newest
  first, the runs that started after that day come before it; oldest first, the page that
  holds the first run started on or after the day's start. When no run is on that side of
  the day it is the last page; in any other order, the first. One count on the index.
  """
  @spec jump_page(Scope.t(), Filters.t(), Date.t(), DateTime.t()) :: pos_integer
  def jump_page(%Scope{} = scope, %Filters{} = filters, %Date{} = date, now \\ DateTime.utc_now()) do
    query = filtered(scope, filters, now)
    start = DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
    next = DateTime.add(start, 86_400, :second)

    before =
      case filters.sort do
        "newest" ->
          Repo.aggregate(
            from(r in query, where: coalesce(r.started_at, r.inserted_at) >= ^next),
            :count
          )

        "oldest" ->
          Repo.aggregate(
            from(r in query, where: coalesce(r.started_at, r.inserted_at) < ^start),
            :count
          )

        _other ->
          0
      end

    total = Repo.aggregate(query, :count)
    last = max(ceil(total / filters.per), 1)
    min(div(before, filters.per) + 1, last)
  end

  @doc """
  The views of the runs list, each counted under every other filter (the views set the
  states and the denials, so those are left out): `%{all:, alive:, ended_badly:,
  with_denials:}`, in one query. The families are `Apiary.Runs.Filters.families/0`.
  """
  def view_counts(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    Repo.one(
      from r in filtered(scope, %{filters | states: [], denials: false}, now),
        select: %{
          all: count(r.id),
          alive: filter(count(r.id), r.state in ^Run.alive_states()),
          ended_badly: filter(count(r.id), r.state in ^Run.ended_badly_states()),
          with_denials: filter(count(r.id), r.denied_count > 0)
        }
    )
  end

  @doc """
  How many runs the filters return; with no filters, how many runs the workspace has, which
  the list's empty state says the filters hide.
  """
  def count_runs(scope, filters \\ nil, now \\ DateTime.utc_now())

  def count_runs(%Scope{} = scope, nil, _now), do: Repo.aggregate(in_scope(scope), :count)

  def count_runs(%Scope{} = scope, %Filters{} = filters, now),
    do: Repo.aggregate(filtered(scope, filters, now), :count)

  @rail_size 20

  @doc "How many targets the rail lists before \"n more\", and how many each asks for."
  def rail_size, do: @rail_size

  @typedoc "A target and the runs it has under the filters."
  @type target_count :: %{system: String.t(), path: String.t(), runs: non_neg_integer}

  @doc """
  The rail of the runs list: the targets of the runs under the filters without their
  target, counted in runs. `%{all:, pinned:, targets:, more:, unassigned:}`: `all` counts
  every run under those filters; `pinned` is each of `pinned:` (a list of `{system,
  path}`, in its order) with its runs, none left out; `targets` the targets with the most
  runs, `limit:` of them (default #{@rail_size}), the pinned ones left out; `more` how many
  more there are; `unassigned` the runs that name no target. `narrow:` keeps the targets
  whose `system/path` holds the text anywhere, as text (`like/1`), and lists them all,
  pinned or not.
  """
  @spec target_counts(Scope.t(), Filters.t(), keyword) :: %{
          all: non_neg_integer,
          pinned: [target_count],
          targets: [target_count],
          more: non_neg_integer,
          unassigned: non_neg_integer
        }
  def target_counts(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    rail(filtered(scope, %{filters | target: nil}, now), opts)
  end

  # `base` is a query with the run bound as `:run`; what is counted per target is its
  # distinct runs: the runs of the list, the runs that reached out on the connections page.
  defp rail(base, opts) do
    limit = opts |> Keyword.get(:limit, @rail_size) |> max(1) |> min(@max_limit * 5)
    narrow = like(Keyword.get(opts, :narrow))
    pinned = if narrow, do: [], else: Enum.uniq(Keyword.get(opts, :pinned, []))

    {rows, total} = count_targets(base, narrow, limit, pinned)

    pinned_counts =
      case pinned do
        [] ->
          %{}

        pairs ->
          condition =
            Enum.reduce(pairs, dynamic(false), fn {system, path}, acc ->
              dynamic([run: r], ^acc or (r.target_system == ^system and r.target_path == ^path))
            end)

          Repo.all(
            from [run: r] in base,
              where: ^condition,
              group_by: [r.target_system, r.target_path],
              select: {{r.target_system, r.target_path}, count(r.id, :distinct)}
          )
          |> Map.new()
      end

    %{all: all, unassigned: unassigned} =
      Repo.one(
        from [run: r] in base,
          select: %{
            all: count(r.id, :distinct),
            unassigned: filter(count(r.id, :distinct), is_nil(r.target_id))
          }
      )

    %{
      all: all,
      unassigned: unassigned,
      pinned:
        for(
          {system, path} <- pinned,
          do: %{system: system, path: path, runs: Map.get(pinned_counts, {system, path}, 0)}
        ),
      targets: for({system, path, n} <- rows, do: %{system: system, path: path, runs: n}),
      more: max(total - length(rows), 0)
    }
  end

  # The targets under `base` with the most runs, `limit` of them, without the pairs of
  # `except`, and how many there are without those; narrowed to a `like/1` pattern.
  defp count_targets(base, pattern, limit, except) do
    grouped =
      from [run: r] in base,
        where: not is_nil(r.target_id),
        group_by: [r.target_system, r.target_path]

    grouped =
      if pattern,
        do:
          where(
            grouped,
            [run: r],
            ilike(fragment("? || '/' || ?", r.target_system, r.target_path), ^pattern)
          ),
        else: grouped

    grouped =
      Enum.reduce(except, grouped, fn {system, path}, query ->
        where(query, [run: r], not (r.target_system == ^system and r.target_path == ^path))
      end)

    rows =
      Repo.all(
        from [run: r] in grouped,
          order_by: [desc: count(r.id, :distinct), asc: r.target_path, asc: r.target_system],
          limit: ^(limit + 1),
          select: {r.target_system, r.target_path, count(r.id, :distinct)}
      )

    total =
      if length(rows) > limit,
        do:
          Repo.one(
            from g in subquery(select(grouped, [run: r], %{s: r.target_system})), select: count()
          ),
        else: length(rows)

    {Enum.take(rows, limit), total}
  end

  @doc """
  The paths the workspace has on more than one system: where a page writes a target's
  system before its path, and nowhere else (the one notation of a target).
  """
  @spec duplicate_paths(Scope.t()) :: MapSet.t(String.t())
  def duplicate_paths(%Scope{} = scope) do
    Repo.all(
      from t in targets_of(scope), group_by: t.path, having: count(t.id) > 1, select: t.path
    )
    |> MapSet.new()
  end

  @doc """
  What a `repo:` of the query names, among the workspace's targets: `{system, path}` for the
  one target whose `system/path` or whose path it is (compared exactly, then without
  regard to case), else `{nil, text}`, the path on every system it is on (none, or more
  than one). `Apiary.Runs.Filters.apply_query/3` asks it.
  """
  @spec resolve_target(Scope.t(), String.t()) :: {String.t() | nil, String.t()}
  def resolve_target(%Scope{} = scope, text) when is_binary(text) do
    folded = String.downcase(text)

    rows =
      Repo.all(
        from t in targets_of(scope),
          where:
            fragment("lower(? || '/' || ?)", t.system, t.path) == ^folded or
              fragment("lower(?)", t.path) == ^folded,
          select: {t.system, t.path},
          limit: 50
      )

    exact = &Enum.filter(rows, fn {system, path} -> &1.(system, path) end)

    with [] <- exact.(fn system, path -> "#{system}/#{path}" == text end),
         [] <- exact.(fn _system, path -> path == text end),
         [] <- exact.(fn system, path -> String.downcase("#{system}/#{path}") == folded end),
         [] <- exact.(fn _system, path -> String.downcase(path) == folded end) do
      {nil, text}
    else
      [{system, path}] -> {system, path}
      [{_system, path} | _several] -> {nil, path}
    end
  end

  defp targets_of(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from t in Target,
      where: t.organisation_id == ^organisation_id and t.workspace_id == ^workspace_id
  end

  @facet_size 50

  @doc "How many options a section of the Filter menu holds, and how many more each asks for."
  def facet_size, do: @facet_size

  @doc """
  The options of each section of the runs list's Filter menu, counted from the data: every
  facet is counted under the other filters and the range, not under itself, so a section
  shows what choosing another value would give. `%{state:, target:, task:, runtime:, host:,
  key:}`, each `%{options: [{label, value, count}], total: n}`: the most frequent values,
  #{@facet_size} of them unless `limits:` maps the facet's name to more, and the chosen one,
  with how many values there are. `narrow:` maps a facet's name to what the reader typed in
  its section, matched anywhere in the value, case-insensitively, as text and never as a
  pattern, over every value there is.
  """
  def run_facets(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    narrow = Keyword.get(opts, :narrow, %{})
    limits = Keyword.get(opts, :limits, %{})
    limit = &facet_limit(limits[&1])

    %{
      state: state_facet(scope, filters, now),
      target:
        target_facet(
          filtered(scope, %{filters | target: nil}, now),
          filters.target,
          narrow["target"],
          limit.("target")
        ),
      task:
        text_facet(scope, filters, now, :task, gettext("No task"), narrow["task"], limit.("task")),
      runtime:
        text_facet(scope, filters, now, :runtime, nil, narrow["runtime"], limit.("runtime")),
      host: text_facet(scope, filters, now, :host, nil, narrow["host"], limit.("host")),
      key: key_facet(scope, filters, now, narrow["key"], limit.("key"))
    }
  end

  defp facet_limit(n) when is_integer(n), do: n |> max(@facet_size) |> min(@facet_size * 20)
  defp facet_limit(_n), do: @facet_size

  defp state_facet(scope, filters, now) do
    counts =
      Repo.all(
        from r in filtered(scope, %{filters | states: []}, now),
          group_by: r.state,
          select: {r.state, count(r.id)}
      )
      |> Map.new()

    options = for state <- Run.states(), count = counts[state], do: {state, state, count}
    %{options: options, total: length(options)}
  end

  # `base` is a query with the run bound as `:run`, counted in distinct runs.
  defp target_facet(base, chosen, narrow, limit) do
    pattern = like(narrow)
    {rows, total} = count_targets(base, pattern, limit, [])

    options =
      for {system, path, n} <- rows,
          do: {"#{system}/#{path}", Filters.target_value({system, path}), n}

    options =
      with {_system, path} <- chosen,
           value = Filters.target_value(chosen),
           false <- Enum.any?(options, &(elem(&1, 1) == value)) do
        n = Repo.one(from [run: r] in where_target(base, chosen), select: count(r.id, :distinct))
        [{target_text(chosen, path), value, n} | options]
      else
        _ -> options
      end

    unassigned =
      Repo.one(from [run: r] in base, where: is_nil(r.target_id), select: count(r.id, :distinct))

    options =
      if unassigned > 0 and is_nil(pattern),
        do: options ++ [{gettext("Unassigned"), "none", unassigned}],
        else: options

    %{options: options, total: total + if(unassigned > 0 and is_nil(pattern), do: 1, else: 0)}
  end

  defp target_text({nil, _path}, path), do: path
  defp target_text({system, _path}, path), do: "#{system}/#{path}"

  defp text_facet(scope, filters, now, field, none_label, narrow, limit) do
    chosen = Map.fetch!(filters, field)
    base = filtered(scope, Map.put(filters, field, nil), now)
    pattern = like(narrow)

    grouped = from r in base, where: not is_nil(field(r, ^field)), group_by: field(r, ^field)

    grouped =
      if pattern, do: where(grouped, [r], ilike(field(r, ^field), ^pattern)), else: grouped

    rows =
      Repo.all(
        from r in grouped,
          order_by: [desc: count(r.id), asc: field(r, ^field)],
          limit: ^(limit + 1),
          select: {field(r, ^field), count(r.id)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [r], field(r, ^field))), select: count()),
        else: length(rows)

    # A label that reads "none" cannot be told from the absence of one in the URL.
    options =
      for {value, n} <- Enum.take(rows, limit), value != "none", do: {value, value, n}

    options =
      if is_binary(chosen) and not Enum.any?(options, &(elem(&1, 1) == chosen)) do
        n = Repo.aggregate(from(r in base, where: field(r, ^field) == ^chosen), :count)
        [{chosen, chosen, n} | options]
      else
        options
      end

    none =
      if none_label && is_nil(pattern),
        do: Repo.aggregate(from(r in base, where: is_nil(field(r, ^field))), :count),
        else: 0

    options = if none > 0, do: options ++ [{none_label, "none", none}], else: options

    %{options: options, total: total + if(none > 0, do: 1, else: 0)}
  end

  # The access keys the runs came in with, by the key's label: the label is unique in the
  # workspace, and a revoked key keeps its runs.
  defp key_facet(scope, filters, now, narrow, limit) do
    base = filtered(scope, %{filters | key: nil}, now)
    pattern = like(narrow)

    grouped =
      from [run: r] in base,
        join: k in AccessKey,
        on: k.id == r.access_key_id and k.workspace_id == r.workspace_id,
        group_by: k.label

    grouped = if pattern, do: where(grouped, [_r, k], ilike(k.label, ^pattern)), else: grouped

    rows =
      Repo.all(
        from [r, k] in grouped,
          order_by: [desc: count(r.id), asc: k.label],
          limit: ^(limit + 1),
          select: {k.label, count(r.id)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [_r, k], k.label)), select: count()),
        else: length(rows)

    options = for {label, n} <- Enum.take(rows, limit), do: {label, label, n}

    options =
      if is_binary(filters.key) and not Enum.any?(options, &(elem(&1, 1) == filters.key)),
        do: [{filters.key, filters.key, 0} | options],
        else: options

    %{options: options, total: total}
  end

  # What the reader typed, as the operand of ILIKE that matches it anywhere and as text:
  # the pattern's own characters are escaped, so "%" finds a per cent sign and nothing else.
  @doc false
  def like(narrow) when is_binary(narrow) do
    narrow = String.trim(narrow)

    if narrow != "" and byte_size(narrow) <= 256 and String.valid?(narrow) and
         not String.match?(narrow, ~r/[\x00-\x1F\x7F]/) do
      escaped =
        narrow
        |> String.replace("\\", "\\\\")
        |> String.replace("%", "\\%")
        |> String.replace("_", "\\_")

      "%" <> escaped <> "%"
    end
  end

  def like(_narrow), do: nil

  @doc "Whether the run is one the filters return: for a page deciding what a change means to it."
  def matches?(%Scope{} = scope, %Filters{} = filters, %Run{id: id}, now \\ DateTime.utc_now()) do
    Repo.exists?(from r in filtered(scope, filters, now), where: r.id == ^id)
  end

  @doc "Which of the runs with these row ids the filters return: one query for a page's flush."
  def matching_ids(%Scope{} = scope, %Filters{} = filters, ids, now \\ DateTime.utc_now())
      when is_list(ids) do
    Repo.all(from r in filtered(scope, filters, now), where: r.id in ^ids, select: r.id)
  end

  defp filtered(scope, %Filters{} = f, now) do
    {from, to} = Filters.bounds(f, now)

    in_scope(scope)
    |> where_if(f.states != [], dynamic([r], r.state in ^f.states))
    |> where_target(f.target)
    |> where_text(:task, f.task)
    |> where_text(:runtime, f.runtime)
    |> where_text(:host, f.host)
    |> where_key(scope, f.key)
    |> where_query(f.q)
    |> where_if(f.denials, dynamic([r], r.denied_count > 0))
    |> where_if(from, dynamic([r], coalesce(r.started_at, r.inserted_at) >= ^from))
    |> where_if(to, dynamic([r], coalesce(r.started_at, r.inserted_at) < ^to))
  end

  defp where_if(query, condition, dynamic) do
    if condition, do: where(query, ^dynamic), else: query
  end

  defp where_target(query, nil), do: query
  defp where_target(query, :none), do: where(query, [run: r], is_nil(r.target_id))

  defp where_target(query, {nil, path}),
    do: where(query, [run: r], not is_nil(r.target_id) and r.target_path == ^path)

  defp where_target(query, {system, path}),
    do: where(query, [run: r], r.target_system == ^system and r.target_path == ^path)

  defp where_text(query, _field, nil), do: query
  defp where_text(query, field, :none), do: where(query, [r], is_nil(field(r, ^field)))
  defp where_text(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp where_key(query, _scope, nil), do: query

  defp where_key(query, scope, label) do
    keys =
      from k in AccessKey,
        where:
          k.organisation_id == ^scope.organisation.id and k.workspace_id == ^scope.workspace.id,
        where: k.label == ^label,
        select: k.id

    where(query, [r], r.access_key_id in subquery(keys))
  end

  # The free text: the start of the run's id (four hexadecimal characters at least, or a
  # run page's address), or its task or its target, `system/path`, holding it anywhere.
  defp where_query(query, nil), do: query

  defp where_query(query, q) do
    case {like(q), run_id_prefix(q)} do
      {nil, _prefix} ->
        query

      {pattern, prefix} ->
        text =
          dynamic(
            [r],
            ilike(r.task, ^pattern) or
              ilike(fragment("? || '/' || ?", r.target_system, r.target_path), ^pattern)
          )

        condition =
          if prefix,
            do: dynamic([r], ^text or fragment("?::text LIKE ?", r.run_id, ^prefix)),
            else: text

        where(query, ^condition)
    end
  end

  ## Tool invocations

  @doc """
  tool_invocation?/2 says whether an egress attempt is a tool invocation: it names a `tool`
  and its `decision` is `"allowed"`, so the proxy handed the request to the tool. This is
  the one definition; every page, listing and query of this application holds to it.

  An attempt names a tool when the proxy decided it by its path for a host a tool serves.
  One a path rule refused names the tool as well, the tool whose host it was for, and
  never reached it: it is no tool invocation, and reads as any denial. A connection
  refused on its host names no tool. `connections.last_tool` keeps the tool of the last
  attempt in either case; with `last_decision` it says whether that attempt was a tool
  invocation.
  """
  @spec tool_invocation?(String.t() | nil, String.t() | nil) :: boolean
  def tool_invocation?(tool, decision),
    do: is_binary(tool) and tool != "" and decision == "allowed"

  # `tool_invocation?/2` in SQL, of a connection's last attempt: the fold never stores an
  # empty tool, so a tool is a non-null `last_tool`.
  defp tool_invocation do
    dynamic([c], not is_nil(c.last_tool) and c.last_decision == "allowed")
  end

  ## The workspace's connections

  @doc "How many destinations a page of the workspace's connections holds."
  def page_size, do: @page_size

  @doc """
  A page of the workspace's destinations across the runs in range: one row per host, port
  and path, with how many runs reached it, the attempts, and the decision, rule, outcome
  and the rest of the most recent attempt across those runs, the tool whose host it was
  for (`last_tool`) and what answered it (`last_status`) among them; the attempt is a tool
  invocation when `tool_invocation?/2` says so of `last_tool` and `last_decision`.
  Filters: `decision` (destinations with any attempt so decided), `target`, `host` (the
  destination's), `q` (a destination whose host or path holds the text), `tools` (tool
  invocations only: the destinations where the last attempt of a run was a tool
  invocation, that run's connection naming a tool with the decision allowed; each is kept
  whole, so its counts are those without the filter) and the range, which is over when a
  run last reached the destination and never wider than
  `Apiary.Runs.Filters.max_window_days/0` days, so the aggregate is over a bounded set.
  The order is `sort`: denied destinations first, then by when they were first seen,
  newest first (the default); the most recently seen first; the most runs first; the most
  attempts first.
  """
  def page_destinations(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = destinations(scope, filters, now)

    # One pass: the page's rows carry the totals of everything grouped, as window
    # aggregates over the same grouping, so the GROUP BY is not run a second time.
    read = fn page ->
      Repo.all(
        from d in subquery(query),
          order_by: ^destination_order(filters.sort),
          limit: @page_size,
          offset: ^((page - 1) * @page_size),
          select:
            {d,
             %{
               destinations: over(count()),
               denied:
                 type(
                   over(sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", d.denied))),
                   :integer
                 ),
               attempts: type(over(sum(d.attempts)), :integer)
             }}
      )
    end

    {page, found} =
      case {filters.page, read.(filters.page)} do
        {page, [_ | _] = found} ->
          {page, found}

        {1, []} ->
          {1, []}

        # A page past the end says nothing of how many there are: count, and read the last.
        {_beyond, []} ->
          total = Repo.one(from d in subquery(query), select: count())
          last = max(ceil(total / @page_size), 1)
          {last, read.(last)}
      end

    summary =
      case found do
        [{_row, totals} | _] -> totals
        [] -> %{destinations: 0, denied: 0, attempts: 0}
      end

    runs =
      Repo.one(from c in connections_in(scope, filters, now), select: count(c.run_id, :distinct))

    %{
      rows: Enum.map(found, &elem(&1, 0)),
      page: page,
      pages: max(ceil(summary.destinations / @page_size), 1),
      summary: Map.put(summary, :runs, runs)
    }
  end

  # Denied first, then by first seen, newest first, so a row the page holds does not move
  # when it is seen again (see Record.connections/3); or the order the reader chose.
  defp destination_order(sort) do
    lead =
      case sort do
        "recent" -> [desc: dynamic([d], d.last_seen_at)]
        "runs" -> [desc: dynamic([d], d.runs), desc: dynamic([d], d.last_seen_at)]
        "attempts" -> [desc: dynamic([d], d.attempts), desc: dynamic([d], d.last_seen_at)]
        _denied -> [desc: dynamic([d], d.last_decision == "denied")]
      end

    lead ++
      [
        desc: dynamic([d], d.first_seen_at),
        asc: dynamic([d], d.host),
        asc: dynamic([d], d.port),
        asc: dynamic([d], d.path)
      ]
  end

  @doc """
  The views of the workspace's connections, each counted in destinations under every other
  filter (the views set the decision): `%{all:, denied:, allowed:}`, a destination counted
  in each decision any of its attempts had.
  """
  def destination_views(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    grouped =
      from [c, r] in connections_in(scope, %{filters | decision: nil}, now),
        group_by: [c.host, c.port, c.path],
        select: %{allowed: sum(c.allowed), denied: sum(c.denied)}

    Repo.one(
      from d in subquery(grouped),
        select: %{
          all: count(),
          denied: filter(count(), d.denied > 0),
          allowed: filter(count(), d.allowed > 0)
        }
    )
  end

  @doc """
  The rail of the workspace's connections: the targets of the runs that reached out under
  the filters without their target, counted in those runs, as `target_counts/3` counts the
  runs list's, with the same options.
  """
  def destination_target_counts(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    rail(connections_in(scope, %{filters | target: nil}, now), opts)
  end

  @doc """
  The runs that reached a destination, the most recent first, under the same filters:
  `%{runs: [%{run:, allowed:, denied:, last_seen_at:}], total:}`. `limit:` defaults to
  #{@hits_page}.
  """
  def destination_runs(%Scope{} = scope, %Filters{} = filters, {host, port, path}, opts \\ [])
      when is_binary(host) and is_integer(port) and is_binary(path) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = opts |> Keyword.get(:limit, @hits_page) |> max(1) |> min(@max_limit)

    query =
      from c in connections_in(scope, filters, now),
        where: c.host == ^host and c.port == ^port and c.path == ^path

    hits =
      Repo.all(
        from [c, r] in query,
          order_by: [desc: c.last_seen_at, desc: c.id],
          limit: ^limit,
          select: %{run: r, allowed: c.allowed, denied: c.denied, last_seen_at: c.last_seen_at}
      )

    %{runs: hits, total: Repo.aggregate(query, :count)}
  end

  @doc """
  The targets whose runs reached a destination under the same filters, the ones with
  the most runs first, 25 at most: `%{target_id:, system:, path:, runs:,
  connection_id:}`, runs that name no target as one entry with nil for the three.
  `connection_id` is the most recent connection of the destination among the target's
  runs: the row a rule made from the destination is made from (`fetch_connection/2`).
  """
  def destination_targets(
        %Scope{} = scope,
        %Filters{} = filters,
        {host, port, path},
        opts \\ []
      )
      when is_binary(host) and is_integer(port) and is_binary(path) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.all(
      from [c, r] in connections_in(scope, filters, now),
        where: c.host == ^host and c.port == ^port and c.path == ^path,
        group_by: [r.target_id, r.target_system, r.target_path],
        order_by: [desc: count(c.run_id, :distinct), asc: r.target_system, asc: r.target_path],
        limit: 25,
        select: %{
          target_id: r.target_id,
          system: r.target_system,
          path: r.target_path,
          runs: count(c.run_id, :distinct),
          connection_id:
            type(
              fragment("(array_agg(? ORDER BY ? DESC, ? DESC))[1]", c.id, c.last_seen_at, c.id),
              :binary_id
            )
        }
    )
  end

  @doc """
  The target of the scope's workspace that runs name with this system and path, or nil:
  one indexed read, however many targets the workspace has.
  """
  def fetch_target(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        system,
        path
      )
      when is_binary(system) and is_binary(path) do
    Repo.one(
      from p in Target,
        where: p.organisation_id == ^organisation_id and p.workspace_id == ^workspace_id,
        where: p.system == ^system and p.path == ^path,
        limit: 1
    )
  end

  def fetch_target(%Scope{}, _system, _path), do: nil

  @doc """
  One connection of the scope's workspace by its row id, whole. `:error` for an id that is
  not a UUID and for a connection of another workspace.
  """
  def fetch_connection(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        id
      ) do
    with <<_::binary-size(36)>> <- id,
         {:ok, id} <- Ecto.UUID.cast(id),
         %Connection{} = connection <-
           Repo.one(
             from c in Connection,
               where:
                 c.id == ^id and c.organisation_id == ^organisation_id and
                   c.workspace_id == ^workspace_id
           ) do
      {:ok, connection}
    else
      _ -> :error
    end
  end

  @doc """
  The options of the connections page's filters, `%{target:, host:}`, each
  `%{options: [{label, value, count}], total: n}` like `run_facets/3`, counted in runs;
  `narrow:` as there.
  """
  def destination_facets(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    narrow = Keyword.get(opts, :narrow, %{})
    limits = Keyword.get(opts, :limits, %{})

    %{
      target:
        target_facet(
          connections_in(scope, %{filters | target: nil}, now),
          filters.target,
          narrow["target"],
          facet_limit(limits["target"])
        ),
      host:
        destination_host_facet(scope, filters, now, narrow["host"], facet_limit(limits["host"]))
    }
  end

  defp destination_host_facet(scope, filters, now, narrow, limit) do
    base = connections_in(scope, %{filters | host: nil}, now)
    like = like(narrow)
    grouped = from c in base, group_by: c.host
    grouped = if like, do: where(grouped, [c], ilike(c.host, ^like)), else: grouped

    rows =
      Repo.all(
        from c in grouped,
          order_by: [desc: count(c.run_id, :distinct), asc: c.host],
          limit: ^(limit + 1),
          select: {c.host, c.host, count(c.run_id, :distinct)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [c], c.host)), select: count()),
        else: length(rows)

    options = Enum.take(rows, limit)

    options =
      if is_binary(filters.host) and not Enum.any?(options, &(elem(&1, 1) == filters.host)) do
        n =
          Repo.one(
            from c in base, where: c.host == ^filters.host, select: count(c.run_id, :distinct)
          )

        [{filters.host, filters.host, n} | options]
      else
        options
      end

    %{options: options, total: total}
  end

  # The workspace's connection rows under the
  # filters, joined to their run (for the target).
  defp connections_in(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{id: workspace_id}
         },
         %Filters{} = f,
         now
       ) do
    {from, to} = Filters.bounds(f, now)

    from(c in Connection,
      join: r in Run,
      as: :run,
      on: r.id == c.run_id and r.workspace_id == c.workspace_id,
      where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
      where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id
    )
    |> where_if(f.host, dynamic([c], c.host == ^f.host))
    |> where_if(from, dynamic([c], c.last_seen_at >= ^from))
    |> where_if(to, dynamic([c], c.last_seen_at < ^to))
    |> where_run_target(f.target)
    |> where_destination_text(f.q)
    |> where_tools(f.tools)
  end

  # The free text of the connections: a destination whose host or path holds it.
  defp where_destination_text(query, nil), do: query

  defp where_destination_text(query, q) do
    case like(q) do
      nil -> query
      pattern -> where(query, [c], ilike(c.host, ^pattern) or ilike(c.path, ^pattern))
    end
  end

  # Tool invocations only: every row of a destination where any row under the same filters
  # says its last attempt was a tool invocation, so a destination is kept whole and counts
  # the same with the filter as without it, and so do the runs and the facets. A
  # destination whose rows name a tool only on refused attempts never reached the tool.
  defp where_tools(query, false), do: query

  defp where_tools(query, true) do
    tooled =
      from c in query,
        where: ^tool_invocation(),
        distinct: true,
        select: %{host: c.host, port: c.port, path: c.path}

    from c in query,
      join: t in subquery(tooled),
      on: t.host == c.host and t.port == c.port and t.path == c.path
  end

  defp where_run_target(query, nil), do: query
  defp where_run_target(query, :none), do: where(query, [_c, r], is_nil(r.target_id))

  defp where_run_target(query, {nil, path}),
    do: where(query, [_c, r], not is_nil(r.target_id) and r.target_path == ^path)

  defp where_run_target(query, {system, path}),
    do: where(query, [_c, r], r.target_system == ^system and r.target_path == ^path)

  # One row per destination. "Last" across runs is by the clock of the record: sequences
  # order the attempts of one run, and nothing but time orders two runs.
  defp destinations(scope, %Filters{} = f, now) do
    query =
      from [c, r] in connections_in(scope, f, now),
        group_by: [c.host, c.port, c.path],
        select: %{
          host: c.host,
          port: c.port,
          path: c.path,
          runs: count(c.run_id, :distinct),
          attempts: sum(c.attempts),
          allowed: sum(c.allowed),
          denied: sum(c.denied),
          first_seen_at: min(c.first_seen_at),
          last_seen_at: max(c.last_seen_at),
          method:
            fragment("(array_agg(? ORDER BY ? DESC, ? DESC))[1]", c.method, c.last_seen_at, c.id),
          last_request_method:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_request_method,
              c.last_seen_at,
              c.id
            ),
          last_decision:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_decision,
              c.last_seen_at,
              c.id
            ),
          last_rule:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_rule,
              c.last_seen_at,
              c.id
            ),
          last_path_rule:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_path_rule,
              c.last_seen_at,
              c.id
            ),
          last_credential:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_credential,
              c.last_seen_at,
              c.id
            ),
          last_outcome:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_outcome,
              c.last_seen_at,
              c.id
            ),
          last_mode:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_mode,
              c.last_seen_at,
              c.id
            ),
          last_tool:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_tool,
              c.last_seen_at,
              c.id
            ),
          last_status:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_status,
              c.last_seen_at,
              c.id
            )
        }

    case f.decision do
      "denied" -> having(query, [c], sum(c.denied) > 0)
      "allowed" -> having(query, [c], sum(c.allowed) > 0)
      _all -> query
    end
  end

  @doc "The last heartbeat each access key of the workspace delivered, by the key's row id; keys that never did are absent."
  def last_heartbeats_by_key(%Scope{
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{id: workspace_id}
      }) do
    Repo.all(
      from k in AccessKey,
        where: k.organisation_id == ^organisation_id and k.workspace_id == ^workspace_id,
        where: not is_nil(k.last_heartbeat_at),
        select: {k.id, k.last_heartbeat_at}
    )
    |> Map.new()
  end

  @doc """
  Whether the workspace has closed the run with this subject. For the receiver, which
  answers `410` to a closed run; a subject the workspace has never seen is not closed.
  """
  def closed?(workspace_id, run_id) do
    with {:ok, workspace_id} <- Ecto.UUID.cast(workspace_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      Repo.exists?(
        from r in Run,
          where: r.workspace_id == ^workspace_id and r.run_id == ^run_id and r.state == "closed"
      )
    else
      :error -> false
    end
  end

  ## The workspace overview

  # The runs are placed by when they started, or, for a run that has only pinged, by when
  # the workspace first heard of it: the expression of
  # `runs_workspace_id_started_or_first_heard_index`.
  defp by_start, do: dynamic([r], coalesce(r.started_at, r.inserted_at))

  @typedoc """
  One UTC day of the workspace's runs, counted in the three families (`alive`,
  `ended_well`, `ended_badly`; `runs` is their sum), with the denials of those runs and
  the cost they reported: `cost` is the sum of `cost_usd` over the day's runs, nil when
  none reported one, and `costed` how many did.
  """
  @type day_facts :: %{
          day: Date.t(),
          runs: non_neg_integer,
          alive: non_neg_integer,
          ended_well: non_neg_integer,
          ended_badly: non_neg_integer,
          denied: non_neg_integer,
          cost: Decimal.t() | nil,
          costed: non_neg_integer
        }

  @doc """
  The workspace's runs from `from` on, one row per UTC day they started (a pending run by
  when its ping arrived), oldest first; a day with no run has no row. One grouped query
  over the index the runs list reads by; the caller fills the days in. `to`, when given,
  bounds the read above (exclusive), so one call can read today alone.
  """
  @spec day_facts(Scope.t(), DateTime.t(), DateTime.t() | nil) :: [day_facts]
  def day_facts(%Scope{} = scope, %DateTime{} = from, to \\ nil) do
    query =
      in_scope(scope)
      |> where(^dynamic([r], ^by_start() >= ^from))
      |> where_if(to, dynamic([r], ^by_start() < ^to))

    Repo.all(
      from r in query,
        group_by:
          fragment("(COALESCE(?, ?) AT TIME ZONE 'UTC')::date", r.started_at, r.inserted_at),
        order_by:
          fragment("(COALESCE(?, ?) AT TIME ZONE 'UTC')::date", r.started_at, r.inserted_at),
        select: %{
          day:
            type(
              fragment("(COALESCE(?, ?) AT TIME ZONE 'UTC')::date", r.started_at, r.inserted_at),
              :date
            ),
          runs: count(r.id),
          alive: filter(count(r.id), r.state in ^Run.alive_states()),
          ended_well: filter(count(r.id), r.state == "succeeded"),
          ended_badly: filter(count(r.id), r.state in ^Run.ended_badly_states()),
          denied: type(coalesce(sum(r.denied_count), 0), :integer),
          cost: sum(r.cost_usd),
          costed: count(r.cost_usd)
        }
    )
  end

  @doc """
  What the organisation's overview says of each of `workspaces`, the workspaces of the
  scope's organisation the reader reaches: `%{workspace_id => %{alive:, runs:, denied:,
  last_at:, days:}}`, where `runs` and `denied` count the last seven UTC days (today
  included), `days` the runs of each of the last fourteen, oldest first, and `last_at` is
  when the workspace's last run started (nil when it has none). A workspace of another
  organisation is left out. Three reads, whatever the number of workspaces.
  """
  @spec workspace_facts(Scope.t(), [%Workspace{}], DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => map
        }
  def workspace_facts(scope, workspaces, now \\ DateTime.utc_now())

  def workspace_facts(%Scope{}, [], _now), do: %{}

  def workspace_facts(%Scope{organisation: %Organisation{id: organisation_id}}, workspaces, now) do
    ids = for %Workspace{id: id, organisation_id: ^organisation_id} <- workspaces, do: id
    today = DateTime.to_date(now)
    first = Date.add(today, -13)
    from = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")

    per_day =
      Repo.all(
        from r in Run,
          where: r.organisation_id == ^organisation_id and r.workspace_id in ^ids,
          where: coalesce(r.started_at, r.inserted_at) >= ^from,
          group_by: [
            r.workspace_id,
            fragment("(COALESCE(?, ?) AT TIME ZONE 'UTC')::date", r.started_at, r.inserted_at)
          ],
          select:
            {r.workspace_id,
             type(
               fragment("(COALESCE(?, ?) AT TIME ZONE 'UTC')::date", r.started_at, r.inserted_at),
               :date
             ), count(r.id), type(coalesce(sum(r.denied_count), 0), :integer)}
      )

    alive =
      Repo.all(
        from r in Run,
          where: r.organisation_id == ^organisation_id and r.workspace_id in ^ids,
          where: r.state in ^Run.alive_states(),
          group_by: r.workspace_id,
          select: {r.workspace_id, count(r.id)}
      )
      |> Map.new()

    # The last run of each, read off the index the runs list reads by, one row each.
    last =
      from r in Run,
        where: r.workspace_id == parent_as(:workspace).id,
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: 1,
        select: %{at: coalesce(r.started_at, r.inserted_at)}

    last_at =
      Repo.all(
        from w in Workspace,
          as: :workspace,
          where: w.id in ^ids,
          left_lateral_join: l in subquery(last),
          on: true,
          select: {w.id, l.at}
      )
      |> Map.new()

    week = Date.add(today, -6)
    by_workspace = Enum.group_by(per_day, &elem(&1, 0))

    Map.new(ids, fn id ->
      rows = Map.get(by_workspace, id, [])
      counts = Map.new(rows, fn {_id, date, runs, denied} -> {date, {runs, denied}} end)

      recent =
        for {_id, date, runs, denied} <- rows, Date.compare(date, week) != :lt, do: {runs, denied}

      {id,
       %{
         alive: Map.get(alive, id, 0),
         runs: recent |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
         denied: recent |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
         last_at: Map.get(last_at, id),
         days: for(d <- Date.range(first, today), do: counts |> Map.get(d, {0, 0}) |> elem(0))
       }}
    end)
  end

  @doc "The alive runs of the workspace, the most recently started first; at most `limit` (default 6)."
  @spec list_alive(Scope.t(), pos_integer) :: [Run.t()]
  def list_alive(%Scope{} = scope, limit \\ 6) do
    Repo.all(
      from r in in_scope(scope),
        where: r.state in ^Run.alive_states(),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc "The workspace's most recently started runs, alive or ended; at most `limit` (default 5)."
  @spec recent_runs(Scope.t(), pos_integer) :: [Run.t()]
  def recent_runs(%Scope{} = scope, limit \\ 5) do
    Repo.all(
      from r in in_scope(scope),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc """
  The runs the workspace found lost since `since`, the most recently lost first, at most
  `limit` (default 6): the ones a member may still want to close. Older losses are facts
  on the runs list, not tasks.
  """
  @spec lost_since(Scope.t(), DateTime.t(), pos_integer) :: [Run.t()]
  def lost_since(%Scope{} = scope, %DateTime{} = since, limit \\ 6) do
    Repo.all(
      from r in in_scope(scope),
        where: r.state == "lost" and r.lost_at >= ^since,
        order_by: [desc: r.lost_at, desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc """
  The last run each of these access keys started, by the key's row id, in one read of the
  index `runs (workspace_id, access_key_id, started)` (`DISTINCT ON`); a key with no run
  is absent. At most #{@max_limit} keys are read.
  """
  @spec last_runs_by_key(Scope.t(), [Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => Run.t()}
  def last_runs_by_key(%Scope{}, []), do: %{}

  def last_runs_by_key(%Scope{} = scope, key_ids) when is_list(key_ids) do
    ids = Enum.take(key_ids, @max_limit)

    Repo.all(
      from r in in_scope(scope),
        where: r.access_key_id in ^ids,
        distinct: r.access_key_id,
        order_by: [asc: r.access_key_id, desc: coalesce(r.started_at, r.inserted_at), desc: r.id]
    )
    |> Map.new(&{&1.access_key_id, &1})
  end

  @doc """
  The hosts each of these access keys' runs came from since `since`, by the key's row id:
  `%{key_id => %{count: n, host: name}}`, `host` being the one host when there is only one
  and nil otherwise; a key with no run in the window is absent. A key is not a machine (a
  pool of ephemeral instances shares one), so a page counts the hosts. One grouped read of
  the index `runs (workspace_id, access_key_id, started)`; at most #{@max_limit} keys.
  """
  @spec hosts_by_key(Scope.t(), [Ecto.UUID.t()], DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => %{count: pos_integer, host: String.t() | nil}
        }
  def hosts_by_key(%Scope{}, [], _since), do: %{}

  def hosts_by_key(%Scope{} = scope, key_ids, %DateTime{} = since) when is_list(key_ids) do
    ids = Enum.take(key_ids, @max_limit)

    Repo.all(
      from r in in_scope(scope),
        where: r.access_key_id in ^ids and not is_nil(r.host),
        where: coalesce(r.started_at, r.inserted_at) >= ^since,
        group_by: r.access_key_id,
        select: {r.access_key_id, count(r.host, :distinct), min(r.host), max(r.host)}
    )
    |> Map.new(fn {key_id, count, first, last} ->
      {key_id, %{count: count, host: if(first == last, do: first)}}
    end)
  end

  defp bound(limit), do: limit |> max(1) |> min(@max_limit)

  ## Search or jump to

  @doc """
  search_targets/3 is the workspace's targets whose system and path, as `system/path`,
  hold `text` anywhere, case-insensitively and as text (`like/1`): at most `limit`, by
  path. What the palette finds (`ApiaryWeb.JumpController`).
  """
  @spec search_targets(Scope.t(), String.t(), pos_integer) :: [Target.t()]
  def search_targets(
        %Scope{organisation: %Organisation{id: organisation_id}, workspace: %Workspace{id: id}},
        text,
        limit \\ 8
      ) do
    case like(text) do
      nil ->
        []

      pattern ->
        Repo.all(
          from t in Target,
            where: t.organisation_id == ^organisation_id and t.workspace_id == ^id,
            where: ilike(fragment("? || '/' || ?", t.system, t.path), ^pattern),
            order_by: [asc: t.path, asc: t.system],
            limit: ^bound(limit)
        )
    end
  end

  @doc """
  search_runs/3 is the workspace's runs that `text` names: by the start of their id, as
  the runner prints it (four hexadecimal characters at least, a whole id or the address
  of a run's page too), or by their task, which holds it anywhere; newest first, at most
  `limit`. What the palette finds (`ApiaryWeb.JumpController`).
  """
  @spec search_runs(Scope.t(), String.t(), pos_integer) :: [Run.t()]
  def search_runs(%Scope{} = scope, text, limit \\ 8) when is_binary(text) do
    prefix = run_id_prefix(text)
    pattern = like(text)

    condition =
      case {prefix, pattern} do
        {nil, nil} ->
          nil

        {nil, pattern} ->
          dynamic([r], ilike(r.task, ^pattern))

        {prefix, nil} ->
          dynamic([r], fragment("?::text LIKE ?", r.run_id, ^prefix))

        {prefix, pattern} ->
          dynamic([r], fragment("?::text LIKE ?", r.run_id, ^prefix) or ilike(r.task, ^pattern))
      end

    if condition do
      Repo.all(
        from r in in_scope(scope),
          where: ^condition,
          order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
          limit: ^bound(limit)
      )
    else
      []
    end
  end

  # The start of a run's id in what was typed, as the operand of LIKE: a run page's
  # address gives its id; otherwise four to thirty-six hexadecimal characters and hyphens.
  defp run_id_prefix(text) do
    text = String.trim(text)

    case Regex.run(~r"/runs/([0-9a-fA-F-]{36})(?:[/?#]|$)", text) do
      [_, run_id] ->
        String.downcase(run_id)

      nil ->
        if Regex.match?(~r/\A[0-9a-fA-F-]{4,36}\z/, text),
          do: String.downcase(text) <> "%"
    end
  end

  ## Closing

  @closable_states ~w(pending running lost)

  @doc "The states a member may close a run from: the ones without an end."
  def closable_states, do: @closable_states

  @doc """
  Closes the run: the workspace takes no more events for it and the receiver answers
  `410` (`run.close`, which every member may). Only a run that has
  not ended is closed: one that is `pending`, `running` or `lost`. A run that succeeded,
  failed or timed out keeps the end its events gave it. A close is final: no event reopens
  the run, and closing a closed run changes nothing.

  `{:error, :forbidden}` when the caller's membership is gone, `{:error, :not_found}`
  when the run is not one of the scope's workspace, `{:error, :not_closable}` when it has
  ended.
  """
  def close_run(%Scope{user: user, workspace: workspace} = scope, %Run{id: id}) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"run.close", workspace) do
        now = DateTime.utc_now()

        # The state it had, for the audit entry, read under the row's lock; the update
        # keeps the state in its WHERE all the same, so an exit that lands between a read
        # and this write is not overwritten.
        closable = from r in in_scope(scope), where: r.id == ^id and r.state in ^@closable_states
        before = Repo.one(from r in closable, select: r.state, lock: "FOR UPDATE")

        case Repo.update_all(from(r in closable, select: r),
               set: [state: "closed", closed_at: now, closed_by_id: user.id, updated_at: now]
             ) do
          {1, [run]} ->
            with {:ok, _entry} <-
                   Audit.record(Repo, scope, :"run.close", run, %{
                     before: %{state: before},
                     after: %{state: run.state}
                   }),
                 do: {:ok, {:closed, run}}

          {0, _} ->
            case Repo.one(from r in in_scope(scope), where: r.id == ^id) do
              %Run{state: "closed"} = run -> {:ok, run}
              %Run{} -> {:error, :not_closable}
              nil -> {:error, :not_found}
            end
        end
      end
    end)
    |> case do
      {:ok, {:closed, run}} ->
        broadcast_changed(run)
        {:ok, run}

      result ->
        result
    end
  end

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from r in Run,
      as: :run,
      where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id
  end
end
