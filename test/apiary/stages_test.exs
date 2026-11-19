defmodule Apiary.StagesTest do
  # The stage runner with the workflow model on (`Apiary.Stages`): a take in enters the
  # first stage and queues explore-a-ticket through today's dispatch; a run's end through
  # its settle reads the proposal and the questions the run pushed; the gate, the
  # escalations, moves, and what the work item page reads.
  # Not async: a test sets the store adapter, the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures
  import Apiary.MachineTypesFixtures

  alias Apiary.{Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{DispatchRun, Settle}
  alias Apiary.Organisations.Workspace
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Confirmation, Explore, Moves, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  # The point of a run outside a loop that ended with no verdict (`Apiary.Stages.Points`).
  @no_verdict %{"text" => "The run stopped before its verdict.", "action" => "run_again"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp take_in!(scope), do: taken_in_fixture(scope)

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  # Turns the workflow model on or off for this test.
  defp workflow_model(on?) do
    previous = Application.get_env(:apiary, :features)

    features =
      if on?,
        do: Enum.uniq([:workflow_model | previous]),
        else: List.delete(previous, :workflow_model)

    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
  end

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

  # A run of the queue of the work item, after its newest, that has not ended: a run that
  # may push and withdraw.
  defp live_run!(work_item) do
    newest = newest_run(work_item)

    %DispatchRun{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id
    }
    |> DispatchRun.queue_changeset(%{
      work_item_id: work_item.id,
      step: newest.step,
      take_in: newest.take_in,
      attempt: newest.attempt + 1,
      of: max(newest.of, newest.attempt + 1),
      queued_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # The registered run of the run of the queue `run`, cancelled by a member: what `run`
  # pushed or withdrew counts for nothing (`Apiary.Artifacts.cancelled?/1`).
  defp cancel_run!(scope, run) do
    Apiary.RunEventsFixtures.run_fixture(scope, %{
      dispatch_run_id: run.id,
      cancel_requested_at: DateTime.utc_now()
    })
  end

  # The approvals of the work item as a gate `none` records them: with no member, so that a
  # run may withdraw the versions they cover.
  defp automatic_approval!(work_item) do
    {1, _rows} =
      Repo.update_all(from(d in GateDecision, where: d.work_item_id == ^work_item.id),
        set: [user_id: nil, automatic: true]
      )

    :ok
  end

  # A version of the explainer `name` that the run of the queue `run` pushes at Explore.
  defp push_explainer(run, name) do
    Stages.Artifacts.push(
      {:run, run},
      Repo.get!(WorkItem, run.work_item_id),
      "explainer",
      [%{filename: "explainer.md", content_type: "text/markdown", binary: "# A"}],
      name: name,
      stage_id: @explore
    )
  end

  # The one file of a `proposal` version, as a run pushes it: the proposal as Markdown.
  defp a_proposal do
    [
      %{
        filename: "proposal.md",
        content_type: "text/markdown",
        binary: understood_result()["message"]
      }
    ]
  end

  # The end of a run that pushes the verdict `verdict`, with `points` where given, as
  # `Apiary.StagesFixtures.end_run!/3` takes it.
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

  # A point that asks a person to run another round, as a run or Core writes it.
  defp again(text), do: %{"text" => text, "action" => "run_again"}

  # The point of a failed Exists check, with the output type's words, such as "acceptance
  # criteria" (`Apiary.Stages.Points.check_failed/1`).
  defp stored_no(words),
    do: %{
      "text" => "Run another round: the run stored no #{words}.",
      "action" => "run_again",
      "action_in_text" => true
    }

  # A run of Explore that pushed proposal version 1 and a question, then a second run of
  # the take in, queued by the answer: the work item, waiting for that second run's end.
  defp answered_after_proposal!(scope) do
    work_item =
      take_in!(scope)
      |> end_run!(fn run, registered ->
        push_result!(run, registered, understood_result())
        push_result!(run, registered, questions_result(["Which basket?"]))
      end)

    assert work_item.stage_state == :waiting_answers
    {:ok, _work_item} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})
    assert %DispatchRun{attempt: 2, state: :waiting} = newest_run(work_item)
    reload(work_item)
  end

  # The end of a run that pushes its proposal and no verdict.
  defp proposal_only, do: &push_output!(&1, &2, understood_result())

  # The text of a version's first file.
  defp read_text(%{files: [file | _rest]}) do
    case Artifacts.open_file(file) do
      {:ok, path} when is_binary(path) -> File.read!(path)
      {:ok, stream} -> stream |> Enum.to_list() |> IO.iodata_to_binary()
    end
  end

  # Explore as the default process has it: explore-a-ticket, with no loop.
  defp explore_stage(extra \\ %{}) do
    stage(
      @explore,
      "Explore",
      [%{"workflow" => "explore-a-ticket"}],
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
               loop_entry: nil
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
               loop_entry: nil,
               workflow: "explore-a-ticket",
               machine_type: "standard"
             } = run

      assert run.process_version_id == version.id

      # The process picks the default type, and the run has the seeded default's spec.
      assert run.machine_spec == %{
               "vcpus" => 2,
               "memory_mib" => 4096,
               "disk_gib" => 30,
               "arch" => "amd64",
               "virtualization" => false
             }

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

    test "a check is for whoever may approve the stage's gate: anyone else reads nothing", %{
      scope: scope
    } do
      member = member_fixture(scope)
      :ok = Processes.record_declared(scope.workspace, ["review"])

      save!(scope, [
        stage(@explore, "Explore", [%{"workflow" => "capture-demo"}], %{
          "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
        })
      ])

      work_item = take_in!(scope)
      assert work_item.stage_state == :waiting_workflow
      read = fn _scope, _workspace -> flunk("read for a person who may not approve") end

      assert Stages.check_workflows(member.scope, work_item, read) == {:error, :not_approver}
      assert %{stage_state: :waiting_workflow} = reload(work_item)

      assert {:ok, %WorkItem{stage_state: :running}} =
               Stages.check_workflows(scope, work_item, fn _scope, _workspace ->
                 {:ok, ["review", "capture-demo"]}
               end)
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
               "Choose another workflow for Explore in Workspace settings › Workflows. To " <>
                 "keep capture-demo, change the harness in Workspace settings › Harness to " <>
                 "one that lists it under workflows. Explore uses capture-demo, which the " <>
                 "Qory harness does not list."

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

    test "take_in_starts/2 reads the run a take in would queue, by the take in's rule", %{
      scope: scope
    } do
      ticket = backlog_ticket_fixture(scope)

      assert Stages.take_in_starts(scope.workspace, ticket.public_id) ==
               {:run, "explore-a-ticket"}

      save!(scope, [
        explore_stage(%{"inputs" => [%{"type" => "acceptance-criteria", "required" => true}]})
      ])

      assert Stages.take_in_starts(scope.workspace, ticket.public_id) == :none
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

      assert {:ok, %WorkItem{stage_state: :waiting_inputs}} = Stages.resume(work_item)
      assert runs(work_item) == []
    end
  end

  describe "the machine type of a queued run" do
    test "is the type the entry picks, with its spec, kept after the type changes", %{
      scope: scope
    } do
      large = machine_type_fixture(key: "large", disk_gib: 60)

      save!(scope, [
        stage(@explore, "Explore", [%{"workflow" => "explore-a-ticket", "machine" => "large"}])
      ])

      work_item = take_in!(scope)
      assert [run] = runs(work_item)
      assert run.machine_type == "large"
      assert run.machine_spec == spec(%{disk_gib: 60})

      # A later change of the type changes no queued run.
      large |> Ecto.Changeset.change(vcpus: 8) |> Repo.update!()
      assert Repo.get!(DispatchRun, run.id).machine_spec == spec(%{disk_gib: 60})
    end

    test "is the document's type for an entry that picks none", %{scope: scope} do
      machine_type_fixture(key: "large")

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "large",
        "stages" => [stage(@explore, "Explore", [%{"workflow" => "explore-a-ticket"}])]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      assert [%DispatchRun{machine_type: "large", machine_spec: spec}] =
               scope |> take_in!() |> runs()

      assert spec == spec()
    end

    test "is the default type for a type deleted after the save", %{scope: scope} do
      large = machine_type_fixture(key: "large")

      save!(scope, [
        stage(@explore, "Explore", [%{"workflow" => "explore-a-ticket", "machine" => "large"}])
      ])

      Repo.delete!(large)

      assert [%DispatchRun{machine_type: "standard", machine_spec: %{"vcpus" => 2}}] =
               scope |> take_in!() |> runs()
    end
  end

  describe "whether a run is a run of Explore" do
    # No commit or file of the Qory harness kept, as before its first read, and so no
    # process version made from a commit of it.
    defp no_harness_kept! do
      {_count, _rows} = Repo.delete_all("qory_harness_heads")
      {_count, _rows} = Repo.delete_all("qory_harness_files")
      Repo.query!("UPDATE process_versions SET template = template - 'commit'")
      :ok
    end

    test "is kept when the run is queued, so its end does not wait on the stored harness files",
         %{scope: scope} do
      work_item = take_in!(scope)
      assert %DispatchRun{explore: true, workflow: "explore-a-ticket"} = newest_run(work_item)

      # The window before the first read of the Qory harness: no files are kept.
      no_harness_kept!()
      assert Stages.explore_workflow(scope.workspace) == nil
      assert Stages.explore_run?(newest_run(work_item))

      work_item = end_run!(work_item, understood_result())
      assert work_item.stage_state == :at_gate
      assert [%{stage_id: @explore}] = versions(work_item, "proposal")
    end

    test "is not known at the queue before the first read, nor after it while none is kept",
         %{scope: scope} do
      no_harness_kept!()

      assert Stages.explore_at_queue("explore", "explore-a-ticket", scope.workspace.id) == nil
      assert Stages.explore_at_queue("explore", nil, scope.workspace.id)
      refute Stages.explore_at_queue("build", "explore-a-ticket", scope.workspace.id)

      run = %DispatchRun{
        step: "explore",
        workflow: "explore-a-ticket",
        workspace_id: scope.workspace.id
      }

      assert Stages.explore_run?(run) == nil
      assert Stages.known_explore(run) == nil
    end

    test "not known, leaves the end of the run for later, and is read once the files are kept",
         %{scope: scope} do
      work_item = take_in!(scope)
      run = newest_run(work_item)
      no_harness_kept!()

      # A run queued before the first read, its record with no answer, which ended lost.
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [explore: nil, state: :ended, end_cause: :lost]
        )

      assert {:ok, []} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert %WorkItem{stage_state: :running} = reload(work_item)
      refute escalation(work_item)
      assert %DispatchRun{explore: nil} = Repo.get!(DispatchRun, run.id)

      # The first read keeps the files: the end is read as a run of Explore that stopped.
      {:ok, _commit} = Apiary.Harnesses.Qory.read({:branch, "main"})

      assert {:ok, [_told]} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert %DispatchRun{explore: true} = Repo.get!(DispatchRun, run.id)
      assert %Escalation{cause: :run_stopped} = escalation(work_item)
    end

    test "reads the commit the workspace's harness settings choose, not main's",
         %{scope: scope} do
      files =
        Map.new(Apiary.QoryHarnessFixture.files(), fn {path, content} ->
          {path, String.replace(content, "explore-a-ticket", "explore-v2")}
        end)

      Apiary.QoryHarnessFixture.serve!(files, tags: ["v2"])
      {:ok, _row} = Apiary.Stacks.Sources.choose(scope, {:qory, {:tag, "v2"}})

      assert Stages.explore_workflow(scope.workspace) == "explore-v2"
      assert Processes.qory_workflows(Apiary.Harnesses.Qory.current()) == ["explore-a-ticket"]
    end

    test "reads the newest commit kept where the chosen commit's files are not kept",
         %{scope: scope} do
      {:ok, row} =
        Apiary.Stacks.Sources.choose(
          scope,
          {:qory, {:commit, Apiary.QoryHarnessFixture.commit()}}
        )

      row
      |> Ecto.Changeset.change(version_name: String.duplicate("ab", 20))
      |> Repo.update!()

      assert Apiary.Harnesses.Qory.workspace_commit(scope.workspace) == nil
      assert Stages.explore_workflow(scope.workspace) == "explore-a-ticket"
    end
  end

  describe "the end of a run of Explore" do
    test "a proposal the run pushed, with no open question, opens the gate", %{
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
      # The run pushed its proposal and its verdict, which the run list shows.
      assert [%{writer: :run, run_id: run_id}] = versions(work_item, "verdict")
      assert run_id == run.id

      assert [%{filename: "proposal.md", content_type: "text/markdown; charset=utf-8"}] =
               proposal.files

      assert read_text(proposal) == understood_result()["message"]

      status = Stages.status(work_item, scope)

      assert %{stage: %{id: @explore, name: "Explore"}, state: :at_gate, round: 1, rounds: nil} =
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
               ~w(attempt end_cause ended_at id of round stage_id started_at status take_in verdict workflow)a

      public_id = work_item.public_id
      assert_receive {:stage_changed, ^public_id}
      assert_receive {:work_items_changed, [^public_id]}

      # Nothing but `{:work_items_changed, ids}` reaches the work items' topic.
      refute_received {:stage_changed, _id}
    end

    test "open questions wait for answers; the answers run the same workflow again", %{
      scope: scope
    } do
      work_item = take_in!(scope)
      work_item = end_run!(work_item, questions_result())

      assert work_item.stage_state == :waiting_answers
      assert [questions] = versions(work_item, "questions")
      assert %{writer: :run} = questions

      assert %{"questions" => [%{"id" => "q1", "state" => "open"}, %{"id" => "q2"}]} =
               Stages.Artifacts.read_json(questions)

      {:ok, _work_item} =
        WorkItems.answer(scope, work_item, 1, %{"1" => "The main one", "2" => "Spring"})

      work_item = reload(work_item)

      # Explore has no loop: the same workflow runs again in the same round.
      assert %{stage_state: :running, stage_round: 1} = work_item

      assert %DispatchRun{
               attempt: 2,
               of: 3,
               round: 1,
               loop_entry: nil,
               workflow: "explore-a-ticket"
             } =
               newest_run(work_item)
    end

    test "open questions at the last run wait for answers, past the runs counted", %{
      scope: scope
    } do
      work_item = take_in!(scope)

      work_item =
        Enum.reduce(1..3, work_item, fn attempt, work_item ->
          work_item = end_run!(work_item, questions_result())
          assert work_item.stage_state == :waiting_answers
          {:ok, _} = WorkItems.answer(scope, work_item, attempt, %{"1" => "a", "2" => "b"})
          reload(work_item)
        end)

      assert %DispatchRun{attempt: 4, of: 4} = newest_run(work_item)
      work_item = end_run!(work_item, questions_result())
      assert work_item.stage_state == :waiting_answers
      refute escalation(work_item)
    end

    test "open questions in a loop's last round wait for answers", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "explore-a-ticket"}]}}
          ]
        })
      ])

      work_item = take_in!(scope) |> end_run!(questions_result())
      assert work_item.stage_state == :waiting_answers
      refute escalation(work_item)
    end

    test "a run that pushed no proposal and passed escalates check_failed", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(verdict("passed"))

      assert work_item.stage_state == :escalated

      points = [stored_no("proposal")]
      assert %Escalation{cause: :check_failed, round: 1, points: ^points} = escalation(work_item)

      assert %{verdict: :passed} = hd(Stages.runs(work_item))
    end

    test "a run that pushed no proposal and changes-requested escalates check_failed", %{
      scope: scope
    } do
      work_item = take_in!(scope) |> end_run!(verdict("changes-requested"))

      assert work_item.stage_state == :escalated

      points = [stored_no("proposal")]
      assert %Escalation{cause: :check_failed, round: 1, points: ^points} = escalation(work_item)

      assert %{verdict: :failed} = hd(Stages.runs(work_item))
    end

    test "a run with no proposal and no verdict escalates run_stopped", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(nil)

      assert work_item.stage_state == :escalated

      assert %Escalation{cause: :run_stopped, round: 1, points: [@no_verdict]} =
               escalation(work_item)

      assert %{verdict: nil} = hd(Stages.runs(work_item))
    end

    test "a proposal with no verdict goes on to the gate, and Confirm moves the work item on",
         %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(proposal_only())

      assert work_item.stage_state == :at_gate
      refute escalation(work_item)
      assert versions(work_item, "verdict") == []
      assert [%{number: 1}] = versions(work_item, "proposal")
      assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())
      assert %{verdict: :passed} = hd(Stages.runs(work_item))

      assert {:ok, %WorkItem{stage_id: @shape}} = WorkItems.confirm(scope, work_item, 1)
    end

    test "the run list reads a proposal with no verdict as passed where the run did not stop", %{
      scope: scope
    } do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "explore-a-ticket"}]}}
          ]
        })
      ])

      work_item = take_in!(scope) |> end_run!(proposal_only())

      assert %WorkItem{stage_state: :running, stage_round: 2} = work_item
      refute escalation(work_item)
      assert [%{verdict: nil}, %{verdict: :passed}] = Stages.runs(work_item)
    end

    test "another round after a run with no result reruns, and a proposal reaches Confirm", %{
      scope: scope
    } do
      work_item = take_in!(scope) |> end_run!(nil)
      assert %Escalation{cause: :run_stopped, points: [@no_verdict]} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :running}} =
               Stages.resolve_escalation(scope, work_item, :another_round, nil,
                 expect_stage: @explore
               )

      assert %DispatchRun{attempt: 2, round: 1} = newest_run(work_item)

      work_item = end_run!(work_item, proposal_only())

      assert work_item.stage_state == :at_gate
      assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())
      assert {:ok, %WorkItem{stage_id: @shape}} = WorkItems.confirm(scope, work_item, 2)
    end

    test "a rerun after a review comment with no verdict goes on: the take in has its proposal",
         %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())
      assert work_item.stage_state == :at_gate

      assert {:ok, %{}} = WorkItems.answer(scope, work_item, 1, "Also read the sale page.")
      assert %WorkItem{stage_state: :running} = reload(work_item)

      work_item = end_run!(reload(work_item), nil)

      assert work_item.stage_state == :at_gate
      refute escalation(work_item)
      assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())
    end

    test "open questions wait, ahead of a passed verdict", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(questions_result())

      assert [%{writer: :run}] = versions(work_item, "verdict")
      assert work_item.stage_state == :waiting_answers
      refute escalation(work_item)
    end

    test "open questions wait with no verdict too", %{scope: scope} do
      asks = &push_output!(&1, &2, questions_result())
      work_item = take_in!(scope) |> end_run!(asks)

      assert versions(work_item, "verdict") == []
      assert work_item.stage_state == :waiting_answers
      refute escalation(work_item)
    end

    test "a run that passed and then failed stopped: its exit comes before the verdict", %{
      scope: scope
    } do
      work_item =
        take_in!(scope)
        |> end_run!(verdict("passed"), %{exit_state: "failed", outcome_state: "failed"})

      assert %Escalation{cause: :run_stopped, points: [%{"text" => text}]} = escalation(work_item)
      assert text =~ "The run stopped: "
      assert %{verdict: nil} = hd(Stages.runs(work_item))
    end

    test "a run with a proposal, passed and a failed exit has no verdict, also after Approve", %{
      scope: scope
    } do
      proposal_and_passed = fn run, registered ->
        proposal_only().(run, registered)
        verdict("passed").(run, registered)
      end

      work_item =
        take_in!(scope)
        |> end_run!(proposal_and_passed, %{exit_state: "failed", outcome_state: "failed"})

      assert %Escalation{cause: :run_stopped} = escalation(work_item)
      assert %{verdict: nil} = hd(Stages.runs(work_item))

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @explore)

      assert %WorkItem{stage_id: @shape} = work_item
      assert %{verdict: nil} = hd(Stages.runs(work_item))
    end

    test "a confirmation is refused while the stage is escalated, and writes nothing", %{
      scope: scope
    } do
      outputs = [
        %{"type" => "proposal", "required" => true},
        %{"type" => "explainer", "required" => true}
      ]

      save!(scope, [explore_stage(%{"outputs" => outputs}), stage(@shape, "Shape", [])])
      work_item = take_in!(scope) |> end_run!(understood_result())
      run = newest_run(work_item)

      # The proposal waits, and the stage escalated: the explainer is missing.
      assert %Escalation{cause: :check_failed} = escalation(work_item)
      assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())

      assert {:error, :not_waiting} = WorkItems.confirm(scope, work_item, run.attempt)

      assert %WorkItem{stage_state: :escalated, stage_id: @explore} = reload(work_item)
      refute Repo.get_by(Confirmation, work_item_id: work_item.id)

      # Another round writes the explainer, and the stage reaches its gate.
      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil, expect_stage: @explore)

      work_item = end_run!(work_item, pushes(["explainer"], 1, "passed"))
      assert %WorkItem{stage_state: :at_gate, stage_id: @explore} = work_item
      run = newest_run(work_item)

      assert {:ok, %WorkItem{stage_id: @shape}} =
               WorkItems.confirm(scope, work_item, run.attempt)
    end

    test "Accept as it is at the last stage with a gate none closes the work item", %{
      scope: scope
    } do
      save!(scope, [explore_stage(%{"gate" => %{"kind" => "none"}})])

      work_item =
        take_in!(scope)
        |> end_run!(understood_result(), %{exit_state: "failed", outcome_state: "failed"})

      assert %Escalation{cause: :run_stopped} = escalation(work_item)

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      assert %WorkItem{state: :closed, stage_id: @explore, stage_state: :done} =
               reload(work_item)
    end

    test "a verdict with another name counts as none: the run stops, with no verdict", %{
      scope: scope
    } do
      other = fn run, _registered ->
        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            [
              %{
                filename: "verdict.json",
                content_type: "application/json",
                binary: Jason.encode!(%{"verdict" => "passed"})
              }
            ],
            name: "other",
            stage_id: run.stage_id
          )
      end

      work_item = take_in!(scope) |> end_run!(other)

      assert %Escalation{cause: :run_stopped, points: [@no_verdict]} = escalation(work_item)
      assert %{verdict: nil} = hd(Stages.runs(work_item))
    end

    test "another workflow's verdict file that cannot be read raises; readable, it counts", %{
      scope: scope
    } do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "write"}])])
      work_item = take_in!(scope)
      run = newest_run(work_item)
      work_item = end_run!(work_item, verdict("passed"))
      assert work_item.stage_state == :at_gate

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :running, stage_entry: 0]
        )

      [file] = hd(versions(work_item, "verdict")).files
      {:ok, path} = Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      assert_raise Apiary.Stages.VerdictUnreadable, fn ->
        Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      end

      assert %WorkItem{stage_state: :running} = reload(work_item)
      refute escalation(work_item)

      File.rename!(path <> ".away", path)
      {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert %WorkItem{stage_state: :at_gate} = reload(work_item)
      refute escalation(work_item)
    end

    test "Explore's escalate escalates, with its points, and a proposal with changes-requested goes on",
         %{
           scope: scope
         } do
      push = fn verdict ->
        fn run, registered ->
          proposal_only().(run, registered)
          points = if verdict == "escalate", do: [again("The ticket has no basket.")]
          verdict(verdict, points).(run, registered)
        end
      end

      escalated = take_in!(scope) |> end_run!(push.("escalate"))
      assert %Escalation{cause: :escalate} = escalation(escalated)

      gate = take_in!(scope) |> end_run!(push.("changes-requested"))
      assert gate.stage_state == :at_gate
      refute escalation(gate)
    end

    test "a test work item's run with no verdict goes on to the checks", %{scope: scope} do
      {:ok, work_item} = WorkItems.take_in_test(scope, "Hi! Where are you running?")
      work_item = end_run!(reload(work_item), nil)

      assert %WorkItem{test: true, stage_state: :escalated} = work_item
      assert %Escalation{cause: :check_failed} = escalation(work_item)
    end

    test "a verdict under another name is not the verdict of a run that did not stop", %{
      scope: scope
    } do
      {:ok, work_item} = WorkItems.take_in_test(scope, "Hi! Where are you running?")

      other = fn run, _registered ->
        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            [
              %{
                filename: "verdict.json",
                content_type: "application/json",
                binary: Jason.encode!(%{"verdict" => "passed"})
              }
            ],
            name: "other",
            stage_id: run.stage_id
          )
      end

      work_item = end_run!(reload(work_item), other)

      assert %Escalation{cause: :check_failed} = escalation(work_item)
      assert %{verdict: nil} = hd(Stages.runs(work_item))
    end

    test "a test work item's run with no verdict reaches the gate with no required output", %{
      scope: scope
    } do
      save!(scope, [explore_stage(%{"outputs" => []})])
      {:ok, work_item} = WorkItems.take_in_test(scope, "Hi! Where are you running?")
      work_item = end_run!(reload(work_item), nil)

      assert %WorkItem{test: true, stage_state: :at_gate} = work_item
      refute escalation(work_item)
    end

    test "a workflow with no verdict, not the last entry, escalates; Accept starts the next", %{
      scope: scope
    } do
      save!(scope, [
        stage(@explore, "Explore", [%{"workflow" => "write"}, %{"workflow" => "check"}])
      ])

      work_item = take_in!(scope)
      assert %DispatchRun{workflow: "write"} = newest_run(work_item)
      work_item = end_run!(work_item, nil)

      assert work_item.stage_state == :escalated
      assert %Escalation{cause: :run_stopped, points: [@no_verdict]} = escalation(work_item)
      assert %DispatchRun{workflow: "write"} = newest_run(work_item)

      assert {:ok, %WorkItem{stage_state: :running, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      assert %DispatchRun{workflow: "check"} = newest_run(work_item)

      # The last entry's run with no verdict, on a run after another round too.
      work_item = end_run!(reload(work_item), nil)
      assert %Escalation{cause: :run_stopped} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :running, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :another_round, nil,
                 expect_stage: @explore
               )

      assert %DispatchRun{workflow: "check"} = newest_run(work_item)
      work_item = end_run!(reload(work_item), nil)
      assert %Escalation{cause: :run_stopped} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate, stage_entry: 2}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)
    end

    test "a workflow outside a loop goes on after passed and changes-requested", %{scope: scope} do
      save!(scope, [
        stage(@explore, "Explore", [
          %{"workflow" => "write"},
          %{"workflow" => "check"},
          %{"workflow" => "ship"}
        ])
      ])

      work_item = take_in!(scope) |> end_run!(verdict("passed"))
      assert %WorkItem{stage_state: :running, stage_entry: 1} = work_item

      work_item = end_run!(work_item, verdict("changes-requested"))
      assert %WorkItem{stage_state: :running, stage_entry: 2} = work_item

      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_state: :at_gate} = work_item
      refute escalation(work_item)
    end

    test "changes-requested with run_again points goes on as changes-requested does", %{
      scope: scope
    } do
      save!(scope, [
        stage(@explore, "Explore", [%{"workflow" => "write"}, %{"workflow" => "check"}])
      ])

      points = [%{"text" => "The demo has no second card.", "action" => "run_again"}]
      work_item = take_in!(scope) |> end_run!(verdict("changes-requested", points))
      assert %WorkItem{stage_state: :running, stage_entry: 1} = work_item
      refute escalation(work_item)
    end

    test "in a loop, a run with no verdict starts the next round", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "explore-a-ticket"}]}}
          ]
        })
      ])

      work_item = take_in!(scope) |> end_run!(proposal_only())
      assert %WorkItem{stage_state: :running, stage_round: 2} = work_item

      work_item = end_run!(work_item, nil)

      assert %Escalation{
               cause: :round_limit,
               round: 2,
               points: [%{"text" => "2 of 2 rounds ran.", "action" => "run_again"}]
             } = escalation(work_item)
    end

    test "a run that exited failed escalates run_stopped", %{scope: scope} do
      work_item = take_in!(scope)
      work_item = end_run!(work_item, nil, %{exit_state: "failed", outcome_state: "failed"})

      assert work_item.stage_state == :escalated

      # With no proposal written, it reads as a run with no result.
      assert %Escalation{
               cause: :run_stopped,
               points: [
                 %{
                   "text" => "The run stopped: it ended without a result.",
                   "action" => "run_again"
                 }
               ]
             } = escalation(work_item)
    end

    test "a run that failed after it wrote a proposal escalates run_stopped with its version",
         %{scope: scope} do
      work_item = take_in!(scope)

      work_item =
        end_run!(work_item, understood_result(), %{exit_state: "failed", outcome_state: "failed"})

      assert work_item.stage_state == :escalated

      assert %Escalation{
               cause: :run_stopped,
               points: [
                 %{
                   "text" => "The run stopped: it failed after it wrote proposal version 1.",
                   "action" => "run_again"
                 }
               ]
             } = escalation(work_item)

      # The proposal is the stage's output, so the member may accept it as it is.
      assert [%{type: "proposal", check: :passed}] = Stages.status(work_item).outputs

      assert {:ok, %WorkItem{stage_state: :at_gate}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil,
                 expect_stage: reload(work_item).stage_id
               )
    end

    test "open questions come before a run that stopped", %{scope: scope} do
      work_item = take_in!(scope)

      work_item =
        end_run!(work_item, questions_result(), %{exit_state: "failed", outcome_state: "failed"})

      assert work_item.stage_state == :waiting_answers
      refute escalation(work_item)
    end

    test "a run that pushed a proposal and no open question goes on to the gate", %{
      scope: scope
    } do
      work_item = take_in!(scope) |> end_run!(understood_result())
      assert work_item.stage_state == :at_gate
    end

    test "a lost run escalates run_stopped", %{scope: scope} do
      work_item = take_in!(scope)
      run = newest_run(work_item)
      run |> Ecto.Changeset.change(state: :ended, end_cause: :lost) |> Repo.update!()

      {:ok, told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert told == [{:work_item, work_item.workspace_id, work_item.public_id}]

      assert %Escalation{
               cause: :run_stopped,
               points: [
                 %{
                   "text" =>
                     "The run stopped: Qory Apiary got no report from it and marked it lost.",
                   "action" => "run_again"
                 }
               ]
             } =
               escalation(work_item)
    end

    test "a run that writes and has no wall escalates run_stopped with its fix, for each kind of pool",
         %{scope: scope} do
      cause =
        "The run stopped: a run that writes to the checkout needs a wall, and this machine has none."

      for {pool, fix} <- [
            {Apiary.NodesFixtures.pool_fixture(scope),
             "Set a wall in the machine's forager.yaml, then start the run again."},
            {Apiary.NodesFixtures.instance_pool_fixture(installed_as: "pool"), "Contact support."}
          ] do
        work_item =
          scope
          |> take_in!()
          |> end_run!(nil, %{
            state: "failed",
            exit_state: "failed",
            reason: "write_needs_wall",
            node_id: pool.id,
            outcome_state: nil,
            outcome_time: nil,
            outcome_received_at: nil,
            outcome_digest: nil
          })

        assert %Escalation{
                 cause: :run_stopped,
                 points: [%{"text" => ^cause, "action" => "run_again", "fix" => ^fix}]
               } = escalation(work_item)
      end
    end

    test "a run that reached its time limit escalates run_stopped with its attempt and stage, and no fix",
         %{scope: scope} do
      save!(scope, [stage(@build, "Build", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope)
      live_run!(work_item)

      work_item =
        end_run!(work_item, nil, %{
          state: "cancelled",
          exit_state: "cancelled",
          exit_code: 124,
          reason: "timeout",
          outcome_state: nil,
          outcome_time: nil,
          outcome_received_at: nil,
          outcome_digest: nil
        })

      assert work_item.stage_state == :escalated

      assert %Escalation{cause: :run_stopped, points: [point]} = escalation(work_item)

      assert point ==
               %{
                 "text" =>
                   "The run stopped: Attempt 2 reached its time limit, so Build has no result.",
                 "action" => "run_again"
               }
    end

    test "a run that pushed the verdict escalate escalates with its points, and nothing waits for Approve",
         %{scope: scope} do
      points = [
        %{
          "text" => "The ticket describes two baskets. Say which one to change.",
          "action" => "run_again"
        }
      ]

      work_item = scope |> answered_after_proposal!() |> end_run!(verdict("escalate", points))

      assert work_item.stage_state == :escalated
      assert %Escalation{cause: :escalate, round: 1, points: ^points} = escalation(work_item)

      assert %{state: :escalated, escalation: %{cause: :escalate, points: ^points}, gaps: nil} =
               Stages.status(work_item)

      # Proposal version 1 of the first run stays, and waits for no confirmation.
      assert [%{number: 1}] = versions(work_item, "proposal")
      assert %DispatchRun{attempt: 2, result_outcome: :none} = newest_run(work_item)
      assert %{status: :no_result} = Explore.current(work_item, DateTime.utc_now())
      refute Stages.status(work_item, scope).gate.approvable?
      assert WorkItems.confirm(scope, work_item, 2) == {:error, :not_waiting}
      assert [%{attempt: 2, verdict: :failed} | _] = Stages.runs(work_item)
    end

    test "a run with no verdict, or a verdict other than escalate, keeps the proposal's Approve",
         %{scope: scope} do
      for pushed <- [nil, verdict("passed"), verdict("changes-requested")] do
        work_item = scope |> answered_after_proposal!() |> end_run!(pushed)

        assert work_item.stage_state == :at_gate
        refute escalation(work_item)
        assert %DispatchRun{attempt: 2, result_outcome: :proposal} = newest_run(work_item)
        assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())
        assert Stages.status(work_item, scope).gate.approvable?
      end
    end

    test "open questions with escalate wait for answers and keep the escalation with its points",
         %{scope: scope} do
      points = [
        %{
          "text" => "The ticket describes two baskets.",
          "action" => "answer",
          "question" => "q1"
        },
        %{"text" => "The ticket links no sale page.", "action" => "run_again"}
      ]

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          push_result!(run, registered, questions_result(["Which basket?"]))
          verdict("escalate", points).(run, registered)
        end)

      # Open questions come first: the stage waits for answers, with the escalation open.
      assert work_item.stage_state == :waiting_answers
      assert %DispatchRun{result_outcome: :questions} = newest_run(work_item)

      assert %Escalation{cause: :escalate, round: 1, points: ^points, resolved_at: nil} =
               escalation(work_item)

      assert %{
               state: :waiting_answers,
               escalation: %{cause: :escalate, points: ^points},
               gaps: nil
             } =
               Stages.status(work_item, scope)

      # The answers run the next round and resolve the escalation as another round.
      {:ok, _work_item} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})

      assert %WorkItem{stage_state: :running} = reload(work_item)
      assert %DispatchRun{attempt: 2, state: :waiting} = newest_run(work_item)
      refute escalation(work_item)

      assert [%Escalation{resolution: :another_round, resolved_at: %DateTime{}}] =
               Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id)
    end

    test "an answer point whose question the run withdrew after its verdict asks for another round",
         %{scope: scope} do
      points = [
        %{
          "text" => "The ticket describes two baskets.",
          "action" => "answer",
          "question" => "q1"
        },
        %{"text" => "The ticket links no sale page.", "action" => "run_again"}
      ]

      # The run asks q1, gives its verdict with a point about q1, then withdraws q1.
      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          push_result!(run, registered, questions_result(["Which basket?"]))
          verdict("escalate", points).(run, registered)

          work_item = Repo.get!(WorkItem, run.work_item_id)
          {_version, document} = Apiary.Explore.Questions.newest(work_item)

          withdrawn =
            update_in(document["questions"], fn questions ->
              for question <- questions, do: %{question | "state" => "withdrawn"}
            end)

          {:ok, _version} =
            Stages.Artifacts.push_json({:run, run}, work_item, "questions", withdrawn,
              stage_id: run.stage_id
            )
        end)

      # No question is open, so the stage escalates; the point keeps its sentence and asks
      # for another round, and no point is dropped.
      assert work_item.stage_state == :escalated

      assert %Escalation{cause: :escalate, points: stored} = escalation(work_item)

      assert stored == [
               %{"text" => "The ticket describes two baskets.", "action" => "run_again"},
               %{"text" => "The ticket links no sale page.", "action" => "run_again"}
             ]
    end

    test "while answers wait, an open escalation's other actions are refused", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          push_result!(run, registered, questions_result(["Which basket?"]))

          verdict("escalate", [
            %{"text" => "The ticket links no sale page.", "action" => "run_again"}
          ]).(run, registered)
        end)

      assert work_item.stage_state == :waiting_answers
      assert %Escalation{cause: :escalate} = escalation(work_item)

      for resolution <- [:accept, :another_round, {:move_back, @explore}, :close] do
        assert Stages.resolve_escalation(scope, work_item, resolution, nil,
                 expect_stage: work_item.stage_id
               ) == {:error, :not_escalated}
      end

      # Nothing changed: the stage still waits, with the escalation open.
      assert %WorkItem{stage_state: :waiting_answers, state: state} = reload(work_item)
      assert state != :closed
      assert %Escalation{resolved_at: nil} = escalation(work_item)
    end

    test "after an escalate, another round with no verdict keeps the proposal's Approve",
         %{scope: scope} do
      points = [%{"text" => "The ticket describes two baskets.", "action" => "run_again"}]

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          push_result!(run, registered, understood_result())
          verdict("escalate", points).(run, registered)
        end)

      assert %Escalation{cause: :escalate, points: ^points} = escalation(work_item)

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil,
          expect_stage: work_item.stage_id
        )

      work_item = end_run!(reload(work_item), nil)

      assert work_item.stage_state == :at_gate
      refute escalation(work_item)

      assert [%Escalation{resolution: :another_round}] =
               Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id)

      assert %DispatchRun{attempt: 2, result_outcome: :proposal} = newest_run(work_item)
      assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())
      assert Stages.status(work_item, scope).gate.approvable?
    end

    test "a run that pushed escalate, then passed, keeps the proposal's Approve", %{
      scope: scope
    } do
      work_item =
        scope
        |> answered_after_proposal!()
        |> end_run!(fn run, registered ->
          verdict("escalate", [%{"text" => "The ticket is unclear.", "action" => "run_again"}]).(
            run,
            registered
          )

          verdict("passed").(run, registered)
        end)

      assert work_item.stage_state == :at_gate
      refute escalation(work_item)
      assert %DispatchRun{attempt: 2, result_outcome: :proposal} = newest_run(work_item)
    end

    test "a run that pushed a proposal and escalate, then exited failed, escalates escalate",
         %{scope: scope} do
      points = [
        %{
          "text" => "The ticket describes two baskets. Say which one to change.",
          "action" => "run_again"
        }
      ]

      work_item =
        scope
        |> answered_after_proposal!()
        |> end_run!(
          fn run, registered ->
            push_result!(run, registered, understood_result(%{"message" => "Version 2."}))
            verdict("escalate", points).(run, registered)
          end,
          %{exit_state: "failed", outcome_state: "failed"}
        )

      assert [%{number: 2}, %{number: 1}] = versions(work_item, "proposal")
      assert work_item.stage_state == :escalated
      assert %Escalation{cause: :escalate, points: ^points} = escalation(work_item)
      assert %DispatchRun{attempt: 2, result_outcome: :none} = newest_run(work_item)
    end

    test "a lost run that pushed escalate escalates run_stopped", %{scope: scope} do
      work_item = take_in!(scope)
      run = newest_run(work_item)
      registered = %Apiary.Runs.Run{}

      verdict("escalate", [%{"text" => "The ticket is unclear.", "action" => "run_again"}]).(
        run,
        registered
      )

      run |> Ecto.Changeset.change(state: :ended, end_cause: :lost) |> Repo.update!()

      {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)

      assert %Escalation{
               cause: :run_stopped,
               points: [
                 %{
                   "text" =>
                     "The run stopped: Qory Apiary got no report from it and marked it lost.",
                   "action" => "run_again"
                 }
               ]
             } = escalation(work_item)
    end

    test "an end whose verdict the store cannot read raises and changes nothing",
         %{scope: scope} do
      # A point no other test writes, so no other test stores the same file.
      points = [again("Which basket #{System.unique_integer([:positive])}?")]
      work_item = take_in!(scope) |> end_run!(verdict("escalate", points))
      run = newest_run(work_item)
      assert %Escalation{cause: :escalate} = escalation(work_item)

      # The end again, as the stage runner reads it, with the verdict's file away.
      Repo.delete_all(from e in Escalation, where: e.work_item_id == ^work_item.id)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :running]
        )

      [file] = Stages.Artifacts.newest_of_run(run, "verdict", "main").files
      {:ok, path} = Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      assert Stages.reported_verdict(run) == {:error, :store_unavailable}
      assert Apiary.Explore.Outcome.at_end(run) == nil

      assert_raise Apiary.Stages.VerdictUnreadable, fn ->
        Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      end

      assert %WorkItem{stage_state: :running} = reload(work_item)
      refute escalation(work_item)

      # Readable again, the end escalates.
      File.rename!(path <> ".away", path)
      {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert %Escalation{cause: :escalate, points: ^points} = escalation(work_item)
    end

    test "an end whose newest questions cannot be read raises and changes nothing, lost or not",
         %{scope: scope} do
      # A question no other test asks, so no other test stores the same file.
      text = "Which basket #{System.unique_integer([:positive])}?"
      work_item = take_in!(scope)
      run = newest_run(work_item)

      # Questions pushed, then the run's end stored with what it gave, `questions`, as a
      # settle that read them writes it; then the file cannot be read.
      work_item = end_run!(work_item, questions_result([text]))
      assert work_item.stage_state == :waiting_answers

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :running]
        )

      {version, _document} = Apiary.Explore.Questions.newest(work_item)
      [file] = version.files
      {:ok, path} = Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      for cause <- [:run_ended, :lost] do
        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [end_cause: cause, result_outcome: :questions]
        )

        assert_raise Apiary.Stages.QuestionsUnreadable, fn ->
          Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
        end

        assert %WorkItem{stage_state: :running} = reload(work_item)
        refute escalation(work_item)
      end

      # Readable again, the end is read as it is: the questions wait for answers.
      File.rename!(path <> ".away", path)
      {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)
      assert %WorkItem{stage_state: :waiting_answers} = reload(work_item)
      refute escalation(work_item)
    end

    test "a claim's end with unreadable questions is left, then read by the stage sweep",
         %{scope: scope} do
      text = "Which basket #{System.unique_integer([:positive])}?"
      work_item = take_in!(scope)
      run = newest_run(work_item)

      # The run pushed its questions while it was live; then a claim ended it before it
      # started, as the claim's end stores it, and the questions file cannot be read.
      work_item =
        end_run!(work_item, fn run, registered ->
          push_result!(run, registered, questions_result([text]))
        end)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :running]
        )

      Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
        set: [end_cause: :key_gone, result_outcome: :error]
      )

      {version, _document} = Apiary.Explore.Questions.newest(work_item)
      [file] = version.files
      {:ok, path} = Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      # The claim's act is left, with one warning: the end stays stored.
      {told, log} = ExUnit.CaptureLog.with_log(fn -> Stages.claim_ended([run.id]) end)
      assert told == []
      assert log =~ "stage end left for later, newest questions unreadable dispatch_run=#{run.id}"
      assert %WorkItem{stage_state: :running} = reload(work_item)
      assert %DispatchRun{state: :ended, end_cause: :key_gone} = Repo.get!(DispatchRun, run.id)

      # The stage sweep reads it at each tick until the file can be read, with one line
      # an hour.
      {{[], nil}, log} =
        ExUnit.CaptureLog.with_log(fn -> Stages.sweep(DateTime.utc_now(), nil) end)

      assert log =~
               "stage end failed dispatch_run=#{run.id} error=Apiary.Stages.QuestionsUnreadable"

      {{[], nil}, log} =
        ExUnit.CaptureLog.with_log(fn -> Stages.sweep(DateTime.utc_now(), nil) end)

      refute log =~ "dispatch_run=#{run.id}"
      assert %WorkItem{stage_state: :running} = reload(work_item)

      File.rename!(path <> ".away", path)
      assert {[_], nil} = Stages.sweep(DateTime.utc_now(), nil)
      assert %WorkItem{stage_state: :waiting_answers} = reload(work_item)
      assert Apiary.Runs.StuckLog.lines() == %{}

      # An end the stage acted on is not read again.
      assert Stages.sweep(DateTime.utc_now(), nil) == {[], nil}
    end

    test "the stage sweep writes the text a claim writes for a gateway with no secrets",
         %{scope: scope} do
      gateway = Apiary.NodesFixtures.gateway_fixture(scope)
      Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, gateway, %{allow_secrets: false})

      pool =
        Apiary.NodesFixtures.pool_fixture(scope, %{gateway_choice: :named, gateway_id: gateway.id})

      %{access_key: pool_key} = Apiary.AccessKeysFixtures.browser_key_fixture(scope, pool)
      {:ok, through, keys} = Apiary.Dispatches.Handover.gateway(pool)

      # Two runs a claim through the pool ended `secrets_not_allowed`.
      [by_claim, by_sweep] =
        for _n <- 1..2 do
          work_item = take_in!(scope)
          run = newest_run(work_item)
          now = DateTime.utc_now()

          Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
            set: [state: :ended, end_cause: :secrets_not_allowed, result_outcome: :error]
          )

          %Apiary.Dispatches.Dispatch{
            organisation_id: run.organisation_id,
            workspace_id: run.workspace_id
          }
          |> Apiary.Dispatches.Dispatch.claim_changeset(%{
            dispatch_run_id: run.id,
            pool_id: pool.id,
            access_key_id: pool_key.id,
            claimed_at: now,
            lease_until: Apiary.Dispatches.lease_until(now)
          })
          |> Apiary.PublicId.Insert.insert!()

          work_item
        end

      # The sweep reads again the context the claim passes, for each run, and none for a
      # run with no dispatch.
      for work_item <- [by_claim, by_sweep] do
        assert Stages.claim_context(newest_run(work_item).id) == %{gateway: through, keys: keys}
      end

      assert Stages.claim_context(newest_run(take_in!(scope)).id) == %{}

      # The claim's act, with what the claim knew; the sweep's, with what it reads again.
      assert [_] = Stages.claim_ended([newest_run(by_claim).id], %{gateway: through, keys: keys})
      assert {[_], nil} = Stages.sweep(DateTime.utc_now(), nil)

      # The same text and fix: who adds a key that allows stored secrets, and where.
      for work_item <- [by_claim, by_sweep] do
        assert %Escalation{cause: :run_stopped, points: [%{"text" => text, "fix" => fix}]} =
                 escalation(work_item)

        assert text ==
                 "The run stopped: it did not start, because gateway #{gateway.name} is not allowed to receive the run's secrets."

        assert fix ==
                 "Owners and admins of #{scope.workspace.name} add an access key for #{gateway.name} with stored secrets allowed, on Machines › #{gateway.name} › Access key."
      end
    end

    test "the stage sweep writes that a gateway's key changed after the claim",
         %{scope: scope} do
      gateway = Apiary.NodesFixtures.gateway_fixture(scope)

      %{access_key: key} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, gateway, %{allow_secrets: false})

      pool =
        Apiary.NodesFixtures.pool_fixture(scope, %{gateway_choice: :named, gateway_id: gateway.id})

      %{access_key: pool_key} = Apiary.AccessKeysFixtures.browser_key_fixture(scope, pool)

      # A claim through the pool ended the run `secrets_not_allowed`.
      work_item = take_in!(scope)
      run = newest_run(work_item)
      now = DateTime.utc_now()

      Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
        set: [state: :ended, end_cause: :secrets_not_allowed, result_outcome: :error]
      )

      %Apiary.Dispatches.Dispatch{
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id
      }
      |> Apiary.Dispatches.Dispatch.claim_changeset(%{
        dispatch_run_id: run.id,
        pool_id: pool.id,
        access_key_id: pool_key.id,
        claimed_at: now,
        lease_until: Apiary.Dispatches.lease_until(now)
      })
      |> Apiary.PublicId.Insert.insert!()

      # Before the sweep acts on the end, the gateway's key is replaced by one that allows
      # stored secrets.
      Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, gateway, %{allow_secrets: true})
      assert {:ok, _revoked} = Apiary.AccessKeys.revoke_access_key(scope, key)

      assert {[_], nil} = Stages.sweep(DateTime.utc_now(), nil)

      assert %Escalation{cause: :run_stopped, points: [%{"text" => text, "fix" => fix}]} =
               escalation(work_item)

      assert text ==
               "The run stopped: it did not start, because the access key of gateway #{gateway.name} changed after the run was claimed."

      assert fix == "Run another round. It then uses the current access key of #{gateway.name}."
    end

    test "the stage sweep reads after where the sweep before stopped", %{scope: scope} do
      # Two runs ended by a claim whose stage did not act.
      [first, second] =
        for _n <- 1..2 do
          work_item = take_in!(scope)
          run = newest_run(work_item)

          Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
            set: [state: :ended, end_cause: :key_gone, result_outcome: :error]
          )

          run
        end
        |> Enum.sort_by(& &1.id)

      assert {[_], next} = Stages.sweep(DateTime.utc_now(), nil, 1)
      assert next == first.id
      assert {[_], next} = Stages.sweep(DateTime.utc_now(), first.id, 1)
      assert next == second.id
      assert Stages.sweep(DateTime.utc_now(), second.id, 1) == {[], nil}

      for run <- [first, second] do
        assert %Escalation{cause: :run_stopped} =
                 escalation(Repo.get!(WorkItem, run.work_item_id))
      end
    end

    test "the stage sweep skips the ends the runner does not act on", %{scope: scope} do
      ended! = fn changes ->
        work_item = take_in!(scope)
        run = newest_run(work_item)

        Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
          set: [state: :ended] ++ changes
        )

        {work_item, run}
      end

      # An end the runner ignores, one of each.
      ignored =
        for cause <- [:closed, :undone, :released, :superseded],
            do: ended!.(end_cause: cause, result_outcome: nil)

      # An exit with no outcome yet, which Settle stores first.
      unsettled = ended!.(end_cause: :run_ended, result_outcome: nil)

      # An older attempt: a newer one is queued.
      {older, run} = ended!.(end_cause: :key_gone, result_outcome: :error)

      %DispatchRun{}
      |> Ecto.Changeset.change(
        run
        |> Map.take(
          DispatchRun.__schema__(:fields) -- [:id, :public_id, :inserted_at, :updated_at]
        )
        |> Map.merge(%{
          attempt: run.attempt + 1,
          run_id: Ecto.UUID.generate(),
          state: :waiting,
          end_cause: nil,
          result_outcome: nil
        })
      )
      |> Apiary.PublicId.Insert.insert!()

      # A stage that is not running.
      {waiting, _run} = ended!.(end_cause: :key_gone, result_outcome: :error)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^waiting.id),
          set: [stage_state: :waiting_answers]
        )

      skipped = Enum.map(ignored ++ [unsettled, {older, run}], &elem(&1, 0)) ++ [waiting]
      before = Enum.map(skipped, &reload/1)

      assert Stages.sweep(DateTime.utc_now(), nil) == {[], nil}
      assert Enum.map(skipped, &reload/1) == before
      assert Enum.all?(skipped, &is_nil(escalation(&1)))
    end

    test "the stage sweep finds nothing with the workflow model off", %{scope: scope} do
      work_item = take_in!(scope)
      run = newest_run(work_item)

      Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
        set: [state: :ended, end_cause: :key_gone, result_outcome: :error]
      )

      workflow_model(false)
      assert Stages.sweep(DateTime.utc_now(), nil) == {[], nil}
      assert %WorkItem{stage_state: :running} = reload(work_item)
    end

    test "with the workflow model back on, the stage sweep acts on one batch per call",
         %{scope: scope} do
      # Two ends while the workflow model was off: the sweep acts on neither.
      [first, second] =
        for(_n <- 1..2, do: newest_run(take_in!(scope))) |> Enum.sort_by(& &1.id)

      workflow_model(false)

      Repo.update_all(from(d in DispatchRun, where: d.id in ^[first.id, second.id]),
        set: [state: :ended, end_cause: :key_gone, result_outcome: :error]
      )

      running? = fn run -> Repo.get!(WorkItem, run.work_item_id).stage_state == :running end
      assert Stages.sweep(DateTime.utc_now(), nil, 1) == {[], nil}
      assert {running?.(first), running?.(second)} == {true, true}

      # Back on: a batch of one acts on the first alone, and the next call on the second.
      workflow_model(true)

      assert {[_], next} = Stages.sweep(DateTime.utc_now(), nil, 1)
      assert next == first.id
      assert {running?.(first), running?.(second)} == {false, true}

      assert {[_], _next} = Stages.sweep(DateTime.utc_now(), next, 1)
      assert {running?.(first), running?.(second)} == {false, false}
    end

    test "a tick of the lost-run check keeps where the stage sweep stopped", %{scope: scope} do
      [first, second] =
        for _n <- 1..2 do
          work_item = take_in!(scope)
          run = newest_run(work_item)

          Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
            set: [state: :ended, end_cause: :key_gone, result_outcome: :error]
          )

          run
        end
        |> Enum.sort_by(& &1.id)

      # The tick reads after the stage cursor it was given: the second alone, and fewer
      # than a batch, so the next tick starts from the first id again.
      state = %{interval: :timer.hours(1), cursors: %{stage: first.id}}

      assert {:noreply, %{cursors: %{stage: nil}}} =
               Apiary.Runs.Liveness.handle_info(:tick, state)

      assert %WorkItem{stage_state: :running} = Repo.get!(WorkItem, first.work_item_id)
      assert %Escalation{} = escalation(Repo.get!(WorkItem, second.work_item_id))
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

      assert %WorkItem{stage_state: :waiting_answers} = end_run!(work_item, questions_result())
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
            %{
              "type" => "submission",
              "required" => true,
              "check" => %{"reported" => "checks-passed"}
            }
          ]
        })
      ])

      work_item = take_in!(scope)
      assert %DispatchRun{loop_entry: nil, of: 3} = newest_run(work_item)
      work_item = end_run!(work_item, understood_result())

      points = [stored_no("mockup")]
      assert %Escalation{cause: :check_failed, points: ^points} = escalation(work_item)

      assert [%{check: :passed}, %{check: :missing}, %{check: :not_checked}] =
               Stages.status(work_item).outputs
    end
  end

  describe "a workspace's stack" do
    defp no_stack!(scope) do
      id = scope.workspace.id

      {1, _rows} =
        Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [qory_stack: nil])

      %{scope | workspace: Repo.reload!(scope.workspace)}
    end

    test "a stage waits for a workflow the stack lists no longer: core lists none", %{
      scope: scope
    } do
      scope = no_stack!(scope)
      :ok = Processes.record_declared(scope.workspace, [])

      work_item = take_in!(scope)

      assert work_item.stage_state == :waiting_workflow
      assert runs(work_item) == []

      assert %{waiting_workflow: "explore-a-ticket", gaps: gaps} = Stages.status(work_item)
      assert gaps == Stages.not_in_qory("Explore", "explore-a-ticket")
    end

    test "a stage starts on a workflow the stack lists, whatever the snapshot", %{scope: scope} do
      :ok = Processes.record_declared(scope.workspace, [])

      assert %WorkItem{stage_state: :running} = take_in!(scope)
    end

    test "a stage waits for its unlisted workflow, not for one the stack lists", %{scope: scope} do
      save!(scope, [
        stage(@explore, "Explore", [
          %{"workflow" => "explore-a-ticket"},
          %{"workflow" => "zeta"}
        ])
      ])

      :ok = Processes.record_declared(scope.workspace, [])
      work_item = take_in!(scope)

      assert work_item.stage_state == :waiting_workflow
      assert %{waiting_workflow: "zeta"} = Stages.status(work_item)
    end
  end

  describe "run_workflow/1" do
    test "is the workflow of a stage's run, Explore's among them" do
      assert Stages.run_workflow(%DispatchRun{stage_id: @explore, workflow: "explore-a-ticket"}) ==
               "explore-a-ticket"

      assert Stages.run_workflow(%DispatchRun{stage_id: @explore, workflow: "review"}) == "review"
      assert Stages.run_workflow(%DispatchRun{stage_id: nil, workflow: "review"}) == nil
      assert Stages.run_workflow(%DispatchRun{stage_id: @explore, workflow: nil}) == nil
    end
  end

  describe "failed checks in a loop" do
    test "start the next round with their gaps, which status, notes and the escalation show",
         %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "capture-demo"}]}}
          ],
          "outputs" => [%{"type" => "mockup", "required" => true}]
        })
      ])

      gaps = "No mockup was stored in this stage."
      work_item = take_in!(scope) |> end_run!(verdict("passed"))

      assert %WorkItem{stage_state: :running, stage_round: 2} = work_item
      assert %DispatchRun{round: 2} = newest_run(work_item)
      assert %{gaps: ^gaps, escalation: nil} = Stages.status(work_item)

      assert [%{kind: :check, stage_id: @explore, user_id: nil, note: ^gaps}] =
               Stages.notes(work_item)

      work_item = work_item |> end_run!(verdict("passed")) |> end_run!(verdict("passed"))

      # At the limit, the escalation has the point of the rounds that ran and one for each
      # failed check, and status shows the points instead of the gaps.
      points = [
        %{"text" => "3 of 3 rounds ran.", "action" => "run_again"},
        stored_no("mockup")
      ]

      assert %Escalation{cause: :round_limit, points: ^points} = escalation(work_item)
      assert %{gaps: nil, escalation: %{points: ^points}} = Stages.status(work_item)
      assert [%{kind: :check}, %{kind: :check}] = Stages.notes(work_item)
    end

    test "a workflow's report reads the questions named main alone", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "capture-demo"}]}}
          ],
          "outputs" => [%{"type" => "mockup", "required" => true}]
        })
      ])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          verdict("passed").(run, registered)
          Apiary.WorkItemsFixtures.push_result!(run, registered, questions_result())

          # Questions under another name, as a version stored before the name was checked.
          {1, _rows} =
            Repo.update_all(
              from(a in Apiary.Artifacts.Artifact,
                where: a.work_item_id == ^run.work_item_id and a.type == "questions"
              ),
              set: [name: "other"]
            )
        end)

      assert %WorkItem{stage_state: :running, stage_round: 2} = work_item
    end
  end

  describe "the end of a run of a workflow other than Explore" do
    test "the verdict escalate escalates with its points", %{scope: scope} do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      points = [%{"text" => "The demo needs a login.", "action" => "run_again"}]
      work_item = take_in!(scope) |> end_run!(verdict("escalate", points))

      assert work_item.stage_state == :escalated
      assert %Escalation{cause: :escalate, round: 1, points: ^points} = escalation(work_item)
      assert %DispatchRun{explore: false, result_outcome: :none} = newest_run(work_item)
    end

    # Not an end by the exit, whose end, settle and stage share one transaction
    # (`Apiary.Dispatches.SettleTest`): an exit stored with no outcome (`end_run!/3`), as
    # Settle leaves one it cannot settle yet, then its settle.
    test "an exit stored with no outcome: an unreadable verdict raises, the sweep settles it",
         %{scope: scope} do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      # A point no other test writes, so no other test stores the same file.
      points = [again("The demo skips step #{System.unique_integer([:positive])}.")]
      work_item = take_in!(scope)
      run = newest_run(work_item)
      paths = self()

      # The run pushes escalate, and its file is gone from the store at the exit.
      unreadable = fn run, registered ->
        verdict("escalate", points).(run, registered)
        [file] = Stages.Artifacts.newest_of_run(run, "verdict", "main").files
        {:ok, path} = Artifacts.open_file(file)
        File.rename!(path, path <> ".away")
        send(paths, {:path, path})
      end

      assert_raise Apiary.Stages.VerdictUnreadable, fn -> end_run!(work_item, unreadable) end

      assert_received {:path, path}
      on_exit(fn -> File.rename(path <> ".away", path) end)

      # The settle rolled back: the end has no outcome, and the stage has not moved.
      assert %DispatchRun{state: :ended, result_outcome: nil} = Repo.get!(DispatchRun, run.id)
      assert %WorkItem{stage_state: :running} = reload(work_item)
      refute escalation(work_item)

      File.rename!(path <> ".away", path)
      Settle.sweep(DateTime.utc_now())

      assert %WorkItem{stage_state: :escalated} = reload(work_item)
      assert %Escalation{cause: :escalate, points: ^points} = escalation(work_item)
    end

    test "open questions with escalate wait for answers and keep the escalation", %{
      scope: scope
    } do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      points = [%{"text" => "The demo needs a login.", "action" => "run_again"}]

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          push_result!(run, registered, questions_result(["Which basket?"]))
          verdict("escalate", points).(run, registered)
        end)

      assert work_item.stage_state == :waiting_answers
      assert %Escalation{cause: :escalate, points: ^points} = escalation(work_item)
      assert %{escalation: %{points: ^points}} = Stages.status(work_item)

      # The next round resolves it as another round.
      {:ok, _run} = Repo.transact(fn -> Stages.next_run(work_item.id, work_item.take_in) end)
      assert %WorkItem{stage_state: :running} = reload(work_item)
      refute escalation(work_item)

      assert %Escalation{resolution: :another_round} =
               Repo.get_by(Escalation, work_item_id: work_item.id)
    end

    test "with a verdict alone, waits for a question an earlier run of the take in left open",
         %{scope: scope} do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      work_item = take_in!(scope) |> end_run!(questions_result(["Which basket?"]))
      assert work_item.stage_state == :waiting_answers

      # The next run of the take in starts while the question is open.
      {:ok, _run} = Repo.transact(fn -> Stages.next_run(work_item.id, work_item.take_in) end)
      assert %WorkItem{stage_state: :running} = reload(work_item)
      assert [%DispatchRun{take_in: 1}, %DispatchRun{take_in: 1}] = runs(work_item)

      work_item = end_run!(work_item, verdict("passed"))

      assert work_item.stage_state == :waiting_answers
      assert escalation(work_item) == nil
    end

    test "with a verdict, does not wait for a question an earlier take in left open", %{
      scope: scope
    } do
      save!(scope, [stage(@explore, "Explore", [%{"workflow" => "capture-demo"}])])
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      work_item = work_item |> reload() |> end_run!(questions_result(["Which basket?"]))
      assert work_item.stage_state == :waiting_answers

      {:ok, _closed} = WorkItems.close(scope, reload(work_item))

      {:ok, _again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      assert %WorkItem{take_in: 2} = work_item = reload(work_item)

      # The run of take in 2 pushes `passed` and a version of the questions that keeps
      # take in 1's question open.
      work_item =
        end_run!(work_item, fn run, registered ->
          verdict("passed").(run, registered)
          {_version, document} = Apiary.Explore.Questions.newest(reload(work_item))

          {:ok, _version} =
            Artifacts.push(
              {:run, run},
              reload(work_item),
              "questions",
              [Apiary.Explore.Questions.file(document)],
              name: "main",
              stage_id: run.stage_id
            )
        end)

      assert %DispatchRun{take_in: 2} = run = newest_run(work_item)
      pushed = Enum.find(versions(work_item, "questions"), &(&1.run_id == run.id))

      assert %{"questions" => [%{"id" => "q1", "state" => "open"}]} =
               Stages.Artifacts.read_json(pushed)

      assert work_item.stage_state == :at_gate
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

    test "approve confirms today's proposal too", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())

      assert {:ok, %WorkItem{stage_id: @shape}} =
               Stages.approve(scope, work_item, "Looks right",
                 expect_stage: reload(work_item).stage_id
               )

      assert %Confirmation{} = Repo.get_by(Confirmation, work_item_id: work_item.id)
      assert [%GateDecision{note: "Looks right"}] = decisions(work_item)
    end

    test "approve is refused away from the gate", %{scope: scope} do
      work_item = take_in!(scope)

      assert Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id) ==
               {:error, :not_at_gate}
    end

    test "request changes reruns the sequence from its start, with the note and its version", %{
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
      assert %DispatchRun{attempt: 2, of: 3, round: 1, loop_entry: nil} = newest_run(work_item)
    end

    test "a continuation of a paused run uses up none of its entry's runs", %{scope: scope} do
      work_item = take_in!(scope)
      paused = newest_run(work_item)

      # The run ends at its model keys' limit, and its continuation is queued
      # (`Apiary.Dispatches.requeue_for_pause/2`).
      {:ok, continuation} =
        Repo.transact(fn ->
          paused
          |> Ecto.Changeset.change(state: :ended, end_cause: :run_ended)
          |> Repo.update!()
          |> Apiary.Dispatches.requeue_for_pause(nil)
        end)

      assert %DispatchRun{attempt: 2, round: 1} = continuation
      assert continuation.continues_id == paused.id

      work_item = end_run!(work_item, understood_result())
      [proposal] = versions(work_item, "proposal")

      assert {:ok, %WorkItem{stage_state: :running}} =
               Stages.request_changes(
                 scope,
                 work_item,
                 "Leave out the invoice",
                 proposal.public_id,
                 expect_stage: reload(work_item).stage_id
               )

      # One run of the entry before, not two: this run and one more are left.
      assert %DispatchRun{attempt: 3, of: 4, round: 1} = newest_run(work_item)
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

      # A handed-over run at Explore (`live_stage_run!/2`) pushes a newer proposal.
      stage_version!(work_item, "proposal", a_proposal(), @explore)

      assert %{state: :at_gate, gate: %{approvals: [%{versions: [%{number: 1, newer?: true}]}]}} =
               Stages.status(work_item)
    end

    # The last stage, Explore, with the output explainer beside the proposal; its run
    # pushes the proposal and an explainer of each of `names`, and the stage is approved.
    # `by` is who approved the gate: `:automatic`, as a gate `none` records it, with no
    # member, or `:person`, the member who approved.
    defp done_with_explainers!(scope, names, by \\ :automatic) do
      save!(scope, [
        explore_stage(%{
          "outputs" => [
            %{"type" => "proposal", "required" => true},
            %{"type" => "explainer", "required" => false}
          ]
        })
      ])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          Apiary.WorkItemsFixtures.push_result!(run, registered, understood_result())

          for name <- names, do: {:ok, _version} = push_explainer(run, name)
        end)

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      assert Stages.status(work_item).state == :done

      if by == :automatic, do: automatic_approval!(work_item)
      work_item
    end

    test "a withdrawal of a covered name reopens the gate, another name of the type left",
         %{scope: scope} do
      # The gate reopened here before `withdrawn_since?/2` existed: name a's version is not
      # among the covered ones.
      work_item = done_with_explainers!(scope, ["a", "b"])

      {:ok, _withdrawal} =
        Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
          name: "b",
          stage_id: @explore
        )

      assert Stages.status(work_item).state == :at_gate
    end

    test "a withdrawal of the only name of a covered output reopens the gate", %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"])

      {:ok, _withdrawal} =
        Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
          stage_id: @explore
        )

      assert Stages.status(work_item).state == :at_gate
    end

    test "a withdrawal by a run a member cancelled leaves the name and the gate as they were",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"])
      run = live_run!(work_item)

      {:ok, _withdrawal} =
        Artifacts.withdraw({:run, run}, work_item, "explainer", stage_id: @explore)

      assert Stages.status(work_item).state == :at_gate
      cancel_run!(scope, run)

      assert Stages.status(work_item).state == :done
      assert [explainer] = Enum.filter(Artifacts.list(work_item), &(&1.type == "explainer"))
      refute Artifacts.withdrawn?(explainer)
      assert Artifacts.exists?(work_item, @explore, "explainer")
      assert MapSet.member?(Explore.versions(work_item.id, work_item.take_in), {"explainer", 1})
    end

    test "a run withdraws a name again after a withdrawal by a run a member cancelled",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"])
      cancelled = live_run!(work_item)

      {:ok, _withdrawal} =
        Artifacts.withdraw({:run, cancelled}, work_item, "explainer", stage_id: @explore)

      cancel_run!(scope, cancelled)

      assert {:ok, %{number: 3, withdrawn: true}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )
    end

    test "a name with versions only by a run a member cancelled has no version to withdraw",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, [])
      cancelled = live_run!(work_item)
      {:ok, %{number: 1}} = push_explainer(cancelled, "main")
      cancel_run!(scope, cancelled)

      assert {:error, {:withdraw, :no_version}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )
    end

    test "an approval covers the newest version of each name of an output type",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main", "scenario-2", "scenario-10"])

      approved =
        for %{type: "explainer", name: name, versions: [%{number: 1, approvals: [_one]}]} <-
              Stages.artifact_index(work_item),
            do: name

      assert Enum.sort(approved) == ["main", "scenario-10", "scenario-2"]
    end

    test "an approval and the gate's outputs leave out a withdrawn name", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "outputs" => [
            %{"type" => "proposal", "required" => true},
            %{"type" => "explainer", "required" => false}
          ]
        })
      ])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          Apiary.WorkItemsFixtures.push_result!(run, registered, understood_result())
          work_item = Repo.get!(WorkItem, run.work_item_id)

          for name <- ["scenario-10", "scenario-2", "scenario-3"],
              do: {:ok, _version} = push_explainer(run, name)

          {:ok, _withdrawal} =
            Artifacts.withdraw({:run, run}, work_item, "explainer",
              name: "scenario-3",
              stage_id: @explore
            )
        end)

      assert %{outputs: outputs} = Stages.status(work_item)

      assert [%{name: "scenario-2", number: 1}, %{name: "scenario-10", number: 1}] =
               Enum.find(outputs, &(&1.type == "explainer")).names

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      approvals =
        for %{type: "explainer", name: name, versions: versions} <-
              Stages.artifact_index(work_item),
            into: %{},
            do: {name, Enum.flat_map(versions, & &1.approvals)}

      assert [_approval] = approvals["scenario-2"]
      assert [_approval] = approvals["scenario-10"]
      assert approvals["scenario-3"] == []
    end

    test "a run does not withdraw a name whose newest version a person approved",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"], :person)

      assert {:error, {:withdraw, {:approved, 1}}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )

      assert Stages.status(work_item).state == :done
      assert [%{number: 1}] = versions(work_item, "explainer")
    end

    test "a run does not withdraw a name a member approved whose account is gone",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"], :person)

      {1, _rows} =
        Repo.update_all(from(d in GateDecision, where: d.work_item_id == ^work_item.id),
          set: [user_id: nil]
        )

      assert [%GateDecision{user_id: nil, automatic: false}] = decisions(work_item)

      assert {:error, {:withdraw, {:approved, 1}}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )
    end

    test "a run withdraws a name whose approval is automatic", %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"], :automatic)

      assert {:ok, %{number: 2, withdrawn: true}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )
    end

    test "a run withdraws a name whose newer version no person approved", %{scope: scope} do
      work_item = done_with_explainers!(scope, ["main"], :person)
      {:ok, %{number: 2}} = push_explainer(live_run!(work_item), "main")

      assert {:ok, %{number: 3, withdrawn: true}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )
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

    # The one file of a version of the acceptance criteria.
    defp criteria_files, do: [json_file("acceptance-criteria", criteria_document())]

    test "waits at its gate for a missing output, and approve is refused",
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
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = reload(work_item)
    end
  end

  describe "required outputs at Accept as it is and Approve" do
    # Explore with `outputs`, then Shape, a stage with no workflow.
    defp outputs_process!(scope, outputs) do
      save!(scope, [
        explore_stage(%{"outputs" => outputs}),
        stage(@shape, "Shape", [])
      ])
    end

    @proposal %{"type" => "proposal", "required" => true}

    test "Approve is refused at the gate of a stage with a workflow while a required output is missing",
         %{scope: scope} do
      shape = fn outputs ->
        save!(scope, [
          explore_stage(),
          stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], %{"outputs" => outputs})
        ])
      end

      shape.([])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = work_item |> reload() |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      # A version whose Shape also requires an explainer, which no run of Shape wrote; the
      # work item keeps its gate when it moves to it.
      version = shape.([%{"type" => "explainer", "required" => true}])
      {:ok, work_item} = Processes.assign(scope, work_item, version)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = reload(work_item)

      assert %{missing_outputs: ["explainer"], gate: %{approvable?: false}} =
               Stages.status(work_item, scope)

      assert Stages.starts(work_item, :approve) == :none

      assert Stages.approve(scope, work_item, nil, expect_stage: @shape) ==
               {:error, {:outputs_not_written, ["explainer"]}}

      # Explore's confirmation is the one decision.
      assert [%GateDecision{stage_id: @explore}] = decisions(work_item)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = reload(work_item)
    end

    test "Accept as it is before the last entry starts the next entry with a required output missing; at the last entry it is refused",
         %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [%{"workflow" => "explore-a-ticket"}, %{"workflow" => "triage-review"}],
          "outputs" => [@proposal]
        }),
        stage(@shape, "Shape", [])
      ])

      # The first run stops with no proposal: Accept as it is goes on to triage-review.
      work_item = take_in!(scope) |> end_run!(nil)
      assert %WorkItem{stage_entry: 0} = work_item
      assert %Escalation{cause: :run_stopped} = escalation(work_item)
      assert %{missing_outputs: ["proposal"], accept_needs: []} = Stages.status(work_item, scope)
      assert Stages.starts(work_item, :accept) == {:run, "triage-review"}

      assert {:ok, %WorkItem{stage_state: :running, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      # The second run stops too: an accept would take the stage to its gate.
      work_item = end_run!(work_item, nil)
      assert %WorkItem{stage_entry: 1, stage_state: :escalated} = work_item

      assert %{missing_outputs: ["proposal"], accept_needs: ["proposal"]} =
               Stages.status(work_item, scope)

      assert Stages.starts(work_item, :accept) == :none

      assert Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore) ==
               {:error, :invalid}

      assert %Escalation{resolution: nil} = escalation(work_item)
    end

    test "an optional output blocks neither Accept as it is nor Approve", %{scope: scope} do
      outputs_process!(scope, [@proposal, %{"type" => "explainer", "required" => false}])

      work_item =
        take_in!(scope)
        |> end_run!(understood_result(), %{exit_state: "failed", outcome_state: "failed"})

      assert %Escalation{cause: :run_stopped} = escalation(work_item)
      assert Stages.missing_outputs(work_item) == []

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      assert %WorkItem{stage_id: @explore, stage_state: :at_gate} = work_item

      assert [%{type: "proposal", check: :passed}, %{type: "explainer", required: false}] =
               Stages.status(work_item, scope).outputs

      assert Stages.status(work_item, scope).gate.approvable?

      assert {:ok, %WorkItem{stage_id: @shape}} =
               Stages.approve(scope, work_item, nil, expect_stage: @explore)
    end
  end

  describe "the when key (A-16)" do
    @verify "st_m1mqbeywdg"
    @demos %{"input" => "demo-scenarios"}
    @optional_scenarios %{"outputs" => [%{"type" => "demo-scenarios", "required" => false}]}

    # Explore; Shape, which runs shape-a-ticket and whose demo scenarios are optional;
    # Verify, whose capture-demos runs only with demo scenarios, and whose film is required
    # only then.
    defp verify_process!(scope, shape \\ @optional_scenarios) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "demo-scenarios",
          "base_view" => "document"
        })

      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], shape),
        stage(
          @verify,
          "Verify",
          [
            %{"workflow" => "capture-demos", "when" => @demos},
            %{"workflow" => "verify-a-ticket"}
          ],
          %{
            "outputs" => [
              %{"type" => "explainer", "required" => true},
              %{"type" => "demo-video", "required" => true, "when" => @demos}
            ]
          }
        )
      ])
    end

    # The work item at Shape's gate after Shape's run pushed the demo scenarios `binary`
    # (nil for none) and passed; `check` reads it there; then Shape approved, so it enters
    # Verify.
    defp at_verify!(scope, binary, check \\ fn _work_item -> :ok end) do
      verify_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = work_item |> reload() |> end_run!(shaped(binary))
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      check.(work_item)
      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      reload(work_item)
    end

    # The end of a run of Shape: the demo scenarios `binary` (nil for none), then the
    # verdict passed.
    defp shaped(nil), do: verdict("passed")
    defp shaped(binary), do: passed_with(binary)

    defp scenarios(binary),
      do: [%{filename: "demo-scenarios.md", content_type: "text/markdown", binary: binary}]

    # The end of a run of verify-a-ticket: an explainer and the verdict passed.
    defp verified(run, registered) do
      {:ok, _version} =
        Artifacts.push(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "explainer",
          [%{filename: "explainer.md", content_type: "text/markdown", binary: "# What changed"}],
          name: "main",
          stage_id: run.stage_id
        )

      verdict("passed").(run, registered)
    end

    test "with no demo-scenarios, capture-demos starts no run and Verify's gate opens without a film",
         %{scope: scope} do
      work_item =
        at_verify!(scope, nil, fn work_item ->
          assert Stages.starts(work_item, :approve) == {:run, "verify-a-ticket"}
        end)

      assert %WorkItem{stage_id: @verify, stage_state: :running, stage_entry: 1} = work_item
      assert %DispatchRun{workflow: "verify-a-ticket", stage_entry: 1} = newest_run(work_item)
      refute Enum.any?(runs(work_item), &(&1.workflow == "capture-demos"))

      # The skip comes after attempt 2, Shape's run.
      assert [
               %{
                 stage_id: @verify,
                 workflow: "capture-demos",
                 input: "demo-scenarios",
                 round: 1,
                 after_attempt: 2
               }
             ] = Stages.skips(work_item)

      work_item = end_run!(work_item, &verified/2)

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
      refute escalation(work_item)
      assert Stages.missing_outputs(work_item) == []

      assert %{state: :at_gate, outputs: outputs, gate: %{approvable?: true}} =
               Stages.status(work_item, scope)

      assert [
               %{type: "explainer", required: true, check: :passed},
               %{type: "demo-video", required: false, version: nil, check: :missing}
             ] = outputs

      assert {:ok, %WorkItem{state: :closed}} =
               Stages.approve(scope, work_item, nil, expect_stage: @verify)
    end

    test "with demo-scenarios of more than 0 bytes, capture-demos runs and the film is required",
         %{scope: scope} do
      work_item =
        at_verify!(scope, "# Scenario 1", fn work_item ->
          assert Stages.starts(work_item, :approve) == {:run, "capture-demos"}
        end)

      assert %WorkItem{stage_id: @verify, stage_state: :running, stage_entry: 0} = work_item
      assert %DispatchRun{workflow: "capture-demos"} = newest_run(work_item)
      assert Stages.skips(work_item) == []

      assert %{outputs: [_explainer, %{type: "demo-video", required: true}]} =
               Stages.status(work_item, scope)
    end

    test "a version of demo-scenarios with one file of 0 bytes does not count", %{scope: scope} do
      work_item =
        at_verify!(scope, "", fn work_item ->
          assert Stages.starts(work_item, :approve) == {:run, "verify-a-ticket"}
        end)

      assert [%{size: 0}] = hd(versions(work_item, "demo-scenarios")).files
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
      assert [%{workflow: "capture-demos"}] = Stages.skips(work_item)
    end

    # Explore; Shape, which runs shape-a-ticket, with the gate `shape_gate`; Review
    # (`@build`), which runs review-scenarios, with a gate none; both require demo
    # scenarios; then Verify. The work item at Shape's gate, after Shape's run pushed the
    # demo scenarios `binary`.
    defp two_gates!(scope, shape_gate, binary) do
      verify_process!(scope)
      outputs = %{"outputs" => [%{"type" => "demo-scenarios", "required" => true}]}
      [explore, shape, verify] = Processes.current(scope.workspace).document["stages"]

      save!(scope, [
        explore,
        Map.merge(shape, Map.put(outputs, "gate", shape_gate)),
        stage(
          @build,
          "Review",
          [%{"workflow" => "review-scenarios"}],
          Map.put(outputs, "gate", %{"kind" => "none"})
        ),
        verify
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = work_item |> reload() |> end_run!(passed_with(binary))
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      work_item
    end

    test "after two approvals, Verify reads the nearer one: Review's empty version does not count",
         %{scope: scope} do
      work_item =
        two_gates!(scope, %{"kind" => "person", "approvers" => "members"}, "# Scenario 1")

      assert Stages.starts(work_item, :approve) == {:run, "review-scenarios"}
      {:ok, _work_item} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)

      # Review's run stores a version of 0 bytes, and Review's gate none passes.
      work_item = work_item |> reload() |> end_run!(passed_with(""))
      assert %WorkItem{stage_id: @verify} = work_item
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
    end

    test "skips/1 lists only the work item's skips, each stored under its work item's organisation",
         %{scope: scope} do
      work_item = at_verify!(scope, nil)
      %{scope: other} = sign_up_fixture()
      other_item = at_verify!(other, nil)

      assert [%{after_attempt: 2}] = Stages.skips(work_item)
      assert [_one] = Stages.skips(other_item)

      assert Repo.aggregate(
               from(s in Apiary.Stages.Skip,
                 where:
                   s.work_item_id == ^work_item.id and
                     s.organisation_id != ^scope.workspace.organisation_id
               ),
               :count
             ) == 0
    end
  end

  describe "the changed key (A-47)" do
    @new_scenarios %{"input" => "demo-scenarios", "changed" => true}

    # Explore; Shape, which runs shape-a-ticket and whose demo scenarios are optional;
    # Verify, whose `sequence` is `entries`.
    defp changed_process!(scope, entries) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "demo-scenarios",
          "base_view" => "document"
        })

      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], %{
          "outputs" => [%{"type" => "demo-scenarios", "required" => false}]
        }),
        stage(@verify, "Verify", entries)
      ])
    end

    # The work item at Shape's gate, after Shape's run stored the demo scenarios `binary`
    # (nil for none) and passed.
    defp at_shape!(scope, binary) do
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item |> reload() |> end_run!(shaped(binary))
    end

    defp approve_shape!(scope, work_item) do
      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      reload(work_item)
    end

    # The work item in Verify, with the demo scenarios `binary` that Shape's run stored
    # (nil for none).
    defp in_verify!(scope, binary), do: approve_shape!(scope, at_shape!(scope, binary))

    # The end of a run that pushes the demo scenarios `binary` in its stage, then the verdict
    # passed.
    defp passed_with(binary) do
      fn run, registered ->
        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "demo-scenarios",
            scenarios(binary),
            name: "main",
            stage_id: run.stage_id
          )

        verdict("passed").(run, registered)
      end
    end

    defp workflows_run(work_item), do: Enum.map(runs(work_item), & &1.workflow)

    test "an entry runs while it has no passed run, is passed over after its pass, and runs again for a new version",
         %{scope: scope} do
      changed_process!(scope, [
        %{"workflow" => "capture-demos", "when" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])

      # No run of capture-demos passed yet: the version from Shape's gate is new to it.
      work_item = in_verify!(scope, "# Scenario 1")
      assert %DispatchRun{workflow: "capture-demos", stage_entry: 0} = newest_run(work_item)
      assert Stages.skips(work_item) == []

      work_item = end_run!(work_item, verdict("passed"))
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      # Request changes runs the sequence again: capture-demos passed after Scenario 1 was
      # stored, so it does not run; no key and no new version.
      assert Stages.starts(work_item, :request_changes, true) == {:run, "verify-a-ticket"}

      {:ok, again} =
        Stages.request_changes(scope, work_item, "Look again.", nil, expect_stage: @verify)

      assert %DispatchRun{workflow: "verify-a-ticket", stage_entry: 1} = newest_run(again)

      assert [
               %{
                 stage_id: @verify,
                 workflow: "capture-demos",
                 input: "demo-scenarios",
                 changed: true,
                 negated: false,
                 track: nil
               }
             ] = Stages.skips(again)

      # A run's version of the scenarios, stored after capture-demos' pass was queued,
      # starts it again; the prediction says so before the click.
      again = end_run!(again, passed_with("# Scenario 2"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = again

      assert Stages.starts(again, :request_changes, true) == {:run, "capture-demos"}

      {:ok, third} =
        Stages.request_changes(scope, again, "And again.", nil, expect_stage: @verify)

      assert %DispatchRun{workflow: "capture-demos", stage_entry: 0} = newest_run(third)

      assert workflows_run(third) ==
               ~w(explore-a-ticket shape-a-ticket capture-demos verify-a-ticket verify-a-ticket
                  capture-demos)
    end

    test "a page reads a stage with the condition while a verdict cannot be read; a click's check raises",
         %{scope: scope} do
      changed_process!(scope, [
        %{"workflow" => "capture-demos", "when" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])

      work_item = in_verify!(scope, "# Scenario 1")
      work_item = work_item |> end_run!(verdict("passed")) |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      # The versions may share one stored file, so each path is moved once.
      paths =
        for version <- versions(work_item, "verdict"), file <- version.files, uniq: true do
          {:ok, path} = Artifacts.open_file(file)
          path
        end

      for path <- Enum.uniq(paths) do
        File.rename!(path, path <> ".away")
        on_exit(fn -> File.rename(path <> ".away", path) end)
      end

      assert %{state: :at_gate, inputs: []} = Stages.status(work_item, scope)
      assert Stages.inputs(work_item) == []

      assert_raise Stages.VerdictUnreadable, fn ->
        Stages.starts(work_item, :request_changes, true)
      end
    end

    test "a version with a file of 0 bytes is a version", %{scope: scope} do
      changed_process!(scope, [
        %{"workflow" => "capture-demos", "when" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])

      work_item = in_verify!(scope, "")
      assert [%{size: 0}] = hd(versions(work_item, "demo-scenarios")).files
      assert %DispatchRun{workflow: "capture-demos"} = newest_run(work_item)
    end

    test "with no version of the type the entry is passed over, and the skip says it was a change",
         %{scope: scope} do
      changed_process!(scope, [
        %{"workflow" => "capture-demos", "when" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])

      work_item = in_verify!(scope, nil)
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)

      assert [%{workflow: "capture-demos", input: "demo-scenarios", changed: true}] =
               Stages.skips(work_item)

      # The record keeps that the condition was on a change.
      assert [%Stages.Skip{input: "demo-scenarios", changed: true}] =
               Repo.all(from s in Stages.Skip, where: s.work_item_id == ^work_item.id)
    end

    test "a version that an earlier entry of the stage stored counts, though no gate approved it",
         %{scope: scope} do
      changed_process!(scope, [
        %{"workflow" => "triage-review"},
        %{"workflow" => "capture-demos", "when" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])

      work_item = in_verify!(scope, "# Scenario 1")
      assert %DispatchRun{workflow: "triage-review"} = newest_run(work_item)

      # capture-demos has no passed run, so it runs for Scenario 1.
      work_item = end_run!(work_item, verdict("passed"))
      assert %DispatchRun{workflow: "capture-demos"} = newest_run(work_item)
      work_item = end_run!(work_item, verdict("passed"))
      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      # With nothing new, triage-review runs and capture-demos is passed over.
      {:ok, again} =
        Stages.request_changes(scope, work_item, "Look again.", nil, expect_stage: @verify)

      assert %DispatchRun{workflow: "triage-review"} = newest_run(again)

      again = end_run!(again, verdict("passed"))
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(again)
      assert [%{workflow: "capture-demos", changed: true}] = Stages.skips(again)
      again = end_run!(again, verdict("passed"))

      # triage-review stores Scenario 2 in its run: capture-demos, later in the same run of
      # the sequence, runs for it.
      {:ok, third} =
        Stages.request_changes(scope, again, "Once more.", nil, expect_stage: @verify)

      assert %DispatchRun{workflow: "triage-review"} = newest_run(third)
      third = end_run!(third, passed_with("# Scenario 2"))
      assert %DispatchRun{workflow: "capture-demos", stage_entry: 1} = newest_run(third)
    end

    defp capture_then_verify!(scope) do
      changed_process!(scope, [
        %{"workflow" => "capture-demos", "when" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])
    end

    test "a run that ended changes-requested is no pass", %{scope: scope} do
      capture_then_verify!(scope)
      work_item = in_verify!(scope, "# Scenario 1")
      assert %DispatchRun{workflow: "capture-demos"} = newest_run(work_item)

      work_item = end_run!(work_item, verdict("changes-requested"))
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      # Scenario 1 is older than capture-demos' run, but the run did not pass.
      assert Stages.starts(work_item, :request_changes, true) == {:run, "capture-demos"}

      {:ok, again} =
        Stages.request_changes(scope, work_item, "Look again.", nil, expect_stage: @verify)

      assert %DispatchRun{workflow: "capture-demos", stage_entry: 0} = newest_run(again)
      assert Stages.skips(again) == []
    end

    test "a pass on another work item is no pass of this one", %{scope: scope} do
      capture_then_verify!(scope)

      # This work item's scenarios were stored before the other's capture-demos was queued.
      this = at_shape!(scope, "# Scenario 1")

      other = in_verify!(scope, "# Scenario 1")
      assert %DispatchRun{workflow: "capture-demos"} = newest_run(other)
      other = end_run!(other, verdict("passed"))
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(other)

      this = approve_shape!(scope, this)
      assert %DispatchRun{workflow: "capture-demos", stage_entry: 0} = newest_run(this)
      assert Stages.skips(this) == []
    end

    test "a pass of another workflow at the entry's position is no pass of the entry",
         %{scope: scope} do
      capture_then_verify!(scope)
      work_item = in_verify!(scope, "# Scenario 1")
      work_item = work_item |> end_run!(verdict("passed")) |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      assert Stages.starts(work_item, :request_changes, true) == {:run, "verify-a-ticket"}

      # The process was edited, and another workflow now sits at entry 0.
      {1, _rows} =
        Repo.update_all(
          from(d in DispatchRun,
            where: d.work_item_id == ^work_item.id and d.workflow == "capture-demos"
          ),
          set: [workflow: "old-workflow"]
        )

      assert Stages.starts(work_item, :request_changes, true) == {:run, "capture-demos"}
    end

    test "only the verdicts of the workflows with a changed condition are read", %{scope: scope} do
      capture_then_verify!(scope)
      work_item = in_verify!(scope, "# Scenario 1")

      # verify-a-ticket's verdict differs from capture-demos', so the store keeps two files.
      work_item =
        work_item
        |> end_run!(verdict("passed"))
        |> end_run!(verdict("changes-requested"))

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      [run] =
        Repo.all(
          from d in DispatchRun,
            where: d.work_item_id == ^work_item.id and d.workflow == "verify-a-ticket"
        )

      [version] = for v <- versions(work_item, "verdict"), v.run_id == run.id, do: v
      [file] = version.files
      {:ok, path} = Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      # The run of verify-a-ticket has no condition on it: its unreadable verdict is not read.
      assert Stages.starts(work_item, :request_changes, true) == {:run, "verify-a-ticket"}
    end

    test "an unless passes the entry over while the version is new", %{scope: scope} do
      changed_process!(scope, [
        %{"workflow" => "capture-demos", "unless" => @new_scenarios},
        %{"workflow" => "verify-a-ticket"}
      ])

      work_item = in_verify!(scope, "# Scenario 1")
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)

      assert [%{workflow: "capture-demos", changed: true, negated: true}] =
               Stages.skips(work_item)

      # With no version, the condition is not met, so the unless lets the entry run.
      other = in_verify!(scope, nil)
      assert %DispatchRun{workflow: "capture-demos"} = newest_run(other)
    end
  end

  describe "feedback and the changed key in Build (A-27)" do
    @changed_criteria %{"input" => "acceptance-criteria", "changed" => true}

    # Explore; Shape, which runs shape-a-ticket and whose acceptance criteria are optional;
    # Build as C-2's template has it, with no `value` condition, which this base has not yet:
    # triage-review on new feedback, plan-the-build and write-acceptance-checks when the
    # criteria changed, then a loop of implement-changes and review-changes.
    defp feedback_process!(scope) do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], %{
          "outputs" => [%{"type" => "acceptance-criteria", "required" => false}]
        }),
        stage(@build, "Build", [
          %{"workflow" => "triage-review", "when" => %{"feedback" => "new"}},
          %{"workflow" => "plan-the-build", "when" => @changed_criteria},
          %{"workflow" => "write-acceptance-checks", "when" => @changed_criteria},
          %{
            "loop" => %{
              "rounds" => 3,
              "body" => [
                %{"workflow" => "implement-changes"},
                %{"workflow" => "review-changes"}
              ]
            }
          }
        ])
      ])
    end

    defp criteria, do: criteria_files()

    # The end of Shape's run: the criteria, then the verdict passed.
    defp criteria_passed(run, registered) do
      {:ok, _version} =
        Artifacts.push(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "acceptance-criteria",
          criteria(),
          stage_id: run.stage_id
        )

      verdict("passed").(run, registered)
    end

    # The work item at Shape's gate, after Shape's run stored the criteria.
    defp shaped_with_criteria!(scope) do
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = work_item |> reload() |> end_run!(&criteria_passed/2)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      work_item
    end

    # The work item in Build, with the criteria Shape's run stored and Shape approved.
    defp in_build!(scope) do
      work_item = shaped_with_criteria!(scope)
      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      reload(work_item)
    end

    test "feedback after the round limit runs triage-review, then skips to the loop", %{
      scope: scope
    } do
      feedback_process!(scope)

      # No feedback yet: triage-review is passed over, and the criteria are new to the
      # two entries that read them.
      work_item = in_build!(scope)
      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 1} = newest_run(work_item)

      assert [%{workflow: "triage-review", reason: "feedback", negated: false, input: nil}] =
               Stages.skips(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      assert %DispatchRun{workflow: "write-acceptance-checks"} = newest_run(work_item)
      work_item = end_run!(work_item, verdict("passed"))

      work_item =
        Enum.reduce(1..3, work_item, fn _round, work_item ->
          # implement-changes stores no verdict, and the ring runs review-changes.
          work_item
          |> end_run!(nil)
          |> end_run!(verdict("changes-requested", [again("The export has no title.")]))
        end)

      assert %WorkItem{stage_state: :escalated, stage_round: 3} = work_item
      assert %Escalation{cause: :round_limit} = escalation(work_item)

      # Run another round with a note is feedback: Build starts at its first entry.
      {:ok, again} =
        Stages.resolve_escalation(scope, work_item, :another_round, "Keep the title short.",
          expect_stage: @build
        )

      assert %DispatchRun{workflow: "triage-review", stage_entry: 0, round: 1} =
               newest_run(again)

      # triage-review passes; the criteria did not change since the two entries passed,
      # so the loop runs next, round 1.
      again = end_run!(again, verdict("passed"))

      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3, loop_entry: 0, round: 1} =
               newest_run(again)

      assert [
               %{workflow: "triage-review", reason: "feedback"},
               %{workflow: "plan-the-build", input: "acceptance-criteria", changed: true},
               %{workflow: "write-acceptance-checks", input: "acceptance-criteria", changed: true}
             ] = Stages.skips(again)

      # The record of a skip for no feedback has the reason and no input.
      assert [%Stages.Skip{reason: "feedback", input: nil, cause_entry: nil}] =
               Repo.all(
                 from s in Stages.Skip,
                   where: s.work_item_id == ^work_item.id and s.reason == "feedback"
               )
    end

    test "a note an earlier stage closed is no feedback when Build first runs", %{
      scope: scope
    } do
      feedback_process!(scope)
      work_item = shaped_with_criteria!(scope)

      # A request for changes at Shape's gate, closed when Shape is approved after it.
      {:ok, work_item} =
        Stages.request_changes(scope, work_item, "Name the export format.", nil,
          expect_stage: @shape
        )

      work_item = work_item |> reload() |> end_run!(verdict("passed"))
      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      work_item = reload(work_item)

      assert Stages.notes(work_item) == []
      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 1} = newest_run(work_item)
      assert [%{workflow: "triage-review", reason: "feedback"}] = Stages.skips(work_item)
    end
  end

  describe "feedback that no run handled, moves and Request changes (A-27)" do
    # Build in the form of the earlier describe, at its round limit: plan-the-build and
    # write-acceptance-checks passed, then three rounds whose review requested changes.
    defp at_round_limit!(scope) do
      feedback_process!(scope)
      round_limit_item!(scope)
    end

    # Another work item at Build's round limit, in the process saved already.
    defp round_limit_item!(scope) do
      work_item =
        in_build!(scope)
        |> end_run!(verdict("passed"))
        |> end_run!(verdict("passed"))

      work_item =
        Enum.reduce(1..3, work_item, fn _round, work_item ->
          work_item
          |> end_run!(nil)
          |> end_run!(verdict("changes-requested", [again("The export has no title.")]))
        end)

      assert %WorkItem{stage_state: :escalated, stage_round: 3} = work_item
      work_item
    end

    # Build at its gate, with no feedback written: the loop's review passed in round 1.
    defp at_build_gate!(scope) do
      feedback_process!(scope)
      build_gate_item!(scope)
    end

    # Another work item at Build's gate, in the process saved already.
    defp build_gate_item!(scope) do
      work_item =
        in_build!(scope)
        |> end_run!(verdict("passed"))
        |> end_run!(verdict("passed"))
        |> end_run!(nil)
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item
      work_item
    end

    defp round!(scope, work_item, note) do
      {:ok, work_item} =
        Stages.resolve_escalation(scope, reload(work_item), :another_round, note,
          expect_stage: @build
        )

      work_item
    end

    # The end of a run that asks `question`, with the verdict `escalate` that points at it
    # when `escalate?`.
    defp asking(question, escalate?) do
      fn run, registered ->
        Apiary.WorkItemsFixtures.push_output!(run, registered, questions_result([question]))

        if escalate?,
          do:
            verdict("escalate", [
              %{"text" => "The format is not chosen.", "action" => "answer", "question" => "q1"}
            ]).(run, registered)
      end
    end

    # The names the harness lists, without triage-review: Build's first workflow is missing.
    defp without_triage!(scope) do
      :ok =
        Processes.record_declared(
          scope.workspace,
          ~w(explore-a-ticket shape-a-ticket plan-the-build write-acceptance-checks
             implement-changes review-changes)
        )
    end

    test "triage-review that stopped, gave no verdict or escalated runs again on Run another round with no note",
         %{scope: scope} do
      work_item = round!(scope, at_round_limit!(scope), "Keep the title short.")
      assert %DispatchRun{workflow: "triage-review", stage_entry: 0} = newest_run(work_item)

      stops = [
        &end_run!(&1, nil, %{exit_state: "failed", outcome_state: "failed"}),
        &end_run!(&1, nil),
        &end_run!(&1, verdict("escalate", [again("The note is unclear.")]))
      ]

      work_item =
        Enum.reduce(stops, work_item, fn stop, work_item ->
          work_item = stop.(work_item)
          assert %WorkItem{stage_state: :escalated, stage_entry: 0} = work_item

          # The note is still unhandled: triage-review runs again, not the step after it.
          work_item = round!(scope, work_item, nil)

          assert %DispatchRun{workflow: "triage-review", stage_entry: 0, round: 1} =
                   newest_run(work_item)

          work_item
        end)

      assert Enum.count(runs(work_item), &(&1.workflow == "triage-review")) == 4

      # triage-review passes and handles the note; a stopped run after it reruns alone.
      work_item = end_run!(work_item, verdict("passed"))
      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3} = newest_run(work_item)
      work_item = end_run!(work_item, nil, %{exit_state: "failed", outcome_state: "failed"})
      work_item = round!(scope, work_item, nil)

      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3, loop_entry: 0} =
               newest_run(work_item)

      assert Enum.count(runs(work_item), &(&1.workflow == "triage-review")) == 4
    end

    test "Run another round with a comment at the gate starts triage-review", %{scope: scope} do
      work_item = at_build_gate!(scope)
      attempt = newest_run(work_item).attempt

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt, %{
                 comment: "Rename the export button."
               })

      assert %DispatchRun{workflow: "triage-review", stage_entry: 0, round: 1} =
               newest_run(work_item)

      assert %WorkItem{stage_state: :running, stage_entry: 0} = reload(work_item)

      assert [%{kind: :answer, comment: true, note: "Rename the export button."} = note] =
               Stages.notes(reload(work_item))

      assert DateTime.after?(newest_run(work_item).queued_at, note.inserted_at)

      # triage-review passes: the comment is handled, and the sequence goes on.
      work_item = end_run!(reload(work_item), verdict("passed"))
      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3} = newest_run(work_item)
    end

    test "a comment while questions wait, with no escalation, starts triage-review", %{
      scope: scope
    } do
      feedback_process!(scope)
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", false))
      assert %WorkItem{stage_state: :waiting_answers, stage_entry: 1} = work_item
      refute escalation(work_item)
      attempt = newest_run(work_item).attempt

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt, %{
                 answers: [%{"id" => "q1", "option" => nil, "note" => "PDF."}],
                 comment: "Name the file by date."
               })

      assert %DispatchRun{workflow: "triage-review", stage_entry: 0, round: 1} =
               newest_run(work_item)
    end

    test "answers alone, while questions wait, run the workflow that asked", %{scope: scope} do
      feedback_process!(scope)
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", false))
      attempt = newest_run(work_item).attempt

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, work_item, attempt, %{
                 answers: [%{"id" => "q1", "option" => nil, "note" => "PDF."}]
               })

      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 1} = newest_run(work_item)
    end

    test "a plain answer that a later run of the stage passed is handled: a stopped run reruns alone",
         %{scope: scope} do
      feedback_process!(scope)
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", false))
      assert %WorkItem{stage_state: :waiting_answers, stage_entry: 1} = work_item
      refute escalation(work_item)

      {:ok, _work_item} =
        WorkItems.answer(scope, work_item, newest_run(work_item).attempt, %{"1" => "PDF."})

      # plan-the-build runs again with the answer and passes; so does the next entry.
      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 1} = newest_run(work_item)
      work_item = reload(work_item) |> end_run!(verdict("passed"))
      assert %DispatchRun{workflow: "write-acceptance-checks"} = newest_run(work_item)
      work_item = end_run!(work_item, verdict("passed"))

      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3, round: 1} =
               newest_run(work_item)

      work_item = end_run!(work_item, nil, %{exit_state: "failed", outcome_state: "failed"})
      assert %WorkItem{stage_state: :escalated, stage_entry: 3} = work_item
      assert [%{kind: :answer, note: "PDF."}] = Stages.notes(work_item)

      # The answer is handled: the stopped workflow runs again in the loop's next round.
      work_item = round!(scope, work_item, nil)

      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3, loop_entry: 0, round: 2} =
               newest_run(work_item)

      refute Enum.any?(runs(work_item), &(&1.workflow == "triage-review"))
    end

    test "an answer and a comment are kept when the harness does not list triage-review", %{
      scope: scope
    } do
      # An answer to an escalation's question.
      feedback_process!(scope)
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", true))
      assert %WorkItem{stage_state: :waiting_answers} = work_item
      assert %Escalation{resolved_at: nil} = escalation(work_item)
      without_triage!(scope)
      attempt = newest_run(work_item).attempt

      assert {:ok, _work_item} = WorkItems.answer(scope, work_item, attempt, %{"1" => "PDF."})

      assert %WorkItem{stage_state: :waiting_workflow, stage_entry: 0} = reload(work_item)
      assert newest_run(work_item).attempt == attempt
      assert [%{kind: :answer, note: "PDF."}] = Stages.notes(reload(work_item))

      # A comment at the gate.
      other = build_gate_item!(scope)
      without_triage!(scope)
      attempt = newest_run(other).attempt

      assert {:ok, _work_item} =
               WorkItems.another_round(scope, other, attempt, %{comment: "Rename the button."})

      assert %WorkItem{stage_state: :waiting_workflow, stage_entry: 0} = reload(other)
      assert newest_run(other).attempt == attempt
      assert [%{note: "Rename the button."}] = Stages.notes(reload(other))
    end

    test "a move into Build with a note starts triage-review; with no note it is passed over",
         %{scope: scope} do
      work_item = at_build_gate!(scope)

      [%Stages.Skip{id: first_skip}] =
        Repo.all(from s in Stages.Skip, where: s.reason == "feedback")

      {:ok, moved} = Stages.move(scope, work_item, @build, nil, expect_stage: @build)
      assert %DispatchRun{workflow: "implement-changes", stage_entry: 3} = newest_run(moved)

      # The record of the pass-over for no feedback stays, and the new pass-over writes one.
      assert Repo.get(Stages.Skip, first_skip)

      assert Repo.aggregate(from(s in Stages.Skip, where: s.reason == "feedback"), :count) ==
               2

      other = build_gate_item!(scope)

      {:ok, moved} =
        Stages.move(scope, other, @build, "Use the new export format.", expect_stage: @build)

      assert %DispatchRun{workflow: "triage-review", stage_entry: 0, round: 1} =
               newest_run(moved)
    end

    test "Request changes with a note starts triage-review; with no note or a blank one it fails",
         %{scope: scope} do
      work_item = at_build_gate!(scope)
      run = newest_run(work_item)

      # No note, and a note of spaces: nothing changes, and no run is queued.
      for note <- [nil, "  \n "] do
        assert Stages.request_changes(scope, work_item, note, nil, expect_stage: @build) ==
                 {:error, :note_missing}

        assert %WorkItem{stage_state: :at_gate} = reload(work_item)
        assert newest_run(work_item).id == run.id
        assert decisions(work_item) |> Enum.filter(&(&1.kind == :request_changes)) == []
      end

      {:ok, changed} =
        Stages.request_changes(scope, work_item, "Sort the list by date.", nil,
          expect_stage: @build
        )

      assert %DispatchRun{workflow: "triage-review", stage_entry: 0, round: 1} =
               newest_run(changed)
    end

    test "a stage with no feedback entry keeps today's Request changes and move", %{
      scope: scope
    } do
      save!(scope, [
        explore_stage(),
        stage(@build, "Build", [
          %{"workflow" => "plan-the-build"},
          %{
            "loop" => %{
              "rounds" => 3,
              "body" => [%{"workflow" => "implement-changes"}, %{"workflow" => "review-changes"}]
            }
          }
        ])
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)

      work_item =
        reload(work_item)
        |> end_run!(verdict("passed"))
        |> end_run!(nil)
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

      {:ok, changed} =
        Stages.request_changes(scope, work_item, "Sort the list by date.", nil,
          expect_stage: @build
        )

      assert %DispatchRun{workflow: "implement-changes", stage_entry: 1, loop_entry: 0} =
               newest_run(changed)

      {:ok, moved} =
        Stages.move(scope, reload(changed), @build, "Use the new format.", expect_stage: @build)

      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 0} = newest_run(moved)
    end

    test "a plain answer starts nothing again: Run another round with no note reruns the stopped workflow",
         %{scope: scope} do
      feedback_process!(scope)
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", false))
      refute escalation(work_item)

      {:ok, _work_item} =
        WorkItems.answer(scope, work_item, newest_run(work_item).attempt, %{"1" => "PDF."})

      # plan-the-build runs again with the answer and stops: the answer is unhandled.
      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 1} = newest_run(work_item)

      work_item =
        reload(work_item) |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      assert %WorkItem{stage_state: :escalated, stage_entry: 1} = work_item
      assert Stages.starts(work_item, :another_round) == {:run, "plan-the-build"}

      work_item = round!(scope, work_item, nil)

      assert %DispatchRun{workflow: "plan-the-build", stage_entry: 1, round: 1} =
               newest_run(work_item)

      refute Enum.any?(runs(work_item), &(&1.workflow == "triage-review"))

      # plan-the-build passes and handles the answer; a later stopped run reruns alone.
      work_item = reload(work_item) |> end_run!(verdict("passed"))
      assert %DispatchRun{workflow: "write-acceptance-checks"} = newest_run(work_item)
      work_item = end_run!(work_item, nil, %{exit_state: "failed", outcome_state: "failed"})
      work_item = round!(scope, work_item, nil)
      assert %DispatchRun{workflow: "write-acceptance-checks"} = newest_run(work_item)
      refute Enum.any?(runs(work_item), &(&1.workflow == "triage-review"))
    end

    test "the spend's workflow is triage-review for an act with a note or a comment", %{
      scope: scope
    } do
      # At Build's gate: Request changes and a move into Build.
      work_item = at_build_gate!(scope)
      assert Stages.starts(work_item, :request_changes) == :none
      assert Stages.starts(work_item, :request_changes, true) == {:run, "triage-review"}
      assert Stages.starts(work_item, {:move, @build}) == {:run, "implement-changes"}
      assert Stages.starts(work_item, {:move, @build}, true) == {:run, "triage-review"}

      # At the round limit: Run another round, with and without a note.
      work_item = round_limit_item!(scope)
      assert Stages.starts(work_item, :another_round) == {:run, "implement-changes"}
      assert Stages.starts(work_item, :another_round, true) == {:run, "triage-review"}
      assert Stages.starts(work_item, :accept, true) == Stages.starts(work_item, :accept)

      # Questions with no escalation: answers alone, and answers with a comment.
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", false))
      assert Stages.starts(work_item, :next_run) == {:run, "plan-the-build"}
      assert Stages.starts(work_item, :next_run, true) == {:run, "triage-review"}

      # An answer to an escalation's question.
      work_item = in_build!(scope) |> end_run!(asking("Which export format?", true))
      assert %Escalation{resolved_at: nil} = escalation(work_item)
      assert Stages.starts(work_item, :next_run) == {:run, "triage-review"}
    end
  end

  describe "the track of an approval (A-23)" do
    @tracks [
      %{"id" => "standard", "name" => "Standard"},
      %{"id" => "fast-track", "name" => "Fast track", "description" => "Skips shaping."}
    ]

    defp offering(ids),
      do: %{"gate" => %{"kind" => "person", "approvers" => "members", "tracks" => ids}}

    # Explore, whose gate offers `explore`, then Shape, whose gate offers `shape`; the
    # process declares the tracks Standard and Fast track.
    defp tracked_process!(scope, explore, shape \\ []) do
      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks,
        "stages" => [
          explore_stage(offering(explore)),
          stage(@shape, "Shape", [], offering(shape))
        ]
      }

      {:ok, version} = Processes.save(scope, scope.workspace, document)
      version
    end

    # The end of a run that pushes a proposal and a verdict that proposes the track `track`.
    defp proposing(track) do
      fn run, registered ->
        proposal_only().(run, registered)

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed", "track" => %{"id" => track, "reason" => "A small change."}},
            stage_id: run.stage_id
          )
      end
    end

    defp proposing_with(track_map) do
      fn run, registered ->
        proposal_only().(run, registered)

        {:ok, _version} =
          Stages.Artifacts.push_json(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verdict",
            %{"verdict" => "passed", "track" => track_map},
            stage_id: run.stage_id
          )
      end
    end

    test "a blank reason of a proposed track is nil", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])

      work_item =
        take_in!(scope)
        |> end_run!(proposing_with(%{"id" => "fast-track", "reason" => " "}))

      assert Stages.proposed_track_with_reason(work_item) == %{id: "fast-track", reason: nil}
      assert Stages.proposed_track(work_item) == "fast-track"
    end

    test "no proposed track has no reason", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      assert Stages.proposed_track_with_reason(work_item) == nil
    end

    # A verdict version whose file has `document`, in the store, as a version of `run` that a
    # run wrote.
    defp stored_verdict(document, fields \\ []) do
      {:ok, staged} = Artifacts.Store.impl().stage({:binary, Jason.encode!(document)}, 100_000)
      {:ok, key} = Artifacts.Store.impl().commit(staged)

      Map.merge(
        %{
          public_id: "av_#{System.unique_integer([:positive])}",
          number: 1,
          writer: :run,
          run_id: "run-a",
          run: %{run: %{cancel_requested_at: nil}},
          files: [%Artifacts.ArtifactFile{store_key: key, filename: "verdict.json"}]
        },
        Map.new(fields)
      )
    end

    defp suite_of(suite) do
      case Stages.full_suite_read(stored_verdict(%{"full_suite" => suite})) do
        {:ok, result} -> result
        :none -> nil
      end
    end

    defp artifact(type, versions), do: %{type: type, name: "main", versions: versions}

    defp report(number, run_id), do: %{number: number, run_id: run_id, writer: :run, run: nil}

    @suite_passed %{
      "state" => "passed",
      "passed" => 120,
      "failed" => 0,
      "skipped" => 3,
      "minutes" => 4.5
    }

    test "the full suite is the member of the verdict file, as the run sent it" do
      assert suite_of(@suite_passed) == %{
               state: :passed,
               passed: 120,
               failed: 0,
               skipped: 3,
               minutes: 4.5,
               reason: nil
             }

      assert %{state: :failed, passed: 9, failed: 2} =
               suite_of(%{@suite_passed | "state" => "failed", "passed" => 9, "failed" => 2})

      assert suite_of(%{"state" => "not_run", "reason" => "No test command."}) == %{
               state: :not_run,
               passed: nil,
               failed: nil,
               skipped: nil,
               minutes: nil,
               reason: "No test command"
             }
    end

    test "counts sent as 12.0 are the whole number 12" do
      assert %{passed: 12, failed: 0, skipped: 3} =
               suite_of(%{@suite_passed | "passed" => 12.0, "skipped" => 3.0})

      assert suite_of(%{@suite_passed | "passed" => 12.5}) == nil
    end

    test "a result with no counts has the minutes and nil counts" do
      for state <- ["passed", "failed"] do
        assert suite_of(%{"state" => state, "minutes" => 6.5}) == %{
                 state: String.to_existing_atom(state),
                 passed: nil,
                 failed: nil,
                 skipped: nil,
                 minutes: 6.5,
                 reason: nil
               }
      end
    end

    test "counts of 0 are counts, not absent counts" do
      assert %{passed: 0, failed: 0, skipped: 0, minutes: 2} =
               suite_of(%{
                 "state" => "passed",
                 "passed" => 0,
                 "failed" => 0,
                 "skipped" => 0,
                 "minutes" => 2
               })

      assert %{passed: 0, failed: 0, skipped: 0} =
               suite_of(%{
                 "state" => "failed",
                 "passed" => 0.0,
                 "failed" => 0.0,
                 "skipped" => 0.0,
                 "minutes" => 2
               })
    end

    test "counts that are there come all three, and are whole numbers" do
      base = %{"state" => "passed", "minutes" => 1}

      for bad <- [
            %{"passed" => 1},
            %{"passed" => 1, "failed" => 0},
            %{"failed" => 0, "skipped" => 0},
            %{"passed" => 1, "failed" => 0, "skipped" => nil},
            %{"passed" => nil, "failed" => nil, "skipped" => nil},
            %{"passed" => "1", "failed" => 0, "skipped" => 0}
          ] do
        assert suite_of(Map.merge(base, bad)) == nil, inspect(bad)
      end

      # No minutes is no result, with or without counts.
      assert suite_of(%{"state" => "passed"}) == nil
    end

    test "a result that is not whole is no result" do
      for bad <- [
            %{"state" => "not_run"},
            %{"state" => "not_run", "reason" => 5},
            %{"state" => "not_run", "reason" => ""},
            %{"state" => "not_run", "reason" => "  "},
            %{"state" => "not_run", "reason" => "."},
            %{"state" => "not_run", "reason" => " . "},
            %{@suite_passed | "passed" => "12"},
            %{@suite_passed | "failed" => nil},
            %{@suite_passed | "skipped" => -1},
            %{@suite_passed | "minutes" => "6"},
            Map.delete(@suite_passed, "minutes"),
            %{@suite_passed | "state" => "unknown"},
            %{"passed" => 1}
          ] do
        assert suite_of(bad) == nil, inspect(bad)
      end
    end

    test "a reason is trimmed and loses one final full stop only" do
      for {sent, read} <- [
            {"Wait...", "Wait.."},
            {"Is it?", "Is it?"},
            {"Stop!", "Stop!"},
            {"  No test command.  ", "No test command"},
            {"No test command", "No test command"},
            {"..", "."}
          ] do
        assert %{reason: ^read} = suite_of(%{"state" => "not_run", "reason" => sent})
      end
    end

    test "no verdict, or a verdict file with no full_suite, is no result" do
      assert Stages.full_suite_read(nil) == :none
      assert Stages.full_suite_read(stored_verdict(%{"verdict" => "passed"})) == :none
      assert Stages.full_suite_read(%{files: []}) == :none
    end

    test "a file the store cannot read is an error, not no result" do
      version = stored_verdict(%{})
      [file] = version.files
      gone = %{version | files: [%{file | store_key: String.duplicate("0", 64)}]}

      assert Stages.full_suite_read(gone) == {:error, :store_unavailable}
    end

    test "a withdrawal is not the verdict of the report" do
      withdrawal = stored_verdict(%{}, run_id: "run-a", number: 2, withdrawn: true)
      kept = stored_verdict(%{}, run_id: "run-a", number: 1)

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [withdrawal, kept])
      ]

      assert Stages.full_suite_versions(artifacts, 1) == [kept]
    end

    defp verdict_with(suite, fields), do: stored_verdict(%{"full_suite" => suite}, fields)

    test "the verdicts of the run that wrote the shown report belong to it, newest first" do
      mine = stored_verdict(%{"verdict" => "passed"}, run_id: "run-a", number: 2)
      earlier = stored_verdict(%{"verdict" => "passed"}, run_id: "run-a", number: 1)

      # Newer verdicts: another run's, and another stage's.
      other_run = stored_verdict(%{"verdict" => "passed"}, run_id: "run-b", number: 4)
      other_stage = stored_verdict(%{"verdict" => "passed"}, run_id: "run-c", number: 3)

      artifacts = [
        artifact("build-report", [report(2, "run-a"), report(1, "run-z")]),
        artifact("verdict", [other_run, other_stage, mine, earlier])
      ]

      assert Stages.full_suite_versions(artifacts, 2) == [mine, earlier]
      assert Stages.full_suite_versions(artifacts, 1) == []
    end

    test "a later verdict of the run with no result does not hide an earlier one" do
      earlier = verdict_with(@suite_passed, run_id: "run-a", number: 1)
      later = stored_verdict(%{"verdict" => "passed"}, run_id: "run-a", number: 2)

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [later, earlier])
      ]

      assert {%{state: :passed, passed: 120}, reads} = Stages.full_suite(artifacts, 1)

      assert reads == %{
               earlier.public_id => Stages.full_suite_read(earlier),
               later.public_id => :none
             }
    end

    test "a later verdict of the run with another result is the one shown" do
      earlier = verdict_with(@suite_passed, run_id: "run-a", number: 1)
      failed = %{@suite_passed | "state" => "failed", "failed" => 2}
      later = verdict_with(failed, run_id: "run-a", number: 2)

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [later, earlier])
      ]

      assert {%{state: :failed, failed: 2}, reads} = Stages.full_suite(artifacts, 1)
      # The earlier verdict is not read once the later one has a result.
      assert Map.keys(reads) == [later.public_id]
    end

    test "a newer verdict of another run is ignored, with its result" do
      mine = verdict_with(@suite_passed, run_id: "run-a", number: 1)
      newer = verdict_with(%{@suite_passed | "passed" => 1}, run_id: "run-b", number: 2)

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [newer, mine])
      ]

      assert {%{passed: 120}, _reads} = Stages.full_suite(artifacts, 1)

      # With no verdict of run-a, the report has no result.
      artifacts = [artifact("build-report", [report(1, "run-a")]), artifact("verdict", [newer])]
      assert {nil, %{}} = Stages.full_suite(artifacts, 1)
    end

    test "a version read before is not read again, and a file the store cannot read is" do
      good = verdict_with(@suite_passed, run_id: "run-a", number: 1)
      [file] = good.files
      gone = %{good | files: [%{file | store_key: String.duplicate("0", 64)}]}

      artifacts = [artifact("build-report", [report(1, "run-a")]), artifact("verdict", [good])]
      {result, reads} = Stages.full_suite(artifacts, 1)

      # The kept read is used: the file of the version is gone and the result stays.
      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [%{gone | public_id: good.public_id}])
      ]

      assert {^result, ^reads} = Stages.full_suite(artifacts, 1, reads)

      # A version that was never read, with a file the store cannot read, is read again.
      artifacts = [artifact("build-report", [report(1, "run-a")]), artifact("verdict", [gone])]
      assert {nil, %{}} = Stages.full_suite(artifacts, 1)
    end

    test "a newest verdict the store cannot read gives no result, and no older one" do
      newest = verdict_with(@suite_passed, run_id: "run-a", number: 2)
      older = verdict_with(%{@suite_passed | "passed" => 7}, run_id: "run-a", number: 1)
      [file] = newest.files
      unreadable = %{newest | files: [%{file | store_key: String.duplicate("0", 64)}]}

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [unreadable, older])
      ]

      # The older result is not shown in place of the newest, and the failed version is not
      # kept, so the next call reads it again.
      assert {nil, reads} = Stages.full_suite(artifacts, 1)
      assert reads == %{}
      refute Map.has_key?(reads, unreadable.public_id)
    end

    test "a version kept as having no result is not read again" do
      none = stored_verdict(%{"verdict" => "passed"}, run_id: "run-a", number: 1)
      [file] = none.files
      unreadable = %{none | files: [%{file | store_key: String.duplicate("0", 64)}]}

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [unreadable])
      ]

      # Read, the file is an error; the kept :none stands in for the read.
      assert {nil, %{}} = Stages.full_suite(artifacts, 1)
      reads = %{unreadable.public_id => :none}
      assert {nil, ^reads} = Stages.full_suite(artifacts, 1, reads)
    end

    test "a verdict of a run a member cancelled is skipped" do
      cancelled = %{run: %{cancel_requested_at: ~U[2026-11-17 10:00:00Z]}}
      kept = stored_verdict(%{}, run_id: "run-a", number: 1)
      dropped = stored_verdict(%{}, run_id: "run-a", number: 2, run: cancelled)

      artifacts = [
        artifact("build-report", [report(1, "run-a")]),
        artifact("verdict", [dropped, kept])
      ]

      assert Stages.full_suite_versions(artifacts, 1) == [kept]

      # A report of a cancelled run is not shown as the work's result either.
      artifacts = [
        artifact("build-report", [%{report(1, "run-a") | run: cancelled}]),
        artifact("verdict", [kept])
      ]

      assert Stages.full_suite_versions(artifacts, 1) == []
    end

    test "a report with no run, or with no verdict, has no verdict" do
      # A verdict with no run either does not belong to the report.
      verdict = verdict_with(@suite_passed, run_id: nil, number: 1)
      artifacts = [artifact("build-report", [report(1, nil)]), artifact("verdict", [verdict])]
      assert Stages.full_suite_versions(artifacts, 1) == []

      assert Stages.full_suite_versions([artifact("build-report", [report(1, "run-a")])], 1) == []
      assert Stages.full_suite_versions([], 1) == []
    end

    defp tracks_of(work_item), do: Enum.map(decisions(work_item), & &1.track)

    test "an approval with no track records the gate's first track, and the work item is on it",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())

      assert Stages.proposed_track(work_item) == nil
      assert [%{id: "standard"}, %{id: "fast-track"}] = Stages.offered_tracks(work_item)
      assert Stages.track(work_item) == nil

      assert {:ok, %WorkItem{stage_id: @shape} = moved} = WorkItems.confirm(scope, work_item, 1)
      assert tracks_of(moved) == ["standard"]
      assert Stages.track(moved) == "standard"
    end

    test "an approval with no track records the track the run proposed", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))

      assert Stages.proposed_track(work_item) == "fast-track"
      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1)
      assert tracks_of(moved) == ["fast-track"]
      assert Stages.track(moved) == "fast-track"
    end

    test "a proposed track that the gate does not offer is not recorded: the first offered is",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))

      # The gate stops offering the track the run proposed, as a later version of the
      # process can.
      version = Repo.get!(Processes.Version, work_item.process_version_id)

      document =
        put_in(version.document, ["stages", Access.at(0), "gate", "tracks"], ["standard"])

      {1, _rows} =
        Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
          set: [document: document]
        )

      assert Stages.proposed_track(work_item) == "fast-track"
      assert [%{id: "standard"}] = Stages.offered_tracks(work_item)
      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1)
      assert tracks_of(moved) == ["standard"]
    end

    test "the track a person chooses wins over the proposed track, at the gate and by confirm",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))

      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")
      assert tracks_of(moved) == ["standard"]

      other = take_in!(scope) |> end_run!(proposing("standard"))

      assert {:ok, moved} =
               Stages.approve(scope, other, nil, expect_stage: @explore, track: "fast-track")

      assert tracks_of(moved) == ["fast-track"]
    end

    test "a verdict with no track proposes none", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          proposal_only().(run, registered)
          verdict("passed").(run, registered)
        end)

      assert Stages.proposed_track(work_item) == nil
      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1)
      assert tracks_of(moved) == ["standard"]
    end

    test "the track a person chooses is recorded, at the gate and by confirm", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())

      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      assert tracks_of(moved) == ["fast-track"]

      other = take_in!(scope) |> end_run!(understood_result())

      assert {:ok, moved} =
               Stages.approve(scope, other, nil, expect_stage: @explore, track: "fast-track")

      assert tracks_of(moved) == ["fast-track"]
    end

    test "a track the gate does not offer is refused, and nothing is written", %{scope: scope} do
      tracked_process!(scope, ["standard"])
      work_item = take_in!(scope) |> end_run!(understood_result())

      assert WorkItems.confirm(scope, work_item, 1, track: "fast-track") ==
               {:error, {:track_not_offered, "fast-track"}}

      assert Stages.approve(scope, work_item, nil, expect_stage: @explore, track: "express") ==
               {:error, {:track_not_offered, "express"}}

      work_item = reload(work_item)
      assert %{stage_id: @explore, stage_state: :at_gate} = work_item
      assert decisions(work_item) == []
      refute Repo.get_by(Confirmation, work_item_id: work_item.id)
    end

    test "a gate that offers no track refuses one, and records none without one", %{scope: scope} do
      tracked_process!(scope, ["standard"], [])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = reload(work_item)
      assert %{stage_id: @shape} = work_item

      assert Stages.offered_tracks(work_item) == []

      assert Stages.approve(scope, work_item, nil, expect_stage: @shape, track: "standard") ==
               {:error, {:track_not_offered, "standard"}}

      assert {:ok, _done} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert tracks_of(work_item) == ["standard", nil]
      assert Stages.track(work_item) == "standard"
    end

    test "a process with no tracks records none, and behaves as before", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())
      assert Stages.offered_tracks(work_item) == []
      assert Stages.proposed_track(work_item) == nil

      assert {:ok, %WorkItem{stage_id: @shape} = moved} = WorkItems.confirm(scope, work_item, 1)
      assert tracks_of(moved) == [nil]
      assert Stages.track(moved) == nil

      assert Stages.approve(scope, moved, nil, expect_stage: @shape, track: "standard") ==
               {:error, {:track_not_offered, "standard"}}
    end

    test "the database keeps a track to an approval, and a skip to one condition", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1)
      [decision] = decisions(moved)

      fields =
        Map.take(decision, [
          :organisation_id,
          :workspace_id,
          :work_item_id,
          :stage_id,
          :process_version_id
        ])

      error =
        catch_error(
          Repo.insert!(
            struct(
              GateDecision,
              Map.merge(fields, %{
                kind: :request_changes,
                track: "standard",
                inserted_at: DateTime.utc_now()
              })
            )
          )
        )

      assert Exception.message(error) =~ "gate_decisions_track_check"

      skip =
        Map.merge(fields, %{
          take_in: 1,
          stage_entry: 0,
          round: 1,
          workflow: "capture-demos",
          after_attempt: 0,
          inserted_at: DateTime.utc_now()
        })

      for condition <- [%{}, %{input: "spec", track: "standard"}] do
        error = catch_error(Repo.insert!(struct(Stages.Skip, Map.merge(skip, condition))))
        assert Exception.message(error) =~ "stage_skips_condition_check"
      end

      for condition <- [%{input: "spec"}, %{track: "fast-track", negated: true}] do
        assert %Stages.Skip{} = Repo.insert!(struct(Stages.Skip, Map.merge(skip, condition)))
      end
    end

    test "the reads that take what the caller read give what the plain reads give", %{
      scope: scope
    } do
      tracked_process!(scope, ["standard", "fast-track"], ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))

      version = Processes.version_for(work_item)
      artifacts = Artifacts.list(work_item)

      assert Stages.offered_tracks(work_item, version) == Stages.offered_tracks(work_item)
      assert Stages.proposed_track(work_item, artifacts) == "fast-track"

      assert Stages.proposed_track_with_reason(work_item, artifacts) ==
               %{id: "fast-track", reason: "A small change."}

      assert Stages.proposed_track_with_reason(work_item) ==
               Stages.proposed_track_with_reason(work_item, artifacts)

      assert Stages.artifact_index(work_item, artifacts) == Stages.artifact_index(work_item)
      assert Stages.skip_records(work_item).track == nil

      {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")
      assert Stages.skip_records(moved).track == "standard"

      {:ok, moved} =
        Stages.approve(scope, reload(moved), nil, expect_stage: @shape, track: "fast-track")

      assert Stages.skip_records(moved).track == Stages.track(moved)
      assert Stages.skip_records(moved).track == "fast-track"
    end

    test "a later approval with another track changes the track", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"], ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")
      assert Stages.track(moved) == "standard"

      {:ok, moved} =
        Stages.approve(scope, reload(moved), nil, expect_stage: @shape, track: "fast-track")

      assert Stages.track(moved) == "fast-track"
      assert tracks_of(moved) == ["standard", "fast-track"]
    end

    test "a later approval at Explore's gate with another track changes the track", %{
      scope: scope
    } do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")
      assert Stages.track(moved) == "standard"

      {:ok, back} = Stages.move(scope, reload(moved), @explore, nil, expect_stage: @shape)
      assert %{stage_id: @explore} = back

      back = end_run!(back, understood_result())

      {:ok, again} =
        Stages.approve(scope, back, nil, expect_stage: @explore, track: "fast-track")

      assert Stages.track(again) == "fast-track"
      assert tracks_of(again) == ["standard", nil, "fast-track"]
    end
  end

  describe "the record of a track (A-23 review)" do
    # `@tracks`, `offering/1`, `tracked_process!/3` and `proposing/1` are the ones of "the
    # track of an approval".

    @fast_track %{"track" => "fast-track"}
    @standard_track %{"track" => "standard"}

    # A process of Explore, Shape (a stage of people, run on Standard only) and a last stage
    # `last`, each with the gate and the conditions of the document.
    defp process_of!(scope, explore, middle, last) do
      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks,
        "stages" => [explore_stage(offering(explore)), middle, last]
      }

      {:ok, version} = Processes.save(scope, scope.workspace, document)
      version
    end

    defp people_stage(id, name, extra \\ %{}), do: stage(id, name, [], extra)

    test "an approval with no track at a later gate keeps the track the work item is on",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"], ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      assert Stages.track(moved) == "fast-track"

      assert {:ok, approved} = Stages.approve(scope, reload(moved), nil, expect_stage: @shape)
      assert tracks_of(approved) == ["fast-track", "fast-track"]
      assert Stages.track(approved) == "fast-track"
    end

    test "with no proposal and a gate that does not offer the current track, the first offered track",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"], ["standard"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")

      assert {:ok, approved} = Stages.approve(scope, reload(moved), nil, expect_stage: @shape)
      assert tracks_of(approved) == ["fast-track", "standard"]
    end

    # The end of a run that pushes the verdict `verdict`, with the track `track` where given.
    defp verdict_on(verdict, track) do
      fn run, _registered ->
        document =
          Map.merge(
            %{"verdict" => verdict},
            if(track,
              do: %{"track" => %{"id" => track, "reason" => "A small change."}},
              else: %{}
            )
          )

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

    test "a proposal counts from any of the stage's runs: the newest verdict with a track",
         %{scope: scope} do
      loop = %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "shape-it"}]}}

      process_of!(
        scope,
        ["standard", "fast-track"],
        stage(@shape, "Shape", [loop], offering(["standard", "fast-track"])),
        people_stage(@build, "Build")
      )

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "standard")

      work_item = reload(work_item)
      assert %WorkItem{stage_id: @shape, stage_state: :running} = work_item
      assert Stages.proposed_track(work_item) == nil

      work_item = end_run!(work_item, verdict_on("changes-requested", "fast-track"))
      assert %DispatchRun{attempt: 3} = newest_run(work_item)
      assert Stages.proposed_track(work_item) == "fast-track"

      # The newest run proposes none: the one before it still counts.
      work_item = end_run!(work_item, verdict_on("changes-requested", nil))
      assert Stages.proposed_track(work_item) == "fast-track"

      # A newer proposal replaces it.
      work_item = end_run!(work_item, verdict_on("changes-requested", "standard"))
      assert Stages.proposed_track(work_item) == "standard"
    end

    test "a run of an earlier visit to the stage proposes nothing: the current track counts",
         %{scope: scope} do
      process_of!(
        scope,
        ["standard", "fast-track"],
        people_stage(@shape, "Shape", offering(["standard", "fast-track"])),
        people_stage(@build, "Build")
      )

      # Explore's run proposes Fast track, and the approval records it.
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1)
      assert Stages.track(reload(work_item)) == "fast-track"

      # A later gate records Standard.
      {:ok, at_build} =
        Stages.approve(scope, reload(work_item), nil, expect_stage: @shape, track: "standard")

      assert Stages.track(at_build) == "standard"

      # A person moves the work item back to Explore. Its new run proposes none.
      {:ok, back} = Stages.move(scope, at_build, @explore, nil, expect_stage: @build)
      back = end_run!(back, understood_result())
      assert Stages.proposed_track(back) == nil

      {:ok, again} = Stages.approve(scope, back, nil, expect_stage: @explore)
      assert Enum.map(decisions(again), & &1.track) == ["fast-track", "standard", nil, "standard"]
      assert Stages.track(again) == "standard"
    end

    test "an approval is refused when a verdict of the stage cannot be read from the store",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))

      [file] = hd(versions(work_item, "verdict")).files
      {:ok, path} = Artifacts.open_file(file)
      File.rename!(path, path <> ".away")
      on_exit(fn -> File.rename(path <> ".away", path) end)

      assert Stages.approve(scope, work_item, nil, expect_stage: @explore) ==
               {:error, :store_unavailable}

      assert WorkItems.confirm(scope, work_item, 1) == {:error, :store_unavailable}

      work_item = reload(work_item)
      assert %{stage_id: @explore, stage_state: :at_gate} = work_item
      assert decisions(work_item) == []

      # With the file back, the approval records the proposal.
      File.rename!(path <> ".away", path)
      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1)
      assert tracks_of(moved) == ["fast-track"]
    end

    test "a move forward past a gate that offers tracks records the track an approval would",
         %{scope: scope} do
      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks,
        "stages" => [
          explore_stage(offering(["standard", "fast-track"])),
          people_stage(@shape, "Shape"),
          people_stage(@build, "Build", %{"when" => %{"track" => "fast-track"}})
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)

      # The proposal is Fast track: the move records it, and the later stage with
      # `when: {track: fast-track}` runs.
      work_item = take_in!(scope) |> end_run!(proposing("fast-track"))
      {:ok, moved} = Stages.move(scope, work_item, @shape, nil, expect_stage: @explore)
      assert [%GateDecision{kind: :move, track: "fast-track"}] = decisions(moved)
      assert Stages.track(moved) == "fast-track"

      {:ok, at_build} = Stages.approve(scope, reload(moved), nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = at_build
      assert Stages.stage_skips(at_build) == []

      # With no proposal the first track is recorded, Standard: the later stage is passed over.
      other = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = Stages.move(scope, other, @shape, nil, expect_stage: @explore)
      assert Stages.track(moved) == "standard"

      {:ok, closed} = Stages.approve(scope, reload(moved), nil, expect_stage: @shape)
      assert %WorkItem{state: :closed} = closed
      assert [%{stage_id: @build, track: "fast-track"}] = Stages.stage_skips(closed)

      # A move back records no track.
      third = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = Stages.move(scope, third, @shape, nil, expect_stage: @explore)
      {:ok, back} = Stages.move(scope, reload(third), @explore, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @explore} = back
      assert Enum.map(decisions(back), & &1.track) == ["standard", nil]
    end

    test "a stage with a track condition reached before any approval recorded a track is passed over",
         %{scope: scope} do
      process_of!(
        scope,
        ["standard", "fast-track"],
        people_stage(@shape, "Shape", %{"when" => @standard_track}),
        people_stage(@build, "Build")
      )

      # The process changes after it is saved: Explore's gate offers no track, so the
      # approval records none and the work item is on no track at Shape.
      version = Repo.get!(Processes.Version, Processes.current(scope.workspace).id)
      document = put_in(version.document, ["stages", Access.at(0), "gate", "tracks"], [])

      {1, _rows} =
        Repo.update_all(from(v in Processes.Version, where: v.id == ^version.id),
          set: [document: document]
        )

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1)

      assert Stages.track(moved) == nil
      assert %WorkItem{stage_id: @build} = reload(moved)

      assert [%{stage_id: @shape, track: "standard", negated: false, approved: nil}] =
               Stages.stage_skips(reload(moved))
    end

    test "a work item taken in again starts with no track, and no stage passed over",
         %{scope: scope} do
      runner_process!(scope)
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
      work_item = work_item |> reload() |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = reload(work_item)

      assert Stages.track(work_item) == "fast-track"
      assert [%{stage_id: @shape}] = Stages.stage_skips(work_item)

      {:ok, _closed} = WorkItems.close(scope, work_item)
      {:ok, _again} = WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})
      again = reload(work_item)

      assert again.take_in == 2
      assert Stages.track(again) == nil
      assert Stages.stage_skips(again) == []
    end

    test "the last stage passed over closes the work item", %{scope: scope} do
      process_of!(
        scope,
        ["standard", "fast-track"],
        people_stage(@shape, "Shape"),
        people_stage(@build, "Build", %{"when" => @standard_track})
      )

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      {:ok, closed} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)

      assert %WorkItem{state: :closed} = closed
      assert [%{stage_id: @build, track: "standard"}] = Stages.stage_skips(closed)
    end

    test "the records of stages passed over are in the order they were written, to the microsecond",
         %{scope: scope} do
      runner_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = reload(work_item)
      [%{stage_id: @shape}] = Stages.stage_skips(work_item)

      Repo.delete_all(from(k in Stages.Skip, where: k.work_item_id == ^work_item.id))

      row = fn stage, at ->
        Repo.insert!(%Stages.Skip{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          stage_id: stage,
          process_version_id: work_item.process_version_id,
          take_in: work_item.take_in,
          round: 1,
          track: "standard",
          after_attempt: 0,
          inserted_at: at
        })
      end

      # The first was written at 12:00:01.9, the second at 12:00:02.1: as terms, 100000
      # sorts before 900000, so the second would come first.
      row.(@shape, ~U[2025-11-14 12:00:01.900000Z])
      row.(@build, ~U[2025-11-14 12:00:02.100000Z])

      assert [@shape, @build] == Enum.map(Stages.stage_skips(work_item), & &1.stage_id)
    end

    test "two stages in a row passed over, then the third runs", %{scope: scope} do
      verify = "st_m1mqbeywdg"

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks,
        "stages" => [
          explore_stage(offering(["standard", "fast-track"])),
          people_stage(@shape, "Shape", %{"when" => @standard_track}),
          people_stage(@build, "Build", %{"unless" => @fast_track}),
          people_stage(verify, "Verify")
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = reload(work_item)

      assert %WorkItem{stage_id: ^verify, stage_state: :at_gate} = work_item

      assert [%{stage_id: @shape, negated: false}, %{stage_id: @build, negated: true}] =
               Stages.stage_skips(work_item)
    end

    test "a stage with a condition on an input is passed over without it and runs with it",
         %{scope: scope} do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "spec",
          "base_view" => "document"
        })

      verify = "st_m1mqbeywdg"
      held = %{"when" => %{"input" => "spec"}}

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          explore_stage(),
          people_stage(@shape, "Shape", %{"outputs" => [%{"type" => "spec", "required" => false}]}),
          people_stage(@build, "Build", held),
          people_stage(verify, "Verify", %{"unless" => %{"input" => "spec"}})
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1)
      {:ok, done} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)

      # No spec: Build is passed over; Verify, which runs unless a spec exists, runs.
      assert %WorkItem{stage_id: ^verify} = done

      assert [%{stage_id: @build, input: "spec", track: nil, negated: false, approved: nil}] =
               Stages.stage_skips(done)
    end
  end

  describe "the runner on tracks (A-23)" do
    @fast_track %{"track" => "fast-track"}
    @standard_track %{"track" => "standard"}

    # Explore, whose gate offers Standard and Fast track; Shape, worked by people, which only
    # Standard goes through; Build, whose input `spec` and whose entry `review` Fast track
    # does without.
    defp runner_process!(scope) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "spec",
          "base_view" => "document"
        })

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks,
        "stages" => [
          explore_stage(offering(["standard", "fast-track"])),
          stage(@shape, "Shape", [], %{
            "when" => @standard_track,
            "outputs" => [%{"type" => "spec", "required" => false}]
          }),
          stage(
            @build,
            "Build",
            [%{"workflow" => "implement"}, %{"workflow" => "review", "unless" => @fast_track}],
            %{"inputs" => [%{"type" => "spec", "required" => true, "unless" => @fast_track}]}
          )
        ]
      }

      {:ok, version} = Processes.save(scope, scope.workspace, document)
      version
    end

    defp confirmed_on!(scope, track) do
      runner_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: track)
      reload(work_item)
    end

    test "Fast track passes Shape over and Build runs with no spec", %{scope: scope} do
      work_item = confirmed_on!(scope, "fast-track")

      assert Stages.track(work_item) == "fast-track"
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
      assert %DispatchRun{workflow: "implement", stage_id: @build} = newest_run(work_item)

      # Shape has no gate decision: nobody approved it.
      assert Enum.map(decisions(work_item), & &1.stage_id) == [@explore]

      assert [%{stage_id: @shape, track: "standard", negated: false, input: nil}] =
               Stages.stage_skips(work_item)

      # Build's input is not required on Fast track, so it shows as not required.
      assert [%{type: "spec", required: false, version: nil}] = Stages.inputs(work_item)
    end

    test "Standard goes through Shape, and Build waits for its spec", %{scope: scope} do
      work_item = confirmed_on!(scope, "standard")

      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      assert Stages.stage_skips(work_item) == []

      {:ok, built} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build, stage_state: :waiting_inputs} = built
      assert [%{type: "spec", required: true, version: nil}] = Stages.inputs(built)
    end

    test "an entry with an unless on the track is passed over on Fast track, with its reason",
         %{scope: scope} do
      fast = confirmed_on!(scope, "fast-track")
      assert %DispatchRun{workflow: "implement"} = newest_run(fast)

      fast = end_run!(fast, verdict("passed"))

      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = fast

      assert [%{workflow: "review", track: "fast-track", negated: true, input: nil}] =
               Stages.skips(fast)
    end

    test "a person's move runs a stage whatever its condition", %{scope: scope} do
      work_item = confirmed_on!(scope, "fast-track")
      assert %WorkItem{stage_id: @build} = work_item

      assert {:ok, %WorkItem{stage_id: @shape, stage_state: :at_gate}} =
               Stages.move(scope, work_item, @shape, "Shape it anyway", expect_stage: @build)

      # The stage the move enters is no stage passed over now: its record is gone.
      assert Stages.stage_skips(work_item) == []
    end

    test "a stage passed over twice has one record, which names the newer approval",
         %{scope: scope} do
      work_item = confirmed_on!(scope, "fast-track")
      assert [%{stage_id: @shape, approved: first}] = Stages.stage_skips(work_item)

      {:ok, back} = Stages.move(scope, work_item, @explore, nil, expect_stage: @build)
      # No record while the work item is back at Explore: Shape is not passed over now.
      assert %WorkItem{stage_id: @explore} = back

      back = end_run!(back, understood_result())

      {:ok, again} =
        Stages.approve(scope, back, nil, expect_stage: @explore, track: "fast-track")

      assert %WorkItem{stage_id: @build} = again
      assert [%{stage_id: @shape, approved: second}] = Stages.stage_skips(again)
      assert second.track_id == "fast-track"
      assert DateTime.compare(second.at, first.at) == :gt
    end

    test "a stage run after a move back and another track has no record of a pass-over",
         %{scope: scope} do
      work_item = confirmed_on!(scope, "fast-track")
      {:ok, back} = Stages.move(scope, work_item, @explore, nil, expect_stage: @build)
      back = end_run!(back, understood_result())

      {:ok, again} =
        Stages.approve(scope, back, nil, expect_stage: @explore, track: "standard")

      assert %WorkItem{stage_id: @shape} = again
      assert Stages.stage_skips(again) == []
    end

    test "a stage a person moved into and out of before it ran has no record either",
         %{scope: scope} do
      work_item = confirmed_on!(scope, "fast-track")
      assert [%{stage_id: @shape}] = Stages.stage_skips(work_item)

      {:ok, in_shape} = Stages.move(scope, work_item, @shape, nil, expect_stage: @build)
      assert %WorkItem{stage_id: @shape} = in_shape

      {:ok, out} = Stages.move(scope, in_shape, @build, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build} = out
      assert Stages.stage_skips(out) == []
    end

    test "a later approval at Explore's gate with another track changes the stages after it",
         %{scope: scope} do
      work_item = confirmed_on!(scope, "fast-track")
      assert %WorkItem{stage_id: @build} = work_item

      {:ok, back} = Stages.move(scope, work_item, @explore, nil, expect_stage: @build)
      assert %WorkItem{stage_id: @explore} = back

      back = end_run!(back, understood_result())

      {:ok, again} =
        Stages.approve(scope, back, nil, expect_stage: @explore, track: "standard")

      assert Stages.track(again) == "standard"
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = again
    end

    test "a process with no tracks runs as before", %{scope: scope} do
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, moved} = WorkItems.confirm(scope, work_item, 1)

      assert %WorkItem{stage_id: @shape} = moved
      assert Stages.stage_skips(moved) == []
      assert Stages.track(moved) == nil
    end
  end

  describe "a gate none (vault 0252)" do
    # A stage with a loop of two workflows and a gate none, as Build, then a stage that
    # reads its outputs, as Verify. `explainer` stands for Build's submission.
    defp build_then_verify!(scope, rounds \\ 3) do
      save!(scope, [
        stage(
          @explore,
          "Build",
          [
            %{
              "loop" => %{
                "rounds" => rounds,
                "body" => [
                  %{"workflow" => "implement-changes"},
                  %{"workflow" => "review-changes"}
                ]
              }
            }
          ],
          %{
            "outputs" => [
              %{"type" => "explainer", "required" => true},
              %{"type" => "decision-record", "required" => false}
            ],
            "gate" => %{"kind" => "none"}
          }
        ),
        stage(@shape, "Verify", [%{"workflow" => "verify-a-ticket"}], %{
          "inputs" => [
            %{"type" => "explainer", "required" => true},
            %{"type" => "decision-record", "required" => false}
          ]
        })
      ])
    end

    # The end of a run that pushes the version `n` of each of `types`, then `verdict`.
    defp pushes(types, n, verdict \\ nil) do
      fn run, registered ->
        for type <- types do
          {:ok, _version} =
            Stages.Artifacts.push(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              type,
              [
                %{filename: "#{type}.md", content_type: "text/markdown", binary: "# #{type} #{n}"}
              ],
              stage_id: run.stage_id
            )
        end

        if verdict, do: verdict(verdict).(run, registered)
      end
    end

    defp version_id(work_item, type, number),
      do: Enum.find(versions(work_item, type), &(&1.number == number)).public_id

    test "a passed run records an approval of the newest outputs, and Verify's run reads them",
         %{scope: scope} do
      build_then_verify!(scope)

      work_item =
        take_in!(scope)
        |> end_run!(pushes(["explainer", "decision-record"], 1))
        |> end_run!(verdict("changes-requested"))
        |> end_run!(pushes(["explainer"], 2))

      assert decisions(work_item) == []
      work_item = end_run!(work_item, verdict("passed"))

      explainer = version_id(work_item, "explainer", 2)
      record = version_id(work_item, "decision-record", 1)

      assert [
               %GateDecision{
                 kind: :approve,
                 stage_id: @explore,
                 user_id: nil,
                 automatic: true,
                 versions: [^explainer, ^record]
               }
             ] = decisions(work_item)

      assert %WorkItem{stage_id: @shape, stage_state: :running} = work_item
      assert %DispatchRun{stage_id: @shape, workflow: "verify-a-ticket"} = newest_run(work_item)

      assert [
               %{type: "explainer", version: %{id: ^explainer, approvals: [approval]}},
               %{type: "decision-record", version: %{id: ^record}}
             ] = Stages.inputs(work_item)

      assert %{automatic: true, user_id: nil, stage_id: @explore} = approval
      # The approval writes no entry in the audit trail: no person acted.
      refute Repo.exists?(
               from e in Entry,
                 where: e.subject_id == ^work_item.id and e.action == "gate.approve"
             )
    end

    test "an accept at the round limit is the approval, recorded with the member", %{
      scope: scope
    } do
      build_then_verify!(scope, 1)

      work_item =
        take_in!(scope)
        |> end_run!(pushes(["explainer"], 1))
        |> end_run!(verdict("changes-requested"))

      assert %Escalation{cause: :round_limit} = escalation(work_item)
      assert decisions(work_item) == []

      assert {:ok, %WorkItem{stage_id: @shape, stage_state: :running}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      explainer = version_id(work_item, "explainer", 1)
      user_id = scope.user.id

      assert [
               %GateDecision{
                 kind: :approve,
                 stage_id: @explore,
                 user_id: ^user_id,
                 automatic: false,
                 versions: [^explainer]
               }
             ] = decisions(work_item)

      assert [%{type: "explainer", version: %{id: ^explainer}}, %{version: nil}] =
               Stages.inputs(work_item)
    end

    test "an accept at a person gate records no approval", %{scope: scope} do
      save!(scope, [
        stage(@explore, "Build", [%{"workflow" => "implement-changes"}], %{
          "outputs" => [%{"type" => "explainer", "required" => true}]
        })
      ])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          pushes(["explainer"], 1).(run, registered)
          verdict("escalate", [again("Choose the wording.")]).(run, registered)
        end)

      assert %Escalation{cause: :escalate} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      assert decisions(work_item) == []
    end

    test "the approval leaves out a version of a run a member cancelled", %{scope: scope} do
      build_then_verify!(scope)

      cancelled = fn run, registered ->
        pushes(["explainer"], 2).(run, registered)

        {1, _rows} =
          Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^registered.id),
            set: [cancel_requested_at: DateTime.utc_now(), cancel_requested_by_id: scope.user.id]
          )
      end

      work_item =
        take_in!(scope)
        |> end_run!(pushes(["explainer"], 1))
        |> end_run!(verdict("changes-requested"))
        |> end_run!(cancelled)

      assert %Escalation{cause: :run_stopped} = escalation(work_item)

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil, expect_stage: @explore)

      # The next round pushes no explainer: the newest one that counts is version 1.
      assert %DispatchRun{workflow: "implement-changes"} = newest_run(work_item)
      work_item = work_item |> end_run!(nil) |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @shape} = work_item

      assert Artifacts.cancelled?(Enum.find(versions(work_item, "explainer"), &(&1.number == 2)))
      explainer = version_id(work_item, "explainer", 1)
      assert [%GateDecision{automatic: true, versions: [^explainer]}] = decisions(work_item)
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
  end

  describe "inputs and the artifact index" do
    test "the next stage reads the approved version; a newer one with no decision is changed " <>
           "after approval, and no change",
         %{scope: scope} do
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

      # A handed-over run at Explore (`live_stage_run!/2`) pushes a newer version with no
      # decision. It is no change (vault 0261, 624 (a)): the next stage still reads the
      # approved one.
      stage_version!(work_item, "proposal", a_proposal(), @explore)

      assert [%{id: ^id, decision: nil}] = Enum.map(Stages.inputs(work_item), & &1.version)

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
               }
             ] = Enum.filter(Stages.artifact_index(work_item), &(&1.type == "proposal"))
    end

    test "a version a cancelled run wrote after an approval is not newer and marks no change",
         %{scope: scope} do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{"inputs" => [%{"type" => "proposal", "required" => true}]})
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      [proposal] = versions(work_item, "proposal")
      id = proposal.public_id
      run = live_run!(work_item)

      {:ok, %{number: 2}} =
        Stages.Artifacts.push({:run, run}, work_item, "proposal", a_proposal(),
          stage_id: @explore
        )

      index = fn -> Enum.filter(Stages.artifact_index(work_item), &(&1.type == "proposal")) end
      assert [%{changed_after_approval: true}] = index.()

      cancel_run!(scope, run)

      assert [
               %{
                 stage_id: @explore,
                 approved_version: ^id,
                 changed_after_approval: false,
                 versions: [%{number: 2, cancelled: true}, %{number: 1, cancelled: false}]
               }
             ] = index.()
    end

    test "an input leaves out a withdrawn name; a push of files lists it again", %{
      scope: scope
    } do
      save!(scope, [
        explore_stage(%{
          "outputs" => [
            %{"type" => "proposal", "required" => true},
            %{"type" => "explainer", "required" => false}
          ]
        }),
        stage(@shape, "Shape", [], %{"inputs" => [%{"type" => "explainer", "required" => true}]})
      ])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          Apiary.WorkItemsFixtures.push_result!(run, registered, understood_result())
          {:ok, _version} = push_explainer(run, "main")
        end)

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      automatic_approval!(work_item)
      [explainer] = versions(work_item, "explainer")
      assert [%{version: %{id: id}}] = Stages.inputs(work_item)
      assert id == explainer.public_id

      # A run of the work item that has not ended withdraws the explainer.
      run = live_run!(work_item)

      {:ok, withdrawal} =
        Artifacts.withdraw({:run, run}, work_item, "explainer", stage_id: @explore)

      assert %{number: 2, withdrawn: true, files: []} = withdrawal
      assert [%{type: "explainer", version: nil}] = Stages.inputs(work_item)

      # The index has the name, its newest version marked.
      assert [%{versions: [%{number: 2, withdrawn: true}, %{number: 1, withdrawn: false}]}] =
               Enum.filter(Stages.artifact_index(work_item), &(&1.type == "explainer"))

      {:ok, _version} = push_explainer(run, "main")

      assert [%{version: %{id: ^id}}] = Stages.inputs(work_item)
    end

    test "an input keeps a name a run a member cancelled withdrew", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "outputs" => [
            %{"type" => "proposal", "required" => true},
            %{"type" => "explainer", "required" => false}
          ]
        }),
        stage(@shape, "Shape", [], %{"inputs" => [%{"type" => "explainer", "required" => true}]})
      ])

      work_item =
        take_in!(scope)
        |> end_run!(fn run, registered ->
          Apiary.WorkItemsFixtures.push_result!(run, registered, understood_result())
          {:ok, _version} = push_explainer(run, "main")
        end)

      {:ok, work_item} =
        Stages.approve(scope, work_item, nil, expect_stage: reload(work_item).stage_id)

      automatic_approval!(work_item)
      [explainer] = versions(work_item, "explainer")
      run = live_run!(work_item)

      {:ok, _withdrawal} =
        Artifacts.withdraw({:run, run}, work_item, "explainer", stage_id: @explore)

      assert [%{type: "explainer", version: nil}] = Stages.inputs(work_item)
      cancel_run!(scope, run)

      assert [%{version: %{id: id}}] = Stages.inputs(work_item)
      assert id == explainer.public_id
    end
  end

  describe "inputs after a move to an earlier stage" do
    @verify "st_m1mqbeywdg"

    # Explore, Shape (reads Explore's proposal), Build (makes an explainer and a spec) and
    # Verify.
    defp moved_process!(scope) do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{"inputs" => [%{"type" => "proposal", "required" => true}]}),
        stage(@build, "Build", [], %{
          "outputs" => [
            %{"type" => "explainer", "required" => false},
            %{"type" => "acceptance-criteria", "required" => false}
          ]
        }),
        stage(@verify, "Verify", [])
      ])
    end

    defp at_shape_with_proposal!(scope) do
      moved_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1)
      assert %WorkItem{stage_id: @shape} = work_item = reload(work_item)
      work_item
    end

    defp at_build!(scope) do
      work_item = at_shape_with_proposal!(scope)
      {:ok, at_build} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build} = at_build
      at_build
    end

    # A version of `type` that a live run of the work item's stage pushes.
    defp add!(work_item, type, name) do
      files = if type == "acceptance-criteria", do: criteria_files(), else: file(name)
      stage_version!(work_item, type, files)
      work_item
    end

    defp move_to!(scope, work_item, stage_id) do
      {:ok, moved} =
        Stages.move(scope, work_item, stage_id, nil, expect_stage: reload(work_item).stage_id)

      moved
    end

    # The marked inputs: the type and the number of the version.
    defp marked(work_item) do
      for %{from: :move, type: type, version: %{number: number}} <- Stages.inputs(work_item),
          do: {type, number}
    end

    defp moves(work_item), do: Enum.filter(decisions(work_item), &(&1.kind == :move))

    defp public_id(work_item, type, number) do
      Enum.find_value(versions(work_item, type), &(&1.number == number && &1.public_id))
    end

    test "a move back lists the newest version of each output of the stage it left", %{
      scope: scope
    } do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      add!(work_item, "explainer", "two.md")
      add!(work_item, "acceptance-criteria", "spec.md")
      assert Stages.inputs(work_item) == []

      shape = move_to!(scope, work_item, @shape)
      proposal = public_id(work_item, "proposal", 1)

      assert [
               %{type: "proposal", required: true, version: %{id: ^proposal}} = read,
               %{type: "explainer", required: false, from: :move, version: %{number: 2} = one},
               %{
                 type: "acceptance-criteria",
                 required: false,
                 from: :move,
                 version: %{number: 1} = two
               }
             ] = Stages.inputs(shape)

      refute Map.has_key?(read, :from)
      assert one.id == public_id(work_item, "explainer", 2)
      assert two.id == public_id(work_item, "acceptance-criteria", 1)
    end

    test "a version made before the work item last entered the stage is not listed", %{
      scope: scope
    } do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "old.md")
      add!(work_item, "acceptance-criteria", "old.md")
      shape = move_to!(scope, work_item, @shape)
      assert marked(shape) == [{"explainer", 1}, {"acceptance-criteria", 1}]

      # Shape's gate passes, so Build is entered again; only its spec is made this time.
      {:ok, again} = Stages.approve(scope, shape, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build} = again
      add!(again, "acceptance-criteria", "new.md")

      shape = move_to!(scope, again, @shape)
      assert marked(shape) == [{"acceptance-criteria", 2}]
    end

    test "a version made after the work item left the stage is not listed", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      run = live_stage_run!(work_item)
      shape = move_to!(scope, work_item, @shape)

      # A late push into Build by a run that was still running at the move.
      {:ok, late} =
        Stages.Artifacts.push({:run, run}, reload(work_item), "explainer", file("late.md"),
          stage_id: @build
        )

      later = DateTime.add(DateTime.utc_now(), 60, :second)

      {1, _rows} =
        Repo.update_all(from(v in "artifact_versions", where: v.public_id == ^late.public_id),
          set: [inserted_at: later]
        )

      assert marked(shape) == [{"explainer", 1}]
    end

    test "the rule stops when the stage's gate passes again", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      shape = move_to!(scope, work_item, @shape)
      assert marked(shape) == [{"explainer", 1}]

      {:ok, again} = Stages.approve(scope, shape, nil, expect_stage: @shape)
      {:ok, verifying} = Stages.approve(scope, again, nil, expect_stage: @build)
      assert %WorkItem{stage_id: @verify} = verifying

      # Back at Shape, Build is not the stage that was left last, and its gate has passed.
      shape = move_to!(scope, verifying, @shape)
      assert marked(shape) == []
    end

    test "each stage a work item left, and not passed since, is listed once", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      add!(work_item, "explainer", "two.md")
      shape = move_to!(scope, work_item, @shape)
      {:ok, build} = Stages.approve(scope, shape, nil, expect_stage: @shape)
      add!(build, "acceptance-criteria", "spec.md")
      shape = move_to!(scope, build, @shape)
      explore = move_to!(scope, shape, @explore)

      # Build was left twice: its newest departure counts, from its last entry.
      assert marked(explore) == [{"acceptance-criteria", 1}]
      assert [@build, @build] = for(d <- moves(work_item), d.stage_id == @build, do: d.stage_id)
    end

    test "no approval lists a marked version that a run made with no decision", %{
      scope: scope
    } do
      # As `moved_process!/1`, but Build runs a workflow, whose run makes the explainer.
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{"inputs" => [%{"type" => "proposal", "required" => true}]}),
        stage(@build, "Build", [%{"workflow" => "make-a-small-change"}], %{
          "outputs" => [%{"type" => "explainer", "required" => false}]
        }),
        stage(@verify, "Verify", [])
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1)
      {:ok, at_build} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build} = at_build

      at_build = end_run!(at_build, pushes_one("explainer", "# One", []))
      assert [%{writer: :run, decision_id: nil}] = versions(at_build, "explainer")

      shape = move_to!(scope, at_build, @shape)
      assert marked(shape) == [{"explainer", 1}]

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.approve(scope, shape, nil, expect_stage: @shape)

      # Shape's two approvals, one for each time Build was entered, list no version.
      assert [[], []] = for(d <- decisions(work_item), d.stage_id == @shape, do: d.versions)

      assert [%{type: "explainer", approved_version: nil, versions: [%{approvals: []}]}] =
               Enum.filter(Stages.artifact_index(work_item), &(&1.type == "explainer"))
    end

    test "an escalation's move back lists them too", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [stage_state: :escalated]
        )

      assert {:ok, %WorkItem{stage_id: @shape} = shape} =
               Stages.resolve_escalation(scope, work_item, {:move_back, @shape}, "Not built",
                 expect_stage: @build
               )

      assert marked(shape) == [{"explainer", 1}]

      # The resolution is a move like a person's: a `move` decision that names the escalation
      # and has none of its text, which the escalation keeps.
      assert [
               %GateDecision{
                 stage_id: @build,
                 to_stage_id: @shape,
                 note: nil,
                 user_id: user_id,
                 escalation_id: escalation_id
               }
             ] = moves(work_item)

      assert user_id == scope.user.id
      assert %Escalation{id: ^escalation_id} = Repo.get_by(Escalation, work_item_id: work_item.id)

      # The notes list the escalation once, and no entry for the move.
      assert [%{kind: :escalation, note: "Not built"}] =
               Enum.filter(Stages.notes(shape), &(&1.kind in [:move, :escalation]))
    end

    test "a person's move without text is listed in the notes", %{scope: scope} do
      work_item = at_build!(scope)
      shape = move_to!(scope, work_item, @shape)

      assert [%GateDecision{escalation_id: nil, note: nil}] = moves(work_item)

      assert [%{kind: :move, stage_id: @build, note: nil}] =
               Enum.filter(Stages.notes(shape), &(&1.kind in [:move, :escalation]))
    end

    test "a move forward past the stage ends the rule", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      shape = move_to!(scope, work_item, @shape)
      assert marked(shape) == [{"explainer", 1}]

      # Past Build without passing its gate, then back again: the first departure is over.
      verifying = move_to!(scope, shape, @verify)
      assert marked(verifying) == []
      assert marked(move_to!(scope, verifying, @shape)) == []
    end

    test "a move forward that stops at the stage does not end the rule", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      shape = move_to!(scope, work_item, @shape)
      explore = move_to!(scope, shape, @explore)

      # Explore to Shape is forward but stays before Build.
      assert marked(explore) == [{"explainer", 1}]
      assert marked(move_to!(scope, explore, @shape)) == [{"explainer", 1}]
    end

    test "a move forward, or a stage entered by a gate, leaves nothing to list", %{scope: scope} do
      work_item = at_shape_with_proposal!(scope)
      build = move_to!(scope, work_item, @build)
      add!(build, "explainer", "one.md")
      {:ok, verifying} = Stages.approve(scope, build, nil, expect_stage: @build)

      assert marked(verifying) == []
      assert Stages.inputs(verifying) == []
    end

    test "a departure of another take in is not read", %{scope: scope} do
      work_item = at_build!(scope)
      add!(work_item, "explainer", "one.md")
      shape = move_to!(scope, work_item, @shape)
      assert marked(shape) == [{"explainer", 1}]

      {1, _rows} =
        Repo.update_all(
          from(d in GateDecision, where: d.work_item_id == ^work_item.id and d.kind == :move),
          set: [take_in: shape.take_in + 1]
        )

      assert marked(shape) == []
    end

    test "a withdrawn name and a cancelled run's version are not listed", %{scope: scope} do
      work_item = at_build!(scope)
      run = live_run!(work_item)
      files = &if(&1 == "acceptance-criteria", do: criteria_files(), else: file("a.md"))
      push = &Stages.Artifacts.push({:run, &1}, work_item, &2, files.(&2), stage_id: @build)

      {:ok, _version} = push.(run, "explainer")
      {:ok, _version} = push.(run, "acceptance-criteria")

      {:ok, _withdrawal} =
        Artifacts.withdraw({:run, run}, work_item, "acceptance-criteria", stage_id: @build)

      cancelled = live_run!(work_item)
      {:ok, _version} = push.(cancelled, "explainer")
      cancel_run!(scope, cancelled)

      assert marked(move_to!(scope, work_item, @shape)) == [{"explainer", 1}]
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
               %{
                 id: nil,
                 kind: :answer,
                 stage_id: @explore,
                 user_id: ^user_id,
                 note: "The sale price"
               },
               %{id: nil, kind: :answer, note: "Yes"},
               %{
                 id: "es_" <> _escalation,
                 kind: :escalation,
                 stage_id: @explore,
                 user_id: ^user_id,
                 note: "Read the cart"
               },
               %{
                 id: "gd_" <> _request,
                 kind: :request_changes,
                 stage_id: @explore,
                 note: "Name the price rule",
                 artifact_version_id: ^proposal_id
               },
               %{id: "gd_" <> _move, kind: :move, stage_id: @explore, note: "Shaped enough"}
             ] = notes = Stages.notes(work_item)

      # Each id is the row's public id, in the shape `Apiary.PublicId` makes.
      for %{id: id} when is_binary(id) <- notes do
        [prefix, _random] = String.split(id, "_")
        assert Apiary.PublicId.valid?(prefix, id)
      end
    end

    # Explore, then Shape, Build and Verify, three stages with no workflow, each at a
    # person's gate.
    defp four_stages!(scope, explore_gate \\ %{"kind" => "person", "approvers" => "members"}) do
      save!(scope, [
        explore_stage(%{"gate" => explore_gate}),
        stage(@shape, "Shape", []),
        stage(@build, "Build", []),
        stage(@verify, "Verify", [])
      ])
    end

    defp texts(work_item), do: Enum.map(Stages.notes(work_item), & &1.note)

    # The work item approved at each stage before `stage_id`, at that stage's gate.
    defp approved_up_to!(scope, work_item, stage_id) do
      Enum.reduce_while([@explore, @shape, @build], work_item, fn at, work_item ->
        if at == stage_id do
          {:halt, work_item}
        else
          {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: at)
          {:cont, reload(work_item)}
        end
      end)
    end

    # A run of Explore that stopped: the stage escalates, `run_stopped`.
    defp stopped_run, do: %{exit_state: "failed", outcome_state: "failed"}

    test "Shape's request for changes is gone once Shape is approved again", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      work_item = approved_up_to!(scope, work_item, @verify)
      {:ok, _} = Stages.move(scope, work_item, @shape, "Back to Shape", expect_stage: @verify)

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Split the plan in two", nil,
          expect_stage: @shape
        )

      assert texts(work_item) == ["Back to Shape", "Split the plan in two"]

      # Shape's first approval came before both notes; its second closes both.
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      assert %{stage_id: @build} = reload(work_item)
      assert Stages.notes(work_item) == []
    end

    test "Verify's request for changes stays open until Verify is approved", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      work_item = approved_up_to!(scope, work_item, @verify)

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Show the refund", nil, expect_stage: @verify)

      {:ok, _} = Stages.move(scope, work_item, @build, "Fix the refund", expect_stage: @verify)

      assert [
               %{kind: :request_changes, stage_id: @verify, note: "Show the refund"},
               %{kind: :move, stage_id: @verify, note: "Fix the refund"}
             ] = Stages.notes(work_item)

      # Build's approval closes the move to Build; Verify's request stays.
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @build)

      assert %{stage_id: @verify, stage_state: :at_gate} = reload(work_item)
      assert texts(work_item) == ["Show the refund"]

      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @verify)
      assert Stages.notes(work_item) == []
    end

    test "an approval before a note leaves it open", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Name the price rule", nil,
          expect_stage: @explore
        )

      work_item = end_run!(work_item, understood_result())
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)
      {:ok, _} = Stages.move(scope, work_item, @explore, "Read the cart", expect_stage: @shape)
      work_item = end_run!(work_item, understood_result())

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Keep the coupon", nil, expect_stage: @explore)

      # The approval came before the move and the second request: it closes only the
      # first request.
      assert texts(work_item) == ["Read the cart", "Keep the coupon"]
    end

    test "a note that a finished run already read stays open until its stage is approved",
         %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Name the price rule", nil,
          expect_stage: @explore
        )

      # The next run of Explore reads the note and ends; the note is still listed for the
      # run after it.
      work_item = end_run!(work_item, understood_result())
      assert texts(work_item) == ["Name the price rule"]

      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)
      assert Stages.notes(work_item) == []
    end

    test "a note that an approval closed stays closed when a newer output reopens the stage",
         %{scope: scope} do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "spec",
          "base_view" => "document"
        })

      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{"outputs" => [%{"type" => "spec", "required" => false}]})
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)
      work_item = reload(work_item)

      spec = fn text ->
        [%{filename: "spec.md", content_type: "text/markdown", binary: text}]
      end

      stage_version!(work_item, "spec", spec.("## The spec"), @shape)

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Split the plan in two", nil,
          expect_stage: @shape
        )

      assert texts(work_item) == ["Split the plan in two"]

      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert Stages.notes(work_item) == []
      assert Stages.status(work_item).state == :done

      # A newer version of Shape's output, the last stage's, reopens Shape's gate; the
      # closed note stays out.
      stage_version!(work_item, "spec", spec.("## The new spec"), @shape)

      assert [_first, _second] = versions(work_item, "spec")
      assert Stages.status(work_item).state == :at_gate
      assert Stages.notes(work_item) == []
    end

    test "a move closes when the stage it went to is approved, not the one it left",
         %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)
      {:ok, _} = Stages.move(scope, work_item, @explore, "Read the cart", expect_stage: @shape)

      assert [%GateDecision{kind: :move, stage_id: @shape, to_stage_id: @explore}] =
               Enum.filter(decisions(work_item), &(&1.kind == :move))

      work_item = end_run!(work_item, understood_result())
      assert [%{kind: :move, stage_id: @shape, note: "Read the cart"}] = Stages.notes(work_item)

      # Shape, the stage it left, is not approved again: Explore's approval closes it.
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)

      assert %{stage_id: @shape, stage_state: :at_gate} = reload(work_item)
      assert Stages.notes(work_item) == []
    end

    test "an escalation's note closes when its stage is approved", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(nil, stopped_run())

      {:ok, _} =
        Stages.resolve_escalation(scope, work_item, :another_round, "Read the cart",
          expect_stage: @explore
        )

      work_item = end_run!(work_item, understood_result())
      assert [%{kind: :escalation, stage_id: @explore}] = Stages.notes(work_item)

      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)
      assert Stages.notes(work_item) == []
    end

    test "the automatic approval of a gate none closes the notes of its stage", %{
      scope: scope
    } do
      four_stages!(scope, %{"kind" => "none"})
      work_item = take_in!(scope) |> end_run!(nil, stopped_run())

      {:ok, _} =
        Stages.resolve_escalation(scope, work_item, :another_round, "Read the cart",
          expect_stage: @explore
        )

      assert texts(work_item) == ["Read the cart"]
      work_item = end_run!(work_item, understood_result())

      assert %{stage_id: @shape} = reload(work_item)

      assert [%GateDecision{kind: :approve, automatic: true, stage_id: @explore, user_id: nil}] =
               decisions(work_item)

      assert Stages.notes(work_item) == []
    end

    test "a move closes when the stage it went to is approved automatically", %{scope: scope} do
      four_stages!(scope, %{"kind" => "none"})
      work_item = take_in!(scope) |> end_run!(understood_result())
      assert %{stage_id: @shape} = reload(work_item)

      {:ok, _} = Stages.move(scope, work_item, @explore, "Read the cart", expect_stage: @shape)
      assert texts(work_item) == ["Read the cart"]

      work_item = end_run!(work_item, understood_result())

      assert %{stage_id: @shape, stage_state: :at_gate} = reload(work_item)
      assert Stages.notes(work_item) == []
    end

    test "an answer closes when its stage is approved after it", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(questions_result())
      {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The sale price", "2" => "Yes"})
      work_item = end_run!(work_item, understood_result())

      assert [%{kind: :answer, stage_id: @explore}, %{kind: :answer}] = Stages.notes(work_item)
      assert texts(work_item) == ["The sale price", "Yes"]

      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @explore)

      assert %{stage_id: @shape} = reload(work_item)
      assert Stages.notes(work_item) == []
    end

    test "a move that resolves an open escalation is one note, the move's", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(nil, stopped_run())
      assert %Escalation{cause: :run_stopped} = escalation(work_item)

      {:ok, _} = Stages.move(scope, work_item, @shape, "Shaped enough", expect_stage: @explore)

      assert %Escalation{resolution: :move_back, note: nil} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert [%{kind: :move, stage_id: @explore, note: "Shaped enough"}] =
               Stages.notes(work_item)

      # The move closes once Shape, the stage it went to, is approved.
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert Stages.notes(work_item) == []
    end

    test "open notes of several stages are listed together, oldest first", %{scope: scope} do
      four_stages!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Name the price rule", nil,
          expect_stage: @explore
        )

      work_item = end_run!(work_item, understood_result())
      {:ok, _} = Stages.move(scope, work_item, @shape, "Shaped enough", expect_stage: @explore)

      {:ok, _} =
        Stages.request_changes(scope, work_item, "Split the plan in two", nil,
          expect_stage: @shape
        )

      assert [
               %{kind: :request_changes, stage_id: @explore},
               %{kind: :move, stage_id: @explore},
               %{kind: :request_changes, stage_id: @shape}
             ] = Stages.notes(work_item)

      # Shape's approval closes the move to Shape and Shape's request; Explore's request
      # stays open, as Explore is not approved after it.
      {:ok, _} = Stages.approve(scope, work_item, nil, expect_stage: @shape)

      assert %{stage_id: @build} = reload(work_item)
      assert texts(work_item) == ["Name the price rule"]
    end
  end

  describe "escalations" do
    # A run whose registered run exited failed: the stage escalates, `run_stopped`.
    setup %{scope: scope} do
      work_item =
        take_in!(scope) |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      %{work_item: work_item}
    end

    test "another round reruns the workflow, with the note", %{
      scope: scope,
      work_item: work_item
    } do
      # Explore has no loop: the workflow runs again in the same round.
      assert {:ok, %WorkItem{stage_state: :running, stage_round: 1}} =
               Stages.resolve_escalation(scope, work_item, :another_round, "Read the sale page",
                 expect_stage: reload(work_item).stage_id
               )

      assert %DispatchRun{attempt: 2, round: 1} = newest_run(work_item)

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
      assert %{stage_state: :running, stage_round: 1} = reload(work_item)

      assert %Escalation{resolution: :another_round} =
               Repo.get_by(Escalation, work_item_id: work_item.id)
    end

    test "accept is refused while a required output is missing, and writes nothing", %{
      scope: scope,
      work_item: work_item
    } do
      # The failed run pushed no proposal, which Explore requires.
      assert Stages.missing_outputs(work_item) == ["proposal"]
      assert Stages.starts(work_item, :accept) == :none

      assert Stages.resolve_escalation(scope, work_item, :accept, nil,
               expect_stage: reload(work_item).stage_id
             ) == {:error, :invalid}

      assert %Escalation{cause: :run_stopped, resolution: nil} = escalation(work_item)
      assert %WorkItem{stage_state: :escalated} = reload(work_item)
      assert runs(work_item) |> length() == 1

      refute Repo.exists?(
               from e in Entry,
                 where: e.action == "gate.approve" and e.subject_id == ^work_item.id
             )
    end

    test "accept counts the run as passed and opens the gate, with every required output", %{
      scope: scope
    } do
      work_item =
        take_in!(scope)
        |> end_run!(understood_result(), %{exit_state: "failed", outcome_state: "failed"})

      assert %Escalation{cause: :run_stopped} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate, stage_round: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert %Escalation{resolution: :accept} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert escalation(work_item) == nil
      assert runs(work_item) |> length() == 1
      assert [%{type: "proposal", check: :passed}] = Stages.status(work_item).outputs
    end

    test "accept at the end of the sequence opens the gate", %{scope: scope} do
      save!(scope, [
        explore_stage(%{
          "sequence" => [
            %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "explore-a-ticket"}]}}
          ]
        })
      ])

      # A run that pushed the proposal and no verdict in the loop's last round.
      work_item = take_in!(scope) |> end_run!(proposal_only())
      assert %Escalation{cause: :round_limit} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert escalation(work_item) == nil
      assert [%{check: :passed}] = Stages.status(work_item).outputs
    end

    test "close ends the work item", %{scope: scope, work_item: work_item} do
      assert {:ok, %WorkItem{state: :closed}} =
               Stages.resolve_escalation(scope, work_item, :close, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert %Escalation{resolution: :close} = Repo.get_by(Escalation, work_item_id: work_item.id)
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
        |> as_placed!(stage_state: :escalated, stage_round: 1, stage_entry: 0, loop_entry: nil)

      assert %{state: :escalated, escalation: %{cause: :run_stopped, round: 1}} =
               Stages.status(work_item)

      assert {:ok, %WorkItem{stage_state: :running, stage_round: 1}} =
               Stages.resolve_escalation(scope, work_item, :another_round, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert %Escalation{resolution: :another_round} =
               Repo.get_by(Escalation, work_item_id: work_item.id)

      assert %DispatchRun{attempt: 2, round: 1, stage_id: @explore} = newest_run(work_item)
    end

    test "an escalated work item explores again", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(nil)
        |> as_placed!(stage_state: :escalated, stage_round: 1, stage_entry: 0, loop_entry: nil)

      assert {:ok, _work_item} = WorkItems.explore_again(scope, work_item, 1)
      assert %DispatchRun{attempt: 2, round: 1} = newest_run(work_item)
    end

    test "a work item waiting for answers runs again", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(questions_result())
        |> as_placed!(
          stage_state: :waiting_answers,
          stage_round: 1,
          stage_entry: 0,
          loop_entry: nil
        )

      assert {:ok, _work_item} = WorkItems.answer(scope, work_item, 1, %{"1" => "a", "2" => "b"})

      assert %DispatchRun{attempt: 2, round: 1, workflow: "explore-a-ticket"} =
               newest_run(work_item)
    end

    test "a confirmed work item at Shape's gate moves on when approved", %{scope: scope} do
      work_item =
        take_in!(scope)
        |> end_run!(understood_result())

      {:ok, _work_item} = Moves.confirm(scope, work_item, 1)

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

      work_item =
        take_in!(scope) |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      assert reload(work_item).stage_state == :escalated

      assert WorkItems.explore_again(member.scope, work_item, 1) == {:error, :not_approver}
      assert %Escalation{resolution: nil} = escalation(work_item)

      assert {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
      assert %{stage_state: :running, stage_round: 1} = reload(work_item)

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

    test "Explore again on an escalated stage with no escalation stored needs a listed approver",
         %{scope: scope} do
      member = member_fixture(scope)

      save!(scope, [
        explore_stage(%{
          "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}}
        })
      ])

      work_item =
        take_in!(scope) |> end_run!(nil, %{exit_state: "failed", outcome_state: "failed"})

      # As the migration placed it: escalated, with no escalation stored.
      Repo.delete_all(from e in Escalation, where: e.work_item_id == ^work_item.id)
      assert reload(work_item).stage_state == :escalated

      assert WorkItems.explore_again(member.scope, work_item, 1) == {:error, :not_approver}
      assert %{stage_state: :escalated} = reload(work_item)
      assert Repo.all(from e in Escalation, where: e.work_item_id == ^work_item.id) == []

      assert {:ok, _} = WorkItems.explore_again(scope, work_item, 1)
      assert %{stage_state: :running} = reload(work_item)
      user_id = scope.user.id

      assert %Escalation{resolution: :another_round, resolved_by_id: ^user_id} =
               Repo.get_by(Escalation, work_item_id: work_item.id)
    end

    test "an answer to the last run a placed work item may have runs again", %{
      scope: scope
    } do
      work_item = take_in!(scope)
      run = newest_run(work_item)

      # As the migration placed it: waiting for answers to the last run of the take in.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [of: 1])

      work_item = end_run!(work_item, questions_result())
      assert work_item.stage_state == :waiting_answers

      assert {:ok, _work_item} =
               WorkItems.answer(scope, reload(work_item), 1, %{"1" => "Main", "2" => "Spring"})

      assert %{stage_state: :running} = reload(work_item)
      assert %DispatchRun{attempt: 2} = newest_run(work_item)
      refute escalation(work_item)
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

  describe "the return from Verify to Build (choice 10)" do
    @verify "st_m1mqbeywdg"
    @findings [
      %{"text" => "Criterion 2 is not met: the export has no PDF.", "action" => "run_again"}
    ]

    # Build: `first` before a loop of implement-changes and review-changes, gate none.
    # Verify: verify-a-ticket, which returns to Build on changes-requested, at most 2 times.
    defp returning!(scope, first \\ []) do
      loop = %{
        "loop" => %{
          "rounds" => 3,
          "body" => [%{"workflow" => "implement-changes"}, %{"workflow" => "review-changes"}]
        }
      }

      save!(scope, [
        stage(@build, "Build", first ++ [loop], %{"gate" => %{"kind" => "none"}}),
        stage(@verify, "Verify", [
          %{"workflow" => "verify-a-ticket", "return" => %{"stage" => @build, "limit" => 2}}
        ])
      ])
    end

    # Build's loop passes on its first run, and Verify's run starts.
    defp through_build!(work_item) do
      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
      work_item
    end

    defp returned(work_item),
      do:
        Repo.all(
          from d in DispatchRun,
            where: d.work_item_id == ^work_item.id and not is_nil(d.returned_to),
            select: d.returned_to
        )

    test "a first and a second return start Build's loop; a third escalates", %{scope: scope} do
      returning!(scope)
      work_item = take_in!(scope) |> through_build!()

      for count <- 1..2 do
        work_item = end_run!(work_item, verdict("changes-requested", @findings))

        assert %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 0, loop_entry: 0} =
                 work_item

        assert %DispatchRun{workflow: "implement-changes", stage_id: @build, round: 1} =
                 newest_run(work_item)

        assert returned(work_item) == List.duplicate(@build, count)
        refute escalation(work_item)
        through_build!(work_item)
      end

      work_item = end_run!(reload(work_item), verdict("changes-requested", @findings))
      assert %WorkItem{stage_id: @verify, stage_state: :escalated} = work_item
      assert returned(work_item) == [@build, @build]

      assert %Escalation{cause: :return_limit, stage_id: @verify, points: points} =
               escalation(work_item)

      assert points == [
               %{
                 "text" =>
                   "Pick Move back to return the work item to Build once more, or pick Accept as it is.",
                 "action" => "run_again",
                 "fix" =>
                   "Verify's run asked for changes again after 2 returns to Build, the most that Verify allows.",
                 "without_accept" => %{
                   "text" => "Pick Move back to return the work item to Build once more."
                 }
               }
               | @findings
             ]

      assert %{escalation: %{cause: :return_limit, points: ^points}} =
               Stages.status(reload(work_item), scope)
    end

    test "a return from Verify's run with no member's note starts Build at triage-review", %{
      scope: scope
    } do
      returning!(scope, [%{"workflow" => "triage-review", "when" => %{"feedback" => "new"}}])

      # No feedback at the take in: triage-review is passed over.
      work_item = take_in!(scope)
      assert %DispatchRun{workflow: "implement-changes"} = newest_run(work_item)
      work_item = through_build!(work_item)

      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert Stages.notes(work_item) == []
      assert %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 0} = work_item

      assert %DispatchRun{workflow: "triage-review", stage_id: @build, round: 1} =
               newest_run(work_item)

      # triage-review passes and handles the return: Build goes on to its loop.
      work_item = end_run!(work_item, verdict("passed"))
      assert %DispatchRun{workflow: "implement-changes", stage_id: @build} = newest_run(work_item)
    end

    test "Request changes with a note at Verify's gate returns to Build, whose triage-review reads the note",
         %{scope: scope} do
      feedback = %{"workflow" => "triage-review", "when" => %{"feedback" => "new"}}

      loop = %{
        "loop" => %{
          "rounds" => 3,
          "body" => [%{"workflow" => "implement-changes"}, %{"workflow" => "review-changes"}]
        }
      }

      save!(scope, [
        stage(@build, "Build", [feedback, loop], %{"gate" => %{"kind" => "none"}}),
        stage(@verify, "Verify", [
          feedback,
          %{"workflow" => "verify-a-ticket", "return" => %{"stage" => @build, "limit" => 2}}
        ])
      ])

      work_item = take_in!(scope) |> through_build!() |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      # With a note too, Request changes at Verify's gate returns the work item to Build.
      assert Stages.starts(work_item, :request_changes, true) == {:run, "triage-review"}

      assert {:ok, %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 0}} =
               Stages.request_changes(scope, work_item, "Drop the CSV option.", nil,
                 expect_stage: @verify
               )

      assert %DispatchRun{workflow: "triage-review", stage_id: @build, round: 1} =
               newest_run(work_item)

      assert [%{kind: :request_changes, note: "Drop the CSV option."}] =
               Stages.notes(reload(work_item))
    end

    test "a person's Request changes starts Build's first entry and counts no return", %{
      scope: scope
    } do
      returning!(scope, [%{"workflow" => "triage-review"}])
      work_item = take_in!(scope) |> end_run!(verdict("passed")) |> through_build!()
      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      assert Stages.starts(work_item, :request_changes, true) == {:run, "triage-review"}

      assert {:ok, %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 0}} =
               Stages.request_changes(scope, work_item, "Drop the CSV option.", nil,
                 expect_stage: @verify
               )

      assert %DispatchRun{workflow: "triage-review", stage_id: @build} = newest_run(work_item)
      assert returned(work_item) == []

      assert [%GateDecision{kind: :request_changes, stage_id: @verify}] =
               Enum.filter(decisions(work_item), &(&1.kind == :request_changes))

      # Two returns of Verify's run still follow before the limit.
      work_item = reload(work_item)

      for count <- 1..2 do
        work_item = work_item |> end_run!(verdict("passed")) |> through_build!()
        work_item = end_run!(work_item, verdict("changes-requested", @findings))
        assert %WorkItem{stage_id: @build, stage_entry: 0} = work_item
        assert %DispatchRun{workflow: "triage-review"} = newest_run(work_item)
        assert length(returned(work_item)) == count
      end

      work_item = reload(work_item) |> end_run!(verdict("passed")) |> through_build!()
      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert %Escalation{cause: :return_limit} = escalation(work_item)
    end

    test "at the limit, Move back returns once more and the next changes escalate again", %{
      scope: scope
    } do
      returning!(scope)
      work_item = take_in!(scope) |> through_build!()

      work_item =
        Enum.reduce(1..2, work_item, fn _count, work_item ->
          work_item
          |> end_run!(verdict("changes-requested", @findings))
          |> through_build!()
        end)

      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert %Escalation{cause: :return_limit} = escalation(work_item)

      assert {:ok, %WorkItem{stage_id: @build, stage_entry: 0}} =
               Stages.resolve_escalation(scope, work_item, {:move_back, @build}, nil,
                 expect_stage: @verify
               )

      work_item = reload(work_item) |> through_build!()
      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert %WorkItem{stage_id: @verify, stage_state: :escalated} = work_item
      assert %Escalation{cause: :return_limit} = escalation(work_item)
      assert length(returned(work_item)) == 2
    end

    test "a take in again counts its returns from none", %{scope: scope} do
      returning!(scope)
      work_item = take_in!(scope) |> through_build!()

      work_item =
        Enum.reduce(1..2, work_item, fn _count, work_item ->
          work_item
          |> end_run!(verdict("changes-requested", @findings))
          |> through_build!()
        end)

      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert %Escalation{cause: :return_limit} = escalation(work_item)

      {:ok, _closed} =
        Stages.resolve_escalation(scope, work_item, :close, nil, expect_stage: @verify)

      item = Repo.get!(Apiary.Sources.Item, work_item.item_id)

      {:ok, _again} =
        WorkItems.take_in_again(scope, item.public_id, %{owner_id: scope.user.id})

      assert %WorkItem{take_in: 2, stage_id: @build} = work_item = reload(work_item)

      # Take in 1's two returns do not count: the changes return the work item to Build.
      work_item = work_item |> through_build!() |> end_run!(verdict("changes-requested"))
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
      assert length(returned(work_item)) == 3
    end

    test "the returns count by stage, after a version that moves the entry", %{scope: scope} do
      returning!(scope)
      work_item = take_in!(scope) |> through_build!()

      work_item =
        work_item
        |> end_run!(verdict("changes-requested", @findings))
        |> through_build!()
        |> end_run!(verdict("changes-requested", @findings))

      assert %WorkItem{stage_id: @build} = work_item
      assert returned(work_item) == [@build, @build]

      # Version 2 keeps Build and puts check-a-ticket before verify-a-ticket, whose entry
      # is then 1, not 0.
      %{document: %{"stages" => [build, verify]}} = Processes.current(scope.workspace)
      [entry] = verify["sequence"]

      version =
        save!(scope, [
          build,
          %{verify | "sequence" => [%{"workflow" => "check-a-ticket"}, entry]}
        ])

      {:ok, work_item} = Processes.assign(scope, work_item, version)

      work_item = end_run!(reload(work_item), verdict("passed"))
      assert %WorkItem{stage_id: @verify, process_version_id: version_id} = work_item
      assert version_id == version.id
      assert %DispatchRun{workflow: "check-a-ticket"} = newest_run(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)

      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert %WorkItem{stage_id: @verify, stage_state: :escalated, stage_entry: 1} = work_item
      assert %Escalation{cause: :return_limit} = escalation(work_item)
    end

    test "a cancelled run with changes requested returns nothing and counts no return", %{
      scope: scope
    } do
      returning!(scope)
      work_item = take_in!(scope) |> through_build!()

      cancelled = fn run, registered ->
        verdict("changes-requested", @findings).(run, registered)

        {1, _rows} =
          Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^registered.id),
            set: [cancel_requested_at: DateTime.utc_now(), cancel_requested_by_id: scope.user.id]
          )
      end

      work_item = end_run!(work_item, cancelled)
      assert %WorkItem{stage_id: @verify, stage_state: :escalated} = work_item
      assert %Escalation{cause: :run_stopped} = escalation(work_item)
      assert returned(work_item) == []
    end

    test "accept at the limit opens Verify's gate", %{scope: scope} do
      returning!(scope)
      work_item = take_in!(scope) |> through_build!()

      work_item =
        Enum.reduce(1..2, work_item, fn _count, work_item ->
          work_item
          |> end_run!(verdict("changes-requested", @findings))
          |> through_build!()
        end)

      work_item = end_run!(work_item, verdict("changes-requested", @findings))

      assert {:ok, %WorkItem{stage_id: @verify, stage_state: :at_gate}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @verify)
    end

    test "a save with a return to a stage that is not earlier, in a loop, or over 10 fails" do
      document = &%{"schema" => "qory.process/v1", "stages" => &1}
      returning = &%{"workflow" => "check", "return" => Map.merge(%{"stage" => &1}, &2)}

      assert Processes.validate(
               document.([
                 stage(@build, "Build", []),
                 stage(@verify, "Verify", [returning.(@build, %{})])
               ])
             ) == :ok

      assert {:error, [%{path: "#/stages/0/sequence/0/return/stage", error: :return_not_earlier}]} =
               Processes.validate(
                 document.([
                   stage(@build, "Build", [returning.(@verify, %{})]),
                   stage(@verify, "Verify", [])
                 ])
               )

      assert {:error, [%{path: "#/stages/1/sequence/0/return/stage", error: :return_not_earlier}]} =
               Processes.validate(
                 document.([
                   stage(@build, "Build", []),
                   stage(@verify, "Verify", [returning.(@verify, %{})])
                 ])
               )

      in_loop = %{"loop" => %{"rounds" => 2, "body" => [returning.(@build, %{})]}}

      assert {:error, [_ | _] = errors} =
               Processes.validate(
                 document.([stage(@build, "Build", []), stage(@verify, "Verify", [in_loop])])
               )

      assert Enum.all?(errors, &(&1.error == :schema))

      assert {:error, [_ | _] = errors} =
               Processes.validate(
                 document.([
                   stage(@build, "Build", []),
                   stage(@verify, "Verify", [returning.(@build, %{"limit" => 11})])
                 ])
               )

      assert Enum.all?(errors, &(&1.error == :schema))
    end
  end

  describe "the findings of a return reach Build as inputs" do
    @verify "st_m1mqbeywdg"
    @findings [%{"text" => "The export has no PDF.", "action" => "run_again"}]

    # Build: a loop of implement-changes and review-changes, gate none. Verify: one run that
    # returns to Build on changes-requested, at most 5 times.
    defp loop_process!(scope) do
      loop = %{
        "loop" => %{
          "rounds" => 3,
          "body" => [%{"workflow" => "implement-changes"}, %{"workflow" => "review-changes"}]
        }
      }

      save!(scope, [
        stage(@build, "Build", [loop], %{"gate" => %{"kind" => "none"}}),
        stage(@verify, "Verify", [
          %{"workflow" => "verify-a-ticket", "return" => %{"stage" => @build, "limit" => 5}}
        ])
      ])
    end

    # The one file of a verification whose matrix has one row, with `evidence`.
    defp checked(type \\ "verification", evidence),
      do:
        json_file(
          type,
          verification_document(%{
            "matrix" => [%{"criterion" => "ac-1", "state" => "not_met", "evidence" => evidence}]
          })
        )

    # What Verify's run pushes: a verification (unless `nil`), then its verdict.
    defp verifying(verdict, verification) do
      fn run, registered ->
        if verification do
          {:ok, _version} =
            Artifacts.push(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              "verification",
              [checked(verification)],
              name: "main",
              stage_id: run.stage_id
            )
        end

        verdict(verdict, @findings).(run, registered)
      end
    end

    defp in_verify!(scope) do
      loop_process!(scope)
      work_item = take_in!(scope) |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
      work_item
    end

    # Build's gate passes again and Verify's run starts.
    defp in_verify_again!(work_item) do
      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
      work_item
    end

    defp returned_by(work_item, verification) do
      work_item = end_run!(work_item, verifying("changes-requested", verification))
      assert %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 0} = work_item
      work_item
    end

    defp from_return(work_item) do
      for %{from: :return, type: type, required: false, version: %{id: id}} <-
            Stages.inputs(work_item),
          do: {type, id}
    end

    # A decision of a person at `stage_id`, recorded now.
    defp decide!(work_item, kind, stage_id) do
      Repo.insert!(%GateDecision{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: work_item.process_version_id,
        stage_id: stage_id,
        kind: kind,
        take_in: work_item.take_in,
        inserted_at: DateTime.utc_now()
      })
    end

    defp newest_id(work_item, type) do
      work_item |> versions(type) |> Enum.max_by(& &1.number) |> Map.fetch!(:public_id)
    end

    test "each run of Build after a return lists the newest verdict and verification",
         %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")

      verdict = newest_id(work_item, "verdict")
      verification = newest_id(work_item, "verification")

      assert [
               %{type: "verdict", required: false, from: :return, version: %{id: ^verdict}},
               %{
                 type: "verification",
                 required: false,
                 from: :return,
                 version: %{id: ^verification}
               }
             ] = Stages.inputs(work_item)

      # The loop's next run of the entry still lists them.
      work_item = end_run!(work_item, verdict("changes-requested", @findings))
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
      assert from_return(work_item) == [{"verdict", verdict}, {"verification", verification}]

      # The findings are no person's note.
      assert Stages.notes(work_item) == []
    end

    test "after Build's gate passes, a later run lists none", %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")
      assert [_verdict, _verification] = from_return(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
      assert from_return(work_item) == []

      # A second return of Verify's run lists them again.
      returned = end_run!(work_item, verifying("changes-requested", "# Again"))
      assert %WorkItem{stage_id: @build} = returned
      assert [_verdict, _verification] = from_return(returned)
    end

    test "a work item moved to Build by a person lists none through a return", %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")
      work_item = end_run!(work_item, verdict("passed"))
      assert from_return(work_item) == []

      {:ok, moved} =
        Stages.move(scope, work_item, @build, nil, expect_stage: @verify)

      assert %WorkItem{stage_id: @build} = moved
      assert from_return(moved) == []
    end

    test "with no verification, only the verdict is listed", %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by(nil)
      verdict = newest_id(work_item, "verdict")

      assert [%{type: "verdict", from: :return, version: %{id: ^verdict}}] =
               Enum.filter(Stages.inputs(work_item), &(&1[:from] == :return))
    end

    test "an approval lists no version through the return", %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")
      assert [_verdict, _verification] = from_return(work_item)

      work_item = end_run!(work_item, verdict("passed"))

      # Build's gate `none` approved twice, with the versions of Build's outputs: none.
      assert [[], []] = for(d <- decisions(work_item), d.stage_id == @build, do: d.versions)

      for type <- ["verdict", "verification"] do
        assert [%{approved_version: nil, versions: versions}] =
                 Enum.filter(Stages.artifact_index(work_item), &(&1.type == type))

        assert Enum.all?(versions, &(&1.approvals == []))
      end
    end

    test "a second return lists the newer versions", %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# First")
      first = from_return(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      work_item = returned_by(work_item, "# Second")
      second = from_return(work_item)

      assert [{"verdict", verdict}, {"verification", verification}] = second
      assert verdict == newest_id(work_item, "verdict")
      assert verification == newest_id(work_item, "verification")
      assert second != first
      assert length(versions(work_item, "verification")) == 2
    end

    test "a Request changes at Build's gate, and a decision in another stage, end nothing",
         %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")
      listed = from_return(work_item)
      assert [_verdict, _verification] = listed

      decide!(work_item, :request_changes, @build)
      assert from_return(work_item) == listed

      decide!(work_item, :approve, @verify)
      decide!(work_item, :move, @verify)
      assert from_return(work_item) == listed
    end

    test "an approval of Build, and a move out of Build, end them", %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")
      assert [_verdict, _verification] = from_return(work_item)

      decide!(work_item, :approve, @build)
      assert from_return(work_item) == []

      # A second return lists the newer versions again, and a move out of Build ends them.
      work_item = in_verify_again!(work_item) |> returned_by("# Second")
      assert [_verdict, _verification] = from_return(work_item)

      decide!(work_item, :move, @build)
      assert from_return(work_item) == []
    end

    test "a later update of the returning run does not change the listed inputs",
         %{scope: scope} do
      work_item = in_verify!(scope) |> returned_by("# Criterion 2 fails")
      listed = from_return(work_item)
      assert [_verdict, _verification] = listed

      run =
        Repo.one!(
          from d in DispatchRun,
            where: d.work_item_id == ^work_item.id and d.returned_to == ^@build
        )

      assert %DateTime{} = run.returned_at

      # The run is written again, long before and long after its return.
      for shift <- [-3600, 3600] do
        {1, _rows} =
          Repo.update_all(from(d in DispatchRun, where: d.id == ^run.id),
            set: [updated_at: DateTime.add(DateTime.utc_now(), shift, :second)]
          )

        assert from_return(work_item) == listed
      end

      # Build's approval still ends them, whatever the run's last write.
      decide!(work_item, :approve, @build)
      assert from_return(work_item) == []
    end

    # Build reads `inputs` and Verify makes a verdict and a verification, the two types that
    # a return lists. `first` is a stage before Build (gate none), or nil for none.
    defp ordered_process!(scope, first, inputs) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "brief",
          "base_view" => "document"
        })

      loop = %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "implement-changes"}]}}

      verify =
        stage(
          @verify,
          "Verify",
          [%{"workflow" => "verify-a-ticket", "return" => %{"stage" => @build, "limit" => 5}}],
          %{
            "outputs" => [
              %{"type" => "verdict", "required" => false},
              %{"type" => "verification", "required" => false}
            ]
          }
        )

      before_build =
        if first, do: [stage(@explore, "Explore", [], %{"gate" => %{"kind" => "none"}})], else: []

      save!(
        scope,
        before_build ++
          [
            stage(@build, "Build", [loop], %{"gate" => %{"kind" => "none"}, "inputs" => inputs}),
            verify
          ]
      )
    end

    # What Verify's run pushes when it passes: a verification, then a `passed` verdict.
    defp passing(verification) do
      fn run, registered ->
        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            "verification",
            [checked(verification)],
            name: "main",
            stage_id: run.stage_id
          )

        verdict("passed").(run, registered)
      end
    end

    defp typed(work_item),
      do: for(input <- Stages.inputs(work_item), do: {input.type, Map.get(input, :from)})

    test "the inputs list read, then moved, then returned, each version once", %{scope: scope} do
      ordered_process!(scope, false, [%{"type" => "brief", "required" => false}])
      work_item = take_in!(scope)
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item

      # Verify's first run ends passed, and a person moves the work item back to Build.
      work_item = end_run!(work_item, verdict("passed"))
      work_item = end_run!(work_item, passing("# First"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
      first = %{verdict: newest_id(work_item, "verdict"), v: newest_id(work_item, "verification")}

      {:ok, _moved} = Stages.move(scope, work_item, @build, nil, expect_stage: @verify)
      work_item = reload(work_item) |> through_build!() |> returned_by("# Second")

      second = %{
        verdict: newest_id(work_item, "verdict"),
        v: newest_id(work_item, "verification")
      }

      assert typed(work_item) == [
               {"brief", nil},
               {"verdict", :move},
               {"verification", :move},
               {"verdict", :return},
               {"verification", :return}
             ]

      # The brief has no version; each of the others is listed once.
      ids = for %{version: %{id: id}} <- Stages.inputs(work_item), do: id
      assert length(Enum.uniq(ids)) == 4
      assert ids == [first.verdict, first.v, second.verdict, second.v]
    end

    test "a version that Build already reads is listed once, from the read", %{scope: scope} do
      ordered_process!(scope, true, [%{"type" => "verification", "required" => false}])
      work_item = take_in!(scope)
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
      work_item = work_item |> in_verify_again!() |> returned_by("# Criterion 2 fails")
      verification = newest_id(work_item, "verification")
      verdict = newest_id(work_item, "verdict")

      # Explore's gate approved the verification, so Build reads it.
      Repo.insert!(%GateDecision{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: work_item.process_version_id,
        stage_id: @explore,
        kind: :approve,
        versions: [verification],
        take_in: work_item.take_in,
        inserted_at: DateTime.utc_now()
      })

      assert [
               %{type: "verification", version: %{id: ^verification}} = read,
               %{type: "verdict", from: :return, version: %{id: ^verdict}}
             ] = Stages.inputs(work_item)

      refute Map.has_key?(read, :from)
    end

    test "a verification that a move back already lists is not listed again by a return",
         %{scope: scope} do
      ordered_process!(scope, false, [])
      work_item = take_in!(scope)
      work_item = end_run!(work_item, verdict("passed"))
      work_item = end_run!(work_item, passing("# First"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
      first = newest_id(work_item, "verification")

      # A person moves the work item back to Build; Verify's second run makes no
      # verification, so its newest one is still the first.
      {:ok, _moved} = Stages.move(scope, work_item, @build, nil, expect_stage: @verify)
      work_item = reload(work_item) |> through_build!() |> returned_by(nil)
      assert length(versions(work_item, "verification")) == 1
      assert newest_id(work_item, "verification") == first

      assert typed(work_item) == [
               {"verdict", :move},
               {"verification", :move},
               {"verdict", :return}
             ]

      assert [^first] =
               for(
                 %{type: "verification", version: %{id: id}} <- Stages.inputs(work_item),
                 do: id
               )
    end
  end

  describe "accepted_findings/2" do
    test "is the points of the verdict a member accepted at the round limit, in this take in",
         %{scope: scope} do
      review = %{"loop" => %{"rounds" => 1, "body" => [%{"workflow" => "review-changes"}]}}

      save!(scope, [
        stage(@build, "Build", [review], %{"gate" => %{"kind" => "none"}}),
        stage(@verify, "Verify", [%{"workflow" => "verify-a-ticket"}])
      ])

      findings = ["The total skips the voucher.", "The receipt shows no voucher line."]

      work_item =
        take_in!(scope)
        |> end_run!(verdict("changes-requested", Enum.map(findings, &again/1)))

      assert %Escalation{cause: :round_limit} = escalation(work_item)
      assert Stages.accepted_findings(reload(work_item), [@build]) == []

      assert {:ok, %WorkItem{stage_id: @verify}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @build)

      user_id = scope.user.id

      assert [%{stage_id: @build, by: ^user_id, at: %DateTime{}, findings: ^findings}] =
               Stages.accepted_findings(reload(work_item), [@build])

      # Only the stages asked for, and only the current take in.
      assert Stages.accepted_findings(reload(work_item), [@verify]) == []

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
          set: [taken_in_at: DateTime.add(DateTime.utc_now(), 60, :second)]
        )

      assert Stages.accepted_findings(reload(work_item), [@build]) == []
    end

    test "is the points of the last round's verdict, at a limit of 2 rounds", %{scope: scope} do
      review = %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => "review-changes"}]}}

      save!(scope, [
        stage(@build, "Build", [review], %{"gate" => %{"kind" => "none"}}),
        stage(@verify, "Verify", [%{"workflow" => "verify-a-ticket"}])
      ])

      work_item =
        take_in!(scope)
        |> end_run!(verdict("changes-requested", [again("Round 1 finding.")]))

      assert %WorkItem{stage_round: 2} = work_item
      work_item = end_run!(work_item, verdict("changes-requested", [again("Round 2 finding.")]))
      assert %Escalation{cause: :round_limit, round: 2} = escalation(work_item)

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @build)

      assert [%{findings: ["Round 2 finding."]}] =
               Stages.accepted_findings(reload(work_item), [@build])
    end

    test "reads the verdict of the escalation's run that reached the limit", %{scope: scope} do
      work_item = take_in!(scope)
      since = reload(work_item).taken_in_at

      # One run pushes a verdict each round, as a shared run does: the newest before the
      # escalation is the one that reached the limit, and a later one is not read.
      shared = live_run!(work_item)
      push_verdict!(shared, "changes-requested", ["Round 1 finding."])
      push_verdict!(shared, "changes-requested", ["Round 2 finding."])
      accepted!(scope, work_item, shared, since)
      push_verdict!(shared, "changes-requested", ["After the escalation."])

      # The checks failed at the round limit after a `passed` verdict: no findings, though
      # an older round's verdict of the run has points.
      checked = live_run!(work_item)
      push_verdict!(checked, "changes-requested", ["Round 1 finding."])
      push_verdict!(checked, "passed")
      accepted!(scope, work_item, checked, DateTime.add(since, 1, :second))

      # Another verdict than changes-requested has no findings to accept.
      escalated = live_run!(work_item)
      push_verdict!(escalated, "escalate", ["Ask the owner."])
      accepted!(scope, work_item, escalated, DateTime.add(since, 2, :second))

      # An escalation with no run has none either. Each accept is listed, oldest first, and
      # one resolved at the very moment of the take in counts.
      accepted!(scope, work_item, nil, DateTime.add(since, 3, :second))

      assert [
               %{at: ^since, findings: ["Round 2 finding."]},
               %{findings: []},
               %{findings: []},
               %{findings: []}
             ] = Stages.accepted_findings(reload(work_item), [@build])
    end
  end

  # A version of the verdict that the run of the queue `run` pushes at Build.
  defp push_verdict!(run, verdict, points \\ nil) do
    document =
      if points,
        do: %{"verdict" => verdict, "points" => Enum.map(points, &again/1)},
        else: %{"verdict" => verdict}

    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        "verdict",
        document,
        stage_id: @build
      )
  end

  # An escalation of the run of the queue `run`, or none, at Build's round limit, that the
  # scope's member accepted at `at`.
  defp accepted!(scope, work_item, run, at) do
    Repo.insert!(%Escalation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      process_version_id: work_item.process_version_id,
      run_id: run && run.id,
      stage_id: @build,
      round: 1,
      cause: :round_limit,
      points: [],
      resolution: :accept,
      resolved_by_id: scope.user.id,
      resolved_at: at,
      inserted_at: DateTime.utc_now()
    })
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
  end

  describe "a first attempt, and Verify with no run" do
    @verify "st_m1mqbeywdg"
    @on_fast %{"track" => "fast"}
    @tracks_of_process [
      %{"id" => "standard", "name" => "Standard"},
      %{"id" => "fast", "name" => "Fast track"}
    ]

    # Explore offering both tracks; Build, whose first attempt runs on Fast track only and
    # ends its sequence when it passes, then plan-the-build and, on Fast track,
    # write-the-checks; Verify, whose run and whose output `verification` Fast track does
    # without.
    defp first_attempt_process!(scope) do
      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks_of_process,
        "stages" => [
          explore_stage(offering(["standard", "fast"])),
          stage(@build, "Build", [
            %{"workflow" => "make-a-small-change", "when" => @on_fast, "first_attempt" => true},
            %{"workflow" => "plan-the-build"},
            %{"workflow" => "write-the-checks", "when" => @on_fast}
          ]),
          stage(@verify, "Verify", [%{"workflow" => "verify-a-ticket", "unless" => @on_fast}], %{
            "outputs" => [
              %{"type" => "verification", "required" => true, "unless" => @on_fast}
            ]
          })
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
    end

    defp in_build!(scope, track) do
      first_attempt_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: track)
      reload(work_item)
    end

    defp verified_with(type) do
      fn run, registered ->
        {:ok, _version} =
          Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            type,
            [checked(type, "Checked")],
            name: "main",
            stage_id: run.stage_id
          )

        verdict("passed").(run, registered)
      end
    end

    test "a passed first attempt ends Build's sequence, and Verify's gate opens with no run and no verification",
         %{scope: scope} do
      work_item = in_build!(scope, "fast")

      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
      assert %DispatchRun{workflow: "make-a-small-change", stage_entry: 0} = newest_run(work_item)

      work_item = end_run!(work_item, verdict("passed"))

      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = work_item

      assert Enum.map(runs(work_item), & &1.workflow) == [
               "explore-a-ticket",
               "make-a-small-change"
             ]

      {:ok, verifying} = Stages.approve(scope, work_item, nil, expect_stage: @build)

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = verifying

      assert Enum.map(runs(verifying), & &1.workflow) == [
               "explore-a-ticket",
               "make-a-small-change"
             ]

      refute escalation(verifying)
      assert Stages.missing_outputs(verifying) == []

      assert %{state: :at_gate, outputs: [%{type: "verification", required: false}]} =
               Stages.status(verifying, scope)

      assert {:ok, %WorkItem{state: :closed}} =
               Stages.approve(scope, verifying, nil, expect_stage: @verify)
    end

    test "a passed first attempt leaves one skip for each later workflow, until the stage runs again",
         %{scope: scope} do
      work_item = in_build!(scope, "fast") |> end_run!(verdict("passed"))

      assert [
               %{stage_id: @build, workflow: "plan-the-build", reason: "first_attempt_passed"},
               %{stage_id: @build, workflow: "write-the-checks", reason: "first_attempt_passed"}
             ] = skips = Stages.skips(work_item)

      assert Enum.all?(skips, &(&1.cause_entry == "make-a-small-change" and &1.input == nil))
      assert Enum.all?(skips, &(&1.track == nil and &1.negated == false and &1.round == 1))

      # Approving Build and moving back into it runs the stage again, from its first entry.
      {:ok, verifying} = Stages.approve(scope, work_item, nil, expect_stage: @build)
      assert Enum.count(Stages.skips(verifying), &(&1.stage_id == @build)) == 2

      {:ok, again} = Stages.move(scope, verifying, @build, "Again.", expect_stage: @verify)
      assert %WorkItem{stage_id: @build, stage_state: :running} = again
      assert Enum.filter(Stages.skips(again), & &1.reason) == []
    end

    test "Request changes clears the skips of a first attempt, and its next pass writes them again",
         %{scope: scope} do
      work_item = in_build!(scope, "fast") |> end_run!(verdict("passed"))
      assert length(Stages.skips(work_item)) == 2
      [proposal] = versions(work_item, "proposal")

      {:ok, again} =
        Stages.request_changes(scope, work_item, "Redo it.", proposal.public_id,
          expect_stage: @build
        )

      assert %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 0} = again
      assert Stages.skips(again) == []

      again = end_run!(again, verdict("passed"))
      assert [_plan, _checks] = Stages.skips(again)
    end

    test "Another round after a failed check clears the skips of the last loop only",
         %{scope: scope} do
      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @tracks_of_process,
        "stages" => [
          explore_stage(offering(["standard", "fast"])),
          stage(
            @build,
            "Build",
            [
              %{"workflow" => "make-a-small-change", "when" => @on_fast, "first_attempt" => true},
              %{"workflow" => "plan-the-build"},
              %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "check-it"}]}}
            ],
            %{"outputs" => [%{"type" => "submission", "required" => true}]}
          )
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast")

      # The first attempt passes with no submission: the check fails and the stage escalates.
      work_item = reload(work_item) |> end_run!(verdict("passed"))
      assert %WorkItem{stage_id: @build, stage_state: :escalated} = work_item
      assert %Escalation{cause: :check_failed} = escalation(work_item)

      assert ["plan-the-build", "check-it"] ==
               for(
                 %{reason: "first_attempt_passed", workflow: w} <- Stages.skips(work_item),
                 do: w
               )

      {:ok, again} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil, expect_stage: @build)

      # The loop runs again, so its skip goes; plan-the-build still does not run.
      assert %DispatchRun{workflow: "check-it"} = newest_run(again)

      assert ["plan-the-build"] ==
               for(%{reason: "first_attempt_passed", workflow: w} <- Stages.skips(again), do: w)
    end

    test "a first attempt that ends changes-requested goes on with the sequence", %{scope: scope} do
      work_item = in_build!(scope, "fast")
      work_item = end_run!(work_item, verdict("changes-requested"))

      assert %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 1} = work_item
      assert %DispatchRun{workflow: "plan-the-build"} = newest_run(work_item)
    end

    test "on Standard the first attempt does not run, and Verify still needs verification",
         %{scope: scope} do
      work_item = in_build!(scope, "standard")

      assert %WorkItem{stage_id: @build, stage_state: :running, stage_entry: 1} = work_item
      assert %DispatchRun{workflow: "plan-the-build"} = newest_run(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      {:ok, verifying} = Stages.approve(scope, work_item, nil, expect_stage: @build)

      assert %WorkItem{stage_id: @verify, stage_state: :running} = verifying
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(verifying)

      ended = end_run!(verifying, verdict("passed"))

      assert %WorkItem{stage_id: @verify, stage_state: :escalated} = ended
      assert %Escalation{cause: :check_failed} = escalation(ended)
      assert Stages.missing_outputs(ended) == ["verification"]

      assert %{outputs: [%{type: "verification", required: true, check: :missing}]} =
               Stages.status(ended, scope)
    end

    test "on Standard, Verify's gate opens once verification is stored", %{scope: scope} do
      work_item = in_build!(scope, "standard") |> end_run!(verdict("passed"))
      {:ok, verifying} = Stages.approve(scope, work_item, nil, expect_stage: @build)

      ended = end_run!(verifying, verified_with("verification"))

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = ended
      assert Stages.missing_outputs(ended) == []
    end
  end

  describe "a switch of track at an escalation" do
    @switch_tracks [
      %{"id" => "standard", "name" => "Standard"},
      %{"id" => "fast-track", "name" => "Fast track"}
    ]
    @on_standard %{"track" => "standard"}

    # Explore offers both tracks, Shape runs on Standard only, Build offers no track.
    defp switch_process!(scope, offered \\ ["standard", "fast-track"]) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "build-report",
          "base_view" => "document"
        })

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => @switch_tracks,
        "stages" => [
          explore_stage(offering(offered)),
          stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], %{"when" => @on_standard}),
          stage(@build, "Build", [%{"workflow" => "make-a-small-change"}], %{
            "outputs" => [%{"type" => "build-report", "required" => false}]
          })
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
    end

    # The work item escalated in its stage, on the track `track` that Explore's gate
    # recorded: Build on Fast track, which passes Shape over, else Shape.
    defp escalated!(scope, track, stage_id) do
      switch_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: track)

      work_item = reload(work_item)
      assert %WorkItem{stage_id: ^stage_id, stage_state: :running} = work_item

      if stage_id == @build do
        {:ok, _version} =
          Artifacts.push(
            {:run, newest_run(work_item)},
            work_item,
            "build-report",
            [%{filename: "build-report.md", content_type: "text/markdown", binary: "# Report"}],
            stage_id: @build
          )
      end

      escalated = end_run!(work_item, verdict("escalate", [again("A server check reads it.")]))
      assert %Escalation{cause: :escalate} = escalation(escalated)
      reload(escalated)
    end

    defp escalated_in_build!(scope, track), do: escalated!(scope, track, @build)

    defp switch(scope, work_item, track),
      do: Stages.resolve_escalation(scope, work_item, {:switch, track}, nil, expect_stage: @build)

    test "Switch to Standard records the track and starts the first stage that runs it",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")
      assert Stages.track(work_item) == "fast-track"

      assert [
               %{
                 id: "standard",
                 name: "Standard",
                 gate: "Explore",
                 first: "Shape",
                 later: ["Build"]
               }
             ] =
               Stages.switch_tracks(work_item)

      assert Stages.starts(work_item, {:switch, "standard"}) == {:run, "shape-a-ticket"}

      assert {:ok, %WorkItem{stage_id: @shape, stage_state: :running}} =
               switch(scope, work_item, "standard")

      assert Stages.track(work_item) == "standard"
      assert %DispatchRun{workflow: "shape-a-ticket", stage_id: @shape} = newest_run(work_item)
      assert escalation(work_item) == nil

      assert %Escalation{resolution: :switch, resolved_by_id: by} =
               Repo.get_by(Escalation, work_item_id: work_item.id, stage_id: @build)

      assert by == scope.user.id

      # The switch is a move out of Build to the stage after Explore's gate, for the
      # escalation it resolves, so `track/1` stays its only reader; it has no note, which
      # the escalation keeps.
      assert [%GateDecision{kind: :approve, track: "fast-track"}, switched] =
               decisions(work_item)

      assert %GateDecision{
               kind: :move,
               track: "standard",
               stage_id: @build,
               to_stage_id: @shape,
               escalation_id: escalation_id,
               left_stage_entered_at: %DateTime{},
               note: nil
             } = switched

      assert escalation_id ==
               Repo.get_by!(Escalation, work_item_id: work_item.id, stage_id: @build).id

      assert Repo.one(
               from e in Entry,
                 where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
                 where: fragment("? ->> 'change' = 'escalation_switch'", e.details),
                 select: e.details
             ) == %{
               "change" => "escalation_switch",
               "stage_id" => @build,
               "cause" => "escalate",
               "track" => "standard"
             }
    end

    test "after a switch, the inputs list Build's report from the move until Build is entered again",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")
      assert Enum.filter(Stages.inputs(work_item), & &1[:from]) == []

      {:ok, %WorkItem{stage_id: @shape}} = switch(scope, work_item, "standard")

      assert [%{type: "build-report", required: false, from: :move, version: %{number: 1}}] =
               Enum.filter(Stages.inputs(work_item), & &1[:from])

      # Shape's run ends and its gate passes: Build is entered again, and its report is no
      # longer an input of the stage the work item is in.
      shaping = end_run!(reload(work_item), verdict("passed"))
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = shaping

      assert {:ok, %WorkItem{stage_id: @build}} =
               Stages.approve(scope, shaping, nil, expect_stage: @shape)

      assert Enum.filter(Stages.inputs(work_item), & &1[:from]) == []
    end

    test "after a switch, the notes list one escalation and no move", %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")

      {:ok, _moved} =
        Stages.resolve_escalation(scope, work_item, {:switch, "standard"}, "Write a spec",
          expect_stage: @build
        )

      assert [%{kind: :escalation, note: "Write a spec", stage_id: @build}] =
               Stages.notes(work_item)
    end

    test "the note of a switch goes to the next run", %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")

      assert {:ok, _moved} =
               Stages.resolve_escalation(scope, work_item, {:switch, "standard"}, "Write a spec",
                 expect_stage: @build
               )

      assert Enum.any?(Stages.notes(work_item), &(&1.note == "Write a spec"))
    end

    test "a track the gate does not list, and the track the work item is on, are refused with nothing written",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")
      before = decisions(work_item)

      # A track the gate does not list, and the track the work item is on, are refused with
      # different reasons.
      assert switch(scope, work_item, "express") ==
               {:error, {:track_not_offered, "express", "Explore"}}

      assert switch(scope, work_item, "fast-track") == {:error, {:already_on, "Fast track"}}

      for track <- ["express", "fast-track"],
          do: assert(Stages.starts(work_item, {:switch, track}) == :none)

      assert %WorkItem{stage_id: @build, stage_state: :escalated} = reload(work_item)
      assert %Escalation{resolution: nil} = escalation(work_item)
      assert decisions(work_item) == before
      assert Stages.track(work_item) == "fast-track"
    end

    test "the track is checked against the gate that recorded it, not Build's gate",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")

      # Build's gate offers no track, and Explore's gate does.
      assert Stages.offered_tracks(work_item) == []
      assert {:ok, %WorkItem{stage_id: @shape}} = switch(scope, work_item, "standard")
    end

    test "a person's move is refused where the escalation is offered a switch, and not otherwise",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")
      before = decisions(work_item)

      assert Stages.move(scope, work_item, @explore, nil, expect_stage: @build) ==
               {:error, :invalid}

      assert %WorkItem{stage_id: @build, stage_state: :escalated} = reload(work_item)
      assert %Escalation{resolution: nil} = escalation(work_item)
      assert decisions(work_item) == before
    end

    test "a person's move of a work item on the gate's first track still resolves the escalation",
         %{scope: scope} do
      work_item = escalated!(scope, "standard", @shape)

      assert {:ok, %WorkItem{stage_id: @explore}} =
               Stages.move(scope, work_item, @explore, nil, expect_stage: @shape)

      assert %Escalation{resolution: :move_back} =
               Repo.get_by(Escalation, work_item_id: work_item.id)
    end

    test "the gate that recorded the track is read from the version it was recorded under, after a repin",
         %{scope: scope} do
      switch_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      work_item = reload(work_item)
      assert %WorkItem{stage_id: @build} = work_item

      # A later version, whose Explore gate no longer offers Fast track; the work item is
      # pinned to it between the approval and the escalation.
      version = Processes.current(scope.workspace)

      document =
        version.document
        |> put_in(["stages", Access.at(0), "gate", "tracks"], ["standard"])
        |> Map.put("tracks", @switch_tracks)

      {:ok, later} = Processes.save(scope, scope.workspace, document)
      assert later.id != version.id
      assert {:ok, _assigned} = Processes.assign(scope, work_item, later)

      escalated = end_run!(reload(work_item), verdict("escalate", [again("It is wrong.")]))
      assert %Escalation{cause: :escalate} = escalation(escalated)
      assert reload(escalated).process_version_id == later.id

      assert [%{id: "standard", name: "Standard", gate: "Explore"}] =
               Stages.switch_tracks(reload(escalated))

      assert {:ok, %WorkItem{stage_id: @shape}} =
               Stages.resolve_escalation(scope, reload(escalated), {:switch, "standard"}, nil,
                 expect_stage: @build
               )
    end

    test "a later gate that offers the same tracks does not take the switch's place as the recording gate",
         %{scope: scope} do
      tracks = [
        %{"id" => "standard", "name" => "Standard"},
        %{"id" => "fast-track", "name" => "Fast track"},
        %{"id" => "express", "name" => "Express"}
      ]

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => tracks,
        "stages" => [
          explore_stage(offering(["standard", "fast-track", "express"])),
          stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], %{"when" => @on_standard}),
          stage(
            @build,
            "Build",
            [%{"workflow" => "make-a-small-change"}],
            offering(["standard", "fast-track", "express"])
          )
        ]
      }

      {:ok, _version} = Processes.save(scope, scope.workspace, document)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, track: "express")
      work_item = reload(work_item)

      escalated =
        end_run!(work_item, verdict("escalate", [again("A server check reads it.")]))

      assert [%{id: "standard", gate: "Explore"}, %{id: "fast-track", gate: "Explore"}] =
               Stages.switch_tracks(escalated)

      # Switch to Fast track: Shape is passed over and Build runs again, on a track that is
      # not the first. The decision of the switch is at Build, whose gate offers the same
      # tracks, and Explore's gate is still the one that recorded the track.
      assert {:ok, %WorkItem{stage_id: @build, stage_state: :running}} =
               switch(scope, reload(escalated), "fast-track")

      assert Stages.track(work_item) == "fast-track"

      again_escalated =
        end_run!(reload(work_item), verdict("escalate", [again("It is still wrong.")]))

      assert [%{id: "standard", gate: "Explore"}, %{id: "express", gate: "Explore"}] =
               Stages.switch_tracks(again_escalated)
    end

    test "after a switch to Standard the work item is offered no switch", %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")
      {:ok, _shape} = switch(scope, work_item, "standard")

      # On Standard the work item is on the gate's first track: it is offered no switch.
      assert Stages.switch_tracks(reload(work_item)) == []
    end

    test "a work item on the gate's first track is offered no switch and keeps Accept and Move back",
         %{scope: scope} do
      work_item = escalated!(scope, "standard", @shape)
      expect = [expect_stage: @shape]
      assert Stages.switch_tracks(work_item) == []
      assert Stages.starts(work_item, {:switch, "fast-track"}) == :none

      assert Stages.resolve_escalation(scope, work_item, {:switch, "fast-track"}, nil, expect) ==
               {:error, :invalid}

      assert %Escalation{resolution: nil} = escalation(work_item)

      assert {:ok, %WorkItem{stage_id: @explore}} =
               Stages.resolve_escalation(scope, work_item, {:move_back, @explore}, nil, expect)
    end

    test "Accept as it is stays for a work item on the gate's first track", %{scope: scope} do
      work_item = escalated!(scope, "standard", @shape)

      assert {:ok, %WorkItem{stage_state: :at_gate}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @shape)
    end

    test "an escalation that is offered a switch refuses Accept as it is and Move back",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")
      before = decisions(work_item)

      for resolution <- [:accept, {:move_back, @explore}, {:move_back, @shape}] do
        assert Stages.resolve_escalation(scope, work_item, resolution, nil, expect_stage: @build) ==
                 {:error, :invalid}
      end

      assert %WorkItem{stage_id: @build, stage_state: :escalated} = reload(work_item)
      assert %Escalation{resolution: nil} = escalation(work_item)
      assert decisions(work_item) == before

      # Run another round and Close are kept.
      assert {:ok, %WorkItem{state: :closed}} =
               Stages.resolve_escalation(scope, work_item, :close, nil, expect_stage: @build)
    end

    test "a work item with no track, or at a stage before the gate's, is offered no switch",
         %{scope: scope} do
      switch_process!(scope)
      work_item = take_in!(scope)
      assert Stages.switch_tracks(work_item) == []
      assert Stages.starts(work_item, {:switch, "standard"}) == :none
    end
  end

  describe "a person's change to an approved output (A-20)" do
    @verify "st_m1mqbeywdg"
    @release "st_q4ncz8w2xe"

    # Shape, whose run of shape-a-ticket makes the acceptance criteria; Build, a loop with
    # a gate none, as the software process has it, which reads the criteria and makes the
    # explainer; and Verify, which reads both, with a person's gate. `last` is the last
    # stage: `:build`, `:verify`, or `:release`, a stage after Verify that reads the
    # criteria. `type` is the type in place of the acceptance criteria, for a test of
    # several names of one type: the acceptance criteria take the name `main` alone.
    defp criteria_process!(scope, last \\ :verify, type \\ "acceptance-criteria") do
      stages = [
        explore_stage(),
        stage(@shape, "Shape", [%{"workflow" => "shape-a-ticket"}], %{
          "outputs" => [%{"type" => type, "required" => true}]
        }),
        stage(
          @build,
          "Build",
          [
            %{
              "loop" => %{
                "rounds" => 3,
                "body" => [
                  %{"workflow" => "implement-changes"},
                  %{"workflow" => "review-changes"}
                ]
              }
            }
          ],
          %{
            "inputs" => [%{"type" => type, "required" => true}],
            "outputs" => [%{"type" => "explainer", "required" => true}],
            "gate" => %{"kind" => "none"}
          }
        )
      ]

      verify =
        stage(@verify, "Verify", [%{"workflow" => "verify-a-ticket"}], %{
          "inputs" => [
            %{"type" => type, "required" => true},
            %{"type" => "explainer", "required" => true}
          ]
        })

      release =
        stage(@release, "Release", [%{"workflow" => "verify-a-ticket"}], %{
          "inputs" => [%{"type" => type, "required" => true}]
        })

      save!(
        scope,
        case last do
          :build -> stages
          :verify -> stages ++ [verify]
          :release -> stages ++ [verify, release]
        end
      )
    end

    # The end of a run that pushes a version of `type` with `opts`, such as a decision.
    defp pushes_one(type, text, opts) do
      fn run, _registered ->
        {:ok, _version} =
          Stages.Artifacts.push(
            {:run, run},
            Repo.get!(WorkItem, run.work_item_id),
            type,
            [file_of(type, text)],
            Keyword.put(opts, :stage_id, run.stage_id)
          )
      end
    end

    # The file of a version of `type` with `text`: the acceptance criteria are a JSON
    # document with `text` as its summary, any other type a Markdown file.
    defp file_of("acceptance-criteria", text),
      do: json_file("acceptance-criteria", criteria_document(%{"summary" => text}))

    defp file_of(type, text),
      do: %{filename: "#{type}.md", content_type: "text/markdown", binary: text}

    defp both(first, second) do
      fn run, registered ->
        first.(run, registered)
        second.(run, registered)
      end
    end

    # The work item in Build after Shape's approval of the criteria Shape's run made, as a
    # version of `type`, and an escalation of Build's first round that a person answered
    # with `note`: the work item, with Build's second round running, and the escalation.
    defp asked_in_build!(scope, note, type \\ "acceptance-criteria") do
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)

      work_item =
        work_item
        |> reload()
        |> end_run!(fn run, registered ->
          {:ok, _version} =
            Stages.Artifacts.push(
              {:run, run},
              Repo.get!(WorkItem, run.work_item_id),
              type,
              [file_of(type, "AC-1")],
              stage_id: run.stage_id
            )

          verdict("passed").(run, registered)
        end)

      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item

      work_item =
        work_item
        |> end_run!(pushes_one("explainer", "# Explainer 1", []))
        |> end_run!(verdict("escalate", [again("AC-2 does not cover the empty cart.")]))

      assert %Escalation{} = escalation = escalation(work_item)

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, note, expect_stage: @build)

      {work_item, Repo.get!(Escalation, escalation.id)}
    end

    defp criteria(work_item, number),
      do: Enum.find(versions(work_item, "acceptance-criteria"), &(&1.number == number))

    test "Build's run stores a criterion's new version with the decision; Build and Verify " <>
           "read it; Verify's gate lists it, Build's automatic gate does not",
         %{scope: scope} do
      criteria_process!(scope)

      {work_item, %Escalation{public_id: decision, resolved_at: at}} =
        asked_in_build!(scope, "Cover the empty cart in AC-2.")

      assert "es_" <> _random = decision

      changed =
        pushes_one("acceptance-criteria", "# AC-2 with the empty cart", decision: decision)

      work_item = end_run!(work_item, both(changed, pushes_one("explainer", "# Explainer 2", [])))

      new = criteria(work_item, 2)
      assert %{writer: :run, stage_id: @build, decision_id: ^decision} = new

      # Build's next run reads the new version.
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item
      assert %DispatchRun{workflow: "review-changes"} = newest_run(work_item)
      new_id = new.public_id

      assert [
               %{
                 type: "acceptance-criteria",
                 version: %{id: ^new_id, decision: ^decision, decision_at: ^at}
               }
             ] = Stages.inputs(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item

      # Build's gate none lists its explainer and leaves out the new criteria.
      explainer = Enum.find(versions(work_item, "explainer"), &(&1.number == 2)).public_id

      assert [
               %GateDecision{stage_id: @shape, automatic: false, versions: [shaped]},
               %GateDecision{stage_id: @build, automatic: true, versions: [^explainer]}
             ] =
               Enum.filter(
                 decisions(work_item),
                 &(&1.kind == :approve and &1.stage_id != @explore)
               )

      assert shaped == criteria(work_item, 1).public_id

      # Verify reads the new version in place of the one Shape's gate approved.
      assert [
               %{type: "acceptance-criteria", version: %{id: ^new_id, decision: ^decision}},
               %{type: "explainer", version: %{id: ^explainer}}
             ] = Stages.inputs(work_item)

      work_item = end_run!(work_item, verdict("passed"))
      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
      {:ok, _work_item} = Stages.approve(scope, work_item, nil, expect_stage: @verify)

      user_id = scope.user.id

      assert %GateDecision{automatic: false, user_id: ^user_id, versions: [^new_id]} =
               Enum.find(decisions(work_item), &(&1.stage_id == @verify))

      assert [
               %{
                 type: "acceptance-criteria",
                 approved_version: ^new_id,
                 versions: [
                   %{id: ^new_id, decision: ^decision, decision_at: ^at, approvals: [approval]},
                   %{number: 1, decision: nil, decision_at: nil}
                 ]
               }
             ] =
               Enum.filter(Stages.artifact_index(work_item), &(&1.type == "acceptance-criteria"))

      assert %{user_id: ^user_id, automatic: false, stage_id: @verify} = approval
    end

    test "a gate none leaves out its stage's output that has a decision, and the next stage " <>
           "reads it",
         %{scope: scope} do
      criteria_process!(scope)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Name the empty cart in the explainer.")

      work_item =
        work_item
        |> end_run!(pushes_one("explainer", "# Explainer 2", decision: decision))
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @verify, stage_state: :running} = work_item
      explainer = Enum.find(versions(work_item, "explainer"), &(&1.number == 2))
      assert explainer.decision_id == decision

      assert %GateDecision{automatic: true, versions: []} =
               Enum.find(decisions(work_item), &(&1.stage_id == @build))

      explainer_id = explainer.public_id

      assert [_criteria, %{type: "explainer", version: %{id: ^explainer_id}}] =
               Stages.inputs(work_item)
    end

    test "a change counts by the approvals that list it, not by its time", %{scope: scope} do
      criteria_process!(scope)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Cover the empty cart in AC-2.")

      changed = pushes_one("acceptance-criteria", "# AC-2", decision: decision)
      work_item = end_run!(work_item, changed)
      new = criteria(work_item, 2)

      # A push takes its time before it waits for the work item's lock, so its version can
      # have a time earlier than an approval that committed first and does not list it.
      shaped = Enum.find(decisions(work_item), &(&1.stage_id == @shape))
      earlier = DateTime.add(shaped.inserted_at, -3600, :second)

      {1, _rows} =
        Repo.update_all(from(v in Apiary.Artifacts.Version, where: v.id == ^new.id),
          set: [inserted_at: earlier]
        )

      new_id = new.public_id
      assert [%{version: %{id: ^new_id, decision: ^decision}}] = Stages.inputs(work_item)
    end

    test "a push refuses a decision that is not a person's note on the work item", %{
      scope: scope
    } do
      criteria_process!(scope)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Cover the empty cart in AC-2.")

      run = newest_run(work_item)
      file = [file_of("acceptance-criteria", "AC-2")]

      # Another work item's request for changes, an approval, which is no note, an id of
      # no note, and malformed ids.
      other = take_in!(scope) |> end_run!(understood_result())

      {:ok, _other} =
        Stages.request_changes(scope, other, "Name the price rule.", nil, expect_stage: @explore)

      [%GateDecision{kind: :request_changes, public_id: elsewhere}] = decisions(other)
      approval = Enum.find(decisions(work_item), &(&1.stage_id == @shape))
      assert "gd_" <> _random = approval.public_id

      for id <- [elsewhere, approval.public_id, "es_0000000000000000", "es_x", "decision"] do
        assert Stages.Artifacts.push({:run, run}, work_item, "acceptance-criteria", file,
                 stage_id: @build,
                 decision: id
               ) == {:error, {:unknown_decision, id}}
      end

      assert Stages.Artifacts.push({:run, run}, work_item, "acceptance-criteria", file,
               stage_id: @build,
               decision: 42
             ) == {:error, {:invalid, :decision}}

      assert [%{number: 1}] = versions(work_item, "acceptance-criteria")

      assert {:ok, %{decision_id: ^decision}} =
               Stages.Artifacts.push({:run, run}, work_item, "acceptance-criteria", file,
                 stage_id: @build,
                 decision: decision
               )
    end

    test "a push refuses the id of a switch's move, and takes the escalation's note",
         %{scope: scope} do
      work_item = escalated_in_build!(scope, "fast-track")

      {:ok, moved} =
        Stages.resolve_escalation(scope, work_item, {:switch, "standard"}, "Write a spec",
          expect_stage: @build
        )

      assert %WorkItem{stage_id: @shape} = moved
      [%GateDecision{public_id: move}] = Enum.filter(decisions(moved), &(&1.kind == :move))
      # The notes list the escalation, with its id, and no move.
      assert [%{kind: :escalation, id: "es_" <> _random = note}] =
               Enum.filter(Stages.notes(moved), &(&1.kind in [:move, :escalation]))

      run = newest_run(moved)
      file = [%{filename: "report.md", content_type: "text/markdown", binary: "# Report"}]

      assert Stages.Artifacts.push({:run, run}, moved, "build-report", file,
               stage_id: @shape,
               decision: move
             ) == {:error, {:unknown_decision, move}}

      assert {:ok, %{decision_id: ^note}} =
               Stages.Artifacts.push({:run, run}, moved, "build-report", file,
                 stage_id: @shape,
                 decision: note
               )
    end

    test "after a move to Shape, Shape's gate shows the change that no approval lists, and " <>
           "its approval lists it: Build and Verify read it",
         %{scope: scope} do
      criteria_process!(scope)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Cover the empty cart in AC-2.")

      changed = pushes_one("acceptance-criteria", "# AC-2", decision: decision)
      work_item = end_run!(work_item, changed)
      new_id = criteria(work_item, 2).public_id

      # A person moves the work item to Shape, whose run pushes no criteria and passes.
      # Its gate shows version 2, the change, in place of version 1, from Shape's first
      # run.
      {:ok, work_item} = Stages.move(scope, work_item, @shape, nil, expect_stage: @build)
      work_item = work_item |> reload() |> end_run!(verdict("passed"))

      assert %{
               state: :at_gate,
               outputs: [%{type: "acceptance-criteria", version: %{id: ^new_id}}]
             } =
               Stages.status(work_item, scope)

      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item

      shaped =
        work_item
        |> decisions()
        |> Enum.filter(&(&1.kind == :approve and &1.stage_id == @shape))
        |> List.last()

      assert shaped.versions == [new_id]

      # No change is left; the read is the higher-numbered version Shape's gate approved.
      assert [%{type: "acceptance-criteria", version: %{id: ^new_id}}] = Stages.inputs(work_item)

      work_item =
        work_item
        |> end_run!(pushes_one("explainer", "# Explainer", []))
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @verify} = work_item

      assert [%{type: "acceptance-criteria", version: %{id: ^new_id}}, _explainer] =
               Stages.inputs(work_item)
    end

    test "a person's approval lists the change of each name of a type, and a later stage " <>
           "reads the same name as before it",
         %{scope: scope} do
      # Decision records in place of the acceptance criteria, which take one name.
      criteria_process!(scope, :release, "decision-record")

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(
          scope,
          "Add a scenario for the empty cart and one for the coupon.",
          "decision-record"
        )

      scenarios =
        both(
          pushes_one("decision-record", "# Empty cart", decision: decision, name: "scenario-1"),
          pushes_one("decision-record", "# Coupon", decision: decision, name: "scenario-2")
        )

      work_item =
        work_item
        |> end_run!(both(scenarios, pushes_one("explainer", "# Explainer", [])))
        |> end_run!(verdict("passed"))
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item

      ids =
        for artifact <- Apiary.Artifacts.list(work_item),
            artifact.name in ["scenario-1", "scenario-2"],
            do: hd(artifact.versions).public_id

      assert length(ids) == 2

      # Before the approval, the read is the newest change: scenario-2, pushed last.
      [first, second] = Enum.sort_by(versions_of(work_item, ids), & &1.inserted_at, DateTime)
      second_id = second.public_id
      assert first.public_id != second_id

      assert [%{type: "decision-record", version: %{id: ^second_id}}, _explainer] =
               Stages.inputs(work_item)

      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @verify)
      verified = Enum.find(decisions(work_item), &(&1.stage_id == @verify))
      assert ids -- verified.versions == []

      # After it, Release reads the same version through Verify's approval.
      assert %WorkItem{stage_id: @release} = work_item

      assert [%{type: "decision-record", version: %{id: ^second_id}}] =
               Stages.inputs(work_item)
    end

    test "after a move back to Build, Build reads the change that Verify's approval listed",
         %{scope: scope} do
      criteria_process!(scope, :release)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Cover the empty cart in AC-2.")

      changed = pushes_one("acceptance-criteria", "# AC-2", decision: decision)

      work_item =
        work_item
        |> end_run!(both(changed, pushes_one("explainer", "# Explainer 2", [])))
        |> end_run!(verdict("passed"))
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @verify, stage_state: :at_gate} = work_item
      new_id = criteria(work_item, 2).public_id

      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @verify)

      assert %GateDecision{versions: [^new_id]} =
               Enum.find(decisions(work_item), &(&1.stage_id == @verify))

      # A person moves the work item from Release back to Build, before Verify's gate.
      assert %WorkItem{stage_id: @release} = work_item
      {:ok, work_item} = Stages.move(scope, work_item, @build, nil, expect_stage: @release)
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item

      assert [%{type: "acceptance-criteria", version: %{id: ^new_id}}] = Stages.inputs(work_item)
    end

    test "after a move back to Shape, Shape's gate shows and approves the change that " <>
           "Verify's approval listed, and Build reads it",
         %{scope: scope} do
      criteria_process!(scope, :release)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Cover the empty cart in AC-2.")

      changed = pushes_one("acceptance-criteria", "# AC-2", decision: decision)

      work_item =
        work_item
        |> end_run!(both(changed, pushes_one("explainer", "# Explainer 2", [])))
        |> end_run!(verdict("passed"))
        |> end_run!(verdict("passed"))

      new_id = criteria(work_item, 2).public_id
      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @verify)

      # A person moves the work item from Release back to Shape, whose run pushes no
      # criteria and passes. Shape's newest output is version 1, from Shape's first run,
      # and its gate shows version 2, which Verify's approval listed.
      {:ok, work_item} = Stages.move(scope, work_item, @shape, nil, expect_stage: @release)
      work_item = work_item |> reload() |> end_run!(verdict("passed"))

      assert %{state: :at_gate, outputs: [%{type: "acceptance-criteria", version: %{number: 2}}]} =
               Stages.status(work_item, scope)

      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      assert %WorkItem{stage_id: @build, stage_state: :running} = work_item

      shaped =
        work_item
        |> decisions()
        |> Enum.filter(&(&1.kind == :approve and &1.stage_id == @shape))
        |> List.last()

      assert shaped.versions == [new_id]

      assert [%{type: "acceptance-criteria", version: %{id: ^new_id}}] = Stages.inputs(work_item)
    end

    defp versions_of(work_item, ids) do
      for artifact <- Apiary.Artifacts.list(work_item),
          v <- artifact.versions,
          v.public_id in ids,
          do: v
    end

    test "a closed work item whose last gate none left out an output with a decision stays " <>
           "done",
         %{scope: scope} do
      criteria_process!(scope, :build)

      {work_item, %Escalation{public_id: decision}} =
        asked_in_build!(scope, "Name the empty cart in the explainer.")

      work_item =
        work_item
        |> end_run!(pushes_one("explainer", "# Explainer 2", decision: decision))
        |> end_run!(verdict("passed"))

      assert %WorkItem{stage_id: @build, stage_state: :done} = work_item
      assert work_item.closed_at != nil

      assert %GateDecision{automatic: true, versions: []} =
               Enum.find(decisions(work_item), &(&1.stage_id == @build))

      assert %{state: :done, gate: %{approvable?: false}} = Stages.status(work_item, scope)
    end
  end

  describe "the fixture live_stage_run!/2" do
    test "hands a claimed run over with the registered run of its claim, which end_run! ends",
         %{scope: scope} do
      work_item = take_in!(scope)
      claimed = newest_run(work_item) |> Ecto.Changeset.change(state: :claimed) |> Repo.update!()

      %Apiary.Runs.Run{
        number:
          Apiary.RunEventsFixtures.next_run_number(claimed.organisation_id, claimed.workspace_id),
        organisation_id: claimed.organisation_id,
        workspace_id: claimed.workspace_id,
        node_run_id: claimed.run_id,
        dispatch_run_id: claimed.id
      }
      |> Ecto.Changeset.change(state: "pending")
      |> Apiary.RunEventsFixtures.insert_run!()

      assert %DispatchRun{id: id, state: :handed_over} = live_stage_run!(work_item)
      assert id == claimed.id
      assert [%{state: "running"}] = runs_of(claimed)

      end_run!(work_item, nil)
      assert [%{state: "completed"}] = runs_of(claimed)
    end

    defp runs_of(%DispatchRun{id: id}),
      do: Repo.all(from r in Apiary.Runs.Run, where: r.dispatch_run_id == ^id)
  end
end
