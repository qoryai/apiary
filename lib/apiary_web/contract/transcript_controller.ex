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
  run continues (`Apiary.Runs.Transcript`), sent in chunks. A run the key's gateway does
  not hold (`ApiaryWeb.Contract.RunApi.Run.fetch/3`), a run that ended, a run that
  continues no paused run, a paused run that is no longer the one it continues, and a
  transcript that is gone, has a gap in its offsets or is over 64 MiB are each `404`
  `not_found`. No transcript byte is logged or put in an error; an exception is `503`
  `unavailable`, logged by its module's name alone.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  require Logger

  alias Apiary.Runs.{Run, Transcript}
  alias ApiaryWeb.Contract.RunApi.Run, as: HeldRun

  def show(conn, %{"run_id" => run_id}) do
    with {:ok, held} <- HeldRun.fetch(conn.assigns.access_key, run_id, conn.assigns[:instance_id]),
         true <- HeldRun.live?(held),
         %Run{} = paused <- Transcript.paused_run(held.dispatch_run),
         %{path: path} <- Transcript.last(paused.id),
         {:ok, file} <- Transcript.file(paused.id, path) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("application/x-ndjson", nil)
      |> put_private(:qory_body_sha256, file.sha256)
      |> send_chunks(Transcript.stream(paused.id, path))
    else
      _none -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  rescue
    exception ->
      Logger.error("a transcript could not be read: #{inspect(exception.__struct__)}")
      conn |> put_status(503) |> json(%{error: "unavailable"})
  end

  defp send_chunks(conn, stream) do
    Enum.reduce_while(stream, send_chunked(conn, 200), fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end
end
