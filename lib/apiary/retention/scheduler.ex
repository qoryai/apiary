defmodule Apiary.Retention.Scheduler do
  @moduledoc """
  Runs `Apiary.Retention.prune_all/1` once a night.

  A supervised process with one timer: it sleeps until the next `:hour` o'clock UTC
  (3 by default) plus a random part of an hour, prunes, and sleeps again. The jitter keeps
  several nodes from waking at once; the job's advisory lock lets one of them prune, and a
  workspace pruned in the last twelve hours is left alone by the others. A failure is
  logged by its kind and the next night tries again. Nothing is pruned at boot.

  Not started when `config :apiary, Apiary.Retention.Scheduler, enabled: false`, which is
  how the tests run; they call `Apiary.Retention.prune_all/1` themselves.
  """

  use GenServer

  require Logger

  @default_hour 3
  @jitter_seconds 3600

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the application starts the process."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc """
  Milliseconds from `now` to the next `hour` o'clock UTC, plus `jitter` seconds: never
  less than a minute, so a job that ends on the hour does not start again at once.
  """
  @spec until_next(DateTime.t(), 0..23, non_neg_integer()) :: pos_integer()
  def until_next(%DateTime{} = now, hour, jitter) do
    today = DateTime.new!(DateTime.to_date(now), Time.new!(hour, 0, 0), "Etc/UTC")

    next =
      if DateTime.compare(today, DateTime.add(now, 60, :second)) == :gt,
        do: today,
        else: DateTime.add(today, 86_400, :second)

    DateTime.diff(next, now, :millisecond) + jitter * 1000
  end

  @impl true
  def init(opts) do
    hour = Keyword.get(opts, :hour) || Keyword.get(config(), :hour, @default_hour)
    {:ok, schedule(%{hour: hour})}
  end

  @impl true
  def handle_info(:prune, state) do
    try do
      case Apiary.Retention.prune_all(trigger: "schedule") do
        {:ok, _results} -> :ok
        {:error, :locked} -> Logger.info("retention skipped reason=locked")
      end
    rescue
      # The database is away, or a statement failed: say so and try again tomorrow.
      error -> Logger.error("retention failed error=#{inspect(error.__struct__)}")
    end

    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(%{hour: hour} = state) do
    delay = until_next(DateTime.utc_now(), hour, :rand.uniform(@jitter_seconds))
    Process.send_after(self(), :prune, delay)
    state
  end

  defp config, do: Application.get_env(:apiary, __MODULE__, [])
end
