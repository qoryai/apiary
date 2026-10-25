defmodule Apiary.Stacks.ResolutionTest do
  # The resolution reads no table: stacks go in, one answer comes out.
  use ExUnit.Case, async: true

  alias Apiary.Stacks.{Resolution, Stack}

  @organisation "00000000-0000-0000-0000-0000000000d1"
  @other_organisation "00000000-0000-0000-0000-0000000000d2"
  @instance "00000000-0000-0000-0000-0000000000d3"
  @workspace "00000000-0000-0000-0000-0000000000a1"
  @other_workspace "00000000-0000-0000-0000-0000000000a2"
  @target "00000000-0000-0000-0000-0000000000b1"
  @other_target "00000000-0000-0000-0000-0000000000b2"
  @document "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"

  defp input(stacks, opts \\ []) do
    %{
      stacks: stacks,
      organisation_id: Keyword.get(opts, :organisation_id, @organisation),
      workspace_id: @workspace,
      target_id: Keyword.get(opts, :target_id, @target),
      workflow: "explore",
      operated: Keyword.get(opts, :operated, false)
    }
  end

  # A stack at `level`, of the organisation, workspace and target above, with a document
  # that names its level; `attrs` are its columns.
  defp at(level, attrs \\ []) do
    place =
      case level do
        :organisation -> %{}
        :workspace -> %{workspace_id: @workspace}
        :workspace_workflow -> %{workspace_id: @workspace, workflow: "explore"}
        :target -> %{workspace_id: @workspace, target_id: @target}
        :target_workflow -> %{workspace_id: @workspace, target_id: @target, workflow: "explore"}
      end

    struct!(
      Stack,
      %{
        id: Ecto.UUID.generate(),
        organisation_id: @organisation,
        harness: "extends: {git: https://code.example.com/#{level}, ref: main}\n"
      }
      |> Map.merge(%{owner_organisation_id: @organisation})
      |> Map.merge(place)
      |> Map.merge(Map.new(attrs))
    )
  end

  defp resolved(input) do
    assert {:ok, %Resolution{} = resolution} = Resolution.resolve(input)
    resolution
  end

  describe "the order" do
    test "each level wins over every level after it" do
      levels = Stack.levels()

      for {level, index} <- Enum.with_index(levels) do
        stacks = for later <- Enum.drop(levels, index), do: at(later)
        resolution = resolved(input(Enum.reverse(stacks)))
        assert resolution.level == level
        assert resolution.harness == at(level).harness
      end
    end

    test "each stored level applies alone" do
      for level <- Stack.levels() do
        assert resolved(input([at(level)])).level == level
      end
    end

    test "an empty level falls through to the next" do
      resolution = resolved(input([at(:target_workflow), at(:workspace)], target_id: nil))
      assert resolution.level == :workspace

      resolution = resolved(input([at(:workspace_workflow), at(:organisation)]))
      assert resolution.level == :workspace_workflow
    end

    test "a resolution has the document, its row, the workflow, the level and the owner" do
      stack = at(:workspace_workflow, harness: @document)

      assert resolved(input([stack])) == %Resolution{
               harness: @document,
               stack_id: stack.id,
               workflow: "explore",
               level: :workspace_workflow,
               owner: @organisation,
               harness_hidden: false
             }
    end

    test "no document at any level is none" do
      assert Resolution.resolve(input([])) == :none
    end

    test "a row that sets only the workflow falls through to the next level" do
      stacks = [at(:workspace_workflow, harness: nil), at(:organisation)]
      assert resolved(input(stacks)).level == :organisation
      assert Resolution.resolve(input([at(:target_workflow, harness: nil)])) == :none
    end

    test "a run without a target skips both target levels" do
      stacks = [at(:target_workflow), at(:target), at(:workspace_workflow)]
      assert resolved(input(stacks, target_id: nil)).level == :workspace_workflow
    end

    test "stacks of another workflow, target, workspace or organisation are left out" do
      stacks = [
        at(:target_workflow, workflow: "review"),
        at(:workspace_workflow, workflow: "review"),
        at(:target, target_id: @other_target),
        at(:workspace, workspace_id: @other_workspace),
        at(:organisation, organisation_id: @other_organisation)
      ]

      assert Resolution.resolve(input(stacks)) == :none
    end
  end

  describe "the owner" do
    test "of a document is its row's owner organisation" do
      stack = at(:workspace, harness: @document, owner_organisation_id: @other_organisation)
      assert Resolution.owner(stack) == @other_organisation
      assert resolved(input([stack])).owner == @other_organisation
    end

    test "of a document whose owner is deleted is nil" do
      stack = at(:workspace, harness: @document, owner_organisation_id: nil)
      assert Resolution.owner(stack) == nil
      assert resolved(input([stack])).owner == nil
    end
  end

  describe "harness_hidden" do
    test "is false for a document the run's organisation owns" do
      stack = at(:workspace, harness: @document, owner_organisation_id: @organisation)
      refute resolved(input([stack])).harness_hidden
    end

    test "is true for a document another organisation owns" do
      stack = at(:workspace, harness: @document, owner_organisation_id: @other_organisation)
      assert resolved(input([stack])).harness_hidden
    end

    test "is true for a document whose owner is deleted" do
      stack = at(:workspace, harness: @document, owner_organisation_id: nil)
      assert resolved(input([stack])).harness_hidden
    end

    test "on an instance of several organisations, a document the instance's organisation owns is hidden from the others' runs alone" do
      # The run's organisation is @organisation, and the instance's is @instance.
      instance_owned = at(:workspace, harness: @document, owner_organisation_id: @instance)
      assert resolved(input([instance_owned])).harness_hidden

      # A run of the instance's organisation, at a row of the run's workspace.
      in_instance = %{instance_owned | organisation_id: @instance}
      refute resolved(input([in_instance], organisation_id: @instance)).harness_hidden
    end

    test "is true for an operated organisation, whoever owns the document" do
      owned_by_run = at(:workspace, harness: @document, owner_organisation_id: @organisation)
      assert resolved(input([owned_by_run], operated: true)).harness_hidden
    end
  end
end
