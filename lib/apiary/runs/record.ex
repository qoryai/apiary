defmodule Apiary.Runs.Record do
  @moduledoc """
  The record of one run, as the run page reads it: its events in windows by sequence, the
  timeline laid out from them, its log chunks, its connections and its steps.

  Every function takes the caller's scope first and the run second, and reads only rows
  that carry the scope's organisation, the scope's workspace and the run's row id. A run
  of another workspace is never reached: `fetch_run/2` does not find it, and a `%Run{}` of
  another workspace handed in reads nothing.

  What an event carries is Forager's input, and an event may be megabytes. No function
  here selects an event's `data` whole: every field is cut by the database before it
  crosses the wire (`left(...)` on text, a bounded number of elements of an array), so
  what a read costs this server is bounded by the number of rows, never by what Forager
  put in them. `Apiary.Runs.Record.Timeline` says what is made of the rows; nothing here
  renders them.
  """

  import Ecto.Query, warn: false

  alias Apiary.Edition
  alias Apiary.Accounts.Scope
  alias Apiary.Harnesses.WorkflowGap
  alias Apiary.Organisations.{Workspace, Organisation}
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, LogChunk, Run, Step}
  alias Apiary.Runs.Record.Timeline

  @policy_applied "dev.qory.run.policy_applied"
  @runtime_started "dev.qory.runtime.started"
  @runtime_text "dev.qory.runtime.text"
  @session_started "dev.qory.session.started"
  @session_exited ~w(dev.qory.session.exited)
  @session_end_types ~w(dev.qory.runtime.started dev.qory.runtime.result dev.qory.session.exited)
  @resized "dev.qory.run.resized"
  @egress "dev.qory.run.egress"
  @list_types ["dev.qory.runtime.turn_finished", "dev.qory.runtime.subagent_finished"]

  @log_page 200
  @default_log_limit 2_000
  @max_log_limit 10_000
  # The most a terminal can be, as the contract has it; and how many resizes are read
  # past `after` for the first that is a size (a run's resizes that are not are rare).
  @max_cells 65_535
  @resizes_read 100
  @connections_page 50
  # The highest step number a step's column holds.
  @max_step 2_147_483_647

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

  # The longest `argument` of a credential use or a tool Forager's contract allows: the
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
  # `@argument_sql` reads it, the first ten string hosts cut at 255, `[]` for none. What a
  # credential and a tool of `run.policy_applied` are read as, by `policy/2`, whose
  # arguments are cut at `@argument_read`, and by the statement of the timeline's items,
  # whose arguments are cut at `Timeline.max_argument/0`. `%DATA%` is the event's data.
  # A credential also has `"purpose"` (`%PURPOSE%`, `@purpose_sql`).
  @named_hosts """
  (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'name', left(c ->> 'name', 120),
      'argument', #{@argument_sql},
      'hosts', (SELECT coalesce(jsonb_agg(left(h #>> '{}', 255)), '[]'::jsonb)
                FROM (SELECT h FROM jsonb_array_elements(
                        CASE WHEN jsonb_typeof(c -> 'hosts') = 'array' THEN c -> 'hosts' ELSE '[]'::jsonb END
                      ) WITH ORDINALITY hs(h, n)
                      WHERE jsonb_typeof(h) = 'string' ORDER BY n LIMIT 10) hq)%PURPOSE%)
      ORDER BY n), '[]'::jsonb)
   FROM (SELECT c, n FROM jsonb_array_elements(
           CASE WHEN jsonb_typeof(%DATA% -> '%KEY%') = 'array' THEN %DATA% -> '%KEY%' ELSE '[]'::jsonb END
         ) WITH ORDINALITY cs(c, n)
         WHERE jsonb_typeof(c -> 'name') = 'string' ORDER BY n LIMIT 20) cq)
  """

  # A credential's purpose: `harness` where its entry says so, else `work`, which is what
  # an entry without one means. Under a hidden harness, Forager lists a harness credential
  # by its name and purpose alone, with no hosts.
  @purpose_sql """
  ,
      'purpose', CASE WHEN c ->> 'purpose' = 'harness' THEN 'harness' ELSE 'work' END\
  """

  # `@named_hosts` for the array under each key, a credential's with its purpose.
  @named_hosts_of %{
    "tools" =>
      @named_hosts |> String.replace("%KEY%", "tools") |> String.replace("%PURPOSE%", ""),
    "credentials" =>
      @named_hosts
      |> String.replace("%KEY%", "credentials")
      |> String.replace("%PURPOSE%", @purpose_sql)
  }

  defmacrop named_hosts(data, key) do
    sql =
      @named_hosts_of
      |> Map.fetch!(key)
      |> String.replace("%DATA%", "?")
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
  The run of the scope's workspace that `param` names, with its access key, its node (a
  deleted node's too), for a run whose start failed, its dispatch (`Apiary.Runs.Run`,
  `dispatch_id`), and, for a run that ended `workflow_not_in_harness`, its run of the
  queue with that run's harness walk and work item. `param` is the run's number, as the
  run's URL carries it (`Apiary.Runs.Run.parse_number/1`), or its `public_id`, `rn_…`, as
  the API and older links carry it. `:error` for a run the workspace has not got, a run
  of another workspace among them, and for anything of neither shape, the node's run id
  among them.
  """
  def fetch_run(%Scope{} = scope, param) do
    case Runs.get_run_by_param(scope, param) do
      %Run{} = run ->
        {:ok, run |> Repo.preload([:access_key, :node, :dispatch]) |> WorkflowGap.preload()}

      nil ->
        :error
    end
  end

  @doc """
  The run again, as the database has it now, with what `fetch_run/2` reads beside it; nil
  when it is gone.
  """
  def reload(%Scope{} = scope, %Run{id: id}) do
    case Repo.one(from r in runs(scope), where: r.id == ^id) do
      %Run{} = run ->
        run |> Repo.preload([:access_key, :node, :dispatch]) |> WorkflowGap.preload()

      nil ->
        nil
    end
  end

  @doc """
  The policy in force, from the run's last `run.policy_applied`: `%{sequence, time, mode,
  source, allow, allow_count, allow_first, allow_first_count, deny, deny_count,
  terminated, terminated_count, credentials, credentials_count, tools, tools_count}`;
  `allow_first` is empty where the event has none. The lists hold at most fifty
  strings, the credentials and the tools at most twenty `%{"name", "argument", "hosts"}`
  each, with ten hosts at most and the argument whole up to the contract's 4096 code
  points, nil when the entry has none. One entry per entry of the event: the uses of one
  credential are as many entries with the same name and argument. A count is of the
  different names and arguments among all of them, as the page groups them. nil when the
  run has none.
  """
  def policy(%Scope{} = scope, %Run{} = run) do
    policy =
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
            allow_first: strings(e.data, "allow_first", 50, 255),
            allow_first_count: array_length(e.data, "allow_first"),
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

    Edition.client_reads(scope, :run_policy, run, policy)
  end

  @doc "The runtime's session id, from the run's last `runtime.started`; nil without one."
  def session_id(%Scope{} = scope, %Run{} = run) do
    Repo.one(
      from e in events(scope, run),
        where: e.type == ^@runtime_started,
        order_by: [desc: e.sequence],
        limit: 1,
        select: fragment("left(? ->> 'session_id', 120)", e.data)
    )
  end

  ## The timeline

  @doc """
  The layout of the run's timeline (`Timeline.index/2`) from a light read of every
  projected event of `Timeline.types/0`: ids and a few words, no payload. The outstanding
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
  The rows returned also have the session's exits (`dev.qory.session.exited`) from
  `first` on, which make no item, as the run page reads the **Run** list again at one.
  """
  def extend_timeline(%Scope{} = scope, %Run{} = run, index, first, last)
      when is_integer(first) and is_integer(last) do
    if first <= index.through do
      :stale
    else
      # A session's exit before `first` was in a range an earlier flush read.
      rows =
        scope
        |> light(run, index.through, last, true, @session_exited)
        |> Enum.reject(&(&1.type in @session_exited and &1.sequence < first))

      {:ok, Timeline.extend(index, rows, alive: run.state in Run.alive_states()), rows}
    end
  end

  # Only projected events: what a projection announces later is then always new. `extra`
  # are types read with the timeline's that make no item.
  defp light(scope, run, after_sequence, last, tasks?, extra \\ []) do
    types = Timeline.types() ++ extra

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
          # True on any event whose `bare` is `true`. The timeline reads it on a session's
          # start alone, where the fold reads the same value (`Apiary.Runs.Fold`).
          bare: fragment("? -> 'bare' = 'true'::jsonb", e.data),
          # The number of the session that sent the event, nil without one: the run page
          # places each item in the Timeline of its session by it.
          session:
            fragment(
              "CASE WHEN jsonb_typeof(? -> 'session') = 'number' AND (? ->> 'session') ~ '^[0-9]{1,10}$' THEN (? ->> 'session')::bigint END",
              e.data,
              e.data,
              e.data
            ),
          # A text event's kind, "prompt" for a user's text, or "empty" for a block with no
          # text, which makes no item.
          text_kind:
            fragment(
              "CASE WHEN ? = ? THEN CASE WHEN coalesce(? -> 'text', '\"\"'::jsonb) = '\"\"'::jsonb THEN 'empty' WHEN ? ->> 'role' = 'user' THEN 'prompt' ELSE left(? ->> 'kind', 12) END END",
              e.type,
              ^@runtime_text,
              e.data,
              e.data,
              e.data
            ),
          # 256 characters hold the 255 bytes the fold keeps of an egress event's host,
          # and one more, so a host longer than that is cut and marked below as the fold
          # cuts and marks it (`Timeline.egress_host/1`).
          host: fragment("left(? ->> 'host', 256)", e.data),
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

    query
    |> Repo.all()
    |> Enum.map(
      &(&1
        |> Map.update!(:session, fn n -> session_number(n) end)
        |> Timeline.egress_host())
    )
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

    Timeline.build(light, events, full: MapSet.to_list(full), scope: scope, run: run)
  end

  # The columns of the statement below, by name: its own names, never an event's.
  @slim_columns Map.new(Timeline.slim_keys(), &{Atom.to_string(&1), &1})

  @slim_sql """
  SELECT
    e.sequence, e.type, e.time,
    #{Enum.map_join(~w(tool agent_id agent_type runtime runtime_version host wall mode source model cwd kind outcome reason state code signal method request_method path decision rule path_rule credential request_id run_configuration), ",\n  ", &"CASE WHEN jsonb_typeof(e.data -> '#{&1}') = 'string' THEN left(e.data ->> '#{&1}', 400) END AS #{&1}")},
    #{Enum.map_join(~w(port exit_code duration_ms turns status line session), ",\n  ", &"CASE WHEN jsonb_typeof(e.data -> '#{&1}') = 'number' AND (e.data ->> '#{&1}') ~ '^-?[0-9]{1,15}$' THEN (e.data ->> '#{&1}')::bigint END AS #{&1}")},
    CASE WHEN jsonb_typeof(e.data -> 'cost_usd') = 'number' AND (e.data ->> 'cost_usd') ~ '^-?[0-9]{1,12}(\\.[0-9]{1,20})?([eE]-?[0-9]{1,2})?$' THEN (e.data ->> 'cost_usd')::float8 END AS cost_usd,
    (e.data -> 'interrupted' = 'true'::jsonb) IS TRUE AS interrupted,
    (e.data -> 'truncated' = 'true'::jsonb) IS TRUE AS truncated,
    (e.data -> 'is_error' = 'true'::jsonb) IS TRUE AS is_error,
    CASE WHEN jsonb_typeof(e.data -> 'summary') = 'string' THEN left(e.data ->> 'summary', 401) END AS summary,
    (x.i -> 'run_in_background' = 'true'::jsonb) IS TRUE AS in_background,
    #{Enum.map_join(~w(allow allow_first deny), ",\n  ", fn list -> """
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
    CASE WHEN e.type = 'dev.qory.run.policy_applied' THEN #{@named_hosts_of["tools"] |> String.replace("%DATA%", "e.data") |> String.replace("%ARGUMENT%", Integer.to_string(Timeline.max_argument()))} END AS tools,
    CASE WHEN e.type = 'dev.qory.run.policy_applied' THEN #{@named_hosts_of["credentials"] |> String.replace("%DATA%", "e.data") |> String.replace("%ARGUMENT%", Integer.to_string(Timeline.max_argument()))} END AS credentials,
    #{Enum.map_join(~w(text error details input response stdout stderr response_json content), ",\n  ", fn name -> "left(y.#{name}, $5) AS #{name}, octet_length(y.#{name}) AS #{name}_bytes" end)},
    #{Enum.map_join(~w(error details response stdout stderr content), ",\n  ", fn name -> "CASE WHEN y.#{name} IS NULL OR y.#{name} = '' THEN 0 ELSE length(y.#{name}) - length(replace(y.#{name}, E'\\n', '')) + CASE WHEN right(y.#{name}, 1) = E'\\n' THEN 0 ELSE 1 END END AS #{name}_lines" end)}
  FROM events e
  CROSS JOIN LATERAL (SELECT e.data -> 'input' AS i, e.data -> 'response' AS r) x
  CROSS JOIN LATERAL (SELECT
      CASE WHEN jsonb_typeof(x.r) = 'string' THEN x.r #>> '{}'
           WHEN jsonb_typeof(x.r #> '{file,content}') = 'string' THEN x.r #>> '{file,content}' END AS plain,
      CASE WHEN jsonb_typeof(x.r -> 'stdout') = 'string' THEN x.r ->> 'stdout' END AS out,
      CASE WHEN jsonb_typeof(x.r -> 'stderr') = 'string' THEN x.r ->> 'stderr' END AS err,
      CASE e.type WHEN 'dev.qory.runtime.prompt_submitted' THEN e.data -> 'prompt'
                  WHEN 'dev.qory.runtime.result' THEN e.data -> 'result'
                  WHEN 'dev.qory.runtime.text' THEN e.data -> 'text'
                  ELSE e.data -> 'message' END AS body) w
  CROSS JOIN LATERAL (SELECT
      CASE WHEN jsonb_typeof(w.body) = 'string' THEN w.body #>> '{}' END AS text,
      CASE WHEN jsonb_typeof(e.data -> 'error') = 'string' THEN e.data ->> 'error' END AS error,
      CASE WHEN jsonb_typeof(e.data -> 'details') = 'string' THEN e.data ->> 'details' END AS details,
      CASE WHEN jsonb_typeof(x.i) = 'object' AND x.i <> '{}'::jsonb THEN jsonb_pretty(x.i) END AS input,
      w.plain AS response, w.out AS stdout, w.err AS stderr,
      CASE WHEN x.r IS NOT NULL AND jsonb_typeof(x.r) NOT IN ('string', 'null') AND x.r <> '{}'::jsonb
                AND coalesce(w.plain, '') = '' AND coalesce(w.out, '') = '' AND coalesce(w.err, '') = ''
           THEN jsonb_pretty(x.r) END AS response_json,
      -- A tool result's content as text (`Timeline.content_text/1`).
      CASE WHEN e.type <> 'dev.qory.runtime.tool_result' THEN NULL
           WHEN jsonb_typeof(e.data -> 'content') = 'string' THEN e.data ->> 'content'
           WHEN jsonb_typeof(e.data -> 'content') = 'array' THEN
             (SELECT string_agg(CASE WHEN jsonb_typeof(b) = 'object' AND b ->> 'type' = 'text' AND jsonb_typeof(b -> 'text') = 'string' THEN b ->> 'text'
                                     WHEN jsonb_typeof(b -> 'type') = 'string' THEN '[' || left(b ->> 'type', 40) || ']'
                                     ELSE '[?]' END, E'\\n' ORDER BY n)
                FROM jsonb_array_elements(e.data -> 'content') WITH ORDINALITY a(b, n)) END AS content) y
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
    row
    |> Map.update!(:time, &utc/1)
    |> Map.update!(:terminated, &(&1 || []))
    |> Map.update!(:allow, &(&1 || []))
    |> Map.update!(:allow_first, &(&1 || []))
    |> Map.update!(:deny, &(&1 || []))
    |> Map.update!(:tools, &(&1 || []))
    |> Map.update!(:credentials, &(&1 || []))
    |> Map.put(:summary, Timeline.tool_summary(row.summary))
    |> Map.take(Timeline.slim_keys())
    |> Map.new(fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
    # 400 characters hold the 255 bytes the fold keeps of an egress event's host, and
    # more, so a longer host is cut and marked as the fold cuts and marks it.
    |> Timeline.egress_host()
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
  A page of the run's connections, one per host, port, path and channel (`channel`,
  `"session"` or `"stack"`, `Apiary.Runs.Connection`), denied destinations first
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
            channel: c.channel,
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

  # `Ecto.UUID.cast/1` takes sixteen raw bytes too; a URL never means those.
  defp cast_uuid(<<_::binary-size(36)>> = id), do: Ecto.UUID.cast(id)
  defp cast_uuid(_other), do: :error

  defp connections_of(scope, run) do
    query =
      from c in Connection,
        where:
          c.organisation_id == ^organisation_id(scope) and
            c.workspace_id == ^workspace_id(scope),
        where: c.run_id == ^run.id

    Edition.client_reads(scope, :run_connections, run, query)
  end

  ## The steps

  @doc """
  The run's steps (`Apiary.Runs.Step`), by number: each a step of its host work or of a
  session's join, with its name, kind, state, exit code, duration and the sequences and
  times of its start and its exit. `[]` for a run with none.
  """
  @spec steps(Scope.t(), Run.t()) :: [Step.t()]
  def steps(%Scope{} = scope, %Run{} = run) do
    Repo.all(from s in steps_of(scope, run), order_by: s.step)
  end

  @doc """
  The log lines of the run's step `step`: its `dev.qory.run.log` chunks with that `step`,
  `%{sequence, stream, bytes}` each, in sequence order. At most `limit:` chunks
  (#{@default_log_limit} by default, #{@max_log_limit} at most) after the sequence
  `after:` (0 by default), so a long step is read a page at a time from the last
  sequence of the page before. `[]` for a step without lines, for a number the run has
  no step of and for a number outside 1 to #{@max_step}.
  """
  @spec step_log(Scope.t(), Run.t(), integer, keyword) :: [map]
  def step_log(scope, run, step, opts \\ [])

  def step_log(%Scope{}, %Run{}, step, _opts) when step not in 1..@max_step, do: []

  def step_log(%Scope{} = scope, %Run{} = run, step, opts) when is_integer(step) do
    after_sequence = Keyword.get(opts, :after, 0)

    limit =
      case log_limit(opts[:limit]) do
        :all -> @max_log_limit
        limit -> limit
      end

    Repo.all(
      from l in log_chunks(scope, run),
        where: l.step == ^step and l.sequence > ^after_sequence,
        order_by: l.sequence,
        limit: ^limit,
        select: %{sequence: l.sequence, stream: l.stream, bytes: l.bytes}
    )
  end

  @doc """
  The end of the output of the run's step `step`: the last `bytes` bytes of its
  `dev.qory.run.log` chunks with that `step`, in sequence order, as `%{chunks, total,
  line_feeds}`. `chunks` are `%{bytes, time}`, oldest first: the part of each chunk that
  is kept, and the `time` of the chunk's event (`events.time` of the same sequence), nil
  once retention deleted the run's events. `total` is the size of the whole output in
  bytes, and `line_feeds` the number of line feeds (`\\n`) in it, so a reader can number
  the lines of the end. `%{chunks: [], total: 0, line_feeds: 0}` for a step without
  output and for a number outside 1 to #{@max_step}.
  """
  @spec step_tail(Scope.t(), Run.t(), integer, pos_integer) :: %{
          chunks: [%{bytes: binary, time: DateTime.t() | nil}],
          total: non_neg_integer,
          line_feeds: non_neg_integer
        }
  def step_tail(scope, run, step, bytes)

  def step_tail(%Scope{}, %Run{}, step, _bytes) when step not in 1..@max_step,
    do: %{chunks: [], total: 0, line_feeds: 0}

  def step_tail(%Scope{} = scope, %Run{} = run, step, bytes)
      when is_integer(step) and is_integer(bytes) and bytes > 0 do
    chunks = from l in log_chunks(scope, run), where: l.step == ^step

    # The database counts the line feeds: `escape` writes a zero byte and every byte from
    # 0x80 as an octal escape and keeps a line feed, so its text has as many as the bytes.
    # The tail is read through the last sequence counted, so on a live run the count and
    # the tail are of the same chunks.
    %{total: total, line_feeds: line_feeds, through: through} =
      Repo.one(
        from l in chunks,
          select: %{
            total: coalesce(sum(fragment("octet_length(?)", l.bytes)), 0),
            line_feeds:
              coalesce(
                sum(
                  fragment(
                    "octet_length(encode(?, 'escape')) - octet_length(replace(encode(?, 'escape'), E'\\n', ''))",
                    l.bytes,
                    l.bytes
                  )
                ),
                0
              ),
            through: max(l.sequence)
          }
      )

    kept =
      if is_nil(through),
        do: [],
        else: step_tail_pages(scope, run, chunks, bytes, through + 1, [])

    %{chunks: kept, total: to_integer(total), line_feeds: to_integer(line_feeds)}
  end

  @step_tail_page 500

  # The step's chunks newest first, a page at a time, each cut by the database to what is
  # left of the budget, until the budget is spent or the chunks run out; oldest first.
  defp step_tail_pages(_scope, _run, _chunks, left, _before, acc) when left <= 0, do: acc

  defp step_tail_pages(scope, run, chunks, left, before, acc) do
    page =
      Repo.all(
        from l in chunks,
          left_join: e in subquery(events(scope, run)),
          on: e.sequence == l.sequence,
          where: l.sequence < ^before,
          order_by: [desc: l.sequence],
          limit: @step_tail_page,
          select:
            {l.sequence,
             fragment(
               "substring(? from greatest(octet_length(?) - ?, 0) + 1)",
               l.bytes,
               l.bytes,
               ^left
             ), e.time}
      )

    {acc, left} =
      Enum.reduce_while(page, {acc, left}, fn {_sequence, part, time}, {acc, left} ->
        size = byte_size(part)

        if size >= left,
          do: {:halt, {[%{bytes: binary_part(part, size - left, left), time: time} | acc], 0}},
          else: {:cont, {[%{bytes: part, time: time} | acc], left - size}}
      end)

    if length(page) < @step_tail_page,
      do: acc,
      else: step_tail_pages(scope, run, chunks, left, page |> List.last() |> elem(0), acc)
  end

  @doc """
  The time of the run's first `dev.qory.session.started`, by sequence; nil for a run
  with none, and once retention deleted the run's events.
  """
  @spec session_started_at(Scope.t(), Run.t()) :: DateTime.t() | nil
  def session_started_at(%Scope{} = scope, %Run{} = run) do
    Repo.one(
      from e in events(scope, run),
        where: e.type == ^@session_started,
        order_by: e.sequence,
        limit: 1,
        select: e.time
    )
  end

  @doc """
  The run's first `dev.qory.run.built` by sequence: `%{time, image, data}`, `image` the
  event's `image` as it is, nil when that is no text, and `data` the event's data, for
  the check that stores its image (Apiary.Dispatches.Built); nil for a run with none,
  and once retention deleted the run's events.
  """
  @spec built(Scope.t(), Run.t()) ::
          %{time: DateTime.t(), image: String.t() | nil, data: map} | nil
  def built(%Scope{} = scope, %Run{} = run) do
    Repo.one(
      from e in events(scope, run),
        where: e.type == "dev.qory.run.built",
        order_by: e.sequence,
        limit: 1,
        select: %{
          time: e.time,
          image: fragment("left(? ->> 'image', 400)", e.data),
          data: e.data
        }
    )
  end

  @doc """
  The run's `dev.qory.session.started` events in sequence order: `%{sequence, time,
  session, bare, runtime}` each. `session` is the session's number, nil when the event
  has none that is an integer; `bare` is true for a session started with no runtime, whose
  `bare` is `true`; `runtime` is the event's `runtime`, its first 1,024 characters, nil
  when it is no text. None once retention deleted the run's events.
  """
  @spec session_starts(Scope.t(), Run.t()) :: [
          %{
            sequence: integer,
            time: DateTime.t(),
            session: integer | nil,
            bare: boolean,
            runtime: String.t() | nil
          }
        ]
  def session_starts(%Scope{} = scope, %Run{} = run) do
    Repo.all(
      from e in events(scope, run),
        where: e.type == ^@session_started,
        order_by: e.sequence,
        select: %{
          sequence: e.sequence,
          time: e.time,
          session: fragment("? -> 'session'", e.data),
          bare: fragment("coalesce(? -> 'bare' = 'true'::jsonb, false)", e.data),
          runtime:
            fragment(
              "CASE WHEN jsonb_typeof(? -> 'runtime') = 'string' THEN left(? ->> 'runtime', 1024) END",
              e.data,
              e.data
            )
        }
    )
    |> Enum.map(&%{&1 | session: session_number(&1.session)})
  end

  @doc """
  The run's `dev.qory.runtime.started`, `dev.qory.runtime.result` and
  `dev.qory.session.exited` events in sequence order: `%{type, sequence, time, session,
  data}` each. `session` is the session's number, nil when the event has none that is an
  integer, as in a record written before Forager sent it on every runtime event. `data`
  has only the members that the end of a session shows (`state`, `reason`, `exit_code`,
  `outcome`, `turns`, `duration_ms`, `cost_usd` and `model`).
  """
  @spec session_end_events(Scope.t(), Run.t()) :: [
          %{
            type: String.t(),
            sequence: integer,
            time: DateTime.t(),
            session: integer | nil,
            data: map
          }
        ]
  def session_end_events(%Scope{} = scope, %Run{} = run) do
    Repo.all(
      from e in events(scope, run),
        where: e.type in ^@session_end_types,
        order_by: e.sequence,
        select: %{
          type: e.type,
          sequence: e.sequence,
          time: e.time,
          session: fragment("? -> 'session'", e.data),
          data:
            fragment(
              "jsonb_strip_nulls(jsonb_build_object('state', ? -> 'state', 'reason', ? -> 'reason', 'exit_code', ? -> 'exit_code', 'outcome', ? -> 'outcome', 'turns', ? -> 'turns', 'duration_ms', ? -> 'duration_ms', 'cost_usd', ? -> 'cost_usd', 'model', ? -> 'model'))",
              e.data,
              e.data,
              e.data,
              e.data,
              e.data,
              e.data,
              e.data,
              e.data
            )
        }
    )
    |> Enum.map(&%{&1 | session: session_number(&1.session)})
  end

  # A session's number as the events send it: an integer from 1, else nil.
  defp session_number(n) when is_integer(n) and n in 1..@max_step, do: n
  defp session_number(_value), do: nil

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
  `{cols, rows}`, of the later by sequence of the last `dev.qory.run.resized` and the last
  `dev.qory.session.started` at or below it, a session's start giving its `terminal`;
  with neither, the `terminal` of the first `dev.qory.session.started`. Each session's
  start sets the size its chunks are written to. Nil when the record says none, a run on
  pipes or one recorded before Forager reported the size. A size is read like the fold
  reads it.
  """
  def terminal_size(%Scope{} = scope, %Run{} = run, after_sequence) do
    last =
      Repo.one(
        from e in events(scope, run),
          where: e.type in [@resized, @session_started] and e.sequence <= ^after_sequence,
          order_by: [desc: e.sequence],
          limit: 1,
          select: {e.type, e.data}
      )

    case last do
      {type, data} ->
        size(sizing(type, data))

      nil ->
        Repo.one(
          from e in events(scope, run),
            where: e.type == @session_started,
            order_by: e.sequence,
            limit: 1,
            select: fragment("? -> 'terminal'", e.data)
        )
        |> size()
    end
  end

  @doc """
  The first event after `after_sequence` that sets a size, `%{sequence, cols, rows}`, or
  nil: a `dev.qory.run.resized` that is a size, or any `dev.qory.session.started` other
  than the run's first, whose `cols` and `rows` are nil when it is on pipes. It is where a
  read of the log has to stop, since the chunks after it were written to a terminal of
  another size, or to none. The run's first session's start is the size from the log's
  beginning (`terminal_size/3`), so a read does not stop there.
  """
  def next_resize(%Scope{} = scope, %Run{} = run, after_sequence) do
    first_start =
      Repo.one(
        from e in events(scope, run),
          where: e.type == @session_started,
          order_by: e.sequence,
          limit: 1,
          select: e.sequence
      ) || 0

    Repo.all(
      from e in events(scope, run),
        where:
          e.sequence > ^after_sequence and
            (e.type == @resized or (e.type == @session_started and e.sequence > ^first_start)),
        order_by: e.sequence,
        limit: @resizes_read,
        select: {e.sequence, e.type, e.data}
    )
    |> Enum.find_value(fn {sequence, type, data} ->
      case {type, size(sizing(type, data))} do
        {_type, {cols, rows}} -> %{sequence: sequence, cols: cols, rows: rows}
        {@session_started, nil} -> %{sequence: sequence, cols: nil, rows: nil}
        {_resized, nil} -> nil
      end
    end)
  end

  # The size of each: a resize's data, a session's start's `terminal`.
  defp sizing(@session_started, %{"terminal" => terminal}), do: terminal
  defp sizing(@session_started, _data), do: nil
  defp sizing(_resized, data), do: data

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

  @doc """
  Where line `line` (1-based) of the session's stdout starts in the log as Raw reads it:
  the number of bytes before it in the run's chunks of `stream`, every stream when nil, in
  sequence order. A runtime event read from the output has the line's number (`line`) and
  the session's (`session`); a `dev.qory.run.log` event has the session's too. `line`
  counts the runtime's output only, so a chunk of a step, such as a walled session's setup
  command, is not counted, though it has the session. The session is read from the chunk's
  event, as `log_chunks` has no column for it. Nil when the session's stdout in the log
  has fewer lines, as after the log was pruned.
  """
  def log_offset(%Scope{} = scope, %Run{} = run, session, line, stream)
      when is_integer(session) and is_integer(line) and line >= 1 do
    case line_start(scope, run, session, line - 1, 0) do
      {sequence, within} ->
        before =
          Repo.one(
            from l in log_after(scope, run, 0, stream),
              where: l.sequence < ^sequence,
              select: coalesce(sum(fragment("octet_length(?)", l.bytes)), 0)
          )

        to_integer(before) + within

      nil ->
        nil
    end
  end

  def log_offset(_scope, _run, _session, _line, _stream), do: nil

  # The chunk the line starts in, and the bytes of the chunk before it: `breaks` line
  # feeds of the session's stdout come before the line. A line that starts where a chunk
  # ends starts at the next chunk; with none, the log has no such line yet.
  defp line_start(scope, run, session, breaks, after_sequence) do
    page =
      Repo.all(
        from l in log_after(scope, run, after_sequence, "stdout"),
          where: is_nil(l.step),
          join: e in subquery(events(scope, run)),
          on: e.sequence == l.sequence,
          where: fragment("(?->>'session') = ?", e.data, ^Integer.to_string(session)),
          order_by: l.sequence,
          limit: @log_page,
          select: {l.sequence, l.bytes}
      )

    case find_break(page, breaks) do
      {:found, sequence, within} ->
        {sequence, within}

      {:more, left, last} when length(page) == @log_page ->
        line_start(scope, run, session, left, last)

      _none ->
        nil
    end
  end

  defp find_break([], breaks), do: {:none, breaks}

  defp find_break([{sequence, _bytes} | _rest], 0), do: {:found, sequence, 0}

  defp find_break([{sequence, bytes} | rest], breaks) do
    feeds = :binary.matches(bytes, "\n")

    if length(feeds) >= breaks do
      {at, 1} = Enum.at(feeds, breaks - 1)

      cond do
        at + 1 < byte_size(bytes) -> {:found, sequence, at + 1}
        rest == [] -> {:more, 0, sequence}
        true -> find_break(rest, 0)
      end
    else
      case rest do
        [] -> {:more, breaks - length(feeds), sequence}
        _ -> find_break(rest, breaks - length(feeds))
      end
    end
  end

  # How much of the end of the log a glance reads: enough for thirty long lines.
  @tail_bytes 32_768
  @tail_chunks 64

  @doc """
  The last `lines` lines of the run's log as plain text, for a glance at it (the runs
  list's preview), never as the log: the end of its last chunks, every stream in sequence
  order, at most #{@tail_bytes} bytes of them, through `plain_lines/1`. The first line is
  left out when the read began inside it. `[]` for a run with no log.
  """
  @spec log_tail(Scope.t(), Run.t(), pos_integer) :: [String.t()]
  def log_tail(%Scope{} = scope, %Run{} = run, lines \\ 30) do
    chunks =
      Repo.all(
        from l in log_chunks(scope, run),
          order_by: [desc: l.sequence],
          limit: @tail_chunks,
          select:
            {fragment("octet_length(?)", l.bytes),
             fragment(
               "substring(? from greatest(octet_length(?) - ?, 0) + 1)",
               l.bytes,
               l.bytes,
               ^@tail_bytes
             )}
      )

    {kept, whole?} = take_tail(chunks, [], 0, length(chunks) < @tail_chunks)
    text = IO.iodata_to_binary(kept)

    text
    |> plain_lines()
    |> then(fn all -> if whole? or length(all) < 2, do: all, else: tl(all) end)
    |> Enum.take(-lines)
  end

  # The chunks, newest first, gathered oldest first until the budget is spent; whether
  # the read holds the log from its start.
  defp take_tail([], acc, _bytes, all?), do: {acc, all?}

  defp take_tail([{size, bytes} | rest], acc, spent, all?) do
    cond do
      spent + byte_size(bytes) >= @tail_bytes ->
        keep = binary_part(bytes, byte_size(bytes) - (@tail_bytes - spent), @tail_bytes - spent)
        {[keep | acc], false}

      size > byte_size(bytes) ->
        {[bytes | acc], false}

      true ->
        take_tail(rest, [bytes | acc], spent + byte_size(bytes), all?)
    end
  end

  @doc """
  plain_lines/1 is a terminal's bytes as lines of plain text: each line as `plain_line/1`
  has it, and the empty lines at the end dropped.
  """
  @spec plain_lines(binary) :: [String.t()]
  def plain_lines(bytes) when is_binary(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.map(&plain_line/1)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  plain_line/1 is one line of a terminal's bytes, without its line feed, as plain text:
  what is not UTF-8 is replaced, escape sequences (colours, cursor moves, titles) are taken
  out, a carriage return starts the line over, every other control character but the tab
  goes, and the spaces at the end are trimmed.
  """
  @spec plain_line(binary) :: String.t()
  def plain_line(bytes) when is_binary(bytes) do
    bytes
    |> String.replace_invalid()
    # OSC (a title, a link) to its terminator; CSI; the two-byte escapes and a charset.
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)?/u, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/u, "")
    |> String.replace(~r/\e[()*+][0-9A-Za-z]|\e[@-_]?/u, "")
    |> String.split("\r")
    |> Enum.reject(&(&1 == ""))
    |> List.last("")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, "")
    |> String.trim_trailing()
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

  defp events(%Scope{} = scope, %Run{id: id} = run) do
    query =
      from e in Event,
        where:
          e.organisation_id == ^organisation_id(scope) and
            e.workspace_id == ^workspace_id(scope),
        where: e.run_id == ^id

    Edition.client_reads(scope, :run_events, run, query)
  end

  defp log_chunks(%Scope{} = scope, %Run{id: id}) do
    from l in LogChunk,
      where:
        l.organisation_id == ^organisation_id(scope) and l.workspace_id == ^workspace_id(scope),
      where: l.run_id == ^id
  end

  defp steps_of(%Scope{} = scope, %Run{id: id}) do
    from s in Step,
      where:
        s.organisation_id == ^organisation_id(scope) and s.workspace_id == ^workspace_id(scope),
      where: s.run_id == ^id
  end

  defp organisation_id(%Scope{organisation: %Organisation{id: id}}), do: id
  defp workspace_id(%Scope{workspace: %Workspace{id: id}}), do: id
end
