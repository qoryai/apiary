defmodule ApiaryWeb.Contract.RawBody do
  @moduledoc """
  Reads the body of a delivery to the events endpoint, of a run's registration, of a run's
  attach, of a run's outcome, of a report of a run's model keys, and of an enrolment,
  before anything parses it.

  The signature of a signed POST is over the raw bytes, and it is checked before the body
  is parsed; an enrolment is read strictly, a member twice refused, which a parser that
  keeps the last of them cannot tell. So for `POST /v1/events`, `POST /v1/runs`,
  `POST /v1/runs/<run_id>/attach`, `POST /v1/runs/<run_id>/outcome`,
  `POST /v1/runs/<run_id>/model-keys` and `POST /.well-known/qory-enrolment`, whatever the
  content type, this plug reads the body
  itself, keeps it in `conn.assigns[:raw_body]` and leaves the body parameters empty; the
  endpoint skips `Plug.Parsers` for such a request. Signed paths of other contracts, which
  this documentation does not name, are read the same way where the instance serves them,
  or where the request carries a signature. Every other request passes untouched.

  At most `max_bytes/0` of a delivery are read, 2 MiB, `max_bytes(:registration)` of a
  registration, 64 KiB, `max_bytes(:attach)` of an attach, 64 KiB, `max_bytes(:outcome)`
  of an outcome, 4 KiB, and
  `max_bytes(:enrolment)` of an enrolment, 8 KiB, the last three many times the longest
  the schema allows: what an unauthenticated sender can make the
  server hold is small. Of a report of a run's model keys, `max_bytes(:model_keys)`, 16 KiB,
  the contract's limit, are read. A longer body is answered `413` here, before the signature or the
  code is looked at, as the contract's reference receiver does.

  A run's push and verdict, `POST /v1/runs/<run_id>/artifacts` and
  `POST /v1/runs/<run_id>/verdict`, contain files as base64, so they take up to
  `max_bytes(:run_api)`, 32 MiB. To keep what an unauthenticated sender can make the
  server hold small there too, such a body is answered `413` at once when its
  `Content-Length` is over 32 MiB, and its first `max_bytes(:unauthenticated)`, 64 KiB,
  are read before anything else: a longer body is read on only when
  `X-Qory-Access-Key-Id` is the key id of an active access key of a gateway, else it is
  answered `413` with the rest left unread. The signature is still checked after the
  read, by the pipeline.
  """

  import Plug.Conn

  @max_bytes 2 * 1024 * 1024
  @registration_max_bytes 64 * 1024
  @outcome_max_bytes 4 * 1024
  # A report of a run's model keys, `POST /v1/runs/<run_id>/model-keys`, of the `factory`
  # and `secrets` features both: at most 16 KiB, the Forager contract's limit, read as a
  # secrets request is, where both are on or where the request has a signature.
  @model_keys_max_bytes 16 * 1024
  @enrolment_max_bytes 8 * 1024
  # The integration contract's limit, 1 MiB, for its signed paths, which this
  # documentation does not name.
  @adapter_max_bytes 1024 * 1024
  # The integration contract's signed paths served here, read the same way where
  # `served?/1` holds, as below: `POST /v1/adapter`, `POST /v1/source-collections`,
  # `POST /v1/source-items`, `POST /v1/sources/disconnect`,
  # `POST /v1/source-items/comments`, `POST /v1/adapter/secrets`, `POST /v1/grants`,
  # `POST /v1/grants/end` and `POST /v1/work-items/changes/failed`.
  @adapter_paths [
    ["v1", "adapter"],
    ["v1", "source-collections"],
    ["v1", "source-items"],
    ["v1", "grants"]
  ]
  @adapter_three_paths [
    ["v1", "sources", "disconnect"],
    ["v1", "source-items", "comments"],
    ["v1", "adapter", "secrets"],
    ["v1", "grants", "end"]
  ]
  @adapter_four_paths [["v1", "work-items", "changes", "failed"]]
  # The provisioner contract's limit, 1 MiB (its `refusal.schema.json`, 413), for its
  # signed paths, a node pool's starter's: `POST /v1/pools/claim` and
  # `POST /v1/dispatches/<dispatch_id>/dispatched`, `/release`, `/machine-log` and
  # `/machine-end`. Read the same way where `served?/1` holds, as below.
  @pool_max_bytes 1024 * 1024
  # The form of an access key id, as `ApiaryWeb.Contract.SignedRequest` checks it
  # (`valid_key_id?/1`). The lookup runs only for an id of this form: an id with an invalid
  # UTF-8 byte or a NUL fails in the database query.
  @key_id_format ~r/\Aak_[0-9a-hjkmnp-tv-z]{16}\z/
  @pool_claim_path ["v1", "pools", "claim"]
  @dispatch_actions ["dispatched", "release", "machine-log", "machine-end"]
  # The integration contract's paths and the provisioner contract's belong to one feature.
  # Their bodies are read here only where the instance has it, or where the request
  # carries a signature, which `ApiaryWeb.Features.Routes` lets through to be verified: an
  # unsigned one where the feature is off is parsed as any request to a path the router
  # does not know, and answered as one.
  @gated [:adapter, :pool]
  @gate_feature :factory
  # A gateway's secrets request, `POST /v1/secrets`, of the `factory` and `secrets`
  # features both: at most 32 KiB, the contract's limit, read the same way where both are
  # on or where the request has a signature.
  @secrets_path ["v1", "secrets"]
  @secrets_max_bytes 32 * 1024
  # The run API's pushes and verdicts, `POST /v1/runs/<run_id>/artifacts` and
  # `/verdict`, of the `workflow_model` feature: at most 32 MiB, base64 JSON
  # (`ApiaryWeb.Contract.RunApi.Body.max_bytes(:push)`), read the same way where the
  # feature is on or where the request has a signature. Past the first 64 KiB, only for
  # the key id of an active gateway key.
  @run_api_max_bytes 32 * 1024 * 1024
  @unauthenticated_max_bytes 64 * 1024
  @run_api_actions ["artifacts", "verdict"]
  @events_path ["v1", "events"]
  @registration_path ["v1", "runs"]
  @enrolment_path [".well-known", "qory-enrolment"]

  @doc """
  The largest body that is accepted, in bytes: of a delivery (`max_bytes/0`), of a
  registration (`max_bytes(:registration)`), of an attach (`max_bytes(:attach)`), of an
  outcome (`max_bytes(:outcome)`), of a report of a run's model keys
  (`max_bytes(:model_keys)`), of an enrolment (`max_bytes(:enrolment)`), or of a
  run's push or verdict (`max_bytes(:run_api)`), of which at most
  `max_bytes(:unauthenticated)` are read before the key id is looked up.
  """
  def max_bytes, do: @max_bytes
  def max_bytes(:events), do: @max_bytes
  def max_bytes(:registration), do: @registration_max_bytes
  def max_bytes(:attach), do: @registration_max_bytes
  def max_bytes(:outcome), do: @outcome_max_bytes
  def max_bytes(:model_keys), do: @model_keys_max_bytes
  def max_bytes(:enrolment), do: @enrolment_max_bytes
  def max_bytes(:adapter), do: @adapter_max_bytes
  def max_bytes(:pool), do: @pool_max_bytes
  def max_bytes(:secrets), do: @secrets_max_bytes
  def max_bytes(:run_api), do: @run_api_max_bytes
  def max_bytes(:unauthenticated), do: @unauthenticated_max_bytes

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: path_info} = conn, _opts) do
    case kept(path_info) do
      nil ->
        conn

      endpoint when endpoint in @gated ->
        if served?(conn), do: keep(conn, max_bytes(endpoint)), else: conn

      endpoint when endpoint in [:secrets, :model_keys] ->
        if secrets_served?(conn), do: keep(conn, max_bytes(endpoint)), else: conn

      :run_api ->
        if run_api_served?(conn), do: keep_of_a_gateway(conn), else: conn

      endpoint ->
        keep(conn, max_bytes(endpoint))
    end
  end

  def call(conn, _opts), do: conn

  # The router matches the decoded path, so this does: `/v1/%65vents` is the
  # events endpoint too, and its body is no more to be parsed unverified.
  defp kept([_, _] = path_info) do
    case Enum.map(path_info, &decode/1) do
      @events_path -> :events
      @registration_path -> :registration
      @enrolment_path -> :enrolment
      @secrets_path -> :secrets
      path when path in @adapter_paths -> :adapter
      _other -> nil
    end
  end

  defp kept([_, _, _] = path_info) do
    case Enum.map(path_info, &decode/1) do
      @pool_claim_path -> :pool
      path when path in @adapter_three_paths -> :adapter
      _other -> nil
    end
  end

  defp kept([_, _, _, _] = path_info) do
    case Enum.map(path_info, &decode/1) do
      path when path in @adapter_four_paths -> :adapter
      path -> of_a_run(path)
    end
  end

  defp kept(_path_info), do: nil

  defp of_a_run(["v1", "runs", _run_id, "attach"]), do: :attach
  defp of_a_run(["v1", "runs", _run_id, "outcome"]), do: :outcome
  defp of_a_run(["v1", "runs", _run_id, "model-keys"]), do: :model_keys
  defp of_a_run(["v1", "runs", _run_id, action]) when action in @run_api_actions, do: :run_api

  defp of_a_run(["v1", "dispatches", _dispatch_id, action]) when action in @dispatch_actions,
    do: :pool

  defp of_a_run(_path_info), do: nil

  defp served?(conn) do
    Apiary.Features.on?(@gate_feature) or get_req_header(conn, "x-qory-signature-ed25519") != []
  end

  defp secrets_served?(conn) do
    (Apiary.Features.on?(@gate_feature) and Apiary.Features.on?(:secrets)) or
      get_req_header(conn, "x-qory-signature-ed25519") != []
  end

  defp run_api_served?(conn) do
    ApiaryWeb.Contract.RunApi.Boundary.on?() or
      get_req_header(conn, "x-qory-signature-ed25519") != []
  end

  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  defp keep(conn, max) do
    case read(conn, [], 0, max) do
      {:ok, body, conn} -> kept_body(conn, body)
      {:over, _acc, _size, conn} -> too_large(conn)
      {:error, conn} -> too_large(conn)
    end
  end

  # A run's push or verdict: refused by its `Content-Length` before a byte is read; then
  # the first 64 KiB; then, for the key id of an active gateway key alone, the rest up
  # to 32 MiB.
  defp keep_of_a_gateway(conn) do
    first = @unauthenticated_max_bytes
    max = @run_api_max_bytes

    if declared_length(conn) > max do
      too_large(conn)
    else
      case read(conn, [], 0, first) do
        {:ok, body, conn} ->
          kept_body(conn, body)

        {:over, acc, size, conn} ->
          if gateway_key?(conn) do
            case read(conn, acc, size, max) do
              {:ok, body, conn} -> kept_body(conn, body)
              {:over, _acc, _size, conn} -> too_large(conn)
              {:error, conn} -> too_large(conn)
            end
          else
            too_large(conn)
          end

        {:error, conn} ->
          too_large(conn)
      end
    end
  end

  # The `Content-Length` the sender gave, 0 for none or one that is not a number.
  defp declared_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(String.trim(value)) do
      length
    else
      _other -> 0
    end
  end

  # Whether the request's key id is an active access key of a gateway. An id that is not of
  # the form of a key id is not one.
  defp gateway_key?(conn) do
    with [key_id] <- get_req_header(conn, "x-qory-access-key-id"),
         true <- String.valid?(key_id) and Regex.match?(@key_id_format, key_id),
         {:ok, %Apiary.AccessKeys.AccessKey{node: %Apiary.Nodes.Node{kind: :gateway}}} <-
           Apiary.AccessKeys.fetch_for_verification(key_id) do
      true
    else
      _other -> false
    end
  end

  defp kept_body(conn, body) do
    %{conn | body_params: %{}}
    |> fetch_query_params()
    |> assign(:raw_body, body)
  end

  defp too_large(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(413, ~s({"error":"payload_too_large"}))
    |> halt()
  end

  # One byte over the limit is asked for, so a body of exactly the limit is
  # told from a longer one without reading the rest. Past the limit, `{:over, acc, size,
  # conn}`, with what was read, and the rest of the body left unread.
  defp read(conn, acc, size, max) do
    case read_body(conn, length: max + 1 - size, read_length: min(64_000, max + 1)) do
      {:ok, chunk, conn} -> finish(conn, [acc, chunk], size + byte_size(chunk), max)
      {:more, chunk, conn} -> more(conn, [acc, chunk], size + byte_size(chunk), max)
      {:error, _reason} -> {:error, conn}
    end
  end

  defp finish(conn, acc, size, max) when size > max, do: {:over, acc, size, conn}
  defp finish(conn, acc, _size, _max), do: {:ok, IO.iodata_to_binary(acc), conn}

  defp more(conn, acc, size, max) when size > max, do: {:over, acc, size, conn}
  defp more(conn, acc, size, max), do: read(conn, acc, size, max)
end
