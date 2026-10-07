defmodule ApiaryWeb.PageComponents do
  @moduledoc """
  The patterns every page of the console is built from, inside the frame
  (`ApiaryWeb.Layouts.app/1`). They are structure, not new looks: each draws with the
  tokens and classes the console already has.

  - `page_header/1`: a page's title, its one-line description and its actions.
  - `page_tabs/1`: a thing's tabs (a target, a node, a run): links, Overview first and
    Settings last, set apart at the bar's right end.
  - `settings_page/1`: a page of a level's settings, whose sections the frame lists as the
    second column (`ApiaryWeb.Layouts.app/1`'s `sections` and `section`).
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
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the bar's name: the kind of thing, as Target"
  attr :current, :atom, required: true, doc: "the key of the page's tab"

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
    <nav id={@id} class="q-tabs" aria-label={@label}>
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
  settings_page/1 is a page of a level's settings. The frame lists the level's sections as
  its second column: the page passes them to `ApiaryWeb.Layouts.app/1` as `sections`
  (`ApiaryWeb.SettingsComponents.sections/2`, read when it mounts) and its own key as
  `section`; a person's own pages and the Instance's pass none, the frame has theirs.

  The page: the level's heading (`heading`, "Workspace settings", the `<h1>`), then the
  section, its title (`#settings-section-title`), one sentence of what it is for and its
  actions, above its content. Without a heading, as a person's page has, the section's
  title is the `<h1>`. A section of forms keeps a 720 px column (`measure="read"`); a list,
  a 960 px one (`measure="list"`).

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:settings}
        sections={@sections} section={:runs} counts={@nav_counts}>
        <.settings_page heading={gettext("Workspace settings")} section={:runs} title={gettext("Runs")}>
          <:subtitle>{gettext("How long this workspace keeps its runs.")}</:subtitle>
          ...
        </.settings_page>
      </Layouts.app>
  """
  attr :heading, :string,
    default: nil,
    doc: "the level's settings, the page's h1; nil where the section's title is the h1"

  attr :section, :atom, required: true, doc: "the section's key, as the second column has it"
  attr :title, :string, required: true, doc: "the section's title"
  attr :measure, :string, default: "read", values: ~w(read list)
  slot :subtitle, doc: "one sentence: what the section is for"
  slot :actions, doc: "at most one primary and one default action"
  slot :inner_block, required: true

  def settings_page(assigns) do
    ~H"""
    <div class="q-settings q-settings-solo">
      <h1 :if={@heading} class="q-settings-title outline-none" tabindex="-1">{@heading}</h1>
      <section
        id={"settings-section-#{@section}"}
        class={["q-settings-main", "q-settings-main-#{@measure}"]}
      >
        <header class="q-settings-head">
          <div class="min-w-0">
            <h2 :if={@heading} id="settings-section-title" class="q-settings-head-title">
              {@title}
            </h2>
            <h1
              :if={!@heading}
              id="settings-section-title"
              class="q-settings-title outline-none"
              tabindex="-1"
            >
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
  and Cancel, which leads back to where the form was opened from (`cancel`): the list, or
  the thing's page. The breadcrumb adds the form's name as the page's last segment
  (`ApiaryWeb.Layouts.app/1`'s `crumb`).

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
    required: true,
    doc: "where the form was opened from, where Cancel and the header's back link lead"

  attr :cancel_by, :string, default: "navigate", values: ~w(navigate patch)
  slot :description, doc: "one line: what the form does"
  slot :inner_block, required: true, doc: "the form"

  def page_form(assigns) do
    ~H"""
    <section id={@id} class="q-form-page" aria-labelledby={"#{@id}-title"}>
      <header class="q-page-head">
        <div class="q-page-head-main">
          <.link
            :if={@cancel_by == "navigate"}
            id={"#{@id}-back"}
            navigate={@cancel}
            class="q-form-back"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />{gettext("Back")}
          </.link>
          <.link :if={@cancel_by == "patch"} id={"#{@id}-back"} patch={@cancel} class="q-form-back">
            <.icon name="hero-arrow-left-micro" class="size-4" />{gettext("Back")}
          </.link>
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
  secret's links. Its words are "Runs don't receive these yet.", or the page's own
  (`inner_block`), as plain: such a page never says that runs receive what it holds.
  """
  attr :id, :string, default: "not-on-runs"
  attr :class, :any, default: nil
  slot :inner_block, doc: "the page's own words, where the default does not fit"

  def not_on_runs(assigns) do
    ~H"""
    <p id={@id} class={["q-not-yet", @class]}>
      <.icon name="hero-information-circle-micro" class="q-not-yet-i size-4" />
      <span :if={@inner_block == []}>{gettext("Runs don't receive these yet.")}</span>
      <span :if={@inner_block != []}>{render_slot(@inner_block)}</span>
    </p>
    """
  end
end
