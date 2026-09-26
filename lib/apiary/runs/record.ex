defmodule Apiary.Runs.Record do
  @moduledoc """
  The record of one run, as the run page reads it: its events in windows by sequence, the
  timeline laid out from them, its log chunks and its connections.

  Every function takes the caller's scope first and the run second, and reads only rows
  that carry the scope's organisation, the scope's workspace and the run's row id. A run
  of another workspace is never reached: `fetch_run/2` does not find it, and a `%Run{}` of
  another workspace handed in reads nothing.

  What an event carries is the runner's input, and an event may be megabytes. No function
  here selects an event's `data` whole: every field is cut by the database before it
  crosses the wire (`left(...)` on text, a bounded number of elements of an array), so
  what a read costs this server is bounded by the number of rows, never by what a runner
  put in them. `Apiary.Runs.Record.Timeline` says what is made of the rows; nothing here
  renders them.
  """

  import Ecto.Query, warn: false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Workspace, Organisation}
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, LogChunk, Run}
  alias Apiary.Runs.Record.Timeline

  @policy_applied "dev.qory.run.policy_applied"
  @session_started "dev.qory.session.started"
  @started "dev.qory.run.started"
  @resized "dev.qory.run.resized"
  @egress "dev.qory.run.egress"
  @list_types ["dev.qory.session.turn_finished", "dev.qory.session.subagent_finished"]

  @log_page 200
  @default_log_limit 2_000
  @max_log_limit 10_000
  # The most a terminal can be, as the contract has it; and how many resizes are read
  # past `after` for the first that is a size (a run's resizes that are not are rare).
  @max_cells 65_535
  @resizes_read 100
  @connections_page 50

  ## SQL that bounds what an array of an event gives. Macros, because a fragment's text is
  ## fixed at compile time.

  # The first `count` strings of the array under `key`, each cut at `length` characters.
  defmacrop strings(data, key, count, length) do
    sql = """
    (SELECT coalesce(jsonb_agg(left(v #>> '{}', #{length})), '[]'::jsonb)
       FROM (SELECT v FROM jsonb_array_elements(
               CASE WHEN jsonb_typeof(? -> '#{key}') = 'array' THEN ? -> '#{key}' ELSE '[]'::jsonb END
             ) WITH ORDINALITY a(v, n)
             WHERE jsonb_typeof(v) = 'string' ORDER BY n LIMIT #{count}) q)
    """

    quote do: fragment(unquote(sql), unquote(data), unquote(data))
  end

  defmacrop array_length(data, key) do
    sql =
      "CASE WHEN jsonb_typeof(? -> '#{key}') = 'array' THEN jsonb_array_length(? -> '#{key}') ELSE 0 END"

    quote do: fragment(unquote(sql), unquote(data), unquote(data))
  end

  # The background tasks an event lists, the first fifty of them, each as the few words
  # the page shows; NULL when the event gives no list.
  defmacrop listed_tasks(data) do
    sql = """
    CASE WHEN jsonb_typeof(? -> 'background_tasks') = 'array' THEN
      (SELECT coalesce(jsonb_agg(jsonb_build_object(
          'id', CASE WHEN jsonb_typeof(t -> 'id') IN ('string', 'number') THEN left(t ->> 'id', 64) END,
          'type', left(t ->> 'type', 40),
          'status', left(t ->> 'status', 40),
          'what', left(coalesce(t ->> 'command', t ->> 'agent_type', t ->> 'subagent_type', t ->> 'description'), 200))), '[]'::jsonb)
       FROM (SELECT t FROM jsonb_array_elements(
               CASE WHEN jsonb_typeof(? -> 'background_tasks') = 'array' THEN ? -> 'background_tasks' ELSE '[]'::jsonb END
             ) WITH ORDINALITY ts(t, n)
             WHERE jsonb_typeof(t) = 'object' ORDER BY n LIMIT 50) tq)
    END
    """

    quote do: fragment(unquote(sql), unquote(data), unquote(data), unquote(data))
  end

  # The longest `argument` of a credential use or a tool the runner's contract allows: the
  # policy in force reads it whole.
  @argument_read 4096

  # An object's `argument`, when it is a non-empty string, cut at `%ARGUMENT%` code points
  # and ending in `…` when cut; null otherwise. `c` is the object.
  @argument_sql """
  CASE WHEN jsonb_typeof(c -> 'argument') = 'string' AND c ->> 'argument' <> '' THEN
    left(c ->> 'argument', %ARGUMENT%)
      || CASE WHEN length(left(c ->> 'argument', %ARGUMENT% + 1)) > %ARGUMENT% THEN '…' ELSE '' END
  END
  """

  # The first twenty objects of the array under `key` that have a string `name`, each as
  # `{"name", "argument", "hosts"}`: the name cut at 120 characters, the argument as
  # `@argument_sql` reads it, the first ten string hosts cut at 255. What a credential and
  # a tool of `run.policy_applied` are read as, by `policy/2`, whose arguments are cut at
  # `@argument_read`, and by the statement of the timeline's items, whose arguments are
  # cut at `Timeline.max_argument/0`. `%DATA%` is the event's data.
  @named_hosts """
  (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'name', left(c ->> 'name', 120),
      'argument', #{@argument_sql},
      'hosts', (SELECT coalesce(jsonb_agg(left(h #>> '{}', 255)), '[]'::jsonb)
                FROM (SELECT h FROM jsonb_array_elements(
                        CASE WHEN jsonb_typeof(c -> 'hosts') = 'array' THEN c -> 'hosts' ELSE '[]'::jsonb END
                      ) WITH ORDINALITY hs(h, n)
                      WHERE jsonb_typeof(h) = 'string' ORDER BY n LIMIT 10) hq)) ORDER BY n), '[]'::jsonb)
   FROM (SELECT c, n FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(%DATA% -> '%KEY%') = 'array' THEN %DATA% -> '%KEY%' ELSE '[]'::jsonb END
         ) WITH ORDINALITY cs(c, n)
         WHERE jsonb_typeof(c -> 'name') = 'string' ORDER BY n LIMIT 20) cq)
  """

  defmacrop named_hosts(data, key) do
    sql =
      @named_hosts
      |> String.replace("%DATA%", "?")
      |> String.replace("%KEY%", key)
      |> String.replace("%ARGUMENT%", Integer.to_string(@argument_read))

    quote do: fragment(unquote(sql), unquote(data), unquote(data))
  end

  # How many entries the page makes of the array under `key`: one for each name and
  # argument, as `named_hosts/2` reads them, among its objects with a string `name`, however
  # many uses each has. The uses of one credential are one entry, so a count of them would
  # count the same credential more than once.
  defmacrop named_count(data, key) do
    sql = """
    (SELECT count(DISTINCT jsonb_build_array(left(c ->> 'name', 120), #{String.replace(@argument_sql, "%ARGUMENT%", Integer.to_string(@argument_read))}))
       FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(? -> '#{key}') = 'array' THEN ? -> '#{key}' ELSE '[]'::jsonb END
            ) cs(c)
      WHERE jsonb_typeof(c -> 'name') = 'string')
    """

    quote do: fragment(unquote(sql), unquote(data), unquote(data))
  end

  ## The run

  @doc """
  The run of the scope's workspace whose subject is `run_id`, the id the runner prints.
  `:error` for a subject the workspace has not seen and for anything that is not a UUID.
  """
  def fetch_run(%Scope{} = scope, run_id) do
    with {:ok, run_id} <- cast_uuid(run_id) do
      {:ok, scope |> Runs.get_run_by_run_id!(run_id) |> Repo.preload(:access_key)}
    end
  rescue
    Ecto.NoResultsError -> :error
  end

  # `Ecto.UUID.cast/1` takes sixteen raw bytes too; a URL never means those.
  defp cast_uuid(<<_::binary-size(36)>> = id), do: Ecto.UUID.cast(id)
  defp cast_uuid(_other), do: :error

  @doc "The run again, as the database has it now; nil when it is gone."
  def reload(%Scope{} = scope, %Run{id: id}) do
    case Repo.one(from r in runs(scope), where: r.id == ^id) do
      %Run{} = run -> Repo.preload(run, :access_key)
      nil -> nil
    end
  end

  @doc """
  The policy in force, from the run's last `run.policy_applied`: `%{sequence, time, mode,
  source, allow, allow_count, deny, deny_count, terminated, terminated_count,
  credentials, credentials_count, tools, tools_count}`; the lists hold at most fifty
  strings, the credentials and the tools at most twenty `%{"name", "argument", "hosts"}`
  each, with ten hosts at most and the argument whole up to the contract's 4096 code
  points, nil when the entry has none. One entry per entry of the event: the uses of one
  credential are as many entries with the same name and argument. A count is of the
  different names and arguments among all of them, as the page groups them. nil when the
  run has none.
  """
  def policy(%Scope{} = scope, %Run{} = run) do
    Repo.one(
      from e in events(scope, run),
        where: e.type == ^@policy_applied,
        order_by: [desc: e.sequence],
        limit: 1,
        select: %{
          sequence: e.sequence,
          time: e.time,
          mode: fragment("left(? ->> 'mode', 40)", e.data),
          source: fragment("left(? ->> 'source', 40)", e.data),
          allow: strings(e.data, "allow", 50, 255),
          allow_count: array_length(e.data, "allow"),
          deny: strings(e.data, "deny", 50, 255),
          deny_count: array_length(e.data, "deny"),
          terminated: strings(e.data, "terminated", 50, 255),
          terminated_count: array_length(e.data, "terminated"),
          credentials: named_hosts(e.data, "credentials"),
          credentials_count: named_count(e.data, "credentials"),
          tools: named_hosts(e.data, "tools"),
          tools_count: named_count(e.data, "tools")
        }
    )
  end

  @doc "The runtime's session id, from the run's last `session.started`; nil without one."
  def session_id(%Scope{} = scope, %Run{} = run) do
    Repo.one(
      from e in events(scope, run),
        where: e.type == ^@session_started,
        order_by: [desc: e.sequence],
        limit: 1,
        select: fragment("left(? ->> 'session_id', 120)", e.data)
    )
  end

  ## The timeline

  @doc """
  The layout of the run's timeline (`Timeline.index/2`) from a light read of every
  projected event that makes an item: ids and a few words, no payload. The outstanding
  background tasks are read beside it, from the last list the runtime gave.
  """
  def timeline(%Scope{} = scope, %Run{} = run) do
    scope
    |> light(run, 0, nil, false)
    |> Timeline.index(alive: run.state in Run.alive_states())
    |> Timeline.put_background(background(scope, run))
  end

  @doc """
  The index extended by the projected events after `index.through`, up to `last`: the
  range a projection announced. `:stale` when the range reaches below what the index
  holds: an event arrived late, and order is the sequence, so the run is read again.
  """
  def extend_timeline(%Scope{} = scope, %Run{} = run, index, first, last)
      when is_integer(first) and is_integer(last) do
    if first <= index.through do
      :stale
    else
      rows = light(scope, run, index.through, last, true)
      {:ok, Timeline.extend(index, rows, alive: run.state in Run.alive_states()), rows}
    end
  end

  # Only projected events: what a projection announces later is then always new.
  defp light(scope, run, after_sequence, last, tasks?) do
    types = Timeline.types()

    query =
      from e in events(scope, run),
        where: e.type in ^types and e.sequence > ^after_sequence and not is_nil(e.projected_at),
        order_by: e.sequence,
        select: %{
          sequence: e.sequence,
          type: e.type,
          time: e.time,
          tool_use_id: fragment("left(? ->> 'tool_use_id', 255)", e.data),
          agent_id: fragment("left(? ->> 'agent_id', 255)", e.data),
          agent_type: fragment("left(? ->> 'agent_type', 255)", e.data),
          host: fragment("left(? ->> 'host', 255)", e.data),
          port: fragment("left(? ->> 'port', 12)", e.data),
          decision: fragment("left(? ->> 'decision', 12)", e.data),
          # The tool whose host an egress event was for; nil on every other type. With the
          # decision it says whether the event was a tool invocation, and a group of them
          # is kept apart by it.
          tool:
            fragment(
              "CASE WHEN ? = ? AND jsonb_typeof(? -> 'tool') = 'string' THEN nullif(left(? ->> 'tool', 255), '') END",
              e.type,
              ^@egress,
              e.data,
              e.data
            )
        }

    query = if last, do: from(e in query, where: e.sequence <= ^last), else: query

    # Lists are read with a range, which is a few rows; the lists of a whole run are read
    # by `background/2`, which takes the last of each agent alone.
    query =
      if tasks? do
        from e in query,
          select_merge: %{
            background_tasks:
              fragment(
                "CASE WHEN ? = ANY(?) THEN ? END",
                e.type,
                type(^@list_types, {:array, :string}),
                listed_tasks(e.data)
              )
          }
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  The tasks of the last background-task list the runtime gave, fifty at most, each with
  the sequence of the first list of the run that named it. One event is read for the
  list, however many the run holds.
  """
  def background(%Scope{} = scope, %Run{} = run) do
    last =
      Repo.one(
        from e in events(scope, run),
          where: e.type in ^@list_types and not is_nil(e.projected_at),
          where: fragment("jsonb_typeof(? -> 'background_tasks') = 'array'", e.data),
          order_by: [desc: e.sequence],
          limit: 1,
          select: %{sequence: e.sequence, tasks: listed_tasks(e.data)}
      )

    tasks =
      if last, do: Enum.filter(last.tasks, &(is_binary(&1["id"]) and &1["id"] != "")), else: []

    listed = first_listed(scope, run, Enum.map(tasks, & &1["id"]))

    for task <- Enum.uniq_by(tasks, & &1["id"]) do
      %{
        id: task["id"],
        type: task["type"],
        status: task["status"],
        what: task["what"],
        listed_at: Map.get(listed, task["id"], last.sequence)
      }
    end
  end

  defp first_listed(_scope, _run, []), do: %{}

  defp first_listed(scope, run, ids) do
    Repo.all(
      from e in events(scope, run),
        where: e.type in ^@list_types,
        inner_lateral_join:
          t in fragment(
            "jsonb_array_elements(CASE WHEN jsonb_typeof(? -> 'background_tasks') = 'array' THEN ? -> 'background_tasks' ELSE '[]'::jsonb END)",
            e.data,
            e.data
          ),
        on: true,
        where: fragment("left(? ->> 'id', 64)", t.value) in ^ids,
        group_by: fragment("left(? ->> 'id', 64)", t.value),
        select: {fragment("left(? ->> 'id', 64)", t.value), min(e.sequence)}
    )
    |> Map.new()
  end

  @doc """
  The full items of the light items `light`, every payload cut by the database at
  #{Timeline.well_limit()} characters. `full:` lists the item sequences read with the
  larger cap of "Show all", #{Timeline.full_limit()}.
  """
  def items(%Scope{} = scope, %Run{} = run, light, opts \\ []) do
    full = opts |> Keyword.get(:full, []) |> MapSet.new()
    {whole, cut} = Enum.split_with(light, &(&1.seq in full))

    events =
      Map.merge(
        slim(scope, run, Timeline.needed(cut), Timeline.well_limit()),
        slim(scope, run, Timeline.needed(whole), Timeline.full_limit())
      )

    Timeline.build(light, events, full: MapSet.to_list(full))
  end

  # The columns of the statement below, by name: its own names, never an event's.
  @input_columns for key <- ~w(command file_path pattern path url description),
                     do: {key, String.to_atom("input_" <> key)}
  @slim_columns Map.new(
                  Timeline.slim_keys() ++ [:input_first | Enum.map(@input_columns, &elem(&1, 1))],
                  &{Atom.to_string(&1), &1}
                )

  @slim_sql """
  SELECT
    e.sequence, e.type, e.time,
    #{Enum.map_join(~w(tool agent_id agent_type runtime runtime_version host wall mode source model cwd kind outcome reason signal method request_method path decision rule path_rule credential request_id run_configuration), ",\n  ", &"CASE WHEN jsonb_typeof(e.data -> '#{&1}') = 'string' THEN left(e.data ->> '#{&1}', 400) END AS #{&1}")},
    #{Enum.map_join(~w(port exit_code duration_ms turns status), ",\n  ", &"CASE WHEN jsonb_typeof(e.data -> '#{&1}') = 'number' AND (e.data ->> '#{&1}') ~ '^-?[0-9]{1,15}$' THEN (e.data ->> '#{&1}')::bigint END AS #{&1}")},
    CASE WHEN jsonb_typeof(e.data -> 'cost_usd') = 'number' AND (e.data ->> 'cost_usd') ~ '^-?[0-9]{1,12}(\\.[0-9]{1,12})?([eE]-?[0-9]{1,2})?$' THEN (e.data ->> 'cost_usd')::float8 END AS cost_usd,
    (e.data -> 'interrupted' = 'true'::jsonb) IS TRUE AS interrupted,
    (x.i -> 'run_in_background' = 'true'::jsonb) IS TRUE AS in_background,
    #{Enum.map_join(~w(allow deny), ",\n  ", fn list -> """
    CASE WHEN jsonb_typeof(e.data -> '#{list}') = 'array' THEN jsonb_array_length(e.data -> '#{list}') ELSE 0 END AS #{list}_count,
    CASE WHEN e.type = 'dev.qory.run.policy_applied' THEN
      (SELECT coalesce(jsonb_agg(left(v #>> '{}', 255)), '[]'::jsonb)
         FROM (SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.data -> '#{list}') = 'array' THEN e.data -> '#{list}' ELSE '[]'::jsonb END) WITH ORDINALITY a(v, n)
               WHERE jsonb_typeof(v) = 'string' ORDER BY n LIMIT #{Timeline.max_allow()}) q) END AS #{list}\
    """ end)},
    (SELECT coalesce(jsonb_agg(left(v #>> '{}', 120)), '[]'::jsonb)
       FROM (SELECT v FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.data -> 'terminated') = 'array' THEN e.data -> 'terminated' ELSE '[]'::jsonb END) WITH ORDINALITY a(v, n)
             WHERE jsonb_typeof(v) = 'string' ORDER BY n LIMIT 5) q) AS terminated,
    CASE WHEN jsonb_typeof(e.data -> 'terminated') = 'array' THEN jsonb_array_length(e.data -> 'terminated') ELSE 0 END AS terminated_count,
    CASE WHEN e.type = 'dev.qory.run.policy_applied' THEN #{@named_hosts |> String.replace("%DATA%", "e.data") |> String.replace("%KEY%", "tools") |> String.replace("%ARGUMENT%", Integer.to_string(Timeline.max_argument()))} END AS tools,
    #{Enum.map_join(~w(command file_path pattern path url description), ",\n  ", &"CASE WHEN jsonb_typeof(x.i -> '#{&1}') = 'string' THEN left(x.i ->> '#{&1}', 400) END AS input_#{&1}")},
    (SELECT left(value #>> '{}', 400) FROM jsonb_each(CASE WHEN jsonb_typeof(x.i) = 'object' THEN x.i ELSE '{}'::jsonb END)
       WHERE jsonb_typeof(value) = 'string' AND value #>> '{}' <> '' ORDER BY key COLLATE "C" LIMIT 1) AS input_first,
    #{Enum.map_join(~w(text error details input response stdout stderr response_json), ",\n  ", fn name -> "left(y.#{name}, $5) AS #{name}, octet_length(y.#{name}) AS #{name}_bytes" end)},
    #{Enum.map_join(~w(error details response stdout stderr), ",\n  ", fn name -> "CASE WHEN y.#{name} IS NULL OR y.#{name} = '' THEN 0 ELSE length(y.#{name}) - length(replace(y.#{name}, E'\\n', '')) + CASE WHEN right(y.#{name}, 1) = E'\\n' THEN 0 ELSE 1 END END AS #{name}_lines" end)}
  FROM events e
  CROSS JOIN LATERAL (SELECT e.data -> 'input' AS i, e.data -> 'response' AS r) x
  CROSS JOIN LATERAL (SELECT
      CASE WHEN jsonb_typeof(x.r) = 'string' THEN x.r #>> '{}'
           WHEN jsonb_typeof(x.r #> '{file,content}') = 'string' THEN x.r #>> '{file,content}' END AS plain,
      CASE WHEN jsonb_typeof(x.r -> 'stdout') = 'string' THEN x.r ->> 'stdout' END AS out,
      CASE WHEN jsonb_typeof(x.r -> 'stderr') = 'string' THEN x.r ->> 'stderr' END AS err,
      CASE e.type WHEN 'dev.qory.session.prompt_submitted' THEN e.data -> 'prompt'
                  WHEN 'dev.qory.session.result' THEN e.data -> 'result'
                  ELSE e.data -> 'message' END AS body) w
  CROSS JOIN LATERAL (SELECT
      CASE WHEN jsonb_typeof(w.body) = 'string' THEN w.body #>> '{}' END AS text,
      CASE WHEN jsonb_typeof(e.data -> 'error') = 'string' THEN e.data ->> 'error' END AS error,
      CASE WHEN jsonb_typeof(e.data -> 'details') = 'string' THEN e.data ->> 'details' END AS details,
      CASE WHEN jsonb_typeof(x.i) = 'object' AND x.i <> '{}'::jsonb THEN jsonb_pretty(x.i) END AS input,
      w.plain AS response, w.out AS stdout, w.err AS stderr,
      CASE WHEN x.r IS NOT NULL AND jsonb_typeof(x.r) NOT IN ('string', 'null') AND x.r <> '{}'::jsonb
                AND coalesce(w.plain, '') = '' AND coalesce(w.out, '') = '' AND coalesce(w.err, '') = ''
           THEN jsonb_pretty(x.r) END AS response_json) y
  WHERE e.organisation_id = $1 AND e.workspace_id = $2 AND e.run_id = $3 AND e.sequence = ANY($4)
  """

  # The slim events of `sequences`, by sequence: one statement, scoped like every other
  # read, whose every text column is cut at `limit` characters by the database.
  defp slim(_scope, _run, [], _limit), do: %{}

  defp slim(scope, run, sequences, limit) do
    params = [
      Ecto.UUID.dump!(organisation_id(scope)),
      Ecto.UUID.dump!(workspace_id(scope)),
      Ecto.UUID.dump!(run.id),
      sequences,
      limit
    ]

    %{columns: columns, rows: rows} = Repo.query!(@slim_sql, params)
    columns = Enum.map(columns, &Map.fetch!(@slim_columns, &1))

    for row <- rows, into: %{} do
      event = columns |> Enum.zip(row) |> Map.new() |> slim_event()
      {event.sequence, event}
    end
  end

  defp slim_event(row) do
    input =
      for {key, column} <- @input_columns, into: %{} do
        {key, row[column]}
      end

    row
    |> Map.update!(:time, &utc/1)
    |> Map.update!(:terminated, &(&1 || []))
    |> Map.update!(:allow, &(&1 || []))
    |> Map.update!(:deny, &(&1 || []))
    |> Map.update!(:tools, &(&1 || []))
    |> Map.put(:summary, Timeline.tool_summary(row.tool, input, row.input_first))
    |> Map.take(Timeline.slim_keys())
    |> Map.new(fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
  end

  defp utc(%NaiveDateTime{} = time), do: DateTime.from_naive!(time, "Etc/UTC")
  defp utc(%DateTime{} = time), do: time

  ## Connections

  @doc "How many destinations a page of a run's connections holds."
  def connections_page_size, do: @connections_page

  @doc """
  What the run's connections come to, in one row: `%{all, allowed, denied, attempts}`,
  destinations that were ever allowed and ever denied, and every attempt.
  """
  def connection_counts(%Scope{} = scope, %Run{} = run) do
    counts =
      Repo.one(
        from c in connections_of(scope, run),
          select: %{
            all: count(c.id),
            allowed: fragment("count(*) FILTER (WHERE ? > 0)", c.allowed),
            denied: fragment("count(*) FILTER (WHERE ? > 0)", c.denied),
            attempts: coalesce(sum(c.attempts), 0)
          }
      )

    Map.update!(counts, :attempts, &to_integer/1)
  end

  @doc """
  A page of the run's connections, one per host, port and path, denied destinations first
  and then the most recently seen, #{@connections_page} to a page. `decision:` keeps the
  destinations ever `"allowed"` or ever `"denied"`. The reason a row gives is the last
  attempt's, as the projection keeps it: `tool` is the tool whose host the last attempt
  was for (nil when it named none), a tool invocation only with `decision` allowed
  (`Apiary.Runs.tool_invocation?/2`), and `status` what answered it.
  `%{rows, page, pages, total}`.
  """
  def connections(%Scope{} = scope, %Run{} = run, opts \\ []) do
    query =
      case opts[:decision] do
        "allowed" -> from c in connections_of(scope, run), where: c.allowed > 0
        "denied" -> from c in connections_of(scope, run), where: c.denied > 0
        _ -> connections_of(scope, run)
      end

    total = Repo.aggregate(query, :count)
    pages = max(ceil(total / @connections_page), 1)
    page = opts |> Keyword.get(:page, 1) |> max(1) |> min(pages)

    rows =
      Repo.all(
        from c in query,
          # Denied first, then by first seen, newest first: a row moves only when a new
          # destination arrives, never because one the page holds was seen again. A
          # live run retries a denied host every few seconds, and an order by last seen
          # swapped two denied rows under the pointer between the look and the click.
          order_by: [
            desc: c.denied > 0,
            desc: c.first_seen_at,
            asc: c.host,
            asc: c.id
          ],
          limit: @connections_page,
          offset: ^((page - 1) * @connections_page),
          select: %{
            id: c.id,
            host: fragment("left(?, 255)", c.host),
            port: c.port,
            path: fragment("left(?, 2000)", c.path),
            method: fragment("left(?, 40)", c.method),
            request_method: fragment("left(?, 40)", c.last_request_method),
            attempts: c.attempts,
            allowed: c.allowed,
            denied: c.denied,
            decision: fragment("left(?, 40)", c.last_decision),
            rule: fragment("left(?, 400)", c.last_rule),
            path_rule: fragment("left(?, 400)", c.last_path_rule),
            credential: fragment("left(?, 400)", c.last_credential),
            mode: fragment("left(?, 40)", c.last_mode),
            outcome: fragment("left(?, 40)", c.last_outcome),
            tool: fragment("left(?, 255)", c.last_tool),
            status: c.last_status,
            first_seen_at: c.first_seen_at,
            last_seen_at: c.last_seen_at,
            last_sequence: c.last_sequence
          }
      )

    %{rows: rows, page: page, pages: pages, total: total}
  end

  @doc """
  One connection of the run by its row id, whole, for `Apiary.Policy.rule_from_connection/4`.
  `:error` for an id that is not a UUID and for a row of another run or another workspace.
  """
  def connection(%Scope{} = scope, %Run{} = run, id) do
    with {:ok, id} <- cast_uuid(id),
         %Connection{} = connection <-
           Repo.one(from c in connections_of(scope, run), where: c.id == ^id) do
      {:ok, connection}
    else
      _ -> :error
    end
  end

  defp connections_of(scope, run) do
    from c in Connection,
      where:
        c.organisation_id == ^organisation_id(scope) and c.workspace_id == ^workspace_id(scope),
      where: c.run_id == ^run.id
  end

  ## The log

  @doc """
  What the run's log holds after `after_sequence` (0 for all of it): `%{chunks, bytes,
  through, streams}`; `through` is the last chunk's sequence (`after_sequence` when none
  follows) and `streams` the stream names among them.
  """
  def log_summary(%Scope{} = scope, %Run{} = run, after_sequence \\ 0) do
    chunks = from l in log_chunks(scope, run), where: l.sequence > ^after_sequence

    summary =
      Repo.one(
        from l in chunks,
          select: %{
            chunks: count(l.id),
            bytes: coalesce(sum(fragment("octet_length(?)", l.bytes)), 0),
            through: coalesce(max(l.sequence), ^after_sequence)
          }
      )

    streams = Repo.all(from l in chunks, distinct: true, select: l.stream, order_by: l.stream)

    summary
    |> Map.update!(:bytes, &to_integer/1)
    |> Map.put(:streams, streams)
  end

  @doc "A summary with what followed it added: the log of a live run, read by difference."
  def add_log_summary(summary, more) do
    %{
      chunks: summary.chunks + more.chunks,
      bytes: summary.bytes + more.bytes,
      through: max(summary.through, more.through),
      streams: Enum.sort(Enum.uniq(summary.streams ++ more.streams))
    }
  end

  defp to_integer(%Decimal{} = n), do: Decimal.to_integer(n)
  defp to_integer(n) when is_integer(n), do: n

  @doc """
  How far `log_pages/7` will go from `after_sequence`: `{through, all?}`, the sequence of
  the last of the first `limit` chunks after it, or `after_sequence` itself when none
  follows, and whether that is every chunk there is (below `before:`, when given).

  `stream:` keeps one stream (`"stdout"`, `"stderr"`, `"terminal"`); `limit: :all` takes
  every chunk; `before:` a sequence stops short of it, the next resize's say.
  """
  def log_through(%Scope{} = scope, %Run{} = run, after_sequence, opts \\ []) do
    query = log_after(scope, run, after_sequence, opts[:stream])

    query =
      case opts[:before] do
        before when is_integer(before) -> from l in query, where: l.sequence < ^before
        _none -> query
      end

    case log_limit(opts[:limit]) do
      :all ->
        {Repo.one(from l in query, select: max(l.sequence)) || after_sequence, true}

      limit ->
        {count, through} =
          Repo.one(
            from l in subquery(
                   from l in query,
                     order_by: l.sequence,
                     limit: ^limit,
                     select: %{sequence: l.sequence}
                 ),
                 select: {count(l.sequence), max(l.sequence)}
          )

        {through || after_sequence, count < limit}
    end
  end

  @doc """
  The size of the terminal the chunks right after `after_sequence` were written to:
  `{cols, rows}`, the last `dev.qory.run.resized` at or below it, else `terminal` of
  `dev.qory.run.started`; nil when the record says none, a run on pipes or one recorded
  before the runner reported the size. A size is read like the fold reads it.
  """
  def terminal_size(%Scope{} = scope, %Run{} = run, after_sequence) do
    resized =
      Repo.one(
        from e in events(scope, run),
          where: e.type == @resized and e.sequence <= ^after_sequence,
          order_by: [desc: e.sequence],
          limit: 1,
          select: e.data
      )

    started =
      resized ||
        Repo.one(
          from e in events(scope, run),
            where: e.type == @started,
            order_by: [desc: e.sequence],
            limit: 1,
            select: fragment("? -> 'terminal'", e.data)
        )

    size(started)
  end

  @doc """
  The first `dev.qory.run.resized` after `after_sequence` that is a size, `%{sequence,
  cols, rows}`, or nil: where a read of the log has to stop, since the chunks after it
  were written to a terminal of another size.
  """
  def next_resize(%Scope{} = scope, %Run{} = run, after_sequence) do
    Repo.all(
      from e in events(scope, run),
        where: e.type == @resized and e.sequence > ^after_sequence,
        order_by: e.sequence,
        limit: @resizes_read,
        select: {e.sequence, e.data}
    )
    |> Enum.find_value(fn {sequence, data} ->
      case size(data) do
        {cols, rows} -> %{sequence: sequence, cols: cols, rows: rows}
        nil -> nil
      end
    end)
  end

  defp size(%{"cols" => cols, "rows" => rows})
       when is_integer(cols) and cols in 1..@max_cells and is_integer(rows) and
              rows in 1..@max_cells,
       do: {cols, rows}

  defp size(_other), do: nil

  @doc """
  Calls `fun` with the bytes of each page of chunks after `after_sequence` up to and
  including `through`, in sequence order, threading `acc`: `fun.(iodata, acc)` answers
  `{:cont, acc}` or `{:halt, acc}`. A page is #{@log_page} chunks, so a long log is never
  held whole.
  """
  def log_pages(%Scope{} = scope, %Run{} = run, after_sequence, through, acc, fun, opts \\ []) do
    page =
      Repo.all(
        from l in log_after(scope, run, after_sequence, opts[:stream]),
          where: l.sequence <= ^through,
          order_by: l.sequence,
          limit: @log_page,
          select: {l.sequence, l.bytes}
      )

    case page do
      [] ->
        acc

      chunks ->
        {last, _bytes} = List.last(chunks)

        case fun.(Enum.map(chunks, &elem(&1, 1)), acc) do
          {:cont, acc} when length(chunks) == @log_page ->
            log_pages(scope, run, last, through, acc, fun, opts)

          {_either, acc} ->
            acc
        end
    end
  end

  defp log_after(scope, run, after_sequence, stream) do
    query = from l in log_chunks(scope, run), where: l.sequence > ^after_sequence
    if is_binary(stream), do: from(l in query, where: l.stream == ^stream), else: query
  end

  defp log_limit(:all), do: :all
  defp log_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_log_limit)
  defp log_limit(_other), do: @default_log_limit

  ## Scoping

  defp runs(%Scope{} = scope) do
    from r in Run,
      where:
        r.organisation_id == ^organisation_id(scope) and r.workspace_id == ^workspace_id(scope)
  end

  defp events(%Scope{} = scope, %Run{id: id}) do
    from e in Event,
      where:
        e.organisation_id == ^organisation_id(scope) and e.workspace_id == ^workspace_id(scope),
      where: e.run_id == ^id
  end

  defp log_chunks(%Scope{} = scope, %Run{id: id}) do
    from l in LogChunk,
      where:
        l.organisation_id == ^organisation_id(scope) and l.workspace_id == ^workspace_id(scope),
      where: l.run_id == ^id
  end

  defp organisation_id(%Scope{organisation: %Organisation{id: id}}), do: id
  defp workspace_id(%Scope{workspace: %Workspace{id: id}}), do: id
end
