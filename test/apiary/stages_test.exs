defmodule Apiary.StagesTest do
  # The stage runner with the workflow model on (`Apiary.Stages`): a take in enters the
  # first stage and queues explore-a-ticket through today's dispatch; a run's end through
  # its settle maps today's explore result into artifacts (D1); the gate, the escalations,
  # moves, and what the work item page reads.
  # Not async: a test sets the store adapter, the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{ArtifactStoreHook, Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Confirmation, Moves, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp take_in!(scope), do: taken_in_fixture(scope)

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp runs(work_item),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [r.take_in, r.attempt]
      )

  defp artifacts(work_item), do: Artifacts.list(work_item)

  defp versions(work_item, type) do
    for a <- artifacts(work_item), a.type == type, v <- a.versions, do: v
  end

  defp escalation(work_item),
    do:
      Repo.one(
        from e in Escalation, where: e.work_item_id == ^work_item.id and is_nil(e.resolved_at)
      )

  defp decisions(work_item),
    do:
      Repo.all(
        from d in GateDecision, where: d.work_item_id == ^work_item.id, order_by: d.inserted_at
      )

  defp save!(scope, stages) do
    document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
    {:ok, version} = Processes.save(scope, scope.workspace, document)
    version
  end

  defp stage(id, name, sequence, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "inputs" => [],
        "sequence" => sequence,
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      extra
    )
  end

  defp a_proposal, do: Stages.proposal_document(understood_result())

  defp explore_stage(extra \\ %{}) do
    stage(
      @explore,
      "Explore",
      [%{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}],
      Map.merge(%{"outputs" => [%{"type" => "proposal", "required" => true}]}, extra)
    )
  end

  describe "take in" do
    test "enters the first stage and queues explore-a-ticket through today's dispatch", %{
      scope: scope
    } do
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(scope.workspace.id))
      work_item = take_in!(scope)
      version = Processes.current(scope.workspace)

      assert %WorkItem{
               process_version_id: version_id,
               stage_id: @explore,
               stage_state: :running,
               stage_round: 1,
               stage_entry: 0,
               loop_entry: 0
             } = work_item

      assert version_id == version.id

      assert [run] = runs(work_item)

      assert %DispatchRun{
               step: "explore",
               take_in: 1,
               attempt: 1,
               of: 3,
               state: :waiting,
               stage_id: @explore,
               round: 1,
               stage_entry: 0,
               loop_entry: 0,
               workflow: "explore-a-ticket",
               machine_type: "default"
             } = run

      assert run.process_version_id == version.id

      # The work items' topic of the workspace gets only its message, which every Work items
      # list reads; the stage's change goes on the work item's topic (`Stages.topic/1`).
      public_id = work_item.public_id
      assert_receive {:work_items_changed, [^public_id]}
      refute_received {:stage_changed, _id}
    end

    test "with no snapshot of the harness's workflows, starts the run", %{scope: scope} do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope)

      assert work_item.stage_state == :running
      assert [%DispatchRun{workflow: "capture-demo"}] = runs(work_item)
    end

    test "starts a workflow the snapshot lists", %{scope: scope} do
      :ok = Processes.record_declared(scope.workspace, ["capture-demo"])
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])

      assert [%DispatchRun{workflow: "capture-demo"}] = scope |> take_in!() |> runs()
    end

    test "waits for a workflow the snapshot does not list, until a check finds it", %{
      scope: scope
    } do
      # A harness repository is chosen; the Qory harness has a different line (the next test).
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: scope.workspace.organisation_id,
        workspace_id: scope.workspace.id,
        choice: :repository,
        version_kind: :commit,
        version_name: String.duplicate("c3", 20),
        harness: "extends:\n  git: https://code.example.com/acme/harness\n  stack: core\n"
      })

      :ok = Processes.record_declared(scope.workspace, ["review"])
      %{read_at: read_at} = Processes.declared_snapshot(scope.workspace)
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope)

      assert work_item.stage_state == :waiting_workflow
      assert runs(work_item) == []

      time = Calendar.strftime(read_at, "%Y-%m-%d %H:%M UTC")

      assert %{state: :waiting_workflow, waiting_workflow: "capture-demo", gaps: gaps} =
               Stages.status(work_item)

      assert gaps ==
               "Explore uses capture-demo, which #{scope.workspace.name}'s harness did not " <>
                 "list at #{time}. Check again, or choose another workflow for Explore."

      read = fn names -> fn _scope, _workspace -> {:ok, names} end end

      assert Stages.check_workflows(scope, work_item, read.(["review"])) ==
               {:error, :still_missing}

      assert Stages.check_workflows(scope, work_item, fn _scope, _workspace ->
               {:error, {:limited, 30}}
             end) == {:error, {:limited, 30}}

      assert {:ok, %WorkItem{stage_state: :running}} =
               Stages.check_workflows(scope, work_item, read.(["review", "capture-demo"]))

      assert %{names: ["capture-demo", "review"]} = Processes.declared_snapshot(scope.workspace)

      assert [%DispatchRun{workflow: "capture-demo"}] = runs(work_item)

      other = sign_up_fixture().scope
      assert Stages.check_workflows(other, work_item, read.([])) == {:error, :not_found}
    end

    test "on a harness repository whose snapshot does not list the Explore workflow, Explore waits",
         %{scope: scope} do
      Repo.insert!(%Apiary.Stacks.Stack{
        organisation_id: scope.workspace.organisation_id,
        workspace_id: scope.workspace.id,
        choice: :repository,
        version_kind: :commit,
        version_name: String.duplicate("c3", 20),
        harness: "extends:\n  git: https://code.example.com/acme/harness\n  stack: core\n"
      })

      :ok = Processes.record_declared(scope.workspace, ["review"])
      work_item = take_in!(scope)

      assert work_item.stage_state == :waiting_workflow
      assert runs(work_item) == []

      assert %{waiting_workflow: "explore-a-ticket"} = Stages.status(work_item)
    end

    test "on the Qory harness with a snapshot that does not list it, Explore starts", %{
      scope: scope
    } do
      :ok = Processes.record_declared(scope.workspace, [])
      work_item = take_in!(scope)

      assert work_item.stage_state == :running
      assert [%DispatchRun{workflow: "explore-a-ticket"}] = runs(work_item)
    end

    test "Check again on the Qory harness reads nothing and records the Qory names", %{
      scope: scope
    } do
      :ok = Processes.record_declared(scope.workspace, ["review"])
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope)
      assert work_item.stage_state == :waiting_workflow

      # The waiting line has no time of a read, and Check again is not its fix.
      assert Stages.status(work_item).gaps ==
               "Explore uses capture-demo, which the Qory harness does not list. Choose " <>
                 "another workflow for Explore, or choose a harness that lists capture-demo " <>
                 "under workflows on the Workflow page."

      # No adapter and no public host is called: the default read takes the Qory names.
      for stub <- [Apiary.Adapters.Calls, Apiary.Harnesses.PublicGit] do
        Req.Test.stub(stub, fn _conn -> raise "the Qory harness was read" end)
      end

      assert Stages.check_workflows(scope, work_item) == {:error, :still_missing}
      assert %{names: ["explore-a-ticket"]} = Processes.declared_snapshot(scope.workspace)
    end

    test "passes through a stage with no workflow and no gate", %{scope: scope} do
      save!(scope, [
        stage("st_aaaaaaaaaa", "Intake", [], %{"gate" => %{"kind" => "none"}}),
        explore_stage()
      ])

      work_item = take_in!(scope)
      assert work_item.stage_id == @explore
      assert [%DispatchRun{stage_id: @explore}] = runs(work_item)
    end

    test "waits for a required input", %{scope: scope} do
      save!(scope, [
        explore_stage(%{"inputs" => [%{"type" => "acceptance-criteria", "required" => true}]})
      ])

      work_item = take_in!(scope)
      assert work_item.stage_state == :waiting_inputs
      assert runs(work_item) == []

      assert [%{type: "acceptance-criteria", required: true, version: nil}] =
               Stages.inputs(work_item)

      {:ok, _version} =
        Artifacts.push(
          {:person, scope},
          work_item,
          "acceptance-criteria",
          [%{filename: "criteria.md", binary: "- The price is the sale price."}],
          stage_id: @explore
        )

      assert {:ok, %WorkItem{stage_state: :running}} = Stages.resume(work_item)
      assert [%{version: %{number: 1, writer: :person, approvals: []}}] = Stages.inputs(work_item)
      assert [%DispatchRun{workflow: "explore-a-ticket"}] = runs(work_item)
    end
  end

  describe "the D1 mapping of an explore result" do
    test "a proposal becomes a proposal version and a verdict passed; the gate opens", %{
      scope: scope
    } do
      work_item = take_in!(scope)
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(scope.workspace.id))
      :ok = Stages.subscribe(work_item)
      assert Stages.topic(work_item) == "stages:work_item:" <> work_item.public_id
      work_item = end_run!(work_item, understood_result())

      assert work_item.stage_state == :at_gate
      run = newest_run(work_item)

      assert [%{writer: :run, number: 1, stage_id: @explore} = proposal] =
               versions(work_item, "proposal")

      assert proposal.run_id == run.id
      assert [%{writer: :run} = verdict] = versions(work_item, "verdict")
      assert Stages.Artifacts.read_json(verdict) == %{"verdict" => "passed"}

      assert Stages.Artifacts.read_json(proposal) ==
               Map.drop(understood_result(), ["version", "verdict"])

      status = Stages.status(work_item, scope)

      assert %{stage: %{id: @explore, name: "Explore"}, state: :at_gate, round: 1, rounds: 3} =
               status

      assert [%{type: "proposal", required: true, check: :passed, version: %{number: 1}}] =
               status.outputs

      assert status.gate.approvable?
      refute Stages.status(work_item).gate.approvable?

      assert [
               %{
                 workflow: "explore-a-ticket",
                 stage_id: @explore,
                 round: 1,
                 of: 3,
                 status: :ended,
                 verdict: :passed,
                 ended_at: %DateTime{}
               } = run
             ] = Stages.runs(work_item)

      assert Map.keys(run) |> Enum.sort() ==
               ~w(attempt ended_at id of round stage_id started_at status take_in verdict workflow)a

      public_id = work_item.public_id
      assert_receive {:stage_changed, ^public_id}
      assert_receive {:work_items_changed, [^public_id]}

      # Nothing but `{:work_items_changed, ids}` reaches the work items' topic.
      refute_received {:stage_changed, _id}
    end

    test "questions wait for answers; the answers run the same workflow as round 2", %{
      scope: scope
    } do
      work_item = take_in!(scope)
      work_item = end_run!(work_item, questions_result())

      assert work_item.stage_state == :waiting_answers
      assert [questions] = versions(work_item, "questions")

      assert Stages.Artifacts.read_json(questions)["questions"] == [
               "Which basket?",
               "Which sale?"
             ]

      {:ok, _work_item} =
        WorkItems.answer(scope, work_item, 1, %{"1" => "The main one", "2" => "Spring"})

      work_item = reload(work_item)

      assert %{stage_state: :running, stage_round: 2} = work_item

      assert %DispatchRun{
               attempt: 2,
               of: 3,
               round: 2,
               loop_entry: 0,
               workflow: "explore-a-ticket"
             } =
               newest_run(work_item)
    end

    test "questions in the last round escalate round_limit", %{scope: scope} do
      work_item = take_in!(scope)

      work_item =
        Enum.reduce(1..2, work_item, fn attempt, work_item ->
          work_item = end_run!(work_item, questions_result())
          {:ok, _} = WorkItems.answer(scope, work_item, attempt, %{"1" => "a", "2" => "b"})
          reload(work_item)
        end)

      work_item = end_run!(work_item, questions_result())
      assert work_item.stage_state == :escalated

      assert %Escalation{cause: :round_limit, round: 3, gaps: "Which basket?\nWhich sale?"} =
               escalation(work_item)
    end

    test "a run without a result escalates run_stopped with the cause", %{scope: scope} do
      work_item = take_in!(scope)
      work_item = end_run!(work_item, nil)
      run = newest_run(work_item)

      assert work_item.stage_state == :escalated

      assert %Escalation{cause: :run_stopped, round: 1, gaps: "The run ended without a result."} =
               escalation = escalation(work_item)

      assert escalation.run_id == run.id
      assert %{escalation: %{cause: :run_stopped, run: %{attempt: 1}}} = Stages.status(work_item)
    end

    test "a result that fails its schema escalates run_stopped", %{scope: scope} do
      work_item = take_in!(scope)
      work_item = end_run!(work_item, %{"version" => 1, "verdict" => "understood"})

      assert %Escalation{
               cause: :run_stopped,
               gaps: "The run's result does not match the explore result schema."
             } =
               escalation(work_item)
    end

    test "a lost run escalates run_stopped", %{scope: scope} do
      work_item = take_in!(scope)
      run = newest_run(work_item)
      run |> Ecto.Changeset.change(state: :ended, end_cause: :lost) |> Repo.update!()

      {:ok, told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert told == [{:work_item, work_item.workspace_id, work_item.public_id}]

      assert %Escalation{
               cause: :run_stopped,
               gaps: "The run stopped reporting and was marked lost."
             } =
               escalation(work_item)
    end

    test "a run queued before its work item was placed counts for the stage it is in", %{
      scope: scope
    } do
      work_item = take_in!(scope)

      newest_run(work_item)
      |> Ecto.Changeset.change(
        stage_id: nil,
        round: nil,
        stage_entry: nil,
        loop_entry: nil,
        workflow: nil,
        machine_type: nil,
        process_version_id: nil
      )
      |> Repo.update!()

      assert %WorkItem{stage_state: :at_gate} = end_run!(work_item, understood_result())
    end

    test "a run's end is read once: a second settle changes nothing", %{scope: scope} do
      work_item = take_in!(scope)
      work_item = end_run!(work_item, understood_result())
      run = newest_run(work_item)

      assert Settle.settle(run.id) == []
      assert {:ok, []} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert length(versions(work_item, "proposal")) == 1
    end

    test "a stage's missing required output escalates check_failed with no loop", %{scope: scope} do
      save!(scope, [
        stage(@explore, "Explore", [%{"workflow" => "explore-a-ticket"}], %{
          "outputs" => [
            %{"type" => "proposal", "required" => true},
            %{"type" => "mockup", "required" => true},
            %{"type" => "change", "required" => true, "check" => %{"reported" => "checks-passed"}}
          ]
        })
      ])

      work_item = take_in!(scope)
      assert %DispatchRun{loop_entry: nil, of: 3} = newest_run(work_item)
      work_item = end_run!(work_item, understood_result())

      assert %Escalation{cause: :check_failed, gaps: "No mockup was stored in this stage."} =
               escalation(work_item)

      assert [%{check: :passed}, %{check: :missing}, %{check: :not_checked}] =
               Stages.status(work_item).outputs
    end
  end

  describe "failed checks in a loop" do
    test "start the next round with their gaps, which status, notes and the escalation show",
         %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "outputs" => [
            %{"type" => "proposal", "required" => true},
            %{"type" => "mockup", "required" => true}
          ]
        })
      ])

      gaps = "No mockup was stored in this stage."
      work_item = take_in!(scope) |> end_run!(understood_result())

      assert %WorkItem{stage_state: :running, stage_round: 2} = work_item
      assert %DispatchRun{round: 2} = newest_run(work_item)
      assert %{gaps: ^gaps, escalation: nil} = Stages.status(work_item)

      assert [%{kind: :check, stage_id: @explore, user_id: nil, note: ^gaps}] =
               Stages.notes(work_item)

      work_item = work_item |> end_run!(understood_result()) |> end_run!(understood_result())

      assert %Escalation{cause: :round_limit, gaps: ^gaps} = escalation(work_item)
      assert %{gaps: ^gaps} = Stages.status(work_item)
      assert [%{kind: :check}, %{kind: :check}] = Stages.notes(work_item)
    end
  end

  describe "Explore's gate" do
    test "a confirmation approves the gate with the proposal version; Shape starts at its gate",
         %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())
      [proposal] = versions(work_item, "proposal")

      assert {:ok, %WorkItem{}} = WorkItems.confirm(scope, work_item, 1)
      work_item = reload(work_item)

      assert %{stage_id: @shape, stage_state: :at_gate} = work_item

      assert [%GateDecision{kind: :approve, stage_id: @explore, versions: [covered]}] =
               decisions(work_item)

      assert covered == proposal.public_id
      assert Repo.get_by(Confirmation, work_item_id: work_item.id)

      # The confirmation's entry is the act's one entry in the trail.
      refute Repo.exists?(
               from e in Entry,
                 where: e.action == "gate.approve" and e.subject_id == ^work_item.id
             )

      {:ok, _work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      assert Repo.one(
               from e in Entry,
                 where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
                 select: e.details
             ) == %{"change" => "approve", "stage_id" => @shape, "versions" => []}
    end

    test "a confirmation with edits stores the person's proposal version, which it approves",
         %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())

      params = %{
        "complexity" => %{"level" => "complex", "reason" => "Two screens read the price."},
        "understanding" => "The basket keeps an old price.",
        "scope_in" => "Read the sale price in the basket",
        "scope_out" => "The invoice",
        "approach" => "Read the price from the catalogue each time."
      }

      assert {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1, params)

      assert [%{number: 2, writer: :person} = edited, %{number: 1}] =
               Enum.sort_by(versions(work_item, "proposal"), & &1.number, :desc)

      document = Stages.Artifacts.read_json(edited)
      assert document["understanding"] == "The basket keeps an old price."
      assert document["complexity"]["level"] == "complex"
      assert [%GateDecision{versions: [covered]}] = decisions(work_item)
      assert covered == edited.public_id
    end

    test "approve confirms today's proposal too", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())

      assert {:ok, %WorkItem{stage_id: @shape}} =
               Stages.approve(scope, work_item, "Looks right",
                 expect_stage: reload(work_item).stage_id
               )

      assert %Confirmation{changes: changes} =
               Repo.get_by(Confirmation, work_item_id: work_item.id)

      assert changes == %{}
      assert [%GateDecision{note: "Looks right"}] = decisions(work_item)
    end

    test "approve is refused away from the gate", %{scope: scope} do
      work_item = take_in!(scope)

      assert Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id) ==
               {:error, :not_at_gate}
    end

    test "request changes reruns the loop from round 1, with the note and its version", %{
      scope: scope
    } do
      work_item = take_in!(scope) |> end_run!(understood_result())
      [proposal] = versions(work_item, "proposal")

      assert Stages.request_changes(scope, work_item, "x", "av_0000000000000000",
               expect_stage: reload(work_item).stage_id
             ) ==
               {:error, :not_found}

      assert {:ok, %WorkItem{stage_state: :running, stage_round: 1}} =
               Stages.request_changes(
                 scope,
                 work_item,
                 "Leave out the invoice",
                 proposal.public_id,
                 expect_stage: reload(work_item).stage_id
               )

      assert [%GateDecision{kind: :request_changes, note: "Leave out the invoice"} = decision] =
               decisions(work_item)

      assert decision.artifact_version_id == proposal.public_id
      assert %DispatchRun{attempt: 2, of: 4, round: 1} = newest_run(work_item)
    end

    test "only the listed approvers approve", %{scope: scope} do
      member = member_fixture(scope)

      save!(scope, [
        explore_stage(%{
          "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
        }),
        stage(@shape, "Shape", [])
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())

      assert Stages.approve(member.scope, work_item, nil,
               expect_stage: reload(work_item).stage_id
             ) == {:error, :not_approver}

      refute Stages.status(work_item, member.scope).gate.approvable?

      assert {:ok, %WorkItem{stage_id: @shape}} =
               Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)
    end

    test "a new output version after the last stage's approval reopens its gate", %{scope: scope} do
      save!(scope, [explore_stage()])
      work_item = take_in!(scope) |> end_run!(understood_result())

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      assert %{stage_state: :done} = reload(work_item)
      assert Stages.status(work_item).state == :done

      {:ok, _version} =
        Stages.Artifacts.push_json({:person, scope}, work_item, "proposal", a_proposal(),
          stage_id: @explore
        )

      assert %{state: :at_gate, gate: %{approvals: [%{versions: [%{number: 1, newer?: true}]}]}} =
               Stages.status(work_item)
    end
  end

  describe "a stage with no workflow (§ 4)" do
    defp people_process!(scope, gate, outputs) do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{
          "outputs" => Enum.map(outputs, &%{"type" => &1, "required" => true}),
          "gate" => gate
        }),
        stage(@build, "Build", [])
      ])
    end

    defp at_shape!(scope) do
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      reload(work_item)
    end

    defp file(name), do: [%{filename: name, content_type: "text/markdown", binary: "# Done"}]
    defp png(name), do: [%{filename: name, content_type: "image/png", binary: @png}]

    test "waits at its gate for a missing output; approve is refused until a person adds it",
         %{scope: scope} do
      people_process!(scope, %{"kind" => "person", "approvers" => "members"}, [
        "acceptance-criteria"
      ])

      work_item = at_shape!(scope)

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      refute escalation(work_item)
      assert Stages.missing_outputs(work_item) == ["acceptance-criteria"]

      assert %{state: :at_gate, missing_outputs: ["acceptance-criteria"], gate: gate} =
               Stages.status(work_item, scope)

      refute gate.approvable?

      assert Stages.approve(scope, work_item, nil, expect_stage: @shape) ==
               {:error, {:outputs_missing, ["acceptance-criteria"]}}

      assert [%GateDecision{stage_id: @explore}] = decisions(work_item)

      assert {:ok, version} =
               Stages.add_version(scope, work_item, "acceptance-criteria", file("ac.md"))

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = reload(work_item)
      assert Stages.missing_outputs(work_item) == []
      assert %{missing_outputs: [], gate: %{approvable?: true}} = Stages.status(work_item, scope)

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.approve(scope, work_item, nil, expect_stage: @shape)

      assert [_explore, %GateDecision{stage_id: @shape, versions: [covered]}] =
               decisions(work_item)

      assert covered == version.public_id
    end

    test "with gate none passes on once a person adds the last required output", %{
      scope: scope
    } do
      people_process!(scope, %{"kind" => "none"}, ["acceptance-criteria", "mockup"])
      work_item = at_shape!(scope)

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      refute escalation(work_item)

      {:ok, _version} = Stages.add_version(scope, work_item, "acceptance-criteria", file("a.md"))
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = reload(work_item)
      assert Stages.missing_outputs(work_item) == ["mockup"]

      {:ok, _version} = Stages.add_version(scope, work_item, "mockup", png("m.png"))
      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = reload(work_item)
    end

    test "a person's version gets the stage_id of the stage the work item is in", %{
      scope: scope
    } do
      work_item = take_in!(scope)

      assert {:ok, %{stage_id: @explore, writer: :person}} =
               Stages.add_version(scope, work_item, "mockup", png("m.png"), stage_id: @build)

      # A stage with a workflow is left as it is.
      assert %WorkItem{stage_id: @explore, stage_state: :running} = reload(work_item)
      assert [_one] = runs(work_item)
    end

    test "a person's version starts a stage that waits for inputs once the last one exists",
         %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "inputs" => [
            %{"type" => "acceptance-criteria", "required" => true},
            %{"type" => "mockup", "required" => true}
          ]
        })
      ])

      work_item = take_in!(scope)
      assert work_item.stage_state == :waiting_inputs

      {:ok, _version} = Stages.add_version(scope, work_item, "acceptance-criteria", file("a.md"))
      assert %WorkItem{stage_state: :waiting_inputs} = reload(work_item)
      assert runs(work_item) == []

      {:ok, _version} = Stages.add_version(scope, work_item, "mockup", png("m.png"))
      assert %WorkItem{stage_id: @explore, stage_state: :running} = reload(work_item)
      assert [%DispatchRun{workflow: "explore-a-ticket"}] = runs(work_item)
    end

    test "a stage change during the push stores nothing and leaves the stage as it is", %{
      scope: scope
    } do
      input = %{"inputs" => [%{"type" => "acceptance-criteria", "required" => true}]}
      save!(scope, [explore_stage(input), stage(@shape, "Shape", [], input)])

      work_item = take_in!(scope)

      # The input exists and nothing acted on it, so a call to version_added/1 starts the
      # stage the work item moves to.
      {:ok, _version} =
        Artifacts.push({:person, scope}, work_item, "acceptance-criteria", file("a.md"),
          stage_id: @explore
        )

      ArtifactStoreHook.on_commit(fn ->
        {1, _rows} =
          Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
            set: [stage_id: @shape]
          )
      end)

      assert Stages.add_version(scope, work_item, "mockup", png("m.png")) ==
               {:error, :stage_changed}

      assert versions(work_item, "mockup") == []
      assert %WorkItem{stage_id: @shape, stage_state: :waiting_inputs} = reload(work_item)
      assert runs(work_item) == []
    end

    test "a person's version leaves a closed work item waiting for inputs as it is", %{
      scope: scope
    } do
      save!(scope, [
        explore_stage(%{"inputs" => [%{"type" => "acceptance-criteria", "required" => true}]})
      ])

      work_item = take_in!(scope)
      assert work_item.stage_state == :waiting_inputs
      {:ok, _closed} = Moves.close(scope, work_item)

      {:ok, _version} = Stages.add_version(scope, work_item, "acceptance-criteria", file("a.md"))

      assert %WorkItem{state: :closed, stage_state: :waiting_inputs} = reload(work_item)
      assert runs(work_item) == []
    end

    test "a person's version leaves a closed work item at a gate none as it is", %{scope: scope} do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{
          "outputs" => [%{"type" => "mockup", "required" => true}],
          "gate" => %{"kind" => "none"}
        }),
        stage(@build, "Build", [%{"workflow" => "explore-a-ticket"}])
      ])

      work_item = at_shape!(scope)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      {:ok, _closed} = Moves.close(scope, work_item)
      run_count = length(runs(work_item))

      {:ok, _version} = Stages.add_version(scope, work_item, "mockup", png("m.png"))

      assert %WorkItem{state: :closed, stage_id: @shape, stage_state: :at_gate} =
               reload(work_item)

      assert length(runs(work_item)) == run_count
    end
  end

  describe "a work item the runner has not placed" do
    setup %{scope: scope} do
      work_item = take_in!(scope)

      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [stage_id: nil, stage_state: nil]
      )

      %{work_item: reload(work_item)}
    end

    test "resume returns not_placed", %{work_item: work_item} do
      assert Stages.resume(work_item) == {:error, :not_placed}
    end

    test "check_workflows returns not_placed", %{scope: scope, work_item: work_item} do
      assert Stages.check_workflows(scope, work_item, fn _scope, _workspace -> {:ok, []} end) ==
               {:error, :not_placed}
    end

    test "version_added returns not_placed", %{work_item: work_item} do
      assert Stages.version_added(work_item) == {:error, :not_placed}
    end
  end

  describe "inputs and the artifact index" do
    test "the next stage reads the approved version; a newer one is changed after approval", %{
      scope: scope
    } do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{"inputs" => [%{"type" => "proposal", "required" => true}]})
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      [proposal] = versions(work_item, "proposal")

      assert reload(work_item).stage_state == :at_gate

      assert [
               %{
                 type: "proposal",
                 required: true,
                 version: %{id: id, writer: :run, approvals: [%{stage_id: @explore}]}
               }
             ] = Stages.inputs(work_item)

      assert id == proposal.public_id

      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, newest_run(work_item)},
          work_item,
          "proposal",
          a_proposal(),
          stage_id: @explore
        )

      assert [%{id: ^id}] = Enum.map(Stages.inputs(work_item), & &1.version)

      user_id = scope.user.id

      assert [
               %{
                 type: "proposal",
                 stage_id: @explore,
                 approved_version: ^id,
                 changed_after_approval: true,
                 versions: [
                   %{number: 2, approvals: [], files: [_file]},
                   %{
                     id: ^id,
                     number: 1,
                     approvals: [%{user_id: ^user_id, stage_id: @explore}]
                   }
                 ]
               },
               %{type: "verdict", approved_version: nil, changed_after_approval: false}
             ] = Stages.artifact_index(work_item)
    end
  end

  describe "notes" do
    test "are the requests for changes, escalation notes, moves and answers, oldest first",
         %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The sale price", "2" => "Yes"})
      work_item = end_run!(work_item, nil)

      {:ok, _} =
        Stages.resolve_escalation(scope, work_item, :another_round, "Read the cart",
          expect_stage: reload(work_item).stage_id
        )

      work_item = end_run!(work_item, understood_result())
      [proposal] = versions(work_item, "proposal")

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Name the price rule", proposal.public_id,
          expect_stage: reload(work_item).stage_id
        )

      {:ok, _} =
        Stages.move(scope, work_item, @shape, "Shaped enough",
          expect_stage: reload(work_item).stage_id
        )

      user_id = scope.user.id
      proposal_id = proposal.public_id

      assert [
               %{kind: :answer, stage_id: @explore, user_id: ^user_id, note: "The sale price"},
               %{kind: :answer, note: "Yes"},
               %{kind: :escalation, stage_id: @explore, user_id: ^user_id, note: "Read the cart"},
               %{
                 kind: :request_changes,
                 stage_id: @explore,
                 note: "Name the price rule",
                 artifact_version_id: ^proposal_id
               },
               %{kind: :move, stage_id: @explore, note: "Shaped enough"}
             ] = Stages.notes(work_item)
    end
  end

  describe "escalations" do
    setup %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(nil)
      %{work_item: work_item}
    end

    test "another round reruns the workflow as the next round, with the note", %{
      scope: scope,
      work_item: work_item
    } do
      assert {:ok, %WorkItem{stage_state: :running, stage_round: 2}} =
               Stages.resolve_escalation(scope, work_item, :another_round, "Read the sale page",
                 expect_stage: reload(work_item).stage_id
               )

      assert %DispatchRun{attempt: 2, round: 2} = newest_run(work_item)

      assert %Escalation{resolution: :another_round, note: "Read the sale page"} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert Repo.one(
               from e in Entry,
                 where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
                 select: e.details
             ) == %{
               "change" => "escalation_another_round",
               "stage_id" => @explore,
               "cause" => "run_stopped"
             }
    end

    test "Explore again resolves it as another round", %{scope: scope, work_item: work_item} do
      assert {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
      assert %{stage_state: :running, stage_round: 2} = reload(work_item)

      assert %Escalation{resolution: :another_round} =
               Repo.get_by(Escalation, work_item_id: work_item.id)
    end

    test "accept counts the loop as passed and opens the gate, the failed check shown", %{
      scope: scope,
      work_item: work_item
    } do
      assert {:ok, %WorkItem{stage_state: :at_gate, stage_round: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert %Escalation{resolution: :accept} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert escalation(work_item) == nil
      assert runs(work_item) |> length() == 1
      assert [%{type: "proposal", check: :missing}] = Stages.status(work_item).outputs
    end

    test "accept at the end of the sequence opens the gate without the checks", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "explore-a-ticket"}]}}
          ]
        })
      ])

      work_item = take_in!(scope) |> end_run!(questions_result())
      assert %Escalation{cause: :round_limit} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert escalation(work_item) == nil
      assert [%{check: :missing}] = Stages.status(work_item).outputs
    end

    test "close and decline end the work item", %{scope: scope, work_item: work_item} do
      assert {:ok, %WorkItem{state: :closed}} =
               Stages.resolve_escalation(scope, work_item, :close, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert %Escalation{resolution: :close} = Repo.get_by(Escalation, work_item_id: work_item.id)

      other = take_in!(scope) |> end_run!(nil)

      assert {:ok, %WorkItem{state: :declined}} =
               Stages.resolve_escalation(scope, other, :decline, nil,
                 expect_stage: reload(other).stage_id
               )
    end

    test "move back goes to an earlier stage only", %{scope: scope, work_item: work_item} do
      assert Stages.resolve_escalation(scope, work_item, {:move_back, @shape}, nil,
               expect_stage: reload(work_item).stage_id
             ) ==
               {:error, :not_earlier}

      assert Stages.resolve_escalation(scope, work_item, :accept_all, nil,
               expect_stage: reload(work_item).stage_id
             ) == {:error, :invalid}
    end

    test "is refused with nothing open", %{scope: scope} do
      work_item = take_in!(scope)

      assert Stages.resolve_escalation(scope, work_item, :accept, nil,
               expect_stage: reload(work_item).stage_id
             ) == {:error, :not_escalated}
    end
  end

  describe "work items placed by the migration" do
    # The migration that adds processes places each open work item without the runner:
    # no escalation row, and runs with no place in a stage.
    defp as_placed!(work_item, fields) do
      Repo.update_all(
        from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
        set: [
          stage_id: nil,
          round: nil,
          stage_entry: nil,
          loop_entry: nil,
          workflow: nil,
          machine_type: nil,
          process_version_id: nil
        ]
      )

      Repo.delete_all(from e in Escalation, where: e.work_item_id == ^work_item.id)
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id), set: fields)
      reload(work_item)
    end

    test "an escalated work item shows its stopped run and takes another round", %{
      scope: scope
    } do
      work_item =
        take_in!(scope)
        |> end_run!(nil)
        |> as_placed!(stage_state: :escalated, stage_round: 1, stage_entry: 0, loop_entry: 0)

      assert %{state: :escalated, escalation: %{cause: :run_stopped, round: 1}} =
               Stages.status(work_item)

      assert {:ok, %WorkItem{stage_state: :running, stage_round: 2}} =
               Stages.resolve_escalation(scope, work_item, :another_round, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert %Escalation{resolution: :another_round} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert %DispatchRun{attempt: 2, round: 2, stage_id: @explore} = newest_run(work_item)
    end

    test "an escalated work item explores again", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(nil)
        |> as_placed!(stage_state: :escalated, stage_round: 1, stage_entry: 0, loop_entry: 0)

      assert {:ok, _work_item} = WorkItems.explore_again(scope, work_item, 1)
      assert %DispatchRun{attempt: 2, round: 2} = newest_run(work_item)
    end

    test "a work item waiting for answers runs the next round", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(questions_result())
        |> as_placed!(
          stage_state: :waiting_answers,
          stage_round: 1,
          stage_entry: 0,
          loop_entry: 0
        )

      assert {:ok, _work_item} = WorkItems.answer(scope, work_item, 1, %{"1" => "a", "2" => "b"})

      assert %DispatchRun{attempt: 2, round: 2, workflow: "explore-a-ticket"} =
               newest_run(work_item)
    end

    test "a confirmed work item at Shape's gate moves on when approved", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(understood_result())

      {:ok, _work_item} = Moves.confirm(scope, work_item, 1, nil)

      work_item =
        as_placed!(work_item,
          stage_id: @shape,
          stage_state: :at_gate,
          stage_round: 0,
          stage_entry: 0,
          loop_entry: nil
        )

      assert %{stage: %{id: @shape}, state: :at_gate} = Stages.status(work_item)

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)
    end
  end

  describe "move" do
    test "moves a work item past a stage, with the person and the note", %{scope: scope} do
      work_item = take_in!(scope)

      assert {:ok, %WorkItem{stage_id: @build, stage_state: :at_gate}} =
               Stages.move(scope, work_item, @build, "Skip shaping",
                 expect_stage: reload(work_item).stage_id
               )

      assert Repo.one(
               from e in Entry,
                 where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
                 select: e.details
             ) == %{
               "change" => "move",
               "from" => @explore,
               "to" => @build,
               "note" => "Skip shaping"
             }

      assert Stages.move(scope, work_item, "st_zzzzzzzzzz", nil,
               expect_stage: reload(work_item).stage_id
             ) == {:error, :unknown_stage}
    end

    test "is refused to a person of another workspace", %{scope: scope} do
      work_item = take_in!(scope)
      other = sign_up_fixture().scope

      assert Stages.move(other, work_item, @build, nil, expect_stage: reload(work_item).stage_id) ==
               {:error, :not_found}
    end
  end

  describe "a page that shows an earlier stage" do
    # Each action names the stage the person's page showed (`expect_stage`). A work item
    # that left that stage, or an action that names none, is refused and nothing changes.
    defp unchanged!(work_item, before) do
      after_ = reload(work_item)

      assert Map.take(after_, [:stage_id, :stage_state, :stage_round, :state]) ==
               Map.take(before, [:stage_id, :stage_state, :stage_round, :state])

      after_
    end

    test "a late approve of Shape does not approve Build", %{scope: scope} do
      work_item = shape_gate_fixture(scope)

      assert {:ok, %WorkItem{stage_id: @build, stage_state: :at_gate}} =
               Stages.approve(scope, work_item, nil, expect_stage: @shape)

      before = reload(work_item)
      count = length(decisions(work_item))

      assert Stages.approve(scope, work_item, nil, expect_stage: @shape) ==
               {:error, :stage_changed}

      assert Stages.approve(scope, work_item, nil) == {:error, :stage_changed}
      unchanged!(work_item, before)
      assert length(decisions(work_item)) == count
    end

    test "request changes, move and resolve are refused for another stage, or none", %{
      scope: scope
    } do
      work_item = shape_gate_fixture(scope)
      before = reload(work_item)

      assert Stages.request_changes(scope, work_item, "x", nil, expect_stage: @explore) ==
               {:error, :stage_changed}

      assert Stages.request_changes(scope, work_item, "x", nil) == {:error, :stage_changed}

      assert Stages.move(scope, work_item, @build, nil, expect_stage: @explore) ==
               {:error, :stage_changed}

      assert Stages.move(scope, work_item, @build, nil) == {:error, :stage_changed}
      unchanged!(work_item, before)

      escalated = take_in!(scope) |> end_run!(nil)
      before = reload(escalated)

      assert Stages.resolve_escalation(scope, escalated, :accept, nil, expect_stage: @shape) ==
               {:error, :stage_changed}

      assert Stages.resolve_escalation(scope, escalated, :accept, nil) ==
               {:error, :stage_changed}

      unchanged!(escalated, before)
      assert %Escalation{resolution: nil} = escalation(escalated)

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.move(scope, work_item, @build, nil, expect_stage: @shape)
    end

    test "a confirmation approves Explore's gate only while the work item is there", %{
      scope: scope
    } do
      work_item = explore_gate_fixture(scope)
      assert Stages.explore_stage_id(work_item) == @explore

      assert Repo.transact(fn ->
               Stages.confirmed(scope, work_item, expect_stage: @shape)
             end) == {:error, :stage_changed}

      assert reload(work_item).stage_state == :at_gate
      assert {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
      assert %{stage_id: @shape} = reload(work_item)
    end

    test "move back to the stage itself, or a later one, is not earlier", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(nil)

      for stage_id <- [@explore, @shape] do
        assert Stages.resolve_escalation(scope, work_item, {:move_back, stage_id}, nil,
                 expect_stage: @explore
               ) == {:error, :not_earlier}
      end

      assert %Escalation{resolution: nil} = escalation(work_item)
    end
  end

  describe "the review's rules" do
    test "approving another stage's gate confirms no proposal; a confirmation there is refused",
         %{scope: scope} do
      work_item = explore_gate_fixture(scope)

      {:ok, _moved} = Stages.move(scope, work_item, @shape, nil, expect_stage: @explore)
      assert %{stage_id: @shape, stage_state: :at_gate} = reload(work_item)

      assert WorkItems.confirm(scope, reload(work_item), 1) == {:error, :stage_changed}
      assert Repo.get_by(Confirmation, work_item_id: work_item.id) == nil

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.approve(scope, work_item, nil, expect_stage: @shape)

      assert Repo.get_by(Confirmation, work_item_id: work_item.id) == nil

      assert Repo.all(
               from e in Entry,
                 where: e.subject_id == ^work_item.id and e.action == "work_item.confirm",
                 select: e.id
             ) == []
    end

    test "Explore again on an escalated stage needs a listed approver, and records them", %{
      scope: scope
    } do
      member = member_fixture(scope)

      save!(scope, [
        explore_stage(%{
          "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
        })
      ])

      work_item = take_in!(scope) |> end_run!(nil)
      assert reload(work_item).stage_state == :escalated

      assert WorkItems.explore_again(member.scope, work_item, 1) == {:error, :not_approver}
      assert %Escalation{resolution: nil} = escalation(work_item)

      assert {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
      assert %{stage_state: :running, stage_round: 2} = reload(work_item)

      user_id = scope.user.id

      assert %Escalation{resolution: :another_round, resolved_by_id: ^user_id} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert %{"change" => "escalation_another_round", "cause" => "run_stopped"} =
               Repo.one(
                 from e in Entry,
                   where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
                   select: e.details
               )
    end

    test "questions outside a loop get three runs, then escalate round_limit", %{scope: scope} do
      save!(scope, [explore_stage(%{"sequence" => [%{"workflow" => "explore-a-ticket"}]})])
      work_item = take_in!(scope)
      assert [%DispatchRun{attempt: 1, of: 3}] = runs(work_item)

      work_item = end_run!(work_item, questions_result())
      assert work_item.stage_state == :waiting_answers
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "Main", "2" => "Spring"})
      assert %DispatchRun{attempt: 2, of: 3} = newest_run(work_item)

      work_item = end_run!(reload(work_item), questions_result())
      assert work_item.stage_state == :waiting_answers
      {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "Main", "2" => "Spring"})
      assert %DispatchRun{attempt: 3, of: 3} = newest_run(work_item)

      work_item = end_run!(reload(work_item), questions_result())
      assert work_item.stage_state == :escalated

      assert %Escalation{cause: :round_limit, gaps: "Which basket?\nWhich sale?"} =
               escalation(work_item)
    end

    test "an answer to the last run a placed work item may have escalates round_limit", %{
      scope: scope
    } do
      save!(scope, [explore_stage(%{"sequence" => [%{"workflow" => "explore-a-ticket"}]})])
      work_item = take_in!(scope)
      run = newest_run(work_item)

      # As the migration placed it: waiting for answers to the last run of the take in.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [of: 1])

      work_item = end_run!(work_item, questions_result())

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :waiting_answers]
        )

      assert {:ok, %WorkItem{stage_state: :escalated}} =
               WorkItems.answer(scope, reload(work_item), 1, %{"1" => "Main", "2" => "Spring"})

      assert %Escalation{cause: :round_limit, gaps: "Which basket?\nWhich sale?"} =
               escalation(work_item)
    end

    test "a note is measured in code points, as the database measures it", %{scope: scope} do
      work_item = explore_gate_fixture(scope)
      # 2,001 letters with a combining accent: 2,001 graphemes, 4,002 code points.
      long = String.duplicate("e\u0301", 2001)

      assert Stages.approve(scope, work_item, long, expect_stage: @explore) ==
               {:error, {:invalid, :note}}

      fits = String.duplicate("e\u0301", 2000)
      assert {:ok, _} = Stages.approve(scope, work_item, fits, expect_stage: @explore)
    end
  end

  describe "a work item that is not live" do
    defp closed_waiting_workflow!(scope) do
      :ok = Processes.record_declared(scope.workspace, ["review"])
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope)
      assert work_item.stage_state == :waiting_workflow
      {:ok, _closed} = Moves.close(scope, work_item)
      work_item
    end

    test "check_workflows returns not_live and queues no run", %{scope: scope} do
      work_item = closed_waiting_workflow!(scope)
      read = fn _scope, _workspace -> {:ok, ["review", "capture-demo"]} end

      assert Stages.check_workflows(scope, work_item, read) == {:error, :not_live}

      assert %WorkItem{state: :closed, stage_state: :waiting_workflow} = reload(work_item)
      assert runs(work_item) == []
    end

    test "resume leaves a stage waiting for a workflow as it is", %{scope: scope} do
      work_item = closed_waiting_workflow!(scope)
      :ok = Processes.record_declared(scope.workspace, ["review", "capture-demo"])

      assert {:ok, %WorkItem{state: :closed, stage_state: :waiting_workflow}} =
               Stages.resume(work_item)

      assert runs(work_item) == []
    end

    test "enter returns not_live and leaves the stage as it is", %{scope: scope} do
      people_process!(scope, %{"kind" => "person", "approvers" => "members"}, ["mockup"])
      work_item = at_shape!(scope)
      {:ok, _closed} = Moves.close(scope, work_item)

      assert Stages.enter(work_item, @build, :moved) == {:error, :not_live}

      assert %WorkItem{state: :closed, stage_id: @shape, stage_state: :at_gate} =
               reload(work_item)
    end

    test "answers_used_up returns the refusal and opens no escalation", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(questions_result())
      assert work_item.stage_state == :waiting_answers
      {:ok, _closed} = Moves.close(scope, work_item)

      assert Stages.answers_used_up(work_item, {:error, :used_up}) == {:error, :used_up}

      assert %WorkItem{state: :closed, stage_state: :waiting_answers} = reload(work_item)
      refute escalation(work_item)
    end
  end
end
