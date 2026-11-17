defmodule ApiaryWeb.ArtifactLive.Markdown do
  # The Markdown of a document artifact (`Apiary.Artifacts.Type`, base view `document`),
  # as its view shows it (`ApiaryWeb.ArtifactComponents.view/1`). An artifact is untrusted
  # data: a run or a person wrote it, so nothing of it reaches the page as markup.
  #
  # `render/2` takes the file's text and the version's images, and returns
  # `{:html, safe}`, `{:as_written, text}` or `:too_large`:
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
  #   * An image of the version is shown: `render/2` takes `images`, a map (or a list of
  #     pairs) from a filename of a proposal version's images to its download address, or
  #     nil for a text of no such version. An image whose URL,
  #     one leading `./` stripped, equals one of those filenames byte for byte, with no
  #     `/`, is `<img src="<address>" alt="<alt>">`, both escaped; its alt is the
  #     filename where it has none (`Apiary.ExternalText.present_lines/1`). The renderer
  #     writes a placeholder of a random token per render in its place and swaps it for
  #     the `<img>` after sanitising, so no markup of the document reaches the page.
  #   * Any other image is never loaded. It is a link to its URL, where the URL may be a
  #     link, whose words are "Image: <alt>", or "Image" with no alt text. Where `images`
  #     is not nil, even empty, a filename of none of them (no `/` and no `:`) is the
  #     words "Image not in this version: <alt>", the filename where it has no alt text.
  #   * Headings move down two levels, so the document's `#` is an `h3` under the page's
  #     `h1` and `h2`.
  #   * A code block whose language is `mermaid` becomes
  #     `<pre class="q-mermaid-source"><code>…</code></pre>`, its text escaped; the
  #     Mermaid hook draws it in the browser (`assets/js/hooks/mermaid.js`).
  #   * A code block whose language is `diff` is the diff box of the harness update page
  #     (`q-diffbox`, in `diff_box/1`): a bar with the path of the block's `+++` header
  #     (`---` for a file with none; `a/` and `b/` stripped) and the number of changed
  #     lines (in each run of `+` and `-` lines, the larger of the two counts), then the lines, with the `---`, `+++` and
  #     `@@` header lines left out. Every line is escaped, as the box is written after
  #     sanitising, in place of a placeholder of the same random token as an image's.
  #
  # The HTML is sanitised last, on the server, by an allowlist of tags, attributes and
  # classes, with `http`, `https` and `mailto` the only URL schemes and no relative URL.
  #
  # The work is bounded by the input and by a budget. A text over `max_bytes/0` bytes is
  # `:too_large`, and is not read at all (`ApiaryWeb.ArtifactLive.Load.content/3`). Every
  # other step runs in another process within `budget/0` (`Apiary.Kinds.Budget`): a heap
  # of at most 64 MiB, 100,000,000 reductions and 10 s. There, a text with more table
  # cells than `max_cells/0`, nested deeper than `max_depth/0`, or not valid UTF-8 is
  # converted as written (`Apiary.ExternalText.lines/1`) to `{:as_written, text}`, which
  # a page interpolates, so HEEx escapes it; any other text is parsed, walked and written
  # as HTML. A render that passes the budget, in either step, is `:too_large`. Measured on
  # OTP 29: 384 KiB of prose with links, emphasis and code fits; 512 KiB of it needs more
  # heap, and so do 262,144 headings of one letter (about 600 MiB), 524,288 nested quote
  # marks, and the conversion as written of 1 MiB of control characters (over 500 MiB); at
  # 256 KiB, the headings and the control characters still pass it.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  # 256 KiB: MDEx allocates outside the heap that the budget checks, so one budgeted render
  # of 1 MiB still raised the VM's peak by 149 to 183 MiB.
  @max_bytes 262_144
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
  @diff_context_header ~w(diff index new deleted similarity rename old copy Binary)

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

  # render/2 is the document `text` as the view shows it, with `images`, a map or a list
  # of pairs from a filename of a proposal version's images to its download address, or
  # nil for a text of no such version: `{:html, safe}`; `{:as_written, text}` for a text
  # it does not format; or `:too_large` for a text over `max_bytes/0` bytes or one whose
  # render passes the budget. `render/1` is `render(text, nil)`.
  @doc false
  @spec render(binary, Enumerable.t() | nil) ::
          {:html, Phoenix.HTML.safe()} | {:as_written, String.t()} | :too_large
  def render(text, images \\ nil)

  def render(text, _images) when is_binary(text) and byte_size(text) > @max_bytes,
    do: :too_large

  def render(text, images) when is_binary(text) do
    images = if images == nil, do: nil, else: Map.new(images)

    case budgeted(text, images) do
      {:ok, {:html, html}} -> {:html, Phoenix.HTML.raw(html)}
      {:ok, {:as_written, written}} -> {:as_written, written}
      {:error, _passed} -> :too_large
    end
  end

  # The words the HTML adds, such as "Not done", are in the reader's language and domain:
  # the process takes the caller's Gettext locale, as `ApiaryWeb.Async` does.
  defp budgeted(text, images) do
    locale = Gettext.get_locale()

    Apiary.Kinds.Budget.run(
      fn ->
        Gettext.put_locale(locale)
        shown(text, images)
      end,
      @budget
    )
  end

  # The text as HTML, or as written where it is not formatted; run within the budget.
  defp shown(text, images) do
    with true <- formattable?(text),
         {:ok, html} <- markdown(text, images) do
      {:html, html}
    else
      _not -> {:as_written, Apiary.ExternalText.lines(text)}
    end
  end

  # budget/0 is what one render may take (`Apiary.Kinds.Budget`).
  @doc false
  @spec budget() :: Apiary.Kinds.Budget.budget()
  def budget, do: @budget

  defp formattable?(text), do: String.valid?(text) and table_cells(text) <= @max_cells

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

  defp markdown(text, images) do
    document = MDEx.parse_document!(text, @parse_options)
    # The placeholders' token: random per render, so no document can write one.
    token = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    context = %{in_link: false, images: images, token: token}

    case walk_document(document.nodes, context) do
      {:ok, nodes} ->
        {:ok, document |> Map.put(:nodes, nodes) |> html() |> images(context) |> diffs(context)}

      :too_deep ->
        :too_deep
    end
  end

  defp walk_document(nodes, context) do
    {:ok, walk(nodes, context, 1)}
  catch
    :too_deep -> :too_deep
  end

  # An image of the version is the text `QIMG<token><filename>X<alt>Z`, filename and alt
  # in lowercase hexadecimal, which the renderer and the sanitiser leave as it is.
  defp placeholder(token, filename, alt),
    do:
      "QIMG" <>
        token <>
        Base.encode16(filename, case: :lower) <> "X" <> Base.encode16(alt, case: :lower) <> "Z"

  # Each placeholder, after sanitising, as its `<img>`: the address of a filename of
  # `images` and the alt, both escaped.
  defp images(html, %{images: images, token: token})
       when is_map(images) and map_size(images) > 0 do
    Regex.replace(~r/QIMG#{token}([0-9a-f]*)X([0-9a-f]*)Z/, html, fn whole, name, alt ->
      with {:ok, filename} <- Base.decode16(name, case: :lower),
           {:ok, path} when is_binary(path) <- Map.fetch(images, filename),
           {:ok, alt} <- Base.decode16(alt, case: :lower) do
        ~s(<img src="#{escape(path)}" alt="#{escape(alt)}">)
      else
        _not -> whole
      end
    end)
  end

  defp images(html, _context), do: html

  # A diff block is the text `QDIFF<token><text>Z` in a paragraph, the text in lowercase
  # hexadecimal, which the renderer and the sanitiser leave as it is.
  defp diff_placeholder(token, text),
    do: "QDIFF" <> token <> Base.encode16(text, case: :lower) <> "Z"

  # Each placeholder, after sanitising, as its diff box.
  defp diffs(html, %{token: token}) do
    Regex.replace(~r{(?:<p>)?QDIFF#{token}([0-9a-f]*)Z(?:</p>)?}, html, fn whole, hex ->
      case Base.decode16(hex, case: :lower) do
        {:ok, text} -> diff_box(text)
        :error -> whole
      end
    end)
  end

  # diff_box/1 is `text`, a unified diff, as the box of the harness update page, in the
  # markup of its panel: the path and the number of changed lines in the bar, then a row
  # per line. A `--- ` line followed by a `+++ ` line is a file header, as is a line
  # starting `@@`, `diff `, `index ` or the like; none is a row, nor is a `+++ ` line before
  # the first row. A line of `+` or `-` is an added or a removed line, another line is
  # context, with its one leading space left out.
  defp diff_box(text) do
    {path, rows} = diff_rows(String.split(text, ~r/\r\n|\r|\n/), nil, nil, [])
    changed = changed_lines(rows)

    count =
      ngettext("%{count} line changed", "%{count} lines changed", changed)

    lines = Enum.map_join(rows, &diff_row/1)

    ~s(<div class="q-diffbox q-diffbox-flat"><div class="q-dpanel">) <>
      ~s(<div><span>#{escape(path || "")}</span><span>#{escape(count)}</span></div>) <>
      ~s(<div class="q-dlines" tabindex="0">#{lines}</div></div></div>)
  end

  # The changed lines: in each run of added and removed lines between context lines, the
  # larger of the two counts, so a line that was replaced is one line changed.
  defp changed_lines(rows) do
    rows
    |> Enum.chunk_by(&(elem(&1, 0) == :ctx))
    |> Enum.reject(&match?([{:ctx, _line} | _], &1))
    |> Enum.sum_by(fn run ->
      added = Enum.count(run, &match?({:add, _line}, &1))
      max(added, length(run) - added)
    end)
  end

  defp diff_row({:add, line}), do: ~s(<div class="q-add"><i>+</i>#{escape(line)}</div>)
  defp diff_row({:del, line}), do: ~s(<div class="q-del"><i>-</i>#{escape(line)}</div>)
  defp diff_row({:ctx, line}), do: ~s(<div class="q-ctx"><i></i>#{escape(line)}</div>)

  # The path and the rows of the lines; `old` and `new` are the paths of the first file
  # header. The empty line a text ends with is no row.
  defp diff_rows([], old, new, rows) do
    rows = rows |> Enum.reverse() |> drop_last_empty()
    {diff_path(new) || diff_path(old), rows}
  end

  defp diff_rows(["--- " <> old, "+++ " <> new | rest], old0, new0, rows),
    do: diff_rows(rest, old0 || old, new0 || new, rows)

  defp diff_rows(["+++ " <> new | rest], old, new0, []),
    do: diff_rows(rest, old, new0 || new, [])

  defp diff_rows(["@@" <> _hunk | rest], old, new, rows), do: diff_rows(rest, old, new, rows)
  defp diff_rows(["\\" <> _note | rest], old, new, rows), do: diff_rows(rest, old, new, rows)

  defp diff_rows(["+" <> line | rest], old, new, rows),
    do: diff_rows(rest, old, new, [{:add, line} | rows])

  defp diff_rows(["-" <> line | rest], old, new, rows),
    do: diff_rows(rest, old, new, [{:del, line} | rows])

  defp diff_rows([" " <> line | rest], old, new, rows),
    do: diff_rows(rest, old, new, [{:ctx, line} | rows])

  defp diff_rows([line | rest], old, new, rows) do
    if diff_header?(line, rows),
      do: diff_rows(rest, old, new, rows),
      else: diff_rows(rest, old, new, [{:ctx, line} | rows])
  end

  # A `diff --git`, `index` or mode line before the first row is a header.
  defp diff_header?(line, []) do
    case String.split(line, " ", parts: 2) do
      [word, _rest] -> word in @diff_context_header
      _one -> false
    end
  end

  defp diff_header?(_line, _rows), do: false

  defp drop_last_empty([]), do: []

  defp drop_last_empty(rows) do
    case List.last(rows) do
      {:ctx, ""} -> Enum.drop(rows, -1)
      _row -> rows
    end
  end

  # The path of a `---` or `+++` header: with no timestamp after a tab, no `a/` or `b/`,
  # and nil for none or `/dev/null`.
  defp diff_path(nil), do: nil

  defp diff_path(header) do
    path = header |> String.split("\t", parts: 2) |> hd() |> String.trim()

    case path do
      "" -> nil
      "/dev/null" -> nil
      "a/" <> rest when rest != "" -> rest
      "b/" <> rest when rest != "" -> rest
      other -> other
    end
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
  # its words and raw HTML nothing. `context` has the version's `images`, the
  # placeholders' `token`, and `in_link`: under a link, an image that is not of the
  # version is its words, so no link is ever inside another. Past `@max_depth`, it
  # throws `:too_deep`.
  defp walk(_nodes, _context, depth) when depth > @max_depth, do: throw(:too_deep)
  defp walk(nodes, context, depth), do: Enum.flat_map(nodes, &shown(&1, context, depth))

  defp shown(%MDEx.HtmlBlock{}, _context, _depth), do: []
  defp shown(%MDEx.HtmlInline{}, _context, _depth), do: []
  defp shown(%MDEx.Raw{}, _context, _depth), do: []

  defp shown(%MDEx.Heading{} = heading, context, depth) do
    level = min(heading.level + 2, 6)
    [%{heading | level: level, nodes: walk(heading.nodes, context, depth + 1)}]
  end

  defp shown(%MDEx.Link{url: url} = link, context, depth) do
    if link?(url) and not context.in_link,
      do: [
        %{link | title: "", nodes: walk(link.nodes, %{context | in_link: true}, depth + 1)}
      ],
      else: walk(link.nodes, context, depth + 1)
  end

  defp shown(%MDEx.Image{url: url} = image, context, _depth) do
    alt = image.nodes |> plain_text() |> Apiary.ExternalText.present_lines()
    at = image.sourcepos
    filename = filename(url)
    # The words for the image: its alt text, else its filename as an external text.
    label = alt || (filename && Apiary.ExternalText.present_lines(filename))

    cond do
      filename != nil and is_map(context.images) and Map.has_key?(context.images, filename) ->
        literal = placeholder(context.token, filename, label || "")
        [%MDEx.Text{literal: literal, sourcepos: at}]

      label != nil and filename != nil and is_map(context.images) and
          not String.contains?(filename, ":") ->
        words = gettext("Image not in this version: %{alt}", alt: label)
        [%MDEx.Text{literal: words, sourcepos: at}]

      true ->
        words =
          if alt == nil,
            do: gettext("Image"),
            else: gettext("Image: %{alt}", alt: alt)

        text = [%MDEx.Text{literal: words, sourcepos: at}]

        if link?(url) and not context.in_link,
          do: [%MDEx.Link{url: url, title: "", nodes: text, sourcepos: at}],
          else: text
    end
  end

  # A code block keeps only the first word of its info string, so its class is
  # `language-<word>` and a Mermaid block's is `language-mermaid` exactly. A `diff` block
  # is a placeholder for its box.
  defp shown(%MDEx.CodeBlock{literal: literal, info: info} = block, context, _depth) do
    language = info |> to_string() |> String.split(~r/\s/, parts: 2) |> hd()
    text = Apiary.ExternalText.lines(literal)

    if language == "diff" do
      placeholder = %MDEx.Text{literal: diff_placeholder(context.token, text)}
      [%MDEx.Paragraph{nodes: [placeholder], sourcepos: block.sourcepos}]
    else
      [%{block | literal: text, info: if(language == "mermaid", do: "mermaid", else: "")}]
    end
  end

  defp shown(%{nodes: nodes} = node, context, depth) when is_list(nodes),
    do: [%{node | nodes: walk(nodes, context, depth + 1)}]

  defp shown(%{literal: literal} = node, _context, _depth) when is_binary(literal),
    do: [%{node | literal: Apiary.ExternalText.lines(literal)}]

  defp shown(node, _context, _depth), do: [node]

  # The filename an image's URL refers to, one leading `./` stripped: nil where it is
  # empty or has a `/`, so an address of another path is none.
  defp filename(url) when is_binary(url) do
    name =
      case url do
        "./" <> rest -> rest
        url -> url
      end

    if name == "" or String.contains?(name, "/"), do: nil, else: name
  end

  defp filename(_url), do: nil

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
