defmodule ApiaryWeb.Contract.RunApi.BoundaryTest do
  # The feature `workflow_model` as the boundary reads it. The stubs are the whole node's
  # configuration, so the module is not async.
  use ExUnit.Case, async: false

  alias ApiaryWeb.Contract.RunApi.Boundary
  alias ApiaryWeb.RunApiStubs

  setup do
    RunApiStubs.install()
  end

  test "the feature: on where the features module lists it and has it on" do
    assert Boundary.on?()
    RunApiStubs.put(:flag, false)
    refute Boundary.on?()
  end
end
