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
  #     check: a second question with an `id` is refused at that `id`. A document of a
  #     standard type has each key once in each object, which a JSON parser does not
  #     check (Jason keeps the last of two, another parser may keep the first): a key
  #     that comes twice is refused at its object's place, before the schema reads the
  #     document.
  #
  # A version of the standard type `mockup` that a run pushes with a `screens.json` is a
  # mockup of pages, checked as the base view `:mockup`: `screens.json` is
  # `application/json` and each page, a filename that ends in `.html`,
  # `text/html; charset=utf-8`; any other file is `{:mockup, message}`. The bytes of the
  # whole version are checked once every file is staged (`Apiary.Artifacts.Mockup`).
  # Every other version of `mockup`, a person's included, is pictures, an image type's.
  #
  # A version of the standard type `proposal` is one Markdown document with images
  # beside it, and the sources the run used. Each file is checked by its filename:
  #
  #   * a filename that ends in `.md` (any case): the document check, and at most
  #     262,144 bytes (256 KiB), else `:document_size`;
  #   * `sources.json`: at most 1 MiB, else `:document_size`; one JSON document, else
  #     `:format`, valid against the proposal sources format, copied from qory
  #     (`priv/schemas/artifacts/proposal-sources.schema.json`); `application/json`. Qory
  #     Apiary reads none of its members;
  #   * a filename that ends in `.png`, `.jpg` or `.jpeg`, `.gif`, `.webp` or `.svg`
  #     (any case): the image check, where the type the bytes show is the one the
  #     extension names, else `:image_type`. An SVG is at most 512 KiB, else
  #     `:document_size`; UTF-8 text an XML parser reads to its end, with a root element
  #     `svg` written with no prefix or in the SVG namespace, else `:svg_format`; a root
  #     `svg` with no prefix outside the SVG namespace is `:svg_root`, and a root with a
  #     prefix in the SVG namespace, such as `s:svg`, is refused by the strict check. An
  #     SVG passes the strict check, else `{:svg_content, part}`, `part` the first part
  #     refused, in plain words with names as the file writes them, such as "the script
  #     element". Before the parse, a document
  #     type declaration is "the DOCTYPE", and an element with more than 256 attributes
  #     "the attributes past the 256th on the rect element". An element that declares a
  #     prefix, or `xmlns`, twice is not well-formed: `:svg_format`. The strict check is
  #     an allowlist, so that the SVG runs no script and loads nothing from outside the
  #     file, shown in an `<img>`, opened as an SVG, or opened as a page after a rename to
  #     `.html`, where an HTML parser reads no namespace:
  #       - each element is one of `@svg_elements`, in the SVG namespace and written with
  #         no prefix ("the iframe element", "the s:rect element"); an element in the
  #         HTML namespace is "the HTML element h:div";
  #       - each attribute is one of `@svg_attribute_names`, by name as written ("the
  #         ping attribute"); `href` and `xlink:href` only on `use`, `a`, `textPath`,
  #         `linearGradient`, `radialGradient` and `pattern`, and only `#` and a name
  #         ("the href attribute");
  #       - nothing but spaces, tabs, CRs and LFs after the root's end ("everything
  #         after the end of the svg element");
  #       - `title`, `desc` and `style` contain text only ("the g element inside the desc
  #         element"); a CDATA section only inside `style` ("the CDATA section in the
  #         desc element"); no comment whose text starts with `>` or `->` ("the comment
  #         that starts with >"); no processing instruction, such as `<?xml-stylesheet ?>`
  #         ("the processing instruction xml-stylesheet"); the XML declaration is not one;
  #       - in any text and attribute, no `@import` and a CSS `url(` only to a place in
  #         the file ("the url() in the fill attribute");
  #       - in a `style` element and in any attribute, namespace declarations such as
  #         `xmlns:a` included, read as CSS, no backslash, since a
  #         CSS escape could spell `url(` ("a backslash in the fill attribute"), and no
  #         `image-set(`, also `-webkit-image-set(`, `image(` or `src(`, any case, also
  #         with spaces before the `(` ("the image-set() in the style element"); the
  #         text of a `style` element is checked as one, joined across comments and
  #         CDATA sections, as a browser reads it.
  #     Attribute values and text are checked as the parser reads them, with their
  #     character references replaced. A name past 64 characters is cut to 64 and `…`;
  #   * any other filename: `:extension`.
  #
  # A version of `proposal` has exactly one Markdown file and at most one `sources.json`
  # (`stored?/2`, `Apiary.Artifacts.push/5`); its type bounds all files together, 5 MiB,
  # and their count, 10 (`Apiary.Artifacts.Type`).
  #
  # A refusal is `{:error, reason}`: `:format` for bytes the base view does not take,
  # `:extension` for a document whose filename does not end in `.md` (for a proposal, in
  # none of the extensions it takes), `{:schema, detail}` for a structured document the
  # schema refuses, `detail` its first failing place (`Apiary.Artifacts.SchemaError`),
  # `:document_size`, `:image_type`, `:svg_format`, `:svg_root` and
  # `{:svg_content, part}` for a file of a proposal, `{:mockup, message}` for a file of a
  # mockup of pages, and `:unreadable` for a file that cannot be read.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  alias Apiary.Artifacts.{CustomSchema, Mockup, SchemaError, Type}
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
  # refused as `:format`, for a proposal `:svg_format`.
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

  # The strict check of a proposal's SVG is an allowlist, the one `docs/contract/run-api.md`
  # lists: the elements a wireframe needs, in the SVG namespace with no prefix, and the
  # attributes, by name as written. None of the elements is a tag an HTML parser ends an
  # SVG at, such as `img`, `meta` or `p`, so the same file opened as a page has no HTML
  # element either. Names are compared as written: SVG is case sensitive.
  @svg_elements ~w(
    svg g defs symbol use title desc
    rect circle ellipse line polyline polygon path
    text tspan textPath
    a
    linearGradient radialGradient stop pattern clipPath mask marker
    style
    filter feGaussianBlur feOffset feFlood feComposite feMerge feMergeNode feBlend
    feColorMatrix feDropShadow
  )

  @svg_attribute_names MapSet.new(~w(
    id class style lang xml:lang xml:space role aria-label aria-hidden
    version viewBox preserveAspectRatio
    x y x1 y1 x2 y2 cx cy r rx ry fx fy fr width height d points pathLength transform
    transform-origin
    dx dy rotate textLength lengthAdjust startOffset method spacing side
    fill fill-opacity fill-rule stroke stroke-width stroke-opacity stroke-dasharray
    stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit opacity color display
    visibility overflow clip-path clip-rule mask filter marker-start marker-mid marker-end
    stop-color stop-opacity flood-color flood-opacity font-family font-size font-weight
    font-style font-variant text-anchor dominant-baseline alignment-baseline baseline-shift
    letter-spacing word-spacing text-decoration writing-mode white-space vector-effect
    shape-rendering text-rendering paint-order mix-blend-mode isolation
    offset gradientUnits gradientTransform spreadMethod patternUnits patternContentUnits
    patternTransform clipPathUnits maskUnits maskContentUnits markerWidth markerHeight
    markerUnits refX refY orient
    filterUnits primitiveUnits in in2 result stdDeviation mode operator k1 k2 k3 k4 type
    values
  ))

  # A link, `href` or `xlink:href`, only on these elements, and only to a place in the
  # file: `#` and a name.
  @svg_links ~w(href xlink:href)
  @svg_linking ~w(use a textPath linearGradient radialGradient pattern)
  @svg_fragment ~r/\A#[A-Za-z_][A-Za-z0-9_.-]*\z/

  # The elements that contain text only. An HTML parser reads the content of `title` and
  # `desc` as HTML, so a child element there would be an HTML element.
  @svg_text_only ~w(title desc style)

  # The part refused for anything but spaces, tabs, CRs and LFs after the root's end.
  @svg_after "everything after the end of the svg element"

  # The namespace of HTML, named in the part refused.
  @xhtml_namespace ~c"http://www.w3.org/1999/xhtml"

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
          | :image_type
          | :svg_format
          | :svg_root
          | {:svg_content, String.t()}
          | {:schema, SchemaError.t()}
          | {:mockup, String.t()}
          | :unreadable

  # check/3 is `{:ok, content_type}` for the file at `path`, named `filename`, that the
  # base view of `type` takes, else `{:error, refusal}`.
  @doc false
  @spec check(Type.t(), String.t(), Path.t()) :: {:ok, String.t()} | {:error, refusal}
  def check(%Type{base_view: :file}, _filename, _path), do: {:ok, "application/octet-stream"}

  # A mockup of pages, from a run with a `screens.json`: the content type by the
  # filename; the version's bytes are checked together once every file is staged
  # (`Apiary.Artifacts.Mockup.check_version/1`).
  def check(%Type{base_view: :mockup}, filename, _path), do: Mockup.content_type(filename)

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
         {:ok, document} <- decode(type, bytes),
         :ok <- structured(type, document) do
      {:ok, @json}
    end
  end

  # A proposal's image: the type its bytes show is the one its extension names, so a
  # downloaded file opens as that type, never as a page; else `:image_type`. An SVG's
  # bytes are not a PNG, JPEG, GIF or WebP, and then pass the SVG checks.
  defp proposal_image(expected, path) do
    with {:ok, head} <- head(path) do
      case image(head) do
        nil when expected == "image/svg+xml" -> svg(path, :strict)
        ^expected -> {:ok, expected}
        _other -> {:error, :image_type}
      end
    end
  end

  # proposal_bytes/1 is the most bytes of a proposal's file named `filename`, past which
  # `check/3` refuses it as `:document_size`: its `sources.json`'s, an SVG's, else its
  # Markdown file's.
  @doc false
  @spec proposal_bytes(String.t()) :: pos_integer
  def proposal_bytes(@sources), do: @sources_bytes

  def proposal_bytes(filename) do
    if String.downcase(Path.extname(filename)) == ".svg",
      do: @svg_bytes,
      else: @proposal_markdown
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

  # A version of `mockup` is pictures, as an image type, or a mockup of pages.
  def stored?(%Type{standard: true, name: "mockup"}, content_types) when is_list(content_types),
    do: stored?(:image, content_types) or Mockup.stored?(content_types)

  def stored?(%Type{base_view: base_view}, content_types), do: stored?(base_view, content_types)

  def stored?(:mockup, content_types) when is_list(content_types),
    do: Mockup.stored?(content_types)

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
    with {:ok, %File.Stat{size: size}} <- stat(path),
         true <- size <= @svg_bytes || {:error, refusal(mode, :document_size)},
         {:ok, bytes} <- read(path) do
      svg_bytes(bytes, mode)
    end
  end

  defp svg_bytes(bytes, mode) do
    with true <- String.valid?(bytes) || {:error, refusal(mode, :svg_format)},
         :ok <- markup(bytes, mode),
         {:ok, :svg} <- Budget.run(fn -> svg_root(:binary.copy(bytes), mode) end, @svg_budget) do
      {:ok, "image/svg+xml"}
    else
      {:error, reason} when is_tuple(reason) or reason in [:format, :svg_format] ->
        {:error, reason}

      {:ok, {:unsafe, part}} ->
        {:error, {:svg_content, part}}

      {:ok, :unparsed} ->
        stylesheet(mode, bytes)

      {:ok, :svg_root} ->
        {:error, refusal(mode, :svg_root)}

      _other ->
        {:error, refusal(mode, :svg_format)}
    end
  end

  # A refusal of `:strict` mode by its reason; `:plain` mode refuses every SVG as `:format`.
  defp refusal(:strict, reason), do: reason
  defp refusal(:plain, _reason), do: :format

  # xmerl's parser stops at a `<?xml-stylesheet ?>` instruction before the root, as a
  # malformed XML declaration, so in `:strict` mode a file whose parse fails is read for
  # its first processing instruction, other than the XML declaration, outside a comment
  # and a CDATA section (`scan/2`), so the refusal says why. A mention in a comment or a
  # CDATA section is not an instruction, and a parse that reads the file to its end sends
  # every instruction to the strict check.
  defp stylesheet(:strict, bytes) do
    case scan(bytes, :instruction) do
      {:instruction, target} ->
        {:error, {:svg_content, "the processing instruction #{shorten(target)}"}}

      _none ->
        {:error, :svg_format}
    end
  end

  defp stylesheet(:plain, _bytes), do: {:error, :format}

  # markup/2 reads the markup of `bytes` before the parse, as an XML parser reads it:
  # comments, CDATA sections and processing instructions to their end, and each tag to its
  # `>` outside a quoted value. `:ok`, else:
  #
  #   * a document type declaration, `<!DOCTYPE` or `<!ENTITY` in any case, outside a
  #     comment, a CDATA section and a processing instruction: "the DOCTYPE". It is where
  #     entities are declared, internal or external; an SVG has none;
  #   * a tag with more than `@svg_attributes` attributes, counted by its `=` outside a
  #     quoted value: "the attributes past the 256th on the rect element".
  #
  # A `<` inside a tag, also in a quoted value, is where an XML parser stops, so the count
  # starts again there. The parser reads no attribute past where this count does.
  defp markup(bytes, mode) do
    case scan(bytes, :limits) do
      :ok -> :ok
      :doctype -> {:error, refusal(mode, {:svg_content, "the DOCTYPE"})}
      {:attributes, ""} -> {:error, refusal(mode, :svg_format)}
      {:attributes, name} -> {:error, refusal(mode, {:svg_content, attributes_part(name)})}
    end
  end

  defp attributes_part(name),
    do: "the attributes past the #{@svg_attributes}th on the #{shorten(name)} element"

  # `find` is `:limits` for the checks of `markup/2`, or `:instruction` for the target of
  # the first processing instruction, other than the XML declaration,
  # `{:instruction, target}`. The parser stops at a `<` inside a tag, so an instruction
  # is looked for only before one.
  defp scan(bytes, find) do
    case :binary.match(bytes, "<") do
      :nomatch -> :ok
      {at, 1} -> open(binary_part(bytes, at + 1, byte_size(bytes) - at - 1), find)
    end
  end

  # `bytes` follow a `<`.
  defp open(<<"!--", rest::binary>>, find), do: skip(rest, "-->", find)
  defp open(<<"![CDATA[", rest::binary>>, find), do: skip(rest, "]]>", find)

  # The target of an instruction is an XML name; without one, no instruction is found.
  defp open(<<"?", rest::binary>>, :instruction) do
    case Regex.run(~r/\A[\p{L}_:][\p{L}\p{N}\p{M}_:.\-\x{B7}]*/u, rest) do
      [target] ->
        if String.downcase(target) == "xml",
          do: skip(rest, "?>", :instruction),
          else: {:instruction, target}

      nil ->
        :ok
    end
  end

  defp open(<<"?", rest::binary>>, find), do: skip(rest, "?>", find)

  defp open(<<"!", rest::binary>> = bytes, :limits) do
    if Regex.match?(~r/\A(?:doctype|entity)/i, rest),
      do: :doctype,
      else: tag(bytes, bytes, 0, :limits)
  end

  defp open(bytes, find), do: tag(bytes, bytes, 0, find)

  defp skip(bytes, close, find) do
    case :binary.match(bytes, close) do
      :nomatch ->
        :ok

      {at, length} ->
        scan(binary_part(bytes, at + length, byte_size(bytes) - at - length), find)
    end
  end

  # A tag from after its `<`: `start` is where its name begins.
  defp tag(_bytes, start, count, :limits) when count > @svg_attributes,
    do: {:attributes, tag_name(start)}

  defp tag(<<">", rest::binary>>, _start, _count, find), do: scan(rest, find)
  defp tag(<<"<", _rest::binary>>, _start, _count, :instruction), do: :ok
  defp tag(<<"<", rest::binary>>, _start, _count, find), do: open(rest, find)
  defp tag(<<"=", rest::binary>>, start, count, find), do: tag(rest, start, count + 1, find)

  defp tag(<<quote, rest::binary>>, start, count, find) when quote in [?", ?'] do
    case :binary.match(rest, [<<quote>>, "<"]) do
      :nomatch ->
        :ok

      {at, 1} ->
        after_at = binary_part(rest, at + 1, byte_size(rest) - at - 1)

        cond do
          :binary.at(rest, at) == quote -> tag(after_at, start, count, find)
          find == :instruction -> :ok
          true -> open(after_at, find)
        end
    end
  end

  defp tag(<<_byte, rest::binary>>, start, count, find), do: tag(rest, start, count, find)
  defp tag(<<>>, _start, _count, _find), do: :ok

  defp tag_name(bytes) do
    [name | _rest] = :binary.split(bytes, [" ", "\t", "\n", "\r", "/", ">", "=", "\"", "'"])
    name
  end

  # The root element's namespace and name, read by the SAX parser, which reads the whole
  # document: `:svg` for an SVG root in a well-formed document, `:unparsed` for a
  # document the parser stops in, `:svg_root` for a root `svg`, written with no prefix,
  # outside the SVG namespace, `:other` otherwise. In `:strict` mode, `{:unsafe, part}`
  # for a well-formed document with an SVG root that fails the strict check, `part` the
  # first part it refuses. The parser stops reading at the end tag of the root and returns
  # the rest; after a root with no end tag, it reads comments and processing instructions,
  # which the strict check refuses. Either is "everything after the end of the svg
  # element".
  defp svg_root(bytes, mode) do
    event = fn event, _location, {root, status, state, declared} ->
      root = root(event, root)
      declared = declared(event, declared)

      if mode == :strict and status == :safe do
        {status, state} = strict(event, state)
        {root, status, state, declared}
      else
        {root, status, state, declared}
      end
    end

    case :xmerl_sax_parser.stream(bytes,
           event_fun: event,
           event_state: {:none, :safe, {[], nil}, []},
           external_entities: :none,
           fail_undeclared_ref: true
         ) do
      {:ok, {_root, _status, _state, :twice}, _rest} ->
        :other

      {:ok, {:svg, status, _state, _declared}, rest} ->
        cond do
          status != :safe -> status
          blank?(rest) -> :svg
          mode == :strict -> {:unsafe, @svg_after}
          true -> :other
        end

      {:ok, {:svg_root, _status, _state, _declared}, _rest} ->
        :svg_root

      {:ok, _root, _rest} ->
        :other

      _stopped ->
        :unparsed
    end
  end

  defp root({:startElement, uri, ~c"svg", qualified, _attributes}, :none) do
    cond do
      uri == @svg_namespace -> :svg
      qualified == {[], ~c"svg"} -> :svg_root
      true -> :other
    end
  end

  defp root({:startElement, _uri, _name, _qualified, _attributes}, :none), do: :other

  defp root(_event, root), do: root

  # The prefixes declared on the next element, `[]` for `xmlns`, or `:twice` once an
  # element declares one twice. XML has no attribute twice on one element, but xmerl's
  # parser takes the last of two declarations and a browser the first, so the element
  # could be in the HTML namespace in the browser and in the SVG namespace here.
  defp declared(_event, :twice), do: :twice

  defp declared({:startPrefixMapping, prefix, _uri}, declared),
    do: if(prefix in declared, do: :twice, else: [prefix | declared])

  defp declared({:startElement, _uri, _name, _qualified, _attributes}, _declared), do: []
  defp declared(_event, declared), do: declared

  # One event of the strict check: `:safe`, or `{:unsafe, part}` with the part refused in
  # plain words, names as the file writes them; and the state: the open elements,
  # innermost first, each its name, and the open `style` element, nil outside one, its
  # name and its text so far. A browser reads a `style` element's CSS as all its text
  # joined, across comments and CDATA sections, so that text is checked as one at the
  # element's end.
  defp strict({:startElement, uri, name, {prefix, _local} = qualified, attributes}, state) do
    {open, style} = state
    local = List.to_string(name)
    written = written(qualified)

    status =
      cond do
        text_only = text_only(open) ->
          {:unsafe, "the #{written} element inside the #{text_only} element"}

        uri == @xhtml_namespace ->
          {:unsafe, "the HTML element #{written}"}

        uri != @svg_namespace or prefix != [] or local not in @svg_elements ->
          {:unsafe, "the #{written} element"}

        true ->
          Enum.find_value(attributes, :safe, &unsafe_attribute(&1, local))
      end

    {status, {[local | open], if(local == "style", do: {written, []}, else: style)}}
  end

  defp strict({:endElement, _uri, _name, _qualified}, {["style" | open], {written, text}}),
    do: {in_text(IO.chardata_to_string(text), true, "the #{written} element"), {open, nil}}

  defp strict({:endElement, _uri, _name, _qualified}, {[_root], _style}), do: {:safe, :after}

  defp strict({:endElement, _uri, _name, _qualified}, {[_closed | open], style}),
    do: {:safe, {open, style}}

  # After the root's end, only XML white space: space, tab, CR and LF.
  defp strict(event, :after) do
    case event do
      {:ignorableWhitespace, _text} -> {:safe, :after}
      {:endPrefixMapping, _prefix} -> {:safe, :after}
      :endDocument -> {:safe, :after}
      _other -> {{:unsafe, @svg_after}, :after}
    end
  end

  # A namespace declaration's address is checked as an attribute's value.
  defp strict({:startPrefixMapping, prefix, uri}, state) do
    name = if prefix == [], do: "xmlns", else: written({~c"xmlns", prefix})
    {in_text(List.to_string(uri), true, "the #{name} attribute"), state}
  end

  defp strict({:characters, text}, {open, nil}) do
    place = with [inner | _outer] <- open, do: inner
    {in_text(List.to_string(text), false, "the text of the #{place} element"), {open, nil}}
  end

  defp strict({:characters, text}, {open, {written, style}}),
    do: {:safe, {open, {written, [style | text]}}}

  # A CDATA section only inside `style`: an HTML parser reads `<![CDATA[` inside an HTML
  # element as a comment that ends at the first `>`, so the rest of the section would be
  # markup.
  defp strict(:startCDATA, {["style" | _outer], _style} = state), do: {:safe, state}

  defp strict(:startCDATA, {[inner | _outer], _style} = state),
    do: {{:unsafe, "the CDATA section in the #{inner} element"}, state}

  # An HTML parser ends `<!-->` and `<!--->` at once, as an empty comment, so the rest of
  # the comment would be markup. XML has no `--` in a comment, so HTML's other end of a
  # comment, `--!>`, never appears.
  defp strict({:comment, [?> | _text]}, state),
    do: {{:unsafe, "the comment that starts with >"}, state}

  defp strict({:comment, [?-, ?> | _text]}, state),
    do: {{:unsafe, "the comment that starts with ->"}, state}

  # An SVG needs no processing instruction; the XML declaration is not one. An HTML
  # parser ends one at its first `>`, so its data could contain markup.
  defp strict({:processingInstruction, target, _data}, state),
    do: {{:unsafe, "the processing instruction #{shorten(List.to_string(target))}"}, state}

  defp strict(_event, state), do: {:safe, state}

  # The innermost open element when it contains text only, else nil.
  defp text_only([inner | _outer]) when inner in @svg_text_only, do: inner
  defp text_only(_open), do: nil

  # An attribute of the element `element` that the strict check refuses: `{:unsafe, part}`,
  # else nil. An attribute is one the allowlist names, as written; a link, `href` or
  # `xlink:href`, is on an element that links and to `#` and a name. Every attribute's
  # value is also checked as CSS: a browser reads presentation attributes, such as `fill`,
  # `mask` or `filter`, as CSS, where an escape such as `\75 rl(` is `url(`.
  defp unsafe_attribute({_uri, prefix, local, value}, element) do
    written = written({prefix, local})
    value = List.to_string(value)

    allowed? =
      if written in @svg_links,
        do: element in @svg_linking and Regex.match?(@svg_fragment, value),
        else: MapSet.member?(@svg_attribute_names, written)

    if allowed? do
      case in_text(value, true, "the #{written} attribute") do
        :safe -> nil
        unsafe -> unsafe
      end
    else
      {:unsafe, "the #{written} attribute"}
    end
  end

  # `:safe` for text with no `@import` and every CSS `url(` to a place in the file; in CSS
  # (`css?`), a `style` element's text or an attribute's value, no backslash either, since
  # a CSS escape could spell `url(`, and no `image-set(` (also `-webkit-image-set(`),
  # `image(` or `src(`, which take an outside address as a plain string. Other text is not
  # CSS, so a label such as "Add image (PNG)" passes. Else `{:unsafe, part}`, the part
  # found in `place`.
  defp in_text(text, css?, place) do
    lower = String.downcase(text)

    found =
      cond do
        css? and String.contains?(text, "\\") -> "a backslash"
        String.contains?(lower, "@import") -> "the @import"
        Regex.match?(~r/url\(\s*+['"]?+\s*+(?!#)/, lower) -> "the url()"
        css? -> css_function(lower)
        true -> nil
      end

    if found, do: {:unsafe, "#{found} in #{place}"}, else: :safe
  end

  defp css_function(lower) do
    case Regex.run(~r/(?:-webkit-)?image(?:-set)?(?=\s*\()|src(?=\s*\()/, lower) do
      [name] -> "the #{name}()"
      nil -> nil
    end
  end

  # A name as the file writes it, with its prefix; past 64 characters, its first 64 and
  # an ellipsis, so a message stays short.
  defp written({[], local}), do: shorten(List.to_string(local))
  defp written({prefix, local}), do: shorten("#{prefix}:#{local}")

  defp shorten(name),
    do: if(String.length(name) > 64, do: String.slice(name, 0, 64) <> "…", else: name)

  # XML allows only space, tab, CR and LF after the root; a browser fails to show a file
  # with other white space there, such as U+00A0 or a form feed.
  defp blank?(rest) when is_binary(rest), do: Regex.match?(~r/\A[ \t\r\n]*\z/, rest)
  defp blank?(rest) when is_list(rest), do: rest |> List.to_string() |> blank?()
  defp blank?(_rest), do: false

  ## A proposal's sources

  # `sources.json`: at most `@sources_bytes`, then the structured check, against the
  # proposal sources format, within the bounds of a standard type's document.
  defp sources(path) do
    with {:ok, %File.Stat{size: size}} <- stat(path),
         true <- size <= @sources_bytes || {:error, :document_size} do
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

  # A standard type's document is read with its objects in order, so a key that comes
  # twice in one object is refused at that object's place (`unique/2`).
  defp decode(%Type{standard: true}, bytes) do
    with true <- String.valid?(bytes),
         {:ok, document} <- Jason.decode(bytes, objects: :ordered_objects) do
      case unique(document, []) do
        {:ok, document} -> {:ok, document}
        {:repeated, key, path} -> {:error, {:schema, repeated(key, path)}}
      end
    else
      _refused -> {:error, :format}
    end
  end

  defp decode(%Type{}, bytes) do
    with true <- String.valid?(bytes),
         {:ok, document} <- Jason.decode(bytes) do
      {:ok, document}
    else
      _refused -> {:error, :format}
    end
  end

  # The document with each object a map: `{:ok, document}`, or `{:repeated, key, path}`
  # for the first key, in the document's order, that comes earlier in its object; `path`
  # the object's place, its segments last first.
  defp unique(%Jason.OrderedObject{values: members}, path) do
    Enum.reduce_while(members, {:ok, %{}}, fn {key, value}, {:ok, object} ->
      if Map.has_key?(object, key) do
        {:halt, {:repeated, key, path}}
      else
        case unique(value, [key | path]) do
          {:ok, value} -> {:cont, {:ok, Map.put(object, key, value)}}
          repeated -> {:halt, repeated}
        end
      end
    end)
  end

  defp unique(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case unique(value, [index | path]) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        repeated -> {:halt, repeated}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      repeated -> repeated
    end
  end

  defp unique(value, _path), do: {:ok, value}

  defp repeated(key, path),
    do:
      SchemaError.detail(
        JSV.ErrorFormatter.format_data_path(path),
        "the object has the key #{key} twice"
      )

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
