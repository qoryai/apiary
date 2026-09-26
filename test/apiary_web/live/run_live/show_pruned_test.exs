defmodule ApiaryWeb.RunLive.ShowPrunedTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures

  alias Apiary.Retention
  alias Apiary.Runs.{Projector, Run}

  setup :register_and_log_in_user

  # A whole run, projected, then pruned by the job under `setting`.
  defp pruned(scope, setting) do
    {:ok, workspace} = Retention.update_retention(scope, setting)
    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, run} = Projector.project(run)

    now = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)
    assert %{runs_pruned: 1} = Retention.prune_workspace(workspace, now: now)
    Apiary.Repo.get!(Run, run.id)
  end

  defp today, do: ApiaryWeb.CoreComponents.short_date(DateTime.utc_now())

  test "a run whose events were pruned keeps its header and says when its timeline went", %{
    conn: conn,
    scope: scope
  } do
    run = pruned(scope, %{events_retention_days: 30})
    {:ok, lv, html} = live(conn, ~p"/workspace/runs/#{run.run_id}")

    # The header, from the row.
    assert html =~ "Succeeded"
    assert html =~ "acme/shop"
    assert html =~ "dev-laptop"

    # Never an empty timeline without a sentence.
    assert has_element?(lv, ".q-limits", "Events pruned")
    assert has_element?(lv, ".q-limits", "This run's events were pruned on #{today()}")
    refute has_element?(lv, "#timeline")
    refute html =~ "No session events arrived"
  end

  test "its terminal says the same, and its connections are still there", %{
    conn: conn,
    scope: scope
  } do
    run = pruned(scope, %{events_retention_days: 30})

    {:ok, lv, _html} = live(conn, ~p"/workspace/runs/#{run.run_id}/terminal")
    assert has_element?(lv, ".q-limits", "This run's events were pruned on #{today()}")
    refute render(lv) =~ "This run wrote no output"

    {:ok, _lv, html} = live(conn, ~p"/workspace/runs/#{run.run_id}/connections")
    assert html =~ "api.example.com"
    assert html =~ "tracker.example.net"

    {:ok, lv, html} = live(conn, ~p"/workspace/runs/#{run.run_id}/details")
    assert has_element?(lv, "#run-id", run.run_id)

    # the policy card is `security`'s (decision 0070)
    if Apiary.Features.on?(:security),
      do: assert(html =~ "The policy event was pruned with the run&#39;s events on #{today()}."),
      else: refute(html =~ "The policy event")
  end

  test "a run that lost only its log keeps its timeline", %{conn: conn, scope: scope} do
    run = pruned(scope, %{log_retention_days: 30})

    {:ok, lv, html} = live(conn, ~p"/workspace/runs/#{run.run_id}")
    assert has_element?(lv, "#timeline")
    assert html =~ "Run started"
    refute html =~ "Events pruned"

    {:ok, lv, _html} = live(conn, ~p"/workspace/runs/#{run.run_id}/terminal")
    assert has_element?(lv, ".q-limits", "Log output pruned")
    assert has_element?(lv, ".q-limits", "The timeline and the connections are whole.")
    refute has_element?(lv, "#terminal")
  end
end
