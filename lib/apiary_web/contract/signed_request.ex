defmodule ApiaryWeb.Contract.SignedRequest do
  @moduledoc ~S"""
  Verifies a signed request of the runner contract under a node's access key, signs every
  answer to it, and refuses what the contract refuses, in the contract's order, for
  discovery, the run configuration and the events endpoint alike.

  **The request.** The runner sends `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`, the
  unsigned `X-Qory-Instance-Name`, `X-Qory-Contract-Version` and
  `X-Qory-Signature-Ed25519`, the Ed25519 signature under the access key of the request
  string (`Apiary.Contract.SignedMessage.request/5`): the access key id and the instance
  id exactly as their headers carry them (an absent instance id as an empty line), the
  method, the request target exactly as received (the path, and the query when there is
  one), and last, for a GET the `X-Qory-Timestamp` value as sent, for a POST the raw body
  as `ApiaryWeb.Contract.RawBody` kept it. A POST signs no timestamp and has no window: a
  replayed batch is a duplicate the receiver discards by event id. A GET's timestamp is
  within 300 seconds of the server's clock, either way.

  **The order of refusals**, as the contract has it (the `413` of a body over its limit
  comes before this plug, in `ApiaryWeb.Contract.RawBody`):

    1. `415` for a POST whose content type is not `application/cloudevents-batch+json`,
       unsigned;
    2. `400` `bad_request` for `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`,
       `X-Qory-Signature-Ed25519` or `X-Qory-Timestamp` sent twice, unsigned;
    3. `401` `{"error":"unauthorized"}`, unsigned and the same whatever the cause: a key id
       or signature missing or empty, a key id of the wrong shape (checked before the key
       is looked up), a key the instance does not hold, has revoked, or that is not a
       node's key, a row that fails its integrity check, a signature that is not 64 bytes
       of strict base64url or does not verify (cofactorless, `Apiary.Contract.Ed25519`);
    4. `429` `rate_limited` with `Retry-After`, when the plug is given `rate_limit: true`
       (the events endpoint and the run configuration, from one bucket per key,
       `Apiary.Runs.RateLimit`; discovery is not limited);
    5. `400` `bad_request` for an instance id absent or outside
       `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`;
    6. `409` `key_pending` for a key that awaits approval, on every endpoint;
    7. `400` `unsupported_contract_version` (`ApiaryWeb.Contract.ContractVersion`);
    8. for a GET, `401` for a timestamp that is not a decimal integer or is outside the
       window, unsigned. The contract puts a `400` `invalid_request` for labels before
       it; the run configuration refuses no labels, so nothing comes between.

  Each endpoint's own refusals follow, in its controller: on the events endpoint the
  `400` `invalid_request` of a body the contract refuses, then deduplication, `410` and
  the ping's `409` `instance_limit` (`ApiaryWeb.Contract.EventsController`).

  **Signed answers.** From the moment the request verifies, its answer is signed
  (`ApiaryWeb.Contract.SignedAnswer.register/2`), whatever its status but `401`. A refusal
  after verification is coded: `application/json`, `{"error": "<code>"}`.

  **What a verified request leaves.** The conn's `access_key` (with its workspace and
  node), `request_signature`, `instance_id` and `contract_version`. The instance is
  recorded as seen on the key's node (`Apiary.Nodes.seen/3`), for a key that awaits
  approval too, once its instance id passes and, on a GET, only when its timestamp is
  within the window: a stale or replayed GET leaves neither the instance's last sighting
  nor its name, and still gets its refusal in the order above. On a GET of an approved key the use of the
  key is recorded: the runner version, reduced to what the column holds and dropped when
  it does not fit, and the contract version; on a POST the receiver records the use with
  the delivery. Neither failing fails the request. The Logger metadata carries the key's
  organisation and workspace ids from verification on (`Apiary.LogMetadata`); a refused
  request's carries neither.

  No input makes this plug raise, nothing here logs a header value, a signature or a
  key, and a request under a key id the instance does not hold is verified under a fixed
  public key, so that it costs what a known one does. The clock is the system's; a test
  of the contract's fixtures, which are signed around a fixed second, sets
  `config :apiary, :contract_now` to a function of no arguments that returns Unix seconds.
  """

  import Plug.Conn

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.LogMetadata
  alias Apiary.Nodes
  alias Apiary.Nodes.Node
  alias Apiary.Runs.RateLimit
  alias ApiaryWeb.Contract.{ContractVersion, SignedAnswer}

  @window_seconds 300
  @key_id_format ~r/\Aak_[0-9a-hjkmnp-tv-z]{16}\z/
  @instance_id_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @timestamp_format ~r/\A[0-9]{1,19}\z/
  @content_type "application/cloudevents-batch+json"
  @runner_version_max 80
  # String.printable?/1 lets escape sequences through; a version has no control characters.
  @printable ~r/\A[^[:cntrl:]]+\z/u
  # The headers the signature depends on, each refused when sent more than once.
  @once [
    "x-qory-access-key-id",
    "x-qory-instance-id",
    "x-qory-signature-ed25519",
    "x-qory-timestamp"
  ]

  # The public key a request under a key id the instance does not hold is verified under,
  # so that it spends the time a known one does; it is refused whatever the result. The
  # key of the seed of 32 zero bytes: a key nobody holds as theirs.
  @unknown_key elem(:crypto.generate_key(:eddsa, :ed25519, <<0::256>>), 0)

  def init(opts), do: Keyword.validate!(opts, rate_limit: false)

  def call(conn, opts) do
    with :ok <- content_type(conn),
         :ok <- sent_once(conn),
         {:ok, access_key, signature} <- verify(conn) do
      LogMetadata.put(access_key)

      conn
      |> assign(:access_key, access_key)
      |> assign(:request_signature, signature)
      |> SignedAnswer.register(signature)
      |> after_verification(access_key, opts)
    else
      {:refuse, status, code} -> refuse(conn, status, code)
      :unauthorized -> unauthorized(conn)
    end
  end

  # The refusals after verification, in the contract's order, each answer signed.
  defp after_verification(conn, access_key, opts) do
    # A GET's freshness is read here and refused last, in the contract's order; until
    # then it decides only whether the instance is recorded as seen.
    freshness = fresh(conn)

    with :ok <- rate(access_key, opts),
         {:ok, instance_id} <- instance_id(header(conn, "x-qory-instance-id")),
         :ok <- seen(conn, access_key, instance_id, freshness),
         :ok <- approved(access_key),
         {:ok, version} <- contract_version(conn),
         :ok <- freshness do
      conn
      |> assign(:instance_id, instance_id)
      |> assign(:contract_version, version)
      |> touch(access_key)
    else
      {:rate_limited, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> refuse(429, "rate_limited")

      {:refuse, status, code} ->
        refuse(conn, status, code)

      :unsupported_contract_version ->
        conn |> ContractVersion.refuse() |> halt()

      :unauthorized ->
        unauthorized(conn)
    end
  end

  # As the reference receiver reads it: the media type, whatever its case and whatever
  # parameters follow. Only a POST, a delivery, has a body to type.
  defp content_type(%Plug.Conn{method: "POST"} = conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        if String.starts_with?(String.downcase(value), @content_type),
          do: :ok,
          else: {:refuse, 415, "unsupported_media_type"}

      _ ->
        {:refuse, 415, "unsupported_media_type"}
    end
  end

  defp content_type(_conn), do: :ok

  defp sent_once(conn) do
    if Enum.any?(@once, &match?([_, _ | _], get_req_header(conn, &1))),
      do: {:refuse, 400, "bad_request"},
      else: :ok
  end

  # Every failure is the same `:unauthorized`. The key id's shape is checked before the
  # key is looked up; a key the instance does not hold, or that is not a node's key, is
  # verified under the fixed key all the same, and refused.
  defp verify(conn) do
    with {:ok, key_id} <- present(conn, "x-qory-access-key-id"),
         {:ok, signature} <- present(conn, "x-qory-signature-ed25519"),
         true <- valid_key_id?(key_id),
         {:ok, raw_signature} <- Ed25519.decode(signature, 64),
         {:ok, message} <- message(conn, key_id) do
      {access_key, public_key} = lookup(key_id)

      if Ed25519.verify(message, raw_signature, public_key) and access_key != nil,
        do: {:ok, access_key, signature},
        else: :unauthorized
    else
      _ -> :unauthorized
    end
  end

  defp lookup(key_id) do
    case AccessKeys.fetch_for_verification(key_id) do
      {:ok, %AccessKey{public_key: <<_::binary-size(32)>> = public_key, node: %Node{}} = key} ->
        {key, public_key}

      _other ->
        {nil, @unknown_key}
    end
  end

  defp message(%Plug.Conn{method: "POST"} = conn, key_id) do
    case conn.assigns do
      %{raw_body: body} when is_binary(body) -> {:ok, request(conn, key_id, body)}
      _ -> :error
    end
  end

  defp message(conn, key_id),
    do: {:ok, request(conn, key_id, header(conn, "x-qory-timestamp") || "")}

  defp request(conn, key_id, last) do
    SignedMessage.request(
      key_id,
      header(conn, "x-qory-instance-id"),
      conn.method,
      target(conn),
      last
    )
  end

  # The path and query exactly as received, so the runner and the server sign the same
  # bytes without any normalisation.
  defp target(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp target(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  defp rate(%AccessKey{id: id}, opts) do
    with true <- Keyword.fetch!(opts, :rate_limit),
         {:error, seconds} <- RateLimit.check(id) do
      {:rate_limited, seconds}
    else
      _ -> :ok
    end
  end

  defp instance_id(instance_id) when is_binary(instance_id) do
    if String.valid?(instance_id) and Regex.match?(@instance_id_format, instance_id),
      do: {:ok, instance_id},
      else: {:refuse, 400, "bad_request"}
  end

  defp instance_id(nil), do: {:refuse, 400, "bad_request"}

  # The instance is the node's, recorded for a key awaiting approval too, so an admin
  # sees what waits. A GET whose timestamp is outside the window records nothing: a
  # stale or replayed request is an authentication failure, refused with 401 further on.
  # `Apiary.Nodes.seen/3` never fails.
  defp seen(_conn, _access_key, _instance_id, :unauthorized), do: :ok

  defp seen(conn, %AccessKey{node: node} = access_key, instance_id, :ok) do
    Nodes.seen(node, %{
      instance_id: instance_id,
      name: header(conn, "x-qory-instance-name"),
      access_key_id: access_key.id,
      runner_version: runner_version(conn),
      contract_version:
        case ContractVersion.fetch(conn) do
          {:ok, version} -> version
          :error -> nil
        end
    })
  end

  defp approved(%AccessKey{} = access_key) do
    if AccessKey.status(access_key) == :pending,
      do: {:refuse, 409, "key_pending"},
      else: :ok
  end

  defp contract_version(conn) do
    case ContractVersion.fetch(conn) do
      {:ok, version} -> {:ok, version}
      :error -> :unsupported_contract_version
    end
  end

  defp fresh(%Plug.Conn{method: "POST"}), do: :ok

  defp fresh(conn) do
    with timestamp when is_binary(timestamp) <- header(conn, "x-qory-timestamp"),
         true <- Regex.match?(@timestamp_format, timestamp),
         true <- abs(now() - String.to_integer(timestamp)) <= @window_seconds do
      :ok
    else
      _ -> :unauthorized
    end
  end

  defp now do
    case Application.get_env(:apiary, :contract_now) do
      clock when is_function(clock, 0) -> clock.()
      _ -> System.os_time(:second)
    end
  end

  defp refuse(conn, status, code) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: code})
    |> halt()
  end

  defp unauthorized(conn), do: refuse(conn, 401, "unauthorized")

  defp valid_key_id?(key_id), do: String.valid?(key_id) and Regex.match?(@key_id_format, key_id)

  # Recording the use is bookkeeping: the request is already verified, and an error here
  # (a lost connection, a value the row refuses) leaves it a success. A delivery's use is
  # the receiver's to record.
  defp touch(%Plug.Conn{method: "POST"} = conn, _access_key), do: conn

  defp touch(conn, access_key) do
    attrs = %{
      last_runner_version: runner_version(conn),
      last_contract_version: conn.assigns.contract_version
    }

    case AccessKeys.touch(access_key, attrs) do
      {:ok, touched} -> assign(conn, :access_key, touched)
      {:error, _changeset} -> conn
    end
  rescue
    _exception -> conn
  end

  defp present(conn, name) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end

  @doc "The runner version of `User-Agent: qory-runner/<version>`, as the columns hold it, or nil."
  def runner_version(conn) do
    with [user_agent] <- get_req_header(conn, "user-agent"),
         true <- String.valid?(user_agent),
         [_, version] <- Regex.run(~r{^qory-runner/(\S+)}, user_agent),
         true <- Regex.match?(@printable, version) do
      String.slice(version, 0, @runner_version_max)
    else
      _ -> nil
    end
  end
end
