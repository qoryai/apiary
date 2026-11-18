defmodule Apiary.Runs.Sessions do
  @moduledoc """
  The record of each session of a run (`Apiary.Runs.SessionRecord`): how it is read from
  the run's events, and how it and the key windows of its reports are written.

  ## Reading the events

  `read/1` and `cost/1` are pure, over events as maps with `type`, `sequence`, `time` and
  `data`, and give the same answer for the events of a run whether they were projected in
  one pass or in many, and in a rebuild.

  A session is a Forager session number (`session` of the event, from 1). `session` is
  optional in the schema of `dev.qory.runtime.result`
  (`priv/contract/events/runtime.result.schema.json`), so a result with no `session`
  belongs to session 1, and so does a `dev.qory.runtime.started` with none. A session has a record
  when it has a start that is not bare (`bare` is Forager's mark of a session with no
  runtime, which measures nothing) or a result. A refused join, which has an exit and no
  start, has none.

  A launch of Claude Code writes several `dev.qory.runtime.result` lines, and each line's
  `cost_usd` and `usage` count the launch so far (decision 652 (a)), but its `turns` and
  `duration_ms` are those of the line. The lines are in the order of `line`, the number of
  the line of the session's standard output, with the lines that have none after those
  that have one, and lines of the same `line` by event `sequence`. So the session has:

    * `cost_usd` and `usage`: those of the last line that has them, so a last line without
      a cost leaves the cost of the line before it, a total so far, and not nothing;
    * `turns` and `duration_ms`: the sum over all the lines that have one, to the bound of
      the column, because each line counts its own turns and time;
    * `error`: true when any line has `is_error` true.

  A run's cost (`cost/1`) is the sum, over its sessions, of each session's cost. A value
  that is not a number in its bounds is absent, never clamped: a cost is 0 or more and
  below 1,000,000,000 dollars, a count 0 or more and within 8 bytes.

  ## Writing

  `write/1` writes the records of a run from all its session events, in a transaction of
  its own after the projector's pass has committed (`Apiary.Runs.Projector`), unless
  retention has deleted the run's events or is due to (`Apiary.Retention.due_or_pruned?/1`,
  asked under the run's projection lock): it inserts a record or
  replaces the columns that come from the events and from the run's place in the queue,
  never its `id`, so the key windows that hang on it stay. The write is the same for the
  same events whichever pass writes it. `record_windows/3` writes the key windows of the
  gateway's reports (`Apiary.ModelKeys.record/4`), and creates the record when the first
  report of a session arrives before the session's events do.

  An event carries a session's `dev.qory.runtime.result` data in the record's database
  columns only, never in a log line.
  """

  import Ecto.Query

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.{Repo, Retention}
  alias Apiary.Runs.{Event, Projector, Run, SessionKeyWindow, SessionRecord}
  alias Apiary.Stages.Session
  alias Apiary.WorkItems.WorkItem

  @session_started "dev.qory.session.started"
  @session_exited "dev.qory.session.exited"
  @runtime_started "dev.qory.runtime.started"
  @result "dev.qory.runtime.result"
  @types [@session_started, @session_exited, @runtime_started, @result]

  @int4 2_147_483_647
  @int8 9_223_372_036_854_775_807
  # The most a result may say a session cost, in dollars, before the value is read as
  # absent: a runtime's accounting error, not a bill.
  @max_cost Decimal.new(1_000_000_000)
  @model_bytes 255

  @usage_fields [
    input_tokens: "input",
    output_tokens: "output",
    cache_read_tokens: "cache_read",
    cache_write_tokens: "cache_write"
  ]

  # What the write replaces on a record that exists: every column but its key and `id`.
  @replaced ~w(dispatch_run_id work_item_id target_id stage_id workflow attempt started_at
               ended_at duration_ms turns input_tokens output_tokens cache_read_tokens
               cache_write_tokens cost_usd model error updated_at)a

  @typedoc "An event as `read/1` takes it."
  @type event :: %{
          required(:type) => String.t(),
          required(:sequence) => integer,
          required(:time) => DateTime.t() | nil,
          required(:data) => map
        }

  @typedoc "What `read/1` says of one session."
  @type session :: %{
          required(:session_number) => pos_integer,
          optional(atom) => term
        }

  @doc "The types of event the records are read from."
  @spec types() :: [String.t()]
  def types, do: @types

  ## Reading

  @doc """
  The sessions of `events`, in the order of their numbers: maps of `session_number`,
  `started_at`, `ended_at`, `model`, `duration_ms`, `turns`, `input_tokens`,
  `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_usd` and `error`, nil
  where the events have no value (`error` is false then).
  """
  @spec read([event]) :: [session]
  def read(events) do
    events = events |> Enum.filter(&(&1.type in @types)) |> Enum.sort_by(& &1.sequence)

    started = for %{type: @session_started} = e <- events, n = number(e.data), do: {n, e}
    agent_starts = for {n, e} <- started, not bare?(e.data), do: n
    results = for %{type: @result} = e <- events, do: {number(e.data) || 1, e}

    numbers = (agent_starts ++ Enum.map(results, &elem(&1, 0))) |> Enum.uniq() |> Enum.sort()

    for n <- numbers do
      lines = for {^n, e} <- results, do: line(e)

      session(n, lines, events)
    end
  end

  defp session(n, lines, events) do
    ordered = order(lines)
    usage = last_value(ordered, & &1.usage)

    %{
      session_number: n,
      started_at: first_time(events, @session_started, n),
      ended_at: last_time(events, @session_exited, n),
      model: model(events, n),
      cost_usd: last_value(ordered, & &1.cost),
      duration_ms: sum(lines, :duration_ms, @int8),
      turns: sum(lines, :turns, @int4),
      error: Enum.any?(lines, & &1.error?)
    }
    |> Map.merge(
      Map.new(@usage_fields, fn {field, member} -> {field, usage && usage[member]} end)
    )
  end

  # The lines in the order of the session's output: by `line`, those with none after those
  # with one, and by event sequence where the `line` is equal or missing. A total order.
  defp order(lines), do: Enum.sort_by(lines, &{is_nil(&1.line), &1.line, &1.sequence})

  defp last_value(ordered, fun) do
    ordered |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> List.last()
  end

  # The sum of a count over the lines that have it, cut at the column's bound; nil when
  # no line has one.
  defp sum(lines, field, bound) do
    case for(%{^field => count} when is_integer(count) <- lines, do: count) do
      [] -> nil
      counts -> min(Enum.sum(counts), bound)
    end
  end

  defp line(%{sequence: sequence, data: data}) do
    %{
      sequence: sequence,
      line: within(data["line"], 1..@int4),
      cost: result_cost(data),
      usage: usage(data),
      turns: within(data["turns"], 0..@int4),
      duration_ms: within(data["duration_ms"], 0..@int8),
      error?: data["is_error"] == true
    }
  end

  # The members of `usage` that are counts, nil with none: a result's counts are unknown
  # where it has none, never 0.
  defp usage(%{"usage" => %{} = usage}) do
    counts =
      for {_field, member} <- @usage_fields,
          count = within(usage[member], 0..@int8),
          into: %{},
          do: {member, count}

    if counts == %{}, do: nil, else: counts
  end

  defp usage(_data), do: nil

  defp first_time(events, type, n) do
    Enum.find_value(events, fn
      %{type: ^type, data: data, time: time} -> if number(data) == n, do: time
      _other -> nil
    end)
  end

  defp last_time(events, type, n), do: first_time(Enum.reverse(events), type, n)

  # The model the session's runtime opened with, the last of its main conversation's
  # `dev.qory.runtime.started`; a subagent's (`agent_id`) is not the session's.
  defp model(events, n) do
    models =
      for %{type: @runtime_started, data: data} <- events,
          (number(data) || 1) == n,
          not is_binary(data["agent_id"]),
          model = data["model"],
          is_binary(model) and model != "" and byte_size(model) <= @model_bytes,
          do: model

    List.last(models)
  end

  defp bare?(data), do: match?(%{"bare" => true}, data)

  # A session's number: an integer from 1, nil for anything else.
  defp number(%{"session" => n}) when is_integer(n) and n in 1..@int4, do: n
  defp number(_data), do: nil

  defp within(value, range), do: if(is_integer(value) and value in range, do: value)

  @doc """
  The cost of a run, from its `dev.qory.runtime.result` events (the pass's and those
  already projected): the sum, over the sessions, of each session's cost, as in the
  moduledoc. Nil when no result carries a cost: a run that reported none is unrecorded,
  not free.
  """
  @spec cost([event]) :: Decimal.t() | nil
  def cost(results) do
    results
    |> Enum.filter(&(&1.type == @result))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.group_by(&(number(&1.data) || 1), &line/1)
    |> Enum.flat_map(fn {_number, lines} -> List.wrap(last_value(order(lines), & &1.cost)) end)
    |> case do
      [] -> nil
      costs -> costs |> Enum.reduce(&Decimal.add/2) |> Decimal.normalize()
    end
  end

  # A cost is a JSON number, zero or more and below the bound; anything else is absent.
  defp result_cost(%{"cost_usd" => value}) when is_integer(value),
    do: bounded(Decimal.new(value))

  defp result_cost(%{"cost_usd" => value}) when is_float(value),
    do: bounded(Decimal.from_float(value))

  defp result_cost(_data), do: nil

  defp bounded(%Decimal{} = cost) do
    if Decimal.compare(cost, 0) != :lt and Decimal.compare(cost, @max_cost) == :lt,
      do: Decimal.normalize(cost)
  end

  ## Reading the stored events

  @doc """
  The run's session events, projected or not, in sequence order: `%{id, type, sequence,
  time, data, projected?}` each. `data` has only the members the records read.
  """
  @spec events(Ecto.UUID.t()) :: [map]
  def events(run_id) do
    Repo.all(
      from e in Event,
        where: e.run_id == ^run_id and e.type in ^@types,
        order_by: e.sequence,
        select: %{
          id: e.id,
          type: e.type,
          sequence: e.sequence,
          time: e.time,
          projected?: not is_nil(e.projected_at),
          data:
            fragment(
              "jsonb_strip_nulls(jsonb_build_object('session', ? -> 'session', 'bare', ? -> 'bare', 'line', ? -> 'line', 'cost_usd', ? -> 'cost_usd', 'usage', ? -> 'usage', 'turns', ? -> 'turns', 'duration_ms', ? -> 'duration_ms', 'is_error', ? -> 'is_error', 'model', ? -> 'model', 'agent_id', ? -> 'agent_id'))",
              e.data,
              e.data,
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
  end

  ## Writing

  @doc """
  Writes the record of each session of the run `run_id`, from all its session events
  (`events/1`), in a transaction that holds the run's projection lock
  (`Apiary.Runs.Projector.lock/1`) and, to check the records' foreign keys, the places in
  the order the end of a run takes them (`lock_places/1`). It is the projector's to call
  after a pass has committed, and once for a run's passes: the same events give the same
  rows, so a rebuild writes the rows of the first projection again. A run that is gone,
  whose events retention has deleted, or is due to delete, is left as it is: its records
  are what is left. Returns `:ok`.
  """
  @spec write(Ecto.UUID.t()) :: :ok
  def write(run_id) when is_binary(run_id) do
    {:ok, :ok} =
      Repo.transact(fn ->
        Projector.lock(run_id)

        with %Run{} = run <- lock_places(run_id),
             false <- Retention.due_or_pruned?(run),
             [_ | _] = sessions <- read(events(run_id)) do
          context = context(run)
          now = DateTime.utc_now()

          rows =
            for session <- sessions do
              run |> row(context, session.session_number, now) |> Map.merge(session)
            end

          Repo.insert_all(SessionRecord, rows,
            on_conflict: {:replace, @replaced},
            conflict_target: [:run_id, :session_number],
            log: false
          )
        end

        {:ok, :ok}
      end)

    :ok
  end

  # Locks, `FOR KEY SHARE`, what a record's foreign keys check, in the order the end of a
  # run locks them (`Apiary.Dispatches.RunEnd`): the work item, the run of the queue, then
  # the run. Postgres takes these locks on its own when it checks the keys, in the order of
  # the columns, the run first, and a record that took them so would wait for a lock the
  # end holds while the end waits for the lock the record holds on the run. Returns the
  # run as it is, nil for a run that is gone.
  defp lock_places(run_id) do
    with %Run{} = run <- Repo.get(Run, run_id) do
      dispatch = run.dispatch_run_id && Repo.get(DispatchRun, run.dispatch_run_id)

      if dispatch && dispatch.work_item_id do
        Repo.one(
          from w in WorkItem,
            where: w.id == ^dispatch.work_item_id,
            select: w.id,
            lock: "FOR KEY SHARE"
        )
      end

      if dispatch do
        Repo.one(
          from d in DispatchRun, where: d.id == ^dispatch.id, select: d.id, lock: "FOR KEY SHARE"
        )
      end

      Repo.one(from r in Run, where: r.id == ^run_id, lock: "FOR KEY SHARE")
    end
  end

  # What the run's place in the queue gives its sessions: the run of the queue and the
  # sessions of its shared run, nil and [] for a run the queue did not start.
  defp context(%Run{dispatch_run_id: id}) when is_binary(id) do
    %{
      dispatch_run: Repo.get(DispatchRun, id),
      sessions: Repo.all(from s in Session, where: s.dispatch_run_id == ^id, order_by: s.sequence)
    }
  end

  defp context(%Run{}), do: %{dispatch_run: nil, sessions: []}

  # The record's columns that come from Qory Apiary, not from the events.
  defp row(%Run{} = run, context, number, now) do
    dispatch = context.dispatch_run
    session = shared_session(context.sessions, number)

    %{
      id: Ecto.UUID.generate(),
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      dispatch_run_id: dispatch && dispatch.id,
      work_item_id: dispatch && dispatch.work_item_id,
      target_id: run.target_id,
      stage_id: dispatch && dispatch.stage_id,
      workflow: (session && session.workflow) || (dispatch && dispatch.workflow),
      attempt: dispatch && dispatch.attempt,
      session_number: number,
      error: false,
      inserted_at: now,
      updated_at: now
    }
  end

  # The row of the shared run's sessions that Forager's session `number` is: the row whose
  # report named it; else, for a session no report ended yet (the one open when a run
  # paused), the newest row with none, when `number` is beyond every reported one; else
  # the row of that sequence. Nil for a run that is not a shared run.
  defp shared_session([], _number), do: nil

  defp shared_session(sessions, number) do
    reported = for %{forager_session: n} when is_integer(n) <- sessions, do: n

    cond do
      row = Enum.find(sessions, &(&1.forager_session == number)) ->
        row

      number > Enum.max(reported, fn -> 0 end) ->
        sessions |> Enum.reverse() |> Enum.find(&is_nil(&1.forager_session))

      true ->
        Enum.find(sessions, &(&1.sequence == number))
    end
  end

  # The id of the record of session `number` of `run`, written with the run's place and no
  # event's values when it is not there yet. The record is written by the first thing that
  # knows of the session: a gateway's report, or the events. Runs in the transaction of
  # `record_windows/3`, after the places are locked.
  defp ensure(%Run{} = run, number) do
    Repo.insert_all(
      SessionRecord,
      [row(run, context(run), number, DateTime.utc_now())],
      on_conflict: :nothing,
      conflict_target: [:run_id, :session_number],
      log: false
    )

    Repo.one!(
      from r in SessionRecord,
        where: r.run_id == ^run.id and r.session_number == ^number,
        select: r.id
    )
  end

  @doc """
  Keeps, for session `number` of `run`, the utilization of each key window in `rows`
  (`%{secret_value_id, window, utilization, observed_at}`, as `Apiary.ModelKeys.record/4`
  has them): the report with the earliest `observed_at` of the session sets
  `first_utilization`, the one with the latest sets `last_utilization`, and `share` is the
  last less the first. A report with no utilization changes nothing. The record's row is
  locked while the windows are read and written, so two reports of one session wait for
  each other. Returns `:ok`.
  """
  @spec record_windows(Run.t(), 1..2_147_483_647, [map]) :: :ok
  def record_windows(%Run{} = run, number, rows) when number in 1..@int4 do
    rows = Enum.filter(rows, &is_integer(&1.utilization))

    if rows == [] do
      :ok
    else
      {:ok, :ok} =
        Repo.transact(fn ->
          # The projector writes this run's records under this lock: a report takes it
          # first, then asks under it whether the run is still one to write to.
          Projector.lock(run.id)

          with %Run{} = run <- lock_places(run.id),
               false <- Retention.due_or_pruned?(run) do
            {:ok, count_windows(run, number, rows)}
          else
            _gone_or_kept -> {:ok, :ok}
          end
        end)

      :ok
    end
  end

  defp count_windows(%Run{} = run, number, rows) do
    id = ensure(run, number)

    Repo.one!(from(r in SessionRecord, where: r.id == ^id, lock: "FOR UPDATE", select: r.id))

    stored =
      Repo.all(from w in SessionKeyWindow, where: w.session_record_id == ^id)
      |> Map.new(&{{&1.key_id, &1.window}, &1})

    now = DateTime.utc_now()

    windows =
      for row <- rows do
        stored
        |> Map.get({row.secret_value_id, row.window})
        |> window(row, %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          session_record_id: id,
          key_id: row.secret_value_id,
          window: row.window,
          inserted_at: now,
          updated_at: now
        })
      end

    Repo.insert_all(SessionKeyWindow, windows,
      on_conflict:
        {:replace,
         ~w(first_utilization first_observed_at last_utilization last_observed_at share updated_at)a},
      conflict_target: [:session_record_id, :key_id, :window]
    )

    :ok
  end

  # The window with `row`'s report counted in: the first of a window, else the earlier or
  # the later of the report and what the window has.
  defp window(nil, row, base) do
    utilization = Decimal.new(row.utilization)

    Map.merge(base, %{
      first_utilization: utilization,
      first_observed_at: row.observed_at,
      last_utilization: utilization,
      last_observed_at: row.observed_at,
      share: Decimal.new(0)
    })
  end

  defp window(%SessionKeyWindow{} = stored, row, base) do
    utilization = Decimal.new(row.utilization)

    first =
      if DateTime.compare(row.observed_at, stored.first_observed_at) == :lt,
        do: {utilization, row.observed_at},
        else: {stored.first_utilization, stored.first_observed_at}

    last =
      if DateTime.compare(row.observed_at, stored.last_observed_at) == :lt,
        do: {stored.last_utilization, stored.last_observed_at},
        else: {utilization, row.observed_at}

    Map.merge(base, %{
      first_utilization: elem(first, 0),
      first_observed_at: elem(first, 1),
      last_utilization: elem(last, 0),
      last_observed_at: elem(last, 1),
      share: Decimal.sub(elem(last, 0), elem(first, 0))
    })
  end
end
