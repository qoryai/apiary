defmodule Apiary.Artifacts.Mockup do
  # Mockup checks a version of the standard type `mockup` that a run pushes with a
  # `screens.json`: the index of its screens, and one HTML page per screen, which the
  # version page shows in a sandboxed frame (`ApiaryWeb.ArtifactMockupController`). The
  # rules are the mockup contract that the Qory harness's pack step checks too: every rule
  # is an allowlist, and what it does not list is refused. A version without
  # `screens.json`, and every version a person adds, is pictures, checked as an image type
  # (`Apiary.Artifacts.Format`).
  #
  # The version:
  #
  #   * `screens.json` and one page per screen, the screen's `file`, and no other file;
  #     at most 10 files and 10 MiB in all, the type's limits (`Apiary.Artifacts.Type`);
  #   * `screens.json`: UTF-8 JSON of at most 64 KiB, each key once in each object,
  #     valid against `priv/schemas/artifacts/mockup.schema.json`; then `start` is the id
  #     of a screen, the ids are unique, each `file` is its screen's id and `.html`, each
  #     link's `to` is the id of a screen, and every screen is reachable from `start`
  #     through `links`. A refusal here is `{:schema, index, detail}`, as a structured
  #     file's (`Apiary.Artifacts.SchemaError`);
  #   * each page: UTF-8 with no byte order mark, at most 1 MiB; at most `@max_tags`
  #     tags and at most `@max_attributes` attributes on one tag, counted before the
  #     parse (`prescan/1`), since the parser's time grows with the square of the
  #     nesting and of one tag's attributes; then parsed by the HTML5 algorithm
  #     (`LazyHTML`, lexbor) and walked, every element and attribute, in its namespace;
  #     one HTML `<title>`, whose text with each run of ASCII white space (tab, line
  #     feed, form feed, carriage return, space) made one space and trimmed at both ends
  #     is the screen's title, any other white space kept as it is; and the screens the page's `<a href>` links lead to are the
  #     `to` values of the screen's `links`.
  #
  # The page rules, in short (the contract has them in full): the HTML and SVG elements
  # of `@html_elements` and `@svg_elements`; the attributes of `@global` on every
  # element, `aria-…` and `data-…`, the element's attributes of `@html_attributes` or
  # `@svg_attributes`, and `href` / `xlink:href` on SVG `use` and `image`; `<meta>` as
  # `charset="utf-8"` alone or `name="viewport"` with `content`; an `<a href>` exactly
  # `<id>.html` of a screen; an image address a base64 `data:` URI of PNG, JPEG, GIF or
  # WebP; a fragment `#` and a name with no `%`, compared with the `id`s as written, and
  # no `id` on two elements; a `use` reference a fragment, to an element that is no `use`
  # and contains none, and at most 1,000 `use`; the `input` and `button` types listed;
  # SVG `fill`, `stroke` and `clip-path` with `url(#…)` alone, to a `linearGradient`,
  # `radialGradient` or `clipPath`; inside a `clipPath`, no `use` and no attribute with
  # `url(`; no attribute value with `javascript:`, `vbscript:` or `data:text`, every
  # ASCII white space and control character removed; and the CSS of `<style>` and
  # `style` checked after its comments are removed and its escapes decoded: `url(…)` and
  # `src(…)` only to a `data:` image, or a `data:` font inside `@font-face`, and no
  # `url(#…)`; no `image()`, `image-set()`, `image-rect()`, `cross-fade()`, `element()`,
  # `paint()`, `expression()` or `attr()`, also with a prefix such as `-webkit-`; no
  # `@import`, `@namespace` or `@document`; no `behavior` or `-moz-binding` property.
  # Core checks the contract alone, not the further refusals of the harness's pack step.
  #
  # The parser's tree has qualified names and no namespaces. An element's namespace is
  # read from its place, as the HTML5 tree builder puts it: `svg` and `math` start their
  # namespace inside HTML, every child of an SVG element is SVG except the children of the
  # HTML integration points `foreignObject`, `desc` and `title`, which are HTML again.
  #
  # A refusal of a page or of the files is `{:mockup, message}` with the index of the
  # file, or nil for the version: the message is the fix first, then the cause and the
  # value, with the file and the screen.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  alias Apiary.Artifacts.{Format, SchemaError, Type}
  alias Apiary.ExternalText

  @index "screens.json"
  @index_bytes 65_536
  @page_bytes 1_048_576
  @schema ["schemas", "artifacts", "mockup.schema.json"]
  @json "application/json"
  @html "text/html; charset=utf-8"

  # The most tags a page has, each a `<` followed by an ASCII letter, and the most
  # attributes on one tag, both counted before the parse. lexbor's parse takes time that
  # grows with the square of the nesting and of one tag's attributes: measured on an
  # Apple M-series machine with lazy_html 0.1.13, 95,000 nested `<div>` parse in 10.6 s
  # and 110,000 attributes on one `<div>` in 30.7 s, while 10,000 nested `<b>` with
  # distinct ids, the slowest nesting found, parse in 0.25 s, and 256 attributes in well
  # under 1 ms.
  @max_tags 10_000
  @max_attributes 256
  @max_uses 1_000

  @html_elements MapSet.new(~w(
    html head body title meta style main header footer nav section article aside div
    span p h1 h2 h3 h4 h5 h6 ul ol li dl dt dd a img picture source figure figcaption
    table caption thead tbody tfoot tr th td colgroup col strong em b i u s small mark
    code pre kbd samp sub sup br hr blockquote q abbr time address details summary label
    input button select option optgroup textarea fieldset legend progress meter output
  ))

  @svg_elements MapSet.new(
                  Enum.map(
                    ~w(svg g defs symbol use title desc path rect circle ellipse line
                       polyline polygon text tspan linearGradient radialGradient stop
                       clipPath image),
                    &String.downcase/1
                  )
                )

  # The SVG elements whose children an HTML5 parser reads as HTML.
  @integration_points ~w(foreignobject desc title)

  @global MapSet.new(~w(id class style title lang dir hidden tabindex role))

  @choice ~w(name multiple size selected disabled label value)
  @cell ~w(colspan rowspan scope headers)
  @range ~w(value min max low high optimum)

  @html_attributes %{
    "a" => MapSet.new(~w(href)),
    "img" => MapSet.new(~w(src srcset alt width height loading decoding)),
    "source" => MapSet.new(~w(srcset type media sizes)),
    "input" =>
      MapSet.new(~w(type name value placeholder checked disabled readonly min max step size)),
    "button" => MapSet.new(~w(type disabled name value)),
    "select" => MapSet.new(@choice),
    "option" => MapSet.new(@choice),
    "optgroup" => MapSet.new(@choice),
    "textarea" => MapSet.new(~w(name rows cols placeholder disabled readonly)),
    "label" => MapSet.new(~w(for)),
    "td" => MapSet.new(@cell),
    "th" => MapSet.new(@cell),
    "col" => MapSet.new(~w(span)),
    "colgroup" => MapSet.new(~w(span)),
    "ol" => MapSet.new(~w(start reversed type)),
    "li" => MapSet.new(~w(value)),
    "time" => MapSet.new(~w(datetime)),
    "meter" => MapSet.new(@range),
    "progress" => MapSet.new(@range),
    "details" => MapSet.new(~w(open)),
    "table" => MapSet.new(~w(border))
  }

  @svg_attributes MapSet.new(
                    Enum.map(
                      ~w(viewBox xmlns xmlns:xlink preserveAspectRatio d x y x1 y1 x2 y2 cx
                         cy r rx ry fx fy dx dy width height points transform rotate
                         textLength lengthAdjust offset fill fill-opacity fill-rule stroke
                         stroke-width stroke-opacity stroke-linecap stroke-linejoin
                         stroke-dasharray stroke-dashoffset stroke-miterlimit opacity
                         clip-path clip-rule font-family font-size font-weight font-style
                         text-anchor dominant-baseline letter-spacing stop-color
                         stop-opacity gradientUnits gradientTransform spreadMethod
                         clipPathUnits visibility display focusable),
                      &String.downcase/1
                    )
                  )

  # The SVG attributes a browser reads as CSS that may hold a `url(#…)`, and the elements
  # it may point at.
  @svg_url_attributes ~w(fill stroke clip-path)
  @url_targets ~w(lineargradient radialgradient clippath)

  @input_types ~w(text email password number search tel url date time checkbox radio
                  range color hidden)

  @page_link ~r/\A([a-z0-9][a-z0-9-]{0,31})\.html\z/
  @data_image ~r/\Adata:image\/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+\/]*={0,2}\z/i
  @data_font ~r/\Adata:font\/(?:woff2|woff|ttf|otf);base64,[A-Za-z0-9+\/]*={0,2}\z/i
  @gap ~r/[\x00-\x20\x7F]/
  @refused_at_rules ~r/@(?:-[a-z0-9]+-)?(import|namespace|document)/
  @refused_functions ~w(image-set image-rect image cross-fade element paint expression attr)
  @script_words ["javascript:", "vbscript:", "data:text"]

  @typedoc "Why a version of a mockup is refused, with the index of the file or nil."
  @type refusal ::
          {{:mockup, String.t()}, non_neg_integer | nil}
          | {:schema, non_neg_integer, SchemaError.t()}

  @typedoc "A screen of `screens.json`, as `index/1` reads it."
  @type screen :: %{id: String.t(), title: String.t(), file: String.t()}

  # index_name/0 is the filename of the index, `screens.json`.
  @doc false
  @spec index_name() :: String.t()
  def index_name, do: @index

  # content_type/1 is the content type a file of a mockup version is kept with, by its
  # filename, `{:ok, type}`, else `{:error, {:mockup, message}}` for a file that is
  # neither `screens.json` nor a page. `check_version/1` checks the bytes.
  @doc false
  @spec content_type(String.t()) :: {:ok, String.t()} | {:error, {:mockup, String.t()}}
  def content_type(@index), do: {:ok, @json}

  def content_type(filename) do
    if String.ends_with?(filename, ".html"),
      do: {:ok, @html},
      else: {:error, {:mockup, extra(filename)}}
  end

  # stored?/1 is whether the content types of a version's files, as `content_type/1`
  # kept them, are a mockup of pages: exactly one JSON file, `screens.json`, and one
  # page or more.
  @doc false
  @spec stored?([String.t()]) :: boolean
  def stored?(content_types) do
    Enum.count(content_types, &(&1 == @json)) == 1 and Enum.any?(content_types, &(&1 == @html)) and
      Enum.all?(content_types, &(&1 in [@json, @html]))
  end

  # check_version/1 checks the files of a version, each `{filename, path}` in the order
  # of the push: `:ok`, else `{:error, refusal}`.
  @doc false
  @spec check_version([{String.t(), Path.t()}]) :: :ok | {:error, refusal}
  def check_version(files) do
    indexed = Enum.with_index(files)

    with {:ok, index_at, path} <- find_index(indexed),
         {:ok, document} <- read_index(index_at, path),
         :ok <- files_match(indexed, document) do
      pages(indexed, document)
    end
  end

  defp find_index(indexed) do
    case Enum.find(indexed, fn {{filename, _path}, _at} -> filename == @index end) do
      {{_filename, path}, at} ->
        {:ok, at, path}

      nil ->
        {:error, {{:mockup, "Add `screens.json` to the version: it lists the screens."}, nil}}
    end
  end

  defp read_index(at, path) do
    type = %Type{standard: true, name: "mockup", base_view: :structured, schema_path: @schema}

    with {:ok, %File.Stat{size: size}} <- stat(path, at),
         true <- size <= @index_bytes || {:error, {{:mockup, index_size(size)}, at}},
         {:ok, @json} <- structured(type, path, at),
         {:ok, bytes} <- read(path, @index, at) do
      document = Jason.decode!(bytes)

      case cross(document) do
        :ok -> {:ok, document}
        {:error, detail} -> {:error, {:schema, at, detail}}
      end
    end
  end

  defp structured(type, path, at) do
    case Format.check(type, @index, path) do
      {:ok, @json} -> {:ok, @json}
      {:error, {:schema, detail}} -> {:error, {:schema, at, detail}}
      {:error, :unreadable} -> {:error, {{:mockup, unreadable(@index)}, at}}
      {:error, _format} -> {:error, {{:mockup, index_format()}, at}}
    end
  end

  # The rules of screens.json that its schema cannot check, each at its place.
  defp cross(%{"start" => start, "screens" => screens}) do
    ids = Enum.map(screens, & &1["id"])

    with :ok <- unique(ids),
         :ok <- files(screens),
         :ok <- start(start, ids),
         :ok <- targets(screens, ids) do
      reachable(start, screens)
    end
  end

  defp unique(ids) do
    ids
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {id, at}, seen ->
      if MapSet.member?(seen, id),
        do:
          {:halt,
           {:error,
            SchemaError.detail(
              "#/screens/#{at}/id",
              "the id #{id} is the id of an earlier screen"
            )}},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      {:error, _detail} = refused -> refused
      _seen -> :ok
    end
  end

  defp files(screens) do
    screens
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {%{"id" => id, "file" => file}, at} ->
      if file != id <> ".html",
        do:
          {:error,
           SchemaError.detail(
             "#/screens/#{at}/file",
             "the file is not #{id}.html, the screen's id and .html"
           )}
    end)
  end

  defp start(start, ids) do
    if start in ids,
      do: :ok,
      else:
        {:error, SchemaError.detail("#/start", "the start #{start} is not the id of a screen")}
  end

  defp targets(screens, ids) do
    screens
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {%{"links" => links}, at} ->
      links
      |> Enum.with_index()
      |> Enum.find_value(fn {%{"to" => to}, link_at} ->
        if to not in ids,
          do:
            {:error,
             SchemaError.detail(
               "#/screens/#{at}/links/#{link_at}/to",
               "the to #{to} is not the id of a screen"
             )}
      end)
    end)
  end

  defp reachable(start, screens) do
    edges =
      Map.new(screens, fn %{"id" => id, "links" => links} -> {id, Enum.map(links, & &1["to"])} end)

    reached = walk_links([start], edges, MapSet.new([start]))

    screens
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {%{"id" => id}, at} ->
      if not MapSet.member?(reached, id),
        do:
          {:error,
           SchemaError.detail(
             "#/screens/#{at}",
             "the screen #{id} cannot be reached from the start screen through links"
           )}
    end)
  end

  defp walk_links([], _edges, reached), do: reached

  defp walk_links([id | rest], edges, reached) do
    new = edges |> Map.get(id, []) |> Enum.reject(&MapSet.member?(reached, &1)) |> Enum.uniq()
    walk_links(new ++ rest, edges, Enum.reduce(new, reached, &MapSet.put(&2, &1)))
  end

  # The files are `screens.json` and each screen's page, and no other.
  defp files_match(indexed, %{"screens" => screens}) do
    wanted = MapSet.new(screens, & &1["file"])
    have = MapSet.new(indexed, fn {{filename, _path}, _at} -> filename end)

    extra =
      Enum.find(indexed, fn {{filename, _path}, _at} ->
        filename != @index and not MapSet.member?(wanted, filename)
      end)

    missing = Enum.find(screens, &(not MapSet.member?(have, &1["file"])))

    cond do
      extra ->
        {{filename, _path}, at} = extra
        {:error, {{:mockup, extra(filename)}, at}}

      missing ->
        {:error,
         {{:mockup,
           "Add `#{missing["file"]}` to the version: it is the page of screen " <>
             "`#{missing["id"]}` in `screens.json`."}, nil}}

      true ->
        :ok
    end
  end

  defp pages(indexed, %{"screens" => screens}) do
    ids = MapSet.new(screens, & &1["id"])
    by_name = Map.new(indexed, fn {{filename, path}, at} -> {filename, {path, at}} end)

    Enum.find_value(screens, :ok, fn %{"file" => file} = screen ->
      {path, at} = Map.fetch!(by_name, file)

      result =
        with {:ok, bytes} <- read(path, file, at),
             {:ok, linked} <- page_refusal(page(bytes, screen, ids), at),
             do: links(screen, linked, at)

      if result == :ok, do: nil, else: result
    end)
  end

  defp page_refusal({:ok, linked}, _at), do: {:ok, linked}
  defp page_refusal({:error, message}, at), do: {:error, {{:mockup, message}, at}}

  # The screens a page links to are the `to` values of its screen's links.
  defp links(%{"id" => id, "file" => file, "links" => links}, linked, at) do
    listed = MapSet.new(links, & &1["to"])

    cond do
      to = linked |> MapSet.difference(listed) |> Enum.sort() |> List.first() ->
        {:error,
         {{:mockup,
           "Add a link to screen `#{to}` to the `links` of screen `#{id}` in `screens.json`: " <>
             "`#{file}` links to `#{to}.html`."}, at}}

      to = listed |> MapSet.difference(linked) |> Enum.sort() |> List.first() ->
        {:error,
         {{:mockup,
           "Link `#{file}` to `#{to}.html` with an `<a href>`, or remove the link to screen " <>
             "`#{to}` from the `links` of screen `#{id}` in `screens.json`: the page has no " <>
             "link to `#{to}.html`."}, at}}

      true ->
        :ok
    end
  end

  # index/1 is the screens of a stored `screens.json`, `{:ok, %{start: id, screens:
  # [screen]}}` in the file's order, else `:error`. The version passed `check_version/1`
  # at its push; this reads only what the version page and the frame need.
  @doc false
  @spec index(binary) :: {:ok, %{start: String.t(), screens: [screen]}} | :error
  def index(bytes) when is_binary(bytes) do
    with true <- byte_size(bytes) <= @index_bytes,
         {:ok, %{"start" => start, "screens" => [_ | _] = screens}} when is_binary(start) <-
           Jason.decode(bytes),
         {:ok, screens} <- index_screens(screens),
         true <- Enum.any?(screens, &(&1.id == start)) do
      {:ok, %{start: start, screens: screens}}
    else
      _not -> :error
    end
  end

  def index(_bytes), do: :error

  defp index_screens(screens) do
    Enum.reduce_while(screens, {:ok, []}, fn
      %{"id" => id, "title" => title, "file" => file}, {:ok, acc}
      when is_binary(id) and is_binary(title) and is_binary(file) ->
        if Regex.match?(@page_link, file) and file == id <> ".html",
          do: {:cont, {:ok, [%{id: id, title: title, file: file} | acc]}},
          else: {:halt, :error}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  ## A page

  # page/3 checks the bytes of the page of `screen`, a screen of `screens.json`, in a
  # version whose screens have the ids `ids`: `{:ok, linked}`, the ids of the screens its
  # `<a href>` links lead to, else `{:error, message}`.
  @doc false
  @spec page(binary, map, MapSet.t()) :: {:ok, MapSet.t()} | {:error, String.t()}
  def page(bytes, %{"id" => id, "file" => file, "title" => title}, ids) do
    ctx = %{file: file, id: id, ids: ids}

    cond do
      byte_size(bytes) > @page_bytes ->
        {:error,
         "Shrink `#{file}` to at most #{@page_bytes} bytes: it has #{byte_size(bytes)} bytes."}

      match?(<<0xEF, 0xBB, 0xBF, _rest::binary>>, bytes) ->
        {:error, "Save `#{file}` as UTF-8 without a byte order mark: the page starts with one."}

      not String.valid?(bytes) ->
        {:error, "Save `#{file}` as UTF-8: it has bytes that are not UTF-8."}

      true ->
        with :ok <- prescan_refusal(prescan(bytes), file) do
          walk_page(bytes, title, ctx)
        end
    end
  end

  defp prescan_refusal(:ok, _file), do: :ok

  defp prescan_refusal(:tags, file),
    do:
      {:error,
       "Shrink `#{file}` to at most #{@max_tags} tags: it has more, each a `<` followed by " <>
         "a letter, and a page with more takes too long to check."}

  defp prescan_refusal(:attributes, file),
    do:
      {:error,
       "Give each tag in `#{file}` at most #{@max_attributes} attributes: one tag has more, " <>
         "and a page with more takes too long to check."}

  defp walk_page(bytes, title, ctx) do
    tree = bytes |> LazyHTML.from_document() |> LazyHTML.to_tree()

    acc = %{
      titles: [],
      linked: MapSet.new(),
      uses: 0,
      use_refs: [],
      url_refs: [],
      ids: %{},
      blocked: MapSet.new()
    }

    try do
      {_contains_use, acc} = nodes(tree, :html, nil, false, ctx, acc)
      :ok = use_refs(Enum.reverse(acc.use_refs), acc.blocked, ctx)
      :ok = url_refs(Enum.reverse(acc.url_refs), acc.ids, ctx)
      :ok = title(Enum.reverse(acc.titles), title, ctx)
      {:ok, acc.linked}
    catch
      {:refused, message} -> {:error, message}
    end
  end

  defp refuse(message), do: throw({:refused, message})

  # The nodes, children of an element in `parent_ns` named `parent`, inside a `clipPath`
  # where `clip?`: whether one is or contains a `use`, and the walk's findings.
  defp nodes(nodes, parent_ns, parent, clip?, ctx, acc) do
    Enum.reduce(nodes, {false, acc}, fn
      {name, attributes, children}, {contains, acc} when is_binary(name) ->
        {use?, acc} = element(name, attributes, children, {parent_ns, parent, clip?}, ctx, acc)
        {contains or use?, acc}

      _text_or_comment, result ->
        result
    end)
  end

  defp element(name, attributes, children, {parent_ns, parent, clip?}, ctx, acc) do
    local = String.downcase(name, :ascii)
    ns = namespace(parent_ns, parent, local)
    allowed!(ns, local, ctx)

    attributes =
      Enum.map(attributes, fn {key, value} -> {String.downcase(key, :ascii), value} end)

    if ns == :html and local == "meta", do: meta!(attributes, ctx)
    if clip?, do: clip!(ns, local, attributes, ctx)
    acc = id(attributes, ns, local, ctx, acc)

    acc = Enum.reduce(attributes, acc, &attribute(&1, ns, local, ctx, &2))

    acc =
      cond do
        ns == :html and local == "title" ->
          %{acc | titles: [text(children) | acc.titles]}

        ns == :html and local == "style" ->
          css!(text(children), :sheet, "a `<style>` element", ctx)
          acc

        true ->
          acc
      end

    use? = ns == :svg and local == "use"

    acc =
      if use? do
        uses = acc.uses + 1

        if uses > @max_uses,
          do: refuse("Draw at most #{@max_uses} `<use>` elements in #{where(ctx)}: it has more.")

        %{acc | uses: uses}
      else
        acc
      end

    {contains, acc} =
      nodes(children, ns, local, clip? or (ns == :svg and local == "clippath"), ctx, acc)

    contains = contains or use?

    acc =
      case List.keyfind(attributes, "id", 0) do
        {"id", id} when contains -> %{acc | blocked: MapSet.put(acc.blocked, id)}
        _other -> acc
      end

    {contains, acc}
  end

  # Each `id` is on one element of the page; a fragment points at it, as written.
  defp id(attributes, ns, local, ctx, acc) do
    case List.keyfind(attributes, "id", 0) do
      {"id", id} ->
        if Map.has_key?(acc.ids, id),
          do:
            refuse(
              "Give each element in #{where(ctx)} a different `id`: `#{shown(id)}` is the " <>
                "`id` of two elements."
            )

        %{acc | ids: Map.put(acc.ids, id, {ns, local})}

      nil ->
        acc
    end
  end

  # Inside a `clipPath`, no `use` and no attribute with `url(`: a browser draws a clip
  # path again for each element that points at it.
  defp clip!(:svg, "use", _attributes, ctx),
    do:
      refuse(
        "Remove the SVG `<use>` element from the `<clipPath>` in #{where(ctx)}: a " <>
          "`<clipPath>` of a mockup page has no `<use>`."
      )

  defp clip!(ns, local, attributes, ctx) do
    case Enum.find(attributes, fn {_name, value} -> String.contains?(css_lower(value), "url(") end) do
      {name, _value} ->
        refuse(
          "Remove the `url(` from the `#{shorten(name)}` attribute of #{tag(ns, local)} inside " <>
            "a `<clipPath>` in #{where(ctx)}: an element of a `<clipPath>` points at no other " <>
            "element."
        )

      nil ->
        :ok
    end
  end

  defp namespace(:html, _parent, "svg"), do: :svg
  defp namespace(:html, _parent, "math"), do: :math
  defp namespace(:html, _parent, _local), do: :html

  defp namespace(:svg, parent, local) when parent in @integration_points,
    do: namespace(:html, nil, local)

  defp namespace(:svg, _parent, _local), do: :svg
  defp namespace(:math, _parent, _local), do: :math

  defp allowed!(:html, local, ctx) do
    if not MapSet.member?(@html_elements, local),
      do:
        refuse(
          "Remove the `<#{shorten(local)}>` element from #{where(ctx)}: #{element_reason(local)}."
        )
  end

  defp allowed!(:svg, local, ctx) do
    if not MapSet.member?(@svg_elements, local),
      do:
        refuse(
          "Remove the SVG `<#{shorten(local)}>` element from #{where(ctx)}: " <>
            "#{element_reason(local)}."
        )
  end

  defp allowed!(:math, local, ctx),
    do:
      refuse(
        "Remove the MathML `<#{shorten(local)}>` element from #{where(ctx)}: " <>
          "#{element_reason(local)}."
      )

  defp element_reason(local) when local in ~w(script noscript),
    do: "a mockup page runs no script"

  defp element_reason(local) when local in ~w(iframe frame frameset object embed foreignobject),
    do: "a mockup page shows no other page or plug-in inside it"

  defp element_reason("form"), do: "a mockup page sends no form"

  defp element_reason(local) when local in ~w(base link),
    do: "a mockup page loads nothing from outside the version"

  defp element_reason(_local), do: "a mockup page has only the elements the mockup format lists"

  # `<meta>` is `charset="utf-8"` alone, or `name="viewport"` with `content`.
  defp meta!(attributes, ctx) do
    names = attributes |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    ok? =
      case names do
        ["charset"] -> lower(value_of(attributes, "charset")) == "utf-8"
        ["content", "name"] -> lower(value_of(attributes, "name")) == "viewport"
        _other -> false
      end

    if not ok?,
      do:
        refuse(
          ~s(Write each `<meta>` element in #{where(ctx)} as `<meta charset="utf-8">` or ) <>
            ~s(`<meta name="viewport" content="…">`: a mockup page has no other `<meta>`.)
        )
  end

  defp value_of(attributes, name) do
    {_name, value} = List.keyfind(attributes, name, 0)
    value
  end

  defp attribute({name, value}, ns, local, ctx, acc) do
    if not (ns == :html and local == "meta") and not attribute_allowed?(ns, local, name),
      do: refuse(attribute_refusal(name, ns, local, ctx))

    script_words!(name, value, ns, local, ctx)
    address = trim(value)

    if name in ~w(href xlink:href src) and Regex.match?(@gap, address),
      do:
        refuse(
          "Remove the space or control character inside the `#{name}` attribute of " <>
            "#{tag(ns, local)} in #{where(ctx)}: an address has none. It is `#{shown(value)}`."
        )

    value_rule({name, value, address}, ns, local, ctx, acc)
  end

  defp value_rule({"style", value, _address}, ns, local, ctx, acc) do
    css!(value, :declarations, "the `style` attribute of #{tag(ns, local)}", ctx)
    acc
  end

  defp value_rule({name, value, _address}, :svg, local, ctx, acc)
       when name in @svg_url_attributes do
    place = "the `#{name}` attribute of #{tag(:svg, local)}"
    fragments = css!(value, :fragment, place, ctx)
    %{acc | url_refs: Enum.reverse(Enum.map(fragments, &{place, &1})) ++ acc.url_refs}
  end

  defp value_rule({"href", value, address}, :html, "a", ctx, acc) do
    case Regex.run(@page_link, address) do
      [_all, id] ->
        if MapSet.member?(ctx.ids, id),
          do: %{acc | linked: MapSet.put(acc.linked, id)},
          else: refuse(page_link_refusal(value, ctx))

      nil ->
        refuse(page_link_refusal(value, ctx))
    end
  end

  defp value_rule({"src", value, address}, :html, "img", ctx, acc) do
    if not Regex.match?(@data_image, address),
      do: refuse(image_refusal("src", :html, "img", value, ctx))

    acc
  end

  defp value_rule({name, value, address}, :svg, "image", ctx, acc)
       when name in ~w(href xlink:href) do
    if not Regex.match?(@data_image, address),
      do: refuse(image_refusal(name, :svg, "image", value, ctx))

    acc
  end

  defp value_rule({"srcset", value, _address}, ns, local, ctx, acc) do
    case value |> srcset() |> Enum.find(&(not Regex.match?(@data_image, &1))) do
      nil ->
        acc

      bad ->
        refuse(
          "Set each address in the `srcset` attribute of #{tag(ns, local)} in #{where(ctx)} " <>
            "to a base64 `data:` URI of a PNG, JPEG, GIF or WebP image: a mockup page loads " <>
            "nothing from outside the version. One is `#{shown(bad)}`."
        )
    end
  end

  defp value_rule({name, value, address}, :svg, "use", ctx, acc)
       when name in ~w(href xlink:href) do
    if not fragment?(address),
      do:
        refuse(
          "Set the `#{name}` attribute of the SVG `<use>` element in #{where(ctx)} to `#` and the " <>
            "`id` of an element of the page, with no `%`: it is `#{shown(value)}`."
        )

    %{acc | use_refs: [{name, address} | acc.use_refs]}
  end

  defp value_rule({"type", value, _address}, :html, "input", ctx, acc) do
    if lower(value) not in @input_types,
      do:
        refuse(
          "Set the `type` attribute of the `<input>` element in #{where(ctx)} to " <>
            "#{Enum.join(Enum.drop(@input_types, -1), ", ")} or #{List.last(@input_types)}: " <>
            "it is `#{shown(value)}`."
        )

    acc
  end

  defp value_rule({"type", value, _address}, :html, "button", ctx, acc) do
    if lower(value) != "button",
      do:
        refuse(
          "Set the `type` attribute of the `<button>` element in #{where(ctx)} to `button`, " <>
            "or remove it: a mockup page sends no form. It is `#{shown(value)}`."
        )

    acc
  end

  defp value_rule(_attribute, _ns, _local, _ctx, acc), do: acc

  defp attribute_allowed?(ns, local, name) do
    cond do
      MapSet.member?(@global, name) ->
        true

      prefixed?(name, "aria-") or prefixed?(name, "data-") ->
        true

      ns == :svg ->
        MapSet.member?(@svg_attributes, name) or
          (local in ~w(use image) and name in ~w(href xlink:href))

      true ->
        @html_attributes |> Map.get(local, MapSet.new()) |> MapSet.member?(name)
    end
  end

  defp prefixed?(name, prefix), do: String.starts_with?(name, prefix) and name != prefix

  defp attribute_refusal(name, ns, local, ctx) do
    reason =
      if String.starts_with?(name, "on"),
        do: "a mockup page runs no script",
        else: "a mockup page has only the attributes the mockup format lists"

    "Remove the `#{shorten(name)}` attribute from #{tag(ns, local)} in #{where(ctx)}: #{reason}."
  end

  defp script_words!(name, value, ns, local, ctx) do
    squeezed = squeeze(lower(value))

    case Enum.find(@script_words, &String.contains?(squeezed, &1)) do
      nil ->
        :ok

      "data:text" ->
        refuse(
          "Remove `data:text` from the `#{shorten(name)}` attribute of #{tag(ns, local)} in " <>
            "#{where(ctx)}: a mockup page opens no page or text from an address."
        )

      word ->
        refuse(
          "Remove `#{word}` from the `#{shorten(name)}` attribute of #{tag(ns, local)} in " <>
            "#{where(ctx)}: a mockup page runs no script."
        )
    end
  end

  defp page_link_refusal(value, ctx),
    do:
      "Set the `href` attribute of the `<a>` element in #{where(ctx)} to `<id>.html` of a " <>
        "screen of the version: it is `#{shown(value)}`."

  defp image_refusal(name, ns, local, value, ctx),
    do:
      "Set the `#{name}` attribute of #{tag(ns, local)} in #{where(ctx)} to a base64 `data:` " <>
        "URI of a PNG, JPEG, GIF or WebP image: a mockup page loads nothing from outside the " <>
        "version. It is `#{shown(value)}`."

  # A fragment: `#` and a name with no `%`, which is compared with the `id`s as written.
  defp fragment?(address), do: Regex.match?(~r/\A#[^%]+\z/s, address)

  # A `use` points at no element that is a `use` or contains one: a browser copies such a
  # `use` again in each copy.
  defp use_refs(refs, blocked, ctx) do
    Enum.each(refs, fn {name, "#" <> id = address} ->
      if MapSet.member?(blocked, id),
        do:
          refuse(
            "Point the `#{name}` attribute of the SVG `<use>` element in #{where(ctx)} at an " <>
              "element that is no `<use>` and contains none: `#{shown(address)}` is or " <>
              "contains a `<use>`."
          )
    end)
  end

  # A `url(#…)` of `fill`, `stroke` or `clip-path` points at a gradient or a clip path of
  # the page.
  defp url_refs(refs, ids, ctx) do
    Enum.each(refs, fn {place, "#" <> id = fragment} ->
      case Map.get(ids, id) do
        {:svg, local} when local in @url_targets ->
          :ok

        _other ->
          refuse(
            "Point `url(#{shown(fragment)})` in #{place} in #{where(ctx)} at a " <>
              "`<linearGradient>`, `<radialGradient>` or `<clipPath>` element of the page: " <>
              "no such element has the `id` `#{shown(id)}`."
          )
      end
    end)
  end

  defp title([text], expected, ctx) do
    found = collapse(text)

    if found == expected,
      do: :ok,
      else:
        refuse(
          "Set the `<title>` of #{where(ctx)} to `#{shown(expected)}`, the title of the screen " <>
            "in `screens.json`: it is `#{shown(found)}`."
        )
  end

  defp title(titles, _expected, ctx),
    do: refuse("Give #{where(ctx)} exactly one `<title>`: it has #{length(titles)}.")

  defp text(children), do: children |> Enum.filter(&is_binary/1) |> Enum.join()

  # ASCII white space only: `String.trim/1` and a Unicode `\s` also take a no-break space.
  defp collapse(text), do: text |> String.replace(~r/[\t\n\f\r ]+/, " ") |> trim()

  ## CSS

  # The CSS `css` of `place`, in `mode`: `:sheet` for a `<style>` element,
  # `:declarations` for a `style` attribute, `:fragment` for an SVG attribute that takes
  # `url(#…)` alone. Checked after its comments are removed and its escapes decoded.
  defp css!(css, mode, place, ctx) do
    plain = plain_css(css)
    lower = lower(plain)
    squeezed = squeeze(lower)
    spot = "#{place} in #{where(ctx)}"

    fragments = addresses!(plain, lower, mode, spot)

    case Regex.run(@refused_at_rules, squeezed) do
      [rule, _name] ->
        refuse(
          "Remove `#{rule}` from #{spot}: a mockup page loads nothing from outside the version."
        )

      nil ->
        :ok
    end

    case Enum.find(@refused_functions, &String.contains?(squeezed, &1 <> "(")) do
      nil -> :ok
      name -> refuse("Remove `#{name}()` from #{spot}: #{function_reason(name)}.")
    end

    cond do
      Regex.match?(~r/(?<![a-z0-9_-])behavior\s*:/, lower) ->
        refuse("Remove the `behavior` property from #{spot}: a mockup page runs no script.")

      String.contains?(squeezed, "-moz-binding") ->
        refuse("Remove the `-moz-binding` property from #{spot}: a mockup page runs no script.")

      word = Enum.find(@script_words, &String.contains?(squeezed, &1)) ->
        refuse(
          "Remove `#{word}` from #{spot}: a mockup page runs no script and opens no address."
        )

      true ->
        fragments
    end
  end

  defp plain_css(css), do: css |> String.replace(~r{/\*.*?(?:\*/|\z)}s, "") |> decode_escapes()
  defp css_lower(value), do: value |> plain_css() |> lower()

  defp function_reason(name) when name in ~w(expression), do: "a mockup page runs no script"
  defp function_reason("attr"), do: "the mockup format lists no `attr()`"
  defp function_reason(_name), do: "a mockup page loads nothing from outside the version"

  # Each `url(` and `src(` of the CSS takes a `data:` image or a fragment, and inside
  # `@font-face` a `data:` font; in `:fragment` mode a fragment alone.
  # Each `url(` and `src(` of the CSS: in a `<style>` element or a `style` attribute, a
  # `data:` image, or inside `@font-face` a `data:` font; in `:fragment` mode, a fragment
  # alone, `#` and a name with no `%`. The fragments, in order.
  defp addresses!(plain, lower, mode, spot) do
    font_faces = if mode == :sheet, do: font_faces(lower), else: []

    ~r/(?:url|src)\(/
    |> Regex.scan(lower, return: :index)
    |> Enum.flat_map(fn [{at, length}] ->
      value = argument(binary_part(plain, at + length, byte_size(plain) - at - length))
      font_face? = Enum.any?(font_faces, fn {first, last} -> at > first and at < last end)

      cond do
        mode == :fragment and fragment?(value) -> [value]
        mode == :fragment -> refuse(address_refusal(mode, value, spot))
        Regex.match?(@data_image, value) -> []
        font_face? and Regex.match?(@data_font, value) -> []
        true -> refuse(address_refusal(mode, value, spot))
      end
    end)
  end

  defp address_refusal(:fragment, value, spot),
    do:
      "Use `url(#<id>)` alone in #{spot}, with no `%`, for a gradient or a clip path of the " <>
        "page: it has `#{shown(value)}`."

  defp address_refusal(_mode, value, spot),
    do:
      "Use only a base64 `data:` image in #{spot}, and a base64 `data:` font only inside " <>
        "`@font-face`: a mockup page loads nothing from outside the version, and a " <>
        "`url(#…)` goes only in the SVG attributes `fill`, `stroke` and `clip-path`. " <>
        "It has `#{shown(value)}`."

  # The argument of a `url(` or `src(`: quoted, to its closing quote; else to the `)`;
  # with the white space around it removed.
  defp argument(rest) do
    rest = trim_leading(rest)

    case rest do
      <<quote, inner::binary>> when quote in [?", ?'] ->
        [value | _rest] = :binary.split(inner, <<quote>>)
        trim(value)

      _unquoted ->
        [value | _rest] = :binary.split(rest, ")")
        trim(value)
    end
  end

  # The byte ranges of the `@font-face` blocks of the CSS, from the `{` to its `}`.
  defp font_faces(lower) do
    ~r/@(?:-[a-z0-9]+-)?font-face/
    |> Regex.scan(lower, return: :index)
    |> Enum.flat_map(fn [{at, length}] ->
      from = at + length
      rest = binary_part(lower, from, byte_size(lower) - from)

      case :binary.match(rest, ["{", ";", "}"]) do
        {open, 1} ->
          if :binary.at(rest, open) == ?{,
            do: [{from + open, block_end(rest, open + 1, 1) + from}],
            else: []

        :nomatch ->
          []
      end
    end)
  end

  defp block_end(_rest, at, 0), do: at - 1
  defp block_end(rest, at, _depth) when at >= byte_size(rest), do: byte_size(rest)

  defp block_end(rest, at, depth) do
    case :binary.at(rest, at) do
      ?{ -> block_end(rest, at + 1, depth + 1)
      ?} -> block_end(rest, at + 1, depth - 1)
      _other -> block_end(rest, at + 1, depth)
    end
  end

  @escape ~r/\\(?:([0-9A-Fa-f]{1,6})(?:\r\n|[\t\n\f\r ])?|(\r\n|[\n\f\r])|(.))?/su

  defp decode_escapes(css) do
    if String.contains?(css, "\\") do
      Regex.replace(@escape, css, fn
        _whole, digits, _newline, _other when digits != "" ->
          code_point(String.to_integer(digits, 16))

        _whole, "", newline, _other when newline != "" ->
          ""

        _whole, "", "", other when other != "" ->
          other

        _whole, _digits, _newline, _other ->
          "�"
      end)
    else
      css
    end
  end

  defp code_point(code) when code == 0 or code > 0x10FFFF or code in 0xD800..0xDFFF, do: "�"
  defp code_point(code), do: <<code::utf8>>

  ## srcset

  # The addresses of a `srcset`, by the parsing rules of HTML: each candidate's address
  # runs to white space; one that ends in commas loses them, and has no descriptors.
  defp srcset(value), do: srcset(value, [])

  defp srcset(value, acc) do
    case Regex.replace(~r/\A[\t\n\f\r ,]+/, value, "") do
      "" ->
        Enum.reverse(acc)

      rest ->
        [url | after_url] = Regex.split(~r/[\t\n\f\r ]/, rest, parts: 2)
        after_url = List.first(after_url) || ""

        if String.ends_with?(url, ",") do
          srcset(after_url, [String.trim_trailing(url, ",") | acc])
        else
          srcset(skip_descriptors(after_url, false), [url | acc])
        end
    end
  end

  defp skip_descriptors(<<>>, _parens), do: ""
  defp skip_descriptors(<<?(, rest::binary>>, _parens), do: skip_descriptors(rest, true)
  defp skip_descriptors(<<?), rest::binary>>, _parens), do: skip_descriptors(rest, false)
  defp skip_descriptors(<<?,, rest::binary>>, false), do: rest
  defp skip_descriptors(<<_byte, rest::binary>>, parens), do: skip_descriptors(rest, parens)

  ## Before the parse

  # prescan/1 counts the tags of a page and the attributes of each, as an HTML5 tokenizer
  # reads a tag: `:ok`, `:tags` past `@max_tags`, or `:attributes` past `@max_attributes`
  # on one tag. Which `<` starts a tag depends on the parser's state (a comment, raw text,
  # a quoted value), so every `<` followed by an ASCII letter, `</` too, is read as the
  # start of a tag: the counts are at least the parser's. A tag is read from its start by
  # the tokenizer's states, which depend on nothing before it; two reads in the same state
  # at the same byte go on alike, so they are kept as one, with the higher count, and at
  # most one read per state is kept.
  @doc false
  @spec prescan(binary) :: :ok | :tags | :attributes
  def prescan(bytes) do
    scan(bytes, %{}, 0)
  catch
    :attributes -> :attributes
  end

  defp scan(bytes, active, tags) when map_size(active) == 0 do
    case :binary.match(bytes, "<") do
      :nomatch -> :ok
      {at, 1} -> open(binary_part(bytes, at + 1, byte_size(bytes) - at - 1), active, tags)
    end
  end

  # A read alone inside a quoted value goes on to the closing quote or the next `<`.
  defp scan(bytes, %{dq: count} = active, tags) when map_size(active) == 1,
    do: jump(bytes, ["\"", "<"], active, :dq, count, tags)

  defp scan(bytes, %{sq: count} = active, tags) when map_size(active) == 1,
    do: jump(bytes, ["'", "<"], active, :sq, count, tags)

  defp scan(<<>>, _active, _tags), do: :ok
  defp scan(<<?<, rest::binary>>, active, tags), do: open(rest, step_all(active, ?<), tags)
  defp scan(<<byte, rest::binary>>, active, tags), do: scan(rest, step_all(active, byte), tags)

  defp jump(bytes, stops, active, _state, _count, tags) do
    case :binary.match(bytes, stops) do
      :nomatch -> :ok
      {0, 1} -> step_byte(bytes, active, tags)
      {at, 1} -> step_byte(binary_part(bytes, at, byte_size(bytes) - at), active, tags)
    end
  end

  defp step_byte(<<?<, rest::binary>>, active, tags), do: open(rest, step_all(active, ?<), tags)

  defp step_byte(<<byte, rest::binary>>, active, tags),
    do: scan(rest, step_all(active, byte), tags)

  # After a `<`: a letter, or `/` and a letter, starts a tag.
  defp open(<<letter, rest::binary>>, active, tags) when letter in ?a..?z or letter in ?A..?Z,
    do: start_tag(rest, step_all(active, letter), tags)

  defp open(<<?/, letter, rest::binary>>, active, tags)
       when letter in ?a..?z or letter in ?A..?Z,
       do: start_tag(rest, active |> step_all(?/) |> step_all(letter), tags)

  defp open(rest, active, tags), do: scan(rest, active, tags)

  defp start_tag(_rest, _active, tags) when tags >= @max_tags, do: :tags

  defp start_tag(rest, active, tags),
    do: scan(rest, Map.update(active, :tag_name, 0, &max(&1, 0)), tags + 1)

  defp step_all(active, byte) do
    Enum.reduce(active, %{}, fn {state, count}, acc ->
      case step(state, byte, count) do
        :done -> acc
        {next, count} -> Map.update(acc, next, count, &max(&1, count))
      end
    end)
  end

  defguardp ws(byte) when byte in [?\t, ?\n, ?\f, ?\r, ?\s]

  defp step(:tag_name, byte, n) when ws(byte), do: {:before_name, n}
  defp step(:tag_name, ?/, n), do: {:self_closing, n}
  defp step(:tag_name, ?>, _n), do: :done
  defp step(:tag_name, _byte, n), do: {:tag_name, n}

  defp step(:self_closing, ?>, _n), do: :done
  defp step(:self_closing, byte, n), do: step(:before_name, byte, n)

  defp step(:before_name, byte, n) when ws(byte), do: {:before_name, n}
  defp step(:before_name, byte, n) when byte in [?/, ?>], do: step(:after_name, byte, n)
  defp step(:before_name, _byte, n), do: attribute_start(n)

  defp step(:attr_name, byte, n) when ws(byte) or byte in [?/, ?>], do: step(:after_name, byte, n)
  defp step(:attr_name, ?=, n), do: {:before_value, n}
  defp step(:attr_name, _byte, n), do: {:attr_name, n}

  defp step(:after_name, byte, n) when ws(byte), do: {:after_name, n}
  defp step(:after_name, ?/, n), do: {:self_closing, n}
  defp step(:after_name, ?=, n), do: {:before_value, n}
  defp step(:after_name, ?>, _n), do: :done
  defp step(:after_name, _byte, n), do: attribute_start(n)

  defp step(:before_value, byte, n) when ws(byte), do: {:before_value, n}
  defp step(:before_value, ?", n), do: {:dq, n}
  defp step(:before_value, ?', n), do: {:sq, n}
  defp step(:before_value, ?>, _n), do: :done
  defp step(:before_value, byte, n), do: step(:unq, byte, n)

  defp step(:dq, ?", n), do: {:after_quoted, n}
  defp step(:dq, _byte, n), do: {:dq, n}
  defp step(:sq, ?', n), do: {:after_quoted, n}
  defp step(:sq, _byte, n), do: {:sq, n}

  defp step(:unq, byte, n) when ws(byte), do: {:before_name, n}
  defp step(:unq, ?>, _n), do: :done
  defp step(:unq, _byte, n), do: {:unq, n}

  defp step(:after_quoted, byte, n) when ws(byte), do: {:before_name, n}
  defp step(:after_quoted, ?/, n), do: {:self_closing, n}
  defp step(:after_quoted, ?>, _n), do: :done
  defp step(:after_quoted, byte, n), do: step(:before_name, byte, n)

  defp attribute_start(n) when n >= @max_attributes, do: throw(:attributes)
  defp attribute_start(n), do: {:attr_name, n + 1}

  ## Words

  defp where(ctx), do: "`#{ctx.file}` (screen `#{ctx.id}`)"

  defp tag(:svg, local), do: "the SVG `<#{shorten(local)}>` element"
  defp tag(_ns, local), do: "the `<#{shorten(local)}>` element"

  defp extra(filename),
    do:
      "Remove `#{shown(filename)}` from the version: a mockup version has `screens.json` and " <>
        "one page per screen, and no other file."

  defp index_size(size),
    do: "Shrink `screens.json` to at most #{@index_bytes} bytes: it has #{size} bytes."

  defp index_format,
    do: "Make `screens.json` one JSON document in UTF-8: the file does not parse as JSON."

  defp unreadable(filename),
    do: "Push `#{filename}` again: Qory Apiary could not read it after it was received."

  # A value as a message shows it: on one line, with its control characters replaced,
  # and past 64 characters its first 64 and an ellipsis.
  defp shown(value) do
    line = ExternalText.line(value)
    if String.length(line) > 64, do: String.slice(line, 0, 64) <> "…", else: line
  end

  defp shorten(name), do: shown(name)

  defp lower(value), do: String.downcase(value, :ascii)
  defp squeeze(value), do: String.replace(value, ~r/[\x00-\x20\x7F]/, "")

  defp trim(value), do: Regex.replace(~r/[\t\n\f\r ]+\z/, trim_leading(value), "")
  defp trim_leading(value), do: Regex.replace(~r/\A[\t\n\f\r ]+/, value, "")

  defp stat(path, at) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      _other -> {:error, {{:mockup, unreadable(@index)}, at}}
    end
  end

  defp read(path, filename, at) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, {{:mockup, unreadable(filename)}, at}}
    end
  end
end
