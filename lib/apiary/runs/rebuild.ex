defmodule Apiary.Runs.Rebuild do
  @moduledoc """
  Projects every run again from its events, a batch at a time: what `mix apiary.rebuild`
  and `Apiary.Release.rebuild/1` run when the projection is to be made again from the
  record.

  Runs are walked by id, `batch:` runs at a time (default 100), so what reading one batch
  costs is bounded by its runs, however many the table holds. Each run is rebuilt in its
  own transactions by `Apiary.Runs.Projector.rebuild/1`, so the work can be stopped and
  started again, and rebuilding a run twice gives the same rows. A run that fails is
  logged by its id, without any event data, and the walk goes on. Safe beside a running
  server: a rebuild takes the run's projection lock like any projection.

  A run whose events `Apiary.Retention` has deleted is never read, and one that is due to
  be pruned is returned untouched by the projector: a rebuild never wipes a projection
  whose events are gone.
  """

  import Ecto.Query

  require Logger

  alias Apiary.Repo
  alias Apiary.Runs.{Projector, Run}

  @default_batch 100

  @doc "Rebuilds every run whose events are held; returns `%{rebuilt: n, failed: n}`."
  @spec run(keyword()) :: %{rebuilt: non_neg_integer(), failed: non_neg_integer()}
  def run(opts \\ []) do
    batch = opts |> Keyword.get(:batch, @default_batch) |> max(1) |> min(1000)
    walk(batch, nil, %{rebuilt: 0, failed: 0})
  end

  defp walk(batch, after_id, acc) do
    case batch |> page(after_id) |> Repo.all() do
      [] -> acc
      runs -> walk(batch, List.last(runs).id, Enum.reduce(runs, acc, &rebuild/2))
    end
  end

  # The next `batch` runs by id after `after_id` (from the first run when nil). A run whose
  # events retention deleted has nothing to be rebuilt from: never read.
  defp page(batch, after_id) do
    query =
      from r in Run,
        where: is_nil(r.events_pruned_at),
        order_by: r.id,
        limit: ^batch

    if after_id, do: where(query, [r], r.id > ^after_id), else: query
  end

  defp rebuild(%Run{} = run, acc) do
    case Projector.rebuild(run) do
      {:ok, _run} -> %{acc | rebuilt: acc.rebuilt + 1}
      {:error, reason} -> failed(run, reason, acc)
    end
  rescue
    error -> failed(run, error.__struct__, acc)
  end

  defp failed(%Run{id: id}, what, acc) do
    Logger.error("rebuild failed run=#{id} error=#{inspect(what)}")
    %{acc | failed: acc.failed + 1}
  end
end
