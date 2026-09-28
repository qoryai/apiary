defmodule ApiaryWeb.Contract.RawBody do
  @moduledoc """
  Reads the body of a delivery to the events endpoint before anything parses it.

  The signature of a signed POST is over the raw bytes, and it is checked before
  the body is parsed, so for `POST /v1/events`, whatever its content type, this
  plug reads the body itself, keeps it in `conn.assigns[:raw_body]` and leaves
  the body parameters empty; the endpoint skips `Plug.Parsers` for such a
  request. Every other request passes untouched.

  At most `max_bytes/0` are read, 2 MiB: what an unauthenticated sender can make
  the server hold is small. A longer body is answered `413` here, before the
  signature is looked at, as the contract's reference receiver does.
  """

  import Plug.Conn

  @max_bytes 2 * 1024 * 1024
  @events_path ["v1", "events"]

  @doc "The largest body of a delivery that is accepted, in bytes."
  def max_bytes, do: @max_bytes

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: path_info} = conn, _opts) do
    if events_path?(path_info), do: keep(conn), else: conn
  end

  def call(conn, _opts), do: conn

  # The router matches the decoded path, so this does: `/v1/%65vents` is the
  # events endpoint too, and its body is no more to be parsed unverified.
  defp events_path?([_, _] = path_info), do: Enum.map(path_info, &decode/1) == @events_path
  defp events_path?(_path_info), do: false

  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  defp keep(conn) do
    case read(conn, [], 0) do
      {:ok, body, conn} ->
        %{conn | body_params: %{}}
        |> fetch_query_params()
        |> assign(:raw_body, body)

      {:error, conn} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(413, ~s({"error":"payload_too_large"}))
        |> halt()
    end
  end

  # One byte over the limit is asked for, so a body of exactly the limit is
  # told from a longer one without reading the rest.
  defp read(conn, acc, size) do
    case read_body(conn, length: @max_bytes + 1 - size, read_length: 64_000) do
      {:ok, chunk, conn} -> finish(conn, [acc, chunk], size + byte_size(chunk))
      {:more, chunk, conn} -> more(conn, [acc, chunk], size + byte_size(chunk))
      {:error, _reason} -> {:error, conn}
    end
  end

  defp finish(conn, _acc, size) when size > @max_bytes, do: {:error, conn}
  defp finish(conn, acc, _size), do: {:ok, IO.iodata_to_binary(acc), conn}

  defp more(conn, _acc, size) when size > @max_bytes, do: {:error, conn}
  defp more(conn, acc, size), do: read(conn, acc, size)
end
