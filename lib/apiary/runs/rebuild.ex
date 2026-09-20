defmodule Apiary.Runs.Rebuild do
  @moduledoc """
  Projects runs again from their events, a batch at a time: what `mix apiary.rebuild` and
  `Apiary.Release.rebuild/1` run after a release that adds to the projection.

  By default only the runs that need it: those with a connection projected before the
  columns of its last attempt existed (`last_mode` is null on a row that has folded an
  event). `all: true` rebuilds every run. Runs are walked by id, `batch:` at a time
  (default 100), each rebuilt in its own transactions by `Apiary.Runs.Projector.rebuild/1`,
  so the work can be stopped and started again: a run already rebuilt is not selected the
  second time, and rebuilding one twice gives the same rows. A run that fails is logged by
  its id, without any event data, and the walk goes on. Safe beside a running server: a
  rebuild takes the run's projection lock like any projection.

  A run whose events `Apiary.Retention` has deleted is never selected, and one that is due
  to be pruned is returned untouched by the projector: a rebuild never wipes a projection
  whose events are gone.
  """

  import Ecto.Query

  require Logger

  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Projector, Run}

  @default_batch 100

  @doc "Rebuilds the runs that need it (or all); returns `%{rebuilt: n, failed: n}`."
  @spec run(keyword()) :: %{rebuilt: non_neg_integer(), failed: non_neg_integer()}
  def run(opts \\ []) do
    batch = opts |> Keyword.get(:batch, @default_batch) |> max(1) |> min(1000)
    walk(Keyword.get(opts, :all, false), batch, nil, %{rebuilt: 0, failed: 0})
  end

  defp walk(all?, batch, after_id, acc) do
    case Repo.all(page(all?, batch, after_id)) do
      [] ->
        acc

      runs ->
        acc = Enum.reduce(runs, acc, &rebuild/2)
        walk(all?, batch, List.last(runs).id, acc)
    end
  end

  defp page(all?, batch, after_id) do
    # A run whose events retention deleted has nothing to be rebuilt from: never selected.
    query = from r in Run, where: is_nil(r.events_pruned_at), order_by: r.id, limit: ^batch
    query = if after_id, do: where(query, [r], r.id > ^after_id), else: query

    if all? do
      query
    else
      stale =
        from c in Connection,
          where: c.run_id == parent_as(:run).id and is_nil(c.last_mode) and c.last_sequence > 0

      from r in query, as: :run, where: exists(stale)
    end
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
