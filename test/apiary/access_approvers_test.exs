defmodule Apiary.AccessApproversTest do
  # The approver rule of `Apiary.Access` (its moduledoc, step 9): `gate.approve`,
  # `work_item.confirm` and `work_item.review_comment` asked of a work item allow only the
  # approvers of the stage it is in, where the stage lists them. An answer to the
  # questions stays every member's.
  # Not async: a test switches the workflow model off, the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Access, Artifacts, Processes, Repo, Stages, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Explore.{Questions, ReviewComments}
  alias Apiary.Organisations.Workspace
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.{Confirmation, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @approver_actions [:"gate.approve", :"work_item.confirm", :"work_item.review_comment"]
  # The approver-only actions that are not part of the workflow model.
  @factory_actions [:"work_item.confirm", :"work_item.review_comment"]

  setup do
    %{scope: scope} = sign_up_fixture()
    member = member_fixture(scope)
    %{scope: scope, member: member.scope, membership: member.membership}
  end

  # The workspace's process with Explore's gate set to `approvers`, saved as the current
  # version.
  defp explore_approvers!(scope, approvers) do
    stages =
      Enum.map(Processes.current(scope.workspace).document["stages"], fn
        %{"id" => @explore} = stage ->
          put_in(stage, ["gate"], %{"kind" => "person", "approvers" => approvers})

        stage ->
          stage
      end)

    {:ok, _version} =
      Processes.save(scope, scope.workspace, %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => stages
      })
  end

  # A work item at Explore's gate, its proposal waiting.
  defp proposed!(scope),
    do: scope |> taken_in_fixture() |> end_run!(understood_result()) |> reload()

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp workflow_model_off do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, List.delete(previous, :workflow_model))
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
  end

  describe "a stage that lists approvers" do
    setup %{scope: scope} do
      explore_approvers!(scope, %{"members" => [scope.user.id]})
      %{work_item: proposed!(scope)}
    end

    test "Run another round with only a decision's option again, from a member who is not among them, sends nothing",
         %{scope: scope, member: member, work_item: work_item} do
      [number] = work_item.id |> Questions.take_in_runs(work_item.take_in) |> MapSet.to_list()
      at = "2026-11-04T10:00:00Z"

      decided = %{
        "id" => "q1",
        "question" => "Which store keeps the baskets?",
        "options" => [
          %{"title" => "Redis", "explanation" => "The store the other services use."},
          %{"title" => "Postgres", "explanation" => "The database of the storefront."}
        ],
        "state" => "decided",
        "asked" => %{"run" => number, "at" => at},
        "decision" => %{
          "option" => "Redis",
          "reason" => "The other services use Redis.",
          "run" => number,
          "at" => at
        }
      }

      {:ok, _version} =
        Artifacts.push({:member_action, scope}, work_item, "questions", [
          Questions.file(%{"questions" => [decided]})
        ])

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Also check the basket page.")

      runs = fn ->
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)
      end

      count = runs.()
      round = %{answers: [%{"id" => "q1", "option" => "Redis"}]}

      # With no answer left, the round sends the open review comment, which only an
      # approver may.
      assert WorkItems.another_round(member, reload(work_item), 1, round) ==
               {:error, :not_approver}

      assert runs.() == count

      assert {:ok, _} = WorkItems.another_round(scope, reload(work_item), 1, round)
      assert runs.() == count + 1
    end

    test "refuses a member who is not among them each approver-only action", %{
      member: member,
      work_item: work_item
    } do
      for action <- @approver_actions do
        refute Access.can?(member, action, work_item), "#{action}"
        assert Access.authorize(member, action, work_item) == {:error, :not_approver}
      end
    end

    test "allows the approver it lists", %{scope: scope, work_item: work_item} do
      for action <- @approver_actions do
        assert Access.can?(scope, action, work_item), "#{action}"
        assert Access.authorize(scope, action, work_item) == :ok
      end
    end

    test "asks the role first", %{scope: scope, work_item: work_item} do
      # The instance's scope has no person, so no list has it; its role refuses first.
      instance = Scope.for_instance(scope.organisation, scope.workspace)

      for action <- @approver_actions do
        assert Access.authorize(instance, action, work_item) == {:error, :forbidden}
      end
    end

    test "leaves the workspace to the role alone", %{member: member, work_item: work_item} do
      workspace = Repo.get!(Workspace, work_item.workspace_id)

      for action <- @approver_actions do
        assert Access.can?(member, action, workspace), "#{action}"
      end
    end

    test "leaves an answer to the questions open to every member", %{
      member: member,
      work_item: work_item
    } do
      assert Access.can?(member, :"work_item.answer", work_item)
      assert Access.authorize(member, :"work_item.answer", work_item) == :ok
    end

    test "allows every member on a work item the runner did not place", %{
      member: member,
      work_item: work_item
    } do
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [stage_id: nil, stage_state: nil]
      )

      for action <- @approver_actions do
        assert Access.can?(member, action, reload(work_item)), "#{action}"
      end
    end

    test "a move of a member who is not among them changes nothing", %{
      scope: scope,
      member: member,
      work_item: work_item
    } do
      expect = [expect_stage: @explore]
      assert Stages.approve(member, work_item, nil, expect) == {:error, :not_approver}
      assert Stages.move(member, work_item, @explore, nil, expect) == {:error, :not_approver}

      assert WorkItems.review_comment(member, work_item, 1, "Keep the price.") ==
               {:error, :not_approver}

      assert WorkItems.answer(member, work_item, 1, "Keep the price.") ==
               {:error, :not_approver}

      assert ReviewComments.newest(reload(work_item)) == nil

      {:ok, _} = WorkItems.review_comment(scope, work_item, 1, "Keep the price.")
      {_version, document} = ReviewComments.newest(reload(work_item))
      [%{"id" => id}] = ReviewComments.entries(document)

      assert WorkItems.reply(member, reload(work_item), 1, id, "Agreed.") ==
               {:error, :not_approver}

      assert WorkItems.send_review_comments(member, reload(work_item), 1) ==
               {:error, :not_approver}

      assert WorkItems.confirm(member, reload(work_item), 1) == {:error, :not_approver}
      refute Repo.get_by(Confirmation, work_item_id: work_item.id)
      assert %{stage_id: @explore, stage_state: :at_gate} = reload(work_item)
      assert {_version, ^document} = ReviewComments.newest(reload(work_item))

      assert {:ok, _confirmed} = WorkItems.confirm(scope, reload(work_item), 1)
      assert Repo.get_by(Confirmation, work_item_id: work_item.id)
    end

    test "a member action of a member who is not among them writes no review comments", %{
      member: member,
      work_item: work_item
    } do
      file = ReviewComments.file(%{"review_comments" => []})

      assert Artifacts.push({:member_action, member}, work_item, "review-comments", [file]) ==
               {:error, :not_approver}

      assert ReviewComments.newest(reload(work_item)) == nil
    end

    test "allows every member with the workflow model off", %{
      member: member,
      work_item: work_item
    } do
      workflow_model_off()

      for action <- @factory_actions do
        assert Access.can?(member, action, work_item), "#{action}"
        assert Access.authorize(member, action, work_item) == :ok
      end

      # The gates are part of the workflow model: off, the action is not found to anyone.
      assert Access.authorize(member, :"gate.approve", work_item) == {:error, :not_found}
    end
  end

  test "a stage that lists none allows every member", %{scope: scope, member: member} do
    # The default process: every gate is every member's.
    work_item = proposed!(scope)

    for action <- @approver_actions do
      assert Access.can?(member, action, work_item), "#{action}"
    end
  end

  test "a work item with its process version loaded is answered from it", %{
    scope: scope,
    member: member
  } do
    explore_approvers!(scope, %{"members" => [scope.user.id]})
    work_item = scope |> proposed!() |> Repo.preload(:process_version)

    # The loaded version, changed in memory only: Explore's gate lists the member, not the
    # owner. The stored version lists the owner, so only an answer that reads the loaded
    # one allows the member and refuses the owner.
    stages =
      Enum.map(work_item.process_version.document["stages"], fn
        %{"id" => @explore} = stage ->
          put_in(stage, ["gate", "approvers"], %{"members" => [member.user.id]})

        stage ->
          stage
      end)

    work_item =
      put_in(work_item.process_version.document["stages"], stages)

    for action <- @approver_actions do
      assert Access.can?(member, action, work_item), "#{action}"
      refute Access.can?(scope, action, work_item), "#{action}"
    end
  end

  describe "questions at a stage that lists approvers" do
    setup %{scope: scope} do
      explore_approvers!(scope, %{"members" => [scope.user.id]})

      work_item =
        scope |> taken_in_fixture() |> end_run!(questions_result(["Which sale?"])) |> reload()

      %{work_item: work_item}
    end

    test "a member who is not among them answers them", %{member: member, work_item: work_item} do
      assert {:ok, _} = WorkItems.answer(member, work_item, 1, %{"1" => "The spring sale."})

      assert {version, document} = Questions.newest(reload(work_item))
      assert version.writer == :person and version.user_id == member.user.id
      assert [%{"state" => "answered"}] = document["questions"]
    end

    test "Run another round with answers alone, from a member who is not among them, runs the next round",
         %{member: member, work_item: work_item} do
      round = %{answers: [%{"id" => "q1", "option" => nil, "note" => "The spring sale."}]}
      assert {:ok, _} = WorkItems.another_round(member, work_item, 1, round)
      assert %WorkItem{stage_state: :running} = reload(work_item)

      assert {_version, %{"questions" => [%{"state" => "answered"}]}} =
               Questions.newest(reload(work_item))
    end

    test "Run another round with answers and a comment, from a member who is not among them, writes nothing",
         %{member: member, work_item: work_item} do
      {_version, before} = Questions.newest(work_item)

      runs = fn ->
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)
      end

      count = runs.()

      round = %{
        answers: [%{"id" => "q1", "option" => nil, "note" => "The spring sale."}],
        comment: "Also check the basket page."
      }

      assert WorkItems.another_round(member, work_item, 1, round) == {:error, :not_approver}

      # The answer is not written either: the move writes all of it or nothing.
      assert {_version, ^before} = Questions.newest(reload(work_item))
      assert ReviewComments.newest(reload(work_item)) == nil
      assert runs.() == count
    end

    test "a member action of a member who is not among them writes the questions", %{
      member: member,
      work_item: work_item
    } do
      {_version, document} = Questions.newest(work_item)

      assert {:ok, version} =
               Artifacts.push({:member_action, member}, work_item, "questions", [
                 Questions.file(document)
               ])

      assert version.user_id == member.user.id
    end
  end

  describe "an escalated stage that lists approvers" do
    # Explore's run pushed a proposal and its stage needs a mockup too: the stage
    # escalated, `check_failed`, while the proposal waits, and the run decided q1.
    setup %{scope: scope} do
      stages =
        Enum.map(Processes.current(scope.workspace).document["stages"], fn
          %{"id" => @explore} = stage ->
            Map.merge(stage, %{
              "gate" => %{"kind" => "person", "approvers" => %{"members" => [scope.user.id]}},
              "outputs" => [
                %{"type" => "proposal", "required" => true},
                %{"type" => "mockup", "required" => true}
              ]
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
      assert work_item.stage_state == :escalated
      assert %{status: :confirm} = WorkItems.explore(scope, work_item)
      decide!(scope, work_item)
      %{work_item: work_item}
    end

    defp decide!(scope, work_item) do
      [number] = work_item.id |> Questions.take_in_runs(work_item.take_in) |> MapSet.to_list()
      at = "2026-11-04T10:00:00Z"

      decided = %{
        "id" => "q1",
        "question" => "Which store keeps the baskets?",
        "options" => [
          %{"title" => "Redis", "explanation" => "The store the other services use."},
          %{"title" => "Postgres", "explanation" => "The database of the storefront."}
        ],
        "state" => "decided",
        "asked" => %{"run" => number, "at" => at},
        "decision" => %{
          "option" => "Redis",
          "reason" => "The other services use Redis.",
          "run" => number,
          "at" => at
        }
      }

      {:ok, _version} =
        Artifacts.push({:member_action, scope}, work_item, "questions", [
          Questions.file(%{"questions" => [decided]})
        ])
    end

    defp escalations(work_item),
      do:
        Repo.all(
          from e in Apiary.Stages.Escalation,
            where: e.work_item_id == ^work_item.id,
            select: {e.resolution, e.resolved_by_id}
        )

    defp settled_entries(work_item),
      do:
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.action == "gate.approve" and e.subject_id == ^work_item.id,
            select: {e.actor_id, e.details}
        )

    test "Run another round with answers, from a member who is not among them, settles nothing",
         %{member: member, work_item: work_item} do
      runs = fn ->
        Repo.aggregate(from(d in DispatchRun, where: d.work_item_id == ^work_item.id), :count)
      end

      count = runs.()
      round = %{answers: [%{"id" => "q1", "option" => "Postgres"}]}

      assert WorkItems.another_round(member, reload(work_item), 1, round) ==
               {:error, :not_approver}

      assert WorkItems.answer(member, reload(work_item), 1, [
               %{"id" => "q1", "option" => "Postgres"}
             ]) == {:error, :not_approver}

      assert runs.() == count
      assert %WorkItem{stage_state: :escalated} = reload(work_item)
      assert escalations(work_item) == [{nil, nil}]
      assert settled_entries(work_item) == []
    end

    test "an approver's Run another round settles it, with who settled it", %{
      scope: scope,
      work_item: work_item
    } do
      round = %{answers: [%{"id" => "q1", "option" => "Postgres"}]}
      assert {:ok, _} = WorkItems.another_round(scope, reload(work_item), 1, round)

      assert %WorkItem{stage_state: :running} = reload(work_item)
      user_id = scope.user.id
      assert escalations(work_item) == [{:another_round, user_id}]

      assert [{^user_id, %{"change" => "escalation_another_round", "cause" => "check_failed"}}] =
               settled_entries(work_item)
    end
  end

  describe "a listed approver" do
    setup %{scope: scope, member: member} do
      explore_approvers!(scope, %{"members" => [member.user.id]})
      %{work_item: proposed!(scope)}
    end

    test "is refused when the role is", %{
      scope: scope,
      member: member,
      membership: membership,
      work_item: work_item
    } do
      for action <- @approver_actions do
        assert Access.authorize(member, action, work_item) == :ok
      end

      {:ok, _suspended} = Apiary.Organisations.suspend_member(scope, membership.id)

      for action <- @approver_actions do
        assert Access.authorize(member, action, work_item) == {:error, :forbidden}
      end
    end
  end

  test "a subject other than a work item or a workspace is refused", %{
    scope: scope,
    member: member
  } do
    work_item = proposed!(scope)
    run = Repo.one!(from d in DispatchRun, where: d.work_item_id == ^work_item.id, limit: 1)

    for action <- @approver_actions, who <- [scope, member] do
      assert Access.check(who, action, run) == {:error, :not_approver}, "#{action}"
    end
  end

  test "an edition that answers the action answers without the approver step", %{
    scope: scope,
    member: member
  } do
    explore_approvers!(scope, %{"members" => [scope.user.id]})
    work_item = proposed!(scope)

    assert Access.authorize(member, :"work_item.review_comment", work_item) ==
             {:error, :not_approver}

    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReviewsWithoutApprovers)

    assert Access.authorize(member, :"work_item.review_comment", work_item) == :ok
    # The edition answers this action alone: the others still ask the approvers.
    assert Access.authorize(member, :"gate.approve", work_item) == {:error, :not_approver}
  end
end
