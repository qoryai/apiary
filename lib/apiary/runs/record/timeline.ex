defmodule Apiary.Runs.Record.Timeline do
  @moduledoc """
  The session timeline of one run, folded from its events. Pure: no query is made here.

  It works in two steps, because a run may hold thousands of events and a page shows a
  window of them:

    * `index/2` and `extend/3` read events in a light form (sequence, type, time and the
      few ids that pair events up) and lay the run out: which events make one item, which
      lane an item sits on, which rails pass it, where a connection goes, which background
      tasks are outstanding. The layout is of the run, not of a window, so rails are right
      at a window's edge. The index keeps the state of the fold, so a run that is still
      being written is extended by the events of the new range alone.
    * `build/3` makes the items of a window from slim events: rows whose every payload was
      already cut by the query that read them (`Apiary.Runs.Record`), or by `slim/2` from
      a whole event.

  Pairing uses ids only: `tool_use_id` for the three tool events, `agent_id` for the two
  subagent events. Order is the events' `sequence`, never a clock. A connection is placed
  inside a tool call only when exactly one call is open at its sequence; that says
  *while*, never *because*. A call whose end the record lacks stops being open when its
  agent's turn ends, its subagent finishes, the session ends or starts again, or the run
  exits: from there on a connection is an item of its own. Heartbeats, log chunks, the
  ping and types this module has not heard of are not items.

  Everything that comes out of an event is the runner's input and is treated as such:
  strings are bounded, what one item loads is bounded (#{100} connections inside a call),
  every pass is linear in the events whatever ids they carry, nothing becomes an atom,
  and nothing here is marked safe.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Runs

  @prefix "dev.qory."

  @kinds %{
    "run.started" => :run_started,
    "run.policy_applied" => :policy_applied,
    "run.exited" => :run_exited,
    "run.egress" => :connection,
    "session.started" => :session_started,
    "session.prompt_submitted" => :prompt,
    "session.tool_started" => :tool,
    "session.tool_finished" => :tool,
    "session.tool_failed" => :tool,
    "session.subagent_started" => :subagent_started,
    "session.subagent_finished" => :subagent_finished,
    "session.notification" => :notification,
    "session.turn_finished" => :turn_finished,
    "session.turn_failed" => :turn_failed,
    "session.result" => :result,
    "session.ended" => :session_ended
  }

  # The runner reads this one from the runtime's output; every other session event comes
  # from a hook.
  @not_from_a_hook "session.result"

  @max_rails 4
  @colors [:a, :b, :c]
  @main %{index: 0, id: "main", type: nil, rail: 0, color: :main, overflow: false}

  @well_limit 8 * 1024
  @full_limit 512 * 1024
  @summary_limit 400
  @max_inner 100
  @max_tasks 20
  @max_listed 50
  @max_open_lanes 1_000
  @max_delta 3
  @max_allow 200
  @max_argument Apiary.Policy.Grammar.argument_max()
  @lane_key 12

  @doc "The bytes of a payload a well shows before \"Show all\"."
  def well_limit, do: @well_limit

  @doc "The bytes of a payload \"Show all\" shows."
  def full_limit, do: @full_limit

  @doc "How many connections one item loads and shows, at most."
  def max_inner, do: @max_inner

  @doc "How many tasks of one list are read, at most."
  def max_listed, do: @max_listed

  @doc "How many hosts of a policy applied event's allow list, and of its deny list, are read, at most."
  def max_allow, do: @max_allow

  @doc """
  How many code points of a tool's argument the timeline reads, at most: the longest
  argument the policy editor writes (`Apiary.Policy.Grammar.argument_max/0`). A longer one
  is cut there and ends in `…`.
  """
  def max_argument, do: @max_argument

  @doc "The event types the index needs, with the `dev.qory.` prefix."
  def types, do: Enum.map(Map.keys(@kinds), &(@prefix <> &1))

  @doc "The kind of item an event type makes, or nil when it makes none."
  def kind(@prefix <> type), do: Map.get(@kinds, type)
  def kind(_type), do: nil

  ## The index

  @doc """
  Lays the run out. `events` are light events in sequence order, maps with `:sequence`,
  `:type`, `:time` and, where the event has them, `:tool_use_id`, `:agent_id`,
  `:agent_type`, `:background_tasks` (a list, or nil when the event gives none), `:host`,
  `:port`, `:decision` and, on an egress event that names one, `:tool`, the tool whose host
  it was for; with `:decision` allowed it is a tool invocation
  (`Apiary.Runs.tool_invocation?/2`). `alive:` says whether the record
  is still being written: it fades the rails of the last item, and a call without an end is
  open only while it is.

  Returns a map:

    * `:items`: the light items in order, each `%{seq, kind, seqs, end_seq, inner,
      inner_count, tool_state, lane, rails, link, who, open_calls}`; `seq` is the item's
      id, the sequence of its first event, and `seqs` the sequences `build/3` needs for
      it, at most #{@max_inner + 2};
    * `:by_seq`: every sequence that belongs to an item, to that item's `seq`;
    * `:lanes`: the first #{@lane_key} lanes beside main, `%{index, id, type, rail, color,
      started_seq, finished_seq}`, main first; `:lane_count` says how many there are, and
      `lane/2` finds any of them;
    * `:rails`: how many rails the gutter needs, one to four;
    * `:session_items`: how many items are the session's (not the runner's, not egress);
    * `:hook_events`: how many session events came from the runtime's hooks;
    * `:background`: `%{tasks: [...], count: n}`, the tasks of the last list the runtime
      gave, each with the sequence it was first listed at;
    * `:through`: the highest sequence folded.
  """
  def index(events, opts \\ []), do: extend(new(), events, opts)

  @doc "The index of a run with no events."
  def new, do: finalize(new_state(), false)

  @doc """
  The index with `events` folded in after what it holds. They must be in sequence order
  and all after `index.through`: an event that arrives below it changes what came
  before, and the run is indexed again.
  """
  def extend(%{state: state}, events, opts \\ []) do
    state =
      Enum.reduce(events, state, fn event, state ->
        state = %{state | through: max(state.through, event.sequence)}
        state = background(state, event)

        case kind(event.type) do
          nil -> state
          kind -> state |> count(event) |> close_calls(kind, event) |> place(kind, event)
        end
      end)

    finalize(state, Keyword.get(opts, :alive, false))
  end

  @doc "The index again, for a run whose record has or has not stopped being written."
  def alive(%{state: state}, alive?), do: finalize(state, alive?)

  @doc "The lane with this id (the last one, when an agent id came twice), or nil."
  def lane(_index, "main"), do: Map.merge(@main, %{started_seq: nil, finished_seq: nil})

  def lane(%{state: state}, id) when is_binary(id) do
    case state.lane_by_id[id] do
      nil -> nil
      index -> public_lane(state.lanes[index])
    end
  end

  def lane(_index, _id), do: nil

  @doc """
  Sets the outstanding background tasks from what was read beside the light events: the
  tasks of the last list the runtime gave, `%{id, type, status, what, listed_at}`.
  """
  def put_background(%{state: state} = index, tasks) when is_list(tasks) do
    state = %{state | tasks: Enum.take(tasks, @max_listed)}
    %{index | state: state, background: outstanding(state)}
  end

  defp new_state do
    %{
      # item seq => raw item, and the item seqs, newest first
      items: %{},
      order: [],
      by_seq: %{},
      # tool_use_id => item seq, while the call is open; agent key => its open ids
      open_tools: %{},
      open_by_agent: %{},
      # tool_use_id => item seq, for a call closed without its end: a late end finds it
      closed_tools: %{},
      # agent_id => lane index, while the agent is open and tracked
      open_lanes: %{},
      # rail => lane index, for the lanes that hold a rail (three at most)
      rail_lanes: %{},
      lanes: %{},
      lane_by_id: %{},
      lane_count: 0,
      rails: 1,
      session_items: 0,
      hook_events: 0,
      # the tasks of the last list given
      tasks: [],
      # the sequence of the last policy applied, for the reload that follows it
      policy_seq: nil,
      through: 0
    }
  end

  defp finalize(state, alive?) do
    last = List.first(state.order)
    first = List.last(state.order)

    items =
      Enum.reduce(state.order, [], fn seq, items ->
        [finish_item(state.items[seq], seq == first, seq == last, alive?) | items]
      end)

    lanes =
      for index <- 1..min(state.lane_count, @lane_key)//1, do: public_lane(state.lanes[index])

    %{
      state: state,
      items: items,
      by_seq: state.by_seq,
      lanes: [lane(nil, "main") | lanes],
      lane_count: state.lane_count,
      rails: state.rails,
      session_items: state.session_items,
      hook_events: state.hook_events,
      background: outstanding(state),
      through: state.through
    }
  end

  defp public_lane(lane),
    do: Map.take(lane, [:index, :id, :type, :rail, :color, :started_seq, :finished_seq])

  defp count(state, %{type: @prefix <> "session." <> _ = type}) do
    if type == @prefix <> @not_from_a_hook,
      do: state,
      else: %{state | hook_events: state.hook_events + 1}
  end

  defp count(state, _event), do: state

  ## Calls

  # Where the record says a call cannot still be open, it is closed without an end.
  defp close_calls(state, kind, event)
       when kind in [:turn_finished, :turn_failed, :subagent_finished],
       do: close_agent(state, agent_key(event))

  defp close_calls(state, kind, _event)
       when kind in [:session_ended, :session_started, :run_exited] do
    state.open_by_agent |> Map.keys() |> Enum.reduce(state, &close_agent(&2, &1))
  end

  defp close_calls(state, _kind, _event), do: state

  defp close_agent(state, agent) do
    case Map.pop(state.open_by_agent, agent) do
      {nil, _} ->
        state

      {ids, open_by_agent} ->
        Enum.reduce(ids, %{state | open_by_agent: open_by_agent}, fn id, state ->
          case Map.pop(state.open_tools, id) do
            {nil, _} ->
              state

            {seq, open_tools} ->
              %{
                state
                | open_tools: open_tools,
                  closed_tools: Map.put(state.closed_tools, id, seq),
                  items: Map.update!(state.items, seq, &%{&1 | no_end: true})
              }
          end
        end)
    end
  end

  defp agent_key(event), do: event[:agent_id] || :main

  defp place(state, :tool, %{type: @prefix <> "session.tool_started"} = event) do
    id = event[:tool_use_id]

    cond do
      not is_binary(id) ->
        # Nothing can end a call without an id: it is an item, and never open.
        state |> push(:tool, event) |> update_item(event.sequence, &%{&1 | no_end: true})

      is_map_key(state.open_tools, id) ->
        # The same call started twice: one item, not a second that nothing would close.
        also(state, state.open_tools[id], event.sequence)

      true ->
        agent = agent_key(event)

        %{
          push(state, :tool, event)
          | open_tools: Map.put(state.open_tools, id, event.sequence),
            open_by_agent: Map.update(state.open_by_agent, agent, [id], &[id | &1])
        }
    end
  end

  defp place(state, :tool, event) do
    id = event[:tool_use_id]

    case Map.pop(state.open_tools, id) do
      {nil, _open} ->
        case Map.pop(state.closed_tools, id) do
          {nil, _} ->
            # An end without its start: the record lacks it, so the item is the end alone.
            state
            |> push(:tool, event)
            |> update_item(event.sequence, &%{&1 | end_seq: event.sequence})

          {seq, closed} ->
            end_call(%{state | closed_tools: closed}, seq, event)
        end

      {seq, open} ->
        end_call(%{state | open_tools: open}, seq, event)
    end
  end

  defp place(state, :connection, event) do
    if map_size(state.open_tools) == 1 do
      [{_id, seq}] = Map.to_list(state.open_tools)
      denied? = event[:decision] == "denied"

      state
      |> update_item(seq, fn item ->
        %{
          item
          | inner:
              if(item.inner_count < @max_inner,
                do: [event.sequence | item.inner],
                else: item.inner
              ),
            inner_count: item.inner_count + 1,
            denied_inside: item.denied_inside or denied?
        }
      end)
      |> also(seq, event.sequence)
    else
      standalone(state, event)
    end
  end

  defp place(state, :subagent_started, event) do
    agent_id = event[:agent_id]

    if is_binary(agent_id) and not is_map_key(state.open_lanes, agent_id) do
      free = Enum.find(1..(@max_rails - 1), &(not is_map_key(state.rail_lanes, &1)))
      index = state.lane_count + 1

      lane = %{
        index: index,
        id: agent_id,
        type: event[:agent_type],
        rail: free || @max_rails - 1,
        color: Enum.at(@colors, rem(index - 1, length(@colors))),
        overflow: is_nil(free),
        started_seq: event.sequence,
        started_at: event.time,
        finished_seq: nil
      }

      # Past a thousand open agents a runner is not describing a session: the lane is
      # known by its id, and its items say who in words.
      tracked? = map_size(state.open_lanes) < @max_open_lanes

      state = %{
        state
        | lanes: Map.put(state.lanes, index, lane),
          lane_by_id: Map.put(state.lane_by_id, agent_id, index),
          lane_count: index,
          open_lanes:
            if(tracked?, do: Map.put(state.open_lanes, agent_id, index), else: state.open_lanes),
          rail_lanes:
            if(free, do: Map.put(state.rail_lanes, free, index), else: state.rail_lanes),
          rails: if(free, do: max(state.rails, free + 1), else: state.rails)
      }

      push(state, :subagent_started, event, %{opens: not is_nil(free)})
    else
      push(state, :subagent_started, event)
    end
  end

  defp place(state, :subagent_finished, event) do
    agent_id = event[:agent_id]

    case state.open_lanes[agent_id] do
      nil ->
        push(state, :subagent_finished, event)

      index ->
        lane = state.lanes[index]

        state =
          push(state, :subagent_finished, event, %{
            closes: not lane.overflow,
            started_seq: lane.started_seq
          })

        %{
          state
          | open_lanes: Map.delete(state.open_lanes, agent_id),
            rail_lanes:
              if(lane.overflow,
                do: state.rail_lanes,
                else: Map.delete(state.rail_lanes, lane.rail)
              ),
            lanes: Map.put(state.lanes, index, %{lane | finished_seq: event.sequence})
        }
    end
  end

  # A policy applied after the first is a reload: it remembers the one before it, which is
  # what its delta is taken against.
  defp place(state, :policy_applied, event) do
    state
    |> push(:policy_applied, event, %{previous_seq: Map.get(state, :policy_seq)})
    |> Map.put(:policy_seq, event.sequence)
  end

  defp place(state, kind, event), do: push(state, kind, event)

  defp end_call(state, seq, event) do
    state
    |> update_item(seq, &%{&1 | end_seq: event.sequence, no_end: false})
    |> also(seq, event.sequence)
  end

  # Runs of allowed connections to one host with nothing between them read as one row.
  # A denied connection is never folded away, a request refused before it reached a tool
  # included: it is no tool invocation, and its item holds no tool. Tool invocations group
  # only with calls to the same tool, so a group says whose calls it holds.
  defp standalone(state, event) do
    open_calls = map_size(state.open_tools)
    previous = state.order |> List.first() |> then(&(&1 && state.items[&1]))

    if event[:decision] == "allowed" and groups_with?(previous, event, open_calls) do
      state
      |> update_item(previous.seq, fn item ->
        %{
          item
          | kind: :connection_group,
            inner:
              if(item.inner_count < @max_inner,
                do: [event.sequence | item.inner],
                else: item.inner
              ),
            inner_count: item.inner_count + 1,
            last_at: event.time
        }
      end)
      |> also(previous.seq, event.sequence)
    else
      push(state, :connection, event, %{
        open_calls: open_calls,
        host: event[:host],
        port: event[:port],
        tool: if(Runs.tool_invocation?(event[:tool], event[:decision]), do: event[:tool]),
        decision: event[:decision],
        inner: [event.sequence],
        inner_count: 1,
        first_at: event.time,
        last_at: event.time
      })
    end
  end

  defp groups_with?(%{kind: kind, decision: "allowed"} = item, event, open_calls)
       when kind in [:connection, :connection_group] do
    item.host == event[:host] and item.port == event[:port] and item[:tool] == event[:tool] and
      item.open_calls == open_calls
  end

  defp groups_with?(_item, _event, _open_calls), do: false

  defp push(state, kind, event, extra \\ %{}) do
    lane = lane_of(state, kind, event)

    rails =
      [{0, :main} | for({rail, index} <- state.rail_lanes, do: {rail, state.lanes[index].color})]
      |> Enum.sort()

    item =
      Map.merge(
        %{
          seq: event.sequence,
          kind: kind,
          end_seq: nil,
          no_end: false,
          inner: [],
          inner_count: 0,
          denied_inside: false,
          started_seq: nil,
          previous_seq: nil,
          lane: lane,
          open_rails: rails,
          opens: false,
          closes: false,
          open_calls: 0,
          # Who is said in words when the rail cannot say it.
          who:
            kind in [:subagent_started, :subagent_finished] or lane.overflow or
              lane[:unknown] == true
        },
        extra
      )

    %{
      state
      | items: Map.put(state.items, event.sequence, item),
        order: [event.sequence | state.order],
        by_seq: Map.put(state.by_seq, event.sequence, event.sequence),
        session_items: state.session_items + if(session_kind?(kind), do: 1, else: 0)
    }
  end

  defp update_item(state, seq, fun), do: %{state | items: Map.update!(state.items, seq, fun)}
  defp also(state, item_seq, seq), do: %{state | by_seq: Map.put(state.by_seq, seq, item_seq)}

  defp lane_of(_state, kind, _event)
       when kind in [:run_started, :policy_applied, :run_exited, :connection],
       do: @main

  defp lane_of(state, _kind, event) do
    case event[:agent_id] do
      nil ->
        @main

      agent_id ->
        case state.open_lanes[agent_id] do
          nil ->
            # An agent the record opened no lane for: the item says who in words.
            %{
              index: nil,
              id: agent_id,
              type: event[:agent_type],
              rail: shared_rail(state),
              color: :main,
              overflow: false,
              unknown: true
            }

          index ->
            lane = state.lanes[index]
            lane = if lane.overflow, do: %{lane | rail: shared_rail(state)}, else: lane
            Map.take(lane, [:index, :id, :type, :rail, :color, :overflow])
        end
    end
  end

  # Agents without a rail of their own sit on the last rail while it is drawn, else on main.
  defp shared_rail(state),
    do: if(is_map_key(state.rail_lanes, @max_rails - 1), do: @max_rails - 1, else: 0)

  defp finish_item(item, first?, last?, alive?) do
    rails =
      for {rail, color} <- item.open_rails do
        part =
          cond do
            item.opens and rail == item.lane.rail -> :from
            item.closes and rail == item.lane.rail -> :to
            last? and alive? -> :live
            rail != 0 -> :through
            first? -> :from
            last? -> :to
            true -> :through
          end

        %{rail: rail, color: color, part: part}
      end

    inner = Enum.reverse(item.inner)

    tool_state =
      cond do
        item.kind != :tool -> nil
        item.end_seq -> :ended
        item.no_end or not alive? -> :no_end
        true -> :open
      end

    load =
      case item.kind do
        kind when kind in [:connection, :connection_group] ->
          inner

        _ ->
          [item.seq | inner] ++
            List.wrap(item.end_seq) ++ List.wrap(item.started_seq) ++ List.wrap(item.previous_seq)
      end

    item
    |> Map.drop([:open_rails, :opens, :closes, :no_end])
    |> Map.merge(%{
      inner: inner,
      seqs: load |> Enum.uniq() |> Enum.sort(),
      rails: rails,
      tool_state: tool_state,
      link: if(item.opens or item.closes, do: %{rail: item.lane.rail, color: item.lane.color})
    })
  end

  defp session_kind?(kind),
    do: kind not in [:run_started, :policy_applied, :run_exited, :connection, :connection_group]

  ## Background tasks

  # The contract's rule: a task is running from the first list that names it until the
  # first later list that leaves it out. So what is outstanding is the last list given,
  # and each of its tasks keeps the sequence it was first listed at.
  defp background(state, %{background_tasks: tasks} = event) when is_list(tasks) do
    known = Map.new(state.tasks, &{&1.id, &1.listed_at})

    listed =
      for task <- Enum.take(tasks, @max_listed), is_map(task), id = task_id(task) do
        %{
          id: id,
          type: string(task, "type"),
          status: string(task, "status"),
          what: task_what(task),
          listed_at: Map.get(known, id, event.sequence)
        }
      end

    %{state | tasks: Enum.uniq_by(listed, & &1.id)}
  end

  defp background(state, _event), do: state

  defp task_id(task) do
    case task["id"] do
      id when is_binary(id) and id != "" -> bound(id, 64)
      id when is_integer(id) -> Integer.to_string(id)
      _ -> nil
    end
  end

  defp task_what(task) do
    string(task, "what") || string(task, "command") || string(task, "agent_type") ||
      string(task, "subagent_type") || string(task, "description")
  end

  defp outstanding(state) do
    tasks = Enum.sort_by(state.tasks, &{&1.listed_at, &1.id})
    %{tasks: Enum.take(tasks, @max_tasks), count: length(tasks)}
  end

  ## Items

  @doc """
  The full items of `light` items, from `events`, a map of sequence to the slim event
  (see `slim/2`). An item whose first event is missing is left out.

  `full:` is a list of item sequences whose events were read with the larger cap.
  """
  def build(light, events, opts \\ []) when is_list(light) do
    full = opts |> Keyword.get(:full, []) |> MapSet.new()

    for item <- light, event = events[first_sequence(item)], is_map(event) do
      limit = if item.seq in full, do: @full_limit, else: @well_limit

      item
      |> Map.take([:seq, :kind, :lane, :rails, :link, :who, :open_calls, :end_seq, :tool_state])
      |> Map.merge(%{
        id: "e-#{item.seq}",
        sequence: item.seq,
        time: event.time,
        full: item.seq in full
      })
      |> Map.merge(body(item, event, events, limit))
    end
  end

  defp first_sequence(%{seq: seq}), do: seq

  @doc "The sequences `build/3` needs for these light items: at most #{@max_inner + 2} each."
  def needed(light), do: light |> Enum.flat_map(& &1.seqs) |> Enum.uniq()

  defp body(%{kind: :run_started}, event, _events, _limit),
    do: Map.take(event, [:runtime, :runtime_version, :host, :wall])

  defp body(%{kind: :policy_applied} = item, event, events, _limit) do
    previous = item[:previous_seq] && events[item.previous_seq]

    %{
      mode: event.mode,
      source: event.source,
      digest: event[:run_configuration],
      allowed_hosts: event.allow_count || 0,
      denied_hosts: event.deny_count || 0,
      terminated: event.terminated || [],
      terminated_count: event.terminated_count || 0,
      tools:
        for(
          tool <- event.tools || [],
          do: %{name: tool["name"], argument: tool["argument"], hosts: tool["hosts"]}
        ),
      again: is_integer(item[:previous_seq]),
      previous_seq: item[:previous_seq],
      previous_digest: is_map(previous) && previous[:run_configuration],
      was_mode: if(is_map(previous) and previous.mode != event.mode, do: previous.mode),
      delta: if(is_map(previous), do: delta(previous, event))
    }
  end

  defp body(%{kind: :session_started}, event, _events, _limit),
    do: Map.take(event, [:model, :source, :cwd])

  defp body(%{kind: :prompt}, event, _events, limit), do: text(event, limit)

  defp body(%{kind: :tool} = item, event, events, limit) do
    # An item made of an end alone has no start: the one event is both.
    source = event
    ended = if item.end_seq, do: events[item.end_seq]

    status =
      cond do
        is_nil(ended) and item.tool_state == :open -> :open
        is_nil(ended) -> :no_end
        failed?(ended) -> :failed
        true -> :finished
      end

    connections =
      for seq <- item.inner, egress = events[seq], is_map(egress), do: connection(egress)

    %{
      tool: source.tool || gettext("tool"),
      summary: source.summary,
      status: status,
      interrupted: status == :failed and ended.interrupted == true,
      duration_ms: ended && ended.duration_ms,
      in_background: source.in_background == true,
      connections: connections,
      connections_count: item.inner_count,
      denied_inside: item.denied_inside,
      wells: wells(source, ended, status, limit)
    }
  end

  defp body(%{kind: kind} = item, event, events, limit)
       when kind in [:subagent_started, :subagent_finished] do
    started = item.started_seq && events[item.started_seq]

    %{
      agent_id: event.agent_id,
      agent_type: event.agent_type,
      # The lane's length, from the two events' own times.
      duration_ms: started && DateTime.diff(event.time, started.time, :millisecond)
    }
    |> Map.merge(if kind == :subagent_finished, do: text(event, limit), else: %{})
  end

  defp body(%{kind: :notification}, event, _events, _limit),
    do: %{notification_kind: event.kind, message: event.text && bound(event.text, @summary_limit)}

  defp body(%{kind: :turn_finished}, event, _events, limit), do: text(event, limit)

  defp body(%{kind: :turn_failed}, event, _events, limit) do
    %{
      error: event.error && bound(event.error, @summary_limit),
      message: event.text && bound(event.text, @summary_limit),
      wells:
        List.wrap(
          well(
            gettext("details"),
            :text,
            event.details,
            event.details_bytes,
            event.details_lines,
            limit,
            :error
          )
        )
    }
  end

  defp body(%{kind: :result}, event, _events, limit) do
    event
    |> Map.take([:outcome, :turns, :duration_ms, :cost_usd])
    |> Map.merge(text(event, limit))
  end

  defp body(%{kind: :session_ended}, event, _events, _limit), do: %{reason: event.reason}

  defp body(%{kind: :run_exited}, event, _events, _limit),
    do: Map.take(event, [:exit_code, :signal, :reason, :duration_ms])

  defp body(%{kind: :connection}, event, _events, _limit), do: %{connection: connection(event)}

  defp body(%{kind: :connection_group} = item, event, events, _limit) do
    %{
      host: event.host || gettext("n/a"),
      tool: event.tool,
      port: event.port,
      connections:
        for(seq <- item.inner, egress = events[seq], is_map(egress), do: connection(egress)),
      connections_count: item.inner_count,
      first_at: item.first_at,
      last_at: item.last_at
    }
  end

  @doc """
  What a reload changed in the allow list and in the deny list, from the two events alone:
  `%{added:, removed:, added_count:, removed_count:, deny_added:, deny_removed:,
  deny_added_count:, deny_removed_count:}`, the hosts at most #{@max_delta} each side. nil
  when either event listed more hosts than were read (#{@max_allow}) in either list: half
  a list says nothing of what was added.
  """
  def delta(previous, event) do
    with {:ok, allow} <- list_delta(previous, event, :allow, :allow_count),
         {:ok, deny} <- list_delta(previous, event, :deny, :deny_count) do
      Map.merge(allow, %{
        deny_added: deny.added,
        deny_removed: deny.removed,
        deny_added_count: deny.added_count,
        deny_removed_count: deny.removed_count
      })
    else
      :unread -> nil
    end
  end

  defp list_delta(previous, event, key, count) do
    before = previous[key] || []
    now = event[key] || []

    if (previous[count] || 0) > length(before) or (event[count] || 0) > length(now) do
      :unread
    else
      added = Enum.uniq(now -- before)
      removed = Enum.uniq(before -- now)

      {:ok,
       %{
         added: Enum.take(added, @max_delta),
         removed: Enum.take(removed, @max_delta),
         added_count: length(added),
         removed_count: length(removed)
       }}
    end
  end

  @doc """
  One slim egress event as the connection row reads it. `tool` names the tool whose host
  the request was for, and is nil when the event names none; the request is a tool
  invocation when it was also allowed (`Apiary.Runs.tool_invocation?/2`). `status` is what
  the host or the tool answered and `request_id` the proxy's id of the request, when the
  event says.
  """
  def connection(event) do
    %{
      sequence: event.sequence,
      at: event.time,
      host: event.host || gettext("n/a"),
      tool: event.tool,
      status: if(event.status in 100..599, do: event.status),
      request_id: event.request_id,
      port: event.port,
      method: event.method,
      request_method: event.request_method,
      path: event.path || "",
      decision: event.decision,
      rule: event.rule,
      path_rule: event.path_rule,
      credential: event.credential,
      outcome: event.outcome,
      mode: event.mode
    }
  end

  defp failed?(%{type: type}), do: type == @prefix <> "session.tool_failed"

  defp wells(source, ended, status, limit) do
    input = well(gettext("input"), :json, source.input, source.input_bytes, nil, limit)

    result =
      case status do
        :failed ->
          [
            well(
              gettext("error"),
              :text,
              ended.error,
              ended.error_bytes,
              ended.error_lines,
              limit,
              :error
            )
          ]

        :finished ->
          [
            well(
              gettext("response"),
              :text,
              ended.response,
              ended.response_bytes,
              ended.response_lines,
              limit
            ),
            well("stdout", :text, ended.stdout, ended.stdout_bytes, ended.stdout_lines, limit),
            well(
              "stderr",
              :text,
              ended.stderr,
              ended.stderr_bytes,
              ended.stderr_lines,
              limit,
              :error
            ),
            well(
              gettext("response"),
              :json,
              ended.response_json,
              ended.response_json_bytes,
              nil,
              limit
            )
          ]

        _open ->
          []
      end

    Enum.reject([input | result], &is_nil/1)
  end

  defp well(label, format, text, bytes, lines, limit, tone \\ nil)
  defp well(_label, _format, nil, _bytes, _lines, _limit, _tone), do: nil
  defp well(_label, _format, "", _bytes, _lines, _limit, _tone), do: nil

  defp well(label, format, text, bytes, lines, limit, tone) do
    {shown, cut?} = cap(text, limit)
    bytes = bytes || byte_size(text)

    %{
      label: label,
      format: format,
      text: shown,
      bytes: bytes,
      lines: if(format == :text, do: lines),
      cut: cut? or bytes > byte_size(shown),
      tone: tone
    }
  end

  defp text(%{text: text} = event, limit) when is_binary(text) and text != "" do
    {shown, cut?} = cap(text, limit)
    bytes = event[:text_bytes] || byte_size(text)
    %{text: shown, text_bytes: bytes, text_cut: cut? or bytes > byte_size(shown)}
  end

  defp text(_event, _limit), do: %{text: nil, text_bytes: 0, text_cut: false}

  @doc "Cuts `text` at `limit` bytes without splitting a character. `{shown, cut?}`."
  def cap(text, limit) when byte_size(text) <= limit, do: {text, false}
  def cap(text, limit), do: {text |> binary_part(0, limit) |> whole_characters(3), true}

  defp whole_characters(binary, 0), do: binary

  defp whole_characters(binary, tries) do
    if String.valid?(binary) or byte_size(binary) == 0,
      do: binary,
      else: whole_characters(binary_part(binary, 0, byte_size(binary) - 1), tries - 1)
  end

  ## Slim events

  @slim_keys ~w(sequence type time tool agent_id agent_type runtime runtime_version host wall mode source
    model cwd kind outcome reason signal method request_method path decision rule path_rule credential
    request_id port exit_code duration_ms turns status cost_usd interrupted in_background allow
    allow_count deny deny_count run_configuration terminated terminated_count tools summary text
    text_bytes error error_bytes error_lines details details_bytes details_lines input input_bytes response response_bytes response_lines stdout stdout_bytes
    stdout_lines stderr stderr_bytes stderr_lines response_json response_json_bytes)a

  @doc "The keys of a slim event."
  def slim_keys, do: @slim_keys

  @doc """
  A whole event (`%{sequence, type, time, data}`) as a slim one: the shape the query of
  `Apiary.Runs.Record` answers, every payload cut at `limit` characters. For events that
  are already in memory, and the statement of what that query must answer.
  """
  def slim(%{data: data} = event, limit \\ @well_limit) do
    data = if is_map(data), do: data, else: %{}
    input = if is_map(data["input"]), do: data["input"], else: %{}
    response = data["response"]

    body =
      case event.type do
        @prefix <> "session.prompt_submitted" -> data["prompt"]
        @prefix <> "session.result" -> data["result"]
        _ -> data["message"]
      end

    plain =
      cond do
        is_binary(response) ->
          response

        is_map(response) and is_map(response["file"]) and is_binary(response["file"]["content"]) ->
          response["file"]["content"]

        true ->
          nil
      end

    stdout = is_map(response) && is_binary(response["stdout"]) && response["stdout"]
    stderr = is_map(response) && is_binary(response["stderr"]) && response["stderr"]
    shown? = Enum.any?([plain, stdout, stderr], &(is_binary(&1) and &1 != ""))

    json =
      if not is_nil(response) and not is_binary(response) and not shown? and response != %{},
        do: Jason.encode!(response, pretty: true)

    terminated = if is_list(data["terminated"]), do: data["terminated"], else: []

    Map.new(@slim_keys, &{&1, nil})
    |> Map.merge(%{sequence: event.sequence, type: event.type, time: event.time})
    |> Map.merge(
      for key <-
            ~w(tool agent_id agent_type runtime runtime_version host wall mode source model cwd kind
            outcome reason signal method request_method path decision rule path_rule credential
            request_id),
          into: %{} do
        {String.to_existing_atom(key), string(data, key)}
      end
    )
    |> Map.merge(
      for key <- ~w(port exit_code duration_ms turns status)a,
          into: %{},
          do: {key, integer(data, Atom.to_string(key))}
    )
    |> Map.merge(%{
      cost_usd: if(is_number(data["cost_usd"]), do: data["cost_usd"]),
      interrupted: data["interrupted"] == true,
      in_background: input["run_in_background"] == true,
      allow: hosts(data["allow"]),
      allow_count: if(is_list(data["allow"]), do: length(data["allow"]), else: 0),
      deny: hosts(data["deny"]),
      deny_count: if(is_list(data["deny"]), do: length(data["deny"]), else: 0),
      run_configuration: string(data, "run_configuration"),
      terminated:
        terminated |> Enum.filter(&is_binary/1) |> Enum.take(5) |> Enum.map(&bound(&1, 120)),
      terminated_count: length(terminated),
      tools:
        if(event.type == @prefix <> "run.policy_applied",
          do: named_hosts(data["tools"]),
          else: []
        ),
      summary: tool_summary(string(data, "tool"), input, first_string(input))
    })
    |> Map.merge(slim_text(:text, body, limit, false))
    |> Map.merge(slim_text(:error, data["error"], limit, true))
    |> Map.merge(slim_text(:details, data["details"], limit, true))
    |> Map.merge(
      slim_text(:input, if(input != %{}, do: Jason.encode!(input, pretty: true)), limit, false)
    )
    |> Map.merge(slim_text(:response, plain, limit, true))
    |> Map.merge(slim_text(:stdout, stdout || nil, limit, true))
    |> Map.merge(slim_text(:stderr, stderr || nil, limit, true))
    |> Map.merge(slim_text(:response_json, json, limit, false))
  end

  defp slim_text(key, text, limit, lines?) when is_binary(text) and text != "" do
    base = %{key => String.slice(text, 0, limit), :"#{key}_bytes" => byte_size(text)}
    if lines?, do: Map.put(base, :"#{key}_lines", lines(text)), else: base
  end

  defp slim_text(_key, _text, _limit, _lines?), do: %{}

  defp lines(text) do
    breaks = text |> :binary.matches("\n") |> length()
    if String.ends_with?(text, "\n"), do: breaks, else: breaks + 1
  end

  @doc """
  The one-line summary of a tool call, chosen per tool from the fields of its input,
  copied, never rewritten: `{:text, s}`, `{:pattern, pattern, path}` or nil. `input` holds
  the strings of the input by key and `first` its first string by key, for a tool
  this module has no rule for.
  """
  def tool_summary(tool, input, first) do
    case tool do
      "Bash" -> field(input, "command")
      tool when tool in ~w(Read Edit Write MultiEdit NotebookEdit) -> field(input, "file_path")
      tool when tool in ~w(Grep Glob) -> pattern(input)
      "WebFetch" -> field(input, "url")
      tool when tool in ~w(Task Agent) -> field(input, "description")
      _ -> nil
    end || (is_binary(first) and first != "" and {:text, bound(first, @summary_limit)}) || nil
  end

  defp field(input, key) do
    case input[key] do
      value when is_binary(value) and value != "" -> {:text, bound(value, @summary_limit)}
      _ -> nil
    end
  end

  defp pattern(input) do
    with {:text, pattern} <- field(input, "pattern") do
      case field(input, "path") do
        {:text, path} -> {:pattern, pattern, path}
        nil -> {:text, pattern}
      end
    end
  end

  # The first string of the input, by key in byte order.
  defp first_string(input) do
    input
    |> Enum.sort()
    |> Enum.find_value(fn {_key, value} -> if is_binary(value) and value != "", do: value end)
  end

  ## Reading untrusted data

  # The allow or deny list of a policy applied event, bounded like everything a runner sends.
  defp hosts(list) when is_list(list) do
    # Cut as the query cuts them (`left(v, 255)`), so a delta is the same either way.
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_allow)
    |> Enum.map(&String.slice(&1, 0, 255))
  end

  defp hosts(_other), do: []

  # The tools of a policy applied event as the query reads them: the first twenty objects
  # with a string name, each `%{"name", "argument", "hosts"}`, the name cut at 120
  # characters, the argument at 256 code points with `…` (nil when there is
  # none) and the first ten string hosts at 255.
  defp named_hosts(list) when is_list(list) do
    for item <- list, is_map(item), is_binary(item["name"]) do
      hosts = if is_list(item["hosts"]), do: item["hosts"], else: []

      %{
        "name" => String.slice(item["name"], 0, 120),
        "argument" =>
          case item["argument"] do
            argument when is_binary(argument) and argument != "" ->
              bound_codepoints(argument, @max_argument)

            _ ->
              nil
          end,
        "hosts" =>
          hosts
          |> Enum.filter(&is_binary/1)
          |> Enum.take(10)
          |> Enum.map(&String.slice(&1, 0, 255))
      }
    end
    |> Enum.take(20)
  end

  defp named_hosts(_other), do: []

  defp string(data, key) when is_map(data) do
    case data[key] do
      value when is_binary(value) and value != "" -> String.slice(value, 0, @summary_limit)
      _ -> nil
    end
  end

  defp string(_data, _key), do: nil

  defp integer(data, key) do
    case data[key] do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp bound(value, limit) do
    if String.length(value) > limit, do: String.slice(value, 0, limit) <> "…", else: value
  end

  # Cut at `limit` code points, as the database's `left/2` counts, with `…` when cut.
  defp bound_codepoints(value, limit) do
    case skip_codepoints(value, limit) do
      "" -> value
      rest -> binary_part(value, 0, byte_size(value) - byte_size(rest)) <> "…"
    end
  end

  defp skip_codepoints(rest, 0), do: rest
  defp skip_codepoints(<<_::utf8, rest::binary>>, n), do: skip_codepoints(rest, n - 1)
  defp skip_codepoints(<<_, rest::binary>>, n), do: skip_codepoints(rest, n - 1)
  defp skip_codepoints(<<>>, _n), do: <<>>
end
