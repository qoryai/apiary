defmodule ApiaryWeb.SourceComponents do
  # The components that show a ticket's text, which an integration sends. Kept out of the
  # generated documentation, which every instance serves.
  #
  # **A ticket's text** (`body/1`) is shown as the integration sent it. Markdown is shown
  # formatted (`Apiary.Sources.Body.render/3`), with Show as written, which shows the
  # text as written, with invisible characters dropped and control characters shown as
  # U+FFFD instead, and Show formatted, back; the switch happens in the browser, with no
  # trip to the server. Plain text and a Markdown text too long to format are shown as
  # written alone, with no switch; a format the console does not know, none included, is
  # shown as written under a muted line that says so. A ticket with no text says it has
  # no description. As written is the text as written, with invisible characters dropped
  # and control characters shown as U+FFFD (`Apiary.ExternalText.lines/1`), interpolated,
  # so HEEx escapes it, with its spaces and line breaks kept and long lines wrapped.
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
  # **The words for a source's collections** (`collection/1`, `collections/1`,
  # `collection_label/1`) are what its adapter calls one of them and many
  # (`Apiary.Adapters.collection_noun/1`), or collection and collections where it names
  # none (nil), in every kind of workspace, bound as data, `%{collection}` or
  # `%{collections}`, with the same rules: a page or a sentence about many collections
  # passes the words their sources share
  # (`Apiary.Adapters.shared_collection_noun/1`), nil where they differ; or it passes
  # every source's words, a list, and says each once, joined with "and" or "or"
  # (`collection/2`, `collections/2`, `collection_label/1`, `collections_label/1`,
  # `joined/2`): "repositories and queues", "Repository or queue".
  #
  # **The line after a collection's Backlog switch is pressed** (`backlog_turned/5`)
  # says what the press changed, and is nil when it changed nothing.
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
  # collection/1 is the word for one of a source's collections, from `noun`, as above.
  @spec collection(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def collection(%{one: one}) when is_binary(one), do: one

  def collection(nil),
    do: pgettext("source collection, when its adapter names none", "collection")

  @doc false
  # collections/1 is the word for many of a source's collections, from `noun`, as above.
  @spec collections(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def collections(%{other: other}) when is_binary(other), do: other

  def collections(nil),
    do: pgettext("source collection, when its adapter names none", "collections")

  @doc false
  # collection/2 is the words for one collection of any of the sources whose words for
  # their collections are `nouns`, a list of what `collection_noun/1` gives, collection
  # for an empty one: each source's word once, in the list's order, joined with "or"
  # (`joined/2`): "repository or queue".
  @spec collection([%{one: String.t(), other: String.t()} | nil], :or) :: String.t()
  def collection(nouns, :or) when is_list(nouns),
    do: nouns |> words(&collection/1) |> joined(:or)

  @doc false
  # collections/2 is the words for many collections of the sources whose words are
  # `nouns`, as `collection/2` reads them, joined with "and" or "or" (`join`):
  # "repositories and queues".
  @spec collections([%{one: String.t(), other: String.t()} | nil], :and | :or) ::
          String.t()
  def collections(nouns, join) when is_list(nouns) and join in [:and, :or],
    do: nouns |> words(&collections/1) |> joined(join)

  defp words([], word), do: [word.(nil)]
  defp words(nouns, word), do: nouns |> Enum.map(word) |> Enum.uniq()

  @doc false
  # joined/2 is `words`, one or more, as a sentence lists them: the last joined to the
  # others with "and" or "or" (`join`), the others with a comma: "a, b and c".
  @spec joined([String.t(), ...], :and | :or) :: String.t()
  def joined([word], _join), do: word

  def joined([_first | _rest] = words, join) do
    {list, [last]} = Enum.split(words, -1)
    list = Enum.join(list, ", ")

    case join do
      :and -> gettext("%{list} and %{last}", list: list, last: last)
      :or -> gettext("%{list} or %{last}", list: list, last: last)
    end
  end

  @doc false
  # backlog_turned/5 is the line a page shows once
  # `Apiary.Adapters.Collections.set_collection_backlog/4` answers `{:ok, count}` for the
  # collection whose title is `name`, turned on or off (`on`), in the words of its source
  # (`collection_noun` and `item_noun`, as above): nil for `count` 0, a press that changed
  # nothing, so the page claims no change.
  @spec backlog_turned(
          non_neg_integer,
          boolean,
          String.t(),
          %{one: String.t(), other: String.t()} | nil,
          %{one: String.t(), other: String.t()} | nil
        ) :: String.t() | nil
  def backlog_turned(0, on, _name, _collection_noun, _item_noun) when is_boolean(on), do: nil

  def backlog_turned(count, true, name, collection_noun, item_noun)
      when is_integer(count) and count > 0 and is_binary(name),
      do:
        gettext("Now taking %{items} into the Backlog from %{collection} %{name}.",
          items: items(item_noun),
          collection: collection(collection_noun),
          name: name
        )

  def backlog_turned(count, false, name, collection_noun, item_noun)
      when is_integer(count) and count > 0 and is_binary(name),
      do:
        gettext("No longer taking %{items} into the Backlog from %{collection} %{name}.",
          items: items(item_noun),
          collection: collection(collection_noun),
          name: name
        )

  @doc false
  # item_label/1 is `item/1` with its first letter in upper case: a label that is the
  # noun alone, such as a tab's.
  @spec item_label(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def item_label(noun), do: noun |> item() |> upcase_first()

  @doc false
  # items_label/1 is `items/1` with its first letter in upper case: the words for many of
  # a source's items at the start of a sentence or as a label, "Tickets" where it names
  # none.
  @spec items_label(%{one: String.t(), other: String.t()} | nil) :: String.t()
  def items_label(noun), do: noun |> items() |> upcase_first()

  @doc false
  # collection_label/1 is `collection/1` with its first letter in upper case: a label
  # that is the noun alone, such as a fact's beside a collection's title.
  # Given a list of words, as `collection/2` reads it, it is their words for one joined
  # with "or": "Repository or queue".
  @spec collection_label(
          %{one: String.t(), other: String.t()}
          | nil
          | [%{one: String.t(), other: String.t()} | nil]
        ) :: String.t()
  def collection_label(nouns) when is_list(nouns),
    do: nouns |> collection(:or) |> upcase_first()

  def collection_label(noun), do: noun |> collection() |> upcase_first()

  @doc false
  # collections_label/1 is `collections/2` of `nouns`, joined with "and", with its first
  # letter in upper case: "Repositories and queues".
  @spec collections_label([%{one: String.t(), other: String.t()} | nil]) :: String.t()
  def collections_label(nouns) when is_list(nouns),
    do: nouns |> collections(:and) |> upcase_first()

  defp upcase_first(word) do
    {first, rest} = String.split_at(word, 1)
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
          >{Apiary.ExternalText.lines(@body)}</div>
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
