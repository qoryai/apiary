defmodule ApiaryWeb.BacklogComponents do
  # The parts the Backlog and the full ticket draw: a ticket's row in the list, who filed
  # it, the integration's tile, a compact time, and one ticket in its frame.
  #
  # Every component takes plain assigns: strings, numbers, times and maps with the keys
  # each one's attributes name, never a context's struct, so the page fills them from
  # whatever the work item records and the source items give it.
  #
  # Everything a ticket holds came from an integration and is untrusted: a component only
  # interpolates it, so HEEx escapes it, and never puts it in a `class` or a `style`, or
  # in a url other than the link out ("Open on %{integration}"), which the core's https
  # rule checks and `CoreComponents.external_link/1` draws. This module calls no `raw/1`.
  # It is shown as an external system's text is: the ticket's key, title, repository,
  # filer, labels and comments' authors in markup isolated in `<bdi>`
  # (`ApiaryWeb.ExternalText.external_text/1`), and `Apiary.ExternalText.line/1` in an
  # attribute or a sentence, and for a closed row's state word. What the page is given
  # stays as it was sent.
  # A ticket's text and its comments' are the page's to render, into the `rendered_body`
  # and `rendered_comment` slots of `ticket/1`, through `SourceComponents.body/1`, the one
  # renderer that sanitises formatted text.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  alias ApiaryWeb.SourceComponents

  ## A row

  @doc """
  A ticket's row in the Backlog's list: the integration's tile, where the row is given the
  integration's name, the ticket's key, its title (a patch to the ticket, `patch`), its
  repository, who filed it, its comment count, when it last changed, and its action.

  `ticket` is a map with these keys:

    * `:id` - Qory Apiary's id for the ticket, `"tk_…"`: the one it is sent and
      addressed by, as sources' keys may overlap within a workspace;
    * `:key` - the ticket's key at the source, such as `"#1231"`, or `nil`; display text
      only, shown as it is, cut to its place with the whole key in its `title`;
    * `:title`, `:repository` - strings, the repository as the source names it
      (`"acme/shop"`). The row's line under the title, where the row is narrow, names
      the ticket by its full form: the repository followed by the key
      (`"acme/shop#1231"`), or the repository alone without a key;
    * `:filer` - who filed it, `%{name: "Lea", kind: :person}`, `filer/1`'s `name` and
      `kind`;
    * `:comment_count` - a whole number;
    * `:updated_at` - a `DateTime`, when it last changed at the source;
    * `:state` - `:open` or `:closed`, its state at the source;
    * `:state_reason` - the integration's word for a closed ticket ("Not planned",
      "Duplicate"), or `nil`; shown on a closed row only;
    * `:work_item` - `nil`, or the ticket's work item, a map with `:number`, `:state` (an
      atom: `:declined`, `:undone`, `:closed`, or a state in which it is live, such as
      `:exploring`), `:path` (its page, or `nil`) and, when declined, `:declined_by` (the
      email address of who declined it, "Former member" for a deleted account, or `nil`
      where no person declined it).

  The action follows the ticket: an open ticket with no work item has Take in; a live
  work item is its number, a link; a declined one says who declined it, links its work
  item, and offers Take in again on hover or focus; an undone or closed one offers Take in
  again. A closed ticket has no action, and shows its state word and the link to its work
  item, if any.

  Who declined a work item is their first letter, with the address as its tooltip
  (`CoreComponents.avatar/1`, in the account menu's colour where the address is
  `reader`), and the address in the title of the work item's link. Where the row is
  narrow, it is on a separate line under the title, which no ellipsis cuts.

  `take_in` and `take_in_again` are what a press does (`phx-click`: an event name or a
  `Phoenix.LiveView.JS`), sent with the ticket's id as `phx-value-id`.
  """
  attr :id, :string, required: true, doc: "the row's DOM id"
  attr :ticket, :map, required: true, doc: "the ticket, as above"

  attr :integration, :string,
    default: nil,
    doc: "the integration's name, `\"GitHub\"`; nil draws no tile"

  attr :patch, :string, required: true, doc: "the list with this ticket open"
  attr :now, :any, default: nil, doc: "the time the row is drawn at; now by default"
  attr :selected, :boolean, default: false, doc: "whether the ticket is the one open"
  attr :reader, :string, default: nil, doc: "the reader's address"
  attr :take_in, :any, default: nil, doc: "Take in's `phx-click`"
  attr :take_in_again, :any, default: nil, doc: "Take in again's `phx-click`"

  def ticket_row(assigns) do
    ticket = assigns.ticket
    now = assigns.now || DateTime.utc_now()
    view = row_view(ticket)
    # Beside the title, the letter's tip opens to its right, as the row is one line high
    # and the list's box cuts what overflows it above the first row.
    {word, shown_word} = word(view.word, assigns.reader, "tooltip-right")
    {_word, narrow_word} = word(view.word, assigns.reader, nil)
    # Under the title, where the row is narrow, who declined it is on a separate line,
    # which no ellipsis cuts; any other word ends the line that can be cut.
    declined = match?({:declined_by, _email}, view.word)
    line_word = if(!declined, do: word)

    sub =
      gettext("%{ref} · by %{who} · %{ago}",
        ref: shown_full_form(ticket),
        who: Apiary.ExternalText.line(ticket.filer.name),
        ago: compact(ticket.updated_at, now)
      )

    assigns =
      assigns
      |> assign(:now, now)
      |> assign(view)
      |> assign(word: word, shown_word: shown_word, narrow_word: narrow_word)
      |> assign(:declined, declined)
      |> assign(sub: sub, line_word: line_word)
      |> assign(:sub_title, if(line_word, do: sub <> " · " <> line_word, else: sub))
      |> assign(
        shown_key: Apiary.ExternalText.line(ticket.key),
        shown_repository: Apiary.ExternalText.line(ticket.repository)
      )

    ~H"""
    <li id={@id} class="q-bl-row">
      <.integration_tile :if={@integration} name={@integration} class="q-bl-mk" />
      <span class="q-bl-no" title={@shown_key}><.external_text text={@ticket.key} /></span>
      <span class="q-bl-ttl">
        <.link
          patch={@patch}
          class="q-bl-t"
          aria-current={@selected && "true"}
        ><.external_text text={@ticket.title} /></.link>
        <span :if={@word} class="q-bl-w"><.rich text={@shown_word} /></span>
        <span class="q-bl-sub" title={@sub_title}>
          {@sub}<span :if={@line_word}> · {@line_word}</span>
        </span>
        <span :if={@declined} class="q-bl-sub q-bl-sub-declined">
          <.rich text={@narrow_word} />
        </span>
      </span>
      <span
        class="q-bl-rp q-mono"
        title={@shown_repository}
      ><.external_text text={@ticket.repository} /></span>
      <span
        class="q-bl-by"
        title={gettext("Filed by %{name}", name: Apiary.ExternalText.line(@ticket.filer.name))}
      >
        <.filer name={@ticket.filer.name} kind={@ticket.filer.kind} />
      </span>
      <span class="q-bl-cm">
        <%= if @ticket.comment_count > 0 do %>
          <.icon name="hero-chat-bubble-left-micro" class="size-3" />
          {Format.number(@ticket.comment_count)}
        <% end %>
      </span>
      <span class="q-bl-upd"><.compact_time at={@ticket.updated_at} now={@now} /></span>
      <span class="q-bl-act">
        <.work_item_link :if={@link} kind={@link} work_item={@ticket.work_item} />
        <.button
          :if={@action == :take_in}
          type="button"
          variant="link"
          class="q-bl-take"
          phx-click={@take_in}
          phx-value-id={@ticket.id}
        >
          {gettext("Take in")}
        </.button>
        <.button
          :if={@action == :again}
          type="button"
          variant="link"
          class={["q-bl-take", @link == :declined && "q-bl-again"]}
          title={gettext("Brings back work item #%{number}", number: @ticket.work_item.number)}
          phx-click={@take_in_again}
          phx-value-id={@ticket.id}
        >
          {gettext("Take in again")}
        </.button>
      </span>
    </li>
    """
  end

  # What a row shows beside its title (`word`), which work item link (`link`: `:taken`,
  # `:declined` or none) and which action (`:take_in`, `:again` or none). A ticket closed
  # at the source has no action, whatever its work item.
  defp row_view(%{state: :closed} = ticket) do
    link =
      case ticket.work_item do
        nil -> nil
        %{state: :declined} -> :declined
        %{state: :undone} -> nil
        _taken -> :taken
      end

    # The state word with nothing left to show is none.
    %{word: shown(ticket.state_reason), link: link, action: nil}
  end

  defp row_view(%{work_item: nil}), do: %{word: nil, link: nil, action: :take_in}

  defp row_view(%{work_item: %{state: :declined} = work_item}),
    do: %{
      word: {:declined_by, work_item.declined_by},
      link: :declined,
      action: :again
    }

  defp row_view(%{work_item: %{state: state}}) when state in [:undone, :closed],
    do: %{word: nil, link: nil, action: :again}

  defp row_view(%{work_item: _live}), do: %{word: nil, link: :taken, action: nil}

  # The word beside the title, as text for a title and as it is drawn: who declined a
  # work item is their first letter, with the address as its tooltip, placed by `tip`.
  defp word({:declined_by, email}, reader, tip) do
    {gettext("Declined by %{name}", name: email),
     rich_gettext("Declined by %{name}", name: letter(email, reader, tip))}
  end

  defp word(word, _reader, _tip), do: {word, word}

  defp letter(email, reader, tip) do
    assigns = %{email: email, reader: reader, tip: tip}
    ~H|<.avatar email={@email} reader={@reader} size="xs" class={@tip} />|
  end

  attr :kind, :atom, required: true, values: [:taken, :declined]
  attr :work_item, :map, required: true

  defp work_item_link(assigns) do
    assigns =
      assign(assigns,
        title:
          case assigns.kind do
            :taken ->
              gettext("Taken in: work item #%{number}", number: assigns.work_item.number)

            :declined ->
              gettext("Work item #%{number}, declined by %{name}",
                number: assigns.work_item.number,
                name: assigns.work_item.declined_by
              )
          end,
        icon:
          if(assigns.kind == :declined,
            do: "hero-minus-circle-micro",
            else: "hero-rectangle-stack-micro"
          )
      )

    ~H"""
    <.link
      :if={@work_item.path}
      navigate={@work_item.path}
      class={["q-bl-wi", @kind == :declined && "q-bl-wi-declined"]}
      title={@title}
    >
      <.icon name={@icon} class="size-3" />#{@work_item.number}
    </.link>
    <span
      :if={!@work_item.path}
      class={["q-bl-wi", @kind == :declined && "q-bl-wi-declined"]}
      title={@title}
    >
      <.icon name={@icon} class="size-3" />#{@work_item.number}
    </span>
    """
  end

  # A ticket's full form: its repository followed directly by its key ("acme/shop#1231"),
  # or the repository alone where the ticket has no key. Plain text, which HEEx escapes
  # where it is interpolated; the key is never parsed. The work item pages name their
  # ticket by it too (`ApiaryWeb.WorkItemComponents`).
  @doc false
  @spec full_form(%{required(:repository) => String.t(), optional(:key) => String.t() | nil}) ::
          String.t()
  def full_form(%{repository: repository, key: key}) when is_binary(key),
    do: repository <> key

  def full_form(%{repository: repository}), do: repository

  # The full form as the Backlog shows it, a text the integration sent
  # (`Apiary.ExternalText.line/1`).
  defp shown_full_form(ticket), do: ticket |> full_form() |> Apiary.ExternalText.line()

  # A text the integration sent, as a page shows it; nil where there is none, or where
  # nothing is left to show.
  defp shown(text), do: Apiary.ExternalText.present(text)

  @doc """
  Who filed a ticket: their mark and their name. A person (`kind` `:person`) has the
  person mark; a bot (`:bot`), an account the source says is not a person, has a neutral
  tile with its name's first letter, and no word for its kind. The name is the source's,
  shown as an external system's text is (`ApiaryWeb.ExternalText.external_text/1`).
  """
  attr :name, :string, required: true, doc: "the filer's name at the source"
  attr :kind, :atom, required: true, values: [:person, :bot], doc: "a person or a bot"
  attr :class, :any, default: nil

  def filer(assigns) do
    ~H"""
    <span class={["q-bl-filer", @class]}>
      <.icon :if={@kind == :person} name="hero-user-circle-micro" class="q-bl-by-i size-3" />
      <.bot_tile :if={@kind == :bot} name={@name} />
      <span><.external_text text={@name} /></span>
    </span>
    """
  end

  @doc """
  A bot's neutral tile: its name's first letter, as the page shows the name
  (`Apiary.ExternalText.line/1`), which a screen reader skips, since the name follows it.
  A row's filer and Filed by's values in the Filter menu draw it.
  """
  attr :name, :string, required: true, doc: "the bot's name at the source"

  def bot_tile(assigns) do
    ~H"""
    <span class="q-bl-bot-av" aria-hidden="true">{String.first(Apiary.ExternalText.line(@name))}</span>
    """
  end

  @doc """
  The integration a ticket came from, as a neutral tile with its name's first letter; a
  screen reader hears the name. It says nothing of the ticket's state.
  """
  attr :name, :string, required: true, doc: "the integration's name, `\"GitHub\"`"
  attr :class, :any, default: nil

  def integration_tile(assigns) do
    ~H"""
    <span class={["q-bl-tile", @class]} role="img" aria-label={@name}>
      <span aria-hidden="true">{String.first(@name)}</span>
    </span>
    """
  end

  @doc """
  A time in a row's narrow column: "now" (under a minute), "3 min", "5 h", "Yesterday",
  "9 d", by the reader's days, with `ApiaryWeb.Format.time_ago/2`'s words in the `title`.
  """
  attr :at, DateTime, required: true, doc: "the time"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def compact_time(assigns) do
    now = assigns.now || DateTime.utc_now()
    assigns = assign(assigns, now: now, words: compact(assigns.at, now))

    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Format.time_ago(@at, @now)}>{@words}</time>
    """
  end

  defp compact(at, now) do
    seconds = max(DateTime.diff(now, at, :second), 0)
    days = Format.days_back(at, now)

    cond do
      seconds < 60 ->
        gettext("now")

      seconds < 3600 ->
        n = div(seconds, 60)
        ngettext("%{number} min", "%{number} min", n, number: Format.number(n))

      days <= 0 ->
        n = div(seconds, 3600)
        ngettext("%{number} h", "%{number} h", n, number: Format.number(n))

      days == 1 ->
        gettext("Yesterday")

      true ->
        ngettext("%{number} d", "%{number} d", days, number: Format.number(days))
    end
  end

  ## The ticket

  @doc """
  One ticket, with its head, its meta line, its facts, the Take in block, its text and its
  comments.

  `frame` is `:list` or `:full`:

    * `:list` - the ticket open over the list. It is one markup, which the page's CSS
      shows beside the list from 1280 px, as a dialog over it from 768 to 1279, and as a
      sheet below 768: the server does not know the width. It is a dialog named "Ticket",
      with a scrim, and its head has Open the full ticket (`full_path`), Open on the
      integration, and Close the ticket. Its name and those words take its source's word
      for its items in place of "ticket" (`item_noun`, `SourceComponents.item/1`):
      "Bug", "Open the full bug"; Close and a press on the scrim patch to
      `close_patch`. Whether the dialog is modal, and its focus, are the page's, by width.
    * `:full` - the full ticket, a page: Backlog back (`back_path`), the head, the text
      and the comments, and beside them the facts, Filed by among them, the link out and
      the Take in block.

  The first fact is the collection the ticket is listed from, labelled with its source's
  word for one of its collections (`collection_noun`, `SourceComponents.collection/1`),
  its first letter in upper case: "Project", or "Collection" where it names none.

  `ticket` is a map with these keys:

    * `:key` - the ticket's key at the source, such as `"#1231"`, or `nil`; display text
      only. The head names the ticket by its full form, the repository followed by the
      key (`"acme/shop#1231"`) or the repository alone, cut to its place with the whole
      of it in its `title`;
    * `:title`, `:repository` - strings, as in `ticket_row/1`;
    * `:url` - the ticket's page at the source, or `nil`. Open on the integration is
      drawn only for a url both the core's https rule (`Apiary.Sources.Body.https?/1`)
      and its external link (`CoreComponents.external_url?/1`) allow;
    * `:labels` - a list of strings, maybe empty;
    * `:filer` - `%{name: "Lea", kind: :person}`, as in `ticket_row/1`;
    * `:filed_at`, `:updated_at` - `DateTime`s at the source.

  `comments` is a list of maps, oldest first, each with `:id` (unique in the ticket),
  `:author` (a name) and `:at` (a `DateTime`), plus whatever the `rendered_comment` slot
  reads to render its text.

  The slots are the page's:

    * `take_in` - the Take in or Take in again block, where the ticket has one;
    * `rendered_body` - the ticket's text, rendered: the page passes
      `SourceComponents.body/1` with the ticket's text and its format;
    * `rendered_comment` - one comment's text, rendered, given the comment
      (`:let={comment}`): the page passes `SourceComponents.body/1` with its text and
      format.

  Without them, the ticket has no block and no text.
  """
  attr :id, :string, required: true, doc: "the ticket's DOM id; the parts take ids under it"
  attr :frame, :atom, default: :list, values: [:list, :full], doc: "over the list, or a page"
  attr :ticket, :map, required: true, doc: "the ticket, as above"
  attr :integration, :string, required: true, doc: "the integration's name, `\"GitHub\"`"
  attr :comments, :list, default: [], doc: "the ticket's comments, as above"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"
  attr :full_path, :string, default: nil, doc: "`:list`: the full ticket's page"
  attr :close_patch, :string, default: nil, doc: "`:list`: the list without the ticket"
  attr :back_path, :string, default: nil, doc: "`:full`: the Backlog"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  attr :collection_noun, :map,
    default: nil,
    doc:
      "what its source calls its collections, `%{one:, other:}` (`Apiary.Adapters.collection_noun/1`); nil for collection and collections"

  slot :take_in, doc: "the Take in or Take in again block"
  slot :rendered_body, doc: "the ticket's text, through `SourceComponents.body/1`"
  slot :rendered_comment, doc: "a comment's text, given the comment, through `body/1`"

  def ticket(assigns) do
    ticket = assigns.ticket
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns,
        now: now,
        out: Apiary.Sources.Body.https?(ticket.url) and external_url?(ticket.url),
        full_form: shown_full_form(ticket),
        item: SourceComponents.item(assigns.item_noun),
        open_on: gettext("Open on %{integration}", integration: assigns.integration),
        meta:
          gettext("%{name} filed this %{filed_ago} · updated %{updated_ago}",
            name: Apiary.ExternalText.line(ticket.filer.name),
            filed_ago: Format.time_ago(ticket.filed_at, now, case: :inline),
            updated_ago: Format.time_ago(ticket.updated_at, now, case: :inline)
          )
      )

    case assigns.frame do
      :list -> list_frame(assigns)
      :full -> full_frame(assigns)
    end
  end

  defp list_frame(assigns) do
    ~H"""
    <div
      :if={@close_patch}
      id={"#{@id}-scrim"}
      class="q-bl-prev-scrim"
      phx-click={JS.patch(@close_patch)}
      aria-hidden="true"
    >
    </div>
    <div id={@id} class="q-bl-prev" role="dialog" aria-label={SourceComponents.item_label(@item_noun)}>
      <div class="q-bl-tb">
        <.integration_tile name={@integration} class="q-bl-src" />
        <span class="q-bl-key" title={@full_form}><.external_text text={@full_form} /></span>
        <span class="q-bl-grow"></span>
        <.button
          :if={@full_path}
          id={"#{@id}-full"}
          variant="ghost"
          class="btn-square"
          navigate={@full_path}
          aria-label={gettext("Open the full %{item}", item: @item)}
          title={gettext("Open the full %{item}", item: @item)}
        >
          <.icon name="hero-arrows-pointing-out-micro" class="size-3.5" />
        </.button>
        <.external_link
          :if={@out}
          id={"#{@id}-out"}
          href={@ticket.url}
          class="btn btn-ghost btn-sm btn-square q-bl-out-icon"
          title={@open_on}
        >
          <span class="sr-only">{@open_on}</span>
        </.external_link>
        <.button
          :if={@close_patch}
          id={"#{@id}-close"}
          variant="ghost"
          class="btn-square"
          patch={@close_patch}
          aria-label={gettext("Close the %{item}", item: @item)}
          title={gettext("Close")}
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </.button>
      </div>
      <h2 id={"#{@id}-title"} class="q-bl-h"><.external_text text={@ticket.title} /></h2>
      <p class="q-bl-meta">{@meta}</p>
      <.facts
        id={@id}
        ticket={@ticket}
        collection_noun={@collection_noun}
        filed_by={false}
      />
      {render_slot(@take_in)}
      <div id={"#{@id}-text"} class="q-bl-text">{render_slot(@rendered_body)}</div>
      <.comments id={@id} comments={@comments} now={@now} rendered_comment={@rendered_comment} />
    </div>
    """
  end

  defp full_frame(assigns) do
    ~H"""
    <article id={@id} class="q-bl-tk" aria-labelledby={"#{@id}-title"}>
      <.button
        :if={@back_path}
        id={"#{@id}-back"}
        variant="ghost"
        class="q-bl-crumb-back"
        navigate={@back_path}
      >
        <.icon name="hero-arrow-left-micro" class="size-3.5" />{gettext("Backlog")}
      </.button>
      <div class="q-bl-tk-head">
        <div class="q-bl-key">
          <.integration_tile name={@integration} class="q-bl-src" />
          <span class="q-bl-key-text" title={@full_form}><.external_text text={@full_form} /></span>
        </div>
        <h1 id={"#{@id}-title"}><.external_text text={@ticket.title} /></h1>
        <p class="q-bl-meta">{@meta}</p>
      </div>
      <div class="q-bl-tk-grid">
        <div class="q-bl-tk-main">
          <div id={"#{@id}-text"} class="q-bl-text">{render_slot(@rendered_body)}</div>
          <.comments id={@id} comments={@comments} now={@now} rendered_comment={@rendered_comment} />
        </div>
        <div class="q-bl-tk-side">
          <.facts
            id={@id}
            ticket={@ticket}
            collection_noun={@collection_noun}
            filed_by={true}
          />
          <.external_link :if={@out} id={"#{@id}-out"} href={@ticket.url} class="q-bl-out">
            {@open_on}
          </.external_link>
          {render_slot(@take_in)}
        </div>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :ticket, :map, required: true
  attr :collection_noun, :map, required: true
  attr :filed_by, :boolean, required: true

  defp facts(assigns) do
    ~H"""
    <dl id={"#{@id}-facts"} class="q-bl-facts">
      <dt>{SourceComponents.collection_label(@collection_noun)}</dt>
      <dd class="q-bl-repo q-mono"><.external_text text={@ticket.repository} /></dd>
      <%= if @ticket.labels != [] do %>
        <dt>{pgettext("ticket", "Labels")}</dt>
        <dd class="q-bl-lb" phx-no-format><%= for {label, index} <- Enum.with_index(@ticket.labels) do %>{if index > 0, do: ", "}<.external_text text={label} /><% end %></dd>
      <% end %>
      <%= if @filed_by do %>
        <dt>{gettext("Filed by")}</dt>
        <dd><.external_text text={@ticket.filer.name} /></dd>
      <% end %>
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :comments, :list, required: true
  attr :now, :any, required: true
  attr :rendered_comment, :list, required: true

  defp comments(assigns) do
    assigns = assign(assigns, :count, length(assigns.comments))

    ~H"""
    <section
      :if={@count > 0}
      id={"#{@id}-comments"}
      class="q-bl-thread"
      aria-labelledby={"#{@id}-comments-h"}
    >
      <h3 id={"#{@id}-comments-h"}>
        {ngettext("%{number} comment", "%{number} comments", @count, number: Format.number(@count))}
      </h3>
      <div :for={comment <- @comments} id={"#{@id}-comment-#{comment.id}"} class="q-bl-cmt">
        <div class="q-bl-who">
          <.avatar name={Apiary.ExternalText.line(comment.author)} size="sm" />
          <b><.external_text text={comment.author} /></b>
          <span class="q-bl-when">{Format.time_ago(comment.at, @now)}</span>
        </div>
        <div class="q-bl-txt">{render_slot(@rendered_comment, comment)}</div>
      </div>
    </section>
    """
  end

  ## The empty Backlog

  @doc """
  The Backlog that holds no ticket: why it is empty, in one of its states, and what to do
  next, in its sources' words (`ApiaryWeb.SourceComponents`). `facts` is what
  `Apiary.Sources.Backlog.backlog_facts/1` gives, a plain map. `state` is the page's
  reading of the facts, the first that holds:

    * `:none` - no integration the organisation is connected through sends tickets. The
      instance's other integrations that do are offered as cards, each with Install to
      whoever may install one; with none, the line says that an instance admin adds them;
    * `:unlisted` - none of those integrations has listed its collections yet: a box for
      each, with Open to whoever may install one;
    * `:unassigned` - no collection is assigned to the workspace: with one integration,
      how many it lists and Assign; with several, a row for each with its count and
      Assign;
    * `:itemless` - the collections assigned have no items at their source, and the cards;
    * `:off` - the Backlog is off for each assigned collection with items: the cards,
      then Turn the Backlog on;
    * `:waiting` - a collection is linked and no ticket has arrived: the first five
      linked, each with its state, then Change.

  Whoever may not take a state's action reads who may, and whom to ask (`facts.ask`).
  Install, Open, Assign, Turn the Backlog on and Change lead to the integration's page in
  Organisation settings › Integrations (`integration_path`, given its adapter's public
  id), or to that list (`integrations_path`) where several integrations are concerned.
  """
  attr :id, :string, default: "backlog-empty"

  attr :state, :atom,
    required: true,
    values: [:none, :unlisted, :unassigned, :itemless, :off, :waiting]

  attr :facts, :map, required: true, doc: "the facts, as above"
  attr :organisation, :string, required: true, doc: "the organisation's name"
  attr :workspace, :string, required: true, doc: "the workspace's name"
  attr :integrations_path, :string, required: true, doc: "Organisation settings › Integrations"
  attr :integration_path, :any, required: true, doc: "an integration's page, of its public id"

  def empty_backlog(%{state: :none} = assigns) do
    ~H"""
    <div id={@id} data-state="none">
      <.empty_state
        icon="hero-squares-plus"
        tone="neutral"
        title={
          gettext("%{organisation} has no integration that sends tickets",
            organisation: @organisation
          )
        }
      >
        <p id={"#{@id}-line"}>
          {pgettext(
            "plain",
            "Tickets come into the Backlog from another system, such as an issue tracker, a support desk or a forge, through an integration that %{organisation} installs.",
            organisation: @organisation
          )}
        </p>
        <p :if={@facts.offered == []} id={"#{@id}-instance"} class="mt-1.5">
          {gettext("An instance admin adds integrations in Instance settings › Adapters.")}
          {gettext(
            "%{organisation} can then install them in Organisation settings › Integrations.",
            organisation: @organisation
          )}
        </p>
        <:actions :if={@facts.offered != []}>
          <.offered
            id={"#{@id}-offered"}
            offered={@facts.offered}
            install={@facts.may.install}
            organisation={@organisation}
            integrations_path={@integrations_path}
            integration_path={@integration_path}
          />
          <.ask_install
            :if={!@facts.may.install}
            id={@id}
            names={@facts.ask.install}
            organisation={@organisation}
          />
        </:actions>
      </.empty_state>
    </div>
    """
  end

  def empty_backlog(%{state: :unlisted} = assigns) do
    ~H"""
    <div id={@id} data-state="unlisted" class="grid gap-4">
      <.empty_state
        :for={source <- @facts.sources}
        icon="hero-arrow-path"
        tone="neutral"
        title={
          gettext("%{integration} hasn't listed its %{collections} yet",
            integration: source.name,
            collections: SourceComponents.collections(source.collection_noun)
          )
        }
      >
        <p id={"#{@id}-line-#{source.id}"}>
          {gettext(
            "%{integration} sends the list after the install. Then the %{items} of the %{collections} assigned to %{workspace} appear here.",
            integration: source.name,
            items: SourceComponents.items(source.item_noun),
            collections: SourceComponents.collections(source.collection_noun),
            workspace: @workspace
          )}
        </p>
        <:actions :if={@facts.may.install}>
          <.action_with_caption
            id={"#{@id}-open-#{source.id}"}
            icon="hero-squares-plus"
            path={@integration_path.(source.id)}
            caption={integration_caption(source.name)}
          >
            {gettext("Open %{integration}", integration: source.name)}
          </.action_with_caption>
        </:actions>
      </.empty_state>
    </div>
    """
  end

  def empty_backlog(%{state: :unassigned} = assigns) do
    sources = assigns.facts.sources
    nouns = Enum.map(sources, & &1.collection_noun)

    assigns =
      assign(assigns,
        sources: sources,
        collections: SourceComponents.collections(nouns, :and),
        title:
          gettext("No %{collection} is assigned to %{workspace}",
            collection: SourceComponents.collection(nouns, :or),
            workspace: assigns.workspace
          ),
        items: SourceComponents.items(shared_item_noun(sources))
      )

    ~H"""
    <div id={@id} data-state="unassigned">
      <.empty_state icon="hero-folder" tone="neutral" title={@title}>
        <p :for={source <- @sources} :if={length(@sources) == 1} id={"#{@id}-line"}>
          {ngettext(
            "%{integration} lists %{number} %{collection} for %{organisation}. Assign it if %{workspace} works on it, and its %{items} appear here.",
            "%{integration} lists %{number} %{collections} for %{organisation}. Assign the ones %{workspace} works on, and their %{items} appear here.",
            source.collections,
            integration: source.name,
            number: Format.number(source.collections),
            collection: SourceComponents.collection(source.collection_noun),
            collections: SourceComponents.collections(source.collection_noun),
            organisation: @organisation,
            workspace: @workspace,
            items: SourceComponents.items(source.item_noun)
          )}
        </p>
        <p :if={length(@sources) > 1} id={"#{@id}-line"}>
          {gettext("Assign the %{collections} %{workspace} works on, and their %{items} appear here.",
            collections: @collections,
            workspace: @workspace,
            items: @items
          )}
        </p>
        <:actions>
          <.action_with_caption
            :for={source <- @sources}
            :if={length(@sources) == 1 and @facts.may.assign}
            id={"#{@id}-assign-#{source.id}"}
            icon="hero-folder"
            variant="primary"
            path={@integration_path.(source.id)}
            caption={integration_caption(source.name)}
          >
            {assign_words(source)}
          </.action_with_caption>
          <ul
            :if={length(@sources) > 1}
            id={"#{@id}-sources"}
            aria-label={gettext("Integrations")}
            class="q-rows w-full max-w-[460px] rounded-box border border-line bg-base-100 text-left"
          >
            <li
              :for={source <- @sources}
              id={"#{@id}-source-#{source.id}"}
              class="flex min-h-[38px] items-center gap-2.5 px-3 py-1.5 text-[12.5px]"
            >
              <.integration_tile name={source.name} class="q-bl-mk" />
              <span class="min-w-0 flex-1 truncate">{source.name}</span>
              <span class="whitespace-nowrap text-faint">
                {ngettext("%{number} %{collection}", "%{number} %{collections}", source.collections,
                  number: Format.number(source.collections),
                  collection: SourceComponents.collection(source.collection_noun),
                  collections: SourceComponents.collections(source.collection_noun)
                )}
              </span>
              <.button
                :if={@facts.may.assign}
                id={"#{@id}-assign-#{source.id}"}
                size="xs"
                navigate={@integration_path.(source.id)}
                title={integration_caption(source.name)}
              >
                {assign_words(source)}
              </.button>
            </li>
          </ul>
          <div
            :if={!@facts.may.assign}
            id={"#{@id}-who"}
            class="grid w-full justify-items-center gap-1"
          >
            <p class="text-[13.5px]/5 text-muted">
              {gettext(
                "Only owners and admins of %{organisation} assign %{collections} to workspaces.",
                organisation: @organisation,
                collections: @collections
              )}
            </p>
            <.ask :if={@facts.ask.assign != []} id={"#{@id}-ask"}>
              {gettext("Ask %{names} to assign the ones %{workspace} works on.",
                names: SourceComponents.joined(@facts.ask.assign, :or),
                workspace: @workspace
              )}
            </.ask>
          </div>
        </:actions>
      </.empty_state>
    </div>
    """
  end

  def empty_backlog(%{state: :itemless} = assigns) do
    assigns =
      assign(assigns, :itemless, Enum.filter(assigns.facts.sources, &(&1.without_items > 0)))

    ~H"""
    <div id={@id} data-state="itemless">
      <.empty_state icon="hero-inbox-stack" tone="neutral" title={off_title(@workspace)}>
        <p id={"#{@id}-line"}>
          <%= for source <- @itemless do %>
            {gettext(
              "The %{collections} assigned to %{workspace} have no %{items} at %{integration}.",
              collections: SourceComponents.collections(source.collection_noun),
              workspace: @workspace,
              items: SourceComponents.items(source.item_noun),
              integration: source.name
            )}
          <% end %>
          <%= if @facts.offered != [] do %>
            {other_system(@workspace)}
          <% end %>
        </p>
        <:actions :if={@facts.offered != []}>
          <.offered
            id={"#{@id}-offered"}
            offered={@facts.offered}
            install={@facts.may.install}
            organisation={@organisation}
            integrations_path={@integrations_path}
            integration_path={@integration_path}
          />
          <.ask_install
            :if={!@facts.may.install}
            id={@id}
            names={@facts.ask.install}
            organisation={@organisation}
          />
        </:actions>
      </.empty_state>
    </div>
    """
  end

  def empty_backlog(%{state: :off} = assigns) do
    off = Enum.filter(assigns.facts.sources, &(&1.switched_off > 0))
    nouns = Enum.map(off, & &1.collection_noun)
    n = assigns.facts.switched_off

    assigns =
      assign(assigns,
        line:
          ngettext(
            "The Backlog is off for the one %{collection} assigned to %{workspace}.",
            "The Backlog is off for the %{number} %{collections} assigned to %{workspace}.",
            n,
            number: Format.number(n),
            collection: SourceComponents.collection(nouns, :or),
            collections: SourceComponents.collections(nouns, :and),
            workspace: assigns.workspace
          ),
        cards?: assigns.facts.offered != [],
        target: several_or_one(off, assigns)
      )

    ~H"""
    <div id={@id} data-state="off">
      <.empty_state icon="hero-inbox-stack" tone="neutral" title={off_title(@workspace)}>
        <p id={"#{@id}-line"}>
          {@line}
          <%= if @cards? do %>
            {other_system(@workspace)}
          <% end %>
        </p>
        <:actions>
          <.offered
            :if={@cards?}
            id={"#{@id}-offered"}
            offered={@facts.offered}
            install={@facts.may.install}
            organisation={@organisation}
            integrations_path={@integrations_path}
            integration_path={@integration_path}
          />
          <.action_with_caption
            :if={@facts.may.switch}
            id={"#{@id}-turn-on"}
            icon={!@cards? && "hero-inbox-stack"}
            variant={if @cards?, do: "ghost", else: "primary"}
            path={@target.path}
            caption={@target.caption}
          >
            {gettext("Turn the Backlog on")}
          </.action_with_caption>
          <.ask_install
            :if={@cards? and !@facts.may.install}
            id={@id}
            names={@facts.ask.install}
            organisation={@organisation}
          />
          <p
            :if={!@cards? and !@facts.may.switch}
            id={"#{@id}-who"}
            class="w-full text-[13.5px]/5 text-muted"
          >
            {gettext("Only owners and admins change the Backlog switches.")}
          </p>
        </:actions>
      </.empty_state>
    </div>
    """
  end

  def empty_backlog(%{state: :waiting} = assigns) do
    sources = Enum.filter(assigns.facts.sources, &(&1.linked > 0))
    nouns = Enum.map(sources, & &1.collection_noun)
    item_noun = shared_item_noun(sources)
    shown = length(assigns.facts.linked)

    assigns =
      assign(assigns,
        sources: sources,
        nouns: nouns,
        item_noun: item_noun,
        more: assigns.facts.linked_collections - shown,
        target: several_or_one(sources, assigns)
      )

    ~H"""
    <div id={@id} data-state="waiting">
      <.empty_state
        icon="hero-inbox-stack"
        tone="neutral"
        title={gettext("No %{items} yet", items: SourceComponents.items(@item_noun))}
      >
        <p :for={source <- @sources} :if={length(@sources) == 1} id={"#{@id}-line"}>
          {gettext(
            "%{integration} lists the open %{items} of the %{collections} assigned to %{workspace}, then sends each new one and each change.",
            integration: source.name,
            items: SourceComponents.items(@item_noun),
            collections: SourceComponents.collections(@nouns, :and),
            workspace: @workspace
          )}
        </p>
        <p :if={length(@sources) > 1} id={"#{@id}-line"}>
          {gettext(
            "Each integration lists the open %{items} of the %{collections} assigned to %{workspace}, then sends each new one and each change.",
            items: SourceComponents.items(@item_noun),
            collections: SourceComponents.collections(@nouns, :and),
            workspace: @workspace
          )}
        </p>
        <:actions>
          <ul
            id={"#{@id}-linked"}
            aria-label={
              gettext("%{collections} assigned to %{workspace}",
                collections: SourceComponents.collections_label(@nouns),
                workspace: @workspace
              )
            }
            class="q-rows w-full max-w-[460px] rounded-box border border-line bg-base-100 text-left"
          >
            <li
              :for={collection <- @facts.linked}
              id={"#{@id}-linked-#{collection.id}"}
              class="flex min-h-[38px] items-center gap-2.5 px-3 py-1.5 text-[12.5px]"
            >
              <.integration_tile name={collection.integration.name} class="q-bl-mk" />
              <span
                class="min-w-0 flex-1 truncate q-mono"
                title={Apiary.ExternalText.line(collection.title)}
              ><.external_text text={collection.title} /></span>
              <span class="whitespace-nowrap text-faint">
                {if collection.listing_complete?,
                  do:
                    gettext("No open %{items}",
                      items: SourceComponents.items(collection.item_noun)
                    ),
                  else: gettext("Not listed yet")}
              </span>
            </li>
            <li
              :if={@more > 0}
              id={"#{@id}-linked-more"}
              class="flex min-h-[38px] items-center justify-center px-3 py-1.5 text-[12.5px] text-muted"
            >
              {ngettext("and %{number} more", "and %{number} more", @more,
                number: Format.number(@more)
              )}
            </li>
          </ul>
          <.action_with_caption
            :if={@facts.may.assign}
            id={"#{@id}-change"}
            icon="hero-folder"
            path={@target.path}
            caption={@target.caption}
          >
            {gettext("Change the %{collections}",
              collections: SourceComponents.collections(@nouns, :and)
            )}
          </.action_with_caption>
          <.ask :if={!@facts.may.assign} id={"#{@id}-who"} icon="hero-inbox">
            {gettext("Each new %{item} filed in one of these %{collections} appears here.",
              item: SourceComponents.item(@item_noun),
              collections: SourceComponents.collections(@nouns, :or)
            )}
          </.ask>
        </:actions>
      </.empty_state>
    </div>
    """
  end

  defp off_title(workspace),
    do: gettext("No tickets come into %{workspace}'s Backlog", workspace: workspace)

  defp other_system(workspace),
    do:
      pgettext(
        "plain",
        "To take %{workspace}'s tickets from another system, install its integration.",
        workspace: workspace
      )

  defp integration_caption(name),
    do: gettext("Organisation settings › Integrations › %{integration}", integration: name)

  defp assign_words(source),
    do:
      gettext("Assign %{collections}",
        collections: SourceComponents.collections(source.collection_noun)
      )

  # The words the sources share for their items; nil, ticket and tickets, where they
  # differ.
  defp shared_item_noun([%{item_noun: noun} | rest]),
    do: if(Enum.all?(rest, &(&1.item_noun == noun)), do: noun)

  defp shared_item_noun([]), do: nil

  # Where an action about `sources` leads: one integration's page, or the list of them.
  defp several_or_one([source], assigns),
    do: %{
      path: assigns.integration_path.(source.id),
      caption: integration_caption(source.name)
    }

  defp several_or_one(_sources, assigns),
    do: %{
      path: assigns.integrations_path,
      caption: gettext("Organisation settings › %{page}", page: gettext("Integrations"))
    }

  # The cards of the integrations the organisation can install: the first six, by name,
  # then Show all.
  attr :id, :string, required: true
  attr :offered, :list, required: true
  attr :install, :boolean, required: true
  attr :organisation, :string, required: true
  attr :integrations_path, :string, required: true
  attr :integration_path, :any, required: true

  defp offered(assigns) do
    assigns = assign(assigns, :cards, Enum.take(assigns.offered, 6))

    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-heading"}
      class="grid w-full justify-items-center gap-2"
    >
      <h3 id={"#{@id}-heading"} class="text-xs/4 font-medium text-muted">
        {gettext("Integrations %{organisation} can install", organisation: @organisation)}
      </h3>
      <ul class={[
        "grid w-full grid-cols-1 gap-2 text-left",
        if(length(@cards) == 1, do: "max-w-[340px]", else: "max-w-[680px] md:grid-cols-2")
      ]}>
        <li
          :for={adapter <- @cards}
          id={"#{@id}-#{adapter.id}"}
          class="flex items-center gap-3 rounded-box border border-line bg-base-100 p-3 shadow-xs hover:border-line-strong"
        >
          <.integration_tile
            name={adapter.name}
            class="q-bl-src !size-8 !rounded-lg !border-[1.5px] bg-base-200 !text-sm"
          />
          <span class="grid min-w-0 flex-1">
            <.link
              id={"#{@id}-#{adapter.id}-name"}
              navigate={@integration_path.(adapter.id)}
              title={integration_caption(adapter.name)}
              class="truncate text-[13.5px] font-medium hover:underline"
            >
              {adapter.name}
            </.link>
            <span class="truncate text-[12.5px] text-muted">{offer_line(adapter)}</span>
          </span>
          <.button
            :if={@install}
            id={"#{@id}-#{adapter.id}-install"}
            size="xs"
            navigate={@integration_path.(adapter.id)}
            title={integration_caption(adapter.name)}
          >
            {gettext("Install")}
          </.button>
        </li>
      </ul>
      <.link
        :if={length(@offered) > length(@cards)}
        id={"#{@id}-all"}
        navigate={@integrations_path}
        class="text-[12.5px] text-accent hover:underline"
      >
        {gettext("Show all")}
      </.link>
    </section>
    """
  end

  # What an offered integration sends, in its words: "Tasks from projects"; its words for
  # its items alone where it names no collections.
  defp offer_line(%{item_noun: items, collection_noun: nil}),
    do: SourceComponents.items_label(items)

  defp offer_line(%{item_noun: items, collection_noun: collections}),
    do:
      gettext("%{items} from %{collections}",
        items: SourceComponents.items_label(items),
        collections: SourceComponents.collections(collections)
      )

  # Who installs integrations, and whom to ask.
  attr :id, :string, required: true
  attr :names, :list, required: true
  attr :organisation, :string, required: true

  defp ask_install(assigns) do
    ~H"""
    <div id={"#{@id}-who"} class="grid w-full justify-items-center gap-1">
      <p class="text-[13.5px]/5 text-muted">
        {gettext("Owners and admins of %{organisation} install integrations.",
          organisation: @organisation
        )}
      </p>
      <.ask :if={@names != []} id={"#{@id}-ask"}>
        {gettext("Ask %{names} to install one.", names: SourceComponents.joined(@names, :or))}
      </.ask>
    </div>
    """
  end

  # A line with a quiet icon: whom to ask, or what happens next.
  attr :id, :string, required: true
  attr :icon, :string, default: "hero-users"
  slot :inner_block, required: true

  defp ask(assigns) do
    ~H"""
    <p id={@id} class="inline-flex w-full items-center justify-center gap-2 text-[13px]">
      <.icon name={@icon} class="size-4 shrink-0 text-muted" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  # A state's action, a button, with where it leads under it.
  attr :id, :string, required: true
  attr :icon, :any, default: nil
  attr :variant, :string, default: "default"
  attr :path, :string, required: true
  attr :caption, :string, required: true
  slot :inner_block, required: true

  defp action_with_caption(assigns) do
    ~H"""
    <div class="grid w-full justify-items-center gap-1.5">
      <.button id={@id} variant={@variant} navigate={@path} title={@caption}>
        <.icon :if={@icon} name={@icon} class="size-4" />{render_slot(@inner_block)}
      </.button>
      <p id={"#{@id}-caption"} class="text-xs text-faint">{@caption}</p>
    </div>
    """
  end
end
