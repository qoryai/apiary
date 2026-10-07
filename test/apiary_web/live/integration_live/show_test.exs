defmodule ApiaryWeb.IntegrationLive.ShowTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release

  @moduletag needs: :security

  setup :register_and_log_in_user

  defp path(scope, connection, rest \\ ""),
    do:
      "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations/#{connection.public_id}#{rest}"

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp reload(scope, connection) do
    {:ok, connection} = Connections.get_connection(scope, connection.public_id)
    connection
  end

  describe "Overview" do
    test "says what a runtime is, its id, where it applies and the secrets it declares",
         %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, html} = live(conn, path(scope, runtime))

      assert has_element?(lv, "#connection-tabs-overview[aria-current=page]")
      assert has_element?(lv, "#connection-id", runtime.public_id)
      assert has_element?(lv, "#connection-facts", "Every target")
      assert has_element?(lv, "#connection-secrets", "ANTHROPIC_API_KEY")
      assert has_element?(lv, "#connection-secrets", "It needs one of: api_key, oauth_token.")
      assert has_element?(lv, "#connection-secrets-unlinked", "can't link a stored secret")
      assert has_element?(lv, "#not-on-runs", "Runs don't receive integrations yet.")
      refute html =~ "runs receive"
    end

    test "says where an integration comes from, its publisher beside the source, and its way",
         %{conn: conn, scope: scope} do
      release = ready_release!(scope, tracker_description(), "github.com/acme/tracker")

      {:ok, integration} =
        Connections.create_integration(scope, release.id, %{
          settings: %{"url" => "https://tracker.example.com"}
        })

      {:ok, lv, _html} = live(conn, path(scope, integration))

      assert has_element?(lv, "#connection-publisher", "Acme")
      assert has_element?(lv, "#connection-publisher", "github.com/acme")
      assert has_element?(lv, "#connection-ways", "Calls its API.")
      assert has_element?(lv, "#connection-tool-way", "doesn't support that way yet")
      assert has_element?(lv, "#connection-plain-settings", "https://tracker.example.com")
    end
  end

  describe "Targets" do
    test "a chosen target is added from a page, and removed on its row, confirmed",
         %{conn: conn, scope: scope} do
      shop = target!(scope, "acme/shop")
      _billing = target!(scope, "acme/billing")

      {:ok, runtime} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      {:ok, lv, _html} = live(conn, path(scope, runtime, "/targets"))
      assert has_element?(lv, "#connection-targets-empty")

      {:ok, lv, _html} =
        lv |> element("#add-target") |> render_click() |> follow_redirect(conn)

      assert has_element?(lv, "#add-target-page-title")
      assert has_element?(lv, "#candidate-#{shop.id}")

      lv |> form("#find-target-form", find: %{text: "shop"}) |> render_change()
      lv |> element("#add-#{shop.id}") |> render_click()

      assert [%{target_id: target_id}] = reload(scope, runtime).targets
      assert target_id == shop.id
      refute has_element?(lv, "#candidate-#{shop.id}")

      {:ok, lv, _html} = live(conn, path(scope, runtime, "/targets"))
      assert has_element?(lv, "#target-#{shop.id}", "acme/shop")

      lv |> element("#target-#{shop.id} a", "Remove") |> render_click()
      assert has_element?(lv, "#target-#{shop.id}-confirm", "Remove acme/shop from claude?")

      lv |> element("#target-#{shop.id}-remove") |> render_click()
      assert reload(scope, runtime).targets == []
      refute has_element?(lv, "#target-#{shop.id}")
    end

    test "a connection for every target offers no target to add", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, path(scope, runtime, "/targets"))

      assert has_element?(lv, "#connection-applies", "every target")
      refute has_element?(lv, "#add-target")
    end
  end

  describe "Settings" do
    test "where it applies and a service's name are saved", %{conn: conn, scope: scope} do
      {:ok, service} = Connections.create_service(scope, %{service: "npm"})
      {:ok, lv, _html} = live(conn, path(scope, service, "/settings"))

      lv
      |> form("#connection-form", connection: %{applies_to: "selected", name: "Packages"})
      |> render_submit()

      assert %Connection{applies_to: "selected", name: "Packages"} = reload(scope, service)
    end

    test "an integration's plain settings are saved and checked", %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})

      {:ok, lv, _html} = live(conn, path(scope, integration, "/settings"))
      assert has_element?(lv, "#connection-setting-app_id")
      refute has_element?(lv, "#connection-setting-private_key")

      lv
      |> form("#connection-form",
        connection: %{applies_to: "all", argument: "acme/shop", settings: %{app_id: "104231"}}
      )
      |> render_submit()

      integration = reload(scope, integration)
      assert Connection.settings_map(integration) == %{"app_id" => "104231"}
      assert integration.argument == "acme/shop"

      html =
        lv
        |> form("#connection-form", connection: %{applies_to: "all", argument: "not a path!"})
        |> render_submit()

      assert html =~ "The argument doesn&#39;t match"
    end

    test "deleting asks in place, then removes it", %{conn: conn, scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      {:ok, lv, _html} = live(conn, path(scope, runtime, "/settings"))

      lv |> element("#delete-connection-button") |> render_click()
      assert has_element?(lv, "#delete-connection-confirming", "Delete claude?")

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#delete-connection-form") |> render_submit()

      assert to =~ "/settings/integrations"
      assert {:ok, []} = Connections.list_connections(scope)
    end

    test "another version is asked for, and leads to the release", %{conn: conn, scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, integration} = Connections.create_integration(scope, release.id, %{})
      {:ok, lv, _html} = live(conn, path(scope, integration, "/version"))

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#version-form", version: %{version: "0.2.0"}) |> render_submit()

      asked = Apiary.Repo.get_by!(Release, requested_version: "0.2.0")
      assert to =~ "/releases/#{asked.id}?for=#{integration.public_id}"
    end

    test "is read only for a member, whose acts are refused", %{scope: scope} do
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      conn = member_conn(scope, :member)

      {:ok, lv, _html} = live(conn, path(scope, runtime, "/targets"))
      refute has_element?(lv, "#add-target")

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, path(scope, runtime, "/settings"))

      assert flash["error"] =~ "Only owners and admins"

      assert {:error, {:live_redirect, _}} = live(conn, path(scope, runtime, "/delete"))
    end

    test "a connection the workspace does not have is not found", %{conn: conn, scope: scope} do
      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, path(scope, %{public_id: "con_0123456789abcdef"}))
      end
    end
  end
end
