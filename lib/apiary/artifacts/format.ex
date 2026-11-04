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
  #     standard type has each member name once in each object, which a JSON parser
  #     does not check: Jason keeps the last of two, another parser may keep the first,
  #     so the second is refused at its place, before the schema reads the document.
  #
  # A refusal is `{:error, reason}`: `:format` for bytes the base view does not take,
  # `:extension` for a document whose filename does not end in `.md`,
  # `{:schema, detail}` for a structured document the schema refuses, `detail` its first
  # failing place (`Apiary.Artifacts.SchemaError`), and `:unreadable` for a file that
  # cannot be read.
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
    "review-comments" => [list: 65_536, members: 7]
  }

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
  @type refusal :: :format | :extension | {:schema, SchemaError.t()} | :unreadable

  # check/3 is `{:ok, content_type}` for the file at `path`, named `filename`, that the
  # base view of `type` takes, else `{:error, refusal}`.
  @doc false
  @spec check(Type.t(), String.t(), Path.t()) :: {:ok, String.t()} | {:error, refusal}
  def check(%Type{base_view: :file}, _filename, _path), do: {:ok, "application/octet-stream"}

  def check(%Type{base_view: :document}, filename, path) do
    if String.downcase(Path.extname(filename)) == ".md" do
      with {:ok, bytes} <- read(path) do
        if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
          do: {:ok, @markdown},
          else: {:error, :format}
      end
    else
      {:error, :extension}
    end
  end

  def check(%Type{base_view: :image}, _filename, path) do
    with {:ok, head} <- head(path) do
      case image(head) do
        nil -> svg(path)
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

  # stored?/2 is whether the content types of a version's files, as `check/3` returned
  # them at the push, are a version `base_view` takes: one file or more, each of a content
  # type of the base view, and, for a structured view, exactly one. The files of a version
  # never change after its push, so the Exists check of a stage's output reads these
  # (`Apiary.Artifacts.exists?/3`) and reads no file again.
  @doc false
  @spec stored?(Type.base_view(), [String.t()]) :: boolean
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

  defp svg(path) do
    with {:ok, %File.Stat{size: size}} when size <= @svg_bytes <- stat(path),
         {:ok, bytes} <- read(path),
         true <- String.valid?(bytes),
         false <- declares_type?(bytes),
         true <- attributes_within?(bytes),
         {:ok, :svg} <- Budget.run(fn -> svg_root(:binary.copy(bytes)) end, @svg_budget) do
      {:ok, "image/svg+xml"}
    else
      {:error, :unreadable} -> {:error, :unreadable}
      _refused -> {:error, :format}
    end
  end

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
  defp svg_root(bytes) do
    event = fn
      {:startElement, uri, name, _qualified, _attributes}, _location, :none ->
        if uri == @svg_namespace and name == ~c"svg", do: :svg, else: :other

      _event, _location, state ->
        state
    end

    case :xmerl_sax_parser.stream(bytes,
           event_fun: event,
           event_state: :none,
           external_entities: :none,
           fail_undeclared_ref: true
         ) do
      {:ok, :svg, rest} -> if blank?(rest), do: :svg, else: :other
      _other -> :other
    end
  end

  defp blank?(rest) when is_binary(rest), do: String.trim(rest) == ""
  defp blank?(rest) when is_list(rest), do: rest |> List.to_string() |> String.trim() == ""
  defp blank?(_rest), do: false

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
