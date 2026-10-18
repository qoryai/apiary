defmodule ApiaryWeb.SourceComponents do
  # The components that show a ticket's text, which an integration sends. Kept out of the
  # generated documentation, which every instance serves.
  #
  # **A ticket's text** (`body/1`) is shown as the integration sent it. Markdown is shown
  # formatted (`Apiary.Sources.Body.render/3`), with Show as written, which shows the
  # exact text instead, and Show formatted, back; the switch happens in the browser, with
  # no trip to the server. Plain text and a Markdown text too long to format are shown as
  # written alone, with no switch; a format the console does not know, none included, is
  # shown as written under a muted line that says so. A ticket with no text says it has
  # no description. As written is the exact characters, interpolated, so HEEx escapes
  # them, with their spaces and line breaks kept and long lines wrapped.
  #
  # **The words for a source's items** (`item/1`, `items/1`, `item_label/1`,
  # `items_label/1`) are what its adapter calls one of them and many
  # (`Apiary.Adapters.item_noun/1`, `%{one:, other:}`), or ticket and tickets where it
  # names none (nil). They are lower case, but for the labels, whose first letter is in
  # upper case, and a sentence binds them as data, `%{item}` or `%{items}`, with no "a"
  # or "an" before them. A page or a sentence about one item passes its source's; one
  # about many, the words their sources share (`Apiary.Adapters.shared_item_noun/1`), nil
  # where they differ.
  #
  # The formatted HTML is the one exception to the rule that a component never passes
  # text it did not write to `raw/1` (docs/ui.md): it is sanitised on the server, by an
  # allowlist, after every other change.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.Sources.Body

  @doc false
  # item/1 is the word for one of a source's items, from `noun`, as above.
  @spec item(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def item(%{one: one}) when is_binary(one), do: one
  def item(nil), do: pgettext("source item, when its adapter names none", "ticket")

  @doc false
  # items/1 is the word for many of a source's items, from `noun`, as above.
  @spec items(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def items(%{other: other}) when is_binary(other), do: other
  def items(nil), do: pgettext("source item, when its adapter names none", "tickets")

  @doc false
  # item_label/1 is `item/1` with its first letter in upper case: a label that is the
  # noun alone, such as a tab's.
  @spec item_label(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def item_label(noun), do: noun |> item() |> capitalise()

  @doc false
  # items_label/1 is `items/1` with its first letter in upper case: the words for many of
  # a source's items at the start of a sentence or as a label, "Tickets" where it names
  # none.
  @spec items_label(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def items_label(noun), do: noun |> items() |> capitalise()

  defp capitalise(words) do
    {first, rest} = String.split_at(words, 1)
    String.upcase(first) <> rest
  end

  # A ticket's text, `body`, in the format `format` (`"markdown"` or `"text"`), with the
  # words of its source for its items (`item_noun`, as above). `id` is the DOM id of its
  # box; the views and the buttons take ids under it.
  @doc false
  attr :id, :string, required: true
  attr :body, :string, default: nil, doc: "the ticket's text, as the integration sent it"
  attr :format, :string, default: nil, doc: ~s(`"markdown"` or `"text"`)

  attr :item_noun, :map,
    default: nil,
    doc: "what its source calls its items, `%{one:, other:}`; nil for ticket and tickets"

  def body(%{body: body} = assigns) when body in [nil, ""] do
    ~H"""
    <div id={@id} class="q-ticket-body">
      <p id={"#{@id}-empty"} class="text-muted">
        {gettext("The %{item} has no description.", item: item(@item_noun))}
      </p>
    </div>
    """
  end

  def body(assigns) do
    case Body.render(assigns.body, assigns.format, item(assigns.item_noun)) do
      {:as_written, text} ->
        assigns =
          assign(assigns, text: text, known: assigns.format in ["markdown", "text"])

        ~H"""
        <div id={@id} class="q-ticket-body">
          <p :if={!@known} id={"#{@id}-unformatted"} class="q-ticket-note text-muted">
            {gettext("Shown as written.")}
          </p>
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
