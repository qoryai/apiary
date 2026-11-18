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
  import Apiary.OrganisationsFixtures, only: [with_domain: 2]
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.{Explore, WorkItem}
  alias ApiaryWeb.WorkflowFake
  alias ApiaryWeb.WorkItemLive.StageTab

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

  defp questions(scope, number), do: page(scope, number, "/questions")

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

      assert %{{"spec", "main", 1} => %{}} = :sys.get_state(view.pid).socket.assigns.frame_texts
      assert has_element?(view, "#work-item-tab-output-spec-fold[open]")
      refute has_element?(view, "#work-item-tab-output-test-features-fold[open]")

      refute Map.has_key?(
               :sys.get_state(view.pid).socket.assigns.frame_texts,
               {"test-features", "main", 1}
             )
    end

    test "an output whose artifact is not named main has a frame with its name", %{
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

      assert has_element?(
               view,
               "#work-item-tab-output-test-features--other---h",
               "Test features · other"
             )

      view |> element("#work-item-tab-output-test-features--other---s") |> render_click()
      assert render(view) =~ "Another"
    end

    test "frames whose names differ by an id's suffix have no DOM id twice", %{
      conn: conn,
      scope: scope
    } do
      # Each upload at Shape's gate is a person's change, so each name has a frame:
      # scenario-1 at version 2, scenario-1-v2, h and h-s.
      work_item = at_gate!(scope)

      for name <- ["scenario-1", "scenario-1", "scenario-1-v2", "h", "h-s"] do
        {:ok, _version} =
          Stages.add_version(
            scope,
            reload(work_item),
            "spec",
            [%{filename: "spec.md", content_type: "text/markdown", binary: "## #{name}"}],
            name: name
          )
      end

      {:ok, view, html} = live(conn, stage(scope, work_item.number))

      named =
        for %{type: "spec", name: name, version: version} <-
              :sys.get_state(view.pid).socket.assigns.frames,
            name != "main",
            do: {name, version}

      assert Enum.sort(named) == [
               {"h", 1},
               {"h-s", 1},
               {"scenario-1", 2},
               {"scenario-1-v2", 1}
             ]

      ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
      assert ids -- Enum.uniq(ids) == []
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

  describe "the approval of a gate none (vault 0252)" do
    setup %{scope: scope} do
      process!(scope, %{"gate" => %{"kind" => "none"}})
      :ok
    end

    test "the first frame has Approved and \"Approved automatically\" with the time", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_gate!(scope)
      assert %WorkItem{stage_id: @build} = work_item

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-spec-s .q-xp-frame-b", "Approved")

      caption = view |> element("#work-item-tab-output-spec-approval") |> render()
      assert caption =~ "hero-check-micro"
      assert caption =~ "Version 1 · Approved automatically · "

      [%{inserted_at: at}] =
        Repo.all(
          from d in Apiary.Stages.GateDecision,
            where: d.work_item_id == ^work_item.id and d.stage_id == ^@shape
        )

      assert caption =~
               ~r|<time [^>]*datetime="[^"]+"[^>]*>#{ApiaryWeb.Format.day_time(at)}</time>|

      # The folded frames show their version alone.
      refute has_element?(view, "#work-item-tab-output-test-features-s .q-xp-frame-b")
      refute has_element?(view, "#work-item-tab-output-test-features-approval")
      assert has_element?(view, "#work-item-tab-output-test-features-s", "Version 1")
    end

    test "an accepted escalation shows \"Accepted by you\", and another member's name to others",
         %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")

          {:ok, _version} =
            Stages.Artifacts.push_json(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              "verdict",
              %{
                "verdict" => "escalate",
                "points" => [%{"text" => "Ask.", "action" => "run_again"}]
              },
              stage_id: run.stage_id
            )
        end)
        |> reload()

      assert work_item.stage_state == :escalated

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @shape)

      assert work_item.stage_id == @build

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))
      assert has_element?(view, "#work-item-tab-output-spec-s .q-xp-frame-b", "Approved")

      assert has_element?(
               view,
               "#work-item-tab-output-spec-approval",
               "Version 1 · Accepted by you · "
             )

      other = Apiary.OrganisationsFixtures.member_fixture(scope, :member)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), other.user), stage(scope, work_item.number))

      name = ApiaryWeb.People.short(scope.user.email)

      assert has_element?(
               view,
               "#work-item-tab-output-spec-approval",
               "Version 1 · Accepted by #{name} · "
             )
    end

    test "a person gate's approval shows no mark", %{conn: conn, scope: scope} do
      process!(scope)
      work_item = at_gate!(scope)
      {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-spec-s", "Version 1")
      refute has_element?(view, "#work-item-tab-output-spec-s .q-xp-frame-b")
      refute has_element?(view, "#work-item-tab-output-spec-approval")
    end

    test "an accept keeps \"Accepted by you\" after a process version makes the gate a person's",
         %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")

          {:ok, _version} =
            Stages.Artifacts.push_json(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              "verdict",
              %{
                "verdict" => "escalate",
                "points" => [%{"text" => "Ask.", "action" => "run_again"}]
              },
              stage_id: run.stage_id
            )
        end)
        |> reload()

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @shape)

      process!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-tab-output-spec-approval",
               "Version 1 · Accepted by you · "
             )
    end

    # The gate is read from the approval, never from the stage as the process has it now.
    test "the line follows the gate the approval was recorded at" do
      index = fn automatic, gate_none ->
        [
          %{
            type: "spec",
            name: "main",
            approved: 1,
            approval: %{
              by: "u_1",
              automatic: automatic,
              gate_none: gate_none,
              stage_id: @shape,
              at: ~U[2026-11-15 14:20:00Z]
            }
          }
        ]
      end

      frames = [%{type: "spec", version: 1, open: true}]
      person = %{id: @shape, gate: %{"kind" => "person"}}
      none = %{id: @shape, gate: %{"kind" => "none"}}

      assert [%{approval: %{automatic: false, by: "u_1"}}] =
               ApiaryWeb.WorkItemLive.StageTab.approved(frames, person, index.(false, true))

      assert [%{approval: %{automatic: true}}] =
               ApiaryWeb.WorkItemLive.StageTab.approved(frames, person, index.(true, true))

      assert [%{approval: nil}] =
               ApiaryWeb.WorkItemLive.StageTab.approved(frames, none, index.(false, false))
    end
  end

  describe "the review comments document" do
    test "has no frame" do
      recorded =
        for {type, number} <- [{"spec", 2}, {"review-comments", 1}, {"mockup", 1}],
            do: %{type: type, name: "main", version: %{number: number, writer: :run}}

      assert [%{type: "spec", version: 2, open: true}, %{type: "mockup", open: false}] =
               ApiaryWeb.WorkItemLive.StageTab.frames(recorded)
    end
  end

  describe "a person's version's caption" do
    test "has the member's short name, or Former member for an account that is gone" do
      recorded =
        for user <- [%Apiary.Accounts.User{email: "sam@example.com"}, nil],
            do: %{type: "spec", name: "main", version: %{number: 1, writer: :person, user: user}}

      assert [%{writer: "sam"}, %{writer: "Former member"}] =
               ApiaryWeb.WorkItemLive.StageTab.frames(recorded)
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

      # The questions are on the Questions tab; Shape's tab counts them and links there.
      refute html =~ "A question of Shape?"

      assert has_element?(
               view,
               ~s|#work-item-tab-questions-line a[href="#{questions(scope, work_item.number)}"]|,
               "Questions tab"
             )

      {:ok, questions_view, _html} = live(conn, questions(scope, work_item.number))
      assert has_element?(questions_view, "#work-item-questions-open", "A question of Shape?")
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

      # On the Questions tab the send shows the line of a member who is not an approver.
      {:ok, view, _html} =
        live(log_in_user(build_conn(), member.user), questions(scope, work_item.number))

      q = "#work-item-questions-open"

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

    test "Shape waiting for an answer: the needs block links the question on the Questions tab",
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
      anchor = "#work-item-questions-question-1"
      point = "#work-item-needs-point-1"

      # From the Ticket tab and Shape's tab, the link opens the Questions tab at the question.
      href = questions(scope, work_item.number) <> anchor

      for address <- [page(scope, work_item.number, "/ticket"), stage(scope, work_item.number)] do
        {:ok, view, _html} = live(conn, address)
        assert has_element?(view, ~s|#{point} a[href="#{href}"]|, "question 1")
      end

      # On the Questions tab, the link is the anchor of the question, which the tab has.
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      assert has_element?(view, ~s|#{point} a[href="#{anchor}"]|, "question 1")
      assert has_element?(view, anchor)
    end

    test "the Questions tab waiting for answers: the questions form, the comment and " <>
           "Run another round",
         %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["Which basket?"])
      {:ok, view, html} = live(conn, questions(scope, work_item.number))
      q = "#work-item-questions-open"

      assert has_element?(view, "#{q}-form")
      assert has_element?(view, "#{q}-go", "Run another round of Shape")
      assert has_element?(view, "#{q}-comment")

      assert has_element?(
               view,
               "label[for=work-item-questions-open-comment]",
               "Comment on Shape's outputs"
             )

      assert html =~
               "That run reads your answers and your comment, and updates Shape&#39;s outputs."

      refute html =~ "updates the proposal"

      view
      |> element("#{q}-form")
      |> render_submit(%{
        "number" => "#{work_item.number}",
        "answers" => %{"q1" => %{"note" => "The cart."}}
      })

      assert has_element?(view, "#spend-dialog-title", "Run another round of Shape?")
      assert has_element?(view, ~s|#spend-dialog[data-return="work-item-questions-open-go"]|)
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

    test "the Questions tab after a move back: its form runs Explore's next round", %{
      conn: conn,
      scope: scope
    } do
      {work_item, _spec_comment} = moved_back_waiting!(scope)
      {:ok, view, _html} = live(conn, questions(scope, work_item.number))
      q = "#work-item-questions-open"

      assert has_element?(view, "#{q}-go", "Run another round of Explore")

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

    test "the notes above the tabs leave out a comment that Explore's approval closed",
         %{conn: conn, scope: scope} do
      work_item = decided_at_gate!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))

      refute has_element?(view, "#work-item-flow", "On the proposal.")
    end

    test "the notes above the tabs list a note written after Explore's approval",
         %{conn: conn, scope: scope} do
      work_item = decided_at_gate!(scope)

      {:ok, _moved} =
        Stages.move(scope, work_item, @explore, "Check the totals.", expect_stage: @shape)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @explore))

      assert has_element?(view, "#work-item-flow", "Check the totals.")
      refute has_element?(view, "#work-item-flow", "On the proposal.")
    end
  end

  describe "the stage card's link to the questions" do
    test "goes to the Questions tab from any tab", %{conn: conn, scope: scope} do
      work_item = waiting!(scope, ["A question of Shape?"])
      to = questions(scope, work_item.number)

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

  describe "a stage passed over whole by a track (A-23)" do
    # Explore's gate offers Standard and Fast track; Shape runs shape-a-ticket on Standard
    # only.
    defp tracked!(scope) do
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore, "gate" => gate} = stage ->
            %{stage | "gate" => Map.put(gate, "tracks", ["standard", "fast-track"])}

          %{"id" => @shape} = stage ->
            Map.merge(stage, %{
              "sequence" => [%{"workflow" => "shape-a-ticket"}],
              "when" => %{"track" => "standard"}
            })

          %{"id" => @build} = stage ->
            %{
              stage
              | "sequence" => [
                  %{"workflow" => "build-it"},
                  %{"workflow" => "shape-a-ticket", "unless" => %{"track" => "fast-track"}}
                ]
            }

          stage ->
            stage
        end)

      document =
        document
        |> Map.put("stages", stages)
        |> Map.put("tracks", [
          %{"id" => "standard", "name" => "Standard"},
          %{"id" => "fast-track", "name" => "Fast track"}
        ])

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
    end

    # The approval and the pass-over it caused, at noon UTC on 14 Nov 2025, a day in the year
    # before the test's now and one that every time zone shows as the same date.
    defp confirmed!(scope, track) do
      tracked!(scope)
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: track)

      {_n, _rows} =
        Repo.update_all(from(d in Stages.GateDecision, where: d.work_item_id == ^work_item.id),
          set: [inserted_at: ~U[2025-11-14 12:00:00.000000Z]]
        )

      {_n, _rows} =
        Repo.update_all(from(k in Stages.Skip, where: k.work_item_id == ^work_item.id),
          set: [inserted_at: ~U[2025-11-14 12:00:01.000000Z]]
        )

      reload(work_item)
    end

    defp shown(view),
      do: view |> element("#work-item-tab-passed-over-why") |> render() |> text_of()

    defp text_of(html),
      do: html |> String.replace(~r/<[^>]*>/, "") |> String.replace("&#39;", "'") |> String.trim()

    test "the tab says the stage did not run, and which approval skips it", %{
      conn: conn,
      scope: scope
    } do
      work_item = confirmed!(scope, "fast-track")
      assert %WorkItem{stage_id: stage_id} = work_item
      assert stage_id != @shape

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert has_element?(view, "#work-item-tab-passed-over-h", "Shape did not run")

      assert view
             |> element("#work-item-tab-passed-over-why")
             |> render() =~
               "You approved Fast track at Explore&#39;s gate on 14 Nov 2025. Fast track skips Shape."
    end

    test "the tab of a stage lists an entry the track passed over, with the reason", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> confirmed!("fast-track")
        |> end_run!(fn run, _registered -> passed!(run) end)

      assert %WorkItem{stage_id: @build} = work_item

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      assert has_element?(view, "#work-item-tab-entries-row-1", "shape-a-ticket")
      assert has_element?(view, "#work-item-tab-entries-row-1", "Not run")
      assert has_element?(view, "#work-item-tab-entries-row-1", "Runs on Standard only.")
      refute has_element?(view, "#work-item-record-skip-1")
    end

    test "the record of a stage lists the entries a passed first attempt passed over, with the reason",
         %{conn: conn, scope: scope} do
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore, "gate" => gate} = stage ->
            %{stage | "gate" => Map.put(gate, "tracks", ["standard", "fast"])}

          %{"id" => @shape} = stage ->
            Map.put(stage, "when", %{"track" => "standard"})

          %{"id" => @build} = stage ->
            %{
              stage
              | "sequence" => [
                  %{"workflow" => "build-it", "first_attempt" => true, "name" => "Quick fix"},
                  %{"workflow" => "shape-a-ticket"},
                  %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "build-it"}]}}
                ]
            }

          stage ->
            stage
        end)

      document =
        document
        |> Map.put("stages", stages)
        |> Map.put("tracks", [
          %{"id" => "standard", "name" => "Standard"},
          %{"id" => "fast", "name" => "Fast track"}
        ])

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(understood_result())

      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast")

      work_item = work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)
      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      for {i, workflow} <- [{1, "shape-a-ticket"}, {2, "build-it"}] do
        assert has_element?(view, "#work-item-record-skip-#{i}", workflow)

        assert has_element?(
                 view,
                 "#work-item-record-skip-#{i}",
                 "Did not run, because Quick fix passed on its first attempt."
               )
      end

      # The same two records, now passed over for a condition on a change.
      for {negated, words} <- [
            {false, "did not run: the demo scenarios did not change since it last passed."},
            {true, "did not run: the demo scenarios changed since it last passed."}
          ] do
        {2, _rows} =
          Repo.update_all(
            from(k in Stages.Skip,
              where: k.work_item_id == ^work_item.id and not is_nil(k.workflow)
            ),
            set: [
              reason: nil,
              cause_entry: nil,
              input: "demo-scenarios",
              changed: true,
              negated: negated
            ]
          )

        {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

        for {i, workflow} <- [{1, "shape-a-ticket"}, {2, "build-it"}] do
          assert has_element?(view, "#work-item-record-skip-#{i}", "#{workflow} #{words}")
        end
      end
    end

    test "the tab of a stage the work item went through has no such block", %{
      conn: conn,
      scope: scope
    } do
      work_item = confirmed!(scope, "standard")
      assert %WorkItem{stage_id: @shape} = work_item

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))
      refute has_element?(view, "#work-item-tab-passed-over")
    end

    test "a person's move into the stage later removes the block: it runs", %{
      conn: conn,
      scope: scope
    } do
      work_item = confirmed!(scope, "fast-track")

      {:ok, moved} =
        Stages.move(scope, work_item, @shape, nil, expect_stage: reload(work_item).stage_id)

      assert %WorkItem{stage_id: @shape} = moved

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))
      refute has_element?(view, "#work-item-tab-passed-over")
    end

    test "another member's approval names the member", %{scope: scope} do
      work_item = confirmed!(scope, "fast-track")
      %{user: other} = Apiary.OrganisationsFixtures.member_fixture(scope, :admin)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), other), stage(scope, work_item.number, @shape))

      assert shown(view) ==
               "#{ApiaryWeb.People.short(scope.user.email)} approved Fast track at Explore's gate on 14 Nov 2025. Fast track skips Shape."
    end

    # Explore's gate offers Fast track first; Build runs on Standard only. A person's move
    # forward past Explore's gate records the first track, and approving Shape then passes
    # Build over. The move and the pass-over are dated as `confirmed!/2` dates them.
    defp moved!(scope) do
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore, "gate" => gate} = stage ->
            %{stage | "gate" => Map.put(gate, "tracks", ["fast-track", "standard"])}

          %{"id" => @shape} = stage ->
            Map.merge(stage, %{"sequence" => [], "outputs" => []})

          %{"id" => @build} = stage ->
            Map.put(stage, "when", %{"track" => "standard"})

          stage ->
            stage
        end)

      document =
        document
        |> Map.put("stages", stages)
        |> Map.put("tracks", [
          %{"id" => "standard", "name" => "Standard"},
          %{"id" => "fast-track", "name" => "Fast track"}
        ])

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
      {:ok, _moved} = Stages.move(scope, work_item, @shape, nil, expect_stage: @explore)
      {:ok, _approved} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)

      {_n, _rows} =
        Repo.update_all(from(d in Stages.GateDecision, where: d.work_item_id == ^work_item.id),
          set: [inserted_at: ~U[2025-11-14 12:00:00.000000Z]]
        )

      {_n, _rows} =
        Repo.update_all(from(k in Stages.Skip, where: k.work_item_id == ^work_item.id),
          set: [inserted_at: ~U[2025-11-14 12:00:01.000000Z]]
        )

      reload(work_item)
    end

    test "a track that a move recorded reads that the person moved the work item, You", %{
      conn: conn,
      scope: scope
    } do
      work_item = moved!(scope)
      assert [%{kind: :move, track_id: "fast-track"}] = approvals_of(work_item)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      assert shown(view) ==
               "You moved the work item past Explore's gate on 14 Nov 2025, so it runs Fast track. Fast track skips Build."
    end

    test "a track that a move recorded reads the member's name for another reader", %{
      scope: scope
    } do
      work_item = moved!(scope)
      %{user: other} = Apiary.OrganisationsFixtures.member_fixture(scope, :admin)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), other), stage(scope, work_item.number, @build))

      assert shown(view) ==
               "#{ApiaryWeb.People.short(scope.user.email)} moved the work item past Explore's gate on 14 Nov 2025, so it runs Fast track. Fast track skips Build."
    end

    # Explore's gate offers Fast track first, Standard second; Shape runs on Standard only.
    # The work item is on Standard, escalated in Build, and a switch puts it on Fast track,
    # which passes Shape over. The decisions are dated before the switch, the switch and
    # the pass-over as `moved!/1` dates them.
    defp switched!(scope) do
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore, "gate" => gate} = stage ->
            %{stage | "gate" => Map.put(gate, "tracks", ["fast-track", "standard"])}

          %{"id" => @shape} = stage ->
            Map.merge(stage, %{
              "sequence" => [],
              "outputs" => [],
              "when" => %{"track" => "standard"}
            })

          %{"id" => @build} = stage ->
            Map.merge(stage, %{"sequence" => [], "outputs" => []})

          stage ->
            stage
        end)

      document =
        document
        |> Map.put("stages", stages)
        |> Map.put("tracks", [
          %{"id" => "standard", "name" => "Standard"},
          %{"id" => "fast-track", "name" => "Fast track"}
        ])

      {:ok, version} = Processes.save(scope, scope.workspace, document)
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")
      {:ok, at_build} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build} = at_build

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :escalated]
        )

      Repo.insert!(%Apiary.Stages.Escalation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: version.id,
        stage_id: @build,
        round: 1,
        cause: :escalate,
        points: [%{"text" => "The change alters the product.", "action" => "run_again"}],
        inserted_at: DateTime.utc_now()
      })

      assert {:ok, _switched} =
               Stages.resolve_escalation(scope, reload(work_item), {:switch, "fast-track"}, nil,
                 expect_stage: @build
               )

      {_n, _rows} =
        Repo.update_all(
          from(d in Stages.GateDecision,
            where: d.work_item_id == ^work_item.id and is_nil(d.escalation_id)
          ),
          set: [inserted_at: ~U[2025-11-13 12:00:00.000000Z]]
        )

      {_n, _rows} =
        Repo.update_all(
          from(d in Stages.GateDecision,
            where: d.work_item_id == ^work_item.id and not is_nil(d.escalation_id)
          ),
          set: [inserted_at: ~U[2025-11-14 12:00:00.000000Z]]
        )

      {_n, _rows} =
        Repo.update_all(from(k in Stages.Skip, where: k.work_item_id == ^work_item.id),
          set: [inserted_at: ~U[2025-11-14 12:00:01.000000Z]]
        )

      reload(work_item)
    end

    test "a track that a switch recorded reads that the person switched the work item, not that they moved it past a gate",
         %{conn: conn, scope: scope} do
      work_item = switched!(scope)
      assert [%{kind: :move, switch: true, track_id: "fast-track"}] = approvals_of(work_item)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert shown(view) ==
               "You switched the work item to Fast track on 14 Nov 2025. Fast track skips Shape."

      refute has_element?(view, "#work-item-tab-passed-over-why", "moved the work item past")
    end

    test "a track that a switch recorded reads the member's name for another reader", %{
      scope: scope
    } do
      work_item = switched!(scope)
      %{user: other} = Apiary.OrganisationsFixtures.member_fixture(scope, :admin)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), other), stage(scope, work_item.number, @shape))

      assert shown(view) ==
               "#{ApiaryWeb.People.short(scope.user.email)} switched the work item to Fast track on 14 Nov 2025. Fast track skips Shape."
    end

    defp approvals_of(work_item),
      do: for(%{approved: %{} = a} <- Stages.stage_skips(work_item), do: a)

    test "an approval of a member whose account is gone reads Former member", %{
      conn: conn,
      scope: scope
    } do
      work_item = confirmed!(scope, "fast-track")

      {_n, _rows} =
        Repo.update_all(from(d in Stages.GateDecision, where: d.work_item_id == ^work_item.id),
          set: [user_id: nil]
        )

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert shown(view) ==
               "Former member approved Fast track at Explore's gate on 14 Nov 2025. Fast track skips Shape."
    end

    test "with no approval to name, the line gives the condition that held the stage back",
         %{conn: conn, scope: scope} do
      work_item = confirmed!(scope, "fast-track")

      {_n, _rows} =
        Repo.delete_all(from(d in Stages.GateDecision, where: d.work_item_id == ^work_item.id))

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))
      assert shown(view) == "Shape runs on Standard only."

      reason = fn set ->
        {1, _rows} =
          Repo.update_all(from(k in Stages.Skip, where: k.work_item_id == ^work_item.id),
            set: set
          )

        {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))
        shown(view)
      end

      assert reason.(negated: true, track: "fast-track") == "Shape does not run on Fast track."

      assert reason.(negated: false, track: nil, input: "test-features") ==
               "Shape runs only while the work item has test features, and it has none."

      assert reason.(negated: true) ==
               "Shape does not run while the work item has test features."
    end
  end

  describe "an approval with a track (A-23)" do
    test "the gate takes the track through the page's action, and says what a refusal needs" do
      flow = %{stage: %{name: "Shape"}}

      assert ApiaryWeb.WorkItemLive.Show.refused({:track_not_offered, "express"}, flow) ==
               "Choose a track that the gate of Shape offers. It does not offer express."
    end

    test "an approval refused for the artifact store says to try again" do
      flow = %{stage: %{name: "Shape"}}

      assert ApiaryWeb.WorkItemLive.Show.refused(:store_unavailable, flow) ==
               "Try again in a minute. The artifact store cannot be reached."
    end

    test "a track the gate does not offer is refused through decide/4", %{scope: scope} do
      work_item = at_gate!(scope)
      page = ApiaryWeb.WorkItemLive.Workflow.page(scope, work_item)

      assert ApiaryWeb.WorkItemLive.Workflow.decide(
               scope,
               work_item,
               page,
               {:approve, nil, "express"}
             ) ==
               {:error, {:track_not_offered, "express"}}
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

  describe "a gate after a move back (A-20)" do
    test "Shape's tab and gate show the spec that a person's approval at Build listed",
         %{conn: conn, scope: scope} do
      # Shape's run pushes spec 1, and a person approves it.
      work_item = at_gate!(scope, "## Spec one")
      {:ok, _at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      # At Build, a person adds spec 2, and Build's approval lists it.
      {:ok, _version} =
        Stages.add_version(scope, reload(work_item), "spec", [
          %{filename: "spec.md", content_type: "text/markdown", binary: "## Spec two"}
        ])

      {:ok, at_verify} = Stages.approve(scope, reload(work_item), nil, expect_stage: @build)
      [spec] = for a <- Artifacts.list(at_verify), a.type == "spec", do: a
      assert [%{number: 2} = two, %{number: 1}] = spec.versions

      assert two.public_id in Enum.find(gate_approvals(at_verify), &(&1.stage_id == @build)).versions

      # A person moves the work item back to Shape; its run pushes no spec.
      {:ok, moved} = Stages.move(scope, at_verify, @shape, nil, expect_stage: at_verify.stage_id)
      work_item = moved |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      assert %WorkItem{stage_id: @shape} = work_item

      {:ok, view, html} = live(conn, stage(scope, work_item.number))

      assert [%{type: "spec", version: 2, open: true} | _rest] =
               :sys.get_state(view.pid).socket.assigns.frames

      assert has_element?(view, "#work-item-tab-output-spec-fold[open]")
      assert html =~ "Spec two"
      refute html =~ "Spec one"
    end

    test "Shape's tab and gate show a spec that a person added at Build, which no approval " <>
           "lists yet",
         %{conn: conn, scope: scope} do
      work_item = at_gate!(scope, "## Spec one")
      {:ok, _at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      {:ok, _version} =
        Stages.add_version(scope, reload(work_item), "spec", [
          %{filename: "spec.md", content_type: "text/markdown", binary: "## Spec two"}
        ])

      # A person moves the work item back to Shape; its run pushes no spec.
      {:ok, moved} = Stages.move(scope, reload(work_item), @shape, nil, expect_stage: @build)
      work_item = moved |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      assert %WorkItem{stage_id: @shape} = work_item

      {:ok, view, html} = live(conn, stage(scope, work_item.number))

      assert [%{type: "spec", version: 2, open: true} | _rest] =
               :sys.get_state(view.pid).socket.assigns.frames

      assert html =~ "Spec two"
      refute html =~ "Spec one"
    end

    defp gate_approvals(work_item) do
      Repo.all(
        from d in Apiary.Stages.GateDecision,
          where: d.work_item_id == ^work_item.id and d.kind == :approve
      )
    end
  end

  describe "every version an approval records has a frame (A-20)" do
    # The public ids of the versions whose frames the page draws on the tab.
    defp drawn(view, work_item) do
      frames = :sys.get_state(view.pid).socket.assigns.frames

      for artifact <- Artifacts.list(work_item),
          version <- artifact.versions,
          frame <- frames,
          frame.type == artifact.type and Map.get(frame, :name, "main") == artifact.name and
            frame.version == version.number,
          do: version.public_id
    end

    # The versions that the newest approval of `stage_id` records.
    defp recorded(work_item, stage_id) do
      Repo.all(
        from d in Apiary.Stages.GateDecision,
          where:
            d.work_item_id == ^work_item.id and d.kind == :approve and d.stage_id == ^stage_id,
          order_by: [desc: d.inserted_at],
          limit: 1,
          select: d.versions
      )
      |> List.first()
    end

    defp add_spec!(scope, work_item, text) do
      {:ok, version} =
        Stages.add_version(scope, reload(work_item), "spec", [
          %{filename: "spec.md", content_type: "text/markdown", binary: text}
        ])

      version
    end

    # Whether the spec frame's caption has version `number` and the short name of the
    # scope's member, not the address.
    defp caption?(view, scope, number) do
      frame = "#work-item-tab-output-spec"
      short = ApiaryWeb.People.short(scope.user.email)

      has_element?(view, frame, "Version #{number} · #{short}") and
        not has_element?(view, frame, "Version #{number} · #{scope.user.email}")
    end

    # The tab of `stage_id` drawn, then its gate approved: the versions the approval
    # records, and those the page drew.
    defp approved_and_drawn(conn, scope, work_item, stage_id) do
      {:ok, view, html} = live(conn, stage(scope, work_item.number, stage_id))
      drawn = drawn(view, work_item)
      {:ok, _approved} = Stages.approve(scope, reload(work_item), nil, expect_stage: stage_id)
      {recorded(work_item, stage_id), drawn, view, html}
    end

    test "a run's version", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)
      {recorded, drawn, _view, _html} = approved_and_drawn(conn, scope, work_item, @shape)

      assert length(recorded) == 2
      assert recorded -- drawn == []
    end

    test "two names of one type, main and other: a frame and a gate row for each, and the " <>
           "approval records both",
         %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")
          push!(run, work_item, "test-features", "## The main features")
          push!(run, work_item, "test-features", "## The other features", "other")
          passed!(run)
        end)
        |> reload()

      features =
        for %{type: "test-features"} = artifact <- Artifacts.list(work_item),
            into: %{},
            do: {artifact.name, hd(artifact.versions).public_id}

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-tab-output-test-features-h", "Test features")

      assert has_element?(
               view,
               "#work-item-tab-output-test-features--other---h",
               "Test features · other"
             )

      assert has_element?(view, "#work-item-stage-gate-output-test-features", "test features v1")

      assert has_element?(
               view,
               "#work-item-stage-gate-output-test-features--other--",
               "test features other v1"
             )

      {recorded, drawn, _view, _html} = approved_and_drawn(conn, scope, work_item, @shape)

      assert features["main"] in recorded and features["other"] in recorded
      assert length(recorded) == 3
      assert Enum.sort(recorded) == Enum.sort(drawn)
    end

    test "a version that only a person uploaded, with who uploaded it",
         %{conn: conn, scope: scope} do
      process!(scope, %{"outputs" => [%{"type" => "spec", "required" => false}]})
      work_item = scope |> at_shape!() |> end_run!(fn run, _registered -> passed!(run) end)
      add_spec!(scope, work_item, "## Spec by hand")

      # Before the approval, the frame's caption has who uploaded it.
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))
      assert caption?(view, scope, 1)

      {recorded, drawn, _view, html} = approved_and_drawn(conn, scope, work_item, @shape)

      assert [_one] = recorded
      assert recorded -- drawn == []
      assert html =~ "Spec by hand"
    end

    test "a version that only an earlier take in made", %{conn: conn, scope: scope} do
      process!(scope, %{"outputs" => [%{"type" => "spec", "required" => false}]})
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)

      work_item
      |> reload()
      |> end_run!(fn run, _registered ->
        push!(run, work_item, "spec", "## Spec of the first take in")
        passed!(run)
      end)

      {:ok, _closed} = WorkItems.close(scope, reload(work_item))
      {:ok, _again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})
      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)

      work_item =
        work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end) |> reload()

      assert %WorkItem{take_in: 2, stage_id: @shape} = work_item

      {recorded, drawn, _view, html} = approved_and_drawn(conn, scope, work_item, @shape)

      assert [_one] = recorded
      assert recorded -- drawn == []
      assert html =~ "Spec of the first take in"
    end

    test "a change that a person's approval lists", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope, "## Spec one")
      {:ok, _at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      add_spec!(scope, work_item, "## Spec two")
      {:ok, at_verify} = Stages.approve(scope, reload(work_item), nil, expect_stage: @build)

      {:ok, moved} = Stages.move(scope, at_verify, @shape, nil, expect_stage: at_verify.stage_id)
      work_item = moved |> end_run!(fn run, _registered -> passed!(run) end) |> reload()

      [spec] = for a <- Artifacts.list(work_item), a.type == "spec", do: a
      spec_two = Enum.find(spec.versions, &(&1.number == 2)).public_id
      {recorded, drawn, _view, _html} = approved_and_drawn(conn, scope, work_item, @shape)

      assert spec_two in recorded
      assert recorded -- drawn == []
    end

    test "a change that no approval lists yet, at a stage with no outputs",
         %{conn: conn, scope: scope} do
      process!(scope, %{}, %{"sequence" => [%{"workflow" => "build-it"}]})
      work_item = at_gate!(scope, "## Spec one")
      {:ok, at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      add_spec!(scope, at_build, "## Spec two")
      at_build = at_build |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = at_build

      {:ok, view, _html} = live(conn, stage(scope, at_build.number, @build))
      assert caption?(view, scope, 2)

      {recorded, drawn, _view, html} = approved_and_drawn(conn, scope, at_build, @build)

      assert [_spec_two] = recorded
      assert recorded -- drawn == []
      assert html =~ "Spec two"
    end

    # At Shape's gate after its run wrote spec v1: `first` and then `second` each add one
    # spec version, with a round between them that the person asks for. The approval and
    # the frames have one spec version, the highest.
    defp one_spec_version!(conn, scope, first, second) do
      work_item = at_gate!(scope, "## Spec one")
      work_item = first.(work_item)

      {:ok, _round} =
        Stages.request_changes(scope, reload(work_item), "Again.", nil, expect_stage: @shape)

      work_item = work_item |> reload() |> second.() |> reload()
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))
      frames = :sys.get_state(view.pid).socket.assigns.frames
      {:ok, _approved} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      [spec] = for a <- Artifacts.list(work_item), a.type == "spec", do: a
      spec_ids = MapSet.new(spec.versions, & &1.public_id)
      three = Enum.find(spec.versions, &(&1.number == 3)).public_id

      assert [%{version: 3}] = Enum.filter(frames, &(&1.type == "spec"))
      assert Enum.filter(recorded(work_item, @shape), &(&1 in spec_ids)) == [three]
    end

    test "a person's upload, then a run's version: one frame, the run's",
         %{conn: conn, scope: scope} do
      one_spec_version!(
        conn,
        scope,
        fn work_item ->
          add_spec!(scope, work_item, "## Spec two")
          work_item
        end,
        fn work_item ->
          end_run!(work_item, fn run, _registered ->
            push!(run, work_item, "spec", "## Spec three")
            passed!(run)
          end)
        end
      )
    end

    test "a run's version, then a person's upload: one frame, the upload",
         %{conn: conn, scope: scope} do
      one_spec_version!(conn, scope, & &1, fn work_item ->
        work_item =
          end_run!(work_item, fn run, _registered ->
            push!(run, work_item, "spec", "## Spec two")
            passed!(run)
          end)

        add_spec!(scope, reload(work_item), "## Spec three")
        work_item
      end)
    end

    test "a past stage's tab frames what its approval recorded", %{conn: conn, scope: scope} do
      process!(scope, %{}, %{"sequence" => [%{"workflow" => "build-it"}]})
      work_item = at_gate!(scope, "## Spec one")
      {:ok, at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      add_spec!(scope, at_build, "## Spec two")
      at_build = at_build |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      {:ok, moved_on} = Stages.approve(scope, at_build, nil, expect_stage: @build)

      assert moved_on.stage_id != @build
      assert [spec_two] = recorded(work_item, @build)

      {:ok, view, html} = live(conn, stage(scope, work_item.number, @build))

      assert spec_two in drawn(view, work_item)
      assert caption?(view, scope, 2)
      assert html =~ "Spec two"
    end

    test "the runs' summary lists the version the runs wrote, not the upload",
         %{conn: conn, scope: scope} do
      work_item = at_gate!(scope, "## Spec one")
      add_spec!(scope, work_item, "## Spec two")
      {:ok, moved_on} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)
      assert moved_on.stage_id != @shape

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert [%{version: 2}] =
               Enum.filter(:sys.get_state(view.pid).socket.assigns.frames, &(&1.type == "spec"))

      summary = "#work-item-record-fold > summary"
      assert has_element?(view, summary, "1 run")
      assert has_element?(view, summary, "spec v1")
      refute has_element?(view, summary, "spec v2")
    end

    # The gate card's line of `type` links to the page of `version`, as the Artifacts list
    # at the foot of the Ticket tab does.
    # Whether the gate card's row of `key`, the row's `StageComponents.frame_key/1`, links
    # to `version`.
    defp gate_link?(view, scope, work_item, key, version) do
      path = ApiaryWeb.ArtifactComponents.version_path(scope, work_item.number, version)
      has_element?(view, ~s(#work-item-stage-gate-output-#{key} a[href="#{path}"]))
    end

    test "the gate card links an upload at a stage with no workflow to its version",
         %{conn: conn, scope: scope} do
      process!(scope, %{"sequence" => [], "outputs" => [%{"type" => "spec", "required" => false}]})

      work_item = at_shape!(scope)
      version = add_spec!(scope, work_item, "## Spec by hand")
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = reload(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-tabs-ticket[aria-current=page]")
      assert has_element?(view, "#work-item-stage-gate-output-spec a", "spec v1")
      assert gate_link?(view, scope, work_item, "spec", version.public_id)
    end

    test "the gate card links a run's version at a stage with a workflow",
         %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)
      [spec] = for a <- Artifacts.list(work_item), a.type == "spec", do: a

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert gate_link?(view, scope, work_item, "spec", hd(spec.versions).public_id)
    end

    test "after a move back to Shape, the gate card links the version a later approval " <>
           "listed, not Shape's newest",
         %{conn: conn, scope: scope} do
      work_item = at_gate!(scope, "## Spec one")
      {:ok, _at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      spec_two = add_spec!(scope, work_item, "## Spec two")
      {:ok, at_verify} = Stages.approve(scope, reload(work_item), nil, expect_stage: @build)

      {:ok, moved} = Stages.move(scope, at_verify, @shape, nil, expect_stage: at_verify.stage_id)
      work_item = moved |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      [spec] = for a <- Artifacts.list(work_item), a.type == "spec", do: a
      assert Enum.find(spec.versions, &(&1.stage_id == @shape)).number == 1

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-output-spec a", "spec v2")
      assert gate_link?(view, scope, work_item, "spec", spec_two.public_id)
    end

    test "the gate card links an output whose only artifact is not named main",
         %{conn: conn, scope: scope} do
      work_item = at_shape!(scope)

      work_item =
        work_item
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "spec", "## The spec text")
          push!(run, work_item, "test-features", "## Another", "other")
          passed!(run)
        end)
        |> reload()

      [other] = for a <- Artifacts.list(work_item), a.type == "test-features", do: a
      assert other.name == "other"

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert gate_link?(
               view,
               scope,
               work_item,
               "test-features--other--",
               hd(other.versions).public_id
             )
    end

    test "the gate card lists a version the approval records that no output line shows",
         %{conn: conn, scope: scope} do
      # Verify runs no workflow, has no outputs, and a member approves its gate.
      verify = "st_m1mqbeywdg"
      version = process!(scope, %{}, %{"sequence" => [%{"workflow" => "build-it"}]})

      assert %{"outputs" => [], "gate" => %{"kind" => "person"}} =
               stage = Enum.find(version.document["stages"], &(&1["id"] == verify))

      assert Map.get(stage, "sequence", []) == []

      work_item = at_gate!(scope, "## Spec one")
      {:ok, at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      at_build = at_build |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      {:ok, at_verify} = Stages.approve(scope, at_build, nil, expect_stage: @build)
      assert %WorkItem{stage_id: ^verify, stage_state: :at_gate} = reload(at_verify)

      spec_two = add_spec!(scope, at_verify, "## Spec two")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      line = "#work-item-stage-gate-recorded-spec"

      path =
        ApiaryWeb.ArtifactComponents.version_path(scope, work_item.number, spec_two.public_id)

      assert has_element?(view, ~s(#{line} a[href="#{path}"]), "spec v2")
      refute has_element?(view, "#work-item-stage-gate-recorded li:not(#{line})")

      {:ok, _approved} = Stages.approve(scope, reload(work_item), nil, expect_stage: verify)
      assert spec_two.public_id in recorded(work_item, verify)
    end

    test "a gate with no change lists no other version", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-outputs")
      refute has_element?(view, "#work-item-stage-gate-recorded")
    end

    test "after a move back, Shape's gate frames a person's upload at Build, which its " <>
           "approval records",
         %{conn: conn, scope: scope} do
      process!(scope, %{}, %{"sequence" => [%{"workflow" => "build-it"}]})
      work_item = at_gate!(scope)
      {:ok, at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      {:ok, explainer} =
        Stages.add_version(scope, at_build, "explainer", [
          %{filename: "explainer.md", content_type: "text/markdown", binary: "## Explainer"}
        ])

      {:ok, moved} = Stages.move(scope, reload(at_build), @shape, nil, expect_stage: @build)
      work_item = moved |> end_run!(fn run, _registered -> passed!(run) end) |> reload()
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-tab-output-explainer",
               "Version 1 · #{ApiaryWeb.People.short(scope.user.email)}"
             )

      {:ok, _approved} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert explainer.public_id in recorded(work_item, @shape)
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

  describe "the screens of a track" do
    @verify "st_m1mqbeywdg"

    # Explore's gate offers Standard and Fast track. Shape runs on Standard only. Build's
    # first entry is the Fast track's, a first attempt; its other entries and its loop run on
    # Standard only, and its gate needs no member. Verify's workflow runs on Standard only,
    # and a person approves its gate.
    defp screens!(scope, build \\ nil, opts \\ []) do
      report = Keyword.get(opts, :report, "test-features")
      verify_outputs = Keyword.get(opts, :verify_outputs, [])
      document = Processes.default_document("software")

      :ok =
        Processes.record_declared(
          scope.workspace,
          Processes.qory_workflows(Apiary.Stacks.Sources.chosen(scope.workspace)) ++
            ~w(shape-a-ticket build-it review-it)
        )

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore, "gate" => gate} = stage ->
            %{stage | "gate" => Map.put(gate, "tracks", ["standard", "fast-track"])}

          %{"id" => @shape} = stage ->
            Map.merge(stage, %{
              "sequence" => [%{"workflow" => "shape-a-ticket"}],
              "when" => %{"track" => "standard"}
            })

          %{"id" => @build} = stage ->
            Map.merge(stage, %{
              "sequence" =>
                build ||
                  [
                    %{
                      "workflow" => "build-it",
                      "name" => "Fast track implementation",
                      "first_attempt" => true,
                      "when" => %{"track" => "fast-track"}
                    },
                    %{"workflow" => "shape-a-ticket", "unless" => %{"track" => "fast-track"}},
                    %{
                      "loop" => %{"rounds" => 3, "body" => [%{"workflow" => "review-it"}]},
                      "unless" => %{"track" => "fast-track"}
                    }
                  ],
              "outputs" => [%{"type" => report, "required" => false}],
              "gate" => %{"kind" => "none"}
            })

          %{"id" => @verify} = stage ->
            Map.merge(stage, %{
              "inputs" => [%{"type" => report, "required" => false}],
              "sequence" => [
                %{"workflow" => "shape-a-ticket", "unless" => %{"track" => "fast-track"}}
              ],
              "outputs" => verify_outputs,
              "gate" => %{"kind" => "person", "approvers" => "members"}
            })

          stage ->
            stage
        end)

      document =
        document
        |> Map.put("stages", stages)
        |> Map.put("tracks", [
          %{"id" => "standard", "name" => "Standard", "description" => "Shape writes a spec."},
          %{"id" => "fast-track", "name" => "Fast track", "description" => "One session."}
        ])

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
    end

    # The end of Explore's run: a proposal, and a verdict that proposes `track`.
    defp proposing(track, reason \\ "A small change.") do
      fn run, registered ->
        push_result!(run, registered, understood_result())
        proposal = %{"id" => track, "reason" => reason}

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed", "track" => proposal},
            stage_id: run.stage_id
          )
      end
    end

    defp at_explore_gate!(scope, proposed \\ "fast-track") do
      screens!(scope)
      scope |> taken_in_fixture() |> end_run!(proposing(proposed))
    end

    # Explore's gate approved with the track `track`, and Build's first attempt run passed,
    # with test-features written. Verify's gate waits, and Verify started no run.
    defp at_verify_gate!(scope, track \\ "fast-track") do
      work_item = at_explore_gate!(scope)
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: track)

      work_item
      |> reload()
      |> end_run!(fn run, _registered ->
        push!(run, work_item, "test-features", "## The report text")
        passed!(run)
      end)
      |> reload()
    end

    # The reader changes the gate's radios to `track`.
    defp pick(view, track) do
      view
      |> form("#work-item-explore-gate")
      |> render_change(%{"track" => track, "_target" => ["track"]})
    end

    defp track_draft(view), do: :sys.get_state(view.pid).socket.assigns.track

    defp track_decisions(work_item) do
      Repo.all(
        from d in Stages.GateDecision,
          where: d.work_item_id == ^work_item.id and d.kind == :approve,
          order_by: d.inserted_at,
          select: {d.stage_id, d.track}
      )
    end

    test "Explore's gate lists the tracks with their descriptions above Approve, the proposed one selected",
         %{conn: conn, scope: scope} do
      work_item = at_explore_gate!(scope)

      {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(
               view,
               "#work-item-explore-gate-track legend",
               "Track to run after you approve"
             )

      assert has_element?(view, "#work-item-explore-gate-track-standard", "Standard")
      assert has_element?(view, "#work-item-explore-gate-track-standard", "Shape writes a spec.")
      assert has_element?(view, "#work-item-explore-gate-track-fast-track", "One session.")

      assert has_element?(
               view,
               "#work-item-explore-gate-track-fast-track-proposed",
               "Proposed by Explore"
             )

      refute has_element?(view, "#work-item-explore-gate-track-standard-proposed")

      assert has_element?(
               view,
               "#work-item-explore-gate-track-fast-track input[type=radio][checked]"
             )

      refute has_element?(view, "#work-item-explore-gate-track-standard input[checked]")

      assert has_element?(
               view,
               "#work-item-step-line",
               "Pick a track and approve the proposal, or add a comment and run another round."
             )

      [before_approve, _rest] = String.split(html, ~s(id="work-item-explore-gate-go"), parts: 2)
      assert before_approve =~ ~s(id="work-item-explore-gate-track")
    end

    test "the proposed track has the reason the run gave, and no other track has one", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(
               view,
               "#work-item-explore-gate-track-fast-track-reason",
               "Explore's reason: A small change."
             )

      refute has_element?(view, "#work-item-explore-gate-track-standard-reason")
    end

    test "a blank reason shows no line of reason", %{conn: conn, scope: scope} do
      screens!(scope)
      work_item = scope |> taken_in_fixture() |> end_run!(proposing("fast-track", "   "))

      {:ok, view, html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(view, "#work-item-explore-gate-track-fast-track-proposed")
      refute has_element?(view, "#work-item-explore-gate-track-fast-track-reason")
      refute html =~ "reason:"
    end

    test "the gate's first track is selected when no run proposed one", %{
      conn: conn,
      scope: scope
    } do
      screens!(scope)
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      assert has_element?(view, "#work-item-explore-gate-track-standard input[checked]")
      refute has_element?(view, "#work-item-explore-gate-track-fast-track-proposed")
    end

    test "the track that the member picks is the one the approval records", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      pick(view, "standard")

      assert has_element?(view, "#work-item-explore-gate-track-standard input[checked]")
      refute has_element?(view, "#work-item-explore-gate-go[phx-value-track]")

      view |> element("#work-item-explore-gate-go") |> render_click()
      view |> form("#spend-dialog-form") |> render_submit()

      assert track_decisions(work_item) == [{@explore, "standard"}]
      assert Stages.track(reload(work_item)) == "standard"
      assert track_draft(view) == nil
    end

    test "an Approve click that carries an older value records the track the page shows", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      pick(view, "standard")

      view |> element("#work-item-explore-gate-go") |> render_click(%{"track" => "fast-track"})
      view |> form("#spend-dialog-form") |> render_submit()

      assert track_decisions(work_item) == [{@explore, "standard"}]
    end

    test "a forged click with a track the gate does not offer records no such track", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      view |> element("#work-item-explore-gate-go") |> render_click(%{"track" => "bogus"})
      view |> form("#spend-dialog-form") |> render_submit()

      assert track_decisions(work_item) == [{@explore, "fast-track"}]
      assert Process.alive?(view.pid)
    end

    test "a forged change with a track the gate does not offer picks nothing", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      pick(view, "bogus")

      assert has_element?(view, "#work-item-explore-gate-track-fast-track input[checked]")
      view |> element("#work-item-explore-gate-go") |> render_click()
      view |> form("#spend-dialog-form") |> render_submit()

      assert track_decisions(work_item) == [{@explore, "fast-track"}]
    end

    test "the pick is kept while the page reads the work item again", %{conn: conn, scope: scope} do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      pick(view, "standard")

      send(view.pid, {:stage_changed, work_item.id})
      render(view)

      assert track_draft(view) == "standard"
      assert has_element?(view, "#work-item-explore-gate-track-standard input[checked]")
    end

    test "typing a comment is no pick of the selected track", %{conn: conn, scope: scope} do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      view
      |> form("#work-item-explore-gate")
      |> render_change(%{
        "comment" => "A note",
        "track" => "fast-track",
        "_target" => ["comment"]
      })

      assert track_draft(view) == nil

      pick(view, "standard")

      view
      |> form("#work-item-explore-gate")
      |> render_change(%{"comment" => "A longer note", "_target" => ["comment"]})

      assert track_draft(view) == "standard"
    end

    test "a pick ends with the stage's gate", %{conn: conn, scope: scope} do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      pick(view, "standard")
      assert track_draft(view) == "standard"

      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      send(view.pid, {:stage_changed, work_item.id})
      render(view)

      assert track_draft(view) == nil
    end

    test "the proposed track is recorded when the member picks none", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))
      refute has_element?(view, "#work-item-explore-gate-go[phx-value-track]")
      view |> element("#work-item-explore-gate-go") |> render_click()
      view |> form("#spend-dialog-form") |> render_submit()

      assert track_decisions(work_item) == [{@explore, "fast-track"}]
    end

    test "a process with no tracks has the gate as before", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(understood_result())

      {:ok, view, _html} = live(conn, page(scope, work_item.number, "/explore"))

      refute has_element?(view, "#work-item-explore-gate-track")
      refute has_element?(view, ~s|#work-item-explore-gate-go[phx-value-track]|)

      assert has_element?(
               view,
               "#work-item-step-line",
               "Approve the proposal, or add a comment and run another round."
             )
    end

    test "Verify's input frame shows a person's version, but the run's for the submit type",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope)

      ran =
        Repo.one(
          from v in Artifacts.Version,
            join: a in Artifacts.Artifact,
            on: a.id == v.artifact_id,
            where: a.work_item_id == ^work_item.id and a.type == "test-features",
            select: v
        )

      {:ok, person} =
        Stages.add_version(
          scope,
          reload(work_item),
          "test-features",
          [%{filename: "test-features.md", content_type: "text/markdown", binary: "## By hand"}],
          name: "main"
        )

      frame = "#work-item-tab-output-test-features"

      # With no submit type, the person's version is a change, and the input frame has it.
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))
      assert has_element?(view, frame, "Version #{person.number}")

      # With test-features as the submit type, the person's version is no change.
      template = %{
        "commit" => String.duplicate("a", 40),
        "submit" => %{"type" => "test-features", "send" => "end_of_run"}
      }

      {_n, _rows} =
        Repo.update_all(
          from(v in Processes.Version, where: v.workspace_id == ^scope.workspace.id),
          set: [template: template]
        )

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))
      assert has_element?(view, frame, "Version #{ran.number}")
      refute has_element?(view, frame, "Version #{person.number}")
    end

    test "only Explore's gate offers tracks: Verify's gate shows the track and no choice", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # The label and the badge are one row.
      assert has_element?(view, "#work-item-stage-gate-path > span", "Track")
      assert has_element?(view, "#work-item-stage-gate-path > .badge", "Fast track")
      assert has_element?(view, "#work-item-stage-gate-track", "Fast track")
      refute has_element?(view, "#work-item-stage-gate input[type=radio]")
      refute has_element?(view, "#work-item-stage-gate-track", "Standard")
      assert has_element?(view, "#work-item-stage-gate-approve-go", "Approve")
      refute has_element?(view, "#work-item-stage-gate-approve-go", "Approve Verify")
    end

    test "the stage track marks the stage that was passed over, not run", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stages-#{@shape}-not-run", "Not run")
      refute has_element?(view, "#work-item-head-stages-#{@build}-not-run")
    end

    test "Shape's tab says it did not run, and why", %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert has_element?(view, "#work-item-tab-passed-over-h", "Shape did not run")

      assert has_element?(
               view,
               "#work-item-tab-passed-over-why",
               "approved Fast track at Explore's gate"
             )

      assert has_element?(view, "#work-item-tab-passed-over-why", "Fast track skips Shape.")
    end

    test "Shape's tab says which proposal version the next stages work to", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert has_element?(
               view,
               "#work-item-tab-passed-over-proposal",
               "The exact change in proposal v1 is the work item's one criterion."
             )

      assert Gettext.with_locale(ApiaryWeb.Gettext, "en", fn ->
               Gettext.dgettext(
                 ApiaryWeb.Gettext,
                 "default",
                 "Proposal v%{version}, as approved, is what the next stages work to.",
                 version: "1"
               )
             end) ==
               "Proposal v1, as approved, is what the next stages work to."
    end

    test "Shape's tab has no such line where Explore's approval lists no proposal version", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {_n, _rows} =
        Repo.update_all(from(d in Stages.GateDecision, where: d.work_item_id == ^work_item.id),
          set: [versions: []]
        )

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert has_element?(view, "#work-item-tab-passed-over-h", "Shape did not run")
      refute has_element?(view, "#work-item-tab-passed-over-proposal")
    end

    test "the line of the proposal version is on Shape's tab only", %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      refute has_element?(view, "#work-item-tab-passed-over-proposal")
    end

    test "Build's tab lists every entry, with the entries that did not run", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      assert has_element?(
               view,
               "#work-item-tab-entries-track",
               "Track: Fast track, approved at Explore's gate"
             )

      assert has_element?(view, "#work-item-tab-entries-row-0", "Fast track implementation")
      assert has_element?(view, "#work-item-tab-entries-row-0", "build-it")
      assert has_element?(view, "#work-item-tab-entries-row-0", "Passed")
      assert has_element?(view, "#work-item-tab-entries-row-0", "Runs on Fast track.")
      assert has_element?(view, "#work-item-tab-entries-row-0", "Attempt")

      first_attempt =
        "Did not run, because Fast track implementation passed on its first attempt."

      assert has_element?(view, "#work-item-tab-entries-row-1", "shape-a-ticket")
      assert has_element?(view, "#work-item-tab-entries-row-1", "Not run")
      assert has_element?(view, "#work-item-tab-entries-row-1", first_attempt)
      refute has_element?(view, "#work-item-tab-entries-row-1", "Runs on Standard only.")

      assert has_element?(view, "#work-item-tab-entries-row-2", "Loop of up to 3 rounds")
      assert has_element?(view, "#work-item-tab-entries-row-2", "Not run")
      assert has_element?(view, "#work-item-tab-entries-row-2", first_attempt)

      assert has_element?(
               view,
               "#work-item-tab-entries-gate",
               "Approved without a member: Build's gate needs no member."
             )
    end

    test "an entry that a passed first attempt passed over reads the reason where it has no condition",
         %{conn: conn, scope: scope} do
      screens!(scope, [
        %{"workflow" => "build-it", "first_attempt" => true, "name" => "Quick fix"},
        %{"workflow" => "shape-a-ticket"}
      ])

      work_item = scope |> taken_in_fixture() |> end_run!(proposing("fast-track"))
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      assert has_element?(view, "#work-item-tab-entries-row-0", "Quick fix")

      assert has_element?(
               view,
               "#work-item-tab-entries-row-1",
               "Did not run, because Quick fix passed on its first attempt."
             )
    end

    test "the reason of a first attempt shows where the entry also has a condition", %{
      conn: conn,
      scope: scope
    } do
      screens!(scope, [
        %{"workflow" => "build-it", "first_attempt" => true, "name" => "Quick fix"},
        %{"workflow" => "shape-a-ticket", "when" => %{"track" => "fast-track"}}
      ])

      work_item = scope |> taken_in_fixture() |> end_run!(proposing("fast-track"))
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      assert has_element?(view, "#work-item-tab-entries-row-1", "Not run")

      assert has_element?(
               view,
               "#work-item-tab-entries-row-1",
               "Did not run, because Quick fix passed on its first attempt."
             )

      refute has_element?(view, "#work-item-tab-entries-row-1", "Runs on Fast track")
    end

    test "a sequence that names one workflow twice keeps the fold's rows and has no table", %{
      conn: conn,
      scope: scope
    } do
      screens!(scope, [
        %{"workflow" => "build-it", "first_attempt" => true},
        %{"workflow" => "shape-a-ticket", "when" => %{"track" => "standard"}},
        %{"workflow" => "shape-a-ticket", "when" => %{"track" => "standard"}}
      ])

      work_item = scope |> taken_in_fixture() |> end_run!(proposing("fast-track"))
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      refute has_element?(view, "#work-item-tab-entries")
      assert has_element?(view, "[id^=work-item-record-skip-]", "shape-a-ticket")
    end

    test "a work item on no track keeps the outputs of a gate where no run started", %{
      conn: conn,
      scope: scope
    } do
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @shape} = stage ->
            %{stage | "outputs" => [%{"type" => "test-features", "required" => false}]}

          %{"id" => @build} = stage ->
            Map.merge(stage, %{
              "sequence" => [
                %{"workflow" => "shape-a-ticket", "when" => %{"input" => "test-features"}}
              ],
              "outputs" => [],
              "gate" => %{"kind" => "person", "approvers" => "members"}
            })

          stage ->
            stage
        end)

      {:ok, _version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
      work_item = at_shape!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @build, nil, expect_stage: @shape)

      assert [%{workflow: "shape-a-ticket"}] = Stages.skips(reload(work_item))
      assert Stages.track(reload(work_item)) == nil

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-stage-gate-track")
      refute has_element?(view, "#work-item-stage-gate-no-run")
      assert has_element?(view, "#work-item-stage-gate-none", "This stage has no outputs.")
    end

    test "the table words each state of a run in sentence case" do
      states = [
        passed: "Passed",
        paused: "Paused",
        failed: "Did not pass",
        questions: "Questions",
        queued: "Queued",
        running: "Running",
        no_verdict: "Ended without a verdict",
        undone: "Undone"
      ]

      entries =
        for {{shows, _word}, i} <- Enum.with_index(states) do
          %{
            item: %{"workflow" => "flow-#{i}"},
            kind: :entry,
            name: "flow-#{i}",
            note: nil,
            rounds: nil,
            attempt: i + 1,
            shows: shows,
            skip: nil
          }
        end

      html =
        render_component(&ApiaryWeb.WorkItemComponents.stage_tab/1,
          stage: %{name: "Build", id: @build, outputs: [], gate: %{"kind" => "none"}},
          work_item: %{number: 1, status: :confirm, run: nil},
          entries: entries,
          current: true
        )

      for {{_shows, word}, i} <- Enum.with_index(states) do
        row =
          html |> LazyHTML.from_fragment() |> LazyHTML.query("#work-item-tab-entries-row-#{i}")

        assert row |> LazyHTML.text() |> String.contains?(word)
      end

      table =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#work-item-tab-entries-table th")

      assert table |> LazyHTML.attribute("scope") == ["col", "col", "col"]
    end

    test "a work item on no track keeps the runs fold's rows and has no table", %{
      conn: conn,
      scope: scope
    } do
      document = Processes.default_document("software")

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @build} = stage ->
            %{
              stage
              | "sequence" => [
                  %{"workflow" => "build-it", "first_attempt" => true},
                  %{"workflow" => "shape-a-ticket"}
                ]
            }

          stage ->
            stage
        end)

      {:ok, _version} = Processes.save(scope, scope.workspace, %{document | "stages" => stages})
      work_item = at_shape!(scope)
      {:ok, _moved} = Stages.move(scope, work_item, @build, nil, expect_stage: @shape)
      work_item |> reload() |> end_run!(fn run, _registered -> passed!(run) end)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @build))

      refute has_element?(view, "#work-item-tab-entries")
      assert has_element?(view, "[id^=work-item-record-skip-]", "shape-a-ticket")
    end

    test "a stage with no entry that did not run has no table", %{conn: conn, scope: scope} do
      work_item = at_gate!(scope)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number))

      refute has_element?(view, "#work-item-tab-entries")
    end

    test "the person's gate has what the person decides first, then the build report", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {:ok, view, html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(
               view,
               "#work-item-stage-gate-no-run",
               "Read the build report below, then approve."
             )

      refute html =~ "started no run"

      assert Gettext.with_locale(ApiaryWeb.Gettext, "en", fn ->
               Gettext.dgettext(
                 ApiaryWeb.Gettext,
                 "default",
                 "Read the inputs below, then approve."
               )
             end) == "Read the inputs below, then approve."

      refute has_element?(view, "#work-item-stage-gate-none")
      refute has_element?(view, "#work-item-stage-gate-outputs")
      assert has_element?(view, "#work-item-tab-output-test-features-fold")
      assert has_element?(view, "#work-item-tab-output-test-features-text", "The report text")

      [gate, report] =
        String.split(html, ~s(id="work-item-tab-output-test-features"), parts: 2)

      assert gate =~ ~s(id="work-item-stage-gate-approve-go")
      assert report =~ "The report text"
    end

    test "with a verification output, a person's picture has the Scenarios frame, open, " <>
           "then the build report, folded",
         %{conn: conn, scope: scope} do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "verification",
          "base_view" => "document"
        })

      screens!(scope, nil,
        verify_outputs: [
          %{"type" => "verification", "required" => false},
          %{"type" => "screenshot", "required" => false}
        ]
      )

      work_item = scope |> taken_in_fixture() |> end_run!(proposing("fast-track"))
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")

      work_item =
        work_item
        |> reload()
        |> end_run!(fn run, _registered ->
          push!(run, work_item, "test-features", "## The report text")
          passed!(run)
        end)
        |> reload()

      {:ok, _version} =
        Stages.add_version(
          scope,
          work_item,
          "screenshot",
          [
            %{
              filename: "phone-check-step-1.png",
              content_type: "image/png",
              binary: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
            }
          ],
          name: "phone-check"
        )

      {:ok, view, html} = live(conn, stage(scope, work_item.number, @verify))
      short = ApiaryWeb.People.short(scope.user.email)

      assert has_element?(view, "#work-item-stage-gate-no-run")
      assert has_element?(view, "#work-item-tab-output-screenshot-h", "Scenarios")
      assert has_element?(view, "#work-item-tab-output-screenshot-fold[open]")

      assert has_element?(
               view,
               "#work-item-tab-scenarios-screenshot--phone-check---caption",
               "Version 1 · #{short}"
             )

      assert has_element?(view, "#work-item-tab-output-test-features-fold")
      refute has_element?(view, "#work-item-tab-output-test-features-fold[open]")

      [scenarios, _report] =
        String.split(html, ~s(id="work-item-tab-output-test-features"), parts: 2)

      assert scenarios =~ ~s(id="work-item-tab-output-screenshot")
    end

    test "a workspace of another domain reads the engine's wording on Verify's gate and Shape's tab",
         %{conn: conn, scope: scope} do
      work_item = at_verify_gate!(scope)
      scope = with_domain(scope, "example")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(
               view,
               "#work-item-stage-gate-no-run",
               "Read the inputs below, then approve."
             )

      refute has_element?(view, "#work-item-stage-gate-no-run", "build report")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      assert has_element?(
               view,
               "#work-item-tab-passed-over-proposal",
               "Proposal v1, as approved, is what the next stages work to."
             )

      refute has_element?(view, "#work-item-tab-passed-over-proposal", "exact change")
    end

    test "Approve at Verify's gate passes the stage with the track the work item is on", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_verify_gate!(scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert [{@explore, "fast-track"}, {_build, nil}, {_verify, nil}] =
               track_decisions(work_item)
    end

    test "on Standard, Shape runs and its tab has no pass-over block", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_explore_gate!(scope)
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @shape))

      refute has_element?(view, "#work-item-tab-passed-over")
      refute has_element?(view, "#work-item-head-stages-#{@shape}-not-run")
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

  describe "the full test suite line under the build report" do
    defp suite_tab(suite, extra \\ []) do
      render_component(
        &ApiaryWeb.WorkItemComponents.stage_tab/1,
        Keyword.merge(
          [
            stage: %{name: "Verify", outputs: []},
            work_item: %{number: 1, status: :confirm, run: nil},
            outputs: [%{type: "build-report", version: 1, open: true, read: nil}],
            suite: suite && Map.merge(%{reason: nil, fast: false}, suite)
          ],
          extra
        )
      )
    end

    defp suite_line(html) do
      case Regex.run(~r/<p[^>]*id="work-item-suite-line"[^>]*>\s*(.*?)\s*<\/p>/s, html) do
        [_all, text] -> text
        nil -> nil
      end
    end

    defp counts(state, fast \\ false),
      do: %{state: state, passed: 412, failed: 3, skipped: 5, minutes: 6, fast: fast}

    test "on the Standard track a passed or failed suite has its counts and its minutes" do
      assert suite_tab(counts(:passed)) |> suite_line() ==
               "The full test suite passed on that commit: 412 passed, 3 failed, 5 skipped, in 6 minutes."

      assert suite_tab(counts(:failed)) |> suite_line() ==
               "The full test suite failed on that commit: 412 passed, 3 failed, 5 skipped, in 6 minutes."
    end

    test "counts of 0 are shown as 0, not left out as absent counts" do
      zero = %{passed: 0, failed: 0, skipped: 0, minutes: 6}

      assert suite_tab(Map.merge(counts(:passed), zero)) |> suite_line() ==
               "The full test suite passed on that commit: 0 passed, 0 failed, 0 skipped, in 6 minutes."

      assert suite_tab(Map.merge(counts(:failed, true), zero)) |> suite_line() ==
               "The full test suite failed: 0 passed, 0 failed, 0 skipped."
    end

    test "a result with no counts has the minutes on the Standard track, and nothing on the Fast" do
      none = %{passed: nil, failed: nil, skipped: nil, minutes: 6}

      for {state, word} <- [passed: "passed", failed: "failed"] do
        standard = Map.merge(counts(state), none)

        assert suite_tab(standard) |> suite_line() ==
                 "The full test suite #{word} on that commit, in 6 minutes."

        assert suite_tab(%{standard | minutes: 1}) |> suite_line() ==
                 "The full test suite #{word} on that commit, in 1 minute."

        assert suite_tab(%{standard | minutes: 1.0}) |> suite_line() ==
                 "The full test suite #{word} on that commit, in 1 minute."

        assert suite_tab(%{standard | minutes: 0.25}) |> suite_line() ==
                 "The full test suite #{word} on that commit, in 0.25 minutes."

        assert suite_tab(%{standard | fast: true}) |> suite_line() ==
                 "The full test suite #{word}."
      end
    end

    test "on the Fast track a passed or failed suite has its counts and no minutes" do
      assert suite_tab(counts(:passed, true)) |> suite_line() ==
               "The full test suite passed: 412 passed, 3 failed, 5 skipped."

      assert suite_tab(counts(:failed, true)) |> suite_line() ==
               "The full test suite failed: 412 passed, 3 failed, 5 skipped."
    end

    test "minutes are one minute for exactly 1, and minutes for any other number" do
      for {minutes, words} <- [
            {1, "in 1 minute."},
            {1.0, "in 1 minute."},
            {0.25, "in 0.25 minutes."},
            {0, "in 0 minutes."},
            {12, "in 12 minutes."},
            {6.0, "in 6 minutes."},
            {4.5, "in 4.5 minutes."}
          ] do
        for state <- [:passed, :failed] do
          line = suite_tab(%{counts(state) | minutes: minutes}) |> suite_line()
          assert line =~ ~r/#{Regex.escape(words)}$/, "#{state} #{inspect(minutes)}: #{line}"
        end
      end
    end

    test "a suite that did not run shows its reason, on any track" do
      for fast <- [false, true] do
        suite = %{state: :not_run, reason: "the repository has no test command", fast: fast}

        assert suite_tab(suite) |> suite_line() ==
                 "The full test suite did not run: the repository has no test command."
      end

      document = %{state: :not_run, reason: "a change to a document runs no tests", fast: true}

      assert suite_tab(document) |> suite_line() ==
               "The full test suite did not run: a change to a document runs no tests."
    end

    test "a reason ends in a full stop, except after a question mark or an exclamation mark" do
      for {reason, line} <- [
            {"no test command", "The full test suite did not run: no test command."},
            {"Wait..", "The full test suite did not run: Wait..."},
            {"Is it?", "The full test suite did not run: Is it?"},
            {"Stop!", "The full test suite did not run: Stop!"}
          ] do
        assert suite_tab(%{state: :not_run, reason: reason}) |> suite_line() == line
      end
    end

    test "only the track fast-track has the Fast track words" do
      assert StageTab.fast_track?(%{track: %{id: "fast-track", name: "Fast track"}})
      refute StageTab.fast_track?(%{track: %{id: "standard", name: "Standard"}})
      refute StageTab.fast_track?(%{track: %{id: "express", name: "Express"}})
      refute StageTab.fast_track?(%{track: nil})
      refute StageTab.fast_track?(%{})
    end

    test "a reason is text: markup in it is escaped" do
      html = suite_tab(%{state: :not_run, reason: "<script>alert(1)</script> & <b>x</b>"})

      refute html =~ "<script>alert"
      refute html =~ "<b>x</b>"

      assert suite_line(html) ==
               "The full test suite did not run: &lt;script&gt;alert(1)&lt;/script&gt; &amp; &lt;b&gt;x&lt;/b&gt;."
    end

    test "no suite result, no line" do
      refute suite_tab(nil) =~ "work-item-suite-line"
      refute suite_tab(nil) =~ "The full test suite"
    end

    test "no build report frame, no line" do
      html =
        suite_tab(counts(:passed), outputs: [%{type: "spec", version: 1, open: true, read: nil}])

      refute html =~ "work-item-suite-line"
    end

    test "the line is under the build report's frame, not in it, and before the next frame" do
      html =
        suite_tab(counts(:passed),
          outputs: [
            %{type: "build-report", version: 1, open: true, read: nil},
            %{type: "spec", version: 1, open: false, read: nil}
          ]
        )

      report = :binary.match(html, ~s(id="work-item-tab-output-build-report")) |> elem(0)
      line = :binary.match(html, ~s(id="work-item-suite-line")) |> elem(0)
      spec = :binary.match(html, ~s(id="work-item-tab-output-spec")) |> elem(0)

      assert report < line and line < spec

      # The frame closed before the line.
      between = binary_part(html, report, line - report)
      assert between =~ "</section>"
    end
  end

  describe "the full test suite line at Verify's gate" do
    # A work item at Verify's gate on `track`, whose Build run wrote a build report and a
    # verdict with `suite` as its full_suite (nil for none). Shape and Verify's workflow
    # run on a track no work item is on, and Build's run on both.
    defp report_gate!(scope, suite, track \\ "fast-track") do
      screens!(scope, [%{"workflow" => "build-it"}], report: "build-report")
      document = Processes.current(scope.workspace).document

      stages =
        Enum.map(document["stages"], fn
          %{"id" => @explore, "gate" => gate} = stage ->
            %{stage | "gate" => Map.update!(gate, "tracks", &(&1 ++ ["manual"]))}

          %{"id" => @shape} = stage ->
            Map.put(stage, "when", %{"track" => "manual"})

          %{"id" => @verify} = stage ->
            %{
              stage
              | "sequence" => [
                  %{"workflow" => "shape-a-ticket", "when" => %{"track" => "manual"}}
                ]
            }

          stage ->
            stage
        end)

      tracks = document["tracks"] ++ [%{"id" => "manual", "name" => "Manual"}]

      {:ok, _version} =
        Processes.save(scope, scope.workspace, %{
          document
          | "stages" => stages,
            "tracks" => tracks
        })

      work_item = scope |> taken_in_fixture() |> end_run!(proposing(track))
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: track)

      work_item
      |> reload()
      |> end_run!(fn run, _registered ->
        push!(run, work_item, "build-report", "## The report text")
        verdict = %{"verdict" => "passed"}

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            if(suite, do: Map.put(verdict, "full_suite", suite), else: verdict),
            stage_id: run.stage_id
          )
      end)
      |> reload()
    end

    setup %{scope: scope} do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "build-report",
          "base_view" => "document",
          "size_limit" => 1_048_576,
          "max_files" => 1
        })

      :ok
    end

    test "a work item on the Fast track shows the Fast track line from the verdict", %{
      conn: conn,
      scope: scope
    } do
      suite = %{
        "state" => "passed",
        "passed" => 412,
        "failed" => 0,
        "skipped" => 3,
        "minutes" => 6
      }

      work_item = report_gate!(scope, suite)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(view, "#work-item-tab-output-build-report")

      assert has_element?(
               view,
               "#work-item-suite-line",
               "The full test suite passed: 412 passed, 0 failed, 3 skipped."
             )

      refute has_element?(view, "#work-item-tab-output-build-report #work-item-suite-line")
    end

    test "a work item on the Standard track shows the Standard line, with the minutes", %{
      conn: conn,
      scope: scope
    } do
      suite = %{
        "state" => "failed",
        "passed" => 409,
        "failed" => 3,
        "skipped" => 3,
        "minutes" => 6
      }

      work_item = report_gate!(scope, suite, "standard")

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(
               view,
               "#work-item-suite-line",
               "The full test suite failed on that commit: 409 passed, 3 failed, 3 skipped, in 6 minutes."
             )
    end

    test "a verdict with minutes and no counts shows the Fast track line without counts", %{
      conn: conn,
      scope: scope
    } do
      work_item = report_gate!(scope, %{"state" => "failed", "minutes" => 2})
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(view, "#work-item-suite-line", "The full test suite failed.")
    end

    test "a verdict with minutes and no counts shows the Standard line with the minutes", %{
      conn: conn,
      scope: scope
    } do
      work_item = report_gate!(scope, %{"state" => "passed", "minutes" => 2}, "standard")
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(
               view,
               "#work-item-suite-line",
               "The full test suite passed on that commit, in 2 minutes."
             )
    end

    test "a verdict that did not run the suite shows the reason as sent", %{
      conn: conn,
      scope: scope
    } do
      suite = %{"state" => "not_run", "reason" => "a change to a document runs no tests"}
      work_item = report_gate!(scope, suite)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(
               view,
               "#work-item-suite-line",
               "The full test suite did not run: a change to a document runs no tests."
             )
    end

    test "the page keeps what it read of a verdict file, a result and no result alike", %{
      conn: conn,
      scope: scope
    } do
      suite = %{"state" => "passed", "passed" => 4, "failed" => 0, "skipped" => 0, "minutes" => 2}
      work_item = report_gate!(scope, suite)

      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))
      assigns = :sys.get_state(view.pid).socket.assigns

      [{id, {:ok, %{passed: 4}}}] = Map.to_list(assigns.suite_reads)

      # The kept read is shown again when the frames are read again, whatever the file says.
      kept = {:ok, %{state: :failed, passed: 1, failed: 1, skipped: 0, minutes: 3, reason: nil}}

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns, &%{&1 | suite_reads: %{id => kept}})
      end)

      send(view.pid, {:artifact_pushed, work_item.id, id})

      assert has_element?(
               view,
               "#work-item-suite-line",
               "The full test suite failed: 1 passed, 1 failed, 0 skipped."
             )
    end

    test "a verdict with no result is kept as none", %{conn: conn, scope: scope} do
      work_item = report_gate!(scope, nil)
      {:ok, view, _html} = live(conn, stage(scope, work_item.number, @verify))

      assert [:none] = Map.values(:sys.get_state(view.pid).socket.assigns.suite_reads)
    end

    test "a verdict with no full_suite has no line", %{conn: conn, scope: scope} do
      work_item = report_gate!(scope, nil)

      {:ok, view, html} = live(conn, stage(scope, work_item.number, @verify))

      assert has_element?(view, "#work-item-tab-output-build-report")
      refute has_element?(view, "#work-item-suite-line")
      refute html =~ "The full test suite"
    end
  end
end
