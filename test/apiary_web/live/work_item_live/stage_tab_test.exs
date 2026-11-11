defmodule ApiaryWeb.WorkItemLive.StageTabTest do
  # One tab for each stage that runs a workflow and has a run or is the current stage, under
  # the stage's name, at the address of the stage's id: the output frames, the questions
  # past Confirm and what each tab lists. `/explore` patches to the tab of the first stage with a
  # `proposal` output.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module is
  # not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.{Explore, WorkItem}
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  setup %{scope: scope} do
    workspace = scope.workspace

    :ok =
      Processes.record_declared(
        workspace,
        Processes.qory_workflows(Apiary.Stacks.Sources.chosen(workspace)) ++
          ~w(shape-a-ticket build-it)
      )

    for workflow <- ~w(shape-a-ticket build-it) do
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        workflow: workflow,
        access: :read
      })
    end

    for name <- ~w(spec test-features) do
      {:ok, _type} =
        Artifacts.create_type(scope, workspace, %{
          "name" => name,
          "base_view" => "document",
          "size_limit" => 1_048_576,
          "max_files" => 1
        })
    end

    process!(scope)
    :ok
  end

  # The default process with Shape running a workflow and `changes` on Shape, and on Build
  # by `build`.
  defp process!(scope, changes \\ %{}, build \\ %{}) do
    document = Processes.default_document("software")

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @shape} = stage ->
          stage
          |> Map.merge(%{
            "sequence" => [%{"workflow" => "shape-a-ticket"}],
            "outputs" => [
              %{"type" => "spec", "required" => true},
              %{"type" => "decision-record", "required" => false},
              %{"type" => "mockup", "required" => false},
              %{"type" => "test-features", "required" => false}
            ],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          })
          |> Map.merge(changes)

        %{"id" => @build} = stage ->
          Map.merge(stage, build)

        stage ->
          stage
      end)

    {:ok, version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
    version
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp page(scope, number, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}" <> rest

  defp stage(scope, number, id \\ @shape), do: page(scope, number, "/stages/#{id}")

  # The live action and the stage of the page's address, once a patch at the join has landed.
  defp address(view) do
    %{live_action: action, tab: tab} = :sys.get_state(view.pid).socket.assigns
    {action, tab}
  end

  defp push!(run, work_item, type, text, name \\ "main") do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        reload(work_item),
        type,
        [%{filename: "#{type}.md", content_type: "text/markdown", binary: text}],
        name: name,
        stage_id: run.stage_id
      )

    version
  end

  defp passed!(run) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        "verdict",
        %{"verdict" => "passed"},
        stage_id: run.stage_id
      )
  end

  # A work item at Shape: Explore's proposal confirmed, and Shape's first run queued.
  defp at_shape!(scope) do
    work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
    {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
    reload(work_item)
  end

  # A work item at Shape's gate, with spec and test-features written.
  defp at_gate!(scope, spec \\ "## The spec text", features \\ "## The features text") do
    work_item = at_shape!(scope)

    work_item
    |> end_run!(fn run, _registered ->
      push!(run, work_item, "spec", spec)
      push!(run, work_item, "test-features", features)
      passed!(run)
    end)
    |> reload()
  end

  # A work item whose Shape run wrote spec and `questions`, so the stage waits for answers.
  defp waiting!(scope, questions \\ ["Which basket?", "Which sale?"]) do
    work_item = at_shape!(scope)

    work_item
    |> end_run!(fn run, registered ->
      push!(run, work_item, "spec", "## The spec text")
      push_result!(run, registered, questions_result(questions))
    end)
    |> reload()
  end

  defp running!(work_item) do
    run = newest_run(work_item)
    now = DateTime.utc_now()

    %Apiary.Runs.Run{
      number: Apiary.RunEventsFixtures.next_run_number(run.organisation_id, run.workspace_id),
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      node_run_id: run.run_id,
      dispatch_run_id: run.id
    }
    |> Ecto.Changeset.change(%{
      state: "running",
      started_at: DateTime.add(now, -240, :second),
      last_heartbeat_at: now
    })
    |> Apiary.RunEventsFixtures.insert_run!()

    run |> Ecto.Changeset.change(state: :handed_over) |> Repo.update!()
    work_item
  end

  defp attempt(work_item), do: newest_run(work_item).attempt

  defp stopped!(work_item) do
    run = newest_run(work_item)

    %Apiary.Runs.Run{
      number: Apiary.RunEventsFixtures.next_run_number(run.organisation_id, run.workspace_id),
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      node_run_id: run.run_id,
      dispatch_run_id: run.id
    }
    |> Ecto.Changeset.change(%{
      state: "failed",
      exit_state: "lost",
      exited_at: DateTime.utc_now()
    })
    |> Apiary.RunEventsFixtures.insert_run!()

    run |> Ecto.Changeset.change(state: :ended, end_cause: :lost) |> Repo.update!()
    {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
    reload(work_item)
  end

  describe "the tab a work item opens on" do
    test "a work item at Shape's gate opens on Shape's tab", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]", "Shape")
      assert has_element?(view, "#work-item-tab-output-spec-fold")
    end

    test "a stopped run at Shape opens on Shape's tab", %{conn: conn, scope: scope} do
      work_item = scope |> at_shape!() |> stopped!()
      assert work_item.stage_id == @shape

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
      refute has_element?(view, "#work-item-tabs-ticket[aria-current=page]")
    end

    test "a stage with no workflow opens on the Ticket tab", %{conn: conn, scope: scope} do
      process!(scope, %{"sequence" => [], "outputs" => []})
      work_item = at_shape!(scope)
      assert work_item.stage_id == @shape

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-ticket[aria-current=page]")
      refute has_element?(view, "#work-item-tabs-#{@shape}")
    end

    test "a work item that ended opens on the Ticket tab", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)
      {:ok, _closed} = WorkItems.close(scope, work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-ticket[aria-current=page]")
    end
  end

  describe "which stages have a tab" do
    test "a stage after the current one has none until it has a run", %{
      conn: conn,
      scope: scope
    } do
      process!(scope, %{}, %{"sequence" => [%{"workflow" => "build-it"}]})
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-tabs-#{@build}")

      {:ok, _approved} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)
      assert reload(work_item).stage_id == @build

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@build}[aria-current=page]", "Build")
      assert has_element?(view, "#work-item-tabs-#{@shape}", "Shape")
      refute has_element?(view, "#work-item-tabs-#{@shape}[aria-current=page]")
    end

    test "the tab has the stage's name, and the address stays after a rename", %{
      conn: conn,
      scope: scope
    } do
      version = process!(scope, %{"name" => "Plan it"})
      work_item = at_gate!(scope)
      assert reload(work_item).process_version_id == version.id

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-#{@shape}", "Plan it")
      refute has_element?(view, "#work-item-tabs-#{@shape}", "Shape")
    end

    test "an address with a stage that has no tab patches to the work item's", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_gate!(scope)
      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, stage(scope, work_item.number, @build))

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, stage(scope, work_item.number, "st_0000000000"))
    end

    test "a stage's tab is the same whatever words its name has", %{conn: conn, scope: scope} do
      process!(scope, %{"name" => "Plan / it? & more"})
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert view |> element("#work-item-tabs-#{@shape}") |> render() =~
               "/stages/#{@shape}"
    end
  end

  describe "/explore" do
    test "patches to the tab of the first stage with a proposal output, with its query", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
      to = {:stage, :explore}

      {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))

      assert html =~ "work-item-explore-proposal"
      assert address(view) == to
      assert has_element?(view, "#work-item-tabs-explore[aria-current=page]")

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Name the rule.")
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore?reply=c1"))

      assert address(view) == to
      assert has_element?(view, "#work-item-review-page-text")
    end

    test "with no stage with a proposal output, patches to the work item's", %{
      conn: conn,
      scope: scope
    } do
      document = Processes.default_document("software")

      {:ok, _version} =
        Processes.save(scope, scope.workspace, %{
          document
          | "stages" =>
              Enum.map(document["stages"], fn
                %{"id" => @explore} = stage -> %{stage | "outputs" => []}
                stage -> stage
              end)
        })

      work_item = taken_in_fixture(scope)
      to = page(scope, work_item.number)

      assert {:error, {:live_redirect, %{to: ^to}}} =
               live(conn, page(scope, work_item.number, "/explore"))
    end
  end

  describe "the output frames" do
    test "one frame per output with a version; the first open; a folded text read on opening",
         %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)

      {:ok, view, html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-spec-fold[open]")
      assert has_element?(view, "#work-item-tab-output-spec-h", "Spec")
      assert has_element?(view, "#work-item-tab-output-test-features-h", "Test features")
      refute has_element?(view, "#work-item-tab-output-test-features-fold[open]")
      refute has_element?(view, "#work-item-tab-output-mockup")
      assert html =~ "The spec text"
      refute html =~ "The features text"

      view |> element("#work-item-tab-output-test-features-s") |> render_click()

      assert render(view) =~ "The features text"
    end

    test "a folded output's version is not read until it opens", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert %{{"spec", 1} => %{}} = :sys.get_state(view.pid).socket.assigns.frame_texts

      refute Map.has_key?(
               :sys.get_state(view.pid).socket.assigns.frame_texts,
               {"test-features", 1}
             )
    end

    test "an output whose artifact is not named main has no frame", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")
          push!(run, work_item, "test-features", "## Another", "other")
          passed!(run)
        end)
        |> reload()

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-spec")
      refute has_element?(view, "#work-item-tab-output-test-features")
    end

    test "a version with no Markdown has its artifact row", %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")

          {:ok, _version} =
            Artifacts.push(
              {:run, run},
              reload(work_item),
              "mockup",
              [
                %{
                  filename: "m.png",
                  content_type: "image/png",
                  binary: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
                }
              ],
              name: "main",
              stage_id: run.stage_id
            )

          passed!(run)
        end)
        |> reload()

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      refute has_element?(view, "#work-item-tab-output-mockup-row")

      view |> element("#work-item-tab-output-mockup-s") |> render_click()
      assert has_element?(view, "#work-item-tab-output-mockup-row")
    end
  end

  describe "the review comments document" do
    test "has no frame" do
      stage = %{outputs: ["spec", "review-comments", "mockup"]}

      assert [%{type: "spec", version: 2, open: true}, %{type: "mockup", open: false}] =
               ApiaryWeb.WorkItemLive.StageTab.frames(stage, %{
                 "spec" => 2,
                 "review-comments" => 1,
                 "mockup" => 1
               })
    end
  end

  describe "a run's questions at Shape" do
    test "the form sends the latest run's attempt, whatever the tab lists", %{scope: scope} do
      work_item = waiting!(scope)

      assert {:error, :stale} =
               WorkItems.answer(scope, work_item, attempt(work_item) - 1, [
                 %{"id" => "q1", "option" => nil, "note" => "Late."}
               ])

      assert {:ok, _answered} =
               WorkItems.answer(scope, work_item, attempt(work_item), [
                 %{"id" => "q1", "option" => nil, "note" => "In time."}
               ])
    end

    test "with the stage waiting before the run's end arrives, the run still shows running", %{
      scope: scope
    } do
      work_item = at_shape!(scope)
      steps = [%{place: :running, attempt: 1, of: 3}]
      waiting = %{work_item | stage_state: :waiting_answers}

      assert Explore.status(steps, true, waiting) == :shape

      assert Explore.status([%{place: :no_result, attempt: 1, of: 3}], true, waiting) ==
               :questions

      # The other order: the run ended and the stage still runs.
      running = %{work_item | stage_state: :running}
      assert Explore.status([%{place: :no_result, attempt: 1, of: 3}], true, running) == :shape
    end

    test "a member's answer reads the stage's state in both orders", %{scope: scope} do
      work_item = at_shape!(scope)
      current = %{status: :shape, step: %{place: :no_result}}

      assert %{status: :questions} =
               Explore.member_view(current, %{work_item | stage_state: :waiting_answers})

      assert %{status: :running} =
               Explore.member_view(
                 %{status: :shape, step: %{place: :running}},
                 %{work_item | stage_state: :waiting_answers}
               )

      assert %{status: :gate} =
               Explore.member_view(current, %{work_item | stage_state: :at_gate})

      assert %{status: :confirm} =
               Explore.member_view(
                 %{status: :confirm, step: %{place: :proposal}},
                 %{work_item | stage_state: :waiting_answers}
               )
    end

    test "a question left open in an earlier take in holds no stage at its run's end", %{
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      work_item = work_item |> reload() |> end_run!(questions_result(["An old question?"]))
      {:ok, _closed} = WorkItems.close(scope, reload(work_item))

      {:ok, _again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
      work_item = reload(work_item)
      assert work_item.stage_id == @shape

      {_version, document} = Apiary.Explore.Questions.newest(work_item)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          {:ok, _version} =
            Stages.Artifacts.push_json({:run, run}, reload(work_item), "questions", document,
              stage_id: run.stage_id
            )

          push!(run, work_item, "spec", "## The spec text")
          passed!(run)
        end)
        |> reload()

      assert work_item.stage_state == :at_gate
    end
  end

  describe "what each tab lists" do
    test "Explore's tab at a later stage: Explore's runs, questions and artifacts", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope, ["A question of Shape?"])

      {:ok, view, html} = live(conn, stage(scope, work_item.number, @explore))

      assert has_element?(view, "#work-item-tabs-explore[aria-current=page]")
      assert has_element?(view, "#work-item-explore-proposal .badge", "Approved")
      refute has_element?(view, "#work-item-explore-proposal-review-add")
      refute has_element?(view, "#work-item-explore-questions-form")
      refute html =~ "A question of Shape?"
      assert has_element?(view, "#work-item-record", "1 run")
      assert has_element?(view, "#work-item-record", "proposal v1")
      refute has_element?(view, "#work-item-record", "spec")
      assert has_element?(view, "#work-item-artifact-list", "proposal")
      refute has_element?(view, "#work-item-artifact-list", "spec")
    end

    test "Shape's tab: its runs, its artifacts and every open question", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting!(scope, ["A question of Shape?"])

      {:ok, view, html} = live(conn, stage(scope, work_item.number))

      assert html =~ "A question of Shape?"
      assert has_element?(view, "#work-item-record", "1 run")
      assert has_element?(view, "#work-item-record", "spec v1")
      refute has_element?(view, "#work-item-artifact-list", "proposal")
    end

    test "Explore's comments stay on its tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
      {:ok, _commented} = WorkItems.review_comment(scope, work_item, 1, "On the proposal.")
      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)

      work_item =
        work_item
        |> reload()
        |> then(fn at_shape ->
          end_run!(at_shape, fn run, _registered ->
            push!(run, at_shape, "spec", "## The spec text")
            passed!(run)
          end)
        end)
        |> reload()

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      refute has_element?(view, "#work-item-review", "On the proposal.")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))
      assert has_element?(view, "#work-item-review", "On the proposal.")
      assert has_element?(view, "#work-item-review", "You, on version 1")
    end
  end

  describe "the record block" do
    test "on the stage's tab: none during a first run with no output", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> at_shape!() |> running!()

      {:ok, view, html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-wait", "Shape is running")

      assert html =~
               "reads the ticket and the stage&#39;s inputs, then writes spec, decision record, mockup and test features."

      refute has_element?(view, "#work-item-record")
    end

    test "on the stage's tab: kept for Add a version with no run and no artifact", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape!(scope)

      Repo.delete_all(
        from r in DispatchRun, where: r.work_item_id == ^work_item.id and r.stage_id == @shape
      )

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-record")
      assert has_element?(view, "#work-item-artifact-list-add", "Add a version")
    end

    test "on the Ticket tab and the Thread: kept during a first run", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> at_shape!() |> running!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))
      assert has_element?(view, "#work-item-record")

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/thread"))
      assert has_element?(view, "#work-item-record")
    end
  end

  describe "a row of the runs fold" do
    # The rows of the runs fold at the foot of the tab, oldest first, each with its parts
    # joined by " · ", as the page shows them.
    defp fold_rows(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        "#work-item-record-fold > .q-xp-inner > .q-xp-runrow, " <>
          "#work-item-record-fold > .q-xp-inner > details > summary"
      )
      |> Enum.map(fn row ->
        row
        |> LazyHTML.query(".q-xp-it")
        |> Enum.map_join(" · ", &(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
      end)
    end

    test "on the Ticket tab and the Thread: each run's workflow, round and verdict", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_gate!(scope)

      for tab <- ["/ticket", "/thread"] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number, tab))

        assert [explore, shape] = fold_rows(view)
        assert explore =~ ~r/^Attempt 1 \(Run \d+\) · explore-a-ticket · round 1 · passed · \S/
        assert shape =~ ~r/^Attempt 2 \(Run \d+\) · shape-a-ticket · round 1 · passed · \S/
      end
    end

    test "on Explore's tab at a later stage: Explore's run with its workflow, round and verdict",
         %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))

      assert [row] = fold_rows(view)
      assert row =~ ~r/^Attempt 1 \(Run \d+\) · explore-a-ticket · round 1 · passed · \S/
    end

    test "a run with no verdict yet: running, and when it started", %{
      conn: conn,
      scope: scope
    } do
      work_item = scope |> at_shape!() |> running!()

      for tab <- ["/ticket", "/thread"] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number, tab))

        assert [_explore, shape] = fold_rows(view)
        assert shape =~ ~r/^Attempt 2 \(Run \d+\) · shape-a-ticket · round 1 · running · started /
      end
    end
  end

  describe "a test work item" do
    test "opens on its current stage's tab, with no Ticket tab", %{conn: conn, scope: scope} do
      {:ok, test_item} = WorkItems.take_in_test(scope, "A line to test")

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, page(scope, test_item.number))
      assert to == stage(scope, test_item.number, @explore)

      {:ok, view, _html} = live(conn, to)

      assert has_element?(view, "#work-item-tabs-explore[aria-current=page]")
      refute has_element?(view, "#work-item-tabs-ticket")
    end
  end

  describe "a workspace that is not a software factory" do
    test "a stage with a workflow has its tab, with no repository in sight", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-spec")
      refute view |> element("#work-item-tab") |> render() =~ ~r/repositor/i
    end
  end

  describe "Run another round at the current stage" do
    @options [
      %{"title" => "Redis", "explanation" => "The store the other services use."},
      %{"title" => "Postgres", "explanation" => "The database of the storefront."}
    ]

    defp decision(question) do
      %{
        "question" => question,
        "options" => @options,
        "option" => "Redis",
        "reason" => "The other services use Redis."
      }
    end

    # Explore's run wrote the proposal and decided q1, with a review comment open on the
    # proposal, confirmed; Shape's run wrote spec, decided q2 and passed: Shape's gate.
    defp decided_at_gate!(scope) do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          push_decided!(run, registered, [decision("Which store keeps the baskets?")])
        end)

      {:ok, _commented} = WorkItems.review_comment(scope, work_item, 1, "On the proposal.")
      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)
      work_item = reload(work_item)

      work_item
      |> end_run!(fn run, registered ->
        push!(run, work_item, "spec", "## The spec text")
        push_decided!(run, registered, [decision("Which store keeps the orders?")])
        passed!(run)
      end)
      |> reload()
    end

    # A member's review comment, open, on version `version` of `type`: its id.
    defp comment_on!(scope, work_item, type, version, text) do
      earlier =
        case Apiary.Explore.ReviewComments.newest(work_item) do
          {_version, document} -> document
          nil -> nil
        end

      {id, document} =
        Apiary.Explore.ReviewComments.comment(
          earlier,
          %{"artifact" => type, "version" => version},
          text,
          "A member",
          DateTime.utc_now()
        )

      {:ok, _version} =
        Artifacts.push(
          {:member_action, scope},
          work_item,
          Apiary.Explore.ReviewComments.type_name(),
          [Apiary.Explore.ReviewComments.file(document)],
          stage_id: work_item.stage_id
        )

      id
    end

    defp round_comments(work_item) do
      %{data: data} =
        work_item.id |> Explore.events() |> Enum.filter(&(&1.kind == :answered)) |> List.last()

      data["review_comments"]
    end

    defp first_workflow(work_item) do
      Repo.one(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [asc: r.take_in, asc: r.attempt],
          limit: 1,
          select: r.workflow
      )
    end

    test "Shape waiting for answers: the answers run Shape's next round", %{scope: scope} do
      work_item = waiting!(scope, ["Which basket?"])
      round = %{answers: [%{"id" => "q1", "option" => nil, "note" => "The cart."}]}

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt(work_item), round)

      assert %DispatchRun{state: :waiting, step: "explore", stage_id: @shape} =
               run = newest_run(work_item)

      assert run.workflow == "shape-a-ticket"
    end

    test "at Shape's gate: a changed decision of Shape's run runs Shape's next round", %{
      scope: scope
    } do
      work_item = decided_at_gate!(scope)
      assert work_item.stage_state == :at_gate
      round = %{answers: [%{"id" => "q2", "option" => "Postgres"}]}

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt(work_item), round)

      assert %DispatchRun{state: :waiting, step: "explore", stage_id: @shape} =
               run = newest_run(work_item)

      assert run.workflow == "shape-a-ticket"
    end

    test "at Shape's gate: a member who is not among Shape's approvers runs no round", %{
      scope: scope
    } do
      process!(scope, %{
        "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
      })

      work_item = decided_at_gate!(scope)
      member = Apiary.OrganisationsFixtures.member_fixture(scope)
      before = attempt(work_item)
      round = %{answers: [%{"id" => "q2", "option" => "Postgres"}]}

      assert WorkItems.another_round(member.scope, work_item, before, round) ==
               {:error, :not_approver}

      assert attempt(work_item) == before
      assert %WorkItem{stage_state: :at_gate} = reload(work_item)

      # On Shape's tab the send shows the line of a member who is not an approver.
      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), stage(scope, work_item.number))

      gate = "#work-item-tab-gate"
      drafted = %{"number" => "#{work_item.number}", "answers" => %{"q2" => %{"option" => "2"}}}
      view |> element(gate) |> render_change(drafted)
      view |> element(gate) |> render_submit(drafted)
      confirm_spend(view)

      assert render(view) =~ "Ask an approver of Shape to act on it."
      assert attempt(work_item) == before

      # The other moves that run Shape's next round from its gate are the approvers' too.
      assert WorkItems.answer(member.scope, work_item, before, round.answers) ==
               {:error, :not_approver}

      comment_on!(scope, work_item, "spec", 1, "On the spec.")

      assert WorkItems.send_review_comments(member.scope, work_item, before) ==
               {:error, :not_approver}

      assert attempt(work_item) == before

      # An approver's run again from the gate leaves its gate.approve entry.
      assert {:ok, _work_item} = WorkItems.send_review_comments(scope, work_item, before)
      assert attempt(work_item) == before + 1
      user_id = scope.user.id

      assert [{^user_id, %{"change" => "another_round", "stage_id" => @shape}}] =
               gate_entries(work_item)
    end

    test "at Shape's gate: Explore's decision and Explore's open comment stay Explore's", %{
      scope: scope
    } do
      work_item = decided_at_gate!(scope)
      before = attempt(work_item)

      assert {:error, {:invalid, %{"q1" => _not_open}}} =
               WorkItems.another_round(scope, work_item, before, %{
                 answers: [%{"id" => "q1", "option" => "Postgres"}]
               })

      assert attempt(work_item) == before
      spec_comment = comment_on!(scope, work_item, "spec", 1, "On the spec.")

      assert {:ok, _work_item} = WorkItems.another_round(scope, work_item, before, %{})
      assert round_comments(work_item) == [spec_comment]
    end

    # As at Explore, whose run with the verdict `escalate` has no result: the escalation
    # has its Run another round (`Apiary.Stages.resolve/4`).
    test "Shape escalated by its run's verdict: the round is refused, the escalation open",
         %{scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, registered ->
          push!(run, work_item, "spec", "## The spec text")
          push_decided!(run, registered, [decision("Which store keeps the orders?")])

          {:ok, _version} =
            Stages.Artifacts.push_json(
              {:run, run},
              reload(work_item),
              "verdict",
              %{
                "verdict" => "escalate",
                "points" => [%{"text" => "The store is open.", "action" => "run_again"}]
              },
              stage_id: run.stage_id
            )
        end)
        |> reload()

      assert work_item.stage_state == :escalated
      before = attempt(work_item)

      assert {:error, :not_waiting} =
               WorkItems.another_round(scope, work_item, before, %{
                 answers: [%{"id" => "q1", "option" => "Postgres"}]
               })

      assert attempt(work_item) == before

      assert [%{resolution: nil}] =
               Repo.all(
                 from e in Apiary.Stages.Escalation, where: e.work_item_id == ^work_item.id
               )
    end

    # Explore again after a move back from Shape's gate, its run waiting with a question.
    defp moved_back_waiting!(scope) do
      work_item = decided_at_gate!(scope)
      spec_comment = comment_on!(scope, work_item, "spec", 1, "On the spec.")
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)
      work_item = reload(work_item)
      assert work_item.stage_id == @explore

      work_item = work_item |> end_run!(questions_result(["Which sale?"])) |> reload()
      assert work_item.stage_state == :waiting_answers
      {work_item, spec_comment}
    end

    test "Explore after a move back: its answers run Explore's next round", %{scope: scope} do
      {work_item, _spec_comment} = moved_back_waiting!(scope)
      round = %{answers: [%{"id" => "q3", "option" => nil, "note" => "The spring sale."}]}

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt(work_item), round)

      assert %DispatchRun{state: :waiting, step: "explore", stage_id: @explore} =
               run = newest_run(work_item)

      assert run.workflow == first_workflow(work_item)
    end

    test "Explore after a move back: Shape's decision and Shape's open comment stay Shape's",
         %{scope: scope} do
      {work_item, spec_comment} = moved_back_waiting!(scope)
      before = attempt(work_item)

      assert {:error, {:invalid, %{"q2" => _not_open}}} =
               WorkItems.another_round(scope, work_item, before, %{
                 answers: [%{"id" => "q2", "option" => "Postgres"}]
               })

      assert {:ok, _work_item} = WorkItems.another_round(scope, work_item, before, %{})
      assert [explore_comment] = round_comments(work_item)
      refute explore_comment == spec_comment
    end

    # Shape's gate lists the scope's person alone.
    defp shape_approver_only!(scope) do
      process!(scope, %{
        "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
      })
    end

    # Shape's run asked q1 and pushed the verdict `escalate`: Shape waits for answers, with
    # the escalation open.
    defp escalated_questions!(scope) do
      work_item = at_shape!(scope)

      work_item
      |> end_run!(fn run, registered ->
        push!(run, work_item, "spec", "## The spec text")
        push_result!(run, registered, questions_result(["Which basket?"]))

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            reload(work_item),
            "verdict",
            %{
              "verdict" => "escalate",
              "points" => [%{"text" => "The ticket has no basket.", "action" => "run_again"}]
            },
            stage_id: run.stage_id
          )
      end)
      |> reload()
    end

    defp escalations(work_item),
      do:
        Repo.all(
          from e in Apiary.Stages.Escalation,
            where: e.work_item_id == ^work_item.id,
            select: {e.resolution, e.resolved_by_id}
        )

    defp gate_entries(work_item),
      do:
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
            order_by: e.inserted_at,
            select: {e.actor_id, e.details}
        )

    test "Shape waiting for answers with its escalation open: a member who is not an approver answers nothing",
         %{scope: scope} do
      shape_approver_only!(scope)
      work_item = escalated_questions!(scope)
      assert work_item.stage_state == :waiting_answers
      member = Apiary.OrganisationsFixtures.member_fixture(scope)
      before = attempt(work_item)
      answers = [%{"id" => "q1", "option" => nil, "note" => "The cart."}]

      assert WorkItems.another_round(member.scope, work_item, before, %{answers: answers}) ==
               {:error, :not_approver}

      assert WorkItems.answer(member.scope, work_item, before, answers) ==
               {:error, :not_approver}

      assert attempt(work_item) == before
      assert escalations(work_item) == [{nil, nil}]
      assert gate_entries(work_item) == []

      # On Shape's tab the send shows the line of a member who is not an approver.
      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), stage(scope, work_item.number))

      q = "#work-item-tab-questions"

      view
      |> element("#{q}-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The cart."}}
      })

      confirm_spend(view)
      assert render(view) =~ "Ask an approver of Shape to act on it."
      assert attempt(work_item) == before
    end

    test "Shape waiting for answers with its escalation open: an approver's answer settles it",
         %{scope: scope} do
      shape_approver_only!(scope)
      work_item = escalated_questions!(scope)
      before = attempt(work_item)

      assert {:ok, _work_item} =
               WorkItems.answer(scope, work_item, before, [
                 %{"id" => "q1", "option" => nil, "note" => "The cart."}
               ])

      assert attempt(work_item) == before + 1
      user_id = scope.user.id
      assert escalations(work_item) == [{:another_round, user_id}]

      assert [{^user_id, %{"change" => "escalation_another_round", "cause" => "escalate"}}] =
               gate_entries(work_item)
    end

    test "Shape waiting for an answer: the needs block links the question on Shape's tab",
         %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, registered ->
          push!(run, work_item, "spec", "## The spec text")
          push_result!(run, registered, questions_result(["Which basket?"]))

          {:ok, _version} =
            Stages.Artifacts.push_json(
              {:run, run},
              reload(work_item),
              "verdict",
              %{
                "verdict" => "escalate",
                "points" => [
                  %{
                    "text" => "The ticket has no basket.",
                    "action" => "answer",
                    "question" => "q1"
                  }
                ]
              },
              stage_id: run.stage_id
            )
        end)
        |> reload()

      assert work_item.stage_state == :waiting_answers
      anchor = "#work-item-tab-questions-question-1"
      point = "#work-item-needs-point-1"

      # From the Ticket tab, the link opens Shape's tab at the question.
      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/ticket"))
      href = stage(scope, work_item.number) <> anchor
      assert has_element?(view, ~s|#{point} a[href="#{href}"]|, "question 1")

      # On Shape's tab, the link is the anchor of the question, which the tab has.
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      assert has_element?(view, ~s|#{point} a[href="#{anchor}"]|, "question 1")
      assert has_element?(view, anchor)
    end

    test "Shape's tab waiting for answers: the questions form, the comment and " <>
           "Run another round",
         %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["Which basket?"])
      {:ok, view, html} = live(conn, stage(scope, work_item.number))
      q = "#work-item-tab-questions"

      assert has_element?(view, "#{q}-form")
      assert has_element?(view, "#{q}-go", "Run another round")
      assert has_element?(view, "#{q}-comment")
      assert html =~ "That run reads your answers and your comment, and updates the outputs."
      refute html =~ "updates the proposal"

      view
      |> element("#{q}-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The cart."}}
      })

      assert has_element?(view, "#spend-dialog-title", "Run another round?")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-tab-questions-go"]|)
      confirm_spend(view)

      assert %DispatchRun{state: :waiting, stage_id: @shape} = newest_run(work_item)
    end

    test "Shape's tab at its gate: the decisions, the comment and Run another round", %{
      conn: conn,
      scope: scope
    } do
      work_item = decided_at_gate!(scope)
      {:ok, view, html} = live(conn, stage(scope, work_item.number))
      gate = "#work-item-tab-gate"

      assert has_element?(view, "#work-item-tab-decisions", "Which store keeps the orders?")
      refute has_element?(view, "#work-item-tab-decisions", "Which store keeps the baskets?")
      assert has_element?(view, "#{gate}-send[disabled]", "Run another round")
      assert has_element?(view, "#{gate}-comment")
      refute has_element?(view, "#{gate}-go")
      assert html =~ "That run reads your comment and updates the outputs."

      drafted = %{"number" => "#{work_item.number}", "answers" => %{"q2" => %{"option" => "2"}}}
      view |> element(gate) |> render_change(drafted)
      refute has_element?(view, "#{gate}-send[disabled]")

      view |> element(gate) |> render_submit(drafted)
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-tab-gate-send"]|)
      confirm_spend(view)

      assert %DispatchRun{state: :waiting, stage_id: @shape} = newest_run(work_item)
    end

    test "Explore's tab after a move back: its form runs Explore's next round", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _spec_comment} = moved_back_waiting!(scope)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))
      q = "#work-item-explore-questions"

      view
      |> element("#{q}-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q3" => %{"note" => "The spring sale."}}
      })

      confirm_spend(view)

      assert %DispatchRun{state: :waiting, stage_id: @explore} = newest_run(work_item)
    end
  end

  describe "the round's comment" do
    defp registered_number(dispatch_run),
      do: Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: dispatch_run.id).number

    defp comment_entry(work_item, id) do
      {_version, document} = Apiary.Explore.ReviewComments.newest(reload(work_item))
      Enum.find(document["review_comments"], &(&1["id"] == id))
    end

    defp event_comment(work_item) do
      %{data: data} =
        work_item.id |> Explore.events() |> Enum.filter(&(&1.kind == :answered)) |> List.last()

      data["review_comment"]
    end

    # Explore's proposal waits at Confirm.
    defp proposed!(scope), do: scope |> taken_in_fixture() |> end_run!(understood_result())

    test "at Shape's gate: a comment alone runs Shape's round, on Shape's newest run", %{
      scope: scope
    } do
      work_item = at_gate!(scope)
      shape_run = newest_run(work_item)

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, shape_run.attempt, %{
                 comment: "Check the totals."
               })

      id = event_comment(work_item)
      assert round_comments(work_item) == [id]

      assert %{"on" => on, "text" => "Check the totals.", "state" => "open"} =
               comment_entry(work_item, id)

      assert on == %{"run" => registered_number(shape_run)}

      assert %DispatchRun{state: :waiting, stage_id: @shape, workflow: "shape-a-ticket"} =
               newest_run(work_item)
    end

    test "at Explore's gate: the comment is on Explore's newest run", %{scope: scope} do
      work_item = proposed!(scope)
      explore_run = newest_run(work_item)

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, 1, %{comment: "Check the totals."})

      assert %{"on" => on} = comment_entry(work_item, event_comment(work_item))
      assert on == %{"run" => registered_number(explore_run)}

      # A comment on the proposal alone keeps the output's form.
      work_item = work_item |> reload() |> end_run!(understood_result())
      assert {:ok, _work_item} = WorkItems.review_comment(scope, work_item, 2, "On the text.")

      assert %{"on" => %{"artifact" => "proposal", "version" => _version}} =
               comment_entry(work_item, "c2")
    end

    test "a member's reply to a round comment of the take in is kept", %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, 1, %{comment: "Shorter."})
      work_item = work_item |> reload() |> end_run!(understood_result())

      assert {:ok, _work_item} = WorkItems.reply(scope, work_item, 2, "c1", "Shorter still.")
      assert %{"replies" => [%{"text" => "Shorter still."}]} = comment_entry(work_item, "c1")
    end

    test "a round comment left open goes with the next round at its stage, not later", %{
      scope: scope
    } do
      work_item = proposed!(scope)
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, 1, %{comment: "Shorter."})
      work_item = work_item |> reload() |> end_run!(understood_result())

      # Run 2 left c1 open: Run another round with nothing new sends it again.
      assert {:ok, _work_item} = WorkItems.another_round(scope, work_item, 2, %{})
      assert round_comments(work_item) == ["c1"]

      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 3)
      work_item = reload(work_item)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")
          passed!(run)
        end)
        |> reload()

      spec_comment = comment_on!(scope, work_item, "spec", 1, "On the spec.")

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt(work_item), %{})

      assert round_comments(work_item) == [spec_comment]
    end

    test "Shape's tab: the comment box, its card on Shape's tab only", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_gate!(scope)
      shape_run = newest_run(work_item)
      {:ok, view, html} = live(conn, stage(scope, work_item.number))
      gate = "#work-item-tab-gate"

      assert has_element?(
               view,
               ~s|label[for="work-item-tab-gate-comment"]|,
               "Comment on the stage's outputs"
             )

      refute html =~ "Comment on the whole proposal"
      assert html =~ "That run reads your comment and updates the outputs."
      assert has_element?(view, "#{gate}-send[disabled]", "Run another round")

      drafted = %{"number" => "#{work_item.number}", "comment" => "Check the totals."}
      view |> element(gate) |> render_change(drafted)
      view |> element(gate) |> render_submit(drafted)
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-tab-gate-send"]|)
      confirm_spend(view)

      assert %DispatchRun{state: :waiting, stage_id: @shape} = newest_run(work_item)
      work_item = work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)

      # The card has the attempt of the round, as the Thread's line has it.
      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-tab-review-c1 .q-rc-by",
               "You, on the round of attempt #{shape_run.attempt}"
             )

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))
      refute has_element?(view, "#work-item-explore-proposal-review-c1")
    end

    test "what members gave has no version field", %{scope: scope} do
      work_item = proposed!(scope)
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, 1, %{comment: "Shorter."})

      assert [%{kind: :comment, id: "c1", text: "Shorter."} = entry] =
               Apiary.Explore.Given.all(reload(work_item))

      refute Map.has_key?(entry, :on)
    end
  end

  describe "after a move back to Explore" do
    test "Shape's tab has the artifacts once, above the tabs", %{conn: conn, scope: scope} do
      work_item = decided_at_gate!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-flow #work-item-artifact-list")
      refute has_element?(view, "#work-item-record #work-item-artifacts")
    end

    test "the notes above the tabs keep the comments", %{conn: conn, scope: scope} do
      work_item = decided_at_gate!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))

      assert has_element?(view, "#work-item-flow", "On the proposal.")
    end
  end

  describe "the stage card's link to the questions" do
    test "goes to the current stage's tab from any tab", %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["A question of Shape?"])
      to = stage(scope, work_item.number)

      for address <- [
            stage(scope, work_item.number, @explore),
            page(scope, work_item.number, "/thread")
          ] do
        {:ok, view, _html} = live(conn, address)
        assert has_element?(view, ~s|#work-item-stage-answers[href="#{to}"]|)
      end
    end
  end

  describe "a round at Shape that runs" do
    # Shape's gate again after a round with a comment, which its run left open: c1, listed
    # on Shape's tab.
    defp commented_gate!(scope) do
      work_item = at_gate!(scope)

      {:ok, _work_item} =
        WorkItems.another_round(scope, work_item, attempt(work_item), %{comment: "Shorter."})

      work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
    end

    test "the rail has the line that the run reads the comment", %{conn: conn, scope: scope} do
      work_item = commented_gate!(scope)
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, attempt(work_item), %{})
      assert %DispatchRun{state: :waiting, stage_id: @shape} = newest_run(work_item)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-review-c1-reading", "reads this comment.")
    end

    test "an open Reply keeps its draft, with the line that the run started first", %{
      conn: conn,
      scope: scope
    } do
      work_item = commented_gate!(scope)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number) <> "?reply=c1")
      assert has_element?(view, "#work-item-review-page-form")

      {:ok, _work_item} = WorkItems.another_round(scope, work_item, attempt(work_item), %{})
      send(view.pid, {:stage_changed, work_item.id})

      assert has_element?(view, "#work-item-review-page-form")
      assert has_element?(view, "#work-item-review-page-error", "started first")
      refute has_element?(view, "#work-item-review-page-error", "changed")
    end
  end

  describe "an output on two stages" do
    defp two_stages!(scope) do
      process!(scope, %{}, %{
        "sequence" => [%{"workflow" => "build-it"}],
        "outputs" => [%{"type" => "spec", "required" => false}],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      })

      work_item = at_gate!(scope)
      page = ApiaryWeb.WorkItemLive.Workflow.page(scope, work_item)

      {:ok, _approved} =
        ApiaryWeb.WorkItemLive.Workflow.decide(scope, work_item, page, {:approve, nil})

      assert %DispatchRun{stage_id: @build} = newest_run(work_item)
      reload(work_item)
    end

    test "Build's tab has no frame of Shape's spec", %{conn: conn, scope: scope} do
      work_item = two_stages!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))
      refute has_element?(view, "#work-item-tab-output-spec")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      assert has_element?(view, "#work-item-tab-output-spec")
    end

    test "a comment on Shape's spec is on Shape's tab, not Build's" do
      stages = [
        %{id: "st_e", name: "Explore", outputs: ["proposal"]},
        %{id: "st_s", name: "Shape", outputs: ["spec"]},
        %{id: "st_b", name: "Build", outputs: ["spec"]}
      ]

      flow = %{
        explore_id: "st_e",
        at_explore: false,
        stage: Enum.at(stages, 2),
        stages: stages,
        index: [],
        tabs: for(%{id: id, name: name} <- stages, do: %{key: id, name: name})
      }

      read = %{
        item: %{run: nil},
        earlier_runs: [],
        earlier_take_ins: [],
        questions: [],
        questions_version: nil,
        review_comments: [%{id: "c1", artifact: "spec", version: 1, run: nil, state: :open}],
        artifacts: [%{type: "spec", name: "main", versions: [%{number: 1, stage_id: "st_s"}]}]
      }

      assert [%{id: "c1"}] =
               ApiaryWeb.WorkItemLive.StageTab.view("st_s", flow, read).review_comments

      assert [] = ApiaryWeb.WorkItemLive.StageTab.view("st_b", flow, read).review_comments
      assert [] = ApiaryWeb.WorkItemLive.StageTab.view(:thread, flow, read).review_comments
    end
  end

  describe "a stage with a workflow and no outputs" do
    test "its run reads the ticket and the stage's inputs", %{conn: conn, scope: scope} do
      process!(scope, %{"outputs" => []})
      work_item = at_shape!(scope)

      {:ok, _view, html} = live(conn, stage(scope, work_item.number))

      assert html =~
               "starts when the workspace&#39;s pool takes it. It reads the ticket and the stage&#39;s inputs.</p>"

      running!(work_item)
      {:ok, _view, html} = live(conn, stage(scope, work_item.number))

      assert html =~ "reads the ticket and the stage&#39;s inputs.</p>"
      refute html =~ "then writes"
    end
  end

  describe "a member's moves at a later stage" do
    # Explore's run decided q1 and wrote the proposal, with c1 open on the proposal,
    # confirmed; Shape's run wrote spec and asked q2, so Shape waits for answers.
    defp shape_waiting!(scope) do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          push_decided!(run, registered, [decision("Which store keeps the baskets?")])
        end)

      {:ok, _commented} = WorkItems.review_comment(scope, work_item, 1, "On the proposal.")
      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)
      work_item = reload(work_item)

      work_item
      |> end_run!(fn run, registered ->
        push!(run, work_item, "spec", "## The spec text")
        push_result!(run, registered, questions_result(["Which basket?"]))
      end)
      |> reload()
    end

    defp question(work_item, id) do
      {_version, document} = Apiary.Explore.Questions.newest(reload(work_item))
      Enum.find(document["questions"], &(&1["id"] == id))
    end

    test "at Shape's questions: an answer to Explore's decided question is refused", %{
      scope: scope
    } do
      work_item = shape_waiting!(scope)
      before = attempt(work_item)

      assert {:error, {:invalid, %{"q1" => _not_open}}} =
               WorkItems.answer(scope, work_item, before, [
                 %{"id" => "q1", "option" => "Postgres"}
               ])

      assert %{"state" => "decided", "decision" => %{"option" => "Redis"}} =
               question(work_item, "q1")

      assert attempt(work_item) == before

      assert {:ok, _work_item} =
               WorkItems.answer(scope, work_item, before, [
                 %{"id" => "q2", "option" => nil, "note" => "The cart."}
               ])

      assert %{"state" => "answered"} = question(work_item, "q2")
      assert %DispatchRun{state: :waiting, stage_id: @shape} = newest_run(work_item)
    end

    test "at Shape's questions: answers by position leave Explore's open question out", %{
      scope: scope
    } do
      # Explore's run asked q1, and a member moved the work item on to Shape with q1 open;
      # Shape's run asked q2.
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(questions_result(["Which store?"]))

      {:ok, _moved} = Stages.move(scope, work_item, @shape, nil, expect_stage: @explore)
      work_item = reload(work_item)

      work_item =
        work_item
        |> end_run!(fn run, registered ->
          push!(run, work_item, "spec", "## The spec text")
          push_result!(run, registered, questions_result(["Which basket?"]))
        end)
        |> reload()

      assert {:ok, _work_item} =
               WorkItems.answer(scope, work_item, attempt(work_item), %{"1" => "The cart."})

      assert %{"state" => "answered"} = question(work_item, "q2")
      assert %{"state" => "open"} = question(work_item, "q1")
    end

    test "at Shape's questions: a reply to a comment of Explore's is not found", %{
      scope: scope
    } do
      # c1 on the round of Explore's first run, c2 on the proposal of its second.
      work_item = proposed!(scope)
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, 1, %{comment: "Shorter."})
      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _commented} = WorkItems.review_comment(scope, work_item, 2, "On the proposal.")
      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 2)
      work_item = reload(work_item)

      work_item =
        work_item
        |> end_run!(fn run, registered ->
          push!(run, work_item, "spec", "## The spec text")
          push_result!(run, registered, questions_result(["Which basket?"]))
        end)
        |> reload()

      assert work_item.stage_state == :waiting_answers

      for id <- ["c1", "c2"] do
        assert {:error, :not_found} =
                 WorkItems.reply(scope, work_item, attempt(work_item), id, "Reopen it.")

        assert (comment_entry(work_item, id)["replies"] || []) == []
      end
    end

    test "a reply to a round comment of an earlier take in is not found", %{scope: scope} do
      ticket = Apiary.WorkItemsFixtures.backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, 1, %{comment: "Shorter."})
      work_item = work_item |> reload() |> end_run!(understood_result())

      {:ok, _closed} = WorkItems.close(scope, reload(work_item))

      {:ok, _again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      work_item = work_item |> reload() |> end_run!(understood_result()) |> reload()
      assert work_item.take_in == 2

      assert {:error, :not_found} = WorkItems.reply(scope, work_item, 1, "c1", "Shorter still.")
      assert (comment_entry(work_item, "c1")["replies"] || []) == []
    end

    test "at Explore: the round carries the open comments on the proposal only", %{
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          push_decided!(run, registered, [decision("Which store keeps the baskets?")])
        end)
        |> reload()

      {:ok, _commented} = WorkItems.review_comment(scope, work_item, 1, "On the proposal.")
      work_item = reload(work_item)
      "c2" = comment_on!(scope, work_item, "questions", 1, "On the questions.")

      assert {:ok, _work_item} = WorkItems.another_round(scope, work_item, 1, %{})
      assert round_comments(work_item) == ["c1"]
    end
  end

  describe "a proposal waiting at Confirm after a gate none" do
    # Explore's gate is none, so the work item passes on to Shape, whose `changes` apply,
    # while Explore's proposal waits at Confirm.
    defp passed_on!(scope, changes) do
      document = Processes.current(scope.workspace).document

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore} = stage -> Map.put(stage, "gate", %{"kind" => "none"})
          %{"id" => @shape} = stage -> Map.merge(stage, changes)
          stage -> stage
        end)

      {:ok, _version} =
        Processes.save(scope, scope.workspace, %{document | "stages" => stages})

      work_item = proposed!(scope) |> reload()
      assert work_item.stage_id == @shape
      work_item
    end

    test "Run another round from the proposal starts no round of Shape while Shape waits for its inputs",
         %{conn: conn, scope: scope} do
      work_item =
        passed_on!(scope, %{"inputs" => [%{"type" => "mockup", "required" => true}]})

      assert work_item.stage_state == :waiting_inputs
      assert %{status: :confirm} = WorkItems.explore(scope, work_item)
      before = attempt(work_item)

      assert WorkItems.another_round(scope, work_item, before, %{comment: "Shorter."}) ==
               {:error, :not_waiting}

      assert attempt(work_item) == before
      assert reload(work_item).stage_state == :waiting_inputs

      # Explore's tab offers Run another round on the proposal; the send starts nothing
      # and shows that the work item changed, as Approve there is refused.
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))
      gate = "#work-item-explore-gate"

      view
      |> element(gate)
      |> render_submit(%{"number" => "#{work_item.number}", "comment" => "Shorter."})

      confirm_spend(view)
      assert render(view) =~ "The work item changed after the page showed it"
      assert attempt(work_item) == before
    end

    test "a reply to a comment on the proposal is kept", %{scope: scope} do
      work_item = passed_on!(scope, %{"sequence" => []})
      {:ok, _commented} = WorkItems.review_comment(scope, work_item, 1, "On the proposal.")

      assert {:ok, _work_item} = WorkItems.reply(scope, reload(work_item), 1, "c1", "Shorter.")
      assert %{"replies" => [%{"text" => "Shorter."}]} = comment_entry(work_item, "c1")
    end
  end

  describe "Explore's tab at a later stage" do
    test "lists Explore's comments with no Reply", %{conn: conn, scope: scope} do
      work_item = shape_waiting!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))

      assert has_element?(view, "#work-item-review", "On the proposal.")
      refute has_element?(view, "#work-item-review [id$='-reply']")
    end

    test "a Reply address opens no form page and goes back to the tab", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_waiting!(scope)
      tab = stage(scope, work_item.number, @explore)

      assert {:error, {:live_redirect, %{to: ^tab}}} = live(conn, tab <> "?reply=c1")
    end
  end

  describe "a reply at Shape's gate" do
    test "is kept, and the page goes back to Shape's tab", %{conn: conn, scope: scope} do
      work_item = commented_gate!(scope)
      tab = stage(scope, work_item.number)
      {:ok, view, _html} = live(conn, tab <> "?reply=c1")

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "comment" => "c1",
        "text" => "Shorter still."
      })

      assert_patch(view, tab)
      assert %{"replies" => [%{"text" => "Shorter still."}]} = comment_entry(work_item, "c1")
    end

    test "a reader who loses the right goes back to Shape's tab, with no line", %{
      conn: conn,
      scope: scope
    } do
      work_item = commented_gate!(scope)
      tab = stage(scope, work_item.number)
      {:ok, view, _html} = live(conn, tab <> "?reply=c1")
      assert has_element?(view, "#work-item-review-page-form")

      # The work item's process version lists another member as Shape's approver.
      listed = Apiary.OrganisationsFixtures.member_fixture(scope, :member)

      version =
        process!(scope, %{
          "gate" => %{"kind" => "person", "approvers" => %{"members" => [listed.user.id]}}
        })

      work_item
      |> Ecto.Changeset.change(process_version_id: version.id)
      |> Repo.update!()

      send(view.pid, {:work_items_changed, [work_item.public_id]})

      assert_patch(view, tab)
      refute has_element?(view, "#work-item-review-page-form")
      refute has_element?(view, "#work-item-review-page-error")
    end
  end

  describe "the Thread at a later stage" do
    test "a Shape run has Shape's name, and its outputs are its result", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_gate!(scope)
      shape = attempt(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/thread"))
      thread = "#work-item-thread"

      assert has_element?(view, thread, "Shape started in attempt #{shape}")
      refute has_element?(view, thread, "Explore started again")
      refute has_element?(view, thread, "ended without a result")
    end

    test "a round comment and the round it starts", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)
      shape = attempt(work_item)
      {:ok, _work_item} = WorkItems.another_round(scope, work_item, shape, %{comment: "Shorter."})
      work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/thread"))
      thread = "#work-item-thread"

      assert has_element?(view, thread, "You wrote a comment on the round of attempt #{shape}")
      refute has_element?(view, thread, "on the proposal")

      assert has_element?(
               view,
               thread,
               "Shape started again, with the comments, in attempt #{shape + 1}"
             )
    end

    test "a Shape run's questions", %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["Which basket?", "Which sale?"])

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/thread"))

      assert has_element?(view, "#work-item-thread", "Shape wrote 2 questions")
      refute has_element?(view, "#work-item-thread", "ended without a result")
    end
  end

  describe "the address's query" do
    test "a list for a reply on /explore patches with no query", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore?reply[]=x"))

      assert address(view) == {:stage, :explore}
      refute has_element?(view, "#work-item-review-page")
    end
  end

  describe "the stage with a proposal output" do
    test "has Approve on its tab, and no Run another round" do
      html =
        render_component(&ApiaryWeb.WorkItemComponents.stage_tab/1,
          stage: %{name: "Plan", outputs: ["proposal"]},
          work_item: %{number: 1, status: :confirm, run: nil},
          current: true,
          can_act: true
        )

      assert html =~ ~s(id="work-item-tab-gate-go")
      assert html =~ "Approve"
      refute html =~ "Run another round"
    end

    test "an output type named gate keeps the id of the gate unique" do
      html =
        render_component(&ApiaryWeb.WorkItemComponents.stage_tab/1,
          stage: %{name: "Plan", outputs: ["proposal", "gate"]},
          work_item: %{number: 1, status: :confirm, run: nil},
          outputs: [%{type: "gate", version: 1, open: true, read: nil}],
          current: true,
          can_act: true
        )

      assert length(Regex.scan(~r/id="work-item-tab-gate"/, html)) == 1
      assert html =~ ~s(id="work-item-tab-output-gate")
    end
  end
end
