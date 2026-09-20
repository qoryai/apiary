defmodule Apiary.Runs.Fold do
  @moduledoc """
  The pure part of the projection: events in, the run's fields and the rows beside it out.

  `Apiary.Runs.Projector` reads a run's unprojected events in `sequence` order, hands them
  to `fold/3` with the run as it is and writes what comes back. Nothing here touches the
  database, so the rules are testable on plain maps.

  Events are stored as received, so `data` is not trusted to follow its schema: a field of
  the wrong type is read as absent, and an event never makes the fold raise.

  The fold is total. Every integer is read within the range of its column and of its
  meaning (a port, an interval of 1 to 3600 seconds) and every string is cut to a sane
  length; a value outside is read as absent, so nothing the fold returns can fail to be
  written.

  The fold tolerates any order of arrival. What decides between two events is always the
  sequence, never a clock and never the order in which they were folded: `latest` carries,
  per rank, the highest sequence already projected. A rank is a type where one event wins
  (`ranks/0`); `run.started` and `ping` also share the rank of the `runner_version`, which
  the later of the two decides.

  Times: `started_at`, `exited_at` and a connection's first and last seen are the runner's
  own, the record. `last_heartbeat_at` is the moment this server received the heartbeat
  with the highest sequence, because the lost-run check compares it with the server's
  clock and a runner's clock may be anywhere.
  """

  @ping "ai.qory.ping"
  @started "ai.qory.run.started"
  @policy_applied "ai.qory.run.policy_applied"
  @heartbeat "ai.qory.run.heartbeat"
  @log "ai.qory.run.log"
  @egress "ai.qory.run.egress"
  @exited "ai.qory.run.exited"

  @runner_version "runner_version"

  @doc """
  The ranks an event of `type` competes in, which the projector seeds `latest` with; none
  for a type that is folded without ranking.
  """
  def ranks(type) when type in [@ping, @started], do: [type, @runner_version]
  def ranks(type) when type in [@policy_applied, @heartbeat, @exited], do: [type]
  def ranks(_type), do: []

  @doc "The types whose highest projected sequence seeds a rank."
  def rank_types(@runner_version), do: [@ping, @started]
  def rank_types(type), do: [type]

  @int4 2_147_483_647
  @int8 9_223_372_036_854_775_807
  @max_interval 3600
  @text 1024
  @long_text 4096
  @max_args 1024
  @max_labels 64

  @terminal ~w(succeeded failed timed_out)
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

  defp event(acc, %{type: @ping, data: data} = event) do
    acc
    |> ranked(event, &%{&1 | contract_version: integer(data, "contract_version", 0..@int4)})
    |> runner_version(event)
  end

  defp event(acc, %{type: @started, data: data} = event) do
    acc
    |> runner_version(event)
    |> ranked(event, fn run ->
      labels = labels(data)

      run
      |> Map.merge(%{
        runtime: string(data, "runtime"),
        runtime_version: string(data, "runtime_version"),
        command: string(data, "command", @long_text),
        args: strings(data, "args"),
        dir: string(data, "dir", @long_text),
        interactive: boolean(data, "interactive"),
        host: string(data, "host"),
        wall: string(data, "wall"),
        image: string(data, "image"),
        labels: labels,
        task: labels["task"],
        forge: repository_label(data, "forge"),
        repository: repository_label(data, "repository"),
        started_at: event.time
      })
      |> started_state()
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

  # Ordered by sequence, timed by this server: see the moduledoc.
  defp event(acc, %{type: @heartbeat, data: data} = event) do
    ranked(acc, event, fn run ->
      run
      |> Map.merge(%{
        last_heartbeat_at: Map.get(event, :received_at) || event.time,
        elapsed_seconds: integer(data, "elapsed_seconds", 0..@int4),
        heartbeat_interval_seconds: integer(data, "interval_seconds", 1..@max_interval)
      })
      |> revive()
    end)
  end

  defp event(acc, %{type: @log, data: data, sequence: sequence}) do
    with stream when stream in @streams <- string(data, "stream"),
         encoded when is_binary(encoded) <- string(data, "bytes", :infinity),
         {:ok, bytes} <- Base.decode64(encoded) do
      chunk = %{sequence: sequence, stream: stream, bytes: bytes}
      %{acc | log_chunks: [chunk | acc.log_chunks]}
    else
      _ -> %{acc | skipped_log_chunks: acc.skipped_log_chunks + 1}
    end
  end

  defp event(acc, %{type: @egress, data: data, time: time, sequence: sequence}) do
    with host when is_binary(host) <- string(data, "host", 255),
         port when is_integer(port) <- integer(data, "port", 0..65_535) do
      key = {host, port, string(data, "path", @text) || ""}
      decision = string(data, "decision", 64)

      # Events come in sequence order, so within a pass the last one folded is the last.
      seen = %{
        method: string(data, "method", 64),
        last_decision: decision,
        last_rule: string(data, "rule"),
        last_outcome: string(data, "outcome", 64),
        last_mode: string(data, "mode", 64),
        last_path_rule: string(data, "path_rule"),
        last_credential: string(data, "credential"),
        last_request_method: string(data, "request_method", 64),
        last_sequence: sequence
      }

      delta =
        case acc.connections[key] do
          nil ->
            Map.merge(seen, %{
              attempts: 0,
              allowed: 0,
              denied: 0,
              first_seen_at: time,
              last_seen_at: time
            })

          delta ->
            delta
            |> Map.merge(seen)
            |> Map.merge(%{
              first_seen_at: earliest(delta.first_seen_at, time),
              last_seen_at: latest_time(delta.last_seen_at, time)
            })
        end

      delta = %{
        delta
        | attempts: delta.attempts + 1,
          allowed: delta.allowed + if(decision == "allowed", do: 1, else: 0),
          denied: delta.denied + if(decision == "denied", do: 1, else: 0)
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
        exit_code: integer(data, "exit_code", -@int4..@int4),
        signal: string(data, "signal", 64),
        reason: reason,
        duration_ms: integer(data, "duration_ms", 0..@int8)
      })
      |> Map.update!(:state, &exited_state(&1, string(data, "state"), reason))
      |> Map.put(:lost_at, nil)
    end)
  end

  # Session events and types this revision does not know: kept in `events`, marked
  # projected by the projector, nothing folded.
  defp event(acc, _event), do: acc

  @doc "The run state an `ai.qory.run.exited` with this `state` and `reason` means."
  def exit_state("succeeded", _reason), do: "succeeded"
  def exit_state("failed", "timeout"), do: "timed_out"
  def exit_state(_state, _reason), do: "failed"

  defp exited_state("closed", _state, _reason), do: "closed"
  defp exited_state(_current, state, reason), do: exit_state(state, reason)

  defp started_state(%{state: state} = run) when state in @terminal or state == "closed",
    do: run

  defp started_state(run), do: %{run | state: "running", lost_at: nil}

  # `ping` and `run.started` both say the runner's version: the later of the two decides.
  defp runner_version(acc, %{sequence: sequence, data: data}) do
    if sequence > Map.get(acc.latest, @runner_version, 0) do
      %{
        acc
        | run: %{acc.run | runner_version: string(data, "runner_version", 255)},
          latest: Map.put(acc.latest, @runner_version, sequence)
      }
    else
      acc
    end
  end

  # A heartbeat says the run is alive: a lost run runs again, and so does a run whose
  # `run.started` has not arrived yet. An exit or a close is not undone.
  defp revive(%{state: state} = run) when state in ["lost", "pending"],
    do: %{run | state: "running", lost_at: nil}

  defp revive(run), do: run

  # Only the event of its type with the highest sequence decides.
  defp ranked(acc, %{type: type, sequence: sequence}, fun) do
    if sequence > Map.get(acc.latest, type, 0) do
      %{acc | run: fun.(acc.run), latest: Map.put(acc.latest, type, sequence)}
    else
      acc
    end
  end

  defp earliest(a, b), do: if(DateTime.compare(b, a) == :lt, do: b, else: a)
  defp latest_time(a, b), do: if(DateTime.compare(b, a) == :gt, do: b, else: a)

  # `max` is a count of bytes, or `:infinity`, which every integer is below.
  defp string(data, key, max \\ @text) do
    case data do
      %{^key => value} when is_binary(value) -> cut(value, max)
      _ -> nil
    end
  end

  # Cut by bytes, on a character boundary.
  defp cut(value, max) when byte_size(value) <= max, do: value

  defp cut(value, max) do
    value |> binary_part(0, max) |> String.chunk(:valid) |> List.first("")
  end

  defp integer(data, key, range) do
    case data do
      %{^key => value} when is_integer(value) -> if value in range, do: value
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
      %{^key => values} when is_list(values) ->
        values
        |> Stream.filter(&is_binary/1)
        |> Stream.map(&cut(&1, @long_text))
        |> Enum.take(@max_args)

      _ ->
        []
    end
  end

  # The label as sent, whole, or nil: see `Apiary.Runs.Repository.label/1`. A label that
  # cannot name a repository stays in `labels` (cut like the others) and the run is
  # unassigned.
  defp repository_label(data, key) do
    case data do
      %{"labels" => %{^key => value}} -> Apiary.Runs.Repository.label(value)
      _ -> nil
    end
  end

  defp labels(data) do
    case data do
      %{"labels" => %{} = labels} ->
        labels
        |> Enum.filter(fn {key, value} ->
          is_binary(key) and is_binary(value) and byte_size(key) <= 64
        end)
        |> Enum.sort()
        |> Enum.take(@max_labels)
        |> Map.new(fn {key, value} -> {key, cut(value, 256)} end)

      _ ->
        %{}
    end
  end
end
