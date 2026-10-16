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
  # in a url other than the checked link out ("Open on %{integration}", through
  # `CoreComponents.external_link/1`). This module calls no `raw/1`. A ticket's text and
  # its comments' are the page's to render, into the `rendered_body` and
  # `rendered_comment` slots of `ticket/1`, through `SourceComponents.body/1`, the one
  # renderer that sanitises formatted text.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  ## A row

  @doc """
  A ticket's row in the Backlog's list: the integration's tile, the ticket's number, its
  title (a patch to the ticket, `patch`), its repository, who filed it, its comment count,
  when it last changed, and its action.

  `ticket` is a map with these keys:

    * `:ref` - the ticket's ref at the source, `"acme/shop#1231"`;
    * `:number` - its number there, `1231`;
    * `:title`, `:repository` - strings, the repository as the source names it
      (`"acme/shop"`);
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
      name of who declined it).

  The action follows the ticket: an open ticket with no work item has Take in; a live
  work item is its number, a link; a declined one says who declined it, links its work
  item, and offers Take in again on hover or focus; an undone or closed one offers Take in
  again. A closed ticket has no action, and shows its state word and the link to its work
  item, if any.

  `take_in` and `take_in_again` are what a press does (`phx-click`: an event name or a
  `Phoenix.LiveView.JS`), sent with the ticket's ref as `phx-value-ref`.
  """
  attr :id, :string, required: true, doc: "the row's DOM id"
  attr :ticket, :map, required: true, doc: "the ticket, as above"
  attr :integration, :string, required: true, doc: "the integration's name, `\"GitHub\"`"
  attr :patch, :string, required: true, doc: "the list with this ticket open"
  attr :now, :any, default: nil, doc: "the time the row is drawn at; now by default"
  attr :selected, :boolean, default: false, doc: "whether the ticket is the one open"
  attr :take_in, :any, default: nil, doc: "Take in's `phx-click`"
  attr :take_in_again, :any, default: nil, doc: "Take in again's `phx-click`"

  def ticket_row(assigns) do
    assigns =
      assigns
      |> assign(:now, assigns.now || DateTime.utc_now())
      |> assign(row_view(assigns.ticket))

    ~H"""
    <li id={@id} class="q-bl-row" aria-current={@selected && "true"}>
      <.integration_tile name={@integration} class="q-bl-mk" />
      <span class="q-bl-no">#{@ticket.number}</span>
      <span class="q-bl-ttl">
        <.link patch={@patch} class="q-bl-t">{@ticket.title}</.link>
        <span :if={@word} class="q-bl-w">{@word}</span>
        <span class="q-bl-sub">
          {gettext("%{ref} · by %{who} · %{ago}",
            ref: @ticket.ref,
            who: @ticket.filer.name,
            ago: compact(@ticket.updated_at, @now)
          )}<span :if={@word}> · {@word}</span>
        </span>
      </span>
      <span class="q-bl-rp q-mono" title={@ticket.repository}>{@ticket.repository}</span>
      <span class="q-bl-by" title={gettext("Filed by %{name}", name: @ticket.filer.name)}>
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
          phx-value-ref={@ticket.ref}
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
          phx-value-ref={@ticket.ref}
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

    %{word: ticket.state_reason, link: link, action: nil}
  end

  defp row_view(%{work_item: nil}), do: %{word: nil, link: nil, action: :take_in}

  defp row_view(%{work_item: %{state: :declined} = work_item}),
    do: %{
      word: gettext("Declined by %{name}", name: work_item.declined_by),
      link: :declined,
      action: :again
    }

  defp row_view(%{work_item: %{state: state}}) when state in [:undone, :closed],
    do: %{word: nil, link: nil, action: :again}

  defp row_view(%{work_item: _live}), do: %{word: nil, link: :taken, action: nil}

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

  @doc """
  Who filed a ticket: their mark and their name. A person (`kind` `:person`) has the
  person mark; a bot (`:bot`), an account the source says is not a person, has a neutral
  tile with its name's first letter, and no word for its kind. The name is the source's,
  as it gave it.
  """
  attr :name, :string, required: true, doc: "the filer's name at the source"
  attr :kind, :atom, required: true, values: [:person, :bot], doc: "a person or a bot"
  attr :class, :any, default: nil

  def filer(assigns) do
    ~H"""
    <span class={["q-bl-filer", @class]}>
      <.icon :if={@kind == :person} name="hero-user-circle-micro" class="q-bl-by-i size-3" />
      <span :if={@kind == :bot} class="q-bl-bot-av" aria-hidden="true">
        {String.first(@name)}
      </span>
      <span>{@name}</span>
    </span>
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
  A time in a row's narrow column: "3 min", "5 h", "Yesterday", "9 d", by the reader's
  days, with `ApiaryWeb.Format.time_ago/2`'s words in the `title`.
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
      integration, and Close the ticket; Close and a press on the scrim patch to
      `close_patch`. Whether the dialog is modal, and its focus, are the page's, by width.
    * `:full` - the full ticket, a page: Backlog back (`back_path`), the head, the text
      and the comments, and beside them the facts, Filed by among them, the link out and
      the Take in block.

  `ticket` is a map with these keys:

    * `:ref`, `:title`, `:repository` - strings, as in `ticket_row/1`;
    * `:url` - the ticket's page at the source, or `nil`. Open on the integration is
      drawn only for a url the core's https rule (`Apiary.Sources.Body.https?/1`) allows;
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

  slot :take_in, doc: "the Take in or Take in again block"
  slot :rendered_body, doc: "the ticket's text, through `SourceComponents.body/1`"
  slot :rendered_comment, doc: "a comment's text, given the comment, through `body/1`"

  def ticket(assigns) do
    ticket = assigns.ticket
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns,
        now: now,
        out: Apiary.Sources.Body.https?(ticket.url),
        open_on: gettext("Open on %{integration}", integration: assigns.integration),
        meta:
          gettext("%{name} filed this %{filed_ago} · updated %{updated_ago}",
            name: ticket.filer.name,
            filed_ago: Format.time_ago(ticket.filed_at, now),
            updated_ago: Format.time_ago(ticket.updated_at, now)
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
    <div id={@id} class="q-bl-prev" role="dialog" aria-label={gettext("Ticket")}>
      <div class="q-bl-tb">
        <.integration_tile name={@integration} class="q-bl-src" />
        <span class="q-bl-key">{@ticket.ref}</span>
        <span class="q-bl-grow"></span>
        <.button
          :if={@full_path}
          id={"#{@id}-full"}
          variant="ghost"
          class="btn-square"
          navigate={@full_path}
          aria-label={gettext("Open the full ticket")}
          title={gettext("Open the full ticket")}
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
          aria-label={gettext("Close the ticket")}
          title={gettext("Close")}
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </.button>
      </div>
      <h2 id={"#{@id}-title"} class="q-bl-h">{@ticket.title}</h2>
      <p class="q-bl-meta">{@meta}</p>
      <.facts id={@id} ticket={@ticket} filed_by={false} />
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
          <.integration_tile name={@integration} class="q-bl-src" />{@ticket.ref}
        </div>
        <h1 id={"#{@id}-title"}>{@ticket.title}</h1>
        <p class="q-bl-meta">{@meta}</p>
      </div>
      <div class="q-bl-tk-grid">
        <div class="q-bl-tk-main">
          <div id={"#{@id}-text"} class="q-bl-text">{render_slot(@rendered_body)}</div>
          <.comments id={@id} comments={@comments} now={@now} rendered_comment={@rendered_comment} />
        </div>
        <div class="q-bl-tk-side">
          <.facts id={@id} ticket={@ticket} filed_by={true} />
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
  attr :filed_by, :boolean, required: true

  defp facts(assigns) do
    ~H"""
    <dl id={"#{@id}-facts"} class="q-bl-facts">
      <dt>{pgettext("ticket", "Collection")}</dt>
      <dd class="q-bl-repo q-mono">{@ticket.repository}</dd>
      <%= if @ticket.labels != [] do %>
        <dt>{pgettext("ticket", "Labels")}</dt>
        <dd class="q-bl-lb">{Enum.join(@ticket.labels, ", ")}</dd>
      <% end %>
      <%= if @filed_by do %>
        <dt>{gettext("Filed by")}</dt>
        <dd>{@ticket.filer.name}</dd>
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
          <.avatar name={comment.author} size="sm" />
          <b>{comment.author}</b>
          <span class="q-bl-when">{Format.time_ago(comment.at, @now)}</span>
        </div>
        <div class="q-bl-txt">{render_slot(@rendered_comment, comment)}</div>
      </div>
    </section>
    """
  end
end
