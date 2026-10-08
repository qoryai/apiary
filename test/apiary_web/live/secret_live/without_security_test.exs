defmodule ApiaryWeb.SecretLive.WithoutSecurityTest do
  # Secrets and variables belong to the secrets feature, which needs security: without
  # security the section is absent from the workspace's settings and its paths are not
  # found. Runs in every mode: the test sets the instance's features itself, so it is not
  # async.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag with_features: [:observability]

  setup :register_and_log_in_user

  test "the workspace's settings have no Secrets and variables", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")

    assert has_element?(lv, "#settings-tab-general")
    refute has_element?(lv, "#settings-tab-secrets")
  end

  test "its paths are not found", %{conn: conn, scope: scope} do
    base = "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings"

    for path <- ~w(/secrets /secrets/new /variables /variables/new) do
      assert get(conn, base <> path).status == 404, path
    end
  end
end
