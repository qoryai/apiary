defmodule Apiary.AccessApproversTest do
  # The approver rule of `Apiary.Access` (its moduledoc, step 9): `gate.approve` asked of
  # a work item allows only the approvers of the stage it is in, where the stage lists
  # them. An answer to the questions stays every member's.
  # Not async: a test switches the workflow model off, the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Access, Processes, Repo, Stages, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace
  alias Apiary.WorkItems.{Confirmation, WorkItem}

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @approver_actions [:"gate.approve"]

  setup do
    %{scope: scope} = sign_up_fixture()
    member = member_fixture(scope)
    %{scope: scope, member: member.scope}
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
      assert WorkItems.confirm(member, work_item, 1) == {:error, :not_approver}
      refute Repo.get_by(Confirmation, work_item_id: work_item.id)
      assert %{stage_id: @explore, stage_state: :at_gate} = reload(work_item)

      assert {:ok, _confirmed} = WorkItems.confirm(scope, work_item, 1)
      assert Repo.get_by(Confirmation, work_item_id: work_item.id)
    end

    test "allows every member with the workflow model off", %{
      member: member,
      work_item: work_item
    } do
      workflow_model_off()

      assert Stages.approver(member, work_item) == :ok
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

    refute Access.can?(member, :"gate.approve", work_item)
    assert Access.can?(scope, :"gate.approve", work_item)
  end
end
