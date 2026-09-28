defmodule ApiaryWeb.Contract.SignedRequest do
  @moduledoc """
  Verifies a signed request of the server contract and assigns the access key.

  A GET has no body: the runner sends `X-Qory-Access-Key`, `X-Qory-Timestamp`
  (Unix seconds) and `X-Qory-Signature-256` over the canonical string of the
  method, the path with its query and the timestamp
  (`Apiary.Contract.Signature`). The timestamp must be within five minutes of
  the server clock.

  A POST is signed over its raw body, as `ApiaryWeb.Contract.RawBody` kept it,
  and nothing else: no timestamp is signed and no window is checked, since a
  replayed batch is a duplicate the receiver discards by event id. A
  `X-Qory-Timestamp` sent on a POST is ignored. The body is verified before
  anything parses it.

  Either secret of the key verifies, in constant time. Every failure, whatever
  its cause, is a 401 with the same body, but one: a key whose secrets the instance
  cannot decrypt, because `CLOAK_KEY` is not the key they were encrypted with, is a
  503 with `{"error":"unavailable"}`, the runner's signal to fail closed and try
  again, and a line in the log names the key id (`Apiary.AccessKeys.fetch_for_verification/1`).
  That is the instance's fault, never the machine's, and a 401 would send the operator
  to the wrong place. Nothing in this module logs a header value.

  No input makes this plug raise. The key id is checked for its exact shape
  before it reaches the database, and a header of the signature sent twice is
  refused. On a GET the use of the key is recorded here: the runner version, reduced to
  what the column holds and dropped when it does not fit, and the contract version when
  it is a revision served (`ApiaryWeb.Contract.ContractVersion`; a request with any other
  is refused by the endpoint and leaves the recorded one as it is). On a POST the
  receiver records the use with the delivery. A failure to record the use does not fail
  the request.

  A verified request's Logger metadata carries the organisation and workspace ids of its
  key from here on (`Apiary.LogMetadata`); a refused one's carries neither.

  The clock is the system's; a test of the contract's fixtures, which are signed
  around a fixed second, sets `config :apiary, :contract_now` to a function of no
  arguments that returns Unix seconds.
  """

  import Plug.Conn

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Signature
  alias Apiary.LogMetadata
  alias ApiaryWeb.Contract.ContractVersion

  @window_seconds 300
  @key_id_format ~r/^ak_[0-9a-hjkmnp-tv-z]{16}$/
  @runner_version_max 80
  # String.printable?/1 lets escape sequences through; a version has no control characters.
  @printable ~r/\A[^[:cntrl:]]+\z/u
  @unauthorized %{error: "unauthorized"}
  @unavailable %{error: "unavailable"}

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with :ok <- no_header_twice(conn),
         {:ok, key_id} <- header(conn, "x-qory-access-key"),
         true <- valid_key_id?(key_id),
         {:ok, signature} <- header(conn, "x-qory-signature-256"),
         %{raw_body: body} when is_binary(body) <- conn.assigns,
         {:ok, %AccessKey{} = access_key} <- AccessKeys.fetch_for_verification(key_id),
         true <- Signature.verify(AccessKey.secrets(access_key), body, signature) do
      LogMetadata.put(access_key)
      assign(conn, :access_key, access_key)
    else
      {:error, :unreadable} -> unavailable(conn)
      _ -> unauthorized(conn)
    end
  end

  def call(conn, _opts) do
    with {:ok, key_id} <- header(conn, "x-qory-access-key"),
         true <- valid_key_id?(key_id),
         {:ok, timestamp} <- header(conn, "x-qory-timestamp"),
         {:ok, signature} <- header(conn, "x-qory-signature-256"),
         {:ok, seconds} <- parse_integer(timestamp),
         true <- within_window?(seconds),
         {:ok, %AccessKey{} = access_key} <- AccessKeys.fetch_for_verification(key_id),
         canonical = Signature.canonical_string(conn.method, path_with_query(conn), timestamp),
         true <- Signature.verify(AccessKey.secrets(access_key), canonical, signature) do
      LogMetadata.put(access_key)
      assign(conn, :access_key, touch(access_key, conn))
    else
      {:error, :unreadable} -> unavailable(conn)
      _ -> unauthorized(conn)
    end
  end

  # On a POST the timestamp is not read, so `header/2` never sees it sent twice.
  defp no_header_twice(conn) do
    case get_req_header(conn, "x-qory-timestamp") do
      [_, _ | _] -> :error
      _ -> :ok
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(@unauthorized)
    |> halt()
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> Phoenix.Controller.json(@unavailable)
    |> halt()
  end

  defp valid_key_id?(key_id), do: String.valid?(key_id) and Regex.match?(@key_id_format, key_id)

  # Recording the use is bookkeeping: the request is already verified, and an
  # error here (a lost connection, a value the row refuses) leaves it a success.
  defp touch(access_key, conn) do
    case AccessKeys.touch(access_key, touch_attrs(conn)) do
      {:ok, touched} -> touched
      {:error, _changeset} -> access_key
    end
  rescue
    _exception -> access_key
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
    abs(now() - seconds) <= @window_seconds
  end

  defp now do
    case Application.get_env(:apiary, :contract_now) do
      clock when is_function(clock, 0) -> clock.()
      _ -> System.os_time(:second)
    end
  end

  # The path and query exactly as received, so the runner and the server sign
  # the same bytes without any normalisation.
  defp path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path

  defp path_with_query(%Plug.Conn{request_path: path, query_string: query}),
    do: path <> "?" <> query

  defp touch_attrs(conn) do
    attrs = %{last_runner_version: runner_version(conn)}

    case ContractVersion.fetch(conn) do
      {:ok, version} -> Map.put(attrs, :last_contract_version, version)
      :error -> attrs
    end
  end

  @doc "The runner version of `User-Agent: qory-runner/<version>`, as the columns hold it, or nil."
  def runner_version(conn) do
    with {:ok, user_agent} <- header(conn, "user-agent"),
         true <- String.valid?(user_agent),
         [_, version] <- Regex.run(~r{^qory-runner/(\S+)}, user_agent),
         true <- Regex.match?(@printable, version) do
      String.slice(version, 0, @runner_version_max)
    else
      _ -> nil
    end
  end
end
