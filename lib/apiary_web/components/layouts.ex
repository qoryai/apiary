defmodule ApiaryWeb.Layouts do
  @moduledoc """
  Layouts: the application shell (`app/1`) for signed-in pages and the split
  view (`auth/1`) for log-in, registration, invitation and welcome pages. The
  product on every surface is Qory Apiary; the shell is section 4 of the v2 design
  brief (`docs/ui.md`).

  The shell shows one scope at a time, the one the page belongs to: a workspace, an
  organisation or the person. The top bar says where the page is and switches it (the
  breadcrumb and its switcher), searches and jumps (the palette), and holds New and the
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
  leaves out those of a feature that is off, and the switcher asks them where it leads.
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
        section: :settings,
        key: :keys,
        label: gettext("Access keys"),
        icon: "hero-key",
        path: fn organisation, workspace -> ~p"/#{organisation}/#{workspace}/settings/keys" end,
        count: :keys
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
  then the core's: on a workspace's page a node, a node pool, an integration, a secret, a
  variable and an access key, and everywhere an invitation; of them, only what the reader
  may do there, each entry's action asked of the workspace or the organisation as its
  `place` says.
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
          },
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
          },
          %Entry{
            key: :key,
            label: gettext("New access key"),
            icon: "hero-key",
            path: ~p"/#{organisation}/#{workspace}/settings/keys/new",
            action: :"access_key.create"
          }
        ]
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
  not on every render: the account menu's Instance leads to the first, and with two or
  more the Instance's pages list them as the second column.
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
  account_menu_entries/2 is what the account menu lists in `scope`, as
  `ApiaryWeb.Nav.Entry` values in their groups (`section`): `:account`, Settings (the
  person's own, under "Your personal account") and Your organisations, then the edition's (`c:ApiaryWeb.Edition.account_menu_entries/1`,
  `:account` where it names no group); `:instance`, after the theme, the core's Instance,
  where the person may open a section of the Instance level (`instance`, as
  `instance_sections/1` gives them), leading to the first, then the edition's. An entry's
  action, where it has one, is asked of the organisation.
  """
  @spec account_menu_entries(Apiary.Accounts.Scope.t() | nil, [Entry.t()]) :: [Entry.t()]
  def account_menu_entries(scope, instance \\ []) do
    organisation = scope_field(scope, :organisation)
    workspace = scope_field(scope, :workspace)

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
      },
      match?([%Entry{} | _], instance) &&
        %Entry{
          section: :instance,
          key: :instance,
          label: gettext("Instance"),
          icon: "hero-server-stack",
          path: Entry.path(hd(instance), organisation, workspace),
          place: :instance
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
  whatever the page adds in its `crumb` slots), whose chevrons open the switcher; then
  Search or jump to (the palette), New and the account menu. The sidebar holds the pages
  of the page's scope, which the entry it passes as `nav` belongs to
  (`ApiaryWeb.Nav.Entry`'s `place`): a workspace's, an organisation's or the person's,
  whose pages are their settings. At its foot are the scope's Settings, the current entry
  on every page of them, then the Qory Apiary menu and the control that folds the sidebar
  to icons, from 768 px; below that it is a drawer behind the bar's menu button. A page
  without a person has no sidebar, and the Qory Apiary menu opens from the bar.

  An organisation's page, one with a navigation item (`nav`) of a workspace or an
  organisation, opens with the edition's notices (the `:notices` slot,
  `ApiaryWeb.Extension`): the page beneath says the rest. A person's own pages carry none.

  **Two levels.** The sidebar is the level's, a workspace's or an organisation's, on every
  page of the level, Settings included. A page of Settings, of Your settings or of the
  Instance opens the level's sections as a second column beside it (`sections`, `section`):
  from 1024 px a column, below it a row of links at the top of the page, and on phones a
  list under Settings in the drawer. A level with a single section gets none. A person's own
  page and an Instance page keep the sidebar the person came from, the workspace the session
  remembers; with no workspace, the person's sidebar is their sections alone, as one
  column. `aria-current="page"` marks the exact page's entry alone; its parents carry
  `aria-current="true"`: Settings at the sidebar's foot while the second column lists its
  sections, and the column's section on a page under it, one that adds `crumb` segments.

  **Narrowing.** On Runs or Network access narrowed to a target (`narrowed`), both entries
  of the sidebar carry the target to the other list; nothing else does.

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
      "%{keys: active keys, members: members, alive: runs alive now, mode: the policy's default mode, own_modes: the modes targets set, pins: the pinned targets, `%{id, system, path, shared}` (`Apiary.Targets.list_pins/2`)}"

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
      "how the second column marks the page's section: `\"page\"` where the page is the section's own, `\"true\"` where it is under it; unless given, `\"true\"` on a page that adds `crumb` segments and `\"page\"` on one that adds none. A tab of the section other than the one its entry leads to passes `\"true\"`"

  attr :narrowed, :map,
    default: nil,
    doc:
      "on Runs and Network access narrowed to one target, that target, `%{system, path, shared}` (`narrowed/2`): the sidebar's Runs and Network access carry it, its path and, only where the path is shared, its system. Nil everywhere else"

  slot :crumb,
    doc: "the breadcrumb's segments after the workspace: a target, a record; the last is the page" do
    attr :navigate, :string, doc: "where the segment leads; none for the page itself"
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
        section={@section}
        second={@second}
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
  # (an entry of the section `:settings`, such as Access keys).
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
        # segments to the breadcrumb (Invite people, Edit secret) or on a tab of it other
        # than the one its entry leads to, the page's parent.
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
  defp second_label(:instance, _place), do: gettext("Instance")

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
  attr :section, :atom, required: true
  attr :second, :map, required: true

  defp top_bar(assigns) do
    # An Instance page offers what a person's own page does.
    new_place = if assigns.place == :instance, do: :person, else: assigns.place

    assigns =
      assigns
      |> assign(:new_entries, new_entries(assigns.scope, new_place))
      |> assign(:account_entries, account_menu_entries(assigns.scope, assigns.instance))

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
      <.brand_menu :if={!@sidebar} version={version()} direction="down" />

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
  # With more than one place to go (or an edition's entry after the places) the chevron
  # beside the organisation and the workspace opens the switcher. A person's own page
  # names itself.
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
            {gettext("Your settings")}
          </.link>
        </li>
        <li :if={@here} class={["q-trail-item", @crumb != [] && "q-trail-lead"]}>
          <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
          <.link
            :if={@crumb != []}
            navigate={Entry.path(@here, @organisation, @workspace)}
            class="q-trail-link"
          >
            {@here.label}
          </.link>
          <span :if={@crumb == []} class="q-trail-link q-trail-page" aria-current="page">
            {@here.label}
          </span>
        </li>
        <.crumbs crumb={@crumb} />
      </ol>
    </nav>
    """
  end

  # An Instance page: Instance, leading to its first section, then the section and what
  # the page adds. With one section, and so no second column whose disclosure names the
  # level on a phone, a phone's bar keeps Instance before the section.
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
            {gettext("Instance")}
          </.link>
          <span :if={!@first} class="q-trail-link q-trail-page">{gettext("Instance")}</span>
        </li>
        <li :if={@here} class={["q-trail-item", @crumb != [] && "q-trail-lead"]}>
          <span class={["q-trail-sep", !@keep && "max-md:hidden"]} aria-hidden="true">/</span>
          <.link
            :if={@crumb != []}
            navigate={Entry.path(@here, @organisation, @workspace)}
            class="q-trail-link"
          >
            {@here.label}
          </.link>
          <span :if={@crumb == []} class="q-trail-link q-trail-page" aria-current="page">
            {@here.label}
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
    places = places(assigns.memberships)
    switcher_entries = ApiaryWeb.Edition.switcher_entries(assigns.scope)

    assigns =
      assigns
      |> assign(:switcher?, places != [] and (length(places) > 1 or switcher_entries != []))
      |> assign(:places, places)
      |> assign(:switcher_entries, switcher_entries)
      |> assign(:workspace, if(assigns.place == :workspace, do: assigns.workspace))
      |> assign(:after_place, assigns.trail != nil or assigns.crumb != [])

    ~H"""
    <nav id="breadcrumb" aria-label={gettext("Where you are")} class="q-trail-nav">
      <div
        id={if @switcher?, do: "organisation-menu", else: "organisation-block"}
        class="contents"
        phx-hook={@switcher? && "Switcher"}
        data-current={@switcher? && current_switch_id(@organisation, @workspace)}
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
              :if={@switcher?}
              id="organisation-menu-button"
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
              :if={@switcher?}
              id="workspace-menu-button"
              label={gettext("Switch workspace, current: %{name}", name: @workspace.name)}
            />
          </li>
          <.settings_crumbs :if={@trail} trail={@trail} crumb={@crumb} />
          <.crumbs crumb={@crumb} />
        </ol>

        <.switcher
          :if={@switcher?}
          scope={@scope}
          organisation={@organisation}
          workspace={@workspace}
          places={@places}
          nav={@nav}
          nav_entries={@nav_entries}
          switcher_entries={@switcher_entries}
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
    <li class={["q-trail-item", (@last == :section || @crumb != []) && "q-trail-lead"]}>
      <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
      <.link
        :if={@last == :section || @crumb != []}
        id="breadcrumb-settings"
        navigate={@trail.path}
        class="q-trail-link"
      >
        {@trail.label}
      </.link>
      <span
        :if={@last == :level && @crumb == []}
        id="breadcrumb-settings"
        class="q-trail-link q-trail-page"
        aria-current="page"
      >
        {@trail.label}
      </span>
    </li>
    <li :if={@trail.section} class={["q-trail-item", @crumb != [] && "q-trail-lead"]}>
      <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
      <.link
        :if={@crumb != []}
        id="breadcrumb-section"
        navigate={@trail.section.path}
        class="q-trail-link"
      >
        {@trail.section.label}
      </.link>
      <span
        :if={@crumb == []}
        id="breadcrumb-section"
        class="q-trail-link q-trail-page"
        aria-current="page"
      >
        {@trail.section.label}
      </span>
    </li>
    """
  end

  # The page's own segments of the breadcrumb, after where the page is: each a link but
  # the page itself, the last, which is current.
  attr :crumb, :list, required: true

  defp crumbs(assigns) do
    ~H"""
    <li
      :for={{crumb, i} <- Enum.with_index(@crumb)}
      class={["q-trail-item", i < length(@crumb) - 1 && "q-trail-lead"]}
    >
      <span class="q-trail-sep max-md:hidden" aria-hidden="true">/</span>
      <.link :if={crumb[:navigate]} navigate={crumb.navigate} class="q-trail-link">
        {render_slot(crumb)}
      </.link>
      <span
        :if={!crumb[:navigate]}
        class="q-trail-link q-trail-page"
        aria-current={i == length(@crumb) - 1 && "page"}
      >
        {render_slot(crumb)}
      </span>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true

  defp switcher_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="q-trail-chev"
      data-switcher-open
      aria-expanded="false"
      aria-controls="organisation-menu-panel"
      aria-label={@label}
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
    >
      <.icon name="hero-chevron-up-down-micro" class="size-4" />
    </button>
    """
  end

  # The switcher: a search on top; the places opened last (the `Switcher` hook keeps
  # them, as a reading preference); the organisations the person reaches, each with its
  # workspaces, a link to each at the section the user is on (the path says which
  # workspace a page shows), and to an organisation where they reach no workspace yet; the
  # places of the edition's groups (`c:ApiaryWeb.Edition.place_group/1`) under their own
  # headings, each folded behind its heading and its count unless the page's place is in
  # it, and opened by a search that finds a place in it. A link loads the page afresh, so the session remembers the workspace for
  # `/`. Last, Your organisations and the edition's entries
  # (`ApiaryWeb.Edition.switcher_entries/1`), such as New organisation.
  attr :scope, :any, required: true
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :places, :list, required: true
  attr :nav, :atom, required: true
  attr :nav_entries, :list, required: true
  attr :switcher_entries, :list, required: true

  defp switcher(assigns) do
    assigns = assign(assigns, :groups, place_groups(assigns.places))

    ~H"""
    <div
      id="organisation-menu-panel"
      class="q-switcher"
      role="group"
      aria-label={gettext("Switch organisation or workspace")}
      hidden
      phx-mounted={JS.ignore_attributes(["hidden"])}
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
      <div id="organisation-menu-places" class="q-switcher-list">
        <section
          id="organisation-menu-recent"
          class="q-switcher-group"
          aria-labelledby="organisation-menu-recent-heading"
          hidden
        >
          <h3 id="organisation-menu-recent-heading" class="q-switcher-heading">
            {gettext("Recent")}
          </h3>
          <ul data-recent></ul>
        </section>
        <section
          :for={{{heading, places}, g} <- Enum.with_index(@groups)}
          class="q-switcher-group"
          aria-labelledby={"organisation-menu-group-#{g}"}
          data-group
        >
          <h3 id={"organisation-menu-group-#{g}"} class="q-switcher-heading">
            <%= if heading do %>
              <button
                type="button"
                class="q-switcher-fold"
                aria-expanded={to_string(group_open?(places, @organisation, @workspace))}
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
          <div
            id={"organisation-menu-group-#{g}-places"}
            hidden={heading && !group_open?(places, @organisation, @workspace)}
            phx-mounted={JS.ignore_attributes(["hidden"])}
            data-fold-list={heading && "true"}
          >
            <div
              :for={{place, workspaces} <- places}
              class="q-switcher-org"
              data-org
              data-search={search_text(place.organisation)}
            >
              <div class="q-switcher-org-name" aria-hidden="true">
                <.avatar name={place.organisation.name} kind="organisation" size="xs" />
                <span class="truncate">{place.organisation.name}</span>
              </div>
              <ul>
                <li :for={w <- workspaces}>
                  <.link
                    id={switch_id({place, w})}
                    href={switch_path(@nav, @nav_entries, place, w)}
                    class="q-switcher-place"
                    aria-current={current?({place, w}, @organisation, @workspace) && "true"}
                    data-place
                    data-search={search_text(place.organisation, w)}
                    data-recent-label={place_label(place.organisation, w)}
                  >
                    <span class="truncate">
                      <span class="sr-only">{place.organisation.name} /</span>
                      {if w, do: w.name, else: gettext("No workspace yet")}
                    </span>
                    <.icon
                      :if={current?({place, w}, @organisation, @workspace)}
                      name="hero-check-micro"
                      class="ml-auto size-4 flex-none text-accent"
                    />
                  </.link>
                </li>
              </ul>
            </div>
          </div>
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
          data-one={gettext("1 place matches.")}
          data-other={gettext("%{count} places match.", count: "%{count}")}
        >
        </p>
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

  # The places by the switcher's groups: the person's own organisations first, then each
  # group the edition names (`c:ApiaryWeb.Edition.place_group/1`), in the order its first
  # place came; each place with the workspaces to list, `[nil]` for one that reaches none
  # yet.
  defp place_groups(places) do
    grouped =
      places
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq_by(& &1.organisation_id)
      |> Enum.map(&{ApiaryWeb.Edition.place_group(&1), &1})

    headings = grouped |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort_by(&(!is_nil(&1)))

    for heading <- headings do
      {heading,
       for {^heading, place} <- grouped do
         {place, if(place.workspaces == [], do: [nil], else: place.workspaces)}
       end}
    end
  end

  # An edition's group opens folded, unless the page's place is in it.
  defp group_open?(places, organisation, workspace),
    do:
      Enum.any?(places, fn {place, workspaces} ->
        Enum.any?(workspaces, &current?({place, &1}, organisation, workspace))
      end)

  defp search_text(organisation, workspace \\ nil) do
    [
      organisation.name,
      organisation.slug,
      workspace && workspace.name,
      workspace && workspace.slug
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp place_label(organisation, nil), do: organisation.name
  defp place_label(organisation, workspace), do: "#{organisation.name} / #{workspace.name}"

  defp current_switch_id(organisation, nil), do: "switch-#{organisation.slug}"

  defp current_switch_id(organisation, workspace),
    do: "switch-#{organisation.slug}-#{workspace.slug}"

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
  # them); the theme, set once and kept; the Instance, for whoever may open a section of
  # it; log out. What is about Qory Apiary itself is the brand menu's, at the sidebar's
  # foot.
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
  # scope's Settings, the current entry on every page of them, then the Qory Apiary menu
  # and the control that folds the sidebar to icons.
  attr :place, :atom, required: true
  attr :nav, :atom, required: true
  attr :groups, :list, required: true
  attr :foot, :any, required: true
  attr :settings_page, :boolean, required: true
  attr :pins, :list, required: true
  attr :target, :string, required: true
  attr :counts, :any, required: true
  attr :second, :any, required: true

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
        <%!-- Settings is current on every page of them; where its sections are the second
             column, the page is the column's entry and Settings its parent. --%>
        <.nav_item
          :if={@foot}
          entry={elem(@foot, 0)}
          path={elem(@foot, 1)}
          current={@settings_page}
          parent={@second != nil and @second.kind == :settings}
          counts={@counts}
        />
        <div id="brand-foot" class="q-brand-row">
          <.brand_menu version={@version} direction="up" />
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
        <span :if={@second.place_name} id={"#{@second.id}-place"} class="q-second-place">
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
          {@second.label}<span :if={@second.place_name} class="q-second-toggle-place"> · {@second.place_name}</span>
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

  attr :version, :any, required: true
  attr :direction, :string, required: true, values: ~w(up down)

  # The product's menu, on the brand: the mark and "Qory Apiary" with the version at the
  # right, opening upward from the sidebar's foot and downward from the bar when there is
  # no sidebar. It holds what is about Qory Apiary itself, not about the person: the docs
  # this instance serves, its changelog and the source. Folded, the sidebar shows the mark
  # alone, still the menu's button.
  defp brand_menu(assigns) do
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
        aria-label={
          if @version,
            do: gettext("Qory Apiary menu, version %{version}", version: @version),
            else: gettext("Qory Apiary menu")
        }
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.logo_mark class="size-[18px]" />
        <span class="q-brand-name">Qory Apiary</span>
        <span
          :if={@version}
          id="brand-version"
          class="q-brand-version"
          title={gettext("Version %{version}", version: @version)}
        >
          {@version}
        </span>
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
        aria-label="Qory Apiary"
      >
        <li role="none">
          <.link href={~p"/docs"} role="menuitem" tabindex="-1" id="brand-menu-docs">
            <.icon name="hero-book-open" class="size-4" /> {gettext("Docs")}
          </.link>
        </li>
        <%!-- The release notes name every feature, so only the documentation of an instance with
             every one has them; the documentation is the instance's, and so is this check. --%>
        <li :if={Apiary.Features.enabled() == Apiary.Features.all()} role="none">
          <.link
            href={~p"/docs/changelog.html"}
            role="menuitem"
            tabindex="-1"
            id="brand-menu-changelog"
          >
            <.icon name="hero-list-bullet" class="size-4" /> {gettext("Changelog")}
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
  # (a clean compile), and then the brand menu shows none.
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

  # Where the switcher leads: to a workspace of a membership, the section the user is on,
  # when they may open it there too, else the first entry they may open there, the
  # overview for a reader of the record. Asked with the scope that membership, and what the
  # edition says of it, give. A membership that reaches no workspace leads to its
  # organisation's own path, which says so.
  defp switch_path(_nav, _entries, %{organisation: organisation}, nil), do: ~p"/#{organisation}"

  defp switch_path(nav, entries, %{organisation: organisation} = place, workspace) do
    scope = place_scope(place, workspace)
    places = [:workspace, :organisation]
    may? = &(&1.place in places and nav_open?(scope, &1.action, workspace))

    entry =
      Enum.find(entries, &(&1.key == nav and may?.(&1))) ||
        Enum.find(entries, &(&1.place == :workspace and may?.(&1)))

    # A page of a feature may be absent there: the feature is the destination's to say, so
    # the link asks it when followed (`ApiaryWeb.SwitchController`), rather than every
    # place's features being read for every page.
    if of_feature?(entry),
      do: ~p"/#{organisation}/#{workspace}/switch/#{entry.key}",
      else: Entry.path(entry, organisation, workspace)
  end

  defp of_feature?(%Entry{action: nil}), do: false
  # The overview is where it would fall back to anyway.
  defp of_feature?(%Entry{key: :overview}), do: false
  defp of_feature?(%Entry{action: action}), do: not is_nil(Access.feature(action))

  @doc """
  switch_target/2 is where the switcher's link to a workspace leads once followed, asked
  with the scope of that workspace: the page of the navigation entry named `key` where the
  reader may open it there, its feature on there too, else the workspace's overview.
  """
  @spec switch_target(Apiary.Accounts.Scope.t(), String.t()) :: String.t()
  def switch_target(scope, key) do
    found =
      Enum.find(palette_entries(scope), fn {entry, _path} ->
        entry.place in [:workspace, :organisation] and Atom.to_string(entry.key) == key
      end)

    case found do
      {_entry, path} -> path
      nil -> ~p"/#{scope.organisation}/#{scope.workspace}"
    end
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
  defp nav_open?(scope, action, subject), do: Access.can?(scope, action, subject)

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
