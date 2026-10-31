defmodule Apiary.StagesTest do
  # The stage runner with the workflow model on (`Apiary.Stages`): a take in enters the
  # first stage and queues explore-a-ticket through today's dispatch; a run's end through
  # its settle maps today's explore result into artifacts (D1); the gate, the escalations,
  # moves, and what the work item page reads.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Processes, Repo, Stages, StagesArtifactsStub, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Confirmation, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"

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

  defp artifacts(work_item), do: StagesArtifactsStub.list(work_item)

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
      public_id = work_item.public_id
      assert_receive {:stage_changed, ^public_id}
    end

    test "waits for a workflow the harness does not declare", %{scope: scope} do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope)

      assert work_item.stage_state == :waiting_workflow
      assert runs(work_item) == []

      assert %{state: :waiting_workflow, waiting_workflow: "capture-demo"} =
               Stages.status(work_item)
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
        StagesArtifactsStub.push(
          {:person, scope},
          work_item,
          "acceptance-criteria",
          [%{filename: "criteria.md", binary: "- The price is the sale price."}],
          stage_id: @explore
        )

      assert {:ok, %WorkItem{stage_state: :running}} = Stages.resume(work_item)
      assert [%{source: :person, version: %{number: 1}}] = Stages.inputs(work_item)
      assert [%DispatchRun{workflow: "explore-a-ticket"}] = runs(work_item)
    end
  end

  describe "the D1 mapping of an explore result" do
    test "a proposal becomes a proposal version and a verdict passed; the gate opens", %{
      scope: scope
    } do
      work_item = take_in!(scope)
      Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(scope.workspace.id))
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
      public_id = work_item.public_id
      assert_receive {:stage_changed, ^public_id}
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
      assert told == [{:stage_changed, work_item.workspace_id, work_item.public_id}]

      assert %Escalation{
               cause: :run_stopped,
               gaps: "The run stopped reporting and was marked lost."
             } =
               escalation(work_item)
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
      assert %DispatchRun{loop_entry: nil, of: 1} = newest_run(work_item)
      work_item = end_run!(work_item, understood_result())

      assert %Escalation{cause: :check_failed, gaps: "No mockup was stored in this stage."} =
               escalation(work_item)

      assert [%{check: :passed}, %{check: :missing}, %{check: :not_checked}] =
               Stages.status(work_item).outputs
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

      {:ok, _work_item} = Stages.approve(scope, work_item, nil)

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

      assert {:ok, %WorkItem{stage_id: @shape}} = Stages.approve(scope, work_item, "Looks right")

      assert %Confirmation{changes: changes} =
               Repo.get_by(Confirmation, work_item_id: work_item.id)

      assert changes == %{}
      assert [%GateDecision{note: "Looks right"}] = decisions(work_item)
    end

    test "approve is refused away from the gate", %{scope: scope} do
      work_item = take_in!(scope)
      assert Stages.approve(scope, work_item, nil) == {:error, :not_at_gate}
    end

    test "request changes reruns the loop from round 1, with the note and its version", %{
      scope: scope
    } do
      work_item = take_in!(scope) |> end_run!(understood_result())
      [proposal] = versions(work_item, "proposal")

      assert Stages.request_changes(scope, work_item, "x", "av_0000000000000000") ==
               {:error, :not_found}

      assert {:ok, %WorkItem{stage_state: :running, stage_round: 1}} =
               Stages.request_changes(
                 scope,
                 work_item,
                 "Leave out the invoice",
                 proposal.public_id
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
      assert Stages.approve(member.scope, work_item, nil) == {:error, :not_approver}
      refute Stages.status(work_item, member.scope).gate.approvable?
      assert {:ok, %WorkItem{stage_id: @shape}} = Stages.approve(scope, work_item, nil)
    end

    test "a new output version after the last stage's approval reopens its gate", %{scope: scope} do
      save!(scope, [explore_stage()])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, work_item} = Stages.approve(scope, work_item, nil)
      assert %{stage_state: :done} = reload(work_item)
      assert Stages.status(work_item).state == :done

      {:ok, _version} =
        Stages.Artifacts.push_json({:person, scope}, work_item, "proposal", %{"a" => 1},
          stage_id: @explore
        )

      assert %{state: :at_gate, gate: %{approvals: [%{versions: [%{number: 1, newer?: true}]}]}} =
               Stages.status(work_item)
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
      {:ok, work_item} = Stages.approve(scope, work_item, nil)
      [proposal] = versions(work_item, "proposal")

      assert reload(work_item).stage_state == :at_gate

      assert [%{type: "proposal", source: :approved, version: %{id: id}}] =
               Stages.inputs(work_item)

      assert id == proposal.public_id

      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, newest_run(work_item)},
          work_item,
          "proposal",
          %{"b" => 2},
          stage_id: @explore
        )

      assert [%{id: ^id}] = Enum.map(Stages.inputs(work_item), & &1.version)

      assert [
               %{
                 type: "proposal",
                 newest: 2,
                 approved: 1,
                 newer_than_approved?: true,
                 changed_after_approval?: true
               },
               %{type: "verdict", approved: nil}
             ] = Stages.artifact_index(work_item)
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
               Stages.resolve_escalation(scope, work_item, :another_round, "Read the sale page")

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

    test "accept counts the loop as passed; a missing proposal then runs another round", %{
      scope: scope,
      work_item: work_item
    } do
      assert {:ok, %WorkItem{stage_state: :running, stage_round: 2}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil)

      assert %Escalation{resolution: :accept} =
               Repo.get_by(Escalation, work_item_id: work_item.id)
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

      assert {:ok, %WorkItem{stage_state: :escalated, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil)

      assert %Escalation{cause: :round_limit, gaps: "No proposal was stored in this stage."} =
               escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil)

      assert escalation(work_item) == nil
      assert [%{check: :missing}] = Stages.status(work_item).outputs
    end

    test "close and decline end the work item", %{scope: scope, work_item: work_item} do
      assert {:ok, %WorkItem{state: :closed}} =
               Stages.resolve_escalation(scope, work_item, :close, nil)

      assert %Escalation{resolution: :close} = Repo.get_by(Escalation, work_item_id: work_item.id)

      other = take_in!(scope) |> end_run!(nil)

      assert {:ok, %WorkItem{state: :declined}} =
               Stages.resolve_escalation(scope, other, :decline, nil)
    end

    test "move back goes to an earlier stage only", %{scope: scope, work_item: work_item} do
      assert Stages.resolve_escalation(scope, work_item, {:move_back, @shape}, nil) ==
               {:error, :not_earlier}

      assert Stages.resolve_escalation(scope, work_item, :accept_all, nil) == {:error, :invalid}
    end

    test "is refused with nothing open", %{scope: scope} do
      work_item = take_in!(scope)
      assert Stages.resolve_escalation(scope, work_item, :accept, nil) == {:error, :not_escalated}
    end
  end

  describe "move" do
    test "moves a work item past a stage, with the person and the note", %{scope: scope} do
      work_item = take_in!(scope)

      assert {:ok, %WorkItem{stage_id: @build, stage_state: :at_gate}} =
               Stages.move(scope, work_item, @build, "Skip shaping")

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

      assert Stages.move(scope, work_item, "st_zzzzzzzzzz", nil) == {:error, :unknown_stage}
    end

    test "is refused to a person of another workspace", %{scope: scope} do
      work_item = take_in!(scope)
      other = sign_up_fixture().scope
      assert Stages.move(other, work_item, @build, nil) == {:error, :not_found}
    end
  end
end
