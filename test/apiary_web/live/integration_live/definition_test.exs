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
    assert has_element?(lv, "#definition-page-title", "New custom API")
    assert has_element?(lv, "#not-on-runs")

    assert has_element?(
             lv,
             "#definition-page",
             "A custom API says which hosts it is, how its secret is sent and which secrets it needs."
           )

    assert has_element?(lv, "#definition-save button[type=submit]", "Create custom API")
    assert has_element?(lv, "#breadcrumb-section", "Integrations")
    assert page_title(lv) =~ "New custom API · Integrations · Workspace settings"

    {:error, {:live_redirect, %{to: to}}} =
      lv |> form("#definition-form") |> render_submit()

    {:ok, [definition]} = Connections.list_service_definitions(scope)
    assert definition.key == "status-api"
    assert to == ipath(scope, "/#{definition.public_id}")
  end

  test "a definition that isn't valid says what is wrong", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ipath(scope, "/new"))

    lv
    |> form("#definition-form", definition: %{json: ~s({"key": "x"})})
    |> render_submit()

    # What is wrong is the field's own error, which describes it and takes the focus.
    assert has_element?(
             lv,
             "#definition_json[aria-invalid=true][aria-describedby=definition_json-error]"
           )

    assert has_element?(lv, "#definition_json-error", "It is not a custom API's definition")
    assert_push_event(lv, "run:focus", %{id: "definition_json"})
    assert {:ok, []} = Connections.list_service_definitions(scope)
  end

  test "a definition over 64 KiB is refused before it is read", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ipath(scope, "/new"))
    json = ~s({"key": "status-api", "title": ") <> String.duplicate("a", 65_536) <> ~s("})

    lv |> form("#definition-form", definition: %{json: json}) |> render_submit()

    assert has_element?(
             lv,
             "#definition_json-error",
             "The definition is too long: it takes at most 64 KiB of JSON."
           )

    assert {:ok, []} = Connections.list_service_definitions(scope)
  end

  test "a definition's page shows it, and it is edited on a page", %{conn: conn, scope: scope} do
    definition = definition!(scope)
    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}"))

    assert has_element?(lv, "#definition-facts", "status.example.com")
    assert has_element?(lv, "#definition-facts", "STATUS_API_KEY")
    assert has_element?(lv, "#definition-json", "status-api")
    assert has_element?(lv, "h1#settings-section-title", "Status API")

    assert has_element?(
             lv,
             "#settings-section-integrations",
             "A custom API of this workspace's own"
           )

    assert has_element?(lv, "#definition-users h2", "Where it is set up")
    assert has_element?(lv, "#definition-users", "It isn't set up yet.")
    assert has_element?(lv, "#delete-definition-title", "Delete this custom API")
    refute lv |> element("#settings-section-integrations") |> render() =~ "ervice definition"

    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}/edit"))
    assert has_element?(lv, "#definition-page-title", "Edit custom API")
    assert has_element?(lv, "#definition-save button[type=submit]", "Save custom API")

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
    assert has_element?(lv, "#delete-definition-button[disabled]", "Delete custom API…")
    assert has_element?(lv, "#delete-definition", "APIs are set up from it: remove them first.")

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

    # Its writes, sent as events, are refused or not taken, and change nothing.
    assert render_hook(lv, "delete", %{}) =~ "Only owners and admins"
    render_hook(lv, "save", %{"definition" => %{"json" => ~s({"key": "x"})}})
    assert {:ok, [_definition]} = Connections.list_service_definitions(scope)

    assert {:error, {:live_redirect, %{flash: flash}}} = live(conn, ipath(scope, "/new"))
    assert flash["error"] =~ "Only owners and admins"
  end

  test "an event sent where its control is not changes nothing", %{conn: conn, scope: scope} do
    definition = definition!(scope)

    {:ok, lv, _html} = live(conn, ipath(scope, "/#{definition.public_id}"))
    render_hook(lv, "save", %{"definition" => %{"json" => ~s({"key": "x"})}})
    assert Process.alive?(lv.pid)

    {:ok, lv, _html} = live(conn, ipath(scope, "/new"))
    render_hook(lv, "delete", %{})
    render_hook(lv, "save", %{"definition" => %{"json" => 1}})
    assert Process.alive?(lv.pid)

    assert {:ok, [_definition]} = Connections.list_service_definitions(scope)
  end

  test "another workspace's definition is not this one's", %{conn: conn, scope: scope} do
    theirs = definition!(sign_up_fixture().scope)

    assert_raise ApiaryWeb.NotFound, fn ->
      live(conn, ipath(scope, "/#{theirs.public_id}"))
    end
  end
end
