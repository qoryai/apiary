defmodule ApiaryWeb.IntegrationLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures

  alias Apiary.Connections
  alias Apiary.Integrations.Release

  @moduletag needs: :security

  setup :register_and_log_in_user

  defp ipath(scope, rest \\ ""),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations#{rest}"

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  describe "the section" do
    test "is an entry of the workspace's settings, after People", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
      assert has_element?(lv, "#settings-tab-integrations", "Integrations")

      {:ok, lv, _html} = live(conn, ipath(scope))
      assert has_element?(lv, "#settings-tab-integrations[aria-current=page]")
      assert has_element?(lv, "#settings-section-title", "Integrations")
    end

    test "says once that runs don't receive integrations yet, and never that they do",
         %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, ipath(scope))

      assert has_element?(
               lv,
               "#not-on-runs",
               "Runs don't receive integrations yet. Today a run receives only its security policy."
             )

      refute html =~ "applies to runs"
      refute html =~ "runs receive"
    end

    test "starts empty, with a card to add each thing by name", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#set-up-part h2", "Set up in this workspace")
      assert has_element?(lv, "#connections-empty", "Nothing is set up in this workspace yet.")
      assert has_element?(lv, "#add-part h2", "Add an integration")

      assert has_element?(lv, "#add-card-runtime-claude h3", "Claude Code")
      assert has_element?(lv, "#add-card-runtime-claude-kind", "Runtime")

      assert has_element?(
               lv,
               "#add-card-runtime-claude",
               "Anthropic's coding agent, with an API key or an OAuth credential."
             )

      assert has_element?(lv, "#add-card-api-sentry h3", "Sentry")
      assert has_element?(lv, "#add-card-api-sentry-kind", "API")
      assert has_element?(lv, "#add-card-api-sentry", "sent as a bearer token")
      assert has_element?(lv, "#add-card-api-npm h3", "npm registry")
      assert has_element?(lv, "#add-card-api-npm-kind", "API")

      assert has_element?(lv, "#add-card-release h3", "From a release…")
      assert has_element?(lv, "#add-card-release", "or at an https address.")
      assert has_element?(lv, ~s(#add-integration[href="#{ipath(scope, "/add")}"]))
      assert has_element?(lv, "#add-integration", "Add from a release")

      assert has_element?(lv, "#add-card-custom-api h3", "Custom API…")
      assert has_element?(lv, ~s(#new-definition[href="#{ipath(scope, "/definitions/new")}"]))
      assert has_element?(lv, "#new-definition", "New custom API")

      # The cards in order: the catalogue's, the built-in APIs, then the two ways to more.
      ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#add-cards > li")
        |> LazyHTML.attribute("id")

      assert ids == [
               "add-card-runtime-claude",
               "add-card-api-npm",
               "add-card-api-sentry",
               "add-card-release",
               "add-card-custom-api"
             ]
    end

    test "offers no card it can't add: no forge's own, no named release yet",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))
      cards = lv |> element("#add-cards") |> render()

      for name <- ["GitHub", "GitLab", "Bitbucket"], do: refute(cards =~ name)
      refute has_element?(lv, "[id^=add-card-named-]")
      assert ApiaryWeb.IntegrationLive.Named.list() == []
    end

    test "a card's Set up opens its form with its item chosen", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(
               lv,
               ~s(#add-card-runtime-claude-act[href="#{ipath(scope, "/new-runtime?runtime=claude")}"]),
               "Set up"
             )

      assert has_element?(lv, "#add-card-runtime-claude-act .sr-only", "Claude Code")

      sentry = ipath(scope, "/new-service?definition=builtin%3Asentry")
      assert has_element?(lv, ~s(#add-card-api-sentry-act[href="#{sentry}"]))

      {:ok, lv, _html} = live(conn, sentry)
      assert has_element?(lv, "#new-service-page-title", "Set up an API")
      assert has_element?(lv, "#connection_definition option[value='builtin:sentry'][selected]")
      assert has_element?(lv, "#service-definition-about", "sentry.io")

      {:ok, lv, _html} = live(conn, ipath(scope, "/new-runtime?runtime=claude"))
      assert has_element?(lv, "#new-runtime-page-title", "Set up a runtime")
      assert has_element?(lv, "#connection_runtime option[value='claude'][selected]")
    end

    test "an item the catalogue doesn't have opens the form as it starts",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/new-runtime?runtime=nonesuch"))
      assert has_element?(lv, "#connection_runtime option[value='claude'][selected]")

      for value <- ["builtin:nonesuch", "own:svc_nonesuch", "sentry", ""] do
        {:ok, lv, _html} =
          live(conn, ipath(scope, "/new-service?" <> URI.encode_query(definition: value)))

        assert has_element?(lv, "#connection_definition option[value='builtin:npm'][selected]")
        refute has_element?(lv, "#new-service-page [role=alert]")
      end
    end

    test "the workspace's own custom APIs are cards, each its name leading to its page",
         %{conn: conn, scope: scope} do
      {:ok, definition} =
        Connections.create_service_definition(
          scope,
          Jason.encode!(%{
            "version" => 1,
            "key" => "status-api",
            "title" => "Status API",
            "hosts" => ["status.example.com"],
            "auth" => %{"scheme" => "bearer", "secret" => "key"},
            "declares" => [%{"id" => "key", "title" => "API key"}]
          })
        )

      {:ok, lv, _html} = live(conn, ipath(scope))
      card = "#add-card-own-#{definition.public_id}"

      assert has_element?(
               lv,
               ~s(#{card} h3 a[href="#{ipath(scope, "/definitions/#{definition.public_id}")}"]),
               "Status API"
             )

      assert has_element?(lv, "#{card}-kind", "Custom API")
      assert has_element?(lv, card, "Its hosts: status.example.com.")

      own = ipath(scope, "/new-service?definition=own%3A#{definition.public_id}")
      assert has_element?(lv, ~s(#{card}-act[href="#{own}"]))

      # Before the two ways to more.
      ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#add-cards > li")
        |> LazyHTML.attribute("id")

      assert Enum.drop_while(ids, &(&1 != "add-card-own-#{definition.public_id}")) == [
               "add-card-own-#{definition.public_id}",
               "add-card-release",
               "add-card-custom-api"
             ]

      {:ok, lv, _html} = live(conn, own)

      assert has_element?(
               lv,
               "#connection_definition option[value='own:#{definition.public_id}'][selected]"
             )
    end

    test "another organisation's custom API is neither a card nor a choice",
         %{conn: conn, scope: scope} do
      other = sign_up_fixture().scope

      {:ok, definition} =
        Connections.create_service_definition(
          other,
          Jason.encode!(%{
            "version" => 1,
            "key" => "billing-api",
            "title" => "Billing API",
            "hosts" => ["billing.example.com"],
            "auth" => %{"scheme" => "bearer", "secret" => "key"},
            "declares" => [%{"id" => "key", "title" => "API key"}]
          })
        )

      {:ok, lv, html} = live(conn, ipath(scope))
      refute has_element?(lv, "#add-card-own-#{definition.public_id}")
      refute html =~ "Billing API"
      refute html =~ "billing.example.com"

      {:ok, lv, html} =
        live(conn, ipath(scope, "/new-service?definition=own%3A#{definition.public_id}"))

      assert has_element?(lv, "#connection_definition option[value='builtin:npm'][selected]")

      refute has_element?(
               lv,
               "#connection_definition option[value='own:#{definition.public_id}']"
             )

      refute has_element?(lv, "#new-service-page [role=alert]")

      for html <- [html, render(lv)] do
        refute html =~ definition.public_id
        refute html =~ "Billing API"
        refute html =~ "billing.example.com"
      end
    end

    test "a named release is a card that opens Add from a release, its source filled in",
         %{conn: conn, scope: scope} do
      named = %ApiaryWeb.IntegrationLive.Named{
        name: "Acme Tracker",
        source: "github.com/acme/tracker",
        about: "Acme's issue tracker, with a token sent as a bearer token."
      }

      html =
        render_component(&ApiaryWeb.IntegrationLive.Index.add_cards/1,
          scope: scope,
          definitions: [],
          url_sources: true,
          named: [named]
        )

      card =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#add-card-named-github-com-acme-tracker")

      assert LazyHTML.text(LazyHTML.query(card, "h3")) =~ "Acme Tracker"
      assert LazyHTML.text(card) =~ "github.com/acme/tracker"

      assert LazyHTML.text(LazyHTML.query(card, "#add-card-named-github-com-acme-tracker-kind")) =~
               "Program"

      assert LazyHTML.text(card) =~ "Acme's issue tracker"

      [href] =
        card
        |> LazyHTML.query("#add-card-named-github-com-acme-tracker-act")
        |> LazyHTML.attribute("href")

      assert href == ipath(scope, "/add?source=github.com%2Facme%2Ftracker")

      # Before the two ways to more, after the built-in APIs.
      [_before, rest] = String.split(html, "add-card-named-github-com-acme-tracker", parts: 2)
      assert rest =~ "add-card-release\""
      refute rest =~ "add-card-api-"

      {:ok, lv, _html} = live(conn, href)
      assert has_element?(lv, "#add-integration-page-title", "Add from a release")
      assert has_element?(lv, "#release_where-0[value='github.com'][checked]")
      assert has_element?(lv, "#release_path[value='acme/tracker']")
      assert has_element?(lv, "#release_version[value='']")
    end

    test "lists what is set up in one list, each row leading to its page",
         %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})

      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#set-up-part .q-part-n", "3")
      refute has_element?(lv, "#connections-empty")

      row = "#connections #connection-#{runtime.public_id}"
      assert has_element?(lv, row, "Every repository")
      assert has_element?(lv, "#{row} a", "Claude Code")
      assert has_element?(lv, "#{row} a .q-mono", "(claude)")
      assert has_element?(lv, row, "Runtime")

      row = "#connections #connection-#{integration.public_id}"
      assert has_element?(lv, "#{row} a", "GitHub")
      assert has_element?(lv, "#{row} a .q-mono", "(github)")
      assert has_element?(lv, row, "github.com/qoryai/qory-github")
      assert has_element?(lv, row, "Program")
      assert has_element?(lv, row, integration.version)

      row = "#connections #connection-#{service.public_id}"
      assert has_element?(lv, row, "npm registry")
      assert has_element?(lv, row, "API")

      assert has_element?(
               lv,
               ~s(#connection-#{runtime.public_id} a[href="#{ipath(scope, "/#{runtime.public_id}")}"])
             )

      # A runtime set up already is still offered: a workspace may set one up again.
      assert has_element?(lv, "#add-card-runtime-claude-act")
    end

    test "names its parts and kinds in words that don't name the section's things twice",
         %{conn: conn, scope: scope} do
      {:ok, _lv, html} = live(conn, ipath(scope))

      refute html =~ "ervice definition"
      refute html =~ ">Services<"
      refute html =~ "New service"
      refute html =~ "New runtime"
    end

    test "Add integration is in the top bar's New, for an owner or an admin, and leads to the cards",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      assert has_element?(
               lv,
               ~s(#new-menu a#new-menu-integration[href="#{ipath(scope, "#add-part")}"])
             )

      {:ok, lv, _html} =
        live(member_conn(scope, :member), ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      refute has_element?(lv, "#new-menu-integration")
    end

    test "is read only for a member", %{scope: scope} do
      conn = member_conn(scope, :member)
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#integrations-readonly", "Only owners and admins")
      assert has_element?(lv, "#set-up-part")
      refute has_element?(lv, "#add-part")
      refute has_element?(lv, "#add-cards")
      refute has_element?(lv, "#add-integration")

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, ipath(scope, "/new-runtime"))

      assert flash["error"] =~ "Only owners and admins"

      # A request sent as an event is refused too, and asks for nothing.
      html =
        render_hook(lv, "request", %{
          "release" => %{"where" => "github.com", "path" => "acme/shop", "version" => "1.0.0"}
        })

      assert html =~ "Only owners and admins"
      assert Apiary.Repo.all(Release) == []
    end

    test "an event its controls don't send changes nothing", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      render_hook(lv, "create", %{"connection" => %{"runtime" => "claude"}})
      render_hook(lv, "unknown", %{})

      assert Process.alive?(lv.pid)
      assert {:ok, []} = Connections.list_connections(scope)
    end

    test "names no product of its own", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      refute lv |> element("#settings-section-integrations") |> render() =~ "Qory"
    end

    test "has the section as its h1 and its title", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "h1#settings-section-title", "Integrations")

      assert has_element?(
               lv,
               "#settings-section-integrations",
               "What this workspace sets up for its runs, and where each applies."
             )

      assert page_title(lv) =~
               "Integrations · Workspace settings · #{scope.workspace.name} · #{scope.organisation.name}"
    end

    test "is another organisation's to read, not this one's", %{scope: scope} do
      other = sign_up_fixture()
      conn = log_in_user(build_conn(), other.user)

      assert get(conn, ipath(scope)).status == 404
    end
  end

  describe "the forms" do
    test "Set up a runtime sets one up and opens it", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/new-runtime"))
      assert has_element?(lv, "#new-runtime-page-title", "Set up a runtime")
      assert has_element?(lv, "#breadcrumb-section", "Integrations")
      assert page_title(lv) =~ "Set up a runtime · Workspace settings"
      assert has_element?(lv, "#runtime-catalogue", "ANTHROPIC_API_KEY")
      assert has_element?(lv, "#connection_runtime[aria-describedby=runtime-catalogue]")

      {:error, {:live_redirect, %{to: to}}} =
        result =
        lv
        |> form("#new-runtime-form", connection: %{runtime: "claude", applies_to: "all"})
        |> render_submit()

      {:ok, [connection]} = Connections.list_connections(scope)
      assert connection.kind == "runtime"
      assert to == ipath(scope, "/#{connection.public_id}")
      {:ok, _lv, html} = follow_redirect(result, conn)
      assert html =~ "Claude Code (claude) is set up."
    end

    test "a second runtime that would overlap is refused, by name", %{conn: conn, scope: scope} do
      {:ok, _} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, ipath(scope, "/new-runtime"))

      html =
        lv
        |> form("#new-runtime-form", connection: %{runtime: "claude", applies_to: "all"})
        |> render_submit()

      assert html =~ "It would overlap with Claude Code (claude)"
    end

    test "Set up an API sets one up from a built-in API, chosen targets at once",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/new-service"))

      assert has_element?(
               lv,
               "#new-service-page",
               "Set up a built-in API or one of this workspace's own."
             )

      assert has_element?(lv, "label[for=connection_definition]", "API")

      assert has_element?(
               lv,
               "#connection_name-hint",
               "The API's title, unless you give it another."
             )

      assert has_element?(lv, "#new-service-save button[type=submit]", "Set up API")

      assert has_element?(
               lv,
               "#connection_definition[aria-describedby=service-definition-about]"
             )

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#new-service-form",
          connection: %{definition: "builtin:npm", name: "Packages", applies_to: "selected"}
        )
        |> render_submit()

      {:ok, [connection]} = Connections.list_connections(scope)
      assert connection.name == "Packages"
      assert connection.applies_to == "selected"
      assert to == ipath(scope, "/#{connection.public_id}/targets")
    end

    test "Add from a release asks for a release and leads to it", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/add"))
      assert has_element?(lv, "#add-integration-page-title", "Add from a release")

      assert has_element?(
               lv,
               "#add-integration-page",
               "Name the release of a program: its description is fetched, and you add it from there."
             )

      assert page_title(lv) =~ "Add from a release · Workspace settings"

      assert has_element?(
               lv,
               "#release_path-hint",
               "Its owner and name, such as acme/shop-integration."
             )

      assert has_element?(
               lv,
               "#add-integration-save",
               "Only its description.json and checksums.txt are read, and nothing of it runs on the server."
             )

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#add-integration-form",
          release: %{where: "github.com", path: "qoryai/qory-github", version: "0.1.0"}
        )
        |> render_submit()

      [release] = Apiary.Repo.all(Release)
      assert release.state == "pending"
      assert release.source == "github.com/qoryai/qory-github"
      assert to == ipath(scope, "/releases/#{release.id}")
    end

    test "Add from a release says what is wrong with a source", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/add"))

      html =
        lv
        |> form("#add-integration-form",
          release: %{where: "github.com", path: "qoryai/tools/qory-github", version: "1.4"}
        )
        |> render_submit()

      assert html =~ "must be owner/repo"
      assert Apiary.Repo.all(Release) == []
    end

    test "offers only the public forges and an https address", %{conn: conn, scope: scope} do
      {:ok, _lv, html} = live(conn, ipath(scope, "/add"))

      for host <- ~w(github.com gitlab.com codeberg.org), do: assert(html =~ host)
      assert html =~ "An https address"
    end

    test "a hint for every forge's path", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/add"))

      for {where, hint} <- [
            {"codeberg.org", "Its owner and name, such as acme/shop-integration."},
            {"gitlab.com", "The project's full path, its groups included."}
          ] do
        lv |> form("#add-integration-form", release: %{where: where}) |> render_change()
        assert has_element?(lv, "#release_path-hint", hint)
      end
    end

    test "is filled in with the release asked for again", %{conn: conn, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ipath(scope, "/add?source=gitlab.com/acme/tools/hooks&version=1.0.0"))

      assert has_element?(lv, "#release_where-1[value='gitlab.com'][checked]")
      assert has_element?(lv, "#release_path[value='acme/tools/hooks']")
      assert has_element?(lv, "#release_version[value='1.0.0']")

      url = "https://downloads.example.com/acme/shop/description.json"
      {:ok, lv, _html} = live(conn, ipath(scope, "/add?" <> URI.encode_query(source: url)))
      assert has_element?(lv, "#release_url[value='#{url}']")
    end
  end
end
