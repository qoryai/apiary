defmodule ApiaryWeb.HiveLive.OverviewTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs
  alias Apiary.Runs.{Liveness, Projector}

  describe "/hive" do
    setup :register_and_log_in_user

    test "shows the empty state with one call to action", %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/hive")

      assert html =~ scope.hive.name
      assert html =~ scope.organisation.name
      assert html =~ "Connect your first machine"
      assert html =~ "Paste the server block into the runner file"
      assert html =~ ~r/<abbr[^>]*data-tip="organisation"[^>]*>apiary<\/abbr>/
      assert html =~ ~r/<abbr[^>]*data-tip="team"[^>]*>hive<\/abbr>/

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
      assert html =~ "Listening for the first post from a machine."
    end
  end

  describe "runs alive now" do
    setup :register_and_log_in_user

    setup %{scope: scope} do
      access_key_fixture(scope)
      :ok
    end

    defp alive(lv) do
      html = lv |> element("#runs-alive .stat-value") |> render()
      [_, count] = Regex.run(~r/>\s*(\d+)\s*</, html)
      count
    end

    test "links to the runs: the count always, a button once a machine has posted", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive")
      assert has_element?(lv, "a#runs-alive[href='/hive/runs']")
      refute has_element?(lv, "#overview-runs")

      run = run_fixture(scope)
      event_fixture(run, 2, "run.started", started_data())
      {:ok, _} = Projector.project(run)

      assert has_element?(lv, "#overview-runs[href='/hive/runs']")
      assert has_element?(lv, "#nav-runs-alive", "1")
    end

    test "is zero, and the page listens, before anything has posted", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/hive")

      assert html =~ "Runs alive now"
      assert alive(lv) == "0"
      assert html =~ "none running"
      assert html =~ "Listening for the first post from a machine."
    end

    test "counts the pending and running runs of this hive only", %{conn: conn, scope: scope} do
      for state <- ~w(pending running exited lost closed), do: run_fixture(scope, %{state: state})
      run_fixture(scope_fixture(), %{state: "running"})

      {:ok, lv, html} = live(conn, ~p"/hive")

      assert alive(lv) == "2"
      assert html =~ "starting or running"
      refute html =~ "Listening for the first post"
    end

    test "follows the hive live: a run starts, is lost, beats again, exits", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/hive")
      assert alive(lv) == "0"

      run = run_fixture(scope)
      event_fixture(run, 1, "run.started", started_data())
      {:ok, _} = Projector.project(run)
      assert alive(lv) == "1"
      refute render(lv) =~ "Listening for the first post"

      assert [_] = Liveness.check(DateTime.add(DateTime.utc_now(), 3600, :second))
      assert alive(lv) == "0"

      event_fixture(run, 2, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30},
        time: DateTime.utc_now()
      )

      {:ok, _} = Projector.project(run)
      assert alive(lv) == "1"

      event_fixture(run, 3, "run.exited", %{
        "state" => "succeeded",
        "exit_code" => 0,
        "duration_ms" => 10
      })

      {:ok, _} = Projector.project(run)
      assert alive(lv) == "0"
    end

    test "a closed run is no longer alive, and another hive's run changes nothing", %{
      conn: conn,
      scope: scope
    } do
      run = run_fixture(scope, %{state: "running"})
      {:ok, lv, _html} = live(conn, ~p"/hive")
      assert alive(lv) == "1"

      other = scope_fixture()
      {:ok, _} = Runs.close_run(other, run_fixture(other, %{state: "running"}))
      assert alive(lv) == "1"

      {:ok, _} = Runs.close_run(scope, run)
      assert alive(lv) == "0"
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
