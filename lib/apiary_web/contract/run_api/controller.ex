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
  #   3. for a push, a verdict and a report of pushed commits, a run that has ended is
  #      `409` `run_ended`, read here and again under the work item's lock
  #      (`Apiary.Artifacts.push/5`), and so is a run a member cancelled, from the cancel
  #      on, with the message for a cancel; then a body over its size `413`
  #      `payload_too_large`, then a body outside the contract `400` `invalid_request` with
  #      the member in `names`. A report of pushed commits is not refused while a cancel is
  #      requested, only once the run's end is recorded
  #      (`Apiary.Runs.PushedCommit.refusal/1`), and a run whose access is not `write` is
  #      `409` `not_writable`, before the body;
  #   4. for a push: a type the workspace does not have, or a standard type it hides, is
  #      `422` `unknown_type`, with a message that starts with the step: define the type;
  #      for a standard type, switch it on; more files than the type takes `422`
  #      `too_many_files`; files over the type's size limit together `422` `too_large`;
  #      then a content that is not strict base64 `400` `invalid_request`; then what
  #      `Apiary.Artifacts.push/5` returns, the files that do not match the type's format
  #      among it, `422` `invalid_artifact`; a run's version of `questions` or
  #      `review-comments` that changes what members wrote, `422` `invalid_artifact` with
  #      the rule it breaks; a `decision` that is not the id of a person's note on the
  #      work item (`Apiary.Stages.Notes`), `422` `unknown_decision`; and a version of
  #      `questions` or `review-comments` whose file is over the size limit as stored,
  #      with each number that is an integer in value written as an integer (`1e3` as
  #      `1000`), `422` `too_large`;
  #   5. for a withdrawal, a push with `withdraw` true: an unknown type as for a push, then
  #      `questions`, `review-comments`, `verdict` or `proposal`, the types Qory Apiary
  #      reads itself, a type with `withdrawable` false, and the type in `submit.type` of
  #      the run's process version or of the work item's, `422` `type_not_withdrawable`,
  #      then files with it `422` `withdrawal_with_files`, then what
  #      `Apiary.Artifacts.withdraw/4` returns under the work item's lock: a name whose
  #      newest version a person approved at a gate `422` `type_not_withdrawable`, a name
  #      with no version `409` `no_version`, a name whose newest version is a withdrawal
  #      `409` `already_withdrawn`, and one whose newest version a person wrote `409`
  #      `person_version`, then a `decision` as for a push, `422` `unknown_decision`.
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

  alias Apiary.Artifacts.Format
  alias Apiary.Dispatches.RunEnd
  alias Apiary.Dispatches.Inputs
  alias Apiary.PublicId
  alias Apiary.Runs.PushedCommit
  alias ApiaryWeb.Contract.Configuration
  alias ApiaryWeb.Contract.RunApi.{Body, Boundary, Run, Wire}

  # The message of a next-session request outside the run contract.
  @next_session_body "Send session, state and reason as the run contract's next-session request has them."

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
         {:ok, version} <- store(run, push) do
      answer(conn, 201, Wire.version(version, push.type, push.name))
    else
      error -> write_error(conn, error)
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  # A withdrawal: the type, whether a run may withdraw it, then no files, then what
  # `Apiary.Artifacts.withdraw/4` returns.
  defp store(run, %{withdraw: true} = push) do
    with {:ok, type} <- known_type(run.work_item.workspace, push.type),
         :ok <- withdrawable_type(type, run, push),
         :ok <- no_files(push) do
      Boundary.withdraw({:run, run.dispatch_run}, run.work_item, push.type,
        name: push.name,
        stage_id: Boundary.push_stage_id(run.dispatch_run, run.work_item),
        note: push.note,
        decision: push.decision
      )
      |> withdrawn(push)
    end
  end

  defp store(run, push) do
    with {:ok, type} <- known_type(run.work_item.workspace, push.type),
         :ok <- within(type, push),
         {:ok, files} <- Body.decode_files(push.files) do
      Boundary.push({:run, run.dispatch_run}, run.work_item, push.type, files,
        name: push.name,
        stage_id: Boundary.push_stage_id(run.dispatch_run, run.work_item),
        note: push.note,
        decision: push.decision
      )
      |> pushed(%{
        name: push.type,
        type: type,
        filenames: Enum.map(files, & &1.filename)
      })
    end
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

  # A report of the commits the run pushed: `204`, signed, with no body. A run that has
  # ended is `409` `run_ended`, a run whose access is not `write` `409` `not_writable`
  # (`Apiary.Runs.Cancel.write_run?/2`), then the body (`400` `invalid_request`), then
  # `Apiary.Runs.PushedCommit.record/3`, which reads the run of the queue again under the
  # work item's lock. A cancel that a member requested does not refuse the report.
  def pushed_commits(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- run(conn, run_id),
         :ok <- reporting(run),
         :ok <- writable(run),
         {:ok, repositories} <- Body.pushed_commits(conn.assigns.raw_body),
         :ok <- PushedCommit.record(run.work_item, run.run, repositories) do
      send_resp(
        put_resp_header(
          conn,
          "x-qory-configuration",
          Configuration.digest(conn.assigns.access_key)
        ),
        204,
        ""
      )
    else
      {:error, :not_writable} ->
        error(conn, 409, "not_writable",
          message:
            "Record pushed commits only from a run with write access. This run cannot push."
        )

      {:error, :run_ended} ->
        error(conn, 409, "run_ended",
          message:
            "Start a new run to record pushed commits. This run ended, so it records no more commits."
        )

      {:error, :invalid_request, member} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "invalid_request",
          names: [member],
          message:
            "Send 1 to 64 repositories, each with system, path and a full commit id of 40 or 64 lowercase hex characters."
        })

      error ->
        write_error(conn, error)
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  # The next-session request of a run of a stage whose workflows run as sessions of one
  # run, sent after each session that did not pause (`Apiary.Stages.next_session/2`):
  # `200` with the next session, `{"next": "session", ...}` without the members that are
  # nil, or `{"next": "end"}`, at most 1 MiB. A run that has ended, or that a member
  # cancelled, is `409` `run_ended`; then a body over 4 KiB `413` `payload_too_large`;
  # then a body outside the run contract's request `400` `invalid_request`; then what the
  # step returns: a run without such a stage `404` `not_found`, a session older than the
  # newest the run reported `409` `session_mismatch`, a store that cannot read the
  # verdict or the questions `503` `unavailable`. Inputs that cannot be formed end the
  # run with the cause `ticket_gone` or `inputs_invalid`, as at a claim
  # (`Apiary.Dispatches.RunEnd.unformed/2`), and are `409` `run_ended`. An error writes
  # nothing but that end. A repeat for the same session returns the same body.
  def next_session(conn, %{"run_id" => run_id}) do
    with {:ok, run} <- run(conn, run_id),
         :ok <- live(run),
         {:ok, report} <- Body.next_session(conn.assigns.raw_body),
         {:ok, next} <- stepped(run, Apiary.Stages.next_session(run.dispatch_run, report)) do
      answer(conn, 200, Wire.next_session(next))
    else
      {:error, {:unformed, cause}} ->
        error(conn, 409, "run_ended", message: unformed_message(cause))

      {:error, :run_ended} ->
        error(conn, 409, "run_ended",
          message: "Close the run. It ended, so it starts no more sessions."
        )

      {:error, :run_cancelled} ->
        error(conn, 409, "run_ended",
          message: "Close the run. A member cancelled it, so it starts no more sessions."
        )

      {:error, :session_mismatch} ->
        error(conn, 409, "session_mismatch",
          message:
            "Send the number of the session that ended last. A later session of this run ended already."
        )

      {:error, :invalid_request} ->
        error(conn, 400, "invalid_request", names: ["body"], message: @next_session_body)

      {:error, :invalid_request, member} ->
        error(conn, 400, "invalid_request", names: [member], message: @next_session_body)

      error ->
        write_error(conn, error)
    end
  rescue
    exception -> unavailable(conn, exception)
  end

  # The step's result; inputs that cannot be formed end the run first.
  defp stepped(run, {:error, cause}) when cause in [:ticket_gone, :inputs_invalid] do
    run.run |> RunEnd.unformed(cause) |> Apiary.Dispatches.broadcast()
    {:error, {:unformed, cause}}
  end

  defp stepped(_run, {:error, _cause} = error), do: error
  defp stepped(_run, next), do: {:ok, next}

  defp unformed_message(:ticket_gone),
    do:
      "Close the run. The ticket of its work item is no longer in Qory Apiary, so the run ended."

  defp unformed_message(:inputs_invalid),
    do:
      "Close the run. The input of its next session breaks a rule for the agent's input, such as its size limit, so the run ended."

  # A run reports while its run of the queue has not ended and the run is live. A cancel
  # a member requested is no reason to refuse (`PushedCommit.refusal/1`).
  defp reporting(run) do
    cond do
      PushedCommit.refusal(run.dispatch_run) -> {:error, :run_ended}
      Run.live?(run) -> :ok
      true -> {:error, :run_ended}
    end
  end

  defp writable(run) do
    if Apiary.Runs.Cancel.write_run?(run.work_item.workspace, run.run),
      do: :ok,
      else: {:error, :not_writable}
  end

  # The policy `ApiaryWeb.ContentSecurityPolicy` set for the answer, with the directive
  # `sandbox` added.
  defp sandboxed(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [policy | _rest] -> policy <> "; sandbox"
      [] -> "sandbox"
    end
  end

  # The verdict's file, as the schema of the type `verdict` takes it: `points`, `track` and
  # `full_suite` only where the body has them, which the schema then checks.
  defp verdict_json(%{verdict: verdict} = body) do
    members =
      [{"verdict", verdict}] ++
        for {key, value} <-
              [
                {"points", body.points},
                {"track", body.track},
                {"full_suite", body.full_suite}
              ],
            value != nil do
          {key, value}
        end

    Jason.encode!(Jason.OrderedObject.new(members))
  end

  ## The feature

  # Where the run did not keep `workflow_model` when it was claimed, whatever the instance
  # has now, or, for a run that kept no features, where the instance does not have it
  # (`ApiaryWeb.Contract.RunFeatures`), the answer a verified request to a route of a
  # feature that is off gets (`ApiaryWeb.Features`): the error page's `404`, signed.
  defp workflow_model(conn, _opts) do
    on? =
      case ApiaryWeb.Contract.RunFeatures.recorded(conn) do
        nil -> Boundary.on?()
        recorded -> Apiary.Features.on?(Boundary.route_feature(), recorded)
      end

    if on? do
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

  # A run a member cancelled gets the message for a cancel, whatever its state.
  defp live(run) do
    cond do
      Apiary.Runs.Run.cancel_requested?(run.run) -> {:error, :run_cancelled}
      Run.live?(run) -> :ok
      true -> {:error, :run_ended}
    end
  end

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

  defp withdrawable_type(type, run, push) do
    case Boundary.withdrawable_type(type, run.dispatch_run, run.work_item) do
      :ok -> :ok
      {:error, {:withdraw, reason}} -> {:error, {:withdraw, reason, push.type, push.name}}
    end
  end

  defp no_files(%{files: []}), do: :ok

  defp no_files(push),
    do: {:error, {:withdrawal_with_files, push.type, push.name, length(push.files)}}

  # What `Apiary.Artifacts.withdraw/4` returns, turned into the run API's errors: a refusal
  # by the artifact's newest version with the type and the name; any other as a push's.
  defp withdrawn({:error, {:withdraw, reason}}, push),
    do: {:error, {:withdraw, reason, push.type, push.name}}

  defp withdrawn(result, push), do: pushed(result, %{name: push.type, type: nil, filenames: []})

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

  # The message for a track the gate does not offer. The sentence that names the track
  # comes only for an id of the form the schema takes, at most 40 characters.
  @track_id ~r/\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/

  defp track_not_offered(%{stage: stage, ids: ids, id: id}) do
    gate = "the gate of #{stage || "the run's stage"}"

    case ids do
      [] ->
        "Leave track out of the verdict: #{gate} offers no track."

      ids ->
        "Set track.id to a track that #{gate} offers (#{Enum.join(ids, ", ")}), " <>
          "or leave track out of the verdict." <> named(id)
    end
  end

  defp named(id) when is_binary(id) and byte_size(id) <= 40 do
    if Regex.match?(@track_id, id), do: " The track #{id} is not offered.", else: ""
  end

  defp named(_id), do: ""

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

  defp refused({:invalid, member}, _push) when member in [:type, :name, :note, :decision],
    do: {:error, :invalid_request, Atom.to_string(member)}

  defp refused({:unknown_decision, _decision}, _push), do: {:error, :unknown_decision}

  defp refused({:invalid, :no_files}, _push), do: {:error, :invalid_request, "files"}

  # A verdict whose `track` the gate of the version's stage does not offer: `422`
  # `invalid_artifact` for `track`, with the fix first.
  defp refused({:invalid, {:track_not_offered, info}}, _push),
    do: {:error, {:invalid_artifact, "track", track_not_offered(info)}}

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

  # A run's mockup of pages that fails a check of `Apiary.Artifacts.Mockup`: its message,
  # at the file, or at the files for the version.
  defp refused({:invalid, {{:mockup, message}, index}}, _push)
       when is_binary(message) and (is_integer(index) or is_nil(index)) do
    member = if index, do: "files[#{index}]", else: "files"
    {:error, {:invalid_artifact, member, message}}
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
  defp refused(:run_cancelled, _push), do: {:error, :run_cancelled}

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
        "Leave question, context, options and about of each answered question in " <>
          "#{filename} as the newest version of questions has them, set or absent."

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
          "as the newest version of questions has them, and its context and about " <>
          "while it stays decided or answered: to change them, withdraw the question and " <>
          "add a new one."

      :decision_changed ->
        "Leave the decision of each question in #{filename} as the newest version of " <>
          "questions has it, and add none: only the run that adds a question records " <>
          "its decision."

      :decision_run ->
        "Set decision.run of each question in #{filename} to the question's asked.run: " <>
          "only the run that asked a question records a decision on it."

      {:about, id, type, name} ->
        "Set about of question #{id} in #{filename} to an output of this work item, " <>
          "or to {\"work_item\": true}: the work item has no #{type} named #{name}."

      {:about_item, id, type, name, item} ->
        "Set about.item of question #{id} in #{filename} to a criterion id of " <>
          "#{type} named #{name}: no version of it has #{item}."
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

  # The step that adds the type of a push.
  defp unknown_type_message(type) do
    if Boundary.standard?(type),
      do:
        "Switch on the artifact type #{type} in the workspace's Artifact types, " <>
          "then run the round again.",
      else:
        "Define the artifact type #{type} in the workspace's Artifact types, " <>
          "then run the round again."
  end

  defp write_error(conn, {:error, :not_found}), do: error(conn, 404, "not_found")

  defp write_error(conn, {:error, :run_ended}) do
    error(conn, 409, "run_ended",
      message: "The run has ended, so it can no longer push artifacts or give a verdict."
    )
  end

  defp write_error(conn, {:error, :run_cancelled}) do
    error(conn, 409, "run_ended",
      message: "The run was cancelled, so it can no longer push artifacts or give a verdict."
    )
  end

  defp write_error(conn, {:error, :too_large}), do: error(conn, 413, "payload_too_large")

  defp write_error(conn, {:error, :invalid_request, member}) do
    conn |> put_status(400) |> json(%{error: "invalid_request", names: [member]})
  end

  defp write_error(conn, {:error, {:unknown_type, type}}) do
    error(conn, 422, "unknown_type", type: type, message: unknown_type_message(type))
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

  defp write_error(conn, {:error, {:withdrawal_with_files, type, name, count}}) do
    error(conn, 422, "withdrawal_with_files",
      type: type,
      message:
        "Push either files or a withdrawal. A withdrawal of #{type}/#{name} stores no " <>
          "files, and the push has #{file_count(count)}."
    )
  end

  defp write_error(conn, {:error, {:withdraw, :type, type, _name}}) do
    error(conn, 422, "type_not_withdrawable",
      type: type,
      message:
        "Push a new version of #{type} instead. Qory Apiary reads questions, " <>
          "review-comments, verdict and proposal itself, so a run cannot withdraw them."
    )
  end

  defp write_error(conn, {:error, {:withdraw, :submit_type, type, _name}}) do
    error(conn, 422, "type_not_withdrawable",
      type: type,
      message:
        "Push a new version of #{type} instead. Qory Apiary reads its newest version as " <>
          "the run's submission, so a run cannot withdraw it."
    )
  end

  defp write_error(conn, {:error, {:withdraw, :type_off, type, _name}}) do
    error(conn, 422, "type_not_withdrawable",
      type: type,
      message:
        "Push a new version of #{type} instead. The artifact type #{type} has " <>
          "withdrawable set to false, so a run cannot withdraw its names."
    )
  end

  defp write_error(conn, {:error, {:withdraw, {:approved, number}, type, name}}) do
    error(conn, 422, "type_not_withdrawable",
      type: type,
      message:
        "Push a new version of #{type}/#{name} instead. A member approved its newest " <>
          "version, v#{number}, so a run cannot withdraw the name."
    )
  end

  defp write_error(conn, {:error, {:withdraw, :no_version, type, name}}) do
    error(conn, 409, "no_version",
      type: type,
      message:
        "Withdraw only a stored artifact. #{type}/#{name} has no version outside cancelled runs."
    )
  end

  defp write_error(conn, {:error, {:withdraw, {:withdrawn, number}, type, name}}) do
    error(conn, 409, "already_withdrawn",
      type: type,
      message:
        "Leave #{type}/#{name} as it is. Its newest version, v#{number}, is already a " <>
          "withdrawal."
    )
  end

  defp write_error(conn, {:error, {:withdraw, {:person, number, user_id}, type, name}}) do
    error(conn, 409, "person_version",
      type: type,
      message:
        "Leave #{type}/#{name} to a member. Its newest version, v#{number}, is a version " <>
          "by #{Inputs.person_name(user_id)}, and a run withdraws only a name whose newest " <>
          "version a run wrote."
    )
  end

  defp write_error(conn, {:error, :unknown_decision}) do
    error(conn, 422, "unknown_decision",
      message:
        "Set decision to the id of a person's note on this work item, from notes in " <>
          "GET work-item, or leave decision out."
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
