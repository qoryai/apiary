defmodule Apiary.Contract.SignedMessage do
  @moduledoc ~S"""
  SignedMessage builds the two messages the server contract signs with Ed25519
  (`Apiary.Contract.Ed25519`): a request's, which a runner signs under its access key,
  and an answer's, which the server signs under its own key. Each is lines joined by
  `\n`, with no newline after the last. Pure functions; nothing here touches the
  database, a connection or a log, and nothing here holds a key.

  **The request string** (`request/5`): `qory-request-ed25519-v1`, the access key id and
  the instance id exactly as their headers carry them, an absent instance id as an empty
  line; the method in upper case; the request target exactly as sent, the path and the
  query when there is one, nothing decoded, reordered or normalised; and last, for a GET
  the timestamp as sent in `X-Qory-Timestamp`, for a POST the raw body.

  **The answer string** (`answer/5`): `qory-answer-ed25519-v1`; the status, three decimal
  digits; the request's `X-Qory-Signature-Ed25519` exactly as sent, or an enrolment's
  `proof`; the lower-case hex SHA-256 of the body as sent, before any content coding, the
  SHA-256 of the empty string for no body; the answer's `X-Qory-Configuration`, and its
  `X-Qory-Run-Configuration`, each empty when the answer has none.

  The contract's known answers for both are in `fixtures/known-answers/signatures.json`
  of the runner's contract directory, and `test/contract/ed25519_known_answers_test.exs`
  replays them.
  """

  @request_tag "qory-request-ed25519-v1"
  @answer_tag "qory-answer-ed25519-v1"

  @doc ~S"""
  request/5 is the request string of a request under `access_key_id` from `instance_id`
  (nil when the request carries none), with `method`, `target` (the path and query as
  sent) and `last`: the `X-Qory-Timestamp` value as sent for a GET, the raw body for a
  POST.

      iex> Apiary.Contract.SignedMessage.request("ak_0000000000000000", "i_a", "get", "/x?y=1", "1700000000")
      "qory-request-ed25519-v1\nak_0000000000000000\ni_a\nGET\n/x?y=1\n1700000000"
  """
  @spec request(String.t(), String.t() | nil, String.t(), String.t(), binary) :: binary
  def request(access_key_id, instance_id, method, target, last)
      when is_binary(access_key_id) and (is_binary(instance_id) or is_nil(instance_id)) and
             is_binary(method) and is_binary(target) and is_binary(last) do
    IO.iodata_to_binary([
      @request_tag,
      ?\n,
      access_key_id,
      ?\n,
      instance_id || "",
      ?\n,
      String.upcase(method),
      ?\n,
      target,
      ?\n,
      last
    ])
  end

  @doc ~S"""
  answer/5 is the answer string of an answer with `status` and `body` to the request
  whose signature, or enrolment proof, is `request_signature`, with the answer's
  `X-Qory-Configuration` and `X-Qory-Run-Configuration` values, nil for a header the
  answer does not carry.

      iex> Apiary.Contract.SignedMessage.answer(404, "c2ln", "", nil, nil)
      "qory-answer-ed25519-v1\n404\nc2ln\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\n"
  """
  @spec answer(100..599, String.t(), iodata, String.t() | nil, String.t() | nil) :: binary
  def answer(status, request_signature, body, configuration, run_configuration)
      when status in 100..599 and is_binary(request_signature) and
             (is_binary(configuration) or is_nil(configuration)) and
             (is_binary(run_configuration) or is_nil(run_configuration)) do
    IO.iodata_to_binary([
      @answer_tag,
      ?\n,
      Integer.to_string(status),
      ?\n,
      request_signature,
      ?\n,
      Base.encode16(:crypto.hash(:sha256, body), case: :lower),
      ?\n,
      configuration || "",
      ?\n,
      run_configuration || ""
    ])
  end
end
