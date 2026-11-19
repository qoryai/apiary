defmodule ApiaryWeb.WorkItemLive.CancelTest do
  # Cancel run on the line of a work item's page of a running run, or of a lost run that
  # may still attach again
  # (`ApiaryWeb.WorkItemLive.Show`), "Cancelling" there until the exit, and the versions
  # of a cancelled run, marked on the run's page and wherever a version's maker shows
  # (`ApiaryWeb.ArtifactComponents.writer/2`).
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures

  alias Apiary.{Artifacts, Repo, Runs}
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :observability]

  setup :register_and_log_in_user

  # The versions go to the suite's store (`Apiary.TestSetup`): an async test leaves the
  # application's store setting alone, which the other async tests read.
  setup %{scope: scope} do
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{dispatch_run: dispatch_run, run: run} = handed_over_fixture(scope, key)

    %{
      pool: pool,
      run: Repo.get!(Run, run.id),
      dispatch_run: dispatch_run,
      work_item: Repo.get!(WorkItem, dispatch_run.work_item_id)
    }
  end

  defp lost!(run, changes) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [state: "lost", lost_at: DateTime.utc_now(), silenced_at: nil] ++ changes
      )

    :ok
  end

  defp explore(scope, work_item),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{work_item.number}/explore"

  test "the running run's line has Cancel run, its confirm, then Cancelling", ctx do
    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))

    line = "#work-item-explore-run"
    assert has_element?(lv, "#{line}-cancel", "Cancel run")

    lv |> element("#{line}-cancel") |> render_click()
    assert has_element?(lv, "#{line}-cancel-confirm-question", "Cancel run #{ctx.run.number}?")
    assert has_element?(lv, "#{line}-cancel-confirm-cancel", "Don't cancel")

    lv |> element("#{line}-cancel-confirm-cancel") |> render_click()
    refute has_element?(lv, "#{line}-cancel-confirm")

    lv |> element("#{line}-cancel") |> render_click()
    lv |> element("#{line}-cancel-confirm-yes") |> render_click()

    assert Run.cancel_requested?(Repo.get!(Run, ctx.run.id))
    assert has_element?(lv, line, "Cancelling")
    refute has_element?(lv, "#{line}-cancel")
  end

  test "the take in's runs, the machine's runs and the run's Timeline read Cancelling",
       ctx do
    {:ok, _cancelled} = Runs.cancel(ctx.scope, ctx.run)

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))
    assert has_element?(lv, "#work-item-record-#{ctx.run.number}", "Cancelling")
    refute has_element?(lv, "#work-item-record-#{ctx.run.number}", "running")

    path = ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/machines/#{ctx.pool}"
    {:ok, lv, _html} = live(ctx.conn, path)
    render_async(lv)
    assert has_element?(lv, "#run-#{ctx.run.public_id} .q-rl-st", "Cancelling")

    path = ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{ctx.run.number}"
    {:ok, lv, _html} = live(ctx.conn, path)
    render_async(lv)
    assert has_element?(lv, "#prepare-machine-h", "Cancelling")
    refute has_element?(lv, "#prepare-machine-h", "Running")
  end

  test "a lost run that may still attach reads Cancelling on its line, by the run's rule",
       ctx do
    {:ok, _cancelled} = Runs.cancel(ctx.scope, ctx.run)
    later = DateTime.add(DateTime.utc_now(), 3600, :second)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [state: "lost", backstop_at: later, silenced_at: nil]
      )

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))
    assert has_element?(lv, "#work-item-record-#{ctx.run.number}", "Cancelling")
    assert has_element?(lv, "#work-item-explore-run", "Cancelling")

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [silenced_at: DateTime.utc_now()]
      )

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))
    refute has_element?(lv, "#work-item-record-#{ctx.run.number}", "Cancelling")
  end

  test "a lost run that may still attach has Cancel run on its line until lost for good",
       ctx do
    now = DateTime.utc_now()
    lost!(ctx.run, backstop_at: DateTime.add(now, 3600, :second))

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))

    line = "#work-item-explore-run"
    assert has_element?(lv, "#{line}-cancel", "Cancel run")

    lv |> element("#{line}-cancel") |> render_click()
    lv |> element("#{line}-cancel-confirm-yes") |> render_click()

    assert %Run{state: "lost"} = cancelled = Repo.get!(Run, ctx.run.id)
    assert Run.cancel_requested?(cancelled)
    assert has_element?(lv, line, "Cancelling")
    refute has_element?(lv, "#{line}-cancel")

    assert [_entry] =
             Repo.all(
               from e in Apiary.Audit.Entry,
                 where: e.subject_id == ^ctx.run.id and e.action == "run.cancel"
             )

    # Past its backstop, the run is lost for good: no Cancel run, and no cancel.
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [cancel_requested_at: nil, cancel_requested_by_id: nil]
      )

    lost!(ctx.run, backstop_at: DateTime.add(now, -1, :second))

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))
    refute has_element?(lv, "#{line}-cancel")
    assert {:error, :not_running} = Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))
  end

  test "a write run of a software workspace says its changes are not pushed", ctx do
    alias Apiary.Harnesses.RunHarness

    case Repo.get_by(RunHarness, dispatch_run_id: ctx.dispatch_run.id) do
      nil ->
        Repo.insert!(%RunHarness{
          dispatch_run_id: ctx.dispatch_run.id,
          state: :resolved,
          access_level: :write
        })

      harness ->
        harness |> Ecto.Changeset.change(access_level: :write) |> Repo.update!()
    end

    # The documents the claim sent a write run have `access` `write`.
    documents = ctx.run.run_documents |> Jason.decode!() |> Map.put("access", "write")

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [run_documents: Jason.encode!(documents)]
      )

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))
    lv |> element("#work-item-explore-run-cancel") |> render_click()

    assert has_element?(
             lv,
             "#work-item-explore-run-cancel-confirm-sub",
             "Its changes are not pushed, unless the run had already started pushing them."
           )
  end

  test "a cancelled run's versions are marked", ctx do
    file = %{filename: "a.md", content_type: "text/markdown", binary: "# A\n"}

    {:ok, _version} =
      Artifacts.push({:run, ctx.dispatch_run}, ctx.work_item, "walkthrough", [file], name: "main")

    {1, _rows} =
      Repo.update_all(
        from(d in Apiary.Dispatches.DispatchRun, where: d.id == ^ctx.dispatch_run.id),
        set: [round: 2]
      )

    [%{versions: [version]}] = Artifacts.list(ctx.work_item)
    refute ApiaryWeb.ArtifactComponents.writer(version, false) =~ "cancelled"

    {:ok, _cancelled} = Runs.cancel(ctx.scope, ctx.run)

    [%{versions: [version]}] = Artifacts.list(ctx.work_item)
    marked = "Run #{ctx.run.number} · round 2 · cancelled, not counted"

    # With its round, also where the page leaves rounds out, as on the Explore tab.
    assert ApiaryWeb.ArtifactComponents.writer(version, false) == marked
    assert ApiaryWeb.ArtifactComponents.writer(version) == marked

    {:ok, lv, _html} = live(ctx.conn, explore(ctx.scope, ctx.work_item))
    assert render(lv) =~ marked

    {:ok, lv, _html} =
      live(ctx.conn, ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/runs/#{ctx.run.number}")

    # The run's page, in Save the outputs and on its Pushed row.
    assert render(lv) =~ "Version 1 · #{marked}"
    assert render(lv) =~ "walkthrough/main version 1 · #{marked}"
  end
end
