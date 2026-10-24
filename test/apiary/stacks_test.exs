defmodule Apiary.StacksTest do
  # The stack at five levels: what each write stores, every refusal of a save, the run's
  # workflow read from the rows with a workflow, and what resolves for a run. The
  # resolution itself is `test/apiary/stacks/resolution_test.exs`.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Target
  alias Apiary.Stacks
  alias Apiary.Stacks.{Resolution, Stack}

  @reference "https://code.example.com/team/stacks#main:core"
  @other_reference "https://code.example.com/team/stacks#v2:general"

  setup do
    %{scope: scope} = sign_up_fixture()

    %{scope: scope, target: target!(scope, "team/place")}
  end

  defp target!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "system.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  # The workspace's row for the workflow `explore`, with `stack`: the run's one row with a
  # workflow.
  defp workflow!(ctx, stack \\ "software-standard") do
    {:ok, row} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "explore"}, stack)
    row
  end

  defp run_stack(ctx, target \\ :target) do
    target =
      case target do
        :target -> %{system: ctx.target.system, path: ctx.target.path}
        other -> other
      end

    Stacks.for_run(ctx.scope.organisation, ctx.scope.workspace, target)
  end

  defp places(ctx) do
    [
      target_workflow: {:target, ctx.target, "explore"},
      target: {:target, ctx.target},
      workspace_workflow: {:workspace, ctx.scope.workspace, "explore"},
      workspace: {:workspace, ctx.scope.workspace},
      organisation: {:organisation, ctx.scope.organisation}
    ]
  end

  describe "put_stack/3" do
    test "stores a stack at each of the five levels", ctx do
      for {level, place} <- places(ctx) do
        assert {:ok, %Stack{} = stack} = Stacks.put_stack(ctx.scope, place, "level-one")
        assert Stack.level(stack) == level
        assert stack.organisation_id == ctx.scope.organisation.id
      end

      assert Repo.aggregate(Stack, :count) == 5
    end

    test "records the person who saved it and that person's organisation", ctx do
      place = {:workspace, ctx.scope.workspace}
      {:ok, first} = Stacks.put_stack(ctx.scope, place, @reference)

      assert first.saved_by_organisation_id == ctx.scope.organisation.id
      assert first.created_by_id == ctx.scope.user.id
      assert first.updated_by_id == ctx.scope.user.id

      %{scope: other} = sign_up_fixture()
      {:ok, second} = Stacks.put_stack(other, place, @other_reference)

      assert second.id == first.id
      assert second.stack == @other_reference
      assert second.organisation_id == ctx.scope.organisation.id
      assert second.saved_by_organisation_id == other.organisation.id
      assert second.created_by_id == ctx.scope.user.id
      assert second.updated_by_id == other.user.id
    end

    test "records a member's organisation, whose reference is shown to its runs", ctx do
      assert Stacks.saved_by(ctx.scope) == ctx.scope.organisation.id

      stack = workflow!(ctx, @reference)

      assert stack.saved_by_organisation_id == ctx.scope.organisation.id
      assert Resolution.owner(stack) == ctx.scope.organisation.id
      assert %{stack: @reference, harness_hidden: false} = run_stack(ctx)
    end

    test "records no organisation for an instance admin who is not a member", ctx do
      admin = instance_admin_scope()
      refute admin.organisation.id == ctx.scope.organisation.id

      # The admin acting in the run's organisation by a reach an edition gives, with no
      # membership there; and with the admin's membership of the instance's organisation.
      without_membership = %{
        admin
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace,
          membership: nil,
          reach: :instance_admin
      }

      with_other_membership = %{
        admin
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      for scope <- [without_membership, with_other_membership] do
        assert Stacks.saved_by(scope) == nil

        {:ok, stack} =
          Stacks.put_stack(scope, {:workspace, ctx.scope.workspace, "explore"}, @reference)

        assert stack.saved_by_organisation_id == nil
        assert Resolution.owner(stack) == nil
        assert %{stack: @reference, harness_hidden: true} = run_stack(ctx)
      end
    end

    test "records no organisation for a member who reaches it another way", ctx do
      scope = %{ctx.scope | reach: {:operator, ctx.scope.organisation.id}}
      assert Stacks.saved_by(scope) == nil
    end

    test "records no organisation for the instance acting by itself", ctx do
      scope = Apiary.Accounts.Scope.for_instance(ctx.scope.organisation, ctx.scope.workspace)
      assert Stacks.saved_by(scope) == nil
    end

    test "keeps one row per place", ctx do
      place = {:target, ctx.target, "explore"}
      {:ok, _first} = Stacks.put_stack(ctx.scope, place, "first")
      {:ok, _second} = Stacks.put_stack(ctx.scope, place, "second")

      assert [%Stack{stack: "second"}] = Repo.all(Stack)
    end

    test "refuses a value that is neither a name nor a reference", ctx do
      place = {:workspace, ctx.scope.workspace}

      for value <- ["Software", "https://user@code.example.com/s#main:core", "", nil, 7] do
        assert {:error, changeset} = Stacks.put_stack(ctx.scope, place, value)
        assert changeset.errors[:stack], inspect(value)
      end

      assert Repo.aggregate(Stack, :count) == 0
    end

    test "refuses a workflow that is not a name", ctx do
      assert {:error, changeset} =
               Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "Explore"}, "core")

      assert changeset.errors[:workflow]
    end
  end

  describe "delete_stack/1" do
    test "removes the stack at a place, and the next level applies", ctx do
      workflow!(ctx)
      place = {:target, ctx.target}
      {:ok, _stack} = Stacks.put_stack(ctx.scope, place, "level-one")
      assert run_stack(ctx).stack == "level-one"

      assert {:ok, %Stack{stack: "level-one"}} = Stacks.delete_stack(place)
      assert run_stack(ctx).stack == "software-standard"
    end

    test "is not found for a place with none", ctx do
      assert Stacks.delete_stack({:organisation, ctx.scope.organisation}) ==
               {:error, :not_found}
    end
  end

  describe "workflow/2" do
    test "is the workflow of the one row with a workflow at the workspace", ctx do
      workflow!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, "core")
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:organisation, ctx.scope.organisation}, "x")

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == "explore"
      assert Stacks.workflow(ctx.scope.workspace, nil) == "explore"
    end

    test "is the workflow of the one row with a workflow at the run's target", ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target, "review"}, "core")

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == "review"
      assert Stacks.workflow(ctx.scope.workspace, nil) == nil
    end

    test "leaves out the rows with a workflow at another target", ctx do
      workflow!(ctx)
      other = target!(ctx.scope, "team/other")
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, other, "review"}, "core")

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == "explore"
      assert Stacks.workflow(ctx.scope.workspace, other) == nil
    end

    test "leaves out the rows of another workspace", ctx do
      %{scope: other} = sign_up_fixture()
      {:ok, _stack} = Stacks.put_stack(other, {:workspace, other.workspace, "explore"}, "core")

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == nil
    end

    test "is nil for no row with a workflow", ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target}, "core")
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, "core")

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == nil
    end

    test "is nil for two rows with a workflow, whatever their workflows", ctx do
      workflow!(ctx)

      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "review"}, "x")

      assert Stacks.workflow(ctx.scope.workspace, nil) == nil

      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace, "review"})
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target, "explore"}, "x")
      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == nil
      assert Stacks.workflow(ctx.scope.workspace, nil) == "explore"
    end
  end

  describe "for_run/3" do
    test "one row with a workflow: the run has that workflow, its stack and harness_hidden",
         ctx do
      workflow!(ctx)

      assert run_stack(ctx) == %{
               stack: "software-standard",
               workflow: "explore",
               harness_hidden: false
             }
    end

    test "no row with a workflow: the run has no stack, whatever the levels have", ctx do
      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        {:ok, _stack} = Stacks.put_stack(ctx.scope, place, "core")
      end

      assert run_stack(ctx) == nil
      assert run_stack(ctx, nil) == nil
    end

    test "two rows with a workflow: the run has no stack", ctx do
      workflow!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target, "review"}, "x")

      assert run_stack(ctx) == nil
      assert run_stack(ctx, nil).workflow == "explore"
    end

    test "a target row without a workflow wins over the workflow row at the workspace", ctx do
      workflow!(ctx, "at-workspace-workflow")

      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        {:ok, _stack} =
          Stacks.put_stack(ctx.scope, place, "at-" <> String.replace("#{level}", "_", "-"))
      end

      assert run_stack(ctx).stack == "at-target"
      assert run_stack(ctx, nil).stack == "at-workspace-workflow"

      {:ok, _stack} = Stacks.delete_stack({:target, ctx.target})
      assert run_stack(ctx).stack == "at-workspace-workflow"
    end

    test "a workflow row at the target wins over every other level", ctx do
      for {level, place} <- places(ctx), level != :workspace_workflow do
        {:ok, _stack} =
          Stacks.put_stack(ctx.scope, place, "at-" <> String.replace("#{level}", "_", "-"))
      end

      assert run_stack(ctx) == %{
               stack: "at-target-workflow",
               workflow: "explore",
               harness_hidden: false
             }

      assert run_stack(ctx, nil) == nil
    end

    test "a target no row of the workspace has counts as none", ctx do
      workflow!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target}, "at-target")

      assert run_stack(ctx, %{system: "system.example", path: "team/elsewhere"}).stack ==
               "software-standard"
    end
  end

  describe "harness_hidden" do
    test "is false for a name, on the core's instance of one organisation", ctx do
      workflow!(ctx, "core")
      assert %{stack: "core", harness_hidden: false} = run_stack(ctx)
    end

    test "is false for a reference saved by the run's organisation", ctx do
      workflow!(ctx, @reference)
      assert %{stack: @reference, harness_hidden: false} = run_stack(ctx)
    end

    test "is true for a reference saved by another organisation", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace, "explore"}, @reference)

      assert %{stack: @reference, harness_hidden: true} = run_stack(ctx)
    end

    test "is true when the run's organisation is operated", ctx do
      workflow!(ctx)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert %{stack: "software-standard", harness_hidden: true} = run_stack(ctx)

      workflow!(ctx, @reference)
      assert %{stack: @reference, harness_hidden: true} = run_stack(ctx)
    end
  end
end
