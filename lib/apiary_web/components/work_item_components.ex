defmodule ApiaryWeb.WorkItemComponents do
  # The parts of a work item's page (`/:org/:workspace/work/:number`, its Ticket tab,
  # `…/explore`, its Explore tab, and `…/thread`, its Thread), and the status words and
  # marks the Work items list shares (`ApiaryWeb.WorkItemListComponents`).
  #
  # Every component takes plain assigns: strings, numbers, times and maps with the keys
  # each one's attributes name, never a context's struct, so the page fills them from
  # whatever the work item records give it. A work item is a map with these keys:
  #
  #   * `:number` - the workspace's number for it, which Qory Apiary gives, `88`;
  #   * `:title` - the ticket's title as it was taken in; a test work item's line;
  #   * `:test` - true for a test work item, made from a line a person typed, with no
  #     ticket and no integration: its parts show the mark Test, and no ticket, no
  #     integration and no Take in again;
  #   * `:key` - the ticket's key at the source, such as `"#1204"`, or `nil`: display text
  #     only, shown as it is and never parsed, as the Backlog shows it. Without a key the
  #     pages show none; the ticket's ref at the source is never shown;
  #   * `:url` - the ticket's page at the source, or `nil`;
  #   * `:repository` - the title of the collection that holds the ticket, `"acme/shop"`.
  #     The ticket's full form is this title followed by its key (`"acme/shop#1204"`), or
  #     the title alone without a key (`BacklogComponents.full_form/1`);
  #   * `:status` - at Explore `:queued`, `:running`, `:questions` (Qory wrote some), `:used_up`
  #     (the take in used its runs), `:no_result`, `:lost` or `:cancelled` (its run gave
  #     nothing to show); then `:confirm`, `:shape`, `:closed` or `:undone`;
  #   * `:run` - at Explore and after, its latest run: `:attempt` and `:of` (run 2 of 3),
  #     and once it has one, `:id` (its `rn_` id), `:path`, `:state`, `:outcome`
  #     (`:proposal`, `:questions`, `:error`, `:none` or `:refused`), `:end_cause`,
  #     `:end_detail` and what it gave;
  #   * `:stage` - for an ended work item, the stage it ended at (`:explore`, `:confirm`
  #     or `:shape`); a live one's stage follows from its status;
  #   * `:owner` - a person, or `nil`;
  #   * `:ended_by`, `:ended_at` - who closed or undid it, and when; `nil` for
  #     `:ended_by` where the instance closed it, with `:ended_reason` saying why:
  #     `:adapter_removed`, when its integration was removed, `:last_stage_done`, when its
  #     last stage finished, or `:ticket_closed`, when its ticket closed at the source. A
  #     close by the instance for any other reason, or none, has no words yet: the parts
  #     that name who closed it draw nothing there;
  #   * `:updated_at` - when it last changed.
  #
  # A part that names the ticket takes the words its source has for its items,
  # `item_noun` (`ApiaryWeb.SourceComponents.item/1`): "the bug" for a source that calls
  # them bugs, and "the ticket" where it names none (nil).
  #
  # The page's parts read more of it, each named where it is used. A person is a map with
  # `:id`, Qory Apiary's id of the person, `:name`, `:email`, the address the person's
  # letter is drawn from, or "Former member", and `:you`, true when the person is the
  # reader: a text the reader is the subject of says "you" ("You own it", "Closed by you").
  # Two people are the same person by `:id`, never by name.
  #
  # Every DOM id, `phx-value-*` and path is Qory Apiary's: the work item's number, a
  # comment's `public_id`, a question's `public_id`, a run's number, and the paths the
  # page gives. A source Qory learned from is a link only when it is an https address
  # core allows; any other is its address as text. The ticket's key at the source is
  # text only. The page gives every path (`again_path`, `ticket_path`, the run's `path`);
  # a component builds none.
  #
  # The events a component sends, for the page to handle:
  #
  #   * `"undo"`, `"ask_close"`, `"close"`, `"explore_again"` - with
  #     `phx-value-number`, the work item's number;
  #   * `"answer_draft"`, `"answer"` - the questions form, on change and on submit:
  #     `answers`, a map of each open question's `public_id` to its answer,
  #     `%{"option" => choice, "note" => text}`: the index of the option picked, or
  #     `"own"` for Give your own option, and the text written;
  #   * `"run_with_comments"`, `"confirm"` - the gate's buttons under the proposal;
  #   * `"review_comment"`, `"reply"` - the form pages Add review comment and Reply: `text`,
  #     and for a reply `comment`, the review comment's id;
  #   * `"ask_delete_comment"`, `"delete_comment"` - with `phx-value-comment`, the
  #     comment's `public_id`;
  #   * `"comment"` - the composer's form, its text as `body`;
  #   * `"show_earlier_comments"` - the Ticket tab's earlier comments.
  #
  # A question (close, delete a comment) shows in place while the page says so
  # (`asking`, a comment's `state`); its Cancel and Escape do `cancel`, a path to patch to
  # or a JS command, `JS.push("cancel_question")` unless given.
  #
  # Everything a ticket holds came from an integration and is untrusted, and what a person
  # wrote is too: a component only interpolates it, so HEEx escapes it. A ticket's text
  # and its comments are rendered by `SourceComponents.body/1`, the one renderer that
  # sanitises formatted text. A line the ticket's source sent (its title, its key, its
  # collection's title, a filer's or an author's name, a label) is shown as
  # `Apiary.ExternalText.line/1` gives it, isolated in `<bdi>` where markup can go
  # (`ApiaryWeb.ExternalText.external_text/1`); a title with nothing left to show is none.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.ExternalText
  alias Apiary.Harnesses.Walk
  alias ApiaryWeb.BacklogComponents
  alias ApiaryWeb.HarnessComponents
  alias ApiaryWeb.RunComponents
  alias ApiaryWeb.SourceComponents

  @stages [:explore, :confirm, :shape]
  @ended [:closed, :undone]
  @exploring [:queued, :running, :questions, :used_up, :no_result, :lost, :cancelled]
  @no_result [:no_result, :lost, :cancelled]
  # The end causes of a run that ended before it started: at its claim, because the claim
  # could not form what the run is made from (`Apiary.Dispatches.Handover`), while it
  # waited for its environment image's build, which failed (`Apiary.Environments`), or
  # because its harness walk failed (`Apiary.Harnesses.WalkJob`).
  @unstarted [
    :variables_invalid,
    :ticket_gone,
    :inputs_invalid,
    :target_access_gone,
    :build_failed
  ]
  # The walk's failure codes that `ApiaryWeb.HarnessComponents.public_read_words/2` words.
  @public_read_codes %{
    "not_covered" => :not_covered,
    "too_large" => :too_large,
    "source_unreachable" => :source_unreachable,
    "host_not_allowed" => :host_not_allowed,
    "rate_limited" => :rate_limited,
    "fetch_failed" => :fetch_failed
  }

  # The values a save check's message has (`Apiary.Stacks.Document`), by their name in a
  # failed walk's rule.
  @rule_values %{
    "source" => :source,
    "name" => :name,
    "key" => :key,
    "place" => :place,
    "rule" => :rule,
    "limit" => :limit,
    "ref" => :ref
  }

  # The most UTF-16 units an answer's or a comment's field takes, the unit a browser's
  # `maxlength` counts: twice the most code points the server takes
  # (`Apiary.WorkItems.Proposal`), so no valid text is refused there, and a paste stays
  # well within the socket's frame.
  @answer_units 2 * 2_000

  ## The status and its mark

  @doc """
  A work item's status: its mark and its words, the row's and the meta line's. You confirm
  next is the one strong status (`q-wi-hot`). Questions and a take in that used
  its runs wait for any member who may act: their mark is the reader's with `can_act`,
  another member's without. Questions or a run without a result at the take in's last
  run read as the run limit, here as on the step card and the tab.
  """
  attr :work_item, :map,
    required: true,
    doc: "the work item: `:status`, `:owner`, `:ended_by`, and `:run` (`:of`) at the run limit"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer or confirm"

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
  A status's mark, the one colour of a row: `:todo` (Explore is queued), `:run` (Explore
  is running), `:wait` (waits for the reader), `:wait_other` (waits for another member),
  `:err` (Explore's run gave no result: a red ring), `:ready` (Ready for Shape),
  `:closed` (closed or undone), and on a row of the Closed view under the feature
  `workflow_model`, `:done` (every stage done: an amber ring) and `:stopped` (any other
  end: a grey ring). Decorative: its words are always beside it.
  """
  attr :kind, :atom,
    required: true,
    values: [:todo, :run, :wait, :wait_other, :err, :ready, :closed, :done, :stopped]

  attr :class, :any, default: nil

  def work_item_mark(assigns) do
    ~H"""
    <span class={["q-wi-mk", "q-wi-mk-#{@kind}", @class]} aria-hidden="true"></span>
    """
  end

  @doc false
  def status_words(work_item), do: words_of(at_limit(work_item))

  defp words_of(%{status: :queued}), do: gettext("Explore is queued")
  defp words_of(%{status: :running}), do: gettext("Explore is running")

  defp words_of(%{status: :confirm, owner: owner}) do
    if you?(owner),
      do: gettext("You confirm next"),
      else: gettext("%{name} confirms next", name: owner.name)
  end

  defp words_of(%{status: :questions}), do: gettext("Needs answers")

  defp words_of(%{status: :used_up, run: %{of: of}}),
    do:
      ngettext("Explore used its %{of} run", "Explore used its %{of} runs", of,
        of: Format.number(of)
      )

  # A failed run that wrote a proposal, which the tab shows: the run failed, and Explore
  # did not end without a result.
  defp words_of(%{status: :no_result, run: %{state: :failed, wrote: version}})
       when is_integer(version),
       do: gettext("Explore's run failed")

  defp words_of(%{status: :no_result}), do: gettext("Explore ended without a result")
  defp words_of(%{status: :lost}), do: gettext("Explore's run was lost")
  defp words_of(%{status: :cancelled}), do: gettext("Explore's run was cancelled")
  defp words_of(%{status: :shape}), do: gettext("Ready for Shape")

  defp words_of(%{status: :closed, ended_by: nil} = work_item),
    do: closed_words(work_item[:ended_reason])

  defp words_of(%{status: :closed, ended_by: by}) do
    if you?(by), do: gettext("Closed by you"), else: gettext("Closed by %{name}", name: by.name)
  end

  defp words_of(%{status: :undone, ended_by: by}) do
    if you?(by), do: gettext("Undone by you"), else: gettext("Undone by %{name}", name: by.name)
  end

  @doc false
  def mark(work_item, can_act \\ false),
    do: mark_of(at_limit(work_item), can_act)

  defp mark_of(%{status: :queued}, _can_act), do: :todo
  defp mark_of(%{status: :running}, _can_act), do: :run

  defp mark_of(%{status: :confirm, owner: owner}, _can_act),
    do: if(you?(owner), do: :wait, else: :wait_other)

  defp mark_of(%{status: status}, can_act) when status in [:questions, :used_up],
    do: if(can_act, do: :wait, else: :wait_other)

  defp mark_of(%{status: status}, _can_act) when status in [:no_result, :lost, :cancelled],
    do: :err

  defp mark_of(%{status: :shape}, _can_act), do: :ready
  defp mark_of(%{status: status}, _can_act) when status in [:closed, :undone], do: :closed

  @doc false
  def hot?(%{status: :confirm, owner: owner}), do: you?(owner)
  def hot?(_work_item), do: false

  @doc false
  def you?(%{you: true}), do: true
  def you?(_person), do: false

  # The ticket's title as a page shows it (`Apiary.ExternalText.present/1`): nil for one
  # with nothing left to show, or only whitespace, as for none.
  defp shown_title(title), do: ExternalText.present(title)

  # Whether the instance closed it when its integration was removed.
  defp instance_removed?(work_item), do: work_item[:ended_reason] == :adapter_removed

  # Why the instance closed it, for a close without a person; nil for a reason with no
  # words.
  defp closed_words(:adapter_removed), do: gettext("Closed when its integration was removed")
  defp closed_words(:last_stage_done), do: gettext("Every stage done")
  defp closed_words(:ticket_closed), do: gettext("Closed when its ticket closed")
  defp closed_words(_none), do: nil

  @doc false
  def stage_name(:explore), do: gettext("Explore")
  def stage_name(:confirm), do: gettext("Confirm")
  def stage_name(:shape), do: gettext("Shape")

  @doc false
  # Who owns the work item, as rich text: "You own it", or the owner's letter with the
  # address as its tooltip; `in_link` inside a link or a button, where the letter is no
  # tab stop.
  def owner_phrase(owner, in_link \\ false) do
    if you?(owner),
      do: gettext("You own it"),
      else: rich_gettext("%{name} owns it", name: letter(owner, in_link))
  end

  # A person in a sentence: their first letter, with the address as its tooltip
  # (`ApiaryWeb.CoreComponents.avatar/1`), in the account menu's colour for the reader.
  defp letter(person, in_link) do
    assigns = %{person: person, in_link: in_link}

    ~H|<.avatar email={@person.email} kind={kind(@person)} in_link={@in_link} size="xs" />|
  end

  defp kind(person), do: if(you?(person), do: "self", else: "person")

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
  A work item's header: the ticket's title as it was taken in and the work item's number,
  with the mark Test for a test work item; the meta line, its status, the ticket's key
  with the integration's mark as a link out ("Open %{ref} on %{integration}", with the
  ticket's full form; none for a test work item), and who owns it; More,
  with Copy link and Close work item…, on a work item that has not ended; then the stages
  (`stage_track/1`, or `track` where the page gives it).

  Copy link copies `link`, the work item's address, in the browser (the `CopyToClipboard`
  hook). Close work item… sends `"ask_close"`, and is there only with `can_close`.
  """
  attr :id, :string, default: "work-item-head"
  attr :work_item, :map, required: true, doc: "the work item"

  attr :integration, :string,
    required: true,
    doc: "the integration's name; nil for a test work item"

  attr :link, :string, required: true, doc: "the work item's address, for Copy link"
  attr :can_close, :boolean, default: false, doc: "whether the reader may close it"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer or confirm"

  attr :stage_status, :map,
    default: nil,
    doc: "`:words` and `:mark` in place of the status, under the feature `workflow_model`"

  slot :track,
    doc:
      "the stages in place of `stage_track/1`: the process version's, under the feature `workflow_model`"

  def work_item_header(assigns) do
    work_item = assigns.work_item

    assigns =
      assign(assigns,
        number: work_item.number,
        title: shown_title(work_item.title),
        ended: ended?(work_item),
        href: if(out?(work_item[:url]), do: work_item.url),
        open_title:
          assigns.integration &&
            gettext("Open %{ref} on %{integration}",
              ref: ExternalText.line(BacklogComponents.full_form(work_item)),
              integration: assigns.integration
            )
      )

    ~H"""
    <div id={@id} class="q-wi-top">
      <div class="q-wi-grow">
        <h1 id={"#{@id}-title"} class="q-wi-title outline-none" tabindex="-1">
          <.external_text :if={@title} text={@title} /><span class="q-wi-no">#{@number}</span>
          <.badge :if={@work_item[:test]} class="q-wi-test">{gettext("Test")}</.badge>
        </h1>
        <div class="q-wi-meta-wrap">
          <p id={"#{@id}-meta"} class="q-wi-meta">
            <.work_item_status :if={!@stage_status} work_item={@work_item} can_act={@can_act} />
            <span :if={@stage_status} id={"#{@id}-stage-status"} class="q-wi-st">
              <.work_item_mark kind={@stage_status.mark} />{@stage_status.words}
            </span>
            <span :if={@integration}>
              <.external_link href={@href} class="q-wi-ref" title={@href && @open_title}>
                <BacklogComponents.integration_tile name={@integration} /><.external_text text={
                  @work_item[:key]
                } />
              </.external_link>
            </span>
            <span><.rich text={owner_phrase(@work_item.owner)} /></span>
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
    <.stage_track :if={@track == []} id={"#{@id}-stages"} work_item={@work_item} />
    {render_slot(@track)}
    """
  end

  @doc """
  The stages, Explore, Confirm and Shape, in order: those before the work item's stage
  done, its stage the current step (`aria-current="step"`), amber while it waits for a
  member: at Confirm, for answers, or at the run limit. An ended work item has no current
  step, and the end mark beside the stages says how it ended: Closed or Undone.
  """
  attr :id, :string, default: "work-item-stages"
  attr :work_item, :map, required: true, doc: "the work item: `:status`, and `:stage` if ended"

  def stage_track(assigns) do
    work_item = at_limit(assigns.work_item)
    at = Enum.find_index(@stages, &(&1 == stage_of(work_item)))
    ended = ended?(work_item)

    stages =
      for {stage, i} <- Enum.with_index(@stages) do
        state =
          cond do
            i < at -> :done
            i == at and not ended -> :now
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
  defp end_icon(:closed), do: "hero-x-circle-micro"

  defp end_word(:undone), do: gettext("Undone")
  defp end_word(:closed), do: gettext("Closed")

  ## The step card

  @doc """
  What the work item needs now, from whom: one card, with at most one primary button, for
  a live work item; nothing for an ended one.

    * Explore, queued, the first run of a take in: what Explore does when the run
      starts, with the run's icon; who took it in and when (the work item's
      `:taken_in_by` and `:taken_in_at`). With `can_undo`, that the reader can undo this until a run starts,
      Undo (`"undo"`), and what undoing does: a first take in's, or an undone work item's
      taken in again, takes Qory's label off the ticket; a closed one's taken
      in again (`previous`) goes back to closed, and nothing is sent to the
      ticket. After the integration's uninstall (`uninstalled`), that nothing changes on
      the ticket, which keeps Qory's label and comment.
    * Explore, queued, a later run (`:run`, `%{attempt:, of:, answers_by:}`): what Explore
      reads, with whose answers, and which run of the take in is queued. No Undo.
    * Explore, running: what Explore reads, with whose answers from a second run (`:run`,
      `%{attempt:, answers_by:}`).
    * Explore, questions (`:questions`): with `can_act`, that answering the questions runs
      Explore again, and Answer the questions (a link to Explore's tab, `explore_path`,
      where it is given); without, that a member answers next.
    * Explore, no result (`:no_result`, `:lost`, `:cancelled`): what happened to the run;
      with `can_act`, Run Explore again (`"explore_again"`), which starts the next run of
      the take in.
    * Explore, the run limit (`:used_up`, and questions or no result at the take in's
      last run): that the take in used its runs, and why Qory cannot explore again; with
      `can_act`, the way on and, with `can_close`, Close work item… (`"ask_close"`).
    * Confirm: the proposal waits; with `can_act`, what to do and Read the proposal
      (`explore_path`), where the gate under the proposal is (`explore_tab/1`).
      Without `can_act`, whose turn it is: the work item's `:owner`, by name, or "you"
      where the owner is the reader.
    * Shape: who confirmed the proposal and when (`:confirmed_by`, `:confirmed_at`).

  While its ticket's repository keeps its tickets out of the Backlog (`backlog_off`),
  Take in again cannot be reached there, so no line says it can.

  A test work item (`:test`) has no ticket: its lines say nothing of one.

  `:run` is the latest run of the take in: `:attempt` (its place, from 1) and `:of` (the
  most a take in has), `:id` and `:path`, `:started_at`, `:answers_by` (the members whose
  answers it reads, people), `:questions` (what it asked, a list) and `:outcome` (`:error`,
  `:none` or `:refused` for a run without a result; `:questions` for one that asked).

  Undo is there only with `can_undo`; Run Explore again only with `can_act`.
  """
  attr :id, :string, default: "work-item-step"
  attr :work_item, :map, required: true, doc: "the work item"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"

  attr :backlog_off, :boolean,
    default: false,
    doc:
      "whether the Backlog leaves its ticket out while its repository is assigned there: its switch is off, or it has no items (`Apiary.WorkItems.backlog_off/2`)"

  attr :can_undo, :boolean, default: false, doc: "whether the reader may undo the take in"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer, confirm, close at the run limit, or run Explore again"

  attr :can_close, :boolean, default: false, doc: "whether the reader may close it"

  attr :previous, :atom,
    default: nil,
    values: [nil, :closed, :undone],
    doc: "how the work item ended before it was taken in again; nil for a first take in"

  attr :explore_path, :string,
    default: nil,
    doc: "Explore's tab, linked from the Ticket and Thread tabs; nil on Explore's tab"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  slot :badge,
    doc:
      "the state in place of the step's badge: the stage's, where the card is the stage's one card at Explore under the feature `workflow_model`"

  attr :stage_name, :string,
    default: nil,
    doc: "the stage's name in place of the step's, where the card is the stage's one card"

  def step_card(%{work_item: %{status: status}} = assigns) when status in @ended, do: ~H""

  def step_card(assigns) do
    work_item = at_limit(assigns.work_item)
    status = work_item.status

    assigns =
      assign(assigns,
        now: now(assigns),
        number: work_item.number,
        status: status,
        stage: stage_of(work_item),
        mark: mark(work_item, assigns.can_act),
        mine: hot?(work_item),
        # Orange while Explore runs too, as concept A draws the card in every state.
        ask:
          hot?(work_item) or status in [:queued, :running] or
            (status in [:questions, :used_up] and assigns.can_act),
        run: work_item[:run],
        item: SourceComponents.item(assigns.item_noun)
      )

    ~H"""
    <section
      id={@id}
      class={["q-wi-step", @ask && "q-wi-step-ask"]}
      aria-labelledby={"#{@id}-h"}
    >
      <div class="q-wi-step-h">
        <.work_item_mark kind={@mark} />
        <h2 id={"#{@id}-h"}>{@stage_name || stage_name(@stage)}</h2>
        <.step_badge :if={@badge == []} status={@status} mine={@mine} run={@run} />
        {render_slot(@badge)}
      </div>
      <.step_body
        id={@id}
        work_item={@work_item}
        run={@run}
        status={@status}
        number={@number}
        integration={@integration}
        uninstalled={@uninstalled}
        backlog_off={@backlog_off}
        can_undo={@can_undo}
        can_act={@can_act}
        can_close={@can_close}
        previous={@previous}
        explore_path={@explore_path}
        item={@item}
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
    do: ~H|<.badge color="warning" class="q-wi-badge">{gettext("Needs answers")}</.badge>|

  defp step_badge(%{status: :used_up} = assigns) do
    ~H"""
    <.badge color="warning" class="q-wi-badge">
      {ngettext("%{attempt} of %{of} attempt used", "%{attempt} of %{of} attempts used", @run.of,
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
    do: ~H|<.badge color="warning" class="q-wi-badge">{gettext("Your turn")}</.badge>|

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
  attr :backlog_off, :boolean, required: true
  attr :can_undo, :boolean, required: true
  attr :can_act, :boolean, required: true
  attr :can_close, :boolean, required: true
  attr :previous, :atom, required: true
  attr :explore_path, :string, required: true
  attr :item, :string, required: true, doc: "the source's word for one of its items"
  attr :now, :any, required: true

  # A later run of the take in: what it reads, with whose answers, and which run is
  # queued. Undo is only until the first run of a take in starts.
  defp step_body(%{status: :queued, run: %{attempt: attempt}} = assigns) when attempt > 1 do
    run = assigns.run

    assigns =
      assign(assigns,
        line:
          case test_line(assigns) || answers_of(run[:answers_by]) do
            line when is_binary(line) ->
              line

            :none ->
              gettext(
                "When the run starts, Explore reads the %{item} and writes a proposal.",
                item: assigns.item
              )

            :you ->
              gettext(
                "When the run starts, Explore reads the %{item} and your answers, and writes a proposal.",
                item: assigns.item
              )

            {:name, name} ->
              gettext(
                "When the run starts, Explore reads the %{item} and the answers of %{name}, and writes a proposal.",
                name: name,
                item: assigns.item
              )

            :several ->
              gettext(
                "When the run starts, Explore reads the %{item} and the answers of this take in, and writes a proposal.",
                item: assigns.item
              )
          end,
        queued: gettext("Attempt %{attempt} is queued.", attempt: Format.number(run.attempt))
      )

    ~H"""
    <p class="q-wi-icon-line"><.run_icon /><span>{@line}</span></p>
    <p id={"#{@id}-run"}>{@queued}</p>
    """
  end

  defp step_body(%{status: :queued} = assigns) do
    assigns =
      assign(assigns,
        undo_line: undo_line(assigns),
        line:
          test_line(assigns) ||
            gettext(
              "When the run starts, Explore reads the %{item} and writes a proposal.",
              item: assigns.item
            )
      )

    ~H"""
    <p class="q-wi-icon-line"><.run_icon /><span>{@line}</span></p>
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
          case test_line(assigns) || answers_of(run[:answers_by]) do
            line when is_binary(line) ->
              line

            :none ->
              gettext(
                "Explore reads the %{item} and writes a proposal.",
                item: assigns.item
              )

            :you ->
              gettext(
                "Explore reads the %{item} and your answers, and writes a proposal.",
                item: assigns.item
              )

            {:name, name} ->
              gettext(
                "Explore reads the %{item} and the answers of %{name}, and writes a proposal.",
                name: name,
                item: assigns.item
              )

            :several ->
              gettext(
                "Explore reads the %{item} and the answers of this take in, and writes a proposal.",
                item: assigns.item
              )
          end
      )

    ~H"""
    <p id={"#{@id}-line"}>{@line}</p>
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
                "Answer the question, and Explore runs again with your answer.",
                "Answer the %{number} questions, and Explore runs again with your answers.",
                n,
                number: number
              )
          ),
        waits:
          ngettext(
            "Next, a member answers the question.",
            "Next, a member answers the questions.",
            n
          ),
        go: ngettext("Answer the question", "Answer the questions", n)
      )

    ~H"""
    <p :if={@line} id={"#{@id}-line"}>{@line}</p>
    <p :if={!@can_act} id={"#{@id}-waits"} class="q-wi-reader">{@waits}</p>
    <.go_link :if={@can_act} id={"#{@id}-explore"} path={@explore_path} words={@go} />
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
                "%{number} question is still open after attempt %{attempt} of %{of}, the last attempt of this take in.",
                "%{number} questions are still open after attempt %{attempt} of %{of}, the last attempt of this take in.",
                length(run.questions),
                number: Format.number(length(run.questions)),
                attempt: Format.number(run.attempt),
                of: Format.number(run.of)
              ),
            else: run[:id] && used_up_line(run)
          )
      )

    ~H"""
    <p :if={@line} id={"#{@id}-line"}><.rich text={@line} /></p>
    <p :if={@can_act && @backlog_off} id={"#{@id}-ways"}>
      {gettext("Close the work item if it is not wanted.")}
    </p>
    <p :if={@can_act && !@backlog_off} id={"#{@id}-ways"}>
      {gettext(
        "To explore again, close the work item and use Take in again in the Backlog: the run count starts again, without this take in's answers."
      )}
    </p>
    <div :if={@can_act} class="q-wi-acts">
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
          next_run?(run) &&
            gettext("Run Explore again starts attempt %{attempt}.",
              attempt: Format.number(run.attempt + 1)
            )
      )

    ~H"""
    <p :if={@line} id={"#{@id}-line"}><.rich text={@line} /></p>
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
    </div>
    <p :if={@can_act && @next} id={"#{@id}-next"} class="q-wi-hint">{@next}</p>
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
              gettext("Confirm the proposal, or add review comments and send them.")

            you?(owner) ->
              gettext("You confirm next")

            owner ->
              gettext("%{name} confirms next", name: owner.name)

            true ->
              nil
          end
      )

    ~H"""
    <p :if={@line} id={"#{@id}-line"}>{@line}</p>
    <.go_link
      :if={@can_act}
      id={"#{@id}-explore"}
      path={@explore_path}
      words={gettext("Read the proposal")}
    />
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

  # A test work item's run answers its line, in words that no workspace's words change,
  # while its run waits or runs; nil for any other work item.
  defp test_line(%{work_item: %{test: true}, status: :queued}),
    do: gettext("When the run starts, the agent writes a reply to the line.")

  defp test_line(%{work_item: %{test: true}, status: :running}),
    do: gettext("The agent is writing a reply to the line.")

  defp test_line(_assigns), do: nil

  # What happened to a run that gave no result, as one sentence with its attempt; none
  # for a run that ended before its handover, which has no page to link.
  defp no_result_line(_status, %{id: nil}), do: nil

  defp no_result_line(
         :no_result,
         %{end_cause: :run_refused, end_detail: "model_key_missing"} = run
       ),
       do:
         rich_gettext(
           "Add a model key in Organisation settings › Model providers. The gateway had no model key for attempt %{attempt}.",
           attempt: attempt_ref(run)
         )

  defp no_result_line(:no_result, %{state: :failed, wrote: version}) when is_integer(version),
    do: failed_after(version)

  defp no_result_line(:no_result, run) do
    case run[:outcome] do
      :none ->
        rich_gettext("Attempt %{attempt} ended without a result.", attempt: attempt_ref(run))

      :refused ->
        rich_gettext(
          "Attempt %{attempt} returned a result that did not pass Qory Apiary's check, so Explore has no result.",
          attempt: attempt_ref(run)
        )

      _error ->
        rich_gettext("Attempt %{attempt} ended with an error, so Explore has no result.",
          attempt: attempt_ref(run)
        )
    end
  end

  defp no_result_line(:lost, run),
    do:
      rich_gettext("Attempt %{attempt} was lost before it ended, so Explore has no result.",
        attempt: attempt_ref(run)
      )

  defp no_result_line(:cancelled, run),
    do:
      rich_gettext("Attempt %{attempt} was cancelled before it ended, so Explore has no result.",
        attempt: attempt_ref(run)
      )

  # A failed run that pushed version `version` of the proposal before it failed: the
  # words of the stage's escalation (`Apiary.Stages.StopCause.failed_after_proposal/1`).
  defp failed_after(version),
    do:
      gettext("The run failed after it wrote proposal version %{version}.",
        version: Format.number(version)
      )

  # The take in's last run, which gave no result, as one sentence with its attempt: for a
  # missing model key, the fix first, as `no_result_line/2` puts it.
  defp used_up_line(%{state: :failed, wrote: version}) when is_integer(version),
    do: failed_after(version)

  defp used_up_line(%{end_cause: :run_refused, end_detail: "model_key_missing"} = run),
    do:
      rich_gettext(
        "Add a model key in Organisation settings › Model providers. The gateway had no model key for attempt %{attempt}. That was attempt %{number} of %{of}, the last attempt of this take in.",
        attempt: attempt_ref(run),
        number: Format.number(run.attempt),
        of: Format.number(run.of)
      )

  defp used_up_line(run),
    do:
      rich_gettext(
        "Attempt %{attempt} ended without a result. That was attempt %{number} of %{of}, the last attempt of this take in.",
        attempt: attempt_ref(run),
        number: Format.number(run.attempt),
        of: Format.number(run.of)
      )

  # Who took the work item in and when; for a reader who may undo it, that they can until
  # a run starts and what undoing does to the ticket. After an uninstall, that nothing
  # changes on the ticket. A closed work item taken in again goes back to how
  # it ended, and nothing is sent to the ticket; an undone one taken in again reads as a
  # first take in, since undoing it takes the label off again. A test work item has no
  # ticket, so its line says nothing of one. Each line is one whole sentence for each
  # case.
  defp undo_line(%{work_item: %{test: true} = work_item} = assigns) do
    by = work_item.taken_in_by
    at = inline_ago(work_item.taken_in_at, assigns.now)

    case {you?(by), assigns.can_undo} do
      {true, true} ->
        rich_gettext("You took this in %{when}. Until a run starts, you can undo the take in.",
          when: at
        )

      {true, false} ->
        rich_gettext("You took this in %{when}.", when: at)

      {false, true} ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo the take in.",
          name: by.name,
          when: at
        )

      {false, false} ->
        rich_gettext("%{name} took this in %{when}.", name: by.name, when: at)
    end
  end

  defp undo_line(%{work_item: work_item, previous: :closed, uninstalled: false} = assigns) do
    by = work_item.taken_in_by
    at = inline_ago(work_item.taken_in_at, assigns.now)

    case {you?(by), assigns.can_undo} do
      {true, true} ->
        rich_gettext(
          "You took this in again %{when}. Until a run starts, you can undo the take in: the work item goes back to closed, and Qory Apiary changes nothing on the %{item}.",
          when: at,
          item: assigns.item
        )

      {false, true} ->
        rich_gettext(
          "%{name} took this in again %{when}. Until a run starts, you can undo the take in: the work item goes back to closed, and Qory Apiary changes nothing on the %{item}.",
          name: by.name,
          when: at,
          item: assigns.item
        )

      {true, false} ->
        rich_gettext("You took this in again %{when}.", when: at)

      {false, false} ->
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
          "You took this in %{when}. Until a run starts, you can undo the take in. %{integration} is no longer connected, so nothing changes on the %{item}: it keeps the label and comment of Qory Apiary.",
          when: at,
          integration: integration,
          item: assigns.item
        )

      {true, true, false} ->
        rich_gettext(
          "You took this in %{when}. %{integration} is no longer connected, so nothing changes on the %{item}: it keeps the label and comment of Qory Apiary.",
          when: at,
          integration: integration,
          item: assigns.item
        )

      {true, false, true} ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo the take in. %{integration} is no longer connected, so nothing changes on the %{item}: it keeps the label and comment of Qory Apiary.",
          name: by.name,
          when: at,
          integration: integration,
          item: assigns.item
        )

      {true, false, false} ->
        rich_gettext(
          "%{name} took this in %{when}. %{integration} is no longer connected, so nothing changes on the %{item}: it keeps the label and comment of Qory Apiary.",
          name: by.name,
          when: at,
          integration: integration,
          item: assigns.item
        )

      {false, true, true} ->
        rich_gettext(
          "You took this in %{when}. Until a run starts, you can undo the take in: Qory Apiary removes its label from the %{item} and leaves its comment.",
          when: at,
          item: assigns.item
        )

      {false, true, false} ->
        rich_gettext("You took this in %{when}.", when: at)

      {false, false, true} ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo the take in: Qory Apiary removes its label from the %{item} and leaves its comment.",
          name: by.name,
          when: at,
          item: assigns.item
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

  # A run inside a work item, by its attempt in the take in, as a link to the run's page
  # where the page gives one. The run's number on the server is shown only under Artifacts.
  defp attempt_ref(%{path: path, attempt: attempt}) when is_binary(path),
    do: {:link, path, shown_number(attempt), "q-wi-run"}

  defp attempt_ref(run), do: shown_number(run[:attempt])

  # A run's place in the take in ("Attempt 2"), as a link to the run's page where the
  # page has one.
  defp place_ref(%{path: path}, place) when is_binary(path), do: {:link, path, place, "q-wi-run"}
  defp place_ref(_run, place), do: place

  # An attempt with no number reads n/a.
  defp shown_number(number) when is_integer(number), do: Integer.to_string(number)
  defp shown_number(_number), do: gettext("n/a")

  # The run's icon (`hero-play-circle`, the Runs icon in the left navigation), beside a
  # line about Explore's run. Decorative: the line beside it has the words.
  defp run_icon(assigns) do
    ~H"""
    <.icon name="hero-play-circle" class="q-wi-play size-6" />
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

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

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
            "This work item stays in Qory Apiary. Qory no longer changes anything on the %{item}, and the %{item} is no longer in the Backlog.",
            item: SourceComponents.item(@item_noun)
          )}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The question before Close, in place under the header: what closing does to the ticket,
  or, after the integration's uninstall (`uninstalled`), that nothing changes there; for a
  test work item (`test`), what closing does in Qory Apiary alone; Close work item
  (`"close"`) and Cancel.
  """
  attr :id, :string, default: "work-item-close"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :test, :boolean, default: false, doc: "whether it is a test work item"
  attr :integration, :string, required: true, doc: "the integration's name; nil for a test"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"

  attr :backlog_off, :boolean,
    default: false,
    doc:
      "whether the Backlog leaves its ticket out while its repository is assigned there: its switch is off, or it has no items (`Apiary.WorkItems.backlog_off/2`)"

  attr :cancel, :any, default: nil, doc: "what Cancel does"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

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
        <%= cond do %>
          <% @test -> %>
            {gettext("The work item stays in Qory Apiary, closed.")}
          <% @uninstalled -> %>
            {gettext(
              "%{integration} is no longer connected, so nothing changes on the %{item}. The work item stays in Qory Apiary, closed.",
              integration: @integration,
              item: SourceComponents.item(@item_noun)
            )}
          <% @backlog_off -> %>
            {gettext(
              "The %{item} stays open on %{integration} with Qory's label, and Qory posts nothing more there.",
              integration: @integration,
              item: SourceComponents.item(@item_noun)
            )}
          <% true -> %>
            {gettext(
              "The %{item} stays open on %{integration} with Qory's label, and Qory posts nothing more there. To bring the work item back, use Take in again in the Backlog.",
              integration: @integration,
              item: SourceComponents.item(@item_noun)
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
  The notice of an ended work item: who closed or undid it and when, what that left on the
  ticket, and Take in again, a link to the ticket's panel in the Backlog
  (`again_path`). After the integration's uninstall (`uninstalled`) the ticket is in no
  Backlog, nor while its repository keeps its tickets out of it (`backlog_off`), and a
  test work item has no ticket: the first line alone. Nothing for a live work item.
  """
  attr :id, :string, default: "work-item-ended"
  attr :work_item, :map, required: true, doc: "the work item: `:status`, `:ended_by`, `:ended_at`"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"

  attr :backlog_off, :boolean,
    default: false,
    doc:
      "whether the Backlog leaves its ticket out while its repository is assigned there: its switch is off, or it has no items (`Apiary.WorkItems.backlog_off/2`)"

  attr :again_path, :string, default: nil, doc: "the ticket's panel in the Backlog"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

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
        second:
          !(assigns.uninstalled or assigns.backlog_off or work_item[:test]) &&
            end_second(
              work_item.status,
              assigns.integration,
              SourceComponents.item(assigns.item_noun)
            )
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

  defp end_line(%{status: :closed, ended_by: nil} = work_item, now) do
    if instance_removed?(work_item),
      do:
        rich_gettext(
          "Qory Apiary closed this work item on %{date}, when its integration was removed.",
          date: day(work_item.ended_at, now)
        ),
      else: closed_words(work_item[:ended_reason])
  end

  defp end_line(%{status: :closed, ended_by: by} = work_item, now) do
    date = day(work_item.ended_at, now)

    if you?(by),
      do: rich_gettext("You closed this work item on %{date}.", date: date),
      else: rich_gettext("%{name} closed this work item on %{date}.", name: by.name, date: date)
  end

  defp end_line(%{status: :undone, ended_by: by} = work_item, now) do
    at = inline_ago(work_item.ended_at, now)

    if you?(by),
      do: rich_gettext("You undid the take in %{when}, before a run started.", when: at),
      else:
        rich_gettext("%{name} undid the take in %{when}, before a run started.",
          name: by.name,
          when: at
        )
  end

  defp end_second(:undone, _integration, item),
    do:
      gettext(
        "Qory removed its label from the %{item} and left its comment. To bring the work item back, use Take in again.",
        item: item
      )

  defp end_second(:closed, integration, item),
    do:
      gettext(
        "The %{item} is still open on %{integration} with Qory's label. To bring the work item back, use Take in again.",
        integration: integration,
        item: item
      )

  ## Details

  @doc """
  A work item's facts: who owns it, its ticket (a link out, where the integration sent it
  from, who filed it and when), its collection, labelled with its source's word for one
  (`collection_noun`, `SourceComponents.collection/1`), its first letter in upper case,
  when and by whom it was taken in, its
  first instruction, its runs, and how it ended. From 1440 px a quiet list beside the page
  under its heading; below it, folded behind a button that says who owns it and the
  ticket's key, which opens it in place. A test work item has no ticket and no
  collection: no row and no key for them.

  It reads the work item's `:owner`, `:key`, `:url`, `:repository`,
  `:taken_in_by`, `:taken_in_at`, `:first_instruction` (`nil`, empty or blank for none),
  `:runs` (`nil` for none in the current take in, or `%{latest: %{attempt:, path:}, count:,
  running:}`), `:ended_by`
  and `:ended_at`, and its ticket's filer and when it was filed (`ticket`,
  `%{filer: %{name:}, filed_at:}`).
  """
  attr :id, :string, default: "work-item-details"
  attr :work_item, :map, required: true, doc: "the work item"

  attr :ticket, :map,
    required: true,
    doc: "its ticket: `:filer` and `:filed_at`; nil once its record is gone, with no line"

  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  attr :collection_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its collections, `%{one:, other:}` (`Apiary.Adapters.collection_noun/1`); nil for \"collection\""

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  attr :queued, :string,
    default: nil,
    doc: "Runs' line while a run waits for a machine and none has started, in place of None yet"

  attr :process_version, :integer,
    default: nil,
    doc: "the number of the work item's process version, under the feature `workflow_model`"

  attr :fold, :boolean,
    default: false,
    doc:
      "whether Details stays folded behind its button at every width: while review comments take the rail"

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
          if(work_item[:test],
            do: owner_phrase(owner, true),
            else:
              rich_gettext("%{owner} · %{ref}",
                owner: owner_phrase(owner, true),
                ref: {:part, :ref}
              )
          ),
        instruction: instruction(work_item.first_instruction),
        ticket_line: ticket_line(assigns, now),
        taken_in: by_line(work_item.taken_in_at, work_item.taken_in_by, now),
        ended: ended?(work_item) && ended_row(work_item, now),
        runs: work_item[:runs]
      )

    ~H"""
    <button
      id={"#{@id}-toggle"}
      type="button"
      class={["q-wi-dtoggle", @fold && "q-wi-dfold"]}
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
              <BacklogComponents.integration_tile name={@integration} /><.external_text text={
                @work_item[:key]
              } />
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
          <.avatar email={@owner.email} kind={kind(@owner)} size="xs" />
          <%!-- The letter's hidden text says "(you)" already. --%>
          <span :if={you?(@owner)} class="q-faint" aria-hidden="true">{gettext("(you)")}</span>
        </dd>
        <%= if !@work_item[:test] do %>
          <dt>{SourceComponents.item_label(@item_noun)}</dt>
          <dd id={"#{@id}-ticket"}>
            <span class="q-wi-l1">
              <BacklogComponents.integration_tile name={@integration} />
              <.external_link :if={@work_item[:key]} href={@href} class="q-wi-tkr">
                <.external_text text={@work_item[:key]} />
              </.external_link>
            </span>
            <span :if={@ticket_line} class="q-wi-sub"><.rich text={@ticket_line} /></span>
          </dd>
          <dt>{SourceComponents.collection_label(@collection_noun)}</dt>
          <dd id={"#{@id}-repository"} class="q-mono">
            <.external_text text={@work_item.repository} />
          </dd>
        <% end %>
        <dt>{gettext("Taken in")}</dt>
        <dd id={"#{@id}-taken-in"}><span><.rich text={@taken_in} /></span></dd>
        <dt>{gettext("First instruction")}</dt>
        <dd id={"#{@id}-instruction"}>
          <span :if={@instruction} class="q-wi-q">{@instruction}</span>
          <span :if={!@instruction} class="q-faint">{gettext("None")}</span>
        </dd>
        <%= if @process_version do %>
          <dt>{gettext("Process")}</dt>
          <dd id={"#{@id}-process"}>
            {gettext("Version %{version}", version: Format.number(@process_version))}
          </dd>
        <% end %>
        <dt>{gettext("Runs")}</dt>
        <dd id={"#{@id}-runs"}>
          <span :if={@runs} class="q-wi-runs"><.rich text={runs_line(@runs)} /></span>
          <span :if={!@runs and @queued} id={"#{@id}-runs-queued"}>{@queued}</span>
          <span :if={!@runs and !@queued} class="q-faint">{gettext("None yet")}</span>
        </dd>
        <%= if @ended do %>
          <dt>{elem(@ended, 0)}</dt>
          <dd id={"#{@id}-ended"}><span><.rich text={elem(@ended, 1)} /></span></dd>
        <% end %>
      </dl>
    </section>
    """
  end

  defp ticket_line(%{ticket: nil}, _now), do: nil

  defp ticket_line(%{ticket: ticket, integration: integration, uninstalled: uninstalled}, now) do
    filed = inline_ago(ticket.filed_at, now)

    if uninstalled,
      do:
        rich_gettext(
          "On %{integration}, no longer connected · %{name} filed it %{when}",
          integration: integration,
          name: ExternalText.line(ticket.filer.name),
          when: filed
        ),
      else:
        rich_gettext("On %{integration} · %{name} filed it %{when}",
          integration: integration,
          name: ExternalText.line(ticket.filer.name),
          when: filed
        )
  end

  # How it ended, for Details: its word and when and by whom; a close by the instance
  # with words says why, and one without has no row.
  defp ended_row(%{status: :closed, ended_by: nil} = work_item, now) do
    cond do
      instance_removed?(work_item) ->
        {end_word(:closed),
         rich_gettext("Closed %{when}, when its integration was removed",
           when: day(work_item.ended_at, now)
         )}

      words = closed_words(work_item[:ended_reason]) ->
        {end_word(:closed), words}

      true ->
        nil
    end
  end

  defp ended_row(work_item, now),
    do: {end_word(work_item.status), by_line(work_item.ended_at, work_item.ended_by, now)}

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

    rich_ngettext(
      "Attempt %{attempt} · %{count} run, %{state}",
      "Attempt %{attempt} · %{count} runs, %{state}",
      count,
      attempt: attempt_ref(latest),
      state: state
    )
  end

  ## The tabs

  @doc """
  A work item's tabs: Ticket (`ticket_path`), named with its source's word for its items,
  "Bug" for a source that calls them bugs (`item_noun`), Explore (`explore_path`) and
  Thread (`thread_path`), with the count of people's comments where there are any; named
  "Work item #%{number}". Ticket stays the work item's address. A test work item has no
  ticket (`ticket` false), so no Ticket tab.
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
  attr :ticket, :boolean, default: true, doc: "whether it has a Ticket tab"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  def work_item_tabs(assigns) do
    ~H"""
    <.page_tabs
      id={@id}
      label={gettext("Work item #%{number}", number: @number)}
      current={@current}
    >
      <:tab :if={@ticket} key={:ticket} patch={@ticket_path} icon="hero-document-text">
        {SourceComponents.item_label(@item_noun)}
      </:tab>
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
  Explore's tab (`/work/:number/explore`), top to bottom:

    * while a run is queued or runs: the run line, which run of the take in it is (linked
      to its page), its state and its time, and what the run does next, with whose
      answers from a second run;
    * a run without a result (no result, lost or cancelled): what happened, and the run's
      page; for a run that ended at its claim, before it started (`:end_cause`
      `:variables_invalid`, `:ticket_gone`, `:inputs_invalid` or `:target_access_gone`),
      while it waited for its environment image's build, which failed (`:build_failed`),
      or because its harness walk failed (`:harness_unresolved`, with
      `:harness_failure`), what a member fixes and why; for a run whose harness had no
      skill for its workflow (`:workflow_gap`), that workflow and where the harness came
      from. At the run limit, and with no run after it, Take in again from the Backlog
      starts the count again, unless its ticket's repository keeps its tickets out of the
      Backlog (`backlog_off`);
    * the newest proposal of the take in (`proposal`), with its version, and
      `Add review comment` (`review_path`) while no run runs and the reader may write
      review comments; confirmed, who confirmed it and when (`:confirmed_by`,
      `:confirmed_at`). Below 1440 px the review comments sit at the top of its text
      (`review_comments/1`); from 1440 px the rail has them;
    * at the gate, for a reader who may confirm (`can_act`): Confirm (`"confirm"`), and
      while a review comment is open, Run with comments (`"run_with_comments"`), which
      starts the next run with every open review comment;
    * the questions (`questions`): the closed ones first, each folded to one line, then
      the open ones; with the form for a reader who may answer them (`can_act`, while
      Explore needs answers): for each open question its options, Give your own option,
      and one field; Run with answers (`"answer"`). While a run runs, the open questions
      show as text;
    * one fold of the take in's runs, oldest first, with what each wrote, and the
      `artifacts` slot; then the earlier take ins (`earlier_take_ins`), each folded with
      its runs, which counted apart.

  A run is a map: `:id` (its `rn_` public id) and `:path`, `:attempt` and `:of`, `:state`
  (`:pending`, `:running`, `:completed`, `:failed`, `:cancelled` or `:lost`),
  `:started_at`, `:ended_at`, `:duration` (how long it took, in words), `:outcome`
  (`:proposal`, `:questions`, `:error`, `:none` or `:refused`), `:end_cause`,
  `:end_detail`, `:wrote` (the version of the proposal it pushed, nil for none) with
  `:wrote_proposal` (that version, `%{message:}`), and `:asked` (how many questions it
  wrote).

  A proposal is `%{version:, message:}`, its text Markdown. A question is `%{id:, number:,
  text:, context:, options:, state:, answer:, history:, follows:}` as
  `Apiary.WorkItems.ExploreView` returns it, each answer with `:by`, a person. A review
  comment is as `review_comments/1` takes it.

  A run's proposal and a question's context are untrusted Markdown, shown as
  `ApiaryWeb.ArtifactLive.Markdown.render/2` returns them: raw HTML dropped, http, https
  and mailto links only, headings two levels down. Each map may have that render as
  `:rendered` (`markdown/1`), so the page renders once for what it read; without it, the
  component renders. A question, an option's title and explanation, an answer, a review
  comment and a reply are plain text: escaped, their line breaks kept, isolated from the
  text around them.

  The questions form's draft is `answers` (by question id, each `%{"option" => choice,
  "note" => text}`, the choice an option's place from 1, or `"own"` for Give your own
  option), and `errors` its errors by question id, as `answer_error/1` words them; and
  `form_error`, `:blank` where the form gave no answer, `:stale` where the questions
  changed after the page showed them and no answer was sent. The focus goes to the first
  question at fault, again after each send (`submits`, counted by the page).
  """
  attr :id, :string, default: "work-item-explore"
  attr :work_item, :map, required: true, doc: "the work item, with its latest run as `:run`"
  attr :earlier_runs, :list, default: [], doc: "the take in's earlier runs, oldest first"
  attr :earlier_take_ins, :list, default: [], doc: "the earlier take ins, oldest first"
  attr :proposal, :map, default: nil, doc: "the newest proposal of the take in, or nil"
  attr :questions, :list, default: [], doc: "every question of the newest questions"
  attr :questions_version, :integer, default: nil, doc: "the newest questions' version"
  attr :review_comments, :list, default: [], doc: "the review comments on its proposals"
  attr :can_act, :boolean, default: false, doc: "whether the reader may answer or confirm"

  attr :review_path, :string,
    default: nil,
    doc: "Add review comment's page, where the reader may write review comments now; else nil"

  attr :reply_path, :any,
    default: nil,
    doc: "a function of a review comment's id: Reply's page, where the reader may reply now"

  attr :backlog_off, :boolean,
    default: false,
    doc:
      "whether the Backlog leaves its ticket out while its repository is assigned there: its switch is off, or it has no items (`Apiary.WorkItems.backlog_off/2`)"

  attr :answers, :map, default: %{}, doc: "the questions form's draft, by question id"
  attr :errors, :map, default: %{}, doc: "the questions form's errors, by question id"

  attr :form_error, :atom,
    default: nil,
    doc:
      "`:blank` where the form gave no answer, `:stale` where the questions changed after the page showed them"

  attr :submits, :integer,
    default: 0,
    doc: "how many times the form was sent; the focus goes to the first error after each"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  slot :artifacts, doc: "the work item's artifacts, in the fold of its runs"

  def explore_tab(assigns) do
    work_item = at_limit(assigns.work_item)
    status = work_item.status
    run = work_item[:run]
    view = explore_view(status, run)
    running = view == :wait
    open = Enum.count(assigns.review_comments, &(&1.state == :open))

    assigns =
      assign(assigns,
        now: now(assigns),
        status: status,
        run: run,
        view: view,
        running: running,
        groups: Enum.filter(assigns.earlier_runs, &answered?/1),
        confirmed:
          status == :shape &&
            %{by: work_item.confirmed_by, at: work_item.confirmed_at},
        mode: if(status == :questions and assigns.can_act, do: :form, else: :read),
        gate: status == :confirm and assigns.can_act,
        open_comments: open,
        # The latest run, where it is one: a run not yet queued has no workspace.
        latest: run && run[:workspace_id] && run,
        item: SourceComponents.item(assigns.item_noun)
      )

    ~H"""
    <div id={@id} class="q-xp">
      <.run_line :if={@running} id={"#{@id}-run"} run={@run} now={@now} />
      <.explore_wait
        :if={@running}
        id={"#{@id}-wait"}
        status={@status}
        run={@run}
        groups={@groups}
        item={@item}
        test={@work_item[:test] == true}
      />
      <.no_result :if={@view == :no_result} id={"#{@id}-none"} run={@run} />
      <.proposal_frame
        :if={@proposal}
        id={"#{@id}-proposal"}
        run={%{proposal: @proposal, version: @proposal.version, attempt: @run[:attempt]}}
        confirmed={@confirmed}
        review_path={!@running && @review_path}
        now={@now}
      >
        <:comments :if={@review_comments != []}>
          <.review_comments
            id={"#{@id}-proposal-review"}
            comments={@review_comments}
            reply_path={!@running && @reply_path}
            reading={@running && @run[:attempt]}
          />
        </:comments>
      </.proposal_frame>
      <.gate
        :if={@gate}
        id={"#{@id}-gate"}
        number={@work_item.number}
        open={if @review_path, do: @open_comments, else: 0}
      />
      <.questions_frame
        :if={@questions != []}
        id={"#{@id}-questions"}
        number={@work_item.number}
        questions={@questions}
        mode={@mode}
        running={@running}
        answers={@answers}
        errors={@errors}
        form_error={@form_error}
        submits={@submits}
        now={@now}
      />
      <.record
        :if={@earlier_runs != [] or @latest != nil or @artifacts != []}
        id="work-item-record"
        runs={@earlier_runs ++ List.wrap(@latest)}
        latest={@latest}
        proposal={@proposal}
        questions_version={@questions_version}
        item={@item}
        now={@now}
      >
        {render_slot(@artifacts)}
      </.record>
      <.earlier_take_ins
        :if={@earlier_take_ins != []}
        id={"#{@id}-take-ins"}
        take_ins={@earlier_take_ins}
        item={@item}
        now={@now}
      />
    </div>
    """
  end

  # Questions or a run without a result at the take in's last run is the run limit: no
  # run can follow it. Answers queue the next run at any count, so questions are not.
  # Every part that reads the status (its words, its mark, the stages, the step, the tab)
  # reads it through this, so one work item reads the same everywhere.
  defp at_limit(%{status: status, run: run} = work_item)
       when status in @no_result and is_map(run) do
    if next_run?(run), do: work_item, else: %{work_item | status: :used_up}
  end

  defp at_limit(work_item), do: work_item

  defp next_run?(%{attempt: attempt, of: of}) when is_integer(attempt) and is_integer(of),
    do: attempt < of

  defp next_run?(_run), do: true

  defp explore_view(status, _run) when status in [:queued, :running], do: :wait
  defp explore_view(_status, nil), do: nil
  defp explore_view(_status, %{outcome: outcome}) when outcome in [:proposal, :questions], do: nil
  defp explore_view(_status, _run), do: :no_result

  defp answered?(run), do: run[:outcome] == :questions and run[:answered_by] != nil

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :now, :any, required: true

  # Which run of the take in, as a link to its page, its state, its time. Before a run
  # exists, and while it is pending, it is Queued, Explore's word.
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
      <span><b><.rich text={place_ref(@run, @place)} /></b></span>
      <span class={@state_class}>{@state_word}</span>
      <span :if={@time}><.rich text={@time} /></span>
    </p>
    """
  end

  defp run_place(run), do: gettext("Attempt %{attempt}", attempt: Format.number(run.attempt))

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
  attr :item, :string, required: true, doc: "the source's word for one of its items"
  attr :test, :boolean, default: false, doc: "whether it is a test work item"

  # Queued or running: what the run does next, with whose answers. A test work item's
  # run writes a reply to its line, in words that no workspace's words change.
  defp explore_wait(assigns) do
    run = assigns.run
    whose = answers_of(Enum.map(assigns.groups, & &1.answered_by))
    attempt = Format.number(run.attempt)

    {heading, line} =
      case {assigns.status, whose} do
        {:queued, _whose} when assigns.test ->
          {gettext("Explore is queued."),
           gettext(
             "Attempt %{attempt} starts when the workspace's pool takes it. The agent writes a reply to the line.",
             attempt: attempt
           )}

        {:running, _whose} when assigns.test ->
          {gettext("Explore is running."),
           gettext("In attempt %{attempt}, the agent writes a reply to the line.",
             attempt: attempt
           )}

        {:queued, :none} ->
          {gettext("Explore is queued."),
           gettext(
             "Attempt %{attempt} starts when the workspace's pool takes it. It reads the %{item}, then writes a proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}

        {:queued, whose} ->
          {queued_heading(whose),
           gettext(
             "Attempt %{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest proposal and the questions with their answers.",
             attempt: attempt,
             item: assigns.item
           )}

        {:running, :none} ->
          {gettext("Explore is running."),
           gettext(
             "Attempt %{attempt} reads the %{item}, then writes a proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}

        {:running, :you} ->
          {running_heading(:you),
           gettext(
             "Attempt %{attempt} reads the %{item}, the newest proposal and the questions with your answers, then writes the next proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}

        {:running, whose} ->
          {running_heading(whose),
           gettext(
             "Attempt %{attempt} reads the %{item}, the newest proposal and the questions with their answers, then writes the next proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}
      end

    assigns = assign(assigns, heading: heading, line: line)

    ~H"""
    <div id={@id} class="q-xp-wait">
      <.icon name="hero-arrow-path" class="q-xp-wait-i size-5" />
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

  defp running_heading(:you), do: gettext("Explore is running again, with your answers.")

  defp running_heading({:name, name}),
    do: gettext("Explore is running again, with the answers of %{name}.", name: name)

  defp running_heading(:several),
    do: gettext("Explore is running again, with the answers of this take in.")

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
          <.run_text value={question} key={:text} />
          <div class="q-xp-ans" phx-no-format>{question.answer}</div>
        </div>
      </li>
    </ol>
    """
  end

  attr :id, :string, default: nil
  attr :value, :map, required: true, doc: "a map with `:rendered`, or with the text under `key`"
  attr :key, :atom, required: true, doc: "where `value` has the text without `:rendered`"

  attr :images, :any,
    default: nil,
    doc: "a proposal version's images, as `markdown/2` takes them; nil for none known"

  # A run's Markdown text: formatted, or as written where the renderer does not format it;
  # nothing for none. With `images`, even empty, the text is rendered here with them, in
  # place of `:rendered`.
  defp run_text(assigns) do
    assigns = assign(assigns, :rendered, rendered(assigns.value, assigns.key, assigns.images))

    ~H"""
    <%= case @rendered do %>
      <% {:html, html} -> %>
        <div id={@id} class="q-ticket-formatted q-xp-md">{html}</div>
      <% {:as_written, written} -> %>
        <div id={@id} class="q-xp-md grid gap-2">
          <p class="q-xp-md-note">{gettext("Shown as written.")}</p>
          <div class="q-ticket-written" phx-no-format>{written}</div>
        </div>
      <% _none -> %>
    <% end %>
    """
  end

  defp rendered(%{} = value, key, images) when images != nil,
    do: markdown(Map.get(value, key), images)

  defp rendered(%{rendered: rendered}, _key, _images), do: rendered
  defp rendered(%{} = value, key, _images), do: markdown(Map.get(value, key))
  defp rendered(_value, _key, _images), do: nil

  @doc false
  # markdown/2 is a run's Markdown text, a proposal's or a question's, as the work item
  # pages show it (`ApiaryWeb.ArtifactLive.Markdown.render/2`), with a proposal version's
  # `images`, pairs of a filename and its download address, nil for none known (as
  # `ApiaryWeb.ArtifactLive.Markdown.render/2` takes them): `{:html, safe}`, or
  # `{:as_written, text}` for a text the renderer does not format, or one past its bounds,
  # which a page interpolates; nil for no text. A contract's text is at most 128 KiB,
  # within the renderer's bounds.
  @spec markdown(term, Enumerable.t() | nil) ::
          {:html, Phoenix.HTML.safe()} | {:as_written, String.t()} | nil
  def markdown(text, images \\ nil)

  def markdown(text, images) when is_binary(text) do
    case ApiaryWeb.ArtifactLive.Markdown.render(text, images) do
      :too_large -> {:as_written, text}
      rendered -> rendered
    end
  end

  def markdown(_text, _images), do: nil

  @sources_heading "<h4>Sources</h4>"
  @void_tags ~w(br hr img input wbr)

  @doc false
  # split_sources/1 is a rendered proposal split at its Sources: the last `## Sources`
  # heading at the top level of the text, which the renderer draws as
  # `<h4>Sources</h4>`; a heading inside a quote or a list is part of the text.
  # `{body, sources, count}`: the render before the heading, the HTML after it, and the
  # number of items of its first-level lists; `{rendered, nil, 0}` for a proposal
  # without the heading, and for one shown as written.
  @spec split_sources(term) :: {term, Phoenix.HTML.safe() | nil, non_neg_integer}
  def split_sources({:html, html}) do
    string = Phoenix.HTML.safe_to_string(html)

    case top_sources(string) do
      nil ->
        {{:html, html}, nil, 0}

      at ->
        from = at + byte_size(@sources_heading)
        rest = binary_part(string, from, byte_size(string) - from)
        {{:html, {:safe, binary_part(string, 0, at)}}, {:safe, rest}, top_items(rest)}
    end
  end

  def split_sources(rendered), do: {rendered, nil, 0}

  # The byte offset of the last `<h4>Sources</h4>` of rendered HTML that no other element
  # contains; nil for none. Text is escaped by the renderer and every attribute value is
  # in double quotes with its `"` escaped, so each `<` outside a quoted value starts a
  # tag.
  defp top_sources(html) do
    ~r{<(/?)([a-zA-Z][a-zA-Z0-9]*)(?:[^>"]|"[^"]*")*>}
    |> Regex.scan(html, return: :index)
    |> Enum.reduce({0, nil}, fn [{at, _whole}, {_slash, slash}, {name_at, name_length}],
                                {depth, last} ->
      name = html |> binary_part(name_at, name_length) |> String.downcase()

      cond do
        name in @void_tags -> {depth, last}
        slash == 1 -> {max(depth - 1, 0), last}
        depth == 0 and heading_at?(html, at) -> {1, at}
        true -> {depth + 1, last}
      end
    end)
    |> elem(1)
  end

  defp heading_at?(html, at) do
    size = byte_size(@sources_heading)
    byte_size(html) - at >= size and binary_part(html, at, size) == @sources_heading
  end

  # The items of the first-level lists of rendered HTML. Text and code are escaped by the
  # renderer, so every `<ul`, `<ol` and `<li` is a tag.
  defp top_items(html) do
    ~r{<(/?)(ul|ol|li)\b}
    |> Regex.scan(html)
    |> Enum.reduce({0, 0}, fn
      [_tag, "", list], {depth, n} when list in ["ul", "ol"] -> {depth + 1, n}
      [_tag, "/", list], {depth, n} when list in ["ul", "ol"] -> {max(depth - 1, 0), n}
      [_tag, "", "li"], {1, n} -> {1, n + 1}
      _other, acc -> acc
    end)
    |> elem(1)
  end

  attr :id, :string, required: true

  attr :run, :map,
    required: true,
    doc: "`:proposal` (`%{message:}`, with `:rendered`), `:version`, and the run's `:attempt`"

  attr :confirmed, :any, default: nil
  attr :now, :any, required: true

  attr :images, :any,
    default: nil,
    doc: "the proposal version's images, filename and download address; nil if not known"

  attr :review_path, :any,
    default: nil,
    doc: "Add review comment's page; nil or false for no link"

  attr :level, :string,
    default: "h2",
    values: ~w(h2 h3 h4),
    doc: "the heading's level: one lower inside a fold than the frames of the tab"

  slot :comments, doc: "the review comments, at the top of the text below 1440 px"

  @doc false
  # proposal_frame/1 is the proposal, in a frame with its version, and Add review comment
  # where `review_path` is given; confirmed, who confirmed it. A result stored before the
  # proposal was Markdown has no text: the frame shows none. The text shows the version's
  # `images` (PNG, JPEG, GIF, WebP and SVG files only, `image_files/1`), and a reference
  # to a file of none of them as "Image not in this version"; with `images` nil, the
  # version's files are not known, and an image is its words. It draws its Mermaid
  # diagrams in the browser (`assets/js/hooks/mermaid.js`); its block has an id of the
  # version and is left alone by later patches (`phx-update="ignore"`), so the drawings of
  # the hook stay and a new version is drawn again. Its Sources, the list under its last
  # `## Sources` heading, are in a fold at the foot of the frame, closed
  # (`split_sources/1`).
  def proposal_frame(assigns) do
    proposal = assigns.run[:proposal] || %{}
    text? = proposal[:rendered] != nil or is_binary(proposal[:message])

    {body, sources, count} =
      if text?,
        do: split_sources(rendered(proposal, :message, image_files(assigns.images))),
        else: {nil, nil, 0}

    assigns =
      assign(assigns,
        body: %{rendered: body},
        sources: sources,
        count: count,
        text?: text?,
        caption: proposal_caption(assigns.run, assigns.confirmed, assigns.now)
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-document-text" class="q-xp-frame-i size-4" />
        <.dynamic_tag tag_name={@level} id={"#{@id}-h"} class="q-xp-frame-t">
          {gettext("Proposal")}
        </.dynamic_tag>
        <.badge :if={@confirmed} color="info" class="q-xp-frame-b">{gettext("Confirmed")}</.badge>
        <.link
          :if={@review_path}
          id={"#{@id}-review-add"}
          patch={@review_path}
          class="q-xp-frame-act text-accent"
        >
          {gettext("Add review comment")}
        </.link>
      </div>
      <p :if={@caption} class="q-xp-cap">
        <.icon name="hero-check-micro" class="q-xp-cap-i size-3.5" />
        <span><.rich text={@caption} /></span>
      </p>
      <p :if={!@caption && @run[:version]} class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span>{gettext("Version %{version}", version: Format.number(@run.version))}</span>
      </p>
      <div :if={@comments != []} class="q-xp-body q-xp-rc-inline">{render_slot(@comments)}</div>
      <div
        :if={@text?}
        id={"#{@id}-v#{@run[:version]}"}
        class="q-xp-body q-xp-prop"
        phx-hook="Mermaid"
        phx-update="ignore"
        data-script={~p"/assets/js/mermaid.js"}
        data-alt={gettext("Diagram")}
        data-source={gettext("Diagram source")}
        data-not-drawn={gettext("Qory Apiary does not draw this diagram, so it is shown as written.")}
        data-failed={gettext("This diagram has an error, so it is shown as written.")}
      >
        <.run_text id={"#{@id}-text"} value={@body} key={:message} />
      </div>
      <details :if={@sources} id={"#{@id}-sources"} class="q-xp-sources">
        <summary>
          <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
          <span class="q-xp-it">
            <b>{gettext("Sources (%{count})", count: Format.number(@count))}</b>
          </span>
        </summary>
        <div class="q-xp-inner">
          <div class="q-ticket-formatted q-xp-md">{@sources}</div>
        </div>
      </details>
    </section>
    """
  end

  @doc false
  # image_files/1 is the images of a proposal version, by the extension of each filename:
  # PNG, JPEG, GIF, WebP and SVG only, so another file of the version, such as
  # sources.json, is never shown as an image, whatever the caller passes; nil for nil, the
  # version's files not known.
  @spec image_files([{String.t(), String.t()}] | nil) :: [{String.t(), String.t()}] | nil
  def image_files(nil), do: nil

  def image_files(images) do
    Enum.filter(images, fn {filename, _path} ->
      is_binary(filename) and
        String.downcase(Path.extname(filename)) in ~w(.png .jpg .jpeg .gif .webp .svg)
    end)
  end

  # The proposal's version, who confirmed it and when; nil before.
  defp proposal_caption(_run, falsy, _now) when falsy in [nil, false], do: nil

  defp proposal_caption(run, %{by: by, at: at}, now) do
    at = inline_ago(at, now)
    version = if is_integer(run[:version]), do: Format.number(run.version), else: gettext("n/a")

    if you?(by),
      do:
        rich_gettext("Version %{version}. You confirmed it %{when}.",
          version: version,
          when: at
        ),
      else:
        rich_gettext("Version %{version}. %{name} confirmed it %{when}.",
          version: version,
          name: by.name,
          when: at
        )
  end

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :open, :integer, required: true, doc: "how many review comments are open"

  # The gate under the proposal: Confirm (`"confirm"`); while review comments are open,
  # Run with comments first (`"run_with_comments"`), which starts the next run with them,
  # and how many review comments Confirm leaves unread. Confirm opens no dialog.
  defp gate(assigns) do
    ~H"""
    <form id={@id} class="q-xp-reply" phx-submit="run_with_comments" novalidate>
      <input type="hidden" name="number" value={@number} />
      <%= if @open > 0 do %>
        <p class="q-xp-cap q-xp-gate-cap">
          <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
          <span>
            {gettext("Running again sends your review comments, and the agent updates the proposal.")}
          </span>
        </p>
        <div class="q-xp-form-foot q-xp-gate-go">
          <span class="q-xp-gate-b">
            <.button id={"#{@id}-send"} type="submit" variant="primary">
              <.icon name="hero-play-micro" class="size-3.5" />{gettext("Run with comments")}
            </.button>
            <.button
              id={"#{@id}-go"}
              type="button"
              phx-click="confirm"
              phx-value-number={@number}
              aria-describedby={"#{@id}-unread"}
            >
              <.icon name="hero-check-micro" class="size-3.5" />{gettext("Confirm")}
            </.button>
          </span>
          <p id={"#{@id}-unread"}>
            {ngettext(
              "Confirm leaves 1 review comment unread.",
              "Confirm leaves %{count} review comments unread.",
              @open
            )}
          </p>
        </div>
      <% else %>
        <div>
          <.button
            id={"#{@id}-go"}
            type="button"
            variant="primary"
            phx-click="confirm"
            phx-value-number={@number}
          >
            <.icon name="hero-check-micro" class="size-3.5" />{gettext("Confirm")}
          </.button>
        </div>
      <% end %>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :questions, :list, required: true
  attr :mode, :atom, required: true, values: [:form, :read]
  attr :running, :boolean, default: false
  attr :answers, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :form_error, :atom, default: nil
  attr :submits, :integer, default: 0
  attr :now, :any, required: true

  # The questions: the closed ones first, each a fold of one line, then the open ones,
  # with the form for a member who may answer them; while a run runs, as text.
  defp questions_frame(assigns) do
    {open, closed} = Enum.split_with(assigns.questions, &(&1.state == :open))
    form? = assigns.mode == :form and open != []

    first_error =
      form? && Enum.find(open, &answer_error(assigns.errors[&1.id]))

    numbers = Map.new(assigns.questions, &{&1.number, &1})

    assigns =
      assign(assigns,
        open: open,
        closed: closed,
        form?: form?,
        numbers: numbers,
        first_error: first_error,
        form_words: assigns.form_error in [:blank, :stale] && answer_error(assigns.form_error),
        heading: ngettext("Question", "Questions", length(assigns.questions))
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-question-mark-circle" class="q-xp-frame-i size-4" />
        <h2 id={"#{@id}-h"} class="q-xp-frame-t">{@heading}</h2>
      </div>
      <p :if={@form?} id={"#{@id}-cap"} class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span>
          {gettext(
            "The agent is waiting for your answers. Running again sends them and updates the proposal."
          )}
        </span>
      </p>
      <div class="q-xp-body q-xp-qbody">
        <div :if={@closed != []} id={"#{@id}-closed"} class="q-xp-earlier q-xp-closed">
          <.closed_question
            :for={question <- @closed}
            id={"#{@id}-question-#{question.number}"}
            question={question}
            now={@now}
          />
        </div>
        <div :if={@open != []} class="q-xp-sec">
          <h3>{gettext("Open questions")}</h3>
          <%= if @form? do %>
            <form
              id={"#{@id}-form"}
              phx-change="answer_draft"
              phx-submit="answer"
              novalidate
              aria-labelledby={"#{@id}-h"}
            >
              <input type="hidden" name="number" value={@number} />
              <ol class="q-xp-qs">
                <.open_question
                  :for={question <- @open}
                  id={@id}
                  question={question}
                  numbers={@numbers}
                  value={@answers[question.id]}
                  error={@errors[question.id]}
                  now={@now}
                />
              </ol>
              <span
                :if={@first_error}
                id={"#{@id}-focus-#{@submits}-#{@first_error.number}"}
                hidden
                phx-mounted={JS.focus(to: "##{@id}-answer-#{@first_error.number}")}
              ></span>
              <p :if={@form_words} id={"#{@id}-error"} class="q-xp-err" role="alert">
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@form_words}
              </p>
              <div class="q-xp-form-foot">
                <.button id={"#{@id}-go"} type="submit" variant="primary">
                  <.icon name="hero-play-micro" class="size-3.5" />{gettext("Run with answers")}
                </.button>
              </div>
            </form>
          <% else %>
            <ol class="q-xp-qs">
              <.open_question
                :for={question <- @open}
                id={@id}
                question={question}
                numbers={@numbers}
                read={true}
                now={@now}
              />
            </ol>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :question, :map, required: true
  attr :now, :any, required: true

  # A closed question, folded to one line: its number and question, and its answer or
  # Withdrawn; open, its context and its answer with who gave it and when.
  defp closed_question(assigns) do
    answer = assigns.question.answer

    assigns =
      assign(assigns,
        answer: answer,
        words: answer && (answer.option || answer.note)
      )

    ~H"""
    <details id={@id}>
      <summary>
        <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
        <span class="q-xp-it q-xp-wrap">
          <b>{@question.number}. <bdi phx-no-format>{@question.text}</bdi></b>
        </span>
        <span :if={@question.state == :withdrawn} class="q-xp-it">
          <.badge>{gettext("Withdrawn")}</.badge>
        </span>
        <span :if={@words} class="q-xp-it q-xp-wrap q-xp-said" phx-no-format>{@words}</span>
      </summary>
      <div class="q-xp-inner">
        <.run_text value={@question} key={:context} />
        <.given_answer :if={@answer} id={"#{@id}-answer"} answer={@answer} now={@now} />
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :answer, :map, required: true
  attr :now, :any, required: true
  attr :earlier, :boolean, default: false

  # An answer: the option chosen, and the note under it, then who answered and when; an
  # earlier answer muted, under Earlier answer.
  defp given_answer(assigns) do
    ~H"""
    <p :if={@earlier} id={"#{@id}-who"} class="q-xp-cm-m">
      <span class="q-xp-it">{gettext("Earlier answer")}</span>
      <span class="q-xp-it"><.rich text={answered_words(@answer, @now)} /></span>
    </p>
    <div id={@id} class={["q-xp-ans", @earlier && "q-xp-ans-old"]} phx-no-format><span :if={@answer.option} class="block">{@answer.option}</span><span :if={@answer.note}>{@answer.note}</span></div>
    <p :if={!@earlier} id={"#{@id}-who"} class="q-xp-cm-m">
      <span class="q-xp-it"><.rich text={answered_words(@answer, @now)} /></span>
    </p>
    """
  end

  defp answered_words(%{by: by, at: at}, now) do
    at = inline_ago(at, now)

    if you?(by),
      do: rich_gettext("You answered %{when}", when: at),
      else: rich_gettext("%{name} answered %{when}", name: by.name, when: at)
  end

  attr :id, :string, required: true
  attr :question, :map, required: true
  attr :numbers, :map, required: true, doc: "the questions by their number"
  attr :read, :boolean, default: false, doc: "as text, while a run runs"
  attr :value, :any, default: nil, doc: "the draft: `%{\"option\" => choice, \"note\" => text}`"
  attr :error, :any, default: nil
  attr :now, :any, required: true

  # An open question: the question it follows, its question in bold and its context, its
  # earlier answer where a run reopened it; then its options, Give your own option and one
  # field without a visible label, whose placeholder shows what it takes. As text: its
  # options only.
  defp open_question(assigns) do
    question = assigns.question
    n = question.number
    field = "#{assigns.id}-answer-#{n}"
    value = if is_map(assigns.value), do: assigns.value, else: %{}
    message = answer_error(assigns.error)
    own = value["option"] == "own"
    placeholder = if own, do: gettext("Your option"), else: gettext("Add details (optional)")

    assigns =
      assign(assigns,
        n: n,
        q_id: "#{assigns.id}-q-#{n}",
        field: field,
        error_id: "#{field}-error",
        name: "answers[#{question.id}]",
        message: message,
        option: value["option"],
        note: value["note"],
        placeholder: placeholder,
        earlier: List.last(question.history),
        follows:
          for(number <- question.follows, Map.has_key?(assigns.numbers, number), do: number),
        answer_units: @answer_units
      )

    ~H"""
    <li id={"#{@id}-question-#{@n}"} style={"counter-set: q-xp-q #{@n - 1}"}>
      <span class="q-xp-n" aria-hidden="true"></span>
      <div>
        <p :for={number <- @follows} class="q-xp-cm-m">
          <span class="q-xp-it">
            <.link href={"##{@id}-question-#{number}"} class="text-accent">
              {gettext("Follows question %{number}", number: Format.number(number))}
            </.link>
          </span>
        </p>
        <p id={@q_id} class="q-xp-qt"><b phx-no-format>{@question.text}</b></p>
        <.run_text value={@question} key={:context} />
        <.given_answer
          :if={@earlier}
          id={"#{@id}-question-#{@n}-earlier"}
          answer={@earlier}
          now={@now}
          earlier
        />
        <%= if @read do %>
          <ul :if={@question.options != []} class="q-xp-opts">
            <li :for={option <- @question.options} class="q-xp-opt">
              <.option_words option={option} />
            </li>
          </ul>
        <% else %>
          <div
            id={"#{@field}-options"}
            class="q-xp-opts"
            role="radiogroup"
            aria-labelledby={@q_id}
          >
            <label
              :for={{option, j} <- Enum.with_index(@question.options, 1)}
              for={"#{@field}-#{j}"}
              class="q-xp-opt q-xp-opt-pick"
            >
              <input
                type="radio"
                id={"#{@field}-#{j}"}
                name={"#{@name}[option]"}
                value={j}
                checked={@option == Integer.to_string(j)}
              />
              <.option_words option={option} />
            </label>
            <label for={"#{@field}-own"} class="q-xp-opt q-xp-opt-pick">
              <input
                type="radio"
                id={"#{@field}-own"}
                name={"#{@name}[option]"}
                value="own"
                checked={@option == "own"}
              />
              <span class="q-xp-opt-w">
                <b class="q-xp-opt-t">{gettext("Give your own option")}</b>
              </span>
            </label>
          </div>
          <textarea
            id={@field}
            name={"#{@name}[note]"}
            rows="2"
            maxlength={@answer_units}
            placeholder={@placeholder}
            aria-label={@placeholder}
            aria-describedby={if(@message, do: "#{@q_id} #{@error_id}", else: @q_id)}
            aria-invalid={@message && "true"}
          >{["\n", @note || ""]}</textarea>
          <p :if={@message} id={@error_id} class="q-xp-err">
            <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@message}
          </p>
        <% end %>
      </div>
    </li>
    """
  end

  attr :option, :map, required: true

  # An option the run wrote: its title, and its explanation under it, both plain text.
  defp option_words(assigns) do
    ~H"""
    <span class="q-xp-opt-w">
      <b class="q-xp-opt-t" phx-no-format>{@option.title}</b>
      <span class="q-xp-opt-e" phx-no-format>{@option.explanation}</span>
    </span>
    """
  end

  @doc false
  # answer_error/1 is the words of what is wrong with an answer, or with the form for
  # `:blank` and `:stale`; nil for an error without words.
  @spec answer_error(term) :: String.t() | nil
  def answer_error(nil), do: nil

  def answer_error(:blank),
    do:
      gettext(
        "Choose an option or write an answer. If nobody knows, say so: Explore reads that too."
      )

  def answer_error(:stale),
    do:
      gettext(
        "Check the questions and your answers, then click Run with answers again. The questions changed after the page showed them, so no answer was sent."
      )

  def answer_error(:note_required), do: gettext("Write your option, or pick one above.")

  def answer_error({:too_long, limit}),
    do: gettext("Write at most %{number} characters.", number: Format.number(limit))

  def answer_error(:characters), do: gettext("Remove the control or invisible characters.")

  def answer_error(_error), do: nil

  @doc """
  The review comments on the take in's proposals, each a card: the open ones first, then
  the closed ones, each group oldest first, as `comments` comes. The first card of each
  group is opened and the others are folded to their first line, as concept A draws
  them. A card shows
  who wrote it on which version of the proposal, `Open` or `Reopened` (an open one a run
  replied to), its text, each reply, and Reply (`reply_path`). A run's reply shows its
  outcome with the version of the proposal that run stood at: `Changed`, `Answered` or
  `Declined in version %{version}`, or `Asked as question %{number}`, linked to that
  question on the Explore tab (`explore_path`, its address; nil on that tab). A closed
  card is muted, with a tick, and folded shows its outcome under its
  first line; a click on the header of a card folds or opens it, in the browser. While a run
  reads the open review comments (`reading`, its attempt), an open card shows that, and no
  card has Reply.

  A review comment is `%{id:, text:, by:, version:, state:, reopened:, replies:}`, `state`
  `:open` or `:closed`, each reply `%{run:, by:, text:, outcome:, question_number:,
  version:}`: a run's with its number, a member's with `by`, a person.
  """
  attr :id, :string, required: true
  attr :comments, :list, required: true

  attr :reply_path, :any,
    default: nil,
    doc: "a function of a review comment's id: Reply's page; nil or false for no Reply"

  attr :reading, :any, default: nil, doc: "the attempt of the run that reads them now, or nil"

  attr :explore_path, :string,
    default: nil,
    doc: "the Explore tab's address, which Asked as question links to; nil on that tab"

  attr :level, :string,
    default: "h3",
    values: ~w(h2 h3),
    doc: "the heading's level: `h2` in the right column, `h3` inside the proposal's frame"

  attr :tip, :string,
    default: nil,
    doc:
      "the class of the avatars' tooltips: `tooltip-right` in the right column, which cuts a tooltip above an avatar at its left edge"

  attr :class, :any, default: nil

  def review_comments(assigns) do
    {open, closed} = Enum.split_with(assigns.comments, &(&1.state == :open))
    assigns = assign(assigns, :cards, Enum.with_index(open) ++ Enum.with_index(closed))

    ~H"""
    <section id={@id} class={["q-rc-list", @class]} aria-labelledby={"#{@id}-h"}>
      <.dynamic_tag tag_name={@level} id={"#{@id}-h"} class="q-rc-h">
        {gettext("Review comments")}
      </.dynamic_tag>
      <.review_card
        :for={{comment, place} <- @cards}
        id={"#{@id}-#{comment.id}"}
        comment={comment}
        reply_path={@reply_path && @reply_path.(comment.id)}
        reading={@reading}
        explore_path={@explore_path}
        tip={@tip}
        expanded={place == 0}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :comment, :map, required: true
  attr :reply_path, :any, default: nil
  attr :reading, :any, default: nil
  attr :explore_path, :string, default: nil
  attr :tip, :string, default: nil
  attr :expanded, :boolean, default: false, doc: "opened; else folded to its first line"

  # A review comment's card, opened or folded (`review_comments/1`).
  defp review_card(assigns) do
    comment = assigns.comment
    closed = comment.state == :closed
    last = comment.replies |> Enum.filter(&is_integer(&1.run)) |> List.last()
    folded = not assigns.expanded

    assigns =
      assign(assigns,
        closed: closed,
        expanded: if(folded, do: "false", else: "true"),
        outcome: closed && last && outcome_words(last)
      )

    ~H"""
    <div id={@id} class={["q-rc", @closed && "q-rc-done"]}>
      <button
        id={"#{@id}-h"}
        type="button"
        class="q-rc-head"
        aria-expanded={@expanded}
        phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon :if={@closed} name="hero-check-micro" class="q-rc-tick size-3.5" />
        <.avatar
          :if={!@closed}
          email={@comment.by.email}
          kind={kind(@comment.by)}
          size="xs"
          class={@tip}
          in_link
        />
        <span class="q-rc-by q-rc-m">{comment_by(@comment)}</span>
        <span class="q-rc-snip" phx-no-format>{@comment.text}</span>
        <.badge :if={@comment.state == :open} color="warning">
          {if(@comment.reopened, do: gettext("Reopened"), else: gettext("Open"))}
        </.badge>
        <.icon name="hero-chevron-down-micro" class="q-rc-chev size-3.5" />
      </button>
      <p class="q-rc-text" phx-no-format>{@comment.text}</p>
      <%= for {reply, i} <- Enum.with_index(@comment.replies, 1) do %>
        <div :if={reply.run} id={"#{@id}-reply-#{i}"} class="q-rc-reply">
          <p class="q-rc-m">
            <.icon name="hero-play-circle" class="q-xp-frame-i size-4" />
            <span><.reply_outcome reply={reply} explore_path={@explore_path} /></span>
          </p>
          <p class="q-rc-text" phx-no-format>{reply.text}</p>
        </div>
        <div :if={!reply.run} id={"#{@id}-reply-#{i}"} class="q-rc-member">
          <p class="q-rc-m">
            <.avatar email={reply.by.email} kind={kind(reply.by)} size="xs" class={@tip} />
            <span>{reply_by(reply)}</span>
          </p>
          <p class="q-rc-text" phx-no-format>{reply.text}</p>
        </div>
      <% end %>
      <p :if={@reading && !@closed} id={"#{@id}-reading"} class="q-rc-m">
        {gettext("Attempt %{attempt} reads this review comment.",
          attempt: Format.number(@reading)
        )}
      </p>
      <p :if={@reply_path} class="q-rc-acts">
        <.link id={"#{@id}-reply"} patch={@reply_path} class="text-accent">
          {gettext("Reply")}
        </.link>
      </p>
      <p :if={@outcome} class="q-rc-m q-rc-out">{@outcome}</p>
    </div>
    """
  end

  attr :reply, :map, required: true
  attr :explore_path, :string, default: nil

  # A run's reply's outcome; Asked links to the question the run added, on the Explore
  # tab at `explore_path`, or on this page where it is nil.
  defp reply_outcome(%{reply: %{outcome: :asked, question_number: n}} = assigns)
       when is_integer(n) do
    ~H"""
    <.link
      href={"#{@explore_path}#work-item-explore-questions-question-#{@reply.question_number}"}
      class="text-accent"
    >
      {gettext("Asked as question %{number}", number: Format.number(@reply.question_number))}
    </.link>
    """
  end

  defp reply_outcome(assigns), do: ~H"{outcome_words(@reply)}"

  defp outcome_words(%{outcome: outcome, version: version} = reply) do
    version = version && Format.number(version)

    case {outcome, version} do
      {:changed, v} when is_binary(v) ->
        gettext("Changed in version %{version}", version: v)

      {:answered, v} when is_binary(v) ->
        gettext("Answered in version %{version}", version: v)

      {:declined, v} when is_binary(v) ->
        gettext("Declined in version %{version}", version: v)

      {:asked, _v} when is_integer(reply.question_number) ->
        gettext("Asked as question %{number}", number: Format.number(reply.question_number))

      _none ->
        nil
    end
  end

  defp comment_by(%{by: by, version: version}) do
    if you?(by),
      do: gettext("You, on version %{version}", version: Format.number(version)),
      else:
        gettext("%{name}, on version %{version}",
          name: by.name,
          version: Format.number(version)
        )
  end

  defp reply_by(%{version: version} = reply) when is_integer(version), do: comment_by(reply)
  defp reply_by(%{by: by}), do: by.name

  @doc """
  The form page of a review comment on the newest proposal (`:comment`), or of a reply to
  one (`:reply`, with the review comment as `comment`): its field, its error under it
  (`error`, as `comment_error/1` words it), the button, and Cancel back to Explore's tab
  (`cancel`). It sends `"review_comment"` or `"reply"`, with `number` and `text`, and for
  a reply `comment`, the review comment's id.
  """
  attr :id, :string, default: "work-item-review-page"
  attr :kind, :atom, required: true, values: [:comment, :reply]
  attr :number, :integer, required: true
  attr :comment, :map, default: nil
  attr :value, :string, default: ""
  attr :error, :any, default: nil
  attr :submits, :integer, default: 0
  attr :cancel, :string, required: true

  def review_page(assigns) do
    {title, label, event} =
      case assigns.kind do
        :comment -> {gettext("Add review comment"), gettext("Review comment"), "review_comment"}
        :reply -> {gettext("Reply"), gettext("Reply"), "reply"}
      end

    assigns =
      assign(assigns,
        title: title,
        label: label,
        event: event,
        message: comment_error(assigns.error),
        answer_units: @answer_units
      )

    ~H"""
    <.page_form id={@id} title={@title}>
      <.review_card :if={@comment} id={"#{@id}-comment"} comment={@comment} expanded />
      <form id={"#{@id}-form"} class="q-form" phx-submit={@event} novalidate>
        <input type="hidden" name="number" value={@number} />
        <input :if={@comment} type="hidden" name="comment" value={@comment.id} />
        <div class="fieldset">
          <label for={"#{@id}-text"} class="text-[13px]/[18px] font-medium">{@label}</label>
          <textarea
            id={"#{@id}-text"}
            name="text"
            rows="4"
            class="textarea w-full"
            maxlength={@answer_units}
            aria-describedby={@message && "#{@id}-error"}
            aria-invalid={@message && "true"}
            phx-mounted={JS.focus()}
          >{["\n", @value]}</textarea>
          <p :if={@message} id={"#{@id}-error"} class="q-xp-err">
            <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@message}
          </p>
        </div>
        <span
          :if={@message}
          id={"#{@id}-focus-#{@submits}"}
          hidden
          phx-mounted={JS.focus(to: "##{@id}-text")}
        ></span>
        <.page_form_foot cancel={@cancel} cancel_by="patch">
          <.button type="submit" variant="primary">{@title}</.button>
        </.page_form_foot>
      </form>
    </.page_form>
    """
  end

  @doc false
  # comment_error/1 is the words of what is wrong with a review comment or a reply; nil
  # for an error without words.
  @spec comment_error(term) :: String.t() | nil
  def comment_error(:blank), do: gettext("Write your review comment.")
  def comment_error(:reply_blank), do: gettext("Write your reply.")

  def comment_error({:too_long, _limit}),
    do: gettext("Shorten the comment to 2,000 characters or fewer.")

  def comment_error(:characters),
    do: gettext("Remove the invisible or control characters from the comment.")

  def comment_error(:not_approver),
    do:
      gettext(
        "Ask one of this stage's approvers to comment. Only they can comment on its proposal."
      )

  def comment_error(_error), do: nil

  attr :id, :string, required: true
  attr :runs, :list, required: true, doc: "the take in's runs, oldest first"
  attr :latest, :map, default: nil, doc: "its latest run, where it is among `runs`"
  attr :proposal, :map, default: nil
  attr :questions_version, :integer, default: nil
  attr :item, :string, required: true
  attr :now, :any, required: true
  slot :inner_block, doc: "the artifacts"

  # One fold of the take in's runs and its artifacts: how many runs, and the newest
  # proposal's and questions' versions; opened, each run with what it wrote. An earlier
  # run that wrote a proposal is a fold with that version, one without a result a fold
  # with what happened; the latest run, and a run with nothing to show, a row.
  defp record(assigns) do
    assigns = assign(assigns, :count, length(assigns.runs))

    ~H"""
    <section id={@id} class="q-xp-earlier" aria-label={gettext("Runs and artifacts")}>
      <details id={"#{@id}-fold"}>
        <summary>
          <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
          <span class="q-xp-it"><b>{ngettext("1 run", "%{count} runs", @count)}</b></span>
          <span :if={@proposal} class="q-xp-it">
            {gettext("proposal v%{version}", version: Format.number(@proposal.version))}
          </span>
          <span :if={@questions_version} class="q-xp-it">
            {gettext("questions v%{version}", version: Format.number(@questions_version))}
          </span>
        </summary>
        <div class="q-xp-inner">
          <%= for run <- @runs do %>
            <%= case run_shows(run, run == @latest) do %>
              <% :row -> %>
                <div id={"#{@id}-#{run_dom(run)}"} class="q-xp-runrow">
                  <span :for={part <- run_parts(run, @now)} class="q-xp-it">
                    <.rich text={part} />
                  </span>
                </div>
              <% shows -> %>
                <details id={"#{@id}-#{run_dom(run)}"}>
                  <summary>
                    <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
                    <span :for={part <- run_parts(run, @now)} class="q-xp-it">
                      <.rich text={part} />
                    </span>
                  </summary>
                  <div class="q-xp-inner">
                    <.proposal_frame
                      :if={shows == :proposal}
                      id={"#{@id}-#{run_dom(run)}-proposal"}
                      run={%{proposal: run.wrote_proposal, version: run.wrote}}
                      now={@now}
                      level="h3"
                    />
                    <.no_result :if={shows == :none} id={"#{@id}-#{run_dom(run)}-none"} run={run} />
                  </div>
                </details>
            <% end %>
          <% end %>
          <div :if={@inner_block != []} class="q-xp-arts">{render_slot(@inner_block)}</div>
        </div>
      </details>
    </section>
    """
  end

  # What a run shows in the fold: a row for the latest run and a run with nothing to
  # show; `:proposal` for an earlier run that wrote one; `:none` for a run without a
  # result.
  defp run_shows(_run, true), do: :row
  defp run_shows(%{wrote_proposal: %{}}, _last), do: :proposal
  defp run_shows(%{state: state}, _last) when state in [:failed, :lost, :cancelled], do: :none
  defp run_shows(_run, _last), do: :row

  # A run's line in the fold: its attempt, what it wrote, and when; while it runs,
  # Running and when it started.
  defp run_parts(run, now) do
    attempt = {:b, run_place(run)}

    rest =
      case run[:state] do
        state when state in [nil, :pending] ->
          [gettext("Queued")]

        :running ->
          [RunComponents.state_label(:running), run_time(run, now)]

        _ended ->
          wrote = if run[:wrote], do: [gettext("Wrote a proposal")], else: []

          asked =
            if (run[:asked] || 0) > 0,
              do: [
                ngettext("Wrote %{number} question", "Wrote %{number} questions", run.asked,
                  number: Format.number(run.asked)
                )
              ],
              else: []

          said = wrote ++ asked

          said =
            if said == [] or run.state in [:failed, :lost, :cancelled],
              do: said ++ [RunComponents.state_label(run.state)],
              else: said

          said ++ List.wrap(run[:ended_at] && ended_ago(run.ended_at, now))
      end

    [attempt | Enum.reject(rest, &is_nil/1)]
  end

  defp ended_ago(at, now), do: time_tag(at, Format.relative(at, now))

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
        <p :if={@body}><.rich text={@body} /></p>
        <p :if={@run[:adapter_failure]} id={"#{@id}-adapter"}>
          <.rich text={adapter_failure_words(@run.adapter_failure)} />
        </p>
        <p :if={@run[:id]}>
          <.rich text={
            rich_gettext("The page of attempt %{attempt} shows what it did.",
              attempt: attempt_ref(@run)
            )
          } />
        </p>
      </div>
    </div>
    """
  end

  # A run that pushed a proposal before it ended shows that proposal on the tab, so the
  # page shows no line that there is nothing to show.
  defp no_result_words(%{state: :failed, wrote: version}) when is_integer(version),
    do: {"hero-exclamation-triangle-micro", failed_after(version), nil}

  defp no_result_words(%{state: :lost, wrote: version}) when is_integer(version),
    do: {"hero-signal-slash-micro", gettext("The run was lost."), nil}

  defp no_result_words(%{state: :lost}),
    do:
      {"hero-signal-slash-micro", gettext("The run was lost."),
       gettext("Qory Apiary has no result from the run. There is nothing to show or confirm.")}

  defp no_result_words(%{state: :cancelled, wrote: version}) when is_integer(version),
    do: {"hero-stop-circle-micro", gettext("The run was cancelled."), nil}

  defp no_result_words(%{state: :cancelled}),
    do:
      {"hero-stop-circle-micro", gettext("The run was cancelled."),
       gettext("There is nothing to show or confirm.")}

  defp no_result_words(%{end_cause: :harness_unresolved} = run),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       harness_failure_words(run[:harness_failure])}

  defp no_result_words(%{end_cause: :run_refused, end_detail: "model_key_missing"}),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       gettext(
         "Add a model key in Organisation settings › Model providers. The gateway had no model key for the run."
       )}

  defp no_result_words(%{end_cause: cause}) when cause in @unstarted,
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       unstarted_words(cause)}

  defp no_result_words(%{workflow_gap: %{} = gap}),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       ApiaryWeb.HarnessComponents.workflow_gap_words(gap)}

  defp no_result_words(%{read_needs: %{} = facts}),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended without a result."),
       read_needs_words(facts)}

  defp no_result_words(%{outcome: :none}),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended without a result."),
       gettext("There is nothing to show or confirm.")}

  defp no_result_words(%{outcome: :refused}),
    do:
      {"hero-exclamation-triangle-micro",
       gettext("The run's result did not pass Qory Apiary's check."),
       gettext(
         "Qory Apiary accepts a result only in Explore's format and up to 128 KiB. This result is outside those limits, so it is not shown."
       )}

  defp no_result_words(_error),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended with an error."),
       gettext("The run's last result was an error. There is nothing to show or confirm.")}

  # What a person does about a read-only run that qory closed (`Apiary.Runs.ReadNeeds`), the
  # fix first. A person in an organisation cannot edit the forager.yaml of the instance's
  # pool, so that pool's run has "Contact support." in place of the fix.
  # `Apiary.Stages.StopCause` stores the same words in English.
  defp read_needs_words(%{code: "read_needs_wall", installed: true}),
    do:
      rich_gettext(
        "%{contact_support}. A read-only run needs a wall, and this machine has none.",
        contact_support: ApiaryWeb.Support.rich()
      )

  defp read_needs_words(%{code: "read_needs_wall"}),
    do:
      gettext(
        "Set a wall in the machine's forager.yaml, then start the run again. A read-only run needs a wall, and this machine has none."
      )

  defp read_needs_words(%{code: "read_needs_setup_outside", installed: true}),
    do:
      rich_gettext(
        "%{contact_support}. A read-only run cannot run its setup inside the agent's container.",
        contact_support: ApiaryWeb.Support.rich()
      )

  defp read_needs_words(%{code: "read_needs_setup_outside"}),
    do:
      gettext(
        "Set wall.setup to outside in the machine's forager.yaml, or remove it, then start the run again. A read-only run cannot run its setup inside the agent's container."
      )

  defp read_needs_words(%{code: "read_needs_no_nested_docker"}),
    do:
      gettext(
        "Choose an image without nested Docker in the workspace's policy or the target's environment, then start the run again. A read-only run cannot use an image with nested Docker."
      )

  defp read_needs_words(%{code: "read_needs_setup_removed"}),
    do:
      gettext(
        "Start the run again. The setup container was not removed, so a process in it could still write the files."
      )

  # What a member does about a run that stopped at a call to an adapter
  # (`Apiary.Adapters.Calls`), and what happened to the call, by its cause.
  defp adapter_failure_words(%{adapter: adapter, cause: cause, call: call} = failure) do
    what = adapter_call_words(call)

    case cause do
      :timeout ->
        rich_gettext(
          "%{contact_support}. The run did not start: the call to %{adapter} for %{what} timed out.",
          contact_support: ApiaryWeb.Support.rich(),
          adapter: adapter,
          what: what
        )

      :unreachable ->
        rich_gettext(
          "%{contact_support}. The run did not start: the call to %{adapter} for %{what} did not reach it.",
          contact_support: ApiaryWeb.Support.rich(),
          adapter: adapter,
          what: what
        )

      :refused ->
        rich_gettext(
          "%{contact_support}. The run did not start: the call to %{adapter} for %{what} returned the error %{code}.",
          contact_support: ApiaryWeb.Support.rich(),
          adapter: adapter,
          what: what,
          code: failure.code || "unauthorized"
        )

      :invalid_answer ->
        rich_gettext(
          "%{contact_support}. The run did not start: the response of %{adapter} failed its signature check or format check, or was over 1 MiB.",
          contact_support: ApiaryWeb.Support.rich(),
          adapter: adapter
        )

      :no_address ->
        rich_gettext(
          "%{contact_support}. The run did not start: %{adapter} has no call address.",
          contact_support: ApiaryWeb.Support.rich(),
          adapter: adapter
        )

      :not_allowed ->
        rich_gettext(
          "%{contact_support}. The run did not start: Qory Apiary does not call the call address of %{adapter}.",
          contact_support: ApiaryWeb.Support.rich(),
          adapter: adapter
        )

      :too_large ->
        gettext(
          "Remove harness sources or files, then run Explore again. The run did not start: the call to %{adapter} for %{what} was over 256 KiB.",
          adapter: adapter,
          what: what
        )
    end
  end

  defp adapter_call_words("run-credential"), do: gettext("the run's credentials")
  defp adapter_call_words("resolve"), do: gettext("the harness sources")
  defp adapter_call_words("read"), do: gettext("the harness files")

  # What a member does about a run whose harness walk failed, and why it failed, by the
  # walk's failure code (`Apiary.Harnesses.Walk`). nil for a call to an adapter that
  # failed, which the adapter's line words (`adapter_failure_words/1`). A source is
  # shown as the walk wrote it, or as the workspace's harness setting where the walk
  # wrote none: a harness choice's document, or a hidden harness. A source no connection
  # reaches, and a failed read of a public repository, have the Harness step's words
  # (`ApiaryWeb.HarnessComponents.public_read_words/2`).
  defp harness_failure_words(%{code: code} = failure) do
    source = failure.source || gettext("the workspace's harness setting")

    case code do
      "no_harness" ->
        gettext(
          "Add a harness file to the target, or set a harness in the workspace's settings, then run Explore again. The run has neither."
        )

      "invalid" ->
        gettext(
          "Correct %{source}, then run Explore again. The source breaks the harness format: %{rule}.",
          source: source,
          rule: harness_rule_words(failure.rule)
        )

      code when is_map_key(@public_read_codes, code) ->
        HarnessComponents.public_read_words(
          Map.fetch!(@public_read_codes, code),
          HarnessComponents.fetch_names(
            failure.rule,
            source,
            failure[:organisation] || gettext("this organisation"),
            failure[:workspace] || gettext("this workspace")
          )
        )

      "not_allowed" ->
        gettext(
          "Ask the owner of %{source} to assign it to this organisation, then run Explore again. That harness source belongs to another owner, who has not assigned it here.",
          source: source
        )

      "scp_form" ->
        gettext(
          "Write %{source} as an https address, then run Explore again. Qory Apiary fetches harness sources over https only, and %{source} has the form user@host:path.",
          source: source
        )

      "credential_in_address" ->
        gettext(
          "Remove the user name and password from %{source}, then run Explore again. A harness source address may not contain a credential.",
          source: source
        )

      "too_many" ->
        gettext(
          "Take the harness sources from at most %{n} accounts, then run Explore again. A run takes %{n} harness credentials at most.",
          n: Walk.max_links()
        )

      "adapter_unavailable" ->
        rich_gettext(
          "Run Explore again. If the run ends the same way, %{contact_support}. Three calls to the adapter %{adapter} failed.",
          contact_support: ApiaryWeb.Support.rich(mid_sentence: true),
          adapter: failure.adapter
        )

      "walk_error" ->
        rich_gettext(
          "Run Explore again. If the run ends the same way, %{contact_support}. The harness walk stopped on an error in Qory Apiary.",
          contact_support: ApiaryWeb.Support.rich(mid_sentence: true)
        )

      _adapter_failed ->
        nil
    end
  end

  defp harness_failure_words(nil), do: nil

  @doc false
  # harness_rule_words/1 is the harness format rule a source breaks: one of the walk's, or
  # one of the save check's (`Apiary.Stacks.Document`), in its words. The Harness step and
  # Workflow show it too (`ApiaryWeb.HarnessComponents.refusal_words/4`).
  @spec harness_rule_words(map | nil) :: String.t()
  def harness_rule_words(%{"rule" => "yaml", "values" => %{"file" => file}} = rule),
    do:
      gettext("%{file} %{problem}",
        file: file,
        problem: saved_rule_words(rule["message"], rule["message_values"])
      )

  def harness_rule_words(%{"rule" => name, "values" => values}),
    do: walk_rule_words(name, values)

  def harness_rule_words(%{"message" => message, "values" => values}),
    do: saved_rule_words(message, values)

  def harness_rule_words(_rule), do: ""

  @doc false
  # harness_problem_words/1 is `harness_rule_words/1` without the file of a `yaml` rule,
  # for a sentence that shows the file before the rule.
  @spec harness_problem_words(map | nil) :: String.t()
  def harness_problem_words(%{"rule" => "yaml"} = rule),
    do: saved_rule_words(rule["message"], rule["message_values"])

  def harness_problem_words(rule), do: harness_rule_words(rule)

  # A save check's message goes inside a sentence that ends in ".": a message that is a
  # sentence of its own, such as the bind messages of `Apiary.Stacks.Document`, loses its
  # "." here, so the line does not end in "..".
  defp saved_rule_words(message, values) when is_binary(message) do
    values =
      for {key, value} <- values || %{}, atom = @rule_values[key], atom != nil do
        {atom, value || gettext("the workspace's harness setting")}
      end

    words = ApiaryWeb.CoreComponents.translate_error({message, values})

    if String.ends_with?(message, "."),
      do: String.replace_suffix(words, ".", ""),
      else: words
  end

  defp walk_rule_words("both_files", _values),
    do: gettext("it has both harness.yaml and qory.yaml: keep one")

  defp walk_rule_words("host", _values),
    do: gettext("its host is an IP address or a local name: give a public host name")

  defp walk_rule_words("host_encoded", _values),
    do: gettext("its host has a percent-encoding: write the host name without one")

  # A hidden harness's rule has no path, ref or stack name: its words name none.
  defp walk_rule_words("path", %{"path" => path}),
    do: gettext("the path %{path} leads out of its source", path: path)

  defp walk_rule_words("path", _hidden), do: gettext("a path leads out of its source")

  defp walk_rule_words("path_form", %{"path" => path}),
    do:
      gettext(
        "the path %{path} has a backslash or a percent sign: write it with / and no percent-encoding",
        path: path
      )

  defp walk_rule_words("path_form", _hidden),
    do:
      gettext("a path has a backslash or a percent sign: write it with / and no percent-encoding")

  defp walk_rule_words("ref", %{"ref" => ref}),
    do:
      gettext(
        "the ref %{ref} is not a version: 1 to 255 letters, digits, dots, underscores, slashes and hyphens",
        ref: to_string(ref)
      )

  defp walk_rule_words("ref", _hidden),
    do:
      gettext(
        "its ref is not a version: 1 to 255 letters, digits, dots, underscores, slashes and hyphens"
      )

  defp walk_rule_words("no_export", %{"name" => name}),
    do: gettext("it exports no stack %{name}", name: name)

  defp walk_rule_words("no_export", _hidden), do: gettext("it exports no stack of that name")

  defp walk_rule_words("no_stack_file", %{"path" => path}),
    do: gettext("it has no %{path}", path: path)

  defp walk_rule_words("no_stack_file", _hidden),
    do: gettext("it has no qory-stack.yaml at the stack's path")

  defp walk_rule_words("no_stack", _values),
    do: gettext("its root has no qory-stack.yaml and no harness section")

  defp walk_rule_words("version", _values),
    do: gettext("its ref is no version of its source")

  defp walk_rule_words("not_text", _values),
    do: gettext("one of its harness files is not text")

  defp walk_rule_words("calls", values),
    do: gettext("reading it takes more than %{n} calls", n: values["n"])

  defp walk_rule_words("size", values),
    do: gettext("it is larger than %{n} bytes as JSON", n: values["n"])

  defp walk_rule_words("extends", _values),
    do: gettext("extends is not a source")

  defp walk_rule_words(name, _values), do: to_string(name)

  # What a member does about a run that ended before it started, at its claim or while it
  # waited for its environment image's build, and why it ended.
  defp unstarted_words(:variables_invalid),
    do:
      gettext(
        "Fix the variables in the workspace's settings, then run Explore again. One of the run's variables breaks a variable rule."
      )

  defp unstarted_words(:ticket_gone),
    do:
      gettext(
        "If the ticket is still in the Backlog, take it in again from there. Qory Apiary no longer has this work item's ticket."
      )

  defp unstarted_words(:inputs_invalid),
    do:
      gettext(
        "Shorten or correct the ticket, then run Explore again. A value in the ticket or the work item breaks a rule for the agent's input, such as the size limit."
      )

  defp unstarted_words(:target_access_gone),
    do:
      gettext(
        "Check the integration that brings in this target on the organisation's Integrations page, then run Explore again. The run had no access to its target: the integration no longer reaches it, or the target's path has a character that access rules do not allow."
      )

  defp unstarted_words(:build_failed),
    do:
      gettext(
        "Check why the build failed on the target's page, then run Explore again. The run did not start because Qory Apiary could not build its environment image."
      )

  # A run in a DOM id: its number, or for a run that ended before its handover, which has
  # no public id, its place in the take in.
  defp run_dom(%{id: id, number: number}) when is_binary(id), do: Integer.to_string(number)
  defp run_dom(run), do: "run-#{run.attempt}"

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :item, :string, required: true, doc: "the source's word for one of its items"
  attr :test, :boolean, default: false, doc: "whether it is a test work item"
  attr :now, :any, required: true

  # Inside a run's fold of Earlier take ins: its questions and the answers, its questions
  # nobody answered, its proposal, or what happened to it. Its frame's heading is an
  # `h4`, under the `h3` of Earlier take ins.
  defp run_body(%{run: %{outcome: :questions}} = assigns) do
    n = length(assigns.run.questions)

    assigns =
      assign(
        assigns,
        :heading,
        ngettext("Question and answer", "Questions and answers", n)
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <h4 id={"#{@id}-h"} class="q-xp-frame-t">{@heading}</h4>
      </div>
      <p class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span>
          <.rich text={
            rich_gettext("Attempt %{attempt} wrote these questions.",
              attempt: attempt_ref(@run)
            )
          } />
        </span>
      </p>
      <div class="q-xp-body">
        <.answered :if={answered?(@run)} id={"#{@id}-qa"} run={@run} now={@now} />
        <ol :if={!answered?(@run)} class="q-xp-qs">
          <li :for={question <- @run.questions} id={"#{@id}-q-#{question.public_id}"}>
            <span class="q-xp-n" aria-hidden="true"></span>
            <div><.run_text value={question} key={:text} /></div>
          </li>
        </ol>
      </div>
    </section>
    """
  end

  defp run_body(%{run: %{outcome: :proposal}} = assigns) do
    ~H"""
    <.proposal_frame id={@id} run={@run} now={@now} level="h4" />
    """
  end

  defp run_body(assigns) do
    ~H"""
    <.no_result id={@id} run={@run} />
    """
  end

  attr :id, :string, required: true
  attr :take_ins, :list, required: true
  attr :item, :string, required: true, doc: "the source's word for one of its items"
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
          <span :if={ended_words(take_in, @now)} class="q-xp-it">
            <.rich text={ended_words(take_in, @now)} />
          </span>
          <span class="q-xp-it">
            {ngettext("%{count} run", "%{count} runs", length(take_in.runs))}
          </span>
        </summary>
        <div class="q-xp-inner">
          <p>{gettext("These runs do not count toward the run limit of this take in.")}</p>
          <%= for run <- take_in.runs do %>
            <.run_line id={"#{@id}-#{i}-#{run_dom(run)}"} run={run} now={@now} />
            <.run_body
              id={"#{@id}-#{i}-#{run_dom(run)}-body"}
              run={run}
              item={@item}
              now={@now}
            />
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

  defp ended_words(%{ended: :closed, ended_by: nil} = take_in, now) do
    if take_in[:ended_reason] == :adapter_removed,
      do:
        rich_gettext("Closed %{when}, when its integration was removed",
          when: inline_ago(take_in.ended_at, now)
        ),
      else: closed_words(take_in[:ended_reason])
  end

  defp ended_words(%{ended: ended, ended_by: by, ended_at: at}, now)
       when ended in [:closed, :undone] do
    at = inline_ago(at, now)

    case {ended, you?(by)} do
      {:closed, true} -> rich_gettext("Closed by you %{when}", when: at)
      {:closed, false} -> rich_gettext("Closed by %{name} %{when}", name: by.name, when: at)
      {:undone, true} -> rich_gettext("Undone by you %{when}", when: at)
      {:undone, false} -> rich_gettext("Undone by %{name} %{when}", name: by.name, when: at)
    end
  end

  defp ended_words(_take_in, _now), do: nil

  ## The Ticket tab

  @doc """
  The Ticket tab: the ticket as the integration sent it, kept current. Its full form with
  the integration's mark, as the Backlog's ticket head names it, who filed it and when,
  when it was last updated, Open on the integration, its labels, its text
  (`SourceComponents.body/1`, with Show as written), and its latest comments under how
  many it has, with Show earlier comments (`"show_earlier_comments"`) where it has more
  than are given.

  After the integration's uninstall (`uninstalled`) a line above it says when the
  integration last sent it (`ticket.received_at`), and that Qory Apiary no longer updates it.

  `ticket` is a map with `:filer` (`%{name:}`), `:filed_at`, `:updated_at`, `:labels` (a
  list of strings), `:body` and `:format` (as `SourceComponents.body/1` takes them),
  `:comment_count` (how many comments it has) and, after an uninstall, `:received_at`.
  `comments` are its latest comments, oldest first, each with `:public_id`, `:author` (a
  name), `:at`, `:body` and `:format`.
  """
  attr :id, :string, default: "work-item-ticket"
  attr :work_item, :map, required: true, doc: "the work item: `:key`, `:repository` and `:url`"
  attr :ticket, :map, required: true, doc: "the ticket, as above"
  attr :comments, :list, default: [], doc: "its latest comments, as above"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :uninstalled, :boolean, default: false, doc: "whether the integration was uninstalled"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

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
        full_form: ExternalText.line(BacklogComponents.full_form(assigns.work_item)),
        # The Backlog's line; the space before its "·" does not break, so a wrapped line
        # never starts with it.
        meta:
          gettext("%{name} filed this %{filed_ago} · updated %{updated_ago}",
            name: ExternalText.line(ticket.filer.name),
            filed_ago: Format.time_ago(ticket.filed_at, now, case: :inline),
            updated_ago: Format.time_ago(ticket.updated_at, now, case: :inline)
          )
          |> String.replace(" · ", " · "),
        stale:
          assigns.uninstalled &&
            rich_gettext(
              "%{integration} last sent this %{item} %{when}. Qory Apiary no longer updates it.",
              integration: assigns.integration,
              when: inline_ago(ticket[:received_at] || ticket.updated_at, now),
              item: SourceComponents.item(assigns.item_noun)
            )
      )

    ~H"""
    <div id={@id} class="q-wi-tkt">
      <p :if={@stale} id={"#{@id}-stale"} class="q-wi-stale">
        <.icon name="hero-signal-slash-micro" class="size-3.5" /><span><.rich text={@stale} /></span>
      </p>
      <div class="q-wi-tkt-meta">
        <span class="q-wi-key">
          <BacklogComponents.integration_tile name={@integration} />
          <span title={@full_form}>{@full_form}</span>
        </span>
        <span class="q-wi-tkt-filed">{@meta}</span>
        <span class="q-wi-grow"></span>
        <.external_link :if={@href} id={"#{@id}-out"} href={@href} class="q-wi-out">
          {gettext("Open on %{integration}", integration: @integration)}
        </.external_link>
      </div>
      <dl :if={@ticket.labels != []} class="q-wi-facts">
        <dt>{pgettext("ticket", "Labels")}</dt>
        <dd>{Enum.map_join(@ticket.labels, ", ", &ExternalText.line/1)}</dd>
      </dl>
      <div class="q-wi-text">
        <SourceComponents.body
          id={"#{@id}-text"}
          body={@ticket.body}
          format={@ticket.format}
          item_noun={@item_noun}
        />
      </div>
      <section
        :if={@count > 0}
        id={"#{@id}-comments"}
        class="q-wi-tcm"
        aria-labelledby={"#{@id}-comments-h"}
      >
        <h3 id={"#{@id}-comments-h"}>
          {ngettext("%{count} comment on the %{item}", "%{count} comments on the %{item}", @count,
            item: SourceComponents.item(@item_noun)
          )}
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
            <.avatar name={ExternalText.line(comment.author)} size="xs" />
            <b><.external_text text={comment.author} /></b>
            <span class="q-faint">{time_tag(comment.at, Format.time_ago(comment.at, @now))}</span>
          </div>
          <div class="q-wi-cmt-txt">
            <SourceComponents.body
              id={"#{@id}-comment-#{comment.public_id}-text"}
              body={comment.body}
              format={comment.format}
              item_noun={@item_noun}
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

    * `:taken_in` - who took the work item in from the ticket (its `key`, beside the mark
      of the integration it came from, `integration`, and a link out where `url` is given;
      the mark alone without a key), or took it in again (`again`), who owns it where that
      is another person (`owner`), and the first instruction under it
      (`first_instruction`, none where it is empty or blank); for a test work item
      (`test`), who started the test run, with no ticket;
    * `:started` - Qory started Explore in a run (`run`), its first, again with the
      answers (`start: :answers`), or again after Run Explore again or a retry
      (`start: :again`), with the run's place in the take in beside it;
    * `:asked` - how many questions Qory wrote and after how long (`questions`,
      `duration`), the questions quoted under it;
    * `:answered` - who answered Qory's questions, each question and its answer quoted;
      or who commented on Qory's proposal (`comment`), the comment quoted;
    * `:proposed` - Qory wrote a proposal, after how long, and whose turn it is
      (`owner`), or only after how long where it has no owner;
    * `:no_result`, `:lost`, `:cancelled` - a run (`run`) that gave no result, and why
      (`outcome`: `:error`, `:none` or `:refused`), or for a failed run that pushed a
      proposal first, its version (`wrote`); for a run the gateway stopped for
      want of a model key (`end_cause: :run_refused`, `end_detail: "model_key_missing"`),
      what a member fixes;
    * `:explore_again` - who ran Explore again;
    * `:confirmed` - who confirmed Qory's proposal, with their changes (`changed`);
    * `:closed` - who closed it; a close by the instance has no `actor`, and says why
      (`reason`), where it has words for the reason, else draws nothing;
    * `:undone` - who undid it, before a run started.

  A run is `%{id:, number:, path:, attempt:, of:}`, its attempt shown and linked to the
  run's page where `path` is given. A run that ended before its handover has no id: a line that would name
  it draws nothing. A question is `%{public_id:, text:, answer:}`, its text Markdown, as
  `explore_tab/1` shows it, with its render as `:rendered` where the page has one. Every
  kind takes `integration`, so no page draws the key without its mark. A member's answers
  and comments are quoted as plain text, never inside a sentence.
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
      :undone
    ]

  attr :actor, :map, default: nil, doc: "who acted, a person; none for Qory's events"
  attr :at, :any, required: true, doc: "when"
  attr :key, :string, default: nil, doc: "`:taken_in`: the ticket's key, or none"
  attr :url, :string, default: nil, doc: "`:taken_in`: the ticket's page at the source"

  attr :integration, :string,
    required: true,
    doc: "the integration's name, beside the key; nil for a test work item"

  attr :test, :boolean, default: false, doc: "`:taken_in`: whether it is a test work item"
  attr :owner, :map, default: nil, doc: "`:taken_in`, `:proposed`: who owns it, a person"
  attr :first_instruction, :string, default: nil, doc: "`:taken_in`: the first instruction"
  attr :again, :boolean, default: false, doc: "`:taken_in`: whether it was taken in again"
  attr :start, :atom, default: nil, values: [nil, :answers, :again], doc: "`:started`: how"
  attr :run, :map, default: nil, doc: "the run, as above"
  attr :questions, :list, default: [], doc: "`:asked`, `:answered`: the questions, as above"
  attr :comment, :string, default: nil, doc: "`:answered`: a comment on Qory's proposal"
  attr :duration, :string, default: nil, doc: "`:asked`, `:proposed`: how long the run took"

  attr :outcome, :atom,
    default: :error,
    values: [:error, :none, :refused],
    doc: "`:no_result`: why the run gave none"

  attr :end_cause, :atom, default: nil, doc: "`:no_result`: why its run of the queue ended"

  attr :end_detail, :string,
    default: nil,
    doc: "`:no_result`: the code that end kept, as a run map has it"

  attr :wrote, :integer,
    default: nil,
    doc: "`:no_result`: the version of the proposal a failed run pushed before it failed"

  attr :changed, :boolean, default: false, doc: "`:confirmed`: with the member's changes"

  attr :reason, :atom,
    default: nil,
    values: [nil, :adapter_removed, :last_stage_done, :ticket_closed],
    doc: "`:closed` by the instance (no `actor`): why"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def thread_event(%{kind: kind, run: %{id: nil}} = assigns)
      when kind in [:started, :no_result, :lost, :cancelled],
      do: ~H""

  def thread_event(%{kind: :closed, actor: nil, reason: nil} = assigns), do: ~H""

  def thread_event(assigns) do
    now = now(assigns)

    assigns =
      assign(assigns,
        line: event_line(assigns),
        tag:
          assigns.kind == :started &&
            gettext("Attempt %{attempt}", attempt: Format.number(assigns.run.attempt)),
        qory: assigns.kind in [:started, :asked, :proposed],
        bad: assigns.kind in [:no_result, :lost, :cancelled],
        at_words: time_tag(assigns.at, Format.relative(assigns.at, now)),
        href: if(out?(assigns.url), do: assigns.url),
        instruction: assigns.kind == :taken_in && instruction(assigns.first_instruction)
      )

    ~H"""
    <li id={@id} class="q-wi-ev">
      <span class="q-wi-ev-ic" aria-hidden="true">
        <.run_icon :if={@qory} />
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
                <.external_link :if={@key} href={@href}><.external_text text={@key} /></.external_link>
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
          <li :for={question <- @questions}><.run_text value={question} key={:text} /></li>
        </ol>
        <div :if={@kind == :answered} id={"#{@id}-answers"} class="q-wi-qa">
          <div :for={question <- @questions}>
            <div class="q-wi-qa-q"><.run_text value={question} key={:text} /></div>
            <div class="q-wi-qa-a" phx-no-format>{question.answer}</div>
          </div>
          <div :if={@comment} class="q-wi-qa-a" phx-no-format>{@comment}</div>
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
  defp event_icon(:undone), do: "hero-arrow-uturn-left-micro"

  defp event_line(%{kind: :taken_in, test: true, actor: actor}) do
    if you?(actor),
      do: rich_gettext("You started a test run"),
      else: rich_gettext("%{name} started a test run", name: {:b, actor.name})
  end

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
      rich_gettext("Explore started again, with the answers, in attempt %{attempt}",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :started, start: :again, run: run}),
    do: rich_gettext("Explore started again in attempt %{attempt}", attempt: attempt_ref(run))

  defp event_line(%{kind: :started, run: run}),
    do: rich_gettext("Explore started in attempt %{attempt}", attempt: attempt_ref(run))

  defp event_line(%{kind: :asked, questions: questions, duration: duration}) do
    n = length(questions)

    ngettext(
      "Explore wrote 1 question, after %{duration}",
      "Explore wrote %{number} questions, after %{duration}",
      n,
      number: Format.number(n),
      duration: duration
    )
  end

  defp event_line(%{kind: :answered, actor: actor, comment: comment})
       when is_binary(comment) do
    if you?(actor),
      do: gettext("You wrote a review comment on the proposal"),
      else: rich_gettext("%{name} wrote a review comment on the proposal", name: {:b, actor.name})
  end

  defp event_line(%{kind: :answered, actor: actor, questions: questions}) do
    n = length(questions)
    number = Format.number(n)

    if you?(actor),
      do:
        ngettext("You answered 1 question", "You answered %{number} questions", n, number: number),
      else:
        rich_ngettext(
          "%{name} answered 1 question",
          "%{name} answered %{number} questions",
          n,
          name: {:b, actor.name},
          number: number
        )
  end

  defp event_line(%{kind: :proposed, owner: nil, duration: duration}),
    do: rich_gettext("Explore wrote a proposal, after %{duration}.", duration: duration)

  defp event_line(%{kind: :proposed, owner: owner, duration: duration}) do
    if you?(owner),
      do:
        rich_gettext(
          "Explore wrote a proposal, after %{duration}. You confirm next",
          duration: duration
        ),
      else:
        rich_gettext(
          "Explore wrote a proposal, after %{duration}. %{name} confirms next",
          duration: duration,
          name: {:b, owner.name}
        )
  end

  defp event_line(%{
         kind: :no_result,
         end_cause: :run_refused,
         end_detail: "model_key_missing",
         run: run
       }),
       do:
         rich_gettext(
           "Add a model key in Organisation settings › Model providers. The gateway had no model key for attempt %{attempt}",
           attempt: attempt_ref(run)
         )

  defp event_line(%{kind: :no_result, wrote: version}) when is_integer(version),
    do: failed_after(version)

  defp event_line(%{kind: :no_result, outcome: :none, run: run}),
    do: rich_gettext("Attempt %{attempt} ended without a result", attempt: attempt_ref(run))

  defp event_line(%{kind: :no_result, outcome: :refused, run: run}),
    do:
      rich_gettext("Attempt %{attempt} returned a result that did not pass Qory Apiary's check",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :no_result, run: run}),
    do:
      rich_gettext("Attempt %{attempt} ended with an error, so Explore has no result",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :lost, run: run}),
    do:
      rich_gettext("Attempt %{attempt} was lost before it ended, so Explore has no result",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :cancelled, run: run}),
    do:
      rich_gettext("Attempt %{attempt} was cancelled before it ended, so Explore has no result",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :explore_again, actor: actor}) do
    if you?(actor),
      do: gettext("You ran Explore again"),
      else: rich_gettext("%{name} ran Explore again", name: {:b, actor.name})
  end

  defp event_line(%{kind: :confirmed, changed: true, actor: actor}) do
    if you?(actor),
      do: gettext("You changed the proposal and confirmed it. Ready for Shape"),
      else:
        rich_gettext("%{name} changed the proposal and confirmed it. Ready for Shape",
          name: {:b, actor.name}
        )
  end

  defp event_line(%{kind: :confirmed, actor: actor}) do
    if you?(actor),
      do: gettext("You confirmed the proposal. Ready for Shape"),
      else:
        rich_gettext("%{name} confirmed the proposal. Ready for Shape", name: {:b, actor.name})
  end

  defp event_line(%{kind: :closed, actor: nil, reason: reason}), do: closed_words(reason)

  defp event_line(%{kind: :closed, actor: actor}) do
    if you?(actor),
      do: gettext("You closed this work item"),
      else: rich_gettext("%{name} closed this work item", name: {:b, actor.name})
  end

  defp event_line(%{kind: :undone, actor: actor}) do
    if you?(actor),
      do: gettext("You undid the take in, before a run started"),
      else:
        rich_gettext("%{name} undid the take in, before a run started", name: {:b, actor.name})
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
      <.avatar email={@author.email} kind={kind(@author)} size="sm" />
      <div class="q-wi-box">
        <div class="q-wi-box-h">
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
          {gettext(
            "The comment leaves the Thread for everyone. A line in its place shows that you deleted it."
          )}
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
  is a draft to keep, and `error` what was wrong with it: `{:too_long, limit}` or
  `:characters` have words under the field; any other error, a blank text among them,
  has none. The field takes at most as many UTF-16 units as a comment has characters
  (`Apiary.WorkItems.Comment.max_body/0`), never more characters than a comment holds.
  """
  attr :id, :string, default: "work-item-composer"
  attr :number, :integer, required: true, doc: "the work item's number"
  attr :workspace, :string, required: true, doc: "the workspace's name"
  attr :reader, :string, required: true, doc: "the reader's name, for the avatar"
  attr :value, :string, default: nil, doc: "a draft"
  attr :error, :any, default: nil, doc: "what was wrong with the draft, as above"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  def composer(assigns) do
    assigns =
      assign(assigns,
        label: gettext("Comment on work item #%{number}", number: assigns.number),
        message: composer_error(assigns.error),
        maxlength: Apiary.WorkItems.Comment.max_body()
      )

    ~H"""
    <form id={@id} class="q-wi-composer" phx-submit="comment" novalidate>
      <.avatar name={@reader} kind="self" size="sm" />
      <div class="q-wi-box">
        <label for={"#{@id}-body"} class="sr-only">{@label}</label>
        <textarea
          id={"#{@id}-body"}
          name="body"
          placeholder={@label}
          rows="3"
          maxlength={@maxlength}
          aria-describedby={@message && "#{@id}-error"}
          aria-invalid={@message && "true"}
        >{["\n", @value || ""]}</textarea>
        <p :if={@message} id={"#{@id}-error"} class="q-xp-err">
          <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@message}
        </p>
        <div class="q-wi-composer-foot">
          <span class="q-wi-grow">
            {gettext("Members of %{workspace} see this. Qory posts nothing to the %{item}.",
              workspace: @workspace,
              item: SourceComponents.item(@item_noun)
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

  defp composer_error({:too_long, limit}),
    do: gettext("Write at most %{number} characters.", number: Format.number(limit))

  defp composer_error(:characters), do: gettext("Remove the control or invisible characters.")

  # A blank text, or any other error, has no words.
  defp composer_error(_error), do: nil
end
