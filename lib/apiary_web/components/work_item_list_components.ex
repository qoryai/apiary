defmodule ApiaryWeb.WorkItemListComponents do
  # The parts of the Work items list (`/:org/:workspace/work`): its head, the stages strip,
  # the views, the search, the Filter menu and its tokens, a view's note, a stage's band,
  # a work item's row, the pager of Closed, and the empty list.
  #
  # Every component takes plain assigns, as `ApiaryWeb.WorkItemComponents` describes: a
  # work item is a map with `:number`, `:title`, `:external_ref`, `:status`, `:owner`,
  # `:ended_by` and `:updated_at`, and a person a map with `:name` and `:you`. Every DOM
  # id and path is Qory Apiary's: the work item's number, and the paths the page gives.
  # The ticket's ref is text only.
  #
  # What waits at Confirm is said one way on the strip and on Confirm's band: `waiting`
  # is `%{count: n, for: whom}`, `whom` being `:you` (the reader's work items), `:member`
  # (any member's) or a name (the list filtered to that owner), or `nil` when nothing
  # waits.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  import ApiaryWeb.WorkItemComponents,
    only: [work_item_mark: 1, stage_name: 1, owner_phrase: 1]

  alias ApiaryWeb.BacklogComponents

  @stages [:explore, :confirm, :shape]

  ## The head

  @doc """
  The list's header: Work items, the page's `<h1>`; the line of what it lists, the tickets
  the workspace took in from the Backlog; and Take in from the Backlog, a link to it.
  """
  attr :workspace, :string, required: true, doc: "the workspace's name"
  attr :backlog_path, :string, required: true, doc: "the Backlog"

  def work_items_head(assigns) do
    ~H"""
    <.page_header title={gettext("Work items")}>
      <:description>
        {gettext("Tickets %{workspace} took in from the Backlog, by stage.", workspace: @workspace)}
      </:description>
      <:actions>
        <.button id="work-items-take-in" navigate={@backlog_path}>
          <.icon name="hero-inbox-stack" class="size-4" />{gettext("Take in from the Backlog")}
        </.button>
      </:actions>
    </.page_header>
    """
  end

  ## The stages strip

  @doc """
  Where the work is: the three stages side by side, each a link to the list of that stage
  alone (`paths`, by stage), with its count, what it is, and what in it needs a look: how
  many Qory is exploring, how many wait for answers and how many Explore left without a
  result, how many wait at Confirm and for whom (`waiting`), and how many are ready for
  Shape.
  """
  attr :id, :string, default: "work-items-stages"

  attr :counts, :map,
    required: true,
    doc: "the work items in each stage: `%{explore:, confirm:, shape:}`"

  attr :exploring, :integer, default: 0, doc: "how many Qory is exploring"
  attr :answers, :integer, default: 0, doc: "how many wait for answers to Qory's questions"
  attr :no_result, :integer, default: 0, doc: "how many Explore left without a result"
  attr :waiting, :map, default: nil, doc: "what waits at Confirm, `%{count:, for:}`"
  attr :ready, :integer, default: 0, doc: "how many are ready for Shape"
  attr :paths, :map, default: %{}, doc: "each stage's list, by stage"

  def stages_strip(assigns) do
    assigns = assign(assigns, :stages, @stages)

    ~H"""
    <nav id={@id} class="q-wl-flow" aria-label={gettext("Stages")}>
      <.link :for={stage <- @stages} id={"#{@id}-#{stage}"} patch={@paths[stage]} class="q-wl-st">
        <span class="q-wl-st-name">{stage_name(stage)}</span>
        <span class="q-wl-st-n">{Format.number(@counts[stage] || 0)}</span>
        <span class="q-wl-st-what">{stage_line(stage)}</span>
        <span class="q-wl-st-attn">
          <.attention
            stage={stage}
            exploring={@exploring}
            answers={@answers}
            no_result={@no_result}
            waiting={@waiting}
            ready={@ready}
            none
          />
        </span>
      </.link>
    </nav>
    """
  end

  @doc false
  def stage_line(:explore), do: gettext("Qory reads the ticket and the code")
  def stage_line(:confirm), do: gettext("A member confirms what Qory proposes")
  def stage_line(:shape), do: gettext("The plan and its acceptance criteria")

  @doc """
  What in a stage needs a look, with its mark: how many Qory is exploring, how many wait
  for answers and how many are without a result (Explore), how many wait and for whom
  (Confirm), how many are ready (Shape). With `none`, the words for none of them;
  without, nothing.
  """
  attr :stage, :atom, required: true, values: @stages
  attr :exploring, :integer, default: 0
  attr :answers, :integer, default: 0
  attr :no_result, :integer, default: 0
  attr :waiting, :map, default: nil
  attr :ready, :integer, default: 0
  attr :none, :boolean, default: false, doc: "whether to say so when there is none"

  def attention(%{stage: :explore, exploring: e, answers: a, no_result: r} = assigns)
      when e > 0 or a > 0 or r > 0 do
    ~H"""
    <span :if={@exploring > 0} class="q-wl-attn">
      <.work_item_mark kind={:run} />{gettext("%{count} exploring", count: Format.number(@exploring))}
    </span>
    <span :if={@answers > 0} class="q-wl-attn">
      <.work_item_mark kind={:wait} />{ngettext(
        "%{number} waits for answers",
        "%{number} wait for answers",
        @answers,
        number: Format.number(@answers)
      )}
    </span>
    <span :if={@no_result > 0} class="q-wl-attn">
      <.work_item_mark kind={:err} />{ngettext(
        "%{number} without a result",
        "%{number} without a result",
        @no_result,
        number: Format.number(@no_result)
      )}
    </span>
    """
  end

  def attention(%{stage: :confirm, waiting: %{count: n}} = assigns) when n > 0 do
    waiting = assigns.waiting

    assigns =
      assign(assigns,
        mark: if(waiting.for == :you, do: :wait, else: :wait_other),
        words: waiting_words(waiting)
      )

    ~H"""
    <span class="q-wl-attn"><.work_item_mark kind={@mark} />{@words}</span>
    """
  end

  def attention(%{stage: :shape, ready: n} = assigns) when n > 0 do
    ~H"""
    <span class="q-wl-attn">
      <.work_item_mark kind={:ready} />{gettext("%{count} ready", count: Format.number(@ready))}
    </span>
    """
  end

  def attention(%{none: true} = assigns) do
    ~H"""
    <span class="q-wl-none">{none_words(@stage)}</span>
    """
  end

  def attention(assigns), do: ~H""

  defp waiting_words(%{count: n, for: :you}),
    do: ngettext("%{count} waits for you", "%{count} wait for you", n)

  defp waiting_words(%{count: n, for: :member}),
    do: ngettext("%{count} waits for a member", "%{count} wait for a member", n)

  defp waiting_words(%{count: n, for: name}) when is_binary(name),
    do: ngettext("%{count} waits for %{name}", "%{count} wait for %{name}", n, name: name)

  defp none_words(:explore), do: gettext("Nothing is exploring")
  defp none_words(:confirm), do: gettext("Nothing waits")
  defp none_words(:shape), do: gettext("Nothing yet")

  ## The bar

  @doc """
  The list's views: Open, Waiting on you, Declined and Closed, each with its count
  (`counts`, by view) and its path (`paths`), the current one marked.
  """
  attr :id, :string, default: "work-items-views"
  attr :current, :atom, required: true, values: [:open, :you, :declined, :closed]
  attr :counts, :map, default: %{}, doc: "each view's count, by view"
  attr :paths, :map, required: true, doc: "each view's path, by view"

  def work_item_views(assigns) do
    ~H"""
    <.views id={@id} label={gettext("Views")}>
      <:view
        id={"#{@id}-open"}
        patch={@paths[:open]}
        count={view_count(@counts[:open])}
        current={@current == :open}
      >
        {pgettext("work item view", "Open")}
      </:view>
      <:view
        id={"#{@id}-you"}
        patch={@paths[:you]}
        count={view_count(@counts[:you])}
        current={@current == :you}
      >
        {gettext("Waiting on you")}
      </:view>
      <:view
        id={"#{@id}-declined"}
        patch={@paths[:declined]}
        count={view_count(@counts[:declined])}
        current={@current == :declined}
      >
        {gettext("Declined")}
      </:view>
      <:view
        id={"#{@id}-closed"}
        patch={@paths[:closed]}
        count={view_count(@counts[:closed])}
        current={@current == :closed}
      >
        {gettext("Closed")}
      </:view>
    </.views>
    """
  end

  defp view_count(nil), do: nil
  defp view_count(n), do: Format.number(n)

  @doc """
  The list's search, by a work item's title, its number or its ticket's ref: sent as the
  reader types (`"search"`, its words as `q`).
  """
  attr :id, :string, default: "work-items-search"
  attr :value, :string, default: nil, doc: "the words searched for"

  def work_item_search(assigns) do
    ~H"""
    <.list_search
      id={@id}
      value={@value}
      label={gettext("Search work items")}
      placeholder={gettext("Search by title, number or ticket")}
    />
    """
  end

  @doc """
  The list's Filter: by Owner, Repository and Updated, each a section the page fills (the
  `owner`, `repository` and `updated` slots: a form that sets the filter); what each is
  set to, where it is (`values`, by section), beside its name. `count` is how many are on.
  """
  attr :id, :string, default: "work-items-filter"
  attr :count, :integer, default: 0, doc: "how many filters are on"
  attr :values, :map, default: %{}, doc: "what each filter is set to, by section"
  slot :owner, required: true
  slot :repository, required: true
  slot :updated, required: true

  def work_item_filter(assigns) do
    ~H"""
    <.filter_menu id={@id} count={@count}>
      <:section
        key="owner"
        label={pgettext("work item", "Owner")}
        icon="hero-user-circle"
        value={@values[:owner]}
      >
        {render_slot(@owner)}
      </:section>
      <:section
        key="repository"
        label={pgettext("work item", "Repository")}
        icon="hero-folder"
        value={@values[:repository]}
      >
        {render_slot(@repository)}
      </:section>
      <:section
        key="updated"
        label={gettext("Updated")}
        icon="hero-calendar"
        value={@values[:updated]}
      >
        {render_slot(@updated)}
      </:section>
    </.filter_menu>
    """
  end

  @doc """
  The filters in force, under the bar: a token for each ("Owner **Priya**") with the link
  that takes it away, Clear (`clear`), and how many work items they keep (`match`).

  `filters` is a list of `%{key: :owner | :repository | :updated, value: words, patch:
  path}`, the path the list without that filter.
  """
  attr :id, :string, default: "work-items-tokens"
  attr :filters, :list, required: true, doc: "the filters in force, as above"
  attr :clear, :string, default: nil, doc: "the list with no filter on"
  attr :match, :integer, default: nil, doc: "how many work items the filters keep"

  def work_item_tokens(assigns) do
    ~H"""
    <.filter_tokens id={@id} clear={@clear}>
      <:token
        :for={filter <- @filters}
        id={"#{@id}-#{filter.key}"}
        patch={filter.patch}
        label={
          gettext("Remove %{filter}: %{value}", filter: filter_name(filter.key), value: filter.value)
        }
      >
        <span class="q-tok-k">{filter_name(filter.key)}</span>
        <b class="q-tok-v" title={filter.value}>{filter.value}</b>
      </:token>
      <span :if={@match} id={"#{@id}-match"} class="q-wl-match" role="status">
        {ngettext("%{count} work item matches", "%{count} work items match", @match,
          count: Format.number(@match)
        )}
      </span>
    </.filter_tokens>
    """
  end

  defp filter_name(:owner), do: pgettext("work item", "Owner")
  defp filter_name(:repository), do: pgettext("work item", "Repository")
  defp filter_name(:updated), do: gettext("Updated")

  @doc """
  The line under the bar of a view whose list is not plain: Waiting on you, and Declined.
  Nothing for the other views.
  """
  attr :view, :atom, required: true, values: [:open, :you, :declined, :closed]

  def view_note(%{view: :you} = assigns) do
    ~H"""
    <p id="work-items-note" class="q-views-note q-wl-note">
      {gettext("Work items that wait for you to confirm what Qory proposes. Oldest first.")}
    </p>
    """
  end

  def view_note(%{view: :declined} = assigns) do
    ~H"""
    <p id="work-items-note" class="q-views-note q-wl-note">
      {gettext(
        "Work items a member declined. Their tickets stay in the Backlog, where Take in again brings one back."
      )}
    </p>
    """
  end

  def view_note(assigns), do: ~H""

  ## The list

  @doc """
  A stage's band and its rows (`inner_block`, `work_item_row/1`s): Fold, which folds the
  rows in the browser; the stage's name, its count, what it is, and what in it needs a
  look (`exploring`, `answers`, `no_result`, `waiting`, as on the strip); and, where the
  stage holds more than
  the rows shown, Show all, a link to the stage's list (`all_path`).
  """
  attr :id, :string, required: true, doc: "the band's DOM id"
  attr :stage, :atom, required: true, values: @stages
  attr :count, :integer, required: true, doc: "the work items in the stage"
  attr :shown, :integer, required: true, doc: "how many rows the band shows"
  attr :exploring, :integer, default: 0
  attr :answers, :integer, default: 0
  attr :no_result, :integer, default: 0
  attr :waiting, :map, default: nil
  attr :all_path, :string, default: nil, doc: "the stage's list"
  slot :inner_block, required: true

  def stage_band(assigns) do
    assigns = assign(assigns, :name, stage_name(assigns.stage))

    ~H"""
    <section id={@id} class="q-wl-grp" aria-labelledby={"#{@id}-h"}>
      <div class="q-band q-wl-band">
        <button
          id={"#{@id}-fold"}
          type="button"
          class="q-wl-fold"
          aria-expanded="true"
          aria-controls={"#{@id}-rows"}
          aria-label={gettext("Fold %{stage}", stage: @name)}
          phx-click={
            JS.toggle_attribute({"aria-expanded", "true", "false"})
            |> JS.toggle_class("hidden", to: "##{@id}-rows")
            |> JS.toggle_class("hidden", to: "##{@id}-all")
          }
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        >
          <.icon name="hero-chevron-down-micro" class="q-wl-fold-i size-4" />
        </button>
        <h2 id={"#{@id}-h"}>{@name}</h2>
        <span class="q-band-n">{Format.number(@count)}</span>
        <span class="q-band-hint q-wl-what">{stage_line(@stage)}</span>
        <span class="q-grow"></span>
        <span class="q-wl-band-attn">
          <.attention
            stage={@stage}
            exploring={@exploring}
            answers={@answers}
            no_result={@no_result}
            waiting={@waiting}
          />
        </span>
      </div>
      <ul id={"#{@id}-rows"} class="q-rows">{render_slot(@inner_block)}</ul>
      <.link
        :if={@count > @shown && @all_path}
        id={"#{@id}-all"}
        patch={@all_path}
        class="q-more q-wl-more"
      >
        {gettext("Show all %{count} in %{stage}", count: Format.number(@count), stage: @name)}
        <.icon name="hero-arrow-right-micro" class="size-3.5" />
      </.link>
    </section>
    """
  end

  @doc """
  A work item's row: its mark, its number, its title (the only strong text), its ticket's
  ref with the integration's mark, its status in words (Waits for you to confirm the one
  strong status), its owner's mark, and when it last changed. The whole row is a link to
  the work item (`navigate`). In a narrow list the number and the status go under the
  title. Questions, and a take in that used its runs, wait for the reader with `can_act`.
  """
  attr :id, :string, required: true, doc: "the row's DOM id, with the work item's number"
  attr :work_item, :map, required: true, doc: "the work item"
  attr :integration, :string, required: true, doc: "the integration's name"
  attr :navigate, :string, required: true, doc: "the work item's page"

  attr :can_act, :boolean,
    default: false,
    doc: "whether the reader may answer, confirm or decline"

  attr :now, :any, default: nil, doc: "the time it is drawn at; now by default"

  def work_item_row(assigns) do
    work_item = assigns.work_item
    owner = work_item.owner

    assigns =
      assign(assigns,
        now: assigns.now || DateTime.utc_now(),
        owner: owner,
        hot: ApiaryWeb.WorkItemComponents.hot?(work_item),
        words: ApiaryWeb.WorkItemComponents.status_words(work_item)
      )

    ~H"""
    <li id={@id}>
      <.link navigate={@navigate} class={["q-wl-row", @hot && "q-wl-row-hot"]}>
        <.work_item_mark kind={ApiaryWeb.WorkItemComponents.mark(@work_item, @can_act)} />
        <span class="q-wl-no">#{@work_item.number}</span>
        <span class="q-wl-ttl">
          <b>{@work_item.title}</b>
          <span class="q-wl-sub">#{@work_item.number} · {@words}</span>
        </span>
        <span class="q-wl-tk">
          <BacklogComponents.integration_tile name={@integration} />
          <span title={@work_item.external_ref}>{@work_item.external_ref}</span>
        </span>
        <span class="q-wl-nx">{@words}</span>
        <span
          class="q-wl-own"
          role="img"
          title={owner_phrase(@owner)}
          aria-label={gettext("Owner: %{name}", name: @owner.name)}
        >
          <.avatar name={@owner.name} size="xs" />
        </span>
        <span class="q-wl-upd">
          <BacklogComponents.compact_time at={@work_item.updated_at} now={@now} />
        </span>
      </.link>
    </li>
    """
  end

  @doc """
  The foot of Closed, a paged list: where the page is ("1–50 of 262"), and Previous and
  Next (`previous`, `next`: the pages' paths, nil at an end).
  """
  attr :id, :string, default: "work-items-pager"
  attr :first, :integer, required: true
  attr :last, :integer, required: true
  attr :total, :integer, required: true
  attr :previous, :any, default: nil, doc: "the page before; nil at the first"
  attr :next, :any, default: nil, doc: "the page after; nil at the last"

  def work_items_pager(assigns) do
    ~H"""
    <.pager
      id={@id}
      prefix={@id}
      first={@first}
      last={@last}
      total={@total}
      previous={@previous}
      next={@next}
      previous_label={gettext("Previous")}
      next_label={gettext("Next")}
    />
    """
  end

  @doc """
  The list with no work item: why, how a work item starts, and Open the Backlog.
  """
  attr :backlog_path, :string, required: true, doc: "the Backlog"

  def work_items_empty(assigns) do
    ~H"""
    <.empty_state
      icon="hero-rectangle-stack"
      tone="neutral"
      title={gettext("No work items yet")}
      class="q-wl-empty"
    >
      {gettext(
        "A work item starts when someone takes in a ticket from the Backlog. Qory then explores it and proposes how to build it."
      )}
      <:actions>
        <.button id="work-items-open-backlog" variant="primary" navigate={@backlog_path}>
          <.icon name="hero-inbox-stack" class="size-4" />{gettext("Open the Backlog")}
        </.button>
      </:actions>
    </.empty_state>
    """
  end
end
