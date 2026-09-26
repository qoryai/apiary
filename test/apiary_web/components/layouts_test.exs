defmodule ApiaryWeb.LayoutsTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
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

    test "the sidebar comes before the top bar and main in the DOM, and the bar is in the content column",
         %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert before?(html, ~s(class="drawer-side), ~s(id="shell-content"))
      assert has_element?(view, "#shell-content > header#top-bar[aria-label='Top bar']")
      assert has_element?(view, "#shell-content > main#main")
      assert has_element?(view, "aside#sidebar[aria-label='Sidebar'] nav[aria-label='Main']")
      assert has_element?(view, "aside#sidebar nav[aria-label='Manage']")
    end

    test "the top bar holds the theme toggle and then the account menu, on every page", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      # Both triggers are buttons, never a div with a tabindex: daisyUI takes the
      # pointer away from a [tabindex] trigger while its dropdown has focus, so the
      # click that should open the menu would land beside it.
      assert has_element?(view, "#top-bar button#theme-menu-button[aria-label='Theme']")
      refute has_element?(view, "#theme-menu [tabindex]")

      assert has_element?(
               view,
               "#top-bar #user-menu-button[aria-haspopup='menu'][aria-label='Account menu, #{user.email}']"
             )

      assert before?(html, ~s(id="theme-menu-button"), ~s(id="user-menu-button"))
      # below 768 px the bar opens the drawer and says where you are; the label is text
      assert has_element?(view, "#top-bar #nav-drawer-open[aria-label='Open menu'].md\\:hidden")
      assert has_element?(view, "#top-bar div#organisation-label.md\\:hidden")
      refute has_element?(view, "#organisation-label a, #organisation-label button")
    end

    test "the account menu: who you are, then Account settings and Log out", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(view, "#user-menu[phx-hook='Menu']")
      menu = view |> element("#user-menu ul[role='menu'][aria-label='Account']") |> render()
      assert menu =~ user.email
      assert menu =~ "Owner of #{scope.organisation.name}"
      assert before?(menu, "Account settings", "Log out")
      assert length(Regex.scan(~r/role="menuitem"/, menu)) == 2
      refute menu =~ "Theme"
      # the docs are the product's, so they are in the brand menu, not here
      refute menu =~ "Docs"
      refute menu =~ "Switch organisation"

      # a keyboard open focuses the first item: it is the first focusable thing in the list
      assert has_element?(
               view,
               "#user-menu .dropdown-content li:nth-child(3) a#user-menu-settings[role='menuitem'][href='/users/settings']"
             )

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

    test "the sidebar: the organisation row at the top, the nav, then the brand foot; no user card",
         %{conn: conn, user: user, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      sidebar = view |> element("#sidebar") |> render()
      assert before?(sidebar, ~s(id="organisation-row"), ~s(aria-label="Main"))
      assert before?(sidebar, ~s(aria-label="Manage"), ~s(id="brand-foot"))

      # one membership: the block is text, the chevron slot empty, nothing to focus
      assert has_element?(
               view,
               "#organisation-row div#organisation-block",
               scope.organisation.name
             )

      assert has_element?(view, "#organisation-block", scope.workspace.name)
      refute has_element?(view, "#organisation-block button, #organisation-block a")
      refute sidebar =~ "hero-chevron-up-down-micro"

      assert has_element?(
               view,
               "#organisation-row button[data-drawer-close][aria-label='Close menu']"
             )

      # the user card and the theme row are gone
      refute sidebar =~ user.email
      refute has_element?(view, "#sidebar #user-menu")
      refute html =~ "theme-seg"
    end

    test "with several memberships the organisation row is the switcher", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      refute has_element?(view, "#organisation-block")

      assert has_element?(
               view,
               "#organisation-row #organisation-menu[phx-hook='Menu'] button#organisation-menu-button[aria-haspopup='menu']"
             )

      # plain links to each workspace's own URL, the current one marked; no form
      refute has_element?(view, "#organisation-menu form")

      assert has_element?(
               view,
               "#organisation-menu a[role='menuitem'][aria-current='true'][href='#{workspace_path(scope)}']"
             )

      assert has_element?(
               view,
               "#organisation-menu a[role='menuitem']:not([aria-current])[href='#{workspace_path(other)}']",
               other.organisation.name
             )
    end

    test "the navigation leads to the workspace's pages and the organisation's", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/keys")
      org = "/#{scope.organisation.slug}"

      # The policy's entry is there only on an instance with the security policy.
      policy = if Apiary.Features.on?(:security), do: [policy: workspace_path(scope, "/policy")]

      for {key, href} <-
            [
              overview: workspace_path(scope),
              runs: workspace_path(scope, "/runs"),
              connections: workspace_path(scope, "/connections")
            ] ++
              List.wrap(policy) ++
              [
                keys: workspace_path(scope, "/keys"),
                members: org <> "/members",
                settings: workspace_path(scope, "/settings"),
                organisation: org <> "/settings",
                activity: org <> "/activity"
              ] do
        assert has_element?(view, "#sidebar a#nav-#{key}[href='#{href}']"), "#{key}"
      end

      assert has_element?(view, "#nav-keys[aria-current='page']")
    end

    test "switching keeps the section the user is on", %{conn: conn, user: user, scope: scope} do
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)
      switch = "#organisation-menu a[role='menuitem']"

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/keys")
      assert has_element?(view, "#{switch}[href='#{workspace_path(other, "/keys")}']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/members")
      assert has_element?(view, "#{switch}[href='/#{other.organisation.slug}/members']")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#{switch}[href='/#{other.organisation.slug}/settings']")

      # the link opens the other workspace, and the session remembers it for `/`
      conn = get(conn, workspace_path(other, "/keys"))
      assert html_response(conn, 200) =~ other.organisation.name
      assert redirected_to(get(recycle(conn), ~p"/")) == workspace_path(other)
    end

    test "the brand foot is the Qory Apiary menu: the version on it, docs, changelog and source in it",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      version = :apiary |> Application.spec(:vsn) |> List.to_string()
      assert has_element?(view, "#brand-foot #brand-menu.dropdown-top[phx-hook='Menu']")

      assert has_element?(
               view,
               "#brand-menu button#brand-menu-button[aria-haspopup='menu'][aria-label='Qory Apiary menu, version #{version}']",
               "Qory Apiary"
             )

      assert has_element?(
               view,
               "#brand-menu-button #brand-version[title='Version #{version}']",
               version
             )

      refute has_element?(view, "#brand-menu [tabindex]")

      menu = view |> element("#brand-menu ul[role='menu'][aria-label='Qory Apiary']") |> render()

      if Apiary.Features.enabled() == Apiary.Features.all() do
        assert before?(menu, "Docs", "Changelog")
        assert before?(menu, "Changelog", "Source on GitHub")
        assert length(Regex.scan(~r/role="menuitem"/, menu)) == 3
      else
        refute menu =~ "Changelog"
        assert before?(menu, "Docs", "Source on GitHub")
        assert length(Regex.scan(~r/role="menuitem"/, menu)) == 2
      end

      assert has_element?(
               view,
               "#brand-menu .dropdown-content li:first-child a#brand-menu-docs[href='/docs']"
             )

      # The release notes name every feature: only an instance with every one links them.
      assert has_element?(view, "#brand-menu a#brand-menu-changelog[href='/docs/changelog.html']") ==
               (Apiary.Features.enabled() == Apiary.Features.all())

      assert has_element?(
               view,
               "#brand-menu a#brand-menu-source[href='https://github.com/qoryai/apiary'][rel='noopener'][target='_blank']"
             )

      # the brand is at the foot, not the top
      sidebar = view |> element("#sidebar") |> render()
      assert before?(sidebar, ~s(id="organisation-row"), "Qory Apiary")
    end

    test "the page title carries the product name as its suffix", %{conn: conn, scope: scope} do
      {:ok, _view, html} = live(conn, ~p"/#{scope.organisation}/members")
      assert html =~ ~r{<title[^>]*>\s*Members · Qory Apiary\s*</title>}
      assert html =~ scope.workspace.name
    end
  end

  describe "the no-workspace shell" do
    test "no sidebar, no menu button, the brand at the left of the bar", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/users/organisations")

      refute has_element?(view, "#sidebar")
      refute has_element?(view, "#nav-drawer, #nav-drawer-open")

      assert has_element?(
               view,
               "#top-bar #brand-menu:not(.dropdown-top) #brand-menu-button",
               "Qory Apiary"
             )

      assert has_element?(view, "#top-bar #brand-menu a#brand-menu-docs[href='/docs']")
      assert has_element?(view, "#top-bar #theme-menu-button")

      assert has_element?(
               view,
               "#top-bar #user-menu-button[aria-label='Account menu, #{user.email}']"
             )

      assert has_element?(view, "#user-menu-level", "Not part of an organisation yet")
      assert before?(html, ~s(id="brand-menu-button"), ~s(id="theme-menu-button"))
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
