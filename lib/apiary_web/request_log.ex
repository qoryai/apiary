defmodule ApiaryWeb.RequestLog do
  @moduledoc """
  The production request log: one JSON line per request, written by
  `LoggerJSON.Plug` from the endpoint's stop event.

  Six routes carry a bearer token in the path (an invitation, a log-in link, an
  email change, a password link, the test link of Instance settings › Mail), and one the
  instance's set-up code. The path is logged, so the token segment is replaced with
  `:token`, and the code with `:code`, before the line is written: a reader of the log
  must not be able to sign in, set a password, join an organisation or set the instance up
  with what it finds there.
  """

  @handler_id "apiary-request-log"

  @doc "Attaches the request log to the endpoint's stop event."
  def attach do
    :telemetry.attach(
      @handler_id,
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_event/4,
      :info
    )
  end

  @doc false
  def handle_event(event, measurements, %{conn: %Plug.Conn{} = conn} = metadata, level) do
    conn = %{conn | request_path: redact_path(conn.request_path)}

    LoggerJSON.Plug.telemetry_logging_handler(
      event,
      measurements,
      %{metadata | conn: conn},
      level
    )
  end

  def handle_event(event, measurements, metadata, level) do
    LoggerJSON.Plug.telemetry_logging_handler(event, measurements, metadata, level)
  end

  @doc """
  The request path with the token segment of the token-bearing routes replaced
  by `:token`, and the set-up code by `:code`. Any other path is returned as it is. The
  routes are `Apiary.SecretLogFilter`'s, which keeps the same tokens out of every other
  log line (`Apiary.SecretLogFilter.redact_path/1`).
  """
  defdelegate redact_path(path), to: Apiary.SecretLogFilter
end
