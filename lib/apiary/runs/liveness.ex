defmodule Apiary.Runs.Liveness do
  @moduledoc """
  Finds the runs that stopped talking and marks them `lost`.

  A run announces how often it beats (`interval_seconds` of its heartbeats). It is lost
  when nothing has been heard for more than three of those intervals; a run that has not
  announced one is held to 30 seconds, the runner's default, so to 90 seconds of silence.

    * a `running` run is measured from its last heartbeat, or from `started_at` when it
      has not beaten yet;
    * a `pending` run, one whose events have begun and whose `run.started` has not come,
      is measured from the moment the hive first heard of it (`inserted_at`).

  The heartbeat's time is the runner's clock and `now` is this node's: a runner whose
  clock is far behind is found lost early, and its next heartbeat corrects that.

  Each rule is one `UPDATE … WHERE`, so several nodes ticking at once do not disagree:
  the row is changed by whichever gets there first and the other matches nothing. `lost`
  is not final: a later heartbeat or the exit corrects the state through the projector.

  The process ticks every `:interval` milliseconds (15 s) and is not started when
  `config :apiary, Apiary.Runs.Liveness, enabled: false`; tests call `check/1`.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.Run

  @default_interval :timer.seconds(15)
  @default_beat 30
  @missed 3

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the application starts the process."
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc """
  Marks the runs lost as of `now` and returns them. Broadcasts `{:run_changed, run}` for
  each.
  """
  @spec check(DateTime.t()) :: [struct()]
  def check(%DateTime{} = now \\ DateTime.utc_now()) do
    lost = mark(running_silent(now), now) ++ mark(pending_silent(now), now)
    Enum.each(lost, &Runs.broadcast_changed/1)
    lost
  end

  defp running_silent(now) do
    from r in Run,
      where: r.state == "running",
      where:
        fragment(
          "COALESCE(?, ?, ?) + make_interval(secs => ? * COALESCE(?, ?)) < ?",
          r.last_heartbeat_at,
          r.started_at,
          r.inserted_at,
          @missed,
          r.heartbeat_interval_seconds,
          @default_beat,
          ^now
        )
  end

  defp pending_silent(now) do
    from r in Run,
      where: r.state == "pending",
      where:
        fragment(
          "? + make_interval(secs => ? * COALESCE(?, ?)) < ?",
          r.inserted_at,
          @missed,
          r.heartbeat_interval_seconds,
          @default_beat,
          ^now
        )
  end

  defp mark(query, now) do
    {_count, runs} =
      Repo.update_all(select(query, [r], r), set: [state: "lost", lost_at: now, updated_at: now])

    runs
  end

  ## The process

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval) || Keyword.get(config(), :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
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
