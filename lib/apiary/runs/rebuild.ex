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
  before those were folded. `all: true` rebuilds every run.

  Runs are walked by id in windows of `batch:` runs (default 100); what reading a window
  costs is bounded by its runs, however many the table holds. Of a window, the runs that
  need it are rebuilt, each in its own transactions by `Apiary.Runs.Projector.rebuild/1`,
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
    case window(batch, after_id) do
      nil ->
        acc

      upper ->
        acc = all? |> page(after_id, upper) |> Repo.all() |> Enum.reduce(acc, &rebuild/2)
        walk(all?, batch, upper, acc)
    end
  end

  # The id of the last of the next `batch` runs, or nil when none is left: a page is read
  # in the window of ids after `after_id` up to it, so what a page costs is bounded by the
  # runs of its window whatever the table holds.
  defp window(batch, after_id) do
    ids =
      from r in Run,
        where: is_nil(r.events_pruned_at),
        order_by: r.id,
        limit: ^batch,
        select: r.id

    ids = if after_id, do: where(ids, [r], r.id > ^after_id), else: ids
    ids |> Repo.all() |> List.last()
  end

  defp page(all?, after_id, upper) do
    # A run whose events retention deleted has nothing to be rebuilt from: never selected.
    query =
      in_window(
        from(r in Run, where: is_nil(r.events_pruned_at), order_by: r.id),
        :id,
        after_id,
        upper
      )

    if all? do
      query
    else
      # Postgres may read an EXISTS under OR as a hashed subplan: each set below is then
      # built once for the page, from every row its subquery reaches, and not probed per
      # run. So every subquery is held to the window's runs by id as well as to the run,
      # which bounds that build by the window, read on the indexes that lead with
      # `run_id`.
      stale =
        from(c in Connection,
          where: c.run_id == parent_as(:run).id and is_nil(c.last_mode) and c.last_sequence > 0
        )
        |> in_window(:run_id, after_id, upper)

      # A result folded before `cost_usd` existed: the run has one and no cost. Read on
      # the index `events (run_id, type, sequence)`.
      uncosted =
        from(e in Event, where: e.run_id == parent_as(:run).id and e.type == @result)
        |> in_window(:run_id, after_id, upper)

      # A start that reports a size, folded before `terminal_cols` existed. Same index.
      unsized =
        from(e in Event,
          where:
            e.run_id == parent_as(:run).id and e.type == @started and
              not is_nil(fragment("? -> 'terminal'", e.data))
        )
        |> in_window(:run_id, after_id, upper)

      # A connection whose last attempt says a tool or a status the row lacks: folded
      # before `last_tool` and `last_status` existed. Of each connection that lacks either,
      # the one event the row says was its last is read, on the unique index
      # `events (run_id, sequence)`. The test is the fold's own reading of the two keys, so
      # a run the rebuild has done is not selected again.
      untooled =
        from(c in Connection,
          join: e in Event,
          on: e.run_id == c.run_id and e.sequence == c.last_sequence,
          where: c.run_id == parent_as(:run).id and c.last_sequence > 0,
          where: is_nil(c.last_tool) or is_nil(c.last_status),
          where: e.type == @egress,
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
        )
        |> in_window(:run_id, after_id, upper)

      from r in query,
        as: :run,
        where:
          exists(stale) or (is_nil(r.cost_usd) and exists(uncosted)) or
            (is_nil(r.terminal_cols) and exists(unsized)) or exists(untooled)
    end
  end

  # The rows of the runs whose id is in the window: after `after_id` (from the first run
  # when nil) up to `upper`, both by the first binding's `field`.
  defp in_window(query, field, nil, upper), do: where(query, [x], field(x, ^field) <= ^upper)

  defp in_window(query, field, after_id, upper) do
    where(query, [x], field(x, ^field) > ^after_id and field(x, ^field) <= ^upper)
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
