defmodule ApiaryWeb.Contract.RunApi.BoundaryTest do
  # Which artifact types a run may write: verdict and questions always, and otherwise
  # what the workflow's declaration lists in `writes`, or any type where it lists none.
  # The stubs are the whole node's configuration, so the module is not async.
  use ExUnit.Case, async: false

  alias ApiaryWeb.Contract.RunApi.Boundary
  alias ApiaryWeb.RunApiStubs

  setup do
    RunApiStubs.install()
  end

  @workspace %{id: "workspace"}

  test "a declaration with a writes list: only its types, verdict and questions" do
    RunApiStubs.put(:declaration, %{name: "capture-demo", writes: ["demo-video", "screenshot"]})

    assert Boundary.writable?(@workspace, "capture-demo", "demo-video")
    assert Boundary.writable?(@workspace, "capture-demo", "screenshot")
    refute Boundary.writable?(@workspace, "capture-demo", "explainer")
    assert RunApiStubs.get(:declared) == "capture-demo"
    assert Boundary.writable?(@workspace, "capture-demo", "verdict")
    assert Boundary.writable?(@workspace, "capture-demo", "questions")
  end

  test "a declaration whose writes list is nil: any type" do
    RunApiStubs.put(:declaration, %{
      name: "implement",
      access: "write",
      time_limit: nil,
      reads: nil,
      writes: nil
    })

    assert Boundary.writable?(@workspace, "implement", "explainer")
    assert Boundary.writable?(@workspace, "implement", "demo-video")
  end

  test "no declaration, a workflow the harness no longer declares: any type" do
    RunApiStubs.put(:declaration, nil)
    assert Boundary.writable?(@workspace, "capture-demo", "explainer")
  end

  test "a run with no workflow: any type, and no declaration is read" do
    assert Boundary.writable?(@workspace, nil, "explainer")
    assert RunApiStubs.get(:declared) == nil
  end

  test "an empty writes list: verdict and questions alone" do
    RunApiStubs.put(:declaration, %{name: "review", writes: []})
    refute Boundary.writable?(@workspace, "review", "explainer")
    assert Boundary.writable?(@workspace, "review", "verdict")
    assert Boundary.writable?(@workspace, "review", "questions")
  end

  test "the feature: on where the features module lists it and has it on" do
    assert Boundary.on?()
    RunApiStubs.put(:flag, false)
    refute Boundary.on?()
  end
end
