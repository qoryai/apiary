defmodule ApiaryWeb.Storybook.Foundations.Icons do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents, only: [icon: 1, logo_mark: 1]

  alias ApiaryWeb.{Layouts, PolicyComponents, RunComponents}
  alias ApiaryWeb.PolicyLive.{Common, RuleList}
  alias ApiaryWeb.Storybook.Sample

  # The app draws the v2 mocks' split: nav and object icons 24 px outline, the small glyphs
  # solid micro. Before, it drew every one solid micro; this is the outline name of each icon
  # it switched, beside the micro one it drew before. Written out whole, so Tailwind generates
  # each class here.
  @previous %{
    "hero-adjustments-horizontal" => "hero-adjustments-horizontal-micro",
    "hero-archive-box" => "hero-archive-box-micro",
    "hero-arrow-down-tray" => "hero-arrow-down-tray-micro",
    "hero-arrow-right-start-on-rectangle" => "hero-arrow-right-start-on-rectangle-micro",
    "hero-arrow-up-tray" => "hero-arrow-up-tray-micro",
    "hero-arrow-uturn-left" => "hero-arrow-uturn-left-micro",
    "hero-arrows-up-down" => "hero-arrows-up-down-micro",
    "hero-book-open" => "hero-book-open-micro",
    "hero-building-office-2" => "hero-building-office-2-micro",
    "hero-calendar" => "hero-calendar-micro",
    "hero-check-circle" => "hero-check-circle-micro",
    "hero-clipboard-document" => "hero-clipboard-document-micro",
    "hero-clipboard-document-list" => "hero-clipboard-document-list-micro",
    "hero-clock" => "hero-clock-micro",
    "hero-cog-6-tooth" => "hero-cog-6-tooth-micro",
    "hero-command-line" => "hero-command-line-micro",
    "hero-computer-desktop" => "hero-computer-desktop-micro",
    "hero-cpu-chip" => "hero-cpu-chip-micro",
    "hero-document-text" => "hero-document-text-micro",
    "hero-envelope" => "hero-envelope-micro",
    "hero-eye" => "hero-eye-micro",
    "hero-folder" => "hero-folder-micro",
    "hero-funnel" => "hero-funnel-micro",
    "hero-globe-alt" => "hero-globe-alt-micro",
    "hero-key" => "hero-key-micro",
    "hero-link" => "hero-link-micro",
    "hero-list-bullet" => "hero-list-bullet-micro",
    "hero-magnifying-glass" => "hero-magnifying-glass-micro",
    "hero-moon" => "hero-moon-micro",
    "hero-play-circle" => "hero-play-circle-micro",
    "hero-question-mark-circle" => "hero-question-mark-circle-micro",
    "hero-queue-list" => "hero-queue-list-micro",
    "hero-server-stack" => "hero-server-stack-micro",
    "hero-shield-check" => "hero-shield-check-micro",
    "hero-shield-exclamation" => "hero-shield-exclamation-micro",
    "hero-squares-2x2" => "hero-squares-2x2-micro",
    "hero-sun" => "hero-sun-micro",
    "hero-swatch" => "hero-swatch-micro",
    "hero-trash" => "hero-trash-micro",
    "hero-user-circle" => "hero-user-circle-micro",
    "hero-user-plus" => "hero-user-plus-micro",
    "hero-users" => "hero-users-micro",
    "hero-wrench-screwdriver" => "hero-wrench-screwdriver-micro"
  }

  # The split at a glance: nav and object icons in outline, the small glyphs in micro.
  @nouns ~w(hero-squares-2x2 hero-play-circle hero-folder hero-globe-alt hero-shield-check
            hero-key hero-cog-6-tooth hero-users hero-building-office-2 hero-funnel
            hero-magnifying-glass hero-calendar hero-clock hero-trash)
  @glyphs ~w(hero-check-micro hero-x-mark-micro hero-chevron-right-micro hero-chevron-down-micro
             hero-arrow-right-micro hero-no-symbol-micro hero-lock-closed-micro
             hero-exclamation-triangle-micro hero-plus-micro hero-ellipsis-horizontal-micro)

  @styles [
    outline:
      {"Current: outline",
       "As the app draws them: nav and object icons 24 px outline, at 18 px in the nav " <>
         "(kit.css:168) and 16 px elsewhere; the small glyphs (check, x, chevrons, arrows, " <>
         "the deny mark, lock, warning) stay solid micro. The current item changes its " <>
         "background, weight and ring; its icon takes the accent and stays outline."},
    solid:
      {"Previous: solid micro",
       "For reference, as the app drew them before: every icon hero-*-micro, 16 px."}
  ]

  def doc,
    do:
      "The app's icons, outline for nav and objects and solid micro for small glyphs, on the " <>
        "real sidebar and on rows of the rule list and the runs list, beside the solid micro " <>
        "the app drew before. The header's theme menu switches qory and qory-dark."

  def render(assigns) do
    scope = Sample.scope()
    rows = Sample.rules() |> Enum.take(4)
    activity = Sample.activity()
    query = %RuleList{}

    assigns =
      assign(assigns,
        styles: @styles,
        nouns: @nouns,
        glyphs: @glyphs,
        scope: scope,
        nav: nav(scope),
        rows: rows,
        activity: activity,
        query: query,
        listing: RuleList.list(rows, query, activity),
        sections: RuleList.sections(rows, activity),
        runs: Sample.runs()
      )

    ~H"""
    <div class="grid gap-10 p-6">
      <section class="grid gap-4">
        <h2 class="text-base font-semibold">The split</h2>
        <div class="grid gap-6 lg:grid-cols-2">
          <.column
            title="Nav and objects: outline"
            note={
              "hero-<name>, the 24 px outline: 18 px in the nav, 16 px in menus, tabs, " <>
                "buttons and fields, 14 px in a Filter menu's sections."
            }
          >
            <.swatches id="split-nouns" names={@nouns} sizes={~w(size-[18px] size-4 size-3.5)} />
          </.column>
          <.column
            title="Small glyphs: solid micro"
            note={
              "hero-<name>-micro, the 16 px solid, at 12 to 16 px: checks, marks, " <>
                "chevrons, arrows, the deny mark, lock and warning."
            }
          >
            <.swatches id="split-glyphs" names={@glyphs} sizes={~w(size-4 size-3.5 size-3)} />
          </.column>
        </div>
      </section>

      <section class="grid gap-4">
        <h2 class="text-base font-semibold">The sidebar</h2>
        <div class="grid gap-6 lg:grid-cols-2">
          <.column :for={{style, {title, note}} <- @styles} title={title} note={note}>
            <.sidebar style={style} nav={@nav} />
          </.column>
        </div>
      </section>

      <section class="grid gap-4">
        <h2 class="text-base font-semibold">The rule list</h2>
        <div class="grid gap-6 2xl:grid-cols-2">
          <.column :for={{style, {title, _note}} <- @styles} title={title}>
            {drawn(style, &rule_rows/1, Map.put(assigns, :id, "#{style}-rules"))}
          </.column>
        </div>
      </section>

      <section class="grid gap-4">
        <h2 class="text-base font-semibold">The runs list</h2>
        <div class="grid gap-6 2xl:grid-cols-2">
          <.column :for={{style, {title, _note}} <- @styles} title={title}>
            {drawn(style, &run_rows/1, Map.put(assigns, :id, "#{style}-runs"))}
          </.column>
        </div>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :note, :string, default: nil
  slot :inner_block, required: true

  defp column(assigns) do
    ~H"""
    <div class="grid min-w-0 content-start gap-3">
      <div>
        <h3 class="font-medium">{@title}</h3>
        <p :if={@note} class="max-w-xl text-[13px]/[18px] text-muted">{@note}</p>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :names, :list, required: true
  attr :sizes, :list, required: true

  defp swatches(assigns) do
    ~H"""
    <table id={@id} class="w-max text-[13px]/[18px]">
      <tr :for={size <- @sizes}>
        <th class="pr-4 text-left font-normal text-muted">{size}</th>
        <td :for={name <- @names} class="p-1.5 text-base-content" title={name}>
          <.icon name={name} class={size} />
        </td>
      </tr>
    </table>
    """
  end

  # The workspace's sidebar as `ApiaryWeb.Layouts` draws it (its `sidebar` and `nav_item`,
  # private to the shell): the real entries, groups and classes, Policy the current page.
  attr :style, :atom, required: true
  attr :nav, :map, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside
      class="q-sidebar !h-auto !w-60 rounded-box border border-line !shadow-none"
      aria-label="Workspace"
    >
      <div class="q-sidebar-body">
        <nav
          :for={{section, heading, entries} <- @nav.groups}
          class="q-nav-group"
          aria-label={heading || "Main"}
          id={"#{@style}-nav-group-#{section}"}
        >
          <p :if={heading} class="q-nav-heading" aria-hidden="true">{heading}</p>
          <.nav_item
            :for={entry <- entries}
            style={@style}
            entry={entry}
            current={entry.key == :policy}
          />
        </nav>

        <nav class="q-nav-group" aria-label="Pinned">
          <p class="q-nav-heading" aria-hidden="true">Pinned</p>
          <a :for={pin <- ~w(acme/shop acme/shared-ui)} href="#" class="q-nav-item" title={pin}>
            <.icon
              name={icon_name(@style, "hero-folder")}
              class={["q-nav-icon", nav_size(@style)]}
            />
            <span class="q-nav-text q-nav-pin">{pin}</span>
          </a>
        </nav>
      </div>

      <div class="q-sidebar-foot">
        <.nav_item :if={@nav.foot} style={@style} entry={@nav.foot} current={false} />
        <div class="q-brand-row">
          <div class="q-brand">
            <button type="button" class="q-brand-btn" aria-label="Qory Apiary menu">
              <.logo_mark class="size-[18px]" />
              <span class="q-brand-name">Qory Apiary</span>
              <span class="q-brand-version">0.1.0</span>
              <.icon name="hero-chevron-up-micro" class="q-brand-chev size-4" />
            </button>
          </div>
          <button type="button" class="q-collapse" aria-label="Collapse sidebar">
            <.icon name="hero-chevron-double-left-micro" class="q-collapse-icon size-4" />
          </button>
        </div>
      </div>
    </aside>
    """
  end

  attr :style, :atom, required: true
  attr :entry, :any, required: true
  attr :current, :boolean, required: true

  defp nav_item(assigns) do
    ~H"""
    <a href="#" aria-current={@current && "page"} class="q-nav-item">
      <.icon name={icon_name(@style, @entry.icon)} class={["q-nav-icon", nav_size(@style)]} />
      <span class="q-nav-text">{@entry.label}</span>
      <span :if={@entry.key == :runs} class="q-nav-count text-info-soft-content">
        <span class="q-dot q-ripple !size-1.5" aria-hidden="true"></span> 2
      </span>
      <span :if={@entry.key == :policy} class="q-nav-count">enforce</span>
    </a>
    """
  end

  defp rule_rows(assigns) do
    ~H"""
    <div>
      <PolicyComponents.rule_list
        id={@id}
        label="Network access rules of the workspace"
        listing={@listing}
        query={@query}
        path={&Common.list_path("/acme/shop/policy", &1)}
        sections={@sections}
        default_sort="Locked first"
        activity={@activity}
        can_add
        can_lock
      />
    </div>
    """
  end

  defp run_rows(assigns) do
    ~H"""
    <RunComponents.runs_table id={@id} label="Runs" runs={@runs} scope={@scope} />
    """
  end

  # The workspace's entries of the real navigation (`ApiaryWeb.Layouts.nav_entries/1`), by
  # the sidebar's groups, and its foot.
  defp nav(scope) do
    entries = Enum.filter(Layouts.nav_entries(scope), &(&1.place == :workspace))

    groups =
      for {section, heading} <- [home: nil, record: "Record", guard: "Guard"],
          shown = Enum.filter(entries, &(&1.section == section)),
          shown != [],
          do: {section, heading, shown}

    %{groups: groups, foot: Enum.find(entries, &(&1.section == :foot))}
  end

  defp icon_name(:outline, name), do: name
  defp icon_name(:solid, name), do: Map.get(@previous, name, name)

  defp nav_size(:outline), do: "size-[18px]"
  defp nav_size(:solid), do: "size-4"

  # A real component, drawn as it is, or with the micro icons it drew before in place of
  # its outline ones: its markup is otherwise the component's own.
  defp drawn(:outline, component, assigns), do: component.(assigns)

  defp drawn(:solid, component, assigns) do
    html = assigns |> component.() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

    Phoenix.HTML.raw(
      Regex.replace(~r/(?<![\w-])hero-[a-z0-9-]+(?![\w-])/, html, &icon_name(:solid, &1))
    )
  end
end
