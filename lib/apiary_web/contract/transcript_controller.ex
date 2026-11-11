defmodule ApiaryWeb.Contract.TranscriptController do
  @moduledoc """
  The transcript of the paused run that a run continues: a signed
  `GET /v1/runs/<run_id>/resume/transcript` under a key of the gateway that attached the
  run, which the run's session reads before its runtime starts, to resume the paused
  run's session (the Forager contract, The transcript of a paused run). Reached only
  through `ApiaryWeb.Contract.SignedRequest`, which verifies the request and signs the
  answer over the SHA-256 of the file.

  The route is under the run endpoint, whose URL the configuration document lists as
  `run.url`, and belongs to its feature, `observability`: a run configuration has
  `resume` (`Apiary.Runs.Transcript.resume/1`) only where a run started, and a run
  starts only where the run endpoint answers.

  The answer is `200`, `application/x-ndjson`, the file of the run that the request's
  run continues (`Apiary.Runs.Transcript`), at the path its `resume` has, sent in
  chunks: the chunks `Apiary.Runs.Transcript.check/2` checked, whose SHA-256 the answer
  is signed over. A run the key's gateway does not hold, as the run API reads it, a run
  that ended, a run with no `resume`, a paused run that is no longer the one it
  continues, and a transcript that is gone, has a gap in its offsets or is over 64 MiB
  are each `404` `not_found`. No transcript byte is logged or put in an error. An
  exception before the answer starts is `503` `unavailable`; one while the chunks are
  sent ends the answer there. Each is logged by its module's name alone.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.Runs.{Run, Transcript}
  alias ApiaryWeb.Contract.RunApi.Run, as: HeldRun

  # The module that reads the chunks: `Apiary.Runs.Transcript`, but in tests, where
  # `config/test.exs` sets one that can fail while the chunks are sent. It is fixed when
  # this module compiles, so a node cannot change it at runtime.
  @transcript Application.compile_env(:apiary, [__MODULE__, :transcript], Transcript)

  def show(conn, %{"run_id" => run_id}) do
    case file(conn, run_id) do
      {:ok, paused_id, path, file} ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type("application/x-ndjson", nil)
        |> put_private(:qory_body_sha256, file.sha256)
        |> send_chunks(@transcript.stream(paused_id, path, file.max_sequence))

      :not_found ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      :unavailable ->
        conn |> put_status(503) |> json(%{error: "unavailable"})
    end
  end

  # The paused run's transcript at the path the run's `resume` has, checked
  # (`Apiary.Runs.Transcript.check/2`), with the digest of the chunks checked. Before any
  # byte is sent, so an exception here is still a `503`.
  defp file(conn, run_id) do
    with {:ok, held} <- HeldRun.fetch(conn.assigns.access_key, run_id, conn.assigns[:instance_id]),
         true <- HeldRun.live?(held),
         %{"run_id" => paused_run_id, "path" => path} <- Transcript.resume(held.run),
         %Run{node_run_id: ^paused_run_id} = paused <- Transcript.paused_run(held.dispatch_run),
         {:ok, file} <- Transcript.check(paused.id, path) do
      digest = Transcript.digest(paused.id, path, file.max_sequence)
      {:ok, paused.id, path, Map.put(file, :sha256, digest)}
    else
      _none -> :not_found
    end
  rescue
    exception ->
      Logger.error("a transcript could not be read: #{inspect(exception.__struct__)}")
      :unavailable
  end

  # Once the answer has started, a failure can no longer change its status: one line in
  # the log, with the exception's module alone, and the answer ends where it is.
  defp send_chunks(conn, stream) do
    conn = send_chunked(conn, 200)

    try do
      Enum.reduce_while(stream, conn, fn data, conn ->
        case chunk(conn, data) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)
    rescue
      exception ->
        Logger.error("a transcript stopped while it was sent: #{inspect(exception.__struct__)}")

        halt(conn)
    end
  end
end
