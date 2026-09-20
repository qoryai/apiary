defmodule Apiary.Runs.Record.Timeline do
  @moduledoc """
  The session timeline of one run, folded from its events. Pure: no query is made here.

  It works in two steps, because a run may hold thousands of events and a page shows a
  window of them:

    * `index/2` reads every event of the run in a light form (its sequence, type, time and
      the few ids that pair events up) and lays the whole run out: which events make one
      item, which lane an item sits on, which rails pass it, where a connection goes,
      which background tasks are outstanding. The layout is of the run, not of a window,
      so rails are right at a window's edge.
    * `build/4` makes the items of a window from the full events, with every payload
      bounded.

  Pairing uses ids only: `tool_use_id` for the three tool events, `agent_id` for the two
  subagent events. Order is the events' `sequence`, never a clock. A connection is placed
  inside a tool call only when exactly one call is open at its sequence; that says
  *while*, never *because*. Heartbeats, log chunks, the ping and types this module has
  not heard of are not items.

  Everything that comes out of an event is the runner's input and is treated as such:
  strings are bounded, nothing becomes an atom, and nothing here is marked safe.
  """

  @prefix "ai.qory."

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
  @main %{id: "main", type: nil, rail: 0, color: :main, overflow: false}

  @well_limit 8 * 1024
  @full_limit 512 * 1024
  @summary_limit 400
  @max_inner 100
  @max_tasks 20

  @doc "The bytes of a payload a well shows before \"Show all\"."
  def well_limit, do: @well_limit

  @doc "The event types the index needs, without the `ai.qory.` prefix."
  def types, do: Map.keys(@kinds)

  @doc "The kind of item an event type makes, or nil when it makes none."
  def kind(@prefix <> type), do: Map.get(@kinds, type)
  def kind(_type), do: nil

  ## The index

  @doc """
  Lays the run out. `events` are light events in sequence order, maps with `:sequence`,
  `:type`, `:time` and, where the event has them, `:tool_use_id`, `:agent_id`,
  `:agent_type`, `:background_tasks` (a list, or nil when the event gives none), `:host`,
  `:port` and `:decision`. `alive:` says whether the record is still being written, which
  fades the rails of the last item.

  Returns a map:

    * `:items`: the light items in order, each `%{seq, kind, seqs, end_seq, inner, lane,
      rails, link, who, open_calls}`; `seq` is the item's id, the sequence of its first
      event, and `seqs` every sequence it is made of;
    * `:by_seq`: every sequence that belongs to an item, to that item's `seq`;
    * `:lanes`: `%{id, type, rail, color, started_seq, finished_seq}`, main first;
    * `:rails`: how many rails the gutter needs, one to four;
    * `:session_items`: how many items are the session's (not the runner's, not egress);
    * `:hook_events`: how many session events came from the runtime's hooks;
    * `:background`: `%{tasks: [...], more: n}`, the tasks of the last list the runtime
      gave, each with the sequence it was first listed at.
  """
  def index(events, opts \\ []) do
    alive? = Keyword.get(opts, :alive, false)

    acc =
      Enum.reduce(events, new_acc(), fn event, acc ->
        acc = background(acc, event)

        case kind(event.type) do
          nil -> acc
          kind -> acc |> count(event) |> place(kind, event)
        end
      end)

    items =
      acc.items
      |> Enum.reverse()
      |> Enum.map(&finish_item(&1, acc))
      |> collapse()
      |> ends(alive?)

    %{
      items: items,
      by_seq: for(item <- items, seq <- item.seqs, into: %{}, do: {seq, item.seq}),
      lanes: [Map.merge(@main, %{started_seq: nil, finished_seq: nil}) | Enum.reverse(acc.lanes)],
      rails: acc.rails,
      session_items: Enum.count(items, &session_kind?(&1.kind)),
      hook_events: acc.hook_events,
      background: outstanding(acc)
    }
  end

  defp new_acc do
    %{
      items: [],
      # tool_use_id => the seq of the item the call opened
      open_tools: %{},
      # item seq => %{end_seq, inner (reversed)}
      tools: %{},
      # agent_id => lane, while the agent is open
      open_lanes: %{},
      lanes: [],
      subagents: 0,
      rails: 1,
      hook_events: 0,
      tasks: %{},
      task_order: []
    }
  end

  defp count(acc, %{type: @prefix <> "session." <> _ = type}) do
    if type == @prefix <> @not_from_a_hook,
      do: acc,
      else: %{acc | hook_events: acc.hook_events + 1}
  end

  defp count(acc, _event), do: acc

  defp place(acc, :tool, %{type: @prefix <> "session.tool_started"} = event) do
    id = event[:tool_use_id]
    acc = push(acc, :tool, event)

    if is_binary(id) and not is_map_key(acc.open_tools, id),
      do: %{acc | open_tools: Map.put(acc.open_tools, id, event.sequence)},
      else: acc
  end

  defp place(acc, :tool, event) do
    case Map.pop(acc.open_tools, event[:tool_use_id]) do
      {nil, _open} ->
        # An end without its start: the record lacks it, so the item is the end alone.
        push(acc, :tool, event)

      {seq, open} ->
        tools =
          Map.update(
            acc.tools,
            seq,
            %{end_seq: event.sequence, inner: []},
            &%{&1 | end_seq: event.sequence}
          )

        %{acc | open_tools: open, tools: tools}
    end
  end

  defp place(acc, :connection, event) do
    case Map.values(acc.open_tools) do
      [seq] ->
        tools =
          Map.update(acc.tools, seq, %{end_seq: nil, inner: [event.sequence]}, fn tool ->
            %{tool | inner: [event.sequence | tool.inner]}
          end)

        %{acc | tools: tools}

      open ->
        push(acc, :connection, event, %{
          open_calls: length(open),
          host: event[:host],
          port: event[:port],
          decision: event[:decision]
        })
    end
  end

  defp place(acc, :subagent_started, event) do
    agent_id = event[:agent_id]

    if is_binary(agent_id) and not is_map_key(acc.open_lanes, agent_id) do
      taken =
        acc.open_lanes |> Map.values() |> Enum.reject(& &1.overflow) |> MapSet.new(& &1.rail)

      free = Enum.find(1..(@max_rails - 1), &(&1 not in taken))

      lane = %{
        id: agent_id,
        type: event[:agent_type],
        rail: free || @max_rails - 1,
        color: Enum.at(@colors, rem(acc.subagents, length(@colors))),
        overflow: is_nil(free),
        started_seq: event.sequence,
        finished_seq: nil
      }

      acc = %{
        acc
        | open_lanes: Map.put(acc.open_lanes, agent_id, lane),
          lanes: [lane | acc.lanes],
          subagents: acc.subagents + 1,
          rails: max(acc.rails, lane.rail + 1)
      }

      push(acc, :subagent_started, event, %{opens: !lane.overflow})
    else
      push(acc, :subagent_started, event)
    end
  end

  defp place(acc, :subagent_finished, event) do
    agent_id = event[:agent_id]

    case acc.open_lanes[agent_id] do
      nil ->
        push(acc, :subagent_finished, event)

      lane ->
        acc = push(acc, :subagent_finished, event, %{closes: !lane.overflow})

        lanes =
          Enum.map(acc.lanes, fn
            %{id: ^agent_id, finished_seq: nil} = open -> %{open | finished_seq: event.sequence}
            other -> other
          end)

        %{acc | open_lanes: Map.delete(acc.open_lanes, agent_id), lanes: lanes}
    end
  end

  defp place(acc, kind, event), do: push(acc, kind, event)

  defp push(acc, kind, event, extra \\ %{}) do
    lane = lane_of(acc, kind, event)

    rails =
      [
        {0, :main}
        | for({_id, open} <- acc.open_lanes, !open.overflow, do: {open.rail, open.color})
      ]
      |> Enum.sort()

    item =
      Map.merge(
        %{
          seq: event.sequence,
          kind: kind,
          seqs: [event.sequence],
          end_seq: nil,
          inner: [],
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

    %{acc | items: [item | acc.items]}
  end

  defp lane_of(_acc, kind, _event)
       when kind in [:run_started, :policy_applied, :run_exited, :connection],
       do: @main

  defp lane_of(acc, _kind, event) do
    case event[:agent_id] do
      nil ->
        @main

      agent_id ->
        case acc.open_lanes[agent_id] do
          nil ->
            # An agent the record never opened a lane for: the item sits on the main rail
            # and says who in words.
            %{
              id: agent_id,
              type: event[:agent_type],
              rail: 0,
              color: :main,
              overflow: false,
              unknown: true
            }

          lane ->
            Map.take(lane, [:id, :type, :rail, :color, :overflow])
        end
    end
  end

  defp finish_item(item, acc) do
    tool = Map.get(acc.tools, item.seq, %{end_seq: nil, inner: []})
    inner = Enum.reverse(tool.inner)

    rails =
      for {rail, color} <- item.open_rails do
        part =
          cond do
            item.opens and rail == item.lane.rail -> :from
            item.closes and rail == item.lane.rail -> :to
            true -> :through
          end

        %{rail: rail, color: color, part: part}
      end

    link = if item.opens or item.closes, do: %{rail: item.lane.rail, color: item.lane.color}

    item
    |> Map.drop([:open_rails, :opens, :closes])
    |> Map.merge(%{
      end_seq: tool.end_seq,
      inner: inner,
      seqs: Enum.sort([item.seq | inner] ++ List.wrap(tool.end_seq)),
      rails: rails,
      link: link
    })
  end

  # Runs of allowed connections to one host with nothing between them read as one row.
  # A denied connection is never folded away.
  defp collapse(items) do
    items
    |> Enum.chunk_while(
      [],
      fn item, run ->
        cond do
          run == [] -> {:cont, [item]}
          groupable?(item) and same_destination?(hd(run), item) -> {:cont, [item | run]}
          true -> {:cont, Enum.reverse(run), [item]}
        end
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
    |> Enum.map(fn
      [item] -> item
      [first | _] = run -> %{first | kind: :connection_group, seqs: Enum.map(run, & &1.seq)}
    end)
  end

  defp groupable?(item), do: item.kind == :connection and item[:decision] == "allowed"

  defp same_destination?(a, b) do
    groupable?(a) and a[:host] == b[:host] and a[:port] == b[:port] and
      a.open_calls == b.open_calls
  end

  # The main rail starts at the first item and stops at the last; while the record is
  # still being written the last item's rails fade instead.
  defp ends([], _alive?), do: []

  defp ends(items, alive?) do
    last = length(items) - 1

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, i} ->
      rails =
        Enum.map(item.rails, fn rail ->
          cond do
            i == last and alive? and rail.part == :through -> %{rail | part: :live}
            rail.rail != 0 -> rail
            i == 0 -> %{rail | part: :from}
            i == last -> %{rail | part: :to}
            true -> rail
          end
        end)

      %{item | rails: rails}
    end)
  end

  defp session_kind?(kind),
    do: kind not in [:run_started, :policy_applied, :run_exited, :connection, :connection_group]

  ## Background tasks

  # The contract's rule: a task is running from the first list that names it until the
  # first later list that leaves it out.
  defp background(acc, %{background_tasks: tasks} = event) when is_list(tasks) do
    listed =
      for task <- tasks, is_map(task), id = task_id(task), into: %{} do
        {id, task}
      end

    kept =
      for {id, task} <- listed, into: %{} do
        {id, %{task: task, listed_at: get_in(acc.tasks, [id, :listed_at]) || event.sequence}}
      end

    order =
      Enum.filter(acc.task_order, &is_map_key(kept, &1)) ++ (Map.keys(listed) -- acc.task_order)

    %{acc | tasks: kept, task_order: order}
  end

  defp background(acc, _event), do: acc

  defp task_id(task) do
    case task["id"] do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      _ -> nil
    end
  end

  defp outstanding(acc) do
    tasks =
      for id <- acc.task_order do
        %{task: task, listed_at: listed_at} = acc.tasks[id]

        %{
          id: bound(id, 64),
          type: string(task, "type"),
          status: string(task, "status"),
          what:
            string(task, "command") || string(task, "agent_type") || string(task, "subagent_type") ||
              string(task, "description"),
          listed_at: listed_at
        }
      end

    %{tasks: Enum.take(tasks, @max_tasks), count: length(tasks)}
  end

  ## Items

  @doc """
  The full items of `light` items, from `events`, a map of sequence to the stored event
  (`%{sequence, type, time, data}`). An item whose first event is missing is left out.

  `full:` is a list of item sequences whose payloads are not cut at #{@well_limit} bytes
  (they are still cut at #{@full_limit}).
  """
  def build(light, events, opts \\ []) when is_list(light) do
    full = opts |> Keyword.get(:full, []) |> MapSet.new()

    for item <- light, event = events[item.seq], is_map(event) do
      limit = if item.seq in full, do: @full_limit, else: @well_limit

      item
      |> Map.take([:seq, :kind, :lane, :rails, :link, :who, :open_calls, :end_seq])
      |> Map.merge(%{
        id: "e-#{item.seq}",
        sequence: item.seq,
        time: event.time,
        full: item.seq in full
      })
      |> Map.merge(body(item, event, events, limit))
    end
  end

  defp body(%{kind: :run_started}, %{data: data}, _events, _limit) do
    %{
      runtime: string(data, "runtime"),
      runtime_version: string(data, "runtime_version"),
      host: string(data, "host"),
      wall: string(data, "wall")
    }
  end

  defp body(%{kind: :policy_applied}, %{data: data}, _events, _limit) do
    %{
      mode: string(data, "mode"),
      source: string(data, "source"),
      allowed_hosts: data |> list("allow") |> length(),
      terminated:
        data
        |> list("terminated")
        |> Enum.filter(&is_binary/1)
        |> Enum.take(5)
        |> Enum.map(&bound(&1, 120)),
      terminated_count: data |> list("terminated") |> length()
    }
  end

  defp body(%{kind: :session_started}, %{data: data}, _events, _limit) do
    %{model: string(data, "model"), source: string(data, "source"), cwd: string(data, "cwd")}
  end

  defp body(%{kind: :prompt}, %{data: data}, _events, limit), do: text(data, "prompt", limit)

  defp body(%{kind: :tool} = item, event, events, limit) do
    ended = item.end_seq && events[item.end_seq]
    # An item made of an end alone has no start: the one event is both.
    {started, ended} = if started?(event), do: {event, ended}, else: {nil, event}
    source = started || ended
    input = map(source.data, "input")

    status =
      cond do
        is_nil(ended) -> :open
        failed?(ended) -> :failed
        true -> :finished
      end

    connections =
      for seq <- item.inner, egress = events[seq], is_map(egress), do: connection(egress)

    %{
      tool: string(source.data, "tool") || "tool",
      summary: tool_summary(string(source.data, "tool"), input),
      status: status,
      interrupted: status == :failed and ended.data["interrupted"] == true,
      duration_ms: ended && integer(ended.data, "duration_ms"),
      in_background: input["run_in_background"] == true,
      connections: Enum.take(connections, @max_inner),
      connections_count: length(item.inner),
      denied_inside: Enum.any?(connections, &(&1.decision == "denied")),
      wells: wells(input, ended, status, limit)
    }
  end

  defp body(%{kind: kind}, %{data: data} = event, events, limit)
       when kind in [:subagent_started, :subagent_finished] do
    started_seq = kind == :subagent_finished && started_sequence(events, data, event.sequence)
    started = started_seq && events[started_seq]

    %{
      agent_id: string(data, "agent_id"),
      agent_type: string(data, "agent_type"),
      # The lane's length, from the two events' own times.
      duration_ms: started && DateTime.diff(event.time, started.time, :millisecond)
    }
    |> Map.merge(if kind == :subagent_finished, do: text(data, "message", limit), else: %{})
  end

  defp body(%{kind: :notification}, %{data: data}, _events, _limit) do
    %{notification_kind: string(data, "kind"), message: string(data, "message")}
  end

  defp body(%{kind: :turn_finished}, %{data: data}, _events, limit),
    do: text(data, "message", limit)

  defp body(%{kind: :turn_failed}, %{data: data}, _events, limit) do
    details = data["details"]

    %{
      error: string(data, "error"),
      message: string(data, "message"),
      wells:
        if(is_binary(details) and details != "",
          do: [well("details", {:text, details}, limit, :error)],
          else: []
        )
    }
  end

  defp body(%{kind: :result}, %{data: data}, _events, limit) do
    %{
      outcome: string(data, "outcome"),
      turns: integer(data, "turns"),
      duration_ms: integer(data, "duration_ms"),
      cost_usd: number(data, "cost_usd")
    }
    |> Map.merge(text(data, "result", limit))
  end

  defp body(%{kind: :session_ended}, %{data: data}, _events, _limit),
    do: %{reason: string(data, "reason")}

  defp body(%{kind: :run_exited}, %{data: data}, _events, _limit) do
    %{
      exit_code: integer(data, "exit_code"),
      signal: string(data, "signal"),
      reason: string(data, "reason"),
      duration_ms: integer(data, "duration_ms")
    }
  end

  defp body(%{kind: :connection}, event, _events, _limit), do: %{connection: connection(event)}

  defp body(%{kind: :connection_group} = item, _event, events, _limit) do
    connections =
      for seq <- item.seqs, egress = events[seq], is_map(egress), do: connection(egress)

    first = List.first(connections)

    %{
      host: first && first.host,
      port: first && first.port,
      connections: Enum.take(connections, @max_inner),
      connections_count: length(item.seqs),
      first_at: first && first.at,
      last_at: connections |> List.last() |> then(&(&1 && &1.at))
    }
  end

  # The sequence of the `subagent_started` of the agent an event names: the window loads
  # it beside the finish, see `needed/1`.
  defp started_sequence(events, data, before) do
    agent_id = data["agent_id"]

    events
    |> Enum.filter(fn {seq, event} ->
      seq < before and event.type == @prefix <> "session.subagent_started" and
        is_map(event.data) and event.data["agent_id"] == agent_id
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.max(fn -> nil end)
  end

  @doc """
  The sequences `build/3` needs for these light items: every event the items are made of
  and, for a subagent's finish, the lane's start, which `lanes` knows.
  """
  def needed(light, lanes) do
    starts =
      for lane <- lanes, lane.finished_seq, into: %{}, do: {lane.finished_seq, lane.started_seq}

    light
    |> Enum.flat_map(fn item -> item.seqs ++ List.wrap(starts[item.seq]) end)
    |> Enum.uniq()
  end

  @doc "One egress event as the connection row reads it."
  def connection(%{data: data} = event) do
    %{
      sequence: event.sequence,
      at: event.time,
      host: string(data, "host") || "n/a",
      port: integer(data, "port"),
      method: string(data, "method"),
      request_method: string(data, "request_method"),
      path: string(data, "path") || "",
      decision: string(data, "decision"),
      rule: string(data, "rule"),
      path_rule: string(data, "path_rule"),
      credential: string(data, "credential"),
      outcome: string(data, "outcome"),
      mode: string(data, "mode")
    }
  end

  defp started?(%{type: type}), do: type == @prefix <> "session.tool_started"
  defp failed?(%{type: type}), do: type == @prefix <> "session.tool_failed"

  # Chosen per tool from the input, copied, never rewritten.
  defp tool_summary(tool, input) do
    case tool do
      "Bash" -> field(input, "command")
      tool when tool in ~w(Read Edit Write MultiEdit NotebookEdit) -> field(input, "file_path")
      tool when tool in ~w(Grep Glob) -> pattern(input)
      "WebFetch" -> field(input, "url")
      tool when tool in ~w(Task Agent) -> field(input, "description")
      _ -> nil
    end || first_string(input)
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

  defp first_string(input) do
    input
    |> Enum.sort()
    |> Enum.find_value(fn {_key, value} ->
      if is_binary(value) and value != "", do: {:text, bound(value, @summary_limit)}
    end)
  end

  defp wells(input, ended, status, limit) do
    input_well = if map_size(input) > 0, do: [well("input", {:json, input}, limit)], else: []

    result =
      case status do
        :open ->
          []

        :failed ->
          case ended.data["error"] do
            error when is_binary(error) and error != "" ->
              [well("error", {:text, error}, limit, :error)]

            _ ->
              []
          end

        :finished ->
          response_wells(ended.data["response"], limit)
      end

    input_well ++ result
  end

  defp response_wells(nil, _limit), do: []
  defp response_wells("", _limit), do: []

  defp response_wells(text, limit) when is_binary(text),
    do: [well("response", {:text, text}, limit)]

  # A file the tool read: its content, as the response carries it.
  defp response_wells(%{"file" => %{"content" => content}}, limit)
       when is_binary(content) and content != "",
       do: [well("response", {:text, content}, limit)]

  defp response_wells(%{} = response, limit) do
    pair =
      for key <- ~w(stdout stderr), text = response[key], is_binary(text), text != "" do
        well(key, {:text, text}, limit, if(key == "stderr", do: :error))
      end

    cond do
      pair != [] -> pair
      map_size(response) == 0 -> []
      true -> [well("response", {:json, response}, limit)]
    end
  end

  defp response_wells(other, limit), do: [well("response", {:json, other}, limit)]

  defp well(label, {format, value}, limit, tone \\ nil) do
    whole =
      case format do
        :text -> value
        :json -> Jason.encode!(value, pretty: true)
      end

    {shown, cut?} = cap(whole, limit)

    %{
      label: label,
      format: format,
      text: shown,
      bytes: byte_size(whole),
      lines: if(format == :text, do: lines(whole)),
      cut: cut?,
      tone: tone
    }
  end

  defp text(data, key, limit) do
    case data[key] do
      whole when is_binary(whole) and whole != "" ->
        {shown, cut?} = cap(whole, limit)
        %{text: shown, text_bytes: byte_size(whole), text_cut: cut?}

      _ ->
        %{text: nil, text_bytes: 0, text_cut: false}
    end
  end

  defp lines(""), do: 0

  defp lines(text) do
    breaks = text |> :binary.matches("\n") |> length()
    if String.ends_with?(text, "\n"), do: breaks, else: breaks + 1
  end

  @doc "Cuts `text` at `limit` bytes without splitting a character. `{shown, cut?}`."
  def cap(text, limit) when byte_size(text) <= limit, do: {text, false}
  def cap(text, limit), do: {text |> binary_part(0, limit) |> whole_characters(3), true}

  defp whole_characters(binary, 0), do: binary

  defp whole_characters(binary, tries) do
    if String.valid?(binary) or byte_size(binary) == 0,
      do: binary,
      else: whole_characters(binary_part(binary, 0, byte_size(binary) - 1), tries - 1)
  end

  ## Reading untrusted data

  defp string(data, key) when is_map(data) do
    case data[key] do
      value when is_binary(value) and value != "" -> bound(value, @summary_limit)
      _ -> nil
    end
  end

  defp string(_data, _key), do: nil

  defp integer(data, key) when is_map(data) do
    case data[key] do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp integer(_data, _key), do: nil

  defp number(data, key) when is_map(data) do
    case data[key] do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp map(data, key) when is_map(data) do
    case data[key] do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp map(_data, _key), do: %{}

  defp list(data, key) when is_map(data) do
    case data[key] do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp list(_data, _key), do: []

  defp bound(value, limit) do
    if String.length(value) > limit, do: String.slice(value, 0, limit) <> "…", else: value
  end
end
