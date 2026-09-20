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
  alias Apiary.Runs.{Connection, Filters, Run}

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
    Repo.aggregate(from(r in in_scope(scope), where: r.state in ^Run.alive_states()), :count)
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

    runs =
      Repo.all(
        from r in query,
          order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
          limit: @page_size,
          offset: ^((page - 1) * @page_size)
      )

    %{runs: runs, page: page, total: total, pages: max(ceil(total / @page_size), 1)}
  end

  @doc """
  What the summary line says of everything the filters return: `runs`, `repositories`,
  `tasks`, `alive` and `with_denials`. `hive_runs` is every run of the hive, filtered or
  not, for the empty state that says how many the filters hide.
  """
  def summarise_runs(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    summary =
      Repo.one(
        from r in filtered(scope, filters, now),
          select: %{
            runs: count(r.id),
            repositories: count(r.repository_id, :distinct),
            tasks: count(r.task, :distinct),
            alive: filter(count(r.id), r.state in ^Run.alive_states()),
            with_denials: filter(count(r.id), r.denied_count > 0)
          }
      )

    Map.put(summary, :hive_runs, Repo.aggregate(in_scope(scope), :count))
  end

  @doc """
  The facts of the groups the given runs fall in, over everything the filters return and
  not only the page: `%{key => %{runs:, alive:, denials:, repositories:}}`. A key is
  `{forge, path}` or `:none` grouped by repository, the task or `:none` grouped by task.
  """
  def group_facts(scope, filters, now \\ DateTime.utc_now())

  def group_facts(%Scope{} = scope, %Filters{group: "repository"} = filters, now) do
    Repo.all(
      from r in filtered(scope, filters, now),
        group_by: [r.repository_id, r.forge, r.repository],
        select:
          {r.repository_id, r.forge, r.repository,
           %{
             runs: count(r.id),
             alive: filter(count(r.id), r.state in ^Run.alive_states()),
             denials: coalesce(sum(r.denied_count), 0)
           }}
    )
    |> Enum.reduce(%{}, fn {repository_id, forge, path, facts}, acc ->
      key = if repository_id, do: {forge, path}, else: :none
      Map.update(acc, key, facts, &Map.merge(&1, facts, fn _k, a, b -> a + b end))
    end)
  end

  def group_facts(%Scope{} = scope, %Filters{group: "task"} = filters, now) do
    Repo.all(
      from r in filtered(scope, filters, now),
        group_by: r.task,
        select:
          {r.task,
           %{
             runs: count(r.id),
             alive: filter(count(r.id), r.state in ^Run.alive_states()),
             denials: coalesce(sum(r.denied_count), 0),
             repositories: count(r.repository_id, :distinct)
           }}
    )
    |> Map.new(fn {task, facts} -> {task || :none, facts} end)
  end

  def group_facts(%Scope{}, %Filters{}, _now), do: %{}

  @doc """
  The page's runs in their groups, the groups by their most recent run with the group that
  has no repository (or no task) last: `[%{key:, kind:, forge:, path:, title:, runs:}]`.
  `kind` is `:repository`, `:unassigned`, `:task`, `:no_task` or `:none` (not grouped).
  """
  def group_runs(runs, "none"),
    do: [%{key: :all, kind: :none, forge: nil, path: nil, title: nil, runs: runs}]

  def group_runs(runs, group) when group in ["repository", "task"] do
    runs
    |> Enum.group_by(&group_key(&1, group))
    |> Enum.map(fn {key, runs} -> group(key, group, runs) end)
    |> Enum.sort_by(fn g -> {g.key == :none, -recency(hd(g.runs))} end)
  end

  @doc "The key of the group a run falls in."
  def group_key(%Run{repository_id: nil}, "repository"), do: :none
  def group_key(%Run{forge: forge, repository: path}, "repository"), do: {forge, path}
  def group_key(%Run{task: nil}, "task"), do: :none
  def group_key(%Run{task: task}, "task"), do: task
  def group_key(%Run{}, _group), do: :all

  defp group(:none, "repository", runs),
    do: %{key: :none, kind: :unassigned, forge: nil, path: nil, title: "Unassigned", runs: runs}

  defp group({forge, path} = key, "repository", runs),
    do: %{key: key, kind: :repository, forge: forge, path: path, title: path, runs: runs}

  defp group(:none, "task", runs),
    do: %{key: :none, kind: :no_task, forge: nil, path: nil, title: "No task", runs: runs}

  defp group(task, "task", runs),
    do: %{key: task, kind: :task, forge: nil, path: nil, title: task, runs: runs}

  defp recency(%Run{} = run),
    do: DateTime.to_unix(run.started_at || run.inserted_at, :microsecond)

  @doc """
  The options of each filter of the runs list, counted from the data: every facet is counted
  under the other filters and the range, not under itself, so a chip shows what choosing
  another value would give. `%{state:, repo:, task:, runtime:, host:}`, each a list of
  `{label, value, count}`, the most frequent first.
  """
  def run_facets(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    %{
      state: state_facet(scope, filters, now),
      repo: repo_facet(scope, filters, now),
      task: text_facet(scope, %{filters | task: nil}, now, :task, "No task"),
      runtime: text_facet(scope, %{filters | runtime: nil}, now, :runtime, nil),
      host: text_facet(scope, %{filters | host: nil}, now, :host, nil)
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

    for state <- Run.states(), count = counts[state], do: {state, state, count}
  end

  defp repo_facet(scope, filters, now) do
    Repo.all(
      from r in filtered(scope, %{filters | repo: nil}, now),
        group_by: [r.repository_id, r.forge, r.repository],
        select: {r.repository_id, r.forge, r.repository, count(r.id)}
    )
    |> Enum.reduce(%{}, fn {repository_id, forge, path, count}, acc ->
      key = if repository_id, do: {forge, path}, else: :none
      Map.update(acc, key, count, &(&1 + count))
    end)
    |> Enum.map(fn
      {:none, count} -> {"Unassigned", "none", count}
      {{forge, path}, count} -> {"#{forge}/#{path}", Filters.repo_param({forge, path}), count}
    end)
    |> Enum.sort_by(fn {label, value, count} -> {value == "none", -count, label} end)
  end

  defp text_facet(scope, filters, now, field, none_label) do
    Repo.all(
      from r in filtered(scope, filters, now),
        group_by: field(r, ^field),
        select: {field(r, ^field), count(r.id)}
    )
    |> Enum.flat_map(fn
      {nil, count} -> if none_label, do: [{none_label, "none", count}], else: []
      # A label that reads "none" cannot be told from the absence of one in the URL.
      {"none", _count} -> []
      {value, count} -> [{value, value, count}]
    end)
    |> Enum.sort_by(fn {label, value, count} -> {value == "none", -count, label} end)
  end

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
    |> where_repo(f.repo)
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

  defp where_repo(query, nil), do: query
  defp where_repo(query, :none), do: where(query, [r], is_nil(r.repository_id))

  defp where_repo(query, {forge, path}),
    do: where(query, [r], r.forge == ^forge and r.repository == ^path)

  defp where_text(query, _field, nil), do: query
  defp where_text(query, field, :none), do: where(query, [r], is_nil(field(r, ^field)))
  defp where_text(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  ## The hive's connections

  @doc """
  A page of the hive's destinations across the runs in range: one row per host, port and
  path, with how many runs reached it, the attempts, and the decision, rule, outcome and
  the rest of the most recent attempt across those runs. Filters: `decision` (destinations
  with any attempt so decided), `repo`, `host` (the destination's) and the range, which is
  over when a run last reached the destination. Denied destinations come first, then the
  most recent.
  """
  def page_destinations(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = destinations(scope, filters, now)

    summary =
      Repo.one(
        from d in subquery(query),
          select: %{
            destinations: count(),
            denied: filter(count(), d.denied > 0),
            attempts: type(coalesce(sum(d.attempts), 0), :integer)
          }
      )

    runs =
      Repo.one(from c in connections_in(scope, filters, now), select: count(c.run_id, :distinct))

    pages = max(ceil(summary.destinations / @page_size), 1)
    page = min(filters.page, pages)

    rows =
      Repo.all(
        from d in subquery(query),
          order_by: [
            desc: d.last_decision == "denied",
            desc: d.last_seen_at,
            asc: d.host,
            asc: d.port,
            asc: d.path
          ],
          limit: @page_size,
          offset: ^((page - 1) * @page_size)
      )

    %{rows: rows, page: page, pages: pages, summary: Map.put(summary, :runs, runs)}
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

  @doc "The options of the connections page's filters: `%{repo:, host:}` of `{label, value, count}`."
  def destination_facets(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    repos =
      Repo.all(
        from [c, r] in connections_in(scope, %{filters | repo: nil}, now),
          group_by: [r.repository_id, r.forge, r.repository],
          select: {r.repository_id, r.forge, r.repository, count(c.run_id, :distinct)}
      )
      |> Enum.reduce(%{}, fn {repository_id, forge, path, count}, acc ->
        key = if repository_id, do: {forge, path}, else: :none
        Map.update(acc, key, count, &(&1 + count))
      end)
      |> Enum.map(fn
        {:none, count} -> {"Unassigned", "none", count}
        {{forge, path}, count} -> {"#{forge}/#{path}", Filters.repo_param({forge, path}), count}
      end)
      |> Enum.sort_by(fn {label, value, count} -> {value == "none", -count, label} end)

    hosts =
      Repo.all(
        from [c, r] in connections_in(scope, %{filters | host: nil}, now),
          group_by: c.host,
          order_by: [desc: count(c.run_id, :distinct), asc: c.host],
          limit: 200,
          select: {c.host, c.host, count(c.run_id, :distinct)}
      )

    %{repo: repos, host: hosts}
  end

  # The hive's connection rows under the filters, joined to their run (for the repository).
  defp connections_in(
         %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
         %Filters{} = f,
         now
       ) do
    {from, to} = Filters.bounds(f, now)

    from(c in Connection,
      join: r in Run,
      on: r.id == c.run_id and r.hive_id == c.hive_id,
      where: c.organisation_id == ^organisation_id and c.hive_id == ^hive_id,
      where: r.organisation_id == ^organisation_id and r.hive_id == ^hive_id
    )
    |> where_if(f.host, dynamic([c], c.host == ^f.host))
    |> where_if(from, dynamic([c], c.last_seen_at >= ^from))
    |> where_if(to, dynamic([c], c.last_seen_at < ^to))
    |> where_run_repo(f.repo)
  end

  defp where_run_repo(query, nil), do: query
  defp where_run_repo(query, :none), do: where(query, [_c, r], is_nil(r.repository_id))

  defp where_run_repo(query, {forge, path}),
    do: where(query, [_c, r], r.forge == ^forge and r.repository == ^path)

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

  ## Closing

  @doc """
  Closes the run: the hive takes no more events for it and the receiver answers `410`.
  Any member of the hive, read again from the database. A close is final: no event
  reopens the run, and closing a closed run changes nothing.

  `{:error, :unauthorized}` when the caller's membership is gone, `{:error, :not_found}`
  when the run is not one of the scope's hive.
  """
  def close_run(%Scope{user: user} = scope, %Run{id: id}) do
    with {:ok, _membership} <- Organisations.fetch_membership(scope) do
      now = DateTime.utc_now()

      query =
        from r in in_scope(scope),
          where: r.id == ^id and r.state != "closed",
          select: r

      case Repo.update_all(query,
             set: [state: "closed", closed_at: now, closed_by_id: user.id, updated_at: now]
           ) do
        {1, [run]} ->
          broadcast_changed(run)
          {:ok, run}

        {0, _} ->
          case Repo.one(from r in in_scope(scope), where: r.id == ^id) do
            %Run{} = run -> {:ok, run}
            nil -> {:error, :not_found}
          end
      end
    end
  end

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         hive: %Hive{id: hive_id}
       }) do
    from r in Run, where: r.organisation_id == ^organisation_id and r.hive_id == ^hive_id
  end
end
