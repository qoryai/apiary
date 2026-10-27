defmodule ApiaryWeb.WorkspaceLive.OverviewSetupTest do
  # The Overview's setup list, with the `factory` feature, in place of the empty
  # workspace's box: its four steps, each done by its rule (`Apiary.WorkspaceSetup`), who
  # may act on each, and the test run's field, its states and each failure's line.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Dispatches, Edition, EditionStubs, Repo, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @line "Hi! Where are you running?"

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

  defmodule ReadyNoTakeIn do
    @moduledoc false
    # The machines and the model key done, as `Apiary.EditionStubs.SetupReady` has them,
    # and nobody takes an item in, as `Apiary.EditionStubs.NoTakeIn` has it.
    defdelegate machines_ready(workspace), to: EditionStubs.SetupReady
    defdelegate model_key_ready?(workspace), to: EditionStubs.SetupReady
    defdelegate check(scope, action, subject), to: EditionStubs.NoTakeIn
  end

  defp open(conn, scope) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    render_async(view, 5_000)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s+([,.;:])/, "\\1")
    |> String.trim()
  end

  defp as_member(%{scope: scope}) do
    %{user: member} = member_fixture(scope, :member)
    log_in_user(build_conn(), member)
  end

  defp ready!, do: :ok = Edition.put_test_stub(EditionStubs.SetupReady)

  defp test_item!(scope) do
    {:ok, item} = WorkItems.take_in_test(scope, @line)
    item
  end

  # The one run of `item`, a test work item, with `changes`, and its registered run, with
  # `run_attrs`; none for nil.
  defp test_run!(item, changes, run_attrs \\ nil) do
    [queued] = Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)
    {1, _} = Repo.update_all(from(d in DispatchRun, where: d.id == ^queued.id), set: changes)

    if run_attrs do
      %Run{
        organisation_id: item.organisation_id,
        workspace_id: item.workspace_id,
        node_run_id: queued.run_id,
        dispatch_run_id: queued.id
      }
      |> Ecto.Changeset.change(Map.merge(%{started_at: DateTime.utc_now()}, run_attrs))
      |> Repo.insert!()
    end
  end

  describe "the feature" do
    test "the setup list takes the box's place, with its four steps",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert has_element?(view, "#setup h2", "Set up #{scope.workspace.name}")
      refute has_element?(view, "#onboarding")

      for {id, name} <- [
            source: "Work source",
            machines: "Machines for runs",
            "model-key": "Model key",
            test: "Test run"
          ] do
        assert has_element?(view, "#setup-#{id}[data-state=todo]", name)
      end
    end

    test "without it, the box is the page, as before", %{conn: conn, scope: scope} do
      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      view = open(conn, scope)

      assert has_element?(view, "#onboarding h2", "Send your first run")
      refute has_element?(view, "#setup")
      render_click(view, "run_test", %{"line" => @line})
      refute Repo.exists?(WorkItem)
    end
  end

  describe "each step" do
    test "not done: what to do, Check the nodes folded, and Run the test disabled",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert text(view, "#setup-source-line") ==
               "Bring tickets in from a system this instance has set up."

      assert has_element?(
               view,
               "#setup-source-act.btn-primary[href='/#{scope.organisation.slug}/set-up?step=source']",
               "Connect"
             )

      assert has_element?(view, "#setup-machines-fold-false:not([open])")

      assert text(view, "#setup-machines-line") ==
               "#{scope.workspace.name}'s runs need a node pool and a gateway, each with a key."

      assert text(view, "#setup-model-key-line") ==
               "Add a model key, so agents can run."

      assert has_element?(
               view,
               "#setup-model-key-act[href='/#{scope.organisation.slug}/settings/model-providers']",
               "Add model key"
             )

      assert text(view, "#setup-test-line") ==
               "Runs once machines and model key are done."

      assert has_element?(view, "#setup-test-act[disabled]", "Run the test")
      refute has_element?(view, "#setup-test-form")

      # The event, sent anyway, takes nothing in.
      render_click(view, "run_test", %{"line" => @line})
      refute Repo.exists?(WorkItem)
    end

    test "the context of each step under its line, and the steps on Nodes in a fold",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert text(view, "#setup-source-context") ==
               "The step is done when #{scope.workspace.name} has a repository from a work " <>
                 "source and Qory Apiary has read its list of repositories."

      assert text(view, "#setup-machines-context") ==
               "Runs need a node pool, whose machines run the agents, and a gateway, which " <>
                 "passes their model calls on. Qory Apiary keeps the model key and seals it " <>
                 "to the gateway for each run."

      assert text(view, "#setup-model-key-context") ==
               "Agents need a model key to run. The step is done when " <>
                 "#{scope.organisation.name} has a model provider with a key and " <>
                 "#{scope.workspace.name} has a model choice."

      assert text(view, "#setup-test-context") ==
               "The test run checks the other steps together: an agent answers your line on " <>
                 "a machine of the pool, through the gateway, with the model key. The run's " <>
                 "log has its answer."

      assert text(view, "#setup-machines-fold-false summary") == "Check the nodes"

      assert text(view, "#setup-machines-fold-false div") ==
               "On Instance settings › Nodes " <>
                 "Find the pool and the gateway in the table. Each one is ready when State " <>
                 "shows Running or Last seen. " <>
                 "If one shows Never seen, open the logs of the pool and the gateway on the " <>
                 "instance's host, as your host's install guide says. " <>
                 "If you are not an instance admin, ask one to check the Nodes page."

      # Only Machines for runs has a fold; How to is gone.
      for id <- ["source", "model-key", "test"],
          do: refute(has_element?(view, "#setup-#{id} details"))

      refute render(view) =~ "How to"
    end

    test "the machines step, current, shows Check the nodes open", %{conn: conn, scope: scope} do
      _collection = collection_fixture(scope)
      view = open(conn, scope)

      assert has_element?(view, "#setup-machines-fold-true[open]")
    end

    test "done: a work source and the machines, each with its line and its link",
         %{conn: conn, scope: scope} do
      collection = collection_fixture(scope)
      adapter = Repo.get!(Apiary.Nodes.Node, collection.adapter_id)
      %{pool: pool, gateway: gateway} = handover_place_fixture(scope)
      view = open(conn, scope)

      assert has_element?(view, "#setup-source[data-state=done]")

      assert text(view, "#setup-source-line") ==
               "#{adapter.name} is connected, with 1 collection."

      assert has_element?(
               view,
               "#setup-source-act[href='/#{scope.organisation.slug}/set-up']",
               "Change"
             )

      assert has_element?(view, "#setup-machines[data-state=done]")

      assert text(view, "#setup-machines-line") ==
               "#{pool.name} and #{gateway.name} are ready."

      assert has_element?(
               view,
               "#setup-machines-act[href='#{workspace_path(scope, "/nodes")}']",
               "View"
             )

      # The first step not done is current: its button is primary, and the fold of the
      # machines, done, is closed.
      assert has_element?(view, "#setup-model-key-act.btn-primary")
      assert has_element?(view, "#setup-machines-fold-false:not([open])")
    end

    test "an edition's answer counts: the machines and the model key from elsewhere",
         %{conn: conn, scope: scope} do
      ready!()
      view = open(conn, scope)

      assert text(view, "#setup-machines-line") ==
               "shared-pool and shared-gateway are ready."

      assert has_element?(view, "#setup-model-key[data-state=done]")
      refute has_element?(view, "#setup-model-key-act")
    end
  end

  describe "who may act" do
    test "a member reads who connects a work source, adds a model key and checks the machines",
         ctx do
      view = open(as_member(ctx), ctx.scope)

      assert text(view, "#setup-source-who") == "Only owners and admins connect a work source."
      refute has_element?(view, "#setup-source-act")
      assert text(view, "#setup-model-key-who") == "Only owners and admins add a model key."
      refute has_element?(view, "#setup-model-key-act")

      assert text(view, "#setup-machines-who") ==
               "Only an instance admin checks the instance's pool and gateway."

      # A member runs the test.
      refute has_element?(view, "#setup-test-who")
    end

    test "an owner who is no instance admin reads who checks the instance's machines",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert text(view, "#setup-machines-who") ==
               "Only an instance admin checks the instance's pool and gateway."

      refute has_element?(view, "#setup-machines-act")
    end

    test "one who may not take an item in reads who runs the test, and has no field",
         %{conn: conn, scope: scope} do
      :ok = Edition.put_test_stub(ReadyNoTakeIn)
      view = open(conn, scope)

      assert text(view, "#setup-test-who") == "Only owners, admins and members run the test."
      refute has_element?(view, "#setup-test-form")
      refute has_element?(view, "#setup-test-act")

      render_click(view, "run_test", %{"line" => @line})
      refute Repo.exists?(WorkItem)
    end
  end

  describe "the test run" do
    setup do
      ready!()
    end

    test "the field, filled, and Run the test, which takes a test work item in",
         %{conn: conn, scope: scope} do
      # Every other step done: the test run is the current step.
      _collection = collection_fixture(scope)
      view = open(conn, scope)

      assert has_element?(view, "#setup-test-form label", "Say hi to your agent")
      assert has_element?(view, "#setup-test-form input[name='test[line]'][value='#{@line}']")
      assert has_element?(view, "#setup-test-act.btn-primary", "Run the test")

      view |> form("#setup-test-form", test: %{line: "Hello there"}) |> render_submit()

      assert [%WorkItem{test: true, title: "Hello there", state: :exploring}] =
               Repo.all(WorkItem)

      assert text(view, "#setup-test-line") ==
               "The test run is queued for a machine."

      refute has_element?(view, "#setup-test-form")
      refute has_element?(view, "#setup-test-act")
    end

    test "while a test run is in progress, the step says to wait, in a plain line",
         %{conn: conn, scope: scope} do
      item = test_item!(scope)
      test_run!(item, [state: :handed_over], %{state: "running"})
      view = open(conn, scope)

      # Run the test again with the line of a test a machine is running.
      render_click(view, "run_test", %{"line" => @line})

      assert text(view, "#setup-test-running") ==
               "Wait until the test run in progress ends, then press Run the test again."

      assert Repo.aggregate(WorkItem, :count) == 1
    end

    test "a line the work item refuses is the field's error", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      html = view |> form("#setup-test-form", test: %{line: "   "}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Repo.exists?(WorkItem)
    end

    test "running, with See the run", %{conn: conn, scope: scope} do
      item = test_item!(scope)
      run = test_run!(item, [state: :handed_over], %{state: "running"})
      view = open(conn, scope)

      assert text(view, "#setup-test-line") == "The test run is running."

      assert has_element?(
               view,
               "#setup-test-run[href='#{workspace_path(scope, "/runs/#{run.public_id}")}']",
               "See the run"
             )
    end

    test "passed, live: the line with See the run; the list stays until the next visit",
         %{conn: conn, scope: scope} do
      item = test_item!(scope)
      view = open(conn, scope)

      pool = pool_fixture(scope, name: "build-pool")

      run =
        test_run!(item, [state: :ended, end_cause: :run_ended], %{
          state: "completed",
          node_id: pool.id
        })

      :ok = Dispatches.broadcast([scope.workspace.id])

      assert has_element?(view, "#setup-test[data-state=done]")

      assert text(view, "#setup-test-passed") ==
               "Test run passed: the agent answered on a machine of build-pool. See the run"

      assert has_element?(
               view,
               "#setup-test-passed a[href='#{workspace_path(scope, "/runs/#{run.public_id}")}']"
             )

      view = open(conn, scope)
      refute has_element?(view, "#setup")
      refute has_element?(view, "#onboarding")
      assert has_element?(view, "#overview-activity")
    end

    test "passed on the instance's pool says so, as the mockup has it",
         %{conn: conn, scope: scope} do
      item = test_item!(scope)
      view = open(conn, scope)
      pool = instance_pool_fixture()

      test_run!(item, [state: :ended, end_cause: :run_ended], %{
        state: "completed",
        node_id: pool.id
      })

      :ok = Dispatches.broadcast([scope.workspace.id])

      assert text(view, "#setup-test-passed") ==
               "Test run passed: the agent answered on a machine of the instance's pool. See the run"
    end

    test "passed with no node names no pool", %{conn: conn, scope: scope} do
      item = test_item!(scope)
      view = open(conn, scope)

      run =
        test_run!(item, [state: :ended, end_cause: :run_ended], %{
          state: "completed",
          node_id: nil
        })

      :ok = Dispatches.broadcast([scope.workspace.id])

      assert text(view, "#setup-test-passed") ==
               "Test run passed: the agent answered on a machine. See the run"

      refute text(view, "#setup-test-passed") =~ "instance's pool"

      assert has_element?(
               view,
               "#setup-test-passed a[href='#{workspace_path(scope, "/runs/#{run.public_id}")}']"
             )
    end

    test "each failure, the fix first, with Run the test again", %{conn: conn, scope: scope} do
      item = test_item!(scope)

      for {changes, run_attrs, cause, line} <- [
            {[queued_at: DateTime.add(DateTime.utc_now(), -301, :second)], nil, "no_machine",
             "Check the pool in Instance settings › Nodes. No machine has taken the test run yet."},
            {[state: :ended, end_cause: :run_refused, end_detail: "model_key_missing"],
             %{state: "failed", reason: "model_key_missing"}, "model_key_missing",
             "Add a model key in Organisation settings › Model providers. The gateway had no model key for the run."},
            {[state: :ended, end_cause: :lost, end_detail: nil],
             %{state: "lost", silenced_at: DateTime.utc_now()}, "silent",
             "Check that the gateway is running in Instance settings › Nodes. The machine stopped sending for 10 minutes."},
            {[state: :ended, end_cause: :run_ended], %{state: "failed"}, "other",
             "Read the run's log, then press Run the test again. The test run ended without passing. See the run"},
            {[state: :ended, end_cause: :harness_unresolved, result_outcome: :error], nil,
             "other",
             "Check the other steps of this list, then press Run the test again. The test run ended before a machine started it."}
          ] do
        Repo.delete_all(from r in Run, where: r.workspace_id == ^scope.workspace.id)
        test_run!(item, changes, run_attrs)
        view = open(conn, scope)

        assert has_element?(view, "#setup-test[data-state=failed]")
        assert has_element?(view, "#setup-test-failed[data-cause=#{cause}]")
        assert text(view, "#setup-test-failed") == line
        assert has_element?(view, "#setup-test-again", "Run the test")
      end
    end

    test "Run the test again takes a new test in, with the failed test's line",
         %{conn: conn, scope: scope} do
      item = test_item!(scope)
      test_run!(item, [state: :ended, end_cause: :run_ended], %{state: "failed"})
      view = open(conn, scope)

      view |> element("#setup-test-again") |> render_click()

      assert [%WorkItem{state: :closed}, %WorkItem{state: :exploring, title: @line}] =
               Repo.all(from w in WorkItem, order_by: w.number)

      assert text(view, "#setup-test-line") ==
               "The test run is queued for a machine."
    end

    test "a wait past 5 minutes turns into its failure without a reload, and Run the test again queues a new test",
         %{conn: conn, scope: scope} do
      item = test_item!(scope)
      view = open(conn, scope)

      assert text(view, "#setup-test-line") ==
               "The test run is queued for a machine."

      test_run!(item, queued_at: DateTime.add(DateTime.utc_now(), -301, :second))
      send(view.pid, :setup_tick)

      assert has_element?(view, "#setup-test-failed[data-cause=no_machine]")

      # Run the test again while no machine has taken the run: the run ends, the test work
      # item closes, and a new test run is queued.
      view |> element("#setup-test-again") |> render_click()
      refute has_element?(view, "#setup-test-running")

      assert [%WorkItem{state: :closed}, %WorkItem{state: :exploring, title: @line}] =
               Repo.all(from w in WorkItem, order_by: w.number)

      assert [%DispatchRun{state: :ended, end_cause: :closed}] =
               Repo.all(from d in DispatchRun, where: d.work_item_id == ^item.id)

      assert text(view, "#setup-test-line") ==
               "The test run is queued for a machine."
    end
  end
end
