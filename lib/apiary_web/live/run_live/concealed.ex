defmodule ApiaryWeb.RunLive.Concealed do
  @moduledoc """
  A run's timeline items as the run page shows them to a reader who may not read the run's
  log (`run.read_log`): the session's texts belong to the Terminal, which is hidden from
  that reader.

  An item of the session keeps the fields its kind lists here: its kind, tool, agent,
  status, times and counts, and the places of the timeline. Every other field is set to
  nil, and `wells` to an empty list, before the item is rendered, so a field added to an
  item later is blank for this reader until it is listed. A field that the Timeline must
  read for such a reader goes on its kind's list, and only when it is no text the run
  produced.

  The Main session row (`Apiary.Runs.Record.Overview`) keeps how many calls the main
  agent made and how long its session took; the first line of its last text is blank.

  Items of other kinds are kept whole: the run's start and end, a policy applied, a
  session's start and end, a connection, and a Pushed row, whose artifact type, name and
  version number are no text of the session.
  """

  # The fields of every item (`Apiary.Runs.Record.Timeline.build/3`), and the page's.
  @common ~w(id seq sequence kind lane rails link who open_calls end_seq tool_state part sub
             group time full line session open)a

  @kept %{
    prompt: [],
    text: [:truncated],
    thinking: [:truncated],
    tool: [
      :tool,
      :status,
      :interrupted,
      :duration_ms,
      :in_background,
      :connections,
      :connections_count,
      :denied_inside
    ],
    subagent_started: [:agent_id, :agent_type, :duration_ms],
    subagent_finished: [:agent_id, :agent_type, :duration_ms],
    turn_finished: [],
    turn_failed: [],
    notification: [:notification_kind],
    result: [:outcome, :turns, :duration_ms, :cost_usd],
    main_session: [:calls, :duration_ms]
  }

  @doc "The item as the reader who may not read the log is shown it."
  @spec item(map) :: map
  def item(%{kind: kind} = item) when is_map_key(@kept, kind) do
    kept = @common ++ Map.fetch!(@kept, kind)

    Map.new(item, fn {key, value} ->
      cond do
        key in kept -> {key, value}
        key == :wells -> {key, []}
        true -> {key, nil}
      end
    end)
  end

  def item(item), do: item

  @doc "The fields an item of `kind` keeps for that reader, or `:all` for a kind kept whole."
  @spec kept(atom) :: [atom] | :all
  def kept(kind) do
    case Map.fetch(@kept, kind) do
      {:ok, fields} -> @common ++ fields
      :error -> :all
    end
  end

  @doc """
  The background tasks of the timeline index for that reader: what a task runs is left
  out, and its type and id stay.
  """
  @spec tasks(map) :: map
  def tasks(%{tasks: tasks} = background),
    do: %{background | tasks: Enum.map(tasks, &%{&1 | what: nil})}
end
