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

    test "starts empty, with a way to set each kind up", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#runtimes-empty")
      assert has_element?(lv, "#integrations-empty")
      assert has_element?(lv, "#services-empty")
      assert has_element?(lv, "#definitions-empty")
      assert has_element?(lv, "#add-integration")
      assert has_element?(lv, "#new-runtime")
      assert has_element?(lv, "#new-service")
      assert has_element?(lv, "#new-definition")
    end

    test "lists each kind, each row leading to its page", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})

      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#runtimes #connection-#{runtime.public_id}", "Every repository")
      assert has_element?(lv, "#runtimes #connection-#{runtime.public_id} a", "Claude Code")
      assert has_element?(lv, "#runtimes #connection-#{runtime.public_id} a .q-mono", "(claude)")
      assert has_element?(lv, "#integrations #connection-#{integration.public_id} a", "GitHub")

      assert has_element?(
               lv,
               "#integrations #connection-#{integration.public_id} a .q-mono",
               "(github)"
             )

      assert has_element?(lv, "#services #connection-#{service.public_id}", "npm registry")

      assert has_element?(
               lv,
               "#integrations #connection-#{integration.public_id}",
               "github.com/qoryai/qory-github"
             )

      assert has_element?(
               lv,
               ~s(#connection-#{runtime.public_id} a[href="#{ipath(scope, "/#{runtime.public_id}")}"])
             )
    end

    test "Add integration is in the top bar's New, for an owner or an admin",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      assert has_element?(
               lv,
               ~s(#new-menu a#new-menu-integration[href="#{ipath(scope, "/add")}"])
             )

      {:ok, lv, _html} =
        live(member_conn(scope, :member), ~p"/#{scope.organisation}/#{scope.workspace}/runs")

      refute has_element?(lv, "#new-menu-integration")
    end

    test "is read only for a member", %{scope: scope} do
      conn = member_conn(scope, :member)
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#integrations-readonly", "Only owners and admins")
      refute has_element?(lv, "#add-integration")
      refute has_element?(lv, "#new-runtime")

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

    test "says the runner's catalogue and the built-in definitions, naming no product",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope))

      assert has_element?(lv, "#runtimes-part", "Agent runtimes from the runner's catalogue.")
      assert has_element?(lv, "#definitions-part", "beside the built-in ones: ")
      refute lv |> element("#settings-section-integrations") |> render() =~ "Qory"
    end

    test "is another organisation's to read, not this one's", %{scope: scope} do
      other = sign_up_fixture()
      conn = log_in_user(build_conn(), other.user)

      assert get(conn, ipath(scope)).status == 404
    end
  end

  describe "the forms" do
    test "New runtime sets one up and opens it", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/new-runtime"))
      assert has_element?(lv, "#new-runtime-page-title", "New runtime")
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

    test "New service sets one up from a built-in definition, chosen targets at once",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/new-service"))

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

    test "Add integration asks for a release and leads to it", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ipath(scope, "/add"))
      assert has_element?(lv, "#add-integration-page-title", "Add integration")

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

    test "Add integration says what is wrong with a source", %{conn: conn, scope: scope} do
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
