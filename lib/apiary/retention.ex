defmodule Apiary.Retention do
  @moduledoc """
  How long a hive keeps what its runs sent, and the job that deletes what is older.

  **The setting.** A hive has two, each a number of days or nil for unlimited, which is the
  default: `events_retention_days` and `log_retention_days`. Owners change them
  (`update_retention/2`). The log is carried by a run's events, so it is never kept longer
  than they are, and a setting that says otherwise is refused.

  **What is pruned.** Retention works on whole runs, so a timeline is never half there. A
  run is due when it is not alive (`pending` or `running`) and the server last received an
  event of it before the cut-off, by this server's clock alone (`runs.last_event_at`, or
  `inserted_at` for a run that never sent one).

    * Past the log cut-off, the run's `log_chunks` and its `ai.qory.run.log` events are
      deleted and `runs.log_pruned_at` is set. The timeline stays whole.
    * Past the events cut-off, all the run's `events`, its `log_chunks` and its
      `deliveries` are deleted and `runs.events_pruned_at` (and `log_pruned_at`) is set.

  A pruned run takes nothing more: `Apiary.Runs.Ingest` answers `410` for a run whose
  events are pruned, since what a replay would be deduplicated against is gone, and drops
  the log events of a run whose log is pruned.

  The run's row stays, with everything the projector folded into it (state, times, labels,
  exit, `event_count`, `denied_count`), and so do its `connections`: the runs list, the
  hive's connections and the run's header and Connections tab read as before. The run page
  says on which date the events or the log were pruned where they would have been. A run
  whose events are gone can no longer be projected again, so `Apiary.Runs.Projector.rebuild/1`
  and `Apiary.Runs.Rebuild` leave it as it is.

  **The job.** `prune_all/1` takes a Postgres advisory lock, so of several nodes one
  prunes, and walks the hives that have a setting. Every delete is one statement over at
  most `:batch` rows (2,000) of one run, found through the unique indexes on
  `(run_id, sequence)`, in its own short transaction under the run's projection lock: no
  statement scans `events`, and none holds a lock longer than its batch. The runs that are
  due are read through the partial indexes `runs_retention_events_index` and
  `runs_retention_log_index`, which a pruned run leaves. One night prunes at most
  `:max_runs` runs of a hive (10,000) and goes on the next night.

  It says what it did: a `Apiary.Retention.RetentionRun` per hive per run of the job,
  which the settings page lists, and one log line per hive, `retention pruned hive=…`.
  With `dry_run: true` it deletes nothing, writes no record and returns the same counts.
  `Apiary.Retention.Scheduler` runs it nightly; `mix apiary.prune` runs it by hand.
  """

  import Ecto.Query

  require Logger

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations
  alias Apiary.Organisations.Hive
  alias Apiary.Repo
  alias Apiary.Retention.RetentionRun
  alias Apiary.Runs.{Delivery, Event, LogChunk, Projector, Run}

  @log_type "ai.qory.run.log"
  @default_batch 2_000
  @default_max_runs 10_000
  @runs_page 100
  # A scheduled job leaves a hive alone that was pruned less than this long ago: several
  # nodes each have a timer, and the second to get the lock has nothing to add.
  @quiet_hours 12

  @type counts :: %{
          runs_pruned: non_neg_integer(),
          events_deleted: non_neg_integer(),
          log_chunks_deleted: non_neg_integer(),
          log_bytes_deleted: non_neg_integer(),
          deliveries_deleted: non_neg_integer()
        }

  ## The setting

  @doc "A changeset of the hive's retention settings, for the form."
  @spec change_retention(struct(), map()) :: Ecto.Changeset.t()
  def change_retention(%Hive{} = hive, attrs \\ %{}), do: Hive.retention_changeset(hive, attrs)

  @doc "Sets the retention of the scope's hive. Owners only."
  @spec update_retention(struct(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update_retention(%Scope{hive: %Hive{} = hive} = scope, attrs) do
    if Organisations.owner?(scope) do
      hive |> Hive.retention_changeset(attrs) |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc "What the job did to the scope's hive, newest first, at most `limit` (default 10)."
  @spec list_retention_runs(struct(), pos_integer()) :: [RetentionRun.t()]
  def list_retention_runs(
        %Scope{organisation: %{id: organisation_id}, hive: %Hive{id: hive_id}},
        limit \\ 10
      ) do
    Repo.all(
      from r in RetentionRun,
        where: r.organisation_id == ^organisation_id and r.hive_id == ^hive_id,
        order_by: [desc: r.started_at, desc: r.id],
        limit: ^min(max(limit, 1), 100)
    )
  end

  ## The job

  @doc """
  Prunes every hive that has a retention setting and returns one result per hive pruned,
  `%{hive_id:, events_cutoff:, log_cutoff:, complete:, …counts}`; `{:error, :locked}` when
  another node, or another `mix apiary.prune`, holds the job's lock.

  Options: `trigger:` (`"schedule"` or `"manual"`, the default), `dry_run:`, `now:`,
  `batch:` (rows a delete), `max_runs:` (runs of a hive a job). A scheduled job skips a
  hive pruned in the last #{@quiet_hours} hours; a manual one never does.
  """
  @spec prune_all(keyword()) :: {:ok, [map()]} | {:error, :locked}
  def prune_all(opts \\ []) do
    # One connection for the whole job: the advisory lock belongs to the session, and it
    # goes with the connection should this process die.
    Repo.checkout(
      fn ->
        if try_lock() do
          try do
            {:ok, opts |> hives() |> Enum.map(&prune_hive(&1, opts))}
          after
            unlock()
          end
        else
          {:error, :locked}
        end
      end,
      timeout: :infinity
    )
  end

  @doc """
  Prunes one hive under its settings, as `prune_all/1` does for each; the options are the
  same. Takes no job lock: `prune_all/1` is what the scheduler and the task call.
  """
  @spec prune_hive(struct(), keyword()) :: map()
  def prune_hive(%Hive{} = hive, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    dry_run? = Keyword.get(opts, :dry_run, false)
    started_at = DateTime.utc_now()

    events_cutoff = cutoff(now, hive.events_retention_days)
    log_cutoff = cutoff(now, hive.log_retention_days)

    {events_counts, events_complete?} = phase(hive, :events, events_cutoff, opts)
    # The runs past the events cut-off are the first phase's, whether or not it got to them.
    {log_counts, log_complete?} =
      phase(hive, :log, log_cutoff, Keyword.put(opts, :not_before, events_cutoff))

    result =
      events_counts
      |> Map.merge(log_counts, fn _key, a, b -> a + b end)
      |> Map.merge(%{
        hive_id: hive.id,
        events_cutoff: events_cutoff,
        log_cutoff: log_cutoff,
        complete: events_complete? and log_complete?,
        dry_run: dry_run?
      })

    unless dry_run?, do: record(hive, result, started_at, opts)
    result
  end

  @doc """
  True when retention is due to delete the run's events, or already has: a run that
  `Apiary.Runs.Projector.rebuild/1` must leave alone, because a projection rebuilt from a
  record that is going, or gone, would lose what the record gave it.
  """
  @spec due_or_pruned?(struct()) :: boolean()
  def due_or_pruned?(%Run{events_pruned_at: %DateTime{}}), do: true

  def due_or_pruned?(%Run{id: id}) do
    Repo.exists?(
      from r in Run,
        join: h in Hive,
        on: h.id == r.hive_id,
        where: r.id == ^id and not is_nil(h.events_retention_days),
        where: r.state not in ^Run.alive_states(),
        where:
          fragment(
            "COALESCE(?, ?) < now() - make_interval(days => ?)",
            r.last_event_at,
            r.inserted_at,
            h.events_retention_days
          )
    )
  end

  @doc """
  What a result of `prune_hive/2` says in a sentence, for the task's output.
  """
  @spec sentence(map()) :: String.t()
  def sentence(result) do
    verb = if result.dry_run, do: "would prune", else: "pruned"

    "hive #{result.hive_id}: #{verb} #{result.runs_pruned} runs: " <>
      "#{result.events_deleted} events, #{result.log_chunks_deleted} log chunks " <>
      "(#{result.log_bytes_deleted} bytes), #{result.deliveries_deleted} deliveries; " <>
      "events before #{iso(result.events_cutoff)}, log before #{iso(result.log_cutoff)}" <>
      if(result.complete, do: ".", else: "; not finished, the next run goes on.")
  end

  ## One phase over one hive

  defp phase(_hive, _kind, nil, _opts), do: {zero(), true}

  defp phase(hive, kind, cutoff, opts) do
    max_runs = Keyword.get(opts, :max_runs, @default_max_runs)
    walk(hive, kind, cutoff, opts, nil, max_runs, zero())
  end

  defp walk(_hive, _kind, _cutoff, _opts, _after, left, acc) when left <= 0, do: {acc, false}

  defp walk(hive, kind, cutoff, opts, after_key, left, acc) do
    case Repo.all(due(hive, kind, cutoff, opts, after_key, min(left, @runs_page))) do
      [] ->
        {acc, true}

      runs ->
        {acc, failed?} =
          Enum.reduce(runs, {acc, false}, fn run, {acc, failed?} ->
            case prune_run(run, kind, opts) do
              {:ok, counts} -> {add(acc, counts), failed?}
              :error -> {acc, true}
            end
          end)

        last = List.last(runs)

        {acc, complete?} =
          walk(hive, kind, cutoff, opts, {last.age, last.id}, left - length(runs), acc)

        {acc, complete? and not failed?}
    end
  end

  # Read through the partial index of the phase: the hive, the age, the id, and only the
  # runs the phase has not pruned.
  defp due(
         %Hive{id: hive_id, organisation_id: organisation_id},
         kind,
         cutoff,
         opts,
         after_key,
         limit
       ) do
    query =
      from r in Run,
        where: r.hive_id == ^hive_id and r.organisation_id == ^organisation_id,
        where: fragment("COALESCE(?, ?) < ?", r.last_event_at, r.inserted_at, ^cutoff),
        where: r.state not in ^Run.alive_states(),
        order_by: [asc: fragment("COALESCE(?, ?)", r.last_event_at, r.inserted_at), asc: r.id],
        limit: ^limit,
        select: %{
          id: r.id,
          run_id: r.run_id,
          hive_id: r.hive_id,
          age: fragment("COALESCE(?, ?)", r.last_event_at, r.inserted_at)
        }

    query =
      case kind do
        :events -> where(query, [r], is_nil(r.events_pruned_at))
        :log -> where(query, [r], is_nil(r.log_pruned_at))
      end

    query =
      case Keyword.get(opts, :not_before) do
        %DateTime{} = not_before when kind == :log ->
          where(
            query,
            [r],
            fragment("COALESCE(?, ?) >= ?", r.last_event_at, r.inserted_at, ^not_before)
          )

        _none ->
          query
      end

    case after_key do
      nil ->
        query

      {age, id} ->
        where(
          query,
          [r],
          fragment(
            "(COALESCE(?, ?), ?) > (?, ?)",
            r.last_event_at,
            r.inserted_at,
            r.id,
            ^age,
            type(^id, :binary_id)
          )
        )
    end
  end

  ## One run

  defp prune_run(run, kind, opts) do
    if Keyword.get(opts, :dry_run, false),
      do: {:ok, count(run, kind)},
      else: delete(run, kind, opts)
  rescue
    error ->
      # The run's id and the kind of failure only, as everywhere a run's data is near.
      Logger.error("retention failed run=#{run.id} error=#{inspect(error.__struct__)}")
      :error
  end

  defp delete(run, kind, opts) do
    batch = opts |> Keyword.get(:batch, @default_batch) |> max(1) |> min(10_000)

    {chunks, bytes} = delete_log_chunks(run, batch, {0, 0})

    {events, deliveries} =
      case kind do
        :events ->
          {delete_batches(run, events_of(run), batch, 0),
           delete_batches(run, deliveries_of(run), batch, 0)}

        :log ->
          {delete_batches(run, where(events_of(run), [e], e.type == @log_type), batch, 0), 0}
      end

    mark(run, kind)

    {:ok,
     %{
       runs_pruned: 1,
       events_deleted: events,
       log_chunks_deleted: chunks,
       log_bytes_deleted: bytes,
       deliveries_deleted: deliveries
     }}
  end

  defp count(run, kind) do
    {chunks, bytes} =
      Repo.one(
        from l in LogChunk,
          where: l.run_id == ^run.id,
          select: {count(l.id), coalesce(sum(fragment("octet_length(?)", l.bytes)), 0)}
      )

    events =
      case kind do
        :events -> events_of(run)
        :log -> where(events_of(run), [e], e.type == @log_type)
      end

    %{
      runs_pruned: 1,
      events_deleted: Repo.aggregate(events, :count),
      log_chunks_deleted: chunks,
      log_bytes_deleted: to_integer(bytes),
      deliveries_deleted:
        if(kind == :events, do: Repo.aggregate(deliveries_of(run), :count), else: 0)
    }
  end

  defp events_of(run), do: from(e in Event, where: e.run_id == ^run.id)

  defp deliveries_of(run) do
    from d in Delivery, where: d.hive_id == ^run.hive_id and d.run_id == ^run.run_id
  end

  # Log chunks give their size as they go: the bytes are what the setting is about.
  defp delete_log_chunks(run, batch, {chunks, bytes}) do
    ids = from l in LogChunk, where: l.run_id == ^run.id, limit: ^batch, select: l.id

    {:ok, {count, sizes}} =
      Repo.transact(fn ->
        Projector.lock(run.id)

        {:ok,
         Repo.delete_all(
           from l in LogChunk,
             where: l.id in subquery(ids),
             select: fragment("octet_length(?)", l.bytes)
         )}
      end)

    acc = {chunks + count, bytes + Enum.sum(sizes)}
    if count < batch, do: acc, else: delete_log_chunks(run, batch, acc)
  end

  defp delete_batches(run, query, batch, deleted) do
    ids = from q in query, limit: ^batch, select: q.id
    schema = query.from.source |> elem(1)

    {:ok, {count, _}} =
      Repo.transact(fn ->
        Projector.lock(run.id)
        {:ok, Repo.delete_all(from s in schema, where: s.id in subquery(ids))}
      end)

    if count < batch,
      do: deleted + count,
      else: delete_batches(run, query, batch, deleted + count)
  end

  # A log already pruned keeps its date.
  defp mark(run, :events) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(r in Run,
        where: r.id == ^run.id,
        update: [
          set: [
            events_pruned_at: ^now,
            log_pruned_at: fragment("COALESCE(?, ?)", r.log_pruned_at, ^now)
          ]
        ]
      ),
      []
    )
  end

  defp mark(run, :log) do
    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [log_pruned_at: DateTime.utc_now()]
    )
  end

  ## What it says

  defp record(hive, result, started_at, opts) do
    finished_at = DateTime.utc_now()
    trigger = Keyword.get(opts, :trigger, "manual")

    Repo.insert!(%RetentionRun{
      organisation_id: hive.organisation_id,
      hive_id: hive.id,
      trigger: trigger,
      started_at: started_at,
      finished_at: finished_at,
      events_retention_days: hive.events_retention_days,
      log_retention_days: hive.log_retention_days,
      events_cutoff: result.events_cutoff,
      log_cutoff: result.log_cutoff,
      runs_pruned: result.runs_pruned,
      events_deleted: result.events_deleted,
      log_chunks_deleted: result.log_chunks_deleted,
      log_bytes_deleted: result.log_bytes_deleted,
      deliveries_deleted: result.deliveries_deleted,
      complete: result.complete
    })

    Logger.info(
      "retention pruned hive=#{hive.id} trigger=#{trigger} runs=#{result.runs_pruned} " <>
        "events=#{result.events_deleted} log_chunks=#{result.log_chunks_deleted} " <>
        "log_bytes=#{result.log_bytes_deleted} deliveries=#{result.deliveries_deleted} " <>
        "events_cutoff=#{iso(result.events_cutoff)} log_cutoff=#{iso(result.log_cutoff)} " <>
        "complete=#{result.complete} duration_ms=#{DateTime.diff(finished_at, started_at, :millisecond)}"
    )
  end

  defp iso(nil), do: "none"
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  ## The hives and the lock

  defp hives(opts) do
    query =
      from h in Hive,
        where: not is_nil(h.events_retention_days) or not is_nil(h.log_retention_days),
        order_by: h.id

    if Keyword.get(opts, :trigger, "manual") == "schedule" and
         not Keyword.get(opts, :dry_run, false) do
      since = DateTime.add(DateTime.utc_now(), -@quiet_hours * 3600, :second)

      recent =
        from r in RetentionRun,
          where: r.hive_id == parent_as(:hive).id and r.started_at > ^since and r.complete

      Repo.all(from h in query, as: :hive, where: not exists(recent))
    else
      Repo.all(query)
    end
  end

  defp try_lock do
    %{rows: [[locked?]]} =
      Repo.query!("SELECT pg_try_advisory_lock(hashtextextended('apiary:retention', 0))")

    locked?
  end

  defp unlock do
    Repo.query!("SELECT pg_advisory_unlock(hashtextextended('apiary:retention', 0))")
    :ok
  end

  defp cutoff(_now, nil), do: nil
  defp cutoff(now, days), do: DateTime.add(now, -days * 86_400, :second)

  defp zero do
    %{
      runs_pruned: 0,
      events_deleted: 0,
      log_chunks_deleted: 0,
      log_bytes_deleted: 0,
      deliveries_deleted: 0
    }
  end

  defp add(acc, counts), do: Map.merge(acc, counts, fn _key, a, b -> a + b end)

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
end
