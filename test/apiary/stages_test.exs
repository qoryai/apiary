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

  alias Apiary.{ArtifactStoreHook, Artifacts, Processes, Repo, Stages, WorkItems}
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
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

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

      # The work item a take in again brings back: its version of the input counts.
      work_item = take_in!(scope)
      item = Repo.get!(Apiary.Sources.Item, work_item.item_id)

      {:ok, _version} =
        Artifacts.push(
          {:person, scope},
          work_item,
          "acceptance-criteria",
          [%{filename: "criteria.md", binary: "- The price is the sale price."}],
          stage_id: @explore
        )

      assert Stages.take_in_starts(scope.workspace, item.public_id) ==
               {:run, "explore-a-ticket"}

      assert Repo.aggregate(WorkItem, :count) == 1
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

      assert %Escalation{
               cause: :check_failed,
               round: 1,
               points: [
                 %{"text" => "No proposal was stored in this stage.", "action" => "run_again"}
               ]
             } = escalation(work_item)

      assert %{verdict: :passed} = hd(Stages.runs(work_item))
    end

    test "a run that pushed no proposal and changes-requested escalates check_failed", %{
      scope: scope
    } do
      work_item = take_in!(scope) |> end_run!(verdict("changes-requested"))

      assert work_item.stage_state == :escalated

      assert %Escalation{
               cause: :check_failed,
               round: 1,
               points: [
                 %{"text" => "No proposal was stored in this stage.", "action" => "run_again"}
               ]
             } = escalation(work_item)

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
        %{"type" => "mockup", "required" => true}
      ]

      save!(scope, [explore_stage(%{"outputs" => outputs}), stage(@shape, "Shape", [])])
      work_item = take_in!(scope) |> end_run!(understood_result())
      run = newest_run(work_item)

      # The proposal waits, and the stage escalated: the mockup is missing.
      assert %Escalation{cause: :check_failed} = escalation(work_item)
      assert %{status: :confirm} = Explore.current(work_item, DateTime.utc_now())

      assert {:error, :not_waiting} = WorkItems.confirm(scope, work_item, run.attempt)

      assert %WorkItem{stage_state: :escalated, stage_id: @explore} = reload(work_item)
      refute Repo.get_by(Confirmation, work_item_id: work_item.id)

      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :accept, nil, expect_stage: @explore)

      assert {:ok, %WorkItem{stage_id: @shape}} =
               WorkItems.confirm(scope, work_item, run.attempt)
    end

    test "Accept as it is at the last stage with a gate none closes the work item", %{
      scope: scope
    } do
      save!(scope, [explore_stage(%{"gate" => %{"kind" => "none"}})])
      work_item = take_in!(scope) |> end_run!(nil)
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

      assert %Escalation{
               cause: :check_failed,
               points: [
                 %{"text" => "No mockup was stored in this stage.", "action" => "run_again"}
               ]
             } = escalation(work_item)

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
        %{"text" => "No mockup was stored in this stage.", "action" => "run_again"}
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

      {:ok, _version} =
        Stages.Artifacts.push({:person, scope}, work_item, "proposal", a_proposal(),
          stage_id: @explore
        )

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

    test "a run does not withdraw a person's upload under a cancelled run's version",
         %{scope: scope} do
      work_item = done_with_explainers!(scope, [])

      {:ok, upload} =
        Stages.Artifacts.push(
          {:person, scope},
          work_item,
          "explainer",
          [%{filename: "explainer.md", content_type: "text/markdown", binary: "# P"}],
          stage_id: @explore
        )

      cancelled = live_run!(work_item)
      {:ok, %{number: 2}} = push_explainer(cancelled, "main")
      cancel_run!(scope, cancelled)

      assert {:error, {:withdraw, {:person, 1, user_id}}} =
               Artifacts.withdraw({:run, live_run!(work_item)}, work_item, "explainer",
                 stage_id: @explore
               )

      assert upload.number == 1
      assert user_id == scope.user.id
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

    test "a person's approval is read before the writer of the version", %{scope: scope} do
      work_item = done_with_explainers!(scope, [], :person)

      {:ok, upload} =
        Stages.Artifacts.push(
          {:person, scope},
          work_item,
          "explainer",
          [%{filename: "explainer.md", content_type: "text/markdown", binary: "# P"}],
          stage_id: @explore
        )

      [%GateDecision{} = earlier | _rest] = decisions(work_item)

      Repo.insert!(%GateDecision{
        organisation_id: earlier.organisation_id,
        workspace_id: earlier.workspace_id,
        work_item_id: work_item.id,
        process_version_id: earlier.process_version_id,
        user_id: scope.user.id,
        stage_id: @explore,
        kind: :approve,
        versions: [upload.public_id],
        inserted_at: DateTime.utc_now()
      })

      assert {:error, {:withdraw, {:approved, 1}}} =
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

      ArtifactStoreHook.on_stage(fn ->
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

  describe "the when key (A-16)" do
    @verify "st_m1mqbeywdg"
    @demos %{"input" => "demo-scenarios"}
    @optional_scenarios %{"outputs" => [%{"type" => "demo-scenarios", "required" => false}]}

    # Explore; Shape, worked by people, whose demo scenarios are optional; Verify, whose
    # capture-demos runs only with demo scenarios, and whose film is required only then.
    defp verify_process!(scope, shape \\ @optional_scenarios) do
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "demo-scenarios",
          "base_view" => "document"
        })

      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], shape),
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

    # The work item at Shape's gate, with the demo scenarios `scenarios` adds; then Shape
    # approved, so it enters Verify.
    defp at_verify!(scope, scenarios) do
      verify_process!(scope)
      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = reload(work_item)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item
      scenarios.(work_item)
      {:ok, work_item} = Stages.approve(scope, work_item, nil, expect_stage: @shape)
      reload(work_item)
    end

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
        at_verify!(scope, fn work_item ->
          assert Stages.starts(work_item, :approve) == {:run, "verify-a-ticket"}
        end)

      assert %WorkItem{stage_id: @verify, stage_state: :running, stage_entry: 1} = work_item
      assert %DispatchRun{workflow: "verify-a-ticket", stage_entry: 1} = newest_run(work_item)
      refute Enum.any?(runs(work_item), &(&1.workflow == "capture-demos"))

      assert [
               %{
                 stage_id: @verify,
                 workflow: "capture-demos",
                 input: "demo-scenarios",
                 round: 1,
                 after_attempt: 1
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
        at_verify!(scope, fn work_item ->
          {:ok, _version} =
            Stages.add_version(scope, work_item, "demo-scenarios", scenarios("# Scenario 1"))

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
        at_verify!(scope, fn work_item ->
          {:ok, _version} = Stages.add_version(scope, work_item, "demo-scenarios", scenarios(""))
          assert Stages.starts(work_item, :approve) == {:run, "verify-a-ticket"}
        end)

      assert [%{size: 0}] = hd(versions(work_item, "demo-scenarios")).files
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
      assert [%{workflow: "capture-demos"}] = Stages.skips(work_item)
    end

    test "a version added at a gate none counts for Verify only with a file of more than 0 bytes",
         %{scope: scope} do
      verify_process!(scope, %{
        "outputs" => [%{"type" => "demo-scenarios", "required" => true}],
        "gate" => %{"kind" => "none"}
      })

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = reload(work_item)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      assert Stages.starts(work_item, {:version_added, "demo-scenarios", [12]}) ==
               {:run, "capture-demos"}

      assert Stages.starts(work_item, {:version_added, "demo-scenarios", [0]}) ==
               {:run, "verify-a-ticket"}

      {:ok, _version} = Stages.add_version(scope, work_item, "demo-scenarios", scenarios(""))

      assert %WorkItem{stage_id: @verify} = reload(work_item)
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
      assert [%{workflow: "capture-demos"}] = Stages.skips(work_item)
    end

    # Explore; Shape, worked by people, with the gate `shape_gate`; Review (`@build`),
    # worked by people, with a gate none; both require demo scenarios; then Verify.
    defp two_gates!(scope, shape_gate) do
      verify_process!(scope)
      outputs = %{"outputs" => [%{"type" => "demo-scenarios", "required" => true}]}
      [explore, _shape, verify] = Processes.current(scope.workspace).document["stages"]

      save!(scope, [
        explore,
        stage(@shape, "Shape", [], Map.put(outputs, "gate", shape_gate)),
        stage(@build, "Review", [], Map.put(outputs, "gate", %{"kind" => "none"})),
        verify
      ])

      work_item = take_in!(scope) |> end_run!(understood_result())
      {:ok, _work_item} = WorkItems.confirm(scope, work_item, 1)
      work_item = reload(work_item)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      # Review's version from an earlier pass: 0 bytes.
      {:ok, _version} =
        Artifacts.push({:person, scope}, work_item, "demo-scenarios", scenarios(""),
          stage_id: @build
        )

      work_item
    end

    test "after two approvals, Verify reads the nearer one: Review's empty version does not count",
         %{scope: scope} do
      work_item = two_gates!(scope, %{"kind" => "person", "approvers" => "members"})

      {:ok, _version} =
        Stages.add_version(scope, work_item, "demo-scenarios", scenarios("# Scenario 1"))

      assert Stages.starts(work_item, :approve) == {:run, "verify-a-ticket"}

      {:ok, _work_item} = Stages.approve(scope, reload(work_item), nil, expect_stage: @shape)

      assert %WorkItem{stage_id: @verify} = reload(work_item)
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
    end

    test "a version added before a later gate none: the later approval wins", %{scope: scope} do
      work_item = two_gates!(scope, %{"kind" => "none"})

      assert Stages.starts(work_item, {:version_added, "demo-scenarios", [12]}) ==
               {:run, "verify-a-ticket"}

      {:ok, _version} =
        Stages.add_version(scope, work_item, "demo-scenarios", scenarios("# Scenario 1"))

      assert %WorkItem{stage_id: @verify} = reload(work_item)
      assert %DispatchRun{workflow: "verify-a-ticket"} = newest_run(work_item)
    end

    test "skips/1 lists only the work item's skips, each stored under its work item's organisation",
         %{scope: scope} do
      work_item = at_verify!(scope, fn _work_item -> :ok end)
      %{scope: other} = sign_up_fixture()
      other_item = at_verify!(other, fn _work_item -> :ok end)

      assert [%{after_attempt: 1}] = Stages.skips(work_item)
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

      assert Stages.proposed_track_with_reason(work_item) == %{
               id: "fast-track",
               reason: nil,
               kind: nil
             }

      assert Stages.proposed_track(work_item) == "fast-track"
    end

    # The end of a run that pushes a proposal and a verdict for each of `track_maps`, oldest
    # first.
    defp proposing_many(track_maps) do
      fn run, registered ->
        proposal_only().(run, registered)

        for track_map <- track_maps do
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
    end

    defp proposed(track, kind), do: %{"id" => track, "reason" => "x", "kind" => kind}

    test "the kind of a proposed track is read as sent, without the spaces around it", %{
      scope: scope
    } do
      tracked_process!(scope, ["standard", "fast-track"])

      work_item =
        take_in!(scope) |> end_run!(proposing_with(proposed("fast-track", " A kind <b> ")))

      assert Stages.proposed_track_with_reason(work_item) ==
               %{id: "fast-track", reason: "x", kind: "A kind <b>"}
    end

    test "a kind with no visible character is nil, and others are as sent", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])

      for {kind, shown} <- [
            {"\u2800", nil},
            {"\u200D", nil},
            {"\u3164 \u2800", nil},
            {"\u2800a", "\u2800a"},
            {"🙂", "🙂"},
            {"👨\u200D👩\u200D👧", "👨\u200D👩\u200D👧"},
            {"!", "!"},
            {"7", "7"},
            {String.duplicate("ä", 80), String.duplicate("ä", 80)}
          ] do
        work_item = take_in!(scope) |> end_run!(proposing_with(proposed("fast-track", kind)))
        assert Stages.proposed_track_with_reason(work_item).kind == shown
        assert Stages.track_kind(work_item, "fast-track") == shown
      end
    end

    test "track_kind/3 is the kind of the newest verdict with a track, where it is the track",
         %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])

      work_item = take_in!(scope) |> end_run!(proposing_with(proposed("fast-track", "Old")))
      assert Stages.track_kind(work_item, "fast-track") == "Old"

      # The newest verdict wins.
      work_item =
        take_in!(scope)
        |> end_run!(
          proposing_many([proposed("fast-track", "Old"), proposed("fast-track", "New")])
        )

      artifacts = Artifacts.list(work_item)
      assert Stages.track_kind(work_item, "fast-track", artifacts) == "New"
      assert Stages.track_kind(work_item, "fast-track") == "New"

      # A newer verdict of another track: no kind of an older one for the track it replaced.
      work_item =
        take_in!(scope)
        |> end_run!(
          proposing_many([
            proposed("fast-track", "Old"),
            %{"id" => "standard", "reason" => "x"}
          ])
        )

      assert Stages.track_kind(work_item, "fast-track") == nil
      assert Stages.track_kind(work_item, "standard") == nil
      assert Stages.track_kind(work_item, nil) == nil

      work_item =
        take_in!(scope)
        |> end_run!(
          proposing_many([proposed("fast-track", "Old"), proposed("standard", "Usual")])
        )

      assert Stages.track_kind(work_item, "standard") == "Usual"
      assert Stages.track_kind(work_item, "fast-track") == nil
    end

    test "a person's choice of a track an earlier verdict proposed has no kind", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])

      work_item =
        take_in!(scope)
        |> end_run!(
          proposing_many([proposed("fast-track", "Old"), proposed("standard", "Usual")])
        )

      assert {:ok, moved} = WorkItems.confirm(scope, work_item, 1, track: "fast-track")
      assert Stages.track(moved) == "fast-track"
      assert Stages.track_kind(moved, "fast-track") == nil
    end

    test "a verdict of an earlier take in has no kind in the next one", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      ticket = backlog_ticket_fixture(scope)
      {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

      work_item =
        work_item |> reload() |> end_run!(proposing_with(proposed("fast-track", "Earlier")))

      assert Stages.track_kind(work_item, "fast-track") == "Earlier"
      {:ok, _closed} = WorkItems.close(scope, reload(work_item))

      {:ok, _again} =
        WorkItems.take_in_again(scope, ticket.public_id, %{owner_id: scope.user.id})

      assert %WorkItem{take_in: 2} = work_item = reload(work_item)
      assert Stages.track_kind(work_item, "fast-track") == nil
      assert [_version] = versions(work_item, "verdict")
    end

    defmodule CountingStore do
      # The volume store, with a message `{:opened, key}` to the test for each file opened.
      @behaviour Apiary.Artifacts.Store

      alias Apiary.Artifacts.Store.Volume

      @impl true
      defdelegate commit(staged), to: Volume
      @impl true
      defdelegate discard(staged), to: Volume
      @impl true
      defdelegate stage(source, limit), to: Volume

      @impl true
      def open(key) do
        send(Application.fetch_env!(:apiary, __MODULE__), {:opened, key})
        Volume.open(key)
      end
    end

    test "track_kind/3 runs one query and reads only the newest verdict", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])

      work_item =
        take_in!(scope)
        |> end_run!(
          proposing_many([proposed("fast-track", "Old"), %{"id" => "standard", "reason" => "x"}])
        )

      artifacts = Artifacts.list(work_item)

      previous = Application.get_env(:apiary, Apiary.Artifacts.Store)
      Application.put_env(:apiary, Apiary.Artifacts.Store, adapter: CountingStore)
      Application.put_env(:apiary, CountingStore, self())

      on_exit(fn ->
        Application.delete_env(:apiary, CountingStore)

        if previous,
          do: Application.put_env(:apiary, Apiary.Artifacts.Store, previous),
          else: Application.delete_env(:apiary, Apiary.Artifacts.Store)
      end)

      handler = "track-kind-queries-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == parent, do: send(parent, :query)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert Stages.track_kind(work_item, "fast-track", artifacts) == nil

      assert_received {:opened, _newest}
      refute_received {:opened, _older}
      assert_received :query
      refute_received :query
    end

    test "no proposed track has no reason", %{scope: scope} do
      tracked_process!(scope, ["standard", "fast-track"])
      work_item = take_in!(scope) |> end_run!(understood_result())
      assert Stages.proposed_track_with_reason(work_item) == nil
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
               %{id: "fast-track", reason: "A small change.", kind: nil}

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

    test "a person's last output there counts as a later stage's input in what a run starts",
         %{scope: scope} do
      save!(scope, [
        explore_stage(),
        stage(@shape, "Shape", [], %{
          "outputs" => [%{"type" => "acceptance-criteria", "required" => true}],
          "gate" => %{"kind" => "none"}
        }),
        stage(@build, "Build", [%{"workflow" => "implement-changes"}], %{
          "inputs" => [%{"type" => "acceptance-criteria", "required" => true}]
        })
      ])

      work_item = at_shape!(scope)
      assert %WorkItem{stage_id: @shape, stage_state: :at_gate} = work_item

      assert Stages.starts(work_item, {:version_added, "acceptance-criteria"}) ==
               {:run, "implement-changes"}

      {:ok, _version} = Stages.add_version(scope, work_item, "acceptance-criteria", file("a.md"))

      assert %WorkItem{stage_id: @build, stage_state: :running} = reload(work_item)
      assert %DispatchRun{stage_id: @build, workflow: "implement-changes"} = newest_run(work_item)
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

      # The run ended and pushes nothing more; a person adds the newer version.
      {:ok, _version} =
        Stages.Artifacts.push({:person, scope}, work_item, "proposal", a_proposal(),
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
               }
             ] = Enum.filter(Stages.artifact_index(work_item), &(&1.type == "proposal"))
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

      {:ok, _version} =
        Stages.Artifacts.push({:person, scope}, work_item, "spec", spec.("## The spec"),
          stage_id: @shape
        )

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
      {:ok, _version} =
        Stages.Artifacts.push({:person, scope}, work_item, "spec", spec.("## The new spec"),
          stage_id: @shape
        )

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

      # A run with no verdict in the loop's last round.
      work_item = take_in!(scope) |> end_run!(nil)
      assert %Escalation{cause: :round_limit} = escalation(work_item)

      assert {:ok, %WorkItem{stage_state: :at_gate, stage_entry: 1}} =
               Stages.resolve_escalation(scope, work_item, :accept, nil,
                 expect_stage: reload(work_item).stage_id
               )

      assert escalation(work_item) == nil
      assert [%{check: :missing}] = Stages.status(work_item).outputs
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
      {:ok, _type} =
        Artifacts.create_type(scope, scope.workspace, %{
          "name" => "verification",
          "base_view" => "document"
        })

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
            [%{filename: "#{type}.md", content_type: "text/markdown", binary: "# Checked"}],
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
end
