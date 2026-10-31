defmodule Apiary.Artifacts.Format do
  # Format checks that a file of an artifact's version is what its type's base view shows
  # (`Apiary.Artifacts.Type`), from the file's bytes alone: what the writer says the file
  # is never counts. `check/3` reads the file at a local path, a staged copy or a stored
  # one, and returns the content type its bytes show, which is the one Qory Apiary keeps.
  #
  #   * document: Markdown, a filename that ends in `.md` (any case) and bytes that are
  #     UTF-8 text with no NUL; `text/markdown; charset=utf-8`.
  #   * image: PNG, JPEG, GIF or WebP by their first bytes; or SVG, at most 512 KiB, UTF-8,
  #     with no document type declaration (so no entity is declared), that an XML parser
  #     reads to its end with a root element `svg` in the SVG namespace,
  #     `http://www.w3.org/2000/svg`. The parse runs in another process within a budget
  #     (`Apiary.Kinds.Budget`).
  #   * video: MP4, an `ftyp` box first with an MP4 brand, or WebM, an EBML header whose
  #     document type is `webm`.
  #   * file: any bytes; `application/octet-stream`.
  #   * structured: one JSON document valid against the type's JSON Schema: a standard
  #     type's file under `priv/schemas/artifacts/`, a custom type's in its row
  #     (`Apiary.Artifacts.CustomSchema`); `application/json`.
  #
  # A refusal is `{:error, reason}`: `:format` for bytes the base view does not take,
  # `:extension` for a document whose filename does not end in `.md`, `:schema` for a
  # structured document the schema refuses, and `:unreadable` for a file that cannot be
  # read.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  alias Apiary.Artifacts.{CustomSchema, Type}
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
  @mp4_brands ~w(isom iso2 iso3 iso4 iso5 iso6 iso8 iso9 mp41 mp42 avc1 dash mmp4) ++
                ["M4V ", "M4VP"]

  # The bounds of a standard type's document beyond the lists and members its schema
  # allows: values in all, the longest string and the deepest nesting.
  @standard_limits [nodes: 65_536, string: 131_072, depth: 16]

  # The keywords whose value is data, not a schema: their members are left as they are.
  @data_keywords ~w(const enum default examples)

  @markdown "text/markdown; charset=utf-8"
  @json "application/json"

  # The content types `check/3` returns, by base view; a file view takes any.
  @content_types %{
    document: [@markdown],
    image: ~w(image/png image/jpeg image/gif image/webp image/svg+xml),
    video: ~w(video/mp4 video/webm),
    structured: [@json]
  }

  @typedoc "Why a file is refused."
  @type refusal :: :format | :extension | :schema | :unreadable

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

  def check(%Type{base_view: :video}, _filename, path) do
    with {:ok, head} <- head(path) do
      case video(head) do
        nil -> {:error, :format}
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

  def stored?(base_view, content_types) when is_list(content_types) do
    taken = Map.fetch!(@content_types, base_view)
    Enum.all?(content_types, &(&1 in taken))
  end

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

  ## SVG

  defp svg(path) do
    with {:ok, %File.Stat{size: size}} when size <= @svg_bytes <- stat(path),
         {:ok, bytes} <- read(path),
         true <- String.valid?(bytes),
         false <- declares_type?(bytes),
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

  defp decode(bytes) do
    with true <- String.valid?(bytes),
         {:ok, document} <- Jason.decode(bytes) do
      {:ok, document}
    else
      _refused -> {:error, :format}
    end
  end

  defp structured(%Type{standard: true, schema_path: path}, document) when is_list(path) do
    limits = Bounds.file!(path) ++ @standard_limits

    case Schema.validate(document, Schema.file!(path, &code_point_lengths/1), limits) do
      :ok -> :ok
      {:error, _summary} -> {:error, :schema}
    end
  end

  defp structured(%Type{json_schema: schema}, document) when is_map(schema) do
    case CustomSchema.validate(document, schema) do
      :ok -> :ok
      {:error, _refusal} -> {:error, :schema}
    end
  end

  defp structured(_type, _document), do: {:error, :schema}

  # JSV counts `minLength` and `maxLength` in graphemes, and a standard type's schema
  # counts code points, as JSON Schema does: each object with an integer `minLength` or
  # `maxLength` gets the bounds as a pattern instead, `^[\s\S]{min,max}$`, which PCRE in
  # UTF mode counts in code points. The members of `const`, `enum`, `default` and
  # `examples` are data and stay as they are.
  defp code_point_lengths(schema) when is_map(schema) do
    schema =
      Map.new(schema, fn
        {keyword, value} when keyword in @data_keywords -> {keyword, value}
        {keyword, value} -> {keyword, code_point_lengths(value)}
      end)

    case Map.split(schema, ["minLength", "maxLength"]) do
      {bounds, rest} when bounds != %{} ->
        min = Map.get(bounds, "minLength", 0)
        max = Map.get(bounds, "maxLength")

        if is_integer(min) and (is_integer(max) or is_nil(max)),
          do: %{"allOf" => [rest, %{"pattern" => "^[\\s\\S]{#{min},#{max}}$"}]},
          else: schema

      _none ->
        schema
    end
  end

  defp code_point_lengths(list) when is_list(list), do: Enum.map(list, &code_point_lengths/1)
  defp code_point_lengths(other), do: other

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
