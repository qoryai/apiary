defmodule Apiary.Runs.Liveness do
  @moduledoc """
  Finds the runs that stopped talking and marks them `lost`, after projecting whatever a
  dead task or a stopped node left unprojected.

  A run announces how often it beats (`interval_seconds` of its heartbeats, and of its
  registration, `Apiary.Runs.Registration`). It is lost when nothing has been heard for
  more than three of those intervals: its heartbeats' once they say one, else its
  registration's; a run that has announced none is held to 30 seconds, Forager's default,
  so to 90 seconds of silence.

    * a `running` run is measured from its last heartbeat, or, when it has not beaten yet,
      from the arrival of its `run.started`;
    * a `pending` run, one that has registered or whose events have begun, and whose
      `run.started` has not come, is measured from the moment the workspace first heard of
      it (`inserted_at`, which for a run that registered is its `registered_at`).

  **A heartbeat's time.** A heartbeat counts as heard at its own `time`, corrected by the
  run's clock offset, plus a tolerance of 300 seconds, and never after its arrival
  (`heard_at/3`); the fold keeps that as the run's `last_heartbeat_at`. The offset,
  `clock_offset_ms`, is the smallest arrival less own time over the run's heartbeats,
  and for a run with no session, which the gateway beats for, its ping's
  (`Apiary.Runs.Fold`). So a backlog of heartbeats delivered late holds no run alive,
  unless they were recorded within the tolerance and three intervals of their arrival, or
  the run had no offset before them, when its first heartbeat counts at its arrival; a
  machine whose clock is off by a constant is not lost for it, and a heartbeat dated in
  the future holds nothing alive. A clock set back by more than the tolerance makes the
  heartbeats after it count as old. The arrival of the `run.started` is its
  `received_at`. Only this server's clock is compared with `now`.

  **The sweep.** The receiver projects a batch in a task after it has answered. If that
  task dies, or the node stops between the commit and the task, the events stay
  unprojected; were that the batch with the exit, the run would be found lost with its
  exit stored. So before the rules, every check projects the runs that have events
  unprojected for more than ten seconds, at most 100 runs a check, oldest first. It
  also runs once when the process starts, which is when a restarted node finds them.

  Each rule is one `UPDATE … WHERE`, so several nodes ticking at once do not disagree:
  the row is changed by whichever gets there first and the other matches nothing. No
  stored value can make a rule raise: the interval is bounded inside the SQL. `lost` is
  not final: a later heartbeat or the exit corrects the state through the projector.

  **Alive.** The two rules are one condition each, shared: `alive/2` is their negation,
  for whatever counts the runs that are still alive, as a node's running instances and
  its instance limit do, so that running means exactly "not yet lost". The fold revives a
  lost or pending run on a heartbeat by the running rule (`heard_within?/3`), judged at
  the heartbeat's arrival, so it revives no run that the check would mark lost at that
  moment.

  The process ticks every `:interval` milliseconds (15 s) and is not started when
  `config :apiary, Apiary.Runs.Liveness, enabled: false`; tests call `check/1`.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Event, Projector, Run}

  @default_interval :timer.seconds(15)
  @default_beat 30
  @missed 3
  @max_beat 3600
  @sweep_after 10
  @sweep_limit 100
  # How far past its own time, corrected by the run's clock offset, a heartbeat may count:
  # the skew, drift and transit the contract's 300 seconds on `X-Qory-Timestamp` allow.
  @clock_tolerance 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the application starts the process."
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc """
  Projects what was left unprojected (`sweep/1`), then marks the runs lost as of `now` and
  returns them. Broadcasts `{:run_changed, run}` for each.
  """
  @spec check(DateTime.t()) :: [struct()]
  def check(%DateTime{} = now \\ DateTime.utc_now()) do
    sweep(now)
    lost = mark(running_silent(now), now) ++ mark(pending_silent(now), now)
    Enum.each(lost, &Runs.broadcast_changed/1)
    lost
  end

  @doc """
  Projects the runs with events received more than ten seconds before `now` and still
  unprojected, oldest first, at most #{@sweep_limit}. Returns how many runs it projected. A run
  whose projection fails is logged by the projector and tried again at the next check.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(%DateTime{} = now \\ DateTime.utc_now()) do
    before = DateTime.add(now, -@sweep_after, :second)

    runs =
      Repo.all(
        from e in Event,
          where: is_nil(e.projected_at) and e.received_at < ^before,
          group_by: e.run_id,
          order_by: min(e.received_at),
          limit: @sweep_limit,
          select: e.run_id
      )

    Enum.each(runs, fn id ->
      try do
        Projector.project(%Run{id: id})
      rescue
        error ->
          Logger.error("sweep failed run=#{id} error=#{inspect(error.__struct__)}")
      end
    end)

    length(runs)
  end

  @doc """
  The clock offset an event gives, in milliseconds: when this server received it less its
  own `time`, rounded down.
  """
  @spec clock_offset(DateTime.t(), DateTime.t()) :: integer()
  def clock_offset(%DateTime{} = received_at, %DateTime{} = time),
    do: Integer.floor_div(DateTime.diff(received_at, time, :microsecond), 1000)

  @doc """
  When a heartbeat received at `received_at` and dated `time` counts as heard, by the run's
  clock offset `offset` (`clock_offset/2`, the smallest of the run's): `time` plus
  `offset` plus #{@clock_tolerance} seconds, never after `received_at` and never before
  1970.
  """
  @spec heard_at(DateTime.t(), DateTime.t(), integer()) :: DateTime.t()
  def heard_at(%DateTime{} = received_at, %DateTime{} = time, offset) when is_integer(offset) do
    heard =
      DateTime.to_unix(time, :microsecond) + offset * 1000 + @clock_tolerance * 1_000_000

    if heard >= DateTime.to_unix(received_at, :microsecond),
      do: received_at,
      else: DateTime.from_unix!(max(heard, 0), :microsecond)
  end

  @doc """
  Whether a run heard at `heard_at`, whose stored heartbeat interval is `interval`, is
  heard from within three of its intervals at `at`: the running rule, bounded as the SQL
  bounds it. The fold revives a run by it; `alive/2` and the check are the same rule.
  """
  @spec heard_within?(DateTime.t(), integer() | nil, DateTime.t()) :: boolean()
  def heard_within?(%DateTime{} = heard_at, interval, %DateTime{} = at) do
    beat = if is_integer(interval), do: interval |> max(1) |> min(@max_beat), else: @default_beat
    DateTime.compare(DateTime.add(heard_at, beat * @missed, :second), at) != :lt
  end

  # The interval is bounded here as well as in the fold, so the arithmetic cannot
  # overflow whatever the column holds: the heartbeats', else the registration's, else the
  # default.
  defmacrop silence(heartbeat, registration) do
    quote do
      fragment(
        "LEAST(GREATEST(COALESCE(?, ?, ?), 1), ?) * ? * interval '1 second'",
        unquote(heartbeat),
        unquote(registration),
        @default_beat,
        @max_beat,
        @missed
      )
    end
  end

  @doc """
  alive/2 narrows `query`, a query of runs whose binding is named `:run` (as
  `from r in Run, as: :run`), to the runs alive as of `now`: `pending` or `running`, and
  heard from within three of their intervals by the rules above. It is the negation of
  the rules the check marks lost by, the same SQL, so a run is alive exactly while the
  check would not mark it: what counts as running anywhere else (an instance, a node, the
  instance limit) is "not yet lost".

  The states are compared as literals, so a query of it can be read from a partial index
  on the runs alive (`WHERE state IN ('pending', 'running')`).
  """
  @spec alive(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def alive(query, %DateTime{} = now) do
    silent =
      dynamic(
        [run: r],
        (r.state == "running" and ^silent(:running, now)) or
          (r.state == "pending" and ^silent(:pending, now))
      )

    where(query, ^dynamic([run: r], r.state in ["pending", "running"] and not (^silent)))
  end

  # The two rules, as conditions on a run named `:run`: a running run silent since its
  # last heartbeat, its run.started's arrival or its first event; a pending run silent
  # since its first event.
  defp silent(:running, now) do
    started =
      from e in Event,
        where: e.run_id == parent_as(:run).id and e.type == "dev.qory.run.started",
        order_by: e.sequence,
        limit: 1,
        select: e.received_at

    dynamic(
      [run: r],
      fragment(
        "COALESCE(?, ?, ?) + ? < ?",
        r.last_heartbeat_at,
        subquery(started),
        r.inserted_at,
        silence(r.heartbeat_interval_seconds, r.registration_interval_seconds),
        ^now
      )
    )
  end

  defp silent(:pending, now) do
    dynamic(
      [run: r],
      fragment(
        "? + ? < ?",
        r.inserted_at,
        silence(r.heartbeat_interval_seconds, r.registration_interval_seconds),
        ^now
      )
    )
  end

  defp running_silent(now),
    do: from(r in Run, as: :run, where: r.state == "running", where: ^silent(:running, now))

  defp pending_silent(now),
    do: from(r in Run, as: :run, where: r.state == "pending", where: ^silent(:pending, now))

  @doc """
  mark/2 marks the runs of `query` lost as of `now`, in one `UPDATE … WHERE`, and returns
  them as they are now. It broadcasts nothing: the caller broadcasts each run once what
  it is part of has committed. The check marks the runs its rules find; Clear instance
  (`Apiary.Nodes.clear_instance/3`) the open runs of an instance.
  """
  @spec mark(Ecto.Queryable.t(), DateTime.t()) :: [Run.t()]
  def mark(query, %DateTime{} = now) do
    {_count, runs} =
      Repo.update_all(select(query, [r], r), set: [state: "lost", lost_at: now, updated_at: now])

    runs
  end

  ## The process

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval) || Keyword.get(config(), :interval, @default_interval)
    send(self(), :boot)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  # Once at the start: what a node that stopped left unprojected.
  @impl true
  def handle_info(:boot, state) do
    try do
      sweep()
    rescue
      error -> Logger.error("sweep failed error=#{inspect(error.__struct__)}")
    end

    {:noreply, state}
  end

  def handle_info(:tick, %{interval: interval} = state) do
    try do
      check()
    rescue
      # The database is away: say so once per tick and try again at the next.
      error -> Logger.error("liveness check failed error=#{inspect(error.__struct__)}")
    end

    schedule(interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)

  defp config, do: Application.get_env(:apiary, __MODULE__, [])
end
