defmodule ApiaryWeb.RunLive.ShowCleanUpTest do
  @moduledoc """
  The Machine removed row of a run's Run list on the run page
  (`ApiaryWeb.PreparationComponents.clean_up/3`): each row the page shows from the
  starter's report, the wait of 15 minutes after the run ended and its end on an open
  page, the report that reaches an open page on the run's topic, the runs with no such
  row, a run that goes on and a dispatch released before a machine existed, and a run on
  a permanent machine, whose last row is Machine stays registered.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Runs.{Projector, Run}

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp claimed_run(scope) do
    pool = pool_fixture(scope, name: "build-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    scope |> handed_over_fixture(key) |> Map.put(:key, key)
  end

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp steps(exited?) do
    [
      {1, "run.started", started_data()},
      {2, "run.step_started", %{"step" => 1, "name" => "setup", "kind" => "setup"}},
      {3, "run.step_exited",
       %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1_000}}
    ] ++
      if(exited?,
        do: [{4, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 2_000}}],
        else: []
      )
  end

  defp open(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

    lv
  end

  # The row's name and words.
  defp row(lv) do
    assert has_element?(lv, "#prepare-machine-removed .q-k", "Machine removed")

    lv
    |> element("#prepare-machine-removed.q-prep-row, #prepare-machine-removed > summary")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp end_dispatch!(%Dispatch{id: id}, ended_at) do
    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [ended_at: ended_at, end_cause: :run_ended]
      )
  end

  defp report!(%{key: key, dispatch: dispatch}, state),
    do: :ok = Dispatches.report_machine_end(key, dispatch.public_id, %{state: state})

  describe "a run whose dispatch was handed over" do
    test "after its end, waits for a report, with one timer for the end of the wait", ctx do
      claimed = claimed_run(ctx.scope)
      run = project!(claimed.run, steps(true))
      end_dispatch!(claimed.dispatch, DateTime.add(DateTime.utc_now(), -60, :second))

      lv = open(ctx.conn, ctx.scope, run)
      assert row(lv) =~ "Waiting for a report"
      # Started is the run's end; there is no duration while no report has come.
      assert has_element?(lv, "#prepare-machine-removed .q-tc1 time")
      refute has_element?(lv, "#prepare-machine-removed .q-tc2 .q-d")

      timer = :sys.get_state(lv.pid).socket.assigns.clean_up_timer
      left = Process.read_timer(timer)
      assert is_integer(left) and left > 13 * 60_000 and left <= 14 * 60_000 + 1
    end

    test "15 minutes after its end, has no report", ctx do
      claimed = claimed_run(ctx.scope)
      run = project!(claimed.run, steps(true))
      end_dispatch!(claimed.dispatch, DateTime.add(DateTime.utc_now(), -16 * 60, :second))

      lv = open(ctx.conn, ctx.scope, run)
      assert row(lv) =~ "No removal report"
      assert :sys.get_state(lv.pid).socket.assigns.clean_up_timer == nil
    end

    test "an open page moves to no report when the wait ends", ctx do
      claimed = claimed_run(ctx.scope)
      run = project!(claimed.run, steps(true))
      end_dispatch!(claimed.dispatch, DateTime.add(DateTime.utc_now(), -60, :second))

      lv = open(ctx.conn, ctx.scope, run)
      assert row(lv) =~ "Waiting for a report"

      # The clock cannot move in a test: the dispatch ends earlier instead, and the timer's
      # message comes now.
      end_dispatch!(claimed.dispatch, DateTime.add(DateTime.utc_now(), -16 * 60, :second))
      send(lv.pid, :clean_up_due)
      assert row(lv) =~ "No removal report"
    end

    test "each report shows with its time, on an open page whose section had settled", ctx do
      claimed = claimed_run(ctx.scope)
      run = project!(claimed.run, steps(true))
      end_dispatch!(claimed.dispatch, DateTime.add(DateTime.utc_now(), -60, :second))

      lv = open(ctx.conn, ctx.scope, run)
      assert :sys.get_state(lv.pid).socket.assigns.preparation_settled
      assert row(lv) =~ "Waiting for a report"

      for {state, words} <- [
            {:deleting, "Machine removal requested"},
            {:delete_failed, "Removal failed: the machine still exists"}
          ] do
        report!(claimed, state)
        assert row(lv) =~ words
        refute has_element?(lv, "#prepare-machine-removed .q-tc2 .q-d")
      end

      # The gone report: no words beside the name, the time from the run's end to the
      # report, and the cause and the machine's time alive.
      report!(claimed, :gone)
      refute row(lv) =~ "Removal failed"
      refute has_element?(lv, "#prepare-machine-removed .q-s")
      assert has_element?(lv, "#prepare-machine-removed .q-tc2 .q-d")
      assert has_element?(lv, "#prepare-machine-removed dd", "Run ended")
      assert has_element?(lv, "#prepare-machine-removed dt", "Alive")

      assert :sys.get_state(lv.pid).socket.assigns.clean_up_timer == nil
    end

    test "while the run goes on: no row, until a report comes", ctx do
      claimed = claimed_run(ctx.scope)
      run = project!(claimed.run, steps(false))

      lv = open(ctx.conn, ctx.scope, run)
      assert has_element?(lv, "#prepare-machine")
      refute has_element?(lv, "#prepare-machine-removed")

      report!(claimed, :deleting)
      assert row(lv) =~ "Machine removal requested"
    end

    test "a report about another run's machine changes nothing on the page", ctx do
      claimed = claimed_run(ctx.scope)
      run = project!(claimed.run, steps(false))
      other = handed_over_fixture(ctx.scope, claimed.key)

      lv = open(ctx.conn, ctx.scope, run)
      :ok = Dispatches.report_machine_end(claimed.key, other.dispatch.public_id, %{state: :gone})
      refute has_element?(lv, "#prepare-machine-removed")
    end
  end

  test "a dispatch released before a machine existed has no row", ctx do
    pool = pool_fixture(ctx.scope, name: "build-pool")
    %{access_key: key} = enrolled_key_fixture(ctx.scope, pool)
    _gateway = gateway_for!(ctx.scope, pool)

    {:ok, _queued} =
      Repo.transact(fn ->
        Dispatches.queue(Apiary.WorkItemsFixtures.work_item_fixture(ctx.scope), 1)
      end)

    {:ok, %{dispatch: dispatch, registered: registered}} =
      Apiary.DispatchedRunsFixtures.walked_claim(key, Dispatches.now())

    :ok = Dispatches.release(key, dispatch.public_id, %{reason: "No capacity in the region."})

    lv = open(ctx.conn, ctx.scope, Repo.get!(Run, registered.id))
    assert has_element?(lv, "#prepare-machine")
    refute has_element?(lv, "#prepare-machine-removed")
  end

  describe "a run on a permanent machine" do
    # The last row's name and words.
    defp stays_row(lv) do
      lv
      |> element("#prepare-machine-removed")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "on an open page whose list had settled, the run's exit brings the row", ctx do
      run =
        ctx.scope
        |> node_fixture()
        |> node_run_fixture(unique_instance_id(), %{state: "running"})
        |> project!(steps(false) ++ [{4, "session.started", session_started_data()}])

      lv = open(ctx.conn, ctx.scope, run)
      assert :sys.get_state(lv.pid).socket.assigns.preparation_settled
      refute has_element?(lv, "#prepare-machine-removed")

      project!(run, [
        {5, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 2_000}}
      ])

      send(lv.pid, :flush)
      assert stays_row(lv) == "Machine stays registered"
    end

    test "once it ended, the last row is Machine stays registered; before, no row", ctx do
      node = node_fixture(ctx.scope)

      running =
        node
        |> node_run_fixture(unique_instance_id(), %{state: "running"})
        |> project!(steps(false))

      lv = open(ctx.conn, ctx.scope, running)
      assert has_element?(lv, "#prepare-machine")
      refute has_element?(lv, "#prepare-machine-removed")

      ended =
        node
        |> node_run_fixture(unique_instance_id(), %{state: "running"})
        |> project!(steps(true))

      lv = open(ctx.conn, ctx.scope, ended)
      assert has_element?(lv, "#prepare-machine-prepare")
      assert stays_row(lv) == "Machine stays registered"
      refute has_element?(lv, "#prepare-machine-removed time")
      refute has_element?(lv, "#prepare-machine-removed .q-prep-name", "Machine removed")
    end

    test "with no setup step, once it ended, the list shows the row alone", ctx do
      node = node_fixture(ctx.scope)

      running =
        node
        |> node_run_fixture(unique_instance_id(), %{state: "running"})
        |> project!([{1, "run.started", started_data()}])

      lv = open(ctx.conn, ctx.scope, running)
      refute has_element?(lv, "#prepare-machine")

      ended =
        node
        |> node_run_fixture(unique_instance_id(), %{state: "running"})
        |> project!([
          {1, "run.started", started_data()},
          {2, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 2_000}}
        ])

      lv = open(ctx.conn, ctx.scope, ended)
      assert has_element?(lv, "#prepare-machine")
      refute has_element?(lv, "#prepare-machine [id^='prepare-machine-step-']")
      assert stays_row(lv) == "Machine stays registered"
    end

    test "with a session, the Timeline is inside Session started, above the row", ctx do
      ended =
        ctx.scope
        |> node_fixture()
        |> node_run_fixture(unique_instance_id(), %{state: "running"})
        |> project!([
          {1, "run.started", started_data()},
          {2, "session.started", session_started_data()},
          {3, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 2_000}}
        ])

      lv = open(ctx.conn, ctx.scope, ended)
      assert has_element?(lv, "#prepare-machine-session #timeline")
      assert stays_row(lv) == "Machine stays registered"
    end
  end
end
