defmodule ApiaryWeb.WorkItemComponents do
  # The components of a work item's pages: the stage track, the line where Explore's gate
  # will be, the details rail, and the Thread's lines, its events and its comments. Kept
  # out of the generated documentation, which every instance serves.
  #
  # They take plain data through their attributes and call no context: the page reads the
  # work item and passes what to show. A component does not ask `Apiary.Features`; the
  # page asks and passes the answer (docs/ui.md, Components).
  #
  # What a person or an integration wrote (a name, a ticket's reference, a comment) is
  # interpolated, so HEEx escapes it, and never passed to `raw/1`.
  @moduledoc false
  use ApiaryWeb, :html

  @stages [:explore, :shape, :build, :verify, :release]

  # The five stages in order, each numbered, the active one marked as the current step
  # (`aria-current="step"`) and every other one muted. No gate is drawn between them.
  @doc false
  attr :id, :string, default: "work-item-stages"
  attr :active, :atom, default: :explore, values: @stages, doc: "the active stage"
  attr :class, :any, default: nil

  def stage_track(assigns) do
    assigns = assign(assigns, :stages, Enum.with_index(@stages, 1))

    ~H"""
    <ol id={@id} class={["q-stages", @class]} aria-label={gettext("Stages")}>
      <li
        :for={{stage, n} <- @stages}
        id={"#{@id}-#{stage}"}
        class={["q-stage", stage == @active && "q-stage-on"]}
        aria-current={stage == @active && "step"}
      >
        <span class="q-stage-n">{Format.number(n)}</span> {stage_name(stage)}
      </li>
    </ol>
    """
  end

  defp stage_name(:explore), do: gettext("Explore")
  defp stage_name(:shape), do: gettext("Shape")
  defp stage_name(:build), do: gettext("Build")
  defp stage_name(:verify), do: gettext("Verify")
  defp stage_name(:release), do: gettext("Release")

  # One muted line where Explore's gate card will be: beside the page from 1280 px, a bar
  # above it below. `class` places it in the page.
  @doc false
  attr :id, :string, default: "work-item-gate-note"
  attr :class, :any, default: nil

  def gate_note(assigns) do
    ~H"""
    <p id={@id} class={["q-gate-note", @class]}>
      {gettext("Explore's gate comes with the phase 2 pages.")}
    </p>
    """
  end

  # The details rail beside the page, on the run page's pattern (run_live/show.ex): from
  # 1280 px the right column of a `q-run` grid, and below it a disclosure, the Details
  # button, that opens it in place; Escape closes it and keeps the focus on the button.
  # It renders both, the button first, as the rail's look needs them side by side.
  @doc false
  attr :id, :string, default: "work-item-details"
  attr :open, :boolean, default: false, doc: "whether the rail is open below 1280 px"
  attr :owner, :string, default: nil, doc: "the owner's name; nil when there is none"
  attr :runs, :integer, required: true, doc: "how many runs the work item has"
  attr :alive, :integer, required: true, doc: "how many of them are alive"

  attr :ticket, :map,
    default: nil,
    doc: "the ticket: `ref`, `integration`, `url` (nil for none) and `updated_at`"

  def details(assigns) do
    ~H"""
    <button
      id={"#{@id}-toggle"}
      type="button"
      class="q-run-dtoggle"
      aria-expanded={to_string(@open)}
      aria-controls={@id}
      phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
      phx-keydown={
        JS.set_attribute({"aria-expanded", "false"}, to: "##{@id}-toggle")
        |> JS.focus(to: "##{@id}-toggle")
      }
      phx-key="Escape"
    >
      <span class="q-run-dtoggle-text">{gettext("Details")}</span>
      <.icon name="hero-chevron-down-micro" class="q-run-dtoggle-i size-4" />
    </button>
    <aside id={@id} class="q-run-rail" aria-label={gettext("Details")}>
      <h2 class="q-rail-title">{gettext("Details")}</h2>
      <div class="q-rail-sec">
        <dl id={"#{@id}-facts"} class="q-rail-kv">
          <dt>{gettext("Owner")}</dt>
          <dd id={"#{@id}-owner"}>{@owner || gettext("n/a")}</dd>
          <dt>{gettext("Runs")}</dt>
          <dd id={"#{@id}-runs"}>{runs_text(@runs, @alive)}</dd>
          <dt>{gettext("Ticket")}</dt>
          <dd id={"#{@id}-ticket"}>
            <%= if @ticket do %>
              <.external_link href={@ticket.url}>
                {gettext("%{ref} in %{integration}",
                  ref: @ticket.ref,
                  integration: @ticket.integration
                )}
              </.external_link>
              <span class="q-rail-sub">
                <.rich text={rich_gettext("updated %{ago}", ago: {:part, :ago})}>
                  <:part name={:ago}><.time_ago at={@ticket.updated_at} case={:inline} /></:part>
                </.rich>
              </span>
            <% else %>
              {gettext("n/a")}
            <% end %>
          </dd>
        </dl>
      </div>
    </aside>
    """
  end

  defp runs_text(runs, alive) when alive > 0,
    do:
      gettext("%{runs} · %{alive} alive", runs: Format.number(runs), alive: Format.number(alive))

  defp runs_text(runs, _alive), do: gettext("%{runs} · none alive", runs: Format.number(runs))

  # One event of the Thread, in a muted line, with its time beside it.
  @doc false
  attr :id, :string, default: nil

  attr :kind, :atom,
    required: true,
    values: [:taken_in, :closed, :undone, :ticket_closed]

  attr :who, :string, default: nil, doc: "the name of the person who acted"
  attr :integration, :string, default: nil, doc: "the ticket's integration"
  attr :ref, :string, default: nil, doc: "the ticket's reference"
  attr :at, DateTime, required: true
  attr :class, :any, default: nil

  def thread_event(assigns) do
    ~H"""
    <p id={@id} class={["q-thread-event", @class]}>
      <span>{event_text(@kind, @who, @integration, @ref)}</span>
      <.time_ago at={@at} class="q-faint" />
    </p>
    """
  end

  defp event_text(:taken_in, who, _integration, ref),
    do: gettext("%{who} took this in from %{ref}", who: who, ref: ref)

  defp event_text(:closed, who, _integration, _ref),
    do: gettext("%{who} closed this", who: who)

  defp event_text(:undone, who, _integration, _ref),
    do: gettext("%{who} undid the take in", who: who)

  defp event_text(:ticket_closed, _who, integration, _ref),
    do: gettext("Its ticket was closed in %{integration}", integration: integration)

  # One person's comment in the Thread: who wrote it and when, then its text as written,
  # interpolated, with its line breaks kept. A deleted comment is one muted line.
  #
  # Delete, where the reader may delete it, sends `delete_event` with the comment's id as
  # `phx-value-id`. The page confirms in place, as node_live/show.ex does: it renders its
  # `inline_confirm/1` in the `confirm` slot, which then takes the place of Delete.
  @doc false
  attr :id, :string, required: true, doc: "the DOM id"
  attr :who, :string, required: true, doc: "the name of the person who wrote it"
  attr :at, DateTime, required: true, doc: "when it was written, or deleted"
  attr :body, :string, default: "", doc: "the text, as written"
  attr :deleted, :boolean, default: false
  attr :can_delete, :boolean, default: false, doc: "whether the reader may delete it"
  attr :delete_event, :string, default: nil, doc: "the event Delete sends"
  attr :comment_id, :any, default: nil, doc: "the comment's id, sent with the event"
  attr :class, :any, default: nil
  slot :confirm, doc: "the page's inline_confirm/1, while it asks"

  def comment(%{deleted: true} = assigns) do
    ~H"""
    <div id={@id} class={["q-comment q-comment-deleted", @class]}>
      <p id={"#{@id}-deleted"}>
        <.rich text={
          rich_gettext("A comment by %{who} was deleted · %{ago}", who: @who, ago: {:part, :ago})
        }>
          <:part name={:ago}><.time_ago at={@at} case={:inline} /></:part>
        </.rich>
      </p>
    </div>
    """
  end

  def comment(assigns) do
    ~H"""
    <div id={@id} class={["q-comment", @class]}>
      <p id={"#{@id}-head"} class="q-comment-head">
        <.rich text={rich_gettext("%{who} commented %{ago}", who: {:b, @who}, ago: {:part, :ago})}>
          <:part name={:ago}><.time_ago at={@at} case={:inline} class="q-faint" /></:part>
        </.rich>
      </p>
      <div id={"#{@id}-body"} class="q-comment-body whitespace-pre-wrap" phx-no-format>{@body}</div>
      <%= if @confirm != [] do %>
        {render_slot(@confirm)}
      <% else %>
        <.button
          :if={@can_delete}
          id={"#{@id}-delete"}
          type="button"
          variant="link"
          class="q-comment-delete"
          phx-click={@delete_event}
          phx-value-id={@comment_id}
          aria-describedby={"#{@id}-head"}
        >
          {gettext("Delete")}
        </.button>
      <% end %>
    </div>
    """
  end
end
