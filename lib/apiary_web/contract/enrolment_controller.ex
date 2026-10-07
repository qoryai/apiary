defmodule ApiaryWeb.Contract.EnrolmentController do
  @moduledoc """
  Enrolment, `POST /.well-known/qory-enrolment`: a machine enrols a new access key with an
  enrolment code an owner or an admin made on a node (the runner contract's "Enrolment",
  `enrolment.schema.json`). The request carries no access key id and no request
  signature: the code and the proof authenticate it, so it goes through no
  `ApiaryWeb.Contract.SignedRequest`. Its body is read raw (`ApiaryWeb.Contract.RawBody`)
  and strictly (`Apiary.Contract.Enrolment`); the code is redeemed by
  `Apiary.AccessKeys.enrol/2`.

  **The answers, in order:**

    1. `413`, unsigned, for a body over 8 KiB (`ApiaryWeb.Contract.RawBody`);
    2. `429` `rate_limited`, unsigned, with `Retry-After`, past the limit of the address
       the request came from (`ApiaryWeb.Origin`): `rate` enrolments a second and `burst`
       at once, 1 and 10 unless `config :apiary, #{inspect(__MODULE__)}` says otherwise,
       counted by `Apiary.Runs.RateLimit`;
    3. `400` `invalid_request`, unsigned, for a body the schema refuses, naming the
       members at fault; then `400` `unsupported_contract_version`, unsigned, for an
       `X-Qory-Contract-Version` that names no revision served
       (`ApiaryWeb.Contract.ContractVersion`);
    4. `401` `{"error":"unauthorized"}`, unsigned, when the code is not accepted: used,
       expired, cancelled, never made, or carrying another fingerprint than the
       instance's key's;
    5. once the code is accepted, every answer is signed: `409` `key_invalid` for a key
       the key checks or the ledger refuse, a proof that does not verify, or a timestamp
       more than 300 seconds from the server's clock; `409` `key_limit` for a node that
       holds a key awaiting approval, or two approved keys; and `201` with the access key
       id, its node, `approved`, `stored_secrets` and the instance's keys.

  A signed answer carries `X-Qory-Signature-Ed25519`, the instance's signature
  (`Apiary.SigningKey.sign/1`) of the answer string (`Apiary.Contract.SignedMessage.answer/5`)
  whose line 3 is the request's `proof` exactly as sent, and
  `Cache-Control: no-store, no-transform`. Each signed body lists `apiary_public_key`,
  the instance's keys (`Apiary.SigningKey.apiary_public_key/0`).

  Nothing here logs the code, the proof or a key; the body is never in the parameters the
  request log sees.
  """
  use ApiaryWeb, :controller

  alias Apiary.{AccessKeys, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Runs.RateLimit
  alias ApiaryWeb.Contract.ContractVersion

  def create(conn, _params) do
    origin = ApiaryWeb.Origin.from_conn(conn)

    with :ok <- within_rate(origin),
         {:ok, request} <- Enrolment.decode(conn.assigns[:raw_body]),
         {:ok, _version} <- version(conn) do
      case AccessKeys.enrol(request, origin: origin) do
        {:ok, key} -> signed(conn, request, 201, answer(key))
        {:error, :key_invalid} -> signed(conn, request, 409, refusal(:key_invalid))
        {:error, :key_limit} -> signed(conn, request, 409, refusal(:key_limit))
        {:error, :unauthorized} -> unauthorized(conn)
      end
    else
      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> put_status(429)
        |> json(%{error: "rate_limited"})

      {:error, names} when is_list(names) ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid_request", names: names})

      :unsupported_version ->
        ContractVersion.refuse(conn)
    end
  end

  # Counted by the address the request came from, before anything is read of the body.
  defp within_rate(%{remote_ip: address}) do
    opts = Keyword.take(Application.get_env(:apiary, __MODULE__, []), [:rate, :burst])
    opts = Keyword.merge([rate: 1, burst: 10], opts)

    case RateLimit.check({:enrolment, address}, opts) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp version(conn) do
    case ContractVersion.fetch(conn) do
      {:ok, version} -> {:ok, version}
      :error -> :unsupported_version
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{error: "unauthorized"})
  end

  defp answer(%AccessKey{node: node} = key) do
    Enrolment.answer_body(%{
      access_key_id: key.key_id,
      node_id: node.public_id,
      node_kind: node.kind,
      approved: key.approved_at != nil,
      stored_secrets: key.allow_secrets,
      apiary_public_key: SigningKey.apiary_public_key()
    })
  end

  defp refusal(error), do: Enrolment.refusal_body(error, SigningKey.apiary_public_key())

  # Line 3 of the answer string is the request's proof, exactly as sent.
  defp signed(conn, %Enrolment{proof: proof}, status, body) do
    signature =
      status
      |> SignedMessage.answer(proof, body, nil, nil)
      |> SigningKey.sign()
      |> Ed25519.encode()

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store, no-transform")
    |> put_resp_header("x-qory-signature-ed25519", signature)
    |> send_resp(status, body)
  end
end
