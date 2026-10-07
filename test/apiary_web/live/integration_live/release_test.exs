defmodule ApiaryWeb.IntegrationLive.ReleaseTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures

  alias Apiary.{Connections, Integrations}
  alias Apiary.Connections.Connection

  @moduletag needs: :security

  setup :register_and_log_in_user

  defp ipath(scope, release, query \\ ""),
    do:
      "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/integrations/releases/#{release.id}#{query}"

  test "a pending release says it is being fetched", %{conn: conn, scope: scope} do
    {:ok, release} =
      Integrations.request_release(scope, %{
        source: "codeberg.org/acme/shop-hooks",
        version: "1.4.0"
      })

    {:ok, lv, _html} = live(conn, ipath(scope, release))

    assert has_element?(lv, "#release-pending", "description.json")
    assert has_element?(lv, "#not-on-runs", "Runs don't receive integrations yet.")
    refute has_element?(lv, "#add-release-form")
  end

  test "a failed release says why, and offers to ask again", %{conn: conn, scope: scope} do
    Req.Test.stub(Apiary.Integrations.Fetch, &Plug.Conn.send_resp(&1, 404, ""))

    {:ok, release} =
      Integrations.request_release(scope, %{
        source: "gitlab.com/acme/tools/hooks",
        version: "1.0.0"
      })

    {:ok, %{state: "failed"}} = Integrations.fetch_release(scope, release.id)

    {:ok, lv, _html} = live(conn, ipath(scope, release))

    assert has_element?(lv, "#release-failed", "couldn't fetch")
    assert has_element?(lv, "#ask-again")
  end

  test "a ready release shows its description and is added with its settings",
       %{conn: conn, scope: scope} do
    release = ready_release!(scope, github_description())
    {:ok, lv, _html} = live(conn, ipath(scope, release))

    assert has_element?(lv, "#settings-section-title", "GitHub")
    assert has_element?(lv, "#release-publisher", "Qory")
    assert has_element?(lv, "#release-publisher", "github.com/qoryai")
    assert has_element?(lv, "#release-ways", "Calls its API")
    assert has_element?(lv, "#release-description", "private_key")
    assert has_element?(lv, "#release-setting-app_id")
    refute has_element?(lv, "#release-setting-private_key")

    {:error, {:live_redirect, %{to: to}}} =
      lv
      |> form("#add-release-form",
        integration: %{applies_to: "all", argument: "", settings: %{app_id: "104231"}}
      )
      |> render_submit()

    {:ok, [connection]} = Connections.list_connections(scope)
    assert connection.kind == "integration"
    assert Connection.settings_map(connection) == %{"app_id" => "104231"}
    assert to =~ "/settings/integrations/#{connection.public_id}"
  end

  test "settings its description refuses are said, and nothing is added",
       %{conn: conn, scope: scope} do
    release = ready_release!(scope, github_description())
    {:ok, lv, _html} = live(conn, ipath(scope, release))

    html =
      lv
      |> form("#add-release-form",
        integration: %{applies_to: "all", argument: "", settings: %{app_id: "not valid!"}}
      )
      |> render_submit()

    assert html =~ "Its settings don&#39;t match"
    assert {:ok, []} = Connections.list_connections(scope)
  end

  test "another version moves the integration there", %{conn: conn, scope: scope} do
    first = ready_release!(scope, github_description())
    {:ok, integration} = Connections.create_integration(scope, first.id, %{})
    second = ready_release!(scope, github_description(%{"program_version" => "0.2.0"}))

    {:ok, lv, _html} = live(conn, ipath(scope, second, "?for=#{integration.public_id}"))
    refute has_element?(lv, "#add-release-form")
    assert has_element?(lv, "#release-move", "Move github from 0.1.0 to 0.2.0")

    {:error, {:live_redirect, _}} = lv |> element("#move-release") |> render_click()

    {:ok, moved} = Connections.get_connection(scope, integration.public_id)
    assert moved.version == "0.2.0"
  end

  test "is read only for a member", %{scope: scope} do
    release = ready_release!(scope, github_description())
    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), ipath(scope, release))

    assert has_element?(lv, "#release-readonly")
    refute has_element?(lv, "#add-release-form")
  end
end
