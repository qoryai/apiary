defmodule ApiaryProWeb.ScopeSettingTest do
  @moduledoc """
  The setting "Available to every workspace in <organisation>" on the Add forms of the
  core's pages (`c:Apiary.Edition.scope_setting?/1`), which the edition shows because an
  organisation has several workspaces: off by default; on, what is added reaches every
  workspace of the organisation; off, it reaches the workspace the form is in alone. The
  core keeps the reach (`Apiary.Connections`); the edition stores none.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Apiary.{Connections, Repo}
  alias Apiary.Secrets.Secret

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-scope-setting-0123456789abcdef"

  setup :register_and_log_in_user

  defp label(scope), do: "Available to every workspace in #{scope.organisation.name}"

  defp new_provider(scope), do: ~p"/#{scope.organisation}/settings/model-providers/new"

  defp integrations(scope, rest),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations#{rest}"

  test "the edition shows the setting", %{scope: scope} do
    assert Apiary.Edition.scope_setting?(scope)
  end

  test "New model provider has the setting, off by default", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, new_provider(scope))

    assert has_element?(lv, "#new-provider-form label", label(scope))

    assert has_element?(
             lv,
             "#new-provider-form input[type=checkbox][name='provider[everywhere]']"
           )

    refute has_element?(
             lv,
             "#new-provider-form input[type=checkbox][name='provider[everywhere]'][checked]"
           )
  end

  test "a model provider added with it on reaches every workspace; with it off, this one",
       %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, new_provider(scope))

    lv
    |> form("#new-provider-form",
      provider: %{provider: "anthropic", key: @key, everywhere: "true"}
    )
    |> render_submit()

    assert {:ok, [every]} = Connections.list_providers(scope)
    assert every.applies_to == "all"
    assert Connections.workspace_ids_of(every) == []
    assert Repo.get!(Secret, every.secret_id).workspace_id == nil

    {:ok, lv, _html} = live(conn, new_provider(scope))

    lv
    |> form("#new-provider-form",
      provider: %{provider: "openrouter", key: @key, everywhere: "false"}
    )
    |> render_submit()

    {:ok, providers} = Connections.list_providers(scope)
    one = Enum.find(providers, &(&1.provider_kind == "openrouter"))
    assert one.applies_to == "selected"
    assert Connections.workspace_ids_of(one) == [scope.workspace.id]
    assert Repo.get!(Secret, one.secret_id).workspace_id == scope.workspace.id
  end

  test "a model provider added with the setting left alone reaches this workspace only",
       %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, new_provider(scope))

    lv
    |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
    |> render_submit()

    assert {:ok, [provider]} = Connections.list_providers(scope)
    assert provider.applies_to == "selected"
    assert Connections.workspace_ids_of(provider) == [scope.workspace.id]
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
