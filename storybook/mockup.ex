defmodule ApiaryWeb.Storybook.Mockup do
  @moduledoc """
  What the screen mock-ups of the storybook share (`storybook/screens/`, docs/ui.md,
  Storybook): the paths between them, the application shell they are drawn in, the
  workspace settings' sections, the integrations' role chips, and the nodes' list and
  the words of their states.

  The mock-ups are a proposal to click through, not pages: no route, context or
  migration stands behind them, and they draw `ApiaryWeb.Storybook.Sample`. A story gets
  none of `app.js`, so everything that moves is a plain link between stories, a story's
  tab (`?tab=`) carrying the theme (`?theme=`) along.

  The shell is `ApiaryWeb.Layouts.app/1` drawn from its own classes (`q-topbar`,
  `q-sidebar`, `q-nav-item`…), since the real one cannot draw here: its entries are the
  app's (`ApiaryWeb.Layouts.nav_entries/1`), with no Nodes yet, its links lead to the
  app's routes and not to the stories, and it asks `Apiary.Access` of a signed-in scope.
  Its drawer opens below 768 px on the checkbox alone, as daisyUI's does without the
  `NavDrawer` hook.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Format
  alias ApiaryWeb.Nav.Entry
  alias ApiaryWeb.Storybook.Sample

  @root "/dev/storybook/screens"

  # The sidebar of the workspace: one list without headings, then the targets pinned. An
  # entry's story is the mock-up it leads to, `nil` where the mock-ups have none.
  @entries [
    {:overview, "Overview", "hero-squares-2x2", {"shell", :overview}},
    {:runs, "Runs", "hero-play-circle", nil},
    {:targets, "Targets", "hero-folder", {"run_setup", nil}},
    {:nodes, "Nodes", "hero-server-stack", {"nodes", :all}},
    {:network, "Network access", "hero-globe-alt", nil},
    {:policy, "Policy", "hero-shield-check", nil}
  ]

  # What a member reads where an owner or an admin has the actions of nodes and keys.
  @members_note "Only owners and admins manage nodes and their keys."

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
  `crumb`s), Search or jump to, New and the menu of `account`; the workspace's sidebar,
  one list without the headings of today's groups, `nav` its current entry, Settings at
  its foot; and the page's column at `width`. `folded`
  draws the sidebar folded to icons, as its fold leaves it, and `fold` is where the fold
  leads.
  """
  attr :theme, :any, required: true, doc: "the story's theme, carried by every link"
  attr :nav, :atom, required: true, doc: "the current entry: an entry's key, or :settings"
  attr :width, :string, default: "list", values: ~w(list work read)
  attr :account, :string, default: "dana@example.com", doc: "who reads the page"
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
        entries: entries(assigns.theme),
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
            aria-label={"Account menu, #{@account}"}
          >
            <.avatar name={@account} kind="self" size="md" />
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
              <nav class="q-nav-group" aria-label="Main" id="mock-nav-group-main">
                <.nav_item :for={item <- @entries} item={item} current={@nav == item.key} />
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
      <span :if={@item.key == :nodes} class="q-nav-count" title={"#{running()} running"}>
        {running()}
      </span>
      <span :if={@item.key == :policy} class="q-nav-count">enforce</span>
    </a>
    """
  end

  defp entries(theme) do
    for {key, label, icon, to} <- @entries do
      href =
        case to do
          {story, tab} -> path(story, tab, theme)
          nil -> nil
        end

      %{key: key, label: label, icon: icon, href: href}
    end
  end

  # How many of the nodes run now, as the sidebar counts them.
  defp running, do: Enum.count(Sample.nodes(), &running?/1)

  @doc """
  settings_sections/1 is the sections of the workspace's settings as the mock-ups propose
  them, as `ApiaryWeb.SettingsComponents.layout/1` takes them: General, Integrations,
  Secrets and variables and Members, each leading to its mock-up in `theme`. Access keys
  is not among them: a key belongs to its node (`nodes/1`).
  """
  @spec settings_sections(atom() | String.t() | nil) :: [Entry.t()]
  def settings_sections(theme) do
    for {key, label, story, tab, count} <- [
          {:general, "General", "settings", :general, nil},
          {:integrations, "Integrations", "integrations", :all, :integrations},
          {:secrets, "Secrets and variables", "settings", :secrets, nil},
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
    do: %{integrations: length(Sample.integrations()), members: 3}

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

  @doc "running?/1 is whether a node or a pool has an instance running now."
  @spec running?(map()) :: boolean()
  def running?(node), do: node.instances != []

  @doc "kind_label/1 is the words of a node's kind: Node or Node pool."
  @spec kind_label(:node | :pool) :: String.t()
  def kind_label(:node), do: "Node"
  def kind_label(:pool), do: "Node pool"

  @doc """
  limit_rule/1 is a node's limit as the rule it is, enforced when a run starts: one
  instance at a time for a node, at most its limit for a pool, or none.
  """
  @spec limit_rule(map()) :: String.t()
  def limit_rule(%{kind: :node}), do: "One instance at a time; a second is refused at run start."
  def limit_rule(%{kind: :pool, limit: nil}), do: "No limit: every instance that starts may run."

  def limit_rule(%{kind: :pool, limit: limit}),
    do: "At most #{limit} at once; an #{ordinal(limit + 1)} is refused at run start."

  defp ordinal(n) when rem(n, 100) in 11..13, do: "#{n}th"
  defp ordinal(n) when rem(n, 10) == 1, do: "#{n}st"
  defp ordinal(n) when rem(n, 10) == 2, do: "#{n}nd"
  defp ordinal(n) when rem(n, 10) == 3, do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  @doc """
  node_state/1 is a node's or a pool's state, as a row says it: Running with its dot, a
  pool's count of running instances ("3/10 running", "5 running" without a limit), or
  when it was last seen. There is no Online or Offline.
  """
  attr :node, :map, required: true
  attr :id, :string, default: nil

  def node_state(assigns) do
    ~H"""
    <span :if={running?(@node)} id={@id} class="inline-flex items-center gap-1.5">
      <span class="q-dot text-success" aria-hidden="true"></span>
      <span :if={@node.kind == :node}>Running</span>
      <span :if={@node.kind == :pool && @node.limit} class="tabular-nums">
        {length(@node.instances)}/{@node.limit} running
      </span>
      <span :if={@node.kind == :pool && !@node.limit} class="tabular-nums">
        {length(@node.instances)} running
      </span>
    </span>
    <.seen :if={!running?(@node)} id={@id} at={@node.seen} />
    """
  end

  @doc "seen/1 is \"Last seen\" and when, in muted words, the full time in its title."
  attr :at, :any, required: true
  attr :id, :string, default: nil

  def seen(assigns) do
    assigns = assign(assigns, ago: lower_first(Format.time_ago(assigns.at)))

    ~H"""
    <span id={@id} class="q-stw">
      Last seen
      <time datetime={DateTime.to_iso8601(@at)} title={Format.datetime(@at, zone: true)}>{@ago}</time>
    </span>
    """
  end

  @doc "since/1 is \"Running since\" and the time of day an instance started."
  attr :at, :any, required: true

  def since(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <span class="q-dot text-success" aria-hidden="true"></span>
      <span>
        Running since
        <time datetime={DateTime.to_iso8601(@at)} title={Format.datetime(@at, zone: true)}>
          {Format.time(@at)}
        </time>
      </span>
    </span>
    """
  end

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest

  @doc """
  key_state/1 is an access key's state in words: Approved, muted; Awaiting approval,
  lifted, the state that needs an owner or an admin; or Revoked.
  """
  attr :key, :map, required: true
  attr :id, :string, default: nil

  def key_state(assigns) do
    ~H"""
    <.state_word :if={@key.state == :approved} id={@id}>Approved</.state_word>
    <.state_word :if={@key.state == :pending} id={@id} hot>Awaiting approval</.state_word>
    <.state_word :if={@key.state == :revoked} id={@id} hot tone="error">Revoked</.state_word>
    """
  end

  @doc """
  members_note/1 is the muted line a member reads where an owner or an admin has the
  actions of nodes and their keys, worded as the settings word what only they may do.
  """
  attr :id, :string, default: nil

  def members_note(assigns) do
    assigns = assign(assigns, :note, @members_note)

    ~H"""
    <p id={@id} class="text-[12.5px]/[18px] text-muted">{@note}</p>
    """
  end

  @doc """
  node_path/3 is the path of `node`'s page at `page` (`nil` for its Overview, else a
  suffix such as `"key"`), in `theme`: the mock-up `node` at the tab named for both.
  """
  @spec node_path(map(), String.t() | nil, atom() | String.t() | nil) :: String.t()
  def node_path(node, nil, theme), do: path("node", String.to_atom(node.id), theme)
  def node_path(node, page, theme), do: path("node", String.to_atom("#{node.id}_#{page}"), theme)

  @doc """
  nodes/1 is Nodes as the mock-ups propose it, a page of the sidebar's: every node and
  node pool of the workspace with its kind, its state, its runs of 14 days, its access key
  and its Qory version, Running and Not running as views with their counts (`view`). A
  pool's running instances are rows beneath it, each by its instance id; they appear only
  while they run. `member` draws it as a member reads it: no New, no Approve, and the line
  that says who manages them.
  """
  attr :theme, :any, required: true
  attr :view, :atom, default: :all, values: [:all, :running, :not_running]
  attr :member, :boolean, default: false

  def nodes(assigns) do
    nodes = Sample.nodes()

    shown =
      Enum.filter(nodes, fn node ->
        case assigns.view do
          :all -> true
          :running -> running?(node)
          :not_running -> not running?(node)
        end
      end)

    assigns =
      assign(assigns,
        all: length(nodes),
        running: Enum.count(nodes, &running?/1),
        not_running: Enum.count(nodes, &(not running?(&1))),
        rows:
          Enum.flat_map(shown, fn
            %{kind: :pool} = node ->
              [{:node, node} | for(i <- node.instances, do: {:instance, i})]

            node ->
              [{:node, node}]
          end)
      )

    ~H"""
    <.header>
      Nodes
      <:subtitle>
        Where the runs of this workspace run. A node is permanent and runs one instance at a
        time; a node pool's instances come and go, share its key and run up to its limit.
      </:subtitle>
      <:actions :if={!@member}>
        <.button id="new-node-pool" href={path("nodes", :new_pool, @theme)}>
          <.icon name="hero-plus-micro" class="size-4" />New node pool
        </.button>
        <.button id="new-node" variant="primary" href={path("nodes", :new_node, @theme)}>
          <.icon name="hero-plus-micro" class="size-4" />New node
        </.button>
      </:actions>
    </.header>

    <div class="grid gap-3">
      <.members_note :if={@member} id="nodes-members-note" />

      <.views id="node-views" label="Views">
        <:view
          id="node-view-all"
          navigate={path("nodes", if(@member, do: :member, else: :all), @theme)}
          count={@all}
          current={@view == :all}
        >
          All
        </:view>
        <:view
          id="node-view-running"
          navigate={path("nodes", :running, @theme)}
          count={@running}
          current={@view == :running}
        >
          Running
        </:view>
        <:view
          id="node-view-not-running"
          navigate={path("nodes", :not_running, @theme)}
          count={@not_running}
          current={@view == :not_running}
        >
          Not running
        </:view>
      </.views>

      <div class="q-bar">
        <.list_search
          id="nodes-search"
          label="Find a node"
          placeholder="Find a node or an instance, e.g. build-01 or m_4F7K"
          live={false}
        />
      </div>

      <.table id="nodes" label="Nodes" rows={@rows} row_id={&row_id/1}>
        <:col :let={row} label="Name" kind="title">
          <.node_name row={row} theme={@theme} />
        </:col>
        <:col :let={row} label="Kind" from="sm">
          <span :if={elem(row, 0) == :node}>{kind_label(elem(row, 1).kind)}</span>
          <span :if={elem(row, 0) == :instance} class="q-faint">Instance</span>
        </:col>
        <:col :let={row} label="State">
          <.node_state :if={elem(row, 0) == :node} node={elem(row, 1)} />
          <.since :if={elem(row, 0) == :instance} at={elem(row, 1).since} />
        </:col>
        <:col :let={row} label="Runs, 14 days" kind="num" from="sm">{elem(row, 1).runs}</:col>
        <:col :let={row} label="Access key" from="sm">
          <.key_cell :if={elem(row, 0) == :node} node={elem(row, 1)} theme={@theme} />
        </:col>
        <:col :let={row} label="Qory" kind="faint" from="md">
          <span :if={version(row)} class="q-mono">{version(row)}</span>
        </:col>
        <:action :let={row}>
          <.button
            :if={!@member && pending?(row)}
            variant="link"
            href={node_path(elem(row, 1), "key", @theme)}
            aria-label={"Review the key of #{elem(row, 1).name}"}
          >
            Review key
          </.button>
        </:action>
      </.table>
      <p class="text-[12.5px]/[18px] text-faint">
        A pool's instances are listed beneath it while they run, each by the instance id its
        runner reports; one that stops leaves the list. The limit is checked when a run starts.
      </p>
    </div>
    """
  end

  defp row_id({:node, node}), do: "node-#{node.id}"
  defp row_id({:instance, instance}), do: "instance-#{instance.id}"

  defp version({:instance, instance}), do: instance.version

  defp version({:node, %{kind: :node} = node}),
    do: (List.first(node.instances) || node.last).version

  defp version({:node, _pool}), do: nil

  defp pending?({:node, node}), do: Enum.any?(node.keys, &(&1.state == :pending))
  defp pending?(_row), do: false

  attr :row, :any, required: true
  attr :theme, :any, required: true

  defp node_name(%{row: {:node, node}} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <span class="q-nm">
      <a href={node_path(@node, nil, @theme)} class="q-title hover:underline">{@node.name}</a>
      <span :if={@node.kind == :node} class="q-side q-mono">
        {(List.first(@node.instances) || @node.last).id}
      </span>
    </span>
    """
  end

  defp node_name(%{row: {:instance, instance}} = assigns) do
    assigns = assign(assigns, :instance, instance)

    ~H"""
    <span class="inline-flex items-center gap-1.5 pl-4 font-normal">
      <.icon name="hero-arrow-turn-down-right-micro" class="size-3.5 text-faint" />
      <span class="q-mono text-[12.5px]">{@instance.id}</span>
    </span>
    """
  end

  attr :node, :map, required: true
  attr :theme, :any, required: true

  # The key a node uses now: its id, or the state of one that is not approved.
  defp key_cell(assigns) do
    assigns = assign(assigns, :key, List.last(assigns.node.keys))

    ~H"""
    <a href={node_path(@node, "key", @theme)} class="hover:underline">
      <span :if={@key.state == :approved} class="q-mono">{@key.id}</span>
      <.key_state :if={@key.state != :approved} key={@key} />
    </a>
    """
  end
end
