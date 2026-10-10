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
  sequence, never a clock and never the order in which they were folded, but for one
  revive (Times, below): `latest` carries,
  per rank, the highest sequence already projected. A rank is a type where one event wins
  (`ranks/0`); `run.started` and `ping` also share the rank of the `forager_version`, which
  the later of the two decides, and `run.started` and `run.resized` share the rank of the
  terminal's size, which the later of them decides: `terminal_cols` and `terminal_rows`
  are the size the record last said, `terminal` of the start on a pseudo-terminal, then
  each resize. A start on pipes reports no size and leaves both null.

  An egress event names a `tool` when the proxy decided the request by its path for a host
  the tool serves. It is folded into the destination's connection like any other, and the
  connection's `last_tool` and `last_status` say the tool whose host the last attempt was
  for and what answered it. The attempt is a tool invocation only when it was also
  allowed (`Apiary.Runs.tool_invocation?/2`); one a path rule refused keeps its tool, and
  never reached it.

  What a run is about is `about` of its `run.started`, read member by member
  (`Apiary.Runs.About.read/1`). No string of it, key or value, may hold a control
  character (U+0000 to U+001F, U+007F to U+009F, U+2028, U+2029). `kind` (1 to 64 bytes), `title` (1 to 256) and `details` are each kept
  whole or dropped whole. `details` is an object of at most 8192 bytes as the event carries
  it (compact, with `<`, `>` and `&` written as `\\u003c`, `\\u003e` and `\\u0026`), nested
  at most 4 levels deep, each key at any level 1 to 64 bytes; a key or a string that
  breaks a rule anywhere in it drops it whole. A member name given twice in `details`
  cannot be seen once the event is decoded, which keeps the last; Forager refuses it
  before it sends. A subject is kept when its `type` matches `^[a-z0-9]+([ _.-][a-z0-9]+)*$`
  in at most 64 bytes and its `ref` is 1 to 256 bytes; its `title` (1 to 256 bytes) and
  `url` (at most 2048 bytes, absolute `http` or `https` with a host and no user name or
  password) are dropped from it alone when they break their rules. Of the subjects kept,
  the first of each type and ref stays, at most 16 in the order given. An `about` that is
  not an object says nothing.

  What opened the run is `opened_by` of its `run.started`, `session` or `gateway`. A run a
  gateway opened has no session: its start says no runtime, command or host, and its exit
  no exit code. An exit with the reason `quiet` says the quiet period, `quiet_seconds`.
  What the start says of the run credential, `credential`, is not read: `starter`, `issuer`
  as an older Forager wrote it, or `none`.

  How the run ended is its exit's `state` and `reason`, the same rule for a session's run
  and a gateway's (`exit_state/2`). The state is `succeeded`, `failed` or `cancelled`, and
  any other value is absent; the reason is a code, a lower-case letter then up to 63
  lower-case letters, digits and `_`, and anything else is absent. An exit that maps to
  lost sets `lost_at` to the exit's time. A run that did not start, `dev.qory.run.refused`,
  is failed, its `reason` the refusal's code, and has no exit time; an exit decides over
  it. Either is final: no start or heartbeat folded after it changes the state.

  Times: `started_at`, `exited_at` and a connection's first and last seen are Forager's
  own, the record. `last_heartbeat_at` is when the heartbeat with the highest sequence
  counts as heard (`Apiary.Runs.Liveness.heard_at/3`): its own time corrected by the run's
  clock offset, within a tolerance, and never after this server received it, because the
  lost-run check compares it with the server's clock and Forager's clock may be anywhere.
  The offset, `clock_offset_ms`, is the smallest of arrival less own time over every
  heartbeat of the run, whatever its sequence, and, for a run a gateway opened, its
  registration's (`registered_at` less `registration_time`) and its ping's, whose clock is
  the gateway's, as its heartbeats' are: a minimum, so it is the same in any order. A
  session's heartbeats are on the session's machine's clock, which behind a separate
  gateway is not the gateway's. Whenever a pass folds a later heartbeat or
  lowers the offset, the heartbeat with the highest sequence is counted again by the
  offset as the pass leaves it, from its time and arrival (the projector hands them over
  when that heartbeat was projected before), so `last_heartbeat_at` is the same in any
  order of arrival and after a rebuild. A heartbeat a pass folds revives a lost or pending
  run only when it counts as heard within three intervals of its arrival; a lower offset
  alone revives nothing and undoes no revive. So the one order that can show is a revive
  by a heartbeat that a lower offset, folded after it, would have kept from reviving: from
  a gateway's start, which revives the run itself, or from an earlier heartbeat delivered
  after it across a clock set back between the two. The next lost-run check settles it.
  """

  alias Apiary.Runs.{About, Liveness}

  @ping "dev.qory.ping"
  @started "dev.qory.run.started"
  @policy_applied "dev.qory.run.policy_applied"
  @heartbeat "dev.qory.run.heartbeat"
  @log "dev.qory.run.log"
  @resized "dev.qory.run.resized"
  @egress "dev.qory.run.egress"
  @exited "dev.qory.run.exited"
  @refused "dev.qory.run.refused"
  @result "dev.qory.session.result"

  @forager_version "forager_version"
  @terminal_rank "terminal"

  # The most a result may say a session cost, in dollars, before the value is read as
  # absent: a runtime's accounting error, not a bill.
  @max_cost Decimal.new(1_000_000_000)

  @doc """
  The ranks an event of `type` competes in, which the projector seeds `latest` with; none
  for a type that is folded without ranking.
  """
  def ranks(@ping), do: [@ping, @forager_version]
  def ranks(@started), do: [@started, @forager_version, @terminal_rank]
  def ranks(@resized), do: [@terminal_rank]
  def ranks(type) when type in [@policy_applied, @heartbeat, @exited, @refused], do: [type]
  def ranks(_type), do: []

  @doc "The types whose highest projected sequence seeds a rank."
  def rank_types(@forager_version), do: [@ping, @started]
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

  # The states no start or heartbeat folded later changes, with the old names an older
  # release stored them under (`Apiary.Runs.Run.old_states/0`).
  @terminal ~w(completed failed cancelled succeeded ended timed_out)
  @openers ~w(session gateway)
  # A reason: an open code of Forager's or of the run's starter.
  @reason ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # The reasons of a failed exit that say nobody knows how the run ended: the session went
  # silent, or the end was never recorded.
  @lost_reasons ~w(session_lost gateway_lost)
  # The reasons of the failed exit an older Forager, under the contract before the outcome,
  # wrote when it stopped a run itself, a session's run or a gateway's: its time limit, no
  # activity, its run credential expired, or its starter ended it. Such an exit is stored,
  # and a rebuild folds it again.
  @stopped_reasons ~w(timeout quiet credential_expired run_ended_at_issuer)
  # The reasons of an exit without a state, stored under that contract, that cancel the run:
  # its time limit, no activity, its run credential expired, or its starter ended it.
  @cancelled_reasons ~w(timeout quiet credential_expired stopped run_ended_at_issuer)
  @streams ~w(terminal stdout stderr)

  defstruct run: %{},
            latest: %{},
            ping_offset: nil,
            beat: nil,
            recount: false,
            beaten: false,
            connections: %{},
            log_chunks: [],
            skipped_log_chunks: 0

  @type t :: %__MODULE__{
          run: map(),
          latest: %{optional(String.t()) => integer()},
          ping_offset: integer() | nil,
          beat: %{time: DateTime.t(), received_at: DateTime.t()} | nil,
          recount: boolean(),
          beaten: boolean(),
          connections: %{optional({String.t(), integer(), String.t()}) => map()},
          log_chunks: [map()],
          skipped_log_chunks: non_neg_integer()
        }

  @doc """
  Folds `events` (maps with `type`, `time`, `sequence`, `data`, and `received_at`, else
  `time` stands for it) into `run` (any map with the run's fields, the schema struct
  included). `latest` maps a type of `ranked_types/0` to the highest sequence of it
  already projected. `projected` says what the fold needs of the events already projected:
  `ping_offset`, the smallest clock offset of the pings (the fold lowers it by the
  registration's own, from `run`), and `beat`, the `time` and
  `received_at` of the heartbeat with the highest sequence; each absent or nil when there
  is none.

  Returns the accumulator: `run` with the new field values, `connections` as one delta per
  (host, port, path), `log_chunks` in sequence order and the count of log events skipped
  because their bytes were not base64.
  """
  @spec fold(map(), Enumerable.t(), map(), map()) :: t()
  def fold(run, events, latest \\ %{}, projected \\ %{}) do
    acc = %__MODULE__{
      run: run,
      latest: latest,
      ping_offset: lower(projected[:ping_offset], registration_offset(run)),
      beat: projected[:beat]
    }

    acc =
      events
      |> Enum.sort_by(& &1.sequence)
      |> Enum.reduce(acc, &event(&2, &1))
      |> count_beat()

    %{acc | log_chunks: Enum.reverse(acc.log_chunks)}
  end

  defp event(acc, %{type: @ping, data: data} = event) do
    offset = Liveness.clock_offset(received_at(event), event.time)

    %{acc | ping_offset: lower(acc.ping_offset, offset)}
    |> ping_clock()
    |> ranked(event, &%{&1 | contract_version: integer(data, "contract_version", 0..@int4)})
    |> forager_version(event)
  end

  defp event(acc, %{type: @started, data: data} = event) do
    acc
    |> forager_version(event)
    |> terminal_size(event, terminal(data))
    |> ranked(event, fn run ->
      labels = labels(data)
      target = target(run, data)

      run
      |> Map.merge(%{
        opened_by: opened_by(data),
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
        target_system: target && target.system,
        target_path: target && target.path,
        started_at: event.time
      })
      |> Map.merge(about(data))
      |> started_state()
    end)
    |> ping_clock()
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

  # Ordered by sequence, timed by its own time within the run's clock offset: see the
  # moduledoc. Every heartbeat lowers the offset; the one with the highest sequence decides
  # the rest, and is counted once the pass is folded (`count_beat/1`).
  defp event(acc, %{type: @heartbeat, data: data, sequence: sequence} = event) do
    received_at = received_at(event)
    acc = put_offset(acc, Liveness.clock_offset(received_at, event.time))

    if sequence > Map.get(acc.latest, @heartbeat, 0) do
      run =
        Map.merge(acc.run, %{
          elapsed_seconds: integer(data, "elapsed_seconds", 0..@int4),
          heartbeat_interval_seconds: integer(data, "interval_seconds", 1..@max_interval)
        })

      %{
        acc
        | run: run,
          latest: Map.put(acc.latest, @heartbeat, sequence),
          beat: %{time: event.time, received_at: received_at},
          recount: true,
          beaten: true
      }
    else
      acc
    end
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
      reason = code(data, "reason")
      state = exit_state(string(data, "state"), reason)

      Map.merge(run, %{
        state: state,
        exited_at: event.time,
        exit_code: integer(data, "exit_code", -@int4..@int4),
        signal: string(data, "signal", 64),
        reason: reason,
        quiet_seconds: integer(data, "quiet_seconds", 1..@int4),
        duration_ms: integer(data, "duration_ms", 0..@int8),
        lost_at: if(state == "lost", do: event.time)
      })
    end)
  end

  # A run that did not start is failed, with the refusal's code; an exit decides over it, in
  # whichever order the two are folded.
  defp event(acc, %{type: @refused, data: data} = event) do
    ranked(acc, event, fn run ->
      if exited?(run),
        do: run,
        else: Map.merge(run, %{state: "failed", reason: code(data, "code"), lost_at: nil})
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

  # The tool whose host a request was for: a name, never empty. Kept whatever the
  # decision; with the decision it says whether the request was a tool invocation.
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

  @doc """
  The run state a `dev.qory.run.exited` with this `state` and `reason` means, the first rule
  that applies, whoever opened the run:

    1. `failed` with `timeout`, `quiet`, `credential_expired` or `run_ended_at_issuer` is
       cancelled: the exit an older Forager, under the contract before the outcome, wrote
       when it stopped a run itself.
    2. `failed` with `session_lost` or `gateway_lost` is lost: nobody knows how it ended.
    3. The state decides: `succeeded` is completed, `failed` failed, `cancelled` cancelled.
    4. Without a state, as an older Forager wrote a gateway's exit, the reason decides:
       `timeout`, `quiet`, `credential_expired`, `stopped` and `run_ended_at_issuer` are
       cancelled, `session_lost` and `gateway_lost` lost, and any other reason, or none,
       failed.

  A state other than the three is read as absent.
  """
  @spec exit_state(String.t() | nil, String.t() | nil) :: String.t()
  def exit_state("failed", reason) when reason in @stopped_reasons, do: "cancelled"
  def exit_state("failed", reason) when reason in @lost_reasons, do: "lost"
  def exit_state("succeeded", _reason), do: "completed"
  def exit_state("failed", _reason), do: "failed"
  def exit_state("cancelled", _reason), do: "cancelled"
  def exit_state(_state, reason) when reason in @cancelled_reasons, do: "cancelled"
  def exit_state(_state, reason) when reason in @lost_reasons, do: "lost"
  def exit_state(_state, _reason), do: "failed"

  defp started_state(run) do
    if ended?(run), do: run, else: %{run | state: "running", lost_at: nil}
  end

  # A run whose exit or refusal said how it ended. A run Apiary marked lost by its own
  # check has neither, and a start or a heartbeat revives it.
  defp ended?(%{state: state}) when state in @terminal, do: true
  defp ended?(run), do: exited?(run)

  defp exited?(run), do: Map.get(run, :exited_at) != nil

  # A code, as the contract writes a reason: anything else is absent.
  defp code(data, key) do
    case string(data, key, :infinity) do
      code when is_binary(code) -> if Regex.match?(@reason, code), do: code
      nil -> nil
    end
  end

  # What opened the run, one of the two the contract names, or nil.
  defp opened_by(data) do
    case string(data, "opened_by", 64) do
      opener when opener in @openers -> opener
      _ -> nil
    end
  end

  # `ping` and `run.started` both say Forager's version: the later of the two decides.
  defp forager_version(acc, %{sequence: sequence, data: data}) do
    if sequence > Map.get(acc.latest, @forager_version, 0) do
      %{
        acc
        | run: %{acc.run | forager_version: string(data, "forager_version", 255)},
          latest: Map.put(acc.latest, @forager_version, sequence)
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

  # The heartbeat with the highest sequence, counted by the offset as the pass leaves it,
  # whenever the pass folded a later heartbeat or lowered the offset: so the last heartbeat
  # is that heartbeat's by the smallest offset, whatever the order the events were folded
  # in. A heartbeat this pass folded and heard within three intervals of its arrival says
  # the run is alive: a lost run runs again, and so does a run whose `run.started` has not
  # arrived yet. An exit is not undone. A lower offset alone revives nothing.
  defp count_beat(%{recount: true, beat: %{time: time, received_at: received_at}} = acc) do
    heard_at = Liveness.heard_at(received_at, time, Map.get(acc.run, :clock_offset_ms))
    run = Map.put(acc.run, :last_heartbeat_at, heard_at)
    # The registration's interval, else the heartbeats': the rule of the lost-run check.
    interval =
      Map.get(run, :registration_interval_seconds) || Map.get(run, :heartbeat_interval_seconds)

    if acc.beaten and Liveness.heard_within?(heard_at, interval, received_at),
      do: %{acc | run: revive(run)},
      else: %{acc | run: run}
  end

  defp count_beat(acc), do: acc

  defp revive(%{state: state} = run) when state in ["lost", "pending"] do
    if exited?(run), do: run, else: %{run | state: "running", lost_at: nil}
  end

  defp revive(run), do: run

  # When this server received the event; an event that does not say is taken at its time.
  defp received_at(event), do: Map.get(event, :received_at) || event.time

  # A lower offset counts the last heartbeat again.
  defp put_offset(%{run: run} = acc, offset) do
    current = Map.get(run, :clock_offset_ms)

    case lower(current, offset) do
      ^current -> acc
      lowered -> %{acc | run: Map.put(run, :clock_offset_ms, lowered), recount: true}
    end
  end

  # The gateway's offset, its registration's and its ping's, counts for a run a gateway
  # opened, whichever of the ping and the start comes first.
  defp ping_clock(%{run: %{opened_by: "gateway"}, ping_offset: offset} = acc)
       when is_integer(offset),
       do: put_offset(acc, offset)

  defp ping_clock(acc), do: acc

  # The registration's time on the gateway's clock and its arrival at this server, as a
  # ping's time and arrival were: nil for a run that did not register.
  defp registration_offset(run) do
    case {Map.get(run, :registered_at), Map.get(run, :registration_time)} do
      {%DateTime{} = received_at, %DateTime{} = time} -> Liveness.clock_offset(received_at, time)
      _ -> nil
    end
  end

  defp lower(offset, nil), do: offset
  defp lower(nil, offset), do: offset
  defp lower(current, offset), do: min(current, offset)

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

  # The four fields of what the run is about, from `about` (`Apiary.Runs.About.read/1`).
  defp about(%{"about" => about}), do: About.read(about)
  defp about(_data), do: About.read(nil)

  # The target the labels as sent name, whole, by the workspace's domain
  # (`Apiary.Lingo.Domain`), or nil. Labels that name no target stay in `labels` (cut like
  # the others) and the run is unassigned.
  defp target(run, %{"labels" => labels}) do
    case Apiary.Lingo.Domain.target(workspace(run), labels) do
      {:ok, target} -> target
      :none -> nil
    end
  end

  defp target(_run, _data), do: nil

  # The projector hands the run in with its workspace loaded, which carries the domain, so
  # the fold reads no database. A run without it reads the default domain.
  defp workspace(%{workspace: %Apiary.Organisations.Workspace{} = workspace}), do: workspace
  defp workspace(_run), do: nil

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
