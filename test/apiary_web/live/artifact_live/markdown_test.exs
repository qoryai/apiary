defmodule ApiaryWeb.ArtifactLive.MarkdownTest do
  # The Markdown of a document artifact as its view shows it
  # (`ApiaryWeb.ArtifactLive.Markdown`): no raw HTML, links of http, https and mailto
  # only, no image loaded, headings two levels down, Mermaid blocks marked for the hook,
  # and texts past the bounds as written.
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
      [js](javascript:alert(1)) [data](data:text/html,x) [rel](/admin) [user](https://a:b@example.com)
      """)

    assert out =~ ~s(href="https://example.com/a")
    assert out =~ ~s(href="http://example.com/b")
    assert out =~ ~s(href="mailto:dana@example.com")
    refute out =~ "javascript:"
    refute out =~ "data:"
    refute out =~ ~s(href="/admin")
    refute out =~ "a:b@"
    assert out =~ "js"
    assert out =~ ~s(rel="nofollow noopener noreferrer")
  end

  test "loads no image: it is a link with its words" do
    out = html("![Checkout form](https://example.com/form.png) ![](javascript:x)")

    refute out =~ "<img"
    assert out =~ ~s(<a href="https://example.com/form.png")
    assert out =~ "Image: Checkout form"
    refute out =~ "javascript:"
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

  test "shows a text past the bounds, or not UTF-8, as written" do
    assert {:as_written, _text} = Markdown.render(String.duplicate("a", Markdown.max_bytes() + 1))
    assert {:as_written, _text} = Markdown.render(<<0xFF, "# a">>)

    deep = String.duplicate(">", Markdown.max_depth() + 5) <> " deep"
    assert {:as_written, _text} = Markdown.render(deep)
  end

  # Each of these texts of 1 MiB makes a parse hold hundreds of MiB. The render runs in a
  # process whose heap may not pass 32 MiB, so the parse cannot happen there.
  test "shows a text whose parse needs more than the budget as written" do
    for text <- [String.duplicate("> ", 524_288), String.duplicate("# a\n", 262_144)] do
      assert {:as_written, _text} = capped(fn -> Markdown.render(text) end)
    end
  end

  # The value of `fun`, run in a process whose heap may hold at most 32 MiB.
  defp capped(fun) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(parent, {self(), fun.()}) end, [
        :monitor,
        {:max_heap_size, %{size: 4_194_304, kill: true, error_logger: false}}
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
