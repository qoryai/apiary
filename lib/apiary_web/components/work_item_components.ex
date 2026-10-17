defmodule ApiaryWeb.WorkItemComponents do
  # The parts of a work item's page (`/:org/:workspace/work/:number`, its Ticket tab, and
  # `…/thread`, its Thread), and the status words and marks the Work items list shares
  # (`ApiaryWeb.WorkItemListComponents`).
  #
  # Every component takes plain assigns: strings, numbers, times and maps with the keys
  # each one's attributes name, never a context's struct, so the page fills them from
  # whatever the work item records give it. A work item is a map with these keys:
  #
  #   * `:number` - the workspace's number for it, which Qory Apiary gives, `88`;
  #   * `:title` - the ticket's title as it was taken in;
  #   * `:external_ref` - the ticket's ref at the source, `"acme/shop#1204"`: words to
  #     show, never an id, a path or an event's value;
  #   * `:url` - the ticket's page at the source, or `nil`;
  #   * `:repository` - the repository as the source names it, `"acme/shop"`;
  #   * `:status` - `:queued` or `:running` (Explore), `:confirm`, `:shape`, `:declined`,
  #     `:closed` or `:undone`;
  #   * `:stage` - for an ended work item, the stage it ended at (`:explore`, `:confirm`
  #     or `:shape`); a live one's stage follows from its status;
  #   * `:owner` - a person;
  #   * `:ended_by`, `:ended_at` - who declined, closed or undid it, and when;
  #   * `:updated_at` - when it last changed.
  #
  # The page's parts read more of it, each named where it is used. A person is a map with
  # `:name` and `:you`, true when the person is the reader: a text the reader is the
  # subject of has its own words ("You own it", "Closed by you").
  #
  # Every DOM id, `phx-value-*` and path is Qory Apiary's: the work item's number, a
  # comment's `public_id`, and the paths the page gives. The ticket's ref and its number
  # at the source are text only. The page gives every path (`again_path`, `ticket_path`,
  # the run's `path`); a component builds none.
  #
  # The events a component sends, for the page to handle:
  #
  #   * `"undo"`, `"confirm"`, `"ask_decline"`, `"decline"`, `"ask_close"`, `"close"` -
  #     with `phx-value-number`, the work item's number;
  #   * `"ask_delete_comment"`, `"delete_comment"` - with `phx-value-comment`, the
  #     comment's `public_id`;
  #   * `"comment"` - the composer's form, its text as `body`;
  #   * `"show_earlier_comments"` - the Ticket tab's earlier comments.
  #
  # A question (decline, close, delete a comment) shows in place while the page says so
  # (`asking`, a comment's `state`); its Cancel and Escape do `cancel`, a path to patch to
  # or a JS command, `JS.push("cancel_question")` unless given.
  #
  # Everything a ticket holds came from an integration and is untrusted, and what a person
  # wrote is too: a component only interpolates it, so HEEx escapes it. A ticket's text
  # and its comments are rendered by `SourceComponents.body/1`, the one renderer that
  # sanitises formatted text.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  alias ApiaryWeb.BacklogComponents
  alias ApiaryWeb.SourceComponents

  @stages [:explore, :confirm, :shape]
  @ended [:declined, :closed, :undone]

  ## The status and its mark

  @doc """
  A work item's status: its mark and its words, the row's and the meta line's. Waits for
  you to confirm is the one strong status (`q-wi-hot`).
  """
  attr :work_item, :map, required: true, doc: "the work item: `:status`, `:owner`, `:ended_by`"
  attr :class, :any, default: nil

  def work_item_status(assigns) do
    assigns =
      assign(assigns, words: status_words(assigns.work_item), hot: hot?(assigns.work_item))

    ~H"""
    <span class={["q-wi-st", @hot && "q-wi-hot", @class]}>
      <.work_item_mark kind={mark(@work_item)} />{@words}
    </span>
    """
  end

  @doc """
  A status's mark, the one colour of a row: `:todo` (Explore is queued), `:run` (Qory is
  exploring), `:wait` (waits for the reader), `:wait_other` (waits for another member),
  `:ready` (Ready for Shape), `:declined` and `:closed` (closed or undone). Decorative:
  its words are always beside it.
  """
  attr :kind, :atom,
    required: true,
    values: [:todo, :run, :wait, :wait_other, :ready, :declined, :closed]

  attr :class, :any, default: nil

  def work_item_mark(assigns) do
    ~H"""
    <span class={["q-wi-mk", "q-wi-mk-#{@kind}", @class]} aria-hidden="true"></span>
    """
  end

  @doc false
  def status_words(%{status: :queued}), do: gettext("Explore is queued")
  def status_words(%{status: :running}), do: gettext("Qory is exploring")

  def status_words(%{status: :confirm, owner: owner}) do
    if you?(owner),
      do: gettext("Waits for you to confirm"),
      else: gettext("Waits for %{name} to confirm", name: owner.name)
  end

  def status_words(%{status: :shape}), do: gettext("Ready for Shape")

  def status_words(%{status: :declined, ended_by: by}) do
    if you?(by),
      do: gettext("Declined by you"),
      else: gettext("Declined by %{name}", name: by.name)
  end

  def status_words(%{status: :closed, ended_by: by}) do
    if you?(by), do: gettext("Closed by you"), else: gettext("Closed by %{name}", name: by.name)
  end

  def status_words(%{status: :undone, ended_by: by}) do
    if you?(by), do: gettext("Undone by you"), else: gettext("Undone by %{name}", name: by.name)
  end

  @doc false
  def mark(%{status: :queued}), do: :todo
  def mark(%{status: :running}), do: :run
  def mark(%{status: :confirm, owner: owner}), do: if(you?(owner), do: :wait, else: :wait_other)
  def mark(%{status: :shape}), do: :ready
  def mark(%{status: :declined}), do: :declined
  def mark(%{status: status}) when status in [:closed, :undone], do: :closed

  @doc false
  def hot?(%{status: :confirm, owner: owner}), do: you?(owner)
  def hot?(_work_item), do: false

  @doc false
  def you?(%{you: true}), do: true
  def you?(_person), do: false

  @doc false
  def stage_name(:explore), do: gettext("Explore")
  def stage_name(:confirm), do: gettext("Confirm")
  def stage_name(:shape), do: gettext("Shape")

  @doc false
  def owner_phrase(owner) do
    if you?(owner), do: gettext("You own it"), else: gettext("%{name} owns it", name: owner.name)
  end

  # Whether a ticket's url may be a link out: https, and one the core's external link
  # allows (as the Backlog's ticket).
  defp out?(url), do: Apiary.Sources.Body.https?(url) and external_url?(url)

  # A time in a sentence: its words, with the full time and its zone in the `title`.
  defp time_tag(at, words) do
    assigns = %{at: at, words: words}

    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Format.datetime(@at, zone: true)}>{@words}</time>
    """
  end

  defp inline_ago(at, now), do: time_tag(at, Format.time_ago(at, now, case: :inline))
  defp day(at, now), do: time_tag(at, Format.day(at, now))
  defp now(assigns), do: assigns[:now] || DateTime.utc_now()

  defp stage_of(%{status: status}) when status in [:queued, :running], do: :explore
  defp stage_of(%{status: :confirm}), do: :confirm
  defp stage_of(%{status: :shape}), do: :shape
  defp stage_of(work_item), do: Map.get(work_item, :stage) || :explore

  defp ended?(%{status: status}), do: status in @ended

  ## The page's frame

  @doc """
  A work item's page: the header (`header`: `work_item_header/1`, then the notices), the
  rail (`rail`: the step card and Details), and the tabs and the tab's body (`body`). From
  1440 px the rail is a sticky column beside the header and the body; below it, it comes
  between them. At most 1360 px wide, from the page's left edge.
  """
  attr :id, :string, default: "work-item"
  attr :label, :string, required: true, doc: "the rail's name: \"Work item #%{number}\""
  slot :header, required: true
  slot :rail
  slot :body, required: true

  def work_item_frame(assigns) do
    ~H"""
    <div id={@id} class="q-wi">
      <header class="q-wi-h">{render_slot(@header)}</header>
      <aside :if={@rail != []} class="q-wi-r" aria-label={@label}>{render_slot(@rail)}</aside>
      <div class="q-wi-b">{render_slot(@body)}</div>
    </div>
    """
  end

  ## The header

  @doc """
  A work item's header: the ticket's title as it was taken in and the work item's number;
  the meta line, its status, the ticket's ref with the integration's mark as a link out
  ("Open %{ref} on %{integration}"), and who owns it; More, with Copy link and Close work
  item…, on a work item that has not ended; then the stages (`stage_track/1`).

  Copy link copies `link`, the work item's address, in the browser (the `CopyToClipboard`
  hook). Close work item… sends `"ask_close"`, and is there only with `can_close`.
  """
  attr :id, :string, default: "work-item-head"
  attr :work_item, :map, required: true, doc: "the work item"
  attr :integration, :string, required: true, doc: "the integration's name, `\"GitHub\"`"
  attr :link, :string, required: true, doc: "the work item's address, for Copy link"
  attr :can_close, :boolean, default: false, doc: "whether the reader may close it"

  def work_item_header(assigns) do
    work_item = assigns.work_item

    assigns =
      assign(assigns,
        number: work_item.number,
        ended: ended?(work_item),
        href: if(out?(work_item[:url]), do: work_item.url),
        open_title:
          gettext("Open %{ref} on %{integration}",
            ref: work_item.external_ref,
            integration: assigns.integration
          )
      )

    ~H"""
    <div id={@id} class="q-wi-top">
      <div class="q-wi-grow">
        <h1 id={"#{@id}-title"} class="q-wi-title outline-none" tabindex="-1">
          {@work_item.title}<span class="q-wi-no">#{@number}</span>
        </h1>
        <div class="q-wi-meta-wrap">
          <p id={"#{@id}-meta"} class="q-wi-meta">
            <.work_item_status work_item={@work_item} />
            <span>
              <.external_link href={@href} class="q-wi-ref" title={@href && @open_title}>
                <BacklogComponents.integration_tile name={@integration} />{@work_item.external_ref}
              </.external_link>
            </span>
            <span>{owner_phrase(@work_item.owner)}</span>
          </p>
        </div>
      </div>
      <.row_menu
        :if={!@ended}
        id={"#{@id}-more"}
        class="q-wi-more"
        label={gettext("More for work item #%{number}", number: @number)}
        title={gettext("More")}
      >
        <.menu_item
          id={"#{@id}-copy"}
          phx-hook="CopyToClipboard"
          data-copy={@link}
          data-copied-words={gettext("Copied")}
        >
          {gettext("Copy link")}
        </.menu_item>
        <.menu_divider :if={@can_close} />
        <.menu_item
          :if={@can_close}
          id={"#{@id}-close"}
          phx-click="ask_close"
          phx-value-number={@number}
        >
          {gettext("Close work item…")}
        </.menu_item>
      </.row_menu>
    </div>
    <.stage_track id={"#{@id}-stages"} work_item={@work_item} />
    """
  end

  @doc """
  The stages, Explore, Confirm and Shape, in order: those before the work item's stage
  done, its stage the current step (`aria-current="step"`), amber while it waits at
  Confirm. An ended work item has no current step, but a declined one's stage, marked
  with a cross, and the end mark beside the stages says how it ended: Closed, Declined or
  Undone.
  """
  attr :id, :string, default: "work-item-stages"
  attr :work_item, :map, required: true, doc: "the work item: `:status`, and `:stage` if ended"

  def stage_track(assigns) do
    work_item = assigns.work_item
    at = Enum.find_index(@stages, &(&1 == stage_of(work_item)))
    ended = ended?(work_item)

    stages =
      for {stage, i} <- Enum.with_index(@stages) do
        state =
          cond do
            i < at -> :done
            i == at and not ended -> :now
            i == at and work_item.status == :declined -> :stop
            true -> :todo
          end

        %{key: stage, n: i + 1, state: state}
      end

    assigns =
      assign(assigns,
        stages: stages,
        ended: ended,
        wait: work_item.status == :confirm,
        status: work_item.status
      )

    ~H"""
    <div id={@id} class={["q-wi-track", @ended && "q-wi-track-ended"]}>
      <ol aria-label={gettext("Stages")}>
        <li
          :for={stage <- @stages}
          id={"#{@id}-#{stage.key}"}
          class={[
            "q-wi-stage",
            "q-wi-stage-#{stage.state}",
            stage.state == :now && @wait && "q-wi-stage-wait"
          ]}
          aria-current={stage.state in [:now, :stop] && "step"}
        >
          <span class="q-wi-stage-n" aria-hidden="true">
            <%= case stage.state do %>
              <% :done -> %>
                <.icon name="hero-check-micro" class="size-3" />
              <% :stop -> %>
                <.icon name="hero-x-mark-micro" class="size-3" />
              <% _ -> %>
                {stage.n}
            <% end %>
          </span>
          {stage_name(stage.key)}
        </li>
      </ol>
      <span :if={@ended} id={"#{@id}-end"} class="q-wi-end">
        <.icon name={end_icon(@status)} class="size-3.5" />{end_word(@status)}
      </span>
    </div>
    """
  end

  defp end_icon(:undone), do: "hero-arrow-uturn-left-micro"
  defp end_icon(:declined), do: "hero-minus-circle-micro"
  defp end_icon(:closed), do: "hero-x-circle-micro"

  defp end_word(:undone), do: gettext("Undone")
  defp end_word(:declined), do: gettext("Declined")
  defp end_word(:closed), do: gettext("Closed")

  ## The step card

  @doc """
  What the work item needs now, from whom: one card, with at most one primary button, for
  a live work item; nothing for an ended one.

    * Explore, queued: what Qory does when the run starts, with Qory's bee; who took it in
      and when, Undo until a run starts (`"undo"`), and what undoing does to the ticket,
      or, after the integration's uninstall (`uninstalled`), that nothing changes there.
      The work item's `:taken_in_by` and `:taken_in_at` say who and when.
    * Explore, running: what Qory does, and with whose answers on a second run (`:run`,
      `%{id:, path:, started_at:, answers_by:}`, `answers_by` a name or `nil`), and when
      the run started; the run's id links its page where `path` is given.
    * Confirm: Qory's proposal waits; Confirm (`"confirm"`) and Decline (`"ask_decline"`).
      With `asking: :decline`, the Decline question in their place: its line, Decline
      (`"decline"`) and Cancel.
    * Shape: who confirmed Qory's proposal and when (`:confirmed_by`, `:confirmed_at`).

  Undo, Confirm and Decline are there only with `can_act`.
  """
  attr :id, :string, default: "work-item-step"
  attr :work_item, :map, required: true, doc: "the work item"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"
  attr :can_act, :boolean, default: false, doc: "whether the reader may undo, confirm, decline"
  attr :asking, :atom, default: nil, values: [nil, :decline], doc: "the question showing"
  attr :cancel, :any, default: nil, doc: "what the question's Cancel does"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def step_card(%{work_item: %{status: status}} = assigns) when status in @ended, do: ~H""

  def step_card(assigns) do
    work_item = assigns.work_item

    assigns =
      assign(assigns,
        now: now(assigns),
        number: work_item.number,
        status: work_item.status,
        stage: stage_of(work_item),
        mark: mark(work_item),
        mine: hot?(work_item),
        cancel: assigns.cancel || JS.push("cancel_question")
      )

    ~H"""
    <section
      id={@id}
      class={["q-wi-step", @mine && "q-wi-step-ask"]}
      aria-labelledby={"#{@id}-h"}
    >
      <div class="q-wi-step-h">
        <.work_item_mark kind={@mark} />
        <h2 id={"#{@id}-h"}>{stage_name(@stage)}</h2>
        <.step_badge status={@status} mine={@mine} />
      </div>
      <.step_body
        id={@id}
        work_item={@work_item}
        status={@status}
        number={@number}
        integration={@integration}
        uninstalled={@uninstalled}
        can_act={@can_act}
        asking={@asking}
        cancel={@cancel}
        now={@now}
      />
    </section>
    """
  end

  attr :status, :atom, required: true
  attr :mine, :boolean, required: true

  defp step_badge(%{status: :queued} = assigns),
    do: ~H|<.badge class="q-wi-badge">{gettext("Queued")}</.badge>|

  defp step_badge(%{status: :running} = assigns),
    do: ~H|<.badge color="success" class="q-wi-badge">{gettext("Running")}</.badge>|

  defp step_badge(%{status: :confirm, mine: true} = assigns),
    do: ~H|<.badge color="warning" class="q-wi-badge">{gettext("Waits for you")}</.badge>|

  defp step_badge(%{status: :shape} = assigns),
    do: ~H|<.badge color="info" class="q-wi-badge">{gettext("Ready")}</.badge>|

  defp step_badge(assigns), do: ~H""

  attr :id, :string, required: true
  attr :work_item, :map, required: true
  attr :status, :atom, required: true
  attr :number, :integer, required: true
  attr :integration, :string, required: true
  attr :uninstalled, :boolean, required: true
  attr :can_act, :boolean, required: true
  attr :asking, :atom, required: true
  attr :cancel, :any, required: true
  attr :now, :any, required: true

  defp step_body(%{status: :queued} = assigns) do
    assigns = assign(assigns, :undo_line, undo_line(assigns))

    ~H"""
    <p class="q-wi-bee-line">
      <.bee />
      <span>
        {gettext(
          "Qory reads the ticket and the code when the run starts, and proposes how to build it."
        )}
      </span>
    </p>
    <div :if={@can_act} id={"#{@id}-undo"} class="q-wi-undo">
      <p :if={@undo_line} id={"#{@id}-undo-line"}><.rich text={@undo_line} /></p>
      <div class="q-wi-acts">
        <.button type="button" phx-click="undo" phx-value-number={@number}>
          <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" />{gettext("Undo")}
        </.button>
      </div>
    </div>
    """
  end

  defp step_body(%{status: :running} = assigns) do
    run = assigns.work_item.run
    answers_by = run[:answers_by]

    assigns =
      assign(assigns,
        line:
          if(answers_by,
            do:
              gettext(
                "Qory is exploring again, with %{name}'s answers. It reads the ticket and the code, and proposes how to build it.",
                name: answers_by
              ),
            else:
              gettext(
                "Qory is exploring. It reads the ticket and the code, and proposes how to build it."
              )
          ),
        started:
          rich_gettext("Run %{run} started %{when}.",
            run: run_ref(run),
            when: inline_ago(run.started_at, assigns.now)
          )
      )

    ~H"""
    <p class="q-wi-bee-line"><.bee /><span>{@line}</span></p>
    <p id={"#{@id}-run"}><.rich text={@started} /></p>
    """
  end

  defp step_body(%{status: :confirm, asking: :decline} = assigns) do
    ~H"""
    <.inline_confirm
      id={"#{@id}-decline"}
      class="q-wi-ask"
      question={gettext("Decline work item #%{number}?", number: @number)}
      cancel={@cancel}
    >
      <%= if @uninstalled do %>
        {gettext(
          "%{integration} is no longer connected, so nothing changes on the ticket. The work item stays in Qory Apiary, declined.",
          integration: @integration
        )}
      <% else %>
        {gettext(
          "The ticket stays open on %{integration} and keeps Qory's label, and nothing new is posted there. In the Backlog, Take in again brings this work item back.",
          integration: @integration
        )}
      <% end %>
      <:action>
        <.button
          id={"#{@id}-decline-go"}
          type="button"
          variant="danger"
          size="xs"
          phx-click="decline"
          phx-value-number={@number}
        >
          {gettext("Decline")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp step_body(%{status: :confirm} = assigns) do
    ~H"""
    <p class="q-wi-bee-line">
      <.bee />
      <span>
        {gettext("Qory proposed how to build it. Confirm the proposal, or decline the work item.")}
      </span>
    </p>
    <div :if={@can_act} class="q-wi-acts">
      <.button
        id={"#{@id}-confirm"}
        type="button"
        variant="primary"
        phx-click="confirm"
        phx-value-number={@number}
      >
        <.icon name="hero-check-micro" class="size-3.5" />{gettext("Confirm")}
      </.button>
      <.button
        id={"#{@id}-decline"}
        type="button"
        variant="ghost"
        phx-click="ask_decline"
        phx-value-number={@number}
      >
        {gettext("Decline")}
      </.button>
    </div>
    """
  end

  defp step_body(%{status: :shape} = assigns) do
    work_item = assigns.work_item

    assigns =
      assign(
        assigns,
        :line,
        rich_gettext(
          "%{name} confirmed Qory's proposal %{when}. Shape is the plan and its acceptance criteria.",
          name: work_item.confirmed_by.name,
          when: inline_ago(work_item.confirmed_at, assigns.now)
        )
      )

    ~H"""
    <p><.rich text={@line} /></p>
    """
  end

  # Who took the work item in, and what undoing does to the ticket. After an uninstall the
  # line has words for the reader alone: for another person's take in, none.
  defp undo_line(%{work_item: work_item, uninstalled: uninstalled} = assigns) do
    by = work_item.taken_in_by
    at = inline_ago(work_item.taken_in_at, assigns.now)

    cond do
      uninstalled and you?(by) ->
        rich_gettext(
          "You took this in %{when}. Until a run starts, you can undo this. %{integration} is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment.",
          when: at,
          integration: assigns.integration
        )

      uninstalled ->
        nil

      you?(by) ->
        rich_gettext(
          "You took this in %{when}. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays.",
          when: at
        )

      true ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays.",
          name: by.name,
          when: at
        )
    end
  end

  # A run's id, as a link to its page where the page gives one.
  defp run_ref(%{path: path, id: id}) when is_binary(path), do: {:link, path, id, "q-wi-run"}
  defp run_ref(%{id: id}), do: {:m, id, "q-wi-run-id"}

  attr :class, :any, default: "q-bl-bee q-bl-bee-lg"

  # Qory's bee, beside Qory's words: decorative, the words name Qory.
  defp bee(assigns) do
    ~H"""
    <span class={@class} aria-hidden="true"></span>
    """
  end

  ## The notices under the header

  @doc """
  The notice that the integration's installation ended (`at`) and what that leaves: the
  work item stays, Qory changes nothing on the ticket, and the ticket is no longer in the
  Backlog.
  """
  attr :id, :string, default: "work-item-uninstalled"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :at, :any, required: true, doc: "when the integration reported the installation gone"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def uninstalled_notice(assigns) do
    assigns =
      assign(
        assigns,
        :line,
        rich_gettext(
          "The %{integration} installation ended on %{date}, when %{integration} reported it gone.",
          integration: assigns.integration,
          date: day(assigns.at, now(assigns))
        )
      )

    ~H"""
    <div id={@id} class="q-wi-note" role="status">
      <.icon name="hero-signal-slash" class="q-wi-note-i size-4" />
      <div class="q-wi-grow">
        <p><.rich text={@line} /></p>
        <p>
          {gettext(
            "This work item stays in Qory Apiary. Qory no longer changes anything on the ticket, and the ticket is no longer in the Backlog."
          )}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The question before Close, in place under the header: what closing does to the ticket,
  or, after the integration's uninstall (`uninstalled`), that nothing changes there; Close
  work item (`"close"`) and Cancel.
  """
  attr :id, :string, default: "work-item-close"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"
  attr :cancel, :any, default: nil, doc: "what Cancel does"

  def close_question(assigns) do
    assigns = assign(assigns, :cancel, assigns.cancel || JS.push("cancel_question"))

    ~H"""
    <div class="q-wi-note q-wi-note-ask">
      <.icon name="hero-exclamation-triangle-micro" class="q-wi-note-i size-4" />
      <.inline_confirm
        id={@id}
        class="q-wi-ask q-wi-grow"
        question={gettext("Close work item #%{number}?", number: @number)}
        cancel={@cancel}
      >
        <%= if @uninstalled do %>
          {gettext(
            "Closing ends the work on it in Qory Apiary. %{integration} is no longer connected, so nothing changes on the ticket.",
            integration: @integration
          )}
        <% else %>
          {gettext(
            "Closing ends the work on it in Qory Apiary. The ticket stays open on %{integration} and keeps Qory's label, and nothing new is posted there. In the Backlog, Take in again brings this work item back.",
            integration: @integration
          )}
        <% end %>
        <:action>
          <.button
            id={"#{@id}-go"}
            type="button"
            variant="danger"
            size="xs"
            phx-click="close"
            phx-value-number={@number}
          >
            {gettext("Close work item")}
          </.button>
        </:action>
      </.inline_confirm>
    </div>
    """
  end

  @doc """
  The notice of an ended work item: who closed, declined or undid it and when, what that
  left on the ticket, and Take in again, a link to the ticket's panel in the Backlog
  (`again_path`). After the integration's uninstall (`uninstalled`) the ticket is in no
  Backlog: the first line alone. Nothing for a live work item.
  """
  attr :id, :string, default: "work-item-ended"
  attr :work_item, :map, required: true, doc: "the work item: `:status`, `:ended_by`, `:ended_at`"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"
  attr :again_path, :string, default: nil, doc: "the ticket's panel in the Backlog"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def end_notice(%{work_item: %{status: status}} = assigns) when status not in @ended,
    do: ~H""

  def end_notice(assigns) do
    work_item = assigns.work_item
    now = now(assigns)

    assigns =
      assign(assigns,
        status: work_item.status,
        first: end_line(work_item, now),
        second: !assigns.uninstalled && end_second(work_item.status, assigns.integration)
      )

    ~H"""
    <div :if={@first || @second} id={@id} class="q-wi-note">
      <.icon name={end_icon(@status)} class="q-wi-note-i size-4" />
      <div class="q-wi-grow">
        <p :if={@first} id={"#{@id}-line"}><.rich text={@first} /></p>
        <p :if={@second}>{@second}</p>
      </div>
      <.button
        :if={@second && @again_path}
        id={"#{@id}-again"}
        size="xs"
        class="q-wi-again"
        navigate={@again_path}
      >
        {gettext("Take in again")}
      </.button>
    </div>
    """
  end

  defp end_line(%{status: :closed} = work_item, now),
    do:
      rich_gettext("%{name} closed this work item on %{date}.",
        name: work_item.ended_by.name,
        date: day(work_item.ended_at, now)
      )

  defp end_line(%{status: :declined} = work_item, now),
    do:
      rich_gettext("%{name} declined this work item %{when}, at Confirm.",
        name: work_item.ended_by.name,
        when: inline_ago(work_item.ended_at, now)
      )

  # The words are the reader's: someone else's undo has none.
  defp end_line(%{status: :undone} = work_item, now) do
    if you?(work_item.ended_by),
      do:
        rich_gettext("You undid this %{when}, before a run started.",
          when: inline_ago(work_item.ended_at, now)
        )
  end

  defp end_second(:undone, _integration),
    do:
      gettext(
        "Qory took its label off the ticket, and its comment stays there. In the Backlog, Take in again brings this work item back."
      )

  defp end_second(_closed_or_declined, integration),
    do:
      gettext(
        "The ticket is still open on %{integration} and keeps Qory's label. In the Backlog, Take in again brings this work item back.",
        integration: integration
      )

  ## Details

  @doc """
  A work item's facts: who owns it, its ticket (a link out, where the integration sent it
  from, who filed it and when), its repository, when and by whom it was taken in, its
  first instruction, its runs, and how it ended. From 1440 px a quiet list beside the page
  under its heading; below it, folded behind a button that says who owns it and the
  ticket's ref, which opens it in place.

  It reads the work item's `:owner`, `:external_ref`, `:url`, `:repository`,
  `:taken_in_by`, `:taken_in_at`, `:first_instruction` (`nil` for none), `:runs` (`nil`
  for none, or `%{latest: %{id:, path:}, count:, running:}`), `:ended_by` and `:ended_at`,
  and its ticket's filer and when it was filed (`ticket`, `%{filer: %{name:}, filed_at:}`).
  """
  attr :id, :string, default: "work-item-details"
  attr :work_item, :map, required: true, doc: "the work item"
  attr :ticket, :map, required: true, doc: "its ticket: `:filer` and `:filed_at`"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def work_item_details(assigns) do
    work_item = assigns.work_item
    now = now(assigns)
    owner = work_item.owner

    assigns =
      assign(assigns,
        now: now,
        owner: owner,
        href: if(out?(work_item[:url]), do: work_item.url),
        summary:
          gettext("%{owner} · %{ref}", owner: owner_phrase(owner), ref: work_item.external_ref),
        ticket_line: ticket_line(assigns, now),
        taken_in: by_line(work_item.taken_in_at, work_item.taken_in_by, now),
        ended:
          ended?(work_item) &&
            {end_word(work_item.status), by_line(work_item.ended_at, work_item.ended_by, now)},
        runs: work_item[:runs]
      )

    ~H"""
    <button
      id={"#{@id}-toggle"}
      type="button"
      class="q-wi-dtoggle"
      aria-expanded="false"
      aria-controls={@id}
      phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
    >
      <span class="q-wi-dtoggle-t">{gettext("Details")}</span>
      <span class="q-wi-dtoggle-s">{@summary}</span>
      <.icon name="hero-chevron-down-micro" class="q-wi-dtoggle-i size-4" />
    </button>
    <section id={@id} class="q-wi-det" aria-labelledby={"#{@id}-h"}>
      <h2 id={"#{@id}-h"} class="q-wi-det-h">{gettext("Details")}</h2>
      <dl class="q-rail-kv">
        <dt>{pgettext("work item", "Owner")}</dt>
        <dd id={"#{@id}-owner"} class="q-wi-l1">
          <.avatar name={@owner.name} size="xs" />
          <span>{@owner.name}</span>
          <span :if={you?(@owner)} class="q-faint">{gettext("(you)")}</span>
        </dd>
        <dt>{gettext("Ticket")}</dt>
        <dd id={"#{@id}-ticket"}>
          <span class="q-wi-l1">
            <BacklogComponents.integration_tile name={@integration} />
            <.external_link href={@href} class="q-wi-tkr">{@work_item.external_ref}</.external_link>
          </span>
          <span class="q-wi-sub"><.rich text={@ticket_line} /></span>
        </dd>
        <dt>{pgettext("work item", "Repository")}</dt>
        <dd id={"#{@id}-repository"} class="q-mono">{@work_item.repository}</dd>
        <dt>{gettext("Taken in")}</dt>
        <dd id={"#{@id}-taken-in"}><.rich text={@taken_in} /></dd>
        <dt>{gettext("First instruction")}</dt>
        <dd id={"#{@id}-instruction"}>
          <span :if={@work_item.first_instruction} class="q-wi-q">
            {@work_item.first_instruction}
          </span>
          <span :if={!@work_item.first_instruction} class="q-faint">{gettext("None")}</span>
        </dd>
        <dt>{gettext("Runs")}</dt>
        <dd id={"#{@id}-runs"}>
          <span :if={@runs} class="q-wi-runs"><.rich text={runs_line(@runs)} /></span>
          <span :if={!@runs} class="q-faint">{gettext("None yet")}</span>
        </dd>
        <%= if @ended do %>
          <dt>{elem(@ended, 0)}</dt>
          <dd id={"#{@id}-ended"}><.rich text={elem(@ended, 1)} /></dd>
        <% end %>
      </dl>
    </section>
    """
  end

  defp ticket_line(%{ticket: ticket, integration: integration, uninstalled: uninstalled}, now) do
    filed = inline_ago(ticket.filed_at, now)

    if uninstalled,
      do:
        rich_gettext(
          "On %{integration}, no longer connected · %{name} filed it %{when}",
          integration: integration,
          name: ticket.filer.name,
          when: filed
        ),
      else:
        rich_gettext("On %{integration} · %{name} filed it %{when}",
          integration: integration,
          name: ticket.filer.name,
          when: filed
        )
  end

  defp by_line(at, by, now) do
    if you?(by),
      do: rich_gettext("%{date}, by you", date: day(at, now)),
      else: rich_gettext("%{date}, by %{name}", date: day(at, now), name: by.name)
  end

  defp runs_line(%{latest: latest, count: count, running: running}) do
    state =
      if running > 0,
        do: gettext("%{count} running", count: running),
        else: gettext("ended")

    rich_ngettext("%{run} · %{count} run, %{state}", "%{run} · %{count} runs, %{state}", count,
      run: run_ref(latest),
      state: state
    )
  end

  ## The tabs

  @doc """
  A work item's tabs: Ticket (`ticket_path`) and Thread (`thread_path`), with the count of
  people's comments where there are any; named "Work item #%{number}".
  """
  attr :id, :string, default: "work-item-tabs"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :current, :atom, required: true, values: [:ticket, :thread], doc: "the page's tab"
  attr :ticket_path, :string, required: true, doc: "the Ticket tab, `/work/:number`"
  attr :thread_path, :string, required: true, doc: "the Thread, `/work/:number/thread`"
  attr :comment_count, :integer, default: 0, doc: "people's comments in the Thread"

  def work_item_tabs(assigns) do
    ~H"""
    <.page_tabs
      id={@id}
      label={gettext("Work item #%{number}", number: @number)}
      current={@current}
    >
      <:tab key={:ticket} patch={@ticket_path} icon="hero-document-text">{gettext("Ticket")}</:tab>
      <:tab
        key={:thread}
        patch={@thread_path}
        icon="hero-chat-bubble-left-right"
        count={@comment_count > 0 && @comment_count}
      >
        {gettext("Thread")}
      </:tab>
    </.page_tabs>
    """
  end

  ## The Ticket tab

  @doc """
  The Ticket tab: the ticket as the integration sent it, kept current. Its ref with the
  integration's mark, who filed it and when, when it was last updated, Open on the
  integration, its labels, its text (`SourceComponents.body/1`, with Show as written), and
  its latest comments under how many it has, with Show earlier comments
  (`"show_earlier_comments"`) where it has more than are given.

  After the integration's uninstall (`uninstalled`) a line above it says when the
  integration last sent it (`ticket.received_at`), and that it is no longer kept current.

  `ticket` is a map with `:filer` (`%{name:}`), `:filed_at`, `:updated_at`, `:labels` (a
  list of strings), `:body` and `:format` (as `SourceComponents.body/1` takes them),
  `:comment_count` (how many comments it has) and, after an uninstall, `:received_at`.
  `comments` are its latest comments, oldest first, each with `:public_id`, `:author` (a
  name), `:at`, `:body` and `:format`.
  """
  attr :id, :string, default: "work-item-ticket"
  attr :work_item, :map, required: true, doc: "the work item: `:external_ref` and `:url`"
  attr :ticket, :map, required: true, doc: "the ticket, as above"
  attr :comments, :list, default: [], doc: "its latest comments, as above"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def ticket_tab(assigns) do
    ticket = assigns.ticket
    now = now(assigns)
    count = ticket.comment_count

    assigns =
      assign(assigns,
        now: now,
        count: count,
        earlier: max(count - length(assigns.comments), 0),
        href: if(out?(assigns.work_item[:url]), do: assigns.work_item.url),
        # The Backlog's line; the space before its "·" does not break, so a wrapped line
        # never starts with it.
        meta:
          gettext("%{name} filed this %{filed_ago} · updated %{updated_ago}",
            name: ticket.filer.name,
            filed_ago: Format.time_ago(ticket.filed_at, now, case: :inline),
            updated_ago: Format.time_ago(ticket.updated_at, now, case: :inline)
          )
          |> String.replace(" · ", " · "),
        stale:
          assigns.uninstalled &&
            rich_gettext(
              "The ticket as %{integration} last sent it, %{when}. It is no longer kept current.",
              integration: assigns.integration,
              when: inline_ago(ticket[:received_at] || ticket.updated_at, now)
            )
      )

    ~H"""
    <div id={@id} class="q-wi-tkt">
      <p :if={@stale} id={"#{@id}-stale"} class="q-wi-stale">
        <.icon name="hero-signal-slash-micro" class="size-3.5" /><span><.rich text={@stale} /></span>
      </p>
      <div class="q-wi-tkt-meta">
        <span class="q-wi-key">
          <BacklogComponents.integration_tile name={@integration} />{@work_item.external_ref}
        </span>
        <span class="q-wi-tkt-filed">{@meta}</span>
        <span class="q-wi-grow"></span>
        <.external_link :if={@href} id={"#{@id}-out"} href={@href} class="q-wi-out">
          {gettext("Open on %{integration}", integration: @integration)}
        </.external_link>
      </div>
      <dl :if={@ticket.labels != []} class="q-wi-facts">
        <dt>{pgettext("ticket", "Labels")}</dt>
        <dd>{Enum.join(@ticket.labels, ", ")}</dd>
      </dl>
      <div class="q-wi-text">
        <SourceComponents.body id={"#{@id}-text"} body={@ticket.body} format={@ticket.format} />
      </div>
      <section
        :if={@count > 0}
        id={"#{@id}-comments"}
        class="q-wi-tcm"
        aria-labelledby={"#{@id}-comments-h"}
      >
        <h3 id={"#{@id}-comments-h"}>
          {gettext("%{count} comments on the ticket", count: Format.number(@count))}
        </h3>
        <.button
          :if={@earlier > 0}
          id={"#{@id}-earlier"}
          type="button"
          variant="link"
          class="q-wi-earlier"
          phx-click="show_earlier_comments"
        >
          {gettext("Show %{count} earlier comments", count: Format.number(@earlier))}
        </.button>
        <div
          :for={comment <- @comments}
          id={"#{@id}-comment-#{comment.public_id}"}
          class="q-wi-cmt"
        >
          <div class="q-wi-who">
            <.avatar name={comment.author} size="xs" />
            <b>{comment.author}</b>
            <span class="q-faint">{time_tag(comment.at, Format.time_ago(comment.at, @now))}</span>
          </div>
          <div class="q-wi-cmt-txt">
            <SourceComponents.body
              id={"#{@id}-comment-#{comment.public_id}-text"}
              body={comment.body}
              format={comment.format}
            />
          </div>
        </div>
      </section>
    </div>
    """
  end

  ## The Thread

  @doc """
  The Thread: what happened to the work item in Qory Apiary and people's comments, oldest
  first, as `thread_event/1`s and `thread_comment/1`s; then the page's composer.
  """
  attr :id, :string, default: "work-item-thread"
  slot :inner_block, required: true

  def thread(assigns) do
    ~H"""
    <ol id={@id} class="q-wi-tl" aria-label={gettext("Thread")}>
      {render_slot(@inner_block)}
    </ol>
    """
  end

  @doc """
  One event of the Thread, a line with its time:

    * `:taken_in` - who took the work item in from the ticket (`external_ref`, a link out
      where `url` is given), who owns it where that is another person (`owner`), and the
      first instruction under it (`first_instruction`);
    * `:closed`, `:declined` - who closed or declined it;
    * `:undone` - who undid it, before a run started.
  """
  attr :id, :string, required: true, doc: "the DOM id: the event's `public_id` under the Thread's"
  attr :kind, :atom, required: true, values: [:taken_in, :closed, :declined, :undone]
  attr :actor, :map, required: true, doc: "who acted, a person"
  attr :at, :any, required: true, doc: "when"
  attr :external_ref, :string, default: nil, doc: "`:taken_in`: the ticket's ref"
  attr :url, :string, default: nil, doc: "`:taken_in`: the ticket's page at the source"
  attr :owner, :map, default: nil, doc: "`:taken_in`: who owns it, a person"
  attr :first_instruction, :string, default: nil, doc: "`:taken_in`: the first instruction"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def thread_event(assigns) do
    now = now(assigns)

    assigns =
      assign(assigns,
        line: event_line(assigns),
        at_words: time_tag(assigns.at, Format.relative(assigns.at, now))
      )

    ~H"""
    <li id={@id} class="q-wi-ev">
      <span class="q-wi-ev-ic" aria-hidden="true">
        <span><.icon name={event_icon(@kind)} class="size-3" /></span>
      </span>
      <div>
        <p><.rich text={@line} /> <span class="q-wi-when">{@at_words}</span></p>
        <p :if={@kind == :taken_in && @first_instruction} class="q-wi-q">
          {gettext("First instruction: %{text}", text: @first_instruction)}
        </p>
      </div>
    </li>
    """
  end

  defp event_icon(:taken_in), do: "hero-arrow-down-tray-micro"
  defp event_icon(:closed), do: "hero-x-circle-micro"
  defp event_icon(:declined), do: "hero-minus-circle-micro"
  defp event_icon(:undone), do: "hero-arrow-uturn-left-micro"

  defp event_line(%{kind: :taken_in, actor: actor, owner: owner} = assigns) do
    ref = taken_in_ref(assigns)
    name = {:b, actor.name}
    other_owner = owner && owner.name != actor.name && owner

    cond do
      !other_owner and you?(actor) ->
        rich_gettext("You took this in from %{ref}", ref: ref)

      !other_owner ->
        rich_gettext("%{name} took this in from %{ref}", name: name, ref: ref)

      you?(actor) ->
        rich_gettext("You took this in from %{ref}. %{owner} owns it",
          ref: ref,
          owner: {:b, other_owner.name}
        )

      you?(other_owner) ->
        rich_gettext("%{name} took this in from %{ref}. You own it", name: name, ref: ref)

      true ->
        rich_gettext("%{name} took this in from %{ref}. %{owner} owns it",
          name: name,
          ref: ref,
          owner: {:b, other_owner.name}
        )
    end
  end

  defp event_line(%{kind: :closed, actor: actor}),
    do: rich_gettext("%{name} closed this work item", name: {:b, actor.name})

  defp event_line(%{kind: :declined, actor: actor}),
    do: rich_gettext("%{name} declined this work item at Confirm", name: {:b, actor.name})

  defp event_line(%{kind: :undone, actor: actor}) do
    if you?(actor),
      do: gettext("You undid this, before a run started"),
      else: rich_gettext("%{name} undid this, before a run started", name: {:b, actor.name})
  end

  defp taken_in_ref(%{external_ref: ref, url: url}) do
    if out?(url), do: {:href, url, ref, "q-wi-ev-ref"}, else: {:m, ref, "q-wi-ev-ref"}
  end

  @doc """
  A person's comment in the Thread: who wrote it and when, then its text as written,
  with its line breaks kept.

  `state` is what it shows:

    * `:shown` - the comment; with `can_delete`, More (named for whose comment it is),
      whose Delete comment sends `"ask_delete_comment"`;
    * `:asking` - the comment, and under it the question: Delete comment
      (`"delete_comment"`) and Cancel (`cancel`);
    * `:deleted` - one line in its place: who deleted it (`deleted_by`) and when
      (`deleted_at`).

  `comment` is a map with `:public_id`, `:author` (a person), `:at` and `:body`.
  """
  attr :id, :string, required: true, doc: "the DOM id, with the comment's `public_id`"
  attr :comment, :map, required: true, doc: "the comment, as above"
  attr :state, :atom, default: :shown, values: [:shown, :asking, :deleted]
  attr :can_delete, :boolean, default: false, doc: "whether the reader may delete it"
  attr :deleted_by, :map, default: nil, doc: "`:deleted`: who deleted it, a person"
  attr :deleted_at, :any, default: nil, doc: "`:deleted`: when"
  attr :cancel, :any, default: nil, doc: "what the question's Cancel does"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def thread_comment(%{state: :deleted} = assigns) do
    by = assigns.deleted_by

    assigns =
      assign(assigns,
        line:
          if(you?(by),
            do: gettext("Comment deleted by you"),
            else: rich_gettext("Comment deleted by %{name}", name: {:b, by.name})
          ),
        at_words: time_tag(assigns.deleted_at, Format.relative(assigns.deleted_at, now(assigns)))
      )

    ~H"""
    <li id={@id} class="q-wi-ev q-wi-ev-deleted">
      <span class="q-wi-ev-ic" aria-hidden="true">
        <span><.icon name="hero-trash-micro" class="size-3" /></span>
      </span>
      <div>
        <p><.rich text={@line} /> <span class="q-wi-when">{@at_words}</span></p>
      </div>
    </li>
    """
  end

  def thread_comment(assigns) do
    comment = assigns.comment
    author = comment.author
    mine = you?(author)

    assigns =
      assign(assigns,
        author: author,
        public_id: comment.public_id,
        at_words: time_tag(comment.at, Format.relative(comment.at, now(assigns))),
        more_label:
          if(mine,
            do: gettext("More for your comment"),
            else: gettext("More for %{name}'s comment", name: author.name)
          ),
        question:
          if(mine,
            do: gettext("Delete your comment?"),
            else: gettext("Delete %{name}'s comment?", name: author.name)
          ),
        cancel: assigns.cancel || JS.push("cancel_question")
      )

    ~H"""
    <li id={@id} class="q-wi-cm">
      <.avatar name={@author.name} size="sm" />
      <div class="q-wi-box">
        <div class="q-wi-box-h">
          <b>{@author.name}</b>
          <span class="q-faint">{@at_words}</span>
          <.row_menu
            :if={@can_delete && @state == :shown}
            id={"#{@id}-more"}
            class="q-wi-cm-more"
            label={@more_label}
            title={gettext("More")}
          >
            <.menu_item
              id={"#{@id}-delete"}
              phx-click="ask_delete_comment"
              phx-value-comment={@public_id}
            >
              {gettext("Delete comment")}
            </.menu_item>
          </.row_menu>
        </div>
        <div id={"#{@id}-body"} class="q-wi-box-b" phx-no-format>{@comment.body}</div>
        <.inline_confirm
          :if={@state == :asking}
          id={"#{@id}-confirm"}
          class="q-wi-ask"
          question={@question}
          cancel={@cancel}
        >
          {gettext("It leaves the Thread for everyone. The Thread keeps a line that you deleted it.")}
          <:action>
            <.button
              id={"#{@id}-confirm-go"}
              type="button"
              variant="danger"
              size="xs"
              phx-click="delete_comment"
              phx-value-comment={@public_id}
            >
              {gettext("Delete comment")}
            </.button>
          </:action>
        </.inline_confirm>
      </div>
    </li>
    """
  end

  @doc """
  The Thread's composer: a comment on the work item, which members of the workspace see
  and which is not posted on the ticket. It sends `"comment"`, its text as `body`; `value`
  is a draft to keep.
  """
  attr :id, :string, default: "work-item-composer"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :workspace, :string, required: true, doc: "the workspace's name"
  attr :reader, :string, required: true, doc: "the reader's name, for the avatar"
  attr :value, :string, default: nil, doc: "a draft"

  def composer(assigns) do
    assigns =
      assign(assigns, :label, gettext("Comment on work item #%{number}", number: assigns.number))

    ~H"""
    <form id={@id} class="q-wi-composer" phx-submit="comment" novalidate>
      <.avatar name={@reader} kind="self" size="sm" />
      <div class="q-wi-box">
        <label for={"#{@id}-body"} class="sr-only">{@label}</label>
        <textarea id={"#{@id}-body"} name="body" placeholder={@label} rows="3">{@value}</textarea>
        <div class="q-wi-composer-foot">
          <span class="q-wi-grow">
            {gettext("Members of %{workspace} see this. Nothing is posted on the ticket.",
              workspace: @workspace
            )}
          </span>
          <.button id={"#{@id}-go"} type="submit" variant="primary" size="xs">
            {gettext("Comment")}
          </.button>
        </div>
      </div>
    </form>
    """
  end
end
