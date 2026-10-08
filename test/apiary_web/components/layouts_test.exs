defmodule ApiaryWeb.LayoutsTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  # The words of the first element `selector` finds, its spaces collapsed.
  defp text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.take(1)
    |> Enum.map_join(&LazyHTML.text/1)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The breadcrumb's segments, each as its words: the items of its trail alone, not those
  # of the switcher the breadcrumb also holds, whose places and edition's entries
  # (`ApiaryWeb.Edition.switcher_entries/1`) are no segments.
  defp trail(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#breadcrumb ol.q-trail > li")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/[\s\/]+/, " ") |> String.trim()))
  end

  defp before?(html, first, second) do
    {a, _} = :binary.match(html, first)
    {b, _} = :binary.match(html, second)
    a < b
  end

  describe "the app shell" do
    setup :register_and_log_in_user

    test "the top bar comes first and spans the window; the sidebar, then main, below it",
         %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#shell > header#top-bar[aria-label='Top bar']")
      assert before?(html, ~s(id="top-bar"), ~s(id="sidebar"))
      assert before?(html, ~s(id="sidebar"), ~s(id="main"))
      assert has_element?(view, "#shell-content > main#main")
      assert has_element?(view, "aside#sidebar[aria-label='Workspace'] nav[aria-label='Main']")
      assert has_element?(view, "aside#sidebar nav[aria-label='Record']")
    end

    test "the top bar: where the page is, the organisation first, Search or jump to, New, then the account menu",
         %{conn: conn, user: user, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      # No mark: Qory Apiary is the sidebar's foot. The bar starts with the organisation.
      refute has_element?(view, "#top-bar-home")
      refute has_element?(view, "#top-bar #brand-menu")

      # the breadcrumb: the organisation and the workspace, each a link to its home
      assert has_element?(
               view,
               "#top-bar nav#breadcrumb[aria-label='Where you are'] li:first-child a[href='/#{scope.organisation.slug}']",
               scope.organisation.name
             )

      assert before?(html, ~s(id="nav-drawer-open"), ~s(id="breadcrumb"))

      assert has_element?(
               view,
               "#breadcrumb a[href='#{workspace_path(scope)}']",
               scope.workspace.name
             )

      assert has_element?(
               view,
               "#top-bar button#palette-open[aria-controls='palette'][aria-keyshortcuts='Meta+K Control+K /']"
             )

      assert has_element?(view, "#top-bar #new-menu[phx-hook='Menu'] #new-menu-button")

      assert has_element?(
               view,
               "#top-bar #user-menu-button[aria-haspopup='menu'][aria-label='Account menu, #{user.email}']"
             )

      assert before?(html, ~s(id="breadcrumb"), ~s(id="palette-open"))
      assert before?(html, ~s(id="palette-open"), ~s(id="new-menu-button"))
      assert before?(html, ~s(id="new-menu-button"), ~s(id="user-menu-button"))

      # below 768 px the bar opens the drawer; the theme is in the account menu now
      assert has_element?(view, "#top-bar #nav-drawer-open[aria-label='Open menu'].md\\:hidden")
      refute has_element?(view, "#theme-menu-button")
    end

    test "New offers what the reader may start here", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      # A workspace's keys are its nodes': New offers no access key of its own.
      refute has_element?(view, "#new-menu-key")
      refute render(view) =~ "New access key"

      assert has_element?(
               view,
               "#new-menu a#new-menu-invite[href='/#{scope.organisation.slug}/settings/people/invite']",
               "Invite people"
             )

      # A workspace's things, for an owner: a node, a node pool, a secret and a variable
      # (with the security feature), each its own form page.
      assert has_element?(view, "#new-menu-node[href='#{workspace_path(scope, "/nodes/new")}']")

      assert has_element?(
               view,
               "#new-menu-node_pool[href='#{workspace_path(scope, "/nodes/new-pool")}']"
             )

      assert has_element?(
               view,
               "#new-menu-secret[href='#{workspace_path(scope, "/settings/secrets/new")}']"
             ) == Apiary.Features.on?(:security)

      assert has_element?(
               view,
               "#new-menu-variable[href='#{workspace_path(scope, "/settings/variables/new")}']"
             ) == Apiary.Features.on?(:security)

      assert before?(render(view), ~s(id="new-menu-node"), ~s(id="new-menu-invite"))

      # a member adds no node, no key and no secret, and invites nobody
      %{user: member} = member_fixture(scope, :member)
      {:ok, view, _html} = live(log_in_user(build_conn(), member), workspace_path(scope))
      refute has_element?(view, "#new-menu-invite")

      for key <- ~w(key node node_pool secret variable),
          do: refute(has_element?(view, "#new-menu-#{key}"), key)

      # an organisation's own page offers what the organisation holds: no key of a
      # workspace the page is not on
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#new-menu-invite")
      refute has_element?(view, "#new-menu-key")
      refute has_element?(view, "#new-menu-node")
    end

    test "the account menu: who you are, your settings and organisations, the theme, log out",
         %{conn: conn, user: user, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#user-menu[phx-hook='Menu']")
      menu = view |> element("#user-menu ul[role='menu'][aria-label='Account']") |> render()

      # The email, then "Your personal account" beneath it (an account has no name), then
      # Settings, the account's own: GitHub's pattern. No level of the place.
      assert before?(menu, user.email, "Your personal account")
      assert has_element?(view, "#user-menu-account", "Your personal account")
      assert before?(menu, "Your personal account", "Settings")
      assert has_element?(view, "#user-menu-settings", "Settings")
      refute has_element?(view, "#user-menu-settings", "Your settings")
      refute menu =~ "Owner of"
      refute has_element?(view, "#user-menu-level")
      assert before?(menu, "Settings", "Your organisations")
      assert before?(menu, "Your organisations", "Theme")
      assert before?(menu, "Theme", "Log out")
      refute menu =~ "Switch organisation"

      # Nothing about Qory Apiary: that is the brand menu's, at the sidebar's foot.
      refute menu =~ "Docs"
      refute menu =~ "Qory Apiary"

      for id <- ~w(user-menu-docs user-menu-changelog user-menu-source user-menu-version),
          do: refute(has_element?(view, "##{id}"), id)

      # a keyboard open focuses the first item: it is the first focusable thing in the list
      assert has_element?(
               view,
               "#user-menu .dropdown-content li:nth-child(3) a#user-menu-settings[role='menuitem'][href='/users/settings']"
             )

      assert has_element?(
               view,
               "#user-menu a#user-menu-organisations[href='/users/organisations']"
             )

      # the theme: three options in a group, the root layout's script sets it
      for theme <- ~w(system light dark) do
        assert has_element?(
                 view,
                 "#user-menu [role='group'] button#theme-menu-#{theme}[role='menuitemradio'][data-phx-theme='#{theme}']"
               )
      end

      assert has_element?(
               view,
               "#user-menu a#user-menu-log-out[href='/users/log-out'][data-method='delete']"
             )
    end

    test "a member's account menu names the account, not the level", %{
      conn: _conn,
      scope: scope
    } do
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      assert has_element?(view, "#user-menu-account", "Your personal account")
      refute render(view) =~ "Member of #{scope.organisation.name}"
    end

    test "a workspace's sidebar: its pages in groups, Settings at the foot, Qory Apiary, the fold",
         %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      # The policy's entry is there only on an instance with the security policy.
      policy = if Apiary.Features.on?(:security), do: [policy: workspace_path(scope, "/policy")]

      for {key, href} <-
            [
              overview: workspace_path(scope),
              runs: workspace_path(scope, "/runs"),
              targets: workspace_path(scope, "/targets"),
              nodes: workspace_path(scope, "/nodes"),
              network: workspace_path(scope, "/network")
            ] ++ List.wrap(policy) ++ [settings: workspace_path(scope, "/settings")] do
        assert has_element?(view, "#sidebar a#nav-#{key}[href='#{href}']"), "#{key}"
      end

      assert has_element?(view, "#nav-overview[aria-current='page']")
      assert before?(html, ~s(id="nav-group-home"), ~s(id="nav-group-record"))
      assert has_element?(view, "#nav-group-record #nav-runs")

      # Record: Runs, Targets, then the nodes they run on.
      assert has_element?(view, "#nav-group-record #nav-nodes")
      assert before?(html, ~s(id="nav-targets"), ~s(id="nav-nodes"))
      assert before?(html, ~s(id="nav-nodes"), ~s(id="nav-group-guard"))

      # Guard: Network access, then the rules that decide it.
      assert has_element?(view, "#nav-group-guard #nav-network")
      refute has_element?(view, "#nav-group-record #nav-network")

      if policy,
        do: assert(before?(html, ~s(id="nav-network"), ~s(id="nav-policy")))

      assert has_element?(view, ".q-sidebar-foot #nav-settings")

      # the organisation's pages and the pages of Settings are not a workspace's entries
      for key <- ~w(keys members activity organisation),
          do: refute(has_element?(view, "#nav-#{key}"), key)

      # The foot: Settings, then the Qory Apiary menu, opening upward, and the fold.
      assert has_element?(
               view,
               "#sidebar .q-sidebar-foot #brand-menu.dropdown-top[phx-hook='Menu'] button#brand-menu-button[aria-haspopup='menu']"
             )

      version = :apiary |> Application.spec(:vsn) |> List.to_string()
      assert has_element?(view, "#brand-menu-button #brand-version", version)

      assert has_element?(
               view,
               "#brand-menu-button[aria-label='Qory Apiary menu, version #{version}']"
             )

      assert has_element?(view, "#brand-menu a#brand-menu-docs[role='menuitem'][href='/docs']")
      # Instance settings is only for whoever may open a section of the Instance level.
      refute has_element?(view, "#brand-menu-instance")

      # The release notes name every feature: only an instance with every one links them.
      assert has_element?(view, "#brand-menu a#brand-menu-changelog[href='/docs/changelog.html']") ==
               (Apiary.Features.enabled() == Apiary.Features.all())

      assert has_element?(
               view,
               "#brand-menu a#brand-menu-source[href='https://github.com/qoryai/apiary'][rel='noopener'][target='_blank']"
             )

      # The fold is an icon: its name in its label and its tooltip, and the [ key.
      assert has_element?(
               view,
               "#brand-foot button#sidebar-collapse[data-sidebar-collapse][aria-keyshortcuts='['][aria-label='Collapse sidebar'][data-tip='Collapse sidebar'][data-label-folded='Expand sidebar']"
             )

      refute has_element?(view, "#sidebar-collapse .q-nav-text, #sidebar-collapse kbd")
      assert before?(html, ~s(id="nav-settings"), ~s(id="brand-menu"))
      assert before?(html, ~s(id="brand-menu"), ~s(id="sidebar-collapse"))

      # The drawer's head is its close button; the mark is the foot's.
      assert has_element?(
               view,
               "#sidebar .q-drawer-head button[data-drawer-close][aria-label='Close menu']"
             )

      refute has_element?(view, "#sidebar .q-drawer-head svg:not(.hero-x-mark)")
    end

    test "a workspace's settings keep the workspace's sidebar, Settings current, and list their own sections only",
         %{conn: conn, scope: scope} do
      org = scope.organisation
      ws = scope.workspace
      {:ok, view, _html} = live(conn, ~p"/#{org}/#{ws}/settings/runs")

      # The sidebar is the workspace's, its Settings the current entry, as the page's
      # parent: the page is the second column's entry; nothing replaces it.
      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "#nav-group-record #nav-runs:not([aria-current])")

      assert has_element?(
               view,
               ".q-sidebar-foot #nav-settings.q-nav-parent[aria-current='true']"
             )

      refute has_element?(view, "#nav-keys")
      refute has_element?(view, "#settings-back")

      # The page: the section is its one h1; the level leaves the page. The list of its
      # sections is the frame's second column, beside the sidebar and before the page, not
      # in it.
      assert has_element?(view, "#main h1#settings-section-title", "Runs")
      refute has_element?(view, "#main h1", "Workspace settings")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#main h1")
             |> Enum.count() ==
               1

      refute has_element?(view, "#main #settings-tabs")

      for {key, href} <- [
            general: ~p"/#{org}/#{ws}/settings",
            people: ~p"/#{org}/#{ws}/settings/people",
            runs: ~p"/#{org}/#{ws}/settings/runs"
          ] do
        assert has_element?(
                 view,
                 "#shell-content > nav#settings-tabs.q-second a#settings-tab-#{key}[href='#{href}']"
               ),
               "#{key}"
      end

      # The column's heading names the level, the workspace beneath it, and names the
      # column's navigation: "Workspace settings", not "Settings".
      assert has_element?(
               view,
               "nav#settings-tabs[aria-labelledby='settings-tabs-heading'] #settings-tabs-heading",
               "Workspace settings"
             )

      assert has_element?(view, "#settings-tabs #settings-tabs-place", ws.name)
      assert has_element?(view, "#settings-tab-runs[aria-current='page']")
      refute has_element?(view, "#settings-tab-keys")

      # The drawer holds the sidebar alone: no copy of the sections.
      refute has_element?(view, "#drawer-sections")

      # No other kind of settings, no cross-link, and nothing that cannot be undone: the
      # workspace's People is its own, the organisation's is not in the list.
      refute has_element?(view, "#settings-tab-organisation, #settings-tab-audit_log")
      refute has_element?(view, "#settings-tabs a[href='/#{org.slug}/settings/people']")
      refute has_element?(view, "#settings-tabs a[href='/#{org.slug}/settings']")
      refute has_element?(view, "#settings-tabs a[href='/users/settings']")
      refute has_element?(view, "#settings-tabs a[href$='/danger']")
      refute render(view) =~ "Elsewhere"

      # The breadcrumb: the organisation, the workspace, Workspace settings leading to its
      # General, then the section, the page.
      assert has_element?(view, "#breadcrumb a[href='#{workspace_path(scope)}']", ws.name)

      assert has_element?(
               view,
               "#breadcrumb a#breadcrumb-settings[href='/#{org.slug}/#{ws.slug}/settings']:not([aria-current])",
               "Workspace settings"
             )

      assert has_element?(
               view,
               "#breadcrumb span#breadcrumb-section[aria-current='page']",
               "Runs"
             )

      assert tl(trail(render(view))) == [ws.name, "Workspace settings", "Runs"]

      # The sidebar's foot names its level.
      assert has_element?(view, ".q-sidebar-foot #nav-settings .q-nav-text", "Workspace settings")

      # The browser title, the most specific first.
      assert page_title(view) ==
               "Runs · Workspace settings · #{ws.name} · #{org.name} · Qory Apiary"
    end

    test "an organisation's settings keep the organisation's sidebar and list their own sections",
         %{conn: conn, scope: scope} do
      org = scope.organisation

      for path <- [~p"/#{org}/settings", ~p"/#{org}/settings/people"] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "aside#sidebar[aria-label='Organisation']")
        refute has_element?(view, "#sidebar #nav-activity")

        assert has_element?(
                 view,
                 ".q-sidebar-foot a#nav-organisation[href='/#{org.slug}/settings'][aria-current='true']"
               )

        for key <- ~w(overview runs network policy settings members),
            do: refute(has_element?(view, "#nav-#{key}"), "#{path} #{key}")

        refute has_element?(view, "#main h1", "Organisation settings")

        assert has_element?(
                 view,
                 "#settings-tabs #settings-tabs-heading",
                 "Organisation settings"
               )

        assert has_element?(view, "#settings-tabs #settings-tabs-place", org.name)

        assert has_element?(
                 view,
                 ".q-sidebar-foot #nav-organisation .q-nav-text",
                 "Organisation settings"
               )

        for key <- ~w(organisation people workspaces),
            do: assert(has_element?(view, "#settings-tabs #settings-tab-#{key}"), key)

        refute has_element?(
                 view,
                 "#settings-tab-general, #settings-tab-keys, #settings-tab-danger, #settings-tab-audit_log"
               )

        # the breadcrumb names the organisation, no workspace, then Organisation settings
        # and the section
        assert has_element?(view, "#breadcrumb", org.name)
        refute has_element?(view, "#breadcrumb a[href='#{workspace_path(scope)}']")

        assert has_element?(
                 view,
                 "#breadcrumb a#breadcrumb-settings[href='/#{org.slug}/settings']",
                 "Organisation settings"
               )

        section = if path =~ "people", do: "People", else: "General"
        assert has_element?(view, "#breadcrumb-section[aria-current='page']", section)
        assert has_element?(view, "#main h1#settings-section-title", section)
        assert tl(trail(render(view))) == ["Organisation settings", section]

        assert page_title(view) ==
                 "#{section} · Organisation settings · #{org.name} · Qory Apiary"
      end
    end

    test "an organisation's page shows the organisation's sidebar", %{conn: conn, scope: scope} do
      for {path, current} <- [
            {~p"/#{scope.organisation}", "nav-organisation_overview"},
            {~p"/#{scope.organisation}/audit-log", "nav-audit_log"}
          ] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "aside#sidebar[aria-label='Organisation']")
        assert has_element?(view, "##{current}[aria-current='page']")

        # The audit log is an entry of the sidebar, beside the overview.
        assert has_element?(
                 view,
                 "#nav-group-home #nav-audit_log[href='/#{scope.organisation.slug}/audit-log']"
               )

        refute has_element?(view, "#sidebar #nav-activity")

        assert has_element?(
                 view,
                 ".q-sidebar-foot a#nav-organisation[href='/#{scope.organisation.slug}/settings']"
               )

        for key <- ~w(overview runs network policy settings members),
            do: refute(has_element?(view, "#nav-#{key}"), "#{path} #{key}")

        # the breadcrumb names the organisation and no workspace
        assert has_element?(view, "#breadcrumb", scope.organisation.name)
        refute has_element?(view, "#breadcrumb a[href='#{workspace_path(scope)}']")
      end
    end

    test "a person's own page keeps the workspace's sidebar, and their sections are the second column",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # The sidebar is the one they came from: the workspace's, nothing current in it.
      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "#sidebar #nav-runs[href='#{workspace_path(scope, "/runs")}']")
      refute has_element?(view, "#sidebar [aria-current='page']")
      refute has_element?(view, "#sidebar #nav-group-account")

      # Their sections, the second column, under Your settings.
      assert has_element?(
               view,
               "#shell-content > nav#nav-group-account.q-second[aria-labelledby='nav-group-account-heading']"
             )

      assert has_element?(view, "#nav-group-account-heading", "Your settings")

      assert has_element?(
               view,
               "#nav-group-account #nav-user_settings[href='/users/settings'][aria-current='page']"
             )

      assert has_element?(view, "#nav-user_preferences[href='/users/settings/preferences']")
      assert has_element?(view, "#nav-user_organisations[href='/users/organisations']")

      # The sidebar's foot is the workspace's, named after its level, and not current.
      assert has_element?(
               view,
               ".q-sidebar-foot #nav-settings:not([aria-current]) .q-nav-text",
               "Workspace settings"
             )

      # Profile is Account; the drawer has no copy of the sections.
      assert has_element?(view, "#nav-user_settings", "Account")
      refute has_element?(view, "#drawer-sections")

      # No other kind of settings, and no list in the page.
      refute has_element?(view, "#settings-tabs, #settings-back")
      assert has_element?(view, "#main h1", "Account")
      assert has_element?(view, "#breadcrumb a[href='/users/settings']", "Your settings")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "Account")
      refute has_element?(view, "#breadcrumb-settings")
      refute render(view) =~ "Profile"
      assert page_title(view) == "Account · Your settings · Qory Apiary"
    end

    test "one place: the breadcrumb's segments are links, with no switcher", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      case ApiaryWeb.Edition.switcher_entries(scope) do
        [] ->
          assert has_element?(view, "#breadcrumb #organisation-block", scope.organisation.name)
          refute has_element?(view, "#organisation-menu")
          refute has_element?(view, "#breadcrumb button")

        entries ->
          refute has_element?(view, "#organisation-block")

          for entry <- entries do
            assert has_element?(view, "#organisation-menu a#organisation-menu-#{entry.key}")
          end
      end
    end

    test "the breadcrumb's segments are its trail's, whatever the switcher beside them lists",
         %{conn: conn, user: user, scope: scope} do
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      ws = scope.workspace
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{ws}/settings/runs")
      html = render(view)

      # The switcher's places are items inside the breadcrumb too, and no segment of it.
      assert has_element?(view, "#breadcrumb #organisation-menu-panel li")

      assert html |> LazyHTML.from_fragment() |> LazyHTML.query("#breadcrumb li") |> Enum.count() >
               length(trail(html))

      assert tl(trail(html)) == [ws.name, "Workspace settings", "Runs"]
    end

    test "with several places the chevrons open the switcher: a search, then the places", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      refute has_element?(view, "#organisation-block")
      assert has_element?(view, "#breadcrumb #organisation-menu[phx-hook='Switcher']")

      for button <- ~w(organisation-menu-button workspace-menu-button) do
        assert has_element?(
                 view,
                 "#organisation-menu button##{button}[aria-controls='organisation-menu-panel'][aria-expanded='false']"
               )
      end

      assert has_element?(view, "#organisation-menu-panel[role='group'][hidden]")

      assert has_element?(
               view,
               "#organisation-menu-panel input#organisation-menu-search[aria-label='Find an organisation or workspace']"
             )

      # What the search leaves is said in a status line the Switcher hook fills.
      assert has_element?(
               view,
               "#organisation-menu-panel p#organisation-menu-status[role='status'][data-none][data-one][data-other]"
             )

      # plain links to each workspace's own URL, the current one marked; no form
      refute has_element?(view, "#organisation-menu form")

      assert has_element?(
               view,
               "#organisation-menu a[data-place][aria-current='true'][href='#{workspace_path(scope)}']"
             )

      assert has_element?(
               view,
               "#organisation-menu a[data-place]:not([aria-current])[href='#{workspace_path(other)}']",
               other.organisation.name
             )

      assert has_element?(
               view,
               "#organisation-menu-panel a#organisation-menu-organisations[href='/users/organisations']"
             )
    end

    test "the switcher lists each workspace the person reaches in each organisation", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      platform = workspace_fixture(scope.organisation, "Platform")
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      # An owner reaches both of their organisation's workspaces; a member the one they
      # were invited to.
      assert has_element?(view, "#switch-#{scope.organisation.slug}-#{scope.workspace.slug}")
      assert has_element?(view, "#switch-#{scope.organisation.slug}-#{platform.slug}")
      assert has_element?(view, "#switch-#{other.organisation.slug}-#{other.workspace.slug}")
    end

    test "switching keeps the section the user is on", %{conn: conn, user: user, scope: scope} do
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)
      switch = "#organisation-menu a[data-place]"

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes")
      assert has_element?(view, "#{switch}[href='#{workspace_path(other, "/nodes")}']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert has_element?(view, "#{switch}[href='/#{other.organisation.slug}/settings/people']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#{switch}[href='/#{other.organisation.slug}/settings']")

      # the link opens the other workspace, and the session remembers it for `/`
      conn = get(conn, workspace_path(other, "/nodes"))
      assert html_response(conn, 200) =~ other.organisation.name
      assert redirected_to(get(recycle(conn), ~p"/")) == workspace_path(other)
    end

    test "the palette asks the page's scope", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      assert has_element?(
               view,
               "dialog#palette[phx-hook='Palette'][phx-update='ignore'][data-url='#{workspace_path(scope, "/jump")}']"
             )

      assert has_element?(
               view,
               "#palette input#palette-input[role='combobox'][aria-controls='palette-results']"
             )

      assert has_element?(view, "#palette #palette-results[role='listbox']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/audit-log")
      assert has_element?(view, "dialog#palette[data-url='/#{scope.organisation.slug}/jump']")

      # A person's own page shows the workspace's sidebar: the palette asks that workspace,
      # as the frame shows, not the organisation.
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "dialog#palette[data-url='#{workspace_path(scope, "/jump")}']")
    end

    test "every menu of the frame and of a list's filters has a trigger the Menu hook finds",
         %{conn: conn, scope: scope} do
      js = File.read!(Path.expand("../../../assets/js/hooks/menu.js", __DIR__))
      [_, trigger] = Regex.run(~r/export const TRIGGER = "([^"]+)"/, js)

      for path <- [
            ~p"/#{scope.organisation}/audit-log",
            ~p"/#{scope.organisation}/#{scope.workspace}/runs",
            ~p"/#{scope.organisation}/#{scope.workspace}/network"
          ] do
        {:ok, view, _html} = live(conn, path)
        doc = view |> render() |> LazyHTML.from_fragment()
        menus = doc |> LazyHTML.query("[phx-hook=Menu]") |> Enum.to_list()
        assert menus != [], path

        for menu <- menus do
          [id] = LazyHTML.attribute(menu, "id")
          found = menu |> LazyHTML.query(trigger) |> Enum.take(1)
          # The first match is the menu's own button, which says whether it is open.
          assert [[button_id]] = Enum.map(found, &LazyHTML.attribute(&1, "id")), "#{path} #{id}"
          assert button_id == "#{id}-button", "#{path} #{id}"
          assert [_] = Enum.flat_map(found, &LazyHTML.attribute(&1, "aria-expanded"))
        end
      end

      # The audit log's chips are among them: disclosures, found by aria-controls.
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/audit-log")

      assert has_element?(
               view,
               "#filter-action[phx-hook=Menu] #filter-action-button[aria-controls][aria-expanded]"
             )
    end

    test "the organisation's notices describe the title that takes the focus", %{
      conn: conn,
      scope: scope
    } do
      # Above the page, in a box of no size of their own, named for the script.
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      assert has_element?(view, "#main > .q-page > div > #shell-notices.contents")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#shell-notices")

      # A person's own pages carry none.
      {:ok, view, _html} = live(conn, ~p"/users/settings")
      refute has_element?(view, "#shell-notices")
    end

    test "a page's own segments end the breadcrumb, the last one the page", %{
      conn: conn,
      scope: scope
    } do
      run = Apiary.RunListFixtures.started_run(scope, Apiary.RunListFixtures.shop())
      short = String.slice(run.run_id, 0, 8)

      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      assert has_element?(view, "#breadcrumb a", "acme/shop")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "Run #{short}")
      assert has_element?(view, "#nav-runs[aria-current='page']")
    end

    test "the page title carries the product name as its suffix", %{conn: conn, scope: scope} do
      {:ok, _view, html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      name = Regex.escape(scope.organisation.name)

      assert html =~
               ~r{<title[^>]*>\s*People · Organisation settings · #{name} · Qory Apiary\s*</title>}
    end
  end

  describe "the pinned targets" do
    test "a workspace's sidebar lists the targets the counts carry, and nothing without them" do
      %{scope: scope} = sign_up_fixture()

      shop = Ecto.UUID.generate()
      api = Ecto.UUID.generate()

      pins = [
        %{id: shop, system: "github.example", path: "acme/shop", shared: true},
        %{id: api, system: "github.example", path: "acme/api", shared: false}
      ]

      html = shell(scope, :runs, %{pins: pins})
      assert html =~ ~s(id="nav-group-pinned")
      assert html =~ ~s(id="nav-pin-#{shop}")
      # A pin's address is its path, with its system only where the path is shared.
      assert html =~ ~s(href="#{workspace_path(scope, "/targets/acme/api")}")
      assert html =~ ~s(href="#{workspace_path(scope, "/targets/github.example/acme/shop")}")
      assert before?(html, "acme/shop", "acme/api")
      # The system shows where the same path is in another system, and nowhere else.
      assert html =~ ~r{q-nav-pin-sys">\s*github.example/\s*</span>\s*acme/shop}
      refute html =~ ~r{q-nav-pin-sys">\s*github.example/\s*</span>\s*acme/api}

      refute shell(scope, :runs, %{}) =~ "nav-group-pinned"
      # an organisation's page lists none
      refute shell(scope, :activity, %{pins: pins}) =~ "nav-group-pinned"
    end

    defp shell(scope, nav, counts) do
      assigns = %{scope: scope, nav: nav, counts: counts}

      ~H"""
      <ApiaryWeb.Layouts.app flash={%{}} current_scope={@scope} nav={@nav} counts={@counts}>
        <p>page</p>
      </ApiaryWeb.Layouts.app>
      """
      |> rendered_to_string()
    end
  end

  describe "narrowing, carried by the sidebar" do
    setup do
      %{scope: sign_up_fixture().scope}
    end

    test "on Runs narrowed to a target, Runs and Network access carry it; every other entry links plainly",
         %{scope: scope} do
      narrowed = ApiaryWeb.Layouts.narrowed({"github.example", "acme/shop"}, MapSet.new())

      for nav <- [:runs, :network] do
        html = narrowed_shell(scope, nav, narrowed)

        assert attribute(html, "#nav-runs", "href") ==
                 workspace_path(scope, "/runs?target=acme%2Fshop")

        assert attribute(html, "#nav-network", "href") ==
                 workspace_path(scope, "/network?target=acme%2Fshop")

        assert attribute(html, "#nav-runs", "aria-label") == "Runs, narrowed to acme/shop"
        assert attribute(html, "#nav-runs", "title") == "Runs, narrowed to acme/shop"
        assert attribute(html, "#nav-runs", "data-title") == "Runs, narrowed to acme/shop"

        assert attribute(html, "#nav-network", "aria-label") ==
                 "Network access, narrowed to acme/shop"

        for {key, path} <- [overview: "", targets: "/targets", settings: "/settings"] do
          assert attribute(html, "#nav-#{key}", "href") == workspace_path(scope, path)
          assert attribute(html, "#nav-#{key}", "aria-label") == nil
        end

        if Apiary.Features.on?(:security),
          do: assert(attribute(html, "#nav-policy", "href") == workspace_path(scope, "/policy"))
      end
    end

    test "the system is carried only where two systems share the path", %{scope: scope} do
      shared =
        ApiaryWeb.Layouts.narrowed({"gitlab.example", "acme/shop"}, MapSet.new(["acme/shop"]))

      html = narrowed_shell(scope, :runs, shared)

      assert attribute(html, "#nav-network", "href") ==
               workspace_path(scope, "/network?system=gitlab.example&target=acme%2Fshop")

      assert attribute(html, "#nav-network", "aria-label") ==
               "Network access, narrowed to gitlab.example/acme/shop"

      # A path on every system, as `?target=` alone reads it.
      html = narrowed_shell(scope, :network, ApiaryWeb.Layouts.narrowed({nil, "acme/shop"}, true))

      assert attribute(html, "#nav-runs", "href") ==
               workspace_path(scope, "/runs?target=acme%2Fshop")
    end

    test "nothing carries on any other page, or without a target", %{scope: scope} do
      narrowed = ApiaryWeb.Layouts.narrowed({"github.example", "acme/shop"}, false)

      for nav <- [:overview, :targets, :policy, :settings] do
        html = narrowed_shell(scope, nav, narrowed)
        assert attribute(html, "#nav-runs", "href") == workspace_path(scope, "/runs"), "#{nav}"
        assert attribute(html, "#nav-network", "href") == workspace_path(scope, "/network")
        assert attribute(html, "#nav-runs", "aria-label") == nil
      end

      html = narrowed_shell(scope, :runs, nil)
      assert attribute(html, "#nav-network", "href") == workspace_path(scope, "/network")

      assert ApiaryWeb.Layouts.narrowed(:none, MapSet.new()) == nil
      assert ApiaryWeb.Layouts.narrowed(nil, MapSet.new()) == nil
    end

    defp narrowed_shell(scope, nav, narrowed) do
      assigns = %{scope: scope, nav: nav, narrowed: narrowed}

      ~H"""
      <ApiaryWeb.Layouts.app
        flash={%{}}
        current_scope={@scope}
        nav={@nav}
        counts={%{}}
        narrowed={@narrowed}
      >
        <p>page</p>
      </ApiaryWeb.Layouts.app>
      """
      |> rendered_to_string()
    end
  end

  describe "the account menu and the Instance" do
    setup do
      %{scope: sign_up_fixture().scope}
    end

    test "the account menu holds the person's own; Instance settings is the Qory Apiary menu's",
         %{scope: scope} do
      html = level_shell(scope, %{place: :workspace, counts: %{}})
      assert attribute(html, "#user-menu-settings", "href") == "/users/settings"
      assert attribute(html, "#user-menu-organisations", "href") == "/users/organisations"
      refute html =~ ~s(id="user-menu-instance")
      refute html =~ ~s(id="brand-menu-instance")

      # Where a section of the Instance level is open: Instance settings, first in the Qory
      # Apiary menu, leading to the first section, then a rule before Docs. The account
      # menu has no Instance.
      for given <- [%{place: :workspace}, %{place: :instance, section: :accounts}] do
        html = level_shell(scope, Map.put(given, :counts, %{instance: instance_sections()}))
        refute html =~ ~s(id="user-menu-instance")

        link = "#sidebar .q-sidebar-foot #brand-menu ul[role='menu'] > li > a#brand-menu-instance"
        assert attribute(html, link, "href") == "/instance/organisations"
        assert attribute(html, link, "role") == "menuitem"
        assert text(html, "#brand-menu-instance") == "Instance settings"

        assert attribute(
                 html,
                 "#brand-menu li:has(#brand-menu-instance) + li.menu-divider",
                 "role"
               ) == "separator"

        assert before?(html, ~s(id="brand-menu-instance"), ~s(id="brand-menu-docs"))
      end

      assert [%{key: :settings}, %{key: :organisations}] =
               ApiaryWeb.Layouts.account_menu_entries(scope)

      assert ApiaryWeb.Layouts.instance_sections(scope) == []
      assert ApiaryWeb.Layouts.instance_sections(nil) == []
    end

    test "an Instance page keeps the sidebar it came from; its sections are the second column",
         %{scope: scope} do
      html =
        level_shell(scope, %{
          place: :instance,
          section: :accounts,
          counts: %{instance: instance_sections()}
        })

      assert attribute(html, "aside#sidebar", "aria-label") == "Workspace"
      assert attribute(html, "#instance-tabs .q-second-heading #instance-tabs-heading", "id")
      # The level's name, as Workspace settings and Organisation settings.
      assert text(html, "#instance-tabs-heading") == "Instance settings"
      assert attribute(html, "#instance-tabs", "aria-labelledby") == "instance-tabs-heading"
      refute html =~ ~s(id="instance-tabs-place")
      assert attribute(html, "#instance-tab-organisations", "href") == "/instance/organisations"
      assert attribute(html, "#instance-tab-accounts", "aria-current") == "page"
      refute html =~ ~s(id="drawer-sections")
      assert attribute(html, "#breadcrumb a", "href") == "/instance/organisations"
      # With a second column, a phone's bar names the section alone: the disclosure names
      # the level.
      assert attribute(html, "#breadcrumb li", "class") =~ "q-trail-lead"
      assert trail(html) == ["Instance settings", "Accounts"]
      assert html =~ ~r{id="breadcrumb".*Instance settings.*aria-current="page"[^>]*>\s*Accounts}s

      # One section opens no second column.
      html =
        level_shell(scope, %{
          place: :instance,
          section: :organisations,
          counts: %{instance: Enum.take(instance_sections(), 1)}
        })

      refute html =~ ~s(id="instance-tabs")
      refute html =~ ~s(id="settings-disclosure")

      # With no second column, a phone's bar keeps both: Instance settings / Organisations.
      assert trail(html) == ["Instance settings", "Organisations"]
      refute attribute(html, "#breadcrumb li", "class") =~ "q-trail-lead"
      refute attribute(html, "#breadcrumb .q-trail-sep", "class") =~ "max-md:hidden"
    end

    test "with no workspace, a person's and an Instance page stand alone in the person's column",
         %{scope: scope} do
      scope = %{scope | workspace: nil}

      for {place, nav} <- [person: :user_settings, instance: nil] do
        html =
          level_shell(scope, %{
            place: place,
            nav: nav,
            section: :accounts,
            counts: %{instance: instance_sections()}
          })

        assert attribute(html, "aside#sidebar", "aria-label") == "Your account"
        assert attribute(html, "#sidebar #nav-group-account #nav-user_settings", "href")
        refute html =~ ~s(id="nav-overview")
        if place == :person, do: refute(html =~ "q-has-second")
      end
    end

    test "a level's settings with one section open no second column", %{scope: scope} do
      [general | _] = ApiaryWeb.SettingsComponents.sections(scope, :workspace)

      html = level_shell(scope, %{nav: :settings, sections: [general], section: :general})
      refute html =~ ~s(id="settings-tabs")
      refute html =~ "q-has-second"

      # Without a second column Settings is the page itself; with one, its parent.
      assert attribute(html, "#nav-settings", "aria-current") == "page"
      refute attribute(html, "#nav-settings", "class") =~ "q-nav-parent"

      html =
        level_shell(scope, %{
          nav: :settings,
          sections: ApiaryWeb.SettingsComponents.sections(scope, :workspace),
          section: :general
        })

      assert html =~ "q-has-second"
      assert attribute(html, "#settings-tab-general", "aria-current") == "page"
      assert attribute(html, "#nav-settings", "aria-current") == "true"
      assert attribute(html, "#nav-settings", "class") =~ "q-nav-parent"
    end

    test "a page under a section, with segments of its own, has the section as its parent",
         %{scope: scope} do
      assigns = %{
        scope: scope,
        sections: ApiaryWeb.SettingsComponents.sections(scope, :workspace)
      }

      html =
        rendered_to_string(~H"""
        <ApiaryWeb.Layouts.app
          flash={%{}}
          current_scope={@scope}
          nav={:settings}
          sections={@sections}
          section={:runs}
        >
          <:crumb>Retention of events</:crumb>
          <p>page</p>
        </ApiaryWeb.Layouts.app>
        """)

      # The section and Workspace settings are the page's parents; the page is the
      # breadcrumb's last. The frame writes the level and the section; the page, the rest.
      assert attribute(html, "#settings-tab-runs", "aria-current") == "true"
      assert attribute(html, "#nav-settings", "aria-current") == "true"
      refute html =~ ~r{id="(settings-tab|nav)-[a-z_]+"[^>]*aria-current="page"}
      assert html =~ ~r{aria-current="page"[^>]*>\s*Retention of events}

      org = scope.organisation.slug
      ws = scope.workspace.slug

      # (the organisation's segment starts with its avatar's initial)
      assert tl(trail(html)) == [
               scope.workspace.name,
               "Workspace settings",
               "Runs",
               "Retention of events"
             ]

      assert attribute(html, "a#breadcrumb-settings", "href") == "/#{org}/#{ws}/settings"
      assert attribute(html, "a#breadcrumb-section", "href") == "/#{org}/#{ws}/settings/runs"
      refute attribute(html, "#breadcrumb-section", "aria-current")

      # A page may lead its section's segment elsewhere, such as a tab of it or its list
      # as it was found, and mark the section as its parent without segments of its own,
      # as a tab other than the one the section's entry leads to does (Variables).
      html =
        rendered_to_string(~H"""
        <ApiaryWeb.Layouts.app
          flash={%{}}
          current_scope={@scope}
          nav={:settings}
          sections={@sections}
          section={:people}
          section_path="/acme/shop/settings/people?q=dana"
          section_current="true"
        >
          <:crumb>Dana</:crumb>
          <p>page</p>
        </ApiaryWeb.Layouts.app>
        """)

      assert attribute(html, "a#breadcrumb-section", "href") ==
               "/acme/shop/settings/people?q=dana"

      assert attribute(html, "#settings-tab-people", "aria-current") == "true"

      html =
        rendered_to_string(~H"""
        <ApiaryWeb.Layouts.app
          flash={%{}}
          current_scope={@scope}
          nav={:settings}
          sections={@sections}
          section={:runs}
          section_current="true"
        >
          <p>page</p>
        </ApiaryWeb.Layouts.app>
        """)

      assert attribute(html, "#settings-tab-runs", "aria-current") == "true"
      assert attribute(html, "span#breadcrumb-section", "aria-current") == "page"
    end

    test "a person's page under a section names it in the breadcrumb, then its own segments",
         %{scope: scope} do
      assigns = %{scope: scope}

      html =
        rendered_to_string(~H"""
        <ApiaryWeb.Layouts.app flash={%{}} current_scope={@scope} nav={:user_organisations}>
          <:crumb>New organisation</:crumb>
          <p>page</p>
        </ApiaryWeb.Layouts.app>
        """)

      trail =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#breadcrumb li")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/[\s\/]+/, " ") |> String.trim()))

      assert trail == ["Your settings", "Organisations", "New organisation"]

      assert attribute(html, "#breadcrumb a[href='/users/organisations']", "class") =~
               "q-trail-link"

      assert html =~ ~r{id="breadcrumb".*aria-current="page"[^>]*>\s*New organisation}s
      assert attribute(html, "#nav-user_organisations", "aria-current") == "true"

      # Without segments the section is the page.
      html =
        rendered_to_string(~H"""
        <ApiaryWeb.Layouts.app flash={%{}} current_scope={@scope} nav={:user_organisations}>
          <p>page</p>
        </ApiaryWeb.Layouts.app>
        """)

      refute attribute(html, "#breadcrumb a[href='/users/organisations']", "href")
      assert html =~ ~r{id="breadcrumb".*aria-current="page"[^>]*>\s*Organisations}s
      assert attribute(html, "#nav-user_organisations", "aria-current") == "page"
    end

    test "below 1024 px the second column is one disclosure: a button over the same links",
         %{scope: scope} do
      for {given, label} <- [
            {%{
               nav: :settings,
               sections: ApiaryWeb.SettingsComponents.sections(scope, :workspace),
               section: :general
             }, "Workspace settings · #{scope.workspace.name}"},
            {%{place: :instance, section: :accounts, counts: %{instance: instance_sections()}},
             "Instance settings"},
            {%{place: :person, nav: :user_preferences}, "Your settings"}
          ] do
        html = level_shell(scope, given)

        [list] =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(".q-second-list")
          |> LazyHTML.attribute("id")

        # The button names the level and the place, opens the list in place, and Escape on
        # it or on a link of the list closes it and gives it the focus back.
        button = "nav.q-second > button#settings-disclosure"
        assert attribute(html, button, "type") == "button"
        assert attribute(html, button, "aria-expanded") == "false"
        assert attribute(html, button, "aria-controls") == list
        assert attribute(html, button, "phx-click") =~ "toggle_attr"
        assert attribute(html, button, "phx-key") == "Escape"
        assert attribute(html, button, "phx-keydown") =~ "aria-expanded"
        assert attribute(html, button, "phx-keydown") =~ "focus"

        text =
          html
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(button)
          |> LazyHTML.text()
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        assert text == label

        # The separator is seen, not read: the button's name is the level and the place.
        # The column's heading carries the place's full name, which it may cut short.
        if label =~ " · " do
          assert html =~ ~s(<span aria-hidden="true"> · </span>)

          assert attribute(html, "nav.q-second .q-second-place", "title") ==
                   scope.workspace.name
        end

        # The list follows the button, every link in it, each closing on Escape.
        assert before?(html, ~s(id="settings-disclosure"), ~s(id="#{list}"))
        assert attribute(html, "##{list} a.q-second-link", "phx-key") == "Escape"

        # The drawer holds the sidebar alone.
        refute html =~ ~s(id="drawer-sections")
      end

      # The stylesheet: the button below 1024 px, the column's heading from 1024 px; the
      # list shown while the button is expanded.
      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

      assert css =~
               ~r/\.q-second-toggle\[aria-expanded="true"\] \+ \.q-second-list \{\s*display: grid;/

      assert css =~
               ~r/@media \(min-width: 1024px\) \{[^@]*?\.q-second-toggle \{\s*display: none;/s

      refute css =~ "q-drawer-sections"
    end

    defp instance_sections do
      for {key, label} <- [organisations: "Organisations", accounts: "Accounts"] do
        %ApiaryWeb.Nav.Entry{
          key: key,
          label: label,
          path: "/instance/#{key}",
          place: :instance,
          section: :instance
        }
      end
    end

    defp level_shell(scope, given) do
      assigns =
        Map.merge(
          %{scope: scope, nav: nil, place: nil, section: nil, sections: nil, counts: %{}},
          given
        )

      ~H"""
      <ApiaryWeb.Layouts.app
        flash={%{}}
        current_scope={@scope}
        nav={@nav}
        place={@place}
        counts={@counts}
        sections={@sections}
        section={@section}
      >
        <p>page</p>
      </ApiaryWeb.Layouts.app>
      """
      |> rendered_to_string()
    end
  end

  describe "the Instance, for an instance admin" do
    setup :register_and_log_in_user

    test "the Qory Apiary menu's Instance settings leads to the first section for an instance admin, and is absent for anyone else",
         %{conn: conn, user: user, scope: scope} do
      home = ~p"/#{scope.organisation}/#{scope.workspace}"

      {:ok, view, _html} = live(conn, home)
      refute has_element?(view, "#brand-menu-instance")

      {:ok, %{granted?: true}} = Organisations.grant_instance_admin(user)
      [first | _] = ApiaryWeb.Layouts.instance_sections(scope)
      path = ApiaryWeb.Nav.Entry.path(first, scope.organisation, scope.workspace)

      {:ok, view, _html} = live(conn, home)

      assert has_element?(
               view,
               "#sidebar #brand-menu a#brand-menu-instance[href='#{path}']",
               "Instance settings"
             )

      refute has_element?(view, "#user-menu-instance")

      # The sidebar is the one they came from, and the palette asks its workspace. The
      # core's one section opens no second column; with an edition's sections before it,
      # the column lists it too. The drawer never copies the sections.
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      refute has_element?(view, "#drawer-sections")

      case ApiaryWeb.Layouts.instance_sections(scope) do
        [_configuration] ->
          refute has_element?(view, "#instance-tabs")

        [_, _ | _] ->
          assert has_element?(
                   view,
                   "#instance-tabs a#instance-tab-configuration[href='/instance/configuration'][aria-current='page']"
                 )
      end

      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "dialog#palette[data-url='#{workspace_path(scope, "/jump")}']")
    end
  end

  describe "the person with no organisation" do
    test "their pages have the person's sidebar, and no palette, New or breadcrumb of a place",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/users/organisations")

      assert has_element?(view, "aside#sidebar[aria-label='Your account']")
      assert has_element?(view, "#nav-group-account #nav-user_organisations[aria-current='page']")
      refute has_element?(view, "#palette-open, #palette, #new-menu")

      assert has_element?(
               view,
               "#top-bar #user-menu-button[aria-label='Account menu, #{user.email}']"
             )

      assert has_element?(view, "#user-menu-account", "Your personal account")
      assert has_element?(view, "#sidebar #brand-menu a#brand-menu-docs[href='/docs']")
      assert html =~ ~r{<title[^>]*>\s*No workspace yet · Qory Apiary\s*</title>}
    end
  end

  describe "a page without a person" do
    test "has no sidebar, and the Qory Apiary menu opens downward from the bar" do
      assigns = %{}

      html =
        ~H"""
        <ApiaryWeb.Layouts.app flash={%{}} current_scope={nil}>
          <p>page</p>
        </ApiaryWeb.Layouts.app>
        """
        |> rendered_to_string()

      refute html =~ ~s(id="sidebar")
      refute html =~ ~s(id="breadcrumb")
      refute html =~ ~s(id="user-menu")
      assert html =~ ~r{<header[^>]*id="top-bar".*id="brand-menu"}s
      refute html =~ "dropdown-top"
      assert html =~ ~s(id="brand-menu-docs")
      assert html =~ "hero-chevron-down-micro"
    end
  end

  describe "the title" do
    test "defaults to Qory Apiary", %{conn: conn} do
      response = conn |> get(~p"/") |> html_response(200)
      assert response =~ ~s(<title phx-r data-default="Qory Apiary" data-suffix=" · Qory Apiary">)
      assert response =~ ~r{<title[^>]*>\s*Welcome · Qory Apiary\s*</title>}
      assert response =~ "Welcome to Qory Apiary"
    end
  end

  describe "the auth panel" do
    test "the slogan is one sentence with its accented words", %{conn: conn} do
      response = conn |> get(~p"/") |> html_response(200)

      assert response =~
               ~s(Can you trust your agents? With Qory <span class="text-accent">you don&#39;t have to</span>.)

      # The line under it, by the instance's features.
      assert response =~
               "Every run of a connected machine reports to Qory Apiary: its session, terminal and every connection, with the decision and rule behind it." ==
               Apiary.Features.on?(:security)
    end
  end

  describe "the reader" do
    test "the body hands the scripts the locale and the time zone the server formats in", %{
      conn: conn
    } do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(data-locale="en-GB")
      assert html =~ ~s(data-time-zone="Etc/UTC")
    end
  end

  describe "time_ago" do
    test "says the time as people say it, with the count's plural" do
      now = ~U[2026-09-20 14:04:00Z]
      time = &ApiaryWeb.Format.time_ago(&1, now)

      assert time.(~U[2026-09-20 14:03:30Z]) == "Just now"
      assert time.(~U[2026-09-20 14:03:00Z]) == "1 minute ago"
      assert time.(~U[2026-09-20 14:02:00Z]) == "2 minutes ago"
      assert time.(~U[2026-09-20 13:00:00Z]) == "1 hour ago"
      assert time.(~U[2026-09-20 11:00:00Z]) == "3 hours ago"
      assert time.(~U[2026-09-19 16:40:03Z]) == "Yesterday, 16:40"
      assert time.(~U[2026-09-17 10:00:00Z]) == "3 days ago"
      assert time.(~U[2026-09-01 10:00:00Z]) == "1 Sept 2026"
    end
  end
end
