defmodule Apiary.WorkflowEndToEndTest do
  # One work item through the default process of the Qory Apiary workflow model, with no
  # stub: a gateway claims, attaches and ends each run and signs every run API request
  # through the whole endpoint; people act through the stage runner (`Apiary.Stages`) and
  # the process versions (`Apiary.Processes`); artifacts are stored in the real tables and
  # store (`Apiary.Artifacts`).
  #
  # Each test drives the steps before it again, then the step it is named for:
  #
  #   1. Take in: Explore's run is queued under process version 1.
  #   2. The run reads its work item, pushes a proposal, and ends; Explore reaches its
  #      gate.
  #   3. Dana saves version 2, in which Shape has a required output and Build has a loop
  #      and an output, and assigns the work item to it. Dana confirms Explore; Shape, with
  #      no workflow, is at its gate. Approving Shape is refused until Dana adds acceptance
  #      criteria; she adds them and approves Shape; Build is entered.
  #   4. A Build run pushes an explainer and gives `changes-requested`; the second round
  #      gives `passed`. The Exists check passes, and Build is at its gate.
  #   5. Dana requests changes; the next run stops, and Build escalates (`run_stopped`).
  #      Dana runs another round with a note, and the next run reads the note.
  #   6. That run gives `changes-requested`. Dana saves version 3 as a trial and assigns
  #      the work item to it; the run queued for round 3 moves to version 3.
  #
  # Not async: the store's folder and the modules the stage runner and the run API call
  # are the application's settings.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Artifacts, Dispatches, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Runs.{Projector, Run}
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:workflow_model, :factory]
  @moduletag :tmp_dir

  # The stages of the software type's default process (`Apiary.Processes`).
  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"

  @title "Add gift cards to the Web shop checkout"

  setup %{tmp_dir: tmp_dir} do
    # The real modules: the store in a folder of this test, and no stand-in for
    # `Apiary.Artifacts`, `Apiary.Processes` or `Apiary.Features` in the stage runner or
    # the run API, whatever the configuration of the suite sets.
    put_env(:artifacts_dir, Path.join(tmp_dir, "store"))
    put_env(Apiary.Stages.Artifacts, Apiary.Artifacts)
    put_env(ApiaryWeb.Contract.RunApi.Boundary, [])

    unique = System.unique_integer([:positive])

    %{scope: scope} =
      sign_up_fixture(%{email: "dana-#{unique}@example.com", organisation_name: "Acme #{unique}"})

    %{scope: scope, place: Apiary.DispatchedRunsFixtures.handover_place_fixture(scope)}
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:apiary, key)
    Application.put_env(:apiary, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:apiary, key, value)
        :error -> Application.delete_env(:apiary, key)
      end
    end)
  end

  ## The tests

  test "1. a take in queues Explore's run under process version 1", ctx do
    step_1(ctx)
  end

  test "2. the run reads its work item, pushes a proposal and ends; Explore is at its gate",
       ctx do
    ctx |> step_1() |> step_2()
  end

  test "3. Shape's gate refuses approval until acceptance criteria are added; then Build starts",
       ctx do
    ctx |> step_1() |> step_2() |> step_3()
  end

  test "4. changes-requested runs a second round; passed and the Exists check open the gate",
       ctx do
    ctx |> step_1() |> step_2() |> step_3() |> step_4()
  end

  test "5. a stopped run escalates; another round with a note reaches the next run", ctx do
    ctx |> step_1() |> step_2() |> step_3() |> step_4() |> step_5()
  end

  test "6. a trial version assigned to the work item moves its queued run", ctx do
    ctx |> step_1() |> step_2() |> step_3() |> step_4() |> step_5() |> step_6()
  end

  ## The steps

  # 1. Take in: the work item enters Explore under version 1, the copy of the software
  # type's default, and explore-a-ticket's first round is queued.
  defp step_1(ctx) do
    ticket =
      Apiary.WorkItemsFixtures.backlog_ticket_fixture(ctx.scope, %{
        title: @title,
        body: "Acme customers want to pay part of an order with a gift card.",
        filed_by_name: "Dana"
      })

    {:ok, taken} = WorkItems.take_in(ctx.scope, ticket.public_id)
    work_item = Repo.get!(WorkItem, taken.id)
    v1 = Processes.current(ctx.scope.workspace)

    assert %{number: 1, status: :current, author_id: nil} = v1
    assert v1.document == Processes.default_document(ctx.scope.workspace)
    assert work_item.process_version_id == v1.id
    assert_place(work_item, @explore, :running, 1)

    assert [run] = runs(work_item)

    assert %DispatchRun{
             state: :waiting,
             workflow: "explore-a-ticket",
             stage_id: @explore,
             round: 1
           } = run

    assert run.process_version_id == v1.id

    Map.merge(ctx, %{work_item: work_item, v1: v1})
  end

  # 2. The gateway claims and attaches explore-a-ticket's run. The run reads its work
  # item, pushes a proposal, and ends; with no question open, Explore goes on to its
  # Exists check and its gate.
  defp step_2(ctx) do
    run = claim!(ctx)

    snapshot = json_response(read!(ctx, run, "/work-item"), 200)
    assert snapshot["version"] == 1
    assert snapshot["work_item"]["id"] == ctx.work_item.public_id

    assert snapshot["run"] == %{
             "id" => run.run_id,
             "number" => run.number,
             "workflow" => "explore-a-ticket",
             "round" => 1
           }

    assert snapshot["stage"] == %{
             "id" => @explore,
             "name" => "Explore",
             "round" => 1,
             "rounds" => nil,
             "state" => "running"
           }

    assert snapshot["inputs"] == []
    refute Map.has_key?(snapshot, "answers")

    assert snapshot["outputs"] == [
             %{"type" => "proposal", "required" => true, "version" => nil, "check" => "missing"}
           ]

    assert snapshot["ticket"]["title"] == @title
    assert snapshot["verdict"] == nil
    assert snapshot["notes"] == []

    proposal = proposal()

    pushed =
      json_response(
        write!(ctx, run, "/artifacts", push_body("proposal", "proposal.md", proposal)),
        201
      )

    assert %{"type" => "proposal", "name" => "main", "version" => %{"number" => 1}} =
             pushed["artifact"]

    verdict!(ctx, run, %{"verdict" => "passed"})
    end_run!(ctx, run)

    work_item = reload(ctx.work_item)
    assert_place(work_item, @explore, :at_gate, 1)

    # A run reads its work item's artifacts after it ends: the proposal it pushed, and its
    # verdict.
    index = json_response(read!(ctx, run, "/artifacts"), 200)
    assert %{"newest_version" => 1} = artifact(index, "proposal")
    assert %{"newest_version" => 1} = artifact(index, "verdict")

    for version <- artifact(index, "proposal")["versions"] do
      assert version["writer"] == %{"kind" => "run", "run_id" => run.run_id}
      assert version["stage_id"] == @explore
    end

    status = Stages.status(work_item, ctx.scope)
    assert [%{type: "proposal", check: :passed, version: %{number: 1}}] = status.outputs
    assert status.gate.approvable?

    Map.put(ctx, :work_item, work_item)
  end

  # 3. Dana saves version 2, whose Build reads acceptance criteria and runs a loop of
  # capture-demo that must write an explainer, and assigns the work item to it. Dana
  # confirms Explore's proposal at its gate: Shape, with no workflow, waits at its gate
  # while its required output, acceptance criteria, is missing. Approving Shape is refused
  # with `outputs_missing`. Dana adds the criteria through `Stages.add_version/5` and
  # approves Shape: Build is entered with its input.
  defp step_3(ctx) do
    %{scope: scope} = ctx

    {:ok, v2} = Processes.save(scope, scope.workspace, build_document(ctx.v1.document))
    assert %{number: 2, status: :current} = v2
    assert Processes.get_version!(ctx.v1.id).status == :past

    {:ok, assigned} = Processes.assign(scope, ctx.work_item, v2)
    assert assigned.process_version_id == v2.id
    assert_place(assigned, @explore, :at_gate, 1)

    {:ok, _work_item} = Stages.approve(scope, assigned, nil, expect_stage: @explore)
    work_item = reload(assigned)
    assert_place(work_item, @shape, :at_gate, 1)
    assert work_item.process_version_id == v2.id

    # The approval covers the newest proposal, the one the run pushed.
    proposal = Artifacts.newest(work_item, "proposal")
    assert proposal.number == 1

    assert [%GateDecision{kind: :approve, versions: [proposal_id]}] =
             decisions(work_item, @explore)

    assert proposal_id == proposal.public_id

    # Shape has no workflow and a required output, so it waits at its gate and the gate
    # cannot be approved. The refusal writes no decision.
    status = Stages.status(work_item, scope)
    assert status.missing_outputs == ["acceptance-criteria"]
    assert [%{type: "acceptance-criteria", required: true, check: :missing}] = status.outputs
    refute status.gate.approvable?

    assert {:error, {:outputs_missing, ["acceptance-criteria"]}} =
             Stages.approve(scope, work_item, "Agreed with the Web shop team.",
               expect_stage: @shape
             )

    assert_place(reload(work_item), @shape, :at_gate, 1)
    assert decisions(work_item, @shape) == []

    {:ok, criteria} =
      Stages.add_version(scope, work_item, "acceptance-criteria", [
        %{
          filename: "criteria.md",
          content_type: "text/markdown",
          binary: "# Acceptance criteria\n\n- A gift card pays part of an order.\n"
        }
      ])

    assert %{number: 1, writer: :person, stage_id: @shape} = criteria

    # The version is stored: the gate still waits, and now accepts the approval.
    assert_place(reload(work_item), @shape, :at_gate, 1)
    status = Stages.status(work_item, scope)
    assert status.missing_outputs == []
    assert [%{type: "acceptance-criteria", check: :passed}] = status.outputs
    assert status.gate.approvable?

    {:ok, _work_item} =
      Stages.approve(scope, work_item, "Agreed with the Web shop team.", expect_stage: @shape)

    work_item = reload(work_item)
    assert_place(work_item, @build, :running, 1)

    assert [%GateDecision{kind: :approve, versions: versions}] = decisions(work_item, @shape)

    assert criteria.public_id in versions

    assert %DispatchRun{
             state: :waiting,
             workflow: "capture-demo",
             stage_id: @build,
             round: 1
           } = run = newest_run(work_item)

    assert run.process_version_id == v2.id

    Map.merge(ctx, %{work_item: work_item, v2: v2, criteria: criteria})
  end

  # 4. Build's first run reads the approved criteria, pushes an explainer and gives
  # `changes-requested`: the loop's ring of one workflow starts round 2. The second run
  # pushes the next explainer and gives `passed`: the loop ends, the Exists check of the
  # explainer passes, and Build waits at its gate.
  defp step_4(ctx) do
    run = claim!(ctx)
    snapshot = json_response(read!(ctx, run, "/work-item"), 200)

    assert snapshot["run"] == %{
             "id" => run.run_id,
             "number" => run.number,
             "workflow" => "capture-demo",
             "round" => 1
           }

    assert snapshot["stage"] == %{
             "id" => @build,
             "name" => "Build",
             "round" => 1,
             "rounds" => 3,
             "state" => "running"
           }

    assert snapshot["inputs"] == [
             %{
               "type" => "acceptance-criteria",
               "required" => true,
               "version" => %{"id" => ctx.criteria.public_id, "number" => 1}
             }
           ]

    assert snapshot["outputs"] == [
             %{"type" => "explainer", "required" => true, "version" => nil, "check" => "missing"}
           ]

    pushed = push_explainer!(ctx, run, "# Gift cards\n\nThe payment step has a field.\n")
    assert pushed["version"]["number"] == 1

    gaps = "The explainer does not show a payment with two gift cards."
    verdict!(ctx, run, %{"verdict" => "changes-requested", "gaps" => gaps})
    end_run!(ctx, run)

    work_item = reload(ctx.work_item)
    assert_place(work_item, @build, :running, 2)

    second = claim!(ctx)
    snapshot = json_response(read!(ctx, second, "/work-item"), 200)

    assert snapshot["run"] == %{
             "id" => second.run_id,
             "number" => second.number,
             "workflow" => "capture-demo",
             "round" => 2
           }

    assert %{"round" => 2, "rounds" => 3, "state" => "running"} = snapshot["stage"]
    assert %{"verdict" => "changes-requested", "gaps" => ^gaps} = snapshot["verdict"]
    assert snapshot["gaps"] == gaps

    assert [%{"type" => "explainer", "check" => "passed", "version" => %{"number" => 1}}] =
             snapshot["outputs"]

    pushed = push_explainer!(ctx, second, "# Gift cards\n\nTwo gift cards pay one order.\n")
    assert pushed["version"]["number"] == 2
    verdict!(ctx, second, %{"verdict" => "passed"})
    end_run!(ctx, second)

    work_item = reload(work_item)
    assert_place(work_item, @build, :at_gate, 2)

    status = Stages.status(work_item, ctx.scope)
    assert [%{type: "explainer", check: :passed, version: %{number: 2}}] = status.outputs
    assert status.gate.approvable?
    assert status.escalation == nil

    assert [%{verdict: :passed, round: 2}, %{verdict: :failed, round: 1} | _explore] =
             Stages.runs(work_item)

    index = json_response(read!(ctx, second, "/artifacts"), 200)
    explainer = artifact(index, "explainer")
    assert %{"stage_id" => @build, "newest_version" => 2} = explainer

    assert [
             %{"number" => 2, "writer" => %{"run_id" => second_id}},
             %{"number" => 1, "writer" => %{"run_id" => first_id}}
           ] = explainer["versions"]

    assert {second_id, first_id} == {second.run_id, run.run_id}

    # The acceptance criteria are the version Shape's gate approved, written by Dana.
    criteria = artifact(index, "acceptance-criteria")

    assert %{
             "stage_id" => @shape,
             "approved_version" => approved,
             "newest_version" => 1,
             "changed_after_approval" => false,
             "versions" => [
               %{"number" => 1, "writer" => %{"kind" => "person"}, "approvals" => [_]}
             ]
           } = criteria

    assert approved == ctx.criteria.public_id

    Map.merge(ctx, %{work_item: work_item, explainer_id: hd(explainer["versions"])["id"]})
  end

  # 5. Dana requests changes at Build's gate, pointing at the explainer: round 1 of the
  # loop runs again. That run stops with a failed exit and no verdict, and Build escalates
  # with the cause `run_stopped`. Dana runs another round with a note; the next run reads
  # both notes as work item data.
  defp step_5(ctx) do
    %{scope: scope} = ctx
    change_note = "Show a payment with two gift cards."

    {:ok, _work_item} =
      Stages.request_changes(scope, ctx.work_item, change_note, ctx.explainer_id,
        expect_stage: @build
      )

    work_item = reload(ctx.work_item)
    assert_place(work_item, @build, :running, 1)

    stopped = claim!(ctx)
    snapshot = json_response(read!(ctx, stopped, "/work-item"), 200)

    assert [
             %{
               "kind" => "request_changes",
               "stage_id" => @build,
               "note" => ^change_note,
               "artifact_version_id" => artifact_version_id,
               "by" => %{"name" => name}
             }
           ] = snapshot["notes"]

    assert is_binary(name)

    assert artifact_version_id == ctx.explainer_id

    end_run!(ctx, stopped, state: "failed")

    work_item = reload(work_item)
    assert_place(work_item, @build, :escalated, 1)

    assert %Escalation{cause: :run_stopped, round: 1, gaps: stop_cause} =
             Repo.one!(
               from e in Escalation,
                 where: e.work_item_id == ^work_item.id and is_nil(e.resolved_at)
             )

    assert is_binary(stop_cause) and stop_cause != ""
    assert %{escalation: %{cause: :run_stopped}} = Stages.status(work_item, scope)

    # A run that has ended writes nothing.
    assert json_response(write!(ctx, stopped, "/verdict", %{"verdict" => "passed"}), 409) == %{
             "error" => "run_ended",
             "message" =>
               "The run has ended, so it can no longer push artifacts or give a verdict."
           }

    escalation_note = "Use the Acme test gift card."

    {:ok, _work_item} =
      Stages.resolve_escalation(scope, work_item, :another_round, escalation_note,
        expect_stage: @build
      )

    work_item = reload(work_item)
    assert_place(work_item, @build, :running, 2)

    next = claim!(ctx)
    snapshot = json_response(read!(ctx, next, "/work-item"), 200)

    assert snapshot["run"] == %{
             "id" => next.run_id,
             "number" => next.number,
             "workflow" => "capture-demo",
             "round" => 2
           }

    assert %{"round" => 2, "state" => "running"} = snapshot["stage"]

    assert [
             %{"kind" => "request_changes", "note" => ^change_note},
             %{"kind" => "escalation", "stage_id" => @build, "note" => ^escalation_note}
           ] = snapshot["notes"]

    Map.merge(ctx, %{work_item: work_item, run: next})
  end

  # 6. The run of round 2 gives `changes-requested`, so round 3 is queued. Dana saves
  # version 3 as a trial, with five rounds for Build's loop, and assigns the work item to
  # it: the work item keeps its place, and the queued run moves to version 3 with it,
  # while the ended runs keep version 2.
  defp step_6(ctx) do
    %{scope: scope, run: run} = ctx

    verdict!(ctx, run, %{"verdict" => "changes-requested", "gaps" => "The note is not done."})
    end_run!(ctx, run)

    work_item = reload(ctx.work_item)
    assert_place(work_item, @build, :running, 3)
    queued = newest_run(work_item)
    assert %DispatchRun{state: :waiting, round: 3} = queued
    assert queued.process_version_id == ctx.v2.id

    {:ok, v3} =
      Processes.save(scope, scope.workspace, rounds(ctx.v2.document, 5), trial: true)

    assert %{number: 3, status: :trial} = v3
    assert Processes.current(scope.workspace).id == ctx.v2.id

    {:ok, assigned} = Processes.assign(scope, work_item, v3)
    assert assigned.process_version_id == v3.id

    work_item = reload(work_item)
    assert_place(work_item, @build, :running, 3)
    assert Repo.get!(DispatchRun, queued.id).process_version_id == v3.id
    assert Repo.get!(DispatchRun, run.dispatch_run_id).process_version_id == ctx.v2.id

    assert %{version: %{number: 3}, round: 3, rounds: 5} = Stages.status(work_item, scope)

    trial_run = claim!(ctx)
    assert trial_run.dispatch_run_id == queued.id
    snapshot = json_response(read!(ctx, trial_run, "/work-item"), 200)

    assert %{"id" => @build, "round" => 3, "rounds" => 5, "state" => "running"} =
             snapshot["stage"]

    ctx
  end

  ## The gateway

  # The pool claims the oldest waiting run, the machine redeems its run code, the gateway
  # attaches the run and posts its start, as `ApiaryWeb.Contract.ClosedWorkItemRunTest`
  # does. Returns the run id the run API path uses, the registered run and its run of the
  # queue.
  #
  # A run of a stage's workflow other than explore-a-ticket waits for its harness walk
  # (`Apiary.Harnesses.WalkJob`), which reads the harness through the adapters and which
  # the suite does not run. Its row is written resolved with origin `:none`
  # (`walk_resolved!/2`), as the job writes it for a run with no workflow, so the claim
  # takes the run. The walk itself is not under test.
  defp claim!(ctx) do
    {key, seed} = ctx.place.gateway_key

    for %DispatchRun{state: :waiting} = run <- runs(ctx.work_item),
        Repo.get_by!(RunHarness, dispatch_run_id: run.id).state == :pending,
        do: Apiary.DispatchedRunsFixtures.walk_resolved!(run)

    assert {:ok, %{run_code: _code} = claimed} =
             Apiary.DispatchedRunsFixtures.walked_claim(ctx.place.key, Dispatches.now())

    run_key = Apiary.DispatchedRunsFixtures.redeemed_run_key!(claimed.run_code)
    run_id = claimed.registered.node_run_id

    attach = Jason.encode!(attach_body(run_key))
    assert signed_attach(build_conn(), key.key_id, seed, run_id, attach).status == 200
    :ok = Dispatches.dispatched(ctx.place.key, claimed.dispatch.public_id, %{external: nil})

    {_subject, started} = first_events(run_id)
    assert response(signed_post(build_conn(), key.key_id, seed, started), 202) == ""
    project!(claimed.registered.id)

    %{
      run_id: run_id,
      id: claimed.registered.id,
      number: Repo.get!(Run, claimed.registered.id).number,
      dispatch_run_id: claimed.registered.dispatch_run_id
    }
  end

  # The gateway posts the run's end: its result event for a run of explore-a-ticket, then
  # its exit, `succeeded` unless `state:` is set.
  defp end_run!(ctx, run, opts \\ []) do
    {key, seed} = ctx.place.gateway_key
    state = Keyword.get(opts, :state, "succeeded")
    exit_code = if state == "succeeded", do: 0, else: 1

    exited =
      wire_event(run.run_id, 4, "run.exited", %{"state" => state, "exit_code" => exit_code})

    assert response(signed_post(build_conn(), key.key_id, seed, [exited]), 202) == ""
    project!(run.id)

    assert %DispatchRun{state: :ended} = Repo.get!(DispatchRun, run.dispatch_run_id)
  end

  defp project!(run_id) do
    assert {:ok, %Run{}} = Projector.project(Repo.get!(Run, run_id))
  end

  ## The run API, signed under the gateway's key through the whole endpoint

  defp read!(ctx, run, path) do
    {key, seed} = ctx.place.gateway_key
    conn = signed_get(build_conn(), key.key_id, seed, "/v1/runs/#{run.run_id}" <> path)
    assert signed_answer?(conn)
    conn
  end

  defp write!(ctx, run, path, body) do
    {key, seed} = ctx.place.gateway_key

    conn =
      signed_post(build_conn(), key.key_id, seed, Jason.encode!(body),
        target: "/v1/runs/#{run.run_id}" <> path,
        content_type: "application/json",
        delivery: nil
      )

    assert signed_answer?(conn)
    conn
  end

  defp push_body(type, filename, content) do
    content = if is_binary(content), do: content, else: Jason.encode!(content)

    %{
      "type" => type,
      "files" => [
        %{
          "filename" => filename,
          "content_type" => content_type(filename),
          "content_base64" => Base.encode64(content)
        }
      ]
    }
  end

  defp content_type(filename) do
    if String.ends_with?(filename, ".md"), do: "text/markdown", else: "application/json"
  end

  defp push_explainer!(ctx, run, text) do
    body = push_body("explainer", "explainer.md", text)
    pushed = json_response(write!(ctx, run, "/artifacts", body), 201)
    assert %{"type" => "explainer", "name" => "main"} = pushed["artifact"]
    pushed["artifact"]
  end

  defp verdict!(ctx, run, body) do
    stored = json_response(write!(ctx, run, "/verdict", body), 201)
    assert %{"type" => "verdict", "name" => "main"} = stored["artifact"]
    stored
  end

  defp artifact(index, type) do
    assert [artifact] = Enum.filter(index["artifacts"], &(&1["type"] == type))
    artifact
  end

  ## The documents

  # The proposal explore-a-ticket's run pushes, as Markdown.
  defp proposal do
    """
    ## What this is

    Acme customers pay part of a Web shop order with a gift card.

    ## How to do it

    Take the gift card as a second payment of the order.

    ## Alternatives

    - Turn the gift card into a discount. Why not: a discount changes the order's taxes.
    """
  end

  # Version 2: Shape must output acceptance criteria; Build reads them, runs a loop of
  # capture-demo, at most 3 rounds, and must output an explainer.
  defp build_document(document) do
    update_stage(document, fn
      %{"id" => @shape} = stage ->
        Map.put(stage, "outputs", [%{"type" => "acceptance-criteria", "required" => true}])

      %{"id" => @build} = stage ->
        Map.merge(stage, %{
          "inputs" => [%{"type" => "acceptance-criteria", "required" => true}],
          "sequence" => [
            %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "capture-demo"}]}}
          ],
          "outputs" => [%{"type" => "explainer", "required" => true}]
        })

      stage ->
        stage
    end)
  end

  defp rounds(document, rounds) do
    update_stage(document, fn
      %{"id" => @build} = stage ->
        put_in(stage, ["sequence", Access.at(0), "loop", "rounds"], rounds)

      stage ->
        stage
    end)
  end

  defp update_stage(document, fun), do: Map.update!(document, "stages", &Enum.map(&1, fun))

  ## Reading

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp assert_place(work_item, stage_id, state, round) do
    assert {work_item.stage_id, work_item.stage_state, work_item.stage_round} ==
             {stage_id, state, round}
  end

  defp runs(work_item),
    do:
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^work_item.id,
          order_by: [r.take_in, r.attempt]
      )

  defp newest_run(work_item), do: work_item |> runs() |> List.last()

  defp decisions(work_item, stage_id),
    do:
      Repo.all(
        from d in GateDecision,
          where: d.work_item_id == ^work_item.id and d.stage_id == ^stage_id,
          order_by: d.inserted_at
      )
end
