defmodule ApiaryWeb.PageComponents do
  @moduledoc """
  The patterns every page of the console is built from, inside the frame
  (`ApiaryWeb.Layouts.app/1`). They are structure, not new looks: each draws with the
  tokens and classes the console already has.

  - `page_header/1`: a page's title, its one-line description and its actions.
  - `page_tabs/1`: a thing's tabs (a target, a node, a run): links, Overview first and
    Settings last, set apart at the bar's right end.
  - `settings_page/1`: a page of a level's settings, its section the `<h1>`; the frame names
    the level and lists its sections as the second column (`ApiaryWeb.Layouts.app/1`'s
    `sections` and `section`).
  - `page_form/1` and `page_form_foot/1`: a create or edit form as a page of its own, never
    a dialog, with Cancel back to where it was opened from.
  - `not_on_runs/1`: the one plain line a page over data no run receives yet says.

  Two more patterns are `ApiaryWeb.CoreComponents`': the confirmation in place, never a
  dialog (`inline_confirm/1`, and a deletion's, `ApiaryWeb.SettingsComponents.deletion_confirm/1`),
  and the empty state (`empty_state/1`).
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1]

  alias ApiaryWeb.Format
  alias ApiaryWeb.SettingsComponents

  @doc """
  page_header/1 is a page's header: its title, the page's one `<h1>`; one line under it of
  what the page is for (`description`); and at the right at most one primary and one
  default action (`actions`), under the title on a phone. Beside the title, a state or a
  tag (`badge`); under the description, what the page says of itself before its content,
  such as the line of a narrowed list (`inner_block`).

      <.page_header title={gettext("Nodes")}>
        <:description>{gettext("The machines and pools your runs run on.")}</:description>
        <:actions><.button variant="primary" navigate={new_path}>{gettext("New node")}</.button></:actions>
      </.page_header>
  """
  attr :id, :string, default: "page-header"
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :badge, doc: "beside the title: a state or a tag"
  slot :description, doc: "one line: what the page is for"
  slot :actions, doc: "at most one primary and one default action"
  slot :inner_block, doc: "under the description, before the page's content"

  def page_header(assigns) do
    ~H"""
    <header id={@id} class={["q-page-head", @class]}>
      <div class="q-page-head-main">
        <div class="q-page-head-title">
          <h1 id={"#{@id}-title"} class="q-page-h1 outline-none" tabindex="-1">{@title}</h1>
          {render_slot(@badge)}
        </div>
        <p :if={@description != []} id={"#{@id}-description"} class="q-page-desc">
          {render_slot(@description)}
        </p>
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} id={"#{@id}-actions"} class="q-page-actions">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  page_tabs/1 is a thing's tabs, under its header: a target's, a node's or a run's. Links,
  not an ARIA tablist: each tab is an address, a `patch` within the page's LiveView or a
  `navigate` to another's. The tab whose `key` is `current` is the page's. Settings, where
  the thing has settings, is the last tab (`settings`), set apart at the bar's right end;
  its few sections are listed in the page, never as a second column. Each tab's id is the
  bar's, then its key: `target-tabs-policy`.

      <.page_tabs id="node-tabs" label={gettext("Node")} current={:overview}>
        <:tab key={:overview} patch={overview}>{gettext("Overview")}</:tab>
        <:tab key={:settings} patch={settings} settings>{gettext("Settings")}</:tab>
      </.page_tabs>

  A thing's bar sticks under the top bar and scrolls sideways. The tabs of a settings
  section (`place="section"`, Secrets | Variables, named by the section's title) stay in
  the page's flow under its `<h1>`, and wrap instead of scrolling.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the bar's name: the kind of thing, as Target"
  attr :current, :atom, required: true, doc: "the key of the page's tab"

  attr :place, :string,
    default: "thing",
    values: ~w(thing section),
    doc:
      "a thing's tabs (sticky, scrolling sideways), or a settings section's (in the flow, wrapping)"

  slot :tab, required: true do
    attr :key, :atom, required: true
    attr :patch, :string
    attr :navigate, :string
    attr :icon, :string
    attr :count, :any, doc: "a number beside the words, or its words (\"3 denied\")"
    attr :tone, :string, doc: "error: the number in red, as denials are"
    attr :settings, :boolean, doc: "the thing's Settings, the last tab"
  end

  def page_tabs(assigns) do
    ~H"""
    <nav id={@id} class={["q-tabs", @place == "section" && "q-tabs-section"]} aria-label={@label}>
      <.link
        :for={tab <- @tab}
        id={"#{@id}-#{tab.key}"}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        aria-current={tab.key == @current && "page"}
        class={tab[:settings] && "q-tabs-end"}
      >
        <.icon :if={tab[:icon]} name={tab[:icon]} class="size-4" />
        {render_slot(tab)}
        <span :if={tab[:count]} class={["q-tabs-n", tab[:tone] == "error" && "q-tabs-bad"]}>
          {if is_integer(tab[:count]), do: Format.number(tab[:count]), else: tab[:count]}
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  settings_page/1 is a page of a level's settings. The frame names the level (the second
  column's heading, the breadcrumb's level segment and the browser title) and lists its
  sections as the second column: the page passes them to `ApiaryWeb.Layouts.app/1` as
  `sections` (`ApiaryWeb.SettingsComponents.sections/2`, read when it mounts) and its own
  key as `section`; a person's own pages and the Instance's pass none, the frame has theirs.

  The page: the section's title, the page's one `<h1>` (`#settings-section-title`), one
  sentence of what it is for and its actions, above its content; its parts are `<h2>`s
  (`ApiaryWeb.SettingsComponents.part/1`). A section of forms keeps a 720 px column
  (`measure="read"`); a list, a 960 px one (`measure="list"`).

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:settings}
        sections={@sections} section={:runs} counts={@nav_counts}>
        <.settings_page section={:runs} title={gettext("Runs")}>
          <:subtitle>{gettext("How long this workspace keeps its runs.")}</:subtitle>
          ...
        </.settings_page>
      </Layouts.app>
  """
  attr :heading, :string,
    default: nil,
    doc:
      "ignored: the frame names the level, and the section's title is the h1. Kept so a caller that passes it still compiles"

  attr :section, :atom, required: true, doc: "the section's key, as the second column has it"
  attr :title, :string, required: true, doc: "the section's title, the page's h1"
  attr :measure, :string, default: "read", values: ~w(read list)
  slot :subtitle, doc: "one sentence: what the section is for"
  slot :actions, doc: "at most one primary and one default action"
  slot :inner_block, required: true

  def settings_page(assigns) do
    ~H"""
    <div class="q-settings q-settings-solo">
      <section
        id={"settings-section-#{@section}"}
        class={["q-settings-main", "q-settings-main-#{@measure}"]}
      >
        <header class="q-settings-head">
          <div class="min-w-0">
            <h1 id="settings-section-title" class="q-settings-title outline-none" tabindex="-1">
              {@title}
            </h1>
            <p :if={@subtitle != []} class="q-settings-head-sub">{render_slot(@subtitle)}</p>
          </div>
          <div :if={@actions != []} class="q-settings-actions">{render_slot(@actions)}</div>
        </header>
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  @doc """
  page_form/1 is a form that creates or changes one thing, as a page of its own: never a
  dialog over a list. Its title, one line of what it does, then the form in a 720 px
  column. The page's form holds its fields and ends with `page_form_foot/1`, its button
  and Cancel, which leads back to where the form was opened from: the list, or the
  thing's page. The breadcrumb adds the form's name as the page's last segment
  (`ApiaryWeb.Layouts.app/1`'s `crumb`), after the segments that lead back. There is no
  other way back in the header: a link the page adds names where it goes ("Back to the
  variables"), never a bare Back.

      <.page_form id="new-node" title={gettext("New node")} cancel={nodes}>
        <:description>{gettext("A machine that runs runs.")}</:description>
        <.form for={@form} id="new-node-form" phx-submit="create" novalidate>
          <.input field={@form[:name]} label={gettext("Name")} />
          <.page_form_foot id="new-node-save" cancel={nodes}>
            <.button variant="primary" type="submit">{gettext("Create node")}</.button>
          </.page_form_foot>
        </.form>
      </.page_form>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true

  attr :cancel, :string,
    default: nil,
    doc:
      "where the form was opened from; the header no longer leads there (the foot's Cancel, `page_form_foot/1`, and the breadcrumb do), kept so a caller that passes it still compiles"

  attr :cancel_by, :string,
    default: "navigate",
    values: ~w(navigate patch),
    doc: "kept with `cancel`"

  slot :description, doc: "one line: what the form does"
  slot :inner_block, required: true, doc: "the form"

  def page_form(assigns) do
    ~H"""
    <section id={@id} class="q-form-page" aria-labelledby={"#{@id}-title"}>
      <header class="q-page-head">
        <div class="q-page-head-main">
          <h1 id={"#{@id}-title"} class="q-page-h1 outline-none" tabindex="-1">{@title}</h1>
          <p :if={@description != []} class="q-page-desc">{render_slot(@description)}</p>
        </div>
      </header>
      <div class="q-form-page-body">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  page_form_foot/1 is the foot of a form page's form: its button, then Cancel back to
  where the form was opened from (`cancel`), and one muted line beside them where the form
  needs one (`note`): who may change it, or what happens once it is saved. It is
  `ApiaryWeb.SettingsComponents.save/1`, the settings' foot.
  """
  attr :id, :string, default: nil
  attr :cancel, :string, required: true
  attr :cancel_by, :string, default: "navigate", values: ~w(navigate patch href)
  slot :inner_block, required: true, doc: "the button"
  slot :note, doc: "the muted line"

  def page_form_foot(assigns) do
    ~H"""
    <SettingsComponents.save id={@id} cancel={@cancel} cancel_by={@cancel_by}>
      {render_slot(@inner_block)}
      <:note :if={@note != []}>{render_slot(@note)}</:note>
    </SettingsComponents.save>
    """
  end

  @doc """
  not_on_runs/1 is the one plain line a page over data no run receives yet says, once, near
  its top: a workspace's integrations, a target's own integrations and variables, a
  secret's links. Its words are the page's own (`inner_block`), naming what runs don't
  receive ("Runs don't receive secrets yet."), never a vague "these": such a page never
  says that runs receive what it holds.
  """
  attr :id, :string, default: "not-on-runs"
  attr :class, :any, default: nil

  slot :inner_block,
    required: true,
    doc: "the page's sentence, naming what runs don't receive yet"

  def not_on_runs(assigns) do
    ~H"""
    <p id={@id} class={["q-not-yet", @class]}>
      <.icon name="hero-information-circle-micro" class="q-not-yet-i size-4" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end
end
