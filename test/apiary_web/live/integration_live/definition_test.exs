defmodule ApiaryWeb.IntegrationLive.DefinitionTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections

  @moduletag needs: :security

  setup :register_and_log_in_user

  defp ipath(scope, rest),
    do:
      "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations/definitions#{rest}"

  defp definition!(scope, key \\ "status-api") do
    {:ok, definition} =
      Connections.create_service_definition(scope, %{
        "version" => 1,
        "key" => key,
        "title" => "Status API",
        "hosts" => ["status.example.com"],
        "auth" => %{"scheme" => "bearer", "secret" => "key"},
        "declares" => [%{"id" => "key", "title" => "API key", "name" => "STATUS_API_KEY"}]
      })

    definition
  end

  test "a new definition is written as JSON, from an example", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ipath(scope, "/new"))
    assert has_element?(lv, "#definition-page-title", "New service definition")
    assert has_element?(lv, "#not-on-runs")

    {:error, {:live_redirect, %{to: to}}} =
      lv |> form("#definition-form") |> render_submit()

    {:ok, [definition]} = Connections.list_service_definitions(scope)
    assert definition.key == "status-api"
    assert to == ipath(scope, "/#{definition.public_id}")
  end

  test "a definition that isn't valid says what is wrong", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ipath(scope, "/new"))

    html =
      lv
      |> form("#definition-form", definition: %{json: ~s({"key": "x"})})
      |> render_submit()

    assert html =~ "It is not a service definition"
    assert {:ok, []} = Connections.list_service_definitions(scope)
  end

  test "a definition's page shows it, and it is edited on a page", %{conn: conn, scope: scope} do
    definition = definition!(scope)
    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}"))

    assert has_element?(lv, "#definition-facts", "status.example.com")
    assert has_element?(lv, "#definition-facts", "STATUS_API_KEY")
    assert has_element?(lv, "#definition-json", "status-api")

    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}/edit"))

    json =
      ~s({"version": 1, "key": "status-api", "title": "Status page", "hosts": ["status.example.com"], "auth": {"scheme": "bearer", "secret": "key"}, "declares": [{"id": "key", "title": "API key"}]})

    {:error, {:live_redirect, _}} =
      lv |> form("#definition-form", definition: %{json: json}) |> render_submit()

    {:ok, [changed]} = Connections.list_service_definitions(scope)
    assert changed.title == "Status page"
  end

  test "deleting asks in place, and is refused while a service names it",
       %{conn: conn, scope: scope} do
    definition = definition!(scope)

    {:ok, service} =
      Connections.create_service(scope, %{definition_id: definition.public_id})

    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}"))
    assert has_element?(lv, "#definition-user-#{service.public_id}")
    assert has_element?(lv, "#delete-definition-button[disabled]")

    {:ok, _} = Connections.delete_connection(scope, service)
    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}/delete"))
    assert has_element?(lv, "#delete-definition-confirming", "Delete Status API?")

    {:error, {:live_redirect, _}} = lv |> form("#delete-definition-form") |> render_submit()
    assert {:ok, []} = Connections.list_service_definitions(scope)
  end

  test "a member reads it and changes nothing", %{scope: scope} do
    definition = definition!(scope)
    %{user: user} = member_fixture(scope, :member)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}"))
    refute has_element?(lv, "#edit-definition")
    refute has_element?(lv, "#delete-definition")

    assert {:error, {:live_redirect, %{flash: flash}}} = live(conn, ipath(scope, "/new"))
    assert flash["error"] =~ "Only owners and admins"
  end
end
