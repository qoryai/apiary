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

    # A list where the schema file allows none is past the bounds, before JSV reads it.
    assert {:error, {:schema, %{path: "#", error: "the document has more values" <> _}}} =
             check(context, "verdict", "a", ~s([1]))

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
        assert {:error,
                {:schema, %{path: "#/questions/0", error: "the object has the key id twice"}}} =
                 questions(context, [question(%{"id" => id})])
      end

      assert {:error, {:schema, %{path: "#/questions/1/id", error: error}}} =
               questions(context, [question(), question(%{"question" => "Which sale?"})])

      assert error =~ "earlier question"
    end

    test "a question offers 0 to 10 options", context do
      option = &%{"title" => "Option #{&1}", "explanation" => "Why #{&1}."}

      assert {:ok, _} =
               questions(context, [question(%{"options" => Enum.map(1..10, option)})])

      assert {:error, {:schema, %{path: "#/questions/0/options"}}} =
               questions(context, [question(%{"options" => Enum.map(1..11, option)})])
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

      for replies <- [
            [reply(%{"by" => run, "outcome" => "changed"})],
            [reply(%{"by" => member})],
            [reply(%{"by" => run, "outcome" => "asked", "question" => "q3"})]
          ] do
        assert {:ok, _} =
                 review_comments(context, [
                   review_comment(%{"state" => "closed", "replies" => replies})
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
    end
  end
end
