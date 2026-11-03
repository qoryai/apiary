defmodule Apiary.WorkItems.ProposalCommentCase do
  # A member's comment on Explore's proposal (`Apiary.WorkItems.answer/4` with a text),
  # step by step: the comment sent and kept on the proposal's version, the take in's next
  # run queued, that run's input with the proposal and the changes, the run's update of
  # the proposal, and the comment marked done. A run that asks, fails or ends without a
  # result leaves it open. At the run limit a comment adds one run. Each module that uses
  # this case runs the tests on one state of the workflow model.
  @moduledoc false

  defmodule Resolver do
    # The explore contract's schemas from `priv/contract`, and the integration contract's
    # it refers to from the vendored fixtures. Nothing is fetched.
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  defmacro __using__(_opts) do
    quote do
      import Ecto.Query, only: [from: 2]
      import Apiary.OrganisationsFixtures
      import Apiary.StagesFixtures
      import Apiary.WorkItemsFixtures

      alias Apiary.{Repo, Stages, WorkItems}
      alias Apiary.Audit.Entry
      alias Apiary.Dispatches.{DispatchRun, Inputs}
      alias Apiary.WorkItems.{Answer, WorkItem, WorkItemEvent}

      @comment "Offer a replacement first, then a refund."

      setup do
        %{scope: scope} = sign_up_fixture()
        %{scope: scope}
      end

      defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

      defp comments(work_item),
        do:
          Repo.all(
            from a in Answer,
              where: a.work_item_id == ^work_item.id and is_nil(a.question),
              order_by: a.attempt
          )

      defp runs(work_item),
        do:
          Repo.all(
            from r in DispatchRun,
              where: r.work_item_id == ^work_item.id,
              order_by: [r.take_in, r.attempt],
              select: {r.attempt, r.of, r.state}
          )

      defp answered_events(work_item),
        do:
          Repo.all(
            from e in WorkItemEvent,
              where: e.work_item_id == ^work_item.id and e.kind == :answered,
              order_by: [asc: e.at, asc: e.id],
              select: e.data
          )

      defp entries(work_item),
        do:
          Repo.all(
            from e in Entry,
              where: e.action == "work_item.answer" and e.subject_id == ^work_item.id,
              order_by: e.inserted_at,
              select: e.details
          )

      defp proposed!(scope, message \\ "## What this is\n\nThe basket keeps the price.") do
        scope |> taken_in_fixture() |> end_run!(understood_result(%{"message" => message}))
      end

      defp failed!(work_item) do
        run = newest_run(work_item)

        {1, _rows} =
          Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
            set: [state: :ended, end_cause: :run_ended]
          )

        registered =
          Repo.insert!(%Apiary.Runs.Run{
            organisation_id: run.organisation_id,
            workspace_id: run.workspace_id,
            node_run_id: run.run_id,
            dispatch_run_id: run.id,
            state: "completed",
            exit_state: "completed",
            outcome_state: "succeeded",
            outcome_time: DateTime.utc_now(),
            outcome_received_at: DateTime.utc_now()
          })

        result_event!(registered, 7, %{"is_error" => true, "result" => "The model stopped."})
        run.id |> Apiary.Dispatches.Settle.settle() |> Apiary.Dispatches.broadcast()
        assert %DispatchRun{result_outcome: :error} = Repo.get!(DispatchRun, run.id)
        reload(work_item)
      end

      # Two runs ask, each answered; the third proposes: the take in's last run.
      defp at_the_limit!(scope) do
        work_item = taken_in_fixture(scope) |> end_run!(questions_result(["Which basket?"]))
        {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The small one."})
        work_item = end_run!(work_item, questions_result(["Which sale?"]))
        {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The spring one."})
        end_run!(work_item, understood_result())
      end

      # The input of the newest run of `work_item`, as a handover gives it, checked
      # against the contract's inputs schema.
      defp input!(work_item) do
        work_item = reload(work_item)
        run = %{domain: "software", target: %{system: "forge", path: "acme/shop"}}
        {:ok, inputs} = Inputs.explore(work_item, newest_run(work_item), run)
        inputs = inputs |> Jason.encode!() |> Jason.decode!()

        validator =
          JSV.build!(%{"$ref" => "https://qory.dev/contracts/explore/v1/inputs.schema.json"},
            resolver:
              {Apiary.WorkItems.ProposalCommentCase.Resolver,
               [
                 Path.expand("../../fixtures/contract", __DIR__),
                 Application.app_dir(:apiary, "priv/contract")
               ]},
            formats: true
          )

        assert {:ok, _} = JSV.validate(inputs, validator)
        inputs
      end

      describe "a comment on the proposal" do
        test "1. is sent where the proposal waits, and checked", %{scope: scope} do
          work_item = proposed!(scope)

          assert WorkItems.answer(scope, work_item, 1, " \r\n ") ==
                   {:error, {:invalid, %{comment: :blank}}}

          assert WorkItems.answer(scope, work_item, 1, String.duplicate("é", 2001)) ==
                   {:error, {:invalid, %{comment: {:too_long, 2000}}}}

          assert WorkItems.answer(scope, work_item, 1, "a\u200Bb") ==
                   {:error, {:invalid, %{comment: :characters}}}

          assert WorkItems.answer(scope, work_item, 1, %{"1" => @comment}) ==
                   {:error, {:invalid, :form}}

          assert WorkItems.answer(scope, work_item, 2, @comment) == {:error, :stale}
          assert comments(work_item) == []
          assert runs(work_item) == [{1, 3, :ended}]

          assert {:ok, %WorkItem{}} =
                   WorkItems.answer(scope, work_item, 1, String.duplicate("é", 2000))
        end

        test "2. is kept on the proposal's version, with its event and its entry", %{
          scope: scope
        } do
          work_item = proposed!(scope)
          assert {:ok, _} = WorkItems.answer(scope, work_item, 1, " #{@comment}\r\n")

          assert [
                   %Answer{
                     take_in: 1,
                     attempt: 1,
                     position: 1,
                     question: nil,
                     custom: nil,
                     answer: @comment,
                     proposal_version: 1,
                     done_version: nil,
                     done_at: nil
                   } = comment
                 ] = comments(work_item)

          assert comment.answered_by_id == scope.user.id

          data = %{"take_in" => 1, "attempt" => 1, "count" => 1, "comment" => true}
          assert answered_events(work_item) == [data]
          assert entries(work_item) == [data]

          # A comment is no answer to a question: the next run's answers have none.
          assert WorkItems.take_in_answers(work_item, 1) == []

          assert [%{text: @comment, attempt: 1, version: 1, done_version: nil}] =
                   WorkItems.explore(scope, reload(work_item)).comments
        end

        test "3. queues the take in's next run", %{scope: scope} do
          work_item = proposed!(scope)
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)

          assert runs(work_item) == [{1, 3, :ended}, {2, 3, :waiting}]
          assert WorkItems.explore(scope, reload(work_item)).status == :queued
          assert_stage_after_comment(reload(work_item))
        end

        test "4. the next run's input has the proposal and the changes", %{scope: scope} do
          work_item = proposed!(scope, "## What this is\n\nThe basket keeps the price.")
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)

          inputs = input!(work_item)
          assert inputs["run"] == %{"attempt" => 2, "of" => 3}
          assert inputs["proposal"] == "## What this is\n\nThe basket keeps the price."
          assert inputs["answers"] == []
          name = Inputs.person_name(scope.user.id)

          assert [%{"text" => @comment, "by" => %{"name" => ^name}, "at" => at}] =
                   inputs["changes"]

          assert at =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
        end

        test "5. the run's updated proposal is its next version", %{scope: scope} do
          work_item = proposed!(scope)
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)

          work_item =
            end_run!(work_item, understood_result(%{"message" => "## What this is\n\nAgain."}))

          explore = WorkItems.explore(scope, work_item)

          assert %{status: :confirm, run: %{attempt: 2, version: 2}} = explore
          assert explore.run.proposal == %{message: "## What this is\n\nAgain."}
          assert_proposal_versions(work_item, 2)
        end

        test "6. the comment is marked done in the version that read it", %{scope: scope} do
          work_item = proposed!(scope)
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
          before = DateTime.utc_now()
          work_item = end_run!(work_item, understood_result())

          assert [%Answer{proposal_version: 1, done_version: 2, done_at: done_at}] =
                   comments(work_item)

          assert DateTime.compare(done_at, before) != :lt

          assert [%{version: 1, done_version: 2, done_at: %DateTime{}}] =
                   WorkItems.explore(scope, work_item).comments

          # Done, the comment is no change for a run after it.
          {:ok, _} = WorkItems.answer(scope, work_item, 2, "Name the refund rule.")
          assert [%{"text" => "Name the refund rule."}] = input!(work_item)["changes"]
        end
      end

      describe "a comment stays open" do
        test "when the next run asks questions, and the run after them reads it", %{
          scope: scope
        } do
          work_item = proposed!(scope)
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
          work_item = end_run!(work_item, questions_result(["Which refund?"]))

          assert [%Answer{done_version: nil, done_at: nil}] = comments(work_item)

          {:ok, _} = WorkItems.answer(scope, work_item, 2, %{"1" => "The full one."})
          inputs = input!(work_item)
          assert [%{"text" => @comment}] = inputs["changes"]
          assert [%{"answer" => "The full one.", "custom" => true}] = inputs["answers"]

          work_item = end_run!(work_item, understood_result())
          assert [%Answer{done_version: 2}] = comments(work_item)
        end

        test "when the next run fails", %{scope: scope} do
          work_item = proposed!(scope)
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
          work_item = failed!(work_item)

          assert [%Answer{done_version: nil, done_at: nil}] = comments(work_item)
        end

        test "when the next run ends without a result", %{scope: scope} do
          work_item = proposed!(scope)
          {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
          work_item = end_run!(work_item, nil)

          assert [%Answer{done_version: nil, done_at: nil}] = comments(work_item)
        end
      end

      describe "the run limit" do
        test "a comment on the proposal of run 3 of 3 adds run 4 of 4", %{scope: scope} do
          work_item = at_the_limit!(scope)

          assert %{status: :confirm, run: %{attempt: 3, of: 3}} =
                   WorkItems.explore(scope, work_item)

          assert {:ok, _} = WorkItems.answer(scope, work_item, 3, @comment)

          assert runs(work_item) ==
                   [{1, 3, :ended}, {2, 3, :ended}, {3, 3, :ended}, {4, 4, :waiting}]

          assert input!(work_item)["run"] == %{"attempt" => 4, "of" => 4}

          work_item = end_run!(work_item, understood_result())

          assert %{status: :confirm, run: %{attempt: 4, of: 4}} =
                   WorkItems.explore(scope, work_item)

          assert [%Answer{done_version: 2}] = comments(work_item)
        end

        test "a run that keeps asking still stops at 3", %{scope: scope} do
          work_item = taken_in_fixture(scope)

          work_item =
            Enum.reduce(1..2, work_item, fn attempt, work_item ->
              work_item = end_run!(work_item, questions_result(["Which basket?"]))
              {:ok, _} = WorkItems.answer(scope, work_item, attempt, %{"1" => "The small one."})
              work_item
            end)

          work_item = end_run!(work_item, questions_result(["Which basket?"]))

          assert WorkItems.answer(scope, work_item, 3, %{"1" => "The small one."}) ==
                   {:error, :used_up}

          assert length(runs(work_item)) == 3
        end
      end
    end
  end
end

defmodule Apiary.WorkItems.ProposalCommentTest do
  # A comment on the proposal with the workflow model on: the work item in Explore, at its
  # gate, and the stage runner stores the proposal and marks the comment.
  use Apiary.DataCase, async: false

  @moduletag needs: [:factory, :workflow_model]

  use Apiary.WorkItems.ProposalCommentCase

  alias Apiary.Processes

  defp assert_stage_after_comment(work_item) do
    assert %WorkItem{stage_id: "st_r79kph11eg", stage_state: :running} = work_item
  end

  defp assert_proposal_versions(work_item, count) do
    numbers =
      for a <- Apiary.Artifacts.list(work_item),
          a.type == "proposal",
          v <- a.versions,
          do: {v.number, v.writer}

    assert Enum.sort(numbers) == for(n <- 1..count, do: {n, :run})
  end

  test "a member not among the approvers the stage lists may not comment", %{scope: scope} do
    member = member_fixture(scope)
    stages = Processes.current(scope.workspace).document["stages"]

    stages =
      Enum.map(stages, fn
        %{"id" => "st_r79kph11eg"} = stage ->
          put_in(stage, ["gate"], %{
            "kind" => "person",
            "approvers" => %{"members" => [scope.user.id]}
          })

        stage ->
          stage
      end)

    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => stages
      })

    work_item = proposed!(scope)

    assert WorkItems.answer(member.scope, work_item, 1, @comment) == {:error, :not_approver}
    assert comments(work_item) == []
    assert {:ok, _} = WorkItems.answer(scope, work_item, 1, @comment)
  end
end

defmodule Apiary.WorkItems.ProposalCommentOffTest do
  # A comment on the proposal with the workflow model off: Explore's queue alone, and the
  # settle of the run's end marks the comment.
  use Apiary.DataCase, async: false

  @moduletag needs: :factory
  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]

  use Apiary.WorkItems.ProposalCommentCase

  defp assert_stage_after_comment(work_item) do
    refute Stages.on?()
    assert %WorkItem{stage_id: nil, stage_state: nil} = work_item
  end

  defp assert_proposal_versions(work_item, _count) do
    assert Apiary.Artifacts.list(work_item) == []
  end

  test "any member of the workspace may comment", %{scope: scope} do
    member = member_fixture(scope)
    work_item = proposed!(scope)
    assert {:ok, _} = WorkItems.answer(member.scope, work_item, 1, @comment)
  end
end
