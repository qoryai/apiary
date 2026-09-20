defmodule Apiary.Runs.Projector do
  @moduledoc """
  Folds a run's events into what the console reads: the `runs` row, its `connections`,
  its `log_chunks` and the hive's `repositories`.

  The receiver stores events and answers; it calls `project_async/1` after its
  transaction has committed. `project/1` is the same work done synchronously: the tests
  call it, and so does `Apiary.Runs.Liveness`, which on every tick projects the runs whose
  events were left unprojected, by a task that died or a node that stopped.

  A pass takes a Postgres advisory transaction lock on the run, so two projections of one
  run never interleave on any node, then locks the run's row, so a close or a lost-run
  check decided meanwhile is seen and not overwritten. It reads the events with
  `projected_at is null` in `sequence` order, folds them (`Apiary.Runs.Fold`), writes the
  result and marks the events projected in the same transaction: an event is folded
  exactly once, and a pass with nothing to fold changes nothing. Events that arrive late
  with a lower sequence are folded when they arrive; the fold decides by sequence alone, so
  the order of arrival does not show in the result.

  One event never blocks a run. The fold is total, and should a pass raise all the same, its
  events are projected one by one and the one that fails is marked projected and named in
  the log by run, sequence and the exception's module.

  `projected_sequence` is the highest sequence up to which every event has been
  projected: it stops before the first gap and moves on when the gap fills.

  Event data is never logged from here: a failure is logged with the run's id and the
  kind of the error, nothing more, and every query that carries event data as a parameter
  is kept out of the query log (`log: false`), which at debug level prints parameters.
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

  A run whose events retention has deleted, or is due to delete (`Apiary.Retention.due_or_pruned?/1`),
  is returned as it is: its projection is all that is left of it, and nothing here deletes
  it. A run that lost only its log events is rebuilt from the rest; its log chunks were
  deleted with them, and `projected_sequence` does not fall back to the first of the gaps
  they left.
  """
  @spec rebuild(struct()) :: {:ok, struct()} | {:error, :not_found}
  def rebuild(%Run{id: id} = run) do
    Repo.transact(fn ->
      lock(id)

      case locked_run(id) do
        nil ->
          {:error, :not_found}

        %Run{} = current ->
          if Apiary.Retention.due_or_pruned?(current),
            do: {:ok, {:kept, current}},
            else: reset(current)
      end
    end)
    |> case do
      {:ok, {:kept, current}} ->
        {:ok, current}

      {:ok, %Run{log_pruned_at: %DateTime{}} = before} ->
        run |> project() |> past_the_gaps(before)

      {:ok, _run} ->
        project(run)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The run as it was before the reset, so the caller knows where it stood.
  defp reset(%Run{id: id} = current) do
    Repo.delete_all(from c in Connection, where: c.run_id == ^id)
    Repo.delete_all(from l in LogChunk, where: l.run_id == ^id)
    Repo.update_all(from(e in Event, where: e.run_id == ^id), set: [projected_at: nil])

    blank = Map.take(%Run{}, @rebuilt_fields)
    state = if current.state == "closed", do: "closed", else: "pending"

    current
    |> Ecto.Changeset.change(blank)
    |> Ecto.Changeset.change(
      state: state,
      projected_sequence: 0,
      repository_id: nil,
      denied_count: 0
    )
    |> Repo.update()
    |> case do
      {:ok, _reset} -> {:ok, current}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # The log events retention deleted left gaps no event will fill.
  defp past_the_gaps({:ok, %Run{} = run}, %Run{projected_sequence: stood})
       when stood > run.projected_sequence do
    run |> Ecto.Changeset.change(projected_sequence: stood) |> Repo.update()
  end

  defp past_the_gaps(result, _before), do: result

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
    case guarded_pass(id) do
      {:ok, {run, nil}} -> {:ok, run, span}
      {:ok, {_run, {first, last, @pass_size}}} -> passes(id, widen(span, first, last))
      {:ok, {run, {first, last, _count}}} -> {:ok, run, widen(span, first, last)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp widen(nil, first, last), do: {first, last}
  defp widen({a, b}, first, last), do: {min(a, first), max(b, last)}

  defp guarded_pass(id) do
    Repo.transact(fn -> pass(id, &unprojected/1) end)
  rescue
    _error -> one_by_one(id)
  end

  # The pass raised and rolled back. Project its events one at a time, each in its own
  # transaction; the one that raises again is marked projected unfolded, so the pass
  # after this one is not the same pass again.
  defp one_by_one(id) do
    events = Repo.all(from e in unprojected_query(id), select: {e.id, e.sequence})

    Enum.each(events, fn {event_id, sequence} ->
      try do
        Repo.transact(fn -> pass(id, fn _id -> unprojected_event(event_id) end) end)
      rescue
        error ->
          Logger.error(
            "event skipped run=#{id} sequence=#{sequence} error=#{inspect(error.__struct__)}"
          )

          Repo.transact(fn ->
            lock(id)
            mark_projected([event_id])
            {:ok, :skipped}
          end)
      end
    end)

    case {events, Repo.get(Run, id)} do
      {_events, nil} ->
        {:error, :not_found}

      {[], run} ->
        {:ok, {run, nil}}

      {events, run} ->
        sequences = Enum.map(events, &elem(&1, 1))
        run = advance(run)
        {:ok, {run, {Enum.min(sequences), Enum.max(sequences), length(events)}}}
    end
  end

  # After events were skipped nothing has moved `projected_sequence` over them.
  defp advance(%Run{id: id}) do
    {:ok, run} =
      Repo.transact(fn ->
        lock(id)
        run = locked_run(id)

        run
        |> Ecto.Changeset.change(projected_sequence: contiguous(run))
        |> Repo.update()
      end)

    run
  end

  defp pass(id, read) do
    lock(id)

    with %Run{} = run <- locked_run(id),
         {:events, _run, [_ | _] = events} <- {:events, run, read.(id)} do
      fold = fold_module().fold(run, events, latest(id, events))

      run =
        run
        |> Ecto.Changeset.change(Map.take(fold.run, @folded_fields))
        |> Ecto.Changeset.change(denied_count: run.denied_count + denied(fold.connections))
        |> put_repository(fold.run)
        |> Repo.update!(log: false)

      insert_log_chunks(run, fold.log_chunks)
      upsert_connections(run, fold.connections)
      mark_projected(Enum.map(events, & &1.id))

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

  # The fold is replaceable so that a test can make a pass raise; nothing else sets it.
  defp fold_module, do: Application.get_env(:apiary, __MODULE__, [])[:fold] || Fold

  @doc """
  Takes the run's projection lock for the rest of the transaction. `Apiary.Retention`
  deletes a run's rows under it, so a delete and a projection never interleave.
  """
  @spec lock(Ecto.UUID.t()) :: :ok
  def lock(id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["run:" <> id])
    :ok
  end

  defp locked_run(id), do: Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")

  defp unprojected(id), do: Repo.all(unprojected_query(id))

  defp unprojected_query(id) do
    from e in Event,
      where: e.run_id == ^id and is_nil(e.projected_at),
      order_by: e.sequence,
      limit: @pass_size
  end

  defp unprojected_event(event_id) do
    Repo.all(from e in Event, where: e.id == ^event_id and is_nil(e.projected_at))
  end

  # The highest sequence already projected in each rank this pass's events compete in.
  # Most passes hold logs and egress only and ask nothing. One that asks walks the run's
  # sequence index backwards to the last such event: a heartbeat back, for a heartbeat.
  defp latest(id, events) do
    ranks =
      events |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.flat_map(&Fold.ranks/1) |> Enum.uniq()

    for rank <- ranks, sequence = last_projected(id, Fold.rank_types(rank)), into: %{} do
      {rank, sequence}
    end
  end

  defp last_projected(id, types) do
    Repo.one(
      from e in Event,
        where: e.run_id == ^id and e.type in ^types and not is_nil(e.projected_at),
        order_by: [desc: e.sequence],
        limit: 1,
        select: e.sequence
    )
  end

  # An egress event is folded exactly once, so the run's count of denials is the sum of
  # what each pass adds: the same number as the sum of its connections' `denied`.
  defp denied(connections) do
    connections |> Map.values() |> Enum.map(& &1.denied) |> Enum.sum()
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
      conflict_target: [:hive_id, :forge, :path],
      log: false
    )

    repository_id =
      Repo.one!(
        from(p in Repository,
          where: p.hive_id == ^run.hive_id and p.forge == ^forge and p.path == ^path,
          select: p.id
        ),
        log: false
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
      conflict_target: [:run_id, :sequence],
      log: false
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
    # of the sequences decides the "last" columns and `last_sequence` together.
    on_conflict =
      from c in Connection,
        update: [
          set: [
            attempts: fragment("? + EXCLUDED.attempts", c.attempts),
            allowed: fragment("? + EXCLUDED.allowed", c.allowed),
            denied: fragment("? + EXCLUDED.denied", c.denied),
            first_seen_at: fragment("LEAST(?, EXCLUDED.first_seen_at)", c.first_seen_at),
            last_seen_at: fragment("GREATEST(?, EXCLUDED.last_seen_at)", c.last_seen_at),
            last_sequence: fragment("GREATEST(?, EXCLUDED.last_sequence)", c.last_sequence),
            method:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.method ELSE ? END",
                c.last_sequence,
                c.method
              ),
            last_decision:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_decision ELSE ? END",
                c.last_sequence,
                c.last_decision
              ),
            last_rule:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_rule ELSE ? END",
                c.last_sequence,
                c.last_rule
              ),
            last_outcome:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_outcome ELSE ? END",
                c.last_sequence,
                c.last_outcome
              ),
            last_mode:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_mode ELSE ? END",
                c.last_sequence,
                c.last_mode
              ),
            last_path_rule:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_path_rule ELSE ? END",
                c.last_sequence,
                c.last_path_rule
              ),
            last_credential:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_credential ELSE ? END",
                c.last_sequence,
                c.last_credential
              ),
            last_request_method:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_request_method ELSE ? END",
                c.last_sequence,
                c.last_request_method
              )
          ]
        ]

    Repo.insert_all(Connection, rows,
      on_conflict: on_conflict,
      conflict_target: [:run_id, :host, :port, :path],
      log: false
    )
  end

  defp mark_projected(ids) do
    Repo.update_all(from(e in Event, where: e.id in ^ids),
      set: [projected_at: DateTime.utc_now()]
    )
  end

  # From where the run stands, the end of the unbroken stretch of projected sequences,
  # read a page at a time from the sequence index: the cost is the length of the advance.
  @page 1000

  defp contiguous(%Run{id: id, projected_sequence: from}) do
    sequences =
      Repo.all(
        from e in Event,
          where: e.run_id == ^id and e.sequence > ^from and not is_nil(e.projected_at),
          order_by: e.sequence,
          limit: @page,
          select: e.sequence
      )

    reached =
      Enum.reduce_while(sequences, from, fn
        sequence, reached when sequence == reached + 1 -> {:cont, sequence}
        _sequence, reached -> {:halt, reached}
      end)

    if reached == from + @page,
      do: contiguous(%Run{id: id, projected_sequence: reached}),
      else: reached
  end
end
