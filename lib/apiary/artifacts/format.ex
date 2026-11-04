defmodule Apiary.Artifacts.Format do
  # Format checks that a file of an artifact's version is what its type's base view shows
  # (`Apiary.Artifacts.Type`), from the file's bytes alone: what the writer says the file
  # is never counts. `check/3` reads the file at a local path, a staged copy or a stored
  # one, and returns the content type its bytes show, which is the one Qory Apiary keeps.
  #
  #   * document: Markdown, a filename that ends in `.md` (any case) and bytes that are
  #     UTF-8 text with no NUL; `text/markdown; charset=utf-8`.
  #   * image: PNG, JPEG, GIF or WebP by their first bytes; or SVG, at most 512 KiB, UTF-8,
  #     with no document type declaration (so no entity is declared) and at most 256 `=`
  #     between two `<` (so no element has more than 256 attributes), that an XML parser
  #     reads to its end with a root element `svg` in the SVG namespace,
  #     `http://www.w3.org/2000/svg`. The parse runs in another process within a budget
  #     (`Apiary.Kinds.Budget`).
  #   * video: MP4, an `ftyp` box first with an MP4 brand, or WebM, an EBML header whose
  #     document type is `webm`; or WebVTT captions beside them, a filename that ends in
  #     `.vtt` (any case) and at most 4 MiB of UTF-8 text with no NUL whose first line
  #     starts with `WEBVTT`, after a byte order mark where it has one,
  #     `text/vtt; charset=utf-8`. A version of a video type has at least one MP4 or
  #     WebM file (`Apiary.Artifacts.push/5`, `video?/1`).
  #   * file: any bytes; `application/octet-stream`.
  #   * structured: one JSON document valid against the type's JSON Schema: a standard
  #     type's file under `priv/schemas/artifacts/`, a custom type's in its row
  #     (`Apiary.Artifacts.CustomSchema`); `application/json`. A document of the standard
  #     type `questions` also has each question's `id` once, which its schema cannot
  #     check: a second question with an `id` is refused at that `id`.
  #
  # A version of the standard type `proposal` is one Markdown document with images
  # beside it, and the sources the run used. Each file is checked by its filename:
  #
  #   * a filename that ends in `.md` (any case): the document check, and at most
  #     262,144 bytes (256 KiB), else `:document_size`;
  #   * `sources.json`: at most 1 MiB, one JSON document valid against the proposal
  #     sources format, copied from qory (`priv/schemas/artifacts/
  #     proposal-sources.schema.json`); `application/json`. Qory Apiary reads none of its
  #     members;
  #   * a filename that ends in `.png`, `.jpg` or `.jpeg`, `.gif`, `.webp` or `.svg`
  #     (any case): the image check, where the type the bytes show is the one the
  #     extension names, else `:format`; and an SVG also passes the strict check:
  #     no element `script`, `foreignObject`, `image`, `iframe`, `animate` or `set`, in
  #     any namespace and any case, and no element in the HTML namespace
  #     (`http://www.w3.org/1999/xhtml`); no attribute whose name starts with `on`, and
  #     no `xml:base`, which changes what a link to `#…` points to; an
  #     `href`, in any namespace, only to a place in the file (`#…`); a CSS `url(` only to
  #     a place in the file, in an attribute or in text; no `@import`, no backslash in a
  #     `style` element or in any attribute (a CSS escape could spell `url(`), no
  #     `image-set(` or `image(` there either (any case, also with spaces before the
  #     `(`), and no processing instruction, such as `<?xml-stylesheet ?>` (the XML
  #     declaration is not one). Else `:svg_content`. Attribute values and text are checked
  #     as the parser reads them, with their character references replaced; a `style`
  #     element has no child element, and its text is checked as one, joined across
  #     comments and CDATA sections, as a browser reads it;
  #   * any other filename: `:extension`.
  #
  # A version of `proposal` has exactly one Markdown file and at most one `sources.json`
  # (`stored?/2`, `Apiary.Artifacts.push/5`); its type bounds all files together, 5 MiB,
  # and their count, 10 (`Apiary.Artifacts.Type`).
  #
  # A refusal is `{:error, reason}`: `:format` for bytes the base view does not take,
  # `:extension` for a document whose filename does not end in `.md` (for a proposal,
  # in none of the extensions it takes),
  # `{:schema, detail}` for a structured document the schema refuses, `detail` its first
  # failing place (`Apiary.Artifacts.SchemaError`), `:document_size` and `:svg_content`
  # for a file of a proposal, and `:unreadable` for a file that cannot be read.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  alias Apiary.Artifacts.{CustomSchema, SchemaError, Type}
  alias Apiary.Kinds.{Bounds, Budget, Schema}

  @head 64
  @svg_bytes 524_288
  @svg_namespace ~c"http://www.w3.org/2000/svg"

  # The budget of an SVG's parse: 20,000,000 reductions and 8,388,608 words of heap (64 MiB
  # on a 64-bit machine), the binaries the process refers to counted in it, and 30 s, a
  # bound only on a parse that runs away while it counts few reductions. Measured on OTP
  # 29 with xmerl 2.2, an SVG of rect elements needs about 64 words of heap per byte:
  # 256 KiB parse in 1,149,244 reductions within 2,097,152 words, and 1 MiB in 5,237,092
  # reductions within 8,388,608 words but not within 4,194,304. So 512 KiB is the largest
  # SVG taken, at about half the budget's heap; an SVG whose parse passes the budget is
  # refused as `:format`.
  @svg_budget [reductions: 20_000_000, heap_words: 8_388_608, ms: 30_000]

  # The most attributes an element of an SVG may have. xmerl's parse of one element takes
  # time quadratic in its attributes: measured on OTP 29 with xmerl 2.2, one element of
  # 10,922 attributes (109 KB) parses in 514 ms. An attribute's value has no `<` in a
  # well-formed document, so the attributes of a start tag lie between its `<` and the
  # next one, and each has a `=`; the count of `=` between two `<` bounds them before the
  # parse. With 256, the worst SVG of 512 KiB parses in about 0.1 s
  # (`Apiary.Artifacts.FormatTest`).
  @svg_attributes 256
  @mp4_brands ~w(isom iso2 iso3 iso4 iso5 iso6 iso8 iso9 mp41 mp42 avc1 dash mmp4) ++
                ["M4V ", "M4VP"]

  # The bounds of a standard type's document beyond the lists and members its schema
  # allows: values in all, the longest string and the deepest nesting.
  @standard_limits [nodes: 65_536, string: 131_072, depth: 16]

  # The lists and members of a standard type whose schema leaves its lists unbounded,
  # which `Apiary.Kinds.Bounds.file!/2` cannot read: the questions and the review comments
  # formats, copied from qory, bound a document by its size, 1 MiB. Their lists are
  # bounded here by the values in all, and their objects by the most members one has, a
  # question's 9 and a review comment's 7.
  @unbounded_lists %{
    "questions" => [list: 65_536, members: 9],
    "review-comments" => [list: 65_536, members: 7],
    "proposal-sources" => [list: 65_536, members: 6]
  }

  # A proposal's images by their extension, in lower case.
  @proposal_images %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml"
  }

  # A proposal's Markdown file, its sources and the schema of its sources.
  @proposal_markdown 262_144
  @sources "sources.json"
  @sources_bytes 1_048_576
  @sources_schema ["schemas", "artifacts", "proposal-sources.schema.json"]

  # The elements a proposal's SVG has none of, by local name in lower case, and the
  # namespace of HTML, whose elements, such as `img` or `object`, load what they refer to
  # where a browser opens the SVG as a page.
  @svg_refused_elements ~w(script foreignobject image iframe animate set)
  @xhtml_namespace ~c"http://www.w3.org/1999/xhtml"
  @xml_namespace ~c"http://www.w3.org/XML/1998/namespace"

  @markdown "text/markdown; charset=utf-8"
  @json "application/json"
  @vtt "text/vtt; charset=utf-8"
  @videos ~w(video/mp4 video/webm)
  @vtt_bytes 4_194_304

  # The content types `check/3` returns, by base view; a file view takes any.
  @content_types %{
    document: [@markdown],
    image: ~w(image/png image/jpeg image/gif image/webp image/svg+xml),
    video: [@vtt | @videos],
    structured: [@json]
  }

  @typedoc "Why a file is refused."
  @type refusal ::
          :format
          | :extension
          | :document_size
          | :svg_content
          | {:schema, SchemaError.t()}
          | :unreadable

  # check/3 is `{:ok, content_type}` for the file at `path`, named `filename`, that the
  # base view of `type` takes, else `{:error, refusal}`.
  @doc false
  @spec check(Type.t(), String.t(), Path.t()) :: {:ok, String.t()} | {:error, refusal}
  def check(%Type{base_view: :file}, _filename, _path), do: {:ok, "application/octet-stream"}

  def check(%Type{standard: true, name: "proposal"}, filename, path) do
    extension = String.downcase(Path.extname(filename))

    cond do
      extension == ".md" ->
        with {:ok, %File.Stat{size: size}} <- stat(path),
             true <- size <= @proposal_markdown || {:error, :document_size} do
          markdown(path)
        end

      filename == @sources ->
        sources(path)

      Map.has_key?(@proposal_images, extension) ->
        proposal_image(Map.fetch!(@proposal_images, extension), path)

      true ->
        {:error, :extension}
    end
  end

  def check(%Type{base_view: :document}, filename, path) do
    if String.downcase(Path.extname(filename)) == ".md",
      do: markdown(path),
      else: {:error, :extension}
  end

  def check(%Type{base_view: :image}, _filename, path) do
    with {:ok, head} <- head(path) do
      case image(head) do
        nil -> svg(path, :plain)
        content_type -> {:ok, content_type}
      end
    end
  end

  def check(%Type{base_view: :video}, filename, path) do
    with {:ok, head} <- head(path) do
      case video(head) do
        nil -> captions(filename, path)
        content_type -> {:ok, content_type}
      end
    end
  end

  def check(%Type{base_view: :structured} = type, _filename, path) do
    with {:ok, bytes} <- read(path),
         {:ok, document} <- decode(bytes),
         :ok <- structured(type, document) do
      {:ok, @json}
    end
  end

  # A proposal's image: the type its bytes show is the one its extension names, so a
  # downloaded file opens as that type, never as a page.
  defp proposal_image(expected, path) do
    with {:ok, head} <- head(path) do
      case image(head) do
        nil when expected == "image/svg+xml" -> svg(path, :strict)
        ^expected -> {:ok, expected}
        _other -> {:error, :format}
      end
    end
  end

  # Markdown: UTF-8 text with no NUL.
  defp markdown(path) do
    with {:ok, bytes} <- read(path) do
      if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
        do: {:ok, @markdown},
        else: {:error, :format}
    end
  end

  # stored?/2 is whether the content types of a version's files, as `check/3` returned
  # them at the push, are a version `type` takes: one file or more, each of a content
  # type of the type's base view, and, for a structured view, exactly one. A version of
  # `proposal` has exactly one Markdown file, at most one JSON file (its `sources.json`),
  # and images. The files of a version never change after its push, so the Exists check
  # of a stage's output reads these (`Apiary.Artifacts.exists?/3`) and reads no file
  # again. A base view in place of a type is that view's rule.
  @doc false
  @spec stored?(Type.t() | Type.base_view(), [String.t()]) :: boolean
  def stored?(%Type{standard: true, name: "proposal"}, content_types)
      when is_list(content_types) do
    images = Map.fetch!(@content_types, :image)

    Enum.count(content_types, &(&1 == @markdown)) == 1 and
      Enum.count(content_types, &(&1 == @json)) <= 1 and
      Enum.all?(content_types, &(&1 in [@markdown, @json | images]))
  end

  def stored?(%Type{base_view: base_view}, content_types), do: stored?(base_view, content_types)
  def stored?(_base_view, []), do: false
  def stored?(:file, _content_types), do: true
  def stored?(:structured, [content_type]), do: content_type == @json
  def stored?(:structured, _content_types), do: false

  def stored?(:video, content_types) do
    video?(content_types) and Enum.all?(content_types, &(&1 in [@vtt | @videos]))
  end

  def stored?(base_view, content_types) when is_list(content_types) do
    taken = Map.fetch!(@content_types, base_view)
    Enum.all?(content_types, &(&1 in taken))
  end

  # video?/1 is whether the content types of a version's files have an MP4 or WebM
  # video among them, as a version of a video type must.
  @doc false
  @spec video?([String.t()]) :: boolean
  def video?(content_types), do: Enum.any?(content_types, &(&1 in @videos))

  defp image(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: "image/png"
  defp image(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp image(<<"GIF8", v, "a", _rest::binary>>) when v in [?7, ?9], do: "image/gif"
  defp image(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  defp image(_head), do: nil

  defp video(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>)
       when brand in @mp4_brands,
       do: "video/mp4"

  # An EBML header with a DocType element (ID 0x4282) and the text `webm` in the first bytes.
  defp video(<<0x1A, 0x45, 0xDF, 0xA3, rest::binary>>) do
    if :binary.match(rest, <<0x42, 0x82>>) != :nomatch and :binary.match(rest, "webm") != :nomatch,
      do: "video/webm"
  end

  defp video(_head), do: nil

  # WebVTT captions: `.vtt`, at most `@vtt_bytes`, UTF-8 with no NUL, and `WEBVTT` first,
  # then the line's end, a space or a tab.
  defp captions(filename, path) do
    with true <- String.downcase(Path.extname(filename)) == ".vtt" || {:error, :format},
         {:ok, %File.Stat{size: size}} <- stat(path),
         true <- size <= @vtt_bytes || {:error, :format},
         {:ok, bytes} <- read(path),
         true <- webvtt?(bytes) || {:error, :format} do
      {:ok, @vtt}
    end
  end

  defp webvtt?(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: webvtt?(rest)

  defp webvtt?(<<"WEBVTT", rest::binary>> = bytes) do
    String.valid?(bytes) and not String.contains?(bytes, <<0>>) and
      (rest == "" or binary_part(rest, 0, 1) in [" ", "\t", "\n", "\r"])
  end

  defp webvtt?(_bytes), do: false

  ## SVG

  # `mode` is `:strict` for a proposal's SVG, which also passes the strict check (the
  # moduledoc), else `:plain`.
  defp svg(path, mode) do
    with {:ok, %File.Stat{size: size}} when size <= @svg_bytes <- stat(path),
         {:ok, bytes} <- read(path),
         true <- String.valid?(bytes),
         false <- declares_type?(bytes),
         true <- attributes_within?(bytes),
         :ok <- no_stylesheet(mode, bytes),
         {:ok, :svg} <- Budget.run(fn -> svg_root(:binary.copy(bytes), mode) end, @svg_budget) do
      {:ok, "image/svg+xml"}
    else
      {:error, :unreadable} -> {:error, :unreadable}
      {:ok, :unsafe} -> {:error, :svg_content}
      {:error, :svg_content} -> {:error, :svg_content}
      _refused -> {:error, :format}
    end
  end

  # A `<?xml-stylesheet ?>` instruction, which xmerl's parser refuses as a malformed XML
  # declaration, is looked for before the parse in `:strict` mode, so the refusal says
  # why.
  defp no_stylesheet(:strict, bytes) do
    if String.contains?(String.downcase(bytes), "<?xml-stylesheet"),
      do: {:error, :svg_content},
      else: :ok
  end

  defp no_stylesheet(:plain, _bytes), do: :ok

  # A document type declaration is where entities are declared, internal or external; an
  # SVG has none, so a file with one is refused before it is parsed.
  defp declares_type?(bytes) do
    lower = String.downcase(bytes)
    String.contains?(lower, "<!doctype") or String.contains?(lower, "<!entity")
  end

  # Whether no stretch of `bytes` between two `<` has more than `@svg_attributes` `=`.
  defp attributes_within?(bytes), do: attributes_within?(bytes, 0)

  defp attributes_within?(_bytes, count) when count > @svg_attributes, do: false
  defp attributes_within?(<<"<", rest::binary>>, _count), do: attributes_within?(rest, 0)
  defp attributes_within?(<<"=", rest::binary>>, count), do: attributes_within?(rest, count + 1)
  defp attributes_within?(<<_byte, rest::binary>>, count), do: attributes_within?(rest, count)
  defp attributes_within?(<<>>, _count), do: true

  # The root element's namespace and name, read by the SAX parser, which reads the whole
  # document: `:svg` for an SVG root in a well-formed document, anything else otherwise.
  # In `:strict` mode, `:unsafe` for a well-formed document with an SVG root that fails
  # the strict check.
  defp svg_root(bytes, mode) do
    event = fn event, _location, {root, safe?, state} ->
      root = root(event, root)

      if mode == :strict and safe? do
        {safe?, state} = strict(event, state)
        {root, safe?, state}
      else
        {root, safe?, state}
      end
    end

    case :xmerl_sax_parser.stream(bytes,
           event_fun: event,
           event_state: {:none, true, {[], nil}},
           external_entities: :none,
           fail_undeclared_ref: true
         ) do
      {:ok, {:svg, safe?, _state}, rest} ->
        cond do
          not blank?(rest) -> :other
          safe? -> :svg
          true -> :unsafe
        end

      _other ->
        :other
    end
  end

  defp root({:startElement, uri, name, _qualified, _attributes}, :none),
    do: if(uri == @svg_namespace and name == ~c"svg", do: :svg, else: :other)

  defp root(_event, root), do: root

  # One event of the strict check: whether the document is still safe, and the state:
  # the local names of the open elements, innermost first, and the text of the open
  # `style` element, nil outside one. A browser reads a `style` element's CSS as all its
  # text joined, across comments, CDATA sections and child elements, so that text is
  # checked as one at the element's end, and a `style` element has no child element.
  defp strict({:startElement, uri, name, _qualified, attributes}, {open, style}) do
    local = name |> List.to_string() |> String.downcase()

    safe? =
      style == nil and local not in @svg_refused_elements and uri != @xhtml_namespace and
        Enum.all?(attributes, fn {uri, prefix, attribute, value} ->
          name = String.downcase(List.to_string(attribute))
          not base?(uri, prefix, name) and safe_attribute?(name, List.to_string(value))
        end)

    {safe?, {[local | open], if(local == "style", do: [], else: style)}}
  end

  defp strict({:endElement, _uri, _name, _qualified}, {["style" | open], style}),
    do: {safe_text?(IO.chardata_to_string(style), true), {open, nil}}

  defp strict({:endElement, _uri, _name, _qualified}, {[_closed | open], style}),
    do: {true, {open, style}}

  defp strict({:characters, text}, {open, nil}),
    do: {safe_text?(List.to_string(text), false), {open, nil}}

  defp strict({:characters, text}, {open, style}), do: {true, {open, [style | text]}}

  # An SVG needs no processing instruction; the XML declaration is not one. An HTML
  # parser ends one at its first `>`, so its data could hold markup.
  defp strict({:processingInstruction, _target, _data}, state), do: {false, state}

  defp strict(_event, state), do: {true, state}

  # `xml:base` sets the address a link such as `href="#x"` is read against, so that
  # `#x` can point outside the file or to `javascript:`.
  defp base?(uri, prefix, name),
    do: name == "base" and (uri == @xml_namespace or prefix == ~c"xml")

  defp safe_attribute?("on" <> _rest, _value), do: false

  # Every attribute's value is checked as CSS: a browser reads presentation attributes,
  # such as `fill`, `mask` or `cursor`, as CSS, where an escape such as `\75 rl(` is `url(`.
  defp safe_attribute?("href", value),
    do: String.starts_with?(value, "#") and safe_text?(value, true)

  defp safe_attribute?(_name, value), do: safe_text?(value, true)

  # Text with no `@import` and every CSS `url(` to a place in the file; in CSS (`css?`),
  # a `style` element's text or an attribute's value, no backslash either, since a CSS
  # escape could spell `url(`, and no `image-set(` (also `-webkit-image-set(`) or
  # `image(`, which take an outside address as a plain string. Other text is not CSS, so
  # a label such as "Add image (PNG)" passes.
  defp safe_text?(text, css?) do
    lower = String.downcase(text)

    not String.contains?(lower, "@import") and
      not Regex.match?(~r/url\(\s*+['"]?+\s*+(?!#)/, lower) and
      not (css? and (String.contains?(text, "\\") or Regex.match?(~r/image(-set)?\s*\(/, lower)))
  end

  defp blank?(rest) when is_binary(rest), do: String.trim(rest) == ""
  defp blank?(rest) when is_list(rest), do: rest |> List.to_string() |> String.trim() == ""
  defp blank?(_rest), do: false

  ## A proposal's sources

  # `sources.json`: at most `@sources_bytes`, then the structured check, against the
  # proposal sources format, within the bounds of a standard type's document.
  defp sources(path) do
    with {:ok, %File.Stat{size: size}} <- stat(path),
         true <- size <= @sources_bytes || {:error, {:schema, refused(:limits)}} do
      check(
        %Type{
          standard: true,
          name: "proposal-sources",
          base_view: :structured,
          schema_path: @sources_schema
        },
        @sources,
        path
      )
    end
  end

  ## Structured

  defp decode(bytes) do
    with true <- String.valid?(bytes),
         {:ok, document} <- Jason.decode(bytes) do
      {:ok, document}
    else
      _refused -> {:error, :format}
    end
  end

  # The document of a standard type is checked in the caller's process: its bounds, the
  # schema file's and `@standard_limits`, are checked before JSV reads it.
  defp structured(%Type{standard: true, name: name, schema_path: path}, document)
       when is_list(path) do
    limits =
      Map.get_lazy(@unbounded_lists, name, fn -> Bounds.file!(path) end) ++ @standard_limits

    if Bounds.within?(document, limits) do
      case JSV.validate(document, Schema.file!(path, &Schema.code_point_lengths/1), cast: false) do
        {:ok, _document} -> once(name, document)
        {:error, %JSV.ValidationError{} = error} -> {:error, {:schema, SchemaError.first(error)}}
      end
    else
      {:error, {:schema, refused(:limits)}}
    end
  end

  defp structured(%Type{json_schema: schema}, document) when is_map(schema) do
    case CustomSchema.validate(document, schema) do
      :ok -> :ok
      {:error, {:schema, detail}} -> {:error, {:schema, detail}}
      {:error, refusal} -> {:error, {:schema, refused(refusal)}}
    end
  end

  defp structured(_type, _document), do: {:error, {:schema, refused(:unbuildable)}}

  # A questions document has each question's `id` once, and a review comments document
  # each review comment's: a second is refused at its place. A questions document's
  # answers, and the earlier answers in a question's `history`, choose an `option` among
  # the question's titles, or none.
  defp once("questions", %{"questions" => questions}) do
    with :ok <- once(questions, "questions", "question"), do: titled(questions)
  end

  defp once("review-comments", %{"review_comments" => comments}),
    do: once(comments, "review_comments", "review comment")

  defp once(_name, _document), do: :ok

  defp titled(questions) do
    questions
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {question, index} ->
      titles = for %{"title" => title} <- question["options"], do: title

      ([{"answer", question["answer"]}] ++
         for(
           {earlier, n} <- Enum.with_index(question["history"] || []),
           do: {"history/#{n}", earlier}
         ))
      |> Enum.find_value(fn
        {place, %{"option" => option}} when is_binary(option) ->
          if option not in titles,
            do:
              {:error,
               {:schema,
                SchemaError.detail(
                  "#/questions/#{index}/#{place}/option",
                  "the option is not the title of an option of the question"
                )}}

        _none ->
          nil
      end)
    end)
  end

  defp once(entries, key, word) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {%{"id" => id}, index}, seen ->
      if MapSet.member?(seen, id),
        do:
          {:halt,
           {:error,
            {:schema,
             SchemaError.detail(
               "#/#{key}/#{index}/id",
               "the id #{id} is the id of an earlier #{word}"
             )}}},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      {:error, _refusal} = refused -> refused
      _seen -> :ok
    end
  end

  # Why a document was refused before JSV found a failing place in it, at its root.
  defp refused(:limits),
    do: SchemaError.detail("#", "the document has more values, or longer ones, than allowed")

  defp refused(:budget),
    do: SchemaError.detail("#", "the check of the document took more time or memory than allowed")

  defp refused(_unbuildable), do: SchemaError.detail("#", "the JSON Schema cannot be read")

  ## Reading

  defp stat(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      _other -> {:error, :unreadable}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp head(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case :file.read(file, @head) do
            {:ok, head} -> {:ok, head}
            :eof -> {:ok, ""}
            {:error, _reason} -> {:error, :unreadable}
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end
end
