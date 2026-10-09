defmodule Apiary.CiProofTest do
  use ExUnit.Case, async: true

  test "the CI proof's deliberate failure" do
    assert false, "the CI proof's deliberate failure: ci-proof-169 is never merged"
  end
end
