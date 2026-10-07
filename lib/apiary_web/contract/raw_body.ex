defmodule ApiaryWeb.Contract.RawBody do
  @moduledoc """
  Reads the body of a delivery to the events endpoint, and of an enrolment, before
  anything parses it.

  The signature of a signed POST is over the raw bytes, and it is checked before the body
  is parsed; an enrolment is read strictly, a member twice refused, which a parser that
  keeps the last of them cannot tell. So for `POST /v1/events` and
  `POST /.well-known/qory-enrolment`, whatever the content type, this plug reads the body
  itself, keeps it in `conn.assigns[:raw_body]` and leaves the body parameters empty; the
  endpoint skips `Plug.Parsers` for such a request. Every other request passes untouched.

  At most `max_bytes/0` of a delivery are read, 2 MiB, and `max_bytes(:enrolment)` of an
  enrolment, 8 KiB, many times the longest the schema allows: what an unauthenticated
  sender can make the server hold is small. A longer body is answered `413` here, before
  the signature or the code is looked at, as the contract's reference receiver does.
  """

  import Plug.Conn

  @max_bytes 2 * 1024 * 1024
  @enrolment_max_bytes 8 * 1024
  @events_path ["v1", "events"]
  @enrolment_path [".well-known", "qory-enrolment"]

  @doc """
  The largest body that is accepted, in bytes: of a delivery (`max_bytes/0`), or of an
  enrolment (`max_bytes(:enrolment)`).
  """
  def max_bytes, do: @max_bytes
  def max_bytes(:events), do: @max_bytes
  def max_bytes(:enrolment), do: @enrolment_max_bytes

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: path_info} = conn, _opts) do
    case kept(path_info) do
      nil -> conn
      endpoint -> keep(conn, max_bytes(endpoint))
    end
  end

  def call(conn, _opts), do: conn

  # The router matches the decoded path, so this does: `/v1/%65vents` is the
  # events endpoint too, and its body is no more to be parsed unverified.
  defp kept([_, _] = path_info) do
    case Enum.map(path_info, &decode/1) do
      @events_path -> :events
      @enrolment_path -> :enrolment
      _other -> nil
    end
  end

  defp kept(_path_info), do: nil

  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  defp keep(conn, max) do
    case read(conn, [], 0, max) do
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
  defp read(conn, acc, size, max) do
    case read_body(conn, length: max + 1 - size, read_length: min(64_000, max + 1)) do
      {:ok, chunk, conn} -> finish(conn, [acc, chunk], size + byte_size(chunk), max)
      {:more, chunk, conn} -> more(conn, [acc, chunk], size + byte_size(chunk), max)
      {:error, _reason} -> {:error, conn}
    end
  end

  defp finish(conn, _acc, size, max) when size > max, do: {:error, conn}
  defp finish(conn, acc, _size, _max), do: {:ok, IO.iodata_to_binary(acc), conn}

  defp more(conn, _acc, size, max) when size > max, do: {:error, conn}
  defp more(conn, acc, size, max), do: read(conn, acc, size, max)
end
