defmodule Apiary.Runs do
  @moduledoc """
  The runs of a hive, as the console reads them.

  Events come in through `Apiary.Runs.Ingest`, are folded by `Apiary.Runs.Projector` and
  watched by `Apiary.Runs.Liveness`; this module is what pages call. Every function takes
  the caller's scope first and reads only the scope's hive; `closed?/2` is the one
  exception, for the receiver, which has an access key's hive and no user.

  Changes are announced on two topics of `Apiary.PubSub`:

    * `topic(hive_id)`, `"runs:<hive_id>"`: `{:run_changed, %Run{}}` whenever a run of the
      hive was projected, found lost or closed;
    * `topic(hive_id, run_id)`, `"run:<hive_id>:<run_id>"` (`run_id` is the row's id):
      `{:run_projected, %Run{}, first_sequence, last_sequence}` after a projection, with
      the lowest and highest sequence it folded, and `{:run_changed, %Run{}}` as above.
  """

  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations
  alias Apiary.Organisations.{Hive, Organisation}
  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Filters, Target, Run}

  @default_limit 50
  @max_limit 200
  @page_size 50
  @hits_page 10

  ## Topics

  def topic(hive_id), do: "runs:#{hive_id}"
  def topic(hive_id, run_id), do: "run:#{hive_id}:#{run_id}"

  @doc """
  The topic of the sidebar's alive count: `{:runs_touched, hive_id}` whenever a run of the
  hive changed, and nothing else, so every page of the hive can follow it without taking
  the messages of `topic/1`.
  """
  def touched_topic(hive_id), do: "runs:#{hive_id}:touched"

  @doc "Subscribes the caller to `touched_topic/1` of the scope's hive."
  def subscribe_touched(%Scope{hive: %Hive{id: hive_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, touched_topic(hive_id))
  end

  @doc "Subscribes the caller to the scope's hive."
  def subscribe(%Scope{hive: %Hive{id: hive_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(hive_id))
  end

  @doc "Subscribes the caller to one run of the scope's hive."
  def subscribe(%Scope{hive: %Hive{id: hive_id}}, %Run{id: id, hive_id: hive_id}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(hive_id, id))
  end

  @doc false
  def broadcast_changed(%Run{} = run) do
    broadcast_touched(run)
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.hive_id), {:run_changed, run})
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.hive_id, run.id), {:run_changed, run})
  end

  @doc false
  def broadcast_projected(%Run{} = run, first_sequence, last_sequence) do
    broadcast_touched(run)
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.hive_id), {:run_changed, run})

    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(run.hive_id, run.id),
      {:run_projected, run, first_sequence, last_sequence}
    )
  end

  defp broadcast_touched(%Run{hive_id: hive_id}) do
    Phoenix.PubSub.broadcast(Apiary.PubSub, touched_topic(hive_id), {:runs_touched, hive_id})
  end

  ## Reads

  @doc "How many runs of the hive are alive now: pending or running."
  def count_alive(%Scope{} = scope) do
    # Tagged, so that what measures a page's own reads can tell the sidebar's timed count
    # from them (`metadata.options[:sidebar]` of the repo's telemetry event).
    Repo.aggregate(from(r in in_scope(scope), where: r.state in ^Run.alive_states()), :count,
      telemetry_options: [sidebar: true]
    )
  end

  @doc "One run of the scope's hive by its row id; raises when the hive has none such."
  def get_run!(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one!(from r in in_scope(scope), where: r.id == ^id)
      :error -> raise Ecto.NoResultsError, queryable: Run
    end
  end

  @doc """
  One run of the scope's hive by its subject, the id the runner prints and the run's URL
  carries; raises `Ecto.NoResultsError` when the hive has none such, which a run of another
  hive and a malformed id both are.
  """
  def get_run_by_run_id!(%Scope{} = scope, run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, run_id} -> Repo.one!(from r in in_scope(scope), where: r.run_id == ^run_id)
      :error -> raise Ecto.NoResultsError, queryable: Run
    end
  end

  @doc "The hive's runs, newest first. `limit:` defaults to #{@default_limit}, at most #{@max_limit}."
  def list_runs(%Scope{} = scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)

    Repo.all(
      from r in in_scope(scope), order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit
    )
  end

  ## The runs list

  @doc "How many runs a page of the list holds."
  def page_size, do: @page_size

  @doc """
  A page of the hive's runs under the filters, newest first by when they started (a run
  that has only pinged is placed by when its ping arrived). Returns the page's runs, the
  page it is (the last one, when the filters asked for one beyond it) and the total.
  """
  def page_runs(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = filtered(scope, filters, now)
    total = Repo.aggregate(query, :count)
    page = filters.page |> min(max(ceil(total / @page_size), 1))

    runs = Repo.all(page_query(query, page))

    %{runs: runs, page: page, total: total, pages: max(ceil(total / @page_size), 1)}
  end

  # In the order of the index `runs_hive_id_started_or_first_heard_index`, expression
  # included, so a page is read from the index and never sorted.
  defp page_query(query, page) do
    from r in query,
      order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
      limit: @page_size,
      offset: ^((page - 1) * @page_size)
  end

  @doc false
  def page_runs_query(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()),
    do: scope |> filtered(filters, now) |> page_query(filters.page)

  @doc """
  What the summary line says of everything the filters return: `runs`, `targets`,
  `tasks`, the three families `alive`, `ended_well` and `ended_badly`
  (`Apiary.Runs.Filters.families/0`), and `with_denials`, all counted in one query.
  `hive_runs` is every run of the hive, filtered or not, for the empty state that says how
  many the filters hide.
  """
  def summarise_runs(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    ended_well = Filters.family_states("ended_well")
    ended_badly = Filters.family_states("ended_badly")

    summary =
      Repo.one(
        from r in filtered(scope, filters, now),
          select: %{
            runs: count(r.id),
            targets: count(r.target_id, :distinct),
            tasks: count(r.task, :distinct),
            alive: filter(count(r.id), r.state in ^Run.alive_states()),
            ended_well: filter(count(r.id), r.state in ^ended_well),
            ended_badly: filter(count(r.id), r.state in ^ended_badly),
            with_denials: filter(count(r.id), r.denied_count > 0)
          }
      )

    Map.put(summary, :hive_runs, Repo.aggregate(in_scope(scope), :count))
  end

  @doc """
  The facts of the groups with these keys (the groups on the page, so at most a page of
  them), over everything the filters return and not only the page:
  `%{key => %{runs:, alive:, denials:, targets:}}`. A key is `{system, path}` or `:none`
  grouped by target, the task or `:none` grouped by task.
  """
  def group_facts(scope, filters, keys, now \\ DateTime.utc_now())

  def group_facts(%Scope{}, %Filters{}, [], _now), do: %{}

  def group_facts(%Scope{} = scope, %Filters{group: "repository"} = filters, keys, now) do
    condition =
      Enum.reduce(keys, dynamic(false), fn
        :none, acc ->
          dynamic([r], ^acc or is_nil(r.target_id))

        {system, path}, acc ->
          dynamic([r], ^acc or (r.target_system == ^system and r.target_path == ^path))

        _other, acc ->
          acc
      end)

    Repo.all(
      from r in filtered(scope, filters, now),
        where: ^condition,
        group_by: [is_nil(r.target_id), r.target_system, r.target_path],
        select:
          {is_nil(r.target_id), r.target_system, r.target_path,
           %{
             runs: count(r.id),
             alive: filter(count(r.id), r.state in ^Run.alive_states()),
             denials: coalesce(sum(r.denied_count), 0)
           }}
    )
    |> Enum.reduce(%{}, fn {unassigned?, system, path, facts}, acc ->
      key = if unassigned?, do: :none, else: {system, path}
      Map.update(acc, key, facts, &Map.merge(&1, facts, fn _k, a, b -> a + b end))
    end)
  end

  def group_facts(%Scope{} = scope, %Filters{group: "task"} = filters, keys, now) do
    tasks = Enum.filter(keys, &is_binary/1)
    none? = :none in keys

    Repo.all(
      from r in filtered(scope, filters, now),
        where: r.task in ^tasks or (^none? and is_nil(r.task)),
        group_by: r.task,
        select:
          {r.task,
           %{
             runs: count(r.id),
             alive: filter(count(r.id), r.state in ^Run.alive_states()),
             denials: coalesce(sum(r.denied_count), 0),
             targets: count(r.target_id, :distinct)
           }}
    )
    |> Map.new(fn {task, facts} -> {task || :none, facts} end)
  end

  def group_facts(%Scope{}, %Filters{}, _keys, _now), do: %{}

  @doc """
  The page's runs in their groups, the groups by their most recent run with the group that
  has no target (or no task) last: `[%{key:, kind:, system:, path:, title:, runs:}]`.
  `kind` is `:target`, `:unassigned`, `:task`, `:no_task` or `:none` (not grouped).
  """
  def group_runs(runs, "none"),
    do: [%{key: :all, kind: :none, system: nil, path: nil, title: nil, runs: runs}]

  def group_runs(runs, group) when group in ["repository", "task"] do
    runs
    |> Enum.group_by(&group_key(&1, group))
    |> Enum.map(fn {key, runs} -> group(key, group, runs) end)
    |> Enum.sort_by(fn g -> {g.key == :none, -recency(hd(g.runs))} end)
  end

  @doc "The key of the group a run falls in."
  def group_key(%Run{target_id: nil}, "repository"), do: :none
  def group_key(%Run{target_system: system, target_path: path}, "repository"), do: {system, path}
  def group_key(%Run{task: nil}, "task"), do: :none
  def group_key(%Run{task: task}, "task"), do: task
  def group_key(%Run{}, _group), do: :all

  defp group(:none, "repository", runs),
    do: %{key: :none, kind: :unassigned, system: nil, path: nil, title: "Unassigned", runs: runs}

  defp group({system, path} = key, "repository", runs),
    do: %{key: key, kind: :target, system: system, path: path, title: path, runs: runs}

  defp group(:none, "task", runs),
    do: %{key: :none, kind: :no_task, system: nil, path: nil, title: "No task", runs: runs}

  defp group(task, "task", runs),
    do: %{key: task, kind: :task, system: nil, path: nil, title: task, runs: runs}

  defp recency(%Run{} = run),
    do: DateTime.to_unix(run.started_at || run.inserted_at, :microsecond)

  @facet_size 50

  @doc "How many options a filter's menu holds at most."
  def facet_size, do: @facet_size

  @doc """
  The options of each filter of the runs list, counted from the data: every facet is counted
  under the other filters and the range, not under itself, so a chip shows what choosing
  another value would give. `%{state:, target:, task:, runtime:, host:}`, each
  `%{options: [{label, value, count}], total: n}`: the #{@facet_size} most frequent values
  and the chosen one, with how many values there are. `narrow:` maps a facet's name to
  what the reader typed in its menu, matched anywhere in the value, case-insensitively, as
  text and never as a pattern.
  """
  def run_facets(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    narrow = Keyword.get(opts, :narrow, %{})

    %{
      state: state_facet(scope, filters, now),
      target: run_target_facet(scope, filters, now, narrow["repo"]),
      task: text_facet(scope, filters, now, :task, "No task", narrow["task"]),
      runtime: text_facet(scope, filters, now, :runtime, nil, narrow["runtime"]),
      host: text_facet(scope, filters, now, :host, nil, narrow["host"])
    }
  end

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

  defp run_target_facet(scope, filters, now, narrow),
    do: target_facet(filtered(scope, %{filters | target: nil}, now), filters.target, narrow)

  # `base` is a query with the run bound as `:run`; what is counted per target is its
  # distinct runs: the runs of the list, the runs that reached out on the connections page.
  defp target_facet(base, chosen, narrow) do
    like = like(narrow)

    grouped =
      from [run: r] in base,
        where: not is_nil(r.target_id),
        group_by: [r.target_system, r.target_path]

    grouped =
      if like,
        do:
          where(
            grouped,
            [run: r],
            ilike(fragment("? || '/' || ?", r.target_system, r.target_path), ^like)
          ),
        else: grouped

    rows =
      Repo.all(
        from [run: r] in grouped,
          order_by: [desc: count(r.id, :distinct), asc: r.target_system, asc: r.target_path],
          limit: ^(@facet_size + 1),
          select: {r.target_system, r.target_path, count(r.id, :distinct)}
      )

    total =
      if length(rows) > @facet_size,
        do:
          Repo.one(
            from g in subquery(select(grouped, [run: r], r.target_system)), select: count()
          ),
        else: length(rows)

    unassigned =
      Repo.one(from [run: r] in base, where: is_nil(r.target_id), select: count(r.id, :distinct))

    options =
      for {system, path, n} <- Enum.take(rows, @facet_size),
          do: {"#{system}/#{path}", Filters.target_value({system, path}), n}

    options =
      with {system, path} <- chosen,
           value = Filters.target_value(chosen),
           false <- Enum.any?(options, &(elem(&1, 1) == value)) do
        n =
          Repo.one(
            from [run: r] in base,
              where: r.target_system == ^system and r.target_path == ^path,
              select: count(r.id, :distinct)
          )

        [{"#{system}/#{path}", value, n} | options]
      else
        _ -> options
      end

    options =
      if unassigned > 0 and is_nil(like),
        do: options ++ [{"Unassigned", "none", unassigned}],
        else: options

    %{options: options, total: total + if(unassigned > 0, do: 1, else: 0)}
  end

  defp text_facet(scope, filters, now, field, none_label, narrow) do
    chosen = Map.fetch!(filters, field)
    base = filtered(scope, Map.put(filters, field, nil), now)
    like = like(narrow)

    grouped = from r in base, where: not is_nil(field(r, ^field)), group_by: field(r, ^field)
    grouped = if like, do: where(grouped, [r], ilike(field(r, ^field), ^like)), else: grouped

    rows =
      Repo.all(
        from r in grouped,
          order_by: [desc: count(r.id), asc: field(r, ^field)],
          limit: ^(@facet_size + 1),
          select: {field(r, ^field), count(r.id)}
      )

    total =
      if length(rows) > @facet_size,
        do: Repo.one(from g in subquery(select(grouped, [r], field(r, ^field))), select: count()),
        else: length(rows)

    # A label that reads "none" cannot be told from the absence of one in the URL.
    options =
      for {value, n} <- Enum.take(rows, @facet_size), value != "none", do: {value, value, n}

    options =
      if is_binary(chosen) and not Enum.any?(options, &(elem(&1, 1) == chosen)) do
        n = Repo.aggregate(from(r in base, where: field(r, ^field) == ^chosen), :count)
        [{chosen, chosen, n} | options]
      else
        options
      end

    none =
      if none_label,
        do: Repo.aggregate(from(r in base, where: is_nil(field(r, ^field))), :count),
        else: 0

    options =
      if none > 0 and is_nil(like), do: options ++ [{none_label, "none", none}], else: options

    %{options: options, total: total + if(none > 0, do: 1, else: 0)}
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
    |> where_if(f.denials, dynamic([r], r.denied_count > 0))
    |> where_if(from, dynamic([r], coalesce(r.started_at, r.inserted_at) >= ^from))
    |> where_if(to, dynamic([r], coalesce(r.started_at, r.inserted_at) < ^to))
  end

  defp where_if(query, condition, dynamic) do
    if condition, do: where(query, ^dynamic), else: query
  end

  defp where_target(query, nil), do: query
  defp where_target(query, :none), do: where(query, [r], is_nil(r.target_id))

  defp where_target(query, {system, path}),
    do: where(query, [r], r.target_system == ^system and r.target_path == ^path)

  defp where_text(query, _field, nil), do: query
  defp where_text(query, field, :none), do: where(query, [r], is_nil(field(r, ^field)))
  defp where_text(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  ## The hive's connections

  @doc """
  A page of the hive's destinations across the runs in range: one row per host, port and
  path, with how many runs reached it, the attempts, and the decision, rule, outcome and
  the rest of the most recent attempt across those runs. Filters: `decision` (destinations
  with any attempt so decided), `target`, `host` (the destination's) and the range, which is
  over when a run last reached the destination and never wider than
  `Apiary.Runs.Filters.max_window_days/0` days, so the aggregate is over a bounded set. Denied destinations come first, then the
  most recent.
  """
  def page_destinations(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = destinations(scope, filters, now)

    # One pass: the page's rows carry the totals of everything grouped, as window
    # aggregates over the same grouping, so the GROUP BY is not run a second time.
    read = fn page ->
      Repo.all(
        from d in subquery(query),
          # Denied first, then by first seen, newest first, so a row the page holds does
          # not move when it is seen again (see Record.connections/3).
          order_by: [
            desc: d.last_decision == "denied",
            desc: d.first_seen_at,
            asc: d.host,
            asc: d.port,
            asc: d.path
          ],
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
  The target of the scope's hive that runs name with this system and path, or nil: one
  indexed read, however many targets the hive has.
  """
  def fetch_target(
        %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
        system,
        path
      )
      when is_binary(system) and is_binary(path) do
    Repo.one(
      from p in Target,
        where: p.organisation_id == ^organisation_id and p.hive_id == ^hive_id,
        where: p.system == ^system and p.path == ^path,
        limit: 1
    )
  end

  def fetch_target(%Scope{}, _system, _path), do: nil

  @doc """
  One connection of the scope's hive by its row id, whole. `:error` for an id that is not
  a UUID and for a connection of another hive.
  """
  def fetch_connection(
        %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
        id
      ) do
    with <<_::binary-size(36)>> <- id,
         {:ok, id} <- Ecto.UUID.cast(id),
         %Connection{} = connection <-
           Repo.one(
             from c in Connection,
               where:
                 c.id == ^id and c.organisation_id == ^organisation_id and c.hive_id == ^hive_id
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

    %{
      target:
        target_facet(
          connections_in(scope, %{filters | target: nil}, now),
          filters.target,
          narrow["repo"]
        ),
      host: destination_host_facet(scope, filters, now, narrow["host"])
    }
  end

  defp destination_host_facet(scope, filters, now, narrow) do
    base = connections_in(scope, %{filters | host: nil}, now)
    like = like(narrow)
    grouped = from c in base, group_by: c.host
    grouped = if like, do: where(grouped, [c], ilike(c.host, ^like)), else: grouped

    rows =
      Repo.all(
        from c in grouped,
          order_by: [desc: count(c.run_id, :distinct), asc: c.host],
          limit: ^(@facet_size + 1),
          select: {c.host, c.host, count(c.run_id, :distinct)}
      )

    total =
      if length(rows) > @facet_size,
        do: Repo.one(from g in subquery(select(grouped, [c], c.host)), select: count()),
        else: length(rows)

    options = Enum.take(rows, @facet_size)

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

  # The hive's connection rows under the filters, joined to their run (for the target).
  defp connections_in(
         %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
         %Filters{} = f,
         now
       ) do
    {from, to} = Filters.bounds(f, now)

    from(c in Connection,
      join: r in Run,
      as: :run,
      on: r.id == c.run_id and r.hive_id == c.hive_id,
      where: c.organisation_id == ^organisation_id and c.hive_id == ^hive_id,
      where: r.organisation_id == ^organisation_id and r.hive_id == ^hive_id
    )
    |> where_if(f.host, dynamic([c], c.host == ^f.host))
    |> where_if(from, dynamic([c], c.last_seen_at >= ^from))
    |> where_if(to, dynamic([c], c.last_seen_at < ^to))
    |> where_run_target(f.target)
  end

  defp where_run_target(query, nil), do: query
  defp where_run_target(query, :none), do: where(query, [_c, r], is_nil(r.target_id))

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
            )
        }

    case f.decision do
      "denied" -> having(query, [c], sum(c.denied) > 0)
      "allowed" -> having(query, [c], sum(c.allowed) > 0)
      _all -> query
    end
  end

  @doc "The last heartbeat each access key of the hive delivered, by the key's row id; keys that never did are absent."
  def last_heartbeats_by_key(%Scope{
        organisation: %Organisation{id: organisation_id},
        hive: %Hive{id: hive_id}
      }) do
    Repo.all(
      from k in AccessKey,
        where: k.organisation_id == ^organisation_id and k.hive_id == ^hive_id,
        where: not is_nil(k.last_heartbeat_at),
        select: {k.id, k.last_heartbeat_at}
    )
    |> Map.new()
  end

  @doc """
  Whether the hive has closed the run with this subject. For the receiver, which answers
  `410` to a closed run; a subject the hive has never seen is not closed.
  """
  def closed?(hive_id, run_id) do
    with {:ok, hive_id} <- Ecto.UUID.cast(hive_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      Repo.exists?(
        from r in Run,
          where: r.hive_id == ^hive_id and r.run_id == ^run_id and r.state == "closed"
      )
    else
      :error -> false
    end
  end

  ## The hive overview

  # The runs are placed by when they started, or, for a run that has only pinged, by when
  # the hive first heard of it: the expression of `runs_hive_id_started_or_first_heard_index`.
  defp by_start, do: dynamic([r], coalesce(r.started_at, r.inserted_at))

  @typedoc """
  One UTC day of the hive's runs, counted in the three families (`alive`, `ended_well`,
  `ended_badly`; `runs` is their sum), with the denials of those runs and the cost they
  reported: `cost` is the sum of `cost_usd` over the day's runs, nil when none reported
  one, and `costed` how many did.
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
  The hive's runs from `from` on, one row per UTC day they started (a pending run by when
  its ping arrived), oldest first; a day with no run has no row. One grouped query over
  the index the runs list reads by; the caller fills the days in. `to`, when given, bounds
  the read above (exclusive), so one call can read today alone.
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

  @doc "The alive runs of the hive, the most recently started first; at most `limit` (default 6)."
  @spec list_alive(Scope.t(), pos_integer) :: [Run.t()]
  def list_alive(%Scope{} = scope, limit \\ 6) do
    Repo.all(
      from r in in_scope(scope),
        where: r.state in ^Run.alive_states(),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc "The hive's most recently started runs, alive or ended; at most `limit` (default 5)."
  @spec recent_runs(Scope.t(), pos_integer) :: [Run.t()]
  def recent_runs(%Scope{} = scope, limit \\ 5) do
    Repo.all(
      from r in in_scope(scope),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc """
  The runs the hive found lost since `since`, the most recently lost first, at most `limit`
  (default 6): the ones a member may still want to close. Older losses are facts on the
  runs list, not tasks.
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
  index `runs (hive_id, access_key_id, started)` (`DISTINCT ON`); a key with no run is
  absent. At most #{@max_limit} keys are read.
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
  the index `runs (hive_id, access_key_id, started)`; at most #{@max_limit} keys.
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

  ## Closing

  @closable_states ~w(pending running lost)

  @doc "The states a member may close a run from: the ones without an end."
  def closable_states, do: @closable_states

  @doc """
  Closes the run: the hive takes no more events for it and the receiver answers `410`.
  Any member of the hive, read again from the database. Only a run that has not ended is
  closed: one that is `pending`, `running` or `lost`. A run that succeeded, failed or timed out
  keeps the end its events gave it. A close is final: no event reopens the run, and
  closing a closed run changes nothing.

  `{:error, :unauthorized}` when the caller's membership is gone, `{:error, :not_found}`
  when the run is not one of the scope's hive, `{:error, :not_closable}` when it has ended.
  """
  def close_run(%Scope{user: user} = scope, %Run{id: id}) do
    with {:ok, _membership} <- Organisations.fetch_membership(scope) do
      now = DateTime.utc_now()

      # One statement: the state is part of the WHERE, so an exit that lands between a
      # read and this write is not overwritten.
      query =
        from r in in_scope(scope),
          where: r.id == ^id and r.state in ^@closable_states,
          select: r

      case Repo.update_all(query,
             set: [state: "closed", closed_at: now, closed_by_id: user.id, updated_at: now]
           ) do
        {1, [run]} ->
          broadcast_changed(run)
          {:ok, run}

        {0, _} ->
          case Repo.one(from r in in_scope(scope), where: r.id == ^id) do
            %Run{state: "closed"} = run -> {:ok, run}
            %Run{} -> {:error, :not_closable}
            nil -> {:error, :not_found}
          end
      end
    end
  end

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         hive: %Hive{id: hive_id}
       }) do
    from r in Run,
      as: :run,
      where: r.organisation_id == ^organisation_id and r.hive_id == ^hive_id
  end
end
