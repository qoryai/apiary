defmodule Apiary.Sources.Body do
  # A ticket's text, as the console shows it. The text is kept as the integration sent
  # it, and that is what an agent reads; this only decides how a page shows it. Kept out
  # of the generated documentation, which every instance serves.
  #
  # `render/2` takes the text and its format, `"markdown"` or `"text"`. Markdown comes
  # back as safe HTML, formatted. Any other format, nil included, comes back as
  # `{:as_written, text}`, the text unchanged, which a page interpolates, so HEEx escapes
  # it.
  #
  # The HTML is the one place the console shows markup it did not write
  # (`ApiaryWeb.SourceComponents.body/1`, docs/ui.md). It is made so:
  #
  #   * The text is parsed as GitHub Flavored Markdown: tables, strikethrough, autolinks
  #     and task lists. Raw HTML is not rendered, as markup or as text: its blocks and
  #     inline tags are dropped from the parsed document, and the renderer leaves out any
  #     left.
  #   * A link whose URL is not an absolute `https` one with a host and no user name or
  #     password is its text, unlinked: `http`, `javascript:`, `data:`, `vbscript:`,
  #     `mailto:`, a relative or `//` URL, or one that does not parse. By choice, so is
  #     one with a port past 65535, or whose host is not a plain name or IPv4 address: a
  #     host with `%`, outside ASCII or in punycode, an IPv6 address, or a number that is
  #     no IPv4 address of four parts. That is stricter than the sanitiser's URL parser,
  #     which refuses some of these, so a link that is kept always keeps its address. A
  #     link's title is dropped.
  #   * An image is never shown. It is a link to its URL whose words are "Image: <alt>",
  #     or "Image" where it has no alt text. Where the URL is not one a link may have, or
  #     the image is inside a link, it is those words alone, unlinked, so no link is
  #     inside another.
  #   * Headings move down two levels, so a ticket's `#` never outranks the page's: `#`
  #     is an `h3`, `##` an `h4`, `###` an `h5`, and `####` to `######` an `h6`.
  #   * A task box is no form field: a mark a screen reader skips, then Done or Not done
  #     for a screen reader alone.
  #   * A link opens in a new tab, as every link out of the console does
  #     (`ApiaryWeb.CoreComponents.external_link/1`), with
  #     `rel="nofollow noopener noreferrer"`, the faint mark of a link out, hidden from a
  #     screen reader, and, for a screen reader, that it opens a new tab.
  #   * A table is named for a screen reader, "Table in the ticket", by an `aria-label`
  #     the sanitiser sets; its header cells are `th` with `scope="col"`.
  #
  # The HTML is sanitised last, on the server, by an allowlist of tags, attributes and
  # classes, with `https` the one URL scheme and no relative URL; nothing changes it
  # after. The work is bounded, and a text past a bound comes back as written, whole.
  # Before it is parsed: longer than `max_length/0` characters (Unicode code points), or
  # able to ask for more table cells than `max_cells/0`, as a table's rows are padded to
  # its header's cells. Before it is rendered and sanitised: nesting deeper than
  # `max_depth/0`. A text that is not valid UTF-8 comes back as written too, its invalid
  # bytes replaced with U+FFFD. Nothing is cached: every call renders.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  # GitHub's cap on a ticket's text, in characters.
  @max_length 65_536

  # A table's rows are padded to its header's cells, so a short text can ask for many
  # cells; they are counted before it is parsed. A text that could ask for more is as
  # written.
  @max_cells 10_000

  # How deep blocks and inlines may nest; a deeper text is as written, as the sanitiser's
  # work grows with the depth.
  @max_depth 128

  @parse_options [
    extension: [table: true, strikethrough: true, autolink: true, tasklist: true],
    render: [unsafe: false],
    syntax_highlight: nil
  ]

  # What the renderer writes for a task box, with `unsafe` off: no text of the ticket
  # can write a `<` there, so these are the renderer's alone, as is every `</a>`.
  @box_done ~s(<input type="checkbox" checked="" disabled="" /> )
  @box_open ~s(<input type="checkbox" disabled="" /> )
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
    # A table's `aria-label` is set here, at render, in the reader's language
    # (`sanitize/0`); the ticket can write no attribute of a table.
    set_tag_attribute_values: %{
      "a" => %{"target" => "_blank"},
      "th" => %{"scope" => "col"}
    },
    allowed_classes: %{
      "span" => ~w(sr-only q-task-mark q-ticket-ext hero-arrow-top-right-on-square-micro)
    },
    generic_attributes: [],
    generic_attribute_prefixes: [],
    url_schemes: ["https"],
    url_relative: :deny,
    link_rel: "nofollow noopener noreferrer",
    strip_comments: true
  ]

  # The longest text, in characters (Unicode code points), that `render/2` formats.
  @doc false
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  # The most table cells a text that `render/2` formats may ask for, counted before it is
  # parsed: one more than the most `|` on one line, times its lines.
  @doc false
  @spec max_cells() :: pos_integer()
  def max_cells, do: @max_cells

  # How deep the blocks and inlines of a text that `render/2` formats may nest.
  @doc false
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  # The ticket's text `body` in the format `format`: safe HTML for `"markdown"`, and
  # `{:as_written, text}` for any other format, nil included, and for a Markdown text
  # `render/2` does not format: longer than `max_length/0`, asking for more table cells
  # than `max_cells/0`, nesting deeper than `max_depth/0`, or not valid UTF-8. An empty or
  # nil text is `{:as_written, ""}`: there is nothing to format. The text as written is
  # the text unchanged where it is valid UTF-8; otherwise its invalid bytes are replaced
  # with U+FFFD, so a page can send it.
  @doc false
  @spec render(String.t() | nil, String.t() | nil) ::
          Phoenix.HTML.safe() | {:as_written, String.t()}
  def render(body, format)
  def render(nil, _format), do: {:as_written, ""}
  def render("", _format), do: {:as_written, ""}

  def render(body, "markdown") when is_binary(body) do
    with true <- formattable?(body),
         {:ok, html} <- markdown(body) do
      Phoenix.HTML.raw(html)
    else
      _ -> as_written(body)
    end
  end

  def render(body, _format) when is_binary(body), do: as_written(body)

  defp as_written(body) do
    if String.valid?(body),
      do: {:as_written, body},
      else: {:as_written, String.replace_invalid(body)}
  end

  # A code point is at most four bytes, so a longer text is not counted.
  defp formattable?(body) do
    byte_size(body) <= 4 * @max_length and String.valid?(body) and
      code_points(body, 0) <= @max_length and table_cells(body) <= @max_cells
  end

  # The code points of valid UTF-8: its bytes that do not continue one.
  defp code_points(<<byte, rest::binary>>, count) when Bitwise.band(byte, 0xC0) == 0x80,
    do: code_points(rest, count)

  defp code_points(<<_byte, rest::binary>>, count), do: code_points(rest, count + 1)
  defp code_points(<<>>, count), do: count

  # The most cells a table of the text could have: a row is a line, and has its header's
  # cells, one more than the `|` of the header's line. With no `|`, there is no table.
  defp table_cells(body) do
    lines = String.split(body, ["\r\n", "\r", "\n"])

    case lines |> Enum.map(&length(:binary.matches(&1, "|"))) |> Enum.max() do
      0 -> 0
      pipes -> (pipes + 1) * length(lines)
    end
  end

  defp markdown(body) do
    document = MDEx.parse_document!(body, @parse_options)

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
    |> String.replace(@box_done, box("☑", pgettext("ticket task", "Done")))
    |> String.replace(@box_open, box("☐", pgettext("ticket task", "Not done")))
    |> String.replace(@link_end, link_end())
    |> MDEx.safe_html(
      sanitize: sanitize(),
      escape: [content: false, curly_braces_in_code: false]
    )
  end

  # The allowlist, with the name every table is given for a screen reader.
  defp sanitize do
    table = %{"aria-label" => pgettext("ticket table", "Table in the ticket")}
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

  defp escape(text),
    do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # Each node, and those under it, as the console shows them: a list, as a link may
  # become its words and raw HTML nothing. Under a link (`in_link`), an image is its
  # words, so no link is ever inside another. `depth` is the nodes' depth; past
  # `@max_depth` it throws `:too_deep`.
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
    if https?(url),
      do: [%{link | title: "", attrs: nil, nodes: walk(link.nodes, true, depth + 1)}],
      else: walk(link.nodes, in_link, depth + 1)
  end

  defp shown(%MDEx.Image{url: url} = image, in_link, _depth) do
    alt = plain_text(image.nodes)

    # Text, which the renderer escapes, so the alt text is never markup.
    words =
      if alt == "",
        do: pgettext("ticket image", "Image"),
        else: pgettext("ticket image", "Image: %{alt}", alt: alt)

    at = image.sourcepos
    text = [%MDEx.Text{literal: words, sourcepos: at}]

    if https?(url) and not in_link,
      do: [%MDEx.Link{url: url, nodes: text, sourcepos: at}],
      else: text
  end

  defp shown(%{nodes: nodes} = node, in_link, depth) when is_list(nodes),
    do: [%{node | nodes: walk(nodes, in_link, depth + 1)}]

  defp shown(node, _in_link, _depth), do: [node]

  # An image's alt text, as the renderer would write it: the words of the nodes under it.
  defp plain_text(nodes) do
    nodes
    |> Enum.map(fn
      %MDEx.HtmlInline{} -> ""
      %{literal: literal} when is_binary(literal) -> literal
      %{nodes: nodes} when is_list(nodes) -> plain_text(nodes)
      %MDEx.SoftBreak{} -> " "
      %MDEx.LineBreak{} -> " "
      _ -> ""
    end)
    |> Enum.join()
  end

  # Whether `url` is a link the console may have: an absolute `https` URL with a host and no
  # user name or password, and by choice a plain one: a port up to 65535, and a host of
  # letters, digits, `-`, `_` and `.` with no empty label (a trailing `.` aside) and no
  # punycode label (`xn--`), or, where its last label is a number, an IPv4 address of four
  # decimal parts. IPv6 addresses and hosts outside ASCII are refused. This is stricter than
  # the sanitiser's URL parser, so a link kept here keeps its href there. A URL with a
  # character outside ASCII is checked with that character percent-encoded, as the renderer
  # writes it, so a host outside ASCII has a `%`. Anything that is not a binary, nil
  # included, is refused.
  #
  # `render/2` links a URL only where this is true.
  @doc false
  @spec https?(term()) :: boolean()
  def https?(url) when is_binary(url) do
    parsed =
      with {:error, _} <- URI.new(url),
           do: URI.new(URI.encode(url, &(&1 < 128)))

    case parsed do
      {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil}}
      when is_binary(scheme) and is_binary(host) and is_integer(port) ->
        String.downcase(scheme) == "https" and port in 0..65_535 and host?(host)

      _ ->
        false
    end
  end

  def https?(_), do: false

  defp host?(host) do
    cond do
      not String.match?(host, ~r/\A[a-z0-9_.-]+\z/i) ->
        false

      true ->
        labels = host |> String.replace_suffix(".", "") |> String.split(".")
        name?(labels) or ipv4?(host, labels)
    end
  end

  # A name: no empty label, none in punycode, and a last label that is not a number.
  defp name?(labels) do
    plain = Enum.all?(labels, &(&1 != "" and not punycode?(&1)))
    plain and not number?(List.last(labels))
  end

  defp punycode?(label), do: label |> String.downcase() |> String.starts_with?("xn--")

  defp ipv4?(host, labels) do
    number?(List.last(labels)) and
      match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(host)))
  end

  # What a URL parser takes for an IPv4 part: decimal digits, or hexadecimal after `0x`.
  defp number?(label), do: String.match?(label, ~r/\A([0-9]+|0x[0-9a-f]*)\z/i)
end
