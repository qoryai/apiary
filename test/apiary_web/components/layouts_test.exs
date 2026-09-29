defmodule ApiaryWeb.LayoutsTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations

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

    test "the top bar: home, where the page is, Search or jump to, New, then the account menu",
         %{conn: conn, user: user, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      assert has_element?(
               view,
               "#top-bar a#top-bar-home[href='/'][aria-label='Qory Apiary, home']"
             )

      # the breadcrumb: the organisation and the workspace, each a link to its home
      assert has_element?(
               view,
               "#top-bar nav#breadcrumb[aria-label='Where you are'] a[href='/#{scope.organisation.slug}']",
               scope.organisation.name
             )

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
    end

    test "the account menu: who you are, your settings and organisations, the theme, Qory Apiary, log out",
         %{conn: conn, user: user, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#user-menu[phx-hook='Menu']")
      menu = view |> element("#user-menu ul[role='menu'][aria-label='Account']") |> render()
      assert menu =~ user.email
      assert menu =~ "Owner of #{scope.organisation.name}"
      assert before?(menu, "Your settings", "Your organisations")
      assert before?(menu, "Your organisations", "Theme")
      assert before?(menu, "Theme", "Docs")
      assert before?(menu, "Docs", "Log out")
      refute menu =~ "Switch organisation"

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

      assert has_element?(view, "#user-menu a#user-menu-docs[href='/docs']")

      # The release notes name every feature: only an instance with every one links them.
      assert has_element?(view, "#user-menu a#user-menu-changelog[href='/docs/changelog.html']") ==
               (Apiary.Features.enabled() == Apiary.Features.all())

      assert has_element?(
               view,
               "#user-menu a#user-menu-source[href='https://github.com/qoryai/apiary'][rel='noopener'][target='_blank']"
             )

      version = :apiary |> Application.spec(:vsn) |> List.to_string()
      assert has_element?(view, "#user-menu #user-menu-version", version)

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

    test "a workspace's sidebar: its pages in groups, Settings at the foot, the fold",
         %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      # The policy's entry is there only on an instance with the security policy.
      policy = if Apiary.Features.on?(:security), do: [policy: workspace_path(scope, "/policy")]

      for {key, href} <-
            [
              overview: workspace_path(scope),
              runs: workspace_path(scope, "/runs"),
              connections: workspace_path(scope, "/connections")
            ] ++ List.wrap(policy) ++ [settings: workspace_path(scope, "/settings")] do
        assert has_element?(view, "#sidebar a#nav-#{key}[href='#{href}']"), "#{key}"
      end

      assert has_element?(view, "#nav-overview[aria-current='page']")
      assert before?(html, ~s(id="nav-group-home"), ~s(id="nav-group-record"))
      assert has_element?(view, "#nav-group-record #nav-runs")
      assert has_element?(view, ".q-sidebar-foot #nav-settings")

      # the organisation's pages and the pages of Settings are not a workspace's entries
      for key <- ~w(keys members activity organisation),
          do: refute(has_element?(view, "#nav-#{key}"), key)

      assert has_element?(
               view,
               "#sidebar button#sidebar-collapse[data-sidebar-collapse][aria-keyshortcuts='[']"
             )

      assert has_element?(view, "#sidebar button[data-drawer-close][aria-label='Close menu']")
    end

    test "a page of a workspace's Settings marks Settings", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      assert has_element?(view, "aside#sidebar[aria-label='Workspace']")
      assert has_element?(view, "#nav-settings[aria-current='page']")
      refute has_element?(view, "#nav-keys")
    end

    test "an organisation's page shows the organisation's sidebar", %{conn: conn, scope: scope} do
      for path <- [
            ~p"/#{scope.organisation}/settings/people",
            ~p"/#{scope.organisation}/settings"
          ] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "aside#sidebar[aria-label='Organisation']")

        assert has_element?(
                 view,
                 "#sidebar a#nav-activity[href='/#{scope.organisation.slug}/activity']"
               )

        assert has_element?(
                 view,
                 ".q-sidebar-foot a#nav-organisation[href='/#{scope.organisation.slug}/settings'][aria-current='page']"
               )

        for key <- ~w(overview runs connections policy settings members),
            do: refute(has_element?(view, "#nav-#{key}"), "#{path} #{key}")

        # the breadcrumb names the organisation and no workspace
        assert has_element?(view, "#breadcrumb", scope.organisation.name)
        refute has_element?(view, "#breadcrumb a[href='#{workspace_path(scope)}']")
      end
    end

    test "a person's own page shows the person's sidebar and no notices of an organisation",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      assert has_element?(view, "aside#sidebar[aria-label='Your account']")
      assert has_element?(view, "#nav-user_settings[href='/users/settings'][aria-current='page']")
      assert has_element?(view, "#nav-user_preferences[href='/users/settings/preferences']")
      assert has_element?(view, "#nav-user_organisations[href='/users/organisations']")
      refute has_element?(view, "#nav-overview, #nav-activity, #nav-settings")
      assert has_element?(view, "#breadcrumb a[href='/users/settings']", "Your settings")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "Profile")
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
                 "#organisation-menu button##{button}[aria-haspopup='dialog'][aria-controls='organisation-menu-panel'][aria-expanded='false']"
               )
      end

      assert has_element?(view, "#organisation-menu-panel[role='dialog'][hidden]")

      assert has_element?(
               view,
               "#organisation-menu-panel input#organisation-menu-search[aria-label='Find an organisation or workspace']"
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

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/activity")
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

      pins = [
        %{key: "1", label: "acme/shop", system: "github.example", href: "/somewhere/shop"},
        %{key: "2", label: "acme/api", system: "github.example", href: "/somewhere/api"}
      ]

      html = shell(scope, :runs, %{pins: pins})
      assert html =~ ~s(id="nav-group-pinned")
      assert html =~ ~s(id="nav-pin-1")
      assert html =~ ~s(href="/somewhere/api")
      assert before?(html, "acme/shop", "acme/api")

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

  describe "the person with no organisation" do
    test "their pages have the person's sidebar, and no palette, New or breadcrumb of a place",
         %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/users/organisations")

      assert has_element?(view, "aside#sidebar[aria-label='Your account']")
      assert has_element?(view, "#nav-user_organisations[aria-current='page']")
      refute has_element?(view, "#palette-open, #palette, #new-menu")

      assert has_element?(
               view,
               "#top-bar #user-menu-button[aria-label='Account menu, #{user.email}']"
             )

      assert has_element?(view, "#user-menu-level", "Not part of an organisation yet")
      assert has_element?(view, "#user-menu a#user-menu-docs[href='/docs']")
      assert html =~ ~r{<title[^>]*>\s*No workspace yet · Qory Apiary\s*</title>}
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
