defmodule ApiaryWeb.Layouts do
  @moduledoc """
  Layouts: the application shell (`app/1`) for signed-in pages and the split
  view (`auth/1`) for log-in, registration, invitation and welcome pages. The
  product on every surface is Qory Apiary; the shell is section f of the
  design brief.
  """
  use ApiaryWeb, :html

  alias ApiaryWeb.Nav.Entry

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # The sidebar's two sections, the record first, because it is why people open the
  # console: each with its heading and its navigation's accessible name. The words are
  # marked for extraction here and translated when the sidebar renders (`nav_text/1`).
  @sections [
    workspace: {gettext_noop("Workspace"), gettext_noop("Main")},
    manage: {gettext_noop("Manage"), gettext_noop("Manage")}
  ]

  @doc """
  nav_entries/1 is the navigation of `scope`'s pages, as `ApiaryWeb.Nav.Entry` values:
  the core's, then the edition's (`c:ApiaryWeb.Edition.nav_entries/1`), each after the
  core's of its section. Each names the action its page is for (`Apiary.Access`), nil for
  the entries every member has: the sidebar keeps the ones the reader may take, which
  leaves out those of a feature that is off, and the switcher asks them where it leads.
  A new entry of the core goes here, not in a page.
  """
  @spec nav_entries(Apiary.Accounts.Scope.t()) :: [Entry.t()]
  def nav_entries(scope), do: core_entries() ++ ApiaryWeb.Edition.nav_entries(scope)

  defp core_entries do
    [
      %Entry{
        section: :workspace,
        key: :overview,
        label: gettext("Overview"),
        icon: "hero-squares-2x2-micro",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}" end,
        action: :"run.read"
      },
      %Entry{
        section: :workspace,
        key: :runs,
        label: gettext("Runs"),
        icon: "hero-play-circle-micro",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/runs" end,
        action: :"run.read"
      },
      %Entry{
        section: :workspace,
        key: :connections,
        label: gettext("Connections"),
        icon: "hero-arrows-right-left-micro",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/connections" end,
        action: :"run.read"
      },
      # After Connections, because the policy is what the connections are judged by.
      %Entry{
        section: :workspace,
        key: :policy,
        label: gettext("Policy"),
        icon: "hero-shield-check-micro",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/policy" end,
        action: :"security_policy.read"
      },
      %Entry{
        section: :manage,
        key: :keys,
        label: gettext("Access keys"),
        icon: "hero-key-micro",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/keys" end,
        count: :keys
      },
      %Entry{
        section: :manage,
        key: :members,
        label: gettext("Members"),
        icon: "hero-users-micro",
        path: fn organisation, _workspace -> ~p"/#{organisation}/members" end,
        place: :organisation,
        count: :members
      },
      %Entry{
        section: :manage,
        key: :settings,
        label: gettext("Settings"),
        icon: "hero-cog-6-tooth-micro",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/settings" end
      },
      %Entry{
        section: :manage,
        key: :organisation,
        label: gettext("Organisation"),
        icon: "hero-building-office-2-micro",
        path: fn organisation, _workspace -> ~p"/#{organisation}/settings" end,
        place: :organisation
      },
      %Entry{
        section: :manage,
        key: :activity,
        label: gettext("Activity"),
        icon: "hero-clipboard-document-list-micro",
        path: fn organisation, _workspace -> ~p"/#{organisation}/activity" end,
        place: :organisation,
        action: :"audit.read"
      }
    ]
  end

  @doc """
  The application shell: a sidebar that is the organisation's (its name and workspace at
  the top, the navigation, the brand at the foot), a 52 px top bar with the
  theme toggle and the account menu at its right end, and a main column for
  the page. Below 768 px the sidebar is a drawer behind the bar's menu button.
  Without a membership there is no sidebar: the bar carries the brand.

  An organisation's page, one with a navigation item (`nav`), opens with the edition's
  notices (the `:notices` slot, `ApiaryWeb.Extension`): the page beneath says the rest. A
  person's own pages, whose sidebar shows the organisation they opened last, carry none.

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:keys}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :memberships, :list,
    default: [],
    doc:
      "the places the user reaches, for the switcher: their memberships and whatever else the edition lets them reach (`Apiary.Organisations.list_places/1`), with the workspaces of each"

  attr :nav, :atom, default: nil, doc: "the active navigation item"

  attr :notices, :boolean,
    default: nil,
    doc:
      "whether the organisation's notices show, the edition's (the `:notices` slot): on every page of the organisation, which passes `nav`, unless given; a person's own pages carry an organisation too, and show none"

  attr :counts, :map,
    default: nil,
    doc:
      "%{keys: active keys, members: members, alive: runs alive now, mode: the policy's default mode, own_modes: the modes targets set}"

  attr :width, :string,
    default: "wide",
    values: ~w(wide narrow full),
    doc: "960 or 640 px column; full is 1200 px, for the runs, run and connections pages"

  slot :inner_block, required: true

  def app(assigns) do
    organisation = scope_field(assigns.current_scope, :organisation)
    entries = if organisation, do: nav_entries(assigns.current_scope), else: []

    assigns =
      assigns
      |> assign(:nav_entries, entries)
      |> assign(:nav_items, nav_items(assigns.current_scope, assigns.counts, entries))
      |> assign(:organisation, organisation)
      |> assign(:workspace, scope_field(assigns.current_scope, :workspace))
      |> assign(:scope, assigns.current_scope)
      |> assign(:user, scope_field(assigns.current_scope, :user))

    ~H"""
    <a
      href="#main"
      class="btn btn-sm sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70]"
    >
      {gettext("Skip to content")}
    </a>

    <%= if @organisation do %>
      <div id="shell" class="drawer md:drawer-open" phx-hook="NavDrawer">
        <input
          id="nav-drawer"
          type="checkbox"
          class="drawer-toggle"
          phx-update="ignore"
          tabindex="-1"
          aria-hidden="true"
        />

        <div class="drawer-side z-40">
          <label for="nav-drawer" class="drawer-overlay" aria-hidden="true"></label>
          <.sidebar
            scope={@scope}
            organisation={@organisation}
            workspace={@workspace}
            memberships={@memberships}
            nav={@nav}
            nav_entries={@nav_entries}
            nav_items={@nav_items}
            counts={@counts}
          />
        </div>

        <div
          id="shell-content"
          class="drawer-content flex min-h-dvh min-w-0 flex-col bg-base-100"
          phx-mounted={JS.ignore_attributes(["inert"])}
        >
          <.top_bar>
            <button
              id="nav-drawer-open"
              type="button"
              data-drawer-open
              class="btn btn-ghost btn-square md:hidden"
              aria-label={gettext("Open menu")}
              aria-controls="sidebar"
              aria-expanded="false"
              phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </button>
            <div
              id="organisation-label"
              class="flex min-w-0 items-center gap-2.5 px-1 md:hidden"
              title={organisation_title(@organisation, @workspace)}
            >
              <.avatar name={@organisation.name} kind="organisation" />
              <span class="grid min-w-0">
                <span class="truncate text-[13px]/4 font-semibold">{@organisation.name}</span>
                <span class="truncate text-[11.5px]/[14px] text-muted">{@workspace && @workspace.name}</span>
              </span>
            </div>
            <:controls>
              <.theme_menu tooltip="tooltip-bottom" />
              <.account_menu user={@user} organisation={@organisation} scope={@scope} />
            </:controls>
          </.top_bar>
          <.content width={@width}>
            <.notices
              :if={if(is_nil(@notices), do: !!@nav, else: @notices)}
              scope={@scope}
              organisation={@organisation}
              counts={@counts}
            />
            {render_slot(@inner_block)}
          </.content>
        </div>
      </div>
    <% else %>
      <div id="shell" class="flex min-h-dvh min-w-0 flex-col bg-base-100">
        <.top_bar>
          <div class="ml-1 flex min-w-0 items-center">
            <.brand_menu version={version()} direction="down" />
          </div>
          <:controls>
            <.theme_menu tooltip="tooltip-bottom" />
            <.account_menu
              :if={@user}
              user={@user}
              organisation={@organisation}
              scope={@scope}
            />
          </:controls>
        </.top_bar>
        <.content width={@width}>{render_slot(@inner_block)}</.content>
      </div>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  # The bar: 52 px, level with the sidebar's organisation row so their lower edges read as
  # one line. The left holds what the default slot gives it (nothing from 768 px, when
  # the sidebar is there); the controls sit at the right end at every width.
  slot :inner_block
  slot :controls, required: true

  defp top_bar(assigns) do
    ~H"""
    <header
      id="top-bar"
      aria-label={gettext("Top bar")}
      class="sticky top-0 z-30 flex h-13 flex-none items-center gap-1 border-b border-line bg-base-100/85 pl-2 pr-4 backdrop-blur md:px-4"
    >
      {render_slot(@inner_block)}
      <div class="ml-auto flex flex-none items-center gap-1">
        {render_slot(@controls)}
      </div>
    </header>
    """
  end

  # The notices of the organisation the page is in: the edition's (`ApiaryWeb.Extension`),
  # given the navigation's counts, which the page read when it loaded, so that a notice
  # needs no read of its own on every render.
  attr :scope, :any, required: true
  attr :organisation, :any, required: true
  attr :counts, :map, default: nil

  defp notices(assigns) do
    ~H"""
    <ApiaryWeb.Extension.slot
      name={:notices}
      scope={@scope}
      organisation={@organisation}
      counts={@counts}
    />
    """
  end

  attr :width, :string, required: true
  slot :inner_block, required: true

  defp content(assigns) do
    ~H"""
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
    """
  end

  attr :scope, :any
  attr :organisation, :any
  attr :workspace, :any
  attr :memberships, :list
  attr :nav, :atom
  attr :nav_entries, :list
  attr :nav_items, :list
  attr :counts, :any

  defp sidebar(assigns) do
    assigns = assign(assigns, :version, version())

    ~H"""
    <aside
      id="sidebar"
      aria-label={gettext("Sidebar")}
      class="flex h-dvh w-72 flex-col border-r border-line bg-base-200 max-md:shadow-modal md:w-60"
    >
      <div id="organisation-row" class="flex h-13 flex-none items-center gap-1 px-2">
        <.organisation_block
          scope={@scope}
          organisation={@organisation}
          workspace={@workspace}
          memberships={@memberships}
          nav={@nav}
          nav_entries={@nav_entries}
        />
        <button
          type="button"
          data-drawer-close
          class="btn btn-ghost btn-square md:hidden"
          aria-label={gettext("Close menu")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <div :for={{title, label, items} <- @nav_items} class="contents">
        <p class="px-4 pb-1 pt-3 text-[11.5px]/4 font-medium text-faint">
          {nav_text(title)}
        </p>
        <nav class="grid gap-px px-2" aria-label={nav_text(label)}>
          <.link
            :for={{entry, path} <- items}
            id={"nav-#{entry.key}"}
            navigate={path}
            aria-current={@nav == entry.key && "page"}
            class={[
              "group flex h-8 items-center gap-2.5 rounded-field px-2 text-[13px] font-medium transition-colors",
              "-outline-offset-2 hover:bg-base-300 hover:text-base-content max-md:h-10 max-md:text-sm",
              if(@nav == entry.key, do: "bg-base-300 text-base-content", else: "text-muted")
            ]}
          >
            <.icon
              name={entry.icon}
              class={[
                "size-4 transition-colors",
                if(@nav == entry.key, do: "text-accent", else: "text-faint")
              ]}
            />
            {entry.label}
            <span
              :if={entry.key == :runs && alive_count(@counts) > 0}
              id="nav-runs-alive"
              class="ml-auto inline-flex items-center gap-1.5 font-mono text-[11.5px]/4 text-info-soft-content tabular-nums"
              title={alive_title(alive_count(@counts))}
            >
              <span class="q-dot q-ripple !size-1.5" aria-hidden="true"></span>
              {alive_count(@counts)}
            </span>
            <span
              :if={entry.key == :policy && policy_mode(@counts)}
              id="nav-policy-mode"
              class="ml-auto font-mono text-[11.5px]/4 text-faint"
              title={policy_mode_title(@counts)}
            >
              {policy_mode(@counts)}<span :if={own_modes(@counts) != []} class="opacity-75"> · {gettext(
                "%{number} own",
                number: Format.number(length(own_modes(@counts)))
              )}</span>
            </span>
            <span
              :if={count = nav_count(@counts, entry)}
              class="ml-auto font-mono text-[11.5px]/4 text-faint tabular-nums"
            >
              {Format.number(count)}
            </span>
          </.link>
        </nav>
      </div>

      <div class="flex-1" />

      <div id="brand-foot" class="m-2 flex-none">
        <.brand_menu version={@version} direction="up" />
      </div>
    </aside>
    """
  end

  # The running version, from the application's spec. Nil before the spec exists
  # (a clean compile), and then the foot shows the brand alone.
  defp version do
    case Application.spec(:apiary, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp nav_text(msgid), do: Gettext.gettext(ApiaryWeb.Gettext, msgid)

  # The entries the scope may open, by section, with where each leads. A feature that is
  # off is absent, not disabled: no entry, greyed or otherwise, and so nothing beside it
  # either (Policy's mode word goes with Policy). A section left empty goes too. Without a
  # workspace, for a member added to none yet, only the organisation's own entries are
  # there.
  defp nav_items(
         %{organisation: %{} = organisation, workspace: workspace} = scope,
         counts,
         entries
       ) do
    for {section, {title, label}} <- @sections,
        shown =
          for(
            %Entry{section: ^section} = entry <- entries,
            shown?(entry, scope, workspace, counts),
            do: {entry, Entry.path(entry, organisation, workspace)}
          ),
        shown != [],
        do: {title, label, shown}
  end

  defp nav_items(_scope, _counts, _entries), do: []

  defp shown?(%Entry{place: :workspace}, _scope, nil, _counts), do: false

  defp shown?(%Entry{} = entry, scope, workspace, counts) do
    (is_nil(entry.filter) or entry.filter.(scope, counts)) and
      nav_open?(scope, entry.action, workspace || scope.organisation)
  end

  # Where the switcher leads: to a workspace of a membership, the section the user is on,
  # when they may open it there too, else the first entry they may open there, the
  # overview for a reader of the record. Asked with the scope that membership, and what the
  # edition says of it, give. A membership that reaches no workspace leads to its
  # organisation's own path, which says so.
  defp switch_path(_nav, _entries, %{organisation: organisation}, nil), do: ~p"/#{organisation}"

  defp switch_path(nav, entries, %{organisation: organisation} = place, workspace) do
    scope = place_scope(place, workspace)
    may? = &nav_open?(scope, &1.action, workspace)
    entry = Enum.find(entries, &(&1.key == nav and may?.(&1))) || Enum.find(entries, may?)

    Entry.path(entry, organisation, workspace)
  end

  # The scope a place of the switcher gives in `workspace`, as
  # `Apiary.Organisations.resolve_scope/4` would load it: the edition's, for a place of its
  # own or a membership it puts more on, else a membership's in its organisation.
  defp place_scope(place, workspace) do
    ApiaryWeb.Edition.place_scope(place, workspace) ||
      %Apiary.Accounts.Scope{
        organisation: place.organisation,
        workspace: workspace,
        membership: place
      }
  end

  defp nav_open?(_scope, nil, _subject), do: true
  defp nav_open?(scope, action, subject), do: Apiary.Access.can?(scope, action, subject)

  # One place to switch to per workspace each membership reaches, and one for a
  # membership that reaches none yet: `{membership, workspace or nil}`.
  defp places(memberships) do
    for membership <- memberships,
        workspace <- if(membership.workspaces == [], do: [nil], else: membership.workspaces),
        do: {membership, workspace}
  end

  defp current?({membership, workspace}, organisation, current_workspace) do
    membership.organisation_id == organisation.id and
      (workspace && workspace.id) == (current_workspace && current_workspace.id)
  end

  defp switch_id({membership, nil}), do: "switch-#{membership.organisation.slug}"

  defp switch_id({membership, workspace}),
    do: "switch-#{membership.organisation.slug}-#{workspace.slug}"

  defp nav_count(%{} = counts, %Entry{count: key}) when is_atom(key) and not is_nil(key),
    do: Map.get(counts, key)

  defp nav_count(_counts, _entry), do: nil

  # The mode in force is a word, not a colour: observe is not a fault. Absent while the
  # workspace has no policy of Qory's yet.
  defp policy_mode(%{mode: mode}) when mode in ["observe", "enforce"], do: mode
  defp policy_mode(_counts), do: nil

  defp own_modes(%{own_modes: modes}) when is_list(modes), do: modes
  defp own_modes(_counts), do: []

  # The tag never claims what every run is under: it names the default and how many differ.
  defp policy_mode_title(counts) do
    lead = gettext("The workspace's default mode is %{mode}.", mode: policy_mode(counts))

    lead <> " " <> own_modes_sentence(own_modes(counts))
  end

  defp own_modes_sentence([]), do: gettext("Every target follows it.")
  defp own_modes_sentence(["observe"]), do: gettext("1 target sets its own and observes.")
  defp own_modes_sentence(["enforce"]), do: gettext("1 target sets its own and enforces.")

  defp own_modes_sentence(modes),
    do:
      ngettext(
        "%{number} target sets its own.",
        "%{number} targets set their own.",
        length(modes),
        number: Format.number(length(modes))
      )

  defp alive_count(%{alive: n}) when is_integer(n), do: n
  defp alive_count(_counts), do: 0

  defp alive_title(n),
    do:
      ngettext("%{number} run alive now", "%{number} runs alive now", n, number: Format.number(n))

  defp organisation_title(organisation, workspace) do
    Enum.map_join([organisation, workspace], " / ", &(&1 && &1.name))
  end

  attr :scope, :any, default: nil
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :memberships, :list, required: true
  attr :nav, :atom, default: nil
  attr :nav_entries, :list, default: []

  # The organisation block at the top of the sidebar. Its third column is the switcher's
  # chevron slot in both variants, so nothing moves the day a second place arrives. One
  # workspace in one organisation, and no new organisation to create: text, the slot
  # empty. Otherwise the switcher, a dropdown of links to each workspace the user reaches
  # in each organisation, at the section the user is on (the path says which workspace a
  # page shows), and to an organisation where they reach no workspace yet; a
  # link loads the page afresh, so the session remembers the workspace for `/`. Last, the
  # edition's entries (`ApiaryWeb.Edition.switcher_entries/1`), such as New organisation.
  defp organisation_block(%{memberships: memberships} = assigns)
       when is_list(memberships) and memberships != [] do
    assigns =
      assigns
      |> assign(:places, places(memberships))
      |> assign(:switcher_entries, ApiaryWeb.Edition.switcher_entries(assigns.scope))

    if length(assigns.places) > 1 or assigns.switcher_entries != [],
      do: switcher(assigns),
      else: organisation_text(assigns)
  end

  defp organisation_block(assigns), do: organisation_text(assigns)

  defp switcher(assigns) do
    ~H"""
    <div
      id="organisation-menu"
      class="dropdown block min-w-0 flex-1"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="organisation-menu-button"
        type="button"
        class="grid w-full cursor-pointer grid-cols-[28px_1fr_auto] items-center gap-2.5 rounded-field border border-line bg-base-100 px-2 py-1.5 text-left shadow-xs transition-colors hover:border-line-strong"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Switch organisation, current: %{name}", name: @organisation.name)}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.organisation_names organisation={@organisation} workspace={@workspace} />
        <.icon name="hero-chevron-up-down-micro" class="size-4 text-faint" />
      </button>
      <ul
        class="menu menu-sm dropdown-content left-0 top-full mt-1.5 w-full min-w-0"
        role="menu"
        aria-label={gettext("Switch organisation")}
      >
        <li class="menu-title" role="presentation">{gettext("Switch organisation")}</li>
        <li :for={{m, w} = place <- @places} role="none">
          <.link
            id={switch_id(place)}
            href={switch_path(@nav, @nav_entries, m, w)}
            role="menuitem"
            aria-current={current?(place, @organisation, @workspace) && "true"}
            class="!h-auto min-h-[38px] py-1"
          >
            <.avatar name={m.organisation.name} kind="organisation" />
            <span class="grid min-w-0 flex-1">
              <span class="truncate font-medium">{m.organisation.name}</span>
              <span class="truncate text-xs/4 text-faint">
                {if w, do: w.name, else: gettext("No workspace yet")}
              </span>
            </span>
            <.icon
              :if={current?(place, @organisation, @workspace)}
              name="hero-check-micro"
              class="size-4 !text-base-content"
            />
          </.link>
        </li>
        <li :if={@switcher_entries != []} class="menu-divider" role="separator"></li>
        <li :for={entry <- @switcher_entries} role="none">
          <.link
            id={"organisation-menu-#{entry.key}"}
            navigate={Entry.path(entry, @organisation, @workspace)}
            role="menuitem"
            class="!h-auto min-h-[38px] py-1"
          >
            <span
              class="grid size-6 flex-none place-items-center rounded-field border border-dashed border-line-field text-faint"
              aria-hidden="true"
            >
              <.icon name={entry.icon} class="size-3.5" />
            </span>
            <span class="truncate font-medium">{entry.label}</span>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp organisation_text(assigns) do
    ~H"""
    <div
      id="organisation-block"
      class="grid min-w-0 flex-1 grid-cols-[28px_1fr_auto] items-center gap-2.5 rounded-field border border-transparent px-2 py-1.5"
      title={organisation_title(@organisation, @workspace)}
    >
      <.organisation_names organisation={@organisation} workspace={@workspace} />
    </div>
    """
  end

  attr :organisation, :any, required: true
  attr :workspace, :any, required: true

  defp organisation_names(assigns) do
    ~H"""
    <.avatar name={@organisation.name} kind="organisation" size="md" />
    <span class="grid min-w-0">
      <span class="truncate text-[13px]/[18px] font-semibold" title={@organisation.name}>
        {@organisation.name}
      </span>
      <span class="truncate text-xs/4 text-muted" title={@workspace && @workspace.name}>
        {@workspace && @workspace.name}
      </span>
    </span>
    """
  end

  attr :user, :any, required: true
  attr :organisation, :any, required: true
  attr :scope, :any, required: true

  # The account menu at the right end of the top bar: who you are, then settings, your
  # organisations (where those pending deletion show) and log out. No theme row (the
  # toggle's), no switching (the sidebar's), no docs and no version (the brand menu's).
  defp account_menu(assigns) do
    ~H"""
    <div
      id="user-menu"
      class="dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="user-menu-button"
        type="button"
        class="tooltip tooltip-bottom btn btn-ghost btn-keep h-10 min-h-0 min-w-10 gap-1 rounded-field px-2 md:h-8 md:min-w-8 md:px-1 aria-expanded:bg-base-300"
        data-tip={gettext("Account")}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Account menu, %{email}", email: @user.email)}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.avatar name={@user.email} kind="self" />
        <.icon name="hero-chevron-down-micro" class="hidden size-4 text-faint md:inline" />
      </button>
      <ul
        class="menu menu-sm dropdown-content right-0 top-full mt-1.5 w-56"
        role="menu"
        aria-label={gettext("Account")}
      >
        <li role="presentation">
          <div class="grid cursor-default grid-flow-row gap-0 px-2 pb-2 pt-1.5 hover:bg-transparent">
            <span class="truncate font-medium" title={@user.email}>{@user.email}</span>
            <span id="user-menu-level" class="truncate text-xs/4 text-faint">
              {level_sentence(@scope, @organisation)}
            </span>
          </div>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link href={~p"/users/settings"} role="menuitem" id="user-menu-settings">
            <.icon name="hero-user-circle-micro" class="size-4" /> {gettext("Account settings")}
          </.link>
        </li>
        <li role="none">
          <.link href={~p"/users/organisations"} role="menuitem" id="user-menu-organisations">
            <.icon name="hero-building-office-2-micro" class="size-4" /> {gettext(
              "Your organisations"
            )}
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link href={~p"/users/log-out"} method="delete" role="menuitem" id="user-menu-log-out">
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> {gettext(
              "Log out"
            )}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :version, :any, required: true
  attr :direction, :string, required: true, values: ~w(up down)

  # The product's menu, on the brand: the mark and "Qory Apiary" with the version at the
  # right, opening upward from the sidebar's foot and downward from the bar when there is
  # no sidebar. It holds what is about Qory Apiary itself, not about the person: the
  # docs served by this instance, its changelog, and the source.
  defp brand_menu(assigns) do
    ~H"""
    <div
      id="brand-menu"
      class={["dropdown block", @direction == "up" && "dropdown-top w-full"]}
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="brand-menu-button"
        type="button"
        class={[
          "flex cursor-pointer items-center gap-2 rounded-field px-2 text-left text-muted transition-colors hover:bg-base-300 hover:text-base-content aria-expanded:bg-base-300 aria-expanded:text-base-content",
          if(@direction == "up", do: "h-9 w-full max-md:h-10", else: "h-8")
        ]}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={
          if @version,
            do: gettext("Qory Apiary menu, version %{version}", version: @version),
            else: gettext("Qory Apiary menu")
        }
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.logo_mark class="size-[18px]" />
        <span class="whitespace-nowrap text-[13px]/[18px] font-medium tracking-[-0.03em]">
          Qory Apiary
        </span>
        <span
          :if={@version}
          id="brand-version"
          class="ml-auto font-mono text-[11.5px]/4 text-faint tabular-nums"
          title={gettext("Version %{version}", version: @version)}
        >
          {@version}
        </span>
        <.icon
          name={if @direction == "up", do: "hero-chevron-up-micro", else: "hero-chevron-down-micro"}
          class={["size-4 text-faint", @direction == "down" && "-ml-0.5"]}
        />
      </button>
      <ul
        class={[
          "menu menu-sm dropdown-content w-56",
          if(@direction == "up", do: "left-0 bottom-full mb-1.5", else: "left-0 top-full mt-1.5")
        ]}
        role="menu"
        aria-label="Qory Apiary"
      >
        <li role="none">
          <.link href={~p"/docs"} role="menuitem" id="brand-menu-docs">
            <.icon name="hero-book-open-micro" class="size-4" /> {gettext("Docs")}
          </.link>
        </li>
        <%!-- The release notes name every feature, so only the documentation of an instance with
             every one has them; the documentation is the instance's, and so is this check. --%>
        <li :if={Apiary.Features.enabled() == Apiary.Features.all()} role="none">
          <.link href={~p"/docs/changelog.html"} role="menuitem" id="brand-menu-changelog">
            <.icon name="hero-list-bullet-micro" class="size-4" /> {gettext("Changelog")}
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link
            href="https://github.com/qoryai/apiary"
            target="_blank"
            rel="noopener"
            role="menuitem"
            id="brand-menu-source"
          >
            <.icon name="hero-code-bracket-micro" class="size-4" /> {gettext("Source on GitHub")}
            <.icon name="hero-arrow-top-right-on-square-micro" class="ml-auto size-3.5 text-faint" />
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  # The level the person acts at where the page is, their membership's
  # (`Apiary.Access.level/1`); a reader, who reads the organisation through the edition's
  # reach and has no membership there, is told so, in the edition's words where it has
  # them.
  defp level_sentence(scope, %{name: name}) do
    case {Apiary.Access.level(scope), Apiary.Access.reader(scope)} do
      {:owner, _reader} ->
        gettext("Owner of %{name}", name: name)

      {:admin, _reader} ->
        gettext("Admin of %{name}", name: name)

      {:member, _reader} ->
        gettext("Member of %{name}", name: name)

      {nil, reader} when not is_nil(reader) ->
        ApiaryWeb.Edition.reader_sentence(:level, scope) ||
          gettext("Reading %{name}", name: name)

      _none ->
        gettext("Not part of an organisation yet")
    end
  end

  defp level_sentence(_scope, _organisation), do: gettext("Not part of an organisation yet")

  # A translated sentence with its accented words between asterisks, so the sentence stays
  # whole in the catalogue: "With Qory *you don't have to*." Every part is escaped.
  defp accented(text) do
    ~r/\*[^*]+\*/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn
      "*" <> _ = part ->
        words =
          part |> String.trim("*") |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        {:safe, [~s(<span class="text-accent">), words, "</span>"]}

      part ->
        part
    end)
  end

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
      {gettext("Skip to content")}
    </a>

    <div class="grid min-h-dvh lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
      <aside
        aria-label="Qory Apiary"
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
        <div class="relative flex min-h-0 flex-1 items-center justify-center py-2">
          <img
            src={~p"/images/qbee-agent.png"}
            alt=""
            width="960"
            height="960"
            class="h-auto w-full max-w-[min(440px,42vh)] select-none drop-shadow-[0_24px_48px_rgba(0,0,0,0.35)]"
            draggable="false"
          />
        </div>
        <div class="relative grid gap-3.5">
          <p class="max-w-[30ch] text-balance text-[26px]/8 font-semibold tracking-[-0.025em]">
            {accented(gettext("Can you trust your agents? With Qory *you don't have to*."))}
          </p>
          <%!-- Before sign-in there is no organisation: the instance's features decide. --%>
          <p :if={Apiary.Features.on?(:security)} class="max-w-[46ch] text-[13px]/5 text-muted">
            {gettext(
              "Every session runs behind a security wall, reaches only what you allow, never holds your keys, and leaves a full record. Open source, so you can check all of that."
            )}
          </p>
          <p :if={!Apiary.Features.on?(:security)} class="max-w-[46ch] text-[13px]/5 text-muted">
            {gettext(
              "Every session leaves a full record: what it ran, what it printed and where it reached out to. Open source, so you can check all of that."
            )}
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
        title={gettext("Connection lost.")}
        spinner
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting. Your changes are safe.")}
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong on our side.")}
        spinner
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting.")}
      </.flash>
    </div>
    """
  end

  @doc """
  The theme toggle: an icon-only button showing the theme on screen, opening
  the three-way menu (Auto, Light, Dark). In the auth header its tooltip opens
  to the left; in the top bar, below.
  """
  attr :tooltip, :string, default: "tooltip-left", values: ~w(tooltip-left tooltip-bottom)

  def theme_menu(assigns) do
    ~H"""
    <div
      id="theme-menu"
      class="theme-menu dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="theme-menu-button"
        type="button"
        class={["tooltip btn btn-ghost btn-square inline-flex", @tooltip]}
        data-tip={gettext("Theme")}
        aria-label={gettext("Theme")}
        aria-haspopup="menu"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-sun-micro" class="size-4 dark:hidden" />
        <.icon name="hero-moon-micro" class="hidden size-4 dark:inline-block" />
      </button>
      <ul
        class="menu menu-sm dropdown-content mt-1.5 w-40 min-w-0"
        role="menu"
        aria-label={gettext("Theme")}
      >
        <li
          :for={
            {theme, icon, label} <- [
              {"system", "hero-computer-desktop-micro", gettext("Auto")},
              {"light", "hero-sun-micro", gettext("Light")},
              {"dark", "hero-moon-micro", gettext("Dark")}
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
