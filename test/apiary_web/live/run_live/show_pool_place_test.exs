defmodule ApiaryWeb.RunLive.ShowPoolPlaceTest do
  @moduledoc """
  Where a run ran, as the run page's header, its Run started item and the runs list's
  preview show it (`ApiaryWeb.RunComponents.place_of/1`): for a run a node pool's dispatch
  handed over, the pool's name, never the host its `run.started` reported; for any other
  run, that host.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    pool = pool_fixture(scope, name: "mac-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)

    %{run: pool_run} = handed_over_fixture(scope, key)
    pool_run = started(pool_run)
    local_run = scope |> run_fixture(%{state: "running"}) |> started()

    %{pool_run: pool_run, local_run: local_run}
  end

  # The run with its `run.started`, from the host dev-laptop, projected.
  defp started(run) do
    event_fixture(run, 1, "run.started", started_data())
    {:ok, run} = Projector.project(run)
    "dev-laptop" = run.host
    run
  end

  defp run_page(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}")

    lv
  end

  defp preview(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs?run=#{run.public_id}")

    render_async(lv)
    render_hook(lv, "viewport", %{"wide" => true})
    render_async(lv)
    lv |> element("#runs-preview .q-pv-m") |> render()
  end

  test "the header: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    lv = run_page(conn, scope, pool_run)
    assert has_element?(lv, "#run-meta #run-host", "mac-pool")
    refute has_element?(lv, "#run-meta #run-host.font-mono")
    refute lv |> element("#run-meta") |> render() =~ "dev-laptop"

    lv = run_page(conn, scope, local_run)
    assert has_element?(lv, "#run-meta #run-host.font-mono > bdi", "dev-laptop")
  end

  test "the Run started item: a pool's run started on the pool, any other run on its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    lv = run_page(conn, scope, pool_run)
    assert lv |> element("#e-1 .q-s") |> render() =~ "on mac-pool, without a wall"
    refute lv |> element("#e-1") |> render() =~ "dev-laptop"

    lv = run_page(conn, scope, local_run)
    assert lv |> element("#e-1 .q-s") |> render() =~ "on dev-laptop, without a wall"
  end

  test "the runs list's preview: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    html = preview(conn, scope, pool_run)
    assert html =~ "mac-pool"
    refute html =~ "dev-laptop"

    html = preview(conn, scope, local_run)
    assert html =~ "dev-laptop"
    refute html =~ "mac-pool"
  end
end
