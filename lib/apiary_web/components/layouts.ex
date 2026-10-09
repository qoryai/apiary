defmodule ApiaryWeb.Layouts do
  @moduledoc """
  Layouts: the application shell (`app/1`) for signed-in pages and the split
  view (`auth/1`) for log-in, registration, invitation and welcome pages. The
  product on every surface is Qory Apiary.

  The shell shows one scope at a time, the one the page belongs to: a workspace, an
  organisation or the person. The top bar says where the page is and switches it (the
  breadcrumb and its menus), searches and jumps (the palette), and holds New and the
  account menu; the sidebar holds that scope's pages and nothing else, a page of its
  settings included (`ApiaryWeb.SettingsComponents`). Qory Apiary itself, its mark,
  version, docs and source, is the menu at the sidebar's foot.
  """
  use ApiaryWeb, :html

  alias Apiary.Access
  alias ApiaryWeb.Nav.Entry

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # The sidebar's groups, in order: the scope's first entries without a heading, then each
  # group of a workspace with its heading, and the person's settings under theirs; an
  # edition's groups follow (`c:ApiaryWeb.Edition.nav_sections/0`). `:settings` (the pages
  # of the scope's Settings) and `:foot` (Settings itself) are not groups. The headings are
  # marked for extraction here and translated when the sidebar renders (`nav_text/1`), and
  # so is the name of the first group's navigation.
  @sections [
    home: nil,
    record: gettext_noop("Record"),
    guard: gettext_noop("Guard"),
    account: gettext_noop("Your settings")
  ]

  # How many pinned targets the sidebar lists.
  @pins 7

  @doc """
  nav_entries/1 is the navigation of `scope`'s pages, as `ApiaryWeb.Nav.Entry` values:
  the core's, then the edition's (`c:ApiaryWeb.Edition.nav_entries/1`), each after the
  core's of its section. Each names the action its page is for (`Apiary.Access`), nil for
  the entries every member has: the sidebar keeps the ones the reader may take, which
  leaves out those of a feature that is off, and a link of the breadcrumb's menus asks
  them where it leads (`switch_target/3`).
  A new entry of the core goes here, not in a page.
  """
  @spec nav_entries(Apiary.Accounts.Scope.t()) :: [Entry.t()]
  def nav_entries(scope), do: core_entries() ++ ApiaryWeb.Edition.nav_entries(scope)

  defp core_entries do
    [
      # A workspace's pages.
      %Entry{
        section: :home,
        key: :overview,
        label: gettext("Overview"),
        icon: "hero-squares-2x2",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}" end,
        action: :"run.read"
      },
      %Entry{
        section: :record,
        key: :runs,
        label: gettext("Runs"),
        icon: "hero-play-circle",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/runs" end,
        action: :"run.read"
      },
      %Entry{
        section: :record,
        key: :targets,
        label: gettext("Targets"),
        icon: "hero-folder",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/targets" end,
        action: :"run.read"
      },
      # The machines and pools the runs run on, each with its page.
      %Entry{
        section: :record,
        key: :nodes,
        label: gettext("Nodes"),
        icon: "hero-server",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/nodes" end,
        action: :"node.read"
      },
      # Guard: what the runs reached and what decided it, then the rules that decide. On an
      # instance without the security policy Network access is the group's one entry, the
      # record of it.
      %Entry{
        section: :guard,
        key: :network,
        label: gettext("Network access"),
        icon: "hero-globe-alt",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/network" end,
        action: :"run.read"
      },
      %Entry{
        section: :guard,
        key: :policy,
        label: gettext("Policy"),
        icon: "hero-shield-check",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/policy" end,
        action: :"security_policy.read"
      },
      %Entry{
        section: :foot,
        key: :settings,
        label: gettext("Workspace settings"),
        icon: "hero-cog-6-tooth",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/settings" end
      },
      # An organisation's pages.
      %Entry{
        section: :home,
        key: :organisation_overview,
        label: gettext("Overview"),
        icon: "hero-squares-2x2",
        path: fn organisation, _workspace -> ~p"/#{organisation}" end,
        place: :organisation
      },
      # The audit log is a record the organisation reads, not a setting: an entry of its
      # sidebar beside the overview.
      %Entry{
        section: :home,
        key: :audit_log,
        label: gettext("Audit log"),
        icon: "hero-clipboard-document-list",
        path: fn organisation, _workspace -> ~p"/#{organisation}/audit-log" end,
        place: :organisation,
        action: :"audit.read"
      },
      %Entry{
        section: :settings,
        key: :members,
        label: gettext("People"),
        icon: "hero-users",
        path: fn organisation, _workspace -> ~p"/#{organisation}/settings/people" end,
        place: :organisation,
        count: :members
      },
      %Entry{
        section: :foot,
        key: :organisation,
        label: gettext("Organisation settings"),
        icon: "hero-cog-6-tooth",
        path: fn organisation, _workspace -> ~p"/#{organisation}/settings" end,
        place: :organisation
      },
      # A person's own pages: their settings, one section a page, and their organisations,
      # under the heading Your settings, for a person has no other pages.
      %Entry{
        section: :account,
        key: :user_settings,
        label: gettext("Account"),
        icon: "hero-user-circle",
        path: ~p"/users/settings",
        place: :person
      },
      %Entry{
        section: :account,
        key: :user_preferences,
        label: gettext("Preferences"),
        icon: "hero-adjustments-horizontal",
        path: ~p"/users/settings/preferences",
        place: :person
      },
      %Entry{
        section: :account,
        key: :user_organisations,
        label: gettext("Organisations"),
        icon: "hero-building-office-2",
        path: ~p"/users/organisations",
        place: :person
      }
    ]
  end

  @doc """
  new_entries/2 is what New offers in `scope` at `place`, a workspace's page, an
  organisation's own or the person's, for the top bar's menu and the palette's actions, as
  `ApiaryWeb.Nav.Entry` values: the edition's first (`c:ApiaryWeb.Edition.new_entries/2`),
  then the core's: on a workspace's page a node, a node pool, and with the `secrets`
  feature an integration, a secret and a variable, and everywhere an invitation; of them,
  only what the reader may do there, each entry's action asked of the workspace or the
  organisation as its `place` says.
  """
  @spec new_entries(Apiary.Accounts.Scope.t(), :workspace | :organisation | :person) ::
          [Entry.t()]
  def new_entries(%{organisation: %{} = organisation, workspace: workspace} = scope, place) do
    workspace_entries =
      if place == :workspace && workspace do
        [
          %Entry{
            key: :node,
            label: gettext("New node"),
            icon: "hero-server",
            path: ~p"/#{organisation}/#{workspace}/nodes/new",
            action: :"node.create"
          },
          %Entry{
            key: :node_pool,
            label: gettext("New node pool"),
            icon: "hero-server-stack",
            path: ~p"/#{organisation}/#{workspace}/nodes/new-pool",
            action: :"node.create"
          }
        ] ++ secrets_entries(scope, organisation, workspace)
      else
        []
      end

    invite = %Entry{
      key: :invite,
      label: gettext("Invite people"),
      icon: "hero-user-plus",
      path: ~p"/#{organisation}/settings/people/invite",
      place: :organisation,
      action: :"member.invite"
    }

    for %Entry{} = entry <-
          ApiaryWeb.Edition.new_entries(scope, place) ++ workspace_entries ++ [invite],
        nav_open?(scope, entry.action, subject(entry, scope)),
        do: entry
  end

  def new_entries(_scope, _place), do: []

  # New's entries of the `secrets` feature, which ask `on?(scope, :secrets)`: an
  # integration, a secret and a variable.
  defp secrets_entries(scope, organisation, workspace) do
    if Apiary.Features.on?(scope, :secrets) do
      [
        # Add integration leads to the cards of Integrations that add one.
        %Entry{
          key: :integration,
          label: gettext("Add integration"),
          icon: "hero-puzzle-piece",
          path: ~p"/#{organisation}/#{workspace}/settings/integrations" <> "#add-part",
          action: :"connection.write"
        },
        %Entry{
          key: :secret,
          label: gettext("New secret"),
          icon: "hero-lock-closed",
          path: ~p"/#{organisation}/#{workspace}/settings/secrets/new",
          action: :"secret.write"
        },
        %Entry{
          key: :variable,
          label: gettext("New variable"),
          icon: "hero-variable",
          path: ~p"/#{organisation}/#{workspace}/settings/variables/new",
          action: :"variable.edit"
        }
      ]
    else
      []
    end
  end

  @doc """
  palette_entries/1 is where the palette's Go to leads in `scope`: every entry of the
  navigation the reader may open there, the workspace's, the organisation's and the
  person's, as `{entry, path}`. The pages of a scope's Settings come with it.
  """
  @spec palette_entries(Apiary.Accounts.Scope.t()) :: [{Entry.t(), String.t()}]
  def palette_entries(scope) do
    for %Entry{} = entry <- nav_entries(scope),
        shown?(entry, scope, nil),
        do: {entry, Entry.path(entry, scope.organisation, scope.workspace)}
  end

  @doc """
  instance_sections/1 is the Instance level's sections the scope's person may open, as
  `ApiaryWeb.Nav.Entry` values with `place: :instance`: the edition's
  (`c:ApiaryWeb.Edition.instance_sections/1`), then the core's Configuration, for an
  instance admin (`Apiary.Access.instance_admin?/1`). It reads the database, so it is read
  once with the navigation's counts (`ApiaryWeb.UserAuth.nav_counts/1`, as `:instance`),
  not on every render: the Qory Apiary menu's Instance settings leads to the first, and
  with two or more the Instance's pages list them as the second column.
  """
  @spec instance_sections(Apiary.Accounts.Scope.t() | nil) :: [Entry.t()]
  def instance_sections(%{user: %{}} = scope) do
    configuration =
      Access.instance_admin?(scope) &&
        %Entry{
          section: :instance,
          key: :configuration,
          label: gettext("Configuration"),
          icon: "hero-adjustments-vertical",
          path: ~p"/instance/configuration",
          place: :instance
        }

    for %Entry{} = entry <- ApiaryWeb.Edition.instance_sections(scope) ++ [configuration],
        do: %{entry | place: :instance, section: entry.section || :instance}
  end

  def instance_sections(_scope), do: []

  @doc """
  account_menu_entries/1 is what the account menu lists in `scope`, as
  `ApiaryWeb.Nav.Entry` values in their groups (`section`): `:account`, Settings (the
  person's own, under "Your personal account") and Your organisations, then the
  edition's (`c:ApiaryWeb.Edition.account_menu_entries/1`, `:account` where it names no
  group); `:instance`, after the theme and before Log out, the edition's alone. The
  Instance level is not the person's: its Instance settings is the Qory Apiary menu's
  (`instance_sections/1`). An entry's action, where it has one, is asked of the
  organisation.
  """
  @spec account_menu_entries(Apiary.Accounts.Scope.t() | nil) :: [Entry.t()]
  def account_menu_entries(scope) do
    organisation = scope_field(scope, :organisation)

    core = [
      %Entry{
        section: :account,
        key: :settings,
        label: gettext("Settings"),
        icon: "hero-user-circle",
        path: ~p"/users/settings",
        place: :person
      },
      %Entry{
        section: :account,
        key: :organisations,
        label: gettext("Your organisations"),
        icon: "hero-building-office-2",
        path: ~p"/users/organisations",
        place: :person
      }
    ]

    edition =
      for %Entry{} = entry <- ApiaryWeb.Edition.account_menu_entries(scope),
          do: %{entry | section: entry.section || :account}

    for %Entry{} = entry <- core ++ edition,
        is_nil(entry.action) or (organisation && nav_open?(scope, entry.action, organisation)),
        do: entry
  end

  @doc """
  narrowed/2 is the value of `app/1`'s `narrowed` for a list narrowed to `target`, as the
  list's filters parsed it (`{system, path}`, `{nil, path}` for the path on every system),
  given the paths shared by two systems of the workspace (`Apiary.Runs.shared_paths/2`, or
  whether this one is): the system is carried only where the path is shared. Nil for no
  target, or `:none`.
  """
  @spec narrowed(term, MapSet.t() | boolean) :: map | nil
  def narrowed({system, path}, shared) when is_binary(path) do
    shared? = if is_boolean(shared), do: shared, else: MapSet.member?(shared, path)
    %{system: system, path: path, shared: shared? and is_binary(system)}
  end

  def narrowed(_target, _shared), do: nil

  @doc """
  The application shell: a 48 px top bar across the window, then the sidebar of the
  page's scope beside the main column.

  The top bar holds, from the left, the breadcrumb (the organisation, the workspace and
  whatever the page adds in its `crumb` slots), whose chevrons open the organisation
  menu and the workspace menu; then
  Search or jump to (the palette), New and the account menu. The sidebar holds the pages
  of the page's scope, which the entry it passes as `nav` belongs to
  (`ApiaryWeb.Nav.Entry`'s `place`): a workspace's, an organisation's or the person's,
  whose pages are their settings. At its foot are the scope's settings, named after the
  level (Workspace settings, Organisation settings), the current entry on every page of
  them, then the Qory Apiary menu, which leads first to Instance settings for whoever may
  open a section of the Instance level, and the control that folds the sidebar to icons,
  from 768 px; below that it is a drawer behind the bar's menu button, whose head opens
  the organisation menu and the workspace menu, as a phone's bar names the page alone. A
  page without a person has no sidebar, and the Qory Apiary menu opens from the bar.

  An organisation's page, one with a navigation item (`nav`) of a workspace or an
  organisation, opens with the edition's notices (the `:notices` slot,
  `ApiaryWeb.Extension`): the page beneath says the rest. A person's own pages carry none.

  **Two levels.** The sidebar is the level's, a workspace's or an organisation's, on every
  page of the level, its settings included. A page of a level's settings, of Your settings
  or of the Instance opens the level's sections as a second column beside it (`sections`,
  `section`): from 1024 px a column under a heading that names the level and, beneath it,
  the place ("Workspace settings", Main); below it, at every width, that heading is a
  button under the top bar that opens the same links in place (`#settings-disclosure`).
  A level with a single section gets none. The level leaves the page: a settings page's h1
  is its section, and the frame writes the breadcrumb's level and section segments, so the
  page's `crumb` slots hold only what follows the section. A person's own page and an
  Instance page keep the sidebar the person came from, the workspace the session
  remembers; with no workspace, the person's sidebar is their sections alone, as one
  column. `aria-current="page"` marks the exact page's entry alone; its parents carry
  `aria-current="true"`: the level's settings at the sidebar's foot while the second column
  lists its sections, and the column's section on a page under it, one that adds `crumb`
  segments or passes `section_current="true"`.

  **Narrowing.** On Runs or Network access narrowed to a target (`narrowed`), both entries
  of the sidebar carry the target to the other list; nothing else does.

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:runs}>
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
      "the places the user reaches, for the breadcrumb's menus: their memberships and whatever else the edition lets them reach (`Apiary.Organisations.list_places/1`), with the workspaces of each"

  attr :nav, :atom, default: nil, doc: "the active navigation item"

  attr :place, :atom,
    default: nil,
    values: [nil, :workspace, :organisation, :person, :instance],
    doc:
      "the scope a page that no navigation entry names belongs to (`nav` nil): its sidebar is that scope's, with no entry current. A page of the Instance level passes `:instance`: its sidebar is the one the person came from, and its sections are the second column"

  attr :notices, :boolean,
    default: nil,
    doc:
      "whether the organisation's notices show, the edition's (the `:notices` slot): on every page of a workspace or an organisation, which passes `nav` or `place`, unless given; a person's own pages show none"

  attr :counts, :map,
    default: nil,
    doc:
      "%{members: members, alive: runs alive now, mode: the policy's default mode, own_modes: the modes targets set, pins: the pinned targets, `%{id, system, path, shared}` (`Apiary.Targets.list_pins/2`)}"

  attr :width, :string,
    default: "list",
    values: ~w(list work read),
    doc:
      "list: fluid up to 1680 px; work: fluid, no cap, for a work surface or a list with a rail or a preview beside it; read: a 720 px column, for forms and prose. Every width starts at the same left edge"

  attr :target, :string,
    default: nil,
    doc:
      "the id of the target the page is about: its entry under Pinned, when it is pinned, is the current one"

  attr :sections, :list,
    default: nil,
    doc:
      "the sections of the level's settings the page is one of, as `ApiaryWeb.Nav.Entry` values in their order (`SettingsComponents.sections/2`, read when the page mounts): with two or more they open as the second column beside the sidebar, `section` current. A person's own pages and the Instance's need not pass theirs: the frame has them"

  attr :section, :atom,
    default: nil,
    doc:
      "the key of the page's own section in the second column; on a person's own page `nav` serves"

  attr :section_path, :string,
    default: nil,
    doc:
      "on a page under a section of a level's settings (one that adds `crumb` segments), where the breadcrumb's section segment leads: the section's own path unless given, such as a tab of it"

  attr :section_current, :string,
    default: nil,
    values: [nil, "page", "true"],
    doc:
      "how the second column marks the page's section: `\"page\"` where the page is the section's own, `\"true\"` where it is under it; unless given, `\"true\"` on a page that adds `crumb` segments and `\"page\"` on one that adds none, a tab of the section included"

  attr :narrowed, :map,
    default: nil,
    doc:
      "on Runs and Network access narrowed to one target, that target, `%{system, path, shared}` (`narrowed/2`): the sidebar's Runs and Network access carry it, its path and, only where the path is shared, its system. Nil everywhere else"

  slot :crumb,
    doc: "the breadcrumb's segments after the workspace: a target, a record; the last is the page" do
    attr :navigate, :string, doc: "where the segment leads; none for the page itself"

    attr :patch, :string,
      doc:
        "where the segment leads within the page's own LiveView, as its tabs do; in place of `navigate`"
  end

  slot :inner_block, required: true

  def app(assigns) do
    scope = assigns.current_scope
    user = scope_field(scope, :user)
    organisation = scope_field(scope, :organisation)
    workspace = scope_field(scope, :workspace)
    entries = if user, do: nav_entries(scope), else: []
    current = Enum.find(entries, &(&1.key == assigns.nav))
    place = place(current, assigns.place, organisation)
    # The sidebar's level: the page's own, or, for a person's own page and an Instance
    # page, the one the person came from.
    level = level(place, organisation, workspace)
    instance = if user, do: instance_list(assigns.counts), else: []
    # Where the Qory Apiary menu's Instance settings leads: the first section of the
    # Instance level the person may open; nil, and no entry, for anyone else.
    instance_path = instance_path(instance, organisation, workspace)

    assigns =
      assigns
      |> assign(:scope, scope)
      |> assign(:user, user)
      |> assign(:organisation, organisation)
      |> assign(:workspace, workspace)
      |> assign(:place, place)
      |> assign(:level, level)
      |> assign(:nav_entries, entries)
      |> assign(:instance, instance)
      |> assign(:instance_path, instance_path)
      |> assign(
        :groups,
        nav_groups(scope, level, assigns.counts, entries, carry(assigns.narrowed, assigns.nav))
      )
      |> assign(:foot, foot(scope, level, entries))
      |> assign(:settings_page, settings_page?(current))
      |> assign(:second, second_column(scope, place, level, entries, instance, assigns))

    assigns =
      assign(
        assigns,
        :trail,
        settings_trail(assigns.foot, assigns.second, assigns.settings_page, assigns)
      )
      |> assign(
        :pins,
        if(level == :workspace, do: pins(assigns.counts, organisation, workspace), else: [])
      )
      |> assign(:show_notices, notices?(assigns.notices, current, assigns.place))
      |> assign(
        :menus,
        if(user, do: menus(scope, assigns.memberships, organisation, workspace, place))
      )

    ~H"""
    <a
      id="skip-to-content"
      href="#main"
      phx-mounted={JS.ignore_attributes(["inert"])}
      class="btn btn-sm sr-only focus:not-sr-only focus:fixed focus:left-3 focus:top-3 focus:z-[70]"
    >
      {gettext("Skip to content")}
    </a>

    <div id="shell" class="min-h-dvh min-w-0 bg-base-100" phx-hook="NavDrawer">
      <.top_bar
        scope={@scope}
        user={@user}
        organisation={@organisation}
        workspace={@workspace}
        memberships={@memberships}
        place={@place}
        nav={@nav}
        nav_entries={@nav_entries}
        crumb={@crumb}
        trail={@trail}
        sidebar={@user != nil}
        instance={@instance}
        instance_path={@instance_path}
        section={@section}
        second={@second}
        menus={@menus}
      />

      <div :if={@user} class="drawer md:drawer-open">
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
          <.sidebar
            place={@level}
            nav={@nav}
            groups={@groups}
            foot={@foot}
            settings_page={@settings_page}
            pins={@pins}
            target={@target}
            counts={@counts}
            second={@second}
            instance_path={@instance_path}
            organisation={@organisation}
            menus={@menus}
          />
        </div>

        <div
          id="shell-content"
          class={[
            "drawer-content flex min-h-[calc(100dvh-3rem)] min-w-0 flex-col",
            @second && "q-has-second"
          ]}
          phx-mounted={JS.ignore_attributes(["inert"])}
        >
          <.second_column :if={@second} second={@second} counts={@counts} />
          <.content width={@width}>
            <%!-- The notices sit above the page's title, which takes the focus on a live
               navigation: the script describes the title by them (`#shell-notices`), so
               a screen reader reads them. No box of its own: the page's grid is theirs. --%>
            <div :if={@show_notices} id="shell-notices" class="contents">
              <.notices scope={@scope} organisation={@organisation} counts={@counts} />
            </div>
            {render_slot(@inner_block)}
          </.content>
        </div>
      </div>

      <div :if={!@user} id="shell-content" class="flex min-w-0 flex-col">
        <.content width={@width}>{render_slot(@inner_block)}</.content>
      </div>

      <%!-- The palette asks the sidebar's level: on a person's own page or an Instance
           page shown with a workspace's sidebar, that workspace, as the frame shows. --%>
      <.palette :if={@organisation} scope={@scope} place={@level} />
    </div>

    <%!-- One announcer for the copies of a page's many rows, which have none of their own. --%>
    <p id="copy-announcer" class="sr-only" role="status" phx-update="ignore"></p>
    <.flash_group flash={@flash} />
    """
  end

  # Whether the page is one of its scope's Settings: Settings itself, or a page of it
  # (an entry of the section `:settings`, such as People).
  defp settings_page?(%Entry{section: section}), do: section in [:foot, :settings]
  defp settings_page?(nil), do: false

  # The breadcrumb's segments of a page of a level's settings, which the frame writes: the
  # level ("Workspace settings", the sidebar's foot), leading to its General, then the
  # page's section, the page itself or, on a page that adds `crumb` segments, a link to the
  # section (`section_path`, else the section's own path). Nil on any other page.
  defp settings_trail({%Entry{} = entry, path}, second, true, assigns) do
    section =
      case second && Enum.find(second.entries, fn {e, _path} -> e.key == second.current end) do
        {%Entry{label: label}, section_path} ->
          %{label: label, path: assigns.section_path || section_path}

        nil ->
          nil
      end

    %{label: entry.label, path: path, section: section}
  end

  defp settings_trail(_foot, _second, _settings_page, _assigns), do: nil

  # The scope the page belongs to: its entry's; without one the place the page names, else
  # the organisation's when the page has an organisation and the person's when it has
  # none.
  defp place(%Entry{place: place}, _given, _organisation), do: place
  defp place(nil, given, _organisation) when not is_nil(given), do: given
  defp place(nil, nil, %{}), do: :organisation
  defp place(nil, nil, nil), do: :person

  # The sidebar of a person's own page and of an Instance page: the workspace the session
  # remembers, as the person came from; with no workspace, the person's own, their
  # sections alone.
  defp level(place, _organisation, %{}) when place in [:person, :instance], do: :workspace
  defp level(place, _organisation, nil) when place in [:person, :instance], do: :person
  defp level(place, _organisation, _workspace), do: place

  # The Instance's sections the counts carry (`instance_sections/1`, read with them).
  defp instance_list(%{instance: [_ | _] = sections}), do: sections
  defp instance_list(_counts), do: []

  defp instance_path([%Entry{} = first | _], organisation, workspace),
    do: Entry.path(first, organisation, workspace)

  defp instance_path([], _organisation, _workspace), do: nil

  # The second column: the sections of the level's settings the page passed, a person's
  # own sections beside the sidebar they came from, or the Instance's; none for fewer than
  # two. Each kind keeps the DOM ids its list had before the column: `settings-tabs` and
  # `settings-tab-<key>`, `nav-group-account` and `nav-<key>`.
  defp second_column(scope, place, level, entries, instance, assigns) do
    {kind, list} =
      cond do
        place == :person and level != :person ->
          {:person,
           assigns.sections ||
             for(
               %Entry{place: :person, section: :account} = entry <- entries,
               shown?(entry, scope, assigns.counts),
               do: entry
             )}

        place == :instance ->
          {:instance, assigns.sections || instance}

        is_list(assigns.sections) ->
          {:settings, assigns.sections}

        true ->
          {nil, []}
      end

    if match?([_, _ | _], list) do
      organisation = scope_field(scope, :organisation)
      workspace = scope_field(scope, :workspace)

      %{
        kind: kind,
        label: second_label(kind, place),
        place_name: second_place(kind, place, organisation, workspace),
        id: second_id(kind),
        current: assigns.section || assigns.nav,
        # The current section is the page, or, on a page under it that adds its own
        # segments to the breadcrumb (Invite people, Edit secret), the page's parent.
        aria_current:
          assigns.section_current || if(assigns.crumb == [], do: "page", else: "true"),
        entries: for(entry <- list, do: {entry, Entry.path(entry, organisation, workspace)})
      }
    end
  end

  # The second column's heading, which names its navigation: the level's settings.
  defp second_label(:settings, :organisation), do: gettext("Organisation settings")
  defp second_label(:settings, _workspace), do: gettext("Workspace settings")
  defp second_label(:person, _place), do: gettext("Your settings")
  defp second_label(:instance, _place), do: gettext("Instance settings")

  # The place whose settings they are, beneath the heading: the workspace's name, or the
  # organisation's; none for a person's own and the Instance's.
  defp second_place(:settings, :organisation, %{name: name}, _workspace), do: name
  defp second_place(:settings, _place, _organisation, %{name: name}), do: name
  defp second_place(_kind, _place, _organisation, _workspace), do: nil

  defp second_id(:settings), do: "settings-tabs"
  defp second_id(:person), do: "nav-group-account"
  defp second_id(:instance), do: "instance-tabs"

  defp second_link_id(:settings, key), do: "settings-tab-#{key}"
  defp second_link_id(:person, key), do: "nav-#{key}"
  defp second_link_id(:instance, key), do: "instance-tab-#{key}"

  # What the sidebar's Runs and Network access carry on a list narrowed to a target: that
  # target, on Runs and on Network access alone; nothing anywhere else.
  defp carry(%{path: path} = narrowed, nav) when nav in [:runs, :network] and is_binary(path),
    do: narrowed

  defp carry(_narrowed, _nav), do: nil

  # The target's name as the lists write it: its path, its system before it where the path
  # is shared.
  defp narrowed_name(%{shared: true, system: system, path: path}) when is_binary(system),
    do: "#{system}/#{path}"

  defp narrowed_name(%{path: path}), do: path

  # The list's path with the target's parameters, written as the lists write them
  # (`Apiary.Runs.Filters.target_params/2`): the path, and the system only where the path
  # is shared.
  defp carried_path(path, %{system: system, path: target_path, shared: shared}) do
    params = Apiary.Runs.Filters.target_params(if(shared, do: system), target_path)
    path <> "?" <> Plug.Conn.Query.encode(params)
  end

  defp carried_label(:runs, name), do: gettext("Runs, narrowed to %{name}", name: name)

  defp carried_label(:network, name),
    do: gettext("Network access, narrowed to %{name}", name: name)

  defp notices?(notices, _current, _place) when is_boolean(notices), do: notices
  defp notices?(nil, %Entry{place: place}, _place), do: place in [:workspace, :organisation]
  defp notices?(nil, nil, given), do: given in [:workspace, :organisation]

  # The bar: 48 px, across the window, above the sidebar. Its left says where the page is,
  # the organisation first, its right what the person may do from anywhere. Without a
  # sidebar, for a page without a person, the Qory Apiary menu opens from its left.
  attr :scope, :any, required: true
  attr :user, :any, required: true
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :memberships, :list, required: true
  attr :place, :atom, required: true
  attr :nav, :atom, required: true
  attr :nav_entries, :list, required: true
  attr :crumb, :list, required: true
  attr :trail, :map, required: true
  attr :sidebar, :boolean, required: true
  attr :instance, :list, required: true
  attr :instance_path, :string, required: true
  attr :section, :atom, required: true
  attr :second, :map, required: true
  attr :menus, :map, default: nil

  defp top_bar(assigns) do
    # An Instance page offers what a person's own page does.
    new_place = if assigns.place == :instance, do: :person, else: assigns.place

    assigns =
      assigns
      |> assign(:new_entries, new_entries(assigns.scope, new_place))
      |> assign(:account_entries, account_menu_entries(assigns.scope))

    ~H"""
    <header
      id="top-bar"
      aria-label={gettext("Top bar")}
      class="q-topbar"
      phx-mounted={JS.ignore_attributes(["inert"])}
    >
      <button
        :if={@sidebar}
        id="nav-drawer-open"
        type="button"
        data-drawer-open
        class="btn btn-ghost btn-square btn-sm md:hidden"
        aria-label={gettext("Open menu")}
        aria-controls="sidebar"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-bars-3" class="size-5" />
      </button>
      <.brand_menu
        :if={!@sidebar}
        version={version()}
        direction="down"
        instance_path={@instance_path}
      />

      <.breadcrumb
        :if={@user}
        scope={@scope}
        organisation={@organisation}
        workspace={@workspace}
        memberships={@memberships}
        place={@place}
        nav={@nav}
        nav_entries={@nav_entries}
        crumb={@crumb}
        trail={@trail}
        instance={@instance}
        here={@section || @nav}
        second={@second}
        menus={@menus}
      />

      <div class="flex-1"></div>

      <div class="flex flex-none items-center gap-1.5 md:gap-2">
        <button
          :if={@organisation}
          id="palette-open"
          type="button"
          class="q-jump"
          data-palette-open
          aria-haspopup="dialog"
          aria-controls="palette"
          aria-keyshortcuts="Meta+K Control+K /"
          aria-label={gettext("Search or jump to")}
        >
          <.icon name="hero-magnifying-glass" class="size-4 flex-none" />
          <span class="q-jump-text">{gettext("Search or jump to…")}</span>
          <kbd class="q-jump-kbd" aria-hidden="true">⌘K</kbd>
        </button>
        <.new_menu :if={@new_entries != []} entries={@new_entries} />
        <.account_menu
          :if={@user}
          user={@user}
          organisation={@organisation}
          scope={@scope}
          entries={@account_entries}
        />
      </div>
    </header>
    """
  end

  # Where the page is: the organisation and the workspace, each a link to its home, and
  # the page's own segments. On a page of an organisation's or a workspace's settings the
  # frame writes the level ("Workspace settings", leading to its General) and the section
  # before them (`settings_trail/4`), and the page adds only what follows the section.
  # The chevron beside the organisation opens the organisation menu, with more than one
  # place to go or an edition's entry after the places; the one beside the workspace opens
  # the workspace menu, with another workspace of the organisation to go to or an
  # edition's entry for it (`menus/5`). A phone's bar names the page alone, so there the
  # drawer's head opens the two menus (`drawer_place/1`). A person's own page names itself.
  attr :scope, :any, required: true
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :memberships, :list, required: true
  attr :place, :atom, required: true
  attr :nav, :atom, required: true
  attr :nav_entries, :list, required: true
  attr :crumb, :list, required: true
  attr :trail, :map, default: nil
  attr :instance, :list, default: []
  attr :here, :atom, default: nil
  attr :second, :map, default: nil
  attr :menus, :map, default: nil

  defp breadcrumb(%{place: :person} = assigns) do
    assigns =
      assign(
        assigns,
        :here,
        Enum.find(assigns.nav_entries, &(&1.place == :person and &1.key == assigns.nav))
      )

    ~H"""
    <nav id="breadcrumb" aria-label={gettext("Where you are")} class="q-trail-nav">
      <ol class="q-trail">
        <li class={["q-trail-item", (@here || @crumb != []) && "q-trail-lead"]}>
          <.link navigate={~p"/users/settings"} class="q-trail-link">
            <span class="truncate">{gettext("Your settings")}</span>
          </.link>
        </li>
        <li
          :if={@here}
          class={["q-trail-item", @crumb != [] && "q-trail-lead", up?(@crumb) && "q-trail-up"]}
        >
          <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
          <.link
            :if={@crumb != []}
            navigate={Entry.path(@here, @organisation, @workspace)}
            class="q-trail-link"
          >
            <.trail_back :if={up?(@crumb)} /><span class="truncate">{@here.label}</span>
          </.link>
          <span :if={@crumb == []} class="q-trail-link q-trail-page" aria-current="page">
            <span class="truncate">{@here.label}</span>
          </span>
        </li>
        <.crumbs crumb={@crumb} />
      </ol>
    </nav>
    """
  end

  # An Instance page: Instance settings, leading to its first section, then the section
  # and what the page adds. With one section, and so no second column whose disclosure
  # names the level on a phone, a phone's bar keeps Instance settings before the section.
  defp breadcrumb(%{place: :instance} = assigns) do
    assigns =
      assigns
      |> assign(:first, List.first(assigns.instance))
      |> assign(:here, Enum.find(assigns.instance, &(&1.key == assigns.here)))
      |> assign(:keep, is_nil(assigns.second) and assigns.crumb == [])

    ~H"""
    <nav id="breadcrumb" aria-label={gettext("Where you are")} class="q-trail-nav">
      <ol class="q-trail">
        <li class={["q-trail-item", (@here || @crumb != []) && !@keep && "q-trail-lead"]}>
          <.link
            :if={@first}
            navigate={Entry.path(@first, @organisation, @workspace)}
            class="q-trail-link"
          >
            <span class="truncate">{gettext("Instance settings")}</span>
          </.link>
          <span :if={!@first} class="q-trail-link q-trail-page">
            <span class="truncate">{gettext("Instance settings")}</span>
          </span>
        </li>
        <li
          :if={@here}
          class={["q-trail-item", @crumb != [] && "q-trail-lead", up?(@crumb) && "q-trail-up"]}
        >
          <span class={["q-trail-sep", !@keep && "max-md:hidden"]} aria-hidden="true">/</span>
          <.link
            :if={@crumb != []}
            navigate={Entry.path(@here, @organisation, @workspace)}
            class="q-trail-link"
          >
            <.trail_back :if={up?(@crumb)} /><span class="truncate">{@here.label}</span>
          </.link>
          <span :if={@crumb == []} class="q-trail-link q-trail-page" aria-current="page">
            <span class="truncate">{@here.label}</span>
          </span>
        </li>
        <.crumbs crumb={@crumb} />
      </ol>
    </nav>
    """
  end

  defp breadcrumb(%{organisation: nil} = assigns) do
    ~H"""
    <nav id="breadcrumb" aria-label={gettext("Where you are")} class="q-trail-nav"></nav>
    """
  end

  defp breadcrumb(assigns) do
    %{organisation_menu?: organisation_menu?, workspace_menu?: workspace_menu?} =
      menus = assigns.menus

    assigns =
      assigns
      |> assign(menus)
      |> assign(:menus?, organisation_menu? or workspace_menu?)
      |> assign(:after_place, assigns.trail != nil or assigns.crumb != [])

    ~H"""
    <nav id="breadcrumb" aria-label={gettext("Where you are")} class="q-trail-nav">
      <div
        id={if @menus?, do: "breadcrumb-menus", else: "organisation-block"}
        class="contents"
        phx-hook={@menus? && "Switcher"}
        data-page-base={@menus? && @workspace && ~p"/#{@organisation}/#{@workspace}"}
      >
        <ol class="q-trail">
          <li class={[
            "q-trail-item",
            (@workspace || @after_place) && "q-trail-lead"
          ]}>
            <.link
              navigate={~p"/#{@organisation}"}
              class="q-trail-link"
              title={@organisation.name}
            >
              <.avatar name={@organisation.name} kind="organisation" size="xs" />
              <span class="truncate">{@organisation.name}</span>
            </.link>
            <.switcher_button
              :if={@organisation_menu?}
              id="organisation-menu-button"
              controls="organisation-menu"
              label={gettext("Switch organisation, current: %{name}", name: @organisation.name)}
            />
          </li>
          <li
            :if={@workspace}
            class={["q-trail-item", @after_place && "q-trail-lead"]}
          >
            <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
            <.link
              navigate={~p"/#{@organisation}/#{@workspace}"}
              class="q-trail-link"
              title={@workspace.name}
            >
              <span class="truncate">{@workspace.name}</span>
            </.link>
            <.switcher_button
              :if={@workspace_menu?}
              id="workspace-menu-button"
              controls="workspace-menu"
              label={gettext("Switch workspace, current: %{name}", name: @workspace.name)}
            />
          </li>
          <.settings_crumbs :if={@trail} trail={@trail} crumb={@crumb} />
          <.crumbs crumb={@crumb} />
        </ol>

        <.organisation_menu
          :if={@organisation_menu?}
          organisation={@organisation}
          workspace={@workspace}
          places={@places}
          nav={@nav}
          switcher_entries={@switcher_entries}
        />
        <.workspace_menu
          :if={@workspace_menu?}
          organisation={@organisation}
          workspace={@workspace}
          workspaces={@workspaces}
          nav={@nav}
          entries={@workspace_entries}
        />
      </div>
    </nav>
    """
  end

  # The level's segments of a page of its settings (`settings_trail/4`): the level, a link
  # to its General, then the section, the page itself unless the page adds segments after
  # it.
  attr :trail, :map, required: true
  attr :crumb, :list, required: true

  defp settings_crumbs(assigns) do
    assigns = assign(assigns, :last, if(assigns.trail.section, do: :section, else: :level))

    ~H"""
    <li class={[
      "q-trail-item",
      (@last == :section || @crumb != []) && "q-trail-lead",
      @last == :level && up?(@crumb) && "q-trail-up"
    ]}>
      <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
      <.link
        :if={@last == :section || @crumb != []}
        id="breadcrumb-settings"
        navigate={@trail.path}
        class="q-trail-link"
      >
        <.trail_back :if={@last == :level && up?(@crumb)} /><span class="truncate">{@trail.label}</span>
      </.link>
      <span
        :if={@last == :level && @crumb == []}
        id="breadcrumb-settings"
        class="q-trail-link q-trail-page"
        aria-current="page"
      >
        <span class="truncate">{@trail.label}</span>
      </span>
    </li>
    <li
      :if={@trail.section}
      class={["q-trail-item", @crumb != [] && "q-trail-lead", up?(@crumb) && "q-trail-up"]}
    >
      <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
      <.link
        :if={@crumb != []}
        id="breadcrumb-section"
        navigate={@trail.section.path}
        class="q-trail-link"
      >
        <.trail_back :if={up?(@crumb)} /><span class="truncate">{@trail.section.label}</span>
      </.link>
      <span
        :if={@crumb == []}
        id="breadcrumb-section"
        class="q-trail-link q-trail-page"
        aria-current="page"
      >
        <span class="truncate">{@trail.section.label}</span>
      </span>
    </li>
    """
  end

  # The page's own segments of the breadcrumb, after where the page is: each a link but
  # the page itself, the last, which is current. The one before the last, when it is a
  # link, is the page's parent, which a phone's bar keeps (`up?/1`).
  attr :crumb, :list, required: true

  defp crumbs(assigns) do
    ~H"""
    <li
      :for={{crumb, i} <- Enum.with_index(@crumb)}
      class={[
        "q-trail-item",
        i < length(@crumb) - 1 && "q-trail-lead",
        i == length(@crumb) - 2 && link?(crumb) && "q-trail-up"
      ]}
    >
      <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
      <.link
        :if={link?(crumb)}
        navigate={crumb[:navigate]}
        patch={crumb[:patch]}
        class="q-trail-link"
      >
        <.trail_back :if={i == length(@crumb) - 2} /><span class="truncate">{render_slot(crumb)}</span>
      </.link>
      <span
        :if={!link?(crumb)}
        class="q-trail-link q-trail-page"
        aria-current={i == length(@crumb) - 1 && "page"}
      >
        <span class="truncate">{render_slot(crumb)}</span>
      </span>
    </li>
    """
  end

  defp link?(crumb), do: is_binary(crumb[:navigate]) or is_binary(crumb[:patch])

  # Whether the segment before the page's one segment, where the frame writes it (the
  # section of a level's settings, of Your settings, of the Instance), is the page's
  # parent: a phone's bar names the parent, a link back, before the page; on a section's
  # own page, which adds no segment, the bar names the page alone.
  defp up?(crumb), do: length(crumb) == 1

  # The parent's mark on a phone, before its words; hidden from the wider bar.
  defp trail_back(assigns) do
    ~H"""
    <.icon name="hero-chevron-left-micro" class="q-trail-back" />
    """
  end

  attr :id, :string, required: true
  attr :controls, :string, required: true
  attr :label, :string, required: true

  defp switcher_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="q-trail-chev"
      data-switcher-open
      aria-expanded="false"
      aria-controls={@controls}
      aria-label={@label}
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
    >
      <.icon name="hero-chevron-up-down-micro" class="size-4" />
    </button>
    """
  end

  # The organisation menu, two panels under a search. On the left the organisations the
  # person reaches, by name: their own first, then the places of the edition's groups
  # (`c:ApiaryWeb.Edition.place_group/1`) under their own headings, each folded behind its
  # heading and its count unless the page's organisation is in it, and opened by a search
  # that finds a place in it. Each is a link to the organisation, which lands in the
  # workspace the person last used there (`switch_organisation_path/2`), and a `›` button
  # that shows its workspaces. On the right the workspaces of the organisation pointed at,
  # by name, each a link to that workspace (`switch_workspace_path/3`); the `Switcher`
  # hook points at the page's organisation when the menu opens, then at the one under the
  # pointer or with focus. Every place is in the markup. A link loads the page afresh, so
  # the session remembers the workspace for `/`. Last, Your organisations and the
  # edition's entries (`ApiaryWeb.Edition.switcher_entries/1`), such as New organisation.
  # An id made of slugs, which hold only a-z, 0-9 and hyphens, has its fixed words before
  # the slug, never after, and joins an organisation's slug to a workspace's with `_`, so
  # no two are the same (`switch-acme_prod` is never `switch-acme-prod`'s).
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :places, :list, required: true
  attr :nav, :atom, required: true
  attr :switcher_entries, :list, required: true

  defp organisation_menu(assigns) do
    groups = place_groups(assigns.places)

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:listed, Enum.flat_map(groups, &elem(&1, 1)))

    ~H"""
    <div
      id="organisation-menu"
      class="q-switcher q-switcher-two"
      role="group"
      aria-label={gettext("Switch organisation")}
      hidden
      phx-mounted={JS.ignore_attributes(["hidden", "data-view"])}
    >
      <div class="q-switcher-search">
        <.icon name="hero-magnifying-glass" class="size-4 flex-none text-faint" />
        <input
          id="organisation-menu-search"
          type="text"
          autocomplete="off"
          spellcheck="false"
          aria-label={gettext("Find an organisation or workspace")}
          aria-controls="organisation-menu-places"
          placeholder={gettext("Find an organisation or workspace…")}
        />
      </div>
      <div class="q-switcher-cols">
        <div id="organisation-menu-places" class="q-switcher-list q-switcher-main" data-panel>
          <section
            :for={{{heading, places}, g} <- Enum.with_index(@groups)}
            class="q-switcher-group"
            data-group
          >
            <h3 id={"organisation-menu-group-#{g}"} class="q-switcher-heading">
              <%= if heading do %>
                <button
                  type="button"
                  class="q-switcher-fold"
                  aria-expanded={to_string(group_open?(places, @organisation))}
                  aria-controls={"organisation-menu-group-#{g}-places"}
                  phx-mounted={JS.ignore_attributes(["aria-expanded"])}
                  data-fold
                >
                  <.icon name="hero-chevron-right-micro" class="q-switcher-fold-i size-3.5" />
                  <span class="truncate">{heading}</span>
                  <span class="q-switcher-n">{Format.number(length(places))}</span>
                </button>
              <% else %>
                {gettext("Your organisations")}
              <% end %>
            </h3>
            <ul
              id={"organisation-menu-group-#{g}-places"}
              aria-labelledby={"organisation-menu-group-#{g}"}
              hidden={heading && !group_open?(places, @organisation)}
              phx-mounted={JS.ignore_attributes(["hidden"])}
              data-fold-list={heading && "true"}
            >
              <li
                :for={{place, _workspaces} <- places}
                class="q-switcher-org"
                data-org={place.organisation.slug}
                data-search={search_text([place.organisation.name, place.organisation.slug])}
              >
                <.link
                  id={"switch-#{place.organisation.slug}"}
                  href={switch_organisation_path(@nav, place.organisation)}
                  class="q-switcher-place"
                  aria-current={current_organisation?(place, @organisation) && "true"}
                  data-switch
                >
                  <.avatar name={place.organisation.name} kind="organisation" size="xs" />
                  <span class="truncate">{place.organisation.name}</span>
                  <.icon
                    :if={current_organisation?(place, @organisation)}
                    name="hero-check-micro"
                    class="ml-auto size-4 flex-none text-accent"
                  />
                </.link>
                <button
                  type="button"
                  class="q-switcher-more"
                  aria-label={
                    gettext("Show the workspaces of %{name}", name: place.organisation.name)
                  }
                  aria-controls="organisation-menu-workspaces"
                  aria-expanded={to_string(current_organisation?(place, @organisation))}
                  phx-mounted={JS.ignore_attributes(["aria-expanded"])}
                  data-show
                >
                  <.icon name="hero-chevron-right-micro" class="size-4" />
                </button>
              </li>
            </ul>
          </section>
          <p id="organisation-menu-empty" class="q-switcher-empty" hidden>
            {gettext("No organisation or workspace matches.")}
          </p>
          <%!-- What the search left, said by the Switcher hook in these words. --%>
          <p
            id="organisation-menu-status"
            role="status"
            class="sr-only"
            data-none={gettext("No organisation or workspace matches.")}
            data-one={gettext("1 organisation matches.")}
            data-other={gettext("%{count} organisations match.", count: "%{count}")}
          >
          </p>
        </div>
        <div id="organisation-menu-workspaces" class="q-switcher-list q-switcher-side" data-panel>
          <%!-- A phone shows one panel at a time: this one leads back to the other. --%>
          <button type="button" class="q-switcher-place q-switcher-back" data-back>
            <.icon name="hero-chevron-left-micro" class="size-4 text-faint" />
            {gettext("Organisations")}
          </button>
          <section
            :for={{place, workspaces} <- @listed}
            id={"organisation-menu-of-#{place.organisation.slug}"}
            data-workspaces={place.organisation.slug}
            hidden={!current_organisation?(place, @organisation)}
            phx-mounted={JS.ignore_attributes(["hidden"])}
          >
            <h3
              id={"organisation-menu-heading-#{place.organisation.slug}"}
              class="q-switcher-heading"
            >
              {gettext("Workspaces of %{name}", name: place.organisation.name)}
            </h3>
            <ul aria-labelledby={"organisation-menu-heading-#{place.organisation.slug}"}>
              <li :for={w <- workspaces}>
                <.link
                  :if={w}
                  id={"switch-#{place.organisation.slug}_#{w.slug}"}
                  href={switch_workspace_path(@nav, place.organisation, w)}
                  class="q-switcher-place"
                  aria-current={current_workspace?(w, @workspace) && "true"}
                  data-switch
                  data-search={search_text([w.name, w.slug])}
                >
                  <span class="truncate">{w.name}</span>
                  <.icon
                    :if={current_workspace?(w, @workspace)}
                    name="hero-check-micro"
                    class="ml-auto size-4 flex-none text-accent"
                  />
                </.link>
                <span :if={!w} class="q-switcher-place q-switcher-none">
                  {gettext("No workspace yet")}
                </span>
              </li>
            </ul>
          </section>
        </div>
      </div>
      <div class="q-switcher-foot">
        <.link
          id="organisation-menu-organisations"
          href={~p"/users/organisations"}
          class="q-switcher-place"
        >
          <.icon name="hero-building-office-2" class="size-4 text-faint" />
          {gettext("Your organisations")}
        </.link>
        <.link
          :for={entry <- @switcher_entries}
          id={"organisation-menu-#{entry.key}"}
          navigate={Entry.path(entry, @organisation, @workspace)}
          class="q-switcher-place"
        >
          <.icon name={entry.icon} class="size-4 text-faint" />
          {entry.label}
        </.link>
      </div>
    </div>
    """
  end

  # The workspace menu: a search on top, then this organisation's workspaces the person
  # reaches, by name, each a link to that workspace at the page the reader is on
  # (`switch_workspace_path/3`); no other organisation's. Last, the edition's entries for
  # it (`ApiaryWeb.Edition.workspace_switcher_entries/1`), such as New workspace.
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :workspaces, :list, required: true
  attr :nav, :atom, required: true
  attr :entries, :list, required: true

  defp workspace_menu(assigns) do
    ~H"""
    <div
      id="workspace-menu"
      class="q-switcher q-switcher-one"
      role="group"
      aria-label={gettext("Switch workspace")}
      hidden
      phx-mounted={JS.ignore_attributes(["hidden", "style"])}
    >
      <div class="q-switcher-search">
        <.icon name="hero-magnifying-glass" class="size-4 flex-none text-faint" />
        <input
          id="workspace-menu-search"
          type="text"
          autocomplete="off"
          spellcheck="false"
          aria-label={gettext("Find a workspace")}
          aria-controls="workspace-menu-places"
          placeholder={gettext("Find a workspace…")}
        />
      </div>
      <div id="workspace-menu-places" class="q-switcher-list" data-panel>
        <h3 id="workspace-menu-heading" class="q-switcher-heading">
          {gettext("Workspaces of %{name}", name: @organisation.name)}
        </h3>
        <ul aria-labelledby="workspace-menu-heading">
          <li :for={w <- @workspaces}>
            <.link
              id={"workspace-menu-switch-#{w.slug}"}
              href={switch_workspace_path(@nav, @organisation, w)}
              class="q-switcher-place"
              aria-current={current_workspace?(w, @workspace) && "true"}
              data-switch
              data-search={search_text([w.name, w.slug])}
            >
              <span class="truncate">{w.name}</span>
              <.icon
                :if={current_workspace?(w, @workspace)}
                name="hero-check-micro"
                class="ml-auto size-4 flex-none text-accent"
              />
            </.link>
          </li>
        </ul>
        <p id="workspace-menu-empty" class="q-switcher-empty" hidden>
          {gettext("No workspace matches.")}
        </p>
        <%!-- What the search left, said by the Switcher hook in these words. --%>
        <p
          id="workspace-menu-status"
          role="status"
          class="sr-only"
          data-none={gettext("No workspace matches.")}
          data-one={gettext("1 workspace matches.")}
          data-other={gettext("%{count} workspaces match.", count: "%{count}")}
        >
        </p>
      </div>
      <div :if={@entries != []} class="q-switcher-foot">
        <.link
          :for={entry <- @entries}
          id={"workspace-menu-#{entry.key}"}
          navigate={Entry.path(entry, @organisation, @workspace)}
          class="q-switcher-place"
        >
          <.icon name={entry.icon} class="size-4 text-faint" />
          {entry.label}
        </.link>
      </div>
    </div>
    """
  end

  # The breadcrumb's two menus, on an organisation's or a workspace's page: the organisation
  # menu with more than one place to go or an edition's entry after the places, the
  # workspace menu, on a workspace's page, with another workspace of the organisation or an
  # edition's entry for it. Worked out once for the bar's breadcrumb and the drawer's head.
  # None on a person's own page, an Instance page or a page with no organisation.
  defp menus(_scope, _memberships, _organisation, _workspace, place)
       when place in [:person, :instance],
       do: nil

  defp menus(_scope, _memberships, nil, _workspace, _place), do: nil

  defp menus(scope, memberships, organisation, workspace, place) do
    places = places(memberships)
    switcher_entries = ApiaryWeb.Edition.switcher_entries(scope)
    workspace = if(place == :workspace, do: workspace)
    workspaces = if(workspace, do: workspaces_of(memberships, organisation, workspace))
    workspace_entries = if(workspace, do: ApiaryWeb.Edition.workspace_switcher_entries(scope))

    %{
      organisation_menu?: places != [] and (length(places) > 1 or switcher_entries != []),
      workspace_menu?: workspace != nil and (length(workspaces) > 1 or workspace_entries != []),
      places: places,
      switcher_entries: switcher_entries,
      workspace: workspace,
      workspaces: workspaces,
      workspace_entries: workspace_entries
    }
  end

  # The places by the organisation menu's groups: the person's own organisations first,
  # then each group the edition names (`c:ApiaryWeb.Edition.place_group/1`), in the order
  # its first place came; within each, the organisations by name, each with its
  # workspaces by name, `[nil]` for one that reaches none yet.
  defp place_groups(places) do
    grouped =
      places
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq_by(& &1.organisation_id)
      |> Enum.map(&{ApiaryWeb.Edition.place_group(&1), &1})

    headings = grouped |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort_by(&(!is_nil(&1)))

    for heading <- headings do
      {heading,
       for {^heading, place} <- by_name(grouped, fn {_heading, place} -> place.organisation end) do
         {place, if(place.workspaces == [], do: [nil], else: by_name(place.workspaces))}
       end}
    end
  end

  # The workspaces of the organisation the person reaches, by name; the page's own
  # workspace for a reader with no place of it, as the organisation's overview lists them.
  defp workspaces_of(places, organisation, workspace) do
    case Enum.find(places, &(&1.organisation_id == organisation.id)) do
      %{workspaces: [_ | _] = workspaces} -> by_name(workspaces)
      _none -> [workspace]
    end
  end

  defp by_name(list, named \\ & &1),
    do: Enum.sort_by(list, &{String.downcase(named.(&1).name), named.(&1).slug})

  # An edition's group opens folded, unless the page's organisation is in it.
  defp group_open?(places, organisation),
    do:
      Enum.any?(places, fn {place, _workspaces} -> current_organisation?(place, organisation) end)

  defp current_organisation?(place, organisation), do: place.organisation_id == organisation.id

  defp current_workspace?(_workspace, nil), do: false
  defp current_workspace?(workspace, current), do: workspace.id == current.id

  defp search_text(words) do
    words
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  # New: what the person may start from here (`new_entries/2`).
  attr :entries, :list, required: true

  defp new_menu(assigns) do
    ~H"""
    <div
      id="new-menu"
      class="dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="new-menu-button"
        type="button"
        class="q-newbtn"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("New")}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-plus-micro" class="size-4" />
        <span class="max-md:hidden">{gettext("New")}</span>
        <.icon name="hero-chevron-down-micro" class="size-3.5 text-faint max-md:hidden" />
      </button>
      <ul
        class="menu menu-sm dropdown-content right-0 top-full mt-1.5 w-56"
        role="menu"
        aria-label={gettext("New")}
      >
        <li :for={entry <- @entries} role="none">
          <.link id={"new-menu-#{entry.key}"} navigate={entry.path} role="menuitem" tabindex="-1">
            <.icon name={entry.icon} class="size-4" /> {entry.label}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :user, :any, required: true
  attr :organisation, :any, required: true
  attr :scope, :any, required: true
  attr :entries, :list, required: true

  # The account menu at the right end of the top bar: who you are, your email over "Your
  # personal account" (an account has no name, only its email), so that Settings under
  # them reads as the account's own; your organisations (and the edition's entries beside
  # them); the theme, set once and kept; the edition's entries of the group `:instance`, if
  # any; log out. What is about Qory Apiary itself, the Instance settings among it, is the
  # brand menu's, at the sidebar's foot.
  defp account_menu(assigns) do
    assigns =
      assigns
      |> assign(:account, Enum.filter(assigns.entries, &(&1.section == :account)))
      |> assign(:instance, Enum.filter(assigns.entries, &(&1.section == :instance)))

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
        class="btn btn-ghost btn-keep h-9 min-h-0 min-w-9 rounded-full p-0.5 aria-expanded:bg-base-300"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Account menu, %{email}", email: @user.email)}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.avatar name={@user.email} kind="self" size="md" />
      </button>
      <ul
        class="menu menu-sm dropdown-content right-0 top-full mt-1.5 w-64"
        role="menu"
        aria-label={gettext("Account")}
      >
        <li role="presentation">
          <div class="grid cursor-default grid-flow-row gap-0 px-2 pb-2 pt-1.5 hover:bg-transparent">
            <span class="truncate font-medium" title={@user.email}>{@user.email}</span>
            <span id="user-menu-account" class="truncate text-xs/4 text-faint">
              {gettext("Your personal account")}
            </span>
          </div>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li :for={entry <- @account} role="none">
          <.link
            href={Entry.path(entry, @organisation, @scope.workspace)}
            role="menuitem"
            tabindex="-1"
            id={"user-menu-#{entry.key}"}
          >
            <.icon name={entry.icon} class="size-4" /> {entry.label}
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none" class="q-theme-row">
          <div role="group" aria-labelledby="user-menu-theme" class="hover:bg-transparent">
            <span id="user-menu-theme" class="flex items-center gap-2">
              <.icon name="hero-swatch" class="size-4" /> {gettext("Theme")}
            </span>
            <span class="q-theme-seg">
              <button
                :for={
                  {theme, label} <- [
                    {"system", gettext("Auto")},
                    {"light", gettext("Light")},
                    {"dark", gettext("Dark")}
                  ]
                }
                id={"theme-menu-#{theme}"}
                type="button"
                role="menuitemradio"
                tabindex="-1"
                phx-click={JS.dispatch("phx:set-theme")}
                phx-mounted={JS.ignore_attributes(["aria-checked"])}
                data-phx-theme={theme}
                aria-checked="false"
              >
                {label}
              </button>
            </span>
          </div>
        </li>
        <li :for={entry <- @instance} role="none">
          <.link
            href={Entry.path(entry, @organisation, @scope.workspace)}
            role="menuitem"
            tabindex="-1"
            id={"user-menu-#{entry.key}"}
          >
            <.icon name={entry.icon} class="size-4" /> {entry.label}
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link
            href={~p"/users/log-out"}
            method="delete"
            role="menuitem"
            tabindex="-1"
            id="user-menu-log-out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> {gettext("Log out")}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  # Search or jump to: a dialog over the page, opened by the bar's button, ⌘K or /. The
  # `Palette` hook asks the page's scope what matches (`ApiaryWeb.JumpController`) and
  # lists it; every word it shows comes from the server.
  attr :scope, :any, required: true
  attr :place, :atom, required: true

  defp palette(assigns) do
    ~H"""
    <dialog
      id="palette"
      class="q-palette"
      phx-hook="Palette"
      phx-update="ignore"
      aria-label={gettext("Search or jump to")}
      data-url={jump_path(@scope, @place)}
    >
      <div class="q-palette-box">
        <div class="q-palette-search">
          <.icon name="hero-magnifying-glass" class="size-5 flex-none text-faint" />
          <input
            id="palette-input"
            type="text"
            role="combobox"
            autocomplete="off"
            spellcheck="false"
            aria-expanded="true"
            aria-controls="palette-results"
            aria-autocomplete="list"
            aria-label={gettext("Search or jump to")}
            placeholder={gettext("Search or jump to…")}
          />
          <kbd class="q-kbd" aria-hidden="true">esc</kbd>
        </div>
        <div
          id="palette-results"
          class="q-palette-results"
          role="listbox"
          aria-label={gettext("Results")}
        >
        </div>
        <p id="palette-status" class="sr-only" role="status" aria-live="polite"></p>
        <div class="q-palette-foot" aria-hidden="true">
          <span><kbd class="q-kbd">↑</kbd> <kbd class="q-kbd">↓</kbd> {gettext("to move")}</span>
          <span><kbd class="q-kbd">↵</kbd> {gettext("to open")}</span>
          <span class="max-md:hidden">
            {gettext("A run id, a page, a target or a place")}
          </span>
        </div>
      </div>
    </dialog>
    """
  end

  defp jump_path(%{organisation: organisation, workspace: %{} = workspace}, :workspace),
    do: ~p"/#{organisation}/#{workspace}/jump"

  defp jump_path(%{organisation: organisation}, _place), do: ~p"/#{organisation}/jump"

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

  # The breadcrumb's places in the drawer's head, below 768 px, where the bar names the
  # page alone: the organisation, then the workspace on a workspace's page, each a button
  # that opens its menu where it has one (`menus/5`), else its name. The menus are the
  # bar's: a button closes the drawer (the `NavDrawer` hook) and opens its menu as the
  # sheet under the bar (the `Switcher` hook), and closing the menu gives the focus to the
  # bar's menu button.
  attr :organisation, :any, required: true
  attr :menus, :map, required: true

  defp drawer_place(assigns) do
    ~H"""
    <div id="drawer-place" class="q-drawer-place md:hidden">
      <.drawer_switch
        :if={@menus.organisation_menu?}
        id="drawer-organisation-menu-button"
        controls="organisation-menu"
        label={gettext("Switch organisation, current: %{name}", name: @organisation.name)}
      >
        <.avatar name={@organisation.name} kind="organisation" size="xs" />
        <span class="truncate">{@organisation.name}</span>
      </.drawer_switch>
      <span :if={!@menus.organisation_menu?} class="q-drawer-switch" title={@organisation.name}>
        <.avatar name={@organisation.name} kind="organisation" size="xs" />
        <span class="truncate">{@organisation.name}</span>
      </span>
      <span :if={@menus.workspace} class="q-trail-sep" aria-hidden="true">/</span>
      <.drawer_switch
        :if={@menus.workspace_menu?}
        id="drawer-workspace-menu-button"
        controls="workspace-menu"
        label={gettext("Switch workspace, current: %{name}", name: @menus.workspace.name)}
      >
        <span class="truncate">{@menus.workspace.name}</span>
      </.drawer_switch>
      <span
        :if={@menus.workspace && !@menus.workspace_menu?}
        class="q-drawer-switch"
        title={@menus.workspace.name}
      >
        <span class="truncate">{@menus.workspace.name}</span>
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :controls, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp drawer_switch(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="q-drawer-switch"
      data-switcher-open
      data-switcher-back="nav-drawer-open"
      aria-expanded="false"
      aria-controls={@controls}
      aria-label={@label}
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
    >
      {render_slot(@inner_block)}
      <.icon name="hero-chevron-up-down-micro" class="q-drawer-switch-chev size-4" />
    </button>
    """
  end

  # The main column. Every width starts at the same left edge, 32 px from the sidebar (24
  # below 1024 px, 16 below 768); nothing is centred in the space beside it.
  attr :width, :string, required: true
  slot :inner_block, required: true

  defp content(assigns) do
    ~H"""
    <main id="main" tabindex="-1" class="min-w-0 flex-1 outline-none">
      <div class={["q-page", "q-page-#{@width}"]}>
        <div class="grid grid-cols-[minmax(0,1fr)] gap-6">
          {render_slot(@inner_block)}
        </div>
      </div>
    </main>
    """
  end

  # The sidebar: the pages of the page's scope, in their groups, each a `<nav>` with its
  # own name; the targets the person pinned, on a workspace's pages. At the foot the
  # scope's settings, Workspace settings or Organisation settings, the current entry on
  # every page of them, then the Qory Apiary menu and the control that folds the sidebar to
  # icons. Its head, in the drawer below 768 px, holds the breadcrumb's menus' places
  # (`drawer_place/1`) and the close button.
  attr :place, :atom, required: true
  attr :nav, :atom, required: true
  attr :groups, :list, required: true
  attr :foot, :any, required: true
  attr :settings_page, :boolean, required: true
  attr :pins, :list, required: true
  attr :target, :string, required: true
  attr :counts, :any, required: true
  attr :second, :any, required: true
  attr :instance_path, :string, required: true
  attr :organisation, :any, default: nil
  attr :menus, :map, default: nil

  defp sidebar(assigns) do
    assigns = assign(assigns, :version, version())

    ~H"""
    <aside
      id="sidebar"
      aria-label={sidebar_label(@place)}
      class="q-sidebar"
      phx-mounted={JS.ignore_attributes(["role", "aria-modal"])}
    >
      <div class="q-drawer-head">
        <.drawer_place
          :if={@menus && (@menus.organisation_menu? or @menus.workspace_menu?)}
          organisation={@organisation}
          menus={@menus}
        />
        <button
          type="button"
          data-drawer-close
          class="btn btn-ghost btn-square"
          aria-label={gettext("Close menu")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <div class="q-sidebar-body">
        <nav
          :for={{section, heading, items} <- @groups}
          class="q-nav-group"
          aria-label={group_name(section, heading, items)}
          id={"nav-group-#{section}"}
        >
          <p :if={heading} class="q-nav-heading" aria-hidden="true">{heading}</p>
          <.nav_item
            :for={{entry, path, carried} <- items}
            entry={entry}
            path={path}
            carried={carried}
            current={@nav == entry.key and not Enum.any?(@pins, &(&1.id == @target))}
            counts={@counts}
          />
        </nav>

        <nav
          :if={@pins != []}
          id="nav-group-pinned"
          class="q-nav-group"
          aria-label={gettext("Pinned")}
        >
          <p class="q-nav-heading" aria-hidden="true">{gettext("Pinned")}</p>
          <.link
            :for={pin <- @pins}
            id={"nav-pin-#{pin.id}"}
            navigate={pin.href}
            aria-current={pin.id == @target && "page"}
            class="q-nav-item"
            title={"#{pin.system}/#{pin.path}"}
            phx-mounted={JS.ignore_attributes(["title"])}
          >
            <.icon name="hero-folder" class="q-nav-icon size-[18px]" />
            <span class="q-nav-text q-nav-pin">
              <span :if={pin.shared} class="q-nav-pin-sys">{pin.system}/</span>{pin.path}
            </span>
          </.link>
        </nav>
      </div>

      <div class="q-sidebar-foot">
        <%!-- The level's settings are current on every page of them; where their sections
             are the second column, the page is the column's entry and this its parent. --%>
        <.nav_item
          :if={@foot}
          entry={elem(@foot, 0)}
          path={elem(@foot, 1)}
          current={@settings_page}
          parent={@second != nil and @second.kind == :settings}
          counts={@counts}
        />
        <div id="brand-foot" class="q-brand-row">
          <.brand_menu version={@version} direction="up" instance_path={@instance_path} />
          <button
            id="sidebar-collapse"
            type="button"
            class="q-collapse tooltip tooltip-right"
            data-sidebar-collapse
            data-tip={gettext("Collapse sidebar")}
            data-label={gettext("Collapse sidebar")}
            data-label-folded={gettext("Expand sidebar")}
            aria-label={gettext("Collapse sidebar")}
            aria-keyshortcuts="["
            phx-mounted={JS.ignore_attributes(["aria-label", "data-tip"])}
          >
            <.icon name="hero-chevron-double-left-micro" class="q-collapse-icon size-4" />
          </button>
        </div>
      </div>
    </aside>
    """
  end

  # The second column (`second_column/6`): from 1024 px a column of the level's sections
  # beside the sidebar, under its heading, which names the level and, beneath it, the
  # place ("Workspace settings", Main) and names the navigation. Below 1024 px the heading
  # is a full-width button under the top bar (`#settings-disclosure`, a disclosure) that
  # opens the same links in place, pushing the page down: not a modal, not sticky. Escape
  # closes it and gives the button the focus back; a choice closes it, and a navigation
  # renders it closed.
  attr :second, :map, required: true
  attr :counts, :any, required: true

  defp second_column(assigns) do
    # Escape, on the button or on a link of the list it opened.
    assigns =
      assign(
        assigns,
        :escape,
        JS.set_attribute({"aria-expanded", "false"}, to: "#settings-disclosure")
        |> JS.focus(to: "#settings-disclosure")
      )

    ~H"""
    <nav id={@second.id} class="q-second" aria-labelledby={"#{@second.id}-heading"}>
      <p class="q-second-heading">
        <span id={"#{@second.id}-heading"} class="q-second-level">{@second.label}</span>
        <span
          :if={@second.place_name}
          id={"#{@second.id}-place"}
          class="q-second-place"
          title={@second.place_name}
        >
          {@second.place_name}
        </span>
      </p>
      <button
        id="settings-disclosure"
        type="button"
        class="q-second-toggle"
        aria-expanded="false"
        aria-controls={"#{@second.id}-list"}
        phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
        phx-keydown={@escape}
        phx-key="Escape"
      >
        <span class="q-second-toggle-text">
          {@second.label}<span :if={@second.place_name} class="q-second-toggle-place"><span aria-hidden="true"> · </span>{@second.place_name}</span>
        </span>
        <.icon name="hero-chevron-down-micro" class="q-second-toggle-i size-4" />
      </button>
      <div id={"#{@second.id}-list"} class="q-second-list">
        <.link
          :for={{entry, path} <- @second.entries}
          id={second_link_id(@second.kind, entry.key)}
          navigate={path}
          aria-current={entry.key == @second.current && @second.aria_current}
          class="q-second-link"
          phx-keydown={@escape}
          phx-key="Escape"
        >
          <span class="q-second-text">{entry.label}</span>
          <span :if={count = second_count(@counts, entry)} class="q-second-n">
            {Format.number(count)}
          </span>
        </.link>
      </div>
    </nav>
    """
  end

  defp second_count(%{} = counts, %Entry{count: key}) when is_atom(key) and not is_nil(key) do
    case Map.get(counts, key) do
      n when is_integer(n) -> n
      _none -> nil
    end
  end

  defp second_count(_counts, _entry), do: nil

  attr :entry, :any, required: true
  attr :path, :string, required: true
  attr :current, :boolean, required: true

  attr :parent, :boolean,
    default: false,
    doc:
      "current as the page's parent, not the page itself: `aria-current=\"true\"`, drawn lighter in the drawer"

  attr :counts, :any, required: true

  attr :carried, :string,
    default: nil,
    doc: "the entry's name where it carries a narrowing, its tooltip and accessible name"

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={"nav-#{@entry.key}"}
      navigate={@path}
      aria-current={@current && if(@parent, do: "true", else: "page")}
      aria-label={@carried}
      title={@carried}
      data-title={@carried}
      class={["q-nav-item", @current && @parent && "q-nav-parent"]}
      phx-mounted={JS.ignore_attributes(["title"])}
    >
      <.icon name={@entry.icon} class="q-nav-icon size-[18px]" />
      <span class="q-nav-text">{@entry.label}</span>
      <span
        :if={@entry.key == :runs && alive_count(@counts) > 0}
        id="nav-runs-alive"
        class="q-nav-count text-info-soft-content"
        title={alive_title(alive_count(@counts))}
      >
        <span class="q-dot q-ripple !size-1.5" aria-hidden="true"></span>
        {Format.number(alive_count(@counts))}
      </span>
      <span
        :if={@entry.key == :policy && policy_mode(@counts)}
        id="nav-policy-mode"
        class="q-nav-count"
        title={policy_mode_title(@counts)}
      >
        {policy_mode(@counts)}
      </span>
      <span :if={count = nav_count(@counts, @entry)} class="q-nav-count">
        {Format.number(count)}
      </span>
    </.link>
    """
  end

  @doc """
  The product's menu, on the brand: the mark and the edition's name
  (`c:ApiaryWeb.Edition.product_name/0`), opening upward from the sidebar's foot and
  downward from the bar when there is no sidebar. It holds what is about the product
  itself, not about the person: first, for whoever may open a section of the Instance
  level (`instance_path`, its first), the instance's own settings, Instance settings, and
  a rule; then the docs this instance serves, its changelog with the running version
  (`version`, none when nil) faint at the right, and the source. Folded, the sidebar shows
  the mark alone, still the menu's button.
  """
  attr :version, :any, required: true
  attr :direction, :string, required: true, values: ~w(up down)
  attr :instance_path, :string, default: nil

  def brand_menu(assigns) do
    assigns = assign(assigns, :product, ApiaryWeb.Edition.product_name())

    ~H"""
    <div
      id="brand-menu"
      class={["q-brand dropdown", @direction == "up" && "dropdown-top"]}
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id="brand-menu-button"
        type="button"
        class="q-brand-btn"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("%{product} menu", product: @product)}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.logo_mark class="size-[18px]" />
        <span class="q-brand-name">{@product}</span>
        <.icon
          name={if @direction == "up", do: "hero-chevron-up-micro", else: "hero-chevron-down-micro"}
          class="q-brand-chev size-4"
        />
      </button>
      <ul
        class={[
          "menu menu-sm dropdown-content w-56",
          if(@direction == "up", do: "left-0 bottom-full mb-1.5", else: "left-0 top-full mt-1.5")
        ]}
        role="menu"
        aria-label={@product}
      >
        <li :if={@instance_path} role="none">
          <.link href={@instance_path} role="menuitem" tabindex="-1" id="brand-menu-instance">
            <.icon name="hero-server-stack" class="size-4" /> {gettext("Instance settings")}
          </.link>
        </li>
        <li :if={@instance_path} class="menu-divider" role="separator"></li>
        <li role="none">
          <.link href={~p"/docs"} role="menuitem" tabindex="-1" id="brand-menu-docs">
            <.icon name="hero-book-open" class="size-4" /> {gettext("Docs")}
          </.link>
        </li>
        <%!-- Every tree of the documentation has the release notes. --%>
        <li role="none">
          <.link
            href={~p"/docs/changelog.html"}
            role="menuitem"
            tabindex="-1"
            id="brand-menu-changelog"
          >
            <.icon name="hero-list-bullet" class="size-4" /> {gettext("Changelog")}
            <span
              :if={@version}
              id="brand-version"
              class="q-brand-version"
              title={gettext("Version %{version}", version: @version)}
            >
              {@version}
            </span>
          </.link>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <.link
            href="https://github.com/qoryai/apiary"
            target="_blank"
            rel="noopener"
            role="menuitem"
            tabindex="-1"
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

  defp sidebar_label(:workspace), do: gettext("Workspace")
  defp sidebar_label(:organisation), do: gettext("Organisation")
  defp sidebar_label(_person), do: gettext("Your account")

  # The pinned targets, each with the path of its page.
  defp pins(%{pins: pins}, organisation, workspace) when is_list(pins) do
    for pin <- Enum.take(pins, @pins) do
      Map.put(
        pin,
        :href,
        ApiaryWeb.TargetComponents.target_path(
          organisation,
          workspace,
          pin.system,
          pin.path,
          [],
          pin[:shared] == true
        )
      )
    end
  end

  defp pins(_counts, _organisation, _workspace), do: []

  # The running version, from the application's spec. Nil before the spec exists
  # (a clean compile), and then the brand menu's Changelog line shows none.
  defp version do
    case Application.spec(:apiary, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp nav_text(msgid), do: Gettext.gettext(ApiaryWeb.Gettext, msgid)

  # Every group of the sidebar, in order, with its heading translated: the core's, the
  # edition's (translated by the edition), then any other section an edition's entry
  # names, without a heading.
  defp sections(entries) do
    core = for {section, heading} <- @sections, do: {section, heading && nav_text(heading)}
    named = core ++ ApiaryWeb.Edition.nav_sections()
    known = Keyword.keys(named) ++ [:settings, :foot, nil]

    others =
      for %Entry{section: section} <- entries,
          section not in known,
          uniq: true,
          do: {section, nil}

    named ++ others
  end

  # The entries of the page's scope the reader may open, by group, with where each leads.
  # A feature that is off is absent, not disabled: no entry, greyed or otherwise, and so
  # nothing beside it either (Policy's mode word goes with Policy). A group left empty goes
  # too. Without a workspace, for a member added to none yet, a workspace's entries are not
  # there.
  # On a list narrowed to a target (`carry`), Runs and Network access lead to the lists
  # narrowed to it, and say so in their names (`{entry, path, label}`); every other entry
  # leads plainly, its label nil.
  defp nav_groups(scope, place, counts, entries, carry) do
    for {section, heading} <- sections(entries),
        shown =
          for(
            %Entry{section: ^section, place: ^place} = entry <- entries,
            shown?(entry, scope, counts),
            do: carried(entry, entry_path(entry, scope), carry)
          ),
        shown != [],
        do: {section, heading, shown}
  end

  defp carried(%Entry{key: key} = entry, path, %{} = carry) when key in [:runs, :network],
    do: {entry, carried_path(path, carry), carried_label(key, narrowed_name(carry))}

  defp carried(entry, path, _carry), do: {entry, path, nil}

  # A group's navigation is named by its heading; the first group, which has none, is
  # Main, and any other group without a heading takes its first entry's name, so no two
  # navigations of the sidebar share a name.
  defp group_name(_section, heading, _items) when is_binary(heading), do: heading
  defp group_name(:home, nil, _items), do: gettext("Main")
  defp group_name(_section, nil, [{entry, _path, _label} | _]), do: entry.label

  # Settings at the sidebar's foot: the scope's.
  defp foot(scope, place, entries) do
    Enum.find_value(entries, fn
      %Entry{section: :foot, place: ^place} = entry ->
        shown?(entry, scope, nil) && {entry, entry_path(entry, scope)}

      _entry ->
        nil
    end)
  end

  defp entry_path(entry, scope),
    do: Entry.path(entry, scope_field(scope, :organisation), scope_field(scope, :workspace))

  defp shown?(%Entry{place: :person} = entry, scope, counts),
    do: is_nil(entry.filter) or entry.filter.(scope, counts)

  defp shown?(%Entry{place: :workspace}, %{workspace: nil}, _counts), do: false
  defp shown?(%Entry{}, %{organisation: nil}, _counts), do: false

  defp shown?(%Entry{} = entry, scope, counts) do
    (is_nil(entry.filter) or entry.filter.(scope, counts)) and
      nav_open?(scope, entry.action, subject(entry, scope))
  end

  # What an entry's action is asked of: the organisation, for an entry of the
  # organisation's; else the workspace where there is one, else the organisation.
  defp subject(%Entry{place: :organisation}, scope), do: scope.organisation
  defp subject(%Entry{}, scope), do: scope.workspace || scope.organisation

  @doc """
  switch_target/3 is where a menu's link to a workspace leads once followed, asked
  with the scope of that workspace: where the reader may open the workspace's navigation
  entry named `key` there, its feature on there too, `page` when given, the path of the
  reader's page as it is there (`ApiaryWeb.SwitchController`), else the entry's page;
  else the workspace's overview. An entry of an organisation's pages is no workspace's, and
  leads to the overview.
  """
  @spec switch_target(Apiary.Accounts.Scope.t(), String.t(), String.t() | nil) :: String.t()
  def switch_target(scope, key, page \\ nil) do
    found =
      Enum.find(palette_entries(scope), fn {entry, _path} ->
        entry.place == :workspace and Atom.to_string(entry.key) == key
      end)

    case found do
      {_entry, path} -> page || path
      nil -> ~p"/#{scope.organisation}/#{scope.workspace}"
    end
  end

  @doc """
  switch_workspace_path/3 is the link of the breadcrumb's menus to `workspace` of
  `organisation`, from a page whose navigation entry is `nav`:
  `GET /:org/:workspace/switch/:section` (`ApiaryWeb.SwitchController`), which lands on
  the reader's page there, given as `?page=` the path after the page's own
  `/:org/:workspace`, which the menu adds when it opens; else on the section, else the
  overview. A link from an organisation's page, with no `page`, lands on the overview.
  Without a workspace, for an organisation the person reaches none of, the organisation's
  own path, which says so.
  """
  @spec switch_workspace_path(atom | nil, struct, struct | nil) :: String.t()
  def switch_workspace_path(_nav, organisation, nil), do: ~p"/#{organisation}"

  def switch_workspace_path(nav, organisation, workspace),
    do: ~p"/#{organisation}/#{workspace}/switch/#{switch_section(nav)}"

  @doc """
  switch_organisation_path/2 is the organisation menu's link to `organisation`, from a
  page whose navigation entry is `nav`: `GET /:org/-/switch/:section`, which lands in the
  workspace the person last used there (`Apiary.Organisations.resolve_scope/4`), at the
  page as `switch_workspace_path/3`'s link does, `?page=` too; in the organisation's own
  path where they reach no workspace.
  """
  @spec switch_organisation_path(atom | nil, struct) :: String.t()
  def switch_organisation_path(nav, organisation),
    do: ~p"/#{organisation}/-/switch/#{switch_section(nav)}"

  defp switch_section(nil), do: :overview
  defp switch_section(nav), do: nav

  defp nav_open?(_scope, nil, _subject), do: true
  defp nav_open?(scope, action, subject), do: Access.can?(scope, action, subject)

  # One place to switch to per workspace each membership reaches, and one for a
  # membership that reaches none yet: `{membership, workspace or nil}`.
  defp places(memberships) do
    for membership <- memberships,
        workspace <- if(membership.workspaces == [], do: [nil], else: membership.workspaces),
        do: {membership, workspace}
  end

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
              "Every run of a connected machine reports to Qory Apiary: its session, terminal and every connection, with the decision and rule behind it. Open source, so you can check all of that."
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
        <.icon name="hero-sun" class="size-4 dark:hidden" />
        <.icon name="hero-moon" class="hidden size-4 dark:inline-block" />
      </button>
      <ul
        class="menu menu-sm dropdown-content mt-1.5 w-40 min-w-0"
        role="menu"
        aria-label={gettext("Theme")}
      >
        <li
          :for={
            {theme, icon, label} <- [
              {"system", "hero-computer-desktop", gettext("Auto")},
              {"light", "hero-sun", gettext("Light")},
              {"dark", "hero-moon", gettext("Dark")}
            ]
          }
          role="none"
        >
          <button
            id={"theme-menu-#{theme}"}
            type="button"
            role="menuitemradio"
            tabindex="-1"
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
