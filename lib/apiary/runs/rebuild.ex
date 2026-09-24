defmodule Apiary.Runs.Rebuild do
  @moduledoc """
  Projects runs again from their events, a batch at a time: what `mix apiary.rebuild` and
  `Apiary.Release.rebuild/1` run after a release that adds to the projection.

  By default only the runs that need it: those with a connection projected before the
  columns of its last attempt existed (`last_mode` is null on a row that has folded an
  event), those with a session result and no `cost_usd`, projected before the cost was
  folded, those whose `run.started` reports a terminal size and no `terminal_cols`,
  projected before the size was folded, and those with a connection whose last attempt
  names a tool or a status the row does not hold (`last_tool`, `last_status`), projected
  before the tool invocations of contract v1 revision 2 were folded. `all: true` rebuilds
  every run. Runs are walked by id, `batch:` at a time (default 100), each rebuilt in its
  own transactions by `Apiary.Runs.Projector.rebuild/1`, so the work can be stopped and
  started again: a run already rebuilt is not selected the second time, and rebuilding one
  twice gives the same rows. A run that fails is logged by
  its id, without any event data, and the walk goes on. Safe beside a running server: a
  rebuild takes the run's projection lock like any projection.

  A run whose events `Apiary.Retention` has deleted is never selected, and one that is due
  to be pruned is returned untouched by the projector: a rebuild never wipes a projection
  whose events are gone.
  """

  import Ecto.Query

  require Logger

  alias Apiary.Repo
  alias Apiary.Runs.{Connection, Event, Projector, Run}

  @default_batch 100
  @result "dev.qory.session.result"
  @started "dev.qory.run.started"
  @egress "dev.qory.run.egress"

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

      # A result folded before `cost_usd` existed: the run has one and no cost. Read on
      # the index `events (run_id, type, sequence)`, one probe a run.
      uncosted =
        from e in Event,
          where: e.run_id == parent_as(:run).id and e.type == @result

      # A start that reports a size, folded before `terminal_cols` existed. Same index.
      unsized =
        from e in Event,
          where:
            e.run_id == parent_as(:run).id and e.type == @started and
              not is_nil(fragment("? -> 'terminal'", e.data))

      # A connection whose last attempt says a tool or a status the row lacks: folded
      # before `last_tool` and `last_status` existed. One probe of the unique index
      # `events (run_id, sequence)` per connection of the run, at the event the row says
      # was its last; the test is the fold's own reading of the two keys, so a run the
      # rebuild has done is not selected again.
      unrevised =
        from c in Connection,
          join: e in Event,
          on: e.run_id == c.run_id and e.sequence == c.last_sequence,
          where: c.run_id == parent_as(:run).id and c.last_sequence > 0 and e.type == @egress,
          where:
            (is_nil(c.last_tool) and
               fragment(
                 "jsonb_typeof(? -> 'tool') = 'string' AND ? ->> 'tool' <> ''",
                 e.data,
                 e.data
               )) or
              (is_nil(c.last_status) and
                 fragment(
                   "jsonb_typeof(? -> 'status') = 'number' AND (? ->> 'status') ~ '^[1-5][0-9]{2}$'",
                   e.data,
                   e.data
                 ))

      from r in query,
        as: :run,
        where:
          exists(stale) or (is_nil(r.cost_usd) and exists(uncosted)) or
            (is_nil(r.terminal_cols) and exists(unsized)) or exists(unrevised)
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
