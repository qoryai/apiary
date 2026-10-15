defmodule ApiaryWeb.SourceComponents do
  @moduledoc """
  The components that show what a work source holds: a ticket's text.

  **A ticket's text** (`body/1`) is shown as its source wrote it. Markdown is shown
  formatted (`Apiary.Sources.Body.render/2`), with Show as written, which shows the exact
  text instead, and Show formatted, back; the switch happens in the browser, with no trip
  to the server. Plain text, a format the console does not know, and a Markdown text too
  long to format are shown as written alone, with no switch. As written is the exact
  characters, interpolated, so HEEx escapes them, with their spaces and line breaks kept
  and long lines wrapped.

  The formatted HTML is the one exception to the rule that a component never passes text
  it did not write to `raw/1` (docs/ui.md): it is sanitised on the server, by an
  allowlist, after every other change.
  """
  use ApiaryWeb, :html

  alias Apiary.Sources.Body

  @doc """
  A ticket's text, `body`, in the format `format` (`"markdown"` or `"text"`). `id` is the
  DOM id of its box; the views and the buttons take ids under it.
  """
  attr :id, :string, required: true
  attr :body, :string, default: nil, doc: "the ticket's text, as its source wrote it"
  attr :format, :string, default: nil, doc: ~s(`"markdown"` or `"text"`)

  def body(assigns) do
    case Body.render(assigns.body, assigns.format) do
      {:as_written, text} ->
        assigns = assign(assigns, :text, text)

        ~H"""
        <div id={@id} class="q-ticket-body">
          <div id={"#{@id}-written"} class="q-ticket-written" phx-no-format>{@text}</div>
        </div>
        """

      html ->
        assigns = assign(assigns, :html, html)

        ~H"""
        <div id={@id} class="q-ticket-body">
          <div class="q-ticket-switch">
            <.button
              id={"#{@id}-show-written"}
              type="button"
              variant="link"
              aria-controls={"#{@id}-written"}
              phx-click={switch(@id, "#{@id}-show-formatted")}
            >
              {gettext("Show as written")}
            </.button>
            <.button
              id={"#{@id}-show-formatted"}
              type="button"
              variant="link"
              class="hidden"
              aria-controls={"#{@id}-formatted"}
              phx-click={switch(@id, "#{@id}-show-written")}
            >
              {gettext("Show formatted")}
            </.button>
          </div>
          <div id={"#{@id}-formatted"} class="q-ticket-formatted">{@html}</div>
          <div
            id={"#{@id}-written"}
            class="q-ticket-written q-ticket-source hidden"
            phx-no-format
          >{@body}</div>
        </div>
        """
    end
  end

  # Swaps the two views and the two buttons, and moves the focus to the button now shown.
  defp switch(id, focus) do
    JS.toggle_class("hidden", to: "##{id}-formatted")
    |> JS.toggle_class("hidden", to: "##{id}-written")
    |> JS.toggle_class("hidden", to: "##{id}-show-written")
    |> JS.toggle_class("hidden", to: "##{id}-show-formatted")
    |> JS.focus(to: "##{focus}")
  end
end
