defmodule Apiary.Runs.StuckLog do
  # StuckLog writes the line about a run of the queue whose end or settle fails at each
  # try, at most once an hour for each run and kind of line: the lost-run check's end
  # (`Apiary.Dispatches.RunEnd.lose/3`), Settle's unreadable questions
  # (`Apiary.Dispatches.Settle`) and the stage sweep's end (`Apiary.Stages.sweep/3`). The
  # lost-run check tries such a run every 15 s, so a questions file that stays unreadable
  # would write one line per tick for good.
  #
  # The time of each run's last line is kept in the dictionary of the process that wrote
  # it, Liveness's process (`Apiary.Runs.Liveness`) or the projector's, so each process
  # keeps the lines it wrote. A line is written again when its run's detail changes, such
  # as another exception, or an hour after the last. An entry is dropped once its run
  # ends or settles (`clear/1`), and once its last line is an hour old, at the next line
  # the process writes, so the dictionary keeps at most the runs stuck in the last hour.
  @moduledoc false

  require Logger

  @hour 3600

  @typedoc "A kind of line and the id of its run of the queue."
  @type key :: {:lose | :settle | :stage, Ecto.UUID.t()}

  # log/5 writes `message`, a function that makes the line, at `level`, unless the line of
  # `key` with the same `detail` was written less than an hour before `now`, in seconds of
  # the monotonic clock.
  @doc false
  @spec log(:warning | :error, key, term, (-> String.t()), integer) :: :ok
  def log(level, key, detail, message, now \\ System.monotonic_time(:second))
      when is_function(message, 0) do
    last = Map.filter(lines(), fn {_key, {_detail, at}} -> now - at < @hour end)

    case Map.get(last, key) do
      {^detail, _at} ->
        put(last)

      _none_or_other ->
        Logger.log(level, message.())
        put(Map.put(last, key, {detail, now}))
    end
  end

  # clear/1 drops the entry of `key`, for a run whose end or settle went through.
  @doc false
  @spec clear(key) :: :ok
  def clear(key), do: lines() |> Map.delete(key) |> put()

  # The entries this process keeps, for a test.
  @doc false
  @spec lines() :: %{key => {term, integer}}
  def lines, do: Process.get(__MODULE__, %{})

  defp put(lines) when map_size(lines) == 0 do
    Process.delete(__MODULE__)
    :ok
  end

  defp put(lines) do
    Process.put(__MODULE__, lines)
    :ok
  end
end
