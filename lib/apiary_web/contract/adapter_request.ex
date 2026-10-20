defmodule ApiaryWeb.Contract.AdapterRequest do
  @moduledoc false

  # Verifies a signed request of an adapter (a node of kind `adapter`) under its access
  # key, as the integration contract has it (qoryai/integrations,
  # `contracts/integration/v1/definitions.schema.json` and `refusal.schema.json`), signs
  # every answer to it but a 401, and refuses what the contract refuses. The routes of the
  # pipeline `:contract_adapter` go through it.
  #
  # **Whose key, by kind.** The plug is given the kind of key it verifies, `kind:
  # :adapter` (the default) or `kind: :pool`. A node pool's starter signs the provisioner
  # contract's requests (`contracts/provisioner/v1/definitions.schema.json`) with the
  # pool's access key exactly as an adapter signs the integration contract's, and is
  # answered as an adapter is: the routes of the pipeline `:contract_pool` go through it
  # with `kind: :pool`. Everything below holds for both kinds; they differ only in the
  # key a request verifies under (`lookup/2`), the revisions served (`revisions/1`) and
  # the bucket the rate limit spends (`rate/2`). This plug refuses a pool's key on an
  # adapter's route, and every key but a pool's on a pool's route, as it refuses an
  # unknown key. A pool's key also verifies on the Forager contract's routes, through
  # `ApiaryWeb.Contract.SignedRequest`, as below.
  #
  # **The signature.** The request is signed as a request of the Forager contract is
  # (`Apiary.Contract.SignedMessage.request/5`): `X-Qory-Access-Key-Id`,
  # `X-Qory-Instance-Id`, `X-Qory-Contract-Version` and `X-Qory-Signature-Ed25519`, the
  # signature over the key id, the instance id, the method, the target exactly as received
  # and, for a GET, `X-Qory-Timestamp`, for a POST, the raw body
  # (`ApiaryWeb.Contract.RawBody`), whose `time` gives its freshness.
  #
  # **Whose key.** With `kind: :adapter`, only an adapter's key verifies here, and an
  # adapter's key verifies only here: `ApiaryWeb.Contract.SignedRequest` holds a node's, a
  # node pool's and a gateway's, and refuses an adapter's; this plug refuses every other
  # kind, with the same `401` as an unknown key, verified under a fixed public key so it
  # costs what a known one does. With `kind: :pool`, only an active key of a node pool
  # verifies (of a workspace, and an organisation in use, as
  # `Apiary.AccessKeys.fetch_for_verification/1` holds a pool's key), and every other
  # kind's is refused the same way. Which key may take which action is
  # `Apiary.Access`'s to decide, not this plug's.
  #
  # **Freshness and replay.** A request is fresh when its time is within 300 seconds of
  # the contract's clock (`ApiaryWeb.Contract.SignedRequest.now/0`), either way: a GET's
  # `X-Qory-Timestamp`, read here, a POST's body `time`, read by its endpoint, which then
  # calls `accept/2`. A fresh request is then recorded as seen
  # (`Apiary.Adapters.SeenRequests.record/4`, keyed on the 64 decoded signature bytes),
  # and a request whose signature was recorded before is a replay. Stale, future and
  # replayed requests are each the same unsigned `401`.
  #
  # **The order of refusals.** The codes, and which refusals may go out unsigned, are the
  # integration contract's. The order of the checks before the body is the one the
  # Forager contract's requests have, as these are signed as those are (the `413` of a
  # body over 1 MiB comes first, in `ApiaryWeb.Contract.RawBody`):
  #
  #   1. `415` `unsupported_media_type`, unsigned, for a POST that is not
  #      `application/json`;
  #   2. `400` `bad_request`, unsigned, for `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`,
  #      `X-Qory-Signature-Ed25519` or `X-Qory-Timestamp` sent twice;
  #   3. `401` `unauthorized`, unsigned and the same whatever the cause: a key id or a
  #      signature missing, a key id of the wrong shape, a key the instance does not hold,
  #      has revoked, or that is not of the kind the route verifies, a row that fails its
  #      integrity check, a signature that is not 64 bytes of strict base64url or does not
  #      verify;
  #   4. `429` `rate_limited` with `Retry-After`, from the key's bucket for adapters, or
  #      for node pools, one bucket per key
  #      (`config :apiary, ApiaryWeb.Contract.AdapterRequest`, `rate` and `burst`, 50 and
  #      100 unless set);
  #   5. `400` `bad_request` for an instance id absent or outside its pattern;
  #   6. `400` `unsupported_contract_version` for an `X-Qory-Contract-Version` absent, sent
  #      twice, not a decimal integer, or a revision of the integration contract this
  #      server does not serve (`revisions/0`), or of the provisioner contract for a
  #      pool's key (`revisions(:pool)`);
  #   7. for a GET, `401`, unsigned, for an `X-Qory-Timestamp` that is missing, not a
  #      decimal integer or not fresh, then `401` for a replay.
  #
  # A POST's endpoint then reads its body, `400` `invalid_request` for one the contract
  # refuses, and asks `accept/2` with the body's `time`: `401` for one that is not fresh,
  # then `401` for a replay. A verified POST whose endpoint answers `2xx` without
  # `accept/2` having marked the conn is answered `500` (`internal_error`) instead, so an
  # endpoint that forgets the check acts on no replay unseen: the log names the module and
  # the path, nothing of the request.
  #
  # **Its use.** A request that passes its freshness and replay checks records the key's
  # use, `last_used_at` (`Apiary.AccessKeys.touch_delivery/2`), POSTs included: it is
  # what an adapter's "Last seen" reads (`Apiary.Adapters.last_seen/2`). Recording is
  # bookkeeping: an error there leaves the request a success.
  #
  # From the moment the request verifies, its answer is signed
  # (`ApiaryWeb.Contract.SignedAnswer.register/2`), but a `401`. A refusal is
  # `application/json`, `{"error": "<code>"}`. A verified request leaves the conn's
  # `access_key` (with its node), `request_signature`, `instance_id` and
  # `contract_version`. Nothing here logs a header value, a signature or a key.

  import Plug.Conn

  require Logger

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.SeenRequests
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.LogMetadata
  alias Apiary.Nodes.Node
  alias Apiary.Runs.RateLimit
  alias ApiaryWeb.Contract.{SignedAnswer, SignedRequest}

  @window_seconds 300
  @json_type {"content-type", "application/json; charset=utf-8"}
  # The revisions served, by the kind of key: the integration contract's for an
  # adapter, the provisioner contract's for a node pool.
  @revisions %{adapter: [1], pool: [3]}
  @kinds Map.keys(@revisions)
  @key_id_format ~r/\Aak_[0-9a-hjkmnp-tv-z]{16}\z/
  @instance_id_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @timestamp_format ~r/\A[0-9]{1,19}\z/
  @revision_format ~r/\A[1-9][0-9]{0,8}\z/
  # The headers the signature depends on, each refused when sent more than once.
  @once [
    "x-qory-access-key-id",
    "x-qory-instance-id",
    "x-qory-signature-ed25519",
    "x-qory-timestamp"
  ]

  # The public key a request under a key the instance does not hold as an adapter's is
  # verified under: the key of the seed of 32 zero bytes, which nobody holds as theirs.
  @unknown_key elem(:crypto.generate_key(:eddsa, :ed25519, <<0::256>>), 0)

  # The revisions of the integration contract this server serves.
  @doc false
  @spec revisions() :: [pos_integer]
  def revisions, do: revisions(:adapter)

  # The revisions this server serves of the contract a key of `kind` signs: the
  # integration contract's for `:adapter`, the provisioner contract's for `:pool`.
  @doc false
  @spec revisions(:adapter | :pool) :: [pos_integer]
  def revisions(kind) when kind in @kinds, do: Map.fetch!(@revisions, kind)

  # How far a request's time may be from the contract's clock, either way, in seconds.
  @doc false
  @spec window_seconds() :: pos_integer
  def window_seconds, do: @window_seconds

  # `kind:`, the kind of key verified, `:adapter` unless given.
  @doc false
  def init(opts) do
    opts = Keyword.validate!(opts, kind: :adapter)

    unless opts[:kind] in @kinds,
      do: raise(ArgumentError, "kind is one of #{inspect(@kinds)}")

    opts
  end

  @doc false
  def call(conn, opts) do
    kind = Keyword.get(opts, :kind, :adapter)

    with :ok <- content_type(conn),
         :ok <- sent_once(conn),
         {:ok, access_key, signature, raw_signature} <- verify(conn, kind) do
      LogMetadata.put(access_key)

      conn
      |> assign(:access_key, access_key)
      |> assign(:request_signature, signature)
      |> put_private(:adapter_request_signature, raw_signature)
      |> SignedAnswer.register(signature)
      |> require_accept(kind)
      |> after_verification(access_key, kind)
    else
      {:refuse, status, code} -> refuse(conn, status, code)
      :unauthorized -> unauthorized(conn)
    end
  end

  # The refusals after verification, in order, each answer signed but a 401.
  defp after_verification(conn, access_key, kind) do
    with :ok <- rate(access_key, kind),
         {:ok, instance_id} <- instance_id(header(conn, "x-qory-instance-id")),
         {:ok, revision} <- revision(conn, kind),
         :ok <- get_fresh_and_unseen(conn, access_key) do
      conn
      |> assign(:instance_id, instance_id)
      |> assign(:contract_version, revision)
    else
      {:rate_limited, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> refuse(429, "rate_limited")

      {:refuse, status, code} ->
        refuse(conn, status, code)

      :unauthorized ->
        unauthorized(conn)
    end
  end

  # Registered after the signing callback, so it runs before it and the signature covers
  # the `500` it may put in place of a `2xx`: callbacks run in the reverse of the order
  # they are registered in.
  defp require_accept(%Plug.Conn{method: "POST"} = conn, kind) do
    register_before_send(conn, fn
      %Plug.Conn{status: status, private: private} = conn when status in 200..299 ->
        if private[:adapter_request_accepted] == true, do: conn, else: unaccepted(conn, kind)

      conn ->
        conn
    end)
  end

  defp require_accept(conn, _kind), do: conn

  defp unaccepted(conn, kind) do
    Logger.error(
      "#{whose(kind)} POST was answered 2xx without AdapterRequest.accept/2: " <>
        "#{inspect(conn.private[:phoenix_controller])} #{conn.request_path}"
    )

    %{
      conn
      | status: 500,
        resp_body: ~s({"error":"internal_error"}),
        resp_headers: List.keystore(conn.resp_headers, "content-type", 0, @json_type)
    }
  end

  @doc false
  # accept/2 is a POST's check of its body's `time`, once its endpoint has read the body:
  # `{:ok, conn}`, the conn marked as accepted, which a `2xx` answer needs, when `time` is
  # within 300 seconds of the contract's clock, either way, and the request's signature
  # was not accepted before, which it then records as accepted, with the key's use;
  # `:unauthorized` otherwise, which the endpoint answers `401`.
  @spec accept(Plug.Conn.t(), DateTime.t()) :: {:ok, Plug.Conn.t()} | :unauthorized
  def accept(
        %Plug.Conn{
          method: "POST",
          assigns: %{access_key: %AccessKey{} = access_key},
          private: %{adapter_request_signature: <<_::binary-size(64)>> = signature}
        } = conn,
        %DateTime{} = time
      ) do
    with :ok <- fresh_and_unseen(access_key, signature, DateTime.to_unix(time)) do
      {:ok, put_private(conn, :adapter_request_accepted, true)}
    end
  end

  def accept(_conn, _time), do: :unauthorized

  # A POST's time is in its body, which its endpoint reads and hands to `accept/2`.
  defp get_fresh_and_unseen(%Plug.Conn{method: "POST"}, _access_key), do: :ok

  defp get_fresh_and_unseen(conn, access_key) do
    with timestamp when is_binary(timestamp) <- header(conn, "x-qory-timestamp"),
         true <- Regex.match?(@timestamp_format, timestamp) do
      fresh_and_unseen(
        access_key,
        conn.private.adapter_request_signature,
        String.to_integer(timestamp)
      )
    else
      _ -> :unauthorized
    end
  end

  # The one place a request's time is judged: fresh, then unseen, then its use recorded.
  defp fresh_and_unseen(access_key, signature, time) do
    now = SignedRequest.now()

    with true <- abs(now - time) <= @window_seconds,
         :ok <- SeenRequests.record(access_key, signature, time, now) do
      touch(access_key)
    else
      _ -> :unauthorized
    end
  end

  # Recording the use is bookkeeping: the request is already accepted, and an error here
  # (a lost connection, a row gone) leaves it a success.
  defp touch(access_key) do
    AccessKeys.touch_delivery(access_key, %{})
    :ok
  rescue
    _exception -> :ok
  end

  # As the reference receiver reads it: the media type, whatever its case and whatever
  # parameters follow. Only a POST has a body to type.
  defp content_type(%Plug.Conn{method: "POST"} = conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        media = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
        if media == "application/json", do: :ok, else: {:refuse, 415, "unsupported_media_type"}

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

  defp whose(:adapter), do: "an adapter's"
  defp whose(:pool), do: "a node pool's"

  # Every failure is the same `:unauthorized`. The key id's shape is checked before the
  # key is looked up; a key that is not of `kind` is verified under the fixed key all the
  # same, and refused.
  defp verify(conn, kind) do
    with {:ok, key_id} <- present(conn, "x-qory-access-key-id"),
         {:ok, signature} <- present(conn, "x-qory-signature-ed25519"),
         true <- String.valid?(key_id) and Regex.match?(@key_id_format, key_id),
         {:ok, raw_signature} <- Ed25519.decode(signature, 64),
         {:ok, message} <- message(conn, key_id) do
      {access_key, public_key} = lookup(key_id, kind)

      if Ed25519.verify(message, raw_signature, public_key) and access_key != nil,
        do: {:ok, access_key, signature, raw_signature},
        else: :unauthorized
    else
      _ -> :unauthorized
    end
  end

  # For `:adapter`, an adapter's key, of the instance, and no other kind's. For `:pool`,
  # a node pool's key, of its workspace and organisation, and no other kind's: one
  # `Apiary.AccessKeys.fetch_for_verification/1` answers with, so neither revoked, nor of
  # a pool deleted, nor of a workspace or an organisation marked for deletion or out of
  # use.
  defp lookup(key_id, kind) do
    case AccessKeys.fetch_for_verification(key_id) do
      {:ok, %AccessKey{public_key: <<_::binary-size(32)>> = public_key} = key} ->
        if of_kind?(key, kind), do: {key, public_key}, else: {nil, @unknown_key}

      _other ->
        {nil, @unknown_key}
    end
  end

  defp of_kind?(
         %AccessKey{organisation_id: nil, workspace_id: nil, node: %Node{kind: :adapter}},
         :adapter
       ),
       do: true

  defp of_kind?(
         %AccessKey{
           organisation_id: organisation_id,
           workspace_id: workspace_id,
           node: %Node{kind: :pool, organisation_id: organisation_id, workspace_id: workspace_id}
         },
         :pool
       )
       when is_binary(organisation_id) and is_binary(workspace_id),
       do: true

  defp of_kind?(_key, _kind), do: false

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

  # The path and query exactly as received, so the adapter and the server sign the same
  # bytes without any normalisation.
  defp target(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp target(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  # Each key spends a bucket of its kind: `{:adapter, id}` or `{:pool, id}`.
  defp rate(%AccessKey{id: id}, kind) do
    limit = Application.get_env(:apiary, __MODULE__, [])
    limit = Keyword.merge([rate: 50, burst: 100], Keyword.take(limit, [:rate, :burst]))

    case RateLimit.check({kind, id}, limit) do
      {:error, seconds} -> {:rate_limited, seconds}
      _ok -> :ok
    end
  end

  defp instance_id(instance_id) when is_binary(instance_id) do
    if String.valid?(instance_id) and Regex.match?(@instance_id_format, instance_id),
      do: {:ok, instance_id},
      else: {:refuse, 400, "bad_request"}
  end

  defp instance_id(nil), do: {:refuse, 400, "bad_request"}

  defp revision(conn, kind) do
    with [value] <- get_req_header(conn, "x-qory-contract-version"),
         true <- Regex.match?(@revision_format, value),
         revision = String.to_integer(value),
         true <- revision in revisions(kind) do
      {:ok, revision}
    else
      _ -> {:refuse, 400, "unsupported_contract_version"}
    end
  end

  defp refuse(conn, status, code) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: code})
    |> halt()
  end

  defp unauthorized(conn), do: refuse(conn, 401, "unauthorized")

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
end
