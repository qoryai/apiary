defmodule ApiaryWeb.WorkItemLive.AcceptButtonTest do
  # The escalation card's accept button on the work item page (PIC-846, "846 (a)"): where
  # an accept starts the stage's next entry, the button, its spend dialog and the points
  # that pick it read "Start %{workflow}", with the entry's name in the process, else its
  # workflow (`Apiary.Stages.status/2`'s `accept_entry`); where the accept takes the stage
  # to its gate, they read Accept as it is. Each case is reached through real runs, as
  # the walk's seed reaches it: Build runs plan-the-build, then capture-demo, then a loop
  # of implement-the-change and review-the-change; Verify runs a loop of
  # write-acceptance-checks and review-acceptance-checks, then verify-a-ticket, an entry
  # named "Acceptance test run".
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module
  # is not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.Escalation
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"

  @accept "Accept as it is"
  @card "#work-item-stage-escalation-accept"

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  # Alex approves Build with the owner; Kim is a member who does not.
  setup %{scope: scope} do
    alex = member_fixture(scope).user
    kim = member_fixture(scope).user

    for name <- ~w(spec build-plan build-report acceptance-checks test-report),
        name not in Enum.map(Artifacts.types(scope.workspace), & &1.name) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => name,
          "base_view" => "document",
          "size_limit" => 1_048_576,
          "max_files" => 1
        })
    end

    process!(scope, [scope.user.id, alex.id])
    %{kim: kim}
  end

  describe "an earlier workflow" do
    test "1. escalated on plan-the-build: Start capture-demo", %{conn: conn, scope: scope} do
      work_item = case_one!(scope)
      assert Stages.starts(work_item, :accept) == {:run, "capture-demo"}

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, @card) == "Start capture-demo"
      refute render(view) =~ @accept

      assert texts(view, "#work-item-needs-points li") == [
               "The ticket does not say how close to the start a member may still cancel a " <>
                 "booking. Run another round."
             ]
    end

    test "2. the dialog: Start capture-demo? and Start capture-demo; the line is kept",
         %{conn: conn, scope: scope} do
      work_item = case_one!(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = runs(work_item)

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "accept"})

      assert line(view, "#spend-dialog-title") == "Start capture-demo?"
      assert line(view, "#spend-dialog-go") == "Start capture-demo"

      assert line(view, "#spend-dialog-line") ==
               "Starts a run of capture-demo on a machine. The run uses model tokens."

      refute render(view) =~ @accept

      view |> form("#spend-dialog-form") |> render_submit()

      assert %Escalation{resolution: :accept} = escalation(work_item)
      assert runs(work_item) == before + 1
      assert %DispatchRun{workflow: "capture-demo"} = newest_run(work_item)
    end

    test "3. the next entry is a loop: Start implement-the-change, the loop's first workflow",
         %{conn: conn, scope: scope} do
      work_item = case_two!(scope)
      assert Stages.starts(work_item, :accept) == {:run, "implement-the-change"}

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, @card) == "Start implement-the-change"
      refute render(view) =~ @accept

      assert texts(view, "#work-item-needs-points li") == [
               "The preview's booking site has no courts, so the demo shows an empty week. " <>
                 "Run another round."
             ]

      assert_dialog(view, "Start implement-the-change", "implement-the-change")
    end

    test "4. the next entry has a name: Start Acceptance test run, in the button and the fix",
         %{conn: conn, scope: scope} do
      work_item = case_three!(scope)
      assert Stages.starts(work_item, :accept) == {:run, "verify-a-ticket"}

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, @card) == "Start Acceptance test run"
      refute render(view) =~ @accept

      assert texts(view, "#work-item-needs-points li") == [
               "2 of 2 rounds ran, and 2 review findings are still open. Check ac-2 books a " <>
                 "doubles game but does not check that four players are named. Check ac-4 " <>
                 "runs on a weekday only, and the club opens doubles slots at weekends. Read " <>
                 "the 2 open findings, then pick Start Acceptance test run or Run another round."
             ]

      # The dialog line has the workflow the run starts.
      assert_dialog(view, "Start Acceptance test run", "verify-a-ticket")
    end

    test "4, stored before PIC-846: a round limit's point with no count picks Run another round",
         %{conn: conn, scope: scope} do
      work_item = case_three!(scope)
      %Escalation{points: [point]} = escalated = escalation(work_item)

      escalated
      |> Ecto.Changeset.change(points: [Map.delete(point, "open_findings")])
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, @card) == "Start Acceptance test run"
      refute render(view) =~ @accept

      assert [text] = texts(view, "#work-item-needs-points li")
      assert text =~ ~r/ Read the 2 open findings, then pick Run another round\.$/
    end

    test "8. a return limit on capture-demo: the action picks Start implement-the-change",
         %{conn: conn, scope: scope} do
      work_item = case_return_limit!(scope)
      assert %Escalation{cause: :return_limit} = escalation(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, @card) == "Start implement-the-change"
      assert has_element?(view, "#work-item-stage-escalation-move", "Move back")
      refute render(view) =~ @accept

      assert texts(view, "#work-item-needs-points li") == [
               "Pick Move back to return the work item to Shape once more, or pick Start " <>
                 "implement-the-change. Build's run asked for changes again after 1 return " <>
                 "to Shape, the most that Build allows.",
               "The spec does not say who gets the court when two members wait for it. Run " <>
                 "another round."
             ]

      assert_dialog(view, "Start implement-the-change", "implement-the-change")
    end
  end

  describe "the last workflow" do
    test "5. every required output stored: Accept as it is, and the fix picks it",
         %{conn: conn, scope: scope} do
      work_item = case_last_loop!(scope, true)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert line(view, @card) == @accept
      refute render(view) =~ "Start "

      assert texts(view, "#work-item-needs-points li") == [
               "2 of 2 rounds ran, and 2 review findings are still open. The block leaves " <>
                 "in place the bookings that members made before it. The block's end time " <>
                 "ignores the club's time zone. Read the 2 open findings, then pick Accept " <>
                 "as it is or Run another round."
             ]

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "accept"})

      # The accept takes Build to its gate: no run, no dialog.
      refute has_element?(view, "#spend-dialog")
      assert %Escalation{resolution: :accept} = escalation(work_item)
    end

    test "6. a required output missing: no accept button, and the fix leaves it out",
         %{conn: conn, scope: scope} do
      work_item = case_last_loop!(scope, false)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, @card)
      refute render(view) =~ @accept
      refute render(view) =~ "Start "

      assert texts(view, "#work-item-needs-points li") == [
               "2 of 2 rounds ran, and 2 review findings are still open. The block leaves " <>
                 "in place the bookings that members made before it. The block's end time " <>
                 "ignores the club's time zone. Read the 2 open findings, then pick Run " <>
                 "another round."
             ]
    end

    test "7. a member who may not decide: no buttons, and who decides", %{
      scope: scope,
      kim: kim
    } do
      work_item = case_last_loop!(scope, true)
      {:ok, view, _html} = live(log_in_user(build_conn(), kim), page(scope, work_item.number))

      refute has_element?(view, @card)
      refute has_element?(view, "#work-item-stage-escalation-form")
      refute render(view) =~ @accept
      refute render(view) =~ "Start "

      assert [point] = texts(view, "#work-item-needs-points li")

      assert point =~
               ~r/^2 of 2 rounds ran, and 2 review findings are still open\. .* An approver of Build decides: .+\.$/
    end
  end

  # Opens the accept's dialog: its title and button read `label`, and its line has the
  # workflow of the run, `workflow`.
  defp assert_dialog(view, label, workflow) do
    view
    |> form("#work-item-stage-escalation-form", %{"note" => ""})
    |> render_submit(%{"how" => "accept"})

    assert line(view, "#spend-dialog-title") == "#{label}?"
    assert line(view, "#spend-dialog-go") == label

    assert line(view, "#spend-dialog-line") ==
             "Starts a run of #{workflow} on a machine. The run uses model tokens."

    refute render(view) =~ @accept
  end

  ## The cases, as the walk's seed reaches them

  # 1. Build escalated on plan-the-build, which stored a build plan; next: capture-demo.
  defp case_one!(scope) do
    scope
    |> at_build!()
    |> end_run!(fn run, registered ->
      stored!(run, "build-plan", "## Build plan\n\nAdd Cancel booking to My bookings.\n")

      verdict(
        "escalate",
        [
          again(
            "The ticket does not say how close to the start a member may still cancel a booking."
          )
        ]
      ).(run, registered)
    end)
    |> escalated!()
  end

  # 2. Build escalated on capture-demo; plan-the-build passed; next: the loop.
  defp case_two!(scope) do
    scope
    |> at_build!()
    |> end_run!(fn run, registered ->
      stored!(run, "build-plan", "## Build plan\n\nAdd a week view of the free courts.\n")
      verdict("passed").(run, registered)
    end)
    |> reload()
    |> end_run!(
      verdict("escalate", [
        again("The preview's booking site has no courts, so the demo shows an empty week.")
      ])
    )
    |> escalated!()
  end

  # 3. Build passes and is approved; Verify's loop reaches its round limit with two open
  # findings; next: verify-a-ticket, the entry "Acceptance test run".
  defp case_three!(scope) do
    work_item = scope |> at_build!() |> build_passes!()
    {:ok, _at_verify} = Stages.approve(scope, reload(work_item), nil, expect_stage: @build)

    findings = [
      again("Check ac-2 books a doubles game but does not check that four players are named."),
      again("Check ac-4 runs on a weekday only, and the club opens doubles slots at weekends.")
    ]

    Enum.reduce(1..2, reload(work_item), fn _round, work_item ->
      work_item
      # In a loop, `passed` leaves the loop: the writer ends with no verdict.
      |> end_run!(fn run, _registered ->
        stored!(run, "acceptance-checks", "## Acceptance checks\n\n1. Book a doubles game.\n")
      end)
      |> reload()
      |> end_run!(verdict("changes-requested", findings))
      |> reload()
    end)
    |> escalated!(@verify)
  end

  # 5, 6 and 7. Build's last loop reaches its round limit with two open findings; the
  # build report is stored (`report`) or not.
  defp case_last_loop!(scope, report) do
    findings = [
      again("The block leaves in place the bookings that members made before it."),
      again("The block's end time ignores the club's time zone.")
    ]

    work_item =
      scope
      |> at_build!()
      |> end_run!(fn run, registered ->
        stored!(run, "build-plan", "## Build plan\n\nBlock courts for a weekend.\n")
        verdict("passed").(run, registered)
      end)
      |> reload()
      |> end_run!(verdict("passed"))
      |> reload()

    Enum.reduce(1..2, work_item, fn _round, work_item ->
      work_item
      # In a loop, `passed` leaves the loop: the change ends with no verdict.
      |> end_run!(fn run, _registered ->
        if report,
          do: stored!(run, "build-report", "## Build report\n\nTests: 212 passed, 0 failed.\n")
      end)
      |> reload()
      |> end_run!(verdict("changes-requested", findings))
      |> reload()
    end)
    |> escalated!()
  end

  # 8. capture-demo asks for changes, which returns the work item to Shape (its return
  # key, limit 1); after Shape's next run and approval, capture-demo asks for changes
  # again: Build escalates at its return limit; next: the loop.
  defp case_return_limit!(scope) do
    capture = fn work_item ->
      work_item
      |> end_run!(fn run, registered ->
        stored!(run, "build-plan", "## Build plan\n\nAdd Join the waiting list.\n")
        verdict("passed").(run, registered)
      end)
      |> reload()
      |> end_run!(
        verdict("changes-requested", [
          again("The spec does not say who gets the court when two members wait for it.")
        ])
      )
      |> reload()
    end

    work_item = scope |> at_build!() |> capture.()
    assert %WorkItem{stage_id: @shape, stage_state: :running} = work_item

    work_item =
      end_run!(work_item, fn run, registered ->
        stored!(run, "spec", "## Spec\n\nThe member who joined first gets the court.\n")
        verdict("passed").(run, registered)
      end)

    {:ok, _at_build} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)
    work_item |> reload() |> capture.() |> escalated!()
  end

  # Build's whole sequence passes: plan, demo, and one round of the loop with the build
  # report.
  defp build_passes!(work_item) do
    work_item
    |> end_run!(fn run, registered ->
      stored!(run, "build-plan", "## Build plan\n\nAdd a doubles option.\n")
      verdict("passed").(run, registered)
    end)
    |> reload()
    |> end_run!(verdict("passed"))
    |> reload()
    |> end_run!(fn run, _registered ->
      stored!(run, "build-report", "## Build report\n\nTests: 198 passed, 0 failed.\n")
    end)
    |> reload()
    |> end_run!(verdict("passed"))
    |> reload()
  end

  # A work item through Explore and Shape, with Build's first run queued.
  defp at_build!(scope) do
    work_item =
      scope
      |> taken_in_fixture()
      |> end_run!(fn run, registered ->
        Apiary.WorkItemsFixtures.push_result!(
          run,
          registered,
          Apiary.WorkItemsFixtures.understood_result()
        )

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{
              "verdict" => "passed",
              "track" => %{"id" => "standard", "reason" => "The change adds a rule."}
            },
            stage_id: run.stage_id
          )
      end)

    {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1, track: "standard")

    work_item =
      work_item
      |> reload()
      |> end_run!(fn run, registered ->
        stored!(run, "spec", "## Spec\n\nThe change.\n")
        verdict("passed").(run, registered)
      end)

    {:ok, _at_build} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)
    work_item = reload(work_item)
    assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
    work_item
  end

  defp escalated!(work_item, stage_id \\ @build) do
    work_item = reload(work_item)
    assert %WorkItem{stage_id: ^stage_id, stage_state: :escalated} = work_item
    work_item
  end

  # The walk's process: Explore's gate offers the track Standard; Shape writes a spec;
  # Build and Verify as the module's head describes them, Build with its return key to
  # Shape (limit 1) on capture-demo and its gate approved by `approvers`.
  defp process!(scope, approvers) do
    document = Processes.default_document("software")

    stages =
      Enum.map(document["stages"], fn
        %{"id" => @explore, "gate" => gate} = stage ->
          %{stage | "gate" => Map.put(gate, "tracks", ["standard"])}

        %{"id" => @shape} = stage ->
          Map.merge(stage, %{
            "sequence" => [%{"workflow" => "shape-a-ticket"}],
            "outputs" => [%{"type" => "spec", "required" => false}],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          })

        %{"id" => @build} = stage ->
          Map.merge(stage, %{
            "inputs" => [%{"type" => "spec", "required" => false}],
            "sequence" => [
              %{"workflow" => "plan-the-build"},
              %{"workflow" => "capture-demo", "return" => %{"stage" => @shape, "limit" => 1}},
              loop(["implement-the-change", "review-the-change"])
            ],
            "outputs" => [
              %{"type" => "build-plan", "required" => false},
              %{"type" => "build-report", "required" => true}
            ],
            "gate" => %{"kind" => "person", "approvers" => %{"members" => approvers}}
          })

        %{"id" => @verify} = stage ->
          Map.merge(stage, %{
            "inputs" => [%{"type" => "build-report", "required" => false}],
            "sequence" => [
              loop(["write-acceptance-checks", "review-acceptance-checks"]),
              %{"workflow" => "verify-a-ticket", "name" => "Acceptance test run"}
            ],
            "outputs" => [
              %{"type" => "acceptance-checks", "required" => false},
              %{"type" => "test-report", "required" => true}
            ],
            "gate" => %{"kind" => "person", "approvers" => "members"}
          })

        stage ->
          stage
      end)

    document =
      document
      |> Map.put("stages", stages)
      |> Map.put("tracks", [
        %{
          "id" => "standard",
          "name" => "Standard",
          "description" => "Shape writes a spec. Build plans, demos and makes the change."
        }
      ])

    {:ok, _version} = Processes.save(scope, scope.workspace, document)
  end

  defp loop(workflows),
    do: %{"loop" => %{"rounds" => 2, "body" => Enum.map(workflows, &%{"workflow" => &1})}}

  defp stored!(run, type, text) do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        type,
        [%{filename: "#{type}.md", content_type: "text/markdown", binary: text}],
        name: "main",
        stage_id: run.stage_id
      )

    version
  end

  # The end of a run that pushes the verdict `verdict`, with `points` where given.
  defp verdict(verdict, points \\ nil) do
    document =
      if points,
        do: %{"verdict" => verdict, "points" => points},
        else: %{"verdict" => verdict}

    fn run, _registered ->
      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "verdict",
          document,
          stage_id: run.stage_id
        )
    end
  end

  defp again(text), do: %{"text" => text, "action" => "run_again"}

  defp reload(%WorkItem{id: id}), do: Repo.get!(WorkItem, id)

  defp escalation(work_item),
    do:
      Repo.one(
        from e in Escalation,
          where: e.work_item_id == ^work_item.id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp runs(work_item),
    do: Repo.aggregate(from(r in DispatchRun, where: r.work_item_id == ^work_item.id), :count)

  defp page(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"

  # The text of the element `selector`, its whitespace collapsed.
  defp line(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # The texts of the elements `selector` matches, each with its whitespace collapsed.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end
end
