defmodule ApiaryWeb.Contract.RunApi.Controller do
  @moduledoc false

  # The run API: a run's reads of its work item and that work item's artifacts, and its
  # pushes of artifacts and its verdict, under `/v1/runs/<run_id>/`, as the run's gateway
  # sends them. With the feature `workflow_model`; docs/contract/run-api.md is the
  # contract.
  #
  # Each request comes through the run endpoint's pipeline (`:contract_registration`):
  # `ApiaryWeb.Contract.SignedRequest` verifies it under the gateway's access key, in the
  # contract's order of refusals, spends the run endpoint's bucket of the key's rate limit
  # and signs every answer to a verified request. Then, in order:
  #
  #   1. where the instance does not have `workflow_model`, `404` with the error page,
  #      signed: the same body and type as a path the router does not know;
  #   2. a run whose gateway is not the key's (`ApiaryWeb.Contract.RunApi.Run`) is `404`
  #      `not_found`, and so is, for a file, a version id or a filename the run's
  #      work item does not have: another run's version, another work item's and an
  #      unknown one get the same answer;
  #   3. for a push and a verdict, a run that has ended is `409` `run_ended`, then a body
  #      over its size `413` `payload_too_large`, then a body outside the contract `400`
  #      `invalid_request` with the member in `names`;
  #   4. for a push: a type the workspace does not have, or a standard type it hides, is
  #      `422` `unknown_type`, whose message says to define the type, or for a standard
  #      type to switch it on; a type the run's workflow may not write `403`
  #      `type_not_writable`; more files than the type takes `422` `too_many_files`; files
  #      over the type's size limit together `422` `too_large`; then a content that is not
  #      strict base64 `400` `invalid_request`; then what `Apiary.Artifacts.push/5` returns,
  #      the files that do not match the type's format among it, `422` `invalid_artifact`.
  #
  # A file is sent from the store, with `send_file` or in chunks, and signed over the
  # SHA-256 Qory Apiary computed from its bytes when it stored them. It is served as a
  # download (`Content-Disposition: attachment`) with
  # `X-Content-Type-Options: nosniff` and the directive `sandbox` added to its
  # `Content-Security-Policy`, and HTML, SVG, XML and script types as
  # `application/octet-stream`, so no artifact is shown inline from Qory Apiary's origin.
  # The content type is the stored one, read from the file's bytes at the push
  # (`Apiary.Artifacts.Format`), with `charset=utf-8` for a text type.
  #
  # Errors are short JSON; nothing logs the body, the signature or the headers. An
  # exception is `503` `unavailable`, logged by its module's name alone.

  use ApiaryWeb, :controller

  require Logger

  alias Apiary.PublicId
  alias ApiaryWeb.Contract.Configuration
  alias ApiaryWeb.Contract.RunApi.{Body, Boundary, Run, Wire}

  # Types a browser could run as a page or a script: served as plain bytes.
  @unsafe_type ~r/html|xml|svg|javascript|ecmascript/i
  @content_type ~r/\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}(; charset=utf-8)?\z/

  plug :workflow_model

  @doc false
  # The feature `ApiaryWeb.Features.Routes` reads for the run API's routes
  # (`ApiaryWeb.Contract.RunApi.Boundary.route_feature/0`).
  def __feature__, do: Boundary.route_feature()

  ## Reads

  def work_item(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- run(conn, run_id),
         {:ok, body} <- Wire.work_item(run, newest_verdict(run.work_item)) do
      answer(conn, 200, body)
    else
      {:error, :not_found} -> error(conn, 404, "not_found")
      {:error, :ticket_gone} -> error(conn, 410, "ticket_gone")
      {:error, :inputs_invalid} -> error(conn, 409, "inputs_invalid")
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  def index(conn, %{"run_id" => run_id}) do
    case run(conn, run_id) do
      {:ok, run} -> answer(conn, 200, Wire.index(Boundary.artifact_index(run.work_item)))
      {:error, :not_found} -> error(conn, 404, "not_found")
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  def file(conn, %{"run_id" => run_id, "version_id" => version_id, "filename" => filename}) do
    with {:ok, run} <- run(conn, run_id),
         {:ok, version} <- version(run.work_item, version_id),
         {:ok, file} <- file_of(version, filename),
         {:ok, source} <- opened(file) do
      conn
      |> put_resp_header("content-disposition", disposition(filename))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", sandboxed(conn))
      |> put_resp_content_type(served_type(field(file, :content_type)), nil)
      |> put_private(:qory_body_sha256, field(file, :sha256))
      |> send_stored(source)
    else
      {:error, :not_found} -> error(conn, 404, "not_found")
      {:error, :unreadable} -> error(conn, 503, "unavailable")
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  ## Writes

  def push(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- run(conn, run_id),
         :ok <- live(run),
         {:ok, push} <- Body.push(conn.assigns.raw_body),
         workspace = run.work_item.workspace,
         {:ok, type} <- known_type(workspace, push.type),
         :ok <- writable(workspace, run, push.type),
         :ok <- within(type, push),
         {:ok, files} <- Body.decode_files(push.files),
         {:ok, version} <-
           Boundary.push({:run, run.dispatch_run}, run.work_item, push.type, files,
             name: push.name,
             stage_id: Boundary.stage_id(run.dispatch_run),
             note: push.note,
             writes: Boundary.writes(workspace, Boundary.workflow(run.dispatch_run))
           )
           |> pushed(%{
             name: push.type,
             type: type,
             workflow: Boundary.workflow(run.dispatch_run),
             filenames: Enum.map(files, & &1.filename)
           }) do
      answer(conn, 201, Wire.version(version, push.type, push.name))
    else
      error -> write_error(conn, error)
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  def verdict(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- run(conn, run_id),
         :ok <- live(run),
         {:ok, verdict} <- Body.verdict(conn.assigns.raw_body),
         content = verdict_json(verdict),
         file = %{filename: "verdict.json", content_type: "application/json", binary: content},
         {:ok, version} <-
           Boundary.push({:run, run.dispatch_run}, run.work_item, "verdict", [file],
             name: "main",
             stage_id: Boundary.stage_id(run.dispatch_run),
             note: nil,
             writes: :any
           )
           |> pushed(%{
             name: "verdict",
             type: nil,
             workflow: Boundary.workflow(run.dispatch_run),
             filenames: ["verdict.json"]
           }) do
      answer(conn, 201, Wire.version(version, "verdict", "main"))
    else
      error -> write_error(conn, error)
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  # The policy `ApiaryWeb.ContentSecurityPolicy` set for the answer, with the directive
  # `sandbox` added.
  defp sandboxed(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [policy | _rest] -> policy <> "; sandbox"
      [] -> "sandbox"
    end
  end

  # The verdict's file, as the schema of the type `verdict` takes it: `gaps` only where
  # the body has it.
  defp verdict_json(%{verdict: verdict, gaps: nil}), do: Jason.encode!(%{"verdict" => verdict})

  defp verdict_json(%{verdict: verdict, gaps: gaps}),
    do: Jason.encode!(Jason.OrderedObject.new([{"verdict", verdict}, {"gaps", gaps}]))

  ## The feature

  # Where the instance does not have `workflow_model`, the answer a verified request to a
  # route of a feature that is off gets (`ApiaryWeb.Features`): the error page's `404`,
  # signed.
  defp workflow_model(conn, _opts) do
    if Boundary.on?() do
      conn
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(404, ApiaryWeb.ErrorHTML.render("404.html", %{}))
      |> halt()
    end
  end

  ## The run

  defp run(conn, run_id),
    do: Run.fetch(conn.assigns.access_key, run_id, conn.assigns[:instance_id])

  defp live(run), do: if(Run.live?(run), do: :ok, else: {:error, :run_ended})

  ## Versions and files

  # The version `version_id` (`av_...`), of the run's work item and only there: a version
  # of another work item is not found, as an unknown or malformed id is.
  # `Apiary.Artifacts.get_version!/1` checks no work item, so the version's artifact is
  # compared with the run's work item here.
  defp version(work_item, version_id) do
    with true <- PublicId.valid?("av", version_id),
         version = Boundary.get_version!(version_id),
         %{work_item_id: work_item_id} when work_item_id == work_item.id <-
           field(version, :artifact) do
      {:ok, version}
    else
      _other -> {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # The file of `version` whose filename is exactly `filename`: the name is compared, never
  # used as a path.
  defp file_of(version, filename) do
    case Enum.find(files(version), &(field(&1, :filename) === filename)) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  # The files of a version, which every read of `Apiary.Artifacts` loads.
  defp files(version) do
    case field(version, :files) do
      files when is_list(files) -> files
      _not_loaded -> []
    end
  end

  # The stored copy of a file, a path on disk or a stream of its bytes; one that cannot be
  # opened is not the run's error.
  defp opened(file) do
    case Boundary.open_file(file) do
      {:ok, path} when is_binary(path) -> {:ok, {:path, path}}
      {:ok, stream} -> {:ok, {:stream, stream}}
      _error -> {:error, :unreadable}
    end
  end

  # The file sent from the store, never read into one binary: a path with `send_file`, a
  # stream in chunks. The answer is signed over the stored SHA-256
  # (`ApiaryWeb.Contract.SignedAnswer`, `conn.private[:qory_body_sha256]`).
  defp send_stored(conn, {:path, path}), do: send_file(conn, 200, path)

  defp send_stored(conn, {:stream, stream}) do
    Enum.reduce_while(stream, send_chunked(conn, 200), fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp read(file) do
    case Boundary.open_file(file) do
      {:ok, path} when is_binary(path) -> File.read(path)
      {:ok, stream} -> {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  # The newest verdict of the work item, with its content, for the work item's answer.
  defp newest_verdict(work_item) do
    case Boundary.newest(work_item, "verdict") do
      nil ->
        nil

      version ->
        content =
          with [file | _] <- files(version),
               {:ok, bytes} <- read(file),
               {:ok, %{} = content} <- Jason.decode(bytes) do
            content
          else
            _unreadable -> nil
          end

        Wire.verdict(version, content)
    end
  end

  defp served_type(type) when is_binary(type) do
    if Regex.match?(@content_type, type) and not Regex.match?(@unsafe_type, type),
      do: String.downcase(type),
      else: "application/octet-stream"
  end

  defp served_type(_type), do: "application/octet-stream"

  # A download under the file's name: an ASCII fallback, and the name itself encoded as
  # RFC 6266 has it.
  defp disposition(filename) do
    fallback = String.replace(filename, ~r/[^A-Za-z0-9._-]/u, "_")
    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end

  ## Pushes

  defp known_type(workspace, name) do
    case Boundary.type(workspace, name) do
      nil -> {:error, {:unknown_type, name}}
      type -> {:ok, type}
    end
  end

  defp writable(workspace, run, type) do
    workflow = Boundary.workflow(run.dispatch_run)

    if Boundary.writable?(workspace, workflow, type),
      do: :ok,
      else: {:error, {:not_writable, type, workflow}}
  end

  # The type's maximum file count and size limit, checked before any content is decoded.
  # The size limit bounds all files of one version together.
  defp within(type, push) do
    max_files = field(type, :max_files)
    size_limit = field(type, :size_limit)
    total = push.files |> Enum.map(&Body.decoded_size/1) |> Enum.sum()

    cond do
      is_integer(max_files) and length(push.files) > max_files ->
        {:error, {:too_many_files, push.type, max_files}}

      is_integer(size_limit) and total > size_limit ->
        {:error, {:too_large, push.type, size_limit}}

      true ->
        :ok
    end
  end

  # What `Apiary.Artifacts.push/5` returns, turned into the run API's errors: the push's
  # type, the type's limit and the member at fault, never another detail of the push.
  # `push` has the type's name (`name`), the type (`type`, nil where it was not read),
  # the run's workflow and the filenames in the order of the files.
  defp pushed({:ok, version}, _push), do: {:ok, version}
  defp pushed({:error, refusal}, push), do: refused(refusal, push)
  defp pushed(_error, _push), do: {:error, :unavailable}

  defp refused({:unknown_type, _name}, push), do: {:error, {:unknown_type, push.name}}

  defp refused({:not_writable, _type}, push),
    do: {:error, {:not_writable, push.name, push.workflow}}

  defp refused({:too_many_files, max_files}, push),
    do: {:error, {:too_many_files, push.name, limit(max_files, push.type, :max_files)}}

  defp refused({:too_large, size_limit}, push),
    do: {:error, {:too_large, push.name, limit(size_limit, push.type, :size_limit)}}

  defp refused({:invalid, member}, _push) when member in [:type, :name, :note],
    do: {:error, :invalid_request, Atom.to_string(member)}

  defp refused({:invalid, :no_files}, _push), do: {:error, :invalid_request, "files"}

  defp refused({:invalid, {:file, index}}, _push) when is_integer(index),
    do: {:error, :invalid_request, "files[#{index}]"}

  defp refused({:invalid, {member, index}}, _push)
       when member in [:filename, :duplicate_filename] and is_integer(index),
       do: {:error, :invalid_request, "files[#{index}].filename"}

  defp refused({:invalid, {check, index}}, push)
       when check in [:format, :extension, :unreadable] and is_integer(index),
       do:
         {:error,
          {:invalid_artifact, "files[#{index}]",
           mismatch(check, Enum.at(push.filenames, index) || "files[#{index}]", push)}}

  # A failed schema check, with the JSON pointer of the first failing value and JSV's message
  # for it, as `Apiary.Artifacts.SchemaError` returns them: text, written as it is.
  defp refused({:invalid, {:schema, index, %{path: path, error: error}}}, push)
       when is_integer(index) do
    filename = Enum.at(push.filenames, index) || "files[#{index}]"

    {:error,
     {:invalid_artifact, "files[#{index}]",
      "Fix #{filename} to match the format of #{push.name}: at #{path}, #{error}."}}
  end

  defp refused({:invalid, :no_video}, push),
    do:
      {:error,
       {:invalid_artifact, "files",
        "Add an MP4 or WebM video to the version of #{push.name}: " <>
          "a WebVTT file goes with a video."}}

  # A run of another work item; the person's refusals never come to a run.
  defp refused(code, _push) when code in [:not_found, :forbidden], do: {:error, :not_found}

  defp refused(_refusal, _push), do: {:error, :unavailable}

  # The message of a file that `Apiary.Artifacts` refuses by its format check: the file,
  # the type and what the type's base view takes.
  defp mismatch(:unreadable, filename, _push),
    do: "Push #{filename} again: Qory Apiary could not read it after it was received."

  defp mismatch(check, filename, push),
    do: "Fix #{filename} to match the format of #{push.name}: #{takes(check, push)}."

  defp takes(:extension, _push), do: "the filename of a document ends in .md"

  defp takes(:format, push) do
    case field(push.type, :base_view) do
      :document -> "a document is a Markdown file of UTF-8 text"
      :image -> "an image is a PNG, JPEG, GIF, WebP or SVG file"
      :video -> "a file is an MP4 or WebM video, or a WebVTT file (.vtt)"
      _structured -> "the file is one JSON document"
    end
  end

  defp limit(limit, _type, _key) when is_integer(limit), do: limit
  defp limit(_limit, type, key), do: field(type, key)

  defp write_error(conn, {:error, :not_found}), do: error(conn, 404, "not_found")

  defp write_error(conn, {:error, :run_ended}) do
    error(conn, 409, "run_ended",
      message: "The run has ended, so it can no longer push artifacts or give a verdict."
    )
  end

  defp write_error(conn, {:error, :too_large}), do: error(conn, 413, "payload_too_large")

  defp write_error(conn, {:error, :invalid_request, member}) do
    conn |> put_status(400) |> json(%{error: "invalid_request", names: [member]})
  end

  defp write_error(conn, {:error, {:unknown_type, type}}) do
    error(conn, 422, "unknown_type",
      type: type,
      message:
        if(Boundary.standard?(type),
          do:
            "Switch on the artifact type #{type} in the workspace's Artifact types, " <>
              "then run the round again.",
          else:
            "Define the artifact type #{type} in the workspace's Artifact types, " <>
              "then run the round again."
        )
    )
  end

  defp write_error(conn, {:error, {:not_writable, type, workflow}}) do
    error(conn, 403, "type_not_writable",
      type: type,
      message:
        "Add the artifact type #{type} to the writes list of the workflow#{named(workflow)}, " <>
          "or push a type that the workflow writes."
    )
  end

  defp write_error(conn, {:error, {:too_many_files, type, limit}}) do
    error(conn, 422, "too_many_files",
      type: type,
      limit: limit,
      message:
        if(is_integer(limit),
          do: "Push at most #{file_count(limit)} in one version of #{type}.",
          else: "Push fewer files in one version of #{type}."
        )
    )
  end

  defp write_error(conn, {:error, {:too_large, type, limit}}) do
    error(conn, 422, "too_large",
      type: type,
      limit: limit,
      message:
        if(is_integer(limit),
          do: "Shrink the files of one version of #{type} to at most #{limit} bytes together.",
          else:
            "Shrink the files of one version of #{type}; together they are over its size limit."
        )
    )
  end

  defp write_error(conn, {:error, {:invalid_artifact, member, message}}) do
    error(conn, 422, "invalid_artifact", names: [member], message: message)
  end

  defp write_error(conn, _error), do: error(conn, 503, "unavailable")

  defp file_count(1), do: "1 file"
  defp file_count(limit), do: "#{limit} files"

  defp named(nil), do: ""
  defp named(workflow), do: " " <> workflow

  ## Answers

  defp answer(conn, status, body) do
    conn
    |> put_resp_header("x-qory-configuration", Configuration.digest(conn.assigns.access_key))
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end

  defp error(conn, status, code, members \\ []) do
    conn
    |> put_status(status)
    |> json(Jason.OrderedObject.new([{"error", code} | strings(members)]))
  end

  defp strings(members),
    do: Enum.map(members, fn {key, value} -> {Atom.to_string(key), value} end)

  defp unavailable(conn, exception) do
    Logger.error("a run API request failed: #{inspect(exception.__struct__)}")
    error(conn, 503, "unavailable")
  end

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
