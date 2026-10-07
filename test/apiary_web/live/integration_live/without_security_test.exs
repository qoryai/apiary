defmodule ApiaryWeb.IntegrationLive.WithoutSecurityTest do
  # Integrations belong to the security feature: without it the section is absent from the
  # workspace's settings and its paths are not found. Runs in every mode: the test sets the
  # instance's features itself, so it is not async.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag with_features: [:observability]

  setup :register_and_log_in_user

  test "the workspace's settings have no Integrations", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")

    assert has_element?(lv, "#settings-tab-general")
    refute has_element?(lv, "#settings-tab-integrations")
  end

  test "its paths are not found", %{conn: conn, scope: scope} do
    base = "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations"

    for path <- ["", "/add", "/new-runtime", "/new-service", "/definitions/new"] do
      assert get(conn, base <> path).status == 404, path
    end
  end
end
