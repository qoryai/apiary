defmodule Apiary.Stacks.ResolutionTest do
  # The resolution reads no table: stacks go in, one answer comes out.
  use ExUnit.Case, async: true

  alias Apiary.Stacks.{Resolution, Stack}

  @organisation "00000000-0000-0000-0000-0000000000d1"
  @other_organisation "00000000-0000-0000-0000-0000000000d2"
  @workspace "00000000-0000-0000-0000-0000000000a1"
  @other_workspace "00000000-0000-0000-0000-0000000000a2"
  @target "00000000-0000-0000-0000-0000000000b1"
  @other_target "00000000-0000-0000-0000-0000000000b2"
  @reference "https://code.example.com/team/stacks#main:core"

  defp input(stacks, opts \\ []) do
    %{
      stacks: stacks,
      organisation_id: @organisation,
      workspace_id: @workspace,
      target_id: Keyword.get(opts, :target_id, @target),
      workflow: "explore",
      default: Keyword.get(opts, :default, "software-standard"),
      operated: Keyword.get(opts, :operated, false),
      single_organisation: Keyword.get(opts, :single_organisation, true)
    }
  end

  # A stack at `level`, of the organisation, workspace and target above; `attrs` are its
  # columns.
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
      %{organisation_id: @organisation, stack: "level-#{level}" |> String.replace("_", "-")}
      |> Map.merge(%{saved_by_organisation_id: @organisation})
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
        assert resolution.stack == at(level).stack
      end
    end

    test "every stored level wins over the instance default" do
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

    test "the instance default applies when no level has a stack" do
      resolution = resolved(input([]))

      assert resolution == %Resolution{
               stack: "software-standard",
               workflow: "explore",
               level: :instance,
               owner: :instance,
               harness_hidden: false
             }
    end

    test "no stack at any level and no default is none" do
      assert Resolution.resolve(input([], default: nil)) == :none
    end

    test "a stored level applies without an instance default" do
      assert resolved(input([at(:organisation)], default: nil)).level == :organisation
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

      assert resolved(input(stacks)).level == :instance
    end
  end

  describe "the owner" do
    test "of a name is the instance, whoever saved it" do
      stack = at(:workspace, stack: "software-standard", saved_by_organisation_id: nil)
      assert Resolution.owner(stack) == :instance
      assert resolved(input([stack])).owner == :instance
    end

    test "of a reference is the organisation of the person who saved it" do
      stack = at(:workspace, stack: @reference, saved_by_organisation_id: @other_organisation)
      assert Resolution.owner(stack) == @other_organisation
      assert resolved(input([stack])).owner == @other_organisation
    end
  end

  describe "harness_hidden" do
    test "is false for a name on an instance of one organisation" do
      refute resolved(input([])).harness_hidden
      refute resolved(input([at(:workspace, stack: "software-standard")])).harness_hidden
    end

    test "is true for a name on an instance of more than one organisation" do
      assert resolved(input([], single_organisation: false)).harness_hidden
    end

    test "is false for a reference saved by the run's organisation" do
      stack = at(:workspace, stack: @reference, saved_by_organisation_id: @organisation)
      refute resolved(input([stack], single_organisation: false)).harness_hidden
    end

    test "is true for a reference saved by another organisation" do
      stack = at(:workspace, stack: @reference, saved_by_organisation_id: @other_organisation)
      assert resolved(input([stack])).harness_hidden
    end

    test "is true for a reference whose saver's organisation is deleted" do
      stack = at(:workspace, stack: @reference, saved_by_organisation_id: nil)
      assert resolved(input([stack])).harness_hidden
    end

    test "is true for an operated organisation, whoever owns the stack" do
      saved_by_run = at(:workspace, stack: @reference, saved_by_organisation_id: @organisation)

      assert resolved(input([], operated: true)).harness_hidden
      assert resolved(input([saved_by_run], operated: true)).harness_hidden
    end
  end
end
