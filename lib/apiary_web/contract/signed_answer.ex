defmodule ApiaryWeb.Contract.SignedAnswer do
  @moduledoc ~S"""
  Signs the server's answers to the runner contract's requests (the contract's "Signed
  answers"): every answer to a request that verified, whatever its status, except a
  `401`, which always goes out unsigned.

  A signed answer carries two headers:

    * `X-Qory-Signature-Ed25519`, the Ed25519 signature under the instance's signing key
      (`Apiary.SigningKey`), 64 bytes in base64url without padding, of the answer string
      (`Apiary.Contract.SignedMessage.answer/5`): the status, the request's
      `X-Qory-Signature-Ed25519` exactly as sent, the SHA-256 of the body as sent, and
      the answer's `X-Qory-Configuration` and `X-Qory-Run-Configuration`, each empty when
      the answer has none; or, for an answer to an enrolment, of the enrolment answer
      string (`Apiary.Contract.SignedMessage.enrolment_answer/3`), under its own domain
      line, with the request's `proof` in place of a signature;
    * `Cache-Control: no-store, no-transform`, so no cache keeps the answer and no proxy
      re-codes the body the signature covers.

  `register/2` is how a verified request's answer is signed: it registers a callback that
  signs the answer as it is sent, from the status, body and digest headers the answer
  has by then, so a controller writes its answer as any other and the signature covers
  exactly what goes out. `put_enrolment/3` signs an answer to an enrolment, written but
  not yet sent, bound to its proof: a function of its own, so an enrolment answer is never
  signed under the request answers' domain line.

  Nothing here logs, and no error message carries a signature or a key.
  """

  import Plug.Conn

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.SigningKey

  @signature "x-qory-signature-ed25519"
  @configuration "x-qory-configuration"
  @run_configuration "x-qory-run-configuration"
  @cache_control "no-store, no-transform"

  @doc """
  register/2 signs the answer to a verified request when it is sent, bound to
  `request_signature`, the request's `X-Qory-Signature-Ed25519` as sent. An answer with
  status `401` is sent unsigned. The key is the instance's (`Apiary.SigningKey.current/0`).
  """
  @spec register(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def register(%Plug.Conn{} = conn, request_signature) when is_binary(request_signature) do
    register_before_send(conn, fn
      %Plug.Conn{status: 401} = conn -> conn
      conn -> put(conn, request_signature)
    end)
  end

  @doc """
  put/3 sets the signature and `Cache-Control` of an answer whose status, body and digest
  headers are set, bound to `request_signature`, the signed request's
  `X-Qory-Signature-Ed25519` as sent, under `key`, the instance's key unless given.
  """
  @spec put(Plug.Conn.t(), String.t(), SigningKey.t() | nil) :: Plug.Conn.t()
  def put(%Plug.Conn{} = conn, request_signature, key \\ nil)
      when is_binary(request_signature) do
    {cache_control, signature} =
      headers(
        conn.status,
        request_signature,
        conn.resp_body || "",
        single(conn, @configuration),
        single(conn, @run_configuration),
        key || SigningKey.current()
      )

    conn
    |> put_resp_header("cache-control", cache_control)
    |> put_resp_header(@signature, signature)
  end

  @doc """
  put_enrolment/3 sets the signature and `Cache-Control` of an answer to an enrolment
  whose status and body are set, bound to `proof`, the request's `proof` exactly as sent:
  the signature, under `key`, the instance's key unless given, of the enrolment answer
  string (`Apiary.Contract.SignedMessage.enrolment_answer/3`).
  """
  @spec put_enrolment(Plug.Conn.t(), String.t(), SigningKey.t() | nil) :: Plug.Conn.t()
  def put_enrolment(%Plug.Conn{} = conn, proof, key \\ nil) when is_binary(proof) do
    message = SignedMessage.enrolment_answer(conn.status, proof, conn.resp_body || "")
    signature = Ed25519.encode(SigningKey.sign(key || SigningKey.current(), message))

    conn
    |> put_resp_header("cache-control", @cache_control)
    |> put_resp_header(@signature, signature)
  end

  @doc """
  headers/6 is the values of a signed answer's two headers, `{cache_control, signature}`,
  for an answer with `status` and `body` bound to `bound_to`, a signed request's
  signature, carrying the digest headers `configuration` and `run_configuration` (nil for
  one it does not carry), under `key`.
  """
  @spec headers(
          100..599,
          String.t(),
          iodata,
          String.t() | nil,
          String.t() | nil,
          SigningKey.t()
        ) :: {String.t(), String.t()}
  def headers(status, bound_to, body, configuration, run_configuration, key) do
    message = SignedMessage.answer(status, bound_to, body, configuration, run_configuration)
    {@cache_control, Ed25519.encode(SigningKey.sign(key, message))}
  end

  # The answer string carries one value per digest header: an answer sets each once.
  defp single(conn, name) do
    case get_resp_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end
end
