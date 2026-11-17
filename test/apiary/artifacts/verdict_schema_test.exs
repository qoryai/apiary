defmodule Apiary.Artifacts.VerdictSchemaTest do
  # The schema of the type verdict, `priv/schemas/artifacts/verdict.schema.json`, revision
  # 1, is the source of the schema; qory keeps a byte copy of it at
  # `contracts/harness/v1/verdict.schema.json`. The test pins the file's SHA-256: update
  # the hash with the file, and name qory's commit here once that commit has these bytes.
  use ExUnit.Case, async: true

  alias Apiary.Kinds.Bounds

  @path Path.expand("../../../priv/schemas/artifacts/verdict.schema.json", __DIR__)
  @sha256 "c1f067bc161638f8df68374851617b6c67dde41bb96525ca41a6d7c279c959fb"

  test "is the bytes of the verdict schema the hash pins" do
    bytes = File.read!(@path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @sha256
  end

  test "limits a verdict to 20 points and at most 6 members in an object" do
    assert @path |> File.read!() |> Jason.decode!() |> Bounds.from_schema() ==
             [list: 20, members: 6]
  end

  defp valid?(document) do
    root = Apiary.Kinds.Schema.file!(["schemas", "artifacts", "verdict.schema.json"])
    match?({:ok, _}, JSV.validate(document, root, cast: false))
  end

  describe "track" do
    test "is an id and a reason of one line, and nothing else" do
      track = %{"id" => "small-change", "reason" => "One file changes."}
      assert valid?(%{"verdict" => "passed", "track" => track})
      assert valid?(%{"verdict" => "changes-requested", "track" => track})

      for bad <- [
            %{"id" => "small-change"},
            %{"reason" => "One file changes."},
            %{"id" => "Small", "reason" => "x"},
            %{"id" => String.duplicate("a", 41), "reason" => "x"},
            %{"id" => "a", "reason" => ""},
            %{"id" => "a", "reason" => String.duplicate("x", 301)},
            %{"id" => "a", "reason" => "two\nlines"},
            %{"id" => "a", "reason" => "x", "more" => 1},
            "a",
            nil
          ] do
        refute valid?(%{"verdict" => "passed", "track" => bad})
      end
    end
  end

  describe "full_suite" do
    @passed %{
      "state" => "passed",
      "passed" => 120,
      "failed" => 0,
      "skipped" => 3,
      "minutes" => 4.5
    }
    @failed %{"state" => "failed", "passed" => 9, "failed" => 2, "skipped" => 0, "minutes" => 12}
    @not_run %{"state" => "not_run", "reason" => "The checkout has no test command."}

    defp with_suite(suite, verdict \\ "passed"),
      do: %{"verdict" => verdict, "full_suite" => suite}

    test "is optional: a verdict with none is valid" do
      assert valid?(%{"verdict" => "passed"})
      assert valid?(%{"verdict" => "changes-requested"})
    end

    test "is a passed, failed or not_run result, for any verdict" do
      for suite <- [@passed, @failed, @not_run] do
        assert valid?(with_suite(suite))
        assert valid?(with_suite(suite, "changes-requested"))
        assert valid?(with_suite(suite, "escalate") |> Map.put("points", [point()]))
      end
    end

    defp point, do: %{"text" => "Something is missing.", "action" => "run_again"}

    test "takes whole-number counts and minutes from the bounds" do
      zero = %{@passed | "passed" => 0, "minutes" => 0}
      assert valid?(with_suite(zero))
      assert valid?(with_suite(%{@passed | "passed" => 1_000_000_000, "minutes" => 100_000}))
      assert valid?(with_suite(%{@passed | "minutes" => 0.25}))
      assert valid?(with_suite(%{@passed | "minutes" => 3}))
      # A count written as 12.0 is the whole number 12.
      assert valid?(with_suite(%{@passed | "passed" => 12.0}))
      assert valid?(with_suite(@passed |> Map.put("passed", 12.0) |> Map.put("failed", 0.0)))
    end

    test "refuses a state that is not one of the three" do
      for state <- ["pass", "Passed", "skipped", "", nil, 1, true] do
        refute valid?(with_suite(%{@passed | "state" => state}))
      end

      refute valid?(with_suite(Map.delete(@passed, "state")))
    end

    test "refuses a count that is negative, fractional, too large or not a number" do
      for key <- ~w(passed failed skipped),
          bad <- [-1, 1.5, 1_000_000_001, "3", nil, true, [1]] do
        refute valid?(with_suite(Map.put(@passed, key, bad))), "#{key}: #{inspect(bad)}"
      end
    end

    test "refuses minutes that are negative, too large or not a number" do
      for bad <- [-0.5, -1, 100_001, "4", nil, true] do
        refute valid?(with_suite(%{@passed | "minutes" => bad})), inspect(bad)
      end
    end

    test "requires the counts and minutes with passed and failed" do
      for state <- ["passed", "failed"], key <- ~w(passed failed skipped minutes) do
        refute valid?(with_suite(@passed |> Map.put("state", state) |> Map.delete(key)))
      end
    end

    test "refuses counts and minutes with not_run" do
      for {key, value} <- [{"passed", 1}, {"failed", 0}, {"skipped", 0}, {"minutes", 1}] do
        refute valid?(with_suite(Map.put(@not_run, key, value)))
      end

      refute valid?(with_suite(@passed |> Map.put("state", "not_run") |> Map.put("reason", "x")))
    end

    test "requires a reason with not_run, and refuses it with passed and failed" do
      refute valid?(with_suite(%{"state" => "not_run"}))
      refute valid?(with_suite(Map.put(@passed, "reason", "All passed.")))
      refute valid?(with_suite(Map.put(@failed, "reason", "Two failed.")))
    end

    test "takes a reason of one line of 1 to 300 characters" do
      assert valid?(with_suite(%{@not_run | "reason" => String.duplicate("x", 300)}))

      for bad <- ["", String.duplicate("x", 301), "two\nlines", "tab\tstop", "bell\u0007", 5, nil] do
        refute valid?(with_suite(%{@not_run | "reason" => bad})), inspect(bad)
      end
    end

    test "refuses a member the schema does not define, and a value that is not an object" do
      refute valid?(with_suite(Map.put(@passed, "flaky", 1)))
      refute valid?(with_suite(Map.put(@not_run, "flaky", 1)))

      for bad <- ["passed", nil, 1, [@passed], true] do
        refute valid?(with_suite(bad))
      end
    end
  end
end
