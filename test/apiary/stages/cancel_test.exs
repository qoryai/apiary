defmodule Apiary.Stages.CancelTest do
  # What a member's cancel (`Apiary.Runs.Cancel`) changes for the stage of a run of a work
  # item: whatever the run's exit, its open questions, its verdict, its outputs and its
  # proposal do not count, and the stage escalates `run_stopped` with the person in its
  # point. A run with no mark, a time-limit cancel among them, keeps today's behaviour.
  # Not async: a test sets the store adapter, the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Processes, Stages}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias Apiary.Stages.Escalation
  alias Apiary.WorkItems.{Explore, ExploreView, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @build "st_6ns22c4pav"

  # A run that ended by the gateway's end of a member's cancel, with no outcome.
  @cancelled_exit %{
    state: "cancelled",
    exit_state: "cancelled",
    exit_reason: "cancelled_by_member",
    outcome_state: nil,
    outcome_time: nil,
    outcome_received_at: nil,
    outcome_digest: nil
  }

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, name: hd(String.split(scope.user.email, "@"))}
  end

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp escalation(work_item),
    do:
      Repo.one(
        from e in Escalation, where: e.work_item_id == ^work_item.id and is_nil(e.resolved_at)
      )

  # A process of one stage whose workflow is not Explore's: its runs report a verdict.
  defp capture_demo!(scope) do
    document = %{
      "schema" => "qory.process/v1",
      "machine" => "default",
      "stages" => [
        %{
          "id" => @explore,
          "name" => "Explore",
          "inputs" => [],
          "sequence" => [%{"workflow" => "triage-review", "when" => %{"feedback" => "new"}}],
          "outputs" => [],
          "gate" => %{"kind" => "none"}
        },
        %{
          "id" => @build,
          "name" => "Build",
          "inputs" => [],
          "sequence" => [%{"workflow" => "capture-demo"}],
          "outputs" => [],
          "gate" => %{"kind" => "person", "approvers" => "members"}
        }
      ]
    }

    {:ok, _version} = Processes.save(scope, scope.workspace, document)
  end

  # The run pushes with `push`, then a member of `scope` cancels it.
  defp then_cancelled(scope, push) do
    fn run, registered ->
      push.(run, registered)
      mark!(registered, scope)
    end
  end

  defp mark!(%Run{id: id}, scope) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [cancel_requested_at: DateTime.utc_now(), cancel_requested_by_id: scope.user.id]
      )
  end

  defp verdict(verdict) do
    fn run, _registered ->
      {:ok, _version} =
        Stages.Artifacts.push_json(
          {:run, run},
          Repo.get!(WorkItem, run.work_item_id),
          "verdict",
          %{"verdict" => verdict},
          stage_id: run.stage_id
        )
    end
  end

  defp passed_and_asked do
    fn run, registered ->
      verdict("passed").(run, registered)
      push_output!(run, registered, questions_result(["Which basket?"]))
    end
  end

  describe "a run of a workflow other than Explore" do
    test "a cancelled run's verdict and question do not count: the stage escalates", %{
      scope: scope,
      name: name
    } do
      capture_demo!(scope)

      for exit <- [@cancelled_exit, %{}] do
        work_item =
          take_in_fixture!(scope)
          |> end_run!(then_cancelled(scope, passed_and_asked()), exit)

        assert work_item.stage_state == :escalated

        assert %Escalation{
                 cause: :run_stopped,
                 points: [
                   %{"text" => text, "action" => "run_again"}
                 ]
               } = escalation(work_item)

        assert text == "The run stopped: #{name} cancelled it."
        assert %{verdict: nil} = hd(Stages.runs(work_item))
      end
    end

    test "a time-limit cancel with no mark keeps today's: its verdict counts", %{scope: scope} do
      capture_demo!(scope)

      work_item =
        take_in_fixture!(scope)
        |> end_run!(verdict("passed"), %{@cancelled_exit | exit_reason: "timeout"})

      refute work_item.stage_state == :escalated
      assert %{verdict: :passed} = hd(Stages.runs(work_item))
    end

    test "its question keeps neither its end nor the next run's waiting", %{scope: scope} do
      capture_demo!(scope)

      asked = fn run, registered ->
        push_output!(run, registered, questions_result(["Which?"]))
      end

      work_item =
        take_in_fixture!(scope) |> end_run!(then_cancelled(scope, asked), @cancelled_exit)

      assert work_item.stage_state == :escalated

      # The next round: its run passes, and the cancelled run's open question keeps nothing
      # waiting.
      {:ok, work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil, expect_stage: @build)

      assert %WorkItem{stage_state: :running} = reload(work_item)
      work_item = end_run!(reload(work_item), verdict("passed"))

      refute work_item.stage_state in [:waiting_answers, :escalated]
    end

    test "a paused run a member cancelled reads as stopped", %{scope: scope, name: name} do
      capture_demo!(scope)

      paused = %{
        @cancelled_exit
        | state: "paused",
          exit_state: "paused",
          exit_reason: "model_key_limit"
      }

      work_item =
        take_in_fixture!(scope)
        |> end_run!(then_cancelled(scope, verdict("passed")), paused)

      assert %Escalation{cause: :run_stopped, points: [%{"text" => text}]} =
               escalation(work_item)

      assert text == "The run stopped: #{name} cancelled it."
    end
  end

  describe "a run of Explore" do
    test "its proposal fails the Exists check and is not the take in's", %{
      scope: scope,
      name: name
    } do
      work_item = take_in_fixture!(scope)
      run = newest_run(work_item)

      work_item =
        end_run!(
          work_item,
          then_cancelled(scope, &push_output!(&1, &2, understood_result())),
          @cancelled_exit
        )

      # The proposal stays, marked.
      assert [%{type: "proposal", versions: [version]}] = Artifacts.list(work_item)
      assert Artifacts.cancelled?(version)

      refute Artifacts.exists?(work_item, @explore, "proposal")
      assert Stages.missing_outputs(work_item) == ["proposal"]
      # Nor is it the stage's newest output, which an approval would take.
      assert %{outputs: [%{type: "proposal", version: nil}]} = Stages.status(work_item)
      assert %DispatchRun{result_outcome: :none} = Repo.get!(DispatchRun, run.id)
      assert Explore.proposal_version(work_item.id, work_item.take_in, 1) == nil

      assert %Escalation{cause: :run_stopped, points: [%{"text" => text}]} =
               escalation(work_item)

      assert text == "The run stopped: #{name} cancelled it."
    end

    test "its proposal does not count for a later run of the take in", %{scope: scope} do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(
          then_cancelled(scope, &push_output!(&1, &2, understood_result())),
          @cancelled_exit
        )

      assert work_item.stage_state == :escalated

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil, expect_stage: @explore)

      # The next run pushes nothing: the cancelled run's proposal is not at the gate.
      work_item = end_run!(reload(work_item), nil)

      assert %DispatchRun{attempt: 2, result_outcome: :none} = newest_run(work_item)
      refute work_item.stage_state == :at_gate
    end

    test "the Explore tab shows no proposal of the cancelled run as the take in's", %{
      scope: scope
    } do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(
          then_cancelled(scope, &push_output!(&1, &2, understood_result())),
          @cancelled_exit
        )

      assert %{proposal: nil} = ExploreView.explore(reload(work_item), DateTime.utc_now())
    end

    test "the Explore tab shows the proposal before the cancelled run's", %{scope: scope} do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(&push_output!(&1, &2, understood_result()), %{
          @cancelled_exit
          | state: "failed",
            exit_state: "failed",
            exit_reason: "agent_exited"
        })

      assert work_item.stage_state == :escalated

      {:ok, _work_item} =
        Stages.resolve_escalation(scope, work_item, :another_round, nil, expect_stage: @explore)

      work_item =
        end_run!(
          reload(work_item),
          then_cancelled(scope, &push_output!(&1, &2, understood_result())),
          @cancelled_exit
        )

      assert [%{type: "proposal", versions: [_second, _first]}] = Artifacts.list(work_item)
      assert %{proposal: %{version: 1}} = ExploreView.explore(work_item, DateTime.utc_now())
    end

    test "a run with no mark keeps its proposal", %{scope: scope} do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(&push_output!(&1, &2, understood_result()), @cancelled_exit)

      assert [%{versions: [version]}] = Artifacts.list(work_item)
      refute Artifacts.cancelled?(version)
      assert Artifacts.exists?(work_item, @explore, "proposal")
    end

    test "its question does not keep its end waiting", %{scope: scope} do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(
          then_cancelled(scope, &push_output!(&1, &2, questions_result(["Which?"]))),
          @cancelled_exit
        )

      assert work_item.stage_state == :escalated
      assert %DispatchRun{result_outcome: :none} = newest_run(work_item)
    end

    test "the Explore tab shows no question of the cancelled run as open", %{scope: scope} do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(
          then_cancelled(scope, &push_output!(&1, &2, questions_result(["Which?"]))),
          @cancelled_exit
        )

      view = ExploreView.explore(reload(work_item), DateTime.utc_now())
      assert view.questions == []
      # The run's fold keeps the question it asked.
      assert %{asked: 1} = view.run
    end

    test "a run with no mark keeps its question open on the Explore tab", %{scope: scope} do
      work_item =
        take_in_fixture!(scope)
        |> end_run!(&push_output!(&1, &2, questions_result(["Which?"])), @cancelled_exit)

      assert %{questions: [%{text: "Which?", state: :open}]} =
               ExploreView.explore(reload(work_item), DateTime.utc_now())
    end
  end

  test "a run lost for good with the mark escalates with the person", %{
    scope: scope,
    name: name
  } do
    work_item = take_in_fixture!(scope)
    run = newest_run(work_item)
    now = DateTime.utc_now()

    %Run{
      number: Apiary.RunEventsFixtures.next_run_number(run.organisation_id, run.workspace_id),
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      node_run_id: run.run_id,
      dispatch_run_id: run.id
    }
    |> Ecto.Changeset.change(%{
      state: "lost",
      lost_at: now,
      silenced_at: now,
      cancel_requested_at: DateTime.add(now, -60, :second),
      cancel_requested_by_id: scope.user.id
    })
    |> Apiary.RunEventsFixtures.insert_run!()

    run |> Ecto.Changeset.change(state: :ended, end_cause: :lost) |> Repo.update!()
    {:ok, _told} = Repo.transact(fn -> {:ok, Stages.run_ended(run.id)} end)

    assert %Escalation{cause: :run_stopped, points: [%{"text" => text}]} =
             escalation(reload(work_item))

    assert text == "The run stopped: #{name} cancelled it."
  end

  defp take_in_fixture!(scope), do: taken_in_fixture(scope)
end
