defmodule Apiary.Explore.ResultTest do
  # The explore result check against the explore contract's fixtures, vendored from the
  # integrations at the commit in `test/fixtures/contract/explore/v1/.contract-ref`: each
  # result fixture passes and each refused result fixture is no result, carried in a
  # `dev.qory.runtime.result` event as Forager sends it. Then the event rules (the last
  # result event by sequence, `is_error`, the `result` string), the 128 KiB bound in
  # bytes of the decoded string, the members the verdict requires or forbids (`message`
  # for `understood`, `questions` for `not_understood`), the refused characters in every
  # text (`message`, `question`, an option's `title` and `explanation`), the lengths in
  # code points, the bounds of the lists, the strict objects, the version, the walk of
  # the bounds before the schema, and input that is not UTF-8 or not JSON.
  #
  # The inputs fixtures are vendored beside them and not validated here:
  # `Apiary.Dispatches.HandoverTest` checks the inputs Qory writes against
  # `inputs.schema.json`.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Apiary.Explore.Result
  alias Apiary.Kinds.Bounds
  alias Apiary.Runs.Event

  @fixtures Path.expand("../../fixtures/contract/explore/v1", __DIR__)
  @max 128 * 1024

  # The characters `$defs/text` refuses, by code point.
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

  defp with_message(message), do: Jason.encode!(%{understood() | "message" => message})

  defp with_questions(questions),
    do: Jason.encode!(%{not_understood() | "questions" => questions})

  # The not-understood fixture with its first question changed by `change`.
  defp with_first_question(change) do
    document = not_understood()
    [first | rest] = document["questions"]
    Jason.encode!(%{document | "questions" => [change.(first) | rest]})
  end

  defp with_question(text), do: with_first_question(&%{&1 | "question" => text})

  defp with_options(options), do: with_first_question(&%{&1 | "options" => options})

  # The not-understood fixture with `changes` merged into its first question's first option.
  defp with_option(changes) do
    with_first_question(fn %{"options" => [option | rest]} = question ->
      %{question | "options" => [Map.merge(option, changes) | rest]}
    end)
  end

  defp with_title(title), do: with_option(%{"title" => title})
  defp with_explanation(explanation), do: with_option(%{"explanation" => explanation})

  defp question(text, options \\ []), do: %{"question" => text, "options" => options}
  defp option(title, explanation), do: %{"title" => title, "explanation" => explanation}

  defp ok?(text), do: match?({:ok, %{}}, from_text(text))

  describe "the contract's fixtures" do
    test "every result fixture is a result, the decoded document" do
      files = fixtures("result")

      assert files == [
               "not-understood-without-options.json",
               "not-understood.json",
               "understood.json"
             ]

      for file <- files do
        text = fixture("result/" <> file)
        assert from_text(text) == {:ok, Jason.decode!(text)}, file
      end
    end

    test "every refused result fixture is no result" do
      files = fixtures("invalid") |> Enum.filter(&String.starts_with?(&1, "result-"))
      assert length(files) == 19

      for file <- files do
        assert from_text(fixture("invalid/" <> file)) == :none, file
      end
    end

    test "the refused inputs fixtures are vendored beside them" do
      assert fixtures("invalid") |> Enum.count(&String.starts_with?(&1, "inputs-")) == 13

      assert fixtures("inputs") == [
               "first-attempt-loopback.json",
               "first-attempt.json",
               "fourth-attempt.json",
               "third-attempt.json",
               "without-target.json",
               "without-ticket.json"
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
        assert Result.parse(String.replace(with_message("MARK"), "MARK", escape)) == :none
      end

      assert {:ok, _} =
               Result.parse(String.replace(with_question("MARK"), "MARK", "\\ud83d\\ude00"))
    end

    test "a version other than 1 or an unknown verdict is no result" do
      refute ok?(Jason.encode!(%{not_understood() | "version" => 2}))
      refute ok?(Jason.encode!(%{not_understood() | "version" => "1"}))
      refute ok?(Jason.encode!(%{not_understood() | "verdict" => "unsure"}))
      refute ok?(Jason.encode!(%{understood() | "verdict" => "unsure"}))
      refute ok?(Jason.encode!(Map.delete(not_understood(), "version")))
      refute ok?(Jason.encode!(Map.delete(understood(), "verdict")))
    end

    test "the verdict decides which members are required or absent" do
      message = understood()["message"]
      questions = not_understood()["questions"]

      refute ok?(Jason.encode!(Map.delete(understood(), "message")))
      refute ok?(Jason.encode!(Map.put(understood(), "questions", questions)))
      refute ok?(Jason.encode!(Map.delete(not_understood(), "questions")))
      refute ok?(Jason.encode!(Map.put(not_understood(), "message", message)))

      assert ok?(Jason.encode!(%{"version" => 1, "verdict" => "understood", "message" => "a"}))

      assert ok?(
               Jason.encode!(%{
                 "version" => 1,
                 "verdict" => "not_understood",
                 "questions" => [question("Why?")]
               })
             )
    end

    test "a question needs its text and its options, and an option its title and explanation" do
      refute ok?(with_questions(["Why?"]))
      refute ok?(with_questions([%{"question" => "Why?"}]))
      refute ok?(with_questions([%{"options" => []}]))
      refute ok?(with_options([%{"title" => "Full refund"}]))
      refute ok?(with_options([%{"explanation" => "The policy covers it."}]))
      refute ok?(with_options(["Full refund"]))
      refute ok?(with_questions([question("Why?", nil)]))
    end
  end

  describe "the 128 KiB bound counts the bytes of the decoded result string" do
    # An understood document of exactly `bytes` bytes: its message is `pad`, repeated as
    # often as fits, and blanks after the document make up the rest.
    defp sized(bytes, pad) do
      message = String.duplicate(pad, div(bytes - 100, byte_size(pad)))

      document =
        Jason.encode!(%{"version" => 1, "verdict" => "understood", "message" => message})

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
      for with_text <- [&with_message/1, &with_question/1, &with_title/1, &with_explanation/1] do
        assert ok?(with_text.("one\ttwo\nthree\r\nfour"))
        assert ok?(with_text.("Ends with a line feed\n"))
      end
    end

    test "every control, bidirectional, separator and format character the schema lists is refused, in every text" do
      for cp <- @refused,
          with_text <- [&with_message/1, &with_question/1, &with_title/1, &with_explanation/1] do
        refute ok?(with_text.("Which " <> <<cp::utf8>> <> " one?")),
               "U+" <> Integer.to_string(cp, 16)
      end
    end

    test "a bidirectional override in an option of a later question is refused" do
      document = not_understood()
      [first, second] = document["questions"]
      [option | rest] = second["options"]
      bad = %{option | "explanation" => "Safe " <> <<0x202E::utf8>> <> "txt.exe"}

      changed = %{
        document
        | "questions" => [first, %{second | "options" => [option, bad | rest]}]
      }

      assert ok?(Jason.encode!(document))
      refute ok?(Jason.encode!(changed))
    end

    test "characters outside the list pass" do
      text = "日本語, é, e" <> <<0x0301::utf8>> <> ", 😀, " <> <<0x200D::utf8>>

      for with_text <- [&with_message/1, &with_question/1, &with_title/1, &with_explanation/1] do
        assert ok?(with_text.(text))
      end
    end
  end

  describe "lengths count code points" do
    test "an explanation, a short text, is 1 to 2000 code points" do
      refute ok?(with_explanation(""))
      assert ok?(with_explanation(String.duplicate("a", 2000)))
      refute ok?(with_explanation(String.duplicate("a", 2001)))
      assert ok?(with_explanation(String.duplicate("😀", 2000)))
      refute ok?(with_explanation(String.duplicate("😀", 2001)))
    end

    test "a letter with a combining accent is two code points, though one grapheme" do
      accented = "e" <> <<0x0301::utf8>>

      assert ok?(with_explanation(String.duplicate(accented, 1000)))
      refute ok?(with_explanation(String.duplicate(accented, 1000) <> "e"))
      refute ok?(with_explanation(String.duplicate(accented, 1001)))

      assert ok?(with_title(String.duplicate(accented, 100)))
      refute ok?(with_title(String.duplicate(accented, 101)))
    end

    test "a question, a long text, is 1 to 20000 code points" do
      assert ok?(with_question(String.duplicate("a", 20_000)))
      refute ok?(with_question(String.duplicate("a", 20_001)))
      refute ok?(with_question(""))

      accented = "e" <> <<0x0301::utf8>>
      assert ok?(with_question(String.duplicate(accented, 10_000)))
      refute ok?(with_question(String.duplicate(accented, 10_001)))
    end

    test "an option's title is 1 to 200 code points" do
      refute ok?(with_title(""))
      assert ok?(with_title(String.duplicate("a", 200)))
      refute ok?(with_title(String.duplicate("a", 201)))
      assert ok?(with_title(String.duplicate("😀", 200)))
      refute ok?(with_title(String.duplicate("😀", 201)))
    end

    test "a message is at least 1 code point, and only the 128 KiB bound limits it" do
      refute ok?(with_message(""))
      assert ok?(with_message("a"))
      assert ok?(with_message(String.duplicate("a", 120_000)))
      assert ok?(with_message(String.duplicate("😀", 30_000)))
    end
  end

  describe "the lists hold as many entries as the schema allows" do
    test "1 to 20 questions" do
      refute ok?(with_questions([]))
      assert ok?(with_questions([question("Why?")]))
      assert ok?(with_questions(List.duplicate(question("Why?"), 20)))
      refute ok?(with_questions(List.duplicate(question("Why?"), 21)))
    end

    test "0 to 10 options to a question" do
      assert ok?(with_options([]))
      assert ok?(with_options(List.duplicate(option("Full refund", "It covers it."), 10)))
      refute ok?(with_options(List.duplicate(option("Full refund", "It covers it."), 11)))
    end
  end

  describe "every object is strict" do
    test "a member the schema does not define is refused, at any depth" do
      for changed <- [
            Jason.encode!(Map.put(understood(), "deliverables", [])),
            Jason.encode!(Map.put(not_understood(), "deliverables", [])),
            with_first_question(&Map.put(&1, "default", 0)),
            with_option(%{"note" => "Ask the customer first."})
          ] do
        refute ok?(changed), changed
      end
    end

    test "the members of earlier versions of the result are refused" do
      for {key, value} <- [
            {"complexity", %{"level" => "simple", "reason" => "One refund."}},
            {"understanding", "The customer asks for a refund."},
            {"scope", %{"in" => ["Refund the order."], "out" => []}},
            {"approach", %{"summary" => "Refund it.", "alternatives" => []}},
            {"knowledge", [%{"text" => "The policy.", "sources" => []}]}
          ],
          document <- [understood(), not_understood()] do
        refute ok?(Jason.encode!(Map.put(document, key, value))), key
      end
    end
  end

  describe "the version is exactly 1" do
    defp with_version(number),
      do:
        ~s({"version":#{number},"verdict":"not_understood","questions":[{"question":"Why?","options":[]}]})

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
      refute ok?(String.replace(with_question("MARK"), ~s("MARK"), "1.5"))
      refute ok?(String.replace(with_title("MARK"), ~s("MARK"), "1.5"))
      refute ok?(String.replace(with_message("MARK"), ~s("MARK"), "1.0"))
      refute ok?(String.replace(with_options([]), ~s("options":[]), ~s("options":[1.5])))
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

    defp many_options,
      do:
        ~s({"version":1,"verdict":"not_understood","questions":[{"question":"q","options":[) <>
          entries("1", 60_000) <> "]}]}"

    defp many_members do
      members = Enum.map_join(1..11_000, ",", &~s("k#{&1}":{}))

      ~s({#{members},"version":1,"verdict":"not_understood","questions":[{"question":"q","options":[]}]})
    end

    defp twenty_by_ten do
      entry = ~s({"question":"q","options":[) <> entries("1", 10) <> "]}"
      ~s({"version":1,"verdict":"not_understood","questions":[) <> entries(entry, 20) <> "]}"
    end

    defp deep,
      do:
        ~s({"version":1,"verdict":"not_understood","questions":[) <>
          String.duplicate("[", 65_000) <> String.duplicate("]", 65_000) <> "]}"

    # A valid document with every list at its largest, over 100 KB.
    defp largest do
      text = fn n -> String.duplicate("t", n) end

      %{
        "version" => 1,
        "verdict" => "not_understood",
        "questions" =>
          List.duplicate(
            question(text.(500), List.duplicate(option(text.(200), text.(250)), 10)),
            20
          )
      }
    end

    test "the walk refuses a list or an object over the bounds, and passes what the schema takes" do
      refute walked?(many_questions())
      refute walked?(many_options())
      refute walked?(many_members())

      assert walked?(twenty_by_ten())
      assert walked?(deep())
      assert Result.within_bounds?(largest())

      for file <- fixtures("result"), do: assert(walked?(fixture("result/" <> file)), file)
    end

    test "40000 empty objects as questions are refused by the walk" do
      refute walked?(many_questions())
      assert parsed(many_questions()) == :none
    end

    test "60000 numbers as one question's options are refused by the walk" do
      refute walked?(many_options())
      assert parsed(many_options()) == :none
    end

    test "an object with thousands of members is refused by the walk" do
      refute walked?(many_members())
      assert parsed(many_members()) == :none
    end

    test "20 questions of 10 numbers as options each pass the walk, and the schema refuses them" do
      assert walked?(twenty_by_ten())
      assert parsed(twenty_by_ten()) == :none
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

      [first | _] = document["questions"]
      refute ok?(Jason.encode!(%{document | "questions" => List.duplicate(first, 21)}))

      more = %{first | "options" => List.duplicate(hd(first["options"]), 11)}
      refute ok?(Jason.encode!(%{document | "questions" => [more]}))
    end
  end

  describe "the bounds come from the schema" do
    test "the vendored result.schema.json allows lists of 20 and objects of 4 members" do
      assert Result.bounds() == [list: 20, members: 4]
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
              file <- member_of(fixtures("result")),
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
        for text <- [
              with_message("MARK"),
              with_question("MARK"),
              with_title("MARK"),
              with_explanation("MARK")
            ] do
          result = Result.parse(String.replace(text, "MARK", bytes))
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
