defmodule Apiary.Explore.ResultTest do
  # The explore result check against the explore contract's fixtures, vendored from the
  # integrations at the commit in `test/fixtures/contract/explore/v1/.contract-ref`: each
  # result fixture passes and each refused result fixture is no result, carried in a
  # `dev.qory.runtime.result` event as Forager sends it. Then the event rules (the last
  # result event by sequence, `is_error`, the `result` string), the 128 KiB bound in
  # bytes of the decoded string, each character and source rule of the schema, the strict
  # objects, the lengths in code points, and input that is not UTF-8 or not JSON.
  #
  # The inputs fixtures are vendored beside them and not validated here:
  # `ApiaryWeb.Contract.HandoverControllerTest` holds the inputs Qory writes to
  # `inputs.schema.json`.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Apiary.Explore.Result
  alias Apiary.Kinds.Bounds
  alias Apiary.Runs.Event

  @fixtures Path.expand("../../fixtures/contract/explore/v1", __DIR__)
  @max 128 * 1024

  # The characters `$defs/text` refuses, by code point; a source refuses them too, with
  # tab, line feed, carriage return and space.
  @refused Enum.concat([
             Enum.to_list(0x00..0x08),
             [0x0B, 0x0C],
             Enum.to_list(0x0E..0x1F),
             [0x7F],
             Enum.to_list(0x80..0x9F),
             [0xAD, 0x061C, 0x180E, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029],
             Enum.to_list(0x202A..0x202E),
             Enum.to_list(0x2060..0x2064),
             Enum.to_list(0x2066..0x2069),
             [0xFEFF],
             Enum.to_list(0xFFF9..0xFFFB)
           ])

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!()

  defp fixtures(dir), do: @fixtures |> Path.join(dir) |> File.ls!() |> Enum.sort()

  # A `dev.qory.runtime.result` event as the record holds it: the wire's JSON, decoded,
  # with `data` as Forager sent it.
  defp event(sequence, data) do
    %{"type" => "dev.qory.runtime.result", "sequence" => sequence, "data" => data}
    |> Jason.encode!()
    |> Jason.decode!()
    |> then(&%{type: &1["type"], sequence: &1["sequence"], data: &1["data"]})
  end

  defp result_event(sequence, text, is_error \\ false) do
    event(sequence, %{
      "session_id" => "session-1",
      "outcome" => if(is_error, do: "error_during_execution", else: "success"),
      "is_error" => is_error,
      "turns" => 3,
      "result" => text
    })
  end

  defp from_text(text), do: Result.from_events([result_event(1, text)])

  defp understood, do: Jason.decode!(fixture("result/understood.json"))
  defp not_understood, do: Jason.decode!(fixture("result/not-understood.json"))

  defp with_question(question), do: Jason.encode!(%{not_understood() | "questions" => [question]})

  defp with_source(source) do
    document = understood()
    [entry | rest] = document["knowledge"]
    Jason.encode!(%{document | "knowledge" => [%{entry | "sources" => [source]} | rest]})
  end

  defp ok?(text), do: match?({:ok, %{}}, from_text(text))

  describe "the contract's fixtures" do
    test "every result fixture is a result, the decoded document" do
      files = fixtures("result")
      assert length(files) == 3

      for file <- files do
        text = fixture("result/" <> file)
        assert from_text(text) == {:ok, Jason.decode!(text)}, file
      end
    end

    test "every refused result fixture is no result" do
      files = fixtures("invalid") |> Enum.filter(&String.starts_with?(&1, "result-"))
      assert length(files) == 14

      for file <- files do
        assert from_text(fixture("invalid/" <> file)) == :none, file
      end
    end

    test "the refused inputs fixtures are vendored beside them" do
      assert fixtures("invalid") |> Enum.count(&String.starts_with?(&1, "inputs-")) == 10

      assert fixtures("inputs") == [
               "first-attempt-loopback.json",
               "first-attempt.json",
               "third-attempt.json",
               "without-target.json"
             ]
    end
  end

  describe "the run's result event" do
    test "a run without a result event has no result" do
      assert Result.from_events([]) == :none

      assert Result.from_events([
               event(1, %{"result" => fixture("result/understood.json")})
               |> Map.put(:type, "dev.qory.runtime.turn_finished")
             ]) == :none
    end

    test "the result event with the highest sequence counts, in any order" do
      first = fixture("result/not-understood.json")
      last = fixture("result/understood.json")
      events = [result_event(2, first), result_event(9, last), result_event(5, first)]

      assert Result.from_events(events) == {:ok, Jason.decode!(last)}
      assert Result.from_events(Enum.reverse(events)) == {:ok, Jason.decode!(last)}
    end

    test "events of other types do not count, whatever their sequence" do
      text = fixture("result/understood.json")

      other = %{
        result_event(10, fixture("result/not-understood.json"))
        | type: "dev.qory.run.log"
      }

      assert Result.from_events([result_event(3, text), other]) == {:ok, Jason.decode!(text)}
    end

    test "a last result event that is an error is no result, though an earlier one passes" do
      events = [
        result_event(1, fixture("result/understood.json")),
        result_event(2, fixture("result/understood.json"), true)
      ]

      assert Result.from_events(events) == :none
    end

    test "is_error must be false: true, missing or not a boolean is no result" do
      text = fixture("result/understood.json")

      for data <- [
            %{"is_error" => true, "result" => text},
            %{"result" => text},
            %{"is_error" => "false", "result" => text},
            %{"is_error" => nil, "result" => text},
            %{"is_error" => 0, "result" => text}
          ] do
        assert Result.from_events([event(1, data)]) == :none, inspect(data)
      end
    end

    test "a result event without a result string is no result" do
      for data <- [
            %{"is_error" => false},
            %{"is_error" => false, "result" => nil},
            %{"is_error" => false, "result" => Jason.decode!(fixture("result/understood.json"))},
            %{"is_error" => false, "result" => ""}
          ] do
        assert Result.from_events([event(1, data)]) == :none
      end

      assert Result.from_events([%{type: "dev.qory.runtime.result", sequence: 1, data: nil}]) ==
               :none

      assert Result.from_events([
               %{result_event(1, fixture("result/understood.json")) | sequence: "1"}
             ]) == :none
    end

    test "a stored event reads the same" do
      text = fixture("result/not-understood.json")

      event = %Event{
        type: "dev.qory.runtime.result",
        sequence: 4,
        data: %{
          "session_id" => "session-1",
          "outcome" => "success",
          "is_error" => false,
          "result" => text
        }
      }

      assert Result.from_events([event]) == {:ok, Jason.decode!(text)}
    end
  end

  describe "the result text" do
    test "text that is not one JSON object is no result" do
      for text <- [
            "",
            "not json",
            "{",
            "[]",
            "null",
            "1",
            ~s("text"),
            fixture("result/understood.json") <> "{}",
            "```json\n" <> fixture("result/understood.json") <> "\n```"
          ] do
        assert from_text(text) == :none, inspect(text)
      end

      assert Result.parse(nil) == :none
      assert Result.parse(%{"version" => 1}) == :none
    end

    test "text that is not UTF-8 is no result" do
      [head, tail] = String.split(fixture("result/not-understood.json"), "Which", parts: 2)

      for bad <- [<<0xFF>>, <<0xC3>>, <<0xED, 0xA0, 0x80>>, <<0xF4, 0x90, 0x80, 0x80>>] do
        assert Result.parse(head <> bad <> "Which" <> tail) == :none
        assert Result.parse(bad <> fixture("result/not-understood.json")) == :none
      end

      for escape <- ["\\ud800", "\\udc00", "\\ud800\\u0041"] do
        assert Result.parse(String.replace(with_question("MARK"), "MARK", escape)) == :none
      end

      assert {:ok, _} =
               Result.parse(String.replace(with_question("MARK"), "MARK", "\\ud83d\\ude00"))
    end

    test "a version other than 1 or an unknown verdict is no result" do
      refute ok?(Jason.encode!(%{not_understood() | "version" => 2}))
      refute ok?(Jason.encode!(%{not_understood() | "version" => "1"}))
      refute ok?(Jason.encode!(%{not_understood() | "verdict" => "unsure"}))
      refute ok?(Jason.encode!(Map.delete(not_understood(), "version")))
    end

    test "the verdict decides which members are required or absent" do
      refute ok?(Jason.encode!(Map.put(understood(), "questions", ["Why?"])))

      for key <- ~w(complexity understanding scope approach) do
        refute ok?(Jason.encode!(Map.delete(understood(), key))), key
      end

      for {key, value} <- Map.take(understood(), ~w(complexity scope approach)) do
        refute ok?(Jason.encode!(Map.put(not_understood(), key, value))), key
      end

      assert ok?(Jason.encode!(Map.delete(not_understood(), "understanding")))
      assert ok?(Jason.encode!(Map.delete(understood(), "knowledge")))
    end
  end

  describe "the 128 KiB bound counts the bytes of the decoded result string" do
    # A not-understood document of exactly `bytes` bytes: its questions hold `pad`,
    # repeated as often as fits under the schema's lengths (20 questions of 2000 code
    # points), and blanks after the document make up the rest.
    defp sized(bytes, pad) do
      chars = min(20 * 2000, div(bytes - 200, byte_size(pad)))
      questions = pad |> List.duplicate(chars) |> Enum.chunk_every(2000) |> Enum.map(&Enum.join/1)

      document =
        Jason.encode!(%{"version" => 1, "verdict" => "not_understood", "questions" => questions})

      assert byte_size(document) <= bytes
      document <> String.duplicate(" ", bytes - byte_size(document))
    end

    test "exactly 128 KiB is a result, and one byte more is not" do
      at = sized(@max, "a")

      assert byte_size(at) == @max
      assert ok?(at)
      refute ok?(at <> " ")
    end

    test "a multi-byte text is counted in bytes, not characters" do
      at = sized(@max, "😀")

      assert byte_size(at) == @max
      assert String.length(at) < div(@max, 3)
      assert ok?(at)

      over = sized(@max + 1, "😀")
      assert byte_size(over) == @max + 1
      assert String.length(over) < div(@max, 3)
      refute ok?(over)

      e = sized(@max, "é")
      assert byte_size(e) == @max
      assert ok?(e)
      refute ok?(e <> "\n")
    end

    test "the string as the event carries it counts, not its escaped form in the event's JSON" do
      document = fixture("result/not-understood.json")
      text = document <> String.duplicate("\n", @max - byte_size(document))
      assert byte_size(text) == @max
      assert byte_size(Jason.encode!(text)) > 2 * @max - 2 * byte_size(document)

      assert from_text(text) == {:ok, Jason.decode!(document)}
      assert from_text(text <> "\n") == :none
    end

    test "an escape in the document counts as the bytes the string holds" do
      at = sized(@max, "a")
      escaped = String.replace(at, "aaaaaa", "\\u0061", global: false)

      assert byte_size(escaped) == @max
      assert ok?(escaped)
    end
  end

  describe "text" do
    test "tab, line feed and carriage return are the only control characters text takes" do
      assert ok?(with_question("one\ttwo\nthree\r\nfour"))
      assert ok?(with_question("Ends with a line feed\n"))
    end

    test "every control, bidirectional, separator and format character the schema lists is refused" do
      for cp <- @refused do
        char = <<cp::utf8>>
        refute ok?(with_question("Which " <> char <> " one?")), "U+" <> Integer.to_string(cp, 16)

        refute ok?(Jason.encode!(%{understood() | "understanding" => "A" <> char})),
               "U+" <> Integer.to_string(cp, 16)
      end
    end

    test "a bidirectional override in a nested text is refused" do
      document = understood()
      [alternative | _] = document["approach"]["alternatives"]
      bad = %{alternative | "reason" => "Safe " <> <<0x202E::utf8>> <> "txt.exe"}

      refute ok?(Jason.encode!(put_in(document, ["approach", "alternatives"], [bad])))
      refute ok?(Jason.encode!(put_in(document, ["scope", "out"], [<<0x2066::utf8>> <> "x"])))
      refute ok?(Jason.encode!(put_in(document, ["complexity", "reason"], <<0xFEFF::utf8>>)))
    end

    test "characters outside the list pass" do
      assert ok?(with_question("日本語, é, e" <> <<0x0301::utf8>> <> ", 😀, " <> <<0x200D::utf8>>))
    end
  end

  describe "lengths count code points" do
    test "a short text is 1 to 2000 code points" do
      refute ok?(with_question(""))
      assert ok?(with_question(String.duplicate("a", 2000)))
      refute ok?(with_question(String.duplicate("a", 2001)))
      assert ok?(with_question(String.duplicate("😀", 2000)))
      refute ok?(with_question(String.duplicate("😀", 2001)))
    end

    test "a letter with a combining accent is two code points, though one grapheme" do
      accented = "e" <> <<0x0301::utf8>>

      assert ok?(with_question(String.duplicate(accented, 1000)))
      refute ok?(with_question(String.duplicate(accented, 1000) <> "e"))
      refute ok?(with_question(String.duplicate(accented, 1001)))
    end

    test "a long text is 1 to 20000 code points" do
      document = understood()
      assert ok?(Jason.encode!(%{document | "understanding" => String.duplicate("a", 20_000)}))
      refute ok?(Jason.encode!(%{document | "understanding" => String.duplicate("a", 20_001)}))
      refute ok?(Jason.encode!(%{document | "understanding" => ""}))

      accented = String.duplicate("e" <> <<0x0301::utf8>>, 10_001)
      refute ok?(Jason.encode!(%{document | "understanding" => accented}))
    end

    test "a source is at most 2048 code points" do
      prefix = "https://docs.example.com/"
      assert ok?(with_source(prefix <> String.duplicate("a", 2048 - byte_size(prefix))))
      refute ok?(with_source(prefix <> String.duplicate("a", 2049 - byte_size(prefix))))
    end

    test "the lists hold as many entries as the schema allows" do
      refute ok?(Jason.encode!(%{not_understood() | "questions" => []}))
      refute ok?(Jason.encode!(%{not_understood() | "questions" => List.duplicate("Why?", 21)}))
      assert ok?(Jason.encode!(%{not_understood() | "questions" => List.duplicate("Why?", 20)}))
    end
  end

  describe "sources" do
    test "an https URL, with a path, a query or a fragment, is a source" do
      for source <- [
            "https://docs.example.com",
            "https://docs.example.com/guide/dates",
            "https://docs.example.com?q=1",
            "https://docs.example.com#part",
            "https://docs.example.com:8443/a",
            "https://docs.example.com/people/@sam",
            "https://docs.example.com/a?mail=sam@example.com",
            "https://docs.example.com/a\\b"
          ] do
        assert ok?(with_source(source)), source
      end
    end

    test "anything else is refused" do
      for source <- [
            "http://docs.example.com/guide",
            "HTTPS://docs.example.com/guide",
            "ftp://docs.example.com/guide",
            "//docs.example.com/guide",
            "docs.example.com/guide",
            "https://",
            "https:///guide",
            "https://?q",
            "https://#f",
            "https://docs example.com/guide",
            "https://docs.example.com/the guide",
            "https://docs.example.com/guide ",
            " https://docs.example.com/guide",
            "https://sam@docs.example.com/guide",
            "https://sam:secret@docs.example.com/guide",
            "https://@docs.example.com",
            "https://docs.example.com\\@evil.example.com/guide",
            "https://docs.example.com\\guide",
            "https://docs.example.com\n",
            "https://docs.example.com/guide\n",
            "https://docs.example.com/guide\t",
            "https://docs.example.com/guide" <> <<0x85::utf8>>,
            "https://docs.example.com" <> <<0x85::utf8>> <> "/guide"
          ] do
        refute ok?(with_source(source)), inspect(source)
      end
    end

    test "every character text refuses is refused in a source too, in the authority or after it" do
      for cp <- @refused ++ [0x09, 0x0A, 0x0D, 0x20] do
        char = <<cp::utf8>>
        refute ok?(with_source("https://docs.example.com/a" <> char <> "b")), "U+#{cp}"
        refute ok?(with_source("https://docs" <> char <> ".example.com/a")), "U+#{cp}"
      end
    end
  end

  describe "every object is strict" do
    test "a member the schema does not define is refused, at any depth" do
      document = understood()
      [alternative | _] = document["approach"]["alternatives"]
      [entry | _] = document["knowledge"]

      for changed <- [
            Map.put(document, "deliverables", []),
            put_in(document, ["complexity", "estimate"], "2d"),
            put_in(document, ["scope", "maybe"], []),
            put_in(document, ["approach", "steps"], []),
            put_in(document, ["approach", "alternatives"], [Map.put(alternative, "cost", "low")]),
            put_in(document, ["knowledge"], [Map.put(entry, "trust", "high")]),
            Map.put(not_understood(), "deliverables", [])
          ] do
        refute ok?(Jason.encode!(changed))
      end
    end
  end

  describe "the version is exactly 1" do
    defp with_version(number),
      do: ~s({"version":#{number},"verdict":"not_understood","questions":["Why?"]})

    test "1 written as an integer, a fraction or an exponent is the integer 1" do
      for number <- ~w(1 1.0 1e0 1E0 10e-1 0.1e1 100e-2 1.000) do
        assert {:ok, %{"version" => version}} = Result.parse(with_version(number)), number
        assert version === 1, number
      end
    end

    test "a number that is not exactly 1 is refused, however close" do
      for number <-
            ~w(1.0000000000000001 0.9999999999999999999 1e400 1e-400 1e999999999 1e-999999999 -1 -1.0 1.5 2 0 true null "1") do
        assert Result.parse(with_version(number)) == :none, number
      end
    end

    test "1. followed by 33 zeros is read, and followed by 34 or 40 zeros fails decoding and is refused" do
      assert {:ok, %{"version" => 1}} =
               Result.parse(with_version("1." <> String.duplicate("0", 33)))

      assert Result.parse(with_version("1." <> String.duplicate("0", 34))) == :none
      assert Result.parse(with_version("1." <> String.duplicate("0", 40))) == :none
    end

    test "Decimal counts significant digits, without leading zeros, after Jason adds a fraction to an exponent" do
      assert Result.parse(with_version("1" <> String.duplicate("0", 33) <> "e-33")) == :none

      assert {:ok, %{"version" => 1}} =
               Result.parse(with_version("0." <> String.duplicate("0", 39) <> "1e40"))
    end

    test "a number with a fraction anywhere else is refused" do
      document = understood()
      [entry | _] = document["knowledge"]

      refute ok?(String.replace(with_question("MARK"), ~s("MARK"), "1.5"))
      refute ok?(Jason.encode!(%{document | "knowledge" => [%{entry | "sources" => [1.5]}]}))
      refute ok?(Jason.encode!(put_in(document, ["complexity"], 1.0)))
    end
  end

  describe "the size of lists and objects" do
    # Which inputs the walk of the bounds refuses is asserted with `within_bounds?/1`, and
    # the refusal of each, not the time; that JSV never reads an input the walk refuses is
    # asserted by tracing (`Apiary.Kinds.BoundsCallersTest`).

    setup do
      # The schema and the bounds are built once; the first check pays for it.
      assert {:ok, _} = Result.parse(fixture("result/understood.json"))
      :ok
    end

    defp parsed(text) do
      assert byte_size(text) <= @max
      Result.parse(text)
    end

    defp entries(entry, count), do: Enum.join(List.duplicate(entry, count), ",")

    defp walked?(text), do: text |> Jason.decode!() |> Result.within_bounds?()

    defp many_questions,
      do:
        ~s({"version":1,"verdict":"not_understood","questions":[) <>
          entries("{}", 40_000) <> "]}"

    defp many_sources,
      do:
        ~s({"version":1,"verdict":"not_understood","questions":["q"],"knowledge":[{"text":"t","sources":[) <>
          entries("1", 60_000) <> "]}]}"

    defp many_members do
      members = Enum.map_join(1..11_000, ",", &~s("k#{&1}":{}))
      ~s({#{members},"version":1,"verdict":"not_understood","questions":["q"]})
    end

    defp fifty_by_fifty do
      entry = ~s({"text":"t","sources":[) <> entries("1", 50) <> "]}"

      ~s({"version":1,"verdict":"not_understood","questions":["q"],"knowledge":[) <>
        entries(entry, 50) <> "]}"
    end

    defp deep,
      do:
        ~s({"version":1,"verdict":"not_understood","questions":[) <>
          String.duplicate("[", 65_000) <> String.duplicate("]", 65_000) <> "]}"

    # A valid document with every list at its largest, over 100 KB.
    defp largest do
      text = fn n -> String.duplicate("t", n) end
      source = fn i -> "https://docs#{i}.example.com/" <> String.duplicate("p", 170) end

      %{
        "version" => 1,
        "verdict" => "understood",
        "complexity" => %{"level" => "complex", "reason" => text.(100)},
        "understanding" => text.(2000),
        "scope" => %{
          "in" => List.duplicate(text.(40), 50),
          "out" => List.duplicate(text.(40), 50)
        },
        "approach" => %{
          "summary" => text.(100),
          "alternatives" => List.duplicate(%{"summary" => text.(40), "reason" => text.(40)}, 10)
        },
        "knowledge" =>
          for(
            i <- 1..50,
            do: %{"text" => text.(40), "sources" => Enum.map(1..10, &source.(i * 10 + &1))}
          )
      }
    end

    test "the walk refuses a list or an object over the bounds, and passes what the schema takes" do
      refute walked?(many_questions())
      refute walked?(many_sources())
      refute walked?(many_members())

      assert walked?(fifty_by_fifty())
      assert walked?(deep())
      assert Result.within_bounds?(largest())

      for file <- fixtures("result"), do: assert(walked?(fixture("result/" <> file)), file)
    end

    test "40000 empty objects as questions are refused by the walk" do
      refute walked?(many_questions())
      assert parsed(many_questions()) == :none
    end

    test "60000 numbers as one knowledge entry's sources are refused by the walk" do
      refute walked?(many_sources())
      assert parsed(many_sources()) == :none
    end

    test "an object with thousands of members is refused by the walk" do
      refute walked?(many_members())
      assert parsed(many_members()) == :none
    end

    test "50 knowledge entries of 50 sources each pass the walk, and the schema refuses them" do
      assert walked?(fifty_by_fifty())
      assert parsed(fifty_by_fifty()) == :none
    end

    test "deep nesting passes the walk in constant stack, and the schema refuses it" do
      assert walked?(deep())
      assert parsed(deep()) == :none
    end

    test "a valid document with every list at its largest is a result" do
      document = largest()
      encoded = Jason.encode!(document)
      assert byte_size(encoded) > 100_000
      assert parsed(encoded) == {:ok, document}

      assert {:ok, _} =
               parsed(
                 Jason.encode!(%{
                   "version" => 1,
                   "verdict" => "not_understood",
                   "understanding" => String.duplicate("t", 20_000),
                   "questions" => List.duplicate(String.duplicate("t", 2000), 20)
                 })
               )

      refute ok?(Jason.encode!(put_in(document, ["scope", "in"], List.duplicate("t", 51))))
    end
  end

  describe "the bounds come from the schema" do
    test "the vendored result.schema.json allows lists of 50 and objects of 8 members" do
      assert Result.bounds() == [list: 50, members: 8]
    end

    test "a schema whose arrays and objects are all bounded gives the largest" do
      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "a" => %{"type" => "array", "maxItems" => 3, "items" => %{"$ref" => "#/$defs/b"}},
          "default" => %{"type" => "array", "maxItems" => 7, "items" => %{"const" => 1}}
        },
        "$defs" => %{"b" => %{"type" => "string"}},
        "allOf" => [%{"if" => %{"properties" => %{"a" => %{"const" => 1}}}, "then" => false}]
      }

      assert Bounds.from_schema(schema) == [list: 7, members: 2]
    end

    test "a schema whose bounds cannot be told raises" do
      object = &%{"type" => "object", "additionalProperties" => false, "properties" => &1}

      for schema <- [
            %{"type" => "array"},
            %{"type" => "array", "maxItems" => "50"},
            %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}},
            %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
            %{"type" => ["array", "null"], "maxItems" => 3},
            %{"items" => %{}},
            %{"properties" => %{}},
            %{"additionalProperties" => false},
            %{"$ref" => "#/$defs/a", "items" => %{"type" => "string"}},
            %{"type" => "object", "additionalProperties" => false, "patternProperties" => %{}},
            %{"type" => "array", "maxItems" => 3, "prefixItems" => []},
            object.(%{"default" => %{"type" => "array"}}),
            object.(%{"enum" => %{"type" => "array"}}),
            object.(%{"const" => %{"type" => "object"}}),
            object.(%{"examples" => %{"type" => "array"}}),
            object.(%{"a" => true}),
            object.(%{"a" => %{}}),
            object.(%{"a" => %{"description" => "anything"}}),
            object.(%{"a" => %{"$ref" => "https://example.com/other.schema.json"}}),
            object.(%{"a" => %{"const" => [1, 2]}}),
            object.(%{"a" => %{"enum" => [%{}]}}),
            %{"type" => "string", "allOf" => [%{"type" => "array"}]},
            %{"type" => "string", "$defs" => %{"a" => %{"type" => "object"}}}
          ] do
        assert_raise ArgumentError, fn -> Bounds.from_schema(schema) end
      end
    end
  end

  describe "untrusted input never raises" do
    property "any bytes as the result text are no result or a result" do
      check all(
              text <- one_of([binary(), string(:utf8), string(:printable)]),
              max_runs: 300
            ) do
        event = %{
          type: "dev.qory.runtime.result",
          sequence: 1,
          data: %{"is_error" => false, "result" => text}
        }

        assert parse_shape(Result.parse(text))
        assert parse_shape(Result.from_events([event]))
      end
    end

    property "a result fixture with any bytes put in at any place is no result or a result" do
      check all(
              file <- member_of(["understood.json", "not-understood.json"]),
              at <- integer(0..2000),
              bytes <- binary(min_length: 1, max_length: 8),
              max_runs: 300
            ) do
        text = fixture("result/" <> file)
        {head, tail} = String.split_at(text, rem(at, String.length(text)))
        changed = head <> bytes <> tail
        result = Result.parse(changed)

        assert parse_shape(result)
        if not String.valid?(changed), do: assert(result == :none)
      end
    end

    property "any bytes inside the document's strings are no result or a result" do
      check all(bytes <- binary(min_length: 1), max_runs: 300) do
        question = ~s({"version":1,"verdict":"not_understood","questions":[") <> bytes <> ~s("]})
        source = with_source("https://docs.example.com/MARK") |> String.replace("MARK", bytes)

        for text <- [question, source] do
          result = Result.parse(text)
          assert parse_shape(result)
          if not String.valid?(bytes), do: assert(result == :none)
        end
      end
    end

    # `check all` raises the generation size by one each run, so over 200 runs it reaches
    # 200, and `term()` grows with it: at size 200 a term nests up to about 340 values
    # (StreamData's `tree/2` allows size^1.1 leaves), and the map holds up to 200 of them.
    # Building one such map took up to half a second, the property several seconds locally
    # and over a minute on a slow runner. Each generator is capped at size 30: a term
    # still nests lists, maps and tuples of booleans, integers, floats, binaries, atoms
    # and references, up to about 42 values, and the map still holds up to 30 members.
    # `from_events/1` reads only the data's `is_error` and `result`, so larger data tests
    # no more.
    property "any data in a result event is no result or a result" do
      check all(
              data <- capped(one_of([term(), map_of(string(:utf8), term())]), 30),
              is_error <- capped(one_of([boolean(), term()]), 30),
              max_runs: 200
            ) do
        data = if is_map(data), do: Map.put(data, "is_error", is_error), else: data

        assert parse_shape(
                 Result.from_events([%{type: "dev.qory.runtime.result", sequence: 1, data: data}])
               )
      end
    end
  end

  # The generator `data` at the run's generation size, at most `max`: early runs stay
  # small, and later runs stop growing at `max`.
  defp capped(data, max), do: StreamData.scale(data, &min(&1, max))

  defp parse_shape(:none), do: true
  defp parse_shape({:ok, %{}}), do: true
  defp parse_shape(_other), do: false
end
