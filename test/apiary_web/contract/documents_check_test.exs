defmodule ApiaryWeb.Contract.DocumentsCheckTest do
  # The rules of a run's documents that the schema cannot state, as the integrations'
  # `Documents.Check()` checks them (`contracts/run.go`). The five `documents-*.json` files
  # of the vendored run contract's `fixtures/check/` are replayed and return the message of
  # the Go test `TestCheckRefusesWhatTheSchemaCannotSay`.
  # `test/apiary/dispatches/wire_test.exs` checks that the run schema accepts them.
  use ExUnit.Case, async: true

  alias ApiaryWeb.Contract.DocumentsCheck

  @fixtures Path.expand("../../fixtures/contract/run/v1/fixtures/check", __DIR__)
  @run_fixtures Path.expand("../../fixtures/contract/run/v1/fixtures/documents", __DIR__)

  defp read(path), do: @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()

  @messages %{
    "documents-deliver-type-twice.json" =>
      ~s|List each deliver type once: "code-change" appears twice.|,
    "documents-read-targets-collection-twice.json" =>
      ~s|List each collection of read_targets once: "R_1002" appears twice.|,
    "documents-read-targets-collection-of-target.json" =>
      ~s|Remove the collection "R_1001" from read_targets (index 1): target has it.|,
    "documents-destination-id-twice.json" =>
      ~s|List each destination once: "tg_0123456789abcdef" appears twice.|,
    "documents-destination-id-twice-after-another.json" =>
      ~s|List each destination once: "tg_0123456789abcdef" appears twice.|
  }

  test "each fixture of check/ breaks one rule, with the message of Documents.Check()" do
    files =
      @fixtures |> Path.join("documents-*.json") |> Path.wildcard() |> Enum.map(&Path.basename/1)

    assert Enum.sort(files) == Enum.sort(Map.keys(@messages))

    for {name, message} <- @messages do
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

  describe "a collection among target and read_targets" do
    @target %{"collection" => "R_1"}
    defp entries(collections), do: Enum.map(collections, &%{"collection" => &1})

    test "is reported once it appears twice, the target's collection or another" do
      assert DocumentsCheck.check(%{
               "target" => @target,
               "read_targets" => entries(~w(R_2 R_1))
             }) ==
               {:error,
                ~s|Remove the collection "R_1" from read_targets (index 1): target has it.|}

      assert DocumentsCheck.check(%{
               "target" => @target,
               "read_targets" => entries(~w(R_2 R_2))
             }) ==
               {:error, ~s|List each collection of read_targets once: "R_2" appears twice.|}
    end

    test "is no repeat when the collections differ, when there is no target, and when there are no read targets" do
      assert DocumentsCheck.check(%{
               "target" => @target,
               "read_targets" => entries(~w(R_2 R_3))
             }) == :ok

      assert DocumentsCheck.check(%{"read_targets" => entries(~w(R_2 R_3))}) == :ok
      assert DocumentsCheck.check(%{"target" => @target}) == :ok
      assert DocumentsCheck.check(%{"target" => @target, "read_targets" => []}) == :ok
      assert DocumentsCheck.check(%{}) == :ok
    end

    test "reports the first entry that the rule refuses, by position" do
      assert DocumentsCheck.check(%{
               "target" => @target,
               "read_targets" => entries(~w(R_2 R_2 R_1))
             }) ==
               {:error, ~s|List each collection of read_targets once: "R_2" appears twice.|}

      assert DocumentsCheck.check(%{
               "target" => @target,
               "read_targets" => entries(~w(R_2 R_1 R_2))
             }) ==
               {:error,
                ~s|Remove the collection "R_1" from read_targets (index 1): target has it.|}
    end

    test "writes a quote, a backslash and a control character as Go's %q does" do
      assert DocumentsCheck.check(%{"read_targets" => entries(["a\"b\\c\n", "a\"b\\c\n"])}) ==
               {:error,
                ~s|List each collection of read_targets once: "a\\"b\\\\c\\n" appears twice.|}
    end
  end

  test "writes a character that Go's unicode.IsPrint refuses as \\u or \\U, and others as they are" do
    ref = "a\u{2028}b\u{3000}c\u{E0041}d\u{E9}\u{7F}"

    assert DocumentsCheck.check(%{"read_targets" => entries([ref, ref])}) ==
             {:error,
              ~s|List each collection of read_targets once: "a\\u2028b\\u3000c\\U000e0041dé\\x7f" appears twice.|}
  end

  test "a deliver type that appears twice is reported before a repeat in read_targets" do
    documents = %{
      "deliver" => [%{"type" => "a"}, %{"type" => "b"}, %{"type" => "a"}],
      "target" => %{"collection" => "R_1"},
      "read_targets" => [%{"collection" => "R_1"}]
    }

    assert DocumentsCheck.check(documents) ==
             {:error, ~s|List each deliver type once: "a" appears twice.|}
  end

  describe "the id of a destination of the inputs" do
    defp inputs(ids), do: %{"inputs" => %{"destinations" => Enum.map(ids, &%{"id" => &1})}}

    test "is reported once it appears twice" do
      assert DocumentsCheck.check(inputs(~w(tg_a tg_b tg_a))) ==
               {:error, ~s|List each destination once: "tg_a" appears twice.|}
    end

    test "is no repeat when the ids differ, when there are no destinations, or no inputs object" do
      assert DocumentsCheck.check(inputs(~w(tg_a tg_b))) == :ok
      assert DocumentsCheck.check(inputs([])) == :ok
      assert DocumentsCheck.check(%{"inputs" => %{"version" => 1}}) == :ok
      assert DocumentsCheck.check(%{"inputs" => %{"destinations" => nil}}) == :ok
      assert DocumentsCheck.check(%{"inputs" => []}) == :ok
      assert DocumentsCheck.check(%{"inputs" => nil}) == :ok
      assert DocumentsCheck.check(%{"inputs" => "text"}) == :ok
      assert DocumentsCheck.check(%{}) == :ok
    end

    test "is not checked when Go cannot decode the destinations" do
      for destinations <- [
            [%{"id" => 5}, %{"id" => 5}],
            ["tg_a", "tg_a"],
            [%{"id" => "tg_a"}, "x", %{"id" => "tg_a"}],
            %{"id" => "tg_a"}
          ] do
        assert DocumentsCheck.check(%{"inputs" => %{"destinations" => destinations}}) == :ok,
               inspect(destinations)
      end
    end

    test "matches each member's key in exact case" do
      assert DocumentsCheck.check(%{
               "inputs" => %{"Destinations" => [%{"id" => "tg_a"}, %{"id" => "tg_a"}]}
             }) == :ok

      assert DocumentsCheck.check(%{
               "inputs" => %{"destinations" => [%{"ID" => "tg_a"}, %{"ID" => "tg_a"}]}
             }) == {:error, ~s|List each destination once: "" appears twice.|}
    end

    test "is reported after a repeat in read_targets" do
      documents =
        Map.put(inputs(~w(tg_a tg_a)), "read_targets", entries(~w(R_2 R_2)))

      assert DocumentsCheck.check(documents) ==
               {:error, ~s|List each collection of read_targets once: "R_2" appears twice.|}
    end
  end

  # Go decodes a missing or null member into a string field as "", so two entries without
  # the member repeat "".
  test "a missing or null member is the empty string, as in Go" do
    for {documents, message} <- [
          {%{"deliver" => [%{}, %{}]}, ~s|List each deliver type once: "" appears twice.|},
          {%{"deliver" => [nil, nil]}, ~s|List each deliver type once: "" appears twice.|},
          {%{"read_targets" => [%{}, %{"collection" => nil}]},
           ~s|List each collection of read_targets once: "" appears twice.|},
          {%{"target" => %{}, "read_targets" => [%{}]},
           ~s|Remove the collection "" from read_targets (index 0): target has it.|},
          {%{"inputs" => %{"destinations" => [%{}, %{}]}},
           ~s|List each destination once: "" appears twice.|},
          {%{"inputs" => %{"destinations" => [nil, %{"id" => nil}]}},
           ~s|List each destination once: "" appears twice.|}
        ] do
      assert DocumentsCheck.check(documents) == {:error, message}, inspect(documents)
    end
  end
end
