defmodule Apiary.Contract.Enrolment do
  @moduledoc """
  Enrolment's wire, the Forager contract's `enrolment.schema.json`: the request a machine
  posts to `/.well-known/qory-enrolment`, read strictly (`decode/1`), the checks of its
  code's fingerprints and of its proof, and the bodies of the `201` answer and the signed
  `409` refusals, byte for byte as the contract's fixtures (`fixtures/enrolment/`) have
  them. Pure functions; nothing here touches the database, a connection or a log, and
  nothing here holds a key. Redeeming the code is `Apiary.AccessKeys.enrol/2`'s; the
  endpoint is `ApiaryWeb.Contract.EnrolmentController`.

  **The request** is a JSON object with exactly the members `version`, `code`, `name`,
  `public_key`, `timestamp` and `proof`, each once:

    * `version` is `1`;
    * `code` is `qec_`, 26 upper-case Crockford base32 characters, then `.` and the
      fingerprint of the server's key, and during a rotation of that key a second `.` and
      the next key's fingerprint; it is what the proof signs, so it is read as sent and
      never normalised;
    * `name` is the access key's name for people, `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`;
    * `public_key` is the new key's raw 32 bytes in base64url without padding, decoded
      strictly (`Apiary.Contract.Ed25519.decode/2`);
    * `timestamp` is a JSON integer from 0 to 2^53 − 1, the machine's clock in Unix
      seconds; a number with a fraction or an exponent is refused;
    * `proof` is the Ed25519 signature, 64 bytes in base64url, under the new key, of
      the five lines `Apiary.Contract.SignedMessage.enrolment/4` builds.

  A member the schema does not define, a member twice, or anything else is refused,
  naming the members at fault where it can.

  **The proof** (`proof_verifies?/2`) is verified cofactorless under the new key, once
  the key has passed the key checks; **its timestamp** (`fresh?/2`) is accepted within 300
  seconds of the server's clock, in either direction.

  **The answers** (`answer_body/1`, `refusal_body/2`) are signed under the enrolment
  answers' own domain line (`Apiary.Contract.SignedMessage.enrolment_answer/3`), and only
  once the key has passed the checks and the proof verified under it.

  A request holds the code and the proof, so its `inspect` shows neither.
  """

  alias Apiary.Contract.{Ed25519, SignedMessage}

  @derive {Inspect, only: [:name, :fingerprints, :timestamp]}
  @enforce_keys [:code, :code_head, :fingerprints, :name, :public_key, :timestamp, :proof]
  defstruct @enforce_keys

  @typedoc """
  An enrolment request, read: `code` as sent, `code_head` the `qec_` and 26 characters
  before the first `.`, `fingerprints` the one or two after it, `name`, `public_key` as
  sent (base64url), `timestamp`, and `proof` as sent (base64url), which an answer's line 3
  carries.
  """
  @type t :: %__MODULE__{
          code: String.t(),
          code_head: String.t(),
          fingerprints: [String.t(), ...],
          name: String.t(),
          public_key: String.t(),
          timestamp: non_neg_integer,
          proof: String.t()
        }

  @members ~w(version code name public_key timestamp proof)
  @code ~r/\Aqec_[0-9A-HJKMNP-TV-Z]{26}(\.[A-Za-z0-9_-]{22}){1,2}\z/
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @public_key ~r/\A[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\z/
  @proof ~r/\A[A-Za-z0-9_-]{85}[AQgw]\z/
  @max_timestamp Integer.pow(2, 53) - 1
  @window_seconds 300

  @doc "window_seconds/0 is how far a proof's timestamp may be from the server's clock."
  @spec window_seconds() :: pos_integer
  def window_seconds, do: @window_seconds

  @doc """
  decode/1 reads the raw body of an enrolment request: `{:ok, request}`, or
  `{:error, names}`, the members at fault in the schema's order, empty for a body that is
  not a JSON object or carries a member the schema does not define.
  """
  @spec decode(term) :: {:ok, t} | {:error, [String.t()]}
  def decode(body) when is_binary(body) do
    case Jason.decode(body, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{values: values}} -> members(values)
      _other -> {:error, []}
    end
  end

  def decode(_body), do: {:error, []}

  defp members(values) do
    keys = Enum.map(values, &elem(&1, 0))
    twice = Enum.uniq(keys -- Enum.uniq(keys))

    cond do
      Enum.any?(keys, &(&1 not in @members)) ->
        {:error, []}

      twice != [] ->
        {:error, Enum.filter(@members, &(&1 in twice))}

      true ->
        fields = Map.new(values)
        wrong = Enum.reject(@members, &valid?(&1, Map.get(fields, &1)))

        if wrong == [], do: {:ok, request(fields)}, else: {:error, wrong}
    end
  end

  defp valid?("version", value), do: value === 1
  defp valid?("code", value), do: is_binary(value) and value =~ @code
  defp valid?("name", value), do: is_binary(value) and value =~ @name

  defp valid?("public_key", value),
    do: is_binary(value) and value =~ @public_key and Ed25519.decode(value, 32) != :error

  defp valid?("timestamp", value),
    do: is_integer(value) and value >= 0 and value <= @max_timestamp

  defp valid?("proof", value),
    do: is_binary(value) and value =~ @proof and Ed25519.decode(value, 64) != :error

  defp request(fields) do
    [head | fingerprints] = String.split(fields["code"], ".")

    %__MODULE__{
      code: fields["code"],
      code_head: head,
      fingerprints: fingerprints,
      name: fields["name"],
      public_key: fields["public_key"],
      timestamp: fields["timestamp"],
      proof: fields["proof"]
    }
  end

  @doc """
  issued_under?/2 says whether the request's code carries exactly `fingerprint`, the
  fingerprint of the server's key, and no other: the code as this server issues it while
  its key does not rotate. The comparison is in constant time.
  """
  @spec issued_under?(t, String.t()) :: boolean
  def issued_under?(%__MODULE__{fingerprints: [carried]}, fingerprint)
      when is_binary(fingerprint),
      do: Plug.Crypto.secure_compare(carried, fingerprint)

  def issued_under?(%__MODULE__{}, _fingerprint), do: false

  @doc """
  issued_code/2 is the code a machine is given, the one `issued_under?/2` accepts: `code`,
  the `qec_` and 26 characters `Apiary.AccessKeys.create_enrolment_code/3` returns, then
  `.` and `fingerprint`, the fingerprint of the server's key.
  """
  @spec issued_code(String.t(), String.t()) :: String.t()
  def issued_code("qec_" <> _ = code, fingerprint) when is_binary(fingerprint),
    do: code <> "." <> fingerprint

  @doc """
  proof_verifies?/2 says whether the request's proof is a signature of its five lines
  (`Apiary.Contract.SignedMessage.enrolment/4`) under `public_key`, the raw 32 bytes of its
  `public_key`, verified cofactorless (`Apiary.Contract.Ed25519.verify/3`). The key is not
  checked here: the caller has run the key checks on it first.
  """
  @spec proof_verifies?(t, Ed25519.public_key()) :: boolean
  def proof_verifies?(%__MODULE__{} = request, <<_::binary-size(32)>> = public_key) do
    message =
      SignedMessage.enrolment(request.code, request.public_key, request.name, request.timestamp)

    case Ed25519.decode(request.proof, 64) do
      {:ok, signature} -> Ed25519.verify(message, signature, public_key)
      :error -> false
    end
  end

  @doc """
  fresh?/2 says whether the request's timestamp is within `window_seconds/0` of `now`, in
  either direction.
  """
  @spec fresh?(t, DateTime.t()) :: boolean
  def fresh?(%__MODULE__{timestamp: timestamp}, %DateTime{} = now),
    do: abs(DateTime.to_unix(now) - timestamp) <= @window_seconds

  @doc """
  answer_body/1 is the body of the `201` answer, its members in the contract's order:
  `version`, `access_key_id`, `node_id`, `node_kind` (`node` for an `nd_` id, `pool` for
  an `np_` one), `stored_secrets` and `apiary_public_key`, the server's keys as
  `Apiary.SigningKey.apiary_public_key/1` lists them. A `201` means the key is active.
  """
  @spec answer_body(%{
          access_key_id: String.t(),
          node_id: String.t(),
          node_kind: :node | :pool,
          stored_secrets: boolean,
          apiary_public_key: [map, ...]
        }) :: binary
  def answer_body(%{node_kind: kind} = answer) when kind in [:node, :pool] do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"version", 1},
        {"access_key_id", answer.access_key_id},
        {"node_id", answer.node_id},
        {"node_kind", Atom.to_string(kind)},
        {"stored_secrets", answer.stored_secrets},
        {"apiary_public_key", keys(answer.apiary_public_key)}
      ])
    )
  end

  @doc """
  refusal_body/2 is the body of a signed refusal at enrolment, listing the server's keys
  as the `201` does: a `409`, `key_invalid` or `key_limit`, or a `429`, `rate_limited`,
  for a code past its limit.
  """
  @spec refusal_body(:key_invalid | :key_limit | :rate_limited, [map, ...]) :: binary
  def refusal_body(error, [_ | _] = apiary_public_key)
      when error in [:key_invalid, :key_limit, :rate_limited] do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"error", Atom.to_string(error)},
        {"apiary_public_key", keys(apiary_public_key)}
      ])
    )
  end

  defp keys(list) do
    for %{"alg" => alg, "public_key" => public_key} <- list,
        do: Jason.OrderedObject.new([{"alg", alg}, {"public_key", public_key}])
  end
end
