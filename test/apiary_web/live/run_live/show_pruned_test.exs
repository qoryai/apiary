defmodule ApiaryWeb.RunLive.ShowPrunedTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures
  import Apiary.Midnight

  alias Apiary.Retention
  alias Apiary.Runs.{Projector, Run}

  setup :register_and_log_in_user

  # A whole run, projected, then pruned by the job under `setting`.
  defp pruned(scope, setting, events \\ record()) do
    {:ok, workspace} = Retention.update_retention(scope, setting)
    run = run_fixture(scope)
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)

    now = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)
    assert %{runs_pruned: 1} = Retention.prune_workspace(workspace, now: now)
    Apiary.Repo.get!(Run, run.id)
  end

  # The pruning is dated by the clock, and the page reads it as a date in the reader's
  # zone: the reader's clock reads about noon (`Apiary.Midnight`), and today is its date.
  defp today(zone),
    do: ApiaryWeb.Format.with_time_zone(zone, fn -> ApiaryWeb.Format.date(DateTime.utc_now()) end)

  test "a run whose events were pruned keeps its header and says when its timeline went", %{
    conn: conn,
    scope: scope
  } do
    zone = reader_at_noon(scope.user)
    run = pruned(scope, %{events_retention_days: 30})

    {:ok, lv, html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    # The header, from the row.
    assert html =~ "Completed"
    assert html =~ "acme/shop"
    assert html =~ "dev-laptop"

    # Never an empty timeline without a sentence.
    assert has_element?(lv, ".q-limits", "Events pruned")
    assert has_element?(lv, ".q-limits", "This run's events were pruned on #{today(zone)}")
    refute has_element?(lv, "#timeline")
    refute html =~ "No session events arrived"
  end

  test "its terminal says the same, and its connections are still there", %{
    conn: conn,
    scope: scope
  } do
    zone = reader_at_noon(scope.user)
    run = pruned(scope, %{events_retention_days: 30})

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

    assert has_element?(lv, ".q-limits", "This run's events were pruned on #{today(zone)}")
    refute render(lv) =~ "This run wrote no output"

    {:ok, _lv, html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/network")

    assert html =~ "api.example.com"
    assert html =~ "tracker.example.net"

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    assert has_element?(lv, "#run-id", run.public_id)

    # With its policy event pruned, the run has no Policy and no Policy in force.
    refute has_element?(lv, "#rail-policy")
    refute has_element?(lv, "#run-facts .q-kv-policy")
  end

  test "a run that lost only its log keeps its timeline", %{conn: conn, scope: scope} do
    run = pruned(scope, %{log_retention_days: 30})

    {:ok, lv, html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    assert has_element?(lv, "#timeline")
    assert html =~ "Run started"
    refute html =~ "Events pruned"

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}/terminal")

    assert has_element?(lv, ".q-limits", "Log output pruned")
    assert has_element?(lv, ".q-limits", "The timeline and the connections are whole.")
    refute has_element?(lv, "#terminal")
  end

  # A run of two agent sessions, each with a prompt and an answer, and the join of the
  # second between them: with its row, the page shows the Run list.
  defp two_sessions do
    session = fn start, n, prompt, answer ->
      [
        {start, "session.started", session_started_data(%{"session" => n})},
        {start + 1, "runtime.started", %{"session" => n, "session_id" => "session-000#{n}"}},
        {start + 2, "runtime.text", %{"session" => n, "role" => "user", "text" => prompt}},
        {start + 3, "runtime.text", %{"session" => n, "role" => "assistant", "text" => answer}},
        {start + 4, "runtime.result",
         %{"session" => n, "outcome" => "success", "result" => "ok"}},
        {start + 5, "session.exited", %{"session" => n, "state" => "succeeded", "exit_code" => 0}}
      ]
    end

    [{1, "run.started", started_data()}] ++
      session.(2, 1, "Map the checkout", "The checkout has four steps.") ++
      [
        {8, "run.step_started", %{"step" => 1, "name" => "join session 2", "kind" => "join"}},
        {9, "run.step_exited",
         %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1000}}
      ] ++
      session.(10, 2, "Add a test", "The storefront has a test.") ++
      [{16, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}]
  end

  test "a run of two sessions whose events were pruned has no Timeline and no session rows",
       %{conn: conn, scope: scope} do
    run = pruned(scope, %{events_retention_days: 30}, two_sessions())

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    assert has_element?(lv, ".q-limits", "Events pruned")
    refute has_element?(lv, "#timeline")
    refute has_element?(lv, "#timeline-2")
    refute has_element?(lv, "#prepare-machine-session")
    refute has_element?(lv, "#prepare-machine-session-2")
  end

  test "a run of two sessions that lost only its log keeps a Timeline per session", %{
    conn: conn,
    scope: scope
  } do
    run = pruned(scope, %{log_retention_days: 30}, two_sessions())

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    assert has_element?(lv, "#prepare-machine-session #timeline")
    assert has_element?(lv, "#prepare-machine-session-2 #timeline-2")
    assert has_element?(lv, "#timeline #main-session")
    assert has_element?(lv, "#timeline-2 #main-session-2")
    assert has_element?(lv, "#timeline-2 #e-13")
    refute has_element?(lv, ".q-limits", "Events pruned")
  end
end
