defmodule ApiaryWeb.Storybook.Foundations.Icons do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents, only: [icon: 1, logo_mark: 1]

  alias ApiaryWeb.{Layouts, PolicyComponents, RunComponents}
  alias ApiaryWeb.PolicyLive.{Common, RuleList}
  alias ApiaryWeb.Storybook.Sample

  # The v2 split (knowledge-vault product/design/apiary/v2, kit.js and icons.js): every
  # icon the app draws solid micro that v2 draws in outline, the nav's and the objects'.
  # The glyphs stay micro: check, x-mark, chevrons, arrows, no-symbol, lock, warning,
  # ellipsis, plus. Written out whole, so Tailwind generates each outline class from here.
  @outline %{
    "hero-adjustments-horizontal-micro" => "hero-adjustments-horizontal",
    "hero-archive-box-micro" => "hero-archive-box",
    "hero-bell-micro" => "hero-bell",
    "hero-book-open-micro" => "hero-book-open",
    "hero-building-office-2-micro" => "hero-building-office-2",
    "hero-calendar-micro" => "hero-calendar",
    "hero-clipboard-document-list-micro" => "hero-clipboard-document-list",
    "hero-clock-micro" => "hero-clock",
    "hero-cog-6-tooth-micro" => "hero-cog-6-tooth",
    "hero-command-line-micro" => "hero-command-line",
    "hero-cpu-chip-micro" => "hero-cpu-chip",
    "hero-document-text-micro" => "hero-document-text",
    "hero-envelope-micro" => "hero-envelope",
    "hero-eye-micro" => "hero-eye",
    "hero-flag-micro" => "hero-flag",
    "hero-folder-micro" => "hero-folder",
    "hero-funnel-micro" => "hero-funnel",
    "hero-globe-alt-micro" => "hero-globe-alt",
    "hero-key-micro" => "hero-key",
    "hero-link-micro" => "hero-link",
    "hero-list-bullet-micro" => "hero-list-bullet",
    "hero-magnifying-glass-micro" => "hero-magnifying-glass",
    "hero-play-circle-micro" => "hero-play-circle",
    "hero-queue-list-micro" => "hero-queue-list",
    "hero-server-stack-micro" => "hero-server-stack",
    "hero-shield-check-micro" => "hero-shield-check",
    "hero-shield-exclamation-micro" => "hero-shield-exclamation",
    "hero-squares-2x2-micro" => "hero-squares-2x2",
    "hero-trash-micro" => "hero-trash",
    "hero-user-circle-micro" => "hero-user-circle",
    "hero-user-plus-micro" => "hero-user-plus",
    "hero-users-micro" => "hero-users",
    "hero-wrench-screwdriver-micro" => "hero-wrench-screwdriver"
  }

  @styles [
    solid: {"Solid", "As ux draws them now: every nav and object icon hero-*-micro, 16 px."},
    outline:
      {"Outline",
       "The v2 mocks' split: nav and object icons 24 px outline, drawn at 18 px in the nav " <>
         "(kit.css:168) and 16 px elsewhere; the small glyphs (check, x, chevrons, arrows, " <>
         "the deny mark, lock, warning) stay solid micro. The current item keeps the app's " <>
         "own marks, its background, weight, ring and accent, and its icon stays outline."}
  ]

  def doc,
    do:
      "Solid micro icons, as the app draws them now, beside the v2 mocks' outline split, on " <>
        "the real sidebar and on rows of the rule list and the runs list. The header's theme " <>
        "menu switches qory and qory-dark."

  def render(assigns) do
    scope = Sample.scope()
    rows = Sample.rules() |> Enum.take(4)
    activity = Sample.activity()
    query = %RuleList{}

    assigns =
      assign(assigns,
        styles: @styles,
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
              name={icon_name(@style, "hero-folder-micro")}
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

  defp icon_name(:solid, name), do: name
  defp icon_name(:outline, name), do: Map.get(@outline, name, name)

  defp nav_size(:solid), do: "size-4"
  defp nav_size(:outline), do: "size-[18px]"

  # A real component, drawn as it is, or with the v2 split's names in place of its micro
  # icons: its markup is otherwise the component's own.
  defp drawn(:solid, component, assigns), do: component.(assigns)

  defp drawn(:outline, component, assigns) do
    html = assigns |> component.() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    Phoenix.HTML.raw(Regex.replace(~r/\bhero-[a-z0-9-]+-micro\b/, html, &icon_name(:outline, &1)))
  end
end
