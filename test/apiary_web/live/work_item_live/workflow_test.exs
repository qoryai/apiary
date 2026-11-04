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
  # artifact topics; and the list's boxes on every view and its groups, a removed stage's
  # and the migrated work items' included, with each view's line.
  #
  # The fake changes the whole node (`ApiaryWeb.WorkflowFake.install/0`), so the module
  # is not async.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Artifacts.Artifact
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{WorkItem, WorkList}
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

  # The document of the workspace's current version, with `fun` applied to Explore's
  # sequence.
  defp explore_sequence(scope, fun) do
    Map.update!(Processes.current(scope.workspace).document, "stages", fn stages ->
      Enum.map(stages, fn
        %{"id" => @explore} = stage -> Map.update!(stage, "sequence", fun)
        stage -> stage
      end)
    end)
  end

  # Saves the workspace's current version with Explore's sequence a loop of
  # explore-a-ticket of `rounds` rounds, in place of the default's one workflow. A run of
  # Explore pushes no verdict, so in the loop each run with no open question starts the
  # next round, up to the limit.
  defp explore_loop!(scope, rounds \\ 3) do
    save!(
      scope,
      explore_sequence(scope, fn _sequence ->
        [%{"loop" => %{"rounds" => rounds, "body" => [%{"workflow" => "explore-a-ticket"}]}}]
      end)
    )
  end

  # Moves `work_item` to a trial version of the workspace's current one with 2 Explore
  # rounds instead of 3; its queued run moves with it and keeps its stored `of`.
  defp two_rounds!(scope, work_item) do
    document =
      explore_sequence(scope, fn sequence ->
        Enum.map(sequence, fn
          %{"loop" => loop} = entry -> %{entry | "loop" => Map.put(loop, "rounds", 2)}
          entry -> entry
        end)
      end)

    {:ok, trial} = Processes.save(scope, scope.workspace, document, trial: true)
    {:ok, work_item} = Processes.assign(scope, Repo.get!(WorkItem, work_item.id), trial)
    work_item
  end

  # A second take in after a first that used its 3 runs, each with no result: the page's
  # Details line while
  # attempt 1 of take in 2 is queued, then the line and its link after attempts 1 and 2
  # of take in 2 ended.
  defp details_of_a_second_take_in(conn, scope) do
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 2)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    assert %DispatchRun{take_in: 1, attempt: 3} = newest_run(work_item)
    {:ok, _} = WorkItems.close(scope, work_item)
    {:ok, _} = WorkItems.take_in_again(scope, ticket.public_id)

    work_item = Repo.get!(WorkItem, work_item.id)
    assert %DispatchRun{take_in: 2, attempt: 1, state: :waiting} = newest_run(work_item)
    {:ok, view, _html} = live(conn, page(scope, work_item.number))
    queued = line(view, "#work-item-details-runs")

    work_item = end_run!(work_item, nil)
    {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
    work_item = end_run!(Repo.get!(WorkItem, work_item.id), nil)
    %DispatchRun{take_in: 2, attempt: 2} = latest = newest_run(work_item)
    number = Repo.one(from r in Run, where: r.dispatch_run_id == ^latest.id, select: r.number)

    {:ok, view, _html} = live(conn, page(scope, work_item.number))

    %{
      queued: queued,
      ended: line(view, "#work-item-details-runs"),
      link: has_element?(view, ~s(#work-item-details-runs a[href$="/runs/#{number}"]), "2")
    }
  end

  # The text of the element `selector`, its whitespace collapsed: the whole line.
  defp line(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
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

  # The workspace's process saved with one member as the only approver of Explore's gate:
  # that member's scope.
  defp explore_gate_listing(scope) do
    default = Processes.default_document("software")
    listed = member_fixture(scope, :member)

    stages =
      for stage <- default["stages"] do
        if stage["id"] == @explore,
          do: %{
            stage
            | "gate" => %{"kind" => "person", "approvers" => %{"members" => [listed.user.id]}}
          },
          else: stage
      end

    save!(scope, %{default | "stages" => stages})
    Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(listed.user))
  end

  defp list(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/work"

  # The texts of the elements `selector` names, each with its spaces made one.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

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

    test "a second take in: Details counts only that take in's runs", %{
      conn: conn,
      scope: scope
    } do
      assert %{queued: "None yet", ended: "Attempt 2 · 2 runs, ended", link: true} =
               details_of_a_second_take_in(conn, scope)
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

    test "the list has its bands with Fold, and the line of Waiting on you alone", %{
      conn: conn,
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, ".q-wl-fold")
      assert has_element?(view, "#work-item-#{work_item.public_id}")
      refute has_element?(view, "#work-items-groups")
      refute has_element?(view, "#work-items-note")

      {:ok, view, _html} = live(conn, list(scope) <> "?view=closed")
      assert has_element?(view, "#work-items-stages")
      refute has_element?(view, "#work-items-note")
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

  # Answers to `questions_result/0`'s two questions, by question id.
  @answers [%{"id" => "q1", "note" => "a"}, %{"id" => "q2", "note" => "b"}]

  # An answer to each open question of the work item's newest questions, by question id.
  defp open_answers(work_item) do
    {_version, document} = Apiary.Explore.Questions.newest(Repo.get!(WorkItem, work_item.id))

    for %{"id" => id, "state" => "open"} <- document["questions"],
        do: %{"id" => id, "note" => "a"}
  end

  describe "Explore" do
    test "running: the track, one card with the stage's state, and the run", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-head-stages-#{@release}.q-wi-stage-todo")
      refute has_element?(view, "#work-item-head-stages-explore")

      # One card: the step card, with the stage's state as its badge; no stage card.
      assert has_element?(view, "#work-item-step")
      refute has_element?(view, "#work-item-stage")

      # The run waits for a machine: the card shows Queued, as the head does, and not
      # Running.
      assert has_element?(view, "#work-item-step-state", "Queued")
      refute has_element?(view, "#work-item-step-state", "Running")
      refute render(view) =~ "Explore is running."
      assert has_element?(view, "#work-item-head-meta", "Explore is queued")
      # No round, and the process version in Details; no runs list above the tabs.
      refute render(view) =~ "Round "
      refute render(view) =~ "Process version"
      assert has_element?(view, "#work-item-details-process", "Version 1")
      refute has_element?(view, "#work-item-runs-0")
      refute html =~ "explore-a-ticket · round"

      # Details names the queued run, as the run list does, and not None yet.
      assert has_element?(view, "#work-item-details-runs", "Attempt 1 is queued.")
      refute has_element?(view, "#work-item-details-runs", "None yet")
    end

    test "a queued run moved to a version with fewer rounds: Details shows its attempt", %{
      conn: conn,
      scope: scope
    } do
      explore_loop!(scope)
      work_item = taken_in_fixture(scope)
      assert %DispatchRun{attempt: 1, of: 3} = newest_run(work_item)

      two_rounds!(scope, work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # The runner stops after round 2 of the version the work item is on, whatever the
      # stored run's limit is. Explore's card shows no round.
      refute has_element?(view, "#work-item-stage-round")
      assert has_element?(view, "#work-item-details-runs", "Attempt 1 is queued.")
    end

    test "a later queued run moved to a version with fewer rounds: the step card shows its attempt",
         %{conn: conn, scope: scope} do
      explore_loop!(scope)
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, @answers)
      assert %DispatchRun{attempt: 2, of: 3} = newest_run(work_item)

      two_rounds!(scope, work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-stage-round")
      assert has_element?(view, "#work-item-step-run", "Attempt 2 is queued.")
    end

    test "a run queued for Explore's next workflow: the page shows its attempt", %{
      conn: conn,
      scope: scope
    } do
      # Explore: explore-a-ticket, then one more workflow.
      save!(
        scope,
        explore_sequence(scope, fn sequence ->
          sequence ++ [%{"workflow" => "explore-a-ticket"}]
        end)
      )

      work_item =
        Enum.reduce(1..2, taken_in_fixture(scope), fn attempt, work_item ->
          work_item = end_run!(work_item, questions_result())
          {:ok, _} = WorkItems.answer(scope, work_item, attempt, open_answers(work_item))
          Repo.get!(WorkItem, work_item.id)
        end)

      # Run 3 proposes; the next workflow is queued with the runs it may have in its round,
      # not the runs of the first.
      work_item = end_run!(work_item, understood_result())
      assert %DispatchRun{attempt: 4, of: 6} = newest_run(work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert render(view) =~ "Attempt 4 is queued."
    end

    test "a second take in: the step card and the fold of the runs count its attempts", %{
      conn: conn,
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      # Take in 1: two runs, then the work item is closed and taken in again.
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, open_answers(work_item))
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result())
      {:ok, _} = WorkItems.close(scope, work_item)
      {:ok, _} = WorkItems.take_in_again(scope, ticket.public_id)

      # Take in 2: run 1 asks, the answer queues attempt 2.
      work_item = end_run!(Repo.get!(WorkItem, work_item.id), questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, open_answers(work_item))
      assert %DispatchRun{take_in: 2, attempt: 2, of: 3} = newest_run(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-runs-0")
      assert has_element?(view, "#work-item-step-run", "Attempt 2 is queued.")
      refute render(view) =~ "Attempt 4"

      # The fold of the runs on Explore's tab has this take in's two runs.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "2 runs"
      refute render(view) =~ "Attempt 3"
      refute render(view) =~ "Attempt 4"
    end

    test "a second take in: Details counts only that take in's runs", %{
      conn: conn,
      scope: scope
    } do
      assert %{
               queued: "Attempt 1 is queued.",
               ended: "Attempt 2 · 2 runs, ended",
               link: true
             } = details_of_a_second_take_in(conn, scope)
    end

    test "a run before the work item was placed: the step card shows its attempt",
         %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())

      # As the migration placed the work item: its first run has no stage.
      {1, _} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^newest_run(work_item).id),
          set: [stage_id: nil]
        )

      {:ok, _} = WorkItems.answer(scope, work_item, 1, @answers)
      # The runs of Explore's entry count only the runs placed in it: the first is not.
      assert %DispatchRun{attempt: 2, of: 4} = newest_run(work_item)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      refute has_element?(view, "#work-item-runs-0")
      assert has_element?(view, "#work-item-step-run", "Attempt 2 is queued.")
    end

    test "a claimed run reads queued, as the step card does", %{conn: conn, scope: scope} do
      work_item = taken_in_fixture(scope)

      work_item
      |> newest_run()
      |> Ecto.Changeset.change(state: :claimed)
      |> Repo.update!()

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step-state", "Queued")
      refute has_element?(view, "#work-item-stage")
      refute html =~ "explore-a-ticket · round"
    end

    test "a run handed over to a machine reads running", %{conn: conn, scope: scope} do
      # Past Explore, where the stage card stands alone.
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      work_item
      |> newest_run()
      |> Ecto.Changeset.change(state: :handed_over)
      |> Repo.update!()

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Running")
      assert has_element?(view, "#work-item-stage-line", "Build is running.")
      assert has_element?(view, "#work-item-head-stage-status", "Build · Running")
      assert html =~ "Attempt 1 · explore-a-ticket · round 1 · running"
    end

    test "waiting for answers: a link to the questions", %{conn: conn, scope: scope} do
      work_item = scope |> taken_in_fixture() |> end_run!(questions_result())
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      # One card: the step card, with the stage's state, and the link to the answers.
      assert has_element?(view, "#work-item-step-state", "Needs answers")
      refute has_element?(view, "#work-item-stage")
      refute html =~ "Explore waits for answers to the agent's questions."
      refute has_element?(view, "#work-item-stage-answers")
      assert length(String.split(html, "Answer the questions")) == 2
      assert has_element?(view, ~s|#work-item-step a[href$="/explore"]|, "Answer the questions")
      refute html =~ "explore-a-ticket · round"
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

    test "at its gate: Confirm on Explore's tab, and no second Approve", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, view, html} = live(conn, page(scope, work_item.number))

      # One card: the step card with the stage's name and state; no Outputs, no stage card.
      assert has_element?(view, "#work-item-step-h", "Explore")
      refute has_element?(view, "#work-item-step-h", "Confirm")
      assert has_element?(view, "#work-item-step-state", "At the gate")
      refute has_element?(view, "#work-item-stage")
      refute has_element?(view, "#work-item-stage-gate-output-proposal")
      assert has_element?(view, "#work-item-step-explore", "Read the proposal")
      refute has_element?(view, "#work-item-stage-gate-approve")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")
      # The decision is Confirm's: the gate card says nothing of who approves.
      refute has_element?(view, "#work-item-stage-gate-approvers")
      refute render(view) =~ "Any member approves."
      refute html =~ "explore-a-ticket · round"
      # Artifacts are in the fold of the runs, on Explore's tab.
      refute has_element?(view, "#work-item-artifact-list")
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "proposal v1"
      assert has_element?(view, "#work-item-artifact-list", "proposal v1")
      # Beside the frames of the tab, not under Questions.
      assert has_element?(view, "#work-item-record h2#work-item-artifacts-h", "Artifacts")

      # Inside the work item, runs count by attempt; only Artifacts names the run by its
      # number on the server.
      number =
        Repo.one(
          from r in Apiary.Runs.Run,
            where: r.dispatch_run_id == ^newest_run(work_item).id,
            select: r.number
        )

      assert has_element?(view, "#work-item-artifact-list", "Run #{number}")
      refute has_element?(view, "#work-item-artifact-list", "round")
      assert line(view, "#work-item-details-runs") == "Attempt 1 · 1 run, ended"
      refute render(view) =~ "Run 1 · explore-a-ticket"
      refute render(view) =~ "rn_"

      render_hook(view, "stage_approve", %{
        "number" => "#{work_item.number}",
        "seen" => @explore,
        "note" => ""
      })

      assert decisions(work_item, :approve) == []

      view |> element("#work-item-explore-gate-go", "Confirm") |> render_click()
      assert [%GateDecision{stage_id: @explore}] = decisions(work_item, :approve)
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
    end

    test "a result that did not pass the check: both cards name the run by its attempt", %{
      conn: conn,
      scope: scope
    } do
      # A run that stopped, whose row a release before the run API kept as refused: the
      # result Core read did not pass its check.
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^newest_run(work_item).id),
          set: [result_outcome: :refused]
        )

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert line(view, "#work-item-stage-escalation-run") == "From attempt 1 · explore-a-ticket"

      assert line(view, "#work-item-step-line") ==
               "Attempt 1 returned a result that did not pass Qory Apiary's check, so Explore has no result."

      refute html =~ ~r/\bRun \d/
    end

    test "a run that stopped: the escalation with its cause", %{conn: conn, scope: scope} do
      work_item =
        scope
        |> taken_in_fixture()
        |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      {:ok, view, html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-state", "Waits for a person")
      # Waiting on you counts no escalation, so the card addresses no one.
      refute has_element?(view, "#work-item-stage-escalation-h")
      refute render(view) =~ "waits for you"

      # The run gave no result, so there is nothing to accept.
      refute has_element?(view, "#work-item-stage-escalation-accept")
      assert has_element?(view, "#work-item-stage-escalation-another")

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
               "From attempt 1 · explore-a-ticket"
             )

      refute has_element?(view, "#work-item-stage-escalation-move")
      # No runs list above the tabs: the fold of the runs on Explore's tab has the run.
      refute html =~ "explore-a-ticket · round"

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

      # Run another round runs Explore again, in the same round, as it has no loop; the run
      # that stopped still reads as it did.
      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      assert %DispatchRun{attempt: 2} = newest_run(work_item)
      assert has_element?(view, "#work-item-step-state", "Queued")

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "2 runs"
      assert has_element?(view, "#work-item-record-fold", "Attempt 1")
      assert has_element?(view, "#work-item-record-fold", "Attempt 2")
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
      assert has_element?(view, "#work-item-stage-escalation-form")

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      assert %DispatchRun{attempt: 2} = newest_run(work_item)
      assert has_element?(view, "#work-item-step-state", "Queued")

      # The run that ended at its claim still has its line in the fold of the runs.
      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      assert line(view, "#work-item-record-fold > summary") =~ "2 runs"
      assert has_element?(view, "#work-item-record-fold", "Attempt 1")
      assert has_element?(view, "#work-item-record-fold", "Attempt 2")
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
    # required outputs and `gate` as its gate.
    defp at_shape_gate(scope, outputs, gate \\ %{"kind" => "person", "approvers" => "members"}) do
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          if stage["id"] == @shape do
            %{
              stage
              | "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => true}),
                "gate" => gate
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
      gate = %{"kind" => "person", "approvers" => %{"members" => [listed.user.id]}}
      work_item = at_shape_gate(scope, ["acceptance-criteria"], gate)
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

    test "at a gate none: the line and Add, no approval, and a real push passes it on", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_shape_gate(scope, ["acceptance-criteria"], %{"kind" => "none"})
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-stage-gate-line", "Shape needs acceptance criteria")
      assert has_element?(view, "#work-item-stage-gate-add-acceptance-criteria", "Add")
      refute has_element?(view, "#work-item-stage-gate-approvers")
      refute has_element?(view, "#work-item-stage-gate-ask-changes")
      refute has_element?(view, "#work-item-stage-gate-approve")

      {:ok, _version} =
        Stages.add_version(scope, work_item, "acceptance-criteria", markdown("ac.md"))

      assert Repo.get!(WorkItem, work_item.id).stage_id == @build
      assert decisions(work_item, :approve) == []
      assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
    end

    test "a review comment from a member Explore's gate does not list: the line under the field",
         %{
           conn: conn,
           scope: scope
         } do
      default = Processes.default_document("software")
      listed = member_fixture(scope, :member)

      stages =
        for stage <- default["stages"] do
          if stage["id"] == @explore,
            do: %{
              stage
              | "gate" => %{"kind" => "person", "approvers" => %{"members" => [listed.user.id]}}
            },
            else: stage
        end

      save!(scope, %{default | "stages" => stages})
      work_item = explore_gate_fixture(scope)

      {:ok, view, _html} =
        live(conn, page(scope, work_item.number) <> "/explore?review=new")

      view
      |> element("#work-item-review-page-form")
      |> render_submit(%{"number" => "#{work_item.number}", "text" => "Offer a refund first."})

      assert has_element?(
               view,
               "#work-item-review-page-error",
               "Ask one of this stage's approvers to comment. Only they can comment on its proposal."
             )

      assert has_element?(view, "#work-item-review-page-text", "Offer a refund first.")
      assert has_element?(view, "#work-item-review-page-text[aria-describedby]")

      assert Apiary.Explore.ReviewComments.newest(work_item) == nil
    end

    test "Run with comments from a member Explore's gate does not list: the line under the gate",
         %{conn: conn, scope: scope} do
      listed = explore_gate_listing(scope)
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(listed, work_item, 1, "Offer a refund first.")

      runs =
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)

      {:ok, view, _html} = live(conn, page(scope, work_item.number) <> "/explore")
      refute has_element?(view, "#work-item-explore-gate-error")

      view
      |> element("#work-item-explore-gate")
      |> render_submit(%{"number" => "#{work_item.number}"})

      assert has_element?(
               view,
               "#work-item-explore-gate-error[role=alert]",
               "Ask an approver of Explore to act on it."
             )

      assert Repo.aggregate(
               from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
               :count
             ) ==
               runs

      # The next move clears the line.
      view
      |> element("#work-item-explore-gate-go")
      |> render_click()

      refute has_element?(view, "#work-item-explore-gate-error")
    end

    test "at Explore with a proposal waiting and no artifact: Confirm and no needs line", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      Repo.delete_all(from a in Artifact, where: a.work_item_id == ^work_item.id)

      assert %{state: :at_gate, missing_outputs: ["proposal"]} = Stages.status(work_item, scope)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-step-explore", "Read the proposal")
      refute has_element?(view, "#work-item-stage-gate-line")
      refute has_element?(view, "#work-item-stage-gate-add-proposal")
      refute has_element?(view, "#work-item-stage-gate-output-proposal")
    end

    test "past Explore with a proposal waiting: Shape's card keeps its needs and Approve", %{
      conn: conn,
      scope: scope
    } do
      # Explore with gate none passes on to Shape while the proposal waits for Confirm.
      default = Processes.default_document("software")

      stages =
        for stage <- default["stages"] do
          case stage["id"] do
            @explore ->
              %{stage | "gate" => %{"kind" => "none"}}

            @shape ->
              %{stage | "outputs" => [%{"type" => "acceptance-criteria", "required" => true}]}

            _other ->
              stage
          end
        end

      save!(scope, %{default | "stages" => stages})
      work_item = explore_gate_fixture(scope)

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} =
               Repo.get!(WorkItem, work_item.id)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      refute has_element?(view, "#work-item-step-explore", "Read Qory's proposal")
      assert has_element?(view, "#work-item-stage-gate-line", "Shape needs acceptance criteria")
      assert has_element?(view, "#work-item-stage-gate-output-acceptance-criteria")
      assert has_element?(view, "#work-item-stage-gate-ask-changes")

      {:ok, _version} =
        Stages.add_version(scope, work_item, "acceptance-criteria", markdown("ac.md"))

      refute has_element?(view, "#work-item-stage-gate-line")
      view |> form("#work-item-stage-gate-approve") |> render_submit()
      assert Repo.get!(WorkItem, work_item.id).stage_id == @build
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

    defp check_line(view) do
      view
      |> element("#work-item-stage-check-result")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    test "for a workflow: a check that stops on an error sends the reader to support", %{
      conn: conn,
      scope: scope
    } do
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)
      work_item = at_build(scope, :waiting_workflow)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))
      WorkflowFake.check_result(scope.workspace, fn -> raise "the check failed" end)

      ExUnit.CaptureLog.capture_log(fn ->
        view |> form("#work-item-stage-check") |> render_submit()
        render_async(view)
      end)

      assert check_line(view) ==
               "Try again, and contact support if it fails again. " <>
                 "The check of the harness stopped with an error in Qory Apiary."

      Application.put_env(:apiary, :support_address, "support@example.com")

      ExUnit.CaptureLog.capture_log(fn ->
        view |> form("#work-item-stage-check") |> render_submit()
        render_async(view)
      end)

      assert has_element?(
               view,
               ~s(#work-item-stage-check-result a[href="mailto:support@example.com"]),
               "contact support"
             )

      assert check_line(view) ==
               "Try again, and contact support if it fails again. " <>
                 "The check of the harness stopped with an error in Qory Apiary."

      # A read that failed, in the harness's words, links Contact support too.
      WorkflowFake.check_result(scope.workspace, {:error, {:unreadable, :address}})
      view |> form("#work-item-stage-check") |> render_submit()
      render_async(view)

      assert has_element?(
               view,
               ~s(#work-item-stage-check-result a[href="mailto:support@example.com"]),
               "Contact support"
             )
    end

    test "a refusal the page has no words for sends the reader to support" do
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)

      assert ApiaryWeb.WorkItemLive.Show.refused(:busy, nil) ==
               "Reload the page and act again, and contact support if it fails again. " <>
                 "Qory Apiary could not act on the stage."

      Application.put_env(:apiary, :support_address, "support@example.com")

      assert ApiaryWeb.WorkItemLive.Show.refused(:busy, nil) ==
               "Reload the page and act again, and contact support at support@example.com " <>
                 "if it fails again. Qory Apiary could not act on the stage."
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
               "Reload the page. The work item is closed, so it has no stage to check."
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
        refute has_element?(view, "#work-item-stage-escalation-h")
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
      test "#{level}: Move back and Close", %{conn: conn, scope: scope} do
        conn = as(conn, scope, unquote(level))

        moved = at_build(scope, :escalated, round: 3)
        escalate!(moved, :escalate, "Blocked")
        {:ok, view, html} = live(conn, page(scope, moved.number))
        refute html =~ "waits for you"

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "Plan again", "stage" => @shape})
        |> render_submit(%{"how" => "move_back"})

        assert %Escalation{resolution: :move_back, note: "Plan again"} = escalation(moved)
        assert Repo.get!(WorkItem, moved.id).stage_id == @shape

        work_item = at_build(scope, :escalated, round: 3)
        escalate!(work_item, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        view
        |> form("#work-item-stage-escalation-form", %{"note" => ""})
        |> render_submit(%{"how" => "close"})

        assert Repo.get!(WorkItem, work_item.id).state == :closed
      end
    end

    test "Accept as it is, and Run another round", %{conn: conn, scope: scope} do
      for how <- ["accept", "another_round"] do
        work_item = at_build(scope, :escalated, round: 3)
        push!({:person, scope}, work_item, "explainer", @build)
        escalate!(work_item, :escalate, "Blocked")
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        view
        |> form("#work-item-stage-escalation-form", %{"note" => "Go on"})
        |> render_submit(%{"how" => how})

        assert %Escalation{resolution: resolution} = escalation(work_item)
        assert Atom.to_string(resolution) == how
      end
    end

    test "no result: no Accept as it is, and a sent accept is refused", %{
      conn: conn,
      scope: scope
    } do
      stopped = scope |> taken_in_fixture() |> end_run!(nil)

      # Every output of the stage is missing: the agent escalated with nothing made.
      empty = at_build(scope, :escalated, round: 3)
      escalate!(empty, :escalate, "Blocked")

      for {work_item, stage} <- [{stopped, @explore}, {empty, @build}] do
        {:ok, view, _html} = live(conn, page(scope, work_item.number))

        refute has_element?(view, "#work-item-stage-escalation-accept")
        assert has_element?(view, "#work-item-stage-escalation-another")

        render_hook(view, "stage_resolve", %{
          "number" => "#{work_item.number}",
          "seen" => stage,
          "how" => "accept",
          "note" => ""
        })

        assert %Escalation{resolution: nil} = escalation(work_item)
        assert Repo.get!(WorkItem, work_item.id).stage_state == :escalated
      end
    end

    test "the round limit at Explore's last run: Run another round queues one more run", %{
      conn: conn,
      scope: scope
    } do
      # Explore's loop of 3 rounds, each run with no result.
      explore_loop!(scope)

      work_item =
        Enum.reduce(1..3, taken_in_fixture(scope), fn _attempt, work_item ->
          end_run!(work_item, nil)
        end)

      assert %Escalation{cause: :round_limit} = escalation(work_item)
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # The step card's "the last run of this take in" is false while Run another round is
      # on the escalation card: the step card is not shown.
      assert has_element?(view, "#work-item-stage-escalation-another")
      refute has_element?(view, "#work-item-stage-escalation-accept")
      refute has_element?(view, "#work-item-step")
      refute render(view) =~ "the last run of this take in."

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "another_round"})

      assert %DispatchRun{attempt: 4, of: 4} = newest_run(work_item)

      # The round past the limit is the last before the stage escalates again: the count
      # is never under the attempt.
      assert has_element?(view, "#work-item-step-run", "Attempt 4 is queued.")
      refute render(view) =~ "4 of 3"
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
    test "close: no stage card, and the track and the head's words stay", %{
      conn: conn,
      scope: scope
    } do
      work_item = at_build(scope, :escalated, round: 3)
      escalate!(work_item, :escalate, "Blocked")
      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      view
      |> form("#work-item-stage-escalation-form", %{"note" => ""})
      |> render_submit(%{"how" => "close"})

      for view <- [view, elem(live(conn, page(scope, work_item.number)), 1)] do
        html = render(view)
        refute has_element?(view, "#work-item-stage")
        refute has_element?(view, "#work-item-stage-escalation-note")
        refute html =~ "Waits for a person"
        refute html =~ "Accept as it is"
        assert has_element?(view, ~s|#work-item-head-stages-#{@build}[aria-current="step"]|)
        refute has_element?(view, "#work-item-head-stages-#{@build}.q-wi-stage-wait")
        assert has_element?(view, "#work-item-head-meta", "Closed by you")
        refute has_element?(view, "#work-item-head-stage-status")
      end
    end
  end

  describe "the head's status" do
    for {state, words} <- [
          {:running, "Build · Running"},
          {:waiting_inputs, "Build · Waits for inputs"},
          {:waiting_answers, "Build · Needs answers"},
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

    test "past Explore, a run waiting for a machine: the stage and Queued", %{
      conn: conn,
      scope: scope
    } do
      work_item =
        scope
        |> taken_in_fixture()
        |> place!(Processes.current(scope.workspace), @build, :running)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      assert has_element?(view, "#work-item-head-stage-status", "Build · Queued")
      assert has_element?(view, "#work-item-stage-state", "Queued")
      refute has_element?(view, "#work-item-stage-line")
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
            {scope |> taken_in_fixture() |> end_run!(questions_result()), "Needs answers"},
            {explore_gate_fixture(scope), "You confirm next"}
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

    test "a review comment on the proposal is a card at Explore, for the next run", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)

      {:ok, _} =
        WorkItems.review_comment(
          scope,
          work_item,
          1,
          "Also check the total after a basket change."
        )

      {:ok, _} = WorkItems.send_review_comments(scope, work_item, 1)

      {:ok, view, _html} = live(conn, page(scope, work_item.number))

      # At Explore the review comment is a card in the right column, not a stage note.
      refute has_element?(view, "#work-item-notes-0")

      assert has_element?(
               view,
               "#work-item-review-c1",
               "Also check the total after a basket change."
             )

      assert has_element?(
               view,
               "#work-item-review-c1-reading",
               "Attempt 2 reads this review comment."
             )
    end

    test "a request for changes at Explore shows above the tabs, without runs or artifacts", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)

      {:ok, _} =
        WorkItems.review_comment(scope, work_item, 1, "Also check the total.")

      {:ok, _work_item} =
        Stages.request_changes(scope, work_item, "Change the credit note PDF too.", nil,
          expect_stage: @explore
        )

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert has_element?(view, "#work-item-notes-h", "Notes for the next run")
      assert texts(view, "#work-item-notes li > p:first-child") == ["Changes requested · Explore"]
      assert has_element?(view, "#work-item-notes-0", "Change the credit note PDF too.")

      # Only the gate's note: the review comment is a card, and the runs and the
      # artifacts are in the history fold.
      refute has_element?(view, "#work-item-flow #work-item-runs")
      refute has_element?(view, "#work-item-flow #work-item-artifacts")

      [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
      assert before_tabs =~ ~s(id="work-item-flow")
    end

    test "a move, a resolved escalation and a failed check at Explore show above the tabs; an answer does not",
         %{conn: conn, scope: scope} do
      work_item = taken_in_fixture(scope)
      work_item = end_run!(work_item, questions_result(["Which refund?"]))
      {:ok, work_item} = WorkItems.answer(scope, work_item, 1, %{"1" => "The full one."})
      at = fn seconds -> DateTime.add(DateTime.utc_now(), seconds, :second) end

      rows = %{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: work_item.process_version_id,
        stage_id: @explore
      }

      Repo.insert!(
        struct(
          GateDecision,
          Map.merge(rows, %{
            kind: :move,
            user_id: scope.user.id,
            note: "Back to Explore: name the refund rule.",
            inserted_at: at.(1)
          })
        )
      )

      Repo.insert!(
        struct(
          Escalation,
          Map.merge(rows, %{
            round: 1,
            cause: :round_limit,
            resolution: :another_round,
            note: "One more round for the refund rule.",
            resolved_by_id: scope.user.id,
            resolved_at: at.(2),
            inserted_at: at.(2)
          })
        )
      )

      Repo.insert!(
        struct(
          Apiary.Stages.Check,
          Map.merge(rows, %{round: 1, gaps: "No proposal was stored.", inserted_at: at.(3)})
        )
      )

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      assert texts(view, "#work-item-notes li > p:first-child") == [
               "Moved · Explore",
               "Escalation resolved · Explore",
               "Failed check · Explore"
             ]

      assert has_element?(view, "#work-item-notes", "Back to Explore: name the refund rule.")
      assert has_element?(view, "#work-item-notes", "One more round for the refund rule.")
      assert has_element?(view, "#work-item-notes", "No proposal was stored.")
      refute has_element?(view, "#work-item-notes", "The full one.")

      [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
      assert before_tabs =~ ~s(id="work-item-flow")
    end

    test "at Explore without a note of a gate, an escalation or a check, no block", %{
      conn: conn,
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Also check the total.")

      {:ok, view, html} = live(conn, page(scope, work_item.number) <> "/explore")

      refute has_element?(view, "#work-item-flow")
      assert has_element?(view, "#work-item-explore-proposal")

      [before_tabs, _after] = String.split(html, ~s(id="work-item-tabs"), parts: 2)
      refute before_tabs =~ ~s(id="work-item-explore-proposal")
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
      assert has_element?(index, "#work-item-#{work_item.public_id}")
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
      assert has_element?(view, "#work-items-group-0-h", "Explore")
      assert has_element?(view, "#work-items-group-0 #work-item-#{explore.public_id}")
      assert has_element?(view, "#work-items-group-1-h", "Shape")
      assert has_element?(view, "#work-items-group-1 #work-item-#{shape.public_id}")

      {:ok, view, _html} = live(conn, page(scope, explore.number))
      assert has_element?(view, ~s|#work-item-head-stages-#{@explore}[aria-current="step"]|)
      assert has_element?(view, "#work-item-step-state", "Running")

      {:ok, view, _html} = live(conn, page(scope, shape.number))
      assert has_element?(view, "#work-item-head-stages-#{@explore}.q-wi-stage-done")
      assert has_element?(view, ~s|#work-item-head-stages-#{@shape}[aria-current="step"]|)
      assert has_element?(view, "#work-item-stage-state", "At the gate")
      assert has_element?(view, "#work-item-stage-gate-approve-go", "Approve Shape")
    end
  end

  describe "the board" do
    test "a box per stage of the current version, and a removed stage's", %{
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

      assert texts(view, "#work-items-board .q-wl-st-name") ==
               ["Explore", "Shape", "Build", "Verify", "Release", "Review"]

      assert texts(view, "#work-items-board .q-wl-st-n") == ["1", "0", "1", "0", "0", "1"]

      assert has_element?(
               view,
               "#work-items-board-5-removed",
               "From version 2. This stage is not in the current version."
             )

      # A box has no link.
      refute has_element?(view, "#work-items-board a")

      assert texts(view, ".q-wl-grp h2") == ["Explore", "Build", "Review"]
      assert has_element?(view, "#work-items-group-0 #work-item-#{unplaced.public_id}")
      assert has_element?(view, "#work-items-group-2 #work-item-#{gift.public_id}")

      assert has_element?(
               view,
               ~s|#work-items-group-5 #work-item-#{basket.public_id} a[href="#{page(scope, basket.number)}"]|
             )
    end

    test "every view shows the same boxes, and its line", %{conn: conn, scope: scope} do
      backfilled!(scope, @explore, :running)
      backfilled!(scope, @shape, :at_gate)

      for {query, note} <- [
            {"", "Work items at a stage of the process. A finished one moves to Closed."},
            {"?view=you",
             "Work items that wait for you to confirm what Qory proposes. Oldest first."},
            {"?view=closed",
             "Finished work items, and work items that stopped: a member closed one or undid its take in, its ticket closed, or its integration was removed. Where the ticket of a stopped one is still in the Backlog, Take in again brings it back."}
          ] do
        {:ok, view, _html} = live(conn, list(scope) <> query)

        assert texts(view, "#work-items-board .q-wl-st-name") ==
                 ["Explore", "Shape", "Build", "Verify", "Release"]

        assert texts(view, "#work-items-board .q-wl-st-n") == ["1", "1", "0", "0", "0"]
        assert texts(view, "#work-items-note") == [note]
        refute has_element?(view, "#work-items-stages")
      end
    end

    test "the Open view groups its rows by stage, with no group at 0 and no control", %{
      conn: conn,
      scope: scope
    } do
      explored = backfilled!(scope, @explore, :running)
      shaped = backfilled!(scope, @shape, :at_gate)
      {:ok, view, _html} = live(conn, list(scope))

      assert texts(view, ".q-wl-grp h2") == ["Explore", "Shape"]
      assert texts(view, ".q-wl-grp .q-band-n") == ["1", "1"]
      assert has_element?(view, "#work-items-group-0 #work-item-#{explored.public_id}")
      assert has_element?(view, "#work-items-group-1 #work-item-#{shaped.public_id}")

      refute has_element?(view, "#work-items-rows")
      refute has_element?(view, ".q-wl-grp button")
      refute has_element?(view, ".q-wl-fold")
    end

    test "a row under its group shows the state; the group shows the stage", %{
      conn: conn,
      scope: scope
    } do
      queued = taken_in_fixture(scope)
      shaped = shape_gate_fixture(scope)
      stopped = scope |> taken_in_fixture() |> end_run!(nil)

      built =
        scope
        |> shape_gate_fixture()
        |> place!(Processes.current(scope.workspace), @build, :waiting_inputs)

      row = &"#work-items-groups #work-item-#{&1.public_id} .q-wl-nx"
      {:ok, view, _html} = live(conn, list(scope))

      assert has_element?(view, row.(queued), "Explore is queued")
      assert texts(view, row.(shaped)) == ["At the gate"]
      assert texts(view, row.(stopped)) == ["Waits for a person"]
      assert texts(view, row.(built)) == ["Waits for inputs"]
    end

    test "search and filters keep the groups, the boxes count what they keep", %{
      conn: conn,
      scope: scope
    } do
      gift =
        scope
        |> work_item_fixture(%{title: "Add gift cards to checkout"})
        |> place!(Processes.current(scope.workspace), @build, :running)

      work_item_fixture(scope, %{title: "Fix the basket total"})

      {:ok, view, _html} = live(conn, list(scope) <> "?q=gift")

      assert texts(view, "#work-items-board .q-wl-st-n") == ["0", "0", "1", "0", "0"]
      assert texts(view, ".q-wl-grp h2") == ["Build"]
      assert texts(view, ".q-wl-grp .q-band-n") == ["1"]
      assert has_element?(view, "#work-items-group-2 #work-item-#{gift.public_id}")
      refute has_element?(view, ".q-wl-fold")

      {:ok, view, _html} = live(conn, list(scope) <> "?q=nothing+like+it")
      assert texts(view, "#work-items-board .q-wl-st-n") == ["0", "0", "0", "0", "0"]
      refute has_element?(view, ".q-wl-grp")
    end

    test "Waiting on you and Closed stay plain rows", %{conn: conn, scope: scope} do
      closed = work_item_fixture(scope, %{title: "Fix the basket total"})
      {:ok, _closed} = WorkItems.close(scope, closed)

      {:ok, view, _html} = live(conn, list(scope) <> "?view=closed")
      assert has_element?(view, "#work-items-rows #work-item-#{closed.public_id}")
      refute has_element?(view, "#work-items-groups")

      waiting =
        scope
        |> explore_gate_fixture()
        |> place!(Processes.current(scope.workspace), @build, :waiting_inputs)

      {:ok, view, _html} = live(conn, list(scope) <> "?view=you")
      refute has_element?(view, "#work-items-groups")

      # With no group above it, a row keeps its stage's name.
      assert texts(view, "#work-items-rows #work-item-#{waiting.public_id} .q-wl-nx") ==
               ["Build · Waits for inputs"]
    end

    test "an address with a stage shows that stage alone, under the boxes, with no control", %{
      conn: conn,
      scope: scope
    } do
      work_item = taken_in_fixture(scope)
      {:ok, view, _html} = live(conn, list(scope) <> "?stage=explore")

      assert has_element?(view, "#work-items-board")
      refute has_element?(view, "#work-items-stages")
      assert texts(view, ".q-wl-grp h2") == ["Explore"]
      assert has_element?(view, "#work-items-explore #work-item-#{work_item.public_id}")
      refute has_element?(view, ".q-wl-fold")
    end

    test "past a page, a group counts its whole stage and the pager stays", %{
      conn: conn,
      scope: scope
    } do
      for _n <- 1..(WorkList.page_size() + 1), do: work_item_fixture(scope)
      {:ok, view, _html} = live(conn, list(scope))

      assert texts(view, ".q-wl-grp .q-band-n") == ["#{WorkList.page_size() + 1}"]
      assert has_element?(view, "#work-items-pager")
    end

    test "a row shows a title without invisible characters, and the mark Test", %{
      conn: conn,
      scope: scope
    } do
      {:ok, line} = WorkItems.take_in_test(scope, "Hello! Where are you running?")
      basket = work_item_fixture(scope, %{title: "Basket \u202Eflow"})

      {:ok, view, html} = live(conn, list(scope))
      item = &"#work-items-group-0 #work-item-#{&1.public_id}"

      refute html =~ "\u202E"
      assert has_element?(view, item.(basket), "Basket flow")
      refute has_element?(view, item.(basket) <> " .badge")
      assert has_element?(view, item.(line) <> " .badge", "Test")
      assert has_element?(view, ~s|#{item.(line)} a[href="#{page(scope, line.number)}"]|)
    end

    test "each group in the list's sort", %{conn: conn, scope: scope} do
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
        |> LazyHTML.query("#work-items-group-0 li")
        |> LazyHTML.attribute("id")
      end

      ids = &Enum.map(&1, fn work_item -> "work-item-#{work_item.public_id}" end)

      {:ok, view, _html} = live(conn, list(scope))
      assert order.(view) == ids.([older, newer])

      {:ok, view, _html} = live(conn, list(scope) <> "?sort=created")
      assert order.(view) == ids.([newer, older])
    end

    test "a message of the workspace's work items reads the board and the groups again", %{
      conn: conn,
      scope: scope
    } do
      work_item = backfilled!(scope, @explore, :running)
      {:ok, view, _html} = live(conn, list(scope))

      assert texts(view, "#work-items-board .q-wl-st-n") == ["1", "0", "0", "0", "0"]
      assert has_element?(view, "#work-items-group-0 #work-item-#{work_item.public_id}")

      place!(work_item, Processes.current(scope.workspace), @shape, :at_gate)

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        WorkItems.topic(scope.workspace.id),
        {:work_items_changed, [work_item.public_id]}
      )

      assert has_element?(view, "#work-items-group-1 #work-item-#{work_item.public_id}")
      assert texts(view, "#work-items-board .q-wl-st-n") == ["0", "1", "0", "0", "0"]
    end
  end
end
