defmodule ApiaryWeb.WorkItemComponents do
  # The parts of a work item's page (`/:org/:workspace/work/:number`, its Ticket tab,
  # `…/explore`, its Explore tab, `…/explore/edit`, the page that changes Qory's proposal,
  # and `…/thread`, its Thread), and the status words and marks the Work items list shares
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
  #   * `:status` - at Explore `:queued`, `:running`, `:questions` (Qory asked), `:used_up`
  #     (the take in used its runs), `:no_result`, `:lost` or `:cancelled` (its run gave
  #     nothing to show); then `:confirm`, `:shape`, `:declined`, `:closed` or `:undone`;
  #   * `:run` - at Explore and after, its latest run: `:attempt` and `:of` (run 2 of 3),
  #     and once it has one, `:id` (its `rn_` id), `:path`, `:state`, `:outcome`
  #     (`:proposal`, `:questions`, `:error`, `:none` or `:refused`) and what it gave;
  #   * `:stage` - for an ended work item, the stage it ended at (`:explore`, `:confirm`
  #     or `:shape`); a live one's stage follows from its status;
  #   * `:owner` - a person, or `nil`;
  #   * `:ended_by`, `:ended_at` - who declined, closed or undid it, and when;
  #   * `:updated_at` - when it last changed.
  #
  # The page's parts read more of it, each named where it is used. A person is a map with
  # `:id`, Qory Apiary's id of the person, `:name` and `:you`, true when the person is the
  # reader: a text the reader is the subject of says "you" ("You own it", "Closed by you").
  # Two people are the same person by `:id`, never by name.
  #
  # Every DOM id, `phx-value-*` and path is Qory Apiary's: the work item's number, a
  # comment's `public_id`, a question's `public_id`, a run's `rn_` id, and the paths the
  # page gives. A source Qory learned from is a link only when it is an https address
  # core allows; any other is its address as text. The ticket's ref and its number
  # at the source are text only. The page gives every path (`again_path`, `ticket_path`,
  # the run's `path`); a component builds none.
  #
  # The events a component sends, for the page to handle:
  #
  #   * `"undo"`, `"confirm"`, `"ask_decline"`, `"decline"`, `"ask_close"`, `"close"`,
  #     `"explore_again"` - with `phx-value-number`, the work item's number;
  #   * `"answer"` - the questions form: `number`, and `answers`, a map of each question's
  #     `public_id` to its answer;
  #   * `"change_proposal"`, `"confirm_changes"` - the edit page's form, on change and on
  #     submit: `number`, `complexity` (`level`, `reason`), `understanding`, `scope_in`,
  #     `scope_out` (one entry for each line) and `approach`;
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
  alias ApiaryWeb.RunComponents
  alias ApiaryWeb.SourceComponents

  @stages [:explore, :confirm, :shape]
  @ended [:declined, :closed, :undone]
  @exploring [:queued, :running, :questions, :used_up, :no_result, :lost, :cancelled]
  @no_result [:no_result, :lost, :cancelled]
  @declinable [:confirm, :questions, :used_up, :no_result, :lost, :cancelled]
  @edit_fields [:level, :reason, :understanding, :scope_in, :scope_out, :approach]

  ## The status and its mark

  @doc """
  A work item's status: its mark and its words, the row's and the meta line's. Waits for
  you to confirm is the one strong status (`q-wi-hot`). Questions and a take in that used
  its runs wait for any member who may act: their mark is the reader's with `can_act`,
  another member's without.
  """
  attr :work_item, :map,
    required: true,
    doc: "the work item: `:status`, `:owner`, `:ended_by`, and `:run` (`:of`) at the run limit"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer, confirm or decline"

  attr :class, :any, default: nil

  def work_item_status(assigns) do
    assigns =
      assign(assigns, words: status_words(assigns.work_item), hot: hot?(assigns.work_item))

    ~H"""
    <span class={["q-wi-st", @hot && "q-wi-hot", @class]}>
      <.work_item_mark kind={mark(@work_item, @can_act)} />{@words}
    </span>
    """
  end

  @doc """
  A status's mark, the one colour of a row: `:todo` (Explore is queued), `:run` (Qory is
  exploring), `:wait` (waits for the reader), `:wait_other` (waits for another member),
  `:err` (Explore's run gave no result: a red ring), `:ready` (Ready for Shape),
  `:declined` and `:closed` (closed or undone). Decorative: its words are always beside
  it.
  """
  attr :kind, :atom,
    required: true,
    values: [:todo, :run, :wait, :wait_other, :err, :ready, :declined, :closed]

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

  def status_words(%{status: :questions}), do: gettext("Waits for answers")

  def status_words(%{status: :used_up, run: %{of: of}}),
    do:
      ngettext("Explore used its %{of} run", "Explore used its %{of} runs", of,
        of: Format.number(of)
      )

  def status_words(%{status: :no_result}), do: gettext("Explore ended without a result")
  def status_words(%{status: :lost}), do: gettext("Explore's run was lost")
  def status_words(%{status: :cancelled}), do: gettext("Explore's run was cancelled")
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
  def mark(work_item, can_act \\ false)
  def mark(%{status: :queued}, _can_act), do: :todo
  def mark(%{status: :running}, _can_act), do: :run

  def mark(%{status: :confirm, owner: owner}, _can_act),
    do: if(you?(owner), do: :wait, else: :wait_other)

  def mark(%{status: status}, can_act) when status in [:questions, :used_up],
    do: if(can_act, do: :wait, else: :wait_other)

  def mark(%{status: status}, _can_act) when status in [:no_result, :lost, :cancelled], do: :err
  def mark(%{status: :shape}, _can_act), do: :ready
  def mark(%{status: :declined}, _can_act), do: :declined
  def mark(%{status: status}, _can_act) when status in [:closed, :undone], do: :closed

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

  defp stage_of(%{status: status}) when status in @exploring, do: :explore
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
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :link, :string, required: true, doc: "the work item's address, for Copy link"
  attr :can_close, :boolean, default: false, doc: "whether the reader may close it"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer, confirm or decline"

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
            <.work_item_status work_item={@work_item} can_act={@can_act} />
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
  done, its stage the current step (`aria-current="step"`), amber while it waits for a
  member: at Confirm, for answers, or at the run limit. An ended work item has no current step: a declined one's stage is marked with
  a cross, and the end mark beside the stages says how it ended: Closed, Declined or
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
        wait: work_item.status in [:confirm, :questions, :used_up],
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
          aria-current={stage.state == :now && "step"}
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

    * Explore, queued, the first run of a take in: what Qory does when the run starts,
      with Qory's bee; who took it in and when (the work item's `:taken_in_by` and
      `:taken_in_at`). With `can_undo`, that the reader can undo this until a run starts,
      Undo (`"undo"`), and what undoing does: a first take in's, or an undone work item's
      taken in again, takes Qory's label off the ticket; a declined or closed one's taken
      in again (`previous`) goes back to declined or closed, and nothing is sent to the
      ticket. After the integration's uninstall (`uninstalled`), that nothing changes on
      the ticket, which keeps Qory's label and comment.
    * Explore, queued, a later run (`:run`, `%{attempt:, of:, answers_by:}`): what Qory
      reads, with whose answers, and which run of the take in is queued. No Undo.
    * Explore, running: what Qory does, and with whose answers from a second run (`:run`,
      `%{id:, path:, started_at:, answers_by:}`), and when the run started; the run's id
      links its page where `path` is given.
    * Explore, questions (`:questions`): how many questions Qory asked; with `can_act`,
      that answering them explores again, Answer the questions (a link to Explore's tab,
      `explore_path`, where it is given) and Decline (`"ask_decline"`); without, that it
      waits for a member to answer.
    * Explore, no result (`:no_result`, `:lost`, `:cancelled`): what happened to the run;
      with `can_act`, Run Explore again (`"explore_again"`), which starts the next run of
      the take in, and Decline.
    * Explore, the run limit (`:used_up`): that the take in used its runs, and why Qory
      cannot explore again; with `can_act`, the two ways on, Decline and, with
      `can_close`, Close work item… (`"ask_close"`).
    * Confirm: Qory's proposal waits; Read Qory's proposal (`explore_path`), Confirm
      (`"confirm"`), Change (the edit page, `edit_path`) and Decline (`"ask_decline"`).
      Without `can_act`, whose turn it is: the work item's `:owner`, by name, or "you"
      where the owner is the reader.
    * Shape: who confirmed Qory's proposal and when (`:confirmed_by`, `:confirmed_at`).

  With `asking: :decline`, the Decline question takes the place of the card's words and
  buttons, wherever Decline is offered: its line, Decline (`"decline"`) and Cancel.

  `:run` is the latest run of the take in: `:attempt` (its place, from 1) and `:of` (the
  most a take in has), `:id` and `:path`, `:started_at`, `:answers_by` (the members whose
  answers it reads, people), `:questions` (what it asked, a list) and `:outcome` (`:error`,
  `:none` or `:refused` for a run without a result; `:questions` for one that asked).

  Undo is there only with `can_undo`; Confirm, Change, Decline, Run Explore again and the
  Decline question only with `can_act`.
  """
  attr :id, :string, default: "work-item-step"
  attr :work_item, :map, required: true, doc: "the work item"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"
  attr :can_undo, :boolean, default: false, doc: "whether the reader may undo the take in"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer, confirm or decline, or run Explore again"

  attr :can_close, :boolean, default: false, doc: "whether the reader may close it"

  attr :previous, :atom,
    default: nil,
    values: [nil, :declined, :closed, :undone],
    doc: "how the work item ended before it was taken in again; nil for a first take in"

  attr :explore_path, :string,
    default: nil,
    doc: "Explore's tab, linked from the Ticket and Thread tabs; nil on Explore's tab"

  attr :edit_path, :string, default: nil, doc: "the edit page, `/work/:number/explore/edit`"
  attr :asking, :atom, default: nil, values: [nil, :decline], doc: "the question showing"
  attr :cancel, :any, default: nil, doc: "what the question's Cancel does"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def step_card(%{work_item: %{status: status}} = assigns) when status in @ended, do: ~H""

  def step_card(assigns) do
    work_item = assigns.work_item
    status = work_item.status

    assigns =
      assign(assigns,
        now: now(assigns),
        number: work_item.number,
        status: status,
        stage: stage_of(work_item),
        mark: mark(work_item, assigns.can_act),
        mine: hot?(work_item),
        ask: hot?(work_item) or (status in [:questions, :used_up] and assigns.can_act),
        run: work_item[:run],
        cancel: assigns.cancel || JS.push("cancel_question")
      )

    ~H"""
    <section
      id={@id}
      class={["q-wi-step", @ask && "q-wi-step-ask"]}
      aria-labelledby={"#{@id}-h"}
    >
      <div class="q-wi-step-h">
        <.work_item_mark kind={@mark} />
        <h2 id={"#{@id}-h"}>{stage_name(@stage)}</h2>
        <.step_badge status={@status} mine={@mine} run={@run} />
      </div>
      <.step_body
        id={@id}
        work_item={@work_item}
        run={@run}
        status={@status}
        number={@number}
        integration={@integration}
        uninstalled={@uninstalled}
        can_undo={@can_undo}
        can_act={@can_act}
        can_close={@can_close}
        previous={@previous}
        explore_path={@explore_path}
        edit_path={@edit_path}
        asking={@asking}
        cancel={@cancel}
        now={@now}
      />
    </section>
    """
  end

  attr :status, :atom, required: true
  attr :mine, :boolean, required: true
  attr :run, :map, default: nil

  defp step_badge(%{status: :queued} = assigns),
    do: ~H|<.badge class="q-wi-badge">{gettext("Queued")}</.badge>|

  defp step_badge(%{status: :running} = assigns),
    do: ~H|<.badge color="success" class="q-wi-badge">{gettext("Running")}</.badge>|

  defp step_badge(%{status: :questions} = assigns),
    do: ~H|<.badge color="warning" class="q-wi-badge">{gettext("Waits for answers")}</.badge>|

  defp step_badge(%{status: :used_up} = assigns) do
    ~H"""
    <.badge color="warning" class="q-wi-badge">
      {ngettext("%{attempt} of %{of} run used", "%{attempt} of %{of} runs used", @run.of,
        attempt: Format.number(@run.attempt),
        of: Format.number(@run.of)
      )}
    </.badge>
    """
  end

  defp step_badge(%{status: :no_result} = assigns),
    do: ~H|<.badge color="error" class="q-wi-badge">{gettext("No result")}</.badge>|

  defp step_badge(%{status: :lost} = assigns),
    do: ~H|<.badge color="error" class="q-wi-badge">{gettext("Lost")}</.badge>|

  defp step_badge(%{status: :cancelled} = assigns),
    do: ~H|<.badge color="error" class="q-wi-badge">{gettext("Cancelled")}</.badge>|

  defp step_badge(%{status: :confirm, mine: true} = assigns),
    do: ~H|<.badge color="warning" class="q-wi-badge">{gettext("Waits for you")}</.badge>|

  defp step_badge(%{status: :shape} = assigns),
    do: ~H|<.badge color="info" class="q-wi-badge">{gettext("Ready")}</.badge>|

  defp step_badge(assigns), do: ~H""

  attr :id, :string, required: true
  attr :work_item, :map, required: true
  attr :run, :map, required: true
  attr :status, :atom, required: true
  attr :number, :integer, required: true
  attr :integration, :string, required: true
  attr :uninstalled, :boolean, required: true
  attr :can_undo, :boolean, required: true
  attr :can_act, :boolean, required: true
  attr :can_close, :boolean, required: true
  attr :previous, :atom, required: true
  attr :explore_path, :string, required: true
  attr :edit_path, :string, required: true
  attr :asking, :atom, required: true
  attr :cancel, :any, required: true
  attr :now, :any, required: true

  defp step_body(%{status: status, asking: :decline, can_act: true} = assigns)
       when status in @declinable do
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

  # A later run of the take in: what it reads, with whose answers, and which run is
  # queued. Undo is only until the first run of a take in starts.
  defp step_body(%{status: :queued, run: %{attempt: attempt}} = assigns) when attempt > 1 do
    run = assigns.run

    assigns =
      assign(assigns,
        line:
          case answers_of(run[:answers_by]) do
            :none ->
              gettext(
                "Qory reads the ticket and the code when the run starts, and proposes how to build it."
              )

            :you ->
              gettext(
                "Qory reads the ticket, the code and your answers when the run starts, and proposes how to build it."
              )

            {:name, name} ->
              gettext(
                "Qory reads the ticket, the code and %{name}'s answers when the run starts, and proposes how to build it.",
                name: name
              )

            :several ->
              gettext(
                "Qory reads the ticket, the code and the answers of this take in when the run starts, and proposes how to build it."
              )
          end,
        queued:
          gettext("Run %{attempt} of %{of} is queued.",
            attempt: Format.number(run.attempt),
            of: Format.number(run.of)
          )
      )

    ~H"""
    <p class="q-wi-bee-line"><.bee /><span>{@line}</span></p>
    <p id={"#{@id}-run"}>{@queued}</p>
    """
  end

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
    <div id={"#{@id}-undo"} class="q-wi-undo">
      <p id={"#{@id}-undo-line"}><.rich text={@undo_line} /></p>
      <div :if={@can_undo} class="q-wi-acts">
        <.button type="button" phx-click="undo" phx-value-number={@number}>
          <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" />{gettext("Undo")}
        </.button>
      </div>
    </div>
    """
  end

  defp step_body(%{status: :running} = assigns) do
    run = assigns.run

    assigns =
      assign(assigns,
        line:
          case answers_of(run[:answers_by]) do
            :none ->
              gettext(
                "Qory is exploring. It reads the ticket and the code, and proposes how to build it."
              )

            :you ->
              gettext(
                "Qory is exploring again, with your answers. It reads the ticket and the code, and proposes how to build it."
              )

            {:name, name} ->
              gettext(
                "Qory is exploring again, with %{name}'s answers. It reads the ticket and the code, and proposes how to build it.",
                name: name
              )

            :several ->
              gettext(
                "Qory is exploring again, with the answers of this take in. It reads the ticket and the code, and proposes how to build it."
              )
          end,
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

  defp step_body(%{status: :questions} = assigns) do
    n = length(assigns.run.questions)
    number = Format.number(n)

    assigns =
      assign(assigns,
        line:
          if(assigns.can_act,
            do:
              ngettext(
                "Qory asked %{number} question before it can propose how to build it. Answer it, and Qory explores again with your answer. Or decline the work item.",
                "Qory asked %{number} questions before it can propose how to build it. Answer them, and Qory explores again with your answers. Or decline the work item.",
                n,
                number: number
              ),
            else:
              ngettext(
                "Qory asked %{number} question before it can propose how to build it.",
                "Qory asked %{number} questions before it can propose how to build it.",
                n,
                number: number
              )
          ),
        waits:
          ngettext(
            "Waits for a member to answer Qory's question.",
            "Waits for a member to answer Qory's questions.",
            n
          ),
        go: ngettext("Answer the question", "Answer the questions", n)
      )

    ~H"""
    <p class="q-wi-bee-line"><.bee /><span>{@line}</span></p>
    <p :if={!@can_act} id={"#{@id}-waits"} class="q-wi-reader">{@waits}</p>
    <.go_link :if={@can_act} id={"#{@id}-explore"} path={@explore_path} words={@go} />
    <div :if={@can_act} class="q-wi-acts">
      <.decline_button id={@id} number={@number} />
    </div>
    """
  end

  defp step_body(%{status: :used_up} = assigns) do
    run = assigns.run

    assigns =
      assign(assigns,
        line:
          if(run[:outcome] == :questions,
            do:
              ngettext(
                "Qory still has %{number} question after run %{attempt} of %{of}, the most one take in has, so it cannot explore again in this take in.",
                "Qory still has %{number} questions after run %{attempt} of %{of}, the most one take in has, so it cannot explore again in this take in.",
                length(run.questions),
                number: Format.number(length(run.questions)),
                attempt: Format.number(run.attempt),
                of: Format.number(run.of)
              ),
            else:
              rich_gettext(
                "Run %{run} was run %{attempt} of %{of}, the most one take in has, and it ended without a result, so Qory cannot explore again in this take in.",
                run: run_ref(run),
                attempt: Format.number(run.attempt),
                of: Format.number(run.of)
              )
          )
      )

    ~H"""
    <p id={"#{@id}-line"}><.rich text={@line} /></p>
    <p :if={@can_act} id={"#{@id}-ways"}>
      {gettext(
        "Decline the work item if it is not wanted. To explore again, close it: Take in again from the Backlog then starts a fresh count, and answers from this take in are not carried over."
      )}
    </p>
    <div :if={@can_act} class="q-wi-acts">
      <.button
        id={"#{@id}-decline"}
        type="button"
        phx-click="ask_decline"
        phx-value-number={@number}
      >
        {gettext("Decline")}
      </.button>
      <.button
        :if={@can_close}
        id={"#{@id}-close"}
        type="button"
        variant="ghost"
        phx-click="ask_close"
        phx-value-number={@number}
      >
        {gettext("Close work item…")}
      </.button>
    </div>
    """
  end

  defp step_body(%{status: status} = assigns) when status in @no_result do
    run = assigns.run

    assigns =
      assign(assigns,
        line: no_result_line(status, run),
        next:
          gettext("It starts run %{attempt} of %{of} of this take in.",
            attempt: Format.number(run.attempt + 1),
            of: Format.number(run.of)
          )
      )

    ~H"""
    <p id={"#{@id}-line"}><.rich text={@line} /></p>
    <div :if={@can_act} class="q-wi-acts">
      <.button
        id={"#{@id}-again"}
        type="button"
        variant="primary"
        phx-click="explore_again"
        phx-value-number={@number}
      >
        <.icon name="hero-arrow-path-micro" class="size-3.5" />{gettext("Run Explore again")}
      </.button>
      <.decline_button id={@id} number={@number} />
    </div>
    <p :if={@can_act} id={"#{@id}-next"} class="q-wi-hint">{@next}</p>
    """
  end

  # A reader who may act reads what to do; one who may not, whose turn it is. Without an
  # owner there is no one to name: no line.
  defp step_body(%{status: :confirm} = assigns) do
    owner = assigns.work_item[:owner]

    assigns =
      assign(assigns,
        line:
          cond do
            assigns.can_act ->
              gettext(
                "Qory proposed how to build it. Confirm it, change it first, or decline the work item."
              )

            you?(owner) ->
              gettext("Waits for you to confirm Qory's proposal or decline the work item.")

            owner ->
              gettext("Waits for %{name} to confirm Qory's proposal or decline the work item.",
                name: owner.name
              )

            true ->
              nil
          end
      )

    ~H"""
    <p :if={@line} class="q-wi-bee-line"><.bee /><span>{@line}</span></p>
    <.go_link
      :if={@can_act}
      id={"#{@id}-explore"}
      path={@explore_path}
      words={gettext("Read Qory's proposal")}
    />
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
      <.button :if={@edit_path} id={"#{@id}-change"} navigate={@edit_path}>
        <.icon name="hero-pencil-square-micro" class="size-3.5" />{pgettext("action", "Change")}
      </.button>
      <.decline_button id={@id} number={@number} />
    </div>
    """
  end

  defp step_body(%{status: :shape} = assigns) do
    work_item = assigns.work_item

    by = work_item.confirmed_by
    at = inline_ago(work_item.confirmed_at, assigns.now)

    assigns =
      assign(
        assigns,
        :line,
        if(you?(by),
          do:
            rich_gettext(
              "You confirmed Qory's proposal %{when}. Shape is the plan and its acceptance criteria.",
              when: at
            ),
          else:
            rich_gettext(
              "%{name} confirmed Qory's proposal %{when}. Shape is the plan and its acceptance criteria.",
              name: by.name,
              when: at
            )
        )
      )

    ~H"""
    <p><.rich text={@line} /></p>
    """
  end

  attr :id, :string, required: true
  attr :number, :integer, required: true

  defp decline_button(assigns) do
    ~H"""
    <.button
      id={"#{@id}-decline"}
      type="button"
      variant="ghost"
      phx-click="ask_decline"
      phx-value-number={@number}
    >
      {gettext("Decline")}
    </.button>
    """
  end

  attr :id, :string, required: true
  attr :path, :string, default: nil
  attr :words, :string, required: true

  # A link to Explore's tab from the Ticket and Thread tabs; nothing on Explore's tab.
  defp go_link(assigns) do
    ~H"""
    <.link :if={@path} id={@id} patch={@path} class="q-wi-golink">
      {@words}<.icon name="hero-arrow-right-micro" class="size-3.5" />
    </.link>
    """
  end

  # What happened to a run that gave no result, as one sentence with its id.
  defp no_result_line(:no_result, run) do
    case run[:outcome] do
      :none ->
        rich_gettext("Run %{run} ended without a result.", run: run_ref(run))

      :refused ->
        rich_gettext(
          "Run %{run} returned a result that did not pass Qory's check, so Explore has no result.",
          run: run_ref(run)
        )

      _error ->
        rich_gettext("Run %{run} ended with an error, so Explore has no result.",
          run: run_ref(run)
        )
    end
  end

  defp no_result_line(:lost, run),
    do:
      rich_gettext("Run %{run} was lost before it ended, so Explore has no result.",
        run: run_ref(run)
      )

  defp no_result_line(:cancelled, run),
    do:
      rich_gettext("Run %{run} was cancelled before it ended, so Explore has no result.",
        run: run_ref(run)
      )

  # Who took the work item in and when; for a reader who may undo it, that they can until
  # a run starts and what undoing does to the ticket. After an uninstall, that nothing
  # changes on the ticket. A declined or closed work item taken in again goes back to how
  # it ended, and nothing is sent to the ticket; an undone one taken in again reads as a
  # first take in, since undoing it takes the label off again. Each line is one whole
  # sentence for each case.
  defp undo_line(%{work_item: work_item, previous: previous, uninstalled: false} = assigns)
       when previous in [:declined, :closed] do
    by = work_item.taken_in_by
    at = inline_ago(work_item.taken_in_at, assigns.now)

    case {previous, you?(by), assigns.can_undo} do
      {:declined, true, true} ->
        rich_gettext(
          "You took this in again %{when}. Until a run starts, you can undo this: the work item goes back to declined, and nothing is sent to the ticket, so its label stays as it was.",
          when: at
        )

      {:declined, false, true} ->
        rich_gettext(
          "%{name} took this in again %{when}. Until a run starts, you can undo this: the work item goes back to declined, and nothing is sent to the ticket, so its label stays as it was.",
          name: by.name,
          when: at
        )

      {:closed, true, true} ->
        rich_gettext(
          "You took this in again %{when}. Until a run starts, you can undo this: the work item goes back to closed, and nothing is sent to the ticket, so its label stays as it was.",
          when: at
        )

      {:closed, false, true} ->
        rich_gettext(
          "%{name} took this in again %{when}. Until a run starts, you can undo this: the work item goes back to closed, and nothing is sent to the ticket, so its label stays as it was.",
          name: by.name,
          when: at
        )

      {_previous, true, false} ->
        rich_gettext("You took this in again %{when}.", when: at)

      {_previous, false, false} ->
        rich_gettext("%{name} took this in again %{when}.", name: by.name, when: at)
    end
  end

  defp undo_line(%{work_item: work_item} = assigns) do
    by = work_item.taken_in_by
    at = inline_ago(work_item.taken_in_at, assigns.now)
    integration = assigns.integration

    case {assigns.uninstalled, you?(by), assigns.can_undo} do
      {true, true, true} ->
        rich_gettext(
          "You took this in %{when}. Until a run starts, you can undo this. %{integration} is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment.",
          when: at,
          integration: integration
        )

      {true, true, false} ->
        rich_gettext(
          "You took this in %{when}. %{integration} is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment.",
          when: at,
          integration: integration
        )

      {true, false, true} ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo this. %{integration} is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment.",
          name: by.name,
          when: at,
          integration: integration
        )

      {true, false, false} ->
        rich_gettext(
          "%{name} took this in %{when}. %{integration} is no longer connected, so nothing changes on the ticket: it keeps Qory's label and comment.",
          name: by.name,
          when: at,
          integration: integration
        )

      {false, true, true} ->
        rich_gettext(
          "You took this in %{when}. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays.",
          when: at
        )

      {false, true, false} ->
        rich_gettext("You took this in %{when}.", when: at)

      {false, false, true} ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo this: Qory takes its label off the ticket, and the comment stays.",
          name: by.name,
          when: at
        )

      {false, false, false} ->
        rich_gettext("%{name} took this in %{when}.", name: by.name, when: at)
    end
  end

  # Whose answers a run reads: none, the reader's, one other member's (by name), or
  # several members'. Two people are one by id, never by name.
  defp answers_of(people) do
    case Enum.uniq_by(people || [], &person_key/1) do
      [] -> :none
      [person] -> if you?(person), do: :you, else: {:name, person.name}
      _several -> :several
    end
  end

  defp person_key(%{you: true}), do: :you
  defp person_key(person), do: person[:id] || make_ref()

  # A run's id, `short_id/1` of its public id (`rn_` and 8 hex), as a link to its page
  # where the page gives one.
  defp run_ref(%{path: path, id: id}) when is_binary(path),
    do: {:link, path, RunComponents.short_id(id), "q-wi-run"}

  defp run_ref(%{id: id}), do: {:m, RunComponents.short_id(id), "q-wi-run-id"}

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
  The notice of an ended work item: who closed, declined or undid it and when (and where
  it was declined, its `:stage`, at Explore or at Confirm), what that left on the ticket, and Take in again, a link to the ticket's panel in the Backlog
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

  defp end_line(%{status: :closed, ended_by: by} = work_item, now) do
    date = day(work_item.ended_at, now)

    if you?(by),
      do: rich_gettext("You closed this work item on %{date}.", date: date),
      else: rich_gettext("%{name} closed this work item on %{date}.", name: by.name, date: date)
  end

  defp end_line(%{status: :declined, stage: :explore, ended_by: by} = work_item, now) do
    at = inline_ago(work_item.ended_at, now)

    if you?(by),
      do: rich_gettext("You declined this work item %{when}, at Explore.", when: at),
      else:
        rich_gettext("%{name} declined this work item %{when}, at Explore.",
          name: by.name,
          when: at
        )
  end

  defp end_line(%{status: :declined, ended_by: by} = work_item, now) do
    at = inline_ago(work_item.ended_at, now)

    if you?(by),
      do: rich_gettext("You declined this work item %{when}, at Confirm.", when: at),
      else:
        rich_gettext("%{name} declined this work item %{when}, at Confirm.",
          name: by.name,
          when: at
        )
  end

  defp end_line(%{status: :undone, ended_by: by} = work_item, now) do
    at = inline_ago(work_item.ended_at, now)

    if you?(by),
      do: rich_gettext("You undid this %{when}, before a run started.", when: at),
      else:
        rich_gettext("%{name} undid this %{when}, before a run started.",
          name: by.name,
          when: at
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
  `:taken_in_by`, `:taken_in_at`, `:first_instruction` (`nil`, empty or blank for none),
  `:runs` (`nil` for none, or `%{latest: %{id:, path:}, count:, running:}`), `:ended_by`
  and `:ended_at`, and its ticket's filer and when it was filed (`ticket`,
  `%{filer: %{name:}, filed_at:}`).
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
          rich_gettext("%{owner} · %{ref}", owner: owner_phrase(owner), ref: {:part, :ref}),
        instruction: instruction(work_item.first_instruction),
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
      <span class="q-wi-dtoggle-s">
        <.rich text={@summary}>
          <:part name={:ref}>
            <span class="q-wi-refm">
              <BacklogComponents.integration_tile name={@integration} />{@work_item.external_ref}
            </span>
          </:part>
        </.rich>
      </span>
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
        <dd id={"#{@id}-taken-in"}><span><.rich text={@taken_in} /></span></dd>
        <dt>{gettext("First instruction")}</dt>
        <dd id={"#{@id}-instruction"}>
          <span :if={@instruction} class="q-wi-q">{@instruction}</span>
          <span :if={!@instruction} class="q-faint">{gettext("None")}</span>
        </dd>
        <dt>{gettext("Runs")}</dt>
        <dd id={"#{@id}-runs"}>
          <span :if={@runs} class="q-wi-runs"><.rich text={runs_line(@runs)} /></span>
          <span :if={!@runs} class="q-faint">{gettext("None yet")}</span>
        </dd>
        <%= if @ended do %>
          <dt>{elem(@ended, 0)}</dt>
          <dd id={"#{@id}-ended"}><span><.rich text={elem(@ended, 1)} /></span></dd>
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
  A work item's tabs: Ticket (`ticket_path`), Explore (`explore_path`) and Thread
  (`thread_path`), with the count of people's comments where there are any; named "Work
  item #%{number}". Ticket stays the work item's address.
  """
  attr :id, :string, default: "work-item-tabs"
  attr :number, :integer, required: true, doc: "the work item's number"

  attr :current, :atom,
    required: true,
    values: [:ticket, :explore, :thread],
    doc: "the page's tab"

  attr :ticket_path, :string, required: true, doc: "the Ticket tab, `/work/:number`"
  attr :explore_path, :string, required: true, doc: "Explore's tab, `/work/:number/explore`"
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
      <:tab key={:explore} patch={@explore_path} icon="hero-light-bulb">{stage_name(:explore)}</:tab>
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

  ## Explore's tab

  @doc """
  Explore's tab (`/work/:number/explore`): the run line, which run of the take in it is,
  its id (linked to its page), its state and its time; then what the run gave, as the
  work item's status says:

    * queued or running: what Qory does next, with whose answers from a second run, and
      the answers that run reads, grouped by the run that asked them;
    * questions: Qory's questions, with the form for a reader who may act (`can_act`):
      one answer for each, Answer and explore again (`"answer"`);
    * the run limit: the note that the take in used its runs, then the last questions,
      read-only, or what happened to the last run;
    * no result, lost or cancelled: what happened, and the run's page;
    * Confirm: Qory's proposal; Shape: the proposal confirmed, who confirmed it and when
      (`:confirmed_by`, `:confirmed_at`), and each section a member changed (`changes`)
      with Qory's words under Show Qory's words;
    * an ended work item: what its last run gave, read-only.

  Then the earlier runs of this take in (`earlier_runs`, oldest first), each folded, and
  the earlier take ins (`earlier_take_ins`), each folded with its runs, which counted
  apart.

  A run is a map: `:id` (its `rn_` public id) and `:path`, `:attempt` and `:of`, `:state`
  (`:pending`, `:running`, `:completed`, `:failed`, `:cancelled` or `:lost`),
  `:started_at`, `:ended_at`, `:duration` (how long it took, in words), `:outcome`
  (`:proposal`, `:questions`, `:error`, `:none` or `:refused`), and what it gave:
  `:proposal`, or `:understanding` and `:questions` (each `%{public_id:, text:, answer:}`)
  with `:answered_by` (a person) and `:answered_at` once a member answered them.

  A proposal is a map: `:complexity` (`%{level: :simple | :standard | :complex, reason:}`),
  `:understanding`, `:scope_in` and `:scope_out` (lists), `:approach`, `:alternatives`
  (each `%{text:, reason:}`) and `:knowledge` (each `%{text:, sources:}`, the sources
  urls). A change is `%{value:, by:}` under the field's key (`:complexity`,
  `:understanding`, `:scope_in`, `:scope_out` or `:approach`), the value as the proposal
  has it. A take in is `%{taken_in_by:, taken_in_at:, ended:, ended_by:, ended_at:, runs:}`,
  `ended` being `:declined`, `:closed` or `:undone`.

  Every word a run wrote is plain text in a frame that names the run: escaped, its line
  breaks kept, isolated from the text around it. A source is a link only where it is an
  https url core allows as a link out; else its address is text, every character outside
  printable ASCII percent-encoded.

  The form's draft is `answers` (by question `public_id`), and `errors` its errors, by
  question `public_id`: `:blank` or `{:too_long, limit}`.
  """
  attr :id, :string, default: "work-item-explore"
  attr :work_item, :map, required: true, doc: "the work item, with its latest run as `:run`"
  attr :earlier_runs, :list, default: [], doc: "the take in's earlier runs, oldest first"
  attr :earlier_take_ins, :list, default: [], doc: "the earlier take ins, oldest first"
  attr :changes, :map, default: %{}, doc: "what a member changed before confirming, by field"
  attr :can_act, :boolean, default: false, doc: "whether the reader may answer"
  attr :answers, :map, default: %{}, doc: "the form's draft, by question `public_id`"
  attr :errors, :map, default: %{}, doc: "the form's errors, by question `public_id`"
  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def explore_tab(assigns) do
    work_item = assigns.work_item
    status = work_item.status
    run = work_item[:run]
    groups = Enum.filter(assigns.earlier_runs, &answered?/1)

    assigns =
      assign(assigns,
        now: now(assigns),
        status: status,
        run: run,
        groups: groups,
        view: explore_view(status, run),
        confirmed:
          status == :shape &&
            %{by: work_item.confirmed_by, at: work_item.confirmed_at},
        mode: if(status == :questions and assigns.can_act, do: :form, else: :read)
      )

    ~H"""
    <div id={@id} class="q-xp">
      <.run_line :if={@run} id={"#{@id}-run"} run={@run} now={@now} />
      <.explore_wait
        :if={@view == :wait}
        id={"#{@id}-wait"}
        status={@status}
        run={@run}
        groups={@groups}
      />
      <.answers_read
        :if={@view == :wait && @groups != []}
        id={"#{@id}-read"}
        run={@run}
        groups={@groups}
        now={@now}
      />
      <div :if={@status == :used_up} id={"#{@id}-limit"} class="q-xp-note">
        <.icon name="hero-exclamation-triangle-micro" class="q-xp-note-i size-4" />
        <p>
          {ngettext(
            "This take in has used its %{of} run, so Qory runs no more for these questions here. After a decline or a close, Take in again from the Backlog starts the count again.",
            "This take in has used its %{of} runs, so Qory runs no more for these questions here. After a decline or a close, Take in again from the Backlog starts the count again.",
            @run.of,
            of: Format.number(@run.of)
          )}
        </p>
      </div>
      <.questions_frame
        :if={@view == :questions}
        id={"#{@id}-questions"}
        number={@work_item.number}
        run={@run}
        mode={@mode}
        answers={@answers}
        errors={@errors}
      />
      <.proposal_frame
        :if={@view == :proposal}
        id={"#{@id}-proposal"}
        run={@run}
        changes={@changes}
        confirmed={@confirmed}
        now={@now}
      />
      <.no_result :if={@view == :no_result} id={"#{@id}-none"} run={@run} />
      <.earlier_runs :if={@earlier_runs != []} id={"#{@id}-earlier"} runs={@earlier_runs} now={@now} />
      <.earlier_take_ins
        :if={@earlier_take_ins != []}
        id={"#{@id}-take-ins"}
        take_ins={@earlier_take_ins}
        now={@now}
      />
    </div>
    """
  end

  # What the tab shows for the latest run: what comes next while it is queued or running,
  # else what the run gave.
  defp explore_view(status, _run) when status in [:queued, :running], do: :wait
  defp explore_view(_status, nil), do: nil
  defp explore_view(_status, %{outcome: :proposal}), do: :proposal
  defp explore_view(_status, %{outcome: :questions}), do: :questions
  defp explore_view(_status, _run), do: :no_result

  defp answered?(run), do: run[:outcome] == :questions and run[:answered_by] != nil

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :now, :any, required: true

  # Which run of the take in, its id, its state, its time. Before a run exists, and while
  # it is pending, it is Queued, Explore's word.
  defp run_line(assigns) do
    run = assigns.run
    state = run[:state]

    assigns =
      assign(assigns,
        place: run_place(run),
        state_word:
          if(state in [nil, :pending],
            do: gettext("Queued"),
            else: RunComponents.state_label(state)
          ),
        state_class:
          cond do
            state == :running -> "q-xp-run-on"
            state in [:failed, :cancelled, :lost] -> "q-xp-run-bad"
            true -> nil
          end,
        time: run_time(run, assigns.now)
      )

    ~H"""
    <p id={@id} class="q-xp-run">
      <span><b>{@place}</b></span>
      <span :if={@run[:id]}><.rich text={run_ref(@run)} /></span>
      <span class={@state_class}>{@state_word}</span>
      <span :if={@time}><.rich text={@time} /></span>
    </p>
    """
  end

  defp run_place(run),
    do:
      gettext("Run %{attempt} of %{of}",
        attempt: Format.number(run.attempt),
        of: Format.number(run.of)
      )

  defp run_time(%{state: :running, started_at: %DateTime{} = at}, now),
    do: rich_gettext("started %{when}", when: inline_ago(at, now))

  defp run_time(%{state: :lost, ended_at: %DateTime{} = at}, now),
    do: rich_gettext("lost %{when}", when: inline_ago(at, now))

  defp run_time(%{state: :cancelled, ended_at: %DateTime{} = at}, now),
    do: rich_gettext("cancelled %{when}", when: inline_ago(at, now))

  defp run_time(%{state: state, ended_at: %DateTime{} = at, duration: duration}, now)
       when state in [:completed, :failed] and is_binary(duration),
       do:
         rich_gettext("ended %{when}, after %{duration}",
           when: inline_ago(at, now),
           duration: duration
         )

  defp run_time(_run, _now), do: nil

  attr :id, :string, required: true
  attr :status, :atom, required: true
  attr :run, :map, required: true
  attr :groups, :list, required: true

  # Queued or running: what Qory does next, with whose answers.
  defp explore_wait(assigns) do
    run = assigns.run
    whose = answers_of(Enum.map(assigns.groups, & &1.answered_by))
    attempt = Format.number(run.attempt)
    of = Format.number(run.of)

    {heading, line} =
      case {assigns.status, whose} do
        {:queued, :none} ->
          {gettext("Explore is queued."),
           gettext(
             "Qory starts run %{attempt} of %{of} when the workspace's node pool takes it. It reads the ticket and the code, and proposes how to build it, or asks what it needs to know.",
             attempt: attempt,
             of: of
           )}

        {:queued, whose} ->
          {queued_heading(whose),
           gettext(
             "Run %{attempt} of %{of} starts when the workspace's node pool takes it. It reads the ticket, the code and these answers, from the start.",
             attempt: attempt,
             of: of
           )}

        {:running, :none} ->
          {gettext("Qory is exploring."),
           gettext(
             "Run %{attempt} of %{of} reads the ticket and the code. It proposes how to build it, or asks what it needs to know.",
             attempt: attempt,
             of: of
           )}

        {:running, whose} ->
          {running_heading(whose),
           gettext(
             "Run %{attempt} of %{of} reads the ticket, the code and these answers, from the start. It proposes how to build it, or asks what it still needs to know.",
             attempt: attempt,
             of: of
           )}
      end

    assigns = assign(assigns, heading: heading, line: line)

    ~H"""
    <div id={@id} class="q-xp-wait">
      <.bee />
      <div>
        <p id={"#{@id}-h"}><b>{@heading}</b></p>
        <p>{@line}</p>
      </div>
    </div>
    """
  end

  defp queued_heading(:you), do: gettext("Explore is queued again, with your answers.")

  defp queued_heading({:name, name}),
    do: gettext("Explore is queued again, with %{name}'s answers.", name: name)

  defp queued_heading(:several),
    do: gettext("Explore is queued again, with the answers of this take in.")

  defp running_heading(:you), do: gettext("Qory is exploring again, with your answers.")

  defp running_heading({:name, name}),
    do: gettext("Qory is exploring again, with %{name}'s answers.", name: name)

  defp running_heading(:several),
    do: gettext("Qory is exploring again, with the answers of this take in.")

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :groups, :list, required: true
  attr :now, :any, required: true

  # The answers a run reads: every answer of the take in, one group for each earlier run
  # that asked, under its run and who answered it.
  defp answers_read(assigns) do
    n = length(assigns.groups)

    assigns =
      assign(assigns,
        heading:
          gettext("The answers run %{attempt} reads", attempt: Format.number(assigns.run.attempt)),
        caption:
          ngettext(
            "Explore asked these in %{number} earlier run of this take in, shown as plain text.",
            "Explore asked these in %{number} earlier runs of this take in, shown as plain text.",
            n,
            number: Format.number(n)
          )
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <h2 id={"#{@id}-h"}>{@heading}</h2>
      </div>
      <p class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span>{@caption}</span>
      </p>
      <div class="q-xp-body">
        <section
          :for={run <- @groups}
          id={"#{@id}-#{run.id}"}
          class="q-xp-grp"
          aria-labelledby={"#{@id}-#{run.id}-h"}
        >
          <h3 id={"#{@id}-#{run.id}-h"}>
            <span>{run_place(run)}</span>
            <.rich text={run_ref(run)} />
          </h3>
          <.answered id={"#{@id}-#{run.id}-qa"} run={run} now={@now} />
        </section>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :now, :any, required: true

  # One run's questions and their answers, under who answered them, once: one member sends
  # a run's answers together.
  defp answered(assigns) do
    by = assigns.run.answered_by
    at = inline_ago(assigns.run.answered_at, assigns.now)

    assigns =
      assign(
        assigns,
        :who,
        if(you?(by),
          do: rich_gettext("You answered %{when}", when: at),
          else: rich_gettext("%{name} answered %{when}", name: by.name, when: at)
        )
      )

    ~H"""
    <p id={"#{@id}-who"} class="q-xp-who"><.rich text={@who} /></p>
    <ol class="q-xp-qs">
      <li :for={question <- @run.questions} id={"#{@id}-#{question.public_id}"}>
        <span class="q-xp-n" aria-hidden="true"></span>
        <div>
          <div class="q-xp-val" phx-no-format>{question.text}</div>
          <div class="q-xp-ans" phx-no-format>{question.answer}</div>
        </div>
      </li>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :run, :map, required: true
  attr :mode, :atom, required: true, values: [:form, :read]
  attr :answers, :map, default: %{}
  attr :errors, :map, default: %{}

  # Qory's questions, in a frame that names the run; with the form for a member who may
  # answer them.
  defp questions_frame(assigns) do
    run = assigns.run
    n = length(run.questions)

    first_error =
      assigns.mode == :form &&
        Enum.find(run.questions, &Map.has_key?(assigns.errors, &1.public_id))

    assigns =
      assign(assigns,
        n: n,
        first_error: first_error,
        heading: ngettext("Qory's question", "Qory's questions", n),
        next:
          gettext(
            "Qory runs Explore again from the start, with the ticket, its comments, the first instruction and the answers of this take in. It is run %{attempt} of %{of}.",
            attempt: Format.number(run.attempt + 1),
            of: Format.number(run.of)
          )
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.bee class="q-bl-bee" />
        <h2 id={"#{@id}-h"}>{@heading}</h2>
      </div>
      <.wrote_caption run={@run} />
      <div class="q-xp-body">
        <div :if={present?(@run[:understanding])} class="q-xp-sec">
          <h3>{gettext("What Qory understood so far")}</h3>
          <div class="q-xp-val" phx-no-format>{@run.understanding}</div>
        </div>
        <div class="q-xp-sec">
          <h3>{gettext("What Qory needs to know")}</h3>
          <%= if @mode == :form do %>
            <form
              id={"#{@id}-form"}
              phx-submit="answer"
              novalidate
              aria-labelledby={"#{@id}-h"}
            >
              <input type="hidden" name="number" value={@number} />
              <ol class="q-xp-qs">
                <.question_field
                  :for={{question, i} <- Enum.with_index(@run.questions, 1)}
                  id={@id}
                  question={question}
                  i={i}
                  value={@answers[question.public_id]}
                  error={@errors[question.public_id]}
                />
              </ol>
              <span
                :if={@first_error}
                id={"#{@id}-focus-#{@first_error.public_id}"}
                hidden
                phx-mounted={JS.focus(to: "##{@id}-answer-#{@first_error.public_id}")}
              ></span>
              <div class="q-xp-form-foot">
                <p id={"#{@id}-next"}>{@next}</p>
                <.button id={"#{@id}-go"} type="submit" variant="primary">
                  <.icon name="hero-paper-airplane-micro" class="size-3.5" />{gettext(
                    "Answer and explore again"
                  )}
                </.button>
              </div>
            </form>
          <% else %>
            <ol class="q-xp-qs">
              <li :for={question <- @run.questions} id={"#{@id}-q-#{question.public_id}"}>
                <span class="q-xp-n" aria-hidden="true"></span>
                <div>
                  <div class="q-xp-val" phx-no-format>{question.text}</div>
                </div>
              </li>
            </ol>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :question, :map, required: true
  attr :i, :integer, required: true
  attr :value, :string, default: nil
  attr :error, :any, default: nil

  # A question and its answer's field, labelled for a screen reader and described by the
  # question, and by its error where it has one.
  defp question_field(assigns) do
    pid = assigns.question.public_id
    field = "#{assigns.id}-answer-#{pid}"

    assigns =
      assign(assigns,
        q_id: "#{assigns.id}-q-#{pid}",
        field: field,
        error_id: "#{field}-error",
        name: "answers[#{pid}]",
        message: answer_error(assigns.error)
      )

    ~H"""
    <li id={"#{@id}-item-#{@question.public_id}"}>
      <span class="q-xp-n" aria-hidden="true"></span>
      <div>
        <div id={@q_id} class="q-xp-val" phx-no-format>{@question.text}</div>
        <label for={@field} class="sr-only">
          {gettext("Answer to question %{number}", number: Format.number(@i))}
        </label>
        <textarea
          id={@field}
          name={@name}
          rows="2"
          placeholder={gettext("Your answer")}
          aria-describedby={if @message, do: "#{@q_id} #{@error_id}", else: @q_id}
          aria-invalid={@message && "true"}
        >{@value}</textarea>
        <p :if={@message} id={@error_id} class="q-xp-err">
          <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@message}
        </p>
      </div>
    </li>
    """
  end

  defp answer_error(nil), do: nil

  defp answer_error(:blank),
    do: gettext("Answer this question. If nobody knows, say so: Qory reads that too.")

  defp answer_error({:too_long, limit}),
    do: gettext("Write at most %{number} characters.", number: Format.number(limit))

  attr :run, :map, required: true

  defp wrote_caption(assigns) do
    ~H"""
    <p class="q-xp-cap">
      <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
      <span>
        <.rich text={
          rich_gettext(
            "Explore wrote this in run %{run}. Qory shows it as plain text, as the run wrote it.",
            run: run_ref(@run)
          )
        } />
      </span>
    </p>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :changes, :map, default: %{}
  attr :confirmed, :any, default: nil
  attr :now, :any, required: true

  # Qory's proposal, in a frame that names the run. Confirmed, who confirmed it; each
  # section a member changed shows their words, marked, and Qory's under a toggle.
  defp proposal_frame(assigns) do
    proposal = assigns.run.proposal
    changes = assigns.changes || %{}

    assigns =
      assign(assigns,
        proposal: proposal,
        changes: changes,
        caption: proposal_caption(assigns.run, assigns.confirmed, changes != %{}, assigns.now)
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.bee class="q-bl-bee" />
        <h2 id={"#{@id}-h"}>{gettext("Qory's proposal")}</h2>
        <.badge :if={@confirmed} color="info" class="q-xp-frame-b">{gettext("Confirmed")}</.badge>
      </div>
      <p :if={@caption} class="q-xp-cap">
        <.icon name="hero-check-micro" class="q-xp-cap-i size-3.5" />
        <span><.rich text={@caption} /></span>
      </p>
      <.wrote_caption :if={!@caption} run={@run} />
      <div class="q-xp-body">
        <.proposal_section
          id={"#{@id}-complexity"}
          label={gettext("Complexity")}
          value={@proposal.complexity}
          change={@changes[:complexity]}
        >
          <:draw :let={complexity}>
            <div class="q-xp-cx">
              <.badge>{level_word(complexity.level)}</.badge>
              <div class="q-xp-val" phx-no-format>{complexity.reason}</div>
            </div>
          </:draw>
        </.proposal_section>
        <.proposal_section
          id={"#{@id}-understanding"}
          label={gettext("Understanding")}
          value={@proposal.understanding}
          change={@changes[:understanding]}
        >
          <:draw :let={text}>
            <div class="q-xp-val" phx-no-format>{text}</div>
          </:draw>
        </.proposal_section>
        <.proposal_section
          id={"#{@id}-scope-in"}
          label={gettext("In scope")}
          value={@proposal.scope_in}
          change={@changes[:scope_in]}
        >
          <:draw :let={items}><.text_list items={items} /></:draw>
        </.proposal_section>
        <.proposal_section
          id={"#{@id}-scope-out"}
          label={gettext("Out of scope")}
          value={@proposal.scope_out}
          change={@changes[:scope_out]}
        >
          <:draw :let={items}><.text_list items={items} /></:draw>
        </.proposal_section>
        <.proposal_section
          id={"#{@id}-approach"}
          label={gettext("Approach")}
          value={@proposal.approach}
          change={@changes[:approach]}
        >
          <:draw :let={text}>
            <div class="q-xp-val" phx-no-format>{text}</div>
          </:draw>
        </.proposal_section>
        <div id={"#{@id}-alternatives"} class="q-xp-sec">
          <h3>{gettext("Not chosen")}</h3>
          <ul class="q-xp-list">
            <li :for={alternative <- @proposal.alternatives || []} phx-no-format>{alternative.text}<span class="q-xp-why"><.rich text={rich_gettext("Why not: %{reason}", reason: {:bdi, alternative.reason})} /></span></li>
            <li :if={(@proposal.alternatives || []) == []} class="q-xp-none">{gettext("None")}</li>
          </ul>
        </div>
        <div id={"#{@id}-knowledge"} class="q-xp-sec">
          <h3>{gettext("What Qory learned, and where")}</h3>
          <ul :if={(@proposal.knowledge || []) != []} class="q-xp-know">
            <li :for={item <- @proposal.knowledge}>
              <div class="q-xp-val" phx-no-format>{item.text}</div>
              <ul :if={(item.sources || []) != []} class="q-xp-src" aria-label={gettext("Sources")}>
                <li :for={url <- item.sources}><.source url={url} /></li>
              </ul>
            </li>
          </ul>
          <ul :if={(@proposal.knowledge || []) == []} class="q-xp-list">
            <li class="q-xp-none">{gettext("None")}</li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  # Who confirmed the proposal and when, with or without their changes; nil before.
  defp proposal_caption(_run, falsy, _changed, _now) when falsy in [nil, false], do: nil

  defp proposal_caption(run, %{by: by, at: at}, changed, now) do
    at = inline_ago(at, now)
    run = run_ref(run)

    case {you?(by), changed} do
      {true, true} ->
        rich_gettext(
          "You confirmed it %{when}, with your changes. Explore wrote the rest in run %{run}, shown as plain text.",
          when: at,
          run: run
        )

      {false, true} ->
        rich_gettext(
          "%{name} confirmed it %{when}, with their changes. Explore wrote the rest in run %{run}, shown as plain text.",
          name: by.name,
          when: at,
          run: run
        )

      {true, false} ->
        rich_gettext(
          "You confirmed it %{when}. Explore wrote it in run %{run}, shown as plain text.",
          when: at,
          run: run
        )

      {false, false} ->
        rich_gettext(
          "%{name} confirmed it %{when}. Explore wrote it in run %{run}, shown as plain text.",
          name: by.name,
          when: at,
          run: run
        )
    end
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true, doc: "the run's words"
  attr :change, :map, default: nil
  slot :draw, required: true

  # A section of the proposal: its label, and the run's words; where a member changed it,
  # their words, marked, with Qory's words under Show Qory's words.
  defp proposal_section(%{change: nil} = assigns) do
    ~H"""
    <div id={@id} class="q-xp-sec">
      <h3>{@label}</h3>
      {render_slot(@draw, @value)}
    </div>
    """
  end

  defp proposal_section(assigns) do
    by = assigns.change.by

    assigns =
      assign(
        assigns,
        :by_words,
        if(you?(by),
          do: gettext("Changed by you"),
          else: gettext("Changed by %{name}", name: by.name)
        )
      )

    ~H"""
    <div id={@id} class="q-xp-sec q-xp-changed">
      <h3>
        {@label}
        <span id={"#{@id}-by"}><.badge color="info">{@by_words}</.badge></span>
        <button
          id={"#{@id}-toggle"}
          type="button"
          class="q-xp-toggle"
          aria-expanded="false"
          aria-controls={"#{@id}-was"}
          phx-click={
            JS.toggle_attribute({"aria-expanded", "true", "false"})
            |> JS.toggle_attribute({"hidden", "hidden"}, to: "##{@id}-was")
          }
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        >
          <span class="q-xp-show">{gettext("Show Qory's words")}</span>
          <span class="q-xp-hide">{gettext("Hide Qory's words")}</span>
        </button>
      </h3>
      <div class="q-xp-mine">{render_slot(@draw, @change.value)}</div>
      <div
        id={"#{@id}-was"}
        class="q-xp-was"
        hidden
        phx-mounted={JS.ignore_attributes(["hidden"])}
      >
        <p class="q-xp-was-l">{gettext("Qory's words")}</p>
        {render_slot(@draw, @value)}
      </div>
    </div>
    """
  end

  attr :items, :list, required: true

  defp text_list(assigns) do
    ~H"""
    <ul class="q-xp-list">
      <li :for={item <- @items} phx-no-format>{item}</li>
      <li :if={@items == []} class="q-xp-none">{gettext("None")}</li>
    </ul>
    """
  end

  defp level_word(:simple), do: pgettext("complexity", "Simple")
  defp level_word(:standard), do: pgettext("complexity", "Standard")
  defp level_word(:complex), do: pgettext("complexity", "Complex")

  attr :url, :string, required: true

  # A source the run gave: a link only where it is an https url core allows as a link
  # out, its host in full and the rest cut where room ends, each isolated, the whole
  # address in its title; else the address as text, every character outside printable
  # ASCII percent-encoded, so no look-alike passes for another.
  defp source(assigns) do
    url = assigns.url

    assigns =
      case out?(url) && Regex.run(~r{\Ahttps://([^/?#]+)(.*)\z}is, url) do
        [_all, host, rest] -> assign(assigns, link: true, host: host, rest: rest)
        _none -> assign(assigns, link: false, text: ascii(url))
      end

    ~H"""
    <.external_link :if={@link} href={@url} class="q-xp-src-a" title={@url}>
      <.icon name="hero-globe-alt-micro" class="q-xp-src-i size-3.5" />
      <bdi class="q-xp-host">{@host}</bdi><bdi class="q-xp-path">{@rest}</bdi>
    </.external_link>
    <span :if={!@link} class="q-xp-src-t"><bdi>{@text}</bdi></span>
    """
  end

  defp ascii(url) when is_binary(url), do: URI.encode(url, &(&1 in 33..126))
  defp ascii(_url), do: ""

  attr :id, :string, required: true
  attr :run, :map, required: true

  # A run that gave no result: what happened, and its page.
  defp no_result(assigns) do
    {icon, heading, body} = no_result_words(assigns.run)
    assigns = assign(assigns, icon: icon, heading: heading, body: body)

    ~H"""
    <div id={@id} class="q-xp-wait q-xp-bad">
      <.icon name={@icon} class="q-xp-bad-i size-4" />
      <div>
        <p id={"#{@id}-h"}><b>{@heading}</b></p>
        <p>{@body}</p>
        <p>
          <.rich text={rich_gettext("The run's page, %{run}, shows what it did.", run: run_ref(@run))} />
        </p>
      </div>
    </div>
    """
  end

  defp no_result_words(%{state: :lost}),
    do:
      {"hero-signal-slash-micro", gettext("The run was lost."),
       gettext(
         "It stopped reporting before it ended. There is nothing for Qory to show or for a member to confirm."
       )}

  defp no_result_words(%{state: :cancelled}),
    do:
      {"hero-stop-circle-micro", gettext("The run was cancelled."),
       gettext(
         "It was cancelled before it ended. There is nothing for Qory to show or for a member to confirm."
       )}

  defp no_result_words(%{outcome: :none}),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended without a result."),
       gettext(
         "It sent no result, so there is nothing for Qory to show or for a member to confirm."
       )}

  defp no_result_words(%{outcome: :refused}),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run's result did not pass Qory's check."),
       gettext(
         "Qory reads a result only in the format Explore uses, and at most 128 KiB. This one was not, so Qory does not show it."
       )}

  defp no_result_words(_error),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended with an error."),
       gettext(
         "Its last result was an error, so there is nothing for Qory to show or for a member to confirm."
       )}

  attr :id, :string, required: true
  attr :runs, :list, required: true
  attr :now, :any, required: true

  # The take in's earlier runs, each folded: its place, its id, what it gave, when.
  defp earlier_runs(assigns) do
    ~H"""
    <section id={@id} class="q-xp-earlier" aria-labelledby={"#{@id}-h"}>
      <h3 id={"#{@id}-h"}>{gettext("Earlier runs of this take in")}</h3>
      <details :for={run <- @runs} id={"#{@id}-#{run.id}"}>
        <summary>
          <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
          <span class="q-xp-it"><b>{run_place(run)}</b></span>
          <span class="q-xp-it q-mono">{RunComponents.short_id(run.id)}</span>
          <span class="q-xp-it">{run_gave(run)}</span>
          <span :if={run[:ended_at]} class="q-xp-it">
            {time_tag(run.ended_at, Format.relative(run.ended_at, @now))}
          </span>
        </summary>
        <div class="q-xp-inner">
          <.run_body id={"#{@id}-#{run.id}-body"} run={run} now={@now} />
        </div>
      </details>
    </section>
    """
  end

  # What a run gave, in a fold's summary.
  defp run_gave(%{outcome: :questions, questions: questions}) do
    n = length(questions)
    ngettext("Asked %{number} question", "Asked %{number} questions", n, number: Format.number(n))
  end

  defp run_gave(%{outcome: :proposal}), do: gettext("Proposed how to build it")
  defp run_gave(%{state: state}), do: RunComponents.state_label(state)

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :now, :any, required: true

  # Inside a run's fold: its questions and the answers, its questions nobody answered,
  # its proposal, or what happened to it.
  defp run_body(%{run: %{outcome: :questions}} = assigns) do
    n = length(assigns.run.questions)

    assigns =
      assign(
        assigns,
        :heading,
        ngettext("Qory's question, and the answer", "Qory's questions, and the answers", n)
      )

    ~H"""
    <section :if={answered?(@run)} id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <h2 id={"#{@id}-h"}>{@heading}</h2>
      </div>
      <p class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span>
          <.rich text={
            rich_gettext("Explore asked these in run %{run}, shown as plain text.",
              run: run_ref(@run)
            )
          } />
        </span>
      </p>
      <div class="q-xp-body">
        <.answered id={"#{@id}-qa"} run={@run} now={@now} />
      </div>
    </section>
    <.questions_frame :if={!answered?(@run)} id={@id} number={0} run={@run} mode={:read} />
    """
  end

  defp run_body(%{run: %{outcome: :proposal}} = assigns) do
    ~H"""
    <.proposal_frame id={@id} run={@run} now={@now} />
    """
  end

  defp run_body(assigns) do
    ~H"""
    <.no_result id={@id} run={@run} />
    """
  end

  attr :id, :string, required: true
  attr :take_ins, :list, required: true
  attr :now, :any, required: true

  # The earlier take ins, each folded: who took it in and when, how it ended, how many
  # runs; inside, its runs, which counted apart from this take in.
  defp earlier_take_ins(assigns) do
    ~H"""
    <section id={@id} class="q-xp-earlier" aria-labelledby={"#{@id}-h"}>
      <h3 id={"#{@id}-h"}>{gettext("Earlier take ins")}</h3>
      <details :for={{take_in, i} <- Enum.with_index(@take_ins, 1)} id={"#{@id}-#{i}"}>
        <summary>
          <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
          <span class="q-xp-it"><b><.rich text={taken_in_words(take_in, @now)} /></b></span>
          <span class="q-xp-it"><.rich text={ended_words(take_in, @now)} /></span>
          <span class="q-xp-it">
            {ngettext("%{count} run", "%{count} runs", length(take_in.runs))}
          </span>
        </summary>
        <div class="q-xp-inner">
          <p>{gettext("Its runs counted apart from this take in.")}</p>
          <%= for run <- take_in.runs do %>
            <.run_line id={"#{@id}-#{i}-#{run.id}"} run={run} now={@now} />
            <.run_body id={"#{@id}-#{i}-#{run.id}-body"} run={run} now={@now} />
          <% end %>
        </div>
      </details>
    </section>
    """
  end

  defp taken_in_words(%{taken_in_by: by, taken_in_at: at}, now) do
    if you?(by),
      do: rich_gettext("Taken in %{date} by you", date: day(at, now)),
      else: rich_gettext("Taken in %{date} by %{name}", date: day(at, now), name: by.name)
  end

  defp ended_words(%{ended: ended, ended_by: by, ended_at: at}, now) do
    at = inline_ago(at, now)

    case {ended, you?(by)} do
      {:declined, true} -> rich_gettext("Declined by you %{when}", when: at)
      {:declined, false} -> rich_gettext("Declined by %{name} %{when}", name: by.name, when: at)
      {:closed, true} -> rich_gettext("Closed by you %{when}", when: at)
      {:closed, false} -> rich_gettext("Closed by %{name} %{when}", name: by.name, when: at)
      {:undone, true} -> rich_gettext("Undone by you %{when}", when: at)
      {:undone, false} -> rich_gettext("Undone by %{name} %{when}", name: by.name, when: at)
    end
  end

  defp present?(text) when is_binary(text), do: String.trim(text) != ""
  defp present?(_text), do: false

  ## The edit page

  @doc false
  def edit_title(number), do: gettext("Change Qory's proposal · #%{number}", number: number)

  @doc """
  The edit page (`/work/:number/explore/edit`), a page at an address apart from the tab: Explore, the
  way back (`explore_path`); what it is for; the fields a member may change, each starting
  from the run's words (`proposal`, as `explore_tab/1` describes it): Complexity (its
  level and why), Understanding, In scope and Out of scope (one line for each entry; a
  line break inside an entry shows as a space), and Approach. A field whose value differs
  from the run's words says Changed, in its description. Then that what Qory did not
  choose and what it learned stay as Qory wrote them, and Confirm with your changes
  (`"confirm_changes"`) and Cancel, back to Explore's tab.

  The form sends `"change_proposal"` as a member types and `"confirm_changes"` to
  confirm, with the work item's `number`, `complexity[level]` (`simple`, `standard` or
  `complex`), `complexity[reason]`, `understanding`, `scope_in`, `scope_out` and
  `approach`. `values` is what the fields hold, by those names (`:level`, `:reason`,
  `:understanding`, `:scope_in`, `:scope_out`, `:approach`), each a string; the run's
  words where it is not given. `errors`, by the same names, says what is wrong with a
  field: `:blank`, `{:too_long, limit}`, `{:line_too_long, limit}` or
  `{:too_many_lines, limit}`; the focus goes to the first field at fault.
  """
  attr :id, :string, default: "work-item-edit"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :proposal, :map, required: true, doc: "the run's proposal"
  attr :values, :map, default: %{}, doc: "what the fields hold, by name"
  attr :errors, :map, default: %{}, doc: "what is wrong, by field"
  attr :explore_path, :string, required: true, doc: "Explore's tab"

  def proposal_edit(assigns) do
    initial = edit_values(assigns.proposal)
    values = Map.merge(initial, assigns.values || %{})

    changed =
      for field <- @edit_fields,
          changed?(field, values[field], initial[field]),
          into: MapSet.new(),
          do: field

    first_error = Enum.find(@edit_fields, &Map.has_key?(assigns.errors, &1))

    assigns =
      assign(assigns,
        values: values,
        changed: changed,
        first_error: first_error,
        complexity_changed: MapSet.member?(changed, :level) or MapSet.member?(changed, :reason)
      )

    ~H"""
    <div id={@id} class="q-xp-edit">
      <.link id={"#{@id}-back"} navigate={@explore_path} class="q-xp-back">
        <.icon name="hero-arrow-left-micro" class="size-3.5" />{stage_name(:explore)}
      </.link>
      <h2 id={"#{@id}-h"}>{gettext("Change Qory's proposal")}</h2>
      <p class="q-xp-lead">
        {gettext(
          "Change what Qory got wrong, then confirm. Qory's words stay in the Explore tab beside yours."
        )}
      </p>
      <form
        id={"#{@id}-form"}
        phx-change="change_proposal"
        phx-submit="confirm_changes"
        novalidate
        aria-labelledby={"#{@id}-h"}
      >
        <input type="hidden" name="number" value={@number} />
        <div
          id={"#{@id}-complexity"}
          class="q-xp-field"
          role="group"
          aria-labelledby={"#{@id}-complexity-l"}
        >
          <div class="q-xp-lbl-row">
            <span id={"#{@id}-complexity-l"} class="q-xp-lbl">{gettext("Complexity")}</span>
            <span :if={@complexity_changed} id={"#{@id}-complexity-ch"}>
              <.badge color="info">{pgettext("field edited", "Changed")}</.badge>
            </span>
          </div>
          <div class="q-xp-cx-row">
            <span class="q-xp-sub">
              <label for={"#{@id}-level"}>{pgettext("complexity", "Level")}</label>
              <select
                id={"#{@id}-level"}
                name="complexity[level]"
                aria-describedby={described([@complexity_changed && "#{@id}-complexity-ch"])}
              >
                <option
                  :for={level <- [:simple, :standard, :complex]}
                  value={level}
                  selected={to_string(level) == @values.level}
                >
                  {level_word(level)}
                </option>
              </select>
            </span>
            <span class="q-xp-sub">
              <label for={"#{@id}-reason"}>{gettext("Why")}</label>
              <.edit_area
                id={"#{@id}-reason"}
                name="complexity[reason]"
                value={@values.reason}
                rows="2"
                described={[@complexity_changed && "#{@id}-complexity-ch"]}
                error={edit_error(:reason, @errors[:reason])}
              />
            </span>
          </div>
        </div>
        <.edit_field
          id={"#{@id}-understanding"}
          name="understanding"
          label={gettext("Understanding")}
          value={@values.understanding}
          rows="6"
          changed={MapSet.member?(@changed, :understanding)}
          error={edit_error(:understanding, @errors[:understanding])}
        />
        <.edit_field
          id={"#{@id}-scope-in"}
          name="scope_in"
          label={gettext("In scope")}
          hint={gettext("One line for each.")}
          value={@values.scope_in}
          rows="4"
          changed={MapSet.member?(@changed, :scope_in)}
          error={edit_error(:scope_in, @errors[:scope_in])}
        />
        <.edit_field
          id={"#{@id}-scope-out"}
          name="scope_out"
          label={gettext("Out of scope")}
          hint={gettext("One line for each. Leave it empty when nothing is left out.")}
          value={@values.scope_out}
          rows="4"
          changed={MapSet.member?(@changed, :scope_out)}
          error={edit_error(:scope_out, @errors[:scope_out])}
        />
        <.edit_field
          id={"#{@id}-approach"}
          name="approach"
          label={gettext("Approach")}
          value={@values.approach}
          rows="3"
          changed={MapSet.member?(@changed, :approach)}
          error={edit_error(:approach, @errors[:approach])}
        />
        <span
          :if={@first_error}
          id={"#{@id}-focus-#{@first_error}"}
          hidden
          phx-mounted={JS.focus(to: "##{@id}-#{edit_dom(@first_error)}")}
        ></span>
        <p class="q-xp-kept">
          <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
          <span>
            {gettext(
              "The approaches Qory did not choose, and what it learned, stay as Qory wrote them."
            )}
          </span>
        </p>
        <div class="q-xp-foot">
          <p>
            {gettext("Confirming makes work item #%{number} ready for Shape.", number: @number)}
          </p>
          <div class="q-wi-acts">
            <.button id={"#{@id}-go"} type="submit" variant="primary">
              <.icon name="hero-check-micro" class="size-3.5" />{gettext("Confirm with your changes")}
            </.button>
            <.button id={"#{@id}-cancel"} variant="ghost" navigate={@explore_path}>
              {gettext("Cancel")}
            </.button>
          </div>
        </div>
      </form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :value, :string, default: nil
  attr :rows, :string, required: true
  attr :changed, :boolean, default: false
  attr :error, :string, default: nil

  # A field of the edit page: its label, Changed where the member changed it, its hint,
  # the field, and its error; the hint, Changed and the error describe it.
  defp edit_field(assigns) do
    ~H"""
    <div class={["q-xp-field", @error && "q-xp-field-bad"]}>
      <div class="q-xp-lbl-row">
        <label for={@id} class="q-xp-lbl">{@label}</label>
        <span :if={@changed} id={"#{@id}-ch"}>
          <.badge color="info">{pgettext("field edited", "Changed")}</.badge>
        </span>
      </div>
      <span :if={@hint} id={"#{@id}-hint"} class="q-xp-hint">{@hint}</span>
      <.edit_area
        id={@id}
        name={@name}
        value={@value}
        rows={@rows}
        described={[@hint && "#{@id}-hint", @changed && "#{@id}-ch"]}
        error={@error}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: nil
  attr :rows, :string, required: true
  attr :described, :list, default: []
  attr :error, :string, default: nil

  defp edit_area(assigns) do
    ~H"""
    <textarea
      id={@id}
      name={@name}
      rows={@rows}
      aria-describedby={described(@described ++ [@error && "#{@id}-err"])}
      aria-invalid={@error && "true"}
    >{@value}</textarea>
    <p :if={@error} id={"#{@id}-err"} class="q-xp-err">
      <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@error}
    </p>
    """
  end

  defp described(ids) do
    case Enum.filter(ids, &is_binary/1) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  # The fields as the edit page shows the run's words: a scope entry one line, its line
  # breaks as spaces.
  defp edit_values(proposal) do
    %{
      level: to_string(proposal.complexity.level),
      reason: proposal.complexity.reason,
      understanding: proposal.understanding,
      scope_in: lines(proposal.scope_in),
      scope_out: lines(proposal.scope_out),
      approach: proposal.approach
    }
  end

  defp lines(entries),
    do: Enum.map_join(entries || [], "\n", &String.replace(&1, ~r/\s*[\r\n]+\s*/, " "))

  # A field differs from the run's words; a scope by its non-empty lines, trimmed, as a
  # save reads them.
  defp changed?(field, value, initial) when field in [:scope_in, :scope_out],
    do: scope_lines(value) != scope_lines(initial)

  defp changed?(_field, value, initial), do: (value || "") != (initial || "")

  defp scope_lines(text) do
    (text || "")
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp edit_dom(:level), do: "level"
  defp edit_dom(:reason), do: "reason"
  defp edit_dom(:understanding), do: "understanding"
  defp edit_dom(:scope_in), do: "scope-in"
  defp edit_dom(:scope_out), do: "scope-out"
  defp edit_dom(:approach), do: "approach"

  defp edit_error(_field, nil), do: nil
  defp edit_error(:reason, :blank), do: gettext("Write why the work is at this level.")
  defp edit_error(:understanding, :blank), do: gettext("Write the understanding.")
  defp edit_error(:scope_in, :blank), do: gettext("Write at least one line in scope.")
  defp edit_error(:approach, :blank), do: gettext("Write the approach.")

  defp edit_error(:understanding, {:too_long, limit}),
    do:
      gettext("Write the understanding in at most %{number} characters.",
        number: Format.number(limit)
      )

  defp edit_error(_field, {:too_long, limit}),
    do: gettext("Write at most %{number} characters.", number: Format.number(limit))

  defp edit_error(_field, {:line_too_long, limit}),
    do: gettext("Write each line in at most %{number} characters.", number: Format.number(limit))

  defp edit_error(_field, {:too_many_lines, limit}),
    do: ngettext("Write at most %{count} line.", "Write at most %{count} lines.", limit)

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
          {ngettext("%{count} comment on the ticket", "%{count} comments on the ticket", @count)}
        </h3>
        <.button
          :if={@earlier > 0}
          id={"#{@id}-earlier"}
          type="button"
          variant="link"
          class="q-wi-earlier"
          phx-click="show_earlier_comments"
        >
          {ngettext("Show %{count} earlier comment", "Show %{count} earlier comments", @earlier)}
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

    * `:taken_in` - who took the work item in from the ticket (`external_ref`, beside the
      mark of the integration it came from, `integration`, and a link out where `url` is
      given), or took it in again (`again`), who owns it where that is another person
      (`owner`), and the first instruction under it (`first_instruction`, none where it is
      empty or blank);
    * `:started` - Qory started Explore in a run (`run`), its first, again with the
      answers (`start: :answers`), or again after Run Explore again or a retry
      (`start: :again`), with the run's place in the take in beside it;
    * `:asked` - how many questions Qory asked and after how long (`questions`,
      `duration`), the questions quoted under it;
    * `:answered` - who answered Qory's questions, each question and its answer quoted;
    * `:proposed` - Qory proposed how to build it, after how long, and whose turn it is
      (`owner`); nothing where it has no owner;
    * `:no_result`, `:lost`, `:cancelled` - a run (`run`) that gave no result, and why
      (`outcome`: `:error`, `:none` or `:refused`);
    * `:explore_again` - who asked Qory to explore again;
    * `:confirmed` - who confirmed Qory's proposal, with their changes (`changed`);
    * `:closed`, `:declined` - who closed or declined it, and where it was declined
      (`stage`);
    * `:undone` - who undid it, before a run started.

  A run is `%{id:, path:, attempt:, of:}`, its id shown as `short_id/1` and linked where
  `path` is given. A question is `%{public_id:, text:, answer:}`. Every kind takes
  `integration`, so no page draws the ref without its mark. What a run wrote, and a
  member's answers, are quoted as plain text, never inside a sentence.
  """
  attr :id, :string, required: true, doc: "the DOM id: the event's `public_id` under the Thread's"

  attr :kind, :atom,
    required: true,
    values: [
      :taken_in,
      :started,
      :asked,
      :answered,
      :proposed,
      :no_result,
      :lost,
      :cancelled,
      :explore_again,
      :confirmed,
      :closed,
      :declined,
      :undone
    ]

  attr :actor, :map, default: nil, doc: "who acted, a person; none for Qory's events"
  attr :at, :any, required: true, doc: "when"
  attr :external_ref, :string, default: nil, doc: "`:taken_in`: the ticket's ref"
  attr :url, :string, default: nil, doc: "`:taken_in`: the ticket's page at the source"
  attr :integration, :string, required: true, doc: "the integration's name, beside the ref"
  attr :owner, :map, default: nil, doc: "`:taken_in`, `:proposed`: who owns it, a person"
  attr :first_instruction, :string, default: nil, doc: "`:taken_in`: the first instruction"
  attr :again, :boolean, default: false, doc: "`:taken_in`: whether it was taken in again"
  attr :start, :atom, default: nil, values: [nil, :answers, :again], doc: "`:started`: how"
  attr :run, :map, default: nil, doc: "the run, as above"
  attr :questions, :list, default: [], doc: "`:asked`, `:answered`: the questions, as above"
  attr :duration, :string, default: nil, doc: "`:asked`, `:proposed`: how long the run took"

  attr :outcome, :atom,
    default: :error,
    values: [:error, :none, :refused],
    doc: "`:no_result`: why the run gave none"

  attr :changed, :boolean, default: false, doc: "`:confirmed`: with the member's changes"

  attr :stage, :atom,
    default: :confirm,
    values: [:explore, :confirm],
    doc: "`:declined`: where"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def thread_event(%{kind: :proposed, owner: nil} = assigns), do: ~H""

  def thread_event(assigns) do
    now = now(assigns)

    assigns =
      assign(assigns,
        line: event_line(assigns),
        tag:
          assigns.kind == :started &&
            gettext("Run %{attempt} of %{of}",
              attempt: Format.number(assigns.run.attempt),
              of: Format.number(assigns.run.of)
            ),
        qory: assigns.kind in [:started, :asked, :proposed],
        bad: assigns.kind in [:no_result, :lost, :cancelled],
        at_words: time_tag(assigns.at, Format.relative(assigns.at, now)),
        href: if(out?(assigns.url), do: assigns.url),
        instruction: assigns.kind == :taken_in && instruction(assigns.first_instruction)
      )

    ~H"""
    <li id={@id} class="q-wi-ev">
      <span class="q-wi-ev-ic" aria-hidden="true">
        <.bee :if={@qory} class="q-bl-bee q-bl-bee-lg" />
        <span :if={!@qory} class={@bad && "q-wi-ev-bad"}>
          <.icon name={event_icon(@kind)} class="size-3" />
        </span>
      </span>
      <div>
        <p>
          <.rich text={@line}>
            <:part name={:ref}>
              <span class="q-wi-ev-ref">
                <BacklogComponents.integration_tile name={@integration} />
                <.external_link href={@href}>{@external_ref}</.external_link>
              </span>
            </:part>
          </.rich>
          <span :if={@tag} class="q-wi-tag">{@tag}</span>
          <span class="q-wi-when">{@at_words}</span>
        </p>
        <p :if={@instruction} class="q-wi-q">
          {gettext("First instruction: %{text}", text: @instruction)}
        </p>
        <ol :if={@kind == :asked} id={"#{@id}-questions"} class="q-wi-qs">
          <li :for={question <- @questions} phx-no-format>{question.text}</li>
        </ol>
        <div :if={@kind == :answered} id={"#{@id}-answers"} class="q-wi-qa">
          <div :for={question <- @questions}>
            <div class="q-wi-qa-q" phx-no-format>{question.text}</div>
            <div class="q-wi-qa-a" phx-no-format>{question.answer}</div>
          </div>
        </div>
      </div>
    </li>
    """
  end

  defp event_icon(:taken_in), do: "hero-arrow-down-tray-micro"
  defp event_icon(:answered), do: "hero-chat-bubble-left-right-micro"
  defp event_icon(:no_result), do: "hero-exclamation-triangle-micro"
  defp event_icon(:lost), do: "hero-signal-slash-micro"
  defp event_icon(:cancelled), do: "hero-stop-circle-micro"
  defp event_icon(:explore_again), do: "hero-arrow-path-micro"
  defp event_icon(:confirmed), do: "hero-check-micro"
  defp event_icon(:closed), do: "hero-x-circle-micro"
  defp event_icon(:declined), do: "hero-minus-circle-micro"
  defp event_icon(:undone), do: "hero-arrow-uturn-left-micro"

  defp event_line(%{kind: :taken_in, again: true, actor: actor, owner: owner}) do
    ref = {:part, :ref}
    name = {:b, actor.name}
    other_owner = owner && !same_person?(owner, actor) && owner

    cond do
      !other_owner and you?(actor) ->
        rich_gettext("You took this in again from %{ref}", ref: ref)

      !other_owner ->
        rich_gettext("%{name} took this in again from %{ref}", name: name, ref: ref)

      you?(actor) ->
        rich_gettext("You took this in again from %{ref}. %{owner} owns it",
          ref: ref,
          owner: {:b, other_owner.name}
        )

      you?(other_owner) ->
        rich_gettext("%{name} took this in again from %{ref}. You own it", name: name, ref: ref)

      true ->
        rich_gettext("%{name} took this in again from %{ref}. %{owner} owns it",
          name: name,
          ref: ref,
          owner: {:b, other_owner.name}
        )
    end
  end

  defp event_line(%{kind: :taken_in, actor: actor, owner: owner}) do
    ref = {:part, :ref}
    name = {:b, actor.name}
    other_owner = owner && !same_person?(owner, actor) && owner

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

  defp event_line(%{kind: :started, start: :answers, run: run}),
    do:
      rich_gettext("Qory started Explore again, with the answers, in run %{run}",
        run: run_ref(run)
      )

  defp event_line(%{kind: :started, start: :again, run: run}),
    do: rich_gettext("Qory started Explore again in run %{run}", run: run_ref(run))

  defp event_line(%{kind: :started, run: run}),
    do: rich_gettext("Qory started Explore in run %{run}", run: run_ref(run))

  defp event_line(%{kind: :asked, questions: questions, duration: duration}) do
    n = length(questions)

    ngettext(
      "Qory asked %{number} question, after %{duration}",
      "Qory asked %{number} questions, after %{duration}",
      n,
      number: Format.number(n),
      duration: duration
    )
  end

  defp event_line(%{kind: :answered, actor: actor, questions: questions}) do
    n = length(questions)

    if you?(actor),
      do: ngettext("You answered Qory's question", "You answered Qory's questions", n),
      else:
        rich_ngettext("%{name} answered Qory's question", "%{name} answered Qory's questions", n,
          name: {:b, actor.name}
        )
  end

  defp event_line(%{kind: :proposed, owner: owner, duration: duration}) do
    if you?(owner),
      do:
        rich_gettext(
          "Qory proposed how to build it, after %{duration}. It waits for you to confirm",
          duration: duration
        ),
      else:
        rich_gettext(
          "Qory proposed how to build it, after %{duration}. It waits for %{name} to confirm",
          duration: duration,
          name: {:b, owner.name}
        )
  end

  defp event_line(%{kind: :no_result, outcome: :none, run: run}),
    do: rich_gettext("Run %{run} ended without a result", run: run_ref(run))

  defp event_line(%{kind: :no_result, outcome: :refused, run: run}),
    do:
      rich_gettext("Run %{run} returned a result that did not pass Qory's check",
        run: run_ref(run)
      )

  defp event_line(%{kind: :no_result, run: run}),
    do:
      rich_gettext("Run %{run} ended with an error, so Explore has no result", run: run_ref(run))

  defp event_line(%{kind: :lost, run: run}),
    do:
      rich_gettext("Run %{run} was lost before it ended, so Explore has no result",
        run: run_ref(run)
      )

  defp event_line(%{kind: :cancelled, run: run}),
    do:
      rich_gettext("Run %{run} was cancelled before it ended, so Explore has no result",
        run: run_ref(run)
      )

  defp event_line(%{kind: :explore_again, actor: actor}) do
    if you?(actor),
      do: gettext("You asked Qory to explore again"),
      else: rich_gettext("%{name} asked Qory to explore again", name: {:b, actor.name})
  end

  defp event_line(%{kind: :confirmed, changed: true, actor: actor}) do
    if you?(actor),
      do: gettext("You changed Qory's proposal and confirmed it. Ready for Shape"),
      else:
        rich_gettext("%{name} changed Qory's proposal and confirmed it. Ready for Shape",
          name: {:b, actor.name}
        )
  end

  defp event_line(%{kind: :confirmed, actor: actor}) do
    if you?(actor),
      do: gettext("You confirmed Qory's proposal. Ready for Shape"),
      else:
        rich_gettext("%{name} confirmed Qory's proposal. Ready for Shape", name: {:b, actor.name})
  end

  defp event_line(%{kind: :closed, actor: actor}) do
    if you?(actor),
      do: gettext("You closed this work item"),
      else: rich_gettext("%{name} closed this work item", name: {:b, actor.name})
  end

  defp event_line(%{kind: :declined, stage: :explore, actor: actor}) do
    if you?(actor),
      do: gettext("You declined this work item at Explore"),
      else: rich_gettext("%{name} declined this work item at Explore", name: {:b, actor.name})
  end

  defp event_line(%{kind: :declined, actor: actor}) do
    if you?(actor),
      do: gettext("You declined this work item at Confirm"),
      else: rich_gettext("%{name} declined this work item at Confirm", name: {:b, actor.name})
  end

  defp event_line(%{kind: :undone, actor: actor}) do
    if you?(actor),
      do: gettext("You undid this, before a run started"),
      else: rich_gettext("%{name} undid this, before a run started", name: {:b, actor.name})
  end

  # The same person: the reader both times, or the same id. Never by name: two people may
  # share one.
  defp same_person?(a, b), do: (you?(a) and you?(b)) or (a[:id] != nil and a[:id] == b[:id])

  # A first instruction, or nil where it is none: missing, empty or blank.
  defp instruction(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp instruction(_none), do: nil

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
