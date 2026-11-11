defmodule Apiary.Artifacts.FormatTest do
  use ExUnit.Case, async: true

  alias Apiary.Artifacts.{Filename, Format, Type}

  @moduletag :tmp_dir

  @svg_namespace "http://www.w3.org/2000/svg"

  defp standard(name), do: Enum.find(Type.standard(), &(&1.name == name))

  defp check(context, type, filename, bytes) do
    path = Path.join(context.tmp_dir, "file-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    Format.check(standard(type), filename, path)
  end

  describe "an image" do
    test "is PNG, JPEG, GIF or WebP by its first bytes", context do
      assert {:ok, "image/png"} =
               check(context, "mockup", "a", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0>>)

      assert {:ok, "image/jpeg"} = check(context, "mockup", "a", <<0xFF, 0xD8, 0xFF, 0xE0>>)
      assert {:ok, "image/gif"} = check(context, "mockup", "a", "GIF87a" <> <<1>>)
      assert {:ok, "image/gif"} = check(context, "mockup", "a", "GIF89a" <> <<1>>)

      assert {:ok, "image/webp"} =
               check(context, "mockup", "a", "RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ")
    end

    test "is SVG when an XML parser reads it to its end with an svg root in the SVG namespace",
         context do
      assert {:ok, "image/svg+xml"} =
               check(context, "mockup", "a.png", ~s(<svg xmlns="#{@svg_namespace}"/>))

      assert {:ok, "image/svg+xml"} =
               check(
                 context,
                 "mockup",
                 "a",
                 ~s(\uFEFF<?xml version="1.0" encoding="UTF-8"?>\n<!-- a mockup -->\n<s:svg xmlns:s="#{@svg_namespace}"><s:rect/></s:svg>\n)
               )
    end

    test "is refused when it is neither", context do
      for bytes <- [
            "",
            "<html><body></body></html>",
            ~s(<svg width="1"/>),
            ~s(<html xmlns="#{@svg_namespace}"/>),
            ~s(<svg xmlns="#{@svg_namespace}">),
            ~s(<svg xmlns="#{@svg_namespace}"/><svg xmlns="#{@svg_namespace}"/>),
            ~s(<svg xmlns="#{@svg_namespace}"/>trailing),
            ~s(<svg xmlns="#{@svg_namespace}">&undeclared;</svg>),
            <<0xFF, 0xFE, "<svg/>">>,
            "RIFF" <> <<0, 0, 0, 0>> <> "AVI "
          ] do
        assert {:error, :format} = check(context, "mockup", "a.svg", bytes),
               "#{inspect(bytes)} is taken"
      end
    end

    test "refuses an SVG that declares a document type or entities", context do
      doctype =
        ~s(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaa"><!ENTITY b "&a;&a;&a;">]>) <>
          ~s(<svg xmlns="#{@svg_namespace}">&b;</svg>)

      assert {:error, :format} = check(context, "mockup", "a.svg", doctype)

      assert {:error, :format} =
               check(
                 context,
                 "mockup",
                 "a.svg",
                 ~s(<!doctype svg><svg xmlns="#{@svg_namespace}"/>)
               )
    end

    test "takes an SVG of 512 KiB within the budget, and refuses a larger one", context do
      element = ~s(<rect x="1" y="2" width="3" height="4" fill="#abcdef"/>\n)
      head = ~s(<svg xmlns="#{@svg_namespace}">)
      tail = "</svg>"
      count = div(524_288 - byte_size(head) - byte_size(tail), byte_size(element))
      svg = head <> String.duplicate(element, count) <> tail
      assert byte_size(svg) <= 524_288
      assert {:ok, "image/svg+xml"} = check(context, "mockup", "a.svg", svg)

      larger = head <> String.duplicate(element, count + 1) <> tail
      assert {:error, :format} = check(context, "mockup", "a.svg", larger)
    end

    test "takes 256 attributes on an element and refuses 257, before the parse", context do
      head = ~s(<svg xmlns="#{@svg_namespace}">)
      at = fn n -> "<g" <> Enum.map_join(1..n, "", &~s( a#{&1}="1")) <> "/>" end

      assert {:ok, "image/svg+xml"} =
               check(context, "mockup", "a.svg", head <> at.(256) <> "</svg>")

      assert {:error, :format} = check(context, "mockup", "a.svg", head <> at.(257) <> "</svg>")

      # A `>` in a value does not end the count: only a `<` does.
      many = "<g" <> Enum.map_join(1..300, "", &~s( a#{&1}=">")) <> "/>"
      assert {:error, :format} = check(context, "mockup", "a.svg", head <> many <> "</svg>")
    end

    test "parses the slowest SVG it takes, 512 KiB of elements of 256 attributes, in under 1 s",
         context do
      element = "<g" <> Enum.map_join(1..256, "", &~s( attribute-#{&1}="1")) <> "/>"
      head = ~s(<svg xmlns="#{@svg_namespace}">)
      tail = "</svg>"
      count = div(524_288 - byte_size(head) - byte_size(tail), byte_size(element))
      svg = head <> String.duplicate(element, count) <> tail
      assert byte_size(svg) > 500_000

      {microseconds, result} = :timer.tc(fn -> check(context, "mockup", "a.svg", svg) end)
      assert {:ok, "image/svg+xml"} = result
      assert microseconds < 1_000_000
    end
  end

  describe "a video" do
    test "is MP4 by an ftyp box with an MP4 brand, or WebM by its EBML document type", context do
      assert {:ok, "video/mp4"} = check(context, "demo-video", "a", <<0, 0, 0, 24, "ftypisom">>)
      assert {:ok, "video/mp4"} = check(context, "demo-video", "a", <<0, 0, 0, 24, "ftypmp42">>)

      assert {:ok, "video/webm"} =
               check(
                 context,
                 "demo-video",
                 "a",
                 <<0x1A, 0x45, 0xDF, 0xA3, 0x42, 0x82, 0x84, "webm">>
               )
    end

    test "is refused for another brand, Matroska or anything else", context do
      for bytes <- [
            <<0, 0, 0, 24, "ftypheic">>,
            <<0, 0, 0, 24, "ftypqt  ">>,
            <<0x1A, 0x45, 0xDF, 0xA3, 0x42, 0x82, 0x88, "matroska">>,
            <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>,
            ""
          ] do
        assert {:error, :format} = check(context, "demo-video", "a.mp4", bytes)
      end
    end

    test "takes WebVTT captions in a file whose name ends in .vtt", context do
      captions = "WEBVTT\n\n00:00.000 --> 00:02.000\nThe gift card field.\n"
      vtt = "text/vtt; charset=utf-8"

      assert {:ok, ^vtt} = check(context, "demo-video", "en.vtt", captions)
      assert {:ok, ^vtt} = check(context, "demo-video", "EN.VTT", "\uFEFFWEBVTT - English\n")
      assert {:ok, ^vtt} = check(context, "demo-video", "en.vtt", "WEBVTT")

      for {filename, bytes} <- [
            {"en.txt", captions},
            {"en.vtt", "WEBVTTX\n"},
            {"en.vtt", "1\n00:00.000 --> 00:02.000\n"},
            {"en.vtt", "WEBVTT\n" <> <<0>>},
            {"en.vtt", "WEBVTT\n" <> <<0xFF>>}
          ] do
        assert {:error, :format} = check(context, "demo-video", filename, bytes),
               "expected #{inspect(bytes)} as #{filename} to be refused"
      end
    end
  end

  describe "a document" do
    test "is UTF-8 Markdown text in a file whose name ends in .md", context do
      assert {:ok, "text/markdown; charset=utf-8"} =
               check(context, "explainer", "a.md", "# Gift cards\n\n```mermaid\ngraph TD\n```\n")

      assert {:ok, _type} = check(context, "explainer", "A.Md", "")
      assert {:error, :extension} = check(context, "explainer", "a.markdown", "# A")
      assert {:error, :extension} = check(context, "explainer", "md", "# A")
      assert {:error, :format} = check(context, "explainer", "a.md", <<0xC3, 0x28>>)
      assert {:error, :format} = check(context, "explainer", "a.md", "a\u0000b")
    end
  end

  test "a file takes any bytes", context do
    {:ok, type} = {:ok, %Type{name: "bids", base_view: :file}}
    path = Path.join(context.tmp_dir, "any")
    File.write!(path, <<0, 1, 2>>)
    assert {:ok, "application/octet-stream"} = Format.check(type, "a.exe", path)
  end

  test "a file that cannot be read is unreadable", context do
    missing = Path.join(context.tmp_dir, "missing")

    for type <- ~w(explainer mockup demo-video verdict) do
      assert {:error, :unreadable} = Format.check(standard(type), "a.md", missing)
    end
  end

  test "a structured document is one JSON value its schema takes", context do
    assert {:ok, "application/json"} = check(context, "verdict", "a", ~s({"verdict":"passed"}))

    assert {:error, {:schema, %{path: "#", error: extra}}} =
             check(context, "verdict", "a", ~s({"verdict":"passed","x":1}))

    assert extra =~ "'x'"

    # A list longer than any list the schema file allows (20 points) is past the bounds,
    # before JSV reads it.
    assert {:error, {:schema, %{path: "#", error: "the document has more values" <> _}}} =
             check(context, "verdict", "a", Jason.encode!(Enum.to_list(1..21)))

    assert {:error, :format} = check(context, "verdict", "a", ~s({"verdict":"passed"} x))
    assert {:error, :format} = check(context, "verdict", "a", <<0xFF>>)
  end

  test "a standard type's text bounds count code points, not graphemes", context do
    # 501 letters, each with a combining accent: 1002 code points, 501 graphemes.
    title = String.duplicate("e\u0301", 501)
    change = %{"url" => "https://forge.example.com/acme/shop/pull/4", "title" => title}

    assert {:error, {:schema, %{path: "#/title"}}} =
             check(context, "change", "a", Jason.encode!(change))

    change = %{change | "title" => String.duplicate("e\u0301", 250)}
    assert {:ok, _type} = check(context, "change", "a", Jason.encode!(change))
  end

  describe "the questions format" do
    @at "2026-11-04T10:00:00Z"

    defp question(attrs \\ %{}) do
      Map.merge(
        %{
          "id" => "q1",
          "question" => "Which basket keeps the price?",
          "options" => [],
          "state" => "open",
          "asked" => %{"run" => 12, "at" => @at}
        },
        attrs
      )
    end

    defp questions(context, list),
      do: check(context, "questions", "questions.json", Jason.encode!(%{"questions" => list}))

    test "an over-long question has the schema's message of the allOf around its limit",
         context do
      # Only the type `mockup` reads the errors inside the `allOf`.
      assert {:error,
              {:schema,
               %{
                 path: "#/questions/0/question",
                 error: "value did not conform to all of the given schemas"
               }}} =
               questions(context, [question(%{"question" => String.duplicate("a", 501)})])
    end

    test "a question is 1 to 500 characters on one line", context do
      assert {:ok, "application/json"} =
               questions(context, [question(%{"question" => String.duplicate("a", 500)})])

      for text <- [String.duplicate("a", 501), "", "Two\nlines?"] do
        assert {:error, {:schema, %{path: "#/questions/0/question"}}} =
                 questions(context, [question(%{"question" => text})])
      end
    end

    test "a context is optional, 1 to 20000 characters of Markdown", context do
      assert {:ok, _} =
               questions(context, [question(%{"context" => String.duplicate("a\n", 10_000)})])

      for text <- [String.duplicate("a", 20_001), ""] do
        assert {:error, {:schema, %{path: "#/questions/0/context"}}} =
                 questions(context, [question(%{"context" => text})])
      end
    end

    test "an id is 1 to 32 lower-case letters, digits and hyphens, each once", context do
      assert {:ok, _} = questions(context, [question(%{"id" => String.duplicate("q-1", 10)})])

      for id <- ["Q1", "q_1", "", String.duplicate("q", 33)] do
        assert {:error, {:schema, %{path: "#/questions/0/id"}}} =
                 questions(context, [question(%{"id" => id})])
      end

      assert {:error, {:schema, %{path: "#/questions/1/id", error: error}}} =
               questions(context, [question(), question(%{"question" => "Which sale?"})])

      assert error =~ "earlier question"
    end

    test "a question offers 0 to 4 options, in any state", context do
      option = &%{"title" => "Option #{&1}", "explanation" => "Why #{&1}."}
      answer = %{"option" => nil, "note" => "Yes.", "by" => %{"name" => "Ann"}, "at" => @at}

      for state <- [
            %{"state" => "open"},
            %{"state" => "answered", "answer" => answer},
            %{"state" => "withdrawn"}
          ] do
        for count <- 1..4 do
          options = Enum.map(1..count, option)
          assert {:ok, _} = questions(context, [question(Map.put(state, "options", options))])
        end

        assert {:error,
                {:schema,
                 %{
                   path: "#/questions/0/options",
                   error: "value should have at most 4 items, got 5"
                 }}} =
                 questions(context, [
                   question(Map.put(state, "options", Enum.map(1..5, option)))
                 ])
      end
    end

    test "an open question with no option is taken: the member writes the answer", context do
      assert {:ok, _} = questions(context, [question(%{"options" => []})])
    end

    test "an option's recommended is an optional boolean", context do
      option = %{"title" => "The small one", "explanation" => "The checkout shows it."}

      for value <- [true, false] do
        assert {:ok, _} =
                 questions(context, [
                   question(%{"options" => [Map.put(option, "recommended", value)]})
                 ])
      end

      assert {:ok, _} = questions(context, [question(%{"options" => [option]})])

      for value <- ["yes", 1, nil] do
        assert {:error,
                {:schema,
                 %{
                   path: "#/questions/0/options/0/recommended",
                   error: "value is not of type boolean"
                 }}} =
                 questions(context, [
                   question(%{"options" => [Map.put(option, "recommended", value)]})
                 ])
      end

      # An option has no other new member.
      assert {:error, {:schema, %{path: "#/questions/0/options/0"}}} =
               questions(context, [question(%{"options" => [Map.put(option, "best", true)]})])

      for member <- ["title", "explanation"] do
        assert {:error, {:schema, %{path: "#/questions/0/options/0"}}} =
                 questions(context, [
                   question(%{
                     "options" => [option |> Map.put("recommended", true) |> Map.delete(member)]
                   })
                 ])
      end
    end

    # The schema as `Apiary.Artifacts.Format` builds and runs it with JSV applies
    # `contains`, `minContains` and `maxContains`: the check below is the schema's.
    test "at most one option of a question has recommended true, in any state", context do
      option = &%{"title" => "Option #{&1}", "explanation" => "Why #{&1}."}
      yes = &Map.put(option.(&1), "recommended", true)
      no = &Map.put(option.(&1), "recommended", false)
      by = %{"name" => "Ann Example"}
      answer = %{"option" => "Option 1", "by" => by, "at" => @at}

      states = [
        %{"state" => "open"},
        %{"state" => "answered", "answer" => answer},
        %{"state" => "withdrawn"}
      ]

      for state <- states do
        for options <- [
              [option.(1), option.(2)],
              [no.(1), no.(2)],
              [yes.(1)],
              [yes.(1), option.(2), no.(3)],
              [option.(1), no.(2), yes.(3)]
            ] do
          assert {:ok, _} =
                   questions(context, [question(Map.put(state, "options", options))]),
                 inspect({state, options})
        end

        for options <- [
              [yes.(1), yes.(2)],
              [yes.(1), option.(2), yes.(3)],
              [yes.(1), yes.(2), yes.(3)]
            ] do
          count = Enum.count(options, &(&1["recommended"] == true))

          error =
            "list contains more than 1 items validating the 'contains' schema, " <>
              "found #{count} items"

          assert {:error, {:schema, %{path: "#/questions/0/options", error: ^error}}} =
                   questions(context, [question(Map.put(state, "options", options))]),
                 inspect({state, options})
        end
      end

      # The rule is per question: two questions may each recommend one.
      assert {:ok, _} =
               questions(context, [
                 question(%{"options" => [yes.(1)]}),
                 question(%{"id" => "q2", "options" => [yes.(1)]})
               ])
    end

    test "an answer chooses one of the question's option titles, or none and a note",
         context do
      options = [%{"title" => "The small one", "explanation" => "The checkout shows it."}]
      by = %{"name" => "Ann Example"}

      answered = fn answer ->
        question(%{"options" => options, "state" => "answered", "answer" => answer})
      end

      assert {:ok, _} =
               questions(context, [
                 answered.(%{"option" => "The small one", "by" => by, "at" => @at})
               ])

      assert {:ok, _} =
               questions(context, [
                 answered.(%{
                   "option" => nil,
                   "note" => "The large one.",
                   "by" => by,
                   "at" => @at
                 })
               ])

      assert {:error, {:schema, %{path: "#/questions/0/answer/option", error: error}}} =
               questions(context, [
                 answered.(%{"option" => "Another", "by" => by, "at" => @at})
               ])

      assert error =~ "not the title"

      assert {:error, {:schema, %{path: "#/questions/0" <> _}}} =
               questions(context, [answered.(%{"option" => nil, "by" => by, "at" => @at})])

      # An earlier answer in the history too.
      reopened = %{"run" => 13, "at" => @at}

      history = [
        %{"option" => "Another", "by" => by, "at" => @at, "reopened" => reopened}
      ]

      assert {:error, {:schema, %{path: "#/questions/0/history/0/option"}}} =
               questions(context, [question(%{"options" => options, "history" => history})])
    end

    test "an answer is present exactly when the question is answered", context do
      answer = %{"option" => nil, "note" => "Yes.", "by" => %{"name" => "Ann"}, "at" => @at}

      assert {:error, {:schema, _}} = questions(context, [question(%{"answer" => answer})])

      assert {:error, {:schema, _}} =
               questions(context, [question(%{"state" => "answered"})])
    end

    test "a document of 1 MiB is the type's limit, and 1 MiB of questions passes the format",
         context do
      for name <- ["questions", "review-comments"],
          do: assert(%Type{size_limit: 1_048_576, max_files: 1} = standard(name))

      list =
        for n <- 1..50,
            do: question(%{"id" => "q#{n}", "context" => String.duplicate("a", 20_000)})

      bytes = Jason.encode!(%{"questions" => list})
      assert byte_size(bytes) > 1_000_000 and byte_size(bytes) < 1_048_576
      assert {:ok, _} = check(context, "questions", "questions.json", bytes)
    end
  end

  describe "the review comments format" do
    defp review_comment(attrs \\ %{}) do
      Map.merge(
        %{
          "id" => "c1",
          "on" => %{"artifact" => "proposal", "version" => 1},
          "text" => "Offer a replacement first.",
          "by" => %{"name" => "Ann Example"},
          "at" => "2026-11-04T10:00:00Z",
          "state" => "open"
        },
        attrs
      )
    end

    defp reply(attrs),
      do: Map.merge(%{"text" => "Changed it.", "at" => "2026-11-04T11:00:00Z"}, attrs)

    defp review_comments(context, list),
      do:
        check(
          context,
          "review-comments",
          "review-comments.json",
          Jason.encode!(%{"review_comments" => list})
        )

    test "each id once", context do
      assert {:ok, _} = review_comments(context, [review_comment()])

      assert {:error, {:schema, %{path: "#/review_comments/1/id", error: error}}} =
               review_comments(context, [review_comment(), review_comment()])

      assert error =~ "earlier review comment"
    end

    test "on one output, or on the round of a run, and no mix of the two", context do
      assert {:ok, _} = review_comments(context, [review_comment(%{"on" => %{"run" => 3}})])

      assert {:ok, _} =
               review_comments(context, [
                 review_comment(%{
                   "on" => %{"artifact" => "mockup", "version" => 2, "screen" => "checkout"}
                 })
               ])

      for on <- [%{"run" => 0}, %{"run" => 1, "artifact" => "proposal"}, %{}] do
        assert {:error, {:schema, %{path: "#/review_comments/0/on"}}} =
                 review_comments(context, [review_comment(%{"on" => on})])
      end
    end

    test "a key twice in one object is refused at the object's place", context do
      bytes =
        ~s({"review_comments": [{"id": "c1", "on": {"artifact": "proposal", "version": 1}, ) <>
          ~s("text": "Offer a replacement first.", "by": {"name": "Ann", "name": "Bob"}, ) <>
          ~s("at": "2026-11-04T10:00:00Z", "state": "open"}]})

      assert {:error,
              {:schema,
               %{
                 path: "#/review_comments/0/by",
                 error: "the object has the key name twice"
               }}} =
               check(context, "review-comments", "review-comments.json", bytes)
    end
  end

  describe "a key twice in one object" do
    test "is refused in a questions document, at the object, before the schema",
         context do
      # Jason alone keeps the last state; another parser may keep the first.
      bytes =
        ~s({"questions": [{"id": "q1", "question": "Which basket?", "options": [], ) <>
          ~s("state": "answered", "state": "open", ) <>
          ~s("asked": {"run": 1, "at": "2026-11-04T10:00:00Z"}}]})

      assert {:error,
              {:schema, %{path: "#/questions/0", error: "the object has the key state twice"}}} =
               check(context, "questions", "questions.json", bytes)

      # At the root, and the first repeated key in the document's order.
      assert {:error, {:schema, %{path: "#", error: "the object has the key questions twice"}}} =
               check(
                 context,
                 "questions",
                 "questions.json",
                 ~s({"questions": [], "questions": []})
               )

      assert {:error,
              {:schema, %{path: "#/questions/0", error: "the object has the key id twice"}}} =
               check(
                 context,
                 "questions",
                 "questions.json",
                 ~s({"questions": [{"id": "a", "id": "b"}], "questions": []})
               )
    end

    test "is refused in a verdict, a standard type the run API writes too", context do
      assert {:error, {:schema, %{path: "#", error: "the object has the key verdict twice"}}} =
               check(
                 context,
                 "verdict",
                 "verdict.json",
                 ~s({"verdict": "escalate", "verdict": "passed"})
               )

      assert {:ok, "application/json"} =
               check(context, "verdict", "verdict.json", ~s({"verdict": "passed"}))
    end

    test "has a place whose pointer escapes / and ~ in a key", context do
      assert {:error, {:schema, %{path: "#/a~1b~0c"}}} =
               check(context, "verdict", "verdict.json", ~s({"a/b~c": {"x": 1, "x": 2}}))
    end

    test "a run's reply has an outcome, a member's none; asked with a question", context do
      run = %{"run" => 12}
      member = %{"name" => "Ann Example"}

      for {state, replies} <- [
            {"closed", [reply(%{"by" => run, "outcome" => "changed"})]},
            {"open", [reply(%{"by" => member})]},
            {"closed", [reply(%{"by" => run, "outcome" => "asked", "question" => "q3"})]}
          ] do
        assert {:ok, _} =
                 review_comments(context, [
                   review_comment(%{"state" => state, "replies" => replies})
                 ])
      end

      for replies <- [
            [reply(%{"by" => run})],
            [reply(%{"by" => member, "outcome" => "declined"})],
            [reply(%{"by" => run, "outcome" => "asked"})],
            [reply(%{"by" => run, "outcome" => "changed", "question" => "q3"})],
            [reply(%{"by" => run, "outcome" => "agreed"})]
          ] do
        assert {:error, {:schema, %{path: "#/review_comments/0/replies/0" <> _}}} =
                 review_comments(context, [review_comment(%{"replies" => replies})]),
               inspect(replies)
      end
    end
  end

  describe "the rules of the formats at qory b03f2e8c" do
    test "a closed review comment has a reply by a run", context do
      comment = fn attrs -> review_comment(Map.put(attrs, "state", "closed")) end
      member = reply(%{"by" => %{"name" => "Ann Example"}})
      run = reply(%{"by" => %{"run" => 12}, "outcome" => "changed"})

      assert {:ok, _} = review_comments(context, [comment.(%{"replies" => [run, member]})])

      for attrs <- [%{}, %{"replies" => []}, %{"replies" => [member]}] do
        assert {:error, {:schema, %{path: "#/review_comments/0" <> _}}} =
                 review_comments(context, [comment.(attrs)]),
               inspect(attrs)
      end
    end

    test "a time has a month from 01 to 12 and a day from 01 to 31", context do
      assert {:ok, _} =
               questions(context, [
                 question(%{"asked" => %{"run" => 12, "at" => "2026-12-31T23:59:59Z"}})
               ])

      for at <- [
            "2026-13-01T10:00:00Z",
            "2026-00-10T10:00:00Z",
            "2026-11-32T10:00:00Z",
            "2026-11-00T10:00:00Z"
          ] do
        assert {:error, {:schema, %{path: "#/questions/0/asked/at"}}} =
                 questions(context, [question(%{"asked" => %{"run" => 12, "at" => at}})]),
               at

        assert {:error, {:schema, %{path: "#/review_comments/0/at"}}} =
                 review_comments(context, [review_comment(%{"at" => at})]),
               at
      end
    end

    test "an option's title is one line", context do
      option = &%{"title" => &1, "explanation" => "Why."}

      assert {:ok, _} = questions(context, [question(%{"options" => [option.("The small one")]})])

      for title <- ["The small\none", "The small\u2028one"] do
        assert {:error, {:schema, %{path: "#/questions/0/options/0/title"}}} =
                 questions(context, [question(%{"options" => [option.(title)]})]),
               inspect(title)
      end
    end
  end

  describe "a proposal" do
    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0>>

    defp svg(body),
      do:
        ~s(<svg xmlns="#{@svg_namespace}" xmlns:xlink="http://www.w3.org/1999/xlink">#{body}</svg>)

    defp sources(list), do: Jason.encode!(%{"sources" => list})

    test "is one Markdown file, images, and sources.json, each by its filename", context do
      assert {:ok, "text/markdown; charset=utf-8"} =
               check(context, "proposal", "proposal.md", "# Gift cards\n")

      assert {:ok, "text/markdown; charset=utf-8"} =
               check(context, "proposal", "PLAN.MD", "# Gift cards\n")

      assert {:ok, "image/png"} = check(context, "proposal", "checkout.png", @png)
      assert {:ok, "image/jpeg"} = check(context, "proposal", "a.jpg", <<0xFF, 0xD8, 0xFF, 0>>)
      assert {:ok, "image/gif"} = check(context, "proposal", "a.gif", "GIF89a" <> <<1>>)

      assert {:ok, "image/webp"} =
               check(context, "proposal", "a.webp", "RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ")

      wireframe =
        svg("""
        <defs><linearGradient id="g"/><style>.box { fill: url('#g'); }</style></defs>
        <rect id="r" class="box" width="10" height="10" fill="url(#g)" style="stroke: url( #g )"/>
        <use href="#r"/><use xlink:href="#r"/><a href="#r"><text>Checkout</text></a>
        <text>Add image (PNG)</text>
        """)

      assert {:ok, "image/svg+xml"} = check(context, "proposal", "checkout.svg", wireframe)

      source = %{"kind" => "page", "ref" => "https://example.com/checkout", "why" => "The form."}

      assert {:ok, "application/json"} =
               check(context, "proposal", "sources.json", sources([source]))

      assert {:ok, "application/json"} = check(context, "proposal", "sources.json", sources([]))
    end

    test "refuses a file that is neither Markdown, the sources nor an image", context do
      assert {:error, :extension} = check(context, "proposal", "notes.txt", "Gift cards.")
      assert {:error, :extension} = check(context, "proposal", "other.json", sources([]))
      assert {:error, :extension} = check(context, "proposal", "Sources.json", sources([]))
      assert {:error, :extension} = check(context, "proposal", "x.html", "GIF89a<script>")
      assert {:error, :extension} = check(context, "proposal", "checkout", @png)
      assert {:error, :format} = check(context, "proposal", "proposal.md", <<0xFF, 0xFE>>)
      assert {:error, :format} = check(context, "proposal", "proposal.md", "a\0b")
    end

    test "takes a Markdown file of 262144 bytes and refuses one a byte larger", context do
      assert {:ok, _type} =
               check(context, "proposal", "proposal.md", String.duplicate("a", 262_144))

      assert {:error, :document_size} =
               check(context, "proposal", "proposal.md", String.duplicate("a", 262_145))

      # Another document type keeps its rule: its size limit bounds the version.
      assert {:ok, _type} =
               check(context, "explainer", "notes.md", String.duplicate("a", 262_145))
    end

    test "checks sources.json against the proposal sources format, up to 1 MiB", context do
      for document <- [
            ~s({"sources": [{"kind": "page", "ref": "x"}]}),
            ~s({"sources": [{"kind": "Page", "ref": "x", "why": "y"}]}),
            ~s({"sources": [{"kind": "page", "ref": "x", "why": "y", "url": "z"}]}),
            sources([%{"kind" => "page", "ref" => "a\nb", "why" => "y"}]),
            ~s({"items": []}),
            ~s([])
          ] do
        assert {:error, {:schema, %{path: "#" <> _, error: _}}} =
                 check(context, "proposal", "sources.json", document),
               document
      end

      assert {:error, :format} = check(context, "proposal", "sources.json", "{")

      source = %{"kind" => "file", "ref" => String.duplicate("a", 2000), "why" => "w"}
      big = sources(List.duplicate(source, 600))
      assert byte_size(big) > 1_048_576
      assert {:error, :document_size} = check(context, "proposal", "sources.json", big)
    end

    test "refuses a key that comes twice in sources.json at its object's place", context do
      assert {:error, {:schema, %{path: "#", error: "the object has the key sources twice"}}} =
               check(context, "proposal", "sources.json", ~s({"sources": [], "sources": []}))

      twice = ~s({"sources": [{"kind": "page", "ref": "x", "why": "y", "why": "z"}]})

      assert {:error,
              {:schema, %{path: "#/sources/0", error: "the object has the key why twice"}}} =
               check(context, "proposal", "sources.json", twice)
    end

    test "takes a source's system only as host labels that neither start nor end with a hyphen",
         context do
      source = fn system ->
        sources([%{"kind" => "record", "ref" => "42", "why" => "w", "system" => system}])
      end

      for system <- ["crm.example.com", "a", "crm-eu.example.com", "x1.y-2.z"] do
        assert {:ok, "application/json"} =
                 check(context, "proposal", "sources.json", source.(system)),
               system
      end

      for system <- [
            "-crm.example.com",
            "crm-.example.com",
            "crm.example.com-",
            "crm.-example.com",
            "-",
            "crm..example.com",
            String.duplicate("a", 64) <> ".com"
          ] do
        assert {:error, {:schema, %{path: "#/sources/0/system"}}} =
                 check(context, "proposal", "sources.json", source.(system)),
               system
      end
    end

    test "refuses an SVG with script, an outside reference or a handler, each", context do
      for body <- [
            "<script>alert(1)</script>",
            "<SCRIPT>alert(1)</SCRIPT>",
            ~s|<x:script xmlns:x="http://www.w3.org/1999/xhtml">alert(1)</x:script>|,
            "<foreignObject><p>a</p></foreignObject>",
            ~s(<h:img xmlns:h="http://www.w3.org/1999/xhtml" src="https://example.com/a.png"/>),
            ~s(<image href="#r"/>),
            "<iframe/>",
            ~s(<rect><animate attributeName="x" to="1"/></rect>),
            ~s(<rect><set attributeName="x" to="1"/></rect>),
            ~s|<rect onload="alert(1)"/>|,
            ~s|<rect ONCLICK="alert(1)"/>|,
            ~s(<a href="https://example.com/"><text>a</text></a>),
            ~s|<a href="javascript:alert(1)"><text>a</text></a>|,
            ~s|<a href="&#106;avascript:alert(1)"><text>a</text></a>|,
            ~s|<a xlink:href="javascript:alert(1)"><text>a</text></a>|,
            ~s(<use href="data:image/svg+xml,&lt;svg/&gt;"/>),
            ~s(<use href="other.svg#r"/>),
            ~s(<use href=" #r"/>),
            ~s|<rect fill="url(https://example.com/a.svg#g)"/>|,
            ~s|<rect fill="url('data:image/png,a')"/>|,
            ~s|<rect style="fill: url(https://example.com/)"/>|,
            ~s|<rect style="fill: \\75 rl(#g)"/>|,
            "<style>rect { fill: url(https://example.com/) }</style>",
            "<style><![CDATA[rect { fill: url(//example.com/) }]]></style>",
            "<style>@import 'https://example.com/a.css';</style>",
            "<style>rect { fill: \\75 rl(x) }</style>",
            "<text>@import</text>",
            ~s|<style>@imp<!---->ort "https://example.com/a.css";</style>|,
            "<style>rect { fill: ur<!---->l(https://example.com/a) }</style>",
            ~s|<style>@imp<![CDATA[ort "https://example.com/a.css";]]></style>|,
            ~s|<style>@imp<g/>ort "https://example.com/a.css";</style>|,
            "<style><g/></style>",
            ~s|<rect cursor="\\75 rl(https://example.com/c.png), auto"/>|,
            ~s|<rect mask="\\75 rl(https://example.com/m.svg#m)"/>|,
            ~s|<use href="#r\\"/>|,
            ~s|<style>svg { background-image: image-set("https://example.com/a.png" 1x) }</style>|,
            ~s|<rect style="mask-image: image-set('https://example.com/m.png' 1x)"/>|,
            ~s|<rect style="mask-image: -WEBKIT-IMAGE-SET('https://example.com/m.png' 1x)"/>|,
            ~s|<rect style="fill: IMAGE ('https://example.com/a.png')"/>|,
            ~s|<style>rect { fill: image("https://example.com/a.png") }</style>|,
            ~s|<a xml:base="javascript:alert(1)//" href="#x"><text>x</text></a>|,
            ~s|<use xml:base="https://example.com/a.svg" href="#x"/>|,
            ~s|<g xml:base="https://example.com/"><use href="#x"/></g>|
          ] do
        assert {:error, {:svg_content, _part}} = check(context, "proposal", "a.svg", svg(body)),
               body
      end

      stylesheet = ~s(<?xml-stylesheet href="https://example.com/a.css"?>\n) <> svg("<rect/>")

      assert {:error, {:svg_content, "the processing instruction xml-stylesheet"}} =
               check(context, "proposal", "a.svg", stylesheet)
    end

    test "refuses an image whose extension is not the type its bytes show, as :image_type",
         context do
      svg = svg("<rect/>")
      assert {:ok, "image/jpeg"} = check(context, "proposal", "A.JPEG", <<0xFF, 0xD8, 0xFF, 0>>)
      assert {:ok, "image/svg+xml"} = check(context, "proposal", "A.SVG", svg)

      for {filename, bytes} <- [
            {"a.png", "GIF89a" <> <<1>>},
            {"a.gif", @png},
            {"a.jpg", @png},
            {"a.webp", @png},
            {"a.svg", @png},
            {"a.svg", "GIF89a" <> svg},
            {"a.png", svg},
            {"a.png", svg("<script>alert(1)</script>")}
          ] do
        assert {:error, :image_type} = check(context, "proposal", filename, bytes), filename
      end
    end

    test "refuses every processing instruction in an SVG, but not the XML declaration",
         context do
      declared = ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <> svg("<rect/>")
      assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", declared)

      for bytes <- [
            "<?foo bar?>" <> svg("<rect/>"),
            "<?foo x><script>alert(1)</script>?>" <> svg("<rect/>"),
            svg("<?foo x><img src=x onerror=alert(1)>?><rect/>")
          ] do
        assert {:error, {:svg_content, "the processing instruction foo"}} =
                 check(context, "proposal", "a.svg", bytes),
               bytes
      end
    end

    test "names the first part of an SVG it refuses, as the file writes it", context do
      long = String.duplicate("a", 70)

      for {body, part} <- [
            {"<SCRIPT>alert(1)</SCRIPT>", "the SCRIPT element"},
            {~s(<rect><animate attributeName="x" to="1"/></rect>), "the animate element"},
            {~s|<x:set xmlns:x="urn:x"/>|, "the x:set element"},
            {~s(<h:div xmlns:h="http://www.w3.org/1999/xhtml"/>), "the HTML element h:div"},
            {~s|<rect onload="alert(1)"/>|, "the onload attribute"},
            {~s|<a xml:base="https://example.com/" href="#x"><text>a</text></a>|,
             "the xml:base attribute"},
            {~s(<use href="other.svg#r"/>), "the href attribute"},
            {~s(<a xlink:href="https://example.com/"><text>a</text></a>),
             "the xlink:href attribute"},
            {~s|<rect fill="\\75 rl(#g)"/>|, "a backslash in the fill attribute"},
            {~s|<rect fill="url(https://example.com/a.svg#g)"/>|,
             "the url() in the fill attribute"},
            {"<style>rect { fill: url(https://example.com/) }</style>",
             "the url() in the style element"},
            {"<desc>@import</desc>", "the @import in the text of the desc element"},
            {~s|<rect style="mask: -webkit-image-set('https://example.com/m.png' 1x)"/>|,
             "the -webkit-image-set() in the style attribute"},
            {~s|<style>rect { fill: IMAGE ("https://example.com/a.png") }</style>|,
             "the image() in the style element"},
            {"<style>rect {}<g/></style>", "the g element inside the style element"},
            {"<?foo bar?><rect/>", "the processing instruction foo"},
            {~s(<rect on#{long}="x"/>), "the on#{String.duplicate("a", 62)}… attribute"},
            {"<iframe/>", "the iframe element"},
            {~s(<s:rect xmlns:s="#{@svg_namespace}"/>), "the s:rect element"},
            {~s(<a href="#x" ping="https://example.com/p"><text>a</text></a>),
             "the ping attribute"},
            {~s(<rect href="#x"/>), "the href attribute"},
            {"<desc><g/></desc>", "the g element inside the desc element"},
            {"<desc><![CDATA[a]]></desc>", "the CDATA section in the desc element"},
            {"<!--><rect/>-->", "the comment that starts with >"},
            {"<!---><rect/>-->", "the comment that starts with ->"},
            {~s|<rect style="mask-image: src('https://example.com/m.png')"/>|,
             "the src() in the style attribute"}
          ] do
        assert {:error, {:svg_content, ^part}} =
                 check(context, "proposal", "a.svg", svg(body)),
               body
      end
    end

    test "takes a wireframe of the elements and attributes the allowlist names", context do
      wireframe =
        ~s(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n) <>
          "<!-- Checkout, step 2 -->\n" <>
          ~s(<svg xmlns="#{@svg_namespace}" xmlns:xlink="http://www.w3.org/1999/xlink" ) <>
          ~s(version="1.1" viewBox="0 0 800 600" width="800" height="600" ) <>
          ~s(preserveAspectRatio="xMidYMid meet" role="img" aria-label="Checkout" xml:lang="en">) <>
          """
          <title>Checkout &amp; payment</title>
          <desc>The second step: address, then card.</desc>
          <defs>
            <style><![CDATA[
              .box { fill: #fff; stroke: #d0d5dd; stroke-width: 1; }
              .label { font: 14px Inter, sans-serif; fill: #101828; }
              .accent { fill: url(#brand); }
            ]]></style>
            <linearGradient id="brand" x1="0" y1="0" x2="1" y2="0" gradientUnits="objectBoundingBox">
              <stop offset="0" stop-color="#7f56d9"/>
              <stop offset="1" stop-color="#9e77ed" stop-opacity="0.8"/>
            </linearGradient>
            <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#fff"/></radialGradient>
            <pattern id="grid" width="8" height="8" patternUnits="userSpaceOnUse">
              <path d="M8 0 L0 0 0 8" fill="none" stroke="#eaecf0"/>
            </pattern>
            <clipPath id="card"><rect width="360" height="200" rx="12"/></clipPath>
            <mask id="fade"><rect width="360" height="200" fill="url(#glow)"/></mask>
            <marker id="arrow" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto">
              <polygon points="0 0, 8 4, 0 8" fill="#667085"/>
            </marker>
            <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
              <feDropShadow dx="0" dy="1" stdDeviation="2" flood-color="#101828" flood-opacity="0.1"/>
              <feGaussianBlur in="SourceAlpha" stdDeviation="1" result="blur"/>
              <feOffset in="blur" dy="1" result="offset"/>
              <feFlood flood-color="#000" flood-opacity="0.05" result="tint"/>
              <feComposite in="tint" in2="offset" operator="in" result="soft"/>
              <feColorMatrix type="saturate" values="0.5"/>
              <feBlend in="SourceGraphic" in2="soft" mode="normal"/>
              <feMerge><feMergeNode in="soft"/><feMergeNode in="SourceGraphic"/></feMerge>
            </filter>
            <symbol id="field" viewBox="0 0 320 40"><rect class="box" width="320" height="40" rx="6"/></symbol>
            <path id="curve" d="M10 80 Q 95 10 180 80"/>
          </defs>
          <rect width="800" height="600" fill="url(#grid)"/>
          <g id="form" transform="translate(40 40)" filter="url(#shadow)" clip-path="url(#card)">
            <rect class="box" width="360" height="200" rx="12" mask="url(#fade)"/>
            <use href="#field" x="20" y="40" width="320" height="40"/>
            <use xlink:href="#field" x="20" y="100" width="320" height="40"/>
            <text class="label" x="20" y="30" font-weight="600">Address <tspan dx="4" fill="#667085">(required)</tspan></text>
            <text><textPath href="#curve" startOffset="10%">Add image (PNG)</textPath></text>
            <circle cx="340" cy="20" r="6" class="accent"/>
            <ellipse cx="20" cy="180" rx="6" ry="4" fill="#12b76a"/>
            <line x1="20" y1="160" x2="340" y2="160" stroke="#eaecf0" stroke-dasharray="4 2" marker-end="url(#arrow)"/>
            <polyline points="20,170 40,175 60,170" fill="none" stroke="#98a2b3"/>
            <a href="#form"><text x="20" y="190" text-decoration="underline">Back to cart</text></a>
          </g>
          <svg x="420" y="40" width="300" height="200"><rect width="300" height="200" fill="#f9fafb"/></svg>
          </svg>
          """

      assert {:ok, "image/svg+xml"} = check(context, "proposal", "checkout.svg", wireframe)
    end

    test "takes text that only looks like markup or CSS outside CSS", context do
      for bytes <- [
            "<!-- Created with a drawing tool -->" <> svg("<rect/>"),
            svg(~s|<rect fill="red"/><!-- fill="url(https://example.com/a)" -->|),
            svg(~s|<!-- <?xml-stylesheet href="a"?> -->|),
            svg("<desc>\\75 rl(x) and image-set(\"a\")</desc>"),
            svg("<text>C:\\path</text>"),
            svg(~s|<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>|),
            svg("<style>rect { fill: ur/**/l(https://example.com/a) }</style>")
          ] do
        assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", bytes), bytes
      end
    end

    # The bypasses the two security reviews of the strict check found, each with the part
    # the run's message names. The HTML cases run script or load from outside when the file
    # is opened as a page after a rename to `.html`.
    test "refuses each bypass of the security reviews, with the part it names", context do
      ev = ~s(xmlns:ev="http://www.w3.org/2001/xml-events")

      for {bytes, part} <- [
            # Text joined in a style element (S1).
            {svg(
               ~s|<style>svg{mask-image:image-<!---->set("https://example.com/a.png" 1x)}</style>|
             ), "the image-set() in the style element"},
            {svg(
               ~s|<style><![CDATA[rect{fill:ur]]><![CDATA[l(https://example.com/a)}]]></style>|
             ), "the url() in the style element"},
            {svg(~s|<style>@&#105;mp<!-- x -->ort "https://example.com/a.css";</style>|),
             "the @import in the style element"},
            {svg(
               ~s|<x:style xmlns:x="urn:x">@imp<!---->ort "https://example.com/a.css";</x:style>|
             ), "the x:style element"},
            {svg(~s|<svg><style>@imp<!---->ort "https://example.com/a.css";</style></svg>|),
             "the @import in the style element"},
            {svg(~s|<style>@imp<?x y?>ort "https://example.com/a.css";</style>|),
             "the processing instruction x"},
            # A CSS escape in an attribute (S2).
            {svg(~s|<rect fill="&#92;75 rl(https://example.com/a)"/>|),
             "a backslash in the fill attribute"},
            {svg(~s|<rect cursor="\\75 rl(https://example.com/c.png), auto"/>|),
             "the cursor attribute"},
            # An outside address as a plain string in CSS (S3).
            {svg(~s|<rect style="mask-image:image&#45;set('https://example.com/m.png' 1x)"/>|),
             "the image-set() in the style attribute"},
            {svg(~s|<rect style="mask-image:src('https://example.com/m.png')"/>|),
             "the src() in the style attribute"},
            # A base address (S4).
            {svg(~s|<a XML:BASE="javascript:alert(1)//" href="#x"><text>x</text></a>|),
             "the XML:BASE attribute"},
            {svg(
               ~s|<a xmlns:q="http://www.w3.org/XML/1998/namespace" q:base="javascript:alert(1)//" href="#x"><text>x</text></a>|
             ), "the q:base attribute"},
            {svg(~s|<a base="javascript:alert(1)//" href="#x"><text>x</text></a>|),
             "the base attribute"},
            # A comment an HTML parser ends at once (S6).
            {~s|<!--><script>alert(1)</script>-->| <> svg("<rect/>"),
             "the comment that starts with >"},
            {~s|<!---><script>alert(1)</script>-->| <> svg("<rect/>"),
             "the comment that starts with ->"},
            {svg(~s|<!--><img src="x" onerror="alert(1)">-->|), "the comment that starts with >"},
            # An HTML tag name, or a CDATA section, an HTML parser reads as markup (S7).
            {svg(~s|<img src="https://example.com/a.png"/>|), "the img element"},
            {svg(~s|<embed src="https://example.com/a.svg"/>|), "the embed element"},
            {svg(~s|<meta http-equiv="refresh" content="0;URL=https://example.com/"/>|),
             "the meta element"},
            {svg(~s|<img srcset="https://example.com/a.png 1x"/>|), "the img element"},
            {svg(~s|<img xmlns="urn:x" src="https://example.com/a.png"/>|), "the img element"},
            {svg(~s|<b><![CDATA[><img src=x onerror=alert(1)>]]></b>|), "the b element"},
            {svg(~s|<desc><g><![CDATA[><img src=x onerror=alert(1)>]]></g></desc>|),
             "the g element inside the desc element"},
            {svg(~s|<desc><object data="https://example.com/a.html"/></desc>|),
             "the object element inside the desc element"},
            {svg(~s|<desc><video src="https://example.com/a.mp4" autoplay=""/></desc>|),
             "the video element inside the desc element"},
            {svg(~s|<title><input type="image" src="https://example.com/a.png"/></title>|),
             "the input element inside the title element"},
            {svg(
               ~s|<desc><noembed><![CDATA[</noembed><img src=x onerror=alert(1)>]]></noembed></desc>|
             ), "the noembed element inside the desc element"},
            {svg(~s|<text><![CDATA[><img src=x onerror=alert(1)>]]></text>|),
             "the CDATA section in the text element"},
            {svg(~s|<desc><![CDATA[<?xml-stylesheet x?>]]></desc>|),
             "the CDATA section in the desc element"},
            {svg(
               ~s|<m:math xmlns:m="http://www.w3.org/1998/Math/MathML"><m:mglyph src="https://example.com/a.png"/></m:math>|
             ), "the m:math element"},
            {svg(~s|<s:style xmlns:s="#{@svg_namespace}"><![CDATA[><img src=x>]]></s:style>|),
             "the s:style element"},
            {~s|<s:svg xmlns:s="#{@svg_namespace}"><s:rect/></s:svg>|, "the s:svg element"},
            # Animation and other elements a wireframe does not need (M2 and the listed cases).
            {svg(
               ~s|<a href="#x"><animateTransform attributeName="href" values="javascript:alert(1)"/></a>|
             ), "the animateTransform element"},
            {svg(
               ~s|<a href="#x"><animateColor attributeName="href" values="javascript:alert(1)"/></a>|
             ), "the animateColor element"},
            {svg(~s|<circle r="1"><animateMotion path="M0 0 L9 9" dur="1s"/></circle>|),
             "the animateMotion element"},
            {svg(~s|<discard begin="1s" href="#x"/>|), "the discard element"},
            {svg(
               ~s|<handler #{ev} ev:event="load" type="application/ecmascript">alert(1)</handler>|
             ), "the handler element"},
            {svg(~s|<listener #{ev} ev:event="click" ev:handler="#h"/>|), "the listener element"},
            {svg(~s|<a href="#x" target="_top"><text>x</text></a>|), "the target attribute"},
            {svg(~s|<filter id="f"><feImage href="#x"/></filter>|), "the feImage element"},
            {svg(~s|<text><tref xlink:href="#t"/></text>|), "the tref element"},
            {svg(~s|<cursor id="c" xlink:href="https://example.com/c.png"/>|),
             "the cursor element"},
            {svg(~s|<font-face><font-face-src/></font-face>|), "the font-face element"},
            {svg(~s|<color-profile name="x" local="x"/>|), "the color-profile element"},
            {svg(~s|<use q:href="#x" xmlns:q="urn:q"/>|), "the q:href attribute"},
            {svg(~s|<use src="https://example.com/a.svg#x"/>|), "the src attribute"},
            {svg(~s|<xi:include xmlns:xi="http://www.w3.org/2001/XInclude" href="a.svg"/>|),
             "the xi:include element"},
            {svg(~s|<a xlink:href="#x" xlink:show="new"><text>x</text></a>|),
             "the xlink:show attribute"},
            {svg(~s|<a href="jav&#x09;ascript:alert(1)"><text>x</text></a>|),
             "the href attribute"},
            {svg(~s|<use href="#a b"/>|), "the href attribute"},
            {svg(~s|<rect one="1"/>|), "the one attribute"},
            {svg(~s|<rect data-u="https://example.com/a.png"/>|), "the data-u attribute"},
            {svg(~s|<style>@namespace x url(https://example.com/);</style>|),
             "the url() in the style element"},
            {svg(~s|<rect style="-moz-binding:url(https://example.com/x.xml#x)"/>|),
             "the url() in the style attribute"}
          ] do
        assert {:error, {:svg_content, ^part}} = check(context, "proposal", "a.svg", bytes),
               bytes
      end

      for bytes <- [
            svg("<rect/>") <> "<?foo x><script>alert(1)</script>?>",
            svg("<rect/>") <> ~s|<!--><script>alert(1)</script>-->|
          ] do
        assert {:error, {:svg_content, "everything after the end of the svg element"}} =
                 check(context, "proposal", "a.svg", bytes),
               bytes
      end

      # Not well-formed, so not an SVG.
      for bytes <- [
            ~s|<?xml version="1.0>"?>| <> svg("<rect/>"),
            svg(~s|<rect onl&#111;ad="x"/>|)
          ] do
        assert {:error, :svg_format} = check(context, "proposal", "a.svg", bytes), bytes
      end
    end

    test "names xml-stylesheet only for an instruction, never for text that mentions one",
         context do
      assert {:error, {:svg_content, "the processing instruction xml-stylesheet"}} =
               check(context, "proposal", "a.svg", ~s(<?xml-stylesheet href="a.css"?>) <> svg(""))

      assert {:error, {:svg_content, "the processing instruction xml-stylesheet"}} =
               check(context, "proposal", "a.svg", svg(~s(<?xml-stylesheet href="a.css"?>)))

      assert {:ok, "image/svg+xml"} =
               check(context, "proposal", "a.svg", svg("<!-- <?xml-stylesheet href=\"a\"?> -->"))

      assert {:error, {:svg_content, "the CDATA section in the desc element"}} =
               check(
                 context,
                 "proposal",
                 "a.svg",
                 svg("<desc><![CDATA[<?xml-stylesheet x?>]]></desc>")
               )

      # A file that does not parse is read for its first instruction outside a comment, a
      # CDATA section and a tag, whose target is an XML name.
      for bytes <- [
            ~s(<!-- <?xml-stylesheet href="a.css"?> -->) <> svg("<rect>"),
            svg("<style><![CDATA[ <?xml-stylesheet ]]></style><rect>"),
            svg(~s(<rect id="<?xml-stylesheet"/>)),
            svg(~s(<rect <?xml-stylesheet ?>/>)),
            "<?\u202Efoo?>" <> svg("<rect>")
          ] do
        assert {:error, :svg_format} = check(context, "proposal", "a.svg", bytes), bytes
      end

      declared = ~s(<?xml version="1.0"?><?xml-stylesheet href="a.css"?>) <> svg("<rect/>")

      assert {:error, {:svg_content, "the processing instruction a"}} =
               check(context, "proposal", "a.svg", "<?a>b<c x?>" <> svg("<rect/>"))

      # The target is an XML name, letters outside ASCII included.
      for {target, part} <- [
            {"café", "the processing instruction café"},
            {"a:b", "the processing instruction a:b"},
            {"xml-stylesheet", "the processing instruction xml-stylesheet"},
            {"x\u0301·y", "the processing instruction x\u0301·y"}
          ] do
        assert {:error, {:svg_content, ^part}} =
                 check(context, "proposal", "a.svg", "<?#{target} x?>" <> svg("<rect>")),
               target
      end

      for target <- ["\u202Efoo", "1a", "-a"] do
        assert {:error, :svg_format} =
                 check(context, "proposal", "a.svg", "<?#{target} x?>" <> svg("<rect>")),
               target
      end

      assert {:error, {:svg_content, "the processing instruction xml-stylesheet"}} =
               check(context, "proposal", "a.svg", declared)
    end

    test "the strict check is a proposal's: a mockup takes the same SVG", context do
      unsafe = svg(~s|<rect onload="alert(1)"/><script>alert(1)</script>|)
      assert {:ok, "image/svg+xml"} = check(context, "mockup", "a.svg", unsafe)
    end

    test "refuses an SVG that is not well-formed UTF-8 with an svg root, as :svg_format",
         context do
      for bytes <- [
            ~s(<html xmlns="#{@svg_namespace}"/>),
            svg("<rect>"),
            svg("<text>") <> <<0xFF>> <> "</text></svg>",
            ~s(<svg xmlns="#{@svg_namespace}"/>]]>),
            "",
            "not markup"
          ] do
        assert {:error, :svg_format} = check(context, "proposal", "a.svg", bytes), bytes
      end

      # Another image type keeps :format.
      assert {:error, :format} = check(context, "mockup", "a.svg", "not markup")
    end

    test "refuses a root svg outside the SVG namespace as :svg_root", context do
      for bytes <- ["<svg/>", "<svg><rect/></svg>", ~s(<svg xmlns="urn:x"><rect/></svg>)] do
        assert {:error, :svg_root} = check(context, "proposal", "a.svg", bytes), bytes
      end

      assert {:error, :svg_format} =
               check(context, "proposal", "a.svg", ~s(<x:svg xmlns:x="urn:x"/>))

      assert {:error, {:svg_content, "the s:svg element"}} =
               check(context, "proposal", "a.svg", ~s(<s:svg xmlns:s="#{@svg_namespace}"/>))

      assert {:error, :format} = check(context, "mockup", "a.svg", "<svg/>")
    end

    test "refuses anything but white space after the end of the svg element", context do
      closed = svg("<rect/>")
      empty = ~s(<svg xmlns="#{@svg_namespace}"/>)

      assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", closed <> "\n \n")
      assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", empty <> "\n")

      for bytes <- [
            closed <> "\n<!-- x -->",
            empty <> "\n<!-- x -->\n",
            empty <> "<?pi x?>",
            closed <> "text",
            empty <> "<![CDATA[x]]>",
            empty <> empty,
            closed <> "\u00A0",
            closed <> "\f",
            empty <> "\n\u3000"
          ] do
        assert {:error, {:svg_content, "everything after the end of the svg element"}} =
                 check(context, "proposal", "a.svg", bytes),
               bytes
      end

      assert {:error, :format} = check(context, "mockup", "a.svg", closed <> "<!-- x -->")
      assert {:error, :format} = check(context, "mockup", "a.svg", closed <> "\u00A0")
    end

    test "refuses an element that declares a prefix or xmlns twice, as :svg_format",
         context do
      xhtml = "http://www.w3.org/1999/xhtml"

      for body <- [
            ~s(<rect id="r"/><a xmlns="#{xhtml}" xmlns="#{@svg_namespace}" href="#r"><text>x</text></a>),
            ~s(<style xmlns="#{xhtml}" xmlns="#{@svg_namespace}">rect { fill: red; }</style>),
            ~s(<g xmlns:x="urn:example:a" xmlns:x="urn:example:b"/>)
          ] do
        assert {:error, :svg_format} = check(context, "proposal", "a.svg", svg(body)), body
        assert {:error, :format} = check(context, "mockup", "a.svg", svg(body)), body
      end

      # The same prefix on two elements is two declarations, one on each.
      assert {:ok, "image/svg+xml"} =
               check(
                 context,
                 "proposal",
                 "a.svg",
                 svg(~s(<g xmlns:x="urn:example:a"><g xmlns:x="urn:example:b"/></g>))
               )
    end

    test "checks a namespace declaration's address as an attribute's value", context do
      for {body, part} <- [
            {~s|<rect xmlns:a="url(https://example.com/)"/>|,
             "the url() in the xmlns:a attribute"},
            {~s|<g xmlns:b="a\\b"/>|, "a backslash in the xmlns:b attribute"},
            {~s|<g xmlns:c="image-set('https://example.com/a.png' 1x)"/>|,
             "the image-set() in the xmlns:c attribute"}
          ] do
        assert {:error, {:svg_content, ^part}} = check(context, "proposal", "a.svg", svg(body)),
               body
      end

      assert {:ok, "image/svg+xml"} =
               check(context, "proposal", "a.svg", svg(~s(<g xmlns:x="urn:example:x"/>)))
    end

    test "refuses a document type declaration as the DOCTYPE, before the parse", context do
      for bytes <- [
            ~s(<!DOCTYPE svg>) <> svg("<rect/>"),
            ~s(<!doctype svg [<!ENTITY e "x">]>) <> svg("<text>&e;</text>"),
            ~s(<?xml version="1.0"?>\n<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" ) <>
              ~s("http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">) <> svg("<rect/>"),
            svg(~s(<!ENTITY e "x">))
          ] do
        assert {:error, {:svg_content, "the DOCTYPE"}} =
                 check(context, "proposal", "a.svg", bytes),
               bytes
      end

      # A mention in a comment, a CDATA section or text is not a declaration.
      for body <- [
            "<!-- <!DOCTYPE svg> -->",
            "<style><![CDATA[ /* <!ENTITY e> */ ]]></style>",
            "<desc>&lt;!DOCTYPE svg&gt;</desc>"
          ] do
        assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", svg(body)), body
      end

      assert {:error, :format} =
               check(context, "mockup", "a.svg", ~s(<!DOCTYPE svg>) <> svg("<rect/>"))
    end

    test "refuses an SVG larger than 524288 bytes as :document_size", context do
      head = ~s(<svg xmlns="#{@svg_namespace}"><desc>)
      tail = "</desc></svg>"
      fill = fn size -> head <> String.duplicate("a", size - byte_size(head <> tail)) <> tail end

      assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", fill.(524_288))
      assert {:error, :document_size} = check(context, "proposal", "a.svg", fill.(524_289))
      assert {:error, :format} = check(context, "mockup", "a.svg", fill.(524_289))

      assert Format.proposal_bytes("a.svg") == 524_288
      assert Format.proposal_bytes("A.SVG") == 524_288
      assert Format.proposal_bytes("proposal.md") == 262_144
      assert Format.proposal_bytes("sources.json") == 1_048_576
    end

    test "names the element with more than 256 attributes, before the parse", context do
      at = fn name, n -> "<#{name}" <> Enum.map_join(1..n, "", &~s( a#{&1}="1")) <> "/>" end

      assert {:error, {:svg_content, "the attributes past the 256th on the g element"}} =
               check(context, "proposal", "a.svg", svg(at.("g", 257)))

      assert {:error, {:svg_content, "the attributes past the 256th on the s:rect element"}} =
               check(context, "proposal", "a.svg", svg(at.("s:rect", 300)))

      # A `>` in a quoted value does not end the tag.
      many = "<g" <> Enum.map_join(1..300, "", &~s( a#{&1}='>')) <> "/>"

      assert {:error, {:svg_content, "the attributes past the 256th on the g element"}} =
               check(context, "proposal", "a.svg", svg(many))

      # An `=` in text, a comment, a CDATA section or a quoted value is no attribute.
      equals = String.duplicate("=", 300)

      for body <- [
            "<desc>#{equals}</desc>",
            "<!-- #{equals} -->",
            "<style><![CDATA[#{equals}]]></style>",
            ~s(<rect id="#{equals}"/>)
          ] do
        assert {:ok, "image/svg+xml"} = check(context, "proposal", "a.svg", svg(body)), body
      end

      assert {:error, :format} = check(context, "mockup", "a.svg", svg(at.("g", 257)))
    end
  end

  describe "Filename.valid?/1" do
    test "takes a base name of 1 to 255 bytes" do
      for name <- ["a", "demo video.mp4", "été.md", ".hidden", "a..b", String.duplicate("a", 255)],
          do: assert(Filename.valid?(name), name)
    end

    test "refuses a path, a dot name, control, format and separator characters, and more than 255 bytes" do
      for name <- [
            "",
            ".",
            "..",
            "a/b",
            "/a",
            "a\\b",
            "a\u0000b",
            "a\tb",
            "a\u007Fb",
            "a\u0085b",
            "a\u200Bb",
            "a\u202Eb",
            "a\u2028b",
            <<0xFF>>,
            String.duplicate("a", 256),
            nil,
            :a
          ] do
        refute Filename.valid?(name), inspect(name)
      end
    end
  end

  describe "stored?/2" do
    test "takes a version whose kept content types are its base view's" do
      assert Format.stored?(:document, ["text/markdown; charset=utf-8"])
      assert Format.stored?(:image, ["image/png", "image/svg+xml"])
      assert Format.stored?(:video, ["video/webm"])
      assert Format.stored?(:video, ["video/mp4", "text/vtt; charset=utf-8"])
      refute Format.stored?(:video, ["text/vtt; charset=utf-8"])
      assert Format.stored?(:file, ["application/octet-stream"])
      assert Format.stored?(:structured, ["application/json"])

      refute Format.stored?(:image, [])
      refute Format.stored?(:image, ["image/png", "application/json"])
      refute Format.stored?(:document, ["application/octet-stream"])
      refute Format.stored?(:structured, ["application/json", "application/json"])

      assert Format.stored?(standard("mockup"), ["image/png", "image/svg+xml"])
      refute Format.stored?(standard("mockup"), [])
    end

    test "takes a proposal of one Markdown file, images and at most one JSON file" do
      proposal = standard("proposal")
      md = "text/markdown; charset=utf-8"

      assert Format.stored?(proposal, [md])
      assert Format.stored?(proposal, [md, "image/png", "image/svg+xml", "application/json"])
      assert Format.stored?(proposal, ["image/webp", md, "image/gif", "image/jpeg"])

      refute Format.stored?(proposal, [])
      refute Format.stored?(proposal, ["image/png"])
      refute Format.stored?(proposal, [md, md])
      refute Format.stored?(proposal, [md, "application/json", "application/json"])
      refute Format.stored?(proposal, [md, "application/octet-stream"])
      refute Format.stored?(proposal, [md, "video/mp4"])
    end
  end
end
