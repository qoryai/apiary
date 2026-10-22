defmodule Apiary.StacksTest do
  # The stack at five levels: what each write stores, every refusal of a save, and what
  # resolves for a run, the instance default from the machines file included. The
  # resolution itself is `test/apiary/stacks/resolution_test.exs`. Not async: the
  # machines file read at boot is the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Dispatches.MachinesFile
  alias Apiary.Runs.Target
  alias Apiary.Stacks
  alias Apiary.Stacks.{Resolution, Stack}

  @moduletag :tmp_dir

  @reference "https://code.example.com/team/stacks#main:core"
  @other_reference "https://code.example.com/team/stacks#v2:general"

  setup %{tmp_dir: dir} do
    setting = Application.fetch_env(:apiary, :machines_file_setting)
    file = Application.fetch_env(:apiary, :machines_file)

    on_exit(fn ->
      restore(:machines_file_setting, setting)
      restore(:machines_file, file)
    end)

    %{scope: scope} = sign_up_fixture()

    target =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "system.example",
        path: "team/place",
        first_seen_at: DateTime.utc_now()
      })

    %{
      scope: scope,
      target: target,
      dir: dir,
      place: "#{scope.organisation.slug}/#{scope.workspace.slug}"
    }
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:apiary, key, value)
  defp restore(key, :error), do: Application.delete_env(:apiary, key)

  # Boots with a machines file whose entry for the scope's workspace is `entry`.
  defp machines!(ctx, entry) do
    path = Path.join(ctx.dir, "machines.json")

    File.write!(
      path,
      Jason.encode!(%{"machines" => ~w(small), "workspaces" => %{ctx.place => entry}})
    )

    Application.put_env(:apiary, :machines_file_setting, path)
    MachinesFile.boot!()
  end

  defp default!(ctx),
    do: machines!(ctx, %{"stack" => "software-standard", "workflow" => "explore"})

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
      default!(ctx)
      assert Stacks.saved_by(ctx.scope) == ctx.scope.organisation.id

      {:ok, stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @reference)

      assert stack.saved_by_organisation_id == ctx.scope.organisation.id
      assert Resolution.owner(stack) == ctx.scope.organisation.id
      assert %{stack: @reference, harness_hidden: false} = run_stack(ctx)
    end

    test "records no organisation for an instance admin who is not a member", ctx do
      default!(ctx)
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
        {:ok, stack} = Stacks.put_stack(scope, {:workspace, ctx.scope.workspace}, @reference)

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
      default!(ctx)
      place = {:workspace, ctx.scope.workspace}
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

  describe "for_run/3" do
    test "each level wins over the levels after it, down to the machines file", ctx do
      default!(ctx)

      for {level, place} <- places(ctx) do
        {:ok, _stack} =
          Stacks.put_stack(ctx.scope, place, "at-" <> String.replace("#{level}", "_", "-"))
      end

      for {level, place} <- places(ctx) do
        assert run_stack(ctx).stack == "at-" <> String.replace("#{level}", "_", "-")
        {:ok, _stack} = Stacks.delete_stack(place)
      end

      assert run_stack(ctx).stack == "software-standard"
    end

    test "an empty level falls through to the next", ctx do
      default!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target, "explore"}, "first")
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:organisation, ctx.scope.organisation}, "last")

      assert run_stack(ctx).stack == "first"
      assert run_stack(ctx, nil).stack == "last"
    end

    test "a stack of another workflow is left out", ctx do
      default!(ctx)

      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "review"}, "x")

      assert run_stack(ctx).stack == "software-standard"
    end

    test "a target no row of the workspace has counts as none", ctx do
      default!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:target, ctx.target}, "at-target")

      assert run_stack(ctx, %{system: "system.example", path: "team/elsewhere"}).stack ==
               "software-standard"
    end

    test "the instance default is the machines file's name for the workspace", ctx do
      default!(ctx)

      assert run_stack(ctx) == %{
               stack: "software-standard",
               workflow: "explore",
               harness_hidden: false
             }
    end

    test "a workspace without a workflow in the machines file has no stack", ctx do
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, "core")

      Application.put_env(:apiary, :machines_file_setting, nil)
      nil = MachinesFile.boot!()
      assert run_stack(ctx) == nil

      machines!(ctx, %{"machine" => "small"})
      assert run_stack(ctx) == nil
    end
  end

  describe "harness_hidden" do
    test "is false for a name, on the core's instance of one organisation", ctx do
      default!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, "core")
      assert %{stack: "core", harness_hidden: false} = run_stack(ctx)
    end

    test "is false for a reference saved by the run's organisation", ctx do
      default!(ctx)
      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @reference)
      assert %{stack: @reference, harness_hidden: false} = run_stack(ctx)
    end

    test "is true for a reference saved by another organisation", ctx do
      default!(ctx)
      %{scope: other} = sign_up_fixture()
      {:ok, _stack} = Stacks.put_stack(other, {:workspace, ctx.scope.workspace}, @reference)
      assert %{stack: @reference, harness_hidden: true} = run_stack(ctx)
    end

    test "is true when the run's organisation is operated", ctx do
      default!(ctx)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert %{stack: "software-standard", harness_hidden: true} = run_stack(ctx)

      {:ok, _stack} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @reference)
      assert %{stack: @reference, harness_hidden: true} = run_stack(ctx)
    end
  end
end
