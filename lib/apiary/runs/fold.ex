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
  the later of the two decides, and `run.started` and `run.resized` share the rank of the
  terminal's size, which the later of them decides: `terminal_cols` and `terminal_rows`
  are the size the record last said, `terminal` of the start on a pseudo-terminal, then
  each resize. A start on pipes reports no size and leaves both null.

  An egress event that names a `tool` is a tool invocation, a request to a host the tool
  serves: it is folded into the destination's connection like any other, and the
  connection's `last_tool` and `last_status` say the tool it was last handed to and what
  answered.

  Times: `started_at`, `exited_at` and a connection's first and last seen are the runner's
  own, the record. `last_heartbeat_at` is the moment this server received the heartbeat
  with the highest sequence, because the lost-run check compares it with the server's
  clock and a runner's clock may be anywhere.
  """

  @ping "dev.qory.ping"
  @started "dev.qory.run.started"
  @policy_applied "dev.qory.run.policy_applied"
  @heartbeat "dev.qory.run.heartbeat"
  @log "dev.qory.run.log"
  @resized "dev.qory.run.resized"
  @egress "dev.qory.run.egress"
  @exited "dev.qory.run.exited"
  @result "dev.qory.session.result"

  @runner_version "runner_version"
  @terminal_rank "terminal"

  # The most a result may say a session cost, in dollars, before the value is read as
  # absent: a runtime's accounting error, not a bill.
  @max_cost Decimal.new(1_000_000_000)

  @doc """
  The ranks an event of `type` competes in, which the projector seeds `latest` with; none
  for a type that is folded without ranking.
  """
  def ranks(@ping), do: [@ping, @runner_version]
  def ranks(@started), do: [@started, @runner_version, @terminal_rank]
  def ranks(@resized), do: [@terminal_rank]
  def ranks(type) when type in [@policy_applied, @heartbeat, @exited], do: [type]
  def ranks(_type), do: []

  @doc "The types whose highest projected sequence seeds a rank."
  def rank_types(@runner_version), do: [@ping, @started]
  def rank_types(@terminal_rank), do: [@started, @resized]
  def rank_types(type), do: [type]

  @int4 2_147_483_647
  @int8 9_223_372_036_854_775_807
  @max_interval 3600
  @text 1024
  @long_text 4096
  @max_args 1024
  @max_labels 64
  @max_cells 65_535
  @statuses 100..599

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
    |> terminal_size(event, terminal(data))
    |> ranked(event, fn run ->
      labels = labels(data)
      target = target(run, data)

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
        target_system: target && target.system,
        target_path: target && target.path,
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

  # A resize that is not a size is nothing: the run keeps the size it had.
  defp event(acc, %{type: @resized, data: data} = event) do
    case size(data) do
      nil -> acc
      size -> terminal_size(acc, event, size)
    end
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
        last_tool: tool(data),
        last_status: integer(data, "status", @statuses),
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

  # The cost a non-interactive session reported is the runtime's own total for the
  # session, its subagents included (`docs/contract-assumptions.md`): every result of the
  # run adds its `cost_usd` to the run's, once, so the run's cost is a sum of totals and
  # never counts a subagent twice. A result without a cost adds nothing and leaves null
  # null: a run that reported no cost is unrecorded, not free.
  defp event(acc, %{type: @result, data: data}) do
    case cost(data) do
      nil -> acc
      cost -> %{acc | run: %{acc.run | cost_usd: add_cost(acc.run.cost_usd, cost)}}
    end
  end

  # Session events and types this revision does not know: kept in `events`, marked
  # projected by the projector, nothing folded.
  defp event(acc, _event), do: acc

  # The tool a request was handed to: a name, never empty. A tool invocation is an egress
  # event like any other; only this key tells it apart.
  defp tool(data) do
    case string(data, "tool", 255) do
      "" -> nil
      tool -> tool
    end
  end

  defp add_cost(nil, cost), do: cost
  defp add_cost(%Decimal{} = sum, cost), do: Decimal.add(sum, cost)

  # A cost is a JSON number, zero or more and below the bound; anything else is absent.
  defp cost(data) do
    case data do
      %{"cost_usd" => value} when is_integer(value) -> bounded_cost(Decimal.new(value))
      %{"cost_usd" => value} when is_float(value) -> bounded_cost(Decimal.from_float(value))
      _ -> nil
    end
  end

  defp bounded_cost(%Decimal{} = cost) do
    if Decimal.compare(cost, 0) != :lt and Decimal.compare(cost, @max_cost) == :lt,
      do: Decimal.normalize(cost)
  end

  @doc "The run state an `dev.qory.run.exited` with this `state` and `reason` means."
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

  # `run.started` and `run.resized` both say the terminal's size: the later decides. A
  # start says none on pipes, which is `{nil, nil}`.
  defp terminal_size(acc, %{sequence: sequence}, {cols, rows}) do
    if sequence > Map.get(acc.latest, @terminal_rank, 0) do
      %{
        acc
        | run: %{acc.run | terminal_cols: cols, terminal_rows: rows},
          latest: Map.put(acc.latest, @terminal_rank, sequence)
      }
    else
      acc
    end
  end

  # The size a start reports: `terminal`, or none on pipes.
  defp terminal(%{"terminal" => %{} = terminal}), do: size(terminal) || {nil, nil}
  defp terminal(_data), do: {nil, nil}

  # Both of `cols` and `rows`, each an integer a terminal can be, or nil.
  defp size(data) do
    with cols when is_integer(cols) <- integer(data, "cols", 1..@max_cells),
         rows when is_integer(rows) <- integer(data, "rows", 1..@max_cells) do
      {cols, rows}
    else
      _ -> nil
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

  # The target the labels as sent name, whole, by the hive's body (`Apiary.Body`), or nil.
  # Labels that name no target stay in `labels` (cut like the others) and the run is
  # unassigned.
  defp target(run, %{"labels" => labels}) do
    case Apiary.Body.target(Map.get(run, :hive_id), labels) do
      {:ok, target} -> target
      :none -> nil
    end
  end

  defp target(_run, _data), do: nil

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
