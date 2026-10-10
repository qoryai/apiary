defmodule ApiaryWeb.RequestLog do
  @moduledoc """
  The production request log: one JSON line per request, written by
  `LoggerJSON.Plug` from the endpoint's stop event.

  Six routes carry a bearer token in the path (an invitation, a log-in link, an
  email change, a password link, the test link of Instance settings › Mail), and one the
  instance's set-up code. The path is logged, so the token segment is replaced with
  `:token`, and the code with `:code`, before the line is written: a reader of the log
  must not be able to sign in, set a password, join an organisation or set the instance
  up with what it finds there.
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
  by `:token`. Any other path is returned as it is.
  """
  def redact_path(path) when is_binary(path) do
    # Empty segments are dropped the way the router drops them, so a doubled or
    # trailing slash does not get a token past the redaction.
    case String.split(path, "/", trim: true) do
      ["invitations", _token] ->
        "/invitations/:token"

      ["invitations", _token, "continue"] ->
        "/invitations/:token/continue"

      ["users", "log-in", _token] ->
        "/users/log-in/:token"

      ["users", "settings", "confirm-email", _token] ->
        "/users/settings/confirm-email/:token"

      ["users", "password", _token] ->
        "/users/password/:token"

      ["instance", "mail", "confirm", _token] ->
        "/instance/mail/confirm/:token"

      ["setup", _code] ->
        "/setup/:code"

      _ ->
        path
    end
  end

  def redact_path(path), do: path
end
