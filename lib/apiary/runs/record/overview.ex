defmodule Apiary.Runs.Record.Overview do
  @moduledoc """
  The rows of a run's Timeline, an overview of the run, from the light items of
  `Apiary.Runs.Record.Timeline.index/2`. Pure: no query is made here, and nothing of a
  page is read.

  The Timeline lists the events of the run and of its session, one row per agent, the
  agents' messages, the artifact versions the run pushed, failures and denials, and each
  tool call that was the only open call at a connection. Every other tool call is in the
  Terminal only.

    * `rows/2` keeps the items the Timeline lists; `routine?/1` is true of a tool call it
      leaves out.
    * `list/2` adds the Main session row and a Pushed row per artifact version. How many
      rows it returns is the Timeline tab's count.
    * `build/2` makes the Main session and Pushed rows a page shows. `Timeline.build/3`
      skips them, because no event has their sequence.
    * `terminal_seq/2` is the sequence a row links to in the Terminal, or nil.
    * `focus/3` is where `?seq=` goes on the Timeline.

  A Main session or Pushed row has `seq: nil`, an `id` that is unique on the page, and a
  `pos`: its place among the rows, which the window of the run page compares as it
  compares `{seq, seq}` (`ApiaryWeb.RunLive.Show`).
  """

  alias Apiary.Runs.Record.Timeline

  @main_id "main-session"

  @doc """
  Whether a tool call is one the Timeline leaves out, for the Terminal only: a call that
  finished, or one still running, with no connection and no denied connection inside.
  A call that failed, was denied, or has no end in a record that stopped being written,
  or after its session or the run ended, is listed. A call to the subagent tool (`Task`
  or `Agent`) follows the same rule: its subagent has a row of the Timeline. An item that
  is not a tool call is never routine.
  """
  def routine?(%{kind: :tool} = item) do
    item.inner_count == 0 and not item.denied_inside and
      (item.tool_state == :open or (item.tool_state == :ended and item.end_type == :finished))
  end

  def routine?(_item), do: false

  @doc """
  The items of `items`, `Timeline.index/2`'s light items in order, that the Timeline
  lists: every item but thinking and the calls of `routine?/1`. A connection outside a
  call, or a group of them, is listed when it was denied; an allowed one only with
  `connections: true`, while the reader has Connections inline on (`?cx=1`).
  """
  def rows(items, opts \\ []) do
    connections? = Keyword.get(opts, :connections, false)
    Enum.filter(items, &listed?(&1, connections?))
  end

  defp listed?(%{kind: :thinking}, _connections?), do: false
  defp listed?(%{kind: :tool} = item, _connections?), do: not routine?(item)

  defp listed?(%{kind: kind} = item, connections?)
       when kind in [:connection, :connection_group],
       do: connections? or item[:decision] == "denied"

  defp listed?(_item, _connections?), do: true

  @doc """
  The rows the Timeline lists, every subagent open: `rows/2`, with the Main session row
  after the first prompt of the main agent, and a Pushed row for each of `versions:`.

  The Main session row, `kind: :main_session`, is the main agent's: `sequence` is its
  prompt's, `calls` how many tool calls the main agent made, routine ones included,
  `text_seq` the sequence of the main agent's last text, nil while there is none, and
  `result_seqs` the sequences of the main agent's results, in order. `seqs` are those
  sequences, whose built items `build/2` takes.

  `versions:` are the artifact versions the run pushed, each `%{type, name, number,
  at}` and `public_id`. A Pushed row, `kind: :pushed`, has those fields but `public_id`,
  the id `push-` and `public_id` (a version without one: its place in the order below),
  and no sequence. It sits after the last row whose `at` is at or before the version's,
  and before every row when there is none; two versions in one place are in order of
  `at`, then `number`.

  The rails of a Main session or Pushed row continue those of the row before it. When
  the index's last item is not listed, the last row ends the rails as that item does.
  """
  def list(items, opts \\ []) do
    items
    |> rows(opts)
    |> with_main(items)
    |> with_pushed(Keyword.get(opts, :versions, []))
    |> place()
    |> end_rails(List.last(items))
  end

  @doc """
  The Main session or Pushed row of `list/2` as a page shows it: without `pos`, `seqs`
  and `at`, with `time`, the row's place in time. A Main session row also has `words`,
  the first line of the main agent's last text, and `duration_ms`, the sum of the
  durations of the main agent's results, each nil while there is none. `built` is a list
  of built items (`Timeline.build/3`) that includes those of the row's `seqs`.
  """
  def build(row, built \\ [])

  def build(%{kind: :main_session} = row, built) do
    text = row.text_seq && Enum.find(built, &(&1.seq == row.text_seq))

    durations =
      for %{seq: seq} = item <- built,
          seq in row.result_seqs,
          is_integer(item[:duration_ms]),
          do: item.duration_ms

    row
    |> shown()
    |> Map.merge(%{
      words: text && text[:first_line],
      duration_ms: if(durations != [], do: Enum.sum(durations))
    })
  end

  def build(%{kind: :pushed} = row, _built), do: shown(row)

  defp shown(row), do: row |> Map.drop([:pos, :seqs, :at]) |> Map.put(:time, row.at)

  @doc """
  The sequence a row links to in the Terminal, or nil when the Transcript has no line
  for it. `line?` is whether a light item has a line in the Transcript
  (`ApiaryWeb.TranscriptComponents.line?/2` on the run page). A row links to its `seq`;
  the Main session row to its last text, which always has a line; a Pushed row nowhere.
  """
  def terminal_seq(%{kind: :main_session} = row, _line?), do: row.text_seq
  def terminal_seq(%{kind: :pushed}, _line?), do: nil
  def terminal_seq(%{seq: seq} = row, line?) when is_integer(seq), do: if(line?.(row), do: seq)
  def terminal_seq(_row, _line?), do: nil

  @doc """
  Where `?seq=` goes on the Timeline for `item`, the light item of the sequence
  (`index.by_seq`), among `rows`, the rows of `list/2`. A row without a sequence, a Main
  session or a Pushed row, is never where it goes.

    * `{:row, row}`: the item's row.
    * `{:terminal, seq}`: the item is a routine call (`routine?/1`) and `read_log?`, the
      reader may read the Terminal, where the call has its line.
    * `{:row, row}` for the nearest row before a routine call, for any other reader, or
      nil when there is none.
    * `:unlisted`: any other item with no row, such as thinking or an allowed connection
      while Connections inline is off. The page shows the first row after it, else the
      last row.
  """
  def focus(rows, %{seq: seq} = item, read_log?) when is_integer(seq) do
    case Enum.find(rows, &(&1.seq == seq)) do
      %{} = row ->
        {:row, row}

      nil ->
        cond do
          not routine?(item) ->
            :unlisted

          read_log? ->
            {:terminal, seq}

          true ->
            rows
            |> Enum.take_while(&(pos(&1) < {seq, seq}))
            |> Enum.filter(&is_integer(&1.seq))
            |> List.last()
            |> then(&(&1 && {:row, &1}))
        end
    end
  end

  ## The Main session row

  defp main_prompt?(%{kind: :prompt, lane: %{id: "main"}}), do: true
  defp main_prompt?(_item), do: false

  defp with_main(rows, items) do
    case Enum.find(items, &main_prompt?/1) do
      nil ->
        rows

      prompt ->
        case Enum.split_while(rows, &(&1.seq != prompt.seq)) do
          {before, [prompt | rest]} -> before ++ [prompt, main_row(prompt, items) | rest]
          {_rows, []} -> rows
        end
    end
  end

  defp main_row(prompt, items) do
    {calls, text_seq, results} =
      Enum.reduce(items, {0, nil, []}, fn
        %{kind: :tool, lane: %{id: "main"}}, {calls, text, results} ->
          {calls + 1, text, results}

        %{kind: :text, lane: %{id: "main"}, seq: seq}, {calls, _text, results} ->
          {calls, seq, results}

        %{kind: :result, lane: %{id: "main"}, seq: seq}, {calls, text, results} ->
          {calls, text, [seq | results]}

        _item, acc ->
          acc
      end)

    result_seqs = Enum.reverse(results)

    synthetic(:main_session, @main_id, prompt.at, prompt.lane)
    |> Map.merge(%{
      sequence: prompt.seq,
      calls: calls,
      text_seq: text_seq,
      result_seqs: result_seqs,
      seqs: List.wrap(text_seq) ++ result_seqs
    })
  end

  ## Pushed rows

  defp with_pushed(rows, []), do: rows

  defp with_pushed(rows, versions) do
    pushed =
      versions
      |> Enum.sort_by(&{instant(&1.at), &1.number})
      |> Enum.with_index(fn version, index ->
        id = if is_binary(version[:public_id]), do: version.public_id, else: "#{index}"

        synthetic(:pushed, "push-" <> id, version.at, main_lane())
        |> Map.merge(%{
          sequence: nil,
          type: version.type,
          name: version[:name],
          number: version.number
        })
      end)

    # A version goes after the last row whose time is at or before its time. From each
    # row on, the earliest time of any row is never earlier than at the row before, so
    # one pass places the versions in order.
    {earliest, _} =
      rows
      |> Enum.reverse()
      |> Enum.map_reduce(:infinity, fn row, later ->
        earliest = min(instant(row[:at]), later)
        {earliest, earliest}
      end)

    {placed, left} =
      rows
      |> Enum.zip(Enum.reverse(earliest))
      |> Enum.flat_map_reduce(pushed, fn {row, from}, pending ->
        {before, pending} = Enum.split_while(pending, &(instant(&1.at) < from))
        {before ++ [row], pending}
      end)

    placed ++ left
  end

  # A time as microseconds, which compare as numbers; no time is after every time.
  defp instant(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  defp instant(%NaiveDateTime{} = time),
    do: time |> DateTime.from_naive!("Etc/UTC") |> instant()

  defp instant(_time), do: :infinity

  ## Places and rails

  defp synthetic(kind, id, at, lane) do
    %{
      kind: kind,
      id: id,
      seq: nil,
      at: at,
      seqs: [],
      lane: lane,
      rails: [],
      link: nil,
      who: false,
      open_calls: 0,
      pos: nil
    }
  end

  defp main_lane,
    do: Map.take(Timeline.lane(nil, "main"), [:index, :id, :type, :rail, :color, :overflow])

  # A row without a sequence takes the place after the row before it: `{a, {b, k}}` after
  # `{a, b}`, which compares after it and before `{c, d}` for every `c` above `a`, and `k`
  # counts the rows without a sequence since that row. Before the first row with a
  # sequence, `{a, b}` is one below that row's place.
  defp place(rows) do
    start =
      case Enum.find(rows, &is_integer(&1.seq)) do
        nil -> {0, 0}
        row -> row |> pos() |> then(fn {a, _b} -> {a - 1, a - 1} end)
      end

    {rows, _} =
      Enum.map_reduce(rows, {start, 0, []}, fn
        %{seq: nil} = row, {{a, b} = after_pos, k, rails} ->
          {%{row | pos: {a, {b, k}}, rails: rails}, {after_pos, k + 1, rails}}

        row, _acc ->
          {row, {pos(row), 0, continued(row.rails)}}
      end)

    rows
  end

  defp pos(%{pos: {_, _} = pos}), do: pos
  defp pos(%{seq: seq}), do: {seq, seq}

  # The rails that pass below a row: those that end at it stop, and the rest pass through,
  # faded while they are faded at it.
  defp continued(rails) do
    for %{part: part} = rail <- rails, part != :to do
      %{rail | part: if(part == :live, do: :live, else: :through)}
    end
  end

  # The last row ends the rails as the index's last item does, when that item is not
  # listed: every rail faded while main's is (the record is being written), else main's
  # rail ending. A rail that starts or ends at the row keeps its part.
  defp end_rails([], _last), do: []
  defp end_rails(rows, nil), do: rows

  defp end_rails(rows, last) do
    case List.last(rows) do
      %{seq: seq} when seq == last.seq ->
        rows

      row ->
        live? = Enum.any?(last.rails, &(&1.rail == 0 and &1.part == :live))

        rails =
          Enum.map(row.rails, fn rail ->
            cond do
              rail.part in [:from, :to] -> rail
              live? -> %{rail | part: :live}
              rail.rail == 0 -> %{rail | part: :to}
              true -> rail
            end
          end)

        List.replace_at(rows, -1, %{row | rails: rails})
    end
  end
end
