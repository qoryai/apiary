defmodule Apiary.Runs.Projector do
  @moduledoc """
  Folds a run's events into what the console reads: the `runs` row, its `connections`,
  its `run_steps`, its `log_chunks` and the workspace's `targets`.

  The receiver stores events and answers; it calls `project_async/1` after its
  transaction has committed. `project/1` is the same work done synchronously: the tests
  call it, and so does `Apiary.Runs.Liveness`, which on every tick projects the runs whose
  events were left unprojected, by a task that died or a node that stopped.

  A pass takes a Postgres advisory transaction lock on the run, so two projections of one
  run never interleave on any node, then locks the run's row, so a lost-run check decided
  meanwhile is seen and not overwritten. It reads the events with
  `projected_at is null` in `sequence` order, folds them (`Apiary.Runs.Fold`), writes the
  result and marks the events projected in the same transaction: an event is folded
  exactly once, and a pass with nothing to fold changes nothing. Events that arrive late
  with a lower sequence are folded when they arrive; the fold decides by sequence alone, so
  the order of arrival does not show in the result, but for one revive that the next
  lost-run check settles (`Apiary.Runs.Fold`, Times).

  One event never blocks a run. The fold is total, and should a pass raise all the same, its
  events are projected one by one and the one that fails is marked projected and named in
  the log by run, sequence and the exception's module.

  `projected_sequence` is the highest sequence up to which every event has been
  projected: it stops before the first gap and moves on when the gap fills.

  A step's row (`Apiary.Runs.Step`) takes the start and the exit with the lowest sequence
  of its number, whichever pass folds them. Once the run's `dev.qory.run.exited` is
  folded, a pass that folds a step event or the exit sets every step of the run without
  an exit to `cancelled`, the contract's state of a step stopped before it ended, and
  leaves its exit columns null: the gateway that ends a run during a step writes no
  `dev.qory.run.step_exited` for it, and the step's outcome stays in the session's record,
  which this server never receives. A step exit folded later sets the step's state
  as the exit says.

  Once its passes have committed, a projection records the run's `last_heartbeat_at` as
  its access key's last heartbeat when it is later than the key's
  (`Apiary.AccessKeys.touch_heartbeat/2`), so the key's is the latest of its runs'.

  Event data is never logged from here: a failure is logged with the run's id and the
  kind of the error, nothing more, and every query that carries event data as a parameter
  is kept out of the query log (`log: false`), which at debug level prints parameters.
  """

  import Ecto.Query

  require Logger

  alias Apiary.AccessKeys
  alias Apiary.Organisations.Workspace
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, Fold, LogChunk, Run, Step, Target}

  # What the fold may change on the run's row. The registration's fields
  # (`Apiary.Runs.Registration`) are not among them, so a rebuild keeps them.
  @folded_fields ~w(
    state forager_version contract_version runtime runtime_version command args
    dir interactive terminal_cols terminal_rows host wall image labels
    about_kind about_title about_subjects about_details
    target_system target_path started_at exited_at exit_code exit_state exit_reason refused_at
    signal reason duration_ms last_heartbeat_at elapsed_seconds heartbeat_interval_seconds
    clock_offset_ms
    policy_digest run_configuration_digest lost_at cost_usd
  )a

  # What `rebuild/1` puts back before projecting again: everything the fold writes,
  # except the two versions, which the receiver also records from the request.
  @rebuilt_fields @folded_fields -- [:state, :forager_version, :contract_version]

  @pass_size 1000
  @heartbeat "dev.qory.run.heartbeat"
  # The events whose pass ends the open steps of a run that exited (`end_open_steps/1`).
  @ending ["dev.qory.run.exited", "dev.qory.run.step_started", "dev.qory.run.step_exited"]
  # The events whose fold may decide what a run of a workspace's queue gave: its exit and
  # its result.
  @settling ["dev.qory.run.exited", "dev.qory.runtime.result"]

  @doc """
  Projects the run's unprojected events. Returns `{:ok, run}` with the run as it is now,
  whether or not there was anything to project.
  """
  @spec project(struct()) :: {:ok, struct()} | {:error, :not_found}
  def project(%Run{} = run), do: project(run, :store_built)

  # A rebuild projects with `:keep_built`: it stores no build (`record_built/3`).
  defp project(%Run{id: id}, built) do
    case passes(id, nil) do
      {:ok, run, nil} ->
        {:ok, run}

      {:ok, run, {first, last}} ->
        touch_heartbeat(run)
        if built == :store_built, do: record_built(run, first, last)
        end_handed_over(run)
        end_refused(run)
        settle_dispatched(run, first, last)
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
      # The task starts with no Logger metadata: it logs under the run's ids.
      task = fn ->
        Apiary.LogMetadata.put_ids(run.organisation_id, run.workspace_id)
        guarded(run)
      end

      case Task.Supervisor.start_child(Apiary.Runs.TaskSupervisor, task) do
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
  the projections come from `events` alone. A lost run is found lost again by the next
  liveness check.

  A run whose events retention has deleted, or is due to delete (`Apiary.Retention.due_or_pruned?/1`),
  is returned as it is: its projection is all that is left of it, and nothing here deletes
  it. A run that lost only its log events is rebuilt from the rest; its log chunks were
  deleted with them, and `projected_sequence` does not fall back to the first of the gaps
  they left. A rebuild stores no image a prebuild reported (`dev.qory.run.built`): only
  the projection that first folded the report stores it.
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
        run |> project(:keep_built) |> past_the_gaps(before)

      {:ok, _run} ->
        project(run, :keep_built)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The run as it was before the reset, so the caller knows where it stood.
  defp reset(%Run{id: id} = current) do
    Repo.delete_all(from c in Connection, where: c.run_id == ^id)
    Repo.delete_all(from s in Step, where: s.run_id == ^id)
    Repo.delete_all(from l in LogChunk, where: l.run_id == ^id)
    Repo.update_all(from(e in Event, where: e.run_id == ^id), set: [projected_at: nil])

    blank = Map.take(%Run{}, @rebuilt_fields)
    # The starter's outcome is not folded: it decides the state the run starts again from,
    # as it decides it after every pass (`Apiary.Runs.Fold.outcome/1`), and so does an end
    # Qory recorded without one (`Apiary.Runs.Fold.settle/1`).
    blank =
      Map.merge(
        blank,
        Fold.settle(%{current | state: "pending", reason: nil, lost_at: nil})
        |> Map.take([:state, :reason, :lost_at])
      )

    current
    |> Ecto.Changeset.change(blank)
    |> Ecto.Changeset.change(
      projected_sequence: Run.projected_from(current),
      target_id: nil,
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

    with {%Run{} = run, domain} <- locked_run_and_domain(id),
         {:events, _run, [_ | _] = events} <- {:events, run, read.(id)} do
      # The fold reads no database: the workspace it names the target by comes with the
      # run, carrying the domain whose labelling rule names it.
      workspace = %Workspace{id: run.workspace_id, domain: domain}

      fold =
        fold_module().fold(
          %{run | workspace: workspace},
          events,
          latest(run, events),
          projected(run, events)
        )

      run =
        run
        |> Ecto.Changeset.change(Map.take(fold.run, @folded_fields))
        |> Ecto.Changeset.change(denied_count: run.denied_count + denied(fold.connections))
        |> put_target(fold.run)
        |> Repo.update!(log: false)

      insert_log_chunks(run, fold.log_chunks)
      upsert_connections(run, fold.connections)
      upsert_steps(run, fold.steps)
      if Enum.any?(events, &(&1.type in @ending)), do: end_open_steps(run)
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

  # The run, locked, and its workspace's domain in the same statement. A scalar subquery,
  # not a join: `FOR UPDATE` locks the run's row only, never the workspace's.
  defp locked_run_and_domain(id) do
    Repo.one(
      from r in Run,
        where: r.id == ^id,
        lock: "FOR UPDATE",
        select: {r, fragment("(SELECT domain FROM workspaces WHERE id = ?)", r.workspace_id)}
    )
  end

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
  # sequence index backwards to the last such event: a heartbeat back, for a heartbeat,
  # of the instance whose heartbeats count (`Apiary.Runs.Fold.liveness_instance/1`).
  defp latest(%Run{} = run, events) do
    ranks =
      events |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.flat_map(&Fold.ranks/1) |> Enum.uniq()

    for rank <- ranks, sequence = last_projected(run, rank), into: %{} do
      {rank, sequence}
    end
  end

  # What the fold needs of the run's events already projected (`Apiary.Runs.Fold`), read
  # only for a pass that holds a heartbeat, which can lower the run's clock offset: the
  # time and arrival of its heartbeat with the highest sequence, which a lower offset
  # counts again.
  defp projected(run, events) do
    %{beat: if(Enum.any?(events, &(&1.type == @heartbeat)), do: last_beat(run))}
  end

  defp last_beat(%Run{id: id} = run) do
    Repo.one(
      from e in counted(run),
        where: e.run_id == ^id and e.type == @heartbeat and not is_nil(e.projected_at),
        order_by: [desc: e.sequence],
        limit: 1,
        select: %{time: e.time, received_at: e.received_at}
    )
  end

  # The events whose heartbeats count towards the run's liveness: every one, but for a run
  # through a gateway whose attaching instance is known, whose heartbeats count from that
  # instance and from every event stored with no instance id alone.
  defp counted(run) do
    case Fold.liveness_instance(run) do
      nil ->
        Event

      instance_id ->
        from e in Event, where: is_nil(e.node_instance_id) or e.node_instance_id == ^instance_id
    end
  end

  # One `UPDATE` by the key's id, which changes nothing when the key holds a later one.
  # After the commit, it never fails the projection: a failure is logged by run and the
  # kind of the error.
  defp touch_heartbeat(%Run{access_key_id: key_id, last_heartbeat_at: %DateTime{} = at} = run)
       when is_binary(key_id) do
    AccessKeys.touch_heartbeat(key_id, at)
  rescue
    error -> log_touch_failure(run, error.__struct__)
  catch
    kind, _reason -> log_touch_failure(run, kind)
  end

  defp touch_heartbeat(_run), do: :ok

  # A run of a workspace's queue whose passes folded the `dev.qory.run.built` that counts,
  # its lowest sequence, has the image it reports stored, once its passes have committed
  # and before its end, in a separate transaction that holds the environment record of a
  # prebuild (`Apiary.Dispatches.Built.record/1`), which stores nothing for a run that is
  # not a prebuild. Only that pass stores it: a later pass, with a second report or
  # without one, and a rebuild of the projection (`rebuild/1`) store nothing, so an image
  # cleared since because the registry lost it (`Apiary.Environments.forget_image/3`) is
  # not stored again. A failure is logged by run and the kind of the error, and the image
  # is not stored.
  defp record_built(%Run{id: id, dispatch_run_id: dispatch_run_id} = run, first, last)
       when is_binary(dispatch_run_id) do
    counted =
      Repo.one(
        from e in Event,
          where: e.run_id == ^id and e.type == ^Apiary.Dispatches.Built.type(),
          select: min(e.sequence)
      )

    if is_integer(counted) and counted >= first and counted <= last,
      do: Apiary.Dispatches.Built.record(run)

    :ok
  rescue
    error -> log_failure(run, {:built, error.__struct__})
  end

  defp record_built(_run, _first, _last), do: :ok

  # A run a workspace's queue handed over whose pass folded its exit ends the queue's run
  # with it, once its passes have committed, in a separate transaction that locks the
  # queue's run before the registered run, after its work item or, for a prebuild, its
  # environment record (`Apiary.Dispatches.RunEnd.run_ended/1`); the workspaces whose
  # slots changed are told. A failure is logged and the lost-run check ends it at its next
  # tick (`Apiary.Dispatches.RunEnd.lose/1`).
  defp end_handed_over(%Run{dispatch_run_id: id, exited_at: %DateTime{}} = run)
       when is_binary(id) do
    run |> Apiary.Dispatches.RunEnd.run_ended() |> Apiary.Dispatches.broadcast()
  rescue
    error -> log_failure(run, {:run_end, error.__struct__})
  end

  defp end_handed_over(_run), do: :ok

  # A run a workspace's queue handed over whose passes folded a refusal, `dev.qory.run.refused`,
  # and no exit, ends the queue's run with it, `run_refused`, once its passes have
  # committed, in a separate transaction that locks the queue's run first
  # (`Apiary.Dispatches.RunEnd.refused/1`). A failure is logged and the lost-run check ends
  # it at its next tick (`Apiary.Dispatches.RunEnd.lose/1`).
  defp end_refused(%Run{dispatch_run_id: id, refused_at: %DateTime{}} = run)
       when is_binary(id) do
    run |> Apiary.Dispatches.RunEnd.refused() |> Apiary.Dispatches.broadcast()
  rescue
    error -> log_failure(run, {:run_refused, error.__struct__})
  end

  defp end_refused(_run), do: :ok

  # A run a workspace's queue handed over whose passes folded an exit or a result event
  # has what it gave stored on the queue's run, once its passes and its end committed, in
  # a separate transaction (`Apiary.Dispatches.Settle.settle/1`): a result that came
  # after its outcome, or after it settled, counts so. The work item is told. A failure is
  # logged, and what the queue's run holds is cleared (`Apiary.Dispatches.Settle.clear/1`),
  # so the sweep of the lost-run check stores it at a tick after, once the run is settled;
  # a clear that fails too is logged, and what was stored stays until the run's next
  # settle.
  defp settle_dispatched(%Run{id: id, dispatch_run_id: dispatch_run_id} = run, first, last)
       when is_binary(dispatch_run_id) do
    settling? =
      Repo.exists?(
        from e in Event,
          where: e.run_id == ^id and e.sequence >= ^first and e.sequence <= ^last,
          where: e.type in ^@settling
      )

    if settling?,
      do: dispatch_run_id |> Apiary.Dispatches.Settle.settle() |> Apiary.Dispatches.broadcast()

    :ok
  rescue
    error ->
      log_failure(run, {:settle, error.__struct__})
      clear_settled(run)
  end

  defp settle_dispatched(_run, _first, _last), do: :ok

  defp clear_settled(%Run{dispatch_run_id: dispatch_run_id} = run) do
    dispatch_run_id |> Apiary.Dispatches.Settle.clear() |> Apiary.Dispatches.broadcast()
  rescue
    error -> log_failure(run, {:settle_clear, error.__struct__})
  end

  defp log_touch_failure(%Run{id: id}, what) do
    Logger.error("key heartbeat not recorded run=#{id} error=#{inspect(what)}")
    :ok
  end

  defp last_projected(%Run{id: id} = run, rank) do
    types = Fold.rank_types(rank)
    events = if rank == @heartbeat, do: counted(run), else: Event

    Repo.one(
      from e in events,
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

  defp put_target(changeset, %{target_system: system, target_path: path})
       when is_binary(system) and is_binary(path) and system != "" and path != "" do
    run = changeset.data

    # A target seen before keeps its row, and so its public id.
    :ok =
      Target.insert_new(run.organisation_id, run.workspace_id, [%{system: system, path: path}])

    target_id =
      Repo.one!(
        from(t in Target,
          where: t.workspace_id == ^run.workspace_id and t.system == ^system and t.path == ^path,
          select: t.id
        ),
        log: false
      )

    Ecto.Changeset.change(changeset, target_id: target_id)
  end

  defp put_target(changeset, _run), do: changeset

  defp insert_log_chunks(_run, []), do: :ok

  defp insert_log_chunks(run, chunks) do
    rows =
      for chunk <- chunks do
        Map.merge(chunk, %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
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
      for {{host, port, path, channel}, delta} <- connections do
        Map.merge(delta, %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          channel: channel,
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
              ),
            last_tool:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_tool ELSE ? END",
                c.last_sequence,
                c.last_tool
              ),
            last_status:
              fragment(
                "CASE WHEN EXCLUDED.last_sequence > ? THEN EXCLUDED.last_status ELSE ? END",
                c.last_sequence,
                c.last_status
              )
          ]
        ]

    Repo.insert_all(Connection, rows,
      on_conflict: on_conflict,
      conflict_target: [:run_id, :channel, :host, :port, :path],
      log: false
    )
  end

  # The incoming row's `column` when the incoming row has a `sequence` and the stored row
  # has none or a higher one; else the stored row's. A macro, because a fragment's text is
  # fixed at compile time.
  defmacrop lower_wins(row, sequence, column) do
    sql =
      "CASE WHEN EXCLUDED.#{sequence} IS NOT NULL AND (? IS NULL OR EXCLUDED.#{sequence} < ?) " <>
        "THEN EXCLUDED.#{column} ELSE ? END"

    quote do
      fragment(
        unquote(sql),
        field(unquote(row), unquote(sequence)),
        field(unquote(row), unquote(sequence)),
        field(unquote(row), unquote(column))
      )
    end
  end

  defp upsert_steps(_run, steps) when map_size(steps) == 0, do: :ok

  defp upsert_steps(run, steps) do
    rows =
      for {step, delta} <- steps do
        Map.merge(delta, %{
          id: Ecto.UUID.generate(),
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          step: step,
          state: delta.state || "running"
        })
      end

    # Every right-hand side reads the row as it was before the update: the start's columns
    # follow the start with the lower sequence, the exit's the exit with the lower sequence,
    # and the state changes with an exit alone.
    on_conflict =
      from s in Step,
        update: [
          set: [
            name: lower_wins(s, :started_sequence, :name),
            kind: lower_wins(s, :started_sequence, :kind),
            started_at: lower_wins(s, :started_sequence, :started_at),
            started_sequence: lower_wins(s, :started_sequence, :started_sequence),
            state: lower_wins(s, :exited_sequence, :state),
            exit_code: lower_wins(s, :exited_sequence, :exit_code),
            duration_ms: lower_wins(s, :exited_sequence, :duration_ms),
            exited_at: lower_wins(s, :exited_sequence, :exited_at),
            exited_sequence: lower_wins(s, :exited_sequence, :exited_sequence)
          ]
        ]

    Repo.insert_all(Step, rows,
      on_conflict: on_conflict,
      conflict_target: [:run_id, :step],
      log: false
    )
  end

  # The steps of a run that exited and that have no exit of their own are cancelled.
  defp end_open_steps(%Run{exited_at: %DateTime{}, id: id}) do
    Repo.update_all(
      from(s in Step,
        where: s.run_id == ^id and is_nil(s.exited_sequence) and s.state == "running"
      ),
      set: [state: "cancelled"]
    )

    :ok
  end

  defp end_open_steps(_run), do: :ok

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
