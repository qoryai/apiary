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
  #   3. for a push and a verdict, a run that has ended is `409` `run_ended`, read here
  #      and again under the work item's lock (`Apiary.Artifacts.push/5`), then a body
  #      over its size `413` `payload_too_large`, then a body outside the contract `400`
  #      `invalid_request` with the member in `names`;
  #   4. for a push: a type the workspace does not have, or a standard type it hides, is
  #      `422` `unknown_type`, whose message says to define the type, or for a standard
  #      type to switch it on; more files than the type takes `422` `too_many_files`; files
  #      over the type's size limit together `422` `too_large`; then a content that is not
  #      strict base64 `400` `invalid_request`; then what `Apiary.Artifacts.push/5` returns,
  #      the files that do not match the type's format among it, `422` `invalid_artifact`;
  #      a run's version of `questions` or `review-comments` that changes what members
  #      wrote, `422` `invalid_artifact` with the rule it breaks; and a version of
  #      `questions` or `review-comments` whose file is over the size limit as stored,
  #      with each number that is an integer in value written as an integer (`1e3` as
  #      `1000`), `422` `too_large`.
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
  # The transcript of a paused run (`GET /resume/transcript`) is the file of the run that
  # the request's run continues (`Apiary.Runs.Transcript`): sent in chunks, signed over
  # its SHA-256, as `application/x-ndjson`. A run that ended, a run that continues no
  # paused run, a paused run that is no longer the one it continues, and a transcript that
  # is gone, has a gap in its offsets or is over 64 MiB are each `404` `not_found`, as a
  # run the key may not read is. No transcript byte is logged or put in an error.
  #
  # Errors are short JSON; nothing logs the body, the signature or the headers. An
  # exception is `503` `unavailable`, logged by its module's name alone.

  use ApiaryWeb, :controller

  require Logger

  alias Apiary.Artifacts.Format
  alias Apiary.PublicId
  alias Apiary.Runs.Transcript
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

  def transcript(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- run(conn, run_id),
         :ok <- live(run),
         %Apiary.Runs.Run{} = paused <- Transcript.paused_run(run.dispatch_run),
         %{path: path} <- Transcript.last(paused.id),
         {:ok, file} <- Transcript.file(paused.id, path) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("application/x-ndjson", nil)
      |> put_private(:qory_body_sha256, file.sha256)
      |> send_stored({:stream, Transcript.stream(paused.id, path)})
    else
      _none -> error(conn, 404, "not_found")
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
         :ok <- within(type, push),
         {:ok, files} <- Body.decode_files(push.files),
         {:ok, version} <-
           Boundary.push({:run, run.dispatch_run}, run.work_item, push.type, files,
             name: push.name,
             stage_id: Boundary.push_stage_id(run.dispatch_run, run.work_item),
             note: push.note
           )
           |> pushed(%{
             name: push.type,
             type: type,
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
             stage_id: Boundary.push_stage_id(run.dispatch_run, run.work_item),
             note: nil
           )
           |> pushed(%{
             name: "verdict",
             type: nil,
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

  # The verdict's file, as the schema of the type `verdict` takes it: `points` only where
  # the body has them, which the schema then checks.
  defp verdict_json(%{verdict: verdict, points: nil}), do: Jason.encode!(%{"verdict" => verdict})

  defp verdict_json(%{verdict: verdict, points: points}),
    do: Jason.encode!(Jason.OrderedObject.new([{"verdict", verdict}, {"points", points}]))

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
  # `push` has the type's name (`name`), the type (`type`, nil where it was not read) and
  # the filenames in the order of the files.
  defp pushed({:ok, version}, _push), do: {:ok, version}
  defp pushed({:error, refusal}, push), do: refused(refusal, push)
  defp pushed(_error, _push), do: {:error, :unavailable}

  defp refused({:unknown_type, _name}, push), do: {:error, {:unknown_type, push.name}}

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
       when check in [
              :format,
              :extension,
              :unreadable,
              :document_size,
              :image_type,
              :svg_format,
              :svg_root
            ] and
              is_integer(index),
       do:
         {:error,
          {:invalid_artifact, "files[#{index}]",
           mismatch(check, Enum.at(push.filenames, index) || "files[#{index}]", push)}}

  # A proposal's SVG that fails the strict check, with the part refused
  # (`Apiary.Artifacts.Format`).
  defp refused({:invalid, {{:svg_content, part}, index}}, push) when is_integer(index) do
    filename = Enum.at(push.filenames, index) || "files[#{index}]"

    {:error,
     {:invalid_artifact, "files[#{index}]",
      "Remove #{part} from #{filename}. An SVG in a proposal uses only the elements and " <>
        "attributes the run API document lists, with no script, HTML or reference outside " <>
        "the file."}}
  end

  # A failed schema check, with the JSON pointer of the first failing value and JSV's message
  # for it, as `Apiary.Artifacts.SchemaError` returns them: text, written as it is.
  defp refused({:invalid, {:schema, index, %{path: path, error: error}}}, push)
       when is_integer(index) do
    filename = Enum.at(push.filenames, index) || "files[#{index}]"

    {:error,
     {:invalid_artifact, "files[#{index}]",
      "Fix #{filename} to match #{schema_of(push.name, filename)}: at #{path}, #{error}."}}
  end

  # A run's version of the questions or the review comments that changes what members
  # wrote, or of the questions with a decision that does not match its question
  # (`Apiary.Artifacts.push/5`): the rule it breaks.
  defp refused({:invalid, {:kept, index, reason}}, push) when is_integer(index) do
    filename = Enum.at(push.filenames, index) || "files[#{index}]"
    {:error, {:invalid_artifact, "files[#{index}]", kept(push.name, reason, filename)}}
  end

  defp refused({:invalid, :one_markdown}, push),
    do:
      {:error,
       {:invalid_artifact, "files",
        "Push one Markdown file (.md) in each version of #{push.name}."}}

  defp refused({:invalid, :no_video}, push),
    do:
      {:error,
       {:invalid_artifact, "files",
        "Add an MP4 or WebM video to the version of #{push.name}: " <>
          "a WebVTT file goes with a video."}}

  # A run of another work item; the person's refusals never come to a run.
  defp refused(code, _push) when code in [:not_found, :forbidden], do: {:error, :not_found}

  # A run that ended after `live/1` read it, found ended under the work item's lock.
  defp refused(:run_ended, _push), do: {:error, :run_ended}

  defp refused(_refusal, _push), do: {:error, :unavailable}

  # The format a refused file is fixed to: for a proposal's sources.json, the proposal
  # sources format; for a structured type's file, its type's. The format also refuses a key
  # that comes twice in an object, which no JSON Schema keyword checks.
  defp schema_of("proposal", "sources.json"), do: "the format of proposal sources"
  defp schema_of(type, _filename), do: "the format of #{type}"

  # The message of a run's version that changes what members wrote, or has a decision that
  # does not match its question, by the rule it breaks
  # (`Apiary.Explore.Questions`, `Apiary.Explore.ReviewComments`).
  defp kept("questions", reason, filename) do
    case reason do
      :id_dropped ->
        "Keep every question of the newest version of questions in #{filename}: " <>
          "the id of a question is missing."

      :asked_changed ->
        "Leave asked of each question in #{filename} as the newest version of " <>
          "questions has it."

      :follows_changed ->
        "Leave follows of each question in #{filename} as the newest version of " <>
          "questions has it."

      :order_changed ->
        "Keep the questions of the newest version of questions first in #{filename}, " <>
          "in the same order, and add new questions after them."

      :answer_changed ->
        "Leave each answer in #{filename} as the newest version of questions has it: " <>
          "members write the answers."

      :history_changed ->
        "Leave the history of each question in #{filename} as the newest version of " <>
          "questions has it, and give a new question no history."

      :reopen_not_kept ->
        "Move the answer of a question you reopen, unchanged, to the end of its history " <>
          "in #{filename}."

      :reopened_run ->
        "Set reopened.run in the history of each question you reopen in #{filename} " <>
          "to this run's number."

      :answered_changed ->
        "Leave question, context and options of each answered question in " <>
          "#{filename} as the newest version of questions has them."

      :new_not_open ->
        "Add each question in #{filename} as open, with no decision, or as decided, " <>
          "with its decision."

      :asked_run ->
        "Set asked.run of each question you add in #{filename} to this run's number."

      :follows_unknown ->
        "Set follows of each question you add in #{filename} to ids of questions " <>
          "before it in #{filename}."

      :decision_option ->
        "Set decision.option of each question in #{filename} to the title of one of " <>
          "the question's options."

      :decided_not_new ->
        "Record each decision in #{filename} on a question you add, and set no " <>
          "question already in it to decided."

      :decided_changed ->
        "Leave question and options of each question with a decision in #{filename} " <>
          "as the newest version of questions has them, and its context while it stays " <>
          "decided or answered: to change them, withdraw the question and add a new one."

      :decision_changed ->
        "Leave the decision of each question in #{filename} as the newest version of " <>
          "questions has it, and add none: only the run that adds a question records " <>
          "its decision."

      :decision_run ->
        "Set decision.run of each question in #{filename} to the question's asked.run: " <>
          "only the run that asked a question records a decision on it."
    end
  end

  # A verdict whose `answer` point is about a question that is not open in the newest
  # questions of the run's take in (`Apiary.Artifacts`): `point` counts from 1.
  defp kept("verdict", {:not_open, point, question}, filename),
    do:
      "Push the questions first, or point at an open question in #{filename}: " <>
        "point #{point} is about question #{question}, which is not open."

  defp kept("review-comments", reason, filename) do
    case reason do
      :id_dropped ->
        "Keep every review comment of the newest version of review-comments in " <>
          "#{filename}: the id of a review comment is missing."

      :comment_added ->
        "Remove the review comment you added in #{filename}: members write review comments."

      :comment_changed ->
        "Leave on, text, by and at of each review comment in #{filename} as the newest " <>
          "version of review-comments has them."

      :reply_changed ->
        "Leave each earlier reply in #{filename} as the newest version of " <>
          "review-comments has it."

      :reply_not_run ->
        "Set by.run of your reply in #{filename} to this run's number."

      :replies_added ->
        "Add at most one reply to each review comment in #{filename}."

      :not_open ->
        "Reply in #{filename} only to review comments that are open."

      :not_closed ->
        "Close each review comment you reply to in #{filename}."

      :state_changed ->
        "Change the state of a review comment in #{filename} only by closing an open " <>
          "one with your reply."

      :question_unknown ->
        "Push the question you asked first, then #{filename}: the question of a reply " <>
          "with the outcome asked is the id of a question in the newest version of questions."
    end
  end

  # The message of a file that `Apiary.Artifacts` refuses by its format check: the file,
  # the type and what the type's base view takes.
  defp mismatch(:unreadable, filename, _push),
    do: "Push #{filename} again: Qory Apiary could not read it after it was received."

  # A proposal's Markdown file over 256 KiB, its SVG over 512 KiB or its sources.json over
  # 1 MiB (`Apiary.Artifacts.Format`).
  defp mismatch(:document_size, filename, _push),
    do: "Shrink #{filename} to at most #{Format.proposal_bytes(filename)} bytes."

  # A proposal's image whose bytes are not the type its extension names, such as cart.png
  # with the bytes of a GIF (`Apiary.Artifacts.Format`).
  defp mismatch(:image_type, filename, _push),
    do: "Replace #{filename} with an image of the type its name ends in."

  # A proposal's SVG that does not parse, is not UTF-8, or has another root than svg
  # (`Apiary.Artifacts.Format`).
  defp mismatch(:svg_format, filename, _push),
    do: "Make #{filename} a well-formed SVG file in UTF-8 with an svg root element."

  # A proposal's SVG whose root svg is outside the SVG namespace: with no xmlns, such as an
  # SVG copied from an HTML page, or with another address.
  defp mismatch(:svg_root, filename, _push),
    do: ~s(Set xmlns="http://www.w3.org/2000/svg" on the svg root element of #{filename}.)

  # A proposal's sources.json that is not one JSON document.
  defp mismatch(:format, "sources.json" = filename, %{name: "proposal"}),
    do: "Make #{filename} valid JSON. The file does not parse as JSON."

  defp mismatch(check, filename, push),
    do: "Fix #{filename} to match the format of #{push.name}: #{takes(check, filename, push)}."

  # A proposal's file that is neither Markdown, its sources nor an image, by its
  # extension or its bytes, gets the proposal's line; its Markdown file that is not UTF-8
  # text, a document's.
  defp takes(check, filename, %{name: "proposal"}) when check in [:format, :extension] do
    if check == :format and String.downcase(Path.extname(filename)) == ".md",
      do: "a document is a Markdown file of UTF-8 text",
      else:
        "a proposal is one Markdown file (.md) with PNG, JPEG, GIF, WebP or SVG images " <>
          "and an optional sources.json"
  end

  defp takes(:extension, _filename, _push), do: "the filename of a document ends in .md"

  defp takes(:format, _filename, push) do
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
