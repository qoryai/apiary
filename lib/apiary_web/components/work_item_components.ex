defmodule ApiaryWeb.WorkItemComponents do
  # The parts of a work item's page (`/:org/:workspace/work/:number`, which shows the tab
  # it opens on, `…/ticket`, its Ticket tab, `…/stages/:stage_id`, a stage's tab, `…/explore`,
  # Explore's tab with no stage card, and `…/thread`, its Thread), and the status words and
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
  #   * `"answer_draft"`, `"answer"` - the questions form and the gate, on change and on
  #     submit (Run another round): `answers`, a map of each open question's
  #     `public_id` to its answer, `%{"option" => choice, "note" => text}`: the index of
  #     the option picked, or `"own"` for Give your own option, and the text written;
  #     and `comment`, the comment on the whole proposal;
  #   * `"confirm"` - the gate's Confirm under the proposal;
  #   * `"reply"` - the form page Reply: `text`, and `comment`, the review comment's id;
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
  alias Apiary.Harnesses.{Qory, Walk}
  alias ApiaryWeb.BacklogComponents
  alias ApiaryWeb.HarnessComponents
  alias ApiaryWeb.PauseWords
  alias ApiaryWeb.RunComponents
  alias ApiaryWeb.SourceComponents
  alias ApiaryWeb.WorkItemLive.StageComponents

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
    doc:
      "the work item: `:status`, `:owner`, `:ended_by`, and `:run`: its `:of` at the run limit, its `:path` while queued or running"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer or confirm"

  attr :class, :any, default: nil

  def work_item_status(assigns) do
    assigns =
      assign(assigns, words: status_ref(assigns.work_item), hot: hot?(assigns.work_item))

    ~H"""
    <span class={["q-wi-st", @hot && "q-wi-hot", @class]}>
      <.status_mark kind={mark(@work_item, @can_act)} run={@work_item[:run]} /><.rich text={@words} />
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

  def work_item_mark(%{kind: :run} = assigns), do: ~H|<.running_mark class={@class} />|

  def work_item_mark(assigns) do
    ~H"""
    <span class={["q-wi-mk", "q-wi-mk-#{@kind}", @class]} aria-hidden="true"></span>
    """
  end

  attr :liveness, :atom, default: nil
  attr :class, :any, default: nil

  # A running mark is the state's dot of the run's page
  # (`ApiaryWeb.TargetComponents.state_mark/1`): blue and still, as where no heartbeat is
  # read (the Work items list, a later stage's run). With `liveness`, it pulses while the
  # run is alive, and it is amber and still once the run is quiet. `q-ripple` on the dot
  # only adds the rules that hide its ring for reduced motion.
  defp running_mark(assigns) do
    ~H"""
    <span
      class={["inline-grid size-4 flex-none place-items-center", @class]}
      aria-hidden="true"
      data-liveness={@liveness}
    >
      <span class="q-sdot q-sdot-running">
        <span :if={@liveness == :quiet} class="q-dot q-alive-amber"></span>
        <i
          :if={@liveness != :quiet}
          class={if(@liveness == :alive, do: "q-ripple", else: "after:hidden")}
        ></i>
      </span>
    </span>
    """
  end

  attr :kind, :atom, required: true
  attr :run, :any, default: nil

  # The mark on a work item's page: a running mark reads a registered run of Explore's
  # liveness (`running_mark/1`), any other mark is `work_item_mark/1`.
  defp status_mark(%{kind: :run} = assigns) do
    assigns = assign(assigns, :liveness, mark_liveness(assigns.run))

    ~H"""
    <.running_mark liveness={@liveness} />
    """
  end

  defp status_mark(assigns), do: ~H|<.work_item_mark kind={@kind} />|

  defp mark_liveness(%{liveness: liveness, other_stage: false}) when liveness in [:alive, :quiet],
    do: liveness

  defp mark_liveness(_run), do: nil

  @doc false
  def status_words(work_item), do: words_of(at_limit(work_item))

  @doc false
  # no_pool_status/0 is the header's status while the work item's run waits in the queue
  # and no pool that serves the workspace's runs is ready: words and the error mark, for a
  # run of Explore and of a later stage alike.
  def no_pool_status,
    do: %{words: gettext("Waiting: no pool can take the run"), mark: :err}

  # The status on the work item's page, where a queued or running run has a link. The
  # Work items list uses `status_words/1`: its whole row is a link to the work item.
  defp status_ref(%{status: status} = work_item) when status in [:queued, :running],
    do: head_ref(work_item[:run], status_words(work_item))

  defp status_ref(work_item), do: status_words(work_item)

  defp words_of(%{status: :queued}), do: gettext("Explore is queued")
  defp words_of(%{status: :running}), do: gettext("Explore is running")

  # Where the stage lists approvers, the page passes who confirms next as `confirmers`:
  # `:you` for a reader who may confirm, else the approvers, in the gate's order, the
  # reader among them where listed (`others/1`).
  defp words_of(%{status: :confirm, confirmers: :you}), do: gettext("You approve next")

  defp words_of(%{status: :confirm, confirmers: [_ | _] = confirmers}),
    do: confirmers_words(others(confirmers))

  defp words_of(%{status: :confirm, owner: owner}) do
    if you?(owner),
      do: gettext("You approve next"),
      else: gettext("%{name} approves next", name: owner.name)
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

  defp confirmers_words([]), do: gettext("No listed approver may approve")
  defp confirmers_words([one]), do: gettext("%{name} approves next", name: one.name)

  defp confirmers_words([one, other]),
    do: gettext("%{name} or %{other} approves next", name: one.name, other: other.name)

  defp confirmers_words(confirmers),
    do:
      gettext("One of %{number} approvers approves next",
        number: Format.number(length(confirmers))
      )

  @doc false
  def mark(work_item, can_act \\ false),
    do: mark_of(at_limit(work_item), can_act)

  defp mark_of(%{status: :queued}, _can_act), do: :todo
  defp mark_of(%{status: :running}, _can_act), do: :run

  # A proposal can still wait after the work item left Explore (a gate `none` passes on):
  # it waits for no one there (`at_explore` false).
  defp mark_of(%{status: :confirm, at_explore: false}, _can_act), do: :wait_other
  defp mark_of(%{status: :confirm, confirmers: :you}, _can_act), do: :wait
  defp mark_of(%{status: :confirm, confirmers: [_ | _]}, _can_act), do: :wait_other

  defp mark_of(%{status: :confirm, owner: owner}, _can_act),
    do: if(you?(owner), do: :wait, else: :wait_other)

  defp mark_of(%{status: status}, can_act) when status in [:questions, :used_up],
    do: if(can_act, do: :wait, else: :wait_other)

  defp mark_of(%{status: status}, _can_act) when status in [:no_result, :lost, :cancelled],
    do: :err

  defp mark_of(%{status: :shape}, _can_act), do: :ready
  defp mark_of(%{status: status}, _can_act) when status in [:closed, :undone], do: :closed

  @doc false
  def hot?(%{status: :confirm, at_explore: false}), do: false
  def hot?(%{status: :confirm, confirmers: :you}), do: true
  def hot?(%{status: :confirm, confirmers: [_ | _]}), do: false
  def hot?(%{status: :confirm, owner: owner}), do: you?(owner)
  def hot?(_work_item), do: false

  @doc false
  def you?(%{you: true}), do: true
  def you?(_person), do: false

  # The listed approvers without the reader: a listed reader here is one for whom the
  # `work_item.confirm` check fails, as one who may confirm has `:you`.
  defp others(confirmers), do: Enum.reject(confirmers, &you?/1)

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
  def stage_name(:confirm), do: gettext("Approve")
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
  1007 px the rail is a sticky column beside the header and the body; below it, it comes
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
    doc:
      "`:words` and `:mark` in place of the status: under the feature `workflow_model`, and `no_pool_status/0` while no pool can take the queued run"

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
        <%!-- The box clips; its padding leaves room for the ring of a running run's dot. --%>
        <div class="q-wi-meta-wrap -ml-1 -mb-0.5 pt-0.5 pb-0.5 pl-1">
          <p id={"#{@id}-meta"} class="q-wi-meta">
            <.work_item_status :if={!@stage_status} work_item={@work_item} can_act={@can_act} />
            <span :if={@stage_status} id={"#{@id}-stage-status"} class="q-wi-st">
              <.status_mark kind={@stage_status.mark} run={@work_item[:run]} /><.rich text={
                @stage_status.words
              } />
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
      taken in again, takes Qory's label off the ticket, and the comment of the person
      who took it in stays where they wrote one with the take in (`:taken_in_comment`,
      true); a closed one's taken
      in again (`previous`) goes back to closed, and nothing is sent to the
      ticket. After the integration's uninstall (`uninstalled`), that nothing changes on
      the ticket, which keeps Qory's label and comment. With `no_pool`, under what
      Explore does, the line that no pool can take the run, with Open Machines.
    * Explore, queued, a later run (`:run`, `%{attempt:, of:, answers_by:}`): what Explore
      reads, with whose answers, and which run of the take in is queued, or with
      `no_pool`, the line that no pool can take the run in its place. No Undo.
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

  attr :no_pool, :map,
    default: nil,
    doc:
      "while the run waits in the queue and no pool can take it, why, as `explore_tab/1` takes it; else nil"

  slot :badge,
    doc:
      "the state in place of the step's badge: the stage's, where the card is the stage's one card at Explore under the feature `workflow_model`"

  attr :stage_name, :string,
    default: nil,
    doc: "the stage's name in place of the step's, where the card is the stage's one card"

  attr :commenting, :boolean,
    default: false,
    doc: "whether Explore's tab has the comment field under the questions"

  attr :points, :integer,
    default: 0,
    doc: "the points of the stage's open escalation, while the questions wait for answers"

  attr :needs_path, :string,
    default: "#work-item-needs",
    doc: "where the block \"What the run needs from you\" is"

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
        <.status_mark kind={@mark} run={@run} />
        <h2 id={"#{@id}-h"}>{@stage_name || stage_name(@stage)}</h2>
        <.step_badge :if={@badge == []} status={@status} mine={@mine} run={@run} />
        {render_slot(@badge)}
        <.run_link
          :if={@status in [:queued, :running] and !(@run && @run[:other_stage])}
          id={"#{@id}-run-link"}
          run={@run}
        />
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
        no_pool={@no_pool}
        commenting={@commenting}
        points={@points}
        needs_path={@needs_path}
      />
    </section>
    """
  end

  @doc """
  The line "Waits for you: N points" of an open escalation, which links to the block
  "What the run needs from you" at `path`: an anchor on the page, or the Explore tab's
  path with it.
  """
  attr :id, :string, default: "work-item-stage-waits"
  attr :count, :integer, required: true
  attr :path, :string, default: "#work-item-needs"

  def waits_line(assigns) do
    ~H"""
    <p id={@id}>
      <.link href={@path} class="q-link">
        {ngettext("Waits for you: %{count} point", "Waits for you: %{count} points", @count,
          count: Format.number(@count)
        )}
      </.link>
    </p>
    """
  end

  attr :status, :atom, required: true
  attr :mine, :boolean, required: true
  attr :run, :map, default: nil

  defp step_badge(%{status: :queued} = assigns),
    do: ~H|<.badge class="q-wi-badge">{gettext("Queued")}</.badge>|

  defp step_badge(%{status: :running} = assigns) do
    ~H"""
    <.badge color={if(quiet?(@run), do: "warning", else: "info")} class="q-wi-badge">
      {gettext("Running")}
    </.badge>
    """
  end

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
  attr :no_pool, :map, default: nil
  attr :commenting, :boolean, default: false
  attr :points, :integer, default: 0
  attr :needs_path, :string, default: "#work-item-needs"

  # A later run of the take in: what it reads, with whose answers, and which run is
  # queued, or that no pool can take it. Undo is only until the first run of a take in
  # starts.
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
        queued: rich_gettext("%{attempt} is queued.", attempt: run_place(run))
      )

    ~H"""
    <p class="q-wi-icon-line">
      <.run_icon /><span><.rich text={@line} /></span>
    </p>
    <.no_pool_line :if={@no_pool} id={"#{@id}-no-pool"} no_pool={@no_pool} />
    <p :if={!@no_pool} id={"#{@id}-run"}><.rich text={@queued} /></p>
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
    <p class="q-wi-icon-line">
      <.run_icon /><span><.rich text={@line} /></span>
    </p>
    <.no_pool_line :if={@no_pool} id={"#{@id}-no-pool"} no_pool={@no_pool} />
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
    <p id={"#{@id}-line"}><.rich text={@line} /></p>
    """
  end

  defp step_body(%{status: :questions} = assigns) do
    n = length(assigns.run.questions)
    number = Format.number(n)

    assigns =
      assign(assigns,
        line:
          cond do
            not assigns.can_act ->
              nil

            assigns.commenting ->
              ngettext(
                "Answer the question or add a comment, then run another round.",
                "Answer the %{number} questions or add a comment, then run another round.",
                n,
                number: number
              )

            true ->
              ngettext(
                "Answer the question, then run another round.",
                "Answer the %{number} questions, then run another round.",
                n,
                number: number
              )
          end,
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
    <.waits_line :if={@points > 0} count={@points} path={@needs_path} />
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
              rich_ngettext(
                "%{number} question is still open after %{attempt}, the last attempt of this take in.",
                "%{number} questions are still open after %{attempt}, the last attempt of this take in.",
                length(run.questions),
                number: Format.number(length(run.questions)),
                attempt:
                  place_ref(
                    run,
                    gettext("attempt %{attempt} of %{of}",
                      attempt: shown_number(run[:attempt]),
                      of: Format.number(run.of)
                    )
                  )
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

  # A reader who may act reads what to do; one who may not, whose turn it is: the stage's
  # approvers where it lists them and the reader may not confirm (`confirmers`), else
  # the owner. Without an owner there is no one to name: no line.
  defp step_body(%{status: :confirm} = assigns) do
    owner = assigns.work_item[:owner]
    confirmers = assigns.work_item[:confirmers]
    listed = match?([_ | _], confirmers)
    others = if listed, do: others(confirmers), else: []

    assigns =
      assign(assigns,
        # A listed reader for whom the `work_item.confirm` check fails, beside others.
        refused: not assigns.can_act and others != [] and others != confirmers,
        line:
          cond do
            assigns.can_act ->
              gettext("Approve the proposal, or add a comment and run another round.")

            listed ->
              confirmers_step(others)

            you?(owner) ->
              gettext("You approve next")

            owner ->
              gettext("%{name} approves next", name: owner.name)

            true ->
              nil
          end
      )

    ~H"""
    <p :if={@line} id={"#{@id}-line"}>{@line}</p>
    <p :if={@refused} id={"#{@id}-refused"}>
      {gettext("You are listed as an approver, but you may not approve in this workspace.")}
    </p>
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
              "You approved the proposal %{when}. Shape is the plan and its acceptance criteria.",
              when: at
            ),
          else:
            rich_gettext(
              "%{name} approved the proposal %{when}. Shape is the plan and its acceptance criteria.",
              name: by.name,
              when: at
            )
        )
      )

    ~H"""
    <p><.rich text={@line} /></p>
    """
  end

  defp confirmers_step([]),
    do: gettext("You are the only listed approver, but you may not approve in this workspace.")

  defp confirmers_step([one]),
    do: gettext("%{name} approves the proposal or runs another round.", name: one.name)

  defp confirmers_step([one, other]),
    do:
      gettext("%{name} or %{other} approves the proposal or runs another round.",
        name: one.name,
        other: other.name
      )

  defp confirmers_step(confirmers),
    do:
      gettext(
        "One of the stage's %{number} approvers approves the proposal or runs another round.",
        number: Format.number(length(confirmers))
      )

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
           "Add a model key in Organisation settings › Model providers. The gateway had no model key for %{attempt}.",
           attempt: attempt_words_lower(run)
         )

  defp no_result_line(:no_result, %{state: :failed, wrote: version} = run)
       when is_integer(version),
       do: place_ref(run, failed_after(version))

  defp no_result_line(:no_result, run) do
    case run[:outcome] do
      :none ->
        rich_gettext("%{attempt} ended without a result.", attempt: attempt_words(run))

      :refused ->
        rich_gettext(
          "%{attempt} returned a result that did not pass Qory Apiary's check, so Explore has no result.",
          attempt: attempt_words(run)
        )

      _error ->
        rich_gettext("%{attempt} ended with an error, so Explore has no result.",
          attempt: attempt_words(run)
        )
    end
  end

  defp no_result_line(:lost, run),
    do:
      rich_gettext("%{attempt} was lost before it ended, so Explore has no result.",
        attempt: attempt_words(run)
      )

  defp no_result_line(:cancelled, run),
    do:
      rich_gettext("%{attempt} was cancelled before it ended, so Explore has no result.",
        attempt: attempt_words(run)
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
  defp used_up_line(%{state: :failed, wrote: version} = run) when is_integer(version),
    do: place_ref(run, failed_after(version))

  defp used_up_line(%{end_cause: :run_refused, end_detail: "model_key_missing"} = run),
    do:
      rich_gettext(
        "Add a model key in Organisation settings › Model providers. The gateway had no model key for %{attempt}. That was attempt %{number} of %{of}, the last attempt of this take in.",
        attempt: attempt_words_lower(run),
        number: Format.number(run.attempt),
        of: Format.number(run.of)
      )

  defp used_up_line(run),
    do:
      rich_gettext(
        "%{attempt} ended without a result. That was attempt %{number} of %{of}, the last attempt of this take in.",
        attempt: attempt_words(run),
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
          "You took this in %{when}. Until a run starts, you can undo the take in. %{integration} is no longer connected, so the label and the comment that Qory Apiary added stay on the %{item}.",
          when: at,
          integration: integration,
          item: assigns.item
        )

      {true, true, false} ->
        rich_gettext(
          "You took this in %{when}. %{integration} is no longer connected, so the label and the comment that Qory Apiary added stay on the %{item}.",
          when: at,
          integration: integration,
          item: assigns.item
        )

      {true, false, true} ->
        rich_gettext(
          "%{name} took this in %{when}. Until a run starts, you can undo the take in. %{integration} is no longer connected, so the label and the comment that Qory Apiary added stay on the %{item}.",
          name: by.name,
          when: at,
          integration: integration,
          item: assigns.item
        )

      {true, false, false} ->
        rich_gettext(
          "%{name} took this in %{when}. %{integration} is no longer connected, so the label and the comment that Qory Apiary added stay on the %{item}.",
          name: by.name,
          when: at,
          integration: integration,
          item: assigns.item
        )

      {false, true, true} ->
        if work_item[:taken_in_comment],
          do:
            rich_gettext(
              "You took this in %{when}. Until a run starts, you can undo the take in: Qory Apiary removes its label from the %{item}, and your comment stays.",
              when: at,
              item: assigns.item
            ),
          else:
            rich_gettext(
              "You took this in %{when}. Until a run starts, you can undo the take in: Qory Apiary removes its label from the %{item}.",
              when: at,
              item: assigns.item
            )

      {false, true, false} ->
        rich_gettext("You took this in %{when}.", when: at)

      {false, false, true} ->
        if work_item[:taken_in_comment],
          do:
            rich_gettext(
              "%{name} took this in %{when}. Until a run starts, you can undo the take in: Qory Apiary removes its label from the %{item}, and the comment by %{name} stays.",
              name: by.name,
              when: at,
              item: assigns.item
            ),
          else:
            rich_gettext(
              "%{name} took this in %{when}. Until a run starts, you can undo the take in: Qory Apiary removes its label from the %{item}.",
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

  # A run in the Thread, by its attempt in the take in, as a link to the run's page where
  # the run has a page, with no number.
  defp attempt_ref(%{path: path, attempt: attempt}) when is_binary(path),
    do: {:link, path, shown_number(attempt), "q-wi-run"}

  defp attempt_ref(run), do: shown_number(run[:attempt])

  # A run's words in a block ("Attempt 2", or a whole line), as a link to the run's page
  # where the page has one, with the run's number in its workspace after the words and
  # before a full stop: "Attempt 2 (Run 14)", "Explore is queued (Run 14)." No link, no number.
  @doc false
  def place_ref(%{path: path} = run, place) when is_binary(path),
    do: {:link, path, numbered(place, run_number(run)), "text-accent"}

  def place_ref(_run, place), do: place

  # The status in the header under the title: linked as `place_ref/2`, with no number.
  @doc false
  def head_ref(%{path: path}, words) when is_binary(path),
    do: {:link, path, words, "text-accent"}

  def head_ref(_run, words), do: words

  # The run's number in its workspace, as a word: "Run 14". `Workflow` has the attempt
  # under `number`, so its runs have this number under `run_number`.
  defp run_number(%{run_number: number}), do: number
  defp run_number(run), do: run[:number]

  defp numbered(place, number) when is_integer(number) do
    run = {:nowrap, gettext("Run %{run}", run: number)}

    case without_stop(place) do
      {:stop, words} -> rich_gettext("%{words} (%{run}).", words: words, run: run)
      :none -> rich_gettext("%{words} (%{run})", words: place, run: run)
    end
  end

  defp numbered(place, _number), do: place

  # Rich text without the full stop that ends it.
  defp without_stop(text) when is_binary(text) do
    if String.ends_with?(text, "."),
      do: {:stop, String.replace_suffix(text, ".", "")},
      else: :none
  end

  defp without_stop([_ | _] = rich) do
    {last, rest} = List.pop_at(rich, -1)

    case without_stop(last) do
      {:stop, words} -> {:stop, rest ++ [words]}
      :none -> :none
    end
  end

  defp without_stop(_rich), do: :none

  attr :id, :string, required: true
  attr :run, :map, default: nil, doc: "the run; a run with no path or no number shows nothing"

  # A card's top row, after its badge: "Run 14", as a link to that run's page.
  @doc false
  def run_link(assigns) do
    assigns = assign(assigns, :number, assigns.run && run_number(assigns.run))

    ~H"""
    <.link
      :if={is_integer(@number) and is_binary(@run[:path])}
      id={@id}
      navigate={@run.path}
      class="text-accent shrink-0 whitespace-nowrap"
    >
      {gettext("Run %{run}", run: @number)}
    </.link>
    """
  end

  @doc false
  # attempt_words/1 is the words "Attempt 2 (Run 14)", linked to that run's page where the
  # run has one, else "Attempt 2" (`place_ref/2`). A text about a run binds them, so the
  # words are one link.
  def attempt_words(run), do: place_ref(run, run_place(run))

  # The same words inside a sentence: "attempt 2 (Run 14)", else "attempt 2".
  defp attempt_words_lower(run),
    do: place_ref(run, run_place_lower(run))

  defp run_place_lower(run),
    do: gettext("attempt %{attempt}", attempt: shown_number(run[:attempt]))

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

  attr :id, :string, required: true
  attr :no_pool, :map, required: true

  # The step card's line while no pool can take the queued run, with Open Machines where
  # the reader may open the workspace's Machines page. The error mark is in the column of
  # the run's icon.
  defp no_pool_line(assigns) do
    ~H"""
    <p id={@id} class="q-wi-icon-line">
      <span class="q-wi-play inline-grid size-6 place-items-center" aria-hidden="true">
        <.icon name="hero-exclamation-triangle-micro" class="size-4 text-error" />
      </span>
      <span>
        {gettext("No pool can take the run.")}
        <.link :if={@no_pool.path} id={"#{@id}-open"} navigate={@no_pool.path} class="text-accent">
          {gettext("Open Machines")}
        </.link>
      </span>
    </p>
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
              "The %{item} stays open on %{integration} with the label that Qory Apiary added, and Qory Apiary posts nothing more there.",
              integration: @integration,
              item: SourceComponents.item(@item_noun)
            )}
          <% true -> %>
            {gettext(
              "The %{item} stays open on %{integration} with the label that Qory Apiary added, and Qory Apiary posts nothing more there. To bring the work item back, use Take in again in the Backlog.",
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
        "Qory Apiary removed its label from the %{item} and left its comment. To bring the work item back, use Take in again.",
        item: item
      )

  defp end_second(:closed, integration, item),
    do:
      gettext(
        "The %{item} is still open on %{integration} with the label that Qory Apiary added. To bring the work item back, use Take in again.",
        integration: integration,
        item: item
      )

  ## Details

  @doc """
  A work item's facts: who owns it, its ticket (a link out, where the integration sent it
  from, who filed it and when), its collection, labelled with its source's word for one
  (`collection_noun`, `SourceComponents.collection/1`), its first letter in upper case,
  when and by whom it was taken in, its
  runs, and how it ended. From 1007 px a quiet list beside the page
  under its heading; below it, folded behind a button that says who owns it and the
  ticket's key, which opens it in place. A test work item has no ticket and no
  collection: no row and no key for them.

  It reads the work item's `:owner`, `:key`, `:url`, `:repository`,
  `:taken_in_by`, `:taken_in_at`,
  `:runs` (`nil` until a run of the current take in is handed over, or `%{latest: %{attempt:, path:}, count:,
  running:, queued:}`), `:ended_by`
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

  attr :queued, :any,
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
        <%= if @process_version do %>
          <dt>{gettext("Process")}</dt>
          <dd id={"#{@id}-process"}>
            {gettext("Version %{version}", version: Format.number(@process_version))}
          </dd>
        <% end %>
        <dt>{gettext("Runs")}</dt>
        <dd id={"#{@id}-runs"}>
          <span :if={@runs} class="q-wi-runs"><.rich text={runs_line(@runs)} /></span>
          <span :if={!@runs and @queued} id={"#{@id}-runs-queued"}><.rich text={@queued} /></span>
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

  defp runs_line(%{latest: latest, count: count, running: running} = runs) do
    state =
      cond do
        runs[:queued] -> gettext("queued")
        running > 0 -> gettext("%{count} running", count: running)
        true -> gettext("ended")
      end

    rich_ngettext(
      "%{attempt} · %{count} run, %{state}",
      "%{attempt} · %{count} runs, %{state}",
      count,
      attempt: attempt_words(latest),
      state: state
    )
  end

  ## The tabs

  @doc """
  A work item's tabs: Ticket (`ticket_path`), named with its source's word for its items,
  "Bug" for a source that calls them bugs (`item_noun`), Explore (`explore_path`) or one tab
  for each of `stages`, and Thread (`thread_path`), with the count of people's comments
  where there are any; named "Work item #%{number}". A test work item has no ticket
  (`ticket` false), so no Ticket tab.
  """
  attr :id, :string, default: "work-item-tabs"
  attr :number, :integer, required: true, doc: "the work item's number"

  attr :current, :any,
    required: true,
    doc: "the page's tab: `:ticket`, `:explore`, `:thread` or a stage tab's key"

  attr :ticket_path, :string, required: true, doc: "the Ticket tab, `/work/:number/ticket`"
  attr :explore_path, :string, default: nil, doc: "Explore's tab, with no `stages`"

  attr :stages, :list,
    default: nil,
    doc:
      "the stage tabs in their order, `%{key:, name:, path:}`, under the stage's name; nil for Explore's tab alone"

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
      <:tab :if={is_nil(@stages)} key={:explore} patch={@explore_path} icon="hero-light-bulb">
        {stage_name(:explore)}
      </:tab>
      <:tab
        :for={stage <- @stages || []}
        key={stage.key}
        patch={stage.path}
        icon={if stage.key == :explore, do: "hero-light-bulb", else: "hero-clipboard-document-list"}
      >
        {stage.name}
      </:tab>
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
  Explore's tab, top to bottom:

    * while a run is queued or runs: the run line, which run of the take in it is (linked
      to its page), its state and its time, and what the run does next, with whose
      answers from a second run. While the run waits in the queue, before a pool claims
      it, and no pool can take it (`no_pool`), an error box in place of what the run does
      next: that no pool can take the attempt, why, and Open Machines;
    * an undone work item (`:undone`): that the take in was undone before a run started,
      whether a run of it waited or the take in queued none; a closed work item whose
      take in queued no run (`:closed`): who closed it and when (`ended_tab_words/2`);
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
    * the newest proposal of the take in (`proposal`), with its version; confirmed, who
      confirmed it and when (`:confirmed_by`, `:confirmed_at`). Below 1007 px the
      review comments are at the top of its text (`review_comments/1`); from 1007 px the
      rail has them;
    * the run's decisions (`decision?/1`), where the take in has no open question: a
      frame between the proposal and the gate, each decision folded to one line; at the
      gate, a reader who may change them (`can_change`, `work_item.answer`) picks
      another option, or writes one, in its fold. A change is a draft of the page until
      Run another round sends it;
    * at the gate: for a reader who may send review comments (`can_send`,
      `work_item.review_comment`), the comment on the whole proposal (`comment`, its
      draft); for that reader, or one who may change the decisions, Run another round
      (`"answer"`), which starts the next run with the comment, every open review comment
      and the changed decisions, enabled where there is one of them; Confirm
      (`"confirm"`), for a reader who may confirm (`can_act`), disabled while a changed
      decision is a draft; under them, why the page's last move on the tab was not made
      (`move_error`), where it is given;
    * the questions (`questions`): the closed ones first, each folded to one line, then
      the run's decisions, each folded to one line, then the open ones; with the form for
      a reader who may answer them (`can_act`, while Explore needs answers): for each
      decision, for a reader who may change it (`can_change`), its options in its fold;
      for each open question its options, Give your own option,
      and one field; under them, for a reader who may send review comments (`can_send`)
      where there is a proposal, the comment on the whole proposal; then Run another
      round (`"answer"`), which sends the answers, the comment and the open review
      comments in one run, enabled where there is an answer, a comment or an open review
      comment the reader may send; under the form, the page's line (`move_error`) where
      it is given. While a run runs, the open questions show as text;
    * one fold of the take in's runs, oldest first, with what each wrote, and the
      `artifacts` slot; at a stage after Explore, the fold of `foot` in its place
      (`foot_record/1`); then the earlier take ins (`earlier_take_ins`), each folded with
      its runs, which counted apart.

  A run is a map: `:id` (its `rn_` public id) and `:path`, `:attempt` and `:of`, `:state`
  (`:pending`, `:running`, `:completed`, `:failed`, `:cancelled` or `:lost`),
  `:started_at`, `:ended_at`, `:duration` (how long it took, in words), `:outcome`
  (`:proposal`, `:questions`, `:error`, `:none` or `:refused`), `:end_cause`,
  `:end_detail`, `:wrote` (the version of the proposal it pushed, nil for none) with
  `:wrote_proposal` (that version, `%{message:}`), and `:asked` (how many questions it
  wrote).

  A proposal is `%{version:, message:}`, its text Markdown. A question is `%{id:, number:,
  text:, context:, options:, state:, answer:, history:, follows:, decision:}` as
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
  `form_error`, `:blank` where the form gave no answer and no comment, and no review
  comment was sent: none is open, or the reader may not send review comments
  (`can_send`); `:stale` where
  the questions changed after the page showed them and no answer was sent. The focus goes
  to the first question at fault, again after each send (`submits`, counted by the
  page).

  `no_pool` is why no pool can take the queued run, as the Machines set-up step reads the
  pools that serve the workspace's runs: `%{pools:, workspace:, path:}`, the pools' lines
  of `Apiary.WorkspaceSetup.pools/1`, the workspace's name, and the path of its Machines
  page, nil for a reader who may not open it; nil while a pool can take the run.
  """
  attr :id, :string, default: "work-item-explore"
  attr :work_item, :map, required: true, doc: "the work item, with its latest run as `:run`"
  attr :earlier_runs, :list, default: [], doc: "the take in's earlier runs, oldest first"
  attr :earlier_take_ins, :list, default: [], doc: "the earlier take ins, oldest first"
  attr :proposal, :map, default: nil, doc: "the newest proposal of the take in, or nil"

  attr :questions, :list,
    default: [],
    doc: "the questions of the newest questions that a run of the current take in wrote"

  attr :questions_version, :integer, default: nil, doc: "the newest questions' version"
  attr :review_comments, :list, default: [], doc: "the review comments on its proposals"
  attr :can_act, :boolean, default: false, doc: "whether the reader may answer or confirm"

  attr :can_send, :boolean,
    default: false,
    doc: "whether the reader may send the open review comments (`work_item.review_comment`)"

  attr :can_change, :boolean,
    default: false,
    doc: "whether the reader may change the run's decisions (`work_item.answer`)"

  attr :reply_path, :any,
    default: nil,
    doc: "a function of a review comment's id: Reply's page, where the reader may reply now"

  attr :backlog_off, :boolean,
    default: false,
    doc:
      "whether the Backlog leaves its ticket out while its repository is assigned there: its switch is off, or it has no items (`Apiary.WorkItems.backlog_off/2`)"

  attr :answers, :map, default: %{}, doc: "the questions form's draft, by question id"
  attr :comment, :string, default: "", doc: "the draft of the comment on the whole proposal"
  attr :errors, :map, default: %{}, doc: "the questions form's errors, by question id"

  attr :form_error, :atom,
    default: nil,
    doc:
      "`:blank` where the form gave no answer and no comment, and no review comment was sent: none is open, or the reader may not send review comments (`can_send`); `:stale` where the questions changed after the page showed them"

  attr :submits, :integer,
    default: 0,
    doc: "how many times the form was sent; the focus goes to the first error after each"

  attr :move_error, :any,
    default: nil,
    doc: "why the page's last move on the tab was not made, with its fix first; nil for none"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  attr :item_noun, :map,
    default: nil,
    doc:
      "what its ticket's source calls its items, `%{one:, other:}` (`Apiary.Adapters.item_noun/1`); nil for ticket and tickets"

  attr :foot, :map,
    default: nil,
    doc: "at a stage after Explore, the fold's runs and summary (`foot_record/1`); else nil"

  attr :verdicts, :list,
    default: [],
    doc:
      "the stage runs of the take in (`ApiaryWeb.WorkItemLive.Workflow.page/2`'s `runs`): a fold row shows the workflow, the round and the verdict of the one with its attempt"

  attr :no_pool, :map,
    default: nil,
    doc:
      "why no pool can take the queued run, `%{pools:, workspace:, path:}`; nil while a pool can take it"

  slot :artifacts, doc: "the work item's artifacts, in the fold of its runs"

  slot :needs,
    doc:
      "the block \"What the run needs from you\" of an open escalation, at the top of the tab, in place of the banner of a run with no result"

  def explore_tab(assigns) do
    work_item = at_limit(assigns.work_item)
    status = explore_status(work_item.status, work_item[:run])
    {run, earlier_runs} = explore_runs(work_item[:run], assigns.earlier_runs)
    view = tab_view(assigns.foot, status, run)
    running = view == :wait
    open = Enum.count(assigns.review_comments, &(&1.state == :open))
    {decisions, questions} = Enum.split_with(assigns.questions, &decision?/1)
    # The decisions sit in the questions frame, above the open questions, where it has
    # open questions; otherwise in the Decisions frame between the proposal and the
    # gate.
    inline = Enum.any?(questions, &(&1.state == :open))
    gate = status == :confirm

    # Sent decisions are text: only a decision still `:decided` takes a change.
    change =
      assigns.can_change and Enum.any?(decisions, &(&1.state == :decided)) and
        (gate or (status == :questions and assigns.can_act))

    assigns =
      assign(assigns,
        now: now(assigns),
        status: status,
        run: run,
        earlier_runs: earlier_runs,
        view: view,
        # The proposal shown is not one that the latest run wrote.
        earlier: not is_nil(assigns.proposal) and run[:wrote] != assigns.proposal.version,
        running: running,
        groups: Enum.filter(earlier_runs, &answered?/1),
        # A stage after Explore can wait for answers once the proposal is confirmed.
        confirmed:
          (status == :shape or (status == :questions and work_item[:confirmed_at] != nil)) &&
            %{by: work_item.confirmed_by, at: work_item.confirmed_at},
        mode: if(status == :questions and assigns.can_act, do: :form, else: :read),
        # The gate shows its controls by the reader's rights; with neither, only the line
        # of a move that was not made, which the page shows after a send of a reader who
        # stopped being an approver.
        gate:
          gate and
            (assigns.can_act or assigns.can_send or change or not is_nil(assigns.move_error)),
        decisions: decisions,
        shown_questions: if(inline, do: assigns.questions, else: questions),
        decisions_frame: if(inline, do: [], else: decisions),
        change: change,
        changed: change and Enum.any?(decisions, &decision_changed?(&1, assigns.answers[&1.id])),
        open_comments: open,
        # The latest run, where it is one: a run not yet queued has no workspace.
        latest: run && run[:workspace_id] && run,
        item: SourceComponents.item(assigns.item_noun),
        # Before a pool claims the run, it has no state.
        no_pool:
          if(running and wait_status(status, run) == :queued and is_nil(run[:state]),
            do: assigns.no_pool
          )
      )

    ~H"""
    <div id={@id} class="q-xp">
      <.run_line :if={@running} id={"#{@id}-run"} run={@run} now={@now} />
      <.no_pool_box :if={@no_pool} id={"#{@id}-no-pool"} run={@run} no_pool={@no_pool} />
      <.explore_wait
        :if={@running and !@no_pool}
        id={"#{@id}-wait"}
        status={wait_status(@status, @run)}
        run={@run}
        groups={@groups}
        item={@item}
        test={@work_item[:test] == true}
      />
      {render_slot(@needs)}
      <.no_result
        :if={@view == :no_result and @needs == []}
        id={"#{@id}-none"}
        run={@run}
        earlier={@earlier}
      />
      <.ended
        :if={@view in [:closed, :undone]}
        id={"#{@id}-#{@view}"}
        work_item={@work_item}
        now={@now}
      />
      <.proposal_frame
        :if={@proposal}
        id={"#{@id}-proposal"}
        run={%{proposal: @proposal, version: @proposal.version, attempt: @run[:attempt]}}
        confirmed={@confirmed}
        earlier={(@needs != [] or @view == :no_result) and @earlier}
        now={@now}
      >
        <:comments :if={@review_comments != []}>
          <.review_comments
            id={"#{@id}-proposal-review"}
            comments={@review_comments}
            reply_path={!@running && @reply_path}
            reading={@running && @run}
          />
        </:comments>
      </.proposal_frame>
      <.decisions_frame
        :if={@decisions_frame != []}
        id={"#{@id}-decisions"}
        decisions={@decisions_frame}
        change={@change and @gate}
        form={"#{@id}-gate"}
        answers={@answers}
        errors={@errors}
        submits={@submits}
        now={@now}
      />
      <.gate
        :if={@gate}
        id={"#{@id}-gate"}
        number={@work_item.number}
        open={if @can_send, do: @open_comments, else: 0}
        comment={@comment}
        can_confirm={@can_act}
        can_send={@can_send}
        can_change={@change and @decisions_frame != []}
        changed={@changed}
        decisions={@decisions != []}
        error={send_words(@move_error, @form_error)}
      />
      <.questions_frame
        :if={@shown_questions != []}
        id={"#{@id}-questions"}
        number={@work_item.number}
        questions={@shown_questions}
        change={@change}
        mode={@mode}
        running={@running}
        answers={@answers}
        errors={@errors}
        form_error={@form_error}
        move_error={@move_error}
        submits={@submits}
        now={@now}
        comment={@comment}
        commenting={@can_send and @proposal != nil}
        open_comments={if @can_send, do: @open_comments, else: 0}
      />
      <.record
        :if={@foot != nil or @earlier_runs != [] or @latest != nil or @artifacts != []}
        id="work-item-record"
        number={@work_item.number}
        runs={if @foot, do: @foot.runs, else: @earlier_runs ++ List.wrap(@latest)}
        latest={if @foot, do: @foot.latest, else: @latest}
        pieces={@foot && @foot.pieces}
        proposal={@proposal}
        questions_version={@questions_version}
        verdicts={@verdicts}
        item={@item}
        now={@now}
      >
        {render_slot(@artifacts)}
      </.record>
      <.earlier_take_ins
        :if={@earlier_take_ins != []}
        id={"#{@id}-take-ins"}
        number={@work_item.number}
        take_ins={@earlier_take_ins}
        item={@item}
        now={@now}
      />
    </div>
    """
  end

  ## A stage's tab

  @doc """
  The tab of a stage that runs a workflow, other than Explore's (`explore_tab/1`), top to
  bottom: while a run is queued or runs, its line and what it does next; the review comments
  below 1007 px; the open questions, as text, or on the current stage's tab where the stage
  waits for answers, with the form of Explore's tab for a reader who may answer them
  (`can_act`), with the comment on the stage's outputs for a reader who may send it
  (`can_send`), and Run another round; one frame for each of `outputs`; on the current
  stage's tab at its gate (`round_gate`), the run's decisions and the gate's Run another
  round, with the comment, for a reader who may change them (`can_change`) or send it;
  Confirm where the stage has a `proposal` output and its proposal waits; the closed
  questions where none is open; the record block (`record`); the earlier take ins.

  An output is `%{type:, version:, open:, read:}`: `read` is `%{message:, rendered:}` once its
  text is read, nil for a version with no Markdown, which has the `row` slot in its place, and
  `:unread` for a folded frame that was not opened (`"open_frame"`).
  """
  attr :id, :string, default: "work-item-tab"
  attr :stage, :map, required: true, doc: "the stage: `:name` and `:outputs`, its types"
  attr :work_item, :map, required: true, doc: "the work item, with its latest run as `:run`"
  attr :runs, :list, default: [], doc: "the stage's runs of the take in, oldest first"
  attr :take_ins, :list, default: [], doc: "the earlier take ins with the stage's runs"
  attr :outputs, :list, default: []
  attr :questions, :list, default: []
  attr :review_comments, :list, default: []
  attr :current, :boolean, default: false, doc: "whether it is the current stage's tab"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer the questions, or confirm"

  attr :can_change, :boolean,
    default: false,
    doc: "whether the reader may change the run's decisions (`work_item.answer`)"

  attr :can_send, :boolean,
    default: false,
    doc: "whether the reader may send the open review comments (`work_item.review_comment`)"

  attr :round_gate, :boolean,
    default: false,
    doc: "whether the stage waits at its gate"

  attr :answers, :map, default: %{}, doc: "the questions form's draft, by question id"
  attr :comment, :string, default: "", doc: "the draft of the comment on the stage's outputs"
  attr :errors, :map, default: %{}, doc: "the questions form's errors, by question id"
  attr :form_error, :atom, default: nil
  attr :submits, :integer, default: 0

  attr :reply_path, :any,
    default: nil,
    doc: "a function of a review comment's id, or nil or false"

  attr :move_error, :any, default: nil
  attr :record, :boolean, default: true, doc: "whether it has the record block"

  attr :verdicts, :list,
    default: [],
    doc:
      "the stage runs of the take in (`ApiaryWeb.WorkItemLive.Workflow.page/2`'s `runs`): a fold row shows the workflow, the round and the verdict of the one with its attempt"

  attr :now, :any, default: nil
  attr :item_noun, :map, default: nil
  slot :artifacts, doc: "the stage's artifacts, in the record block"

  slot :row, doc: "an output's artifact row, for a version with no Markdown; takes its type"

  def stage_tab(assigns) do
    run = List.last(assigns.runs)
    running = match?(%{place: place} when place in [:queued, :running], run)
    {open, closed} = Enum.split_with(assigns.review_comments, &(&1.state == :open))
    open_questions? = Enum.any?(assigns.questions, &(&1.state == :open))
    types = assigns.stage.outputs
    {decisions, others} = Enum.split_with(assigns.questions, &decision?/1)
    form? = assigns.current and assigns.work_item.status == :questions and assigns.can_act
    round_gate = assigns.current and assigns.round_gate and not running and not open_questions?

    # Sent decisions are text: only a decision still `:decided` takes a change.
    change =
      assigns.can_change and Enum.any?(decisions, &(&1.state == :decided)) and
        (round_gate or form?)

    # At the gate the decisions sit in the Decisions frame, above the gate, as on Explore's
    # tab; elsewhere in the questions frame.
    decisions_frame = if round_gate and change, do: decisions, else: []

    assigns =
      assign(assigns,
        now: now(assigns),
        mode: if(form?, do: :form, else: :read),
        change: change,
        changed: change and Enum.any?(decisions, &decision_changed?(&1, assigns.answers[&1.id])),
        decisions_frame: decisions_frame,
        closed_questions: if(decisions_frame == [], do: assigns.questions, else: others),
        round:
          round_gate and
            (decisions_frame != [] or assigns.can_send or not is_nil(assigns.move_error)),
        sendable: if(assigns.can_send, do: length(open), else: 0),
        item: SourceComponents.item(assigns.item_noun),
        run: run,
        running: running,
        open_comments: open,
        closed_comments: closed,
        open_questions?: open_questions?,
        groups: Enum.filter(assigns.runs, &(&1[:answered_by] != nil)),
        # The stage with a proposal output has Confirm: a proposal waits for it.
        confirm: assigns.current and assigns.work_item.status == :confirm and "proposal" in types,
        pieces:
          StageComponents.output_versions(%{
            outputs: Enum.map(assigns.outputs, &Map.take(&1, [:type, :version]))
          })
      )

    ~H"""
    <div id={@id} class="q-xp">
      <.run_line :if={@running} id={"#{@id}-run"} run={@run} now={@now} />
      <.stage_wait
        :if={@running}
        id={"#{@id}-wait"}
        stage={@stage}
        run={@run}
        groups={@groups}
        item={@item}
      />
      <div :if={@review_comments != []} class="q-xp-rc-inline">
        <.review_comments
          id={"#{@id}-review"}
          comments={@review_comments}
          reply_path={!@running && @reply_path}
          reading={@running && @run}
          questions_id={"#{@id}-questions"}
        />
      </div>
      <.questions_frame
        :if={@open_questions?}
        id={"#{@id}-questions"}
        number={@work_item.number}
        questions={@questions}
        change={@change}
        mode={@mode}
        running={@running}
        answers={@answers}
        errors={@errors}
        form_error={@form_error}
        move_error={@move_error}
        submits={@submits}
        now={@now}
        comment={@comment}
        commenting={@can_send}
        open_comments={@sendable}
        updates={:outputs}
      />
      <.output_frame
        :for={output <- @outputs}
        id={"#{@id}-output-#{output.type}"}
        number={@work_item.number}
        output={output}
      >
        {render_slot(@row, output.type)}
      </.output_frame>
      <.decisions_frame
        :if={@decisions_frame != []}
        id={"#{@id}-decisions"}
        decisions={@decisions_frame}
        change={true}
        form={"#{@id}-gate"}
        answers={@answers}
        errors={@errors}
        submits={@submits}
        now={@now}
      />
      <.gate
        :if={(@confirm and (@can_act or not is_nil(@move_error))) or @round}
        id={"#{@id}-gate"}
        number={@work_item.number}
        open={if @confirm, do: length(@open_comments), else: @sendable}
        comment={@comment}
        can_confirm={@confirm and @can_act}
        can_send={@round and @can_send}
        can_change={@decisions_frame != []}
        changed={@changed}
        decisions={@decisions_frame != []}
        error={send_words(@move_error, @form_error)}
        updates={:outputs}
      />
      <.questions_frame
        :if={@closed_questions != [] and !@open_questions?}
        id={"#{@id}-questions"}
        number={@work_item.number}
        questions={@closed_questions}
        mode={:read}
        now={@now}
      />
      <.record
        :if={@record}
        id="work-item-record"
        number={@work_item.number}
        runs={@runs}
        latest={@run}
        pieces={@pieces}
        verdicts={@verdicts}
        item={@item}
        now={@now}
      >
        {render_slot(@artifacts)}
      </.record>
      <.earlier_take_ins
        :if={@take_ins != []}
        id={"#{@id}-take-ins"}
        number={@work_item.number}
        take_ins={@take_ins}
        item={@item}
        now={@now}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :stage, :map, required: true
  attr :run, :map, required: true
  attr :groups, :list, required: true
  attr :item, :string, required: true

  # A stage's run, queued or running: what it does next, with whose answers or review
  # comments. A send of the review comments comes first, as on Explore's tab.
  defp stage_wait(assigns) do
    assigns = assign(assigns, stage_wait_words(assigns))

    ~H"""
    <div id={@id} class="q-xp-wait">
      <.icon name="hero-arrow-path" class="q-xp-wait-i size-5" />
      <div>
        <p id={"#{@id}-h"}><b><.rich text={place_ref(@run, @heading)} /></b></p>
        <p><.rich text={@line} /></p>
      </div>
    </div>
    """
  end

  defp stage_wait_words(%{stage: %{name: stage, outputs: types}, run: run, item: item} = assigns) do
    attempt = run_place(run)
    queued? = run[:state] in [nil, :pending]
    whose = answers_of(Enum.map(assigns.groups, & &1.answered_by))

    {heading, line} =
      cond do
        run[:sent] == true -> stage_sent_words(stage, you?(run[:sent_by]), attempt, item, queued?)
        whose != :none -> stage_answers_words(stage, whose == :you, attempt, item, queued?)
        true -> stage_first_words(stage, types, attempt, item, queued?)
      end

    %{heading: heading, line: line}
  end

  # A stage with no outputs writes nothing the line can list.
  defp stage_first_words(stage, [], attempt, item, true) do
    {gettext("%{stage} is queued.", stage: stage),
     rich_gettext(
       "%{attempt} starts when the workspace's pool takes it. It reads the %{item} and the stage's inputs.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_first_words(stage, [], attempt, item, false) do
    {gettext("%{stage} is running.", stage: stage),
     rich_gettext("%{attempt} reads the %{item} and the stage's inputs.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_first_words(stage, types, attempt, item, true) do
    {gettext("%{stage} is queued.", stage: stage),
     rich_gettext(
       "%{attempt} starts when the workspace's pool takes it. It reads the %{item} and the stage's inputs, then writes %{outputs}.",
       attempt: attempt,
       item: item,
       outputs: StageComponents.outputs_words(types)
     )}
  end

  defp stage_first_words(stage, types, attempt, item, false) do
    {gettext("%{stage} is running.", stage: stage),
     rich_gettext(
       "%{attempt} reads the %{item} and the stage's inputs, then writes %{outputs}.",
       attempt: attempt,
       item: item,
       outputs: StageComponents.outputs_words(types)
     )}
  end

  defp stage_sent_words(stage, true, attempt, item, true) do
    {gettext("%{stage} is queued again, with your comments.", stage: stage),
     rich_gettext(
       "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest outputs and your comments.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_sent_words(stage, false, attempt, item, true) do
    {gettext("%{stage} is queued again, with the comments.", stage: stage),
     rich_gettext(
       "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest outputs and the comments.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_sent_words(stage, true, attempt, item, false) do
    {gettext("%{stage} is running again, with your comments.", stage: stage),
     rich_gettext(
       "%{attempt} reads the %{item}, the newest outputs and your comments, then writes the next versions.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_sent_words(stage, false, attempt, item, false) do
    {gettext("%{stage} is running again, with the comments.", stage: stage),
     rich_gettext(
       "%{attempt} reads the %{item}, the newest outputs and the comments, then writes the next versions.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_answers_words(stage, true, attempt, item, true) do
    {gettext("%{stage} is queued again, with your answers.", stage: stage),
     rich_gettext(
       "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest outputs and the questions with your answers.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_answers_words(stage, false, attempt, item, true) do
    {gettext("%{stage} is queued again, with the answers.", stage: stage),
     rich_gettext(
       "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest outputs and the questions with their answers.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_answers_words(stage, true, attempt, item, false) do
    {gettext("%{stage} is running again, with your answers.", stage: stage),
     rich_gettext(
       "%{attempt} reads the %{item}, the newest outputs and the questions with your answers, then writes the next versions.",
       attempt: attempt,
       item: item
     )}
  end

  defp stage_answers_words(stage, false, attempt, item, false) do
    {gettext("%{stage} is running again, with the answers.", stage: stage),
     rich_gettext(
       "%{attempt} reads the %{item}, the newest outputs and the questions with their answers, then writes the next versions.",
       attempt: attempt,
       item: item
     )}
  end

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :output, :map, required: true
  slot :inner_block, doc: "the output's artifact row, for a version with no Markdown"

  @doc false
  # output_frame/1 is one output of a stage, in a frame with its version, folded but for the
  # first (`open`). A folded frame's
  # text is read when it opens (`"open_frame"`, with its type). The frames keep the state the
  # reader gave them when the page draws again.
  def output_frame(assigns) do
    read = assigns.output.read
    text? = is_map(read)

    {body, sources, count} =
      if text?, do: split_sources(rendered(read, :message, nil)), else: {nil, nil, 0}

    assigns =
      assign(assigns,
        text?: text?,
        body: %{rendered: body},
        sources: sources,
        count: count,
        heading: output_heading(assigns.output.type)
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <details
        id={"#{@id}-fold"}
        class="q-xp-frame-fold"
        open={@output.open}
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary
          id={"#{@id}-s"}
          phx-click={@output.read == :unread && "open_frame"}
          phx-value-number={@number}
          phx-value-type={@output.type}
        >
          <div class="q-xp-frame-h">
            <.icon name="hero-chevron-right-micro" class="q-xp-chev q-xp-frame-i size-4" />
            <h2 id={"#{@id}-h"} class="q-xp-frame-t">{@heading}</h2>
          </div>
          <p class="q-xp-cap">
            <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
            <span>{gettext("Version %{version}", version: Format.number(@output.version))}</span>
          </p>
        </summary>
        <div
          :if={@text?}
          id={"#{@id}-v#{@output.version}"}
          class="q-xp-body q-xp-prop"
          phx-hook="Mermaid"
          phx-update="ignore"
          data-script={~p"/assets/js/mermaid.js"}
          data-alt={gettext("Diagram")}
          data-source={gettext("Diagram source")}
          data-not-drawn={
            gettext("Qory Apiary does not draw this diagram, so it is shown as written.")
          }
          data-failed={gettext("This diagram has an error, so it is shown as written.")}
        >
          <.run_text id={"#{@id}-text"} value={@body} key={:message} />
        </div>
        <.sources_fold :if={@sources} id={"#{@id}-sources"} sources={@sources} count={@count} />
        <div :if={is_nil(@output.read)} class="q-xp-body">{render_slot(@inner_block)}</div>
      </details>
    </section>
    """
  end

  # A frame's heading: the type's words, with a capital first letter.
  defp output_heading(type) do
    {first, rest} = type |> StageComponents.type_words() |> String.split_at(1)
    String.upcase(first) <> rest
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

  # A work item that left Explore with no confirmation, by a gate `none` or a move forward
  # and an approve, has the status of another stage's live run. That status is not Explore's.
  defp explore_status(status, %{other_stage: true}) when status in [:queued, :running],
    do: :other_stage

  defp explore_status(status, _run), do: status

  # At a stage after Explore (`foot` set), a take in with no run has no wait block. A run
  # with `workspace_id` nil is the page's placeholder for Explore's first run, and nothing
  # is queued.
  defp tab_view(foot, status, run) do
    if foot && is_nil(run[:workspace_id]), do: nil, else: explore_view(status, run)
  end

  # A work item moved back to Explore has a confirmation, so its status is `:shape`, while
  # the run that the move queued waits or runs. The take in's first run before it exists
  # (`workspace_id` nil) is not such a run.
  defp explore_view(status, _run) when status in [:queued, :running], do: :wait

  defp explore_view(status, %{place: place, workspace_id: workspace_id})
       when status in [:shape, :other_stage] and place in [:queued, :running] and
              is_binary(workspace_id),
       do: :wait

  # An undo works only before a run of the take in starts (`Apiary.WorkItems.undo/2`), so
  # an undone work item has no result to show: its run of the queue ended `undone`, or the
  # take in queued none, as when its first stage waits for a workflow.
  defp explore_view(:undone, _run), do: :undone

  # The take in's first run before it exists (`workspace_id` nil) is no run that ended: a
  # work item closed while Explore waited for it shows how it ended, and any other shows no
  # result.
  defp explore_view(:closed, %{workspace_id: nil}), do: :closed
  defp explore_view(_status, %{workspace_id: nil}), do: nil
  defp explore_view(_status, nil), do: nil
  defp explore_view(_status, %{outcome: outcome}) when outcome in [:proposal, :questions], do: nil
  defp explore_view(_status, _run), do: :no_result

  defp wait_status(status, _run) when status in [:queued, :running], do: status
  defp wait_status(_status, run), do: run.place

  # The tab's latest run and earlier runs: Explore's. A later stage's run, live or ended,
  # is not a run of Explore (`:other_stage`, `ApiaryWeb.WorkItemLive.View`).
  defp explore_runs(run, earlier_runs) do
    case Enum.reject(earlier_runs ++ List.wrap(run), & &1[:other_stage]) do
      [] -> {nil, []}
      runs -> {List.last(runs), Enum.drop(runs, -1)}
    end
  end

  defp answered?(run), do: run[:outcome] == :questions and run[:answered_by] != nil

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :now, :any, required: true

  # Which run of the take in, as a link to its page, its state, its time. Before a run
  # exists, and while it is pending, it is Queued, Explore's word. A paused run that a run
  # continues has why it paused in place of its state (`ApiaryWeb.PauseWords`).
  defp run_line(assigns) do
    run = assigns.run
    state = run[:state]

    assigns =
      assign(assigns,
        place: run_place(run),
        state_word:
          cond do
            state in [nil, :pending] -> gettext("Queued")
            run[:paused] -> PauseWords.line(run.paused, run[:paused_path])
            true -> RunComponents.state_label(state)
          end,
        state_class:
          cond do
            state == :running -> running_word_class(run)
            state in [:failed, :cancelled, :lost] -> "q-xp-run-bad"
            true -> nil
          end,
        time: run_time(run, assigns.now)
      )

    ~H"""
    <p id={@id} class="q-xp-run">
      <span><b><.rich text={place_ref(@run, @place)} /></b></span>
      <span class={@state_class}><.rich text={@state_word} /></span>
      <span :if={@time}><.rich text={@time} /></span>
    </p>
    """
  end

  defp run_place(run), do: gettext("Attempt %{attempt}", attempt: shown_number(run[:attempt]))

  defp quiet?(run), do: run[:liveness] == :quiet

  # A running run's word has the colours of its badge: blue, amber once the run is quiet.
  defp running_word_class(run),
    do: if(quiet?(run), do: "text-primary-soft-content", else: "text-info-soft-content")

  attr :run, :map, required: true

  defp running_word(assigns) do
    ~H"""
    <span class={running_word_class(@run)}>{RunComponents.state_label(:running)}</span>
    """
  end

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
  # run writes a reply to its line, in words that no workspace's words change. A run that
  # a send of the review comments started (`sent`) reads the review comments, the
  # sender's ("your") where the reader sent them (`sent_by`), in its heading and its line,
  # whatever answers the take in has.
  defp explore_wait(assigns) do
    run = assigns.run
    whose = answers_of(Enum.map(assigns.groups, & &1.answered_by))
    # The block's heading is its one link to the run, so the sentence has plain words.
    attempt = run_place(run)

    {heading, line} =
      case {assigns.status, whose} do
        {:queued, _whose} when assigns.test ->
          {gettext("Explore is queued."),
           rich_gettext(
             "%{attempt} starts when the workspace's pool takes it. The agent writes a reply to the line.",
             attempt: attempt
           )}

        {:running, _whose} when assigns.test ->
          {gettext("Explore is running."),
           rich_gettext("In %{attempt}, the agent writes a reply to the line.",
             attempt: run_place_lower(run)
           )}

        {:queued, :none} ->
          {gettext("Explore is queued."),
           rich_gettext(
             "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, then writes a proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}

        {:queued, whose} ->
          {queued_heading(whose),
           rich_gettext(
             "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest proposal and the questions with their answers.",
             attempt: attempt,
             item: assigns.item
           )}

        {:running, :none} ->
          {gettext("Explore is running."),
           rich_gettext(
             "%{attempt} reads the %{item}, then writes a proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}

        {:running, :you} ->
          {running_heading(:you),
           rich_gettext(
             "%{attempt} reads the %{item}, the newest proposal and the questions with your answers, then writes the next proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}

        {:running, whose} ->
          {running_heading(whose),
           rich_gettext(
             "%{attempt} reads the %{item}, the newest proposal and the questions with their answers, then writes the next proposal and questions.",
             attempt: attempt,
             item: assigns.item
           )}
      end

    {heading, line} =
      if assigns.run[:sent] == true and not assigns.test,
        do:
          {sent_heading(assigns.status, assigns.run),
           sent_line(assigns.status, assigns.run, attempt, assigns.item)},
        else: {heading, line}

    assigns = assign(assigns, heading: heading, line: line)

    ~H"""
    <div id={@id} class="q-xp-wait">
      <.icon name="hero-arrow-path" class="q-xp-wait-i size-5" />
      <div>
        <p id={"#{@id}-h"}><b><.rich text={place_ref(@run, @heading)} /></b></p>
        <p><.rich text={@line} /></p>
      </div>
    </div>
    """
  end

  defp sent_heading(:queued, run) do
    if you?(run[:sent_by]),
      do: gettext("Explore is queued again, with your comments."),
      else: gettext("Explore is queued again, with the comments.")
  end

  defp sent_heading(:running, run) do
    if you?(run[:sent_by]),
      do: gettext("Explore is running again, with your comments."),
      else: gettext("Explore is running again, with the comments.")
  end

  defp sent_line(:queued, _run, attempt, item),
    do:
      rich_gettext(
        "%{attempt} starts when the workspace's pool takes it. It reads the %{item}, the newest proposal and the comments.",
        attempt: attempt,
        item: item
      )

  defp sent_line(:running, run, attempt, item) do
    if you?(run[:sent_by]),
      do:
        rich_gettext(
          "%{attempt} reads the %{item}, the newest proposal and your comments, then writes the next proposal and questions.",
          attempt: attempt,
          item: item
        ),
      else:
        rich_gettext(
          "%{attempt} reads the %{item}, the newest proposal and the comments, then writes the next proposal and questions.",
          attempt: attempt,
          item: item
        )
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
          <div class="q-xp-ans" phx-no-format>{question.answer}<.recommended_mark :if={question[:recommended]} class="ms-1.5" /></div>
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
  @doc false
  def run_text(assigns) do
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

  @background_heading "<h4>Background</h4>"

  @doc false
  # fold_background/1 is a rendered proposal with its Background folded: under the first
  # `## Background` heading at the top level of the text, which the renderer draws as
  # `<h4>Background</h4>`, its first paragraph shows, and every block after it, up to the
  # next heading of the same level or a higher one at the top level, is in a closed
  # `<details>` with the summary Read more, which reads Read less while the fold is open
  # (app.css hides the label that does not apply). A Background with nothing after its
  # first paragraph, a proposal without the heading, and one shown as written are as
  # given.
  @spec fold_background(term) :: term
  def fold_background({:html, html}) do
    string = Phoenix.HTML.safe_to_string(html)
    blocks = top_blocks(string)

    heading? = fn {at, to, _open} -> binary_part(string, at, to - at) == @background_heading end

    with {_before, [_heading | after_heading]} <- Enum.split_while(blocks, &(!heading?.(&1))),
         section = Enum.take_while(after_heading, &(!section_end?(elem(&1, 2)))),
         {_shown, [_first | [{from, _end, _open} | _] = folded]} <-
           Enum.split_while(section, &(!paragraph?(elem(&1, 2)))) do
      {_at, to, _open} = List.last(folded)

      [more, less] =
        for words <- [gettext("Read more"), gettext("Read less")],
            do: words |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      {:html,
       {:safe,
        [
          binary_part(string, 0, from),
          ~s(<details class="q-xp-more"><summary class="text-accent">),
          ~s(<span class="hero-chevron-down-micro size-3.5"></span>),
          ~s(<span class="q-xp-read-more">),
          more,
          ~s(</span><span class="q-xp-read-less">),
          less,
          "</span></summary>\n",
          binary_part(string, from, to - from),
          "\n</details>",
          binary_part(string, to, byte_size(string) - to)
        ]}}
    else
      _none -> {:html, html}
    end
  end

  def fold_background(rendered), do: rendered

  # A heading that ends the Background: one of its level or a higher one.
  defp section_end?(open), do: String.starts_with?(open, ["<h1", "<h2", "<h3", "<h4"])

  defp paragraph?(open), do: open == "<p>" or String.starts_with?(open, "<p ")

  # The blocks at the top level of rendered HTML, in order: `{start, end, open}`, the byte
  # offsets of each element and its start tag. Quoting as `top_sources/1` reads it.
  defp top_blocks(html) do
    ~r{<(/?)([a-zA-Z][a-zA-Z0-9]*)(?:[^>"]|"[^"]*")*>}
    |> Regex.scan(html, return: :index)
    |> Enum.reduce({0, nil, []}, fn [{at, length}, {_slash, slash}, {name_at, name_length}],
                                    {depth, start, blocks} ->
      name = html |> binary_part(name_at, name_length) |> String.downcase()
      tag_end = at + length

      cond do
        name in @void_tags and depth == 0 ->
          {0, nil, [{at, tag_end, binary_part(html, at, length)} | blocks]}

        name in @void_tags ->
          {depth, start, blocks}

        slash == 1 and depth == 1 ->
          {0, nil, [{elem(start, 0), tag_end, elem(start, 1)} | blocks]}

        slash == 1 ->
          {max(depth - 1, 0), start, blocks}

        depth == 0 ->
          {1, {at, binary_part(html, at, length)}, blocks}

        true ->
          {depth + 1, start, blocks}
      end
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  attr :id, :string, required: true

  attr :run, :map,
    required: true,
    doc: "`:proposal` (`%{message:}`, with `:rendered`), `:version`, and the run's `:attempt`"

  attr :confirmed, :any, default: nil
  attr :now, :any, required: true

  attr :earlier, :boolean,
    default: false,
    doc: "whether a run before the latest one wrote it, while that run escalated"

  attr :images, :any,
    default: nil,
    doc: "the proposal version's images, filename and download address; nil if not known"

  attr :level, :string,
    default: "h2",
    values: ~w(h2 h3),
    doc: "the heading's level: one lower inside a fold than the frames of the tab"

  slot :comments, doc: "the review comments, at the top of the text below 1007 px"

  @doc false
  # proposal_frame/1 is the proposal, in a frame with its version; confirmed, who
  # confirmed it. A result stored before the
  # proposal was Markdown has no text: the frame shows none. The text shows the version's
  # `images` (PNG, JPEG, GIF, WebP and SVG files only, `image_files/1`), and a reference
  # to a file of none of them as "Image not in this version"; with `images` nil, the
  # version's files are not known, and an image is its words. It draws its Mermaid
  # diagrams in the browser (`assets/js/hooks/mermaid.js`); its block has an id of the
  # version and is left alone by later patches (`phx-update="ignore"`), so the drawings of
  # the hook stay and a new version is drawn again; a proposal still unread (`:unread`),
  # which shows its result's `message`, has another id, so its text is drawn once read.
  # Its Sources, the list under its last `## Sources` heading, are in a fold at the foot
  # of the frame, closed (`split_sources/1`); its Background shows its first paragraph,
  # with the rest in a fold, closed (`fold_background/1`).
  def proposal_frame(assigns) do
    proposal = assigns.run[:proposal] || %{}
    text? = proposal[:rendered] != nil or is_binary(proposal[:message])

    {body, sources, count} =
      if text?,
        do: split_sources(rendered(proposal, :message, image_files(assigns.images))),
        else: {nil, nil, 0}

    assigns =
      assign(assigns,
        body: %{rendered: fold_background(body)},
        sources: sources,
        count: count,
        text?: text?,
        kept: if(unread?(proposal), do: "-kept"),
        caption: proposal_caption(assigns.run, assigns.confirmed, assigns.now)
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-document-text" class="q-xp-frame-i size-4" />
        <.dynamic_tag tag_name={@level} id={"#{@id}-h"} class="q-xp-frame-t">
          {gettext("Proposal")}
        </.dynamic_tag>
        <.badge :if={@confirmed} color="info" class="q-xp-frame-b">{gettext("Approved")}</.badge>
      </div>
      <p :if={@caption} class="q-xp-cap">
        <.icon name="hero-check-micro" class="q-xp-cap-i size-3.5" />
        <span><.rich text={@caption} /></span>
      </p>
      <p :if={!@caption && @run[:version]} class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span :if={!@earlier}>{gettext("Version %{version}", version: Format.number(@run.version))}</span>
        <span :if={@earlier}>
          {gettext("Version %{version} · from an earlier round", version: Format.number(@run.version))}
        </span>
      </p>
      <div :if={@comments != []} class="q-xp-body q-xp-rc-inline">{render_slot(@comments)}</div>
      <div
        :if={@text?}
        id={"#{@id}-v#{@run[:version]}#{@kept}"}
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
      <.sources_fold :if={@sources} id={"#{@id}-sources"} sources={@sources} count={@count} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :sources, :any, required: true, doc: "the HTML under the heading (`split_sources/1`)"
  attr :count, :integer, required: true, doc: "the number of its items (`split_sources/1`)"

  @doc false
  # sources_fold/1 is a proposal's Sources: a closed fold, last of the text, on Explore's
  # tab and on a version's page.
  def sources_fold(assigns) do
    ~H"""
    <details id={@id} class="q-xp-sources">
      <summary>
        <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
        <span class="q-xp-it"><b>{gettext("Sources (%{count})", count: Format.number(@count))}</b></span>
      </summary>
      <div class="q-xp-inner">
        <div class="q-ticket-formatted q-xp-md">{@sources}</div>
      </div>
    </details>
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

  # The proposal's version, who confirmed it and when; nil before. A proposal with no
  # version, stored before proposals were artifacts, has who and when alone.
  defp proposal_caption(_run, falsy, _now) when falsy in [nil, false], do: nil

  defp proposal_caption(run, %{by: by, at: at}, now) do
    at = inline_ago(at, now)

    cond do
      not is_integer(run[:version]) and you?(by) ->
        rich_gettext("You approved it %{when}.", when: at)

      not is_integer(run[:version]) ->
        rich_gettext("%{name} approved it %{when}.", name: by.name, when: at)

      true ->
        versioned_caption(Format.number(run.version), by, at)
    end
  end

  defp versioned_caption(version, by, at) do
    if you?(by),
      do:
        rich_gettext("Version %{version}. You approved it %{when}.",
          version: version,
          when: at
        ),
      else:
        rich_gettext("Version %{version}. %{name} approved it %{when}.",
          version: version,
          name: by.name,
          when: at
        )
  end

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :open, :integer, required: true, doc: "how many review comments are open"
  attr :comment, :string, default: "", doc: "the comment on the whole proposal, as drafted"
  attr :can_confirm, :boolean, default: true, doc: "whether the reader may confirm"
  attr :can_send, :boolean, default: true, doc: "whether the reader may send review comments"

  attr :can_change, :boolean,
    default: false,
    doc: "whether the reader may change the decisions of the frame above the gate"

  attr :changed, :boolean, default: false, doc: "whether the reader changed a decision"
  attr :decisions, :boolean, default: false, doc: "whether the tab shows decisions"
  attr :error, :any, default: nil, doc: "why the last move on the tab was not made"

  attr :updates, :atom,
    default: :proposal,
    values: [:proposal, :outputs],
    doc: "what the next run updates, as the caption names it"

  # The gate under the proposal: for a reader who may send review comments, the comment on
  # the whole proposal; for a reader who may send them or change the decisions above the
  # gate (`can_change`), Run another round (`"answer"`), which starts the next run with
  # the comment, every open review comment and the changed decisions, enabled where there
  # is one of them; and Confirm (`"confirm"`), for a reader who may confirm, with how many
  # review comments it leaves unread. While a decision is changed and not sent
  # (`changed`), Approve is disabled, with the line that Run another round applies the
  # change. Where a button starts a run, its click opens the spend's dialog first
  # (`ApiaryWeb.SpendDialog`). The caption has only the changed decisions for a reader who
  # may change a decision and may not comment (`can_send`). Under them, why the last move
  # was not made (`error`), as the questions form shows its error.
  defp gate(assigns) do
    assigns =
      assign(assigns,
        ready: comment?(assigns.comment) or assigns.open > 0 or assigns.changed,
        sends: assigns.can_send or assigns.can_change
      )

    ~H"""
    <form id={@id} class="q-xp-reply" phx-change="answer_draft" phx-submit="answer" novalidate>
      <input type="hidden" name="number" value={@number} />
      <p :if={@sends} class="q-xp-cap q-xp-gate-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span :if={!@can_send and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your changed decisions and updates the proposal."
          )}
        </span>
        <span :if={!@can_send and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your changed decisions and updates the outputs."
          )}
        </span>
        <span :if={@can_send and !@changed and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your comment and updates the proposal."
          )}
        </span>
        <span :if={@can_send and !@changed and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your comment and updates the outputs."
          )}
        </span>
        <span :if={@can_send and @changed and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your changed decisions and your comment, and updates the proposal."
          )}
        </span>
        <span :if={@can_send and @changed and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your changed decisions and your comment, and updates the outputs."
          )}
        </span>
      </p>
      <.comment_field
        :if={@can_send}
        id={"#{@id}-comment"}
        value={@comment}
        decisions={@decisions}
        updates={@updates}
      />
      <div class="q-xp-form-foot q-xp-gate-go">
        <span class="q-xp-gate-b">
          <.button
            :if={@sends}
            id={"#{@id}-send"}
            type="submit"
            variant={if @can_confirm, do: "default", else: "primary"}
            disabled={!@ready}
          >
            <.icon name="hero-play-micro" class="size-3.5" />{gettext("Run another round")}
          </.button>
          <.button
            :if={@can_confirm}
            id={"#{@id}-go"}
            type="button"
            variant="primary"
            phx-click="confirm"
            phx-value-number={@number}
            disabled={@changed}
            aria-describedby={
              cond do
                @changed -> "#{@id}-hint"
                @open > 0 -> "#{@id}-unread"
                true -> nil
              end
            }
          >
            <.icon name="hero-check-micro" class="size-3.5" />{gettext("Approve")}
          </.button>
        </span>
        <p :if={@can_confirm and @changed} id={"#{@id}-hint"}>
          {pgettext("plain", "Run another round to apply your change.")}
        </p>
        <p :if={@can_confirm and @open > 0 and !@changed} id={"#{@id}-unread"}>
          {ngettext(
            "Approve leaves 1 comment unread.",
            "Approve leaves %{count} comments unread.",
            @open
          )}
        </p>
      </div>
      <p :if={@error} id={"#{@id}-error"} class="q-xp-err" role="alert">
        <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /><.rich text={@error} />
      </p>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, default: ""
  attr :decisions, :boolean, default: false, doc: "whether the tab shows decisions"

  attr :updates, :atom,
    default: :proposal,
    values: [:proposal, :outputs],
    doc: "what the next run updates, as the label names it"

  # The comment on the whole proposal, or on a stage's outputs, one field with its label:
  # in the questions form, and at the gate. Run another round sends it, as a review
  # comment on the round. Where the tab shows decisions, its placeholder covers them too.
  defp comment_field(assigns) do
    assigns =
      assign(assigns,
        answer_units: @answer_units,
        placeholder:
          if(assigns.decisions,
            do: gettext("Add anything the questions and decisions do not cover."),
            else: gettext("Add anything the questions do not cover.")
          )
      )

    ~H"""
    <div class="q-xp-comment">
      <label :if={@updates == :proposal} for={@id}>{gettext("Comment on the whole proposal")}</label>
      <label :if={@updates == :outputs} for={@id}>{gettext("Comment on the stage's outputs")}</label>
      <textarea
        id={@id}
        name="comment"
        rows="3"
        maxlength={@answer_units}
        placeholder={@placeholder}
      >{["\n", @value || ""]}</textarea>
    </div>
    """
  end

  defp comment?(text) when is_binary(text), do: String.trim(text) != ""
  defp comment?(_text), do: false

  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :questions, :list, required: true
  attr :mode, :atom, required: true, values: [:form, :read]
  attr :running, :boolean, default: false
  attr :answers, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :form_error, :atom, default: nil
  attr :move_error, :any, default: nil
  attr :submits, :integer, default: 0
  attr :now, :any, required: true
  attr :comment, :string, default: "", doc: "the comment on the whole proposal, as drafted"
  attr :commenting, :boolean, default: false, doc: "whether the form has the comment field"
  attr :open_comments, :integer, default: 0, doc: "the open review comments it sends"
  attr :change, :boolean, default: false, doc: "whether the reader may change the decisions"

  attr :updates, :atom,
    default: :proposal,
    values: [:proposal, :outputs],
    doc: "what the next run updates, as the caption names it"

  # The questions: the closed ones first, each a fold of one line; then the run's
  # decisions (`decision?/1`), each a fold of one line, and the open ones, with the form
  # for a member who may answer them, where a member who may change the decisions
  # (`change`) changes them too; while a run runs, as text. Under the open questions, the
  # comment on the whole proposal (`commenting`), then Run another round, enabled where
  # the form has an answer, a changed decision or a comment, or a review comment is open
  # (`open_comments`). Under the form, why the last move was not made: the page's line
  # (`move_error`), else the form's.
  defp questions_frame(assigns) do
    {decisions, questions} = Enum.split_with(assigns.questions, &decision?/1)
    {open, closed} = Enum.split_with(questions, &(&1.state == :open))
    form? = assigns.mode == :form and open != []
    change = form? and assigns.change

    ready =
      Enum.any?(open, &drafted_answer?(assigns.answers[&1.id])) or
        (change and Enum.any?(decisions, &decision_changed?(&1, assigns.answers[&1.id]))) or
        (assigns.commenting and comment?(assigns.comment)) or assigns.open_comments > 0

    first_error =
      form? &&
        Enum.find(
          if(change, do: decisions, else: []) ++ open,
          &answer_error(assigns.errors[&1.id])
        )

    numbers = Map.new(assigns.questions, &{&1.number, &1})

    assigns =
      assign(assigns,
        open: open,
        closed: closed,
        decisions: decisions,
        change: change,
        form?: form?,
        numbers: numbers,
        first_error: first_error,
        ready: ready,
        form_words: send_words(assigns.move_error, assigns.form_error),
        heading:
          if(decisions != [],
            do: gettext("Questions and decisions"),
            else: ngettext("Question", "Questions", length(assigns.questions))
          )
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-question-mark-circle" class="q-xp-frame-i size-4" />
        <h2 id={"#{@id}-h"} class="q-xp-frame-t">{@heading}</h2>
      </div>
      <p :if={@form?} id={"#{@id}-cap"} class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span :if={@commenting and @change and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your answers, your changed decisions and your comment, and updates the proposal."
          )}
        </span>
        <span :if={@commenting and @change and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your answers, your changed decisions and your comment, and updates the outputs."
          )}
        </span>
        <span :if={!@commenting and @change and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your answers and your changed decisions, and updates the proposal."
          )}
        </span>
        <span :if={!@commenting and @change and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your answers and your changed decisions, and updates the outputs."
          )}
        </span>
        <span :if={@commenting and !@change and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your answers and your comment, and updates the proposal."
          )}
        </span>
        <span :if={@commenting and !@change and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your answers and your comment, and updates the outputs."
          )}
        </span>
        <span :if={!@commenting and !@change and @updates == :proposal}>
          {gettext(
            "Run another round starts the next run. That run reads your answers and updates the proposal."
          )}
        </span>
        <span :if={!@commenting and !@change and @updates == :outputs}>
          {gettext(
            "Run another round starts the next run. That run reads your answers and updates the outputs."
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
        <%= if @form? do %>
          <form
            id={"#{@id}-form"}
            phx-change="answer_draft"
            phx-submit="answer"
            novalidate
            aria-labelledby={"#{@id}-h"}
          >
            <input type="hidden" name="number" value={@number} />
            <div :if={@decisions != []} id={"#{@id}-decisions"} class="q-xp-sec">
              <h3>{gettext("Decisions")}</h3>
              <.decision_rows
                id={@id}
                decisions={@decisions}
                change={@change}
                answers={@answers}
                errors={@errors}
                submits={@submits}
                now={@now}
              />
            </div>
            <div class="q-xp-sec">
              <h3>{gettext("Open questions")}</h3>
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
            </div>
            <.comment_field
              :if={@commenting}
              id={"#{@id}-comment"}
              value={@comment}
              decisions={@decisions != []}
              updates={@updates}
            />
            <.error_focus :if={@first_error} id={@id} question={@first_error} submits={@submits} />
            <p :if={@form_words} id={"#{@id}-error"} class="q-xp-err" role="alert">
              <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /><.rich text={
                @form_words
              } />
            </p>
            <div class="q-xp-form-foot">
              <.button id={"#{@id}-go"} type="submit" variant="primary" disabled={!@ready}>
                <.icon name="hero-play-micro" class="size-3.5" />{gettext("Run another round")}
              </.button>
            </div>
          </form>
        <% else %>
          <div :if={@decisions != []} id={"#{@id}-decisions"} class="q-xp-sec">
            <h3>{gettext("Decisions")}</h3>
            <.decision_rows id={@id} decisions={@decisions} now={@now} />
          </div>
          <div :if={@open != []} class="q-xp-sec">
            <h3>{gettext("Open questions")}</h3>
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
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  # Why the last send wrote nothing, under the form or the gate: the page's line
  # (`move_error`), else the form's (`form_error`); false for none.
  defp send_words(move_error, form_error),
    do: move_error || (form_error in [:blank, :stale] && answer_error(form_error))

  # Whether a question's draft is an answer: an option picked, or a note written.
  defp drafted_answer?(%{} = value),
    do: (value["option"] || "") != "" or comment?(value["note"])

  defp drafted_answer?(_value), do: false

  @doc false
  # decision?/1 is whether a question is a run's decision the tab shows as one: decided,
  # or answered by a member after a run chose its option (its `decision` kept).
  @spec decision?(map) :: boolean
  def decision?(%{decision: %{}, state: state}) when state in [:decided, :answered], do: true
  def decision?(_question), do: false

  @doc false
  # decision_changed?/2 is whether `value`, a draft as the questions form keeps it
  # (`%{"option" => choice, "note" => text}`), changes the decided question: another
  # option than the run's, Give your own option, or a note written. Picking an option
  # with the run's title with no note is no change, as the move compares titles
  # (`Apiary.WorkItems.Proposal`, `Apiary.Explore.Questions.same_as_decision?/3`).
  @spec decision_changed?(map, map | nil) :: boolean
  def decision_changed?(%{state: :decided, decision: %{}} = question, %{} = value) do
    option = value["option"]

    (is_binary(option) and option != "" and not run_option?(question, option)) or
      comment?(value["note"])
  end

  def decision_changed?(_question, _value), do: false

  # Whether the form's choice `choice`, an option's place from 1, has the run's title.
  defp run_option?(%{decision: %{option: title}, options: options}, choice) do
    case Integer.parse(choice) do
      {n, ""} when n >= 1 ->
        case Enum.at(options, n - 1) do
          %{title: option} -> same_title?(option, title)
          nil -> false
        end

      _other ->
        false
    end
  end

  # Whether two option titles are one, as `Apiary.WorkItems.Proposal` compares them.
  defp same_title?(one, other) when is_binary(one) and is_binary(other),
    do: normal_title(one) == normal_title(other)

  defp same_title?(_one, _other), do: false

  defp normal_title(title), do: title |> String.replace("\r\n", "\n") |> String.trim()

  # The place from 1 of the run's option among the question's options, as the form's
  # choice; nil where the options do not have it.
  defp run_choice(%{decision: %{option: title}, options: options}) do
    case Enum.find_index(options, &same_title?(&1.title, title)) do
      nil -> nil
      index -> Integer.to_string(index + 1)
    end
  end

  attr :id, :string, required: true
  attr :decisions, :list, required: true
  attr :change, :boolean, default: false, doc: "whether the reader may change them"
  attr :form, :string, required: true, doc: "the id of the gate's form their fields belong to"
  attr :answers, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :submits, :integer, default: 0
  attr :now, :any, required: true

  # The run's decisions where the take in has no open question: a frame between the
  # proposal and the gate, each decision folded to one line. Its fields belong to the
  # gate's form (`form`), so Run another round sends the changed decisions. After a send
  # with an error in a decision, focus moves to the first such field.
  defp decisions_frame(assigns) do
    assigns =
      assign(
        assigns,
        :first_error,
        assigns.change && Enum.find(assigns.decisions, &answer_error(assigns.errors[&1.id]))
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <.icon name="hero-check-circle" class="q-xp-frame-i size-4" />
        <h2 id={"#{@id}-h"} class="q-xp-frame-t">{gettext("Decisions")}</h2>
      </div>
      <div class="q-xp-body q-xp-qbody">
        <.decision_rows
          id={@id}
          decisions={@decisions}
          change={@change}
          form={@form}
          answers={@answers}
          errors={@errors}
          submits={@submits}
          now={@now}
        />
        <.error_focus :if={@first_error} id={@id} question={@first_error} submits={@submits} />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :question, :map, required: true
  attr :submits, :integer, required: true

  # Moves focus to the field of `question` once for each send (`submits`). In the page's
  # order this comes after the decision's row, so the row is open when focus moves.
  defp error_focus(assigns) do
    ~H"""
    <span
      id={"#{@id}-focus-#{@submits}-#{@question.number}"}
      hidden
      phx-mounted={JS.focus(to: "##{@id}-answer-#{@question.number}")}
    ></span>
    """
  end

  attr :id, :string, required: true
  attr :decisions, :list, required: true
  attr :change, :boolean, default: false, doc: "whether the reader may change them"

  attr :form, :string,
    default: nil,
    doc: "the id of the form their fields belong to, if outside it"

  attr :answers, :map, default: %{}
  attr :errors, :map, default: %{}
  attr :submits, :integer, default: 0
  attr :now, :any, required: true

  # The decisions, each folded to one line: its number and question, then the run's
  # option and the run's reason, cut to one line by the CSS; for a decision a member
  # changed to another option or a text, Changed and the member's option or text.
  defp decision_rows(assigns) do
    ~H"""
    <div class="q-xp-earlier q-xp-closed q-xp-decs">
      <.decision_row
        :for={question <- @decisions}
        id={@id}
        question={question}
        change={@change}
        form={@form}
        value={@answers[question.id]}
        error={@errors[question.id]}
        submits={@submits}
        now={@now}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :question, :map, required: true
  attr :change, :boolean, default: false
  attr :form, :string, default: nil
  attr :value, :any, default: nil, doc: "the draft: `%{\"option\" => choice, \"note\" => text}`"
  attr :error, :any, default: nil
  attr :submits, :integer, default: 0, doc: "the count of sends that wrote nothing"
  attr :now, :any, required: true

  # A decision. Folded: its number and question, and the run's option with its reason
  # under them; changed by a member, Changed and the member's option or text, without
  # the reason. Open: the run's reason in full, which run chose it and when, then, for a
  # reader who may change it, the options as the open questions have them, the run's
  # option marked Chosen by the agent and picked until the reader picks another, Give
  # your own option and one field; for any other reader, the options as text. A changed
  # decision opens to the member's answer, who changed it and when, and under Changed
  # from, the run's option and reason. A member's answer with the run's option is no
  # change: the row stays as the run left it, and opens to the options as text, then who
  # added the note and when, and the note; with no note, who answered and when. The
  # row's head keeps the run's option while a change is a draft. The page's patches leave
  # the fold's `open` as the reader set it, so a pick does not fold the decision. For the
  # same reason, a send with an error in this row opens a folded row with a click on its
  # `<summary>`, and the reader can fold it again; a command that sets `open` would set it
  # back after every patch. The anchor of "Follows question" and "Asked as question" is the
  # number in the row's head.
  defp decision_row(assigns) do
    question = assigns.question
    n = question.number
    field = "#{assigns.id}-answer-#{n}"
    value = if is_map(assigns.value), do: assigns.value, else: %{}
    option = if (value["option"] || "") == "", do: run_choice(question), else: value["option"]
    answer = question.state == :answered && question.answer
    # An answer with the run's option keeps the decision, with the member's note if any.
    kept = !!answer and same_title?(answer.option, question.decision.option)
    noted = kept and comment?(answer.note)
    own = option == "own"

    placeholder =
      cond do
        question.options == [] -> gettext("Give your own option")
        own -> gettext("Your option")
        true -> gettext("Add details (optional)")
      end

    message = answer_error(assigns.error)

    assigns =
      assign(assigns,
        n: n,
        q_id: "#{assigns.id}-decision-#{n}-q",
        field: field,
        error_id: "#{field}-error",
        name: "answers[#{question.id}]",
        option: option,
        note: value["note"],
        answer: if(kept, do: false, else: answer),
        kept: kept,
        noted: if(noted, do: answer, else: false),
        answered: if(kept and !noted, do: answer, else: false),
        decision: question.decision,
        placeholder: placeholder,
        message: message,
        answer_units: @answer_units
      )

    ~H"""
    <details
      id={"#{@id}-decision-#{@n}"}
      open={!!@message}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary>
        <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
        <span id={@q_id} class="q-xp-it q-xp-wrap"><b id={"work-item-explore-questions-question-#{@n}"}>{@n}. <bdi phx-no-format>{@question.text}</bdi></b></span>
        <%= if @answer do %>
          <span class="q-xp-it q-xp-dec-chg">
            <.badge color="warning">{gettext("Changed")}</.badge>
            <span class="q-xp-said q-xp-dec-said" phx-no-format>{@answer.option || @answer.note}</span>
          </span>
        <% else %>
          <span class="q-xp-it q-xp-wrap q-xp-said" phx-no-format>{@decision.option}</span>
          <span class="q-xp-dec-why" phx-no-format>{@decision.reason}</span>
        <% end %>
      </summary>
      <span
        :if={@message}
        id={"#{@id}-decision-#{@n}-opens-#{@submits}"}
        hidden
        phx-mounted={JS.dispatch("click", to: "##{@id}-decision-#{@n}:not([open]) > summary")}
      ></span>
      <div class="q-xp-inner">
        <%= if @answer do %>
          <.run_text value={@question} key={:context} />
          <div id={"#{@id}-decision-#{@n}-answer"} class="q-xp-ans" phx-no-format><span :if={@answer.option} class="block">{@answer.option}</span><span :if={@answer.note}>{@answer.note}</span></div>
          <p class="q-xp-cm-m">
            <span class="q-xp-it q-xp-by"><.rich text={changed_words(@answer, @now)} /></span>
          </p>
          <p class="q-xp-cm-m" phx-no-format><span class="q-xp-it">{gettext("Changed from")}</span><wbr /><span :if={@decision.at} class="q-xp-it q-xp-by"><.rich text={chose_words(@decision, @now)} /></span></p>
          <div class="q-xp-ans q-xp-ans-old" phx-no-format><span class="block">{@decision.option}</span><span>{@decision.reason}</span></div>
        <% else %>
          <p class="q-xp-dec-r" phx-no-format>{@decision.reason}</p>
          <p :if={@decision.at} class="q-xp-cm-m">
            <span class="q-xp-it q-xp-by"><.rich text={chose_words(@decision, @now)} /></span>
          </p>
          <.run_text value={@question} key={:context} />
          <%= if @change and !@kept do %>
            <div
              :if={@question.options != []}
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
                  form={@form}
                  checked={@option == Integer.to_string(j)}
                />
                <.chosen_words option={option} chosen={same_title?(option.title, @decision.option)} />
              </label>
              <label for={"#{@field}-own"} class="q-xp-opt q-xp-opt-pick">
                <input
                  type="radio"
                  id={"#{@field}-own"}
                  name={"#{@name}[option]"}
                  value="own"
                  form={@form}
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
              form={@form}
              rows="2"
              class="q-xp-dec-note"
              maxlength={@answer_units}
              placeholder={@placeholder}
              aria-label={@placeholder}
              aria-describedby={if(@message, do: "#{@q_id} #{@error_id}", else: @q_id)}
              aria-invalid={@message && "true"}
            >{["\n", @note || ""]}</textarea>
            <p :if={@message} id={@error_id} class="q-xp-err">
              <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />{@message}
            </p>
          <% else %>
            <ul :if={@question.options != []} class="q-xp-opts">
              <li :for={option <- @question.options} class="q-xp-opt">
                <.chosen_words option={option} chosen={same_title?(option.title, @decision.option)} />
              </li>
            </ul>
          <% end %>
          <%= if @noted do %>
            <p class="q-xp-cm-m">
              <span class="q-xp-it q-xp-by"><.rich text={noted_words(@noted, @now)} /></span>
            </p>
            <div id={"#{@id}-decision-#{@n}-answer"} class="q-xp-ans" phx-no-format><span>{@noted.note}</span></div>
          <% end %>
          <p :if={@answered} class="q-xp-cm-m">
            <span class="q-xp-it q-xp-by"><.rich text={answered_words(@answered, @now)} /></span>
          </p>
        <% end %>
      </div>
    </details>
    """
  end

  attr :option, :map, required: true
  attr :chosen, :boolean, required: true

  # An option of a decision: its title, the mark of the run's option on the next line,
  # and its explanation, as `option_words/1` draws an open question's option.
  defp chosen_words(assigns) do
    ~H"""
    <span class="q-xp-opt-w">
      <b class="q-xp-opt-t" phx-no-format>{@option.title}</b>
      <.badge :if={@chosen} class="justify-self-start">{gettext("Chosen by the agent")}</.badge>
      <span class="q-xp-opt-e" phx-no-format>{@option.explanation}</span>
    </span>
    """
  end

  defp chose_words(%{run: run, at: at}, now),
    do:
      rich_gettext("Run %{number} chose it %{when}",
        number: shown_number(run),
        when: inline_ago(at, now)
      )

  defp changed_words(%{by: by, at: at}, now) do
    at = inline_ago(at, now)

    if you?(by),
      do: rich_gettext("You changed it %{when}", when: at),
      else: rich_gettext("%{name} changed it %{when}", name: by.name, when: at)
  end

  defp noted_words(%{by: by, at: at}, now) do
    at = inline_ago(at, now)

    if you?(by),
      do: rich_gettext("You added a note %{when}", when: at),
      else: rich_gettext("%{name} added a note %{when}", name: by.name, when: at)
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
        <span class="q-xp-it q-xp-wrap"><b>{@question.number}. <bdi phx-no-format>{@question.text}</bdi></b></span>
        <span :if={@question.state == :withdrawn} class="q-xp-it" phx-no-format><.badge>{gettext("Withdrawn")}</.badge></span>
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
  # earlier answer muted, under Earlier answer. The pieces of the Earlier answer line
  # have no white space between them, so the margins of the "·" alone set its gaps.
  # The <wbr> between them is the line's break point, and the CSS rule for the "·"
  # covers the piece after the <wbr>. A `q-xp-by` piece wider than the column wraps.
  defp given_answer(assigns) do
    ~H"""
    <p :if={@earlier} id={"#{@id}-who"} class="q-xp-cm-m" phx-no-format><span class="q-xp-it">{gettext("Earlier answer")}</span><wbr /><span class="q-xp-it q-xp-by"><.rich text={answered_words(@answer, @now)} /></span></p>
    <div id={@id} class={["q-xp-ans", @earlier && "q-xp-ans-old"]} phx-no-format><span :if={@answer.option} class="block">{@answer.option}<.recommended_mark :if={@answer[:recommended]} class="ms-1.5" /></span><span :if={@answer.note}>{@answer.note}</span></div>
    <p :if={!@earlier} id={"#{@id}-who"} class="q-xp-cm-m">
      <span class="q-xp-it q-xp-by"><.rich text={answered_words(@answer, @now)} /></span>
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
  # field without a visible label, whose placeholder shows what it takes; a question with
  # no options has the field alone. As text: its options only.
  defp open_question(assigns) do
    question = assigns.question
    n = question.number
    field = "#{assigns.id}-answer-#{n}"
    value = if is_map(assigns.value), do: assigns.value, else: %{}
    message = answer_error(assigns.error)
    own = value["option"] == "own"

    placeholder =
      cond do
        assigns.question.options == [] -> gettext("Give your own option")
        own -> gettext("Your option")
        true -> gettext("Add details (optional)")
      end

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
            :if={@question.options != []}
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

  # An option the run wrote: its title, the mark of the option the run recommends on a line
  # of its own, and its explanation under them, both plain text. The mark is inside the
  # card's label, so a screen reader reads it in the radio button's name.
  defp option_words(assigns) do
    ~H"""
    <span class="q-xp-opt-w">
      <b class="q-xp-opt-t" phx-no-format>{@option.title}</b>
      <.recommended_mark :if={@option[:recommended]} class="justify-self-start" />
      <span class="q-xp-opt-e" phx-no-format>{@option.explanation}</span>
    </span>
    """
  end

  attr :class, :string, required: true

  # The mark of the option a run recommends, on the option's card and on an answer that
  # chose it.
  defp recommended_mark(assigns) do
    ~H"""
    <.badge class={@class}>{gettext("Recommended by the agent")}</.badge>
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
        "Check the questions and your answers, then click Run another round again. The questions changed after the page showed them, so no answer was sent."
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
  question on the Explore tab (`explore_path`, its address; nil links to the question
  on this page). A closed card is muted, with a tick, and folded shows its outcome under
  its first line; a click on the header of a card folds or opens it, in the browser.
  While a run reads the open review comments (`reading`, that run), an open card
  shows that, and no card has Reply.

  A review comment is `%{id:, text:, by:, version:, state:, reopened:, replies:}`, `state`
  `:open` or `:closed`, each reply `%{run:, by:, text:, outcome:, question_number:,
  version:}`: a run's with its number, a member's with `by`, a person.
  """
  attr :id, :string, required: true
  attr :comments, :list, required: true

  attr :reply_path, :any,
    default: nil,
    doc: "a function of a review comment's id: Reply's page; nil or false for no Reply"

  attr :reading, :any, default: nil, doc: "the run that reads them now, or nil"

  attr :explore_path, :string,
    default: nil,
    doc: "the Explore tab's address, for Asked as question; nil links to the question here"

  attr :questions_id, :string,
    default: "work-item-explore-questions",
    doc: "the DOM id of the questions' frame on the tab at `explore_path`"

  attr :level, :string,
    default: "h3",
    values: ~w(h2 h3),
    doc: "the heading's level: `h2` in the right column, `h3` inside the proposal's frame"

  attr :tip, :string,
    default: nil,
    doc:
      "the class of the avatars' tooltips: `tooltip-right` in the right column: that column scrolls, so it cuts the default tooltip, which opens above an avatar at its left edge; a `tooltip-right` tooltip opens to the right and stays inside the column."

  attr :class, :any, default: nil

  def review_comments(assigns) do
    {open, closed} = Enum.split_with(assigns.comments, &(&1.state == :open))
    assigns = assign(assigns, :cards, Enum.with_index(open) ++ Enum.with_index(closed))

    ~H"""
    <section id={@id} class={["q-rc-list", @class]} aria-labelledby={"#{@id}-h"}>
      <.dynamic_tag tag_name={@level} id={"#{@id}-h"} class="q-rc-h">
        {gettext("Comments")}
      </.dynamic_tag>
      <.review_card
        :for={{comment, place} <- @cards}
        id={"#{@id}-#{comment.id}"}
        comment={comment}
        reply_path={@reply_path && @reply_path.(comment.id)}
        reading={@reading}
        explore_path={@explore_path}
        tip={@tip}
        questions_id={@questions_id}
        expanded={place == 0 or (comment.state == :open and is_binary(comment[:target]))}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :comment, :map, required: true
  attr :reply_path, :any, default: nil
  attr :reading, :any, default: nil
  attr :explore_path, :string, default: nil
  attr :questions_id, :string, default: "work-item-explore-questions"
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
            <span>
              <.reply_outcome reply={reply} explore_path={@explore_path} questions_id={@questions_id} />
            </span>
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
        <.rich text={rich_gettext("%{attempt} reads this comment.", attempt: attempt_words(@reading))} />
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
  attr :questions_id, :string, default: "work-item-explore-questions"

  # A run's reply's outcome; Asked links to the question the run added, on the tab at
  # `explore_path`, or on this page where it is nil.
  defp reply_outcome(%{reply: %{outcome: :asked, question_number: n}} = assigns)
       when is_integer(n) do
    ~H"""
    <.link
      href={"#{@explore_path}##{@questions_id}-question-#{@reply.question_number}"}
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

  # A review comment on the whole round of a run has the run's attempt, as the Thread's
  # line of that comment has it (`event_line/1`).
  defp comment_by(%{by: by, run: run} = comment) when is_integer(run) do
    attempt = shown_number(comment[:attempt])

    if you?(by),
      do: gettext("You, on the round of attempt %{attempt}", attempt: attempt),
      else:
        gettext("%{name}, on the round of attempt %{attempt}", name: by.name, attempt: attempt)
  end

  # A card on a stage's tab has its target (`:target`), the type's words.
  defp comment_by(%{by: by, version: version, target: target}) do
    if you?(by),
      do:
        gettext("You, on %{target} version %{version}",
          target: target,
          version: Format.number(version)
        ),
      else:
        gettext("%{name}, on %{target} version %{version}",
          name: by.name,
          target: target,
          version: Format.number(version)
        )
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
  The form page of a reply to a review comment (`comment`): its field, its error under it
  (`error`, as `comment_error/2` words it), the button, and Cancel back to its tab
  (`cancel`). With the line that nothing can be sent (`:changed`), the page has no button.
  It sends `"reply"`, with `number`, `text` and `comment`, the review comment's id; as
  the reader writes, `"page_draft"` with the same fields, so the page keeps the draft
  (`value`).
  """
  attr :id, :string, default: "work-item-review-page"
  attr :number, :integer, required: true
  attr :comment, :map, required: true
  attr :value, :string, default: ""
  attr :error, :any, default: nil
  attr :submits, :integer, default: 0
  attr :cancel, :string, required: true

  def review_page(assigns) do
    assigns =
      assign(assigns,
        message: comment_error(assigns.error, :reply),
        answer_units: @answer_units
      )

    ~H"""
    <.page_form id={@id} title={gettext("Reply")}>
      <.review_card id={"#{@id}-comment"} comment={@comment} expanded />
      <form id={"#{@id}-form"} class="q-form" phx-change="page_draft" phx-submit="reply" novalidate>
        <input type="hidden" name="number" value={@number} />
        <input type="hidden" name="comment" value={@comment.id} />
        <div class="fieldset">
          <label for={"#{@id}-text"} class="text-[13px]/[18px] font-medium">
            {gettext("Reply")}
          </label>
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
            <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /><.rich text={@message} />
          </p>
        </div>
        <span
          :if={@message}
          id={"#{@id}-focus-#{@submits}"}
          hidden
          phx-mounted={JS.focus(to: "##{@id}-text")}
        ></span>
        <.page_form_foot cancel={@cancel} cancel_by="patch">
          <.button :if={@error != :changed} type="submit" variant="primary">
            {gettext("Reply")}
          </.button>
        </.page_form_foot>
      </form>
    </.page_form>
    """
  end

  @doc false
  # store_error/0 is the words under a form whose send found the artifact store out of
  # reach (`:store_unavailable`), so nothing was written.
  @spec store_error() :: String.t()
  def store_error, do: gettext("Try again in a minute. The artifact store cannot be reached.")

  @doc false
  # send_error/1 is the words under a form whose send wrote nothing, by why: a run that
  # started first (`{:running, run}`, that run); the artifact store out
  # of reach (`:store_unavailable`); a work item that changed after the page showed it
  # (`:stale`, `:not_waiting`); the reader's access or the work item changed
  # (`:forbidden`, `:not_found`, `:not_live`); and for any other, that it was not saved.
  @spec send_error(term) :: term
  def send_error({:running, run}),
    do:
      rich_gettext(
        "Send it again when attempt %{number} ends. %{attempt} started first, so nothing was sent.",
        number: shown_number(run[:attempt]),
        attempt: attempt_words(run)
      )

  def send_error(:store_unavailable), do: store_error()

  def send_error(reason) when reason in [:stale, :not_waiting],
    do:
      gettext(
        "Check the page, then send again. The work item changed after the page showed it, so nothing was sent."
      )

  def send_error(reason) when reason in [:forbidden, :not_found, :not_live],
    do: gettext("Reload the page. Your access or the work item changed, so nothing was sent.")

  def send_error(_reason), do: gettext("Send again. Qory Apiary could not save it.")

  @doc false
  # comment_error/2 is the words of what is wrong with the comment on the whole proposal
  # (`:comment`) or a reply (`:reply`); nil for an error without words.
  @spec comment_error(term, :comment | :reply) :: term
  def comment_error(:reply_blank, _kind), do: gettext("Write your reply.")

  def comment_error({:too_long, _limit}, :comment),
    do: gettext("Shorten the comment to 2,000 characters or fewer.")

  def comment_error({:too_long, _limit}, :reply),
    do: gettext("Shorten the reply to 2,000 characters or fewer.")

  def comment_error(:characters, :comment),
    do: gettext("Remove the invisible or control characters from the comment.")

  def comment_error(:characters, :reply),
    do: gettext("Remove the invisible or control characters from the reply.")

  def comment_error(:not_approver, _kind),
    do:
      gettext(
        "Ask one of this stage's approvers to write comments on the proposal. Only approvers of the stage can write them."
      )

  def comment_error({:running, _run} = running, _kind), do: send_error(running)

  def comment_error(:changed, :reply),
    do:
      gettext(
        "Copy your text if you need it. You can no longer send this reply, because the work item changed."
      )

  def comment_error(reason, _kind)
      when reason in [:store_unavailable, :stale, :forbidden, :not_found, :not_live, :not_saved],
      do: send_error(reason)

  def comment_error(_error, _kind), do: nil

  @doc false
  # foot_record/1 is the record block at the foot of the Ticket tab and the Thread, at a
  # stage after Explore. `foot` is `%{runs:, latest:, pieces:}`: every run of the current
  # take in, as Details counts them, oldest first; the latest of them; and the summary's
  # pieces after the count. It has the id of the Explore tab's block, and each tab draws
  # one block.
  attr :foot, :map, required: true
  attr :number, :integer, required: true, doc: "the work item's number"

  attr :item_noun, :map,
    default: nil,
    doc: "what its ticket's source calls its items (`Apiary.Adapters.item_noun/1`)"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  attr :verdicts, :list,
    default: [],
    doc:
      "the stage runs of the take in (`ApiaryWeb.WorkItemLive.Workflow.page/2`'s `runs`): a fold row shows the workflow, the round and the verdict of the one with its attempt"

  slot :inner_block, doc: "the artifacts"

  def foot_record(assigns) do
    assigns = assign(assigns, now: now(assigns), item: SourceComponents.item(assigns.item_noun))

    ~H"""
    <.record
      id="work-item-record"
      class="q-xp-earlier q-wi-foot"
      number={@number}
      runs={@foot.runs}
      latest={@foot.latest}
      pieces={@foot.pieces}
      verdicts={@verdicts}
      item={@item}
      now={@now}
    >
      {render_slot(@inner_block)}
    </.record>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: "q-xp-earlier"
  attr :number, :integer, default: nil, doc: "the work item's number, for `\"open_fold\"`"
  attr :runs, :list, required: true, doc: "the take in's runs, oldest first"
  attr :latest, :map, default: nil, doc: "its latest run, where it is among `runs`"

  attr :pieces, :list,
    default: nil,
    doc: "the summary's pieces after the count; nil for `proposal` and `questions_version`"

  attr :proposal, :map, default: nil
  attr :questions_version, :integer, default: nil

  attr :verdicts, :list,
    default: [],
    doc:
      "the stage runs of the take in (`ApiaryWeb.WorkItemLive.Workflow.page/2`'s `runs`): a fold row shows the workflow, the round and the verdict of the one with its attempt"

  attr :item, :string, required: true
  attr :now, :any, required: true
  slot :inner_block, doc: "the artifacts"

  # One fold of the take in's runs and its artifacts: how many runs, and `pieces`, or the
  # newest proposal's and questions' versions, each where it has a number; opened, each
  # run's line (`run_parts/4`). An earlier run of Explore that wrote a proposal is a fold with
  # that version, one without a result a fold with what happened; the latest run, a run
  # with nothing to show, and a later stage's run, a row. A proposal the page has not read
  # (`:unread`) is read when its fold opens (`"open_fold"`, with its version). The folds
  # keep the state the reader gave them when the page draws again.
  defp record(assigns) do
    assigns =
      assign(assigns,
        count: length(assigns.runs),
        pieces: assigns.pieces || explore_pieces(assigns.proposal, assigns.questions_version),
        verdicts:
          for(%{attempt: n} = run <- assigns.verdicts, is_integer(n), into: %{}, do: {n, run})
      )

    ~H"""
    <section id={@id} class={@class} aria-labelledby={"#{@id}-h"}>
      <h2 id={"#{@id}-h"} class="sr-only">{gettext("Runs and artifacts")}</h2>
      <details id={"#{@id}-fold"} phx-mounted={JS.ignore_attributes(["open"])}>
        <summary>
          <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
          <span class="q-xp-parts">
            <span class="q-xp-it"><b>{ngettext("1 run", "%{count} runs", @count)}</b></span>
            <%= for piece <- @pieces do %>
              <span class="q-xp-it">{piece}</span>
            <% end %>
          </span>
        </summary>
        <div class="q-xp-inner">
          <%= for run <- @runs do %>
            <%= case run_shows(run, run == @latest) do %>
              <% :row -> %>
                <div id={"#{@id}-#{run_dom(run)}"} class="q-xp-runrow">
                  <span class="q-xp-parts">
                    <%= for part <- run_parts(attempt_words(run), run, @verdicts[run[:attempt]], @now) do %>
                      <span class="q-xp-it"><.rich text={part} /></span>
                    <% end %>
                  </span>
                </div>
              <% shows -> %>
                <details
                  id={"#{@id}-#{run_dom(run)}"}
                  phx-mounted={JS.ignore_attributes(["open"])}
                >
                  <summary
                    id={"#{@id}-#{run_dom(run)}-s"}
                    phx-click={unread?(run[:wrote_proposal]) && "open_fold"}
                    phx-value-number={@number}
                    phx-value-version={run[:wrote]}
                  >
                    <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
                    <span class="q-xp-parts">
                      <%= for part <- run_parts(attempt_words(run), run, @verdicts[run[:attempt]], @now) do %>
                        <span class="q-xp-it"><.rich text={part} /></span>
                      <% end %>
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

  # The summary's pieces at Explore: the newest proposal's and questions' versions, each
  # where it has a number.
  defp explore_pieces(proposal, questions_version) do
    proposal_version =
      case proposal do
        %{version: version} when is_integer(version) -> version
        _none -> nil
      end

    [
      proposal_version &&
        gettext("proposal v%{version}", version: Format.number(proposal_version)),
      questions_version &&
        gettext("questions v%{version}", version: Format.number(questions_version))
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Whether a proposal is one the page has not read (`:unread`).
  defp unread?(%{unread: number}) when is_integer(number), do: true
  defp unread?(_proposal), do: false

  # What a run shows in the fold: a row for the latest run, a later stage's run and a run
  # with nothing to show; `:proposal` for an earlier run that wrote one; `:none` for a run
  # without a result. The words of `:none` are Explore's, so a later stage's run has none.
  defp run_shows(_run, true), do: :row
  defp run_shows(%{other_stage: true}, _last), do: :row
  defp run_shows(%{wrote_proposal: %{}}, _last), do: :proposal
  defp run_shows(%{state: state}, _last) when state in [:failed, :lost, :cancelled], do: :none
  defp run_shows(_run, _last), do: :row

  # A run's line in the fold: its attempt, the workflow, the round and the verdict of its
  # stage run (`StageComponents.verdict_parts/2`), running blue or amber as its badge, and
  # when it ended; while it runs, when it started. A stage run handed over whose run has
  # not started (state nil or pending) reads queued, as the tab's top line (`run_line/1`).
  # A stage run with no verdict (running, or ended without one) whose run failed, was
  # lost, was cancelled or paused reads that state, as the top line, in place of the
  # verdict; a paused run that a run continues shows why it paused
  # (`StageComponents.verdict_parts/2`).
  # A run with no stage run has what it wrote, or its state, in place of the three. In a
  # fold's summary, a click on `place`'s link opens the run's page, and a click beside it
  # opens the fold (`open_fold`).
  defp run_parts(place, run, %{} = stage_run, now) do
    stage_run =
      if stage_run.shows == :running and run[:state] in [nil, :pending],
        do: %{stage_run | shows: :queued},
        else: stage_run

    parts = StageComponents.verdict_parts(stage_run, running_word_class(run))

    # The verdict is the last of `parts`: `verdict_parts/2` drops only a missing workflow
    # or round.
    parts =
      if stage_run.shows in [:running, :no_verdict] and
           run[:state] in [:failed, :lost, :cancelled, :paused],
         do: List.replace_at(parts, -1, RunComponents.state_label(run.state)),
         else: parts

    time =
      case run[:state] do
        :running -> run_time(run, now)
        _other -> run[:ended_at] && ended_ago(run.ended_at, now)
      end

    # A rich text is a list of pieces, so `time` goes in whole, not through `List.wrap/1`.
    [{:b, place} | parts] ++ if(time, do: [time], else: [])
  end

  defp run_parts(place, run, nil, now) do
    attempt = {:b, place}

    rest =
      case run[:state] do
        state when state in [nil, :pending] ->
          [gettext("Queued")]

        :running ->
          [running_word(%{run: run}), run_time(run, now)]

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
            cond do
              run[:paused] ->
                said ++ [PauseWords.line(run.paused, run[:paused_path])]

              said == [] or run.state in [:failed, :lost, :cancelled, :paused] ->
                said ++ [RunComponents.state_label(run.state)]

              true ->
                said
            end

          said ++ List.wrap(run[:ended_at] && ended_ago(run.ended_at, now))
      end

    [attempt | Enum.reject(rest, &is_nil/1)]
  end

  defp ended_ago(at, now), do: time_tag(at, Format.relative(at, now))

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :no_pool, :map, required: true

  # A queued run that no pool can take: which attempt, why with its step on the Machines
  # page, and Open Machines.
  defp no_pool_box(assigns) do
    assigns =
      assign(assigns,
        heading:
          rich_gettext("No pool can take %{attempt}.", attempt: run_place_lower(assigns.run)),
        reason: no_pool_reason(assigns.no_pool)
      )

    ~H"""
    <div id={@id} class="q-xp-wait q-xp-bad">
      <.icon name="hero-exclamation-triangle-micro" class="q-xp-bad-i size-4" />
      <div>
        <p id={"#{@id}-h"}><b><.rich text={@heading} /></b></p>
        <p id={"#{@id}-reason"}><.rich text={@reason} /></p>
        <div :if={@no_pool.path} class="q-wi-acts mt-3">
          <.button id={"#{@id}-open"} navigate={@no_pool.path}>{gettext("Open Machines")}</.button>
        </div>
      </div>
    </div>
    """
  end

  # Why no pool can take the run, from the Machines set-up step's lines (`no_pool.pools`),
  # each sentence with its step on the Machines page: the reason every line shares, where
  # all have one; else one sentence for any reason. The instance's pool is fixed by an
  # instance admin, so its sentence has the step a member of the workspace takes: a pool
  # of the workspace in its place. A line the edition did not count but that the step reads
  # as ready has no reason here, so it gets the sentence for any reason.
  defp no_pool_reason(%{pools: lines, workspace: workspace, path: path}) do
    machines =
      if path, do: {:link, path, gettext("Machines"), "text-accent"}, else: gettext("Machines")

    count = length(lines)
    number = Format.number(count)

    case lines |> Enum.map(&line_reason/1) |> Enum.uniq() do
      [:no_pool] ->
        rich_gettext(
          "No pool takes the runs of %{workspace}. Add a pool on the %{machines} page.",
          workspace: workspace,
          machines: machines
        )

      [:instance] ->
        rich_gettext(
          "The Qory Pool takes the runs of %{workspace}, and it is not ready. Add a pool for %{workspace} on the %{machines} page.",
          workspace: workspace,
          machines: machines
        )

      [:no_active_key] ->
        rich_ngettext(
          "The pool of %{workspace} has no active access key. Enrol a machine on the pool on the %{machines} page.",
          "The %{number} pools of %{workspace} have no active access key. Enrol a machine on a pool on the %{machines} page.",
          count,
          number: number,
          workspace: workspace,
          machines: machines
        )

      [:direct] ->
        rich_ngettext(
          "The pool of %{workspace} is set to Direct, and a run needs a gateway. Choose a gateway for the pool on the %{machines} page.",
          "The %{number} pools of %{workspace} are set to Direct, and a run needs a gateway. Choose a gateway for a pool on the %{machines} page.",
          count,
          number: number,
          workspace: workspace,
          machines: machines
        )

      [:no_gateway] ->
        rich_ngettext(
          "No gateway exists for the gateway choice of the pool of %{workspace}. Choose a gateway for the pool on the %{machines} page.",
          "No gateway exists for the gateway choices of the %{number} pools of %{workspace}. Choose a gateway for a pool on the %{machines} page.",
          count,
          number: number,
          workspace: workspace,
          machines: machines
        )

      [:gateway_not_serving] ->
        rich_ngettext(
          "The gateway chosen for the pool of %{workspace} does not serve %{workspace}. Choose another gateway for the pool on the %{machines} page.",
          "The gateways chosen for the %{number} pools of %{workspace} do not serve %{workspace}. Choose another gateway for a pool on the %{machines} page.",
          count,
          number: number,
          workspace: workspace,
          machines: machines
        )

      [:gateway_without_key] ->
        rich_ngettext(
          "The gateway of the pool of %{workspace} has no active access key. Enrol a machine on the gateway on the %{machines} page.",
          "The gateways of the %{number} pools of %{workspace} have no active access key. Enrol a machine on a gateway on the %{machines} page.",
          count,
          number: number,
          workspace: workspace,
          machines: machines
        )

      _any ->
        rich_gettext(
          "No pool of %{workspace} is ready to take runs. Set up a pool on the %{machines} page.",
          workspace: workspace,
          machines: machines
        )
    end
  end

  defp line_reason(%{state: {:not_ready, :no_pool}}), do: :no_pool
  defp line_reason(%{instance: true, state: {:not_ready, _reason}}), do: :instance
  defp line_reason(%{state: {:not_ready, reason}}), do: reason
  defp line_reason(_ready), do: :ready

  attr :id, :string, required: true
  attr :run, :map, required: true

  attr :earlier, :boolean,
    default: false,
    doc: "whether a proposal of an earlier round shows below"

  # A run that gave no result: what happened, and its page.
  defp no_result(assigns) do
    {icon, heading, body} = no_result_words(assigns.run, assigns.earlier)
    assigns = assign(assigns, icon: icon, heading: heading, body: body)

    ~H"""
    <div id={@id} class="q-xp-wait q-xp-bad">
      <.icon name={@icon} class="q-xp-bad-i size-4" />
      <div>
        <p id={"#{@id}-h"}><b><.rich text={place_ref(@run, @heading)} /></b></p>
        <p :if={@body}><.rich text={@body} /></p>
        <p :if={@run[:adapter_failure]} id={"#{@id}-adapter"}>
          <.rich text={adapter_failure_words(@run.adapter_failure)} />
        </p>
        <p :if={@run[:id]}>
          <.rich text={
            rich_gettext("The page of %{attempt} shows what it did.",
              attempt: attempt_words_lower(@run)
            )
          } />
        </p>
      </div>
    </div>
    """
  end

  # Explore's tab of an ended work item where no run of the take in started, in place of
  # `no_result/1`: an undone one, or a closed one whose take in queued no run. The frame
  # has how the work item ended, not an end of a run.
  defp ended(assigns) do
    {heading, body} = ended_tab_words(assigns.work_item, assigns.now)
    assigns = assign(assigns, heading: heading, body: body)

    ~H"""
    <div id={@id} class="q-xp-wait">
      <.icon name={end_icon(@work_item.status)} class="q-xp-wait-i size-4" />
      <div>
        <p :if={@heading} id={"#{@id}-h"}><b><.rich text={@heading} /></b></p>
        <p :if={@body} id={"#{@id}-body"}>{@body}</p>
      </div>
    </div>
    """
  end

  # The words of Explore's tab for an ended work item with no run that started: how it
  # ended, as the notice above the tabs has it (`end_line/2`), then what is left. The one
  # place they are set.
  defp ended_tab_words(work_item, now),
    do: {end_line(work_item, now), gettext("There is nothing to show or approve.")}

  # A run that pushed a proposal before it ended shows that proposal on the tab, so the
  # page shows no line that there is nothing to show.
  defp no_result_words(%{state: :failed, wrote: version}, _earlier) when is_integer(version),
    do: {"hero-exclamation-triangle-micro", failed_after(version), nil}

  defp no_result_words(%{state: :lost, wrote: version}, _earlier) when is_integer(version),
    do: {"hero-signal-slash-micro", gettext("The run was lost."), nil}

  defp no_result_words(%{state: :lost}, earlier),
    do:
      {"hero-signal-slash-micro", gettext("The run was lost."),
       if(earlier,
         do:
           gettext(
             "Qory Apiary has no result from the run. The proposal below is from an earlier round."
           ),
         else:
           gettext("Qory Apiary has no result from the run. There is nothing to show or approve.")
       )}

  defp no_result_words(%{state: :cancelled, wrote: version}, _earlier)
       when is_integer(version),
       do: {"hero-stop-circle-micro", gettext("The run was cancelled."), nil}

  defp no_result_words(%{state: :cancelled}, earlier),
    do: {"hero-stop-circle-micro", gettext("The run was cancelled."), nothing_left(earlier)}

  defp no_result_words(%{end_cause: :harness_unresolved} = run, _earlier),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       harness_failure_words(run[:harness_failure])}

  defp no_result_words(%{end_cause: :run_refused, end_detail: "model_key_missing"}, _earlier),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       gettext(
         "Add a model key in Organisation settings › Model providers. The gateway had no model key for the run."
       )}

  defp no_result_words(%{end_cause: cause}, _earlier) when cause in @unstarted,
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       unstarted_words(cause)}

  defp no_result_words(%{workflow_gap: %{} = gap}, _earlier),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run did not start."),
       ApiaryWeb.HarnessComponents.workflow_gap_words(gap)}

  defp no_result_words(%{read_needs: %{} = facts}, _earlier),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended without a result."),
       read_needs_words(facts)}

  defp no_result_words(%{outcome: :none}, earlier),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended without a result."),
       nothing_left(earlier)}

  defp no_result_words(%{outcome: :refused}, _earlier),
    do:
      {"hero-exclamation-triangle-micro",
       gettext("The run's result did not pass Qory Apiary's check."),
       gettext(
         "Qory Apiary accepts a result only in Explore's format and up to 128 KiB. This result is outside those limits, so it is not shown."
       )}

  defp no_result_words(_error, earlier),
    do:
      {"hero-exclamation-triangle-micro", gettext("The run ended with an error."),
       if(earlier,
         do:
           gettext(
             "The run's last result was an error. The proposal below is from an earlier round."
           ),
         else: gettext("The run's last result was an error. There is nothing to show or approve.")
       )}

  # What is left to read below a run with no result: a proposal of an earlier round
  # (`earlier`), or nothing.
  defp nothing_left(true), do: gettext("The proposal below is from an earlier round.")
  defp nothing_left(false), do: gettext("There is nothing to show or approve.")

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

      "ref_missing" ->
        HarnessComponents.qory_words(
          {:ref_missing, failure.rule["values"]["ref"]},
          if(failure.rule["values"]["builtin"] == true, do: :builtin, else: :run),
          failure.rule["values"]["url"]
        )

      "harness_unreadable" ->
        HarnessComponents.qory_words(
          {:unreadable, Qory.cause_of(failure.rule["values"]["cause"]), nil},
          :run,
          failure.rule["values"]["url"]
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
  # `h3`, under the `h2` of Earlier take ins: "Question and answer" where the answers
  # show, else "Question", each by the count of the questions.
  defp run_body(%{run: %{outcome: :questions}} = assigns) do
    n = length(assigns.run.questions)

    assigns =
      assign(assigns,
        n: n,
        heading:
          if(answered?(assigns.run),
            do: ngettext("Question and answer", "Questions and answers", n),
            else: ngettext("Question", "Questions", n)
          )
      )

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <div class="q-xp-frame-h">
        <h3 id={"#{@id}-h"} class="q-xp-frame-t">{@heading}</h3>
      </div>
      <p class="q-xp-cap">
        <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
        <span>
          <.rich text={
            rich_ngettext(
              "%{attempt} wrote this question.",
              "%{attempt} wrote these questions.",
              @n,
              attempt: attempt_words(@run)
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
    <.proposal_frame id={@id} run={@run} now={@now} level="h3" />
    """
  end

  defp run_body(assigns) do
    ~H"""
    <.no_result id={@id} run={@run} />
    """
  end

  attr :id, :string, required: true
  attr :number, :integer, default: nil, doc: "the work item's number, for `\"open_fold\"`"
  attr :take_ins, :list, required: true
  attr :item, :string, required: true, doc: "the source's word for one of its items"
  attr :now, :any, required: true

  # The earlier take ins, each folded: who took it in and when, how it ended, how many
  # runs; inside, its runs, which counted apart from this take in. The proposals of its
  # runs that the page has not read (`:unread`) are read when its fold opens
  # (`"open_fold"`, with its place from 1). The folds keep the state the reader gave them
  # when the page draws again.
  defp earlier_take_ins(assigns) do
    ~H"""
    <section id={@id} class="q-xp-earlier" aria-labelledby={"#{@id}-h"}>
      <h2 id={"#{@id}-h"} class="q-xp-earlier-t">{gettext("Earlier take ins")}</h2>
      <details
        :for={{take_in, i} <- Enum.map(Enum.with_index(@take_ins, 1), &take_in_place/1)}
        id={"#{@id}-#{i}"}
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary
          id={"#{@id}-#{i}-s"}
          phx-click={Enum.any?(take_in.runs, &unread?(&1[:proposal])) && "open_fold"}
          phx-value-number={@number}
          phx-value-take_in={i}
        >
          <.icon name="hero-chevron-right-micro" class="q-xp-chev size-3.5" />
          <span class="q-xp-parts">
            <span class="q-xp-it"><b><.rich text={taken_in_words(take_in, @now)} /></b></span>
            <span :if={ended_words(take_in, @now)} class="q-xp-it" phx-no-format><.rich text={ended_words(take_in, @now)} /></span>
            <span class="q-xp-it">{ngettext("%{count} run", "%{count} runs", length(take_in.runs))}</span>
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

  # A take in's place among all of the work item's: a tab that lists only some keeps it, so
  # `"open_fold"` reads the right one.
  defp take_in_place({take_in, i}), do: {take_in, Map.get(take_in, :place, i)}

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
  name), `:at`, `:body` and `:format`; a member's comment has how far its post at the
  source is, after its time (`BacklogComponents.post_state/1`), and, where it was not
  posted, why under its text, with Post again (`post_again`) where the page gives it
  (`BacklogComponents.post_failure/1`).
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

  attr :post_again, :any,
    default: nil,
    doc: "Post again's `phx-click` on a comment not posted; nil draws none"

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
            <BacklogComponents.post_state
              id={"#{@id}-comment-#{comment.public_id}-post"}
              comment={comment}
              source={@integration}
            />
          </div>
          <div class="q-wi-cmt-txt">
            <SourceComponents.body
              id={"#{@id}-comment-#{comment.public_id}-text"}
              body={comment.body}
              format={comment.format}
              item_noun={@item_noun}
            />
          </div>
          <BacklogComponents.post_failure
            id={"#{@id}-comment-#{comment.public_id}-failed"}
            comment={comment}
            source={@integration}
            item_noun={@item_noun}
            post_again={@post_again}
            class="q-wi-cmt-txt"
          />
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
      review comments a member sent (`start: :review_comments`), again with the answers
      (`start: :answers`), or again after Run Explore again or a retry
      (`start: :again`), with the run's place in the take in beside it;
    * `:asked` - how many questions Qory wrote and after how long (`questions`,
      `duration`), the questions quoted under it;
    * `:answered` - who answered Qory's questions, each question and its answer quoted;
      or who wrote a review comment on the proposal or on another output (`comment`, on
      the type `artifact`), or a reply to one
      (`comment`, with `reply` true), the text quoted;
    * `:proposed` - Qory wrote a proposal, after how long, and whose turn it is
      (`owner`, set only on the proposal that waits at Confirm), or only after how long
      where it has no owner;
    * `:replied` - Qory wrote no proposal and no question, but wrote replies to review
      comments: to how many (`replies`) and after how long (`duration`);
    * `:no_result`, `:lost`, `:cancelled` - a run (`run`) that gave no result, and why
      (`outcome`: `:error`, `:none` or `:refused`), or for a failed run that pushed a
      proposal first, its version (`wrote`); for a run the gateway stopped for
      want of a model key (`end_cause: :run_refused`, `end_detail: "model_key_missing"`),
      what a member fixes;
    * `:explore_again` - who ran Explore again;
    * `:confirmed` - who approved the proposal, with their changes (`changed`);
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
      :replied,
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

  attr :start, :atom,
    default: nil,
    values: [nil, :review_comments, :answers, :again],
    doc: "`:started`: how"

  attr :run, :map, default: nil, doc: "the run, as above"

  attr :stage, :string,
    default: nil,
    doc: "the name of the stage after Explore's that `run` ran at; nil for Explore"

  attr :questions, :list, default: [], doc: "`:asked`, `:answered`: the questions, as above"
  attr :comment, :string, default: nil, doc: "`:answered`: a comment on an output"
  attr :artifact, :string, default: nil, doc: "`:answered`: the type `comment` is on"
  attr :reply, :boolean, default: false, doc: "`:answered`: whether `comment` is a reply"

  attr :replies, :integer,
    default: 0,
    doc: "`:replied`: to how many review comments it wrote a reply"

  attr :duration, :string,
    default: nil,
    doc: "`:asked`, `:proposed`, `:replied`: how long the run took"

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
        qory: assigns.kind in [:started, :asked, :proposed, :replied],
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

  # How a run at a stage after Explore's started, with the stage's name.
  defp stage_started(stage, :review_comments, attempt),
    do:
      rich_gettext("%{stage} started again, with the comments, in attempt %{attempt}",
        stage: stage,
        attempt: attempt
      )

  defp stage_started(stage, :answers, attempt),
    do:
      rich_gettext("%{stage} started again, with the answers, in attempt %{attempt}",
        stage: stage,
        attempt: attempt
      )

  defp stage_started(stage, :again, attempt),
    do:
      rich_gettext("%{stage} started again in attempt %{attempt}", stage: stage, attempt: attempt)

  defp stage_started(stage, nil, attempt),
    do: rich_gettext("%{stage} started in attempt %{attempt}", stage: stage, attempt: attempt)

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

  defp event_line(%{kind: :started, stage: stage, start: start, run: run})
       when is_binary(stage),
       do: stage_started(stage, start, attempt_ref(run))

  defp event_line(%{kind: :started, start: :review_comments, run: run}),
    do:
      rich_gettext("Explore started again, with the comments, in attempt %{attempt}",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :started, start: :answers, run: run}),
    do:
      rich_gettext("Explore started again, with the answers, in attempt %{attempt}",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :started, start: :again, run: run}),
    do: rich_gettext("Explore started again in attempt %{attempt}", attempt: attempt_ref(run))

  defp event_line(%{kind: :started, run: run}),
    do: rich_gettext("Explore started in attempt %{attempt}", attempt: attempt_ref(run))

  defp event_line(%{kind: :asked, stage: stage, questions: questions, duration: duration})
       when is_binary(stage) do
    n = length(questions)

    ngettext(
      "%{stage} wrote 1 question, after %{duration}",
      "%{stage} wrote %{number} questions, after %{duration}",
      n,
      stage: stage,
      number: Format.number(n),
      duration: duration
    )
  end

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

  defp event_line(%{kind: :answered, actor: actor, comment: comment, reply: true})
       when is_binary(comment) do
    if you?(actor),
      do: gettext("You replied to a comment"),
      else: rich_gettext("%{name} replied to a comment", name: {:b, actor.name})
  end

  # Run another round with answers and a comment: one line for both.
  defp event_line(%{
         kind: :answered,
         actor: actor,
         comment: comment,
         questions: [_ | _] = questions
       })
       when is_binary(comment) do
    n = length(questions)
    number = Format.number(n)

    if you?(actor),
      do:
        ngettext(
          "You answered 1 question and wrote a comment",
          "You answered %{number} questions and wrote a comment",
          n,
          number: number
        ),
      else:
        rich_ngettext(
          "%{name} answered 1 question and wrote a comment",
          "%{name} answered %{number} questions and wrote a comment",
          n,
          name: {:b, actor.name},
          number: number
        )
  end

  # A comment on the round of a run at a stage after Explore's.
  defp event_line(%{
         kind: :answered,
         actor: actor,
         comment: comment,
         artifact: nil,
         stage: stage,
         run: run
       })
       when is_binary(comment) and is_binary(stage) do
    if you?(actor),
      do:
        rich_gettext("You wrote a comment on the round of attempt %{attempt}",
          attempt: attempt_ref(run)
        ),
      else:
        rich_gettext("%{name} wrote a comment on the round of attempt %{attempt}",
          name: {:b, actor.name},
          attempt: attempt_ref(run)
        )
  end

  defp event_line(%{kind: :answered, actor: actor, comment: comment})
       when is_binary(comment) do
    if you?(actor),
      do: gettext("You wrote a comment on the proposal"),
      else: rich_gettext("%{name} wrote a comment on the proposal", name: {:b, actor.name})
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

  defp event_line(%{kind: :replied, stage: stage, replies: n, duration: duration})
       when is_binary(stage),
       do:
         ngettext(
           "%{stage} wrote a reply to 1 comment, after %{duration}",
           "%{stage} wrote replies to %{number} comments, after %{duration}",
           n,
           stage: stage,
           number: Format.number(n),
           duration: duration
         )

  defp event_line(%{kind: :replied, replies: n, duration: duration}),
    do:
      ngettext(
        "Explore wrote a reply to 1 comment, after %{duration}",
        "Explore wrote replies to %{number} comments, after %{duration}",
        n,
        number: Format.number(n),
        duration: duration
      )

  defp event_line(%{kind: :proposed, owner: nil, duration: duration}),
    do: rich_gettext("Explore wrote a proposal, after %{duration}", duration: duration)

  # Where the stage lists approvers, the page passes who confirms next as `confirmers`:
  # `:you` for a reader who may confirm, else the approvers, in the gate's order, the
  # reader among them where listed (`others/1`).
  defp event_line(%{kind: :proposed, confirmers: :you, duration: duration}),
    do:
      rich_gettext("Explore wrote a proposal, after %{duration}. You approve next",
        duration: duration
      )

  defp event_line(%{kind: :proposed, confirmers: [_ | _] = confirmers, duration: duration}),
    do: proposed_line(others(confirmers), duration)

  defp event_line(%{kind: :proposed, owner: owner, duration: duration}) do
    if you?(owner),
      do:
        rich_gettext(
          "Explore wrote a proposal, after %{duration}. You approve next",
          duration: duration
        ),
      else:
        rich_gettext(
          "Explore wrote a proposal, after %{duration}. %{name} approves next",
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

  defp event_line(%{kind: :no_result, stage: stage, run: run}) when is_binary(stage),
    do:
      rich_gettext("Attempt %{attempt} ended with an error, so %{stage} has no result",
        attempt: attempt_ref(run),
        stage: stage
      )

  defp event_line(%{kind: :no_result, run: run}),
    do:
      rich_gettext("Attempt %{attempt} ended with an error, so Explore has no result",
        attempt: attempt_ref(run)
      )

  defp event_line(%{kind: :lost, stage: stage, run: run}) when is_binary(stage),
    do:
      rich_gettext("Attempt %{attempt} was lost before it ended, so %{stage} has no result",
        attempt: attempt_ref(run),
        stage: stage
      )

  defp event_line(%{kind: :cancelled, stage: stage, run: run}) when is_binary(stage),
    do:
      rich_gettext(
        "Attempt %{attempt} was cancelled before it ended, so %{stage} has no result",
        attempt: attempt_ref(run),
        stage: stage
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
      do: gettext("You changed the proposal and approved it. Ready for Shape"),
      else:
        rich_gettext("%{name} changed the proposal and approved it. Ready for Shape",
          name: {:b, actor.name}
        )
  end

  defp event_line(%{kind: :confirmed, actor: actor}) do
    if you?(actor),
      do: gettext("You approved the proposal. Ready for Shape"),
      else: rich_gettext("%{name} approved the proposal. Ready for Shape", name: {:b, actor.name})
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

  # A proposal's line with the approvers who approve next. With no approver left, no one
  # is named.
  defp proposed_line([], duration),
    do: rich_gettext("Explore wrote a proposal, after %{duration}", duration: duration)

  defp proposed_line([one], duration),
    do:
      rich_gettext("Explore wrote a proposal, after %{duration}. %{name} approves next",
        duration: duration,
        name: {:b, one.name}
      )

  defp proposed_line([one, other], duration),
    do:
      rich_gettext(
        "Explore wrote a proposal, after %{duration}. %{name} or %{other} approves next",
        duration: duration,
        name: {:b, one.name},
        other: {:b, other.name}
      )

  defp proposed_line(confirmers, duration),
    do:
      rich_gettext(
        "Explore wrote a proposal, after %{duration}. One of %{number} approvers approves next",
        duration: duration,
        number: Format.number(length(confirmers))
      )

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
            {gettext("Members of %{workspace} see this. Qory Apiary posts nothing to the %{item}.",
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
