defmodule ApiaryProWeb.ScopeSettingTest do
  @moduledoc """
  The setting "Available to every workspace in <organisation>" on the forms that add an
  API or a runtime (`c:Apiary.Edition.scope_setting?/1`), which the edition shows because
  an organisation has several workspaces: off by default; on, what is added reaches every
  workspace of the organisation; off, it reaches the workspace the form is in alone. The
  core keeps the reach (`Apiary.Connections`); the edition stores none. New model
  provider key has Workspaces in its place (`ApiaryWeb.ModelProviderKeysTest`).
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Connections

  @moduletag needs: [:factory, :secrets]

  setup :register_and_log_in_user

  defp label(scope), do: "Available to every workspace in #{scope.organisation.name}"

  defp integrations(scope, rest),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations#{rest}"

  test "the edition shows the setting", %{scope: scope} do
    assert Apiary.Edition.scope_setting?(scope)
  end

  test "an API and a runtime have the setting, off by default", %{conn: conn, scope: scope} do
    for {path, form} <- [
          {"/new-service", "#new-service-form"},
          {"/new-runtime", "#new-runtime-form"}
        ] do
      {:ok, lv, _html} = live(conn, integrations(scope, path))
      assert has_element?(lv, "#{form} label", label(scope))
      assert has_element?(lv, "#{form} input[type=checkbox][name='connection[everywhere]']")
      refute has_element?(lv, "#{form} input[name='connection[everywhere]'][checked]")
    end
  end

  test "an API added with it on reaches every workspace; with it off, this one",
       %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, integrations(scope, "/new-service"))

    lv
    |> form("#new-service-form",
      connection: %{definition: "builtin:npm", name: "Packages", everywhere: "true"}
    )
    |> render_submit()

    {:ok, lv, _html} = live(conn, integrations(scope, "/new-service"))

    lv
    |> form("#new-service-form",
      connection: %{definition: "builtin:sentry", name: "Errors", everywhere: "false"}
    )
    |> render_submit()

    {:ok, connections} = Connections.list_connections(scope)
    by_name = Map.new(connections, &{&1.name, &1})
    assert by_name["Packages"].applies_to == "all"
    assert by_name["Errors"].applies_to == "selected"
    assert Connections.workspace_ids_of(by_name["Errors"]) == [scope.workspace.id]
  end
end
