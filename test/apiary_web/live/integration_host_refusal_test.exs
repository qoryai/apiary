defmodule ApiaryWeb.IntegrationHostRefusalTest do
  @moduledoc """
  A deny of an integration's host, saved from the rule form or from a row of Network
  access, is refused with the sentence that names the host and the integration, and
  nothing is saved.
  """
  use ApiaryWeb.ConnCase, async: true

  @moduletag needs: :secrets

  import Phoenix.LiveViewTest
  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Connections, Policy}
  alias ApiaryWeb.RunComponents

  @sentence "Remove api.example.com from the rule. acme-tracker needs this host, so no rule can deny it."

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    started_run(scope, shop(), egress: [%{"host" => "api.example.com", "rule" => ""}])

    release =
      ready_release!(
        scope,
        tracker_description(%{"name" => "acme-tracker", "egress_hosts" => ["api.example.com"]}),
        "codeberg.org/acme/tracker"
      )

    {:ok, connection} = Connections.create_integration(scope, release.id, %{})
    assert connection.name == "acme-tracker"
    :ok
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "the rule form shows the sentence under the Host field", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))

    view
    |> form("#policy-rule-form", rule: %{"action" => "deny", "host" => "api.example.com"})
    |> render_change()

    view |> form("#policy-rule-form") |> render_submit()

    assert text(view, "#policy-rule-write-error") == @sentence

    assert has_element?(
             view,
             ".q-rule-field:has(#policy-rule-host) #policy-rule-write-error[role=alert]"
           )

    assert Policy.list_rules(scope, nil) == []
  end

  test "Network access's panel shows the sentence", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/network"))
    render_async(view, 2_000)
    api = RunComponents.destination_id(%{host: "api.example.com", port: 443, path: ""})

    view |> element("##{api}-deny") |> render_click()
    view |> form("#rule-panel-form", %{"for" => "workspace"}) |> render_change()
    view |> form("#rule-panel-form") |> render_submit()

    assert text(view, "#rule-panel-error") == @sentence
    assert Policy.list_rules(scope, nil) == []
  end
end
