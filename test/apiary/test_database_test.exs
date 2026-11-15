defmodule Apiary.TestDatabaseTest do
  # Which database the end of a test run drops (`Apiary.TestDatabase.to_drop/2`). The drop
  # itself runs as the VM exits, after the suite.
  use ExUnit.Case, async: true

  alias Apiary.TestDatabase

  test "a partitioned run drops apiary_test followed by its partition" do
    assert TestDatabase.to_drop("2", "apiary_test2") == {:drop, "apiary_test2"}

    assert TestDatabase.to_drop("run1763200000p4242", "apiary_testrun1763200000p4242") ==
             {:drop, "apiary_testrun1763200000p4242"}
  end

  test "a run without a partition keeps apiary_test" do
    assert TestDatabase.to_drop(nil, "apiary_test") == :keep
    assert TestDatabase.to_drop("", "apiary_test") == :keep
  end

  test "a database other than the partition's is kept" do
    assert TestDatabase.to_drop("2", "apiary_dev") == :keep
    assert TestDatabase.to_drop("2", "apiary_test3") == :keep
    assert TestDatabase.to_drop("2", nil) == :keep
  end
end
