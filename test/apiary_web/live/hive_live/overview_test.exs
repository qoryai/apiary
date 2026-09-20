defmodule ApiaryWeb.HiveLive.OverviewTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures

  describe "/hive" do
    setup :register_and_log_in_user

    test "shows the empty state with one call to action", %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/hive")

      assert html =~ scope.hive.name
      assert html =~ scope.organisation.name
      assert html =~ "Connect your first machine"
      assert html =~ "Paste the server block into the runner file"
      assert html =~ ~r/<abbr[^>]*title="organisation"[^>]*>apiary<\/abbr>/
      assert html =~ ~r/<abbr[^>]*title="team"[^>]*>hive<\/abbr>/

      # the user menu lives in the shell
      assert html =~ ~p"/users/settings"
      assert html =~ ~p"/users/log-out"

      # one membership: no switcher
      refute html =~ ~p"/organisations/switch"

      {:ok, _lv, html} =
        lv
        |> element("a", "Create an access key")
        |> render_click()
        |> follow_redirect(conn, ~p"/hive/keys/new")

      assert html =~ "New access key"
    end

    test "shows summary cards once a key exists", %{conn: conn, scope: scope} do
      access_key_fixture(scope, label: "build-server-1")

      {:ok, _lv, html} = live(conn, ~p"/hive")

      refute html =~ "Connect your first machine"
      assert html =~ "Access keys"
      assert html =~ "Members"
      assert html =~ "1 owner"
      assert html =~ "Connect a machine"
      assert html =~ "Runs will appear here once a machine posts."
    end
  end

  test "redirects to log in when signed out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/hive")
  end

  test "sends a user without a hive to a friendly page", %{conn: conn} do
    conn = log_in_user(conn, Apiary.AccountsFixtures.user_fixture())

    assert {:error, {:redirect, %{to: "/no-hive"}}} = live(conn, ~p"/hive")

    {:ok, _lv, html} = live(conn, ~p"/no-hive")
    assert html =~ "not part of an"
    assert html =~ "Log out"
  end
end
