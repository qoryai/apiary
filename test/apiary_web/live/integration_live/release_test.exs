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

  # The release's files where codeberg.org serves them, every other path a 404.
  defp serve_codeberg(description, path) do
    bytes = encode(description)
    base = "/#{path}/releases/download/v#{description["program_version"]}/"

    Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
      case conn.request_path do
        path when path == base <> "description.json" ->
          Plug.Conn.send_resp(conn, 200, bytes)

        path when path == base <> "checksums.txt" ->
          Plug.Conn.send_resp(conn, 200, checksums(bytes))

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  test "a pending release says it is being fetched", %{conn: conn, scope: scope} do
    {:ok, release} =
      Integrations.request_release(scope, %{
        source: "codeberg.org/acme/shop-hooks",
        version: "1.4.0"
      })

    {:ok, lv, _html} = live(conn, ipath(scope, release))

    assert has_element?(
             lv,
             "#release-pending",
             "Fetching the release's description.json and checksums.txt…"
           )

    assert has_element?(lv, "#release-status.sr-only[role=status]", "Fetching the release's")
    assert has_element?(lv, "#not-on-runs", "Runs don't use any of this yet:")
    assert has_element?(lv, "#settings-section-integrations header span[aria-hidden=true]", "·")
    refute has_element?(lv, "#add-release-form")
  end

  test "the poll finds the release read, and says so", %{conn: conn, scope: scope} do
    {:ok, release} =
      Integrations.request_release(scope, %{source: "codeberg.org/acme/hooks", version: "0.1.0"})

    {:ok, lv, _html} = live(conn, ipath(scope, release))
    assert has_element?(lv, "#release-pending")

    serve_codeberg(github_description(), "acme/hooks")
    {:ok, %{state: "ready"}} = Integrations.fetch_release(scope, release.id)
    send(lv.pid, :poll)

    assert has_element?(lv, "#release-status[role=status]", "The release is read.")
    refute has_element?(lv, "#release-pending")
    assert has_element?(lv, "#release-found", "GitHub")
    assert has_element?(lv, "#add-release-form")
  end

  test "the poll finds the release failed, and says why", %{conn: conn, scope: scope} do
    {:ok, release} =
      Integrations.request_release(scope, %{source: "codeberg.org/acme/hooks", version: "0.1.0"})

    {:ok, lv, _html} = live(conn, ipath(scope, release))

    Req.Test.stub(Apiary.Integrations.Fetch, &Plug.Conn.send_resp(&1, 404, ""))
    {:ok, %{state: "failed"}} = Integrations.fetch_release(scope, release.id)
    send(lv.pid, :poll)

    assert has_element?(lv, "#release-failed", "couldn't be fetched")
    refute has_element?(lv, "#release-pending")
    refute has_element?(lv, "#release-status", "The release is read.")
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

    assert has_element?(
             lv,
             "#release-failed",
             "The release's description.json and checksums.txt couldn't be fetched."
           )

    query = URI.encode_query(source: "gitlab.com/acme/tools/hooks", version: "1.0.0")
    assert has_element?(lv, ~s(#ask-again[href$="/settings/integrations/add?#{query}"]))
  end

  test "a ready release shows its description and is added with its settings",
       %{conn: conn, scope: scope} do
    release = ready_release!(scope, github_description())
    {:ok, lv, _html} = live(conn, ipath(scope, release))

    assert has_element?(lv, "h1#settings-section-title", "GitHub")
    assert has_element?(lv, "#settings-section-integrations", "github.com/qoryai/qory-github")
    assert has_element?(lv, "#breadcrumb-section", "Integrations")
    assert has_element?(lv, "#breadcrumb [aria-current=page]", "Add from a release")
    assert page_title(lv) =~ "Add from a release · Workspace settings"
    assert has_element?(lv, "#release-publisher", "Qory")
    assert has_element?(lv, "#release-publisher", "github.com/qoryai")
    assert has_element?(lv, "#release-ways", "Calls its API")
    assert has_element?(lv, "#release-description", "private_key")

    assert has_element?(
             lv,
             "#release-found",
             "The release is only read; nothing of it runs on Qory Apiary."
           )

    assert has_element?(lv, "#release-setting-app_id")
    refute has_element?(lv, "#release-setting-private_key")
    assert has_element?(lv, "#add-release-form fieldset legend", "For runs in")

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

  test "a yes/no setting says what it is", %{conn: conn, scope: scope} do
    description =
      github_description()
      |> put_in(["settings", "properties", "verbose"], %{
        "title" => "Verbose",
        "type" => "boolean",
        "description" => "Logs every request it makes."
      })
      |> update_in(["roles", "credential", "settings"], &(&1 ++ ["verbose"]))

    release = ready_release!(scope, description)
    {:ok, lv, _html} = live(conn, ipath(scope, release))

    assert has_element?(
             lv,
             "#release-setting-verbose[aria-describedby='release-setting-verbose-hint']"
           )

    assert has_element?(lv, "#release-setting-verbose-hint", "Logs every request it makes.")
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
    assert has_element?(lv, "#release-move", "Move GitHub (github) from 0.1.0 to 0.2.0")
    assert has_element?(lv, "#release-move .q-mono", "(github)")

    {:error, {:live_redirect, _}} = result = lv |> element("#move-release") |> render_click()
    {:ok, _lv, html} = follow_redirect(result, conn)
    assert html =~ "GitHub (github) is at 0.2.0."
    {:ok, moved} = Connections.get_connection(scope, integration.public_id)
    assert moved.version == "0.2.0"
  end

  test "only an integration of the same source moves to it", %{conn: conn, scope: scope} do
    {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
    tracker = ready_release!(scope, tracker_description(), "github.com/acme/tracker")
    {:ok, other} = Connections.create_integration(scope, tracker.id, %{})
    release = ready_release!(scope, github_description())

    for connection <- [runtime, other] do
      {:ok, lv, _html} = live(conn, ipath(scope, release, "?for=#{connection.public_id}"))
      refute has_element?(lv, "#release-move")

      # Move, sent where it is not offered, does nothing.
      render_hook(lv, "move", %{})
      assert Process.alive?(lv.pid)
    end

    {:ok, unchanged} = Connections.get_connection(scope, other.public_id)
    assert unchanged.version == "0.3.0"
  end

  test "another workspace's release is not this one's", %{conn: conn, scope: scope} do
    other = sign_up_fixture().scope
    release = ready_release!(other, github_description())

    assert_raise ApiaryWeb.NotFound, fn -> live(conn, ipath(scope, release)) end
  end

  test "is read only for a member", %{scope: scope} do
    release = ready_release!(scope, github_description())
    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), ipath(scope, release))

    assert has_element?(lv, "#release-readonly")
    refute has_element?(lv, "#add-release-form")

    html =
      render_hook(lv, "add", %{
        "integration" => %{"applies_to" => "all", "settings" => %{"app_id" => "104231"}}
      })

    assert html =~ "Only owners and admins"
    assert {:ok, []} = Connections.list_connections(scope)
  end
end
