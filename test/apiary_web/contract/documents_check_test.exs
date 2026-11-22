defmodule ApiaryWeb.Contract.DocumentsCheckTest do
  # The two rules of a run's documents that the schema cannot state, as the integrations'
  # `Documents.Check()` states them (`contracts/run.go`). The three documents of
  # `contracts/run/v1/fixtures/check/` at the commit in
  # `test/fixtures/documents-check/.contract-ref` are replayed and return the message of the
  # Go test `TestCheckRefusesWhatTheSchemaCannotSay`. The run schema at that commit accepts
  # them. The vendored run contract (`test/fixtures/contract/run/v1`) is at e0d7be1, whose
  # schema refuses them for their `subject`, and has no `check/` folder. So these three are
  # vendored beside it, by their SHA-256, until the run contract is vendored at a later
  # commit.
  use ExUnit.Case, async: true

  alias ApiaryWeb.Contract.DocumentsCheck

  @fixtures Path.expand("../../fixtures/documents-check", __DIR__)
  @ref "4c788f46237d3ffa3124c8c87d9de085e3a36dc1"
  @run_fixtures Path.expand("../../fixtures/contract/run/v1/fixtures/documents", __DIR__)

  defp read(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  @messages %{
    "documents-deliver-type-twice.json" =>
      {"714948d28d810b9f90192273a243c0101b5254bfc4f0c1261e47f9bef386c0d7",
       ~s|List each deliver type once: "code-change" appears twice.|},
    "documents-further-targets-collection-twice.json" =>
      {"f9817ce485bcf22c55d16b9c80cc0f640bf6ce234ebd4976c280d8b77eb2b7d3",
       ~s|List each collection of further_targets once: "R_1002" appears twice.|},
    "documents-further-targets-collection-of-target.json" =>
      {"9c290a47f1362c130ab786839b0ffd3f62ffcbd5332083b6958ae5fee2faa268",
       ~s|Remove the collection "R_1001" from further_targets (index 1): target has it.|}
  }

  test "each fixture of check/ breaks one rule, with the message of Documents.Check()" do
    assert File.read!(Path.join(@fixtures, ".contract-ref")) == @ref <> "\n"

    names = @fixtures |> Path.join("*.json") |> Path.wildcard() |> Enum.map(&Path.basename/1)
    assert Enum.sort(names) == Enum.sort(Map.keys(@messages))

    for {name, {sha256, message}} <- @messages do
      bytes = File.read!(Path.join(@fixtures, name))
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256, name
      assert DocumentsCheck.check(read(name)) == {:error, message}, name
    end
  end

  test "each valid document of the vendored run contract passes" do
    paths = Path.wildcard(Path.join(@run_fixtures, "*.json"))
    assert paths != []

    for path <- paths do
      assert DocumentsCheck.check(path |> File.read!() |> Jason.decode!()) == :ok, path
    end
  end

  describe "a collection among target and further_targets" do
    @target %{"collection" => "R_1"}
    defp further(collections), do: Enum.map(collections, &%{"collection" => &1})

    test "is reported once it appears twice, the target's collection or another" do
      assert DocumentsCheck.check(%{
               "target" => @target,
               "further_targets" => further(~w(R_2 R_1))
             }) ==
               {:error,
                ~s|Remove the collection "R_1" from further_targets (index 1): target has it.|}

      assert DocumentsCheck.check(%{
               "target" => @target,
               "further_targets" => further(~w(R_2 R_2))
             }) ==
               {:error, ~s|List each collection of further_targets once: "R_2" appears twice.|}
    end

    test "is no repeat when the collections differ, when there is no target, and when there are no further targets" do
      assert DocumentsCheck.check(%{
               "target" => @target,
               "further_targets" => further(~w(R_2 R_3))
             }) == :ok

      assert DocumentsCheck.check(%{"further_targets" => further(~w(R_2 R_3))}) == :ok
      assert DocumentsCheck.check(%{"target" => @target}) == :ok
      assert DocumentsCheck.check(%{}) == :ok
    end

    test "reports the first entry that the rule refuses, by position" do
      assert DocumentsCheck.check(%{
               "target" => @target,
               "further_targets" => further(~w(R_2 R_2 R_1))
             }) ==
               {:error, ~s|List each collection of further_targets once: "R_2" appears twice.|}

      assert DocumentsCheck.check(%{
               "target" => @target,
               "further_targets" => further(~w(R_2 R_1 R_2))
             }) ==
               {:error,
                ~s|Remove the collection "R_1" from further_targets (index 1): target has it.|}
    end

    test "writes a quote, a backslash and a control character as Go's %q does" do
      assert DocumentsCheck.check(%{"further_targets" => further(["a\"b\\c\n", "a\"b\\c\n"])}) ==
               {:error,
                ~s|List each collection of further_targets once: "a\\"b\\\\c\\n" appears twice.|}
    end
  end

  test "writes a character that Go's unicode.IsPrint refuses as \\u or \\U, and others as they are" do
    ref = "a\u{2028}b\u{3000}c\u{E0041}d\u{E9}\u{7F}"

    assert DocumentsCheck.check(%{"further_targets" => further([ref, ref])}) ==
             {:error,
              ~s|List each collection of further_targets once: "a\\u2028b\\u3000c\\U000e0041dé\\x7f" appears twice.|}
  end

  test "a deliver type that appears twice is reported before a repeat in further_targets" do
    documents = %{
      "deliver" => [%{"type" => "a"}, %{"type" => "b"}, %{"type" => "a"}],
      "target" => %{"collection" => "R_1"},
      "further_targets" => [%{"collection" => "R_1"}]
    }

    assert DocumentsCheck.check(documents) ==
             {:error, ~s|List each deliver type once: "a" appears twice.|}
  end
end
