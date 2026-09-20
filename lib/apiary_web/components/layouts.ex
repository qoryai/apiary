defmodule ApiaryWeb.Layouts do
  @moduledoc """
  Layouts: the application shell (`app/1`) for signed-in pages and the split
  view (`auth/1`) for log-in, registration, invitation and welcome pages.
  """
  use ApiaryWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # Two sections: the record first, because it is why people open the console.
  @nav [
    {"Hive", "Main",
     [
       {:overview, "Overview", "hero-squares-2x2-micro", "/hive"},
       {:runs, "Runs", "hero-play-circle-micro", "/hive/runs"},
       {:connections, "Connections", "hero-arrows-right-left-micro", "/hive/connections"},
       # After Connections, because the policy is what the connections are judged by.
       {:policy, "Policy", "hero-shield-check-micro", "/hive/policy"}
     ]},
    {"Manage", "Manage",
     [
       {:keys, "Access keys", "hero-key-micro", "/hive/keys"},
       {:members, "Members", "hero-users-micro", "/hive/members"},
       {:settings, "Settings", "hero-cog-6-tooth-micro", "/hive/settings"}
     ]}
  ]

  @doc """
  The application shell: a sidebar with the apiary and its hive, the navigation
  and the user menu, and a main column for the page. Below 768 px the sidebar
  is a drawer behind a top bar.

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:keys}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :memberships, :list, default: [], doc: "the user's memberships, for the switcher"
  attr :nav, :atom, default: nil, doc: "the active navigation item"

  attr :counts, :map,
    default: nil,
    doc:
      "%{keys: active keys, members: members, alive: runs alive now, mode: the policy's default mode, own_modes: the modes repositories set}"

  attr :width, :string,
    default: "wide",
    values: ~w(wide narrow full),
    doc: "960 or 640 px column; full is 1200 px, for the runs, run and connections pages"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:nav_items, @nav)
      |> assign(:organisation, scope_field(assigns.current_scope, :organisation))
      |> assign(:hive, scope_field(assigns.current_scope, :hive))
      |> assign(:membership, scope_field(assigns.current_scope, :membership))
      |> assign(:user, scope_field(assigns.current_scope, :user))

    ~H"""
    <a
      href="#main"
      class="btn btn-sm sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70]"
    >
      Skip to content
    </a>

    <div id="shell" class="drawer md:drawer-open" phx-hook="NavDrawer">
      <input
        id="nav-drawer"
        type="checkbox"
        class="drawer-toggle"
        phx-update="ignore"
        tabindex="-1"
        aria-hidden="true"
      />

      <div
        id="shell-content"
        class="drawer-content flex min-h-dvh min-w-0 flex-col bg-base-100"
        phx-mounted={JS.ignore_attributes(["inert"])}
      >
        <header class="sticky top-0 z-30 flex h-13 flex-none items-center justify-between border-b border-line bg-base-100/85 pl-2 pr-4 backdrop-blur md:hidden">
          <div class="flex items-center gap-1">
            <button
              id="nav-drawer-open"
              type="button"
              data-drawer-open
              class="btn btn-ghost btn-square"
              aria-label="Open menu"
              aria-controls="sidebar"
              aria-expanded="false"
              phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>
            <.brand />
          </div>
          <.avatar :if={@user} name={@user.email} kind="self" />
        </header>

        <main id="main" tabindex="-1" class="min-w-0 flex-1 outline-none">
          <div class="mx-auto w-full px-4 pb-12 pt-5 md:px-6 md:pt-8 lg:px-10">
            <div class={["mx-auto", if(@width == "full", do: "max-w-[1200px]", else: "max-w-[960px]")]}>
              <div class={[
                "grid grid-cols-[minmax(0,1fr)] gap-6",
                @width == "narrow" && "max-w-[640px]"
              ]}>
                {render_slot(@inner_block)}
              </div>
            </div>
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="nav-drawer" class="drawer-overlay" aria-hidden="true"></label>
        <.sidebar
          organisation={@organisation}
          hive={@hive}
          membership={@membership}
          user={@user}
          memberships={@memberships}
          nav={@nav}
          nav_items={@nav_items}
          counts={@counts}
        />
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :organisation, :any
  attr :hive, :any
  attr :membership, :any
  attr :user, :any
  attr :memberships, :list
  attr :nav, :atom
  attr :nav_items, :list
  attr :counts, :any

  defp sidebar(assigns) do
    ~H"""
    <aside
      id="sidebar"
      aria-label="Sidebar"
      class="flex h-dvh w-72 flex-col border-r border-line bg-base-200 max-md:shadow-modal md:w-60"
    >
      <div class="flex h-14 flex-none items-center justify-between pl-4 pr-2 md:pr-4">
        <.brand />
        <button
          type="button"
          data-drawer-close
          class="btn btn-ghost btn-square md:hidden"
          aria-label="Close menu"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <.workspace
        :if={@organisation}
        organisation={@organisation}
        hive={@hive}
        memberships={@memberships}
      />

      <div :for={{section, label, items} <- (@organisation && @nav_items) || []} class="contents">
        <p class="px-4 pb-1 pt-3 text-[11.5px]/4 font-medium text-faint">
          <.term :if={section == "Hive"} word="Hive" />
          <span :if={section != "Hive"}>{section}</span>
        </p>
        <nav class="grid gap-px px-2" aria-label={label}>
          <.link
            :for={{key, label, icon, path} <- items}
            id={"nav-#{key}"}
            navigate={path}
            aria-current={@nav == key && "page"}
            class={[
              "group flex h-8 items-center gap-2.5 rounded-field px-2 text-[13px] font-medium transition-colors",
              "-outline-offset-2 hover:bg-base-300 hover:text-base-content max-md:h-10 max-md:text-sm",
              if(@nav == key, do: "bg-base-300 text-base-content", else: "text-muted")
            ]}
          >
            <.icon
              name={icon}
              class={[
                "size-4 transition-colors",
                if(@nav == key, do: "text-accent", else: "text-faint")
              ]}
            />
            {label}
            <span
              :if={key == :runs && alive_count(@counts) > 0}
              id="nav-runs-alive"
              class="ml-auto inline-flex items-center gap-1.5 font-mono text-[11.5px]/4 text-info-soft-content tabular-nums"
              title={alive_title(alive_count(@counts))}
            >
              <span class="q-dot q-ripple !size-1.5" aria-hidden="true"></span>
              {alive_count(@counts)}
            </span>
            <span
              :if={key == :policy && policy_mode(@counts)}
              id="nav-policy-mode"
              class="ml-auto font-mono text-[11.5px]/4 text-faint"
              title={policy_mode_title(@counts)}
            >
              {policy_mode(@counts)}<span :if={own_modes(@counts) != []} class="opacity-75"> · {length(
                own_modes(@counts)
              )} own</span>
            </span>
            <span
              :if={count = nav_count(@counts, key)}
              class="ml-auto font-mono text-[11.5px]/4 text-faint tabular-nums"
            >
              {count}
            </span>
          </.link>
        </nav>
      </div>

      <div class="flex-1" />

      <.user_card
        :if={@user}
        user={@user}
        organisation={@organisation}
        membership={@membership}
      />
    </aside>
    """
  end

  defp nav_count(%{keys: n}, :keys), do: n
  defp nav_count(%{members: n}, :members), do: n
  defp nav_count(_counts, _key), do: nil

  # The mode in force is a word, not a colour: observe is not a fault. Absent while the
  # hive has no policy of Qory's yet.
  defp policy_mode(%{mode: mode}) when mode in ["observe", "enforce"], do: mode
  defp policy_mode(_counts), do: nil

  defp own_modes(%{own_modes: modes}) when is_list(modes), do: modes
  defp own_modes(_counts), do: []

  # The tag never claims what every run is under: it names the default and how many differ.
  defp policy_mode_title(counts) do
    lead = "The hive's default mode is #{policy_mode(counts)}."

    case own_modes(counts) do
      [] -> "#{lead} Every repository follows it."
      [mode] -> "#{lead} 1 repository sets its own and #{mode}s."
      modes -> "#{lead} #{length(modes)} repositories set their own."
    end
  end

  defp alive_count(%{alive: n}) when is_integer(n), do: n
  defp alive_count(_counts), do: 0

  defp alive_title(1), do: "1 run alive now"
  defp alive_title(n), do: "#{n} runs alive now"

  attr :organisation, :any, required: true
  attr :hive, :any, required: true
  attr :memberships, :list, required: true

  # One membership: a plain block. Several: a dropdown of POST buttons.
  defp workspace(%{memberships: memberships} = assigns) when length(memberships) > 1 do
    ~H"""
    <div
      id="workspace-menu"
      class="dropdown mx-2 mb-2 block"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="workspace-menu-button"
        type="button"
        class="grid w-full cursor-pointer grid-cols-[28px_1fr_auto] items-center gap-2.5 rounded-field border border-line bg-base-100 px-2 py-1.5 text-left shadow-xs transition-colors hover:border-line-strong"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={"Switch apiary, current: #{@organisation.name}"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.workspace_label organisation={@organisation} hive={@hive} />
        <.icon name="hero-chevron-up-down-micro" class="size-4 text-faint" />
      </button>
      <form
        method="post"
        action={~p"/organisations/switch"}
        class="dropdown-content left-0 top-full mt-1.5 w-full"
      >
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <ul class="menu menu-sm w-full min-w-0" role="menu" aria-label="Switch apiary">
          <li class="menu-title" role="presentation">Switch <.term word="apiary" /></li>
          <li :for={m <- @memberships} role="none">
            <button
              type="submit"
              name="organisation_id"
              value={m.organisation_id}
              role="menuitem"
              aria-current={m.organisation_id == @organisation.id && "true"}
              class="!h-auto min-h-[38px] py-1"
            >
              <.avatar name={m.organisation.name} kind="apiary" />
              <span class="grid min-w-0 flex-1">
                <span class="truncate font-medium">{m.organisation.name}</span>
                <span class="truncate text-xs/4 text-faint">{m.hive.name}</span>
              </span>
              <.icon
                :if={m.organisation_id == @organisation.id}
                name="hero-check-micro"
                class="size-4 !text-base-content"
              />
            </button>
          </li>
        </ul>
      </form>
    </div>
    """
  end

  defp workspace(assigns) do
    ~H"""
    <div class="mx-2 mb-2 grid grid-cols-[28px_1fr] items-center gap-2.5 rounded-field border border-transparent px-2 py-1.5">
      <.workspace_label organisation={@organisation} hive={@hive} />
    </div>
    """
  end

  attr :organisation, :any, required: true
  attr :hive, :any, required: true

  defp workspace_label(assigns) do
    ~H"""
    <.avatar name={@organisation.name} kind="apiary" size="md" />
    <span class="grid min-w-0">
      <span class="truncate text-[13px]/[18px] font-semibold" title={@organisation.name}>
        {@organisation.name}
      </span>
      <span class="truncate text-xs/4 text-muted" title={@hive && @hive.name}>
        {@hive && @hive.name}
      </span>
    </span>
    """
  end

  attr :user, :any, required: true
  attr :organisation, :any, required: true
  attr :membership, :any, required: true

  defp user_card(assigns) do
    ~H"""
    <div
      id="user-menu"
      class="dropdown dropdown-top m-2 block"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="user-menu-button"
        type="button"
        class="grid w-full cursor-pointer grid-cols-[24px_1fr_auto] items-center gap-2.5 rounded-field px-2 py-1.5 text-left transition-colors hover:bg-base-300 aria-expanded:bg-base-300"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={"Account menu, #{@user.email}"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.avatar name={@user.email} kind="self" />
        <span class="grid min-w-0">
          <span class="truncate text-[13px]/[18px] font-medium" title={@user.email}>
            {@user.email}
          </span>
          <span class="text-[11.5px]/[14px] text-faint">{level_label(@membership)}</span>
        </span>
        <.icon name="hero-chevron-up-down-micro" class="size-4 text-faint" />
      </button>
      <ul
        class="menu menu-sm dropdown-content bottom-full left-0 mb-1.5 w-56"
        role="menu"
        aria-label="Account"
      >
        <li role="presentation">
          <div class="grid cursor-default grid-flow-row gap-0 px-2 pb-2 pt-1.5 hover:bg-transparent">
            <span class="truncate font-medium">{@user.email}</span>
            <span class="truncate text-xs/4 text-faint">
              {level_sentence(@membership, @organisation)}
            </span>
          </div>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link href={~p"/users/settings"} role="menuitem">
            <.icon name="hero-user-circle-micro" class="size-4" /> Account settings
          </.link>
        </li>
        <li role="none">
          <.link href={~p"/docs"} role="menuitem" id="user-menu-docs">
            <.icon name="hero-book-open-micro" class="size-4" /> Docs
          </.link>
        </li>
        <li class="menu-title" role="presentation">Theme</li>
        <li role="none">
          <div class="block cursor-default px-1 pb-1 pt-0.5 hover:bg-transparent">
            <.theme_segments />
          </div>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link href={~p"/users/log-out"} method="delete" role="menuitem">
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> Log out
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp level_label(%{level: :owner}), do: "Owner"
  defp level_label(%{level: :member}), do: "Member"
  defp level_label(_membership), do: "No apiary yet"

  defp level_sentence(%{level: :owner}, %{name: name}), do: "Owner of #{name}"
  defp level_sentence(%{level: :member}, %{name: name}), do: "Member of #{name}"
  defp level_sentence(_membership, _organisation), do: "Not part of an apiary yet"

  defp scope_field(nil, _field), do: nil
  defp scope_field(scope, field), do: Map.get(scope, field)

  @doc """
  The split view for log-in, registration, confirmation, invitation and the
  welcome page: a brand panel from 1024 px (a header strip below), and a
  352 px form column with no card around it.

      <Layouts.auth flash={@flash}>
        ...
      </Layouts.auth>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <a
      href="#main"
      class="btn btn-sm sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70]"
    >
      Skip to content
    </a>

    <div class="grid min-h-dvh lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
      <aside
        aria-label="Qory"
        class="relative hidden flex-col justify-between gap-8 overflow-hidden border-r border-line bg-base-200 p-8 lg:flex lg:p-10"
      >
        <svg
          class="absolute inset-0 size-full text-base-content opacity-[0.2] [mask-image:radial-gradient(130%_100%_at_0%_100%,#000_10%,transparent_75%)]"
          aria-hidden="true"
        >
          <defs>
            <pattern id="comb" width="24.25" height="42" patternUnits="userSpaceOnUse">
              <path
                d="M12.125 0 24.25 7v14l-12.125 7L0 21V7ZM12.125 28v14"
                fill="none"
                stroke="currentColor"
                stroke-width="1"
              />
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill="url(#comb)" />
        </svg>
        <div class="relative"><.brand size="lg" /></div>
        <div class="relative grid gap-3.5">
          <p class="max-w-[30ch] text-balance text-[26px]/8 font-semibold tracking-[-0.025em]">
            Can you trust your agents? With Qory <span class="text-accent">you don't have to</span>.
          </p>
          <p class="max-w-[46ch] text-[13px]/5 text-muted">
            Every session runs behind a security wall, reaches only what you allow, never holds
            your keys, and leaves a full record. Open source, so you can check all of that.
          </p>
        </div>
      </aside>

      <div class="relative flex min-h-dvh min-w-0 flex-col bg-base-100">
        <header class="flex h-14 flex-none items-center justify-between border-b border-line px-4 lg:absolute lg:right-5 lg:top-5 lg:h-auto lg:border-0 lg:px-0">
          <.brand class="lg:hidden" />
          <.theme_menu />
        </header>
        <main
          id="main"
          tabindex="-1"
          class="flex flex-1 items-start justify-center px-4 pb-12 pt-10 outline-none lg:items-center lg:px-6 lg:py-16"
        >
          <div class="grid w-full max-w-[352px] gap-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The display heading of an auth page with its one-line description.
  """
  slot :inner_block, required: true
  slot :subtitle

  def auth_heading(assigns) do
    ~H"""
    <div class="grid gap-1.5">
      <h1 class="text-2xl/8 font-semibold tracking-[-0.025em] sm:text-3xl/9">
        {render_slot(@inner_block)}
      </h1>
      <p :if={@subtitle != []} class="text-sm/5 text-muted">{render_slot(@subtitle)}</p>
    </div>
    """
  end

  @doc """
  Shows the flash group as toasts, bottom-right.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="toast toast-end toast-bottom pointer-events-none z-[60] p-4 max-sm:inset-x-0 sm:p-6"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Connection lost."
        spinner
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting. Your changes are safe.
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong on our side."
        spinner
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting.
      </.flash>
    </div>
    """
  end

  @doc """
  The three-way theme control: Auto, Light, Dark. A labelled group of buttons;
  `aria-pressed` follows the theme script in root.html.heex.
  """
  def theme_segments(assigns) do
    ~H"""
    <div class="theme-seg" role="group" aria-label="Theme">
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "Auto"},
            {"light", "hero-sun-micro", "Light"},
            {"dark", "hero-moon-micro", "Dark"}
          ]
        }
        id={"theme-#{theme}"}
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        phx-mounted={JS.ignore_attributes(["aria-pressed"])}
        data-phx-theme={theme}
        aria-pressed="false"
      >
        <.icon name={icon} class="size-[13px]" />{label}
      </button>
    </div>
    """
  end

  @doc """
  The theme control of the auth pages: an icon-only button opening the
  three-way menu.
  """
  def theme_menu(assigns) do
    ~H"""
    <div
      id="theme-menu"
      class="theme-menu dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <div
        id="theme-menu-button"
        tabindex="0"
        role="button"
        class="tooltip tooltip-left btn btn-ghost btn-square inline-flex"
        data-tip="Theme"
        aria-label="Theme"
        aria-haspopup="menu"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-sun-micro" class="size-4 dark:hidden" />
        <.icon name="hero-moon-micro" class="hidden size-4 dark:inline-block" />
      </div>
      <ul class="menu menu-sm dropdown-content mt-1.5 w-40 min-w-0" role="menu" aria-label="Theme">
        <li
          :for={
            {theme, icon, label} <- [
              {"system", "hero-computer-desktop-micro", "Auto"},
              {"light", "hero-sun-micro", "Light"},
              {"dark", "hero-moon-micro", "Dark"}
            ]
          }
          role="none"
        >
          <button
            id={"theme-menu-#{theme}"}
            type="button"
            role="menuitemradio"
            phx-click={JS.dispatch("phx:set-theme")}
            phx-mounted={JS.ignore_attributes(["aria-checked"])}
            data-phx-theme={theme}
            aria-checked="false"
            data-menu-close
          >
            <.icon name={icon} class="size-4" />
            <span class="flex-1">{label}</span>
            <.icon name="hero-check-micro" class="theme-check size-4 !text-base-content" />
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
