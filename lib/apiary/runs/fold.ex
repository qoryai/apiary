defmodule Apiary.Runs.Fold do
  @moduledoc """
  The pure part of the projection: events in, the run's fields and the rows beside it out.

  `Apiary.Runs.Projector` reads a run's unprojected events in `sequence` order, hands them
  to `fold/3` with the run as it is and writes what comes back. Nothing here touches the
  database, so the rules are testable on plain maps.

  Events are stored as received, so `data` is not trusted to follow its schema: a field of
  the wrong type is read as absent, and an event never makes the fold raise.

  The fold tolerates any order of arrival. What decides between two events of one type is
  the sequence (`latest`, the highest sequence already projected per type) or the event's
  time (heartbeats, connections), never the order in which they were folded.
  """

  @ping "ai.qory.ping"
  @started "ai.qory.run.started"
  @policy_applied "ai.qory.run.policy_applied"
  @heartbeat "ai.qory.run.heartbeat"
  @log "ai.qory.run.log"
  @egress "ai.qory.run.egress"
  @exited "ai.qory.run.exited"

  @doc "The types whose highest projected sequence the projector passes in as `latest`."
  def ranked_types, do: [@started, @policy_applied, @exited]

  @terminal ~w(exited failed timed_out)
  @streams ~w(terminal stdout stderr)

  defstruct run: %{},
            latest: %{},
            connections: %{},
            log_chunks: [],
            skipped_log_chunks: 0

  @type t :: %__MODULE__{
          run: map(),
          latest: %{optional(String.t()) => integer()},
          connections: %{optional({String.t(), integer(), String.t()}) => map()},
          log_chunks: [map()],
          skipped_log_chunks: non_neg_integer()
        }

  @doc """
  Folds `events` (maps with `type`, `time`, `sequence`, `data`) into `run` (any map with
  the run's fields, the schema struct included). `latest` maps a type of `ranked_types/0`
  to the highest sequence of it already projected.

  Returns the accumulator: `run` with the new field values, `connections` as one delta per
  (host, port, path), `log_chunks` in sequence order and the count of log events skipped
  because their bytes were not base64.
  """
  @spec fold(map(), Enumerable.t(), map()) :: t()
  def fold(run, events, latest \\ %{}) do
    acc =
      events
      |> Enum.sort_by(& &1.sequence)
      |> Enum.reduce(%__MODULE__{run: run, latest: latest}, &event(&2, &1))

    %{acc | log_chunks: Enum.reverse(acc.log_chunks)}
  end

  defp event(acc, %{type: @ping, data: data}) do
    update_run(acc, fn run ->
      run
      |> put_present(:runner_version, string(data, "runner_version"))
      |> put_present(:contract_version, integer(data, "contract_version"))
    end)
  end

  defp event(acc, %{type: @started, data: data} = event) do
    ranked(acc, event, fn run ->
      labels = labels(data)

      run
      |> Map.merge(%{
        runtime: string(data, "runtime"),
        runtime_version: string(data, "runtime_version"),
        command: string(data, "command"),
        args: strings(data, "args"),
        dir: string(data, "dir"),
        interactive: boolean(data, "interactive"),
        host: string(data, "host"),
        wall: string(data, "wall"),
        image: string(data, "image"),
        labels: labels,
        task: labels["task"],
        forge: labels["forge"],
        repository: labels["repository"],
        started_at: event.time
      })
      |> put_present(:runner_version, string(data, "runner_version"))
      |> Map.update!(:state, &started_state/1)
    end)
  end

  defp event(acc, %{type: @policy_applied, data: data} = event) do
    ranked(acc, event, fn run ->
      %{
        run
        | policy_digest: string(data, "digest"),
          run_configuration_digest: string(data, "run_configuration")
      }
    end)
  end

  defp event(acc, %{type: @heartbeat, data: data, time: time}) do
    update_run(acc, fn run ->
      if newer_heartbeat?(run, time, integer(data, "elapsed_seconds")) do
        run
        |> Map.put(:last_heartbeat_at, time)
        |> put_present(:elapsed_seconds, integer(data, "elapsed_seconds"))
        |> put_present(:heartbeat_interval_seconds, positive(data, "interval_seconds"))
        |> revive()
      else
        run
      end
    end)
  end

  defp event(acc, %{type: @log, data: data, sequence: sequence}) do
    with stream when stream in @streams <- string(data, "stream"),
         encoded when is_binary(encoded) <- string(data, "bytes"),
         {:ok, bytes} <- Base.decode64(encoded) do
      chunk = %{sequence: sequence, stream: stream, bytes: bytes}
      %{acc | log_chunks: [chunk | acc.log_chunks]}
    else
      _ -> %{acc | skipped_log_chunks: acc.skipped_log_chunks + 1}
    end
  end

  defp event(acc, %{type: @egress, data: data, time: time}) do
    with host when is_binary(host) <- string(data, "host"),
         port when is_integer(port) <- integer(data, "port") do
      key = {host, port, string(data, "path") || ""}
      allowed? = string(data, "decision") == "allowed"
      denied? = string(data, "decision") == "denied"

      seen = %{
        method: string(data, "method"),
        last_decision: string(data, "decision"),
        last_rule: string(data, "rule"),
        last_outcome: string(data, "outcome"),
        last_seen_at: time
      }

      delta =
        case acc.connections[key] do
          nil ->
            Map.merge(seen, %{attempts: 0, allowed: 0, denied: 0, first_seen_at: time})

          %{last_seen_at: last} = delta ->
            delta = %{delta | first_seen_at: earliest(delta.first_seen_at, time)}
            if DateTime.compare(time, last) == :lt, do: delta, else: Map.merge(delta, seen)
        end

      delta = %{
        delta
        | attempts: delta.attempts + 1,
          allowed: delta.allowed + if(allowed?, do: 1, else: 0),
          denied: delta.denied + if(denied?, do: 1, else: 0)
      }

      %{acc | connections: Map.put(acc.connections, key, delta)}
    else
      _ -> acc
    end
  end

  defp event(acc, %{type: @exited, data: data} = event) do
    ranked(acc, event, fn run ->
      reason = string(data, "reason")

      run
      |> Map.merge(%{
        exited_at: event.time,
        exit_code: integer(data, "exit_code"),
        signal: string(data, "signal"),
        reason: reason,
        duration_ms: integer(data, "duration_ms")
      })
      |> Map.update!(:state, &exited_state(&1, string(data, "state"), reason))
      |> Map.put(:lost_at, nil)
    end)
  end

  # Session events and types this revision does not know: kept in `events`, marked
  # projected by the projector, nothing folded.
  defp event(acc, _event), do: acc

  @doc "The run state an `ai.qory.run.exited` with this `state` and `reason` means."
  def exit_state("succeeded", _reason), do: "exited"
  def exit_state("failed", "timeout"), do: "timed_out"
  def exit_state(_state, _reason), do: "failed"

  defp exited_state("closed", _state, _reason), do: "closed"
  defp exited_state(_current, state, reason), do: exit_state(state, reason)

  defp started_state(state) when state in @terminal or state == "closed", do: state
  defp started_state(_state), do: "running"

  # A heartbeat says the run is alive: a lost run runs again, and so does a run whose
  # `run.started` has not arrived yet. An exit or a close is not undone.
  defp revive(%{state: state} = run) when state in ["lost", "pending"],
    do: %{run | state: "running", lost_at: nil}

  defp revive(run), do: run

  defp newer_heartbeat?(%{last_heartbeat_at: nil}, _time, _elapsed), do: true

  defp newer_heartbeat?(%{last_heartbeat_at: last} = run, time, elapsed) do
    case DateTime.compare(time, last) do
      :gt -> true
      :eq -> is_integer(elapsed) and elapsed > (run.elapsed_seconds || -1)
      :lt -> false
    end
  end

  # Only the event of its type with the highest sequence decides.
  defp ranked(acc, %{type: type, sequence: sequence}, fun) do
    if sequence > Map.get(acc.latest, type, 0) do
      %{acc | run: fun.(acc.run), latest: Map.put(acc.latest, type, sequence)}
    else
      acc
    end
  end

  defp update_run(acc, fun), do: %{acc | run: fun.(acc.run)}

  defp put_present(run, _key, nil), do: run
  defp put_present(run, key, value), do: Map.put(run, key, value)

  defp earliest(a, b), do: if(DateTime.compare(b, a) == :lt, do: b, else: a)

  defp string(data, key) do
    case data do
      %{^key => value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp integer(data, key) do
    case data do
      %{^key => value} when is_integer(value) -> value
      _ -> nil
    end
  end

  defp positive(data, key) do
    case integer(data, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp boolean(data, key) do
    case data do
      %{^key => value} when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp strings(data, key) do
    case data do
      %{^key => values} when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp labels(data) do
    case data do
      %{"labels" => %{} = labels} ->
        for {key, value} <- labels, is_binary(key), is_binary(value), into: %{}, do: {key, value}

      _ ->
        %{}
    end
  end
end
