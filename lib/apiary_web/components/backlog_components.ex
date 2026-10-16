defmodule ApiaryWeb.BacklogComponents do
  # The parts the Backlog draws: a ticket's row in the list, who filed it, the
  # integration's tile and a compact time.
  #
  # Every component takes plain assigns: strings, numbers, times and maps with the keys
  # each one's attributes name, never a context's struct, so the page fills them from
  # whatever the work item records and the source items give it.
  #
  # Everything a ticket holds came from an integration and is untrusted: a component only
  # interpolates it, so HEEx escapes it, and never puts it in a `class`, a `style` or a
  # url.
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
end
