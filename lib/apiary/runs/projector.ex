defmodule Apiary.Runs.Projector do
  @moduledoc """
  Folds a run's events into what the console reads: the `runs` row, its `connections`,
  its `log_chunks` and the hive's `repositories`.

  The receiver stores events and answers; it calls `project_async/1` after its
  transaction has committed. `project/1` is the same work done synchronously, for the
  tests and for anything that sweeps up events left unprojected.

  A pass takes a Postgres advisory transaction lock on the run, so two projections of one
  run never interleave on any node, then locks the run's row, so a close or a lost-run
  check decided meanwhile is seen and not overwritten. It reads the events with
  `projected_at is null` in `sequence` order, folds them (`Apiary.Runs.Fold`), writes the
  result and marks the events projected in the same transaction: an event is folded
  exactly once, and a pass with nothing to fold changes nothing. Events that arrive late
  with a lower sequence are folded when they arrive; the fold decides by sequence and by
  the events' own times, so the order of arrival does not show in the result.

  `projected_sequence` is the highest sequence up to which every event has been
  projected: it stops before the first gap and moves on when the gap fills.

  Event data is never logged from here: a failure is logged with the run's id and the
  kind of the error, nothing more.
  """

  import Ecto.Query

  require Logger

  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, Fold, LogChunk, Repository, Run}

  # What the fold may change on the run's row.
  @folded_fields ~w(
    state runner_version contract_version runtime runtime_version command args dir
    interactive host wall image labels task forge repository started_at exited_at exit_code
    signal reason duration_ms last_heartbeat_at elapsed_seconds heartbeat_interval_seconds
    policy_digest run_configuration_digest lost_at
  )a

  # What `rebuild/1` puts back before projecting again: everything the fold writes,
  # except the two versions, which the receiver also records from the request.
  @rebuilt_fields @folded_fields -- [:state, :runner_version, :contract_version]

  @pass_size 1000

  @doc """
  Projects the run's unprojected events. Returns `{:ok, run}` with the run as it is now,
  whether or not there was anything to project.
  """
  @spec project(struct()) :: {:ok, struct()} | {:error, :not_found}
  def project(%Run{id: id}) do
    case passes(id, nil) do
      {:ok, run, nil} ->
        {:ok, run}

      {:ok, run, {first, last}} ->
        Runs.broadcast_projected(run, first, last)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Projects in a supervised task and returns at once. Never raises into the caller and
  never makes it wait; a failure is logged without any event data, and the events stay
  unprojected for the next pass.
  """
  @spec project_async(struct()) :: :ok
  def project_async(%Run{} = run) do
    if inline?() do
      guarded(run)
    else
      case Task.Supervisor.start_child(Apiary.Runs.TaskSupervisor, fn -> guarded(run) end) do
        {:ok, _pid} -> :ok
        {:error, reason} -> log_failure(run, {:not_started, reason})
      end
    end

    :ok
  catch
    # The supervisor is down or restarting: the events wait for the next projection.
    :exit, _reason ->
      log_failure(run, :supervisor_down)
      :ok
  end

  def project_async(_other), do: :ok

  @doc """
  Deletes the run's projections, clears `projected_at` on its events and projects again:
  the projections come from `events` alone. A close is not an event and is kept; a lost
  run is found lost again by the next liveness check.
  """
  @spec rebuild(struct()) :: {:ok, struct()} | {:error, :not_found}
  def rebuild(%Run{id: id} = run) do
    Repo.transact(fn ->
      lock(id)

      case locked_run(id) do
        nil ->
          {:error, :not_found}

        %Run{} = current ->
          Repo.delete_all(from c in Connection, where: c.run_id == ^id)
          Repo.delete_all(from l in LogChunk, where: l.run_id == ^id)
          Repo.update_all(from(e in Event, where: e.run_id == ^id), set: [projected_at: nil])

          blank = Map.take(%Run{}, @rebuilt_fields)
          state = if current.state == "closed", do: "closed", else: "pending"

          current
          |> Ecto.Changeset.change(blank)
          |> Ecto.Changeset.change(state: state, projected_sequence: 0, repository_id: nil)
          |> Repo.update()
      end
    end)
    |> case do
      {:ok, _run} -> project(run)
      {:error, reason} -> {:error, reason}
    end
  end

  defp inline?, do: Application.get_env(:apiary, __MODULE__, [])[:async] == false

  defp guarded(run) do
    case project(run) do
      {:ok, _run} -> :ok
      {:error, reason} -> log_failure(run, reason)
    end
  rescue
    error -> log_failure(run, error.__struct__)
  catch
    kind, _reason -> log_failure(run, kind)
  end

  # The run's id and the kind of failure only: an exception's message can quote a value,
  # and values here are event data.
  defp log_failure(%Run{id: id}, what) do
    Logger.error("projection failed run=#{id} error=#{inspect(what)}")
    :ok
  end

  # One transaction per pass of at most @pass_size events, so a long record, or a rebuild
  # of one, is not held in memory or in one transaction.
  defp passes(id, span) do
    case Repo.transact(fn -> pass(id) end) do
      {:ok, {run, nil}} -> {:ok, run, span}
      {:ok, {_run, {first, last, @pass_size}}} -> passes(id, widen(span, first, last))
      {:ok, {run, {first, last, _count}}} -> {:ok, run, widen(span, first, last)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp widen(nil, first, last), do: {first, last}
  defp widen({a, b}, first, last), do: {min(a, first), max(b, last)}

  defp pass(id) do
    lock(id)

    with %Run{} = run <- locked_run(id),
         {:events, _run, [_ | _] = events} <- {:events, run, unprojected(id)} do
      fold = Fold.fold(run, events, latest(id))

      run =
        run
        |> Ecto.Changeset.change(Map.take(fold.run, @folded_fields))
        |> put_repository(fold.run)
        |> Repo.update!()

      insert_log_chunks(run, fold.log_chunks)
      upsert_connections(run, fold.connections)
      mark_projected(events)

      run =
        run
        |> Ecto.Changeset.change(projected_sequence: contiguous(run))
        |> Repo.update!()

      if fold.skipped_log_chunks > 0 do
        Logger.warning(
          "log chunks skipped run=#{run.id} count=#{fold.skipped_log_chunks} reason=not_base64"
        )
      end

      sequences = Enum.map(events, & &1.sequence)
      {:ok, {run, {Enum.min(sequences), Enum.max(sequences), length(events)}}}
    else
      nil -> {:error, :not_found}
      {:events, run, []} -> {:ok, {run, nil}}
    end
  end

  defp lock(id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["run:" <> id])
  end

  defp locked_run(id), do: Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")

  defp unprojected(id) do
    Repo.all(
      from e in Event,
        where: e.run_id == ^id and is_nil(e.projected_at),
        order_by: e.sequence,
        limit: @pass_size
    )
  end

  # The highest sequence already projected of each type where the highest decides.
  defp latest(id) do
    Repo.all(
      from e in Event,
        where: e.run_id == ^id and not is_nil(e.projected_at) and e.type in ^Fold.ranked_types(),
        group_by: e.type,
        select: {e.type, max(e.sequence)}
    )
    |> Map.new()
  end

  defp put_repository(changeset, %{forge: forge, repository: path})
       when is_binary(forge) and is_binary(path) and forge != "" and path != "" do
    run = changeset.data
    now = DateTime.utc_now()

    Repo.insert_all(
      Repository,
      [
        %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          hive_id: run.hive_id,
          forge: forge,
          path: path,
          first_seen_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:hive_id, :forge, :path]
    )

    repository_id =
      Repo.one!(
        from p in Repository,
          where: p.hive_id == ^run.hive_id and p.forge == ^forge and p.path == ^path,
          select: p.id
      )

    Ecto.Changeset.change(changeset, repository_id: repository_id)
  end

  defp put_repository(changeset, _run), do: changeset

  defp insert_log_chunks(_run, []), do: :ok

  defp insert_log_chunks(run, chunks) do
    rows =
      for chunk <- chunks do
        Map.merge(chunk, %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          hive_id: run.hive_id,
          run_id: run.id
        })
      end

    Repo.insert_all(LogChunk, rows,
      on_conflict: :nothing,
      conflict_target: [:run_id, :sequence]
    )
  end

  defp upsert_connections(_run, connections) when map_size(connections) == 0, do: :ok

  defp upsert_connections(run, connections) do
    rows =
      for {{host, port, path}, delta} <- connections do
        Map.merge(delta, %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          hive_id: run.hive_id,
          run_id: run.id,
          host: host,
          port: port,
          path: path
        })
      end

    # Every right-hand side reads the row as it was before the update, so the comparison
    # of the times decides all four "last" columns together.
    on_conflict =
      from c in Connection,
        update: [
          set: [
            attempts: fragment("? + EXCLUDED.attempts", c.attempts),
            allowed: fragment("? + EXCLUDED.allowed", c.allowed),
            denied: fragment("? + EXCLUDED.denied", c.denied),
            first_seen_at: fragment("LEAST(?, EXCLUDED.first_seen_at)", c.first_seen_at),
            last_seen_at: fragment("GREATEST(?, EXCLUDED.last_seen_at)", c.last_seen_at),
            method:
              fragment(
                "CASE WHEN EXCLUDED.last_seen_at >= ? THEN EXCLUDED.method ELSE ? END",
                c.last_seen_at,
                c.method
              ),
            last_decision:
              fragment(
                "CASE WHEN EXCLUDED.last_seen_at >= ? THEN EXCLUDED.last_decision ELSE ? END",
                c.last_seen_at,
                c.last_decision
              ),
            last_rule:
              fragment(
                "CASE WHEN EXCLUDED.last_seen_at >= ? THEN EXCLUDED.last_rule ELSE ? END",
                c.last_seen_at,
                c.last_rule
              ),
            last_outcome:
              fragment(
                "CASE WHEN EXCLUDED.last_seen_at >= ? THEN EXCLUDED.last_outcome ELSE ? END",
                c.last_seen_at,
                c.last_outcome
              )
          ]
        ]

    Repo.insert_all(Connection, rows,
      on_conflict: on_conflict,
      conflict_target: [:run_id, :host, :port, :path]
    )
  end

  defp mark_projected(events) do
    ids = Enum.map(events, & &1.id)

    Repo.update_all(from(e in Event, where: e.id in ^ids),
      set: [projected_at: DateTime.utc_now()]
    )
  end

  # From where the run stands, the end of the unbroken stretch of projected sequences.
  defp contiguous(%Run{id: id, projected_sequence: from}) do
    next = from + 1

    stretch_end =
      Repo.one(
        from e in Event,
          where: e.run_id == ^id and e.sequence >= ^next and not is_nil(e.projected_at),
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM events n WHERE n.run_id = ? AND n.sequence = ? + 1 AND n.projected_at IS NOT NULL)",
              e.run_id,
              e.sequence
            ),
          select: min(e.sequence)
      )

    starts? =
      Repo.exists?(
        from e in Event,
          where: e.run_id == ^id and e.sequence == ^next and not is_nil(e.projected_at)
      )

    if starts? and is_integer(stretch_end), do: stretch_end, else: from
  end
end
