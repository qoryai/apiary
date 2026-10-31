defmodule ApiaryWeb.WorkItemLive.WorkflowTest do
  # The work item page and the board under the workflow model
  # (`ApiaryWeb.WorkItemLive.Workflow`), with `ApiaryWeb.WorkflowFake` in place of
  # `Apiary.Stages` and `Apiary.Artifacts` until they land: without the feature, the
  # page and the list as before it; the stage track; each stage state (running, waiting
  # for inputs, for answers or for a workflow, escalated with each cause, at the gate,
  # done); the runs with their rounds and verdicts; the approval marks; the artifact
  # list; each action, for the owner, an admin and a member, hidden from a person the
  # stage does not list and refused on the server; the page read again on
  # `{:stage_changed, id}`; and the board's columns, a removed stage's included.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module
  # is not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Processes, Repo}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.WorkflowFake

  @moduletag needs: [:factory, :workflow_model]

  setup_all do
    previous = WorkflowFake.install()
    on_exit(fn -> WorkflowFake.uninstall(previous) end)
    :ok
  end

  setup :register_and_log_in_user

  # The stage ids of the software type's default process (`Apiary.Processes`), and one
  # more for a stage a later version removes.
  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  @release "st_k9kpv17xmy"
  @review "st_rev0000000"

  # The default process, with Build's sequence of § 4 and the gate's approvers.
  defp document(approvers \\ "members") do
    default = Processes.default_document("software")

    stages =
      for stage <- default["stages"] do
        if stage["id"] == @build do
          %{
            stage
            | "sequence" => [
                %{"workflow" => "implement"},
                %{
                  "loop" => %{
                    "rounds" => 3,
                    "body" => [
                      %{"workflow" => "capture-demo"},
                      %{"workflow" => "fix-demo-findings"}
                    ]
                  }
                }
              ],
              "gate" => %{"kind" => "person", "approvers" => approvers}
          }
        else
          stage
        end
      end

    %{default | "stages" => stages}
  end

  # A saved version of the scope's workspace with `document`, current; the current one
  # where it has that document already.
  defp save!(scope, document) do
    case Processes.save(scope, scope.workspace, document) do
      {:ok, version} -> version
      {:error, [%{error: :unchanged} | _]} -> Processes.current(scope.workspace)
    end
  end

  defp place!(work_item, version, stage_id) do
    {1, _} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: version.id, stage_id: stage_id]
      )

    Repo.get!(WorkItem, work_item.id)
  end

  # A work item at Build in `state`, on a version with Build's sequence.
  defp at_build(scope, state, attrs \\ []) do
    version = save!(scope, document(Keyword.get(attrs, :approvers, "members")))
    status = Map.new(Keyword.get(attrs, :status, []))
    stage_id = get_in(status, [:stage, "id"]) || @build
    work_item = scope |> work_item_fixture() |> place!(version, stage_id)

    status =
      Map.merge(
        %{
          stage: %{"id" => @build, "name" => "Build"},
          round: 2,
          rounds: 3,
          state: state,
          gaps: nil,
          outputs: [],
          inputs: [],
          escalation: nil,
          gate: %{approvable?: false, approvals: []},
          runs: []
        },
        status
      )

    WorkflowFake.put_work_item(work_item,
      status: status,
      inputs: Keyword.get(attrs, :inputs, []),
      index: Keyword.get(attrs, :index, []),
      artifacts: Keyword.get(attrs, :artifacts, [])
    )

    work_item
  end

  # A work item where the migration of piece F puts an open one: on the workspace's
  # current version, in Explore, or in Shape at its gate.
  defp backfilled!(scope, stage_id, state) do
    work_item = work_item_fixture(scope)

    {1, _} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [
          process_version_id: Processes.current(scope.workspace).id,
          stage_id: stage_id,
          stage_state: state,
          stage_round: 1
        ]
      )

    Repo.get!(WorkItem, work_item.id)
  end

  defp page(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"
  defp list(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/work"

  defp as(conn, scope, :owner), do: {conn, scope}

  defp as(_conn, scope, level) do
    member = member_fixture(scope, level)
    {log_in_user(build_conn(), member.user), member}
  end

  describe "without the feature" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the page has the step card and the stages as before it", %{conn: conn, scope: scope} do
      work_item = backfilled!(scope, @explore, :running)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step")
      assert has_element?(view, "#work-item-head-stages-explore")
      refute has_element?(view, "#work-item-stage")
      refute has_element?(view, "#work-item-flow")
    end

    test "a stage event does nothing", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{"number" => "#{work_item.number}", "note" => ""})
      assert WorkflowFake.calls(work_item) == []
    end

    test "the list has the stages strip and no board", %{conn: conn, scope: scope} do
      backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, "#work-items-stages")
      refute has_element?(view, "#work-items-board")
    end
  end

  describe "the stage track and the runs" do
    test "the process version's stages, the current one marked, and each run", %{
      conn: conn,
      scope: scope
    } do
      runs = [
        %{id: "rn_17", workflow: "capture-demo", round: 2, verdict: "passed", state: :ended},
        %{id: "rn_16", workflow: "fix-demo-findings", round: 1, verdict: nil, state: :ended},
        %{
          id: "rn_15",
          workflow: "capture-demo",
          round: 1,
          verdict: "changes-requested",
          state: :ended
        },
        %{id: "rn_14", workflow: "implement", round: 1, verdict: "escalate", state: :ended},
        %{id: "rn_18", workflow: "capture-demo", round: 3, verdict: nil, state: :running},
        %{id: "rn_13", workflow: "implement", round: 1, verdict: nil, state: :stopped}
      ]

      work_item = at_build(scope, :running, status: [runs: runs])
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
      assert has_element?(view, "#work-item-head-stages-#{@shape}.q-wi-stage-done")
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-todo")
      refute has_element?(view, "#work-item-head-stages-explore")
      refute has_element?(view, "#work-item-step")

      assert has_element?(view, "#work-item-stage-state", "Running")
      assert has_element?(view, "#work-item-stage-round", "Round 2 of 3")
      assert has_element?(view, "#work-item-stage-version", "Process version 2")
      assert has_element?(view, "#work-item-stage-line", "Build is running.")

      assert html =~ "Run rn_17 · capture-demo · round 2 · passed"
      assert html =~ "Run rn_16 · fix-demo-findings · round 1 · no verdict, goes on"
      assert html =~ "Run rn_15 · capture-demo · round 1 · changes requested"
      assert html =~ "Run rn_14 · implement · round 1 · escalated"
      assert html =~ "Run rn_18 · capture-demo · round 3 · running"
      assert html =~ "Run rn_13 · implement · round 1 · stopped"
    end

    test "no run yet, and the artifact list", %{conn: conn, scope: scope} do
      work_item =
        at_build(scope, :running, artifacts: [%{type: "proposal", number: 1}])

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-runs-none", "No run yet.")
      assert has_element?(view, "#work-item-artifact-list", "proposal v1")
    end

    test "done: every stage done", %{conn: conn, scope: scope} do
      work_item =
        at_build(scope, :done, status: [stage: %{"id" => @release, "name" => "Release"}])

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-done")
      assert has_element?(view, "#work-item-stage-line", "Every stage is done.")
    end
  end

  describe "waiting" do
    test "for inputs: what is missing, Add and Move back", %{conn: conn, scope: scope} do
      work_item =
        at_build(scope, :waiting_inputs,
          inputs: [
            %{type: "acceptance-criteria", required: true, version: nil},
            %{type: "mockup", required: false, version: nil}
          ]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for inputs")
      assert has_element?(view, "#work-item-stage-line", "Build needs acceptance criteria")
      refute has_element?(view, "#work-item-stage-input-mockup")

      assert has_element?(
               view,
               ~s|#work-item-stage-add-acceptance-criteria[href="#{page(scope, work_item.number)}/artifacts/new?type=acceptance-criteria"]|
             )

      view
      |> form("#work-item-stage-move", %{"stage" => @shape, "note" => "Write the criteria"})
      |> render_submit()

      assert WorkflowFake.calls(work_item) == [{:move, @shape, "Write the criteria"}]
    end

    test "a move to a stage that is not earlier is refused", %{conn: conn, scope: scope} do
      work_item =
        at_build(scope, :waiting_inputs,
          inputs: [%{type: "acceptance-criteria", required: true, version: nil}]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_move", %{
        "number" => "#{work_item.number}",
        "stage" => @release,
        "note" => ""
      })

      assert WorkflowFake.calls(work_item) == []
    end

    test "for answers: a link to the questions", %{conn: conn, scope: scope} do
      work_item =
        at_build(scope, :waiting_answers,
          status: [stage: %{"id" => @explore, "name" => "Explore"}, round: 1]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for answers")

      assert has_element?(
               view,
               "#work-item-stage-line",
               "Explore waits for answers to the agent's questions."
             )

      assert has_element?(
               view,
               ~s|#work-item-stage-answers[href="#{page(scope, work_item.number)}/explore"]|
             )
    end

    test "for a workflow the harness no longer declares", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for a workflow")

      assert has_element?(
               view,
               "#work-item-stage-workflow-capture-demo",
               "Build uses capture-demo, which the harness no longer declares. Add it to the harness, or choose another workflow for Build."
             )

      assert has_element?(view, "#work-item-stage-workflow-fix-demo-findings")
      assert has_element?(view, "#work-item-stage-workflow-implement")
      refute has_element?(view, "#work-item-stage-workflow-explore-a-ticket")
    end
  end

  describe "at the gate" do
    setup %{scope: scope} do
      outputs = [
        %{
          type: "change",
          required: true,
          version: %{id: "av_c2", number: 2},
          check: :not_checked
        },
        %{type: "demo-video", required: true, version: %{id: "av_d3", number: 3}, check: :passed},
        %{type: "explainer", required: true, version: nil, check: :missing},
        %{type: "decision-record", required: false, version: nil, check: :missing}
      ]

      index = [
        %{type: "demo-video", name: "main", approved: 2, newer: 3, changed_after_approval: false},
        %{
          type: "acceptance-criteria",
          name: "main",
          approved: 2,
          newer: nil,
          changed_after_approval: true
        }
      ]

      work_item =
        at_build(scope, :at_gate,
          status: [outputs: outputs, gate: %{approvable?: true, approvals: []}],
          index: index
        )

      %{work_item: work_item}
    end

    test "each output with its version and check, and the approval marks", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "At the gate")
      assert has_element?(view, "#work-item-stage-gate-output-change", "change v2")

      assert has_element?(
               view,
               "#work-item-stage-gate-check-change",
               "Not checked in this version"
             )

      assert has_element?(view, "#work-item-stage-gate-check-demo-video", "Passed")
      assert has_element?(view, "#work-item-stage-gate-check-explainer", "Missing")
      assert has_element?(view, "#work-item-stage-gate-check-decision-record", "Optional, none")

      assert has_element?(
               view,
               "#work-item-stage-gate-mark-demo-video",
               "Approved v2; v3 is newer"
             )

      assert has_element?(
               view,
               "#work-item-marks-acceptance-criteria-main",
               "Changed after approval"
             )

      assert has_element?(
               view,
               "#work-item-stage-gate-approvers",
               "One approval covers each version. Any member approves."
             )
    end

    for level <- [:owner, :admin, :member] do
      test "#{level}: one Approve, and Request changes about one version", %{
        conn: conn,
        scope: scope,
        work_item: work_item
      } do
        {conn, _who} = as(conn, scope, unquote(level))
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        assert has_element?(view, "#work-item-stage-gate-approve-go", "Approve Build")
        view |> form("#work-item-stage-gate-approve") |> render_submit()
        assert WorkflowFake.calls(work_item) == [{:approve, nil}]

        view |> element("#work-item-stage-gate-ask-changes") |> render_click()

        view
        |> form("#work-item-stage-gate-changes", %{
          "version" => "av_d3",
          "note" => "Show a payment with two gift cards"
        })
        |> render_submit()

        assert List.last(WorkflowFake.calls(work_item)) ==
                 {:request_changes, "Show a payment with two gift cards", "av_d3"}

        refute has_element?(view, "#work-item-stage-gate-changes")
      end
    end

    test "Request changes about a version not at the gate, or without a note, is refused", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      n = "#{work_item.number}"

      render_hook(view, "stage_request_changes", %{
        "number" => n,
        "version" => "av_x",
        "note" => "x"
      })

      render_hook(view, "stage_request_changes", %{"number" => n, "version" => "", "note" => " "})

      assert has_element?(
               view,
               "#work-item-stage-gate-changes-note-error",
               "Write what needs to change."
             )

      assert WorkflowFake.calls(work_item) == []

      render_hook(view, "stage_request_changes", %{
        "number" => n,
        "version" => "",
        "note" => "Redo"
      })

      assert WorkflowFake.calls(work_item) == [{:request_changes, "Redo", nil}]
    end

    test "an event for another number does nothing", %{
      conn: conn,
      scope: scope,
      work_item: work_item
    } do
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      render_hook(view, "stage_approve", %{"number" => "#{work_item.number + 1}", "note" => ""})
      assert WorkflowFake.calls(work_item) == []
    end
  end

  describe "a stage that lists its approvers" do
    test "only a listed member sees Approve; anyone else is refused on the server", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)

      work_item =
        at_build(scope, :at_gate,
          approvers: %{"members" => [listed.user.id]},
          status: [gate: %{approvable?: true, approvals: []}]
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-stage-gate-approve")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")

      assert has_element?(
               view,
               "#work-item-stage-gate-approvers",
               "The members this stage lists approve."
             )

      render_hook(view, "stage_approve", %{"number" => "#{work_item.number}", "note" => ""})

      render_hook(view, "stage_resolve", %{
        "number" => "#{work_item.number}",
        "how" => "accept",
        "note" => ""
      })

      assert WorkflowFake.calls(work_item) == []

      {:ok, view, _html} =
        live(log_in_user(build_conn(), listed.user), page(scope, work_item.number))

      view |> form("#work-item-stage-gate-approve") |> render_submit()
      assert WorkflowFake.calls(work_item) == [{:approve, nil}]
    end
  end

  defp escalated(scope, cause, gaps, attrs \\ []) do
    at_build(
      scope,
      :escalated,
      Keyword.merge(
        [
          status: [
            round: 3,
            escalation: %{cause: cause, gaps: gaps, round: 3, run_id: "rn_19"}
          ]
        ],
        attrs
      )
    )
  end

  describe "escalated" do
    test "at the round limit, with the newest gaps", %{conn: conn, scope: scope} do
      work_item =
        escalated(
          scope,
          :round_limit,
          "- The gift card field has no error text when the code is expired.\n- The demo does not show a payment with two gift cards.\n"
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for a person")
      assert has_element?(view, "#work-item-stage-escalation-h", "Build waits for you")

      assert has_element?(
               view,
               "#work-item-stage-escalation-cause",
               "3 of 3 rounds ran, with these gaps:"
             )

      assert has_element?(
               view,
               "#work-item-stage-escalation-gaps li",
               "The gift card field has no error text when the code is expired."
             )

      assert has_element?(view, "#work-item-stage-escalation-run", "From run rn_19")

      assert has_element?(
               view,
               "#work-item-stage-escalation-form",
               "A note you add goes to the next run as work item data."
             )
    end

    test "each cause", %{conn: conn, scope: scope} do
      for {cause, words} <- [
            {"escalate", "The agent escalated, with these gaps:"},
            {"check_failed", "These output checks failed:"},
            {"run_stopped", "The run stopped before its verdict:"}
          ] do
        work_item = escalated(scope, cause, "The time limit of 15 minutes ran out.")
        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        assert has_element?(view, "#work-item-stage-escalation-cause", words)
        assert has_element?(view, "#work-item-stage-escalation-gaps", "The time limit")
      end
    end

    for level <- [:owner, :admin, :member] do
      test "#{level}: Accept, Run another round, Move back, Close and Decline", %{
        conn: conn,
        scope: scope
      } do
        work_item = escalated(scope, :escalate, "Blocked")
        {conn, _who} = as(conn, scope, unquote(level))
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        for how <- ["accept", "another_round", "close", "decline"] do
          view
          |> form("#work-item-stage-escalation-form", %{"note" => "Go on"})
          |> render_submit(%{"how" => how})
        end

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "", "stage" => @shape})
        |> render_submit(%{"how" => "move_back"})

        assert WorkflowFake.calls(work_item) == [
                 {:resolve_escalation, :accept, "Go on"},
                 {:resolve_escalation, :another_round, "Go on"},
                 {:resolve_escalation, :close, "Go on"},
                 {:resolve_escalation, :decline, "Go on"},
                 {:resolve_escalation, {:move_back, @shape}, nil}
               ]
      end
    end

    test "a move back to a later stage, or an action it does not know, is refused", %{
      conn: conn,
      scope: scope
    } do
      work_item = escalated(scope, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      n = "#{work_item.number}"

      render_hook(view, "stage_resolve", %{
        "number" => n,
        "how" => "move_back",
        "stage" => @verify
      })

      render_hook(view, "stage_resolve", %{"number" => n, "how" => "delete"})
      assert WorkflowFake.calls(work_item) == []
    end
  end

  describe "live" do
    test "the page is read again on {:stage_changed, id}", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :running)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-stage-state", "Running")

      WorkflowFake.put_work_item(work_item,
        status: %{
          stage: %{"id" => @build, "name" => "Build"},
          round: 2,
          rounds: 3,
          state: :at_gate,
          outputs: [],
          gate: %{approvable?: true, approvals: []}
        }
      )

      send(view.pid, {:stage_changed, work_item.public_id})
      assert has_element?(view, "#work-item-stage-state", "At the gate")
    end
  end

  describe "work items the migration placed" do
    test "in Explore and in Shape at its gate, on the page and the board", %{
      conn: conn,
      scope: scope
    } do
      explore = backfilled!(scope, @explore, :running)
      shape = backfilled!(scope, @shape, :at_gate)

      WorkflowFake.put_work_item(explore,
        status: %{
          stage: %{"id" => @explore, "name" => "Explore"},
          round: 1,
          rounds: 3,
          state: :running
        }
      )

      WorkflowFake.put_work_item(shape,
        status: %{
          stage: %{"id" => @shape, "name" => "Shape"},
          state: :at_gate,
          outputs: [],
          gate: %{approvable?: true, approvals: []}
        }
      )

      {:ok, view, _html} = live(conn, list(scope))
      assert has_element?(view, "#work-items-board-0-h", "Explore")
      assert has_element?(view, "#work-items-board-0 #work-items-board-item-#{explore.public_id}")
      assert has_element?(view, "#work-items-board-1-h", "Shape")
      assert has_element?(view, "#work-items-board-1 #work-items-board-item-#{shape.public_id}")

      {:ok, view, _html} = live(conn, page(scope, explore.number))
      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-stage-state", "Running")
      assert has_element?(view, "#work-item-stage-round", "Round 1 of 3")

      {:ok, view, _html} = live(conn, page(scope, shape.number))
      assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
      assert has_element?(view, "#work-item-stage-state", "At the gate")
      assert has_element?(view, "#work-item-stage-gate-none", "This stage has no outputs.")
      assert has_element?(view, "#work-item-stage-gate-approve-go", "Approve Shape")
      refute has_element?(view, "#work-item-stage-round")
    end
  end

  describe "the board" do
    test "a column per stage of the current version, and a removed stage's", %{
      conn: conn,
      scope: scope
    } do
      default = Processes.default_document("software")
      review = %{hd(tl(default["stages"])) | "id" => @review, "name" => "Review"}
      with_review = %{default | "stages" => default["stages"] ++ [review]}
      v2 = save!(scope, with_review)
      v3 = save!(scope, default)

      gift =
        scope |> work_item_fixture(%{title: "Add gift cards to checkout"}) |> place!(v3, @build)

      basket = scope |> work_item_fixture(%{title: "Fix the basket total"}) |> place!(v2, @review)
      unplaced = work_item_fixture(scope, %{title: "Show the delivery date"})

      {:ok, view, _html} = live(conn, list(scope))

      refute has_element?(view, "#work-items-stages")
      assert has_element?(view, "#work-items-board-0-h", "Explore")

      assert has_element?(
               view,
               "#work-items-board-0 #work-items-board-item-#{unplaced.public_id}"
             )

      assert has_element?(view, "#work-items-board-4-h", "Release")

      assert has_element?(
               view,
               "#work-items-board-2 #work-items-board-item-#{gift.public_id}",
               "##{gift.number}"
             )

      assert has_element?(view, "#work-items-board-5-h", "Review")

      assert has_element?(
               view,
               "#work-items-board-5-removed",
               "From version 2; the current version removed this stage."
             )

      assert has_element?(
               view,
               ~s|#work-items-board-5 #work-items-board-item-#{basket.public_id} a[href="#{page(scope, basket.number)}"]|
             )

      {:ok, view, _html} = live(conn, list(scope) <> "?q=gift")
      refute has_element?(view, "#work-items-board")
    end
  end
end
