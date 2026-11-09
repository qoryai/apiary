defmodule ApiaryWeb.Contract.RunApi.Body do
  @moduledoc false

  # The bodies of the run API's two POSTs, read from the raw bytes the request was signed
  # over, each held to its size before it is decoded.
  #
  # - `push/1`: `{"type", "name"?, "note"?, "files": [{"filename", "content_type",
  #   "content_base64"}]}`, at most `max_bytes(:push)` bytes. The file contents stay
  #   base64 here; `decode_files/1` decodes them once the type's limits have been checked
  #   against their decoded sizes (`decoded_size/1`).
  # - `verdict/1`: `{"verdict", "points"?}`, at most `max_bytes(:verdict)` bytes. The
  #   points pass as they are: the schema of the type `verdict` checks them
  #   (`priv/schemas/artifacts/verdict.schema.json`).
  #
  # A member the body does not define, a member of the wrong form or a body that is not a
  # JSON object is `{:error, :invalid_request, member}`, where `member` is the path of the
  # first member that failed, such as `files[0].filename`. A body over its size is
  # `{:error, :too_large}`.

  alias ApiaryWeb.Contract.RunApi.Boundary

  # A push of base64 JSON: at most 32 MiB encoded, about 24 MiB of files decoded. A larger
  # version cannot be pushed through this API, whatever the type's size limit.
  @push_max_bytes 32 * 1024 * 1024
  @verdict_max_bytes 64 * 1024

  # A media type: `type/subtype`, without parameters.
  @content_type ~r/\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\z/
  # The characters a note may not contain, as `Apiary.Artifacts` checks them: control and
  # format characters and the line and paragraph separators, but tab, line feed, U+200C and
  # U+200D. Carriage return passes too: `Apiary.Artifacts` turns it into a line feed
  # before its check.
  @refused_in_note ~r/(?![\x{9}\x{A}\x{D}\x{200C}\x{200D}])[\p{Cc}\p{Cf}\x{2028}\x{2029}]/u
  @max_note 4000
  @max_files 100

  @verdicts ["passed", "changes-requested", "escalate"]

  @spec max_bytes(:push | :verdict) :: pos_integer
  def max_bytes(:push), do: @push_max_bytes
  def max_bytes(:verdict), do: @verdict_max_bytes

  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @spec push(binary) ::
          {:ok, %{type: String.t(), name: String.t(), note: String.t() | nil, files: [map]}}
          | {:error, :too_large}
          | {:error, :invalid_request, String.t()}
  def push(raw_body) when byte_size(raw_body) > @push_max_bytes, do: {:error, :too_large}

  def push(raw_body) do
    with {:ok, body} <- object(raw_body),
         :ok <- members(body, ~w(type name note files)),
         {:ok, type} <- required(body, "type", &name?/1),
         {:ok, name} <- optional(body, "name", &name?/1, "main"),
         {:ok, note} <- optional(body, "note", &note?/1, nil),
         {:ok, files} <- files(body["files"]) do
      {:ok, %{type: type, name: name, note: note, files: files}}
    end
  end

  @spec verdict(binary) ::
          {:ok, %{verdict: String.t(), points: term}}
          | {:error, :too_large}
          | {:error, :invalid_request, String.t()}
  def verdict(raw_body) when byte_size(raw_body) > @verdict_max_bytes, do: {:error, :too_large}

  def verdict(raw_body) do
    with {:ok, body} <- object(raw_body),
         :ok <- members(body, ~w(verdict points)),
         {:ok, verdict} <- required(body, "verdict", &(&1 in @verdicts)) do
      {:ok, %{verdict: verdict, points: Map.get(body, "points")}}
    end
  end

  # decoded_size/1 is the size in bytes of a file's content once decoded, read from the
  # length of its base64 alone.
  @spec decoded_size(map) :: non_neg_integer
  def decoded_size(%{content_base64: encoded}) do
    padding =
      cond do
        String.ends_with?(encoded, "==") -> 2
        String.ends_with?(encoded, "=") -> 1
        true -> 0
      end

    max(div(byte_size(encoded), 4) * 3 - padding, 0)
  end

  # decode_files/1 is the files with their contents decoded, as `Apiary.Artifacts.push/5`
  # takes them, or the member whose content is not strict base64.
  @spec decode_files([map]) :: {:ok, [map]} | {:error, :invalid_request, String.t()}
  def decode_files(files) do
    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, decoded} ->
      case Base.decode64(file.content_base64) do
        {:ok, binary} ->
          entry = %{filename: file.filename, content_type: file.content_type, binary: binary}
          {:cont, {:ok, [entry | decoded]}}

        :error ->
          {:halt, {:error, :invalid_request, "files[#{index}].content_base64"}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp object(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = body} -> {:ok, body}
      _other -> {:error, :invalid_request, "body"}
    end
  end

  defp members(body, known) do
    case Enum.sort(Map.keys(body) -- known) do
      [] -> :ok
      [member | _] when byte_size(member) <= 64 -> {:error, :invalid_request, member}
      [_long | _] -> {:error, :invalid_request, "body"}
    end
  end

  defp required(body, member, valid?) do
    case Map.fetch(body, member) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid(member)
      :error -> invalid(member)
    end
  end

  defp optional(body, member, valid?, default) do
    case Map.fetch(body, member) do
      {:ok, nil} -> {:ok, default}
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: invalid(member)
      :error -> {:ok, default}
    end
  end

  defp files([_ | _] = files) when length(files) <= @max_files do
    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, read} ->
      case file(file, index) do
        {:ok, file} -> {:cont, {:ok, [file | read]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, read} -> unique(Enum.reverse(read))
      error -> error
    end
  end

  defp files(_files), do: invalid("files")

  defp file(%{} = file, index) do
    member = &"files[#{index}].#{&1}"

    with :ok <- prefixed(members(file, ~w(filename content_type content_base64)), member),
         {:ok, filename} <- prefixed(required(file, "filename", &Boundary.filename?/1), member),
         {:ok, content_type} <-
           prefixed(required(file, "content_type", &content_type?/1), member),
         {:ok, encoded} <- prefixed(required(file, "content_base64", &is_binary/1), member) do
      {:ok, %{filename: filename, content_type: content_type, content_base64: encoded}}
    end
  end

  defp file(_file, index), do: invalid("files[#{index}]")

  defp prefixed({:error, :invalid_request, name}, member), do: invalid(member.(name))
  defp prefixed(result, _member), do: result

  # Two files of one version under one filename: the second is an error.
  defp unique(files) do
    files
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {file, index}, seen ->
      if MapSet.member?(seen, file.filename),
        do: {:halt, invalid("files[#{index}].filename")},
        else: {:cont, MapSet.put(seen, file.filename)}
    end)
    |> case do
      %MapSet{} -> {:ok, files}
      error -> error
    end
  end

  defp name?(value), do: Boundary.name?(value)

  defp content_type?(value), do: is_binary(value) and Regex.match?(@content_type, value)

  defp note?(value) do
    is_binary(value) and String.valid?(value) and code_points(value) <= @max_note and
      not Regex.match?(@refused_in_note, value)
  end

  # The length counted in code points, never graphemes: a letter with any number of
  # combining marks is one grapheme.
  defp code_points(text), do: text |> String.codepoints() |> length()

  defp invalid(member), do: {:error, :invalid_request, member}
end
