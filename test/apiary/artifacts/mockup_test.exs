defmodule Apiary.Artifacts.MockupTest do
  use ExUnit.Case, async: true

  alias Apiary.Artifacts.Mockup

  @moduletag :tmp_dir

  # The shared cases of the mockup contract, copied byte for byte from the Qory harness's
  # pack step (`cases.md`): each line of a `cases` block is `<verdict> <place> <snippet>`.
  @cases_file Path.expand("../../support/fixtures/mockup_cases.md", __DIR__)
  @external_resource @cases_file

  @cases (for [block] <-
                Regex.scan(~r/^```cases\n(.*?)^```$/ms, File.read!(@cases_file),
                  capture: :all_but_first
                ),
              line <- String.split(block, "\n", trim: true) do
            [verdict, place, snippet] = String.split(line, " ", parts: 3)
            {String.to_atom(verdict), String.to_atom(place), snippet}
          end)

  @ids MapSet.new(["start", "next"])
  @start %{"id" => "start", "file" => "start.html", "title" => "Start"}

  defp page(head, body),
    do:
      ~s(<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Start</title>) <>
        head <> "</head><body>" <> body <> "</body></html>"

  defp check(bytes), do: Mockup.page(bytes, @start, @ids)

  defp assert_verdict(:allowed, {:ok, _linked}), do: :ok
  defp assert_verdict(:refused, {:error, message}) when is_binary(message), do: :ok
  defp assert_verdict(verdict, result), do: flunk("expected #{verdict}, got #{inspect(result)}")

  describe "the shared cases" do
    test "are all read: 136 lines in the cases blocks" do
      assert length(@cases) == 136

      assert Enum.all?(@cases, fn {verdict, place, _snippet} ->
               verdict in [:allowed, :refused] and place in [:head, :body]
             end)
    end

    test "the page with both places empty is allowed" do
      assert {:ok, linked} = check(page("", ""))
      assert MapSet.size(linked) == 0
    end

    for {{verdict, place, snippet}, n} <- Enum.with_index(@cases, 1) do
      @verdict verdict
      @place place
      @snippet snippet
      test "case #{n}: #{verdict} #{place} #{snippet}" do
        bytes = if @place == :head, do: page(@snippet, ""), else: page("", @snippet)

        assert_verdict(@verdict, check(bytes))
      end
    end
  end

  describe "the prose cases" do
    test "a page with no <title> is refused" do
      assert {:error, "Give `start.html` (screen `start`) exactly one `<title>`: it has 0."} =
               check(
                 ~s(<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>)
               )
    end

    test "a <title> of Start with spaces and a line feed around it is allowed" do
      bytes =
        ~s(<!doctype html><html><head><meta charset="utf-8"><title> \nStart\n </title></head><body></body></html>)

      assert {:ok, _linked} = check(bytes)
    end

    test "a page with a UTF-8 byte order mark is refused" do
      assert {:error,
              "Save `start.html` as UTF-8 without a byte order mark: the page starts with one."} =
               check(<<0xEF, 0xBB, 0xBF>> <> page("", ""))
    end

    test "a page that is not UTF-8 is refused" do
      assert {:error, "Save `start.html` as UTF-8: it has bytes that are not UTF-8."} =
               check(page("", <<0xFF>>))
    end

    test "a page of 1 MiB is allowed, and one byte more is refused" do
      empty = page("", "")
      bytes = page("", String.duplicate("a", 1_048_576 - byte_size(empty)))
      assert byte_size(bytes) == 1_048_576
      assert {:ok, _linked} = check(bytes)

      assert {:error, "Shrink `start.html` to at most 1048576 bytes: it has 1048577 bytes."} =
               check(page("", String.duplicate("a", 1_048_577 - byte_size(empty))))
    end

    test "1,000 <use> are allowed, 1,001 refused" do
      uses = fn n ->
        page(
          "",
          ~s(<svg><defs><path id="p" d="M0 0"/></defs>) <>
            String.duplicate(~s(<use href="#p"/>), n) <> "</svg>"
        )
      end

      assert {:ok, _linked} = check(uses.(1_000))

      assert {:error,
              "Draw at most 1000 `<use>` elements in `start.html` (screen `start`): it has more."} =
               check(uses.(1_001))
    end

    test "1,000 <use> of a <g> with 99 paths are allowed, with 100 paths refused" do
      uses = fn paths ->
        page(
          "",
          ~s(<svg><defs><g id="a">) <>
            String.duplicate(~s(<path d="M0 0"/>), paths) <>
            "</g></defs>" <> String.duplicate(~s(<use href="#a"/>), 1_000) <> "</svg>"
        )
      end

      assert {:ok, _linked} = check(uses.(99))

      assert {:error,
              "Draw at most 100000 elements through `<use>` in `start.html` (screen `start`): " <>
                "each `<use>` draws the elements of its target, the target included, and the " <>
                "page has 101000."} = check(uses.(100))
    end

    test "a gradient has only stops, and a clip path no url( on itself" do
      assert {:error,
              "Remove the SVG `<rect>` element from the `<linearGradient>` in `start.html` " <>
                "(screen `start`): a gradient of a mockup page has only `<stop>` elements."} =
               check(
                 page(
                   "",
                   ~s(<svg><defs><linearGradient id="g"><rect width="1" height="1"/>) <>
                     "</linearGradient></defs></svg>"
                 )
               )

      assert {:error, "Remove the `url(` from the `clip-path` attribute of the SVG" <> _rest} =
               check(
                 page(
                   "",
                   ~s|<svg><defs><clipPath id="c" clip-path="url(#c)"><rect width="1" | <>
                     ~s|height="1"/></clipPath></defs></svg>|
                 )
               )
    end
  end

  describe "a version" do
    defp screens(overrides \\ []) do
      Map.merge(
        %{
          "start" => "start",
          "screens" => [
            %{
              "id" => "start",
              "title" => "Start",
              "file" => "start.html",
              "criteria" => ["ac-1"],
              "links" => [%{"to" => "next", "label" => "Next"}]
            },
            %{
              "id" => "next",
              "title" => "Next",
              "file" => "next.html",
              "criteria" => [],
              "links" => [%{"to" => "start", "label" => "Back"}]
            }
          ]
        },
        Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
      )
    end

    defp html(title, body),
      do:
        ~s|<!doctype html><html><head><meta charset="utf-8"><title>#{title}</title></head>| <>
          "<body>#{body}</body></html>"

    defp pages do
      [
        {"start.html", html("Start", ~s|<a href="next.html">Next</a>|)},
        {"next.html", html("Next", ~s|<a href="start.html">Back</a>|)}
      ]
    end

    defp version(context, files) do
      files
      |> Enum.map(fn {filename, bytes} ->
        path = Path.join(context.tmp_dir, "#{System.unique_integer([:positive])}-#{filename}")
        File.write!(path, if(is_binary(bytes), do: bytes, else: Jason.encode!(bytes)))
        {filename, path}
      end)
      |> Mockup.check_version()
    end

    test "of screens.json and one page per screen passes", context do
      assert :ok = version(context, [{"screens.json", screens()} | pages()])
    end

    test "without screens.json is refused for the version", context do
      assert {:error,
              {{:mockup, "Add `screens.json` to the version: it lists the screens."}, nil}} =
               version(context, pages())
    end

    test "with another file is refused at that file", context do
      assert {:error, {{:mockup, message}, 3}} =
               version(context, [{"screens.json", screens()} | pages()] ++ [{"a.png", "x"}])

      assert message ==
               "Remove `a.png` from the version: a mockup version has `screens.json` and one " <>
                 "page per screen, and no other file."
    end

    test "without a screen's page is refused for the version", context do
      assert {:error, {{:mockup, message}, nil}} =
               version(context, [{"screens.json", screens()}, hd(pages())])

      assert message ==
               "Add `next.html` to the version: it is the page of screen `next` in `screens.json`."
    end

    test "whose screens.json fails the schema is refused at it", context do
      assert {:error, {:schema, 0, %{path: "#/screens/0/id"}}} =
               version(context, [
                 {"screens.json",
                  screens(
                    screens: [
                      %{
                        "id" => "Start",
                        "title" => "S",
                        "file" => "a.html",
                        "criteria" => [],
                        "links" => []
                      }
                    ]
                  )}
               ])

      assert {:error, {:schema, 0, %{path: "#", error: _error}}} =
               version(context, [{"screens.json", Map.put(screens(), "extra", 1)} | pages()])

      assert {:error, {:schema, 0, %{path: "#/screens/0/title"}}} =
               version(context, [
                 {"screens.json",
                  screens(
                    screens: [
                      %{
                        "id" => "a",
                        "title" => "A\tB",
                        "file" => "a.html",
                        "criteria" => [],
                        "links" => []
                      }
                    ],
                    start: "a"
                  )}
               ])
    end

    test "whose screens.json has a key twice is refused at it", context do
      bytes = ~s|{"start":"a","start":"a","screens":[]}|

      assert {:error, {:schema, 0, %{path: "#", error: "the object has the key start twice"}}} =
               version(context, [{"screens.json", bytes}])
    end

    test "whose screens.json is not JSON or too large is refused at it", context do
      assert {:error,
              {{:mockup,
                "Make `screens.json` one JSON document in UTF-8: the file does not parse as JSON."},
               0}} =
               version(context, [{"screens.json", "{"} | pages()])

      assert {:error,
              {{:mockup, "Shrink `screens.json` to at most 65536 bytes: it has 65537 bytes."}, 0}} =
               version(context, [{"screens.json", String.duplicate(" ", 65_537)} | pages()])
    end

    test "breaks no rule of screens.json beside its schema", context do
      [start, next] = screens()["screens"]

      for {document, path, error} <- [
            {screens(start: "gone"), "#/start", "the start gone is not the id of a screen"},
            {screens(screens: [start, %{next | "id" => "start", "file" => "start.html"}]),
             "#/screens/1/id", "the id start is the id of an earlier screen"},
            {screens(screens: [start, %{next | "file" => "other.html"}]), "#/screens/1/file",
             "the file is not next.html, the screen's id and .html"},
            {screens(screens: [%{start | "links" => [%{"to" => "gone", "label" => "x"}]}, next]),
             "#/screens/0/links/0/to", "the to gone is not the id of a screen"},
            {screens(screens: [%{start | "links" => []}, next]), "#/screens/1",
             "the screen next cannot be reached from the start screen through links"}
          ] do
        assert {:error, {:schema, 0, %{path: ^path, error: ^error}}} =
                 version(context, [{"screens.json", document} | pages()])
      end
    end

    test "has each screen's links as its page links to", context do
      [start, next] = screens()["screens"]

      document =
        screens(
          screens: [
            start,
            %{
              next
              | "links" => [
                  %{"to" => "start", "label" => "Back"},
                  %{"to" => "next", "label" => "Again"}
                ]
            }
          ]
        )

      assert {:error, {{:mockup, message}, 2}} =
               version(context, [{"screens.json", document} | pages()])

      assert message ==
               "Link `next.html` to `next.html` with an `<a href>`, or remove the link to screen " <>
                 "`next` from the `links` of screen `next` in `screens.json`: the page has no " <>
                 "link to `next.html`."

      [start_page, _next_page] = pages()

      extra =
        {"next.html",
         html("Next", ~s|<a href="start.html">Back</a><a href="next.html">Again</a>|)}

      assert {:error, {{:mockup, message}, 2}} =
               version(context, [{"screens.json", screens()}, start_page, extra])

      assert message ==
               "Add a link to screen `next` to the `links` of screen `next` in `screens.json`: " <>
                 "`next.html` links to `next.html`."
    end

    test "refuses a page with its message, at the page", context do
      [start_page, _next] = pages()
      bad = {"next.html", html("Next", ~s|<a href="start.html">Back</a><script>x()</script>|)}

      assert {:error, {{:mockup, message}, 2}} =
               version(context, [{"screens.json", screens()}, start_page, bad])

      assert message ==
               "Remove the `<script>` element from `next.html` (screen `next`): a mockup page " <>
                 "runs no script."
    end

    test "keeps a no-break space in a title, and collapses only ASCII white space", context do
      [_start, next_page] = pages()

      for {title, verdict} <- [
            {"Start&nbsp;", :refused},
            {"&#xA0;Start", :refused},
            {"\t Start\r\n\f ", :ok}
          ] do
        start_page = {"start.html", html(title, ~s(<a href="next.html">Next</a>))}
        result = version(context, [{"screens.json", screens()}, start_page, next_page])

        case verdict do
          :ok -> assert :ok = result, title
          :refused -> assert {:error, {{:mockup, "Set the `<title>`" <> _}, 1}} = result, title
        end
      end
    end

    test "has the page's title as its screen's", context do
      [start_page, _next] = pages()
      bad = {"next.html", html("Other", ~s|<a href="start.html">Back</a>|)}

      assert {:error, {{:mockup, message}, 2}} =
               version(context, [{"screens.json", screens()}, start_page, bad])

      assert message ==
               "Set the `<title>` of `next.html` (screen `next`) to `Next`, the title of the " <>
                 "screen in `screens.json`: it is `Other`."
    end
  end

  describe "the messages" do
    for {snippet, message} <- [
          {~s|<div onclick="x()">x</div>|,
           "Remove the `onclick` attribute from the `<div>` element in `start.html` (screen `start`): a mockup page runs no script."},
          {~s|<a href="https://example.com/">Out</a>|,
           "Set the `href` attribute of the `<a>` element in `start.html` (screen `start`) to `<id>.html` of a screen of the version: it is `https://example.com/`."},
          {~s|<div title="java&#09;script:x">x</div>|,
           "Remove `javascript:` from the `title` attribute of the `<div>` element in `start.html` (screen `start`): a mockup page runs no script."},
          {~s|<img src="a.png" alt="x">|,
           "Set the `src` attribute of the `<img>` element in `start.html` (screen `start`) to a base64 `data:` URI of a PNG, JPEG, GIF or WebP image: a mockup page loads nothing from outside the version. It is `a.png`."},
          {~s|<button type="submit">Go</button>|,
           "Set the `type` attribute of the `<button>` element in `start.html` (screen `start`) to `button`, or remove it: a mockup page sends no form. It is `submit`."},
          {~s|<svg><rect fill="url(#g)" width="1" height="1"/></svg>|,
           "Point `url(#g)` in the `fill` attribute of the SVG `<rect>` element in `start.html` (screen `start`) at a `<linearGradient>`, `<radialGradient>` or `<clipPath>` element of the page: no such element has the `id` `g`."},
          {~s|<div id="a"></div><p id="a"></p>|,
           "Give each element in `start.html` (screen `start`) a different `id`: `a` is the `id` of two elements."},
          {~s|<div style="background:url(https://example.com/a.png)">x</div>|,
           "Use only a base64 `data:` image in the `style` attribute of the `<div>` element in `start.html` (screen `start`), and a base64 `data:` font only inside `@font-face`: a mockup page loads nothing from outside the version, and a `url(#…)` goes only in the SVG attributes `fill`, `stroke` and `clip-path`. It has `https://example.com/a.png`."}
        ] do
      @snippet snippet
      @message message
      test "for #{snippet}" do
        assert {:error, @message} = check(page("", @snippet))
      end
    end

    test "for CSS rules and functions" do
      assert {:error,
              "Remove `@import` from a `<style>` element in `start.html` (screen `start`): a mockup page loads nothing from outside the version."} =
               check(page(~s|<style>@IMPORT url(data:image/png;base64,AA==);</style>|, ""))

      assert {:error,
              "Remove the `behavior` property from a `<style>` element in `start.html` (screen `start`): a mockup page runs no script."} =
               check(page(~s|<style>.a{behavior:none}</style>|, ""))

      assert {:error,
              "Remove `attr()` from a `<style>` element in `start.html` (screen `start`): the mockup format lists no `attr()`."} =
               check(page(~s|<style>.a::after{content:attr(x)}</style>|, ""))
    end
  end

  # Inputs that a parse by the HTML5 algorithm takes long on, each within 1 MiB: the check
  # refuses them before the parse, from a count of their tags and of one tag's
  # attributes, in well under 2 s.
  describe "a page that is slow to parse" do
    # A short name for `n`, in ASCII characters an attribute name may have, lower case:
    # each name is 3 characters or fewer.
    @name_characters ~c"0123456789abcdefghijklmnopqrstuvwxyz!#$%&()*+,.:;?@[]^_`{|}~-"

    defp name(n) when n < length(@name_characters), do: <<Enum.at(@name_characters, n)>>

    defp name(n) do
      base = length(@name_characters)
      name(div(n, base) - 1) <> <<Enum.at(@name_characters, rem(n, base))>>
    end

    defp timed(bytes) do
      {microseconds, result} = :timer.tc(fn -> check(bytes) end)
      assert microseconds < 2_000_000, "took #{div(microseconds, 1000)} ms"
      result
    end

    test "95,000 nested <div> are refused as too many tags" do
      bytes = page("", String.duplicate("<div>", 95_000))
      assert byte_size(bytes) < 1_048_576
      assert {:error, "Shrink `start.html` to at most 10000 tags" <> _rest} = timed(bytes)
    end

    test "110,000 data attributes on one element are refused" do
      bytes =
        page(
          "",
          "<div " <>
            Enum.map_join(1..110_000, " ", &"data-#{name(&1)}") <> ">x</div>"
        )

      assert byte_size(bytes) <= 1_048_576

      assert {:error, "Give each tag in `start.html` at most 256 attributes" <> _rest} =
               timed(bytes)
    end

    test "150,000 unknown elements are refused as too many tags" do
      bytes = page("", String.duplicate("<q-a>", 150_000))
      assert byte_size(bytes) < 1_048_576
      assert {:error, "Shrink `start.html` to at most 10000 tags" <> _rest} = timed(bytes)
    end

    test "attributes hidden from a naive count by a quoted value are counted" do
      # A comment that a quoted value seems to cover: an HTML5 tokenizer ends the comment
      # at -->, so the div's attributes are real.
      bytes =
        page(
          "",
          ~s|<!--<a b="-->| <>
            "<div " <> Enum.map_join(1..300, " ", &"data-a#{&1}") <> ~s|>x</div>"|
        )

      assert {:error, "Give each tag in `start.html` at most 256 attributes" <> _rest} =
               timed(bytes)
    end

    test "10,000 nested elements, the most tags, are checked in time" do
      bytes = page("", Enum.map_join(1..9_990, &~s|<b id="b#{&1}">|))
      assert {:ok, _linked} = timed(bytes)
    end

    test "a page of 1 MiB with many < inside a quoted value is counted in time" do
      bytes =
        page(
          "",
          ~s|<div title="| <>
            String.duplicate("<a>", 9_000) <> String.duplicate("x", 1_000_000) <> ~s|">x</div>|
        )

      assert {:ok, _linked} = timed(bytes)
    end
  end
end
