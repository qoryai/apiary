defmodule ApiaryWeb.Prototype.Shell do
  @moduledoc """
  The prototype's page and shell (`ApiaryWeb.Prototype`): the root layout, with the
  storybook's stylesheet (the app's, with the classes under `storybook/` besides); the top
  bar, breadcrumb, New and the account menu; the sidebar of the organisation, the workspace
  or the person, its Settings at the foot; Settings' section list with its headings; and the
  header and tabs of a repository or a node, ⚙ Settings at the right end. The real shell's
  markup and hooks (`NavDrawer`, `Menu`, `Modal`), with every link a `patch`.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents
  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Prototype.Data
  alias Phoenix.LiveView.JS

  @doc "The prototype's root layout: the app's, drawn with the storybook's stylesheet."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en-GB">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta name="color-scheme" content="light dark" />
        <.live_title default="Navigation prototype" suffix=" · Qory Apiary">
          {assigns[:page_title]}
        </.live_title>
        <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
        <link phx-track-static rel="stylesheet" href="/assets/css/storybook.css" />
        <script defer phx-track-static type="text/javascript" src="/assets/js/app.js">
        </script>
        <script>
          (() => {
            const names = {light: "qory", dark: "qory-dark"};
            const dark = () => matchMedia("(prefers-color-scheme: dark)").matches;
            const set = (theme) => {
              const t = theme === "light" || theme === "dark" ? theme : (dark() ? "dark" : "light");
              document.documentElement.setAttribute("data-theme", names[t]);
            };
            set(localStorage.getItem("phx:theme") || "system");
            window.addEventListener("phx:set-theme", (e) => {
              const theme = e.target.closest("[data-phx-theme]").dataset.phxTheme;
              theme === "system" ? localStorage.removeItem("phx:theme") : localStorage.setItem("phx:theme", theme);
              set(theme);
            });
            try {
              if (localStorage.getItem("qory:sidebar") === "collapsed") {
                document.documentElement.setAttribute("data-sidebar", "collapsed");
              }
            } catch (e) {}
          })();
        </script>
      </head>
      <body
        data-clock-words={Jason.encode!(ApiaryWeb.RunComponents.clock_words())}
        data-locale={ApiaryWeb.Format.locale()}
        data-time-zone={ApiaryWeb.Format.time_zone()}
      >
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc """
  shell/1 is the page's shell: the top bar with the breadcrumb (`crumb`, after `acme /
  shop`, or after `acme` on an organisation's page), the sidebar of `place` with `nav`
  current, and the page's column at `width`.
  """
  attr :place, :atom, required: true, values: [:workspace, :organisation, :person]
  attr :nav, :any, required: true
  attr :role, :atom, required: true
  attr :path, :string, required: true, doc: "the page's path, for the account menu's role"
  attr :width, :string, default: "list"
  attr :flash, :map, default: %{}

  attr :crumbs, :list, default: [], doc: "the breadcrumb after the place: `{label, href}`"

  slot :inner_block, required: true

  def shell(assigns) do
    assigns =
      assign(assigns,
        entries: entries(assigns.place, assigns.role),
        foot: foot(assigns.place),
        pins: if(assigns.place == :workspace, do: Data.pinned(), else: []),
        member: assigns.role == :member
      )

    ~H"""
    <div id="shell" class="min-h-dvh min-w-0 bg-base-100" phx-hook="NavDrawer">
      <header id="top-bar" aria-label="Top bar" class="q-topbar">
        <button
          id="nav-drawer-open"
          type="button"
          data-drawer-open
          class="btn btn-ghost btn-square btn-sm md:hidden"
          aria-label="Open menu"
          aria-controls="sidebar"
          aria-expanded="false"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>

        <nav aria-label="Where you are" class="q-trail-nav">
          <ol class="q-trail">
            <li :if={@place == :person} class="q-trail-item">
              <span class="q-trail-link q-trail-page">Your settings</span>
            </li>
            <li :if={@place != :person} class="q-trail-item q-trail-lead">
              <.link patch={P.org("")} class="q-trail-link" title="acme">
                <.avatar name="acme" kind="organisation" size="xs" />
                <span class="truncate">acme</span>
                <.icon name="hero-chevron-down-micro" class="size-3.5 text-faint" />
              </.link>
            </li>
            <li :if={@place == :workspace} class="q-trail-item q-trail-lead">
              <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
              <.link patch={P.ws("")} class="q-trail-link" title="shop">
                <span class="truncate">shop</span>
                <.icon name="hero-chevron-down-micro" class="size-3.5 text-faint" />
              </.link>
            </li>
            <li
              :for={{{label, href}, i} <- Enum.with_index(@crumbs)}
              class={["q-trail-item", i < length(@crumbs) - 1 && "q-trail-lead"]}
            >
              <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
              <.link :if={href} patch={href} class="q-trail-link">{label}</.link>
              <span
                :if={!href}
                class="q-trail-link q-trail-page"
                aria-current={i == length(@crumbs) - 1 && "page"}
              >
                {label}
              </span>
            </li>
          </ol>
        </nav>

        <div class="flex-1"></div>

        <div class="flex flex-none items-center gap-1.5 md:gap-2">
          <button
            type="button"
            class="q-jump"
            aria-label="Search or jump to"
            title="Search is not in the prototype"
          >
            <.icon name="hero-magnifying-glass" class="size-4 flex-none" />
            <span class="q-jump-text">Search or jump to…</span>
            <kbd class="q-jump-kbd" aria-hidden="true">⌘K</kbd>
          </button>
          <.new_menu :if={!@member} />
          <.account_menu role={@role} path={@path} />
        </div>
      </header>

      <div class="drawer md:drawer-open">
        <input
          id="nav-drawer"
          type="checkbox"
          class="drawer-toggle"
          phx-update="ignore"
          tabindex="-1"
          aria-hidden="true"
        />

        <div class="drawer-side z-50 md:top-12 md:z-20 md:h-[calc(100dvh-3rem)]">
          <label for="nav-drawer" class="drawer-overlay" aria-hidden="true"></label>
          <aside id="sidebar" aria-label={sidebar_label(@place)} class="q-sidebar">
            <div class="q-drawer-head">
              <button
                type="button"
                data-drawer-close
                class="btn btn-ghost btn-square"
                aria-label="Close menu"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>

            <div class="q-sidebar-body">
              <nav class="q-nav-group" aria-label="Main" id="nav-group-main">
                <.nav_item :for={item <- @entries} item={item} current={@nav == item.key} />
              </nav>

              <nav :if={@pins != []} id="nav-group-pinned" class="q-nav-group" aria-label="Pinned">
                <p class="q-nav-heading" aria-hidden="true">Pinned</p>
                <.link
                  :for={pin <- @pins}
                  id={"nav-pin-#{String.replace(pin.path, "/", "-")}"}
                  patch={P.repo(pin.path)}
                  aria-current={@nav == {:pin, pin.path} && "page"}
                  class="q-nav-item"
                  title={"#{pin.system}/#{pin.path}"}
                >
                  <.icon name="hero-folder" class="q-nav-icon size-[18px]" />
                  <span class="q-nav-text q-nav-pin">{pin.path}</span>
                </.link>
              </nav>
            </div>

            <div class="q-sidebar-foot">
              <.nav_item :if={@foot} item={@foot} current={@nav == :settings} />
              <div class="q-brand-row">
                <div class="q-brand">
                  <button type="button" class="q-brand-btn" aria-label="Qory Apiary menu">
                    <.logo_mark class="size-[18px]" />
                    <span class="q-brand-name">Qory Apiary</span>
                    <span class="q-brand-version">0.9.0</span>
                    <.icon name="hero-chevron-up-micro" class="q-brand-chev size-4" />
                  </button>
                </div>
                <button
                  id="sidebar-collapse"
                  type="button"
                  class="q-collapse"
                  data-sidebar-collapse
                  data-label="Collapse sidebar"
                  data-label-folded="Expand sidebar"
                  aria-label="Collapse sidebar"
                >
                  <.icon name="hero-chevron-double-left-micro" class="q-collapse-icon size-4" />
                </button>
              </div>
            </div>
          </aside>
        </div>

        <div id="shell-content" class="drawer-content flex min-h-[calc(100dvh-3rem)] min-w-0 flex-col">
          <main id="main" class="min-w-0 flex-1">
            <div class={["q-page", "q-page-#{@width}"]}>
              <div class="grid grid-cols-[minmax(0,1fr)] gap-6">
                {render_slot(@inner_block)}
              </div>
            </div>
          </main>
        </div>
      </div>
    </div>
    <ApiaryWeb.Layouts.flash_group flash={@flash} />
    """
  end

  defp sidebar_label(:workspace), do: "Workspace"
  defp sidebar_label(:organisation), do: "Organisation"
  defp sidebar_label(:person), do: "Your settings"

  defp entries(:workspace, role) do
    [
      %{key: :overview, label: "Overview", icon: "hero-squares-2x2", href: P.ws("")},
      %{key: :runs, label: "Runs", icon: "hero-play-circle", href: P.ws("/runs"), count: :runs},
      %{key: :network, label: "Network access", icon: "hero-globe-alt", href: P.ws("/network")},
      %{key: :repositories, label: "Repositories", icon: "hero-folder", href: P.ws("/targets")},
      %{
        key: :nodes,
        label: "Nodes",
        icon: "hero-server-stack",
        href: P.ws("/nodes"),
        count: if(role == :member, do: :nodes, else: :nodes_hot)
      }
    ]
  end

  defp entries(:organisation, role) do
    Enum.reject(
      [
        %{key: :overview, label: "Overview", icon: "hero-squares-2x2", href: P.org("")},
        role != :member &&
          %{
            key: :audit_log,
            label: "Audit log",
            icon: "hero-clipboard-document-list",
            href: P.org("/audit-log")
          }
      ],
      &(!&1)
    )
  end

  defp entries(:person, _role) do
    [
      %{key: :profile, label: "Profile", icon: "hero-user-circle", href: P.person("/settings")},
      %{
        key: :preferences,
        label: "Preferences",
        icon: "hero-adjustments-horizontal",
        href: P.person("/settings/preferences")
      },
      %{
        key: :organisations,
        label: "Organisations",
        icon: "hero-building-office-2",
        href: P.person("/organisations")
      }
    ]
  end

  defp foot(:workspace),
    do: %{key: :settings, label: "Settings", icon: "hero-cog-6-tooth", href: P.ws("/settings")}

  defp foot(:organisation),
    do: %{key: :settings, label: "Settings", icon: "hero-cog-6-tooth", href: P.org("/settings")}

  defp foot(:person), do: nil

  attr :item, :map, required: true
  attr :current, :boolean, required: true

  defp nav_item(assigns) do
    assigns = assign(assigns, running: Data.running_instances())

    ~H"""
    <.link
      id={"nav-#{@item.key}"}
      patch={@item.href}
      aria-current={@current && "page"}
      class="q-nav-item"
      title={@item.label}
    >
      <.icon name={@item.icon} class="q-nav-icon size-[18px]" />
      <span class="q-nav-text">{@item.label}</span>
      <span
        :if={@item[:count] == :runs}
        class="q-nav-count text-info-soft-content"
        title="2 runs running now"
      >
        <span class="q-dot q-ripple !size-1.5" aria-hidden="true"></span> 2
      </span>
      <span
        :if={@item[:count] in [:nodes, :nodes_hot]}
        class="q-nav-count inline-flex items-center gap-1"
        title={"#{@running} instances running" <> if(@item[:count] == :nodes_hot, do: "; a key is waiting", else: "")}
      >
        <span
          :if={@item[:count] == :nodes_hot}
          class="q-dot !size-1.5 text-warning"
          aria-hidden="true"
        ></span>
        {@running}
      </span>
    </.link>
    """
  end

  defp new_menu(assigns) do
    assigns =
      assign(assigns, :entries, [
        {"new-node", "New node", "hero-server", P.ws("/nodes/new")},
        {"new-pool", "New node pool", "hero-server-stack", P.ws("/nodes/new-pool")},
        {"add-integration", "Add integration", "hero-puzzle-piece",
         P.ws("/settings/integrations/add")},
        {"new-secret", "New secret", "hero-lock-closed", P.ws("/settings/secrets/new")},
        {"new-variable", "New variable", "hero-variable", P.ws("/settings/variables/new")}
      ])

    ~H"""
    <div id="new-menu" class="dropdown dropdown-end" phx-hook="Menu">
      <button
        id="new-menu-button"
        type="button"
        class="q-newbtn"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label="New"
      >
        <.icon name="hero-plus-micro" class="size-4" />
        <span class="max-md:hidden">New</span>
        <.icon name="hero-chevron-down-micro" class="size-3.5 text-faint max-md:hidden" />
      </button>
      <ul
        class="menu menu-sm dropdown-content right-0 top-full mt-1.5 w-56"
        role="menu"
        aria-label="New"
      >
        <li :for={{id, label, icon, href} <- @entries} role="none">
          <.link id={"new-menu-#{id}"} patch={href} role="menuitem" tabindex="-1">
            <.icon name={icon} class="size-4" /> {label}
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link
            id="new-menu-invite"
            patch={P.org("/settings/people/invite")}
            role="menuitem"
            tabindex="-1"
          >
            <.icon name="hero-user-plus" class="size-4" /> Invite people
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :role, :atom, required: true
  attr :path, :string, required: true

  defp account_menu(assigns) do
    assigns =
      assign(assigns,
        email: email(assigns.role),
        roles: [{:owner, "Owner"}, {:admin, "Admin"}, {:member, "Member"}]
      )

    ~H"""
    <div id="user-menu" class="dropdown dropdown-end" phx-hook="Menu">
      <button
        id="user-menu-button"
        type="button"
        class="btn btn-ghost btn-keep h-9 min-h-0 min-w-9 rounded-full p-0.5 aria-expanded:bg-base-300"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={"Account menu, #{@email}"}
      >
        <.avatar name={@email} kind="self" size="md" />
      </button>
      <ul
        class="menu menu-sm dropdown-content right-0 top-full mt-1.5 w-64"
        role="menu"
        aria-label="Account"
      >
        <li role="presentation">
          <div class="grid cursor-default grid-flow-row gap-0 px-2 pb-2 pt-1.5 hover:bg-transparent">
            <span class="truncate font-medium">{@email}</span>
            <span class="truncate text-xs/4 text-faint">
              {String.capitalize(to_string(@role))} of acme
            </span>
          </div>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link patch={P.person("/settings")} role="menuitem" tabindex="-1" id="user-menu-settings">
            <.icon name="hero-user-circle" class="size-4" /> Your settings
          </.link>
        </li>
        <li role="none">
          <.link
            patch={P.person("/organisations")}
            role="menuitem"
            tabindex="-1"
            id="user-menu-organisations"
          >
            <.icon name="hero-building-office-2" class="size-4" /> Your organisations
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="presentation">
          <span class="cursor-default text-xs/4 text-faint hover:bg-transparent">
            Prototype: read the pages as
          </span>
        </li>
        <li :for={{role, label} <- @roles} role="none">
          <.link
            id={"user-menu-as-#{role}"}
            patch={with_role(@path, role)}
            role="menuitemradio"
            aria-checked={to_string(@role == role)}
            tabindex="-1"
          >
            <.icon
              name={if @role == role, do: "hero-check-micro", else: "hero-minus-micro"}
              class={["size-4", @role != role && "opacity-0"]}
            />
            {label} <span class="text-faint">{email(role)}</span>
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none" class="q-theme-row">
          <div role="group" aria-labelledby="user-menu-theme" class="hover:bg-transparent">
            <span id="user-menu-theme" class="flex items-center gap-2">
              <.icon name="hero-swatch" class="size-4" /> Theme
            </span>
            <span class="q-theme-seg">
              <button
                :for={{theme, label} <- [{"system", "Auto"}, {"light", "Light"}, {"dark", "Dark"}]}
                type="button"
                role="menuitemradio"
                tabindex="-1"
                phx-click={JS.dispatch("phx:set-theme")}
                data-phx-theme={theme}
              >
                {label}
              </button>
            </span>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @doc "Who reads the pages as `role`."
  def email(:owner), do: "dana@example.com"
  def email(:admin), do: "lee@example.com"
  def email(:member), do: "sam@example.com"

  defp with_role(path, role) do
    uri = URI.parse(path)
    query = (uri.query && URI.decode_query(uri.query)) || %{}
    %{uri | query: URI.encode_query(Map.put(query, "as", role))} |> URI.to_string()
  end

  @doc """
  settings/1 is a page of Settings: an optional heading ("Workspace settings"), the section
  list beside the section, in `groups` (`{heading, entries}`, `nil` for none), `current`
  marked; and the section with its title, sentence and actions.
  """
  attr :heading, :string, default: nil
  attr :groups, :list, required: true
  attr :current, :atom, required: true
  attr :title, :string, required: true
  attr :measure, :string, default: "read", values: ~w(read list)
  attr :readonly, :boolean, default: false, doc: "draws the line that says who changes it"
  slot :subtitle
  slot :actions
  slot :back, doc: "a link back above the title, for a sub-page"
  slot :inner_block, required: true

  def settings(assigns) do
    ~H"""
    <div class="q-settings">
      <h1 :if={@heading} class="q-settings-title">{@heading}</h1>

      <nav id="settings-tabs" class="q-settings-nav lg:!gap-0.5" aria-label="Settings">
        <%= for {{heading, entries}, i} <- Enum.with_index(@groups) do %>
          <p
            :if={heading}
            class={[
              "px-2 pb-1 text-[11px]/4 font-semibold uppercase tracking-[0.04em] text-faint max-lg:hidden",
              i > 0 && "pt-4",
              i == 0 && "pt-1"
            ]}
          >
            {heading}
          </p>
          <.link
            :for={entry <- entries}
            id={"settings-tab-#{entry.key}"}
            patch={entry.href}
            aria-current={entry.key == @current && "page"}
            class="q-settings-link"
          >
            <span class="truncate">{entry.label}</span>
            <span :if={entry[:count]} class="q-settings-n">{entry.count}</span>
            <span :if={entry[:hot]} class="q-dot !size-1.5 text-warning" title={entry.hot}></span>
          </.link>
        <% end %>
      </nav>

      <section
        id={"settings-section-#{@current}"}
        class={["q-settings-main", "q-settings-main-#{@measure}"]}
      >
        <div :if={@back != []} class="-mb-2 text-[13px]">{render_slot(@back)}</div>
        <header class="q-settings-head">
          <div class="min-w-0">
            <h2 id="settings-section-title" class="q-settings-head-title">{@title}</h2>
            <p :if={@subtitle != []} class="q-settings-head-sub">{render_slot(@subtitle)}</p>
          </div>
          <div :if={@actions != []} class="q-settings-actions">{render_slot(@actions)}</div>
        </header>
        <p
          :if={@readonly}
          class="inline-flex items-center gap-1.5 text-[12.5px]/[18px] text-muted"
        >
          <.icon name="hero-eye-micro" class="size-4" /> Only owners and admins change this.
        </p>
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  @doc "The workspace Settings' sections, in two headed groups."
  def workspace_sections do
    integrations = Data.integrations()

    [
      {"Workspace",
       [
         %{key: :general, label: "General", href: P.ws("/settings")},
         %{
           key: :people,
           label: "People",
           href: P.ws("/settings/people"),
           count: length(Data.people())
         },
         %{key: :retention, label: "Retention", href: P.ws("/settings/retention")}
       ]},
      {"What runs are given",
       [
         %{key: :policy, label: "Policy", href: P.ws("/settings/policy")},
         %{
           key: :integrations,
           label: "Integrations",
           href: P.ws("/settings/integrations"),
           count: length(integrations),
           hot: Enum.any?(integrations, & &1.needs_secret) && "An integration needs a secret"
         },
         %{key: :secrets, label: "Secrets and variables", href: P.ws("/settings/secrets")}
       ]}
    ]
  end

  @doc """
  level_header/1 is the head of a repository's or a node's page: its icon and name, its
  line of facts, its actions; then its tabs, the operational ones first and ⚙ Settings at
  the right end.
  """
  attr :icon, :string, required: true
  attr :id, :string, default: nil, doc: "an id beside the name, in mono"
  attr :tabs_label, :string, required: true
  attr :settings_href, :string, required: true
  attr :settings_current, :boolean, required: true
  slot :name, required: true
  slot :meta
  slot :actions

  slot :tab do
    attr :href, :string, required: true
    attr :current, :boolean
    attr :count, :any
    attr :icon, :string
  end

  def level_header(assigns) do
    ~H"""
    <header class="q-tgt-head">
      <div class="min-w-0 flex-1">
        <h1 class="q-tgt-h1">
          <.icon name={@icon} class="size-5 flex-none text-muted" />
          <span class="min-w-0 truncate">{render_slot(@name)}</span>
          <span :if={@id} class="q-mono text-[13px] font-normal text-faint">{@id}</span>
        </h1>
        <p :if={@meta != []} class="q-tgt-meta">{render_slot(@meta)}</p>
      </div>
      <div :if={@actions != []} class="q-tgt-actions">{render_slot(@actions)}</div>
    </header>

    <nav class="q-tabs" aria-label={@tabs_label}>
      <.link
        :for={tab <- @tab}
        patch={tab.href}
        aria-current={tab[:current] == true && "page"}
      >
        <.icon :if={tab[:icon]} name={tab.icon} class="size-4" />
        {render_slot(tab)}
        <span :if={tab[:count]} class="q-tabs-n">{tab.count}</span>
      </.link>
      <.link
        patch={@settings_href}
        aria-current={@settings_current && "page"}
        class="ml-auto"
      >
        <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
      </.link>
    </nav>
    """
  end

  @doc """
  dialog/1 is a dialog at a path of its own, over its page: closing it, by its X, Escape,
  the backdrop or Cancel, patches back to `back`.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :back, :string, required: true
  attr :size, :string, default: "md"
  slot :inner_block, required: true
  slot :footer

  def dialog(assigns) do
    ~H"""
    <.modal id={@id} title={@title} size={@size} on_cancel={JS.patch(@back)}>
      {render_slot(@inner_block)}
      <:footer :if={@footer != []}>{render_slot(@footer)}</:footer>
    </.modal>
    """
  end

  @doc "A line that something needs someone, with its link: the operational page's way into Settings."
  attr :id, :string, default: nil
  attr :href, :string, default: nil
  attr :link, :string, default: nil
  slot :inner_block, required: true

  def needs(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-box border border-warning/40 bg-warning/10 px-4 py-2.5 text-[13.5px]/5"
    >
      <.icon name="hero-exclamation-triangle-micro" class="size-4 text-warning" />
      <span class="min-w-0 flex-1">{render_slot(@inner_block)}</span>
      <.link :if={@href} patch={@href} class="font-medium text-accent hover:underline">
        {@link} →
      </.link>
    </div>
    """
  end

  @doc "A link into Settings or a list, in the accent colour, with its arrow."
  attr :href, :string, required: true
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def go(assigns) do
    ~H"""
    <.link id={@id} patch={@href} class={["whitespace-nowrap text-accent hover:underline", @class]}>
      {render_slot(@inner_block)} →
    </.link>
    """
  end

  @doc "A run's state as a dot and its word."
  attr :state, :atom, required: true

  def run_state(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 whitespace-nowrap">
      <span class={["q-dot", dot(@state), @state == :running && "q-ripple"]} aria-hidden="true"></span>
      {Data.state_label(@state)}
    </span>
    """
  end

  defp dot(:running), do: "text-info"
  defp dot(:succeeded), do: "text-success"
  defp dot(:failed), do: "text-error"
  defp dot(_), do: "text-faint"
end
