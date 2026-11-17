defmodule ApiaryWeb.ArtifactLive.MarkdownTest do
  # The Markdown of a document artifact as its view shows it
  # (`ApiaryWeb.ArtifactLive.Markdown`): no raw HTML, links of http, https and mailto and
  # of the pages of this Qory Apiary only, no image loaded, headings two levels down,
  # Mermaid blocks marked for the hook, and texts past the bounds as written.
  use ExUnit.Case, async: true

  alias ApiaryWeb.ArtifactLive.Markdown

  defp html(text) do
    assert {:html, safe} = Markdown.render(text)
    Phoenix.HTML.safe_to_string(safe)
  end

  test "drops raw HTML, a script among it, as markup and as text" do
    out =
      html(
        "# Plan\n\n<script>alert(1)</script>\n\nText <b onclick=\"x()\">bold</b> <img src=x onerror=alert(1)>"
      )

    refute out =~ "<script"
    refute out =~ "alert"
    refute out =~ "onclick"
    refute out =~ "<img"
    refute out =~ "<b"
    assert out =~ "<h3>Plan</h3>"
    assert out =~ "Text"
  end

  test "keeps http, https and mailto links, and unlinks every other" do
    out =
      html("""
      [web](https://example.com/a) [plain](http://example.com/b) [mail](mailto:dana@example.com)
      [js](javascript:alert(1)) [data](data:text/html,x) [user](https://a:b@example.com)
      [word](admin) [dot](./admin) [query](?q=1) [frag](#f)
      """)

    assert out =~ ~s(href="https://example.com/a")
    assert out =~ ~s(href="http://example.com/b")
    assert out =~ ~s(href="mailto:dana@example.com")
    refute out =~ "javascript:"
    refute out =~ "data:"
    refute out =~ ~s(href="/admin")
    refute out =~ ~s(href="admin")
    refute out =~ ~s(href="./admin")
    refute out =~ ~s(href="?q=1")
    refute out =~ ~s(href="#f")
    refute out =~ "a:b@"
    assert out =~ "js"
    assert out =~ ~s(rel="nofollow noopener noreferrer")
  end

  @path "/acme/main/work/7/artifacts/av_1"

  test "a link to a page of this Qory Apiary is a plain link with no icon and no new tab" do
    out = html("[submission v1](#{@path}?a=1&b=2#top) and [site](https://example.com/x)")

    assert out =~ ~s(<a href="#{@path}?a=1&amp;b=2#top">submission v1</a>)
    refute out =~ "qint"
    refute out =~ ".invalid"

    # The link to another site keeps its icon, its new tab and its words for a reader.
    assert out =~
             ~s(<a href="https://example.com/x" target="_blank" rel="nofollow noopener noreferrer">site<span class="q-ticket-ext)

    assert out =~ "(opens in a new tab)"

    assert length(String.split(out, "q-ticket-ext")) == 2
  end

  test "a link to the host of this Qory Apiary is a link to its path, with no icon" do
    own = ApiaryWeb.Endpoint.struct_url()
    base = "#{own.scheme}://#{own.host}:#{own.port}"

    other = "#{own.scheme}://#{own.host}.example.com:#{own.port}"

    out = html("[a](#{base}#{@path}) [b](#{base}) [c](#{other}/x) [d](#{base}1/x)")

    assert out =~ ~s(<a href="#{@path}">a</a>)
    assert out =~ ~s(<a href="/">b</a>)
    # Another host, though its name starts with this one's, and another port, are other sites.
    assert out =~ ~s(href="#{other}/x")
    assert out =~ ~s(href="#{base}1/x")
    assert length(String.split(out, "q-ticket-ext")) == 3
  end

  test "a link of this Qory Apiary has no icon in a list, a heading and under emphasis" do
    out = html("# [h](#{@path})\n\n- *[e](#{@path}/files/a.md)*\n- [x](https://example.com)")

    assert out =~ ~s(<h3><a href="#{@path}">h</a></h3>)
    assert out =~ ~s(<em><a href="#{@path}/files/a.md">e</a></em>)
    assert length(String.split(out, "q-ticket-ext")) == 2
  end

  test "a link or text with the marker host of a render is no link of this Qory Apiary" do
    # The renderer's token is random per render, so a document cannot write the marker
    # host: a link to an address like it is a link to another site, and text is text.
    fake = "qint" <> String.duplicate("0", 32) <> ".invalid"

    out = html("[a](https://#{fake}/x) https://#{fake}/y and `#{fake}` and #{fake}/z")

    assert out =~ ~s(<a href="https://#{fake}/x" target="_blank")
    assert out =~ "q-ticket-ext"
    assert out =~ "<code>#{fake}</code>"
    assert out =~ " and #{fake}/z"
    refute out =~ ~s(<a href="/x")
    refute out =~ ~s(<a href="/y")
  end

  test "a path with a character outside the allowed set, or an encoded slash, stays text" do
    for url <- [
          "/x>y",
          "/x'y",
          "/x\0y",
          "/x\x7Fy",
          "/x%2F%2Fevil",
          "/x%2fevil",
          "/x%5Cevil",
          "/x%5cevil",
          "/%2F%2Fevil.example",
          "/%5Cevil.example"
        ] do
      assert Markdown.site_path(url) == nil, inspect(url)
      refute html("[a](<#{url}>)") =~ "<a ", inspect(url)
    end
  end

  test "a path with a dot segment stays text, also as %2e" do
    for url <- [
          "/.//evil.example",
          "/./x",
          "/a/./b",
          "/a/../b",
          "/..",
          "/.",
          "/%2e//evil.example",
          "/%2E%2E/x",
          "/.%2e/x",
          "/a/%2e%2E",
          "/a/..?q=1",
          "/a/.#f"
        ] do
      assert Markdown.site_path(url) == nil, inspect(url)
      refute html("[a](<#{url}>)") =~ "<a ", inspect(url)
    end

    # A dot inside a name, or in the query or fragment, is no dot segment.
    for url <- ["/a.b/c", "/a/...", "/a/b.", "/a?q=/../x", "/a#/./x", "/.well-known/x"] do
      assert Markdown.site_path(url) == url, inspect(url)
    end
  end

  test "an absolute URL of this host and port keeps the rules of a path, the host exactly" do
    own = ApiaryWeb.Endpoint.struct_url()
    base = "#{own.scheme}://#{own.host}:#{own.port}"

    # A path of `//` start, a dot segment, a host with a trailing dot, or another scheme's
    # default port is another site: it keeps its icon.
    out =
      html(
        "[a](#{base}//evil.example) [b](#{base}/./x) [c](#{own.scheme}://#{own.host}.:#{own.port}/x) " <>
          "[d](#{own.scheme}://#{own.host}/x)"
      )

    assert length(String.split(out, "q-ticket-ext")) == 5
    refute out =~ ~s(<a href="/)

    # The host in another case is the same host.
    upper = "#{own.scheme}://#{String.upcase(own.host)}:#{own.port}"
    assert html("[a](#{upper}/x)") =~ ~s(<a href="/x">a</a>)
  end

  test "an entity in a link address is decoded before the check" do
    for text <- ["[a](/x&quot;y)", "[a](/x&#10;y)", "[a](/x&#9;y)", "[a](/x&#92;y)"] do
      out = html(text)
      refute out =~ "<a ", inspect(text)
    end

    # The same address with an entity that is a safe character is a link.
    assert html("[a](/x&amp;y)") =~ ~s(<a href="/x&amp;y">a</a>)
  end

  test "an image with a path is its words, never a link of this Qory Apiary" do
    out = html("![Form](/acme/main/work/7/artifacts/av_1/files/form.png)")

    refute out =~ "<a "
    refute out =~ "<img"
    assert out =~ "Image: Form"
  end

  test "site_path/1 takes a path that starts with one slash and the host of this Qory Apiary" do
    own = ApiaryWeb.Endpoint.struct_url()

    assert Markdown.site_path("/a") == "/a"
    assert Markdown.site_path("/a/b?x=1&y=2#f") == "/a/b?x=1&y=2#f"
    assert Markdown.site_path("/") == "/"
    assert Markdown.site_path("http://#{own.host}:#{own.port}/a?b#c") == "/a?b#c"
    assert Markdown.site_path("HTTP://#{String.upcase(own.host)}:#{own.port}") == "/"

    for url <- [
          "//example.com",
          "//example.com/x",
          "/\\example.com",
          "\\/example.com",
          "/\texample.com",
          "/ a",
          "/a\nb",
          "/a\"b",
          "/<a",
          "/é",
          "./x",
          "../x",
          "x",
          "",
          "?q",
          "#f",
          "javascript:alert(1)",
          "data:text/html,x",
          "mailto:a@example.com",
          "https://example.com/a",
          "https://a:b@#{own.host}:#{own.port}/a",
          "ftp://#{own.host}:#{own.port}/a",
          nil
        ] do
      assert Markdown.site_path(url) == nil, inspect(url)
    end
  end

  test "loads no image: it is a link with its words" do
    out = html("![Checkout form](https://example.com/form.png) ![](javascript:x)")

    refute out =~ "<img"
    assert out =~ ~s(<a href="https://example.com/form.png")
    assert out =~ "Image: Checkout form"
    refute out =~ "javascript:"
  end

  @images %{
    "checkout.svg" => "/acme/main/work/7/artifacts/av_1/files/checkout.svg",
    "invoice.png" => "/acme/main/work/7/artifacts/av_1/files/invoice.png"
  }

  defp html(text, images) do
    assert {:html, safe} = Markdown.render(text, images)
    Phoenix.HTML.safe_to_string(safe)
  end

  defp imgs(out), do: ~r/<img[^>]*>/ |> Regex.scan(out) |> List.flatten()

  describe "render/2, with the version's images" do
    test "shows an image of the version as <img> from its address" do
      out = html("Before ![Checkout form](checkout.svg) after", @images)

      assert imgs(out) == [
               ~s(<img src="/acme/main/work/7/artifacts/av_1/files/checkout.svg" alt="Checkout form">)
             ]

      refute out =~ "Image"
      refute out =~ "QIMG"
    end

    test "takes a list of pairs as a map, and the filename as alt where none is given" do
      out = html("![](invoice.png)", Map.to_list(@images))

      assert imgs(out) == [
               ~s(<img src="/acme/main/work/7/artifacts/av_1/files/invoice.png" alt="invoice.png">)
             ]
    end

    test "strips one leading ./ only, and matches no path" do
      out = html("![a](./checkout.svg) ![b](././checkout.svg) ![c](files/checkout.svg)", @images)

      assert imgs(out) == [
               ~s(<img src="/acme/main/work/7/artifacts/av_1/files/checkout.svg" alt="a">)
             ]

      assert out =~ "Image: b"
      assert out =~ "Image: c"
    end

    test "compares the filename byte for byte" do
      out = html("![a](Checkout.svg) ![b](checkout.svg%20)", @images)

      assert imgs(out) == []
      assert out =~ "Image not in this version: a"
      assert out =~ "Image not in this version: b"
    end

    test "loads no outside image: it stays a link with its words" do
      out =
        html("![Form](https://example.com/checkout.svg) ![x](data:image/png;base64,AA)", @images)

      assert imgs(out) == []
      assert out =~ ~s(<a href="https://example.com/checkout.svg")
      assert out =~ "Image: Form"
      refute out =~ "data:"
    end

    test "shows a filename of no image of the version as words, with its alt or name" do
      out = html("![Old wireframe](header.svg) ![](footer.svg)", @images)

      assert imgs(out) == []
      assert out =~ "Image not in this version: Old wireframe"
      assert out =~ "Image not in this version: footer.svg"
    end

    test "a proposal version with no images: a filename is not in this version" do
      out = html("![Form](checkout.svg) ![](footer.svg)", [])

      assert imgs(out) == []
      assert out =~ "Image not in this version: Form"
      assert out =~ "Image not in this version: footer.svg"
    end

    test "a text of no proposal version (nil, and render/1): a filename stays its words" do
      for out <- [html("![Form](checkout.svg)", nil), html("![Form](checkout.svg)")] do
        assert imgs(out) == []
        assert out =~ "Image: Form"
        refute out =~ "not in this version"
      end
    end

    test "shows an image of the version inside a link, and the link once" do
      out = html("[![Form](checkout.svg)](https://example.com/form)", @images)

      assert out =~ ~s(<a href="https://example.com/form")

      assert imgs(out) == [
               ~s(<img src="/acme/main/work/7/artifacts/av_1/files/checkout.svg" alt="Form">)
             ]

      assert [_one] = Regex.scan(~r/<a /, out)
    end

    test "a placeholder written in the document stays text" do
      name = Base.encode16("checkout.svg", case: :lower)
      written = "QIMG#{String.duplicate("0", 32)}#{name}X#{Base.encode16("a", case: :lower)}Z"
      out = html("#{written} and `#{written}`", @images)

      assert imgs(out) == []
      assert out =~ written
    end

    test "escapes the address and the alt" do
      images = %{"a.svg" => ~s(/acme/files/a.svg?x="1"&y=<2>)}
      out = html(~s|![Say "hi" <b>&</b>](a.svg)|, images)

      assert [img] = imgs(out)
      assert img =~ ~s(src="/acme/files/a.svg?x=&quot;1&quot;&amp;y=&lt;2&gt;")
      refute img =~ "<b>"
      assert img =~ ~s(alt="Say &quot;hi&quot;)
    end
  end

  test "marks a Mermaid block for the hook, its text escaped" do
    out =
      html("```mermaid\nflowchart LR\n  A[<b>Cart</b>] --> B\n```\n\n```elixir\nIO.puts(1)\n```")

    assert out =~ ~s(<pre class="q-mermaid-source"><code>flowchart LR)
    assert out =~ "A[&lt;b&gt;Cart&lt;/b&gt;]"
    refute out =~ "<b>"
    assert out =~ "<pre><code>IO.puts(1)"
    refute out =~ "language-"
  end

  test "moves headings down two levels" do
    out = html("# One\n\n## Two\n\n#### Four")
    assert out =~ "<h3>One</h3>"
    assert out =~ "<h4>Two</h4>"
    assert out =~ "<h6>Four</h6>"
  end

  test "is too large past max_bytes, and shows a text past the other bounds, or not UTF-8, as written" do
    assert Markdown.render(String.duplicate("a", Markdown.max_bytes() + 1)) == :too_large
    assert {:as_written, "\uFFFD# a"} = Markdown.render(<<0xFF, "# a">>)

    deep = String.duplicate(">", Markdown.max_depth() + 5) <> " deep"
    assert {:as_written, _text} = Markdown.render(deep)
  end

  # Each of these texts of `max_bytes/0` makes a parse, or the conversion as written, hold
  # far more than 64 MiB. Both run within the budget, in another process, so the page's
  # process needs little more than the text, and the text is too large to show.
  test "is too large to show when the render needs more than the budget" do
    max = Markdown.max_bytes()

    for text <- [
          String.duplicate("# a\n", div(max, 4)),
          String.duplicate(<<1>>, max),
          String.duplicate("\x01\n", div(max, 2))
        ] do
      assert capped(fn -> Markdown.render(text) end, 2_097_152) == :too_large
    end
  end

  test "is too large to show for 1 MiB of control or invisible characters" do
    for text <- [
          String.duplicate(<<1>>, 1_048_576),
          String.duplicate("\x01\n", 524_288),
          String.duplicate("\u200B", 349_525)
        ] do
      assert capped(fn -> Markdown.render(text) end, 2_097_152) == :too_large
    end
  end

  # A text of `max_bytes/0` lines is checked for tables in one pass that builds no list of
  # its lines, within the budget, so the page's process needs little more than the text.
  test "checks a text of many lines for tables within 16 MiB of heap" do
    max = Markdown.max_bytes()

    for text <- [String.duplicate("\n", max), String.duplicate("|\r\n", div(max, 3))] do
      assert {kind, _shown} = capped(fn -> Markdown.render(text) end, 2_097_152)
      assert kind in [:html, :as_written]
    end
  end

  test "counts the cells of the line with the most |" do
    assert {:as_written, _text} =
             Markdown.render(String.duplicate("| a |\n", div(Markdown.max_cells(), 2)))

    assert {:html, _html} = Markdown.render("| a | b |\r|---|---|\r\n| 1 | 2 |")
  end

  # The value of `fun`, run in a process whose heap may have at most `words` words.
  defp capped(fun, words) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(parent, {self(), fun.()}) end, [
        :monitor,
        {:max_heap_size, %{size: words, kill: true, error_logger: false}}
      ])

    receive do
      {^pid, value} ->
        Process.demonitor(ref, [:flush])
        value

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("the render passed the heap cap: #{inspect(reason)}")
    after
      30_000 -> flunk("the render took longer than 30 s")
    end
  end

  test "link?/1 takes absolute http and https URLs and mailto addresses" do
    assert Markdown.link?("https://example.com")
    assert Markdown.link?("HTTP://example.com/x")
    assert Markdown.link?("mailto:dana@example.com")

    for url <- [
          "javascript:alert(1)",
          "//example.com",
          "/a",
          "https://",
          "mailto:",
          "ftp://x",
          nil
        ] do
      refute Markdown.link?(url), inspect(url)
    end
  end
end
