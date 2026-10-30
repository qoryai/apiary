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
  the later of the two decides, and `session.started` and `run.resized` share the rank of
  the terminal's size, which the later of them decides: `terminal_cols` and
  `terminal_rows` are the size the record last said, `terminal` of a session's start on a
  pseudo-terminal, then each resize. A session's start on pipes reports no size and
  leaves both null.

  A run is opened once, `run.started` (`opened_by` `run`, which `Apiary.Runs.Batch`
  requires), and each session that joins it has a `session.started` and a
  `session.exited`. What the run runs, `runtime`, `runtime_version`, `command`, `args`,
  `dir`, `interactive` and `image`, is the `session.started` with the highest sequence.
  `session.exited` is folded into nothing: how the run ended is its `run.exited`.

  The steps of the run's host work and joins (`Apiary.Runs.Step`) are folded by `step`,
  their number, an integer from 1: `steps` has one delta per number, the start's `name`,
  `kind` and sequence from its `run.step_started`, and the exit's `state`, `exit_code`,
  `duration_ms` and sequence from its `run.step_exited`. Of two starts, or two exits, with
  one number, which the contract forbids, the lower sequence decides, in this pass
  and against what is stored (`Apiary.Runs.Projector`). A `kind` outside the contract's
  six is absent. An exit's `state` other than `succeeded`, `failed` and `cancelled`, or
  none, is `failed`, the rule of a run's exit without a state (`exit_state/2`). A step
  event whose `step` is not such an integer is folded into nothing. A log chunk keeps its
  event's `step`, read the same way.

  An egress event is folded into the connection of its destination (host, port and path)
  and its channel: `channel` `stack` for the stack proxy, which fetches the run's harness
  definition, and `session` for any other value or none, the run's proxy. One destination
  reached on both channels is two connections.

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

  How the run ended is its exit's `state` and `reason` (`exit_state/2`). The state is `succeeded`, `failed` or `cancelled`, and
  any other value is absent; the reason is a code, a lower-case letter then up to 63
  lower-case letters, digits and `_`, and anything else is absent. An exit that maps to
  lost sets `lost_at` to the exit's time. A run that did not start, `dev.qory.run.refused`,
  is failed, its `reason` the refusal's code, and has no exit time; an exit decides over
  it. Either is final: no start or heartbeat folded after it changes the state. The state
  and reason the exit means are kept as `exit_state` and `exit_reason` too, and the
  refusal's time as `refused_at`, nil once an exit decides over it, in either order.

  The run's starter's outcome (`Apiary.Runs.Outcome`), stored on the run and not folded,
  decides over all of them whenever it arrives (`outcome/1`): the last step of every fold
  applies it, so its state and reason are the run's, and the exit's stay beside them. A
  run of a workspace's queue takes no outcome; one stored on it before that rule is
  applied as any other. A run whose end Qory recorded without an outcome (`released_at`,
  not folded either) is cancelled with the reason `released`, whatever its exit said;
  that step comes just before the outcome's, so an outcome stored before decides over
  it. A run whose machine never started it (`start_failure`, not folded either) is
  failed, its reason that cause, in a step before both.

  Times: `started_at`, `exited_at` and a connection's first and last seen are Forager's,
  the record. `last_heartbeat_at` is when the heartbeat with the highest sequence
  counts as heard (`Apiary.Runs.Liveness.heard_at/3`): the heartbeat's time corrected by the run's
  clock offset, within a tolerance, and never after this server received it, because the
  lost-run check compares it with the server's clock and Forager's clock may be anywhere.
  The offset, `clock_offset_ms`, is the smallest of arrival less the heartbeat's time over every
  heartbeat of the run, whatever its sequence: a minimum, so it is the same in any order.
  A session's heartbeats are on the session's machine's clock, which behind a separate
  gateway is not the gateway's. Whenever a pass folds a later heartbeat or
  lowers the offset, the heartbeat with the highest sequence is counted again by the
  offset as the pass leaves it, from its time and arrival (the projector hands them over
  when that heartbeat was projected before), so `last_heartbeat_at` is the same in any
  order of arrival and after a rebuild. A heartbeat a pass folds revives a lost or pending
  run only when it counts as heard within three intervals of its arrival, and, for a run
  whose attach set a deadline for its end (`backstop_at`, `Apiary.Runs.Liveness`), only
  when it arrived by then, as does a start. Neither revives a run the lost-run check ended
  for its silence (`silenced_at`), whenever it arrived: that end freed the run's slot, and
  only its exit changes the run then, as a run of the queue takes no outcome. A lower
  offset alone revives nothing and undoes no revive. So the one order that can show is a
  revive by a heartbeat that a lower offset, folded after it, would have kept from
  reviving: from an earlier heartbeat delivered after it across a clock set back between
  the two. The next lost-run check settles it.

  A run through a gateway counts the starts and heartbeats of the instance that attached
  it alone (`liveness_instance/1`), by the instance id each event was delivered with
  (`events.node_instance_id`): after a loss, only the attaching instance's heartbeat makes
  the run live again. Another instance's heartbeat is folded into nothing, neither the last
  heartbeat, nor the offset, nor the elapsed time, and its start revives nothing. An
  event stored before its instance was kept counts, and so does every event of a run
  whose attaching instance is not known, and of a direct run. The instance ids are stored
  with the events and the run's attaching instance, once known, does not change, so a
  rebuild folds the same, except heartbeats another instance sent before a run attached
  with none took its instance, which a rebuild no longer counts.
  """

  alias Apiary.Runs.{About, Liveness}

  @ping "dev.qory.ping"
  @started "dev.qory.run.started"
  @session_started "dev.qory.session.started"
  @session_exited "dev.qory.session.exited"
  @policy_applied "dev.qory.run.policy_applied"
  @heartbeat "dev.qory.run.heartbeat"
  @log "dev.qory.run.log"
  @resized "dev.qory.run.resized"
  @egress "dev.qory.run.egress"
  @exited "dev.qory.run.exited"
  @refused "dev.qory.run.refused"
  @result "dev.qory.runtime.result"
  @step_started "dev.qory.run.step_started"
  @step_exited "dev.qory.run.step_exited"

  # The most bytes of a connection's host, and what ends one cut to fit (`host/1`).
  @host_max 255
  @cut_mark "…"

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
  def ranks(@started), do: [@started, @forager_version]
  def ranks(@session_started), do: [@session_started, @terminal_rank]
  def ranks(@resized), do: [@terminal_rank]
  def ranks(type) when type in [@policy_applied, @heartbeat, @exited, @refused], do: [type]
  def ranks(_type), do: []

  @doc "The types whose highest projected sequence seeds a rank."
  def rank_types(@forager_version), do: [@ping, @started]
  def rank_types(@terminal_rank), do: [@session_started, @resized]
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

  # The states no start or heartbeat folded later changes.
  @terminal ~w(completed failed cancelled)
  # A reason: an open code of Forager's or of the run's starter.
  @reason ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # The reasons of a failed exit that say nobody knows how the run ended: the session went
  # silent, or the end was never recorded.
  @lost_reasons ~w(session_lost gateway_lost)
  @streams ~w(terminal stdout stderr)
  # The states a run's starter may give as its outcome (`Apiary.Runs.Outcome`).
  @outcome_states ~w(succeeded failed cancelled)
  # The states a step's exit says, and the kinds of step the contract lists.
  @step_states ~w(succeeded failed cancelled)
  @step_kinds ~w(fetch compose image setup join wall)

  defstruct run: %{},
            latest: %{},
            beat: nil,
            recount: false,
            beaten: false,
            connections: %{},
            steps: %{},
            log_chunks: [],
            skipped_log_chunks: 0

  @type t :: %__MODULE__{
          run: map(),
          latest: %{optional(String.t()) => integer()},
          beat: %{time: DateTime.t(), received_at: DateTime.t()} | nil,
          recount: boolean(),
          beaten: boolean(),
          connections: %{optional({String.t(), integer(), String.t(), String.t()}) => map()},
          steps: %{optional(pos_integer()) => map()},
          log_chunks: [map()],
          skipped_log_chunks: non_neg_integer()
        }

  @doc """
  Folds `events` (maps with `type`, `time`, `sequence`, `data`, and `received_at`, else
  `time` stands for it) into `run` (any map with the run's fields, the schema struct
  included). `latest` maps a type of `ranked_types/0` to the highest sequence of it
  already projected. `projected` says what the fold needs of the events already projected:
  `beat`, the `time` and `received_at` of the heartbeat with the highest sequence, absent
  or nil when there is none.

  Returns the accumulator: `run` with the new field values, `connections` as one delta per
  (host, port, path, channel), `steps` as one delta per step number, `log_chunks` in sequence order
  and the count of log events skipped because their bytes were not base64.
  """
  @spec fold(map(), Enumerable.t(), map(), map()) :: t()
  def fold(run, events, latest \\ %{}, projected \\ %{}) do
    acc = %__MODULE__{
      run: run,
      latest: latest,
      beat: projected[:beat]
    }

    acc =
      events
      |> Enum.sort_by(& &1.sequence)
      |> Enum.reduce(acc, &event(&2, &1))
      |> count_beat()

    %{acc | run: settle(acc.run), log_chunks: Enum.reverse(acc.log_chunks)}
  end

  # settle/1 is the last step of every fold, and what a rebuild's reset and an end Qory
  # records apply: a run its starter released after a queue handed it over
  # (`released_at`, `Apiary.Dispatches.RunEnd`) is cancelled with the reason `released`,
  # whatever its exit said, and not lost; then its outcome, should one have been stored
  # before a run of the queue was refused one, decides over that as over all the rest
  # (`outcome/1`). No outcome is recorded for a release. A run whose machine never
  # started it (`start_failure`, `Apiary.Dispatches.Handover.fail_start/3`) is failed,
  # its reason that cause, and not lost, before both. Every other run is `outcome/1`
  # alone.
  @doc false
  @spec settle(map()) :: map()
  def settle(run), do: run |> start_failed() |> released() |> outcome()

  defp start_failed(%{start_failure: failure} = run) when is_binary(failure),
    do: Map.merge(run, %{state: "failed", reason: failure, lost_at: nil})

  defp start_failed(run), do: run

  defp released(%{released_at: %DateTime{}} = run) do
    if Map.get(run, :outcome_state) in @outcome_states,
      do: run,
      else: Map.merge(run, %{state: "cancelled", reason: "released", lost_at: nil})
  end

  defp released(run), do: run

  @doc """
  `run` with its starter's outcome applied: given an outcome (`outcome_state`, from
  `Apiary.Runs.Outcome`), its state decides the run's (`succeeded` is completed, `failed`
  failed, `cancelled` cancelled), its reason the run's `reason` (nil when it gave none),
  and the run is not lost; with none, `run` as it is. What the exit said stays beside it:
  `exit_state`, `exit_reason`, `exit_code`, `signal` and `exited_at`, and so does a
  refusal's `refused_at`.

  The last step of every fold, and what the outcome's write and a rebuild's reset
  apply, so the outcome decides whenever it arrives, before the exit or after it, and a
  rebuild gives the same run.
  """
  @spec outcome(map()) :: map()
  def outcome(%{outcome_state: outcome} = run) when outcome in @outcome_states do
    Map.merge(run, %{
      state: outcome_run_state(outcome),
      reason: Map.get(run, :outcome_reason),
      lost_at: nil
    })
  end

  def outcome(run), do: run

  defp outcome_run_state("succeeded"), do: "completed"
  defp outcome_run_state("failed"), do: "failed"
  defp outcome_run_state("cancelled"), do: "cancelled"

  defp event(acc, %{type: @ping, data: data} = event) do
    acc
    |> ranked(event, &%{&1 | contract_version: integer(data, "contract_version", 0..@int4)})
    |> forager_version(event)
  end

  defp event(acc, %{type: @started, data: data} = event) do
    acc
    |> forager_version(event)
    |> ranked(event, fn run ->
      labels = labels(data)
      target = target(run, data)

      run
      |> Map.merge(%{
        host: string(data, "host"),
        wall: string(data, "wall"),
        labels: labels,
        target_system: target && target.system,
        target_path: target && target.path,
        started_at: event.time
      })
      |> Map.merge(about(data))
      |> started_state(event)
    end)
  end

  # What the run runs is its last session's: the `session.started` with the highest
  # sequence decides every member, one the event leaves out included.
  defp event(acc, %{type: @session_started, data: data} = event) do
    acc
    |> terminal_size(event, terminal(data))
    |> ranked(event, fn run ->
      Map.merge(run, %{
        runtime: string(data, "runtime"),
        runtime_version: string(data, "runtime_version"),
        command: string(data, "command", @long_text),
        args: strings(data, "args"),
        dir: string(data, "dir", @long_text),
        interactive: boolean(data, "interactive"),
        image: string(data, "image")
      })
    end)
  end

  # How one session ended is folded into nothing; a refused join has no `session.started`
  # and changes nothing either.
  defp event(acc, %{type: @session_exited}), do: acc

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
  # the rest, and is counted once the pass is folded (`count_beat/1`). A heartbeat from
  # another instance than the one that attached the run is folded into nothing.
  defp event(acc, %{type: @heartbeat} = event) do
    if attaching_instance?(acc.run, event), do: heartbeat(acc, event), else: acc
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
      chunk = %{sequence: sequence, stream: stream, bytes: bytes, step: step_number(data)}
      %{acc | log_chunks: [chunk | acc.log_chunks]}
    else
      _ -> %{acc | skipped_log_chunks: acc.skipped_log_chunks + 1}
    end
  end

  defp event(acc, %{type: @egress, data: data, time: time, sequence: sequence}) do
    with host when is_binary(host) <- host(string(data, "host", :infinity)),
         port when is_integer(port) <- integer(data, "port", 0..65_535) do
      key = {host, port, string(data, "path", @text) || "", channel(data)}
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
        exit_state: state,
        exited_at: event.time,
        exit_code: integer(data, "exit_code", -@int4..@int4),
        signal: string(data, "signal", 64),
        reason: reason,
        exit_reason: reason,
        refused_at: nil,
        duration_ms: integer(data, "duration_ms", 0..@int8),
        lost_at: if(state == "lost", do: event.time)
      })
    end)
  end

  # A run that did not start is failed, with the refusal's code, and keeps when it was
  # refused; an exit decides over it, in whichever order the two are folded. The outcome,
  # applied after, sets the state and reason, and leaves `refused_at`.
  defp event(acc, %{type: @refused, data: data} = event) do
    ranked(acc, event, fn run ->
      if exited?(run),
        do: run,
        else:
          Map.merge(run, %{
            state: "failed",
            reason: code(data, "code"),
            lost_at: nil,
            refused_at: event.time
          })
    end)
  end

  # A step's start: the lowest sequence of its number decides, so the first by sequence
  # in this pass is kept (events come in sequence order).
  defp event(acc, %{type: @step_started, data: data, time: time, sequence: sequence}) do
    case step_number(data) do
      nil ->
        acc

      step ->
        start = %{
          name: string(data, "name"),
          kind: step_kind(data),
          started_sequence: sequence,
          started_at: time
        }

        put_step(acc, step, :started_sequence, start)
    end
  end

  # A step's exit, the same way: the lowest sequence of its number decides.
  defp event(acc, %{type: @step_exited, data: data, time: time, sequence: sequence}) do
    case step_number(data) do
      nil ->
        acc

      step ->
        exit = %{
          state: step_state(data),
          exit_code: integer(data, "exit_code", -@int4..@int4),
          duration_ms: integer(data, "duration_ms", 0..@int8),
          exited_sequence: sequence,
          exited_at: time
        }

        put_step(acc, step, :exited_sequence, exit)
    end
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

  # The fields of a step's delta. A delta has every one, nil where its events said
  # nothing, so that the projector writes all its rows alike.
  @step_delta %{
    name: nil,
    kind: nil,
    started_sequence: nil,
    started_at: nil,
    state: nil,
    exit_code: nil,
    duration_ms: nil,
    exited_sequence: nil,
    exited_at: nil
  }

  # Merges a start or an exit into the step's delta unless the delta has one already,
  # which then has the lower sequence.
  defp put_step(acc, step, sequence_key, fields) do
    delta = Map.get(acc.steps, step, @step_delta)

    if delta[sequence_key],
      do: acc,
      else: %{acc | steps: Map.put(acc.steps, step, Map.merge(delta, fields))}
  end

  # A step's number: an integer from 1 that the column holds, else absent.
  defp step_number(data), do: integer(data, "step", 1..@int4)

  defp step_kind(data) do
    case string(data, "kind") do
      kind when kind in @step_kinds -> kind
      _ -> nil
    end
  end

  # An exit that says no state of the three ended badly, as a run's does (`exit_state/2`).
  defp step_state(data) do
    case string(data, "state") do
      state when state in @step_states -> state
      _ -> "failed"
    end
  end

  # The channel of an egress event: `stack` for the stack proxy's, `session` for any
  # other.
  defp channel(%{"channel" => "stack"}), do: "stack"
  defp channel(_data), do: "session"

  # The destination's host, at most 255 bytes. A longer one is kept, so the attempt is
  # counted and shown: its first 252 bytes, cut on a character boundary, then "…" (3
  # bytes), which the grammar of a rule's host refuses, so no rule can be made from it.
  # Two hosts that share the first 252 bytes, the port and the path fold into one row. A
  # longer host that is not valid UTF-8 has no character boundary to cut on, and is not a
  # connection. The run's timeline shows an egress event's host with it, so a long host
  # reads there as on its connection's row (`Apiary.Runs.Record.Timeline.egress_host/1`).
  @doc false
  def host(host) when is_binary(host) and byte_size(host) <= @host_max, do: host

  def host(host) when is_binary(host) do
    if String.valid?(host), do: cut(host, @host_max - byte_size(@cut_mark)) <> @cut_mark
  end

  def host(_host), do: nil

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
  that applies:

    1. `failed` with `session_lost` or `gateway_lost` is lost: nobody knows how it ended.
    2. The state decides: `succeeded` is completed, `failed` failed, `cancelled` cancelled.
    3. Without a state, which the contract requires, `session_lost` and `gateway_lost` are
       lost, and any other reason, or none, failed.

  A state other than the three is read as absent.
  """
  @spec exit_state(String.t() | nil, String.t() | nil) :: String.t()
  def exit_state("failed", reason) when reason in @lost_reasons, do: "lost"
  def exit_state("succeeded", _reason), do: "completed"
  def exit_state("failed", _reason), do: "failed"
  def exit_state("cancelled", _reason), do: "cancelled"
  def exit_state(_state, reason) when reason in @lost_reasons, do: "lost"
  def exit_state(_state, _reason), do: "failed"

  # A start revives the run as a heartbeat does, from the attaching instance alone, not
  # past the run's backstop, and not once its silence ended it.
  defp started_state(run, event) do
    if ended?(run) or not attaching_instance?(run, event) or
         Liveness.past_backstop?(run, received_at(event)) or silenced?(run),
       do: run,
       else: %{run | state: "running", lost_at: nil}
  end

  @doc """
  The instance whose starts and heartbeats count towards `run`'s liveness: the instance
  that attached it (`gateway_instance_id`), for a run through a gateway that has one; nil
  for any other run, whose events count from whoever sent them.
  """
  @spec liveness_instance(map()) :: String.t() | nil
  def liveness_instance(run) do
    if Map.get(run, :run_key_payload), do: Map.get(run, :gateway_instance_id)
  end

  # An event stored before its instance was kept, with none, counts as it did.
  defp attaching_instance?(run, event) do
    case liveness_instance(run) do
      nil -> true
      instance_id -> Map.get(event, :node_instance_id) in [nil, instance_id]
    end
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

  # `session.started` and `run.resized` both say the terminal's size: the later decides. A
  # session's start says none on pipes, which is `{nil, nil}`.
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

  # The size a session's start reports: `terminal`, or none on pipes.
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

  defp heartbeat(acc, %{data: data, sequence: sequence} = event) do
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

  # The heartbeat with the highest sequence, counted by the offset as the pass leaves it,
  # whenever the pass folded a later heartbeat or lowered the offset: so the last heartbeat
  # is that heartbeat's by the smallest offset, whatever the order the events were folded
  # in. A heartbeat this pass folded and heard within three intervals of its arrival says
  # the run is alive: a lost run runs again, and so does a run whose `run.started` has not
  # arrived yet, but not past its backstop or once its silence ended it. An exit is not
  # undone. A lower offset alone revives nothing.
  defp count_beat(%{recount: true, beat: %{time: time, received_at: received_at}} = acc) do
    heard_at = Liveness.heard_at(received_at, time, Map.get(acc.run, :clock_offset_ms))
    run = Map.put(acc.run, :last_heartbeat_at, heard_at)
    # The registration's interval, else the attach's, else the heartbeats': the rule of the
    # lost-run check.
    interval =
      Map.get(run, :registration_interval_seconds) || Map.get(run, :attach_interval_seconds) ||
        Map.get(run, :heartbeat_interval_seconds)

    if acc.beaten and Liveness.heard_within?(heard_at, interval, received_at) and
         not Liveness.past_backstop?(run, received_at) and not silenced?(run),
       do: %{acc | run: revive(run)},
       else: %{acc | run: run}
  end

  defp count_beat(acc), do: acc

  # A run the lost-run check ended for its silence (`Apiary.Dispatches.RunEnd`).
  defp silenced?(run), do: match?(%DateTime{}, Map.get(run, :silenced_at))

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
