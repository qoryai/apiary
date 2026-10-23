defmodule ApiaryWeb.RunLive.RunCodePagesTest do
  # The pages that show a run handed over with a run code (`Apiary.Runs.RunCode`) before
  # its code is redeemed: the run has no run key yet. The run page with each tab, the runs list
  # and the workspace overview show it as they show any run through a gateway not yet
  # attached; once its code expires unredeemed, the overview shows it lost with the tip of
  # a run never picked up.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Runs.{Liveness, Run}

  @moduletag needs: :factory

  @never "It never started: its gateway did not pick it up in the time it was given, and now it can't."

  setup :register_and_log_in_user

  setup %{scope: scope} do
    place = handover_place_fixture(scope)
    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, %{dispatch: dispatch, registered: registered}} =
      Dispatches.claim(place.key, Dispatches.now())

    :ok = Dispatches.dispatched(place.key, dispatch.public_id, %{external: nil})

    run = Repo.get!(Run, registered.id)
    nil = run.run_key_payload
    %{run: run}
  end

  test "the run page shows the run in each tab", %{conn: conn, scope: scope, run: run} do
    for tab <- ["", "/terminal", "/network", "/details"] do
      {:ok, view, html} = live(conn, workspace_path(scope, "/runs/#{run.public_id}#{tab}"))
      assert html =~ run.public_id, tab
      assert render(view) =~ run.public_id, tab
    end
  end

  test "the runs list shows the run", %{conn: conn, scope: scope, run: run} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/runs"))
    render_async(view)
    assert has_element?(view, "#run-#{run.public_id}")
  end

  test "the overview shows the run lost, never picked up, once its code expires",
       %{conn: conn, scope: scope, run: run} do
    {:ok, view, _html} = live(conn, workspace_path(scope))
    render_async(view, 5_000)

    assert [%Run{state: "lost"}] =
             Liveness.check(DateTime.add(run.run_code_expires_at, 1, :second))

    {:ok, view, _html} = live(conn, workspace_path(scope))
    render_async(view, 5_000)

    assert view
           |> element("#att-run-#{run.public_id}")
           |> render() =~ "Lost, never posted its exit"

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#att-run-#{run.public_id} .q-ar-why")
           |> LazyHTML.attribute("title") == [@never]
  end
end
