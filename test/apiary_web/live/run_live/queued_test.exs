defmodule ApiaryWeb.RunLive.QueuedTest do
  # A queued run (`Apiary.Runs.Run.queued?/1`) on the Runs list and on its run page: the
  # list puts it first, newest first, with the badge Queued, its work item, its workflow
  # and who started it, its queue time and no duration; the State filter has Queued; the
  # sidebar counts it alive; the list follows a queue, a claim and an end. The page has
  # Queue the run running, the steps to come, why it waits, the Workflow row, n/a for the
  # run id on the machine, no duration in its header, and becomes the page of a run a
  # pool registered at the claim, with no reload.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [walked_claim: 2, workspace_gateway!: 1]
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    workspace_gateway!(scope)
    pool = pool_fixture(scope, name: "build-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{pool: pool, key: key}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp queue!(scope) do
    work_item = work_item_fixture(scope, %{title: "Add currency to orders"})
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    # With the workflow model a run waits for its harness walk, which no adapter reads here.
    :ok = Apiary.DispatchedRunsFixtures.walks_resolved!()
    {work_item, queued}
  end

  defp record(%DispatchRun{id: id}), do: Repo.one!(from r in Run, where: r.dispatch_run_id == ^id)

  # The walk of `queued` resolved from a file with the workflow explore-a-ticket.
  defp walked!(%DispatchRun{id: id}) do
    Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^id),
      set: [state: :resolved, origin: :file, workflow: "explore-a-ticket"]
    )
  end

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> squish()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#runs-rows > tr[id]")
    |> LazyHTML.attribute("id")
  end

  describe "the Runs list" do
    test "puts a queued run first, newest first, with Queued, its facts, its queue time and no duration",
         %{conn: conn, scope: scope} do
      {_work_item, queued} = queue!(scope)
      walked!(queued)
      run = record(queued)
      # Started after the run was queued.
      started = run_fixture(scope, %{state: "running", started_at: DateTime.utc_now()})

      view = open(conn, workspace_path(scope, "/runs"))

      assert row_ids(view) == ["run-#{run.public_id}", "run-#{started.public_id}"]
      row = "#run-#{run.public_id}"
      assert has_element?(view, "#{row} .q-st-queued", "Queued")
      assert text(view, "#{row} .q-rl-wf") == "explore-a-ticket"
      assert text(view, "#{row} .q-rl-wi") =~ "Add currency to orders"
      assert text(view, "#{row} .q-rl-sb") != "n/a"

      assert has_element?(
               view,
               ~s(#{row} .q-rl-when time[datetime="#{DateTime.to_iso8601(run.inserted_at)}"])
             )

      assert text(view, "#{row} .q-rl-dur") =~ "n/a"
    end

    test "the State filter has Queued, and state:queued lists queued runs alone",
         %{conn: conn, scope: scope} do
      {_work_item, queued} = queue!(scope)
      run = record(queued)
      pending = run_fixture(scope, %{state: "pending"})

      view = open(conn, workspace_path(scope, "/runs?state=queued"))
      assert row_ids(view) == ["run-#{run.public_id}"]

      view = open(conn, workspace_path(scope, "/runs?state=pending"))
      assert row_ids(view) == ["run-#{pending.public_id}"]

      view = open(conn, workspace_path(scope, "/runs"))
      assert render(view) =~ ~s(value="queued")
    end

    test "the sidebar counts a queued run alive", %{conn: conn, scope: scope} do
      queue!(scope)
      view = open(conn, workspace_path(scope, "/runs"))
      assert text(view, "#nav-runs-alive") == "1"
    end

    test "follows a queue, a claim and an end while it waits",
         %{conn: conn, scope: scope} = ctx do
      {_first_item, first} = queue!(scope)
      first_run = record(first)
      {second_item, second} = queue!(scope)
      second_run = record(second)

      view = open(conn, workspace_path(scope, "/runs"))
      assert row_ids(view) == ["run-#{second_run.public_id}", "run-#{first_run.public_id}"]

      # A run queued after the page was read is a new run, as any run is.
      queue!(scope)
      assert eventually(fn -> has_element?(view, "#runs-new", "1 new run") end)

      assert {:ok, %{run: %{id: id}}} = walked_claim(ctx.key, Dispatches.now())
      assert id == first.id

      assert eventually(fn ->
               not has_element?(view, "#run-#{first_run.public_id} .q-st-queued") and
                 has_element?(view, "#run-#{second_run.public_id} .q-st-queued")
             end)

      assert {:ok, _undone} = Apiary.WorkItems.undo(scope, Repo.get!(WorkItem, second_item.id))

      assert eventually(fn ->
               has_element?(view, "#run-#{second_run.public_id} .q-st-cancelled")
             end)
    end
  end

  describe "the run page" do
    test "has Queue the run running, the steps to come, why it waits and the Details of a queued run",
         %{conn: conn, scope: scope} do
      {_work_item, queued} = queue!(scope)
      walked!(queued)
      run = record(queued)

      view = open(conn, workspace_path(scope, "/runs/#{run.number}"))

      assert text(view, "#prepare-machine-h") =~ "Run · Queued"
      assert has_element?(view, "#prepare-machine-queue[data-state=running]")

      for key <- ~w(request start prepare session remove),
          do: assert(has_element?(view, "#prepare-machine-#{key}[data-state=not_run]"))

      assert text(view, "#prepare-machine-why") == "Waiting for build-pool to run it."
      assert has_element?(view, "#run-state", "Queued")
      refute has_element?(view, "#run-duration-line")
      assert text(view, "#rail-workflow") == "explore-a-ticket"
      assert text(view, "#run-node-run-id") == "n/a"
      assert render(view) =~ "Waiting for the run to start"
      assert render(view) =~ "Listening for the run"
      refute render(view) =~ "Forager has pinged"
    end

    test "a run that ended while it waited has no run id on a machine", %{
      conn: conn,
      scope: scope
    } do
      {work_item, queued} = queue!(scope)
      assert {:ok, _undone} = Apiary.WorkItems.undo(scope, Repo.get!(WorkItem, work_item.id))
      run = record(queued)
      assert run.state == "cancelled"

      view = open(conn, workspace_path(scope, "/runs/#{run.number}"))
      assert text(view, "#run-node-run-id") == "n/a"
    end

    test "shows that a second run waits behind the first, and updates when the first is claimed",
         %{conn: conn, scope: scope} = ctx do
      queue!(scope)
      {_work_item, second} = queue!(scope)
      run = record(second)

      view = open(conn, workspace_path(scope, "/runs/#{run.number}"))

      assert text(view, "#prepare-machine-why") ==
               "Waiting for a machine: 1 run was queued before this one."

      assert {:ok, %{run: %DispatchRun{}}} = walked_claim(ctx.key, Dispatches.now())

      assert eventually(fn ->
               text(view, "#prepare-machine-why") == "Waiting for build-pool to run it."
             end)
    end

    test "becomes the page of a registered run at the claim, with no reload",
         %{conn: conn, scope: scope} = ctx do
      {_work_item, queued} = queue!(scope)
      run = record(queued)
      view = open(conn, workspace_path(scope, "/runs/#{run.number}"))
      assert has_element?(view, "#run-state", "Queued")

      assert {:ok, %{registered: registered}} = walked_claim(ctx.key, Dispatches.now())
      assert registered.id == run.id

      assert eventually(fn ->
               not has_element?(view, "#run-state", "Queued") and
                 not has_element?(view, "#prepare-machine-why") and
                 text(view, "#run-node-run-id") == queued.run_id
             end)
    end
  end

  # Renders until `check` holds, for the broadcasts that reach the view after the test's
  # write: at most 50 tries, 20 ms apart.
  defp eventually(check, tries \\ 50)
  defp eventually(check, 0), do: check.()

  defp eventually(check, tries) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, tries - 1)
    end
  end
end
