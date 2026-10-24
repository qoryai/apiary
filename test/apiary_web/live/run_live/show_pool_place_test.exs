defmodule ApiaryWeb.RunLive.ShowPoolPlaceTest do
  @moduledoc """
  Where a run ran, wherever the pages show a run's host (`ApiaryWeb.RunComponents.place_of/1`,
  `Apiary.Runs.Place`): for a run a node pool's dispatch handed over, the pool's name,
  never the host its `run.started` reported; for any other run, that host. The run page's
  header, its Run started item and its Details tab's Host row, the runs list's Host column,
  its preview and its Filter, a target's runs and its Machines, and a key's hosts.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{Runs, Targets}
  alias Apiary.Runs.{Filters, Projector}

  @moduletag needs: :factory

  # The host of the pool's machine, which no page shows, and of the run outside a pool.
  @machine "pool-machine-7"
  @laptop "dev-laptop"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    pool = pool_fixture(scope, name: "mac-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{access_key: local_key} = access_key_fixture(scope)

    %{run: pool_run} = handed_over_fixture(scope, key)
    pool_run = started(pool_run, @machine)

    local_run =
      scope
      |> run_fixture(%{state: "running", access_key_id: local_key.id})
      |> started(@laptop)

    %{pool_run: pool_run, local_run: local_run, key: key, local_key: local_key}
  end

  # The run with its `run.started` from `host`, of the target acme/shop, projected.
  defp started(run, host) do
    event_fixture(run, 1, "run.started", started_data(%{"host" => host}))
    {:ok, run} = Projector.project(run)
    ^host = run.host
    true = is_binary(run.target_id)
    run
  end

  defp open(conn, path) do
    {:ok, lv, _html} = live(conn, path)
    render_async(lv)
    lv
  end

  defp run_page(conn, scope, run),
    do: open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}")

  defp preview(conn, scope, run) do
    lv = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs?run=#{run.public_id}")
    render_hook(lv, "viewport", %{"wide" => true})
    render_async(lv)
    lv |> element("#runs-preview .q-pv-m") |> render()
  end

  # The value `fun` returns and how many queries it sent.
  defp counted(fun) do
    handler = "pool-place-#{System.unique_integer()}"
    parent = self()

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == parent, do: send(parent, :query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(n) do
    receive do
      :query -> drain(n + 1)
    after
      0 -> n
    end
  end

  test "the header: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    lv = run_page(conn, scope, pool_run)
    assert has_element?(lv, "#run-meta #run-host", "mac-pool")
    refute has_element?(lv, "#run-meta #run-host.font-mono")
    refute lv |> element("#run-meta") |> render() =~ @machine

    lv = run_page(conn, scope, local_run)
    assert has_element?(lv, "#run-meta #run-host.font-mono > bdi", @laptop)
  end

  test "the Run started item: a pool's run started on the pool, any other run on its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    lv = run_page(conn, scope, pool_run)
    assert lv |> element("#e-1 .q-s") |> render() =~ "on mac-pool, without a wall"
    refute lv |> element("#e-1") |> render() =~ @machine

    lv = run_page(conn, scope, local_run)
    assert lv |> element("#e-1 .q-s") |> render() =~ "on #{@laptop}, without a wall"
  end

  test "the Details tab's Host row: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    lv = run_page(conn, scope, pool_run)
    assert has_element?(lv, "#run-details #rail-host", "mac-pool")
    refute has_element?(lv, "#run-details #rail-host.font-mono")
    refute lv |> element("#run-details #rail-host") |> render() =~ @machine

    lv = run_page(conn, scope, local_run)
    assert has_element?(lv, "#run-details #rail-host.font-mono > bdi", @laptop)
  end

  test "the runs list's preview: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    html = preview(conn, scope, pool_run)
    assert html =~ "mac-pool"
    refute html =~ @machine

    html = preview(conn, scope, local_run)
    assert html =~ @laptop
    refute html =~ "mac-pool"
  end

  test "the runs list's Host column: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    lv = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")

    pool_cell = lv |> element("#run-#{pool_run.public_id} .q-rl-host") |> render()
    assert pool_cell =~ "mac-pool"
    refute pool_cell =~ @machine

    local_cell = lv |> element("#run-#{local_run.public_id} .q-rl-host") |> render()
    assert local_cell =~ @laptop
    refute local_cell =~ "mac-pool"
  end

  test "the target page's runs: a pool's run shows the pool's name, any other run its host",
       %{conn: conn, scope: scope, pool_run: pool_run, local_run: local_run} do
    %{public_id: target} = Apiary.Repo.get!(Apiary.Runs.Target, pool_run.target_id)
    lv = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/targets/#{target}")

    pool_row = lv |> element("#target-last-runs-#{pool_run.id}") |> render()
    assert pool_row =~ "mac-pool"
    refute pool_row =~ @machine

    local_row = lv |> element("#target-last-runs-#{local_run.id}") |> render()
    assert local_row =~ @laptop
    refute local_row =~ "mac-pool"
  end

  test "the runs list's Filter: a pool's run is chosen and found by the pool's name, any other run by its host",
       %{scope: scope, pool_run: pool_run, local_run: local_run} do
    ids = [pool_run.id, local_run.id]

    assert %{options: options} = Runs.run_facets(scope, %Filters{}).host
    assert Enum.sort(options) == [{@laptop, @laptop, 1}, {"mac-pool", "mac-pool", 1}]

    assert Runs.matching_ids(scope, %Filters{host: "mac-pool"}, ids) == [pool_run.id]
    assert Runs.matching_ids(scope, %Filters{host: @machine}, ids) == []
    assert Runs.matching_ids(scope, %Filters{host: @laptop}, ids) == [local_run.id]

    # A pool machine's host, chosen, counts no run.
    assert {@machine, @machine, 0} in Runs.run_facets(scope, %Filters{host: @machine}).host.options
  end

  test "a target's Machines: a pool's runs count under the pool's name, any other run under its host; one query",
       %{scope: scope, pool_run: pool_run} do
    target = Apiary.Repo.get!(Apiary.Runs.Target, pool_run.target_id)

    assert {[{@laptop, 1}, {"mac-pool", 1}], 1} =
             counted(fn -> Targets.machines(scope, target) end)
  end

  test "a key's hosts: a pool's key lists the pool's name, any other key its runs' host; one query",
       %{scope: scope, key: key, local_key: local_key} do
    since = DateTime.add(t0(), -86_400, :second)

    assert {hosts, 1} = counted(fn -> Runs.hosts_by_key(scope, [key.id, local_key.id], since) end)

    assert hosts == %{
             key.id => %{count: 1, host: "mac-pool"},
             local_key.id => %{count: 1, host: @laptop}
           }
  end
end
