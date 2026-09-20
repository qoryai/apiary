defmodule ApiaryWeb.Contract.SignedRequest do
  @moduledoc """
  Verifies a signed GET of the server contract and assigns the access key.

  The runner sends `X-Qory-Access-Key`, `X-Qory-Timestamp` (Unix seconds) and
  `X-Qory-Signature-256` over the canonical string of the method, the path with
  its query and the timestamp (`Apiary.Contract.Signature`). The timestamp must
  be within five minutes of the server clock. Every failure, whatever its cause,
  is a 401 with the same body. Nothing in this module logs a header value.
  """

  import Plug.Conn

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Signature

  @window_seconds 300
  @unauthorized %{error: "unauthorized"}

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, key_id} <- header(conn, "x-qory-access-key"),
         {:ok, timestamp} <- header(conn, "x-qory-timestamp"),
         {:ok, signature} <- header(conn, "x-qory-signature-256"),
         {:ok, seconds} <- parse_integer(timestamp),
         true <- within_window?(seconds),
         {:ok, %AccessKey{} = access_key} <- AccessKeys.fetch_for_verification(key_id),
         canonical = Signature.canonical_string(conn.method, path_with_query(conn), timestamp),
         true <- Signature.verify(AccessKey.secrets(access_key), canonical, signature) do
      {:ok, access_key} = AccessKeys.touch(access_key, touch_attrs(conn))
      assign(conn, :access_key, access_key)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(@unauthorized)
    |> halt()
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp within_window?(seconds) do
    abs(System.os_time(:second) - seconds) <= @window_seconds
  end

  # The path and query exactly as received, so the runner and the server sign
  # the same bytes without any normalisation.
  defp path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path

  defp path_with_query(%Plug.Conn{request_path: path, query_string: query}),
    do: path <> "?" <> query

  defp touch_attrs(conn) do
    %{
      last_runner_version: runner_version(conn),
      last_contract_version: contract_version(conn)
    }
  end

  defp runner_version(conn) do
    with {:ok, user_agent} <- header(conn, "user-agent"),
         [_, version] <- Regex.run(~r{^qory-runner/(\S+)}, user_agent) do
      version
    else
      _ -> nil
    end
  end

  defp contract_version(conn) do
    with {:ok, value} <- header(conn, "x-qory-contract-version"),
         {:ok, version} <- parse_integer(value) do
      version
    else
      _ -> nil
    end
  end
end
