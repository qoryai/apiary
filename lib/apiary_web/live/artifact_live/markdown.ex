defmodule ApiaryWeb.ArtifactLive.Markdown do
  # The Markdown of a document artifact (`Apiary.Artifacts.Type`, base view `document`),
  # as its view shows it (`ApiaryWeb.ArtifactComponents.view/1`). An artifact is untrusted
  # data: a run or a person wrote it, so nothing of it reaches the page as markup.
  #
  # `render/1` takes the file's text and returns `{:html, safe}` or `{:as_written, text}`:
  #
  #   * The text is parsed as GitHub Flavored Markdown: tables, strikethrough, autolinks
  #     and task lists. Raw HTML is never rendered (`unsafe: false`), and its blocks and
  #     inline tags are dropped from the parsed document, so `<script>` is no element and
  #     no text.
  #   * The words of the document, its text, code and an image's alt text, are shown as
  #     an external system's text of several lines is (`Apiary.ExternalText.lines/1`).
  #   * A link keeps its address only where it is an absolute `http` or `https` URL with a
  #     host and no user name or password, or a `mailto:` address; any other link is its
  #     text, unlinked. A link's title is dropped, and a link opens in a new tab with
  #     `rel="nofollow noopener noreferrer"`.
  #   * An image is never loaded. It is a link to its URL, where the URL may be a link,
  #     whose words are "Image: <alt>", or "Image" with no alt text.
  #   * Headings move down two levels, so the document's `#` is an `h3` under the page's
  #     `h1` and `h2`.
  #   * A code block whose language is `mermaid` becomes
  #     `<pre class="q-mermaid-source"><code>…</code></pre>`, its text escaped; the
  #     Mermaid hook draws it in the browser (`assets/js/hooks/mermaid.js`).
  #
  # The HTML is sanitised last, on the server, by an allowlist of tags, attributes and
  # classes, with `http`, `https` and `mailto` the only URL schemes and no relative URL.
  #
  # The work is bounded by the input and by a budget. A text over `max_bytes/0` bytes,
  # with more table cells than `max_cells/0`, nested deeper than `max_depth/0`, or not
  # valid UTF-8, is `{:as_written, text}`, which a page interpolates, so HEEx escapes it.
  # The parse, the walk and the HTML run in another process within `budget/0`
  # (`Apiary.Kinds.Budget`): a heap of at most 64 MiB, 100,000,000 reductions and 10 s.
  # Past the budget the text is `{:as_written, text}`. Measured on OTP 29: 384 KiB of
  # prose with links, emphasis and code fits; 512 KiB of it needs more heap, and so do
  # 262,144 headings of one letter (about 600 MiB) and 524,288 nested quote marks. A
  # file over `max_bytes/0` is not read at all (`ApiaryWeb.ArtifactLive.Load.content/2`).
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  @max_bytes 1_048_576
  @max_cells 50_000
  @max_depth 128

  # What one render may take (`Apiary.Kinds.Budget`): 64 MiB of heap, in 8-byte words.
  @budget [heap_words: 8_388_608, reductions: 100_000_000, ms: 10_000]

  @parse_options [
    extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
    render: [unsafe: false],
    syntax_highlight: nil
  ]

  # What the renderer writes, with `unsafe` off, for a task box and a Mermaid block: no
  # text of the document can write a `<` there, so these are the renderer's alone.
  @box_done ~s(<input type="checkbox" checked="" disabled="" /> )
  @box_open ~s(<input type="checkbox" disabled="" /> )
  @mermaid_open ~s(<pre><code class="language-mermaid">)
  @link_end "</a>"

  @sanitize [
    tags: ~w(a blockquote br code del em h3 h4 h5 h6 hr li ol p pre span strong table
             tbody td th thead tr ul),
    clean_content_tags: ~w(script style),
    tag_attributes: %{
      "a" => ~w(href),
      "ol" => ~w(start),
      "td" => ~w(align),
      "th" => ~w(align)
    },
    tag_attribute_values: %{"span" => %{"aria-hidden" => ["true"]}},
    set_tag_attribute_values: %{
      "a" => %{"target" => "_blank"},
      "th" => %{"scope" => "col"}
    },
    allowed_classes: %{
      "pre" => ~w(q-mermaid-source),
      "span" => ~w(sr-only q-task-mark q-ticket-ext hero-arrow-top-right-on-square-micro)
    },
    generic_attributes: [],
    generic_attribute_prefixes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "nofollow noopener noreferrer",
    strip_comments: true
  ]

  # max_bytes/0 is the largest text, in bytes, that `render/1` formats.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  # max_cells/0 is the most table cells a text that `render/1` formats may ask for.
  @doc false
  @spec max_cells() :: pos_integer
  def max_cells, do: @max_cells

  # max_depth/0 is how deep the blocks and inlines of a text that `render/1` formats may
  # nest.
  @doc false
  @spec max_depth() :: pos_integer
  def max_depth, do: @max_depth

  # render/1 is the document `text` as the view shows it: `{:html, safe}`, or
  # `{:as_written, text}` for a text `render/1` does not format.
  @doc false
  @spec render(binary) :: {:html, Phoenix.HTML.safe()} | {:as_written, String.t()}
  def render(text) when is_binary(text) do
    with true <- formattable?(text),
         {:ok, {:ok, html}} <- budgeted(text) do
      {:html, Phoenix.HTML.raw(html)}
    else
      _not -> {:as_written, Apiary.ExternalText.lines(text)}
    end
  end

  # The words the HTML adds, such as "Not done", are in the reader's language and domain:
  # the process takes the caller's Gettext locale, as `ApiaryWeb.Async` does.
  defp budgeted(text) do
    locale = Gettext.get_locale()

    Apiary.Kinds.Budget.run(
      fn ->
        Gettext.put_locale(locale)
        markdown(text)
      end,
      @budget
    )
  end

  # budget/0 is what one render may take (`Apiary.Kinds.Budget`).
  @doc false
  @spec budget() :: Apiary.Kinds.Budget.budget()
  def budget, do: @budget

  defp formattable?(text),
    do: byte_size(text) <= @max_bytes and String.valid?(text) and table_cells(text) <= @max_cells

  # The most cells a table of the text could have: a row is a line, and has as many
  # cells as the line with the most `|` has, plus one. With no `|`, there is no table.
  # One pass over the bytes that builds no list: the text runs in the page's process,
  # outside the budget, and a list of its lines would take more memory than the text.
  defp table_cells(text) do
    case scan(text, 0, 0, 1) do
      {0, _lines} -> 0
      {pipes, lines} -> (pipes + 1) * lines
    end
  end

  # The most `|` on one line, and the lines, by `\r\n`, `\r` or `\n`.
  defp scan(<<"\r\n", rest::binary>>, here, most, lines),
    do: scan(rest, 0, max(here, most), lines + 1)

  defp scan(<<byte, rest::binary>>, here, most, lines) when byte in [?\r, ?\n],
    do: scan(rest, 0, max(here, most), lines + 1)

  defp scan(<<?|, rest::binary>>, here, most, lines), do: scan(rest, here + 1, most, lines)
  defp scan(<<_byte, rest::binary>>, here, most, lines), do: scan(rest, here, most, lines)
  defp scan(<<>>, here, most, lines), do: {max(here, most), lines}

  defp markdown(text) do
    document = MDEx.parse_document!(text, @parse_options)

    case walk_document(document.nodes) do
      {:ok, nodes} -> {:ok, html(%{document | nodes: nodes})}
      :too_deep -> :too_deep
    end
  end

  defp walk_document(nodes) do
    {:ok, walk(nodes, false, 1)}
  catch
    :too_deep -> :too_deep
  end

  defp html(document) do
    document
    |> MDEx.to_html!()
    |> String.replace(@box_done, box("☑", gettext("Done")))
    |> String.replace(@box_open, box("☐", gettext("Not done")))
    |> String.replace(@mermaid_open, ~s(<pre class="q-mermaid-source"><code>))
    |> String.replace(@link_end, link_end())
    |> MDEx.safe_html(sanitize: sanitize(), escape: [content: false, curly_braces_in_code: false])
  end

  defp sanitize do
    table = %{"aria-label" => gettext("Table in the document")}
    update_in(@sanitize[:set_tag_attribute_values], &Map.put(&1, "table", table))
  end

  defp box(mark, words) do
    ~s(<span class="q-task-mark" aria-hidden="true">#{mark}</span>) <>
      ~s(<span class="sr-only">#{escape(words)}</span> )
  end

  defp link_end do
    icon = "q-ticket-ext hero-arrow-top-right-on-square-micro"
    words = escape(gettext("(opens in a new tab)"))

    ~s(<span class="#{icon}" aria-hidden="true"></span>) <>
      ~s(<span class="sr-only"> #{words}</span></a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # Each node, and those under it, as the view shows them: a list, as a link may become
  # its words and raw HTML nothing. Under a link (`in_link`), an image is its words, so no
  # link is ever inside another. Past `@max_depth`, it throws `:too_deep`.
  defp walk(_nodes, _in_link, depth) when depth > @max_depth, do: throw(:too_deep)
  defp walk(nodes, in_link, depth), do: Enum.flat_map(nodes, &shown(&1, in_link, depth))

  defp shown(%MDEx.HtmlBlock{}, _in_link, _depth), do: []
  defp shown(%MDEx.HtmlInline{}, _in_link, _depth), do: []
  defp shown(%MDEx.Raw{}, _in_link, _depth), do: []

  defp shown(%MDEx.Heading{} = heading, in_link, depth) do
    level = min(heading.level + 2, 6)
    [%{heading | level: level, nodes: walk(heading.nodes, in_link, depth + 1)}]
  end

  defp shown(%MDEx.Link{url: url} = link, in_link, depth) do
    if link?(url) and not in_link,
      do: [%{link | title: "", nodes: walk(link.nodes, true, depth + 1)}],
      else: walk(link.nodes, in_link, depth + 1)
  end

  defp shown(%MDEx.Image{url: url} = image, in_link, _depth) do
    alt = image.nodes |> plain_text() |> Apiary.ExternalText.present_lines()

    words =
      if alt == nil,
        do: gettext("Image"),
        else: gettext("Image: %{alt}", alt: alt)

    at = image.sourcepos
    text = [%MDEx.Text{literal: words, sourcepos: at}]

    if link?(url) and not in_link,
      do: [%MDEx.Link{url: url, title: "", nodes: text, sourcepos: at}],
      else: text
  end

  # A code block keeps only the first word of its info string, so its class is
  # `language-<word>` and a Mermaid block's is `language-mermaid` exactly.
  defp shown(%MDEx.CodeBlock{literal: literal, info: info} = block, _in_link, _depth) do
    language = info |> to_string() |> String.split(~r/\s/, parts: 2) |> hd()

    [
      %{
        block
        | literal: Apiary.ExternalText.lines(literal),
          info: if(language == "mermaid", do: "mermaid", else: "")
      }
    ]
  end

  defp shown(%{nodes: nodes} = node, in_link, depth) when is_list(nodes),
    do: [%{node | nodes: walk(nodes, in_link, depth + 1)}]

  defp shown(%{literal: literal} = node, _in_link, _depth) when is_binary(literal),
    do: [%{node | literal: Apiary.ExternalText.lines(literal)}]

  defp shown(node, _in_link, _depth), do: [node]

  defp plain_text(nodes) do
    nodes
    |> Enum.map(fn
      %MDEx.HtmlInline{} -> ""
      %{literal: literal} when is_binary(literal) -> literal
      %{nodes: nodes} when is_list(nodes) -> plain_text(nodes)
      %MDEx.SoftBreak{} -> " "
      %MDEx.LineBreak{} -> " "
      _other -> ""
    end)
    |> Enum.join()
  end

  # link?/1 is whether `url` may be a link of a document: an absolute `http` or `https`
  # URL with a host and no user name or password, or a `mailto:` address with something
  # after the colon. Anything else, nil included, is false.
  @doc false
  @spec link?(term) :: boolean
  def link?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} when is_binary(scheme) ->
        case String.downcase(scheme) do
          web when web in ["http", "https"] -> is_binary(host) and host != ""
          "mailto" -> String.length(url) > 7 and not String.contains?(url, ["\\", " "])
          _other -> false
        end

      _not ->
        false
    end
  end

  def link?(_url), do: false
end
