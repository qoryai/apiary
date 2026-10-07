defmodule ApiaryWeb.Contract.EnrolmentController do
  @moduledoc """
  Enrolment, `POST /.well-known/qory-enrolment`: a machine enrols a new access key with an
  enrolment code an owner or an admin made on a node (the runner contract's "Enrolment",
  `enrolment.schema.json`). The request carries no access key id and no request
  signature: the code and the proof authenticate it, so it goes through no
  `ApiaryWeb.Contract.SignedRequest`. Its body is read raw (`ApiaryWeb.Contract.RawBody`)
  and strictly (`Apiary.Contract.Enrolment`); the code is redeemed by
  `Apiary.AccessKeys.enrol/2`.

  **The answers, in order** (the contract's "Enrolment"): unsigned until the code is
  accepted, the key passes the checks and the proof verifies under it; signed after.

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
       expired, cancelled, never made, carrying another fingerprint than the instance's
       key's, or made by someone who is no longer an owner or an admin of its workspace;
       or when the timestamp is more than 300 seconds from the server's clock;
    5. `409` `{"error":"key_invalid"}`, **unsigned**, for a public key the key checks
       refuse (`Apiary.Contract.Ed25519.decode_public_key/1`), checked first, or a proof
       that does not verify under it: nothing is signed for a proof no checked key made;
    6. `429` `rate_limited`, signed, with `Retry-After`, past the code's own limit:
       `code_rate` requests a second and `code_burst` at once, 1 and 5 unless the same
       configuration says otherwise;
    7. `409` `key_invalid`, signed, for a public key the ledger holds: another access
       key's, or a revoked one's;
    8. `409` `key_limit`, signed, for a node that holds two keys;
    9. `201`, signed, with the access key id, its node and its kind, `stored_secrets` and
       the instance's keys: the key is active.

  The order of 5 to 9 is `Apiary.AccessKeys.enrol/2`'s. A signed answer is signed by
  `ApiaryWeb.Contract.SignedAnswer.put_enrolment/3`: `X-Qory-Signature-Ed25519`, the
  instance's signature of the enrolment answer string
  (`Apiary.Contract.SignedMessage.enrolment_answer/3`), under the enrolment answers' own
  domain line `qory-enrol-answer-ed25519-v1`, whose line 3 is the request's `proof`
  exactly as sent, and `Cache-Control: no-store, no-transform`. Each signed body lists
  `apiary_public_key`, the instance's keys (`Apiary.SigningKey.apiary_public_key/0`); an
  unsigned one lists none.

  Nothing here logs the code, the proof or a key; the body is never in the parameters the
  request log sees.
  """
  use ApiaryWeb, :controller

  alias Apiary.{AccessKeys, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.Enrolment
  alias Apiary.Runs.RateLimit
  alias ApiaryWeb.Contract.{ContractVersion, SignedAnswer}

  def create(conn, _params) do
    origin = ApiaryWeb.Origin.from_conn(conn)

    with :ok <- within_rate(origin),
         {:ok, request} <- Enrolment.decode(conn.assigns[:raw_body]),
         {:ok, _version} <- version(conn) do
      case AccessKeys.enrol(request, origin: origin, code_limit: code_limit()) do
        {:ok, key} ->
          signed(conn, request, 201, answer(key))

        {:error, :unauthorized} ->
          unauthorized(conn)

        {:error, :key_unproven} ->
          conn
          |> put_status(409)
          |> json(%{error: "key_invalid"})

        {:error, {:rate_limited, seconds}} ->
          conn
          |> put_resp_header("retry-after", Integer.to_string(seconds))
          |> signed(request, 429, refusal(:rate_limited))

        {:error, :key_invalid} ->
          signed(conn, request, 409, refusal(:key_invalid))

        {:error, :key_limit} ->
          signed(conn, request, 409, refusal(:key_limit))
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

  # The code's own limit, which `Apiary.AccessKeys.enrol/2` counts once the key is proven.
  defp code_limit do
    config = Application.get_env(:apiary, __MODULE__, [])
    [rate: Keyword.get(config, :code_rate, 1), burst: Keyword.get(config, :code_burst, 5)]
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
      stored_secrets: key.allow_secrets,
      apiary_public_key: SigningKey.apiary_public_key()
    })
  end

  defp refusal(error), do: Enrolment.refusal_body(error, SigningKey.apiary_public_key())

  # Under the enrolment answers' own domain line; line 3 of the answer string is the
  # request's proof, exactly as sent.
  defp signed(conn, %Enrolment{proof: proof}, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> resp(status, body)
    |> SignedAnswer.put_enrolment(proof)
    |> send_resp()
  end
end
