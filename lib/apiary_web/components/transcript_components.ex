defmodule ApiaryWeb.TranscriptComponents do
  @moduledoc """
  The Transcript of a run's Terminal tab (`docs/ui.md`, The terminal): the session drawn
  from its runtime events (`dev.qory.runtime.*`), in sequence order, as a terminal shows
  a session of Claude Code. It reads no runtime's output: a runtime whose Forager
  descriptor maps its output to these events is drawn the same way.

  An item is what `Apiary.Runs.Record.Timeline.build/3` made of the run's events; the
  Transcript shows the items of `transcript?/2`. Everything in an item came from Forager
  and is untrusted: a text is interpolated, so it is escaped, and an assistant's text is
  Markdown made safe by the work item renderer (Apiary.Sources.Body), which renders no
  HTML of the text. The markers (`❯`, `⏺`, `⎿`, `✓`, `✗`) are not words and are not
  translated.

    * Prompt: `❯` and the prompt.
    * Tool call: `⏺`, the tool and its summary in brackets, then under it the result the
      runtime gave the model (its first 3 lines, the rest behind a button), the denial's
      reason, or the error of a call that failed. A call recorded before Forager sent its
      result shows what the tool returned, as JSON, in its place. When lines of another
      agent arrived between the call and its result, the result is a separate line after
      them, at the call's indent (`lines/2`).
    * Text: `⏺` and the text as Markdown, each line of a paragraph a line. Thinking with
      text is folded. A run recorded before Forager sent its texts shows the text of each
      turn's end in their place.
    * Result: `✓` or `✗`, the outcome, turns, duration and cost.

  A subagent's lines are indented. On the Terminal tab a subagent's start heads its lines
  (`arrange/4`): its agent type, whether it runs or how long it ran, and how many calls it
  made, then its last message once it finished. The group follows its head whatever
  arrived between, and it closes when the subagent finishes; the reader opens or closes it
  with the head's caret or with Show and Hide. A line read from the session's output has a
  link to that line in Raw (`data-raw-line`, followed by the `Terminal` hook).

  A line drawn with `controls` false has no button: no fold of a result, no "Show all"
  of a text, and thinking is its line alone, closed. The runs list's preview draws its
  lines so (`ApiaryWeb.RunComponents.run_preview/1`), with `raw` false.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1]
  import ApiaryWeb.ExternalText, only: [external_text: 1]

  alias Apiary.Sources.Body
  alias ApiaryWeb.Format
  alias ApiaryWeb.RunPageComponents

  # The lines of a result shown before the button that opens the rest.
  @folded 3

  @doc "The lines of a result shown while it is folded."
  def folded, do: @folded

  @doc """
  Whether an item is a line of the Transcript. `texts` is how many text items the run
  has (`Timeline.index/2`): with none, the run was recorded before Forager sent its texts,
  and a turn's end shows the turn's last message in their place.
  """
  def transcript?(%{kind: kind}, _texts)
      when kind in [:prompt, :tool, :text, :thinking, :result],
      do: true

  def transcript?(%{kind: :turn_finished}, 0), do: true
  def transcript?(_item, _texts), do: false

  # A subagent's start that the record opened a lane for: the head of its lines. A start
  # without an agent id is in the main agent's lane, index 0, and heads nothing.
  defp head?(%{kind: :subagent_started, lane: %{index: index}})
       when is_integer(index) and index > 0,
       do: true

  defp head?(_item), do: false

  @doc """
  Whether an item has a line at its sequence among `lines/3` with `subagents: true`: an
  item of `transcript?/2`, or a subagent's start the record opened a lane for.
  """
  def line?(item, texts), do: transcript?(item, texts) or head?(item)

  @doc """
  The Transcript's lines from the index's light items (`Timeline.index/2`), in sequence
  order: the items of `transcript?/2`, and with `subagents: true` each subagent's start,
  which `arrange/4` makes the head of its lines. A tool call whose result came after a
  line of another agent (a subagent's prompt, calls and texts) is two lines: the call,
  with `part: :call`, and the result at the result's sequence, with `part: :result`, after
  those lines. The choice reads sequences and agents only.
  """
  def lines(items, texts, opts \\ []) do
    heads? = Keyword.get(opts, :subagents, false)
    shown = Enum.filter(items, &(transcript?(&1, texts) or (heads? and head?(&1))))

    {lines, results} =
      shown
      |> Enum.zip(next_other_agent(shown))
      |> Enum.map_reduce([], fn {item, other}, results ->
        result = item[:result_seq]

        if item.kind == :tool and is_integer(result) and is_integer(other) and other < result,
          do:
            {Map.put(item, :part, :call),
             [Map.merge(item, %{seq: result, part: :result}) | results]},
          else: {item, results}
      end)

    if results == [], do: lines, else: Enum.sort_by(lines ++ results, & &1.seq)
  end

  @doc """
  The subagents of the index's light items (`Timeline.index/2`), by their lane's index:
  each started with a subagent start the record opened a lane for. Each is `%{seq, type,
  calls, finished_seq, state}`: `seq` is its start's sequence, `type` its agent type,
  `calls` how many tool calls it made, and `finished_seq` its finish's sequence, nil while
  the record has none. `state` is `:finished` once the finish is recorded; `:running`
  while the record is being written (`alive?`) and neither its session nor the run ended
  after its start; else `:ended`: the record lacks its finish, and has no event for
  how it ended.
  """
  def subagents(items, alive?) do
    items
    |> Enum.reduce(%{}, fn item, subs ->
      lane = item.lane[:index]

      case item.kind do
        # A second start of an agent id still open is in the first one's lane, which
        # keeps its first start and its count.
        :subagent_started when is_integer(lane) and lane > 0 and not is_map_key(subs, lane) ->
          Map.put(subs, lane, %{
            seq: item.seq,
            type: item.lane[:type],
            calls: 0,
            finished_seq: nil,
            ended: false
          })

        :subagent_finished when is_map_key(subs, lane) ->
          put_in(subs, [lane, :finished_seq], item.seq)

        :tool when is_map_key(subs, lane) ->
          update_in(subs, [lane, :calls], &(&1 + 1))

        kind when kind in [:session_ended, :run_exited] ->
          Map.new(subs, fn {lane, sub} -> {lane, %{sub | ended: true}} end)

        _kind ->
          subs
      end
    end)
    |> Map.new(fn {lane, sub} ->
      state =
        cond do
          sub.finished_seq -> :finished
          alive? and not sub.ended -> :running
          true -> :ended
        end

      {lane, sub |> Map.delete(:ended) |> Map.put(:state, state)}
    end)
  end

  @doc """
  The lines of `lines/2` (with `subagents: true`) with each subagent's lines under its
  start, its head, whatever arrived between: each line has `pos`, its place, `{head, seq}`
  for a line of a subagent and `{seq, seq}` for any other, and the lines are in `pos`
  order. A head has `sub`, its subagent (`subagents/2`) with `open` and `lines`, how many
  lines its group has; a line of a group has `group`, its head's sequence. The lines of a
  closed group are left out. A call and its result that `lines/2` drew apart are one line
  again where they end up next to each other.

  A group is open as the reader chose in `choices` (a head's sequence to true or false),
  else while its subagent has not finished, or when it has the line `focused` points at.
  """
  def arrange(lines, subs, choices \\ %{}, focused \\ nil)

  def arrange(lines, subs, _choices, _focused) when map_size(subs) == 0,
    do: Enum.map(lines, &Map.put(&1, :pos, {&1.seq, &1.seq}))

  def arrange(lines, subs, choices, focused) do
    tagged =
      Enum.map(lines, fn line ->
        lane = line.lane[:index]
        sub = is_integer(lane) && subs[lane]

        cond do
          sub && line.kind == :subagent_started && line.seq == sub.seq -> {:head, lane, line}
          # A second start of an agent id still open: its first start heads its lines.
          sub && line.kind == :subagent_started -> {:again, lane, line}
          sub && line.seq > sub.seq -> {:kid, lane, line}
          true -> {:line, nil, line}
        end
      end)

    counts = Enum.frequencies(for {:kid, lane, _line} <- tagged, do: lane)

    with_focus =
      Enum.find_value(tagged, fn
        {:kid, lane, %{seq: ^focused}} -> lane
        _tagged -> nil
      end)

    open =
      Map.new(subs, fn {lane, sub} ->
        {lane,
         case choices[sub.seq] do
           choice when is_boolean(choice) -> choice
           nil -> sub.state != :finished or lane == with_focus
         end}
      end)

    tagged
    |> Enum.flat_map(fn
      {:head, lane, line} ->
        sub = subs[lane]

        [
          Map.merge(line, %{
            pos: {line.seq, line.seq},
            sub: Map.merge(sub, %{open: open[lane], lines: Map.get(counts, lane, 0)}),
            seqs: Enum.uniq(line.seqs ++ List.wrap(sub.finished_seq))
          })
        ]

      {:kid, lane, line} ->
        head = subs[lane].seq
        if open[lane], do: [Map.merge(line, %{pos: {head, line.seq}, group: head})], else: []

      {:again, _lane, _line} ->
        []

      {:line, _lane, line} ->
        [Map.put(line, :pos, {line.seq, line.seq})]
    end)
    |> Enum.sort_by(& &1.pos)
    |> join_results()
  end

  # A call drawn apart from its result (`lines/2`) is one line again where the grouping put
  # the two together: no line of another agent is between them any more.
  defp join_results([%{part: :call, result_seq: seq} = call, %{part: :result, seq: seq} | rest]),
    do: [Map.delete(call, :part) | join_results(rest)]

  defp join_results([line | rest]), do: [line | join_results(rest)]
  defp join_results([]), do: []

  # For each item, the sequence of the first later item of another agent, or nil.
  defp next_other_agent(items) do
    items
    |> Enum.reverse()
    |> Enum.map_reduce({nil, nil}, fn item, {next, next_other} ->
      other =
        cond do
          is_nil(next) -> nil
          next.lane.id != item.lane.id -> next.seq
          true -> next_other
        end

      {other, {item, other}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  The Transcript: a LiveView stream of lines, with the buttons that load the lines before
  and after the window. `target` is the DOM id of the line `?seq=` points at.
  """
  attr :id, :string, required: true
  attr :stream, :any, required: true
  attr :earlier, :integer, default: 0
  attr :later, :integer, default: 0
  attr :raw, :boolean, default: true, doc: "whether Raw has the log, so a line links to it"
  attr :target, :string, default: nil

  attr :results, :boolean,
    default: true,
    doc: "false for a run with neither texts nor turn ends: its result shows its text"

  def transcript(assigns) do
    ~H"""
    <div id={"#{@id}-box"} class="q-transcript" data-transcript data-target={@target}>
      <button
        :if={@earlier > 0}
        id={"#{@id}-earlier"}
        type="button"
        class="q-tr-more"
        phx-click="load_earlier"
      >
        <.icon name="hero-arrow-up-micro" class="size-3" /> {ngettext(
          "%{number} earlier event",
          "%{number} earlier events",
          @earlier,
          number: Format.number(@earlier)
        )}
      </button>
      <ol id={@id} class="q-tr" phx-update="stream" aria-label={gettext("Transcript")}>
        <.line
          :for={{dom_id, item} <- @stream}
          id={dom_id}
          item={item}
          raw={@raw}
          open={item[:open] == true}
          result_text={not @results}
        />
      </ol>
      <button
        :if={@later > 0}
        id={"#{@id}-later"}
        type="button"
        class="q-tr-more"
        phx-click="load_later"
        data-later
      >
        <.icon name="hero-arrow-down-micro" class="size-3" /> {gettext("Load newer")}
        <span class="text-faint">
          · {ngettext("%{number} later event", "%{number} later events", @later,
            number: Format.number(@later)
          )}
        </span>
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :raw, :boolean, required: true
  attr :open, :boolean, default: false
  attr :result_text, :boolean, default: false

  attr :controls, :boolean,
    default: true,
    doc: "false for a line with no button: no fold, no Show all, thinking closed"

  @doc "One line of the Transcript, with what is under it."
  def line(assigns) do
    ~H"""
    <li
      id={@id}
      class={[
        "q-tr-i",
        "q-tr-#{@item.kind}",
        @item.lane.id != "main" && !@item[:sub] && "q-tr-sub",
        @item[:group] && "q-tr-in"
      ]}
      data-seq={@item.sequence}
      data-part={@item[:part]}
      data-group={@item[:group]}
    >
      <.body
        id={@id}
        item={@item}
        raw={@raw}
        open={@open}
        result_text={@result_text}
        controls={@controls}
      />
    </li>
    """
  end

  attr :id, :string, default: nil
  attr :item, :map, required: true
  attr :raw, :boolean, required: true
  attr :open, :boolean, default: false
  attr :result_text, :boolean, default: false
  attr :controls, :boolean, default: true

  # A subagent's start that heads its lines (`arrange/4`): the caret that opens or closes
  # them (a dot for a subagent with no lines), the agent type, whether it runs or how long
  # it ran, and its calls; under it the subagent's last message, folded as a result is,
  # and Show or Hide.
  defp body(%{item: %{kind: :subagent_started, sub: %{} = sub}} = assigns) do
    out =
      case assigns.item[:text] do
        text when is_binary(text) and text != "" ->
          %{
            text: text,
            lines: count_lines(text),
            cut: false,
            truncated: false,
            tone: nil
          }

        _none ->
          nil
      end

    assigns =
      assign(assigns,
        sub: sub,
        out: out,
        toggles: assigns.controls and sub.lines > 0,
        said: "#{assigns.id}-said"
      )

    ~H"""
    <div class="q-tr-row">
      <button
        :if={@toggles}
        type="button"
        class="q-tr-mark q-tr-caret"
        phx-click="subagent_toggle"
        phx-value-seq={@item.sequence}
        aria-expanded={to_string(@sub.open)}
        aria-labelledby={@said}
      >
        {if @sub.open, do: "▾", else: "▸"}
      </button>
      <span :if={!@toggles} class="q-tr-mark q-tr-caret" aria-hidden="true">⏺</span>
      <span id={@said} class="q-tr-head">
        <b class="q-tr-tool"><.external_text text={@sub.type || @item[:agent_type] || ""} /></b>{subagent_words(
          @sub,
          @item[:duration_ms]
        )}
      </span>
    </div>
    <.output
      :if={@out}
      out={@out}
      seq={@item.sequence}
      open={@open}
      raw={@raw}
      item={@item}
      controls={@controls}
    />
    <div :if={@toggles and @sub.calls > 0} class="q-tr-out">
      <span class="q-tr-hook" aria-hidden="true"></span>
      <button
        type="button"
        class="q-tr-fold"
        phx-click="subagent_toggle"
        phx-value-seq={@item.sequence}
        aria-expanded={to_string(@sub.open)}
      >
        {if @sub.open,
          do:
            ngettext("Hide %{number} call", "Hide %{number} calls", @sub.calls,
              number: Format.number(@sub.calls)
            ),
          else:
            ngettext("Show %{number} call", "Show %{number} calls", @sub.calls,
              number: Format.number(@sub.calls)
            )}
      </button>
    </div>
    """
  end

  defp body(%{item: %{kind: :prompt}} = assigns) do
    ~H"""
    <div class="q-tr-row">
      <span class="q-tr-mark" aria-hidden="true">❯</span>
      <span class="q-tr-head q-tr-wrap">{RunPageComponents.sent_lines(@item.text)}</span>
      <.raw_link raw={@raw} item={@item} line={@item.line} />
    </div>
    """
  end

  # A result drawn apart from its call: the result alone, at the call's indent.
  defp body(%{item: %{kind: :tool, part: :result}} = assigns) do
    assigns = assign(assigns, out: tool_output(assigns.item))

    ~H"""
    <.output
      :if={@out}
      out={@out}
      seq={@item.sequence}
      open={@open}
      tone={@out.tone}
      raw={@raw}
      item={@item}
      controls={@controls}
    />
    """
  end

  defp body(%{item: %{kind: :tool}} = assigns) do
    item = assigns.item

    assigns =
      assign(assigns,
        out: if(item[:part] != :call, do: tool_output(item)),
        reason: shown(item.reason)
      )

    ~H"""
    <div class="q-tr-row q-tr-call">
      <span class={["q-tr-mark", "q-tr-dot", "q-tr-#{@item.status}"]} aria-hidden="true">⏺</span>
      <span class="q-tr-head">
        <b class="q-tr-tool"><.external_text text={@item.tool} /></b><span :if={@item.summary}>(<.external_text text={
          @item.summary
        } />)</span>
      </span>
      <.raw_link raw={@raw} item={@item} line={@item.line} />
    </div>
    <div :if={@item.status == :denied} class="q-tr-out q-tr-warn">
      <span class="q-tr-hook" aria-hidden="true">⎿</span>
      <span :if={@reason} class="q-tr-ln">{gettext("Denied: %{reason}", reason: @reason)}</span>
      <span :if={!@reason} class="q-tr-ln">{gettext("Not run: denied")}</span>
    </div>
    <.output
      :if={@out}
      out={@out}
      seq={@item.sequence}
      open={@open}
      tone={@out.tone}
      raw={@raw}
      item={@item}
      controls={@controls}
    />
    """
  end

  defp body(%{item: %{kind: kind}} = assigns) when kind in [:text, :turn_finished] do
    ~H"""
    <div :if={@item.text} class="q-tr-row">
      <span class="q-tr-mark q-tr-say" aria-hidden="true">⏺</span>
      <div class="q-tr-text">
        <.markdown text={@item.text} />
        <RunPageComponents.show_all
          :if={@item.text_cut and @controls}
          seq={@item.sequence}
          bytes={@item.text_bytes}
        />
        <p :if={@item[:truncated]} class="q-tr-cut">{cut_words()}</p>
      </div>
      <.raw_link raw={@raw} item={@item} line={@item.line} />
    </div>
    """
  end

  defp body(%{item: %{kind: :thinking}, controls: false} = assigns) do
    ~H"""
    <div class="q-tr-think">
      <div class="q-tr-row">
        <span class="q-tr-mark" aria-hidden="true">✻</span>
        <span class="q-tr-head">{gettext("Thinking")}</span>
      </div>
    </div>
    """
  end

  defp body(%{item: %{kind: :thinking}} = assigns) do
    ~H"""
    <details class="q-tr-think" phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}>
      <summary class="q-tr-row">
        <span class="q-tr-mark" aria-hidden="true">✻</span>
        <span class="q-tr-head">{gettext("Thinking")}</span>
        <.raw_link raw={@raw} item={@item} line={@item.line} />
      </summary>
      <div class="q-tr-out q-tr-wrap">
        <span class="q-tr-hook" aria-hidden="true"></span>
        <span class="q-tr-ln">{RunPageComponents.sent_lines(@item.text)}</span>
      </div>
      <p :if={@item[:truncated]} class="q-tr-cut">{cut_words()}</p>
    </details>
    """
  end

  defp body(%{item: %{kind: :result}} = assigns) do
    ~H"""
    <div class="q-tr-row q-tr-end">
      <span
        class={["q-tr-mark", @item[:outcome] != "success" && "q-tr-failed"]}
        aria-hidden="true"
      >
        {if @item[:outcome] == "success", do: "✓", else: "✗"}
      </span>
      <span class="q-tr-head">{RunPageComponents.result_words(@item)}</span>
      <.raw_link raw={@raw} item={@item} line={@item.line} />
    </div>
    <div :if={@result_text and @item.text} class="q-tr-row">
      <span class="q-tr-mark q-tr-say" aria-hidden="true">⏺</span>
      <div class="q-tr-text"><.markdown text={@item.text} /></div>
    </div>
    """
  end

  defp body(assigns), do: ~H""

  # What shows under a tool line: the result, the error of a failed call, or, for a call
  # recorded before Forager sent results, the response as JSON. `tone` is :error for the
  # error, and for a result the runtime reported as one.
  defp tool_output(%{status: :failed} = item) do
    case item[:error] do
      text when is_binary(text) and text != "" ->
        %{text: text, lines: count_lines(text), cut: false, truncated: false, tone: :error}

      _ ->
        nil
    end
  end

  defp tool_output(%{status: :denied}), do: nil

  defp tool_output(%{result: %{} = result}),
    do: Map.put(result, :tone, if(result.error, do: :error))

  # A response shows no line until the reader opens it: it is the tool's value as JSON,
  # not what the model read.
  defp tool_output(%{response: %{} = response}),
    do: response |> Map.merge(%{truncated: false, tone: nil, folded: 0})

  defp tool_output(_item), do: nil

  attr :out, :map, required: true
  attr :seq, :integer, required: true
  attr :open, :boolean, required: true
  attr :tone, :atom, default: nil
  attr :raw, :boolean, required: true
  attr :item, :map, required: true
  attr :controls, :boolean, default: true

  # The output's first lines, and a button for the rest: `%{number} more lines` opens it,
  # `Show less` folds it again. The server reads an opened result whole. With `controls`
  # false, the first lines alone.
  defp output(assigns) do
    lines = assigns.out.text |> RunPageComponents.sent_lines() |> split_lines()
    folded = Map.get(assigns.out, :folded, @folded)
    more = max(assigns.out.lines - folded, 0)

    assigns =
      assign(assigns,
        shown: if(assigns.open, do: lines, else: Enum.take(lines, folded)),
        more: more
      )

    ~H"""
    <div class={["q-tr-out", @tone == :error && "q-tr-bad"]}>
      <span class="q-tr-hook" aria-hidden="true">⎿</span>
      <div class="q-tr-lns">
        <span :for={line <- @shown} class="q-tr-ln">{line}</span>
        <button
          :if={@controls and @more > 0 and not @open}
          type="button"
          class="q-tr-fold"
          phx-click="transcript_open"
          phx-value-seq={@seq}
        >
          … {ngettext("%{number} more line", "%{number} more lines", @more,
            number: Format.number(@more)
          )}
        </button>
        <button
          :if={@controls and @open}
          type="button"
          class="q-tr-fold"
          phx-click="transcript_close"
          phx-value-seq={@seq}
        >
          {gettext("Show less")}
        </button>
        <p :if={@out.truncated} class="q-tr-cut">{cut_words()}</p>
      </div>
    </div>
    """
  end

  attr :text, :string, required: true

  # An assistant's text, as Markdown with each line kept (`Apiary.Sources.Body`). A text
  # the renderer does not format is shown as written.
  defp markdown(assigns) do
    case Body.render(assigns.text, "markdown", pgettext("a table in a text", "text"),
           hard_breaks: true
         ) do
      {:as_written, text} ->
        assigns = assign(assigns, :written, text)

        ~H"""
        <div class="q-tr-md q-tr-wrap">{@written}</div>
        """

      html ->
        assigns = assign(assigns, :html, html)

        ~H"""
        <div class="q-tr-md q-ticket-formatted">{@html}</div>
        """
    end
  end

  attr :raw, :boolean, required: true
  attr :item, :map, required: true
  attr :line, :any, required: true

  # The link to the line in Raw, at the end of the row, shown on hover and on focus. Only
  # for a line read from a session's output, while Raw has the log.
  defp raw_link(assigns) do
    ~H"""
    <button
      :if={@raw and is_integer(@line) and is_integer(@item[:session])}
      type="button"
      class="q-tr-raw"
      data-raw-line={@line}
      data-session={@item.session}
      aria-label={gettext("Show line %{number} in Raw", number: Format.number(@line))}
    >
      {gettext("Raw")}
    </button>
    """
  end

  defp cut_words, do: gettext("Cut at 64 KiB. Raw has every byte.")

  @doc """
  The words after a subagent's type (`subagents/2`): " · running · 2 calls so far",
  " · finished in 51 s · 3 calls", or, for a subagent whose finish the record lacks,
  " · 3 calls". `duration_ms` is how long it ran, nil while that is unknown. The
  Transcript's head and the Timeline's (`ApiaryWeb.RunPageComponents`) read them.
  """
  def subagent_words(sub, duration_ms) do
    calls = Format.number(sub.calls)

    state =
      case sub.state do
        :running ->
          gettext("running")

        :finished when is_integer(duration_ms) ->
          gettext("finished in %{duration}",
            duration: ApiaryWeb.RunComponents.format_duration_ms(max(duration_ms, 0))
          )

        _state ->
          nil
      end

    counted =
      if sub.state == :running,
        do: ngettext("%{number} call so far", "%{number} calls so far", sub.calls, number: calls),
        else: ngettext("%{number} call", "%{number} calls", sub.calls, number: calls)

    [state, counted] |> Enum.reject(&is_nil/1) |> Enum.map_join(&(" · " <> &1))
  end

  @doc """
  The Transcript's part of the terminal's bar on a run with subagents: how many there are
  and how many run, and the buttons that open and close every subagent's lines.
  """
  attr :count, :integer, required: true
  attr :running, :integer, required: true

  def subagents_bar(assigns) do
    ~H"""
    <span class="q-tr-subs">
      {ngettext(
        "%{number} subagent, %{running} running",
        "%{number} subagents, %{running} running",
        @count,
        number: Format.number(@count),
        running: Format.number(@running)
      )}
    </span>
    <span class="q-term-sep" aria-hidden="true"></span>
    <button type="button" class="q-tbtn" phx-click="subagents_all" phx-value-open="true">
      {gettext("Expand all")}
    </button>
    <button type="button" class="q-tbtn" phx-click="subagents_all" phx-value-open="false">
      {gettext("Collapse all")}
    </button>
    """
  end

  defp shown(text) when is_binary(text) and text != "", do: Apiary.ExternalText.present(text)
  defp shown(_text), do: nil

  defp split_lines(nil), do: []

  defp split_lines(text) do
    text |> String.trim_trailing("\n") |> String.split("\n")
  end

  defp count_lines(text) do
    breaks = text |> :binary.matches("\n") |> length()
    if String.ends_with?(text, "\n"), do: breaks, else: breaks + 1
  end
end
