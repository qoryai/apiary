defmodule ApiaryWeb.WorkspaceLive.OverviewBudgetTest do
  # Not async: the query counter hears every query of the node, so nothing else may run.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Runs.Projector

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.WorkspaceLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    :ok
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    render_async(view, 5_000)
    view
  end

  describe "read budget (oj)" do
    defp count_queries(fun) do
      handler = {__MODULE__, make_ref()}
      counter = :counters.new(1, [])
      page = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # The reads of the page's own process and of its tasks; the sidebar's timed count
          # is tagged and is not what this budget is about.
          if not (metadata[:options][:sidebar] == true), do: :counters.add(counter, 1, 1)
          _ = page
        end,
        nil
      )

      fun.()
      :telemetry.detach(handler)
      :counters.get(counter, 1)
    end

    test "a change of one run costs the same on a workspace of many runs", %{
      conn: conn,
      scope: scope
    } do
      small = for _ <- 1..8, do: started_run(scope, shop())
      view = open(conn)
      run = hd(small)

      small_cost =
        count_queries(fn ->
          for n <- 1..5 do
            event_fixture(
              run,
              100 + n,
              "run.heartbeat",
              %{"elapsed_seconds" => n, "interval_seconds" => 30},
              time: DateTime.utc_now()
            )

            {:ok, _} = Projector.project(run)
            render_async(view, 5_000)
          end
        end)

      # The same page, on a workspace that has grown meanwhile: no broadcast for a row
      # inserted straight into the table, so the page is where it was.
      for _ <- 1..60,
          do:
            run_fixture(scope, %{
              state: "succeeded",
              started_at: DateTime.utc_now(),
              denied_count: 1
            })

      large_cost =
        count_queries(fn ->
          for n <- 1..5 do
            event_fixture(
              run,
              200 + n,
              "run.heartbeat",
              %{"elapsed_seconds" => n, "interval_seconds" => 30},
              time: DateTime.utc_now()
            )

            {:ok, _} = Projector.project(run)
            render_async(view, 5_000)
          end
        end)

      IO.puts(
        "\n[budget overview] 5 projections: #{small_cost} queries on 8 runs, #{large_cost} on 68 runs"
      )

      assert large_cost <= small_cost + 2
      assert large_cost <= 100
    end
  end
end
