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
      result shows what the tool returned, as JSON, in its place.
    * Text: `⏺` and the text as Markdown, each line of a paragraph a line. Thinking with
      text is folded. A run recorded before Forager sent its texts shows the text of each
      turn's end in their place.
    * Result: `✓` or `✗`, the outcome, turns, duration and cost.

  A subagent's lines are indented. A line read from the session's output has a link to
  that line in Raw (`data-raw-line`, followed by the `Terminal` hook).
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

  @doc "One line of the Transcript, with what is under it."
  def line(assigns) do
    ~H"""
    <li
      id={@id}
      class={["q-tr-i", "q-tr-#{@item.kind}", @item.lane.id != "main" && "q-tr-sub"]}
      data-seq={@item.sequence}
    >
      <.body item={@item} raw={@raw} open={@open} result_text={@result_text} />
    </li>
    """
  end

  attr :item, :map, required: true
  attr :raw, :boolean, required: true
  attr :open, :boolean, default: false
  attr :result_text, :boolean, default: false

  defp body(%{item: %{kind: :prompt}} = assigns) do
    ~H"""
    <div class="q-tr-row">
      <span class="q-tr-mark" aria-hidden="true">❯</span>
      <span class="q-tr-head q-tr-wrap">{RunPageComponents.sent_lines(@item.text)}</span>
      <.raw_link raw={@raw} item={@item} line={@item.line} />
    </div>
    """
  end

  defp body(%{item: %{kind: :tool}} = assigns) do
    assigns = assign(assigns, out: tool_output(assigns.item))

    ~H"""
    <div class="q-tr-row">
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
      <span :if={reason = shown(@item.reason)} class="q-tr-ln">
        {gettext("Denied: %{reason}", reason: reason)}
      </span>
      <span :if={!shown(@item.reason)} class="q-tr-ln">{gettext("Not run: denied")}</span>
    </div>
    <.output
      :if={@out}
      out={@out}
      seq={@item.sequence}
      open={@open}
      tone={@out.tone}
      raw={@raw}
      item={@item}
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
          :if={@item.text_cut}
          seq={@item.sequence}
          bytes={@item.text_bytes}
        />
        <p :if={@item[:truncated]} class="q-tr-cut">{cut_words()}</p>
      </div>
      <.raw_link raw={@raw} item={@item} line={@item.line} />
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

  # The output's first lines, and a button for the rest: `%{number} more lines` opens it,
  # `Show less` folds it again. The server reads an opened result whole.
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
          :if={@more > 0 and not @open}
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
          :if={@open}
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
