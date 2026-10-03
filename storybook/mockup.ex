defmodule ApiaryWeb.Storybook.Mockup do
  @moduledoc """
  What the screen mock-ups of the storybook share (`storybook/screens/`, docs/ui.md,
  Storybook): the paths between them, the application shell they are drawn in, the
  workspace settings' sections, and the integrations' role chips.

  The mock-ups are a proposal to click through, not pages: no route, context or
  migration stands behind them, and they draw `ApiaryWeb.Storybook.Sample`. A story gets
  none of `app.js`, so everything that moves is a plain link between stories, a story's
  tab (`?tab=`) carrying the theme (`?theme=`) along.

  The shell is `ApiaryWeb.Layouts.app/1` drawn from its own classes (`q-topbar`,
  `q-sidebar`, `q-nav-item`…), since the real one cannot draw here: its entries are the
  app's (`ApiaryWeb.Layouts.nav_entries/1`), with no Machines yet, its links lead to the
  app's routes and not to the stories, and it asks `Apiary.Access` of a signed-in scope.
  Its drawer opens below 768 px on the checkbox alone, as daisyUI's does without the
  `NavDrawer` hook.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Nav.Entry

  @root "/dev/storybook/screens"

  # The sidebar of the workspace: its groups, then the targets pinned. An entry's story is
  # the mock-up it leads to, `nil` where the mock-ups have none.
  @groups [
    {:home, nil, [{:overview, "Overview", "hero-squares-2x2", {"shell", :overview}}]},
    {:record, "Record",
     [
       {:runs, "Runs", "hero-play-circle", nil},
       {:targets, "Targets", "hero-folder", {"run_setup", nil}},
       {:machines, "Machines", "hero-server-stack", {"machines", :all}}
     ]},
    {:guard, "Guard",
     [
       {:network, "Network access", "hero-globe-alt", nil},
       {:policy, "Policy", "hero-shield-check", nil}
     ]}
  ]

  @doc """
  path/3 is the path of the mock-up `story` (its file's name under `storybook/screens/`)
  at its `tab`, `nil` for its first, in `theme`, `nil` for the storybook's default.
  """
  @spec path(String.t(), atom() | nil, atom() | String.t() | nil) :: String.t()
  def path(story, tab, theme) do
    case [tab: tab, theme: theme] |> Enum.reject(&is_nil(elem(&1, 1))) |> URI.encode_query() do
      "" -> "#{@root}/#{story}"
      query -> "#{@root}/#{story}?#{query}"
    end
  end

  @doc """
  shell/1 is the application shell a mock-up is drawn in, as `ApiaryWeb.Layouts.app/1`
  draws a workspace's page: the top bar with the breadcrumb (`acme / shop` and the page's
  `crumb`s), Search or jump to, New and the account menu; the workspace's sidebar, `nav`
  its current entry, Settings at its foot; and the page's column at `width`. `folded`
  draws the sidebar folded to icons, as its fold leaves it, and `fold` is where the fold
  leads.
  """
  attr :theme, :any, required: true, doc: "the story's theme, carried by every link"
  attr :nav, :atom, required: true, doc: "the current entry: an entry's key, or :settings"
  attr :width, :string, default: "list", values: ~w(list work read)
  attr :folded, :boolean, default: false

  attr :fold, :string,
    default: nil,
    doc: "where the fold leads; none for a fold that does nothing"

  slot :crumb, doc: "the breadcrumb's segments after the workspace; the last is the page" do
    attr :href, :string, doc: "where the segment leads; none for the page itself"
  end

  slot :inner_block, required: true

  def shell(assigns) do
    assigns =
      assign(assigns,
        groups: groups(assigns.theme),
        settings_path: path("settings", :general, assigns.theme),
        home_path: path("shell", :overview, assigns.theme),
        pins: [
          %{id: "pin-shop", path: "acme/shop", href: path("run_setup", nil, assigns.theme)},
          %{id: "pin-shared-ui", path: "acme/shared-ui", href: nil}
        ]
      )

    ~H"""
    <div
      id="shell"
      class="min-w-0 overflow-hidden rounded-box border border-line bg-base-100"
      data-sidebar={@folded && "collapsed"}
    >
      <header aria-label="Top bar" class="q-topbar">
        <label
          for="mock-nav-drawer"
          class="btn btn-ghost btn-square btn-sm md:hidden"
          aria-label="Open menu"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </label>

        <nav aria-label="Where you are" class="q-trail-nav">
          <ol class="q-trail">
            <li class="q-trail-item q-trail-lead">
              <a href={@home_path} class="q-trail-link" title="Acme">
                <.avatar name="Acme" kind="organisation" size="xs" />
                <span class="truncate">Acme</span>
              </a>
            </li>
            <li class={["q-trail-item", (@crumb != [] || @nav == :settings) && "q-trail-lead"]}>
              <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
              <a href={@home_path} class="q-trail-link" title="shop">
                <span class="truncate">shop</span>
              </a>
            </li>
            <li :if={@nav == :settings} class={["q-trail-item", @crumb != [] && "q-trail-lead"]}>
              <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
              <a :if={@crumb != []} href={@settings_path} class="q-trail-link">Settings</a>
              <span :if={@crumb == []} class="q-trail-link q-trail-page" aria-current="page">
                Settings
              </span>
            </li>
            <li
              :for={{crumb, i} <- Enum.with_index(@crumb)}
              class={["q-trail-item", i < length(@crumb) - 1 && "q-trail-lead"]}
            >
              <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
              <a :if={crumb[:href]} href={crumb.href} class="q-trail-link">{render_slot(crumb)}</a>
              <span
                :if={!crumb[:href]}
                class="q-trail-link q-trail-page"
                aria-current={i == length(@crumb) - 1 && "page"}
              >
                {render_slot(crumb)}
              </span>
            </li>
          </ol>
        </nav>

        <div class="flex-1"></div>

        <div class="flex flex-none items-center gap-1.5 md:gap-2">
          <button type="button" class="q-jump" aria-label="Search or jump to">
            <.icon name="hero-magnifying-glass" class="size-4 flex-none" />
            <span class="q-jump-text">Search or jump to…</span>
            <kbd class="q-jump-kbd" aria-hidden="true">⌘K</kbd>
          </button>
          <button type="button" class="q-newbtn" aria-label="New">
            <.icon name="hero-plus-micro" class="size-4" />
            <span class="max-md:hidden">New</span>
            <.icon name="hero-chevron-down-micro" class="size-3.5 text-faint max-md:hidden" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-keep h-9 min-h-0 min-w-9 rounded-full p-0.5"
            aria-label="Account menu, dana@example.com"
          >
            <.avatar name="dana@example.com" kind="self" size="md" />
          </button>
        </div>
      </header>

      <div class="drawer md:drawer-open">
        <input
          id="mock-nav-drawer"
          type="checkbox"
          class="drawer-toggle"
          tabindex="-1"
          aria-hidden="true"
        />

        <div class="drawer-side z-50 md:z-20 md:h-auto">
          <label for="mock-nav-drawer" class="drawer-overlay" aria-hidden="true"></label>
          <aside aria-label="Workspace" class="q-sidebar">
            <div class="q-drawer-head">
              <label for="mock-nav-drawer" class="btn btn-ghost btn-square" aria-label="Close menu">
                <.icon name="hero-x-mark" class="size-5" />
              </label>
            </div>

            <div class="q-sidebar-body">
              <nav
                :for={{section, heading, items} <- @groups}
                class="q-nav-group"
                aria-label={heading || "Main"}
                id={"mock-nav-group-#{section}"}
              >
                <p :if={heading} class="q-nav-heading" aria-hidden="true">{heading}</p>
                <.nav_item :for={item <- items} item={item} current={@nav == item.key} />
              </nav>

              <nav id="mock-nav-group-pinned" class="q-nav-group" aria-label="Pinned">
                <p class="q-nav-heading" aria-hidden="true">Pinned</p>
                <a
                  :for={pin <- @pins}
                  id={"mock-nav-#{pin.id}"}
                  href={pin.href || "#"}
                  aria-current={@nav == :pin_shop && pin.id == "pin-shop" && "page"}
                  class="q-nav-item"
                  title={"git.example.com/#{pin.path}"}
                >
                  <.icon name="hero-folder" class="q-nav-icon size-[18px]" />
                  <span class="q-nav-text q-nav-pin">{pin.path}</span>
                </a>
              </nav>
            </div>

            <div class="q-sidebar-foot">
              <.nav_item
                item={
                  %{key: :settings, label: "Settings", icon: "hero-cog-6-tooth", href: @settings_path}
                }
                current={@nav == :settings}
              />
              <div class="q-brand-row">
                <div class="q-brand">
                  <button type="button" class="q-brand-btn" aria-label="Qory Apiary menu">
                    <.logo_mark class="size-[18px]" />
                    <span class="q-brand-name">Qory Apiary</span>
                    <span class="q-brand-version">0.9.0</span>
                    <.icon name="hero-chevron-up-micro" class="q-brand-chev size-4" />
                  </button>
                </div>
                <a
                  href={@fold || "#"}
                  class="q-collapse"
                  aria-label={if @folded, do: "Expand sidebar", else: "Collapse sidebar"}
                  title={if @folded, do: "Expand sidebar", else: "Collapse sidebar"}
                >
                  <.icon name="hero-chevron-double-left-micro" class="q-collapse-icon size-4" />
                </a>
              </div>
            </div>
          </aside>
        </div>

        <div class="drawer-content flex min-w-0 flex-col">
          <main class="min-w-0 flex-1">
            <div class={["q-page", "q-page-#{@width}"]}>
              <div class="grid grid-cols-[minmax(0,1fr)] gap-6">
                {render_slot(@inner_block)}
              </div>
            </div>
          </main>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :current, :boolean, required: true

  defp nav_item(assigns) do
    ~H"""
    <a
      id={"mock-nav-#{@item.key}"}
      href={@item.href || "#"}
      aria-current={@current && "page"}
      class="q-nav-item"
      title={!@item.href && "Not in these mock-ups"}
    >
      <.icon name={@item.icon} class="q-nav-icon size-[18px]" />
      <span class="q-nav-text">{@item.label}</span>
      <span
        :if={@item.key == :runs}
        class="q-nav-count text-info-soft-content"
        title="2 runs alive now"
      >
        <span class="q-dot q-ripple !size-1.5" aria-hidden="true"></span> 2
      </span>
      <span :if={@item.key == :machines} class="q-nav-count" title="8 machines online">8</span>
      <span :if={@item.key == :policy} class="q-nav-count">enforce</span>
    </a>
    """
  end

  defp groups(theme) do
    for {section, heading, items} <- @groups do
      {section, heading,
       for {key, label, icon, to} <- items do
         href =
           case to do
             {story, tab} -> path(story, tab, theme)
             nil -> nil
           end

         %{key: key, label: label, icon: icon, href: href}
       end}
    end
  end

  @doc """
  settings_sections/1 is the sections of the workspace's settings as the mock-ups propose
  them, as `ApiaryWeb.SettingsComponents.layout/1` takes them: General, Integrations,
  Secrets and variables, Access keys and Members, each leading to its mock-up in `theme`.
  """
  @spec settings_sections(atom() | String.t() | nil) :: [Entry.t()]
  def settings_sections(theme) do
    for {key, label, story, tab, count} <- [
          {:general, "General", "settings", :general, nil},
          {:integrations, "Integrations", "integrations", :all, :integrations},
          {:secrets, "Secrets and variables", "settings", :secrets, nil},
          {:keys, "Access keys", "access_keys", :all, :keys},
          {:members, "Members", "settings", :members, :members}
        ],
        do: %Entry{
          section: :main,
          key: key,
          label: label,
          path: path(story, tab, theme),
          count: count
        }
  end

  @doc "settings_counts/0 is the counts the settings' list shows beside its sections."
  @spec settings_counts() :: map()
  def settings_counts,
    do: %{integrations: length(ApiaryWeb.Storybook.Sample.integrations()), keys: 4, members: 3}

  @doc "role_label/1 is the words of an integration's role, as a chip says it."
  @spec role_label(atom()) :: String.t()
  def role_label(:task_source), do: "Task source"
  def role_label(:llm_provider), do: "LLM provider"
  def role_label(:output), do: "Output"
  def role_label(:service), do: "Service"

  @doc "roles/1 is an integration's roles as label chips (`<.badge>`), in its order."
  attr :roles, :list, required: true
  attr :class, :any, default: nil

  def roles(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1 whitespace-nowrap", @class]}>
      <.badge :for={role <- @roles}>{role_label(role)}</.badge>
    </span>
    """
  end

  @doc """
  source/1 is where an integration comes from: "Built in", or its GitHub repository in mono
  with the version it was added at, faint.
  """
  attr :source, :any, required: true
  attr :class, :any, default: nil

  def source(assigns) do
    ~H"""
    <span :if={is_nil(@source)} class={@class}>Built in</span>
    <span :if={@source} class={["inline-flex items-baseline gap-1.5", @class]}>
      <.icon name="hero-code-bracket-micro" class="size-3.5 self-center text-faint" />
      <span class="q-mono">{@source.repo}</span>
      <span class="q-mono q-faint">{@source.version}</span>
    </span>
    """
  end

  @doc "needs_secret?/1 is whether one of an integration's secrets is linked to none."
  @spec needs_secret?(map()) :: boolean()
  def needs_secret?(integration), do: Enum.any?(integration.secrets, &is_nil(&1.secret))

  @doc """
  status/1 is an integration's state, as a row says it: "Ready" in muted words, or "Needs
  a secret" lifted with its dot (`<.state_word hot>`), the state that needs someone.
  """
  attr :integration, :map, required: true
  attr :id, :string, default: nil

  def status(assigns) do
    ~H"""
    <.state_word :if={needs_secret?(@integration)} id={@id} hot>Needs a secret</.state_word>
    <.state_word :if={!needs_secret?(@integration)} id={@id}>Ready</.state_word>
    """
  end

  @doc """
  machines/1 is Record › Machines as the mock-ups propose it: the machines that post to
  the workspace, by the instance id the runner reports, with Online and Offline as views
  with their counts (`view`), and per machine its state, its runs of 14 days, the access
  key it uses (a link to Settings › Access keys), its Qory version and when it was last
  seen.
  """
  attr :theme, :any, required: true
  attr :view, :atom, default: :all, values: [:all, :online, :offline]

  def machines(assigns) do
    machines = ApiaryWeb.Storybook.Sample.machines()
    keys = Map.new(ApiaryWeb.Storybook.Sample.access_keys(), &{&1.id, &1})

    assigns =
      assign(assigns,
        keys: keys,
        all: length(machines),
        online: Enum.count(machines, &(&1.status == :online)),
        offline: Enum.count(machines, &(&1.status == :offline)),
        rows: Enum.filter(machines, &(assigns.view == :all or &1.status == assigns.view))
      )

    ~H"""
    <.header>
      Machines
      <:subtitle>
        The machines that post runs to this workspace, each by the instance id its runner
        reports and the access key it uses. A machine is online while its heartbeat comes in.
      </:subtitle>
    </.header>

    <div class="grid gap-3">
      <.views id="machine-views" label="Views">
        <:view navigate={path("machines", :all, @theme)} count={@all} current={@view == :all}>
          All
        </:view>
        <:view
          navigate={path("machines", :online, @theme)}
          count={@online}
          current={@view == :online}
        >
          Online
        </:view>
        <:view
          navigate={path("machines", :offline, @theme)}
          count={@offline}
          current={@view == :offline}
        >
          Offline
        </:view>
      </.views>

      <div class="q-bar">
        <.list_search
          id="machines-search"
          label="Find a machine"
          placeholder="Find a machine, e.g. build-03 key:build-fleet"
          live={false}
        />
      </div>

      <.table id="machines" label="Machines" rows={@rows} row_id={&"machine-#{&1.id}"}>
        <:col :let={machine} label="Instance" kind="title">
          <span class="q-nm">
            <span class="q-title-mono">{machine.id}</span>
            <span class="q-side">{machine.host}</span>
          </span>
        </:col>
        <:col :let={machine} label="State">
          <span :if={machine.status == :online} class="inline-flex items-center gap-1.5">
            <span class="q-dot text-success" aria-hidden="true"></span>Online
          </span>
          <.state_word :if={machine.status == :offline}>Offline</.state_word>
        </:col>
        <:col :let={machine} label="Runs, 14 days" kind="num" from="sm">{machine.runs}</:col>
        <:col :let={machine} label="Access key" from="sm">
          <a href={path("access_keys", :all, @theme)} class="hover:underline">
            {@keys[machine.key].label}
          </a>
        </:col>
        <:col :let={machine} label="Qory" kind="faint" from="md">
          <span class="q-mono">{machine.version}</span>
        </:col>
        <:col :let={machine} label="Last seen" from="md">
          <.time_ago at={machine.last_seen} class="tabular-nums" />
        </:col>
      </.table>
      <p class="text-[12.5px]/[18px] text-faint">
        Ten machines share build-fleet: a key serves as many machines as use it, and each
        is told apart by its instance id.
      </p>
    </div>
    """
  end
end
