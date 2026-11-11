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
  #     is the screen's title, any other white space kept as it is; and the screens the
  #     page's `<a href>` links lead to are the `to` values of the screen's `links`.
  #
  # The page rules, in short (the contract has them in full): the HTML and SVG elements
  # of `@html_elements` and `@svg_elements`; the attributes of `@global` on every
  # element, `aria-…` and `data-…`, the element's attributes of `@html_attributes` or
  # `@svg_attributes`, and `href` / `xlink:href` on SVG `use` and `image`; `<meta>` as
  # `charset="utf-8"` alone or `name="viewport"` with `content`; an `<a href>` exactly
  # `<id>.html` of a screen; an image address a base64 `data:` URI of PNG, JPEG, GIF or
  # WebP; a fragment `#` and a name with no `%`, compared with the `id`s as written, and
  # no `id` on two elements; a `use` reference a fragment, to an element that is no `use`
  # and contains none, at most 1,000 `use`, and at most 100,000 elements drawn through
  # them and 1,048,576 characters of their attribute values and texts, each `use`
  # counting the elements and characters of its target, the target included; the
  # `input` and `button` types listed; SVG `fill`, `stroke` and `clip-path` with
  # `url(#…)` alone, to a `linearGradient`, `radialGradient` or `clipPath`; on a
  # `clipPath` and inside it, no `use` and no attribute with `url(`; in a
  # `linearGradient` or `radialGradient`, only `stop` elements, and none inside a
  # `stop`; no attribute value with `javascript:`, `vbscript:` or `data:text`, every
  # ASCII white space and control character removed; and the CSS of `<style>` and
  # `style`, read as the tokens of CSS Syntax 3, its comments removed and its escapes
  # decoded: `url(…)` and `src(…)` outside a string only to a `data:` image, or a
  # `data:` font inside `@font-face`, and no `url(#…)`; outside a string no `image()`,
  # `image-set()`, `-webkit-image-set()`, `image-rect()`, `-webkit-image-rect()`,
  # `cross-fade()`, `element()` or `paint()`, and no at-rule `@import`, `@namespace` or
  # `@document`; anywhere, strings included, no `expression(`, `attr(` or
  # `javascript:`; and no property `behavior`, `-moz-binding` or `stroke-dasharray`,
  # each a whole name at the start of a declaration, and no SVG `stroke-dasharray`
  # attribute.
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
  @max_used_elements 100_000
  @max_used_characters 1_048_576

  @html_elements MapSet.new(~w(
    html head body title meta style main header footer nav section article aside div
    span p h1 h2 h3 h4 h5 h6 ul ol li dl dt dd a img picture source figure figcaption
    table caption thead tbody tfoot tr th td colgroup col strong em b i u s small mark
    code pre kbd samp sub sup br hr blockquote q abbr time address details summary label
    input button textarea fieldset legend progress meter output
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

  @cell ~w(colspan rowspan scope headers)
  @range ~w(value min max low high optimum)

  @html_attributes %{
    "a" => MapSet.new(~w(href)),
    "img" => MapSet.new(~w(src srcset alt width height loading decoding)),
    "source" => MapSet.new(~w(srcset type media sizes)),
    "input" =>
      MapSet.new(~w(type name value placeholder checked disabled readonly min max step size)),
    "button" => MapSet.new(~w(type disabled name value)),
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
                         stroke-dashoffset stroke-miterlimit opacity
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
  @refused_at_rules ~w(import namespace document)
  @refused_functions ~w(image image-set -webkit-image-set image-rect -webkit-image-rect
                        cross-fade element paint)
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
      {:error, {:schema, detail}} -> {:error, text_refusal(detail, path, at)}
      {:error, :unreadable} -> {:error, {{:mockup, unreadable(@index)}, at}}
      {:error, _format} -> {:error, {{:mockup, index_format()}, at}}
    end
  end

  # A screen's `title` or a link's `label` that fails the schema's text rule gets a
  # message with the fix first, which names the screen and the link: a schema message
  # quotes the rule's pattern. Every other schema refusal is the schema's.
  defp text_refusal(%{path: place} = detail, path, at) do
    with {:ok, screen, link} <- text_place(place),
         {:ok, %{"screens" => screens}} when is_list(screens) <- decoded(path),
         %{} = screen <- Enum.at(screens, screen),
         {:ok, field, value} <- text_field(screen, link),
         message when is_binary(message) <- text_message(field, value) do
      {{:mockup, message}, at}
    else
      _other -> {:schema, at, detail}
    end
  end

  # The screen's index, and the link's or nil for the title, of a place of the text rule.
  defp text_place(place) do
    case Regex.run(~r/\A#\/screens\/(\d+)\/(?:title|links\/(\d+)\/label)\z/, place) do
      [_all, screen] -> {:ok, String.to_integer(screen), nil}
      [_all, screen, link] -> {:ok, String.to_integer(screen), String.to_integer(link)}
      nil -> :error
    end
  end

  defp decoded(path) do
    with {:ok, bytes} <- File.read(path), do: Jason.decode(bytes)
  end

  defp text_field(%{"title" => title} = screen, nil),
    do: {:ok, "the title of #{screen_name(screen)}", title}

  defp text_field(%{"links" => links} = screen, link) when is_list(links) do
    case Enum.at(links, link) do
      %{"label" => label} = found ->
        to = if is_binary(found["to"]), do: " to `#{shown(found["to"])}`", else: ""
        {:ok, "the label of the link#{to} on #{screen_name(screen)}", label}

      _other ->
        :error
    end
  end

  defp text_field(_screen, _link), do: :error

  defp screen_name(%{"id" => id}) when is_binary(id), do: "screen `#{shown(id)}`"
  defp screen_name(_screen), do: "a screen"

  # The fix for a text that is not 1 to 200 characters with no control character, or
  # nil for a value that is no string.
  defp text_message(field, value) when is_binary(value) do
    cond do
      value == "" ->
        "Write #{field} in `screens.json`: it is empty."

      code_points(value) > 200 ->
        "Shorten #{field} in `screens.json` to at most 200 characters: it has " <>
          "#{code_points(value)}."

      Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, value) ->
        "Remove the control character from #{field} in `screens.json`: a tab, a line " <>
          "feed and every other control character are refused."

      true ->
        nil
    end
  end

  defp text_message(_field, _value), do: nil

  # The rules of screens.json that its schema cannot check, each at its place.
  defp cross(%{"start" => start, "screens" => screens}) do
    ids = Enum.map(screens, & &1["id"])

    with :ok <- unique(ids),
         :ok <- files(screens),
         :ok <- titles(screens),
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
              "use an id that no earlier screen has: `#{id}` is the id of an earlier screen"
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
             "use `#{id}.html`, the screen's id and `.html`"
           )}
    end)
  end

  # A page's `<title>` is compared with its white space collapsed, so a title with a
  # space at its start or end, or two spaces in a row, matches no page.
  defp titles(screens) do
    screens
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {%{"title" => title}, at} ->
      if collapse(title) != title,
        do:
          {:error,
           SchemaError.detail(
             "#/screens/#{at}/title",
             "write the title with no space at its start or end and one space between " <>
               "words: a page's <title> is compared with its white space collapsed, so " <>
               "this title matches no page"
           )}
    end)
  end

  defp start(start, ids) do
    if start in ids,
      do: :ok,
      else: {:error, SchemaError.detail("#/start", "use the id of a screen, not `#{start}`")}
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
               "use the id of a screen, not `#{to}`"
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
             "add a link to `#{id}` on the start screen, or on a screen that its links " <>
               "reach: they do not reach `#{id}`"
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
      drawn_refs: [],
      sizes: %{},
      url_refs: [],
      ids: %{},
      blocked: MapSet.new()
    }

    try do
      {_contains_use, _size, acc} = nodes(tree, :html, nil, false, ctx, acc)
      :ok = use_refs(Enum.reverse(acc.use_refs), acc.blocked, ctx)
      :ok = used_elements(acc.drawn_refs, acc.sizes, ctx)
      :ok = url_refs(Enum.reverse(acc.url_refs), acc.ids, ctx)
      :ok = title(Enum.reverse(acc.titles), title, ctx)
      {:ok, acc.linked}
    catch
      {:refused, message} -> {:error, message}
    end
  end

  defp refuse(message), do: throw({:refused, message})

  # The nodes, children of an element in `parent_ns` named `parent`, inside a `clipPath`
  # where `clip?`: whether one is or contains a `use`, their size (how many elements they
  # are with every element inside them, and how many characters their attribute values
  # and texts have), and the walk's findings.
  defp nodes(nodes, parent_ns, parent, clip?, ctx, acc) do
    Enum.reduce(nodes, {false, {0, 0}, acc}, fn
      {name, attributes, children}, {contains, {count, chars}, acc} when is_binary(name) ->
        {use?, {size, size_chars}, acc} =
          element(name, attributes, children, {parent_ns, parent, clip?}, ctx, acc)

        {contains or use?, {count + size, chars + size_chars}, acc}

      text, {contains, {count, chars}, acc} when is_binary(text) ->
        {contains, {count, chars + code_points(text)}, acc}

      _comment, result ->
        result
    end)
  end

  defp element(name, attributes, children, {parent_ns, parent, clip?}, ctx, acc) do
    local = String.downcase(name, :ascii)
    ns = namespace(parent_ns, parent, local)
    allowed!(ns, local, ctx)

    if parent_ns == :svg and parent in ~w(lineargradient radialgradient),
      do: stop!(ns, local, parent, ctx)

    if parent_ns == :svg and parent == "stop",
      do:
        refuse(
          "Remove #{tag(ns, local)} from the `<stop>` in #{where(ctx)}: a `<stop>` of a " <>
            "mockup page has no element inside it."
        )

    attributes =
      Enum.map(attributes, fn {key, value} -> {String.downcase(key, :ascii), value} end)

    if ns == :html and local == "meta", do: meta!(attributes, ctx)
    if clip? or (ns == :svg and local == "clippath"), do: clip!(ns, local, attributes, ctx)
    acc = id(attributes, ns, local, ctx, acc)

    acc = Enum.reduce(attributes, acc, &attribute(&1, ns, local, ctx, &2))
    acc = if ns == :svg and local == "use", do: drawn_ref(attributes, acc), else: acc

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

    {contains, {count, chars}, acc} =
      nodes(children, ns, local, clip? or (ns == :svg and local == "clippath"), ctx, acc)

    contains = contains or use?

    size =
      {count + 1,
       Enum.reduce(attributes, chars, fn {_name, value}, sum -> sum + code_points(value) end)}

    acc =
      case List.keyfind(attributes, "id", 0) do
        {"id", id} when contains ->
          %{acc | blocked: MapSet.put(acc.blocked, id), sizes: Map.put(acc.sizes, id, size)}

        {"id", id} ->
          %{acc | sizes: Map.put(acc.sizes, id, size)}

        nil ->
          acc
      end

    {contains, size, acc}
  end

  # A gradient has only `stop` elements: a browser draws nothing else in one.
  defp stop!(:svg, "stop", _parent, _ctx), do: :ok

  defp stop!(ns, local, parent, ctx) do
    gradient = if parent == "lineargradient", do: "linearGradient", else: "radialGradient"

    refuse(
      "Remove #{tag(ns, local)} from the `<#{gradient}>` in #{where(ctx)}: a gradient of a " <>
        "mockup page has only `<stop>` elements."
    )
  end

  # What the `use` of a page draw: each `use` the elements of its target with the target,
  # at most `@max_used_elements` in all, and the characters of their attribute values and
  # texts, in code points, at most `@max_used_characters`. Each target's size is counted
  # once, in the walk.
  defp used_elements(refs, sizes, ctx) do
    {elements, characters} =
      Enum.reduce(refs, {0, 0}, fn "#" <> id, {elements, characters} ->
        {size, chars} = Map.get(sizes, id, {0, 0})
        {elements + size, characters + chars}
      end)

    if elements > @max_used_elements,
      do:
        refuse(
          "Draw at most #{@max_used_elements} elements through `<use>` in #{where(ctx)}: " <>
            "each `<use>` draws the elements of its target, the target included, and the " <>
            "page has #{elements}."
        )

    if characters > @max_used_characters,
      do:
        refuse(
          "Draw at most #{@max_used_characters} characters through `<use>` in " <>
            "#{where(ctx)}: each `<use>` draws the attribute values and texts of its " <>
            "target, the target included, and the page has #{characters}."
        )

    :ok
  end

  # The code points of UTF-8 `text`: every byte but a continuation byte.
  defp code_points(text), do: code_points(text, 0)
  defp code_points(<<byte, rest::binary>>, n) when byte in 0x80..0xBF, do: code_points(rest, n)
  defp code_points(<<_byte, rest::binary>>, n), do: code_points(rest, n + 1)
  defp code_points(<<>>, n), do: n

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

  # On a `clipPath` and inside it, no `use` and no attribute with `url(`: a browser draws
  # a clip path again for each element that points at it.
  defp clip!(:svg, "use", _attributes, ctx),
    do:
      refuse(
        "Remove the SVG `<use>` element from the `<clipPath>` in #{where(ctx)}: a " <>
          "`<clipPath>` of a mockup page has no `<use>`."
      )

  defp clip!(ns, local, attributes, ctx) do
    case Enum.find(attributes, fn {_name, value} -> String.contains?(lower(value), "url(") end) do
      {name, _value} ->
        refuse(
          "Remove the `url(` from the `#{shorten(name)}` attribute of #{tag(ns, local)} in " <>
            "#{where(ctx)}: a `<clipPath>` and the elements inside it point at no other " <>
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

  # A `use` with both `href` and `xlink:href` draws the target of `href` alone, as a
  # browser does: the address of `xlink:href` leaves the targets drawn.
  defp drawn_ref(attributes, acc) do
    if List.keymember?(attributes, "href", 0) and List.keymember?(attributes, "xlink:href", 0),
      do: %{acc | drawn_refs: drawn_without_xlink(attributes, acc.drawn_refs)},
      else: acc
  end

  # The attributes are read in order, so the address of `xlink:href` is the first of
  # the two at the head of `drawn`, if it comes after `href`, else the second.
  defp drawn_without_xlink(attributes, [last, first | drawn]) do
    names = attributes |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in ~w(href xlink:href)))

    case names do
      ["href", "xlink:href"] -> [first | drawn]
      ["xlink:href", "href"] -> [last | drawn]
    end
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

    %{acc | use_refs: [{name, address} | acc.use_refs], drawn_refs: [address | acc.drawn_refs]}
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
  # `url(#…)` alone. Read as the tokens of CSS Syntax 3 (`tokens/2`), so a comment, a
  # string and a `url(` token are each one token, in one pass: `expression(`, `attr(`
  # and `javascript:` anywhere in the text, strings included; at-rules, functions,
  # addresses and property names as tokens. The contract checks CSS after its comments
  # are removed, so the text without them, where `ur/**/l(` is `url(`, is read as tokens
  # again and checked the same way. The comments are the tokens', so a `/*` inside a
  # string or a `url(` hides nothing. The fragments, in order.
  defp css!(css, mode, place, ctx) do
    css = css |> String.replace("\r\n", "\n") |> String.replace(["\r", "\f"], "\n")
    css = String.replace(css, <<0>>, "\uFFFD")
    spot = "#{place} in #{where(ctx)}"
    tokens = tokens(css, [])
    fragments = css_check!(tokens, mode, spot)

    case uncommented(css, tokens) do
      ^css ->
        fragments

      text ->
        _again = css_check!(tokens(text, []), mode, spot)
        fragments
    end
  end

  defp css_check!(tokens, mode, spot) do
    anywhere!(tokens, spot)
    state = %{mode: mode, spot: spot, blocks: [], font_faces: 0, font_face?: false}
    css_walk(tokens, mode == :declarations, state, [])
  end

  # The CSS without its comments: each comment token is the bytes between two sizes of
  # what was left to read.
  defp uncommented(css, tokens) do
    total = byte_size(css)

    {parts, at} =
      Enum.reduce(tokens, {[], 0}, fn
        {:comment, left, after_left}, {parts, at} ->
          from = total - left
          {[binary_part(css, at, from - at) | parts], total - after_left}

        _token, acc ->
          acc
      end)

    case parts do
      [] -> css
      parts -> IO.iodata_to_binary(Enum.reverse([binary_part(css, at, total - at) | parts]))
    end
  end

  # The CSS's text after its comments are removed and its escapes decoded, strings and
  # their quotes included: `expression(`, `attr(` and `javascript:` are refused anywhere
  # in it, without regard to case.
  defp anywhere!(tokens, spot) do
    text = tokens |> Enum.map(&css_text/1) |> IO.iodata_to_binary() |> lower()

    cond do
      String.contains?(text, "expression(") ->
        refuse("Remove `expression()` from #{spot}: a mockup page runs no script.")

      String.contains?(text, "attr(") ->
        refuse("Remove `attr()` from #{spot}: the mockup format lists no `attr()`.")

      String.contains?(text, "javascript:") ->
        refuse(
          "Remove `javascript:` from #{spot}: a mockup page runs no script and opens no " <>
            "address."
        )

      true ->
        :ok
    end
  end

  # The tokens in order, one pass. `start?` is whether a declaration can start at the
  # next token: after `{`, `;` or `}`, and at the start of a `style` attribute.
  defp css_walk([], _start?, _state, fragments), do: Enum.reverse(fragments)

  defp css_walk([:ws | rest], start?, state, fragments),
    do: css_walk(rest, start?, state, fragments)

  defp css_walk([{:comment, _left, _after} | rest], start?, state, fragments),
    do: css_walk(rest, start?, state, fragments)

  defp css_walk([{:at, name} | rest], _start?, state, fragments) do
    case lower(name) do
      rule when rule in @refused_at_rules ->
        refuse(
          "Remove `@#{rule}` from #{state.spot}: a mockup page loads nothing from outside " <>
            "the version."
        )

      "font-face" ->
        css_walk(rest, false, %{state | font_face?: true}, fragments)

      _other ->
        css_walk(rest, false, %{state | font_face?: false}, fragments)
    end
  end

  defp css_walk([:lbrace | rest], _start?, state, fragments) do
    state = %{
      state
      | blocks: [state.font_face? | state.blocks],
        font_faces: state.font_faces + if(state.font_face?, do: 1, else: 0),
        font_face?: false
    }

    css_walk(rest, true, state, fragments)
  end

  defp css_walk([:rbrace | rest], _start?, state, fragments) do
    state =
      case state.blocks do
        [font_face? | blocks] ->
          %{
            state
            | blocks: blocks,
              font_faces: state.font_faces - if(font_face?, do: 1, else: 0),
              font_face?: false
          }

        [] ->
          %{state | font_face?: false}
      end

    css_walk(rest, true, state, fragments)
  end

  defp css_walk([:semicolon | rest], _start?, state, fragments),
    do: css_walk(rest, true, %{state | font_face?: false}, fragments)

  defp css_walk([{:ident, name} | rest], true, state, fragments) do
    if next_significant(rest) == :colon, do: property!(lower(name), state.spot)
    css_walk(rest, false, state, fragments)
  end

  defp css_walk([{:url, value} | rest], _start?, state, fragments),
    do: css_walk(rest, false, state, address(value, state, fragments))

  defp css_walk([{:bad_url, raw} | _rest], _start?, state, _fragments),
    do: refuse(address_refusal(state.mode, raw, state.spot))

  defp css_walk([{:function, name} | rest], _start?, state, fragments) do
    case lower(name) do
      function when function in @refused_functions ->
        refuse(
          "Remove `#{function}()` from #{state.spot}: a mockup page loads nothing from " <>
            "outside the version."
        )

      function when function in ["url", "src"] ->
        {value, rest} = function_argument(rest)
        css_walk(rest, false, state, address(value, state, fragments))

      _other ->
        css_walk(rest, false, state, fragments)
    end
  end

  defp css_walk([_token | rest], _start?, state, fragments),
    do: css_walk(rest, false, state, fragments)

  defp next_significant([:ws | rest]), do: next_significant(rest)
  defp next_significant([{:comment, _left, _after} | rest]), do: next_significant(rest)
  defp next_significant([token | _rest]), do: token
  defp next_significant([]), do: nil

  defp property!("behavior", spot),
    do: refuse("Remove the `behavior` property from #{spot}: a mockup page runs no script.")

  defp property!("-moz-binding", spot),
    do: refuse("Remove the `-moz-binding` property from #{spot}: a mockup page runs no script.")

  defp property!("stroke-dasharray", spot),
    do:
      refuse(
        "Remove the `stroke-dasharray` property from #{spot}: a mockup page draws no " <>
          "dashed SVG stroke, which takes a browser long to paint."
      )

  defp property!(_name, _spot), do: :ok

  # The address of a `url(` or `src(` function: a string, or else the text of its
  # tokens up to its `)`, trimmed; and the tokens after it.
  defp function_argument(tokens) do
    case drop_ws(tokens) do
      [{:string, value, _quote, _closed?} | rest] -> {value, rest}
      rest -> function_text(rest, 0, [])
    end
  end

  defp function_text([], _depth, text), do: {text |> Enum.reverse() |> to_text(), []}

  defp function_text([:rparen | rest], 0, text),
    do: {text |> Enum.reverse() |> to_text(), rest}

  defp function_text([:rparen | rest], depth, text),
    do: function_text(rest, depth - 1, [")" | text])

  defp function_text([token | rest], depth, text)
       when token == :lparen or elem(token, 0) == :function,
       do: function_text(rest, depth + 1, [css_text(token) | text])

  defp function_text([token | rest], depth, text),
    do: function_text(rest, depth, [css_text(token) | text])

  defp to_text(iodata), do: iodata |> IO.iodata_to_binary() |> trim()

  defp drop_ws([:ws | rest]), do: drop_ws(rest)
  defp drop_ws([{:comment, _left, _after} | rest]), do: drop_ws(rest)
  defp drop_ws(tokens), do: tokens

  # An address of the CSS: in `:fragment` mode a fragment alone, else a `data:` image, or
  # inside `@font-face` a `data:` font.
  defp address(value, %{mode: :fragment} = state, fragments) do
    if fragment?(value),
      do: [value | fragments],
      else: refuse(address_refusal(:fragment, value, state.spot))
  end

  defp address(value, state, fragments) do
    cond do
      Regex.match?(@data_image, value) -> fragments
      state.font_faces > 0 and Regex.match?(@data_font, value) -> fragments
      true -> refuse(address_refusal(state.mode, value, state.spot))
    end
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

  # A token's text, its escapes decoded: a string with its quotes, a comment as nothing.
  defp css_text(:ws), do: " "
  defp css_text({:comment, _left, _after}), do: ""
  defp css_text(:colon), do: ":"
  defp css_text(:semicolon), do: ";"
  defp css_text(:comma), do: ","
  defp css_text(:lbrace), do: "{"
  defp css_text(:rbrace), do: "}"
  defp css_text(:lparen), do: "("
  defp css_text(:rparen), do: ")"
  defp css_text(:lbracket), do: "["
  defp css_text(:rbracket), do: "]"
  defp css_text({:ident, name}), do: name
  defp css_text({:function, name}), do: [name, "("]
  defp css_text({:at, name}), do: ["@", name]
  defp css_text({:hash, name}), do: ["#", name]
  defp css_text({:string, value, quote, true}), do: [quote, value, quote]
  defp css_text({:string, value, quote, false}), do: [quote, value]
  defp css_text({:url, value}), do: ["url(", value, ")"]
  defp css_text({:bad_url, raw}), do: raw
  defp css_text({:delim, text}), do: text
  defp css_text({:other, text}), do: text

  ## CSS tokens

  # tokens/2 is the tokens of CSS Syntax 3, section 4, in one pass over the bytes, which
  # `css!/4` preprocessed (`\r\n`, `\r` and `\f` made `\n`, NUL made U+FFFD): a comment
  # is `{:comment, left, after}`, the sizes of what was left to read before and after
  # it; an escape is decoded; a string runs to its closing quote, to a line feed (a bad
  # string, its text kept as a string's), or to the end; `url(` with no quote is a `url`
  # token, or a bad URL; a `\` that is a valid escape starts a name. A number, a CDO and
  # a CDC are `:other` tokens. `:ws` is a run of white space.
  defguardp css_ws(c) when c in [?\n, ?\t, ?\s]
  defguardp name_start(c) when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 0x80
  defguardp name_char(c) when name_start(c) or c in ?0..?9 or c == ?-
  defguardp digit(c) when c in ?0..?9

  @punctuation %{
    ?: => :colon,
    ?; => :semicolon,
    ?, => :comma,
    ?{ => :lbrace,
    ?} => :rbrace,
    ?( => :lparen,
    ?) => :rparen,
    ?[ => :lbracket,
    ?] => :rbracket
  }

  defp tokens(<<>>, acc), do: Enum.reverse(acc)

  defp tokens(<<"/*", rest::binary>> = bytes, acc) do
    rest = comment_end(rest)
    tokens(rest, [{:comment, byte_size(bytes), byte_size(rest)} | acc])
  end

  defp tokens(<<c, _::binary>> = s, acc) when css_ws(c), do: tokens(skip_ws(s), [:ws | acc])

  defp tokens(<<quote, rest::binary>>, acc) when quote in [?", ?'] do
    {value, closed?, rest} = string(rest, quote, [])
    tokens(rest, [{:string, value, <<quote>>, closed?} | acc])
  end

  defp tokens(<<?#, rest::binary>>, acc) do
    if name_next?(rest) do
      {name, rest} = name(rest, [])
      tokens(rest, [{:hash, name} | acc])
    else
      tokens(rest, [{:delim, "#"} | acc])
    end
  end

  defp tokens(<<?@, rest::binary>>, acc) do
    if ident_start?(rest) do
      {name, rest} = name(rest, [])
      tokens(rest, [{:at, name} | acc])
    else
      tokens(rest, [{:delim, "@"} | acc])
    end
  end

  defp tokens(<<"<!--", rest::binary>>, acc), do: tokens(rest, [{:other, "<!--"} | acc])
  defp tokens(<<"-->", rest::binary>>, acc), do: tokens(rest, [{:other, "-->"} | acc])

  defp tokens(<<c, rest::binary>> = s, acc) do
    cond do
      Map.has_key?(@punctuation, c) -> tokens(rest, [Map.fetch!(@punctuation, c) | acc])
      number_start?(s) -> number(s, acc)
      ident_start?(s) -> ident_like(s, acc)
      true -> delim(s, acc)
    end
  end

  defp delim(<<c::utf8, rest::binary>>, acc), do: tokens(rest, [{:delim, <<c::utf8>>} | acc])

  defp comment_end(<<"*/", rest::binary>>), do: rest
  defp comment_end(<<>>), do: <<>>

  defp comment_end(bytes) do
    case :binary.match(bytes, "*/") do
      {at, 2} -> binary_part(bytes, at + 2, byte_size(bytes) - at - 2)
      :nomatch -> <<>>
    end
  end

  defp skip_ws(<<c, rest::binary>>) when css_ws(c), do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  # Whether the bytes start a name: a name character or a valid escape.
  defp name_next?(<<c, _::binary>>) when name_char(c), do: true
  defp name_next?(bytes), do: valid_escape?(bytes)

  defp valid_escape?(<<?\\, c, _::binary>>), do: c != ?\n
  defp valid_escape?(_bytes), do: false

  # Whether the bytes start an ident sequence (CSS Syntax 3, 4.3.9).
  defp ident_start?(<<?-, c, _::binary>>) when name_start(c) or c == ?-, do: true
  defp ident_start?(<<?-, rest::binary>>), do: valid_escape?(rest)
  defp ident_start?(<<c, _::binary>>) when name_start(c), do: true
  defp ident_start?(bytes), do: valid_escape?(bytes)

  defp number_start?(<<sign, c, _::binary>>) when sign in [?+, ?-] and digit(c), do: true
  defp number_start?(<<sign, ?., c, _::binary>>) when sign in [?+, ?-] and digit(c), do: true
  defp number_start?(<<?., c, _::binary>>) when digit(c), do: true
  defp number_start?(<<c, _::binary>>) when digit(c), do: true
  defp number_start?(_bytes), do: false

  # A name (CSS Syntax 3, 4.3.12), its escapes decoded, and the bytes after it.
  defp name(<<c, rest::binary>>, acc) when name_char(c) and c < 0x80, do: name(rest, [c | acc])

  defp name(<<c::utf8, rest::binary>>, acc) when c >= 0x80,
    do: name(rest, [<<c::utf8>> | acc])

  defp name(<<?\\, _::binary>> = bytes, acc) do
    if valid_escape?(bytes) do
      {char, rest} = escape(binary_part(bytes, 1, byte_size(bytes) - 1))
      name(rest, [char | acc])
    else
      {acc |> Enum.reverse() |> IO.iodata_to_binary(), bytes}
    end
  end

  defp name(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  # An escape after its `\` (CSS Syntax 3, 4.3.7): up to 6 hex digits and one white space
  # after them, else the next code point; at the end, U+FFFD.
  defp escape(<<>>), do: {"�", <<>>}

  defp escape(<<c, _::binary>> = bytes) when c in ?0..?9 or c in ?a..?f or c in ?A..?F do
    {hex, rest} = hex(bytes, [], 0)

    rest =
      case rest do
        <<w, after_ws::binary>> when css_ws(w) -> after_ws
        _other -> rest
      end

    {code_point(String.to_integer(hex, 16)), rest}
  end

  defp escape(<<c::utf8, rest::binary>>), do: {<<c::utf8>>, rest}

  defp hex(<<c, rest::binary>>, acc, n)
       when n < 6 and (c in ?0..?9 or c in ?a..?f or c in ?A..?F),
       do: hex(rest, [c | acc], n + 1)

  defp hex(rest, acc, _n), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp code_point(code) when code == 0 or code > 0x10FFFF or code in 0xD800..0xDFFF, do: "�"
  defp code_point(code), do: <<code::utf8>>

  # A string after its opening quote: its text, whether a closing quote ends it, and the
  # bytes after it. A line feed ends a bad string and stays in the input.
  defp string(<<>>, _quote, acc), do: {iodata(acc), false, <<>>}
  defp string(<<quote, rest::binary>>, quote, acc), do: {iodata(acc), true, rest}
  defp string(<<?\n, _::binary>> = rest, _quote, acc), do: {iodata(acc), false, rest}
  defp string(<<?\\>>, _quote, acc), do: {iodata(acc), false, <<>>}
  defp string(<<?\\, ?\n, rest::binary>>, quote, acc), do: string(rest, quote, acc)

  defp string(<<?\\, rest::binary>>, quote, acc) do
    {char, rest} = escape(rest)
    string(rest, quote, [char | acc])
  end

  defp string(bytes, quote, acc) do
    # The bytes up to the next quote, `\` or line feed, at once.
    case :binary.match(bytes, [<<quote>>, "\\", "\n"]) do
      {at, 1} ->
        string(binary_part(bytes, at, byte_size(bytes) - at), quote, [
          binary_part(bytes, 0, at) | acc
        ])

      :nomatch ->
        {iodata([bytes | acc]), false, <<>>}
    end
  end

  defp iodata(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A number, a percentage or a dimension, as `:other`.
  defp number(bytes, acc) do
    {sign, rest} =
      case bytes do
        <<s, rest::binary>> when s in [?+, ?-] -> {<<s>>, rest}
        _other -> {"", bytes}
      end

    {int, rest} = digits(rest, [])

    {fraction, rest} =
      case rest do
        <<?., d, _::binary>> when digit(d) ->
          {digits, rest} = digits(binary_part(rest, 1, byte_size(rest) - 1), [])
          {"." <> digits, rest}

        _other ->
          {"", rest}
      end

    {exponent, rest} =
      case rest do
        <<e, s, d, _::binary>> when e in [?e, ?E] and s in [?+, ?-] and digit(d) ->
          {digits, rest} = digits(binary_part(rest, 2, byte_size(rest) - 2), [])
          {<<e, s>> <> digits, rest}

        <<e, d, _::binary>> when e in [?e, ?E] and digit(d) ->
          {digits, rest} = digits(binary_part(rest, 1, byte_size(rest) - 1), [])
          {<<e>> <> digits, rest}

        _other ->
          {"", rest}
      end

    number = sign <> int <> fraction <> exponent

    cond do
      ident_start?(rest) ->
        {unit, rest} = name(rest, [])
        tokens(rest, [{:other, number <> unit} | acc])

      match?(<<?%, _::binary>>, rest) ->
        tokens(binary_part(rest, 1, byte_size(rest) - 1), [{:other, number <> "%"} | acc])

      true ->
        tokens(rest, [{:other, number} | acc])
    end
  end

  defp digits(<<d, rest::binary>>, acc) when digit(d), do: digits(rest, [d | acc])
  defp digits(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  # An ident, a function, or a `url(` with no quote (CSS Syntax 3, 4.3.4).
  defp ident_like(bytes, acc) do
    {name, rest} = name(bytes, [])

    case rest do
      <<?(, after_paren::binary>> ->
        if lower(name) == "url" do
          case skip_ws(after_paren) do
            <<quote, _::binary>> when quote in [?", ?'] ->
              tokens(after_paren, [{:function, name} | acc])

            unquoted ->
              {token, rest} = url(unquoted, [])
              tokens(rest, [token | acc])
          end
        else
          tokens(after_paren, [{:function, name} | acc])
        end

      _other ->
        tokens(rest, [{:ident, name} | acc])
    end
  end

  # A `url(` token after its white space (CSS Syntax 3, 4.3.6).
  defp url(<<>>, acc), do: {{:url, iodata(acc)}, <<>>}
  defp url(<<?), rest::binary>>, acc), do: {{:url, iodata(acc)}, rest}

  defp url(<<c, _::binary>> = bytes, acc) when css_ws(c) do
    case skip_ws(bytes) do
      <<>> -> {{:url, iodata(acc)}, <<>>}
      <<?), rest::binary>> -> {{:url, iodata(acc)}, rest}
      rest -> bad_url(rest, [" " | acc])
    end
  end

  defp url(<<c, _::binary>> = bytes, acc)
       when c in [?", ?', ?(] or c in 0x00..0x08 or c == 0x0B or c in 0x0E..0x1F or c == 0x7F,
       do: bad_url(bytes, acc)

  defp url(<<?\\, _::binary>> = bytes, acc) do
    if valid_escape?(bytes) do
      {char, rest} = escape(binary_part(bytes, 1, byte_size(bytes) - 1))
      url(rest, [char | acc])
    else
      bad_url(bytes, acc)
    end
  end

  defp url(<<c::utf8, rest::binary>>, acc), do: url(rest, [<<c::utf8>> | acc])

  # The rest of a bad URL, to its `)` or the end (CSS Syntax 3, 4.3.14).
  defp bad_url(<<>>, acc), do: {{:bad_url, iodata(acc)}, <<>>}
  defp bad_url(<<?), rest::binary>>, acc), do: {{:bad_url, iodata(acc)}, rest}

  defp bad_url(<<?\\, _::binary>> = bytes, acc) do
    if valid_escape?(bytes) do
      {char, rest} = escape(binary_part(bytes, 1, byte_size(bytes) - 1))
      bad_url(rest, [char | acc])
    else
      bad_url(binary_part(bytes, 1, byte_size(bytes) - 1), ["\\" | acc])
    end
  end

  defp bad_url(<<c::utf8, rest::binary>>, acc), do: bad_url(rest, [<<c::utf8>> | acc])

  ## srcset

  # The addresses of a `srcset`, by the parsing rules of HTML, in one pass: each
  # candidate's address runs to white space; one that ends in commas loses them, and has
  # no descriptors.
  defp srcset(value), do: srcset(value, [])

  defp srcset(value, acc) do
    case skip_separators(value) do
      <<>> ->
        Enum.reverse(acc)

      rest ->
        {url, after_url} =
          case :binary.match(rest, [" ", "\t", "\n", "\f", "\r"]) do
            {at, 1} ->
              {binary_part(rest, 0, at), binary_part(rest, at + 1, byte_size(rest) - at - 1)}

            :nomatch ->
              {rest, <<>>}
          end

        if String.ends_with?(url, ",") do
          srcset(after_url, [String.trim_trailing(url, ",") | acc])
        else
          srcset(skip_descriptors(after_url, false), [url | acc])
        end
    end
  end

  defp skip_separators(<<c, rest::binary>>) when c in [?\t, ?\n, ?\f, ?\r, ?\s, ?,],
    do: skip_separators(rest)

  defp skip_separators(rest), do: rest

  defp skip_descriptors(<<>>, _parens), do: ""
  defp skip_descriptors(<<?(, rest::binary>>, _parens), do: skip_descriptors(rest, true)
  defp skip_descriptors(<<?), rest::binary>>, _parens), do: skip_descriptors(rest, false)
  defp skip_descriptors(<<?,, rest::binary>>, false), do: rest
  defp skip_descriptors(<<_byte, rest::binary>>, parens), do: skip_descriptors(rest, parens)

  ## Before the parse

  # prescan/1 counts the tags of a page and the attributes of each, as an HTML5 tokenizer
  # reads a tag: `:ok`, `:tags` past `@max_tags`, or `:attributes` past `@max_attributes`
  # on one tag. Only a `<` followed by an ASCII letter counts toward `@max_tags`, as the
  # contract counts tags, anywhere in the source. Which `<` starts a tag depends on the
  # parser's state (a comment, raw text, a quoted value), so for the attribute count
  # every `<` or `</` followed by an ASCII letter is read as the start of a tag, an end
  # tag's attributes included: that count is at least the parser's. A tag is read from
  # its start by the tokenizer's states, which depend on nothing before it; two reads in
  # the same state at the same byte go on alike, so they are kept as one, with the higher
  # count, and at most one read per state is kept.
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

  # After a `<`: a letter starts a tag, counted toward `@max_tags`; `/` and a letter
  # starts an end tag, not counted there, whose attributes the tokenizer reads too.
  defp open(<<letter, rest::binary>>, active, tags) when letter in ?a..?z or letter in ?A..?Z,
    do: start_tag(rest, step_all(active, letter), tags + 1)

  defp open(<<?/, letter, rest::binary>>, active, tags)
       when letter in ?a..?z or letter in ?A..?Z,
       do: start_tag(rest, active |> step_all(?/) |> step_all(letter), tags)

  defp open(rest, active, tags), do: scan(rest, active, tags)

  defp start_tag(_rest, _active, tags) when tags > @max_tags, do: :tags

  defp start_tag(rest, active, tags),
    do: scan(rest, Map.update(active, :tag_name, 0, &max(&1, 0)), tags)

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
