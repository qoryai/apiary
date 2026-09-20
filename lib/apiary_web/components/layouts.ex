defmodule ApiaryWeb.Layouts do
  @moduledoc """
  Layouts: the application shell (`app/1`) for signed-in pages and the
  centred card (`auth/1`) for sign-in, registration and similar pages.
  """
  use ApiaryWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @nav [
    {:overview, "Overview", "hero-squares-2x2", "/hive"},
    {:keys, "Access keys", "hero-key", "/hive/keys"},
    {:members, "Members", "hero-users", "/hive/members"},
    {:settings, "Settings", "hero-cog-6-tooth", "/hive/settings"}
  ]

  @doc """
  The application shell: a sidebar with the apiary and hive, the navigation
  and the user menu, and a main column for the page.

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

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> assign(:nav_items, @nav)
      |> assign(:organisation, scope_field(assigns.current_scope, :organisation))
      |> assign(:hive, scope_field(assigns.current_scope, :hive))
      |> assign(:user, scope_field(assigns.current_scope, :user))

    ~H"""
    <div class="min-h-dvh lg:flex">
      <aside class="hidden lg:fixed lg:inset-y-0 lg:left-0 lg:flex lg:w-60 lg:flex-col lg:border-r lg:border-line lg:bg-surface">
        <.sidebar
          organisation={@organisation}
          hive={@hive}
          user={@user}
          memberships={@memberships}
          nav={@nav}
          nav_items={@nav_items}
          id="sidebar"
        />
      </aside>

      <header class="sticky top-0 z-30 flex h-14 items-center justify-between border-b border-line bg-surface px-4 lg:hidden">
        <.brand />
        <button
          type="button"
          class="-mr-2 rounded-md p-2 text-ink-muted transition hover:bg-surface-2 hover:text-ink"
          phx-click={
            JS.toggle(to: "#mobile-nav") |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
          aria-controls="mobile-nav"
          aria-expanded="false"
          aria-label="Open menu"
        >
          <.icon name="hero-bars-3" class="size-6" />
        </button>
      </header>
      <div
        id="mobile-nav"
        class="hidden border-b border-line bg-surface lg:hidden"
        phx-click-away={JS.hide(to: "#mobile-nav")}
      >
        <.sidebar
          organisation={@organisation}
          hive={@hive}
          user={@user}
          memberships={@memberships}
          nav={@nav}
          nav_items={@nav_items}
          id="mobile-sidebar"
        />
      </div>

      <main class="min-w-0 flex-1 lg:pl-60">
        <div class="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6 sm:py-8 lg:px-10">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :organisation, :any
  attr :hive, :any
  attr :user, :any
  attr :memberships, :list
  attr :nav, :atom
  attr :nav_items, :list

  defp sidebar(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <div class="hidden h-14 items-center px-5 lg:flex">
        <.brand />
      </div>

      <div :if={@organisation} class="border-y border-line px-3 py-3 lg:border-t-0">
        <%= if length(@memberships) > 1 do %>
          <form method="post" action={~p"/organisations/switch"} class="relative">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <label for={"#{@id}-switcher"} class="sr-only">
              Switch <.term word="apiary" />
            </label>
            <select
              id={"#{@id}-switcher"}
              name="organisation_id"
              phx-hook="SubmitOnChange"
              class="select-field h-9 w-full cursor-pointer rounded-field border border-line-strong bg-surface px-3 text-sm font-medium text-ink shadow-low transition hover:bg-surface-2"
            >
              <option
                :for={m <- @memberships}
                value={m.organisation_id}
                selected={m.organisation_id == @organisation.id}
              >
                {m.organisation.name}
              </option>
            </select>
          </form>
        <% else %>
          <p class="truncate px-2 text-sm font-semibold text-ink" title={@organisation.name}>
            {@organisation.name}
          </p>
        <% end %>
        <p class="mt-1 flex items-center gap-1.5 px-2 text-[13px] text-ink-muted">
          <.icon name="hero-cube-micro" class="size-3.5 text-ink-faint" />
          <span class="truncate" title={@hive && @hive.name}>{@hive && @hive.name}</span>
          <.term word="hive" class="text-ink-faint" />
        </p>
      </div>

      <nav :if={@organisation} class="flex-1 space-y-0.5 px-3 py-3" aria-label="Main">
        <.link
          :for={{key, label, icon, path} <- @nav_items}
          navigate={path}
          aria-current={@nav == key && "page"}
          class={[
            "flex items-center gap-2.5 rounded-field px-2.5 py-2 text-sm font-medium transition",
            @nav == key && "bg-accent-soft text-ink",
            @nav != key && "text-ink-muted hover:bg-surface-2 hover:text-ink"
          ]}
        >
          <.icon
            name={icon}
            class={[
              "size-[18px]",
              @nav == key && "text-accent-soft-ink",
              @nav != key && "text-ink-faint"
            ]}
          />
          {label}
        </.link>
      </nav>
      <div :if={!@organisation} class="flex-1" />

      <div class="border-t border-line px-3 py-3">
        <div class="mb-2 flex items-center justify-between px-2">
          <span class="text-xs font-medium text-ink-faint">Theme</span>
          <.theme_toggle />
        </div>
        <details :if={@user} class="group relative">
          <summary class="flex cursor-pointer list-none items-center gap-2.5 rounded-field px-2 py-2 transition hover:bg-surface-2 [&::-webkit-details-marker]:hidden">
            <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-accent-soft text-xs font-semibold uppercase text-accent-soft-ink">
              {String.first(@user.email)}
            </span>
            <span class="min-w-0 flex-1 truncate text-sm text-ink" title={@user.email}>
              {@user.email}
            </span>
            <.icon
              name="hero-chevron-up-down-micro"
              class="size-4 shrink-0 text-ink-faint"
            />
          </summary>
          <div class="absolute inset-x-0 bottom-full mb-1 rounded-box border border-line bg-surface p-1 shadow-pop">
            <.link
              href={~p"/users/settings"}
              class="flex items-center gap-2 rounded-field px-2.5 py-2 text-sm text-ink transition hover:bg-surface-2"
            >
              <.icon name="hero-user-circle-micro" class="size-4 text-ink-faint" /> Account settings
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              class="flex items-center gap-2 rounded-field px-2.5 py-2 text-sm text-ink transition hover:bg-surface-2"
            >
              <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4 text-ink-faint" />
              Log out
            </.link>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp scope_field(nil, _field), do: nil
  defp scope_field(scope, field), do: Map.get(scope, field)

  @doc """
  The centred card layout for sign-in, registration and invitation pages.

      <Layouts.auth flash={@flash}>
        ...
      </Layouts.auth>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  attr :width, :string, default: "max-w-sm"
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <header class="flex h-16 items-center justify-between px-4 sm:px-6">
        <.brand />
        <.theme_toggle />
      </header>
      <main class="flex flex-1 items-start justify-center px-4 pb-16 pt-6 sm:pt-12">
        <div class={["w-full", @width]}>
          <div class="rounded-box border border-line bg-surface p-6 shadow-low sm:p-8">
            {render_slot(@inner_block)}
          </div>
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

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
      class="pointer-events-none fixed inset-x-0 top-0 z-[60] flex flex-col items-end gap-2 p-4 sm:p-6"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="theme-toggle inline-flex items-center gap-0.5 rounded-full border border-line bg-surface-2 p-0.5">
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "System theme"},
            {"light", "hero-sun-micro", "Light theme"},
            {"dark", "hero-moon-micro", "Dark theme"}
          ]
        }
        type="button"
        class="flex size-6 cursor-pointer items-center justify-center rounded-full transition hover:text-ink"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end
end
