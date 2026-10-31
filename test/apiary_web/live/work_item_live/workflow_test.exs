defmodule ApiaryWeb.WorkItemLive.WorkflowTest do
  # The work item page and the board under the workflow model
  # (`ApiaryWeb.WorkItemLive.Workflow`), with the stage runner (`Apiary.Stages`), the
  # artifacts (`Apiary.Artifacts`), and `ApiaryWeb.WorkflowFake` in place of the read of
  # the harness: without the feature, the page and the list as before it; the stage
  # track; each stage state (running, waiting for inputs, for answers or for a workflow
  # with Check again, escalated with each cause, at the gate, done); a gate's missing
  # outputs and Add to the artifact page; the runs with their rounds and verdicts; the
  # approval marks; the artifact list; Explore's gate with today's Confirm and no second
  # Approve; each action, for the owner, an admin and a member, hidden from a person the
  # stage does not list and refused on the server; the page read again on the stage and
  # artifact topics; and the board's columns, a removed stage's and the migrated work
  # items' included.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module
  # is not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Stages.{Escalation, GateDecision}
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
  @release "st_k9kpv17xmy"
  @review "st_rev0000000"

  # The default process, with Build's inputs, sequence and outputs of § 4, and its gate's
  # approvers.
  defp document(approvers) do
    default = Processes.default_document("software")

    stages =
      for stage <- default["stages"] do
        if stage["id"] == @build do
          %{
            stage
            | "inputs" => [
                %{"type" => "acceptance-criteria", "required" => true},
                %{"type" => "mockup", "required" => false}
              ],
              "sequence" => [
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
              "outputs" => [
                %{"type" => "change", "required" => true, "check" => %{"reported" => "opened"}},
                %{"type" => "demo-video", "required" => true},
                %{"type" => "explainer", "required" => true},
                %{"type" => "decision-record", "required" => false}
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

  defp place!(work_item, version, stage_id, state, fields \\ []) do
    {1, _} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [process_version_id: version.id, stage_id: stage_id, stage_state: state] ++ fields
      )

    Repo.get!(WorkItem, work_item.id)
  end

  # A work item at Build in `state`, on a version with Build's inputs, sequence and
  # outputs.
  defp at_build(scope, state, opts \\ []) do
    version = save!(scope, document(Keyword.get(opts, :approvers, "members")))

    scope
    |> work_item_fixture()
    |> place!(version, @build, state, stage_round: Keyword.get(opts, :round, 1), stage_entry: 1)
  end

  # A work item where the migration of piece F puts an open one: on the workspace's
  # current version, in Explore, or in Shape at its gate.
  defp backfilled!(scope, stage_id, state) do
    scope
    |> work_item_fixture()
    |> place!(Processes.current(scope.workspace), stage_id, state, stage_round: 1)
  end

  defp escalate!(work_item, cause, gaps, run \\ nil) do
    Repo.insert!(%Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      process_version_id: work_item.process_version_id,
      stage_id: work_item.stage_id,
      round: work_item.stage_round,
      cause: cause,
      gaps: gaps,
      run_id: run && run.id,
      inserted_at: DateTime.utc_now()
    })
  end

  defp push!(actor, work_item, type, stage_id) do
    {:ok, version} = Artifacts.push(actor, work_item, type, [sample(type)], stage_id: stage_id)
    version
  end

  # A file `Apiary.Artifacts.push/5` takes for `type`.
  defp sample("demo-video") do
    %{
      filename: "demo.mp4",
      content_type: "video/mp4",
      binary: <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
    }
  end

  defp sample("change") do
    json("change.json", %{"url" => "https://forge.example.com/example/shop/pull/4"})
  end

  defp sample("proposal") do
    json("proposal.json", %{
      "complexity" => %{"level" => "standard", "reason" => "Two pages change."},
      "understanding" => "Add gift cards to the checkout.",
      "scope" => %{"in" => ["Checkout page"], "out" => ["Refunds"]},
      "approach" => %{"summary" => "A field on the payment step.", "alternatives" => []}
    })
  end

  defp sample(type) do
    %{filename: "#{type}.md", content_type: "text/markdown", binary: "# #{type}"}
  end

  defp json(filename, value) do
    %{filename: filename, content_type: "application/json", binary: Jason.encode!(value)}
  end

  defp decisions(work_item, kind),
    do:
      Repo.all(from d in GateDecision, where: d.work_item_id == ^work_item.id and d.kind == ^kind)

  defp escalation(work_item),
    do:
      Repo.one(
        from e in Escalation,
          where: e.work_item_id == ^work_item.id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp page(scope, number), do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"
  defp list(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/work"

  defp as(conn, _scope, :owner), do: conn

  defp as(_conn, scope, level),
    do: log_in_user(build_conn(), member_fixture(scope, level).user)

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
      work_item = backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @shape,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []
    end

    test "the list has the stages strip and no board", %{conn: conn, scope: scope} do
      backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, "#work-items-stages")
      refute has_element?(view, "#work-items-board")
    end
  end

  describe "a work item the stage runner has not placed" do
    test "draws as before the feature", %{conn: conn, scope: scope} do
      work_item = work_item_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step")
      refute has_element?(view, "#work-item-stage")
    end
  end

  describe "Explore" do
    test "running: the track, the round and the run", %{conn: conn, scope: scope} do
      work_item = taken_in_fixture(scope)
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-todo")
      refute has_element?(view, "#work-item-head-stages-explore")

      # Explore runs as before the model: today's step card stays beside the stage card.
      assert has_element?(view, "#work-item-step")

      assert has_element?(view, "#work-item-stage-state", "Running")
      assert has_element?(view, "#work-item-stage-round", "Round 1 of 3")
      assert has_element?(view, "#work-item-stage-version", "Process version 1")
      assert has_element?(view, "#work-item-stage-line", "Explore is running.")
      assert html =~ "Run 1 · explore-a-ticket · round 1 · queued"
    end

    test "a claimed run reads queued, as the step card does", %{conn: conn, scope: scope} do
      work_item = taken_in_fixture(scope)

      work_item
      |> newest_run()
      |> Ecto.Changeset.change(state: :claimed)
      |> Repo.update!()

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step .q-wi-badge", "Queued")
      assert html =~ "Run 1 · explore-a-ticket · round 1 · queued"
    end

    test "waiting for answers: a link to the questions", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for answers")

      assert has_element?(
               view,
               "#work-item-stage-line",
               "Explore waits for answers to the agent's questions."
             )

      # The step card beside it has the link to the answers: the stage card has none.
      refute has_element?(view, "#work-item-stage-answers")
      assert length(String.split(html, "Answer the questions")) == 2
      assert has_element?(view, ~s|#work-item-step a[href$="/explore"]|, "Answer the questions")
      assert html =~ "Run 1 · explore-a-ticket · round 1 · questions"
    end

    test "waiting for answers past Explore: the stage card has the link", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> shape_gate_fixture()
        |> place!(Processes.current(scope.workspace), @build, :waiting_answers)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               ~s|#work-item-stage-answers[href="#{page(scope, work_item.number)}/explore"]|
             )
    end

    test "at its gate: today's Confirm, and no second Approve", %{conn: conn, scope: scope} do
      work_item = explore_gate_fixture(scope)
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "At the gate")
      assert has_element?(view, "#work-item-stage-gate-output-proposal", "proposal v1")
      assert has_element?(view, "#work-item-stage-gate-check-proposal", "Passed")
      assert has_element?(view, "#work-item-step-confirm")
      refute has_element?(view, "#work-item-stage-gate-approve")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")
      assert html =~ "Run 1 · explore-a-ticket · round 1 · passed"
      assert has_element?(view, "#work-item-artifact-list", "proposal v1")

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @explore,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      view |> element("#work-item-step-confirm") |> render_click()
      assert [%GateDecision{stage_id: @explore}] = decisions(work_item, :approve)
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
    end

    test "a run that stopped: the escalation with its cause", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(nil)
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for a person")
      assert has_element?(view, "#work-item-stage-escalation-h", "Explore waits for you")

      assert has_element?(
               view,
               "#work-item-stage-escalation-cause",
               "The run stopped before its verdict:"
             )

      assert has_element?(
               view,
               "#work-item-stage-escalation-gaps li",
               "The run ended without a result."
             )

      assert has_element?(
               view,
               "#work-item-stage-escalation-run",
               "From run 1 · explore-a-ticket"
             )

      refute has_element?(view, "#work-item-stage-escalation-move")
      assert html =~ "Run 1 · explore-a-ticket · round 1 · ended without a verdict"

      # The escalation card's Run another round runs Explore again: the step card offers no
      # Run Explore again, and the event does nothing.
      assert has_element?(view, "#work-item-step")
      refute has_element?(view, "#work-item-step-again")

      runs = fn ->
        Repo.aggregate(from(r in DispatchRun, where: r.work_item_id == ^work_item.id), :count)
      end

      before = runs.()
      render_hook(view, "explore_again", %{"number" => "#{work_item.number}"})
      assert runs.() == before

      # Run another round starts round 2; the run that stopped still reads as it did.
      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      html = render(view)
      assert html =~ "Run 2 · explore-a-ticket · round 2"
      assert html =~ "Run 1 · explore-a-ticket · round 1 · ended without a verdict"
    end

    test "a run that ended at its claim keeps its line after another round", %{
      conn: conn,
      scope: scope
    } do
      # The claim could not form the run, so the run ended with no registered run and no
      # result (`Apiary.Dispatches.Handover.end_claimed/3`).
      work_item = taken_in_fixture(scope)
      run = newest_run(work_item)

      run
      |> Ecto.Changeset.change(
        state: :ended,
        end_cause: :variables_invalid,
        result_outcome: :error
      )
      |> Repo.update!()

      [run.id] |> Stages.claim_ended() |> Apiary.Dispatches.broadcast()
      assert %{cause: :run_stopped, run_id: run_id} = escalation(work_item)
      assert run_id == run.id
      refute Repo.exists?(from r in Apiary.Runs.Run, where: r.dispatch_run_id == ^run.id)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert render(view) =~ "Run 1 · explore-a-ticket · round 1 · ended without a verdict"

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      html = render(view)
      assert html =~ "Run 2 · explore-a-ticket · round 2"
      assert html =~ "Run 1 · explore-a-ticket · round 1 · ended without a verdict"
    end
  end

  describe "at Shape's gate" do
    for level <- [:owner, :admin, :member] do
      test "#{level}: one Approve, and Request changes", %{conn: conn, scope: scope} do
        work_item = shape_gate_fixture(scope)
        conn = as(conn, scope, unquote(level))
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
        assert has_element?(view, "#work-item-stage-gate-none", "This stage has no outputs.")

        assert has_element?(
                 view,
                 "#work-item-stage-gate-approvers",
                 "One approval covers each version. Any member approves."
               )

        view |> element("#work-item-stage-gate-ask-changes") |> render_click()
        view |> form("#work-item-stage-gate-changes", %{"note" => ""}) |> render_submit()

        assert has_element?(
                 view,
                 "#work-item-stage-gate-changes-note-error",
                 "Write what needs to change."
               )

        view
        |> form("#work-item-stage-gate-changes", %{"note" => "Split the plan in two"})
        |> render_submit()

        assert [%GateDecision{note: "Split the plan in two"}] =
                 decisions(work_item, :request_changes)

        view |> form("#work-item-stage-gate-approve") |> render_submit()

        assert [%GateDecision{}] =
                 work_item |> decisions(:approve) |> Enum.filter(&(&1.stage_id == @shape))

        assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
      end
    end

    test "an earlier stage's artifact changed after approval", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      push!({:person, scope}, work_item, "proposal", @explore)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-marks-proposal-main-m", "Approved v1; v2 is newer")

      assert has_element?(
               view,
               "#work-item-marks-proposal-main-m-changed",
               "Changed after approval"
             )

      # The two marks read apart.
      words =
        view
        |> element("#work-item-marks-proposal-main")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.split()
        |> Enum.join(" ")

      assert words =~ "Approved v1; v2 is newer · Changed after approval"
    end

    test "an event for another number does nothing", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number + 1}",
        "seen" => @shape,
        "note" => ""
      })

      assert work_item |> decisions(:approve) |> Enum.all?(&(&1.stage_id == @explore))
    end
  end

  describe "at Build's gate" do
    test "each output with its version and its check", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :at_gate)
      push!({:person, scope}, work_item, "demo-video", @build)
      video = push!({:person, scope}, work_item, "demo-video", @build)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-output-demo-video", "demo video v2")
      assert has_element?(view, "#work-item-stage-gate-check-demo-video", "Passed")

      assert has_element?(
               view,
               "#work-item-stage-gate-check-change",
               "Not checked in this version"
             )

      assert has_element?(view, "#work-item-stage-gate-check-explainer", "Missing")
      assert has_element?(view, "#work-item-stage-gate-check-decision-record", "Optional, none")

      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      assert has_element?(
               view,
               ~s|#work-item-stage-gate-changes-version option[value="#{video.public_id}"]|,
               "demo video v2"
             )

      render_hook(view, "stage_request_changes", %{
        "number" => "#{work_item.number}",
        "seen" => @build,
        "version" => "av_other",
        "note" => "Show two gift cards"
      })

      assert decisions(work_item, :request_changes) == []
    end
  end

  describe "a gate with a missing output" do
    # A work item at the gate of Shape, a stage with no workflow that has `outputs` as
    # required outputs.
    defp at_shape_gate(scope, outputs, approvers \\ "members") do
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          if stage["id"] == @shape do
            %{
              stage
              | "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => true}),
                "gate" => %{"kind" => "person", "approvers" => approvers}
            }
          else
            stage
          end
        end

      version = save!(scope, %{default | "stages" => stages})

      scope
      |> work_item_fixture()
      |> place!(version, @shape, :at_gate, stage_round: 1, stage_entry: 1)
    end

    defp markdown(name),
      do: [%{filename: name, content_type: "text/markdown", binary: "# Done"}]

    test "one line, an Add for each output, and no Approve that can only fail", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria", "explainer"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-stage-gate-line",
               "Shape needs acceptance criteria and explainer"
             )

      assert has_element?(view, "#work-item-stage-gate-add-acceptance-criteria", "Add")
      assert has_element?(view, "#work-item-stage-gate-add-explainer", "Add")
      refute has_element?(view, "#work-item-stage-gate-approve")
      assert has_element?(view, "#work-item-stage-gate-ask-changes")
    end

    test "Add opens the artifact page with the type chosen", %{conn: conn, scope: scope} do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      {:ok, new, _html} =
        view
        |> element("#work-item-stage-gate-add-acceptance-criteria")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(new, "#artifact-new")
      assert has_element?(new, ~s|#artifact-form option[selected][value="acceptance-criteria"]|)
    end

    test "the line goes when a person adds the output, and Approve works", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      {:ok, _version} =
        Stages.add_version(scope, work_item, "acceptance-criteria", markdown("ac.md"))

      refute has_element?(view, "#work-item-stage-gate-line")
      refute has_element?(view, "#work-item-stage-gate-add-acceptance-criteria")

      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert [%GateDecision{stage_id: @shape}] = decisions(work_item, :approve)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build
    end

    test "a member the gate does not list may add the output and has no Approve", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)
      work_item = at_shape_gate(scope, ["acceptance-criteria"], %{"members" => [listed.user.id]})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-line", "Shape needs acceptance criteria")
      assert has_element?(view, "#work-item-stage-gate-add-acceptance-criteria")
      refute has_element?(view, "#work-item-stage-gate-approve")
    end

    test "a stage with a workflow keeps Approve beside the line", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :at_gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-line", "Build needs")
      assert has_element?(view, "#work-item-stage-gate-approve")
    end

    test "a stale Approve: the notice lists the output and the stage", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"])
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @shape,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Add acceptance criteria before you approve Shape."
             )
    end
  end

  describe "a stage that lists its approvers" do
    test "only a listed member sees Approve; anyone else is refused on the server", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)
      work_item = at_build(scope, :at_gate, approvers: %{"members" => [listed.user.id]})
      push!({:person, scope}, work_item, "demo-video", @build)
      push!({:person, scope}, work_item, "explainer", @build)
      push!({:person, scope}, work_item, "change", @build)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-stage-gate-approve")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")

      assert has_element?(
               view,
               "#work-item-stage-gate-approvers",
               "The members this stage lists approve."
             )

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @build,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      {:ok, view, _html} =
        live(log_in_user(build_conn(), listed.user), page(scope, work_item.number))

      view |> form("#work-item-stage-gate-approve") |> render_submit()
      assert [%GateDecision{stage_id: @build}] = decisions(work_item, :approve)
    end
  end

  describe "waiting" do
    test "for inputs: what is missing, Add and Move back", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for inputs")
      assert has_element?(view, "#work-item-stage-line", "Build needs acceptance criteria")
      refute has_element?(view, "#work-item-stage-input-mockup")

      assert has_element?(
               view,
               ~s|#work-item-stage-add-acceptance-criteria[href="#{page(scope, work_item.number)}/artifacts/new?type=acceptance-criteria"]|
             )

      render_hook(view, "stage_move", %{
        "number" => "#{work_item.number}",
        "seen" => @build,
        "stage" => @release,
        "note" => ""
      })

      assert decisions(work_item, :move) == []

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Choose a stage before Build to move back to."
             )

      view
      |> form("#work-item-stage-move", %{"stage" => @shape, "note" => "Write the criteria"})
      |> render_submit()

      assert [%GateDecision{note: "Write the criteria"}] = decisions(work_item, :move)
      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape
    end

    test "for a workflow: the runner's line and Check again", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for a workflow")

      WorkflowFake.check_result(scope.workspace, {:ok, ["review"]})
      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert has_element?(
               view,
               "#work-item-stage-check-result",
               "The harness still does not list capture-demo."
             )

      assert has_element?(view, "#work-item-stage-gap-0", "Build uses capture-demo, which")

      WorkflowFake.check_result(scope.workspace, {:error, {:unreadable, :address}})
      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert has_element?(
               view,
               "#work-item-stage-check-result",
               "Contact support to correct the address of"
             )

      assert has_element?(view, "#work-item-stage-check-go", "Try again")

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)
      # The stage leaves its wait for the workflow, and waits for Build's required input.
      assert has_element?(view, "#work-item-stage-state", "Waits for inputs")
      refute has_element?(view, "#work-item-stage-check")
    end

    # A work item at Build, which needs no input here, waiting for a workflow the harness
    # now lists: a check that finds it queues Build's run.
    defp waiting_for_found_workflow(scope) do
      stages =
        for stage <- document("members")["stages"] do
          if stage["id"] == @build, do: %{stage | "inputs" => []}, else: stage
        end

      version = save!(scope, %{document("members") | "stages" => stages})

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      scope
      |> work_item_fixture()
      |> place!(version, @build, :waiting_workflow, stage_round: 1, stage_entry: 1)
    end

    defp run_count(work_item),
      do: Repo.aggregate(from(r in DispatchRun, where: r.work_item_id == ^work_item.id), :count)

    test "for a workflow: Check again that finds it queues the stage's run", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = run_count(work_item)

      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert run_count(work_item) == before + 1
    end

    test "for a workflow: a stale Check again on a closed work item queues no run", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = run_count(work_item)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now()]
      )

      render_hook(view, "stage_check", %{"number" => "#{work_item.number}", "seen" => @build})
      render_async(view)

      assert run_count(work_item) == before
      assert Repo.get!(WorkItem, work_item.id).stage_state == :waiting_workflow
      refute has_element?(view, "#work-item-stage")
    end

    test "for a workflow: a work item closed during the check gets the check's message", %{
      conn: conn,
      scope: scope
    } do
      work_item = waiting_for_found_workflow(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      before = run_count(work_item)

      WorkflowFake.check_result(scope.workspace, fn ->
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [state: :closed, closed_at: DateTime.utc_now()]
        )

        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      end)

      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert run_count(work_item) == before

      assert has_element?(
               view,
               "#work-item-stage-check-result",
               "Reload the page. The work item is closed or declined, so it has no stage to check."
             )
    end

    test "for a workflow: a stale Check again on another stage does not run the check", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      version = Repo.get!(Apiary.Processes.Version, work_item.process_version_id)
      place!(work_item, version, @release, :waiting_workflow, stage_round: 1)

      render_hook(view, "stage_check", %{"number" => "#{work_item.number}", "seen" => @build})
      render_async(view)

      assert %{stage_id: @release, stage_state: :waiting_workflow} =
               Repo.get!(WorkItem, work_item.id)

      assert has_element?(view, "#work-item-stage-notice", "moved from Build to Release")
    end

    test "for a workflow: no Check again for a person the stage does not list", %{
      conn: conn,
      scope: scope
    } do
      listed = member_fixture(scope, :member)

      work_item =
        at_build(scope, :waiting_workflow, approvers: %{"members" => [listed.user.id]})

      WorkflowFake.check_result(
        scope.workspace,
        {:ok, ["implement", "capture-demo", "fix-demo-findings"]}
      )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-stage-check")
      render_hook(view, "stage_check", %{"number" => "#{work_item.number}", "seen" => @build})
      render_async(view)
      assert Repo.get!(WorkItem, work_item.id).stage_state == :waiting_workflow
    end
  end

  describe "escalated" do
    test "each cause, with the gaps the runner stored", %{conn: conn, scope: scope} do
      for {cause, words} <- [
            {:round_limit, "3 of 3 rounds ran, with these gaps:"},
            {:escalate, "The agent escalated, with these gaps:"},
            {:check_failed, "These output checks failed:"}
          ] do
        work_item = at_build(scope, :escalated, round: 3)

        escalate!(
          work_item,
          cause,
          "The gift card field has no error text.\nThe demo shows one gift card."
        )

        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        assert has_element?(view, "#work-item-stage-escalation-h", "Build waits for you")
        assert has_element?(view, "#work-item-stage-escalation-cause", words)

        assert has_element?(
                 view,
                 "#work-item-stage-escalation-gaps li",
                 "The demo shows one gift card."
               )

        assert has_element?(
                 view,
                 "#work-item-stage-escalation-form",
                 "A note you add goes to the next run as work item data."
               )
      end
    end

    for level <- [:owner, :admin, :member] do
      test "#{level}: Move back, Close and Decline", %{conn: conn, scope: scope} do
        conn = as(conn, scope, unquote(level))

        moved = at_build(scope, :escalated, round: 3)
        escalate!(moved, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, moved.number))

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "Plan again", "stage" => @shape})
        |> render_submit(%{"how" => "move_back"})

        assert %Escalation{resolution: :move_back, note: "Plan again"} = escalation(moved)
        assert Repo.get!(WorkItem, moved.id).stage_id == @shape

        for {how, state} <- [{"close", :closed}, {"decline", :declined}] do
          work_item = at_build(scope, :escalated, round: 3)
          escalate!(work_item, :escalate, "Blocked")
          {:ok, view, _html} = live(conn, page(scope, work_item.number))

          view
          |> form("#work-item-stage-escalation-form", %{"note" => ""})
          |> render_submit(%{"how" => how})

          assert Repo.get!(WorkItem, work_item.id).state == state
        end
      end
    end

    test "Accept as it is, and Run another round", %{conn: conn, scope: scope} do
      for how <- ["accept", "another_round"] do
        work_item = scope |> taken_in_fixture() |> end_run!(nil)
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "Go on"})
        |> render_submit(%{"how" => how})

        assert %Escalation{resolution: resolution} = escalation(work_item)
        assert Atom.to_string(resolution) == how
      end
    end

    test "a move back to a later stage, or an action it does not know, is refused", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      n = "#{work_item.number}"

      render_hook(view, "stage_resolve", %{
        "number" => n,
        "seen" => @build,
        "how" => "move_back",
        "stage" => @release
      })

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Choose a stage before Build to move back to."
             )

      render_hook(view, "stage_resolve", %{"number" => n, "seen" => @build, "how" => "delete"})
      assert %Escalation{resolution: nil} = escalation(work_item)
    end
  end

  describe "a work item that ended" do
    for {how, words} <- [{"close", "Closed by you"}, {"decline", "Declined by you"}] do
      test "#{how}: no stage card, and the track and the head's words stay", %{
        conn: conn,
        scope: scope
      } do
        work_item = at_build(scope, :escalated, round: 3)
        escalate!(work_item, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        view
        |> form("#work-item-stage-escalation-form", %{"note" => ""})
        |> render_submit(%{"how" => unquote(how)})

        for view <- [view, elem(live(conn, page(scope, work_item.number)), 1)] do
          html = render(view)
          refute has_element?(view, "#work-item-stage")
          refute has_element?(view, "#work-item-stage-escalation-note")
          refute html =~ "Waits for a person"
          refute html =~ "Accept as it is"
          assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
          refute has_element?(view, "#work-item-head-stages-#{@build}.q-wi-stage-wait")
          assert has_element?(view, "#work-item-head-meta", unquote(words))
          refute has_element?(view, "#work-item-head-stage-status")
        end
      end
    end
  end

  describe "the head's status" do
    for {state, words} <- [
          {:running, "Build · Running"},
          {:waiting_inputs, "Build · Waits for inputs"},
          {:waiting_answers, "Build · Waits for answers"},
          {:waiting_workflow, "Build · Waits for a workflow"},
          {:escalated, "Build · Waits for a person"},
          {:at_gate, "Build · At the gate"},
          {:done, "Build · Done"}
        ] do
      test "at Build, #{state}: the stage and its state", %{conn: conn, scope: scope} do
        work_item = at_build(scope, unquote(state))
        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        assert has_element?(view, "#work-item-head-stage-status", unquote(words))
      end
    end

    test "after Approve at Shape, it follows the stage", %{conn: conn, scope: scope} do
      save!(scope, document("members"))
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, "#work-item-head-stage-status", "Shape · At the gate")

      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert has_element?(view, "#work-item-head-stage-status", "Build · ")
      refute render(view) =~ "Ready for Shape"
    end

    test "at Explore, Explore's words while a run, its questions or its gate are on", %{
      conn: conn,
      scope: scope
    } do
      for {work_item, words} <- [
            {taken_in_fixture(scope), "Explore is queued"},
            {scope |> taken_in_fixture() |> end_run!(questions_result()), "Waits for answers"},
            {explore_gate_fixture(scope), "Waits for you to confirm"}
          ] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number))
        assert has_element?(view, "#work-item-head-meta", words)
        refute has_element?(view, "#work-item-head-stage-status")
      end
    end

    test "at Explore, escalated: the stage and its state", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(nil)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-head-stage-status",
               "Explore · Waits for a person"
             )
    end
  end

  describe "an action on a stage the work item left" do
    test "Approve does nothing and says where the work item moved", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      place!(work_item, Processes.version_for(work_item), @build, :at_gate)
      view |> form("#work-item-stage-gate-approve") |> render_submit()

      assert work_item |> decisions(:approve) |> Enum.all?(&(&1.stage_id == @explore))
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "Check the new stage and act again. The work item moved from Shape to Build before your click."
             )
    end

    test "a stale Move back does nothing", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      place!(work_item, Processes.version_for(work_item), @shape, :running)

      view
      |> form("#work-item-stage-move", %{"stage" => @explore, "note" => "Plan again"})
      |> render_submit()

      assert decisions(work_item, :move) == []
      assert Repo.get!(WorkItem, work_item.id).stage_id == @shape

      assert has_element?(
               view,
               "#work-item-stage-notice",
               "The work item moved from Build to Shape before your click."
             )
    end

    test "an open Request changes form closes when the stage changes", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      view |> element("#work-item-stage-gate-ask-changes") |> render_click()

      place!(work_item, Processes.version_for(work_item), @build, :running)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Stages.topic(work_item),
        {:stage_changed, work_item.public_id}
      )

      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
      refute has_element?(view, "#work-item-stage-gate-changes")
    end
  end

  describe "a refused action" do
    defp notice(view), do: view |> element("#work-item-stage-notice") |> render()

    defp hook(view, work_item, event, params),
      do: render_hook(view, event, Map.merge(%{"number" => "#{work_item.number}"}, params))

    test "Approve while the stage runs: the stage changed", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :running)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_approve", %{"seen" => @build, "note" => ""})
      assert decisions(work_item, :approve) == []
      assert notice(view) =~ "Check the stage and act again. Build changed before your click."
    end

    test "an escalation action with no escalation: the stage changed", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :at_gate)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_resolve", %{"seen" => @build, "how" => "accept", "note" => ""})
      assert notice(view) =~ "Check the stage and act again. Build changed before your click."
    end

    test "a person the stage does not list", %{conn: conn, scope: scope} do
      listed = member_fixture(scope, :member)
      work_item = at_build(scope, :at_gate, approvers: %{"members" => [listed.user.id]})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_approve", %{"seen" => @build, "note" => ""})
      assert decisions(work_item, :approve) == []
      assert notice(view) =~ "Ask an approver of Build to act on it."
    end

    test "a stage the version does not have", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_move", %{
        "seen" => @build,
        "stage" => "st_unknown000",
        "note" => ""
      })

      assert notice(view) =~
               "Choose a stage from the list. The stage you sent is not in the work item&#39;s process version."
    end

    test "a work item closed before the click", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [state: :closed, closed_at: DateTime.utc_now()]
      )

      hook(view, work_item, "stage_approve", %{"seen" => @shape, "note" => ""})

      assert work_item |> decisions(:approve) |> Enum.all?(&(&1.stage_id == @explore))
      refute has_element?(view, "#work-item-stage")
    end

    test "a note over 4,000 characters", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      hook(view, work_item, "stage_request_changes", %{
        "seen" => @shape,
        "note" => String.duplicate("a", 4001)
      })

      assert decisions(work_item, :request_changes) == []
      assert notice(view) =~ "Shorten the note to 4,000 characters or fewer."
    end

    test "a work item no longer in the workspace", %{conn: conn, scope: scope} do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      other = workspace_fixture(scope.organisation, "Platform")

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      hook(view, work_item, "stage_approve", %{"seen" => @shape, "note" => ""})
      assert_redirect(view)
    end
  end

  describe "an escalation's gaps" do
    test "two lines, without a raw line break or markup", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :escalated, round: 3)

      escalate!(
        work_item,
        :run_stopped,
        "The build of the environment failed.\nAn instance admin fixes the <b>image</b>."
      )

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-stage-escalation-gaps li:nth-child(1)",
               "The build of the environment failed."
             )

      assert has_element?(
               view,
               "#work-item-stage-escalation-gaps li:nth-child(2)",
               "An instance admin fixes the <b>image</b>."
             )

      refute html =~ "\\n"
      refute html =~ "<b>image</b>"
    end
  end

  describe "an escalation with no gaps" do
    for {cause, words} <- [
          {:round_limit, "3 of 3 rounds ran."},
          {:escalate, "The agent escalated."},
          {:check_failed, "The output checks failed."},
          {:run_stopped, "The run stopped before its verdict."}
        ] do
      test "#{cause}: the cause with no colon", %{conn: conn, scope: scope} do
        work_item = at_build(scope, :escalated, round: 3)
        escalate!(work_item, unquote(cause), nil)
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        assert view |> element("#work-item-stage-escalation-cause") |> render() =~
                 unquote(words)

        refute view |> element("#work-item-stage-escalation-cause") |> render() =~ ":<"
        refute has_element?(view, "#work-item-stage-escalation-gaps")
      end
    end
  end

  describe "an escalation whose fix is on the set-up step Harness" do
    # A work item escalated at Explore because its run's harness did not resolve, with the
    # walk's `failure` (nil for none) and the gaps' fix line `fix`.
    defp harness_escalated!(scope, failure, fix) do
      work_item = taken_in_fixture(scope)
      run = newest_run(work_item)

      run =
        run
        |> Ecto.Changeset.change(
          state: :ended,
          end_cause: :harness_unresolved,
          result_outcome: :error
        )
        |> Repo.update!()

      if failure do
        Repo.delete_all(
          from h in Apiary.Harnesses.RunHarness, where: h.dispatch_run_id == ^run.id
        )

        Repo.insert!(%Apiary.Harnesses.RunHarness{
          dispatch_run_id: run.id,
          state: :failed,
          failure: failure
        })
      end

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [stage_state: :escalated]
      )

      work_item = Repo.get!(WorkItem, work_item.id)
      escalate!(work_item, :run_stopped, "The run's harness did not resolve.\n" <> fix, run)
      work_item
    end

    defp harness(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/set-up/harness"

    test "links the words in the fix line, and escapes the rest", %{conn: conn, scope: scope} do
      work_item =
        harness_escalated!(
          scope,
          "no_harness",
          "Owners and admins of <b>Main</b> choose a harness on the set-up step Harness."
        )

      {:ok, view, html} = live(conn, page(scope, work_item.number))
      gaps = "#work-item-stage-escalation-gaps li:nth-child(2)"

      assert has_element?(
               view,
               ~s|#{gaps} a[href="#{harness(scope)}"]|,
               "the set-up step Harness"
             )

      assert has_element?(view, gaps, "Owners and admins of <b>Main</b> choose a harness on")
      refute html =~ "<b>Main</b>"
      refute has_element?(view, "#work-item-stage-escalation-gaps li:nth-child(1) a")
    end

    test "a fix line without the words shows as it is", %{conn: conn, scope: scope} do
      work_item = harness_escalated!(scope, "no_harness", "Owners and admins choose a harness.")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-stage-escalation-gaps li:nth-child(2)",
               "Owners and admins choose a harness."
             )

      refute has_element?(view, "#work-item-stage-escalation-gaps a")
    end

    test "no link where the fix is not on that step", %{conn: conn, scope: scope} do
      work_item =
        harness_escalated!(
          scope,
          nil,
          "Owners and admins choose a harness on the set-up step Harness."
        )

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(
               view,
               "#work-item-stage-escalation-gaps li:nth-child(2)",
               "on the set-up step Harness."
             )

      refute has_element?(view, "#work-item-stage-escalation-gaps a")
    end
  end

  describe "notes" do
    test "a request for changes and a failed check, for the next run", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)

      {:ok, _work_item} =
        Stages.request_changes(scope, work_item, "Split the plan in two", nil,
          expect_stage: @shape
        )

      Repo.insert!(%Apiary.Stages.Check{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: work_item.process_version_id,
        stage_id: @shape,
        round: 1,
        gaps: "The plan has no test step.",
        inserted_at: DateTime.utc_now()
      })

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-notes-h", "Notes for the next run")
      assert has_element?(view, "#work-item-notes-0", "Changes requested · Shape")
      assert has_element?(view, "#work-item-notes-0", "Split the plan in two")
      assert has_element?(view, "#work-item-notes-1", "Failed check · Shape")
      assert has_element?(view, "#work-item-notes-1", "The plan has no test step.")
    end

    test "a move with no note has no note line", %{conn: conn, scope: scope} do
      work_item = at_build(scope, :waiting_inputs)
      {:ok, _work_item} = Stages.move(scope, work_item, @shape, nil, expect_stage: @build)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-notes-0", "Moved · Build")
      refute has_element?(view, "#work-item-notes-0 p.whitespace-pre-line")
    end
  end

  describe "done" do
    test "every stage done", %{conn: conn, scope: scope} do
      work_item = backfilled!(scope, @release, :done)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-done")
      assert has_element?(view, "#work-item-stage-line", "Every stage is done.")
    end
  end

  describe "live" do
    test "the page is read again on the work item's stage and artifact topics", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-marks-proposal-main-m")

      push!({:person, scope}, work_item, "proposal", @explore)
      assert has_element?(view, "#work-item-marks-proposal-main-m", "Approved v1; v2 is newer")

      {1, _} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_id: @build, stage_state: :running]
        )

      topic = Stages.topic(work_item)
      Phoenix.PubSub.broadcast(Apiary.PubSub, topic, {:stage_changed, work_item.public_id})
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
    end

    test "a message the pages do not know leaves them as they are", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, show, _html} = live(conn, page(scope, work_item.number))
      {:ok, index, _html} = live(conn, list(scope))

      send(show.pid, {:something_else, work_item.public_id})
      send(index.pid, {:something_else, work_item.public_id})

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Apiary.WorkItems.topic(work_item.workspace_id),
        :other
      )

      assert has_element?(show, "#work-item-stage-state", "At the gate")
      assert has_element?(index, "#work-items-board-item-#{work_item.public_id}")
    end

    test "the page is read again after an approval in another session", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)

      {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
    end
  end

  describe "work items the migration placed" do
    test "in Explore and in Shape at its gate, on the page and the board", %{
      conn: conn,
      scope: scope
    } do
      explore = backfilled!(scope, @explore, :running)
      shape = backfilled!(scope, @shape, :at_gate)

      {:ok, view, _html} = live(conn, list(scope))
      assert has_element?(view, "#work-items-board-0-h", "Explore")
      assert has_element?(view, "#work-items-board-0 #work-items-board-item-#{explore.public_id}")
      assert has_element?(view, "#work-items-board-1-h", "Shape")
      assert has_element?(view, "#work-items-board-1 #work-items-board-item-#{shape.public_id}")

      {:ok, view, _html} = live(conn, page(scope, explore.number))
      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-stage-state", "Running")

      {:ok, view, _html} = live(conn, page(scope, shape.number))
      assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
      assert has_element?(view, "#work-item-stage-state", "At the gate")
      assert has_element?(view, "#work-item-stage-gate-approve-go", "Approve Shape")
    end
  end

  describe "the board" do
    test "a column per stage of the current version, and a removed stage's", %{
      conn: conn,
      scope: scope
    } do
      default = Processes.default_document("software")
      review = %{hd(tl(default["stages"])) | "id" => @review, "name" => "Review"}
      v2 = save!(scope, %{default | "stages" => default["stages"] ++ [review]})
      v3 = save!(scope, default)

      gift =
        scope
        |> work_item_fixture(%{title: "Add gift cards to checkout"})
        |> place!(v3, @build, :running)

      basket =
        scope
        |> work_item_fixture(%{title: "Fix the basket total"})
        |> place!(v2, @review, :at_gate)

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
               "From version 2. This stage is not in the current version."
             )

      assert has_element?(
               view,
               ~s|#work-items-board-5 #work-items-board-item-#{basket.public_id} a[href="#{page(scope, basket.number)}"]|
             )

      {:ok, view, _html} = live(conn, list(scope) <> "?q=gift")
      refute has_element?(view, "#work-items-board")
    end

    test "a work item's number, its title without invisible characters, and the mark Test", %{
      conn: conn,
      scope: scope
    } do
      {:ok, line} = Apiary.WorkItems.take_in_test(scope, "Hello! Where are you running?")
      basket = work_item_fixture(scope, %{title: "Basket \u202Eflow"})
      blank = work_item_fixture(scope, %{title: "\u00A0"})

      {:ok, view, html} = live(conn, list(scope))
      item = &"#work-items-board-item-#{&1.public_id}"

      refute html =~ "\u202E"
      assert has_element?(view, item.(basket), "Basket flow")
      refute has_element?(view, item.(basket) <> " .badge")
      assert view |> element(item.(blank) <> " a") |> render() =~ ~r/>\s*##{blank.number}\s*<\/a>/
      assert has_element?(view, item.(line) <> " a", "Hello! Where are you running?")
      assert has_element?(view, item.(line) <> " .badge", "Test")
      assert has_element?(view, ~s|#{item.(line)} a[href="#{page(scope, line.number)}"]|)
    end

    test "each column in the list's sort", %{conn: conn, scope: scope} do
      older = work_item_fixture(scope, %{title: "Fix the basket total"})
      newer = work_item_fixture(scope, %{title: "Show the delivery date"})
      now = DateTime.utc_now()

      for {work_item, created, updated} <- [{older, -60, 0}, {newer, 0, -60}] do
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [inserted_at: DateTime.add(now, created), updated_at: DateTime.add(now, updated)]
        )
      end

      order = fn view ->
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#work-items-board-0 li")
        |> LazyHTML.attribute("id")
      end

      ids = &Enum.map(&1, fn work_item -> "work-items-board-item-#{work_item.public_id}" end)

      {:ok, view, _html} = live(conn, list(scope))
      assert order.(view) == ids.([older, newer])

      {:ok, view, _html} = live(conn, list(scope) <> "?sort=created")
      assert order.(view) == ids.([newer, older])
    end

    test "a message of the workspace's work items reads the board again", %{
      conn: conn,
      scope: scope
    } do
      work_item = backfilled!(scope, @explore, :running)
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(
               view,
               "#work-items-board-0 #work-items-board-item-#{work_item.public_id}"
             )

      place!(work_item, Processes.current(scope.workspace), @shape, :at_gate)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Apiary.WorkItems.topic(scope.workspace.id),
        {:work_items_changed, [work_item.public_id]}
      )

      assert has_element?(
               view,
               "#work-items-board-1 #work-items-board-item-#{work_item.public_id}"
             )
    end
  end
end
