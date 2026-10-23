defmodule Apiary.TimeLimits.ResolutionTest do
  # What the time limits of a run's workspace come to for its workflow
  # (`Apiary.TimeLimits.Resolution`): the target's limit, else the workspace's, else none.
  use ExUnit.Case, async: true

  alias Apiary.TimeLimits.{Resolution, TimeLimit}

  @workspace "00000000-0000-0000-0000-00000000000a"
  @other_workspace "00000000-0000-0000-0000-00000000000b"
  @target "00000000-0000-0000-0000-0000000000a1"
  @other_target "00000000-0000-0000-0000-0000000000a2"

  defp limit(workflow, minutes, target_id \\ nil, workspace_id \\ @workspace),
    do: %TimeLimit{
      workflow: workflow,
      minutes: minutes,
      target_id: target_id,
      workspace_id: workspace_id
    }

  defp resolve(limits, target_id \\ @target, workflow \\ "hello"),
    do:
      Resolution.resolve(%{
        limits: limits,
        workspace_id: @workspace,
        target_id: target_id,
        workflow: workflow
      })

  test "no limit resolves to none" do
    assert resolve([]) == :none
  end

  test "the target's limit comes first, then the workspace's" do
    workspace = limit("hello", 90)
    target = limit("hello", 600, @target)

    assert resolve([workspace, target]) == {:ok, %Resolution{minutes: 600, level: :target}}
    assert resolve([target, workspace]) == {:ok, %Resolution{minutes: 600, level: :target}}
    assert resolve([workspace]) == {:ok, %Resolution{minutes: 90, level: :workspace}}
  end

  test "a run with no target reads the workspace's limit alone" do
    limits = [limit("hello", 90), limit("hello", 600, @target)]
    assert resolve(limits, nil) == {:ok, %Resolution{minutes: 90, level: :workspace}}
  end

  test "leaves out another target, another workspace and another workflow" do
    limits = [
      limit("hello", 600, @other_target),
      limit("hello", 30, nil, @other_workspace),
      limit("review", 45, @target),
      limit("review", 45)
    ]

    assert resolve(limits) == :none
  end
end
