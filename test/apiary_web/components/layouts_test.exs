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

      assert has_element?(
               view,
               "#new-menu a#new-menu-key[role='menuitem'][href='#{workspace_path(scope, "/settings/keys/new")}']",
               "New access key"
             )

      assert has_element?(
               view,
               "#new-menu a#new-menu-invite[href='/#{scope.organisation.slug}/settings/people/invite']",
               "Invite people"
             )

      # a member creates keys and invites nobody
      %{user: member} = member_fixture(scope, :member)
      {:ok, view, _html} = live(log_in_user(build_conn(), member), workspace_path(scope))
      assert has_element?(view, "#new-menu-key")
      refute has_element?(view, "#new-menu-invite")

      # an organisation's own page offers what the organisation holds: no key of a
      # workspace the page is not on
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#new-menu-invite")
      refute has_element?(view, "#new-menu-key")
    end

    test "the account menu: who you are, your settings and organisations, the theme, log out",
         %{conn: conn, user: user, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#user-menu[phx-hook='Menu']")
      menu = view |> element("#user-menu ul[role='menu'][aria-label='Account']") |> render()
      assert menu =~ user.email
      assert menu =~ "Owner of #{scope.organisation.name}"
      assert before?(menu, "Your settings", "Your organisations")
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

    test "a member's account menu says so", %{conn: _conn, scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      conn = log_in_user(build_conn(), member)
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      assert has_element?(view, "#user-menu-level", "Member of #{scope.organisation.name}")
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
              network: workspace_path(scope, "/network")
            ] ++ List.wrap(policy) ++ [settings: workspace_path(scope, "/settings")] do
        assert has_element?(view, "#sidebar a#nav-#{key}[href='#{href}']"), "#{key}"
      end

      assert has_element?(view, "#nav-overview[aria-current='page']")
      assert before?(html, ~s(id="nav-group-home"), ~s(id="nav-group-record"))
      assert has_element?(view, "#nav-group-record #nav-runs")

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
      {:ok, view, _html} = live(conn, ~p"/#{org}/#{ws}/settings/keys")

      # The sidebar is the workspace's, its Settings the current entry; nothing replaces it.
      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "#nav-group-record #nav-runs:not([aria-current])")
      assert has_element?(view, ".q-sidebar-foot #nav-settings[aria-current='page']")
      refute has_element?(view, "#nav-keys")
      refute has_element?(view, "#settings-back")

      # The page: Workspace settings and the section; the list of its sections is the
      # frame's second column, beside the sidebar and before the page, not in it.
      assert has_element?(view, "#main h1", "Workspace settings")
      refute has_element?(view, "#main #settings-tabs")

      for {key, href} <- [
            general: ~p"/#{org}/#{ws}/settings",
            people: ~p"/#{org}/#{ws}/settings/people",
            keys: ~p"/#{org}/#{ws}/settings/keys",
            runs: ~p"/#{org}/#{ws}/settings/runs"
          ] do
        assert has_element?(
                 view,
                 "#shell-content > nav#settings-tabs.q-second a#settings-tab-#{key}[href='#{href}']"
               ),
               "#{key}"

        # On phones the drawer lists them under Settings.
        assert has_element?(
                 view,
                 "#sidebar .q-sidebar-foot #drawer-sections a#drawer-section-#{key}[href='#{href}']"
               ),
               "#{key}"
      end

      assert has_element?(view, "#settings-tabs-heading", "Settings")
      assert has_element?(view, "#settings-tab-keys[aria-current='page']")
      assert has_element?(view, "#drawer-section-keys[aria-current='page']")
      assert has_element?(view, "#main h2#settings-section-title", "Access keys")

      # No other kind of settings, no cross-link, and nothing that cannot be undone: the
      # workspace's People is its own, the organisation's is not in the list.
      refute has_element?(view, "#settings-tab-organisation, #settings-tab-audit_log")
      refute has_element?(view, "#settings-tabs a[href='/#{org.slug}/settings/people']")
      refute has_element?(view, "#settings-tabs a[href='/#{org.slug}/settings']")
      refute has_element?(view, "#settings-tabs a[href='/users/settings']")
      refute has_element?(view, "#settings-tabs a[href$='/danger']")
      refute render(view) =~ "Elsewhere"

      # The breadcrumb: the organisation, the workspace, Settings.
      assert has_element?(view, "#breadcrumb a[href='#{workspace_path(scope)}']", ws.name)

      assert has_element?(
               view,
               "#breadcrumb #breadcrumb-settings[aria-current='page']",
               "Settings"
             )
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
                 ".q-sidebar-foot a#nav-organisation[href='/#{org.slug}/settings'][aria-current='page']"
               )

        for key <- ~w(overview runs network policy settings members),
            do: refute(has_element?(view, "#nav-#{key}"), "#{path} #{key}")

        assert has_element?(view, "#main h1", "Organisation settings")

        for key <- ~w(organisation people workspaces),
            do: assert(has_element?(view, "#settings-tabs #settings-tab-#{key}"), key)

        refute has_element?(
                 view,
                 "#settings-tab-general, #settings-tab-keys, #settings-tab-danger, #settings-tab-audit_log"
               )

        # the breadcrumb names the organisation, no workspace, and Settings
        assert has_element?(view, "#breadcrumb", org.name)
        refute has_element?(view, "#breadcrumb a[href='#{workspace_path(scope)}']")
        assert has_element?(view, "#breadcrumb #breadcrumb-settings[aria-current='page']")
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
      refute has_element?(view, "#sidebar [aria-current='page']:not(#drawer-sections a)")
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

      # On phones the drawer lists them after the workspace's sidebar, under their heading.
      assert has_element?(
               view,
               "#sidebar .q-sidebar-body nav#drawer-sections[aria-label='Your settings'] #drawer-section-user_settings[aria-current='page']"
             )

      # No other kind of settings, and no list in the page.
      refute has_element?(view, "#settings-tabs, #settings-back")
      assert has_element?(view, "#main h1", "Profile")
      assert has_element?(view, "#breadcrumb a[href='/users/settings']", "Your settings")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "Profile")
      refute has_element?(view, "#breadcrumb-settings")
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

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")
      assert has_element?(view, "#{switch}[href='#{workspace_path(other, "/settings/keys")}']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings/people")
      assert has_element?(view, "#{switch}[href='/#{other.organisation.slug}/settings/people']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#{switch}[href='/#{other.organisation.slug}/settings']")

      # the link opens the other workspace, and the session remembers it for `/`
      conn = get(conn, workspace_path(other, "/settings/keys"))
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
      assert html =~ ~r{<title[^>]*>\s*People · Organisation settings · Qory Apiary\s*</title>}
      assert html =~ scope.organisation.name
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
      assert html =~ ~s(href="#{workspace_path(scope, "/targets/github.example/acme/api")}")
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

    test "the core's entries, and Instance after the theme where a section of it is open",
         %{scope: scope} do
      html = level_shell(scope, %{place: :workspace, counts: %{}})
      assert attribute(html, "#user-menu-settings", "href") == "/users/settings"
      assert attribute(html, "#user-menu-organisations", "href") == "/users/organisations"
      refute html =~ ~s(id="user-menu-instance")

      html = level_shell(scope, %{place: :workspace, counts: %{instance: instance_sections()}})
      assert attribute(html, "#user-menu-instance", "href") == "/instance/organisations"
      assert before?(html, ~s(id="theme-menu-dark"), ~s(id="user-menu-instance"))
      assert before?(html, ~s(id="user-menu-instance"), ~s(id="user-menu-log-out"))

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
      assert attribute(html, "#instance-tabs-heading", "class") =~ "q-second-heading"
      assert attribute(html, "#instance-tab-organisations", "href") == "/instance/organisations"
      assert attribute(html, "#instance-tab-accounts", "aria-current") == "page"
      assert attribute(html, "#drawer-section-accounts", "aria-current") == "page"
      assert attribute(html, "#breadcrumb a", "href") == "/instance/organisations"
      assert html =~ ~r{id="breadcrumb".*Instance.*aria-current="page"[^>]*>\s*Accounts}s

      # One section opens no second column.
      html =
        level_shell(scope, %{
          place: :instance,
          section: :organisations,
          counts: %{instance: Enum.take(instance_sections(), 1)}
        })

      refute html =~ ~s(id="instance-tabs")
      refute html =~ ~s(id="drawer-sections")
    end

    test "a level's settings with one section open no second column", %{scope: scope} do
      [general | _] = ApiaryWeb.SettingsComponents.sections(scope, :workspace)

      html = level_shell(scope, %{nav: :settings, sections: [general], section: :general})
      refute html =~ ~s(id="settings-tabs")
      refute html =~ "q-has-second"

      html =
        level_shell(scope, %{
          nav: :settings,
          sections: ApiaryWeb.SettingsComponents.sections(scope, :workspace),
          section: :general
        })

      assert html =~ "q-has-second"
      assert attribute(html, "#settings-tab-general", "aria-current") == "page"
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

      assert has_element?(view, "#user-menu-level", "Not part of an organisation yet")
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
