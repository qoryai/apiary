defmodule Apiary.Sources.BodyTest do
  @moduledoc """
  A ticket's text as the console shows it (`Apiary.Sources.Body.render/2`): Markdown
  formatted, to a fixed allowlist, every link `https`, no image and no raw HTML; any other
  format as written, unchanged.
  """
  use ExUnit.Case, async: true

  alias Apiary.Sources.Body

  # What the sanitiser lets through, and nothing else may be in the HTML.
  @tags ~w(a blockquote br code del em h3 h4 h5 h6 hr li ol p pre span strong table tbody
           td th thead tr ul)
  @attributes %{
    "a" => ~w(href target rel),
    "ol" => ~w(start),
    "td" => ~w(align),
    "th" => ~w(align scope),
    "table" => ~w(aria-label),
    "span" => ~w(class aria-hidden)
  }

  # https URLs that URI parses and the sanitiser's URL parser refuses: a link to one would
  # lose its href, so it is its words.
  @refused [
    "https://example.com:99999/",
    "https://1.2.3.4:99999/",
    "https://exa%zzmple.com/",
    "https://exa%20mple.com/",
    "https://good.com%40evil.com",
    "https://999.1.1.1/",
    "https://1.2.3.4.5/",
    "https://example.123/",
    "https://xn--zz.example/",
    "https://[::ffff:192.0.2.1]/"
  ]

  # https URLs the sanitiser keeps and that are not linked by choice: a host that is no
  # plain name or IPv4 address of four parts, an IPv6 address, or a host outside ASCII.
  @not_linked [
    "https://0x7f.1/",
    "https://a..b.example/",
    "https://[::1]/",
    "https://ü.example/"
  ]

  defp html(markdown) do
    assert {:safe, html} = Body.render(markdown, "markdown")
    html = IO.iodata_to_binary(html)
    assert_allowed(html)
    html
  end

  defp doc(markdown), do: markdown |> html() |> LazyHTML.from_fragment()

  defp words(doc), do: doc |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # Every element is on the allowlist, with only its attributes; every link is https and
  # opens a new tab with the rel; no attribute holds a script.
  defp assert_allowed(html) do
    for element <- LazyHTML.query(LazyHTML.from_fragment(html), "*") do
      [tag] = LazyHTML.tag(element)
      [attributes] = LazyHTML.attributes(element)
      assert tag in @tags, "#{tag} is not allowed: #{html}"

      for {name, value} <- attributes do
        allowed = Map.get(@attributes, tag, [])
        assert name in allowed, "#{tag}[#{name}] is not allowed: #{html}"
        refute value =~ ~r/javascript|vbscript|data:/i
      end

      if tag == "table" do
        assert attributes == [{"aria-label", "Table in the ticket"}]
      end

      if tag == "a" do
        assert {"href", "https://" <> _} = List.keyfind(attributes, "href", 0)
        assert {"target", "_blank"} in attributes
        assert {"rel", "nofollow noopener noreferrer"} in attributes
      end
    end

    refute html =~ ~r/<(img|script|style|iframe|svg|input|form|object|embed)\b/i
    refute html =~ "<!--"
  end

  describe "markdown, formatted" do
    test "headings move down two levels, so # is an h3 and the deepest an h6" do
      doc = doc("# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six")

      assert doc |> LazyHTML.query("h3") |> LazyHTML.text() == "One"
      assert doc |> LazyHTML.query("h4") |> LazyHTML.text() == "Two"
      assert doc |> LazyHTML.query("h5") |> LazyHTML.text() == "Three"
      sixes = doc |> LazyHTML.query("h6") |> Enum.map(&LazyHTML.text/1)
      assert sixes == ~w(Four Five Six)
      assert LazyHTML.query(doc, "h1, h2") |> Enum.empty?()
    end

    test "emphasis, strong, strikethrough and inline code" do
      doc = doc("Some *em*, **strong**, ~~gone~~ and `mix test`.")

      assert doc |> LazyHTML.query("p > em") |> LazyHTML.text() == "em"
      assert doc |> LazyHTML.query("p > strong") |> LazyHTML.text() == "strong"
      assert doc |> LazyHTML.query("p > del") |> LazyHTML.text() == "gone"
      assert doc |> LazyHTML.query("p > code") |> LazyHTML.text() == "mix test"
    end

    test "lists, numbered from where they start, and a block quote" do
      doc = doc("- one\n- two\n\n3. three\n4. four\n\n> quoted\n> words")

      assert doc |> LazyHTML.query("ul > li") |> Enum.map(&LazyHTML.text/1) == ~w(one two)
      assert doc |> LazyHTML.query("ol") |> LazyHTML.attribute("start") == ["3"]
      assert doc |> LazyHTML.query("ol > li") |> Enum.count() == 2
      assert doc |> LazyHTML.query("blockquote p") |> words() == "quoted words"
    end

    test "a code block keeps its text, escaped, and drops its language" do
      html = html("```elixir\nIO.puts(\"<b>{x}</b>\")\n```")
      doc = LazyHTML.from_fragment(html)

      code = doc |> LazyHTML.query("pre > code") |> LazyHTML.text()
      assert code == "IO.puts(\"<b>{x}</b>\")\n"
      assert html =~ "&lt;b&gt;{x}&lt;/b&gt;"
      refute html =~ "language-"
    end

    test "a table: header cells are th with scope col, the body's are td" do
      doc = doc("| Name | Count |\n|:-----|------:|\n| one  | 1     |\n| two  | 2     |")

      header = LazyHTML.query(doc, "table > thead > tr > th")
      assert Enum.map(header, &LazyHTML.text/1) == ~w(Name Count)
      assert LazyHTML.attribute(header, "scope") == ["col", "col"]
      assert LazyHTML.attribute(header, "align") == ["left", "right"]

      table = LazyHTML.query(doc, "table")
      assert LazyHTML.attribute(table, "aria-label") == ["Table in the ticket"]

      cells = LazyHTML.query(doc, "table > tbody > tr > td")
      assert Enum.map(cells, &LazyHTML.text/1) == ~w(one 1 two 2)
      assert doc |> LazyHTML.query("td[scope]") |> Enum.empty?()
    end

    test "a task box is no form field: a hidden mark, and Done or Not done in words" do
      doc = doc("- [x] write the docs\n- [ ] run the suite")

      assert doc |> LazyHTML.query("input") |> Enum.empty?()

      [done, open] = doc |> LazyHTML.query("ul > li") |> Enum.to_list()
      assert done |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "Done"
      assert open |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "Not done"

      for item <- [done, open] do
        mark = LazyHTML.query(item, ".q-task-mark")
        assert LazyHTML.attribute(mark, "aria-hidden") == ["true"]
      end

      assert done |> words() =~ "write the docs"
    end

    test "a bare https URL and www are autolinked; the www one, http, is its words" do
      doc = doc("See https://example.com/a?b=1 and www.example.org today.")

      assert doc |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
               "https://example.com/a?b=1"
             ]

      assert words(doc) =~ "www.example.org today."
    end

    test "an e-mail address is autolinked as mailto, so it is its words" do
      doc = doc("Write to someone@example.com.")

      assert doc |> LazyHTML.query("a") |> Enum.empty?()
      assert words(doc) == "Write to someone@example.com."
    end
  end

  describe "links" do
    test "an https link is kept, opens a new tab, with the rel and the new-tab words" do
      doc = doc("[the docs](https://example.com/docs)")

      [link] = doc |> LazyHTML.query("a") |> Enum.to_list()
      assert LazyHTML.attribute(link, "href") == ["https://example.com/docs"]
      assert LazyHTML.attribute(link, "target") == ["_blank"]
      assert LazyHTML.attribute(link, "rel") == ["nofollow noopener noreferrer"]
      new_tab = link |> LazyHTML.query(".sr-only") |> LazyHTML.text()
      assert new_tab == " (opens in a new tab)"

      icon = LazyHTML.query(link, ".q-ticket-ext")
      assert LazyHTML.attribute(icon, "aria-hidden") == ["true"]
    end

    test "a link's title is dropped, quotes and all" do
      html = html(~s{[x](https://example.com "say \\"hi\\" onmouseover=alert(1)")})

      refute html =~ "title"
      refute html =~ "onmouseover"
      assert html =~ ~s(href="https://example.com")
    end

    test "a link that is not https is its words, unlinked" do
      for url <- [
            "http://example.com/",
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "&#106;avascript:alert(1)",
            "&#x6A;avascript&#58;alert(1)",
            "java&#09;script:alert(1)",
            "data:text/html;base64,AAAA",
            "vbscript:msgbox(1)",
            "mailto:someone@example.com",
            "/relative/path",
            "relative",
            "#anchor",
            "//evil.example/",
            "https:evil.example",
            "https:///nohost",
            "https://user:secret@example.com/",
            "ftp://example.com/"
            | @refused ++ @not_linked
          ] do
        doc = doc("Go [there](#{url}) now.")

        assert doc |> LazyHTML.query("a") |> Enum.empty?(), url
        assert words(doc) == "Go there now.", url
      end
    end

    test "the sanitiser's URL parser refuses each URL of @refused" do
      sanitize = [url_schemes: ["https"], url_relative: :deny, link_rel: nil]

      for url <- @refused do
        html = MDEx.to_html!("[x](#{url})", render: [unsafe: false])
        assert html =~ "href=", url
        sanitised = MDEx.safe_html(html, sanitize: sanitize, escape: [content: false])
        refute sanitised =~ "href=", url
      end
    end

    test "an https URL refused or not linked by choice is its words, linked or bare" do
      for url <- @refused ++ @not_linked do
        forms = ["Go [there](#{url}) now.", "Go #{url} now.", "Go <#{url}> now."]

        for markdown <- forms do
          doc = doc(markdown)

          assert doc |> LazyHTML.query("a") |> Enum.empty?(), markdown
          refute words(doc) =~ "opens in a new tab", markdown
        end
      end
    end

    test "an https URL to an IPv4 address of four parts is a link" do
      assert html("[x](https://192.0.2.1:8443/a)") =~ ~s(href="https://192.0.2.1:8443/a")
    end

    test "an autolink in angle brackets follows the same rule" do
      assert html("<https://example.com/x>") =~ ~s(href="https://example.com/x")
      assert "<http://example.com/x>" |> doc() |> LazyHTML.query("a") |> Enum.empty?()
      assert "<javascript:alert(1)>" |> doc() |> LazyHTML.query("a") |> Enum.empty?()
    end

    test "an https URL with a character outside ASCII is a link" do
      doc = doc("[über](https://example.com/über)")

      assert doc |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
               "https://example.com/%C3%BCber"
             ]
    end
  end

  describe "images" do
    test "an https image is a link to it whose words are Image: and its alt text" do
      doc = doc(~s{![a diagram](https://example.com/d.png "Diagram")})

      [link] = doc |> LazyHTML.query("a") |> Enum.to_list()
      assert LazyHTML.attribute(link, "href") == ["https://example.com/d.png"]
      assert words(link) == "Image: a diagram (opens in a new tab)"

      icon = LazyHTML.query(link, ".q-ticket-ext")
      assert LazyHTML.attribute(icon, "aria-hidden") == ["true"]
    end

    test "an https image with no alt text is a link whose words are Image" do
      doc = doc("![](https://example.com/d.png)")

      assert doc |> LazyHTML.query("a") |> words() == "Image (opens in a new tab)"
      refute words(doc) =~ "d.png"
    end

    test "an image whose URL is not https is the same words, unlinked" do
      for url <- [
            "http://example.com/d.png",
            "javascript:alert(1)",
            "data:image/png;base64,AAAA",
            "/d.png",
            "//example.com/d.png"
          ] do
        doc = doc("Before ![the alt](#{url}) after")

        assert doc |> LazyHTML.query("a") |> Enum.empty?(), url
        assert words(doc) == "Before Image: the alt after", url

        assert "![](#{url})" |> doc() |> words() == "Image", url
      end
    end

    test "an image's alt text is text: its markup and entities are escaped" do
      html = html(~s{![a \\<b onclick="x"> "q" 'r' &amp;](https://example.com/d.png)})
      doc = LazyHTML.from_fragment(html)

      # In text, a quote needs no escape; < and & do.
      assert html =~ ~s(>Image: a &lt;b onclick="x"&gt; "q" 'r' &amp;<span)

      assert doc |> LazyHTML.query("a") |> words() ==
               ~s[Image: a <b onclick="x"> "q" 'r' & (opens in a new tab)]

      assert doc |> LazyHTML.query("b") |> Enum.empty?()
    end

    test "a script in an image's alt text is dropped, as raw HTML is; its text stays" do
      doc = doc("![a <script>alert(1)</script>](https://example.com/d.png)")

      assert doc |> LazyHTML.query("script") |> Enum.empty?()
      words = doc |> LazyHTML.query("a") |> words()
      assert words == "Image: a alert(1) (opens in a new tab)"
    end

    test "an image inside a link is the link's words, so no link is inside another" do
      doc = doc("[![logo](https://example.com/logo.png)](https://example.org/home)")

      [link] = doc |> LazyHTML.query("a") |> Enum.to_list()
      assert LazyHTML.attribute(link, "href") == ["https://example.org/home"]
      assert words(link) == "Image: logo (opens in a new tab)"
    end
  end

  describe "the generated documentation" do
    # Every instance serves the module reference at /docs, which leaves this module out.
    test "leaves Apiary.Sources.Body out" do
      assert {:docs_v1, _anno, :elixir, _format, :hidden, _meta, docs} =
               Code.fetch_docs(Body)

      assert docs != []

      for {{kind, _name, _arity}, _anno, _signature, doc, _meta} <- docs,
          kind != :type,
          do: assert(doc == :hidden)
    end
  end

  describe "raw HTML and scripts" do
    test "no tag of raw HTML reaches the HTML, as markup or as text" do
      # Each vector, between two paragraphs, and the words left of it: a block of raw
      # HTML is dropped whole; inline tags are dropped and the Markdown text between them
      # stays, escaped.
      vectors = [
        {"<script>alert(1)</script>", ""},
        {"<img src=x onerror=alert(1)>", ""},
        {"<iframe src=\"https://example.com\"></iframe>", ""},
        {"<svg onload=alert(1)>", ""},
        {"<svg><script>alert(1)</script></svg>", "alert(1)"},
        {"<a href=\"javascript:alert(1)\">click</a>", "click"},
        {"<style>body{display:none}</style>", ""},
        {"<!-- a comment -->", ""},
        {"<div style=\"color:red\" onclick=\"alert(1)\">block</div>", ""},
        {"<details open ontoggle=alert(1)>", ""},
        {"<object data=\"https://example.com/x.swf\"></object>", ""},
        {"<math><mi xlink:href=\"javascript:alert(1)\">x</mi></math>", "x"},
        {"<form action=\"https://example.com\"><input name=x></form>", ""},
        {"<textarea><script>alert(1)</script></textarea>", ""},
        {"<meta http-equiv=\"refresh\" content=\"0;url=https://example.com\">", ""},
        {"one <script>alert(1)</script> two", "one alert(1) two"}
      ]

      for {vector, left} <- vectors do
        html = html("before\n\n#{vector}\n\nafter")

        refute html =~ "&lt;", vector
        refute html =~ ~r/style|onclick|onerror|onload|ontoggle|href|src|action/i, vector
        expected = String.trim("before #{left}") <> " after"
        assert words(LazyHTML.from_fragment(html)) == expected
      end
    end

    test "inline tags are dropped and their text stays" do
      doc =
        doc(
          ~s[Some <b onclick="alert(1)">bold</b> and ] <>
            ~s[<span style="color:red">red</span>.]
        )

      assert words(doc) == "Some bold and red."
      assert doc |> LazyHTML.query("b, span") |> Enum.empty?()
    end

    test "a quote in a link's URL cannot open an attribute: it is no URL, so no link" do
      html = html(~s{[x](<https://example.com/"onmouseover="alert(1)>)})

      assert html == "<p>x</p>"
    end
  end

  describe "as written" do
    test "text, nil and an unknown format come back unchanged, byte for byte" do
      text = "# Not a heading\n  <script>alert(1)</script>\r\n\ttabbed  **x** é\n"

      for format <- ["text", nil, "html", "Markdown", "markdown "] do
        assert Body.render(text, format) == {:as_written, text}
      end
    end

    test "an empty or nil text is the empty text, as written" do
      for format <- ["markdown", "text", nil] do
        assert Body.render(nil, format) == {:as_written, ""}
        assert Body.render("", format) == {:as_written, ""}
      end
    end

    test "markdown longer than max_length/0 characters is shown as written, whole" do
      at_most = String.duplicate("é", Body.max_length())
      assert {:safe, _} = Body.render(at_most, "markdown")

      longer = at_most <> "x"
      assert Body.render(longer, "markdown") == {:as_written, longer}
    end

    test "a character is a code point, so combining marks count one each" do
      # One grapheme each: e and a combining acute accent are two code points.
      at_most = String.duplicate("e\u0301", div(Body.max_length(), 2))
      assert {:safe, _} = Body.render(at_most, "markdown")
      assert Body.render(at_most <> "x", "markdown") == {:as_written, at_most <> "x"}

      # One grapheme of 70,001 code points
      long = "a" <> String.duplicate("\u0301", 70_000)
      assert String.length(long) == 1
      assert Body.render(long, "markdown") == {:as_written, long}
    end

    test "invalid UTF-8 is as written, its invalid bytes replaced with U+FFFD" do
      for format <- ["markdown", "text", nil] do
        bad = <<"# x ", 0xFF, " y">>
        assert Body.render(bad, format) == {:as_written, "# x \uFFFD y"}

        # The first two bytes of a three-byte character are one sequence
        assert Body.render(<<0xE2, 0x82, ?a>>, format) == {:as_written, "\uFFFDa"}
      end
    end

    test "a table that could ask for more than max_cells/0 cells is as written" do
      # A wide header and many short rows: each row would be padded to the header's cells.
      c = 100

      header = "|" <> String.duplicate("a|", c) <> "\n"
      header = header <> "|" <> String.duplicate("-|", c) <> "\n"
      body = header <> String.duplicate("a\n", div(65_536 - 4 * c - 4, 2))

      {microseconds, result} = :timer.tc(fn -> Body.render(body, "markdown") end)
      assert result == {:as_written, body}
      # A ceiling against a hang, not a measure: the bound answers in milliseconds.
      assert microseconds < 10_000_000

      # Lines end with a carriage return as well
      cr = String.replace(body, "\n", "\r")
      assert Body.render(cr, "markdown") == {:as_written, cr}
    end

    test "a table within max_cells/0 is formatted, and so is a long text with no |" do
      body = "| a | b |\n|---|---|\n" <> String.duplicate("| 1 | 2 |\n", 100)
      assert {:safe, _} = Body.render(body, "markdown")

      assert {:safe, _} = Body.render(String.duplicate("a\n", 30_000), "markdown")
    end

    test "text that nests deeper than max_depth/0 is as written" do
      deep_list = for i <- 0..199, into: "", do: String.duplicate(" ", i * 2) <> "- x\n"

      for body <- [
            String.duplicate(">", 65_536),
            String.duplicate("> ", 32_768),
            String.duplicate(">", Body.max_depth()) <> " x",
            deep_list,
            String.duplicate("- ", 1000) <> "x",
            String.duplicate("*", 600) <> "a" <> String.duplicate("*", 600)
          ] do
        {microseconds, result} = :timer.tc(fn -> Body.render(body, "markdown") end)
        assert result == {:as_written, body}
        # A ceiling against a hang, not a measure: the bound answers in milliseconds.
        assert microseconds < 10_000_000
      end
    end

    test "nesting within max_depth/0 is formatted" do
      doc = doc(String.duplicate(">", 20) <> " deep")

      assert doc |> LazyHTML.query("blockquote") |> Enum.count() == 20
      assert words(doc) == "deep"
    end
  end
end
