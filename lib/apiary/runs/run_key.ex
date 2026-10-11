defmodule Apiary.Runs.RunKey do
  @moduledoc ~S"""
  A run key: the grant this server makes for one run that goes through a gateway, in its
  registration's answer (`Apiary.Runs.Registration`), and checks when the gateway attaches
  the run (`Apiary.Runs.Attach`).

  **Its form.** One string, `qrk_`, the payload in base64url without padding, `.`, and the
  signature in base64url without padding, at most `max_length/0` characters. The payload
  is the JSON bytes the server signed, never serialised again; the signature is 64 bytes
  of Ed25519 under the instance's signing key (`Apiary.SigningKey`) over the run key's
  message (`Apiary.Contract.SignedMessage.run_key/1`): `qory-run-key-ed25519-v1`, a line
  feed, then the payload's bytes.

  **The payload**, its members in this order, each required and no other:

    * `version`, 1;
    * `signer`, the fingerprint of the key that signed it, as an enrolment code names keys;
    * `run_id`, the run's id, a UUID in lower case;
    * `workspace`, the run's workspace, by its public id (`ws_`);
    * `node_id`, the node or node pool that registered the run, by its public id;
    * `gateway`, the gateway its choice resolved to, by its public id (`ng_`);
    * `gateway_url`, the gateway's address: `https://`, a host and an optional port;
    * `gateway_public_key`, the gateway's active keys, one or two, oldest first, each
      `{"alg": "ed25519", "public_key": <base64url>}`;
    * `instance_id`, the instance id the registration was signed from;
    * `issued` and `attach_by`, when it was made and the end of its attach window, in UTC
      to the second.

  `issue/2` makes one; `verify/2` reads one back, in the order the contract gives: the
  prefix and the length, both parts decoded strictly, the signing key whose fingerprint
  `signer` names among the keys given (the instance's own unless told), the signature
  over the message, and last the payload against the rules above. Any failure is
  `:error`, whatever the cause. Nothing here touches the database, logs, or puts a run key
  in an error.
  """

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.SigningKey

  @prefix "qrk_"
  @max_length 2048
  @version 1
  @members ~w(version signer run_id workspace node_id gateway gateway_url gateway_public_key
              instance_id issued attach_by)

  @fingerprint ~r/\A[A-Za-z0-9_-]{21}[AQgw]\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @workspace ~r/\Aws_[0-9a-hjkmnp-tv-z]{16}\z/
  @node ~r/\An[dp]_[0-9a-hjkmnp-tv-z]{16}\z/
  @gateway ~r/\Ang_[0-9a-hjkmnp-tv-z]{16}\z/
  @gateway_url ~r/\Ahttps:\/\/[^\/?#@\s]+\z/
  @public_key ~r/\A[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\z/
  @instance_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc """
  What a run key grants, as `issue/2` takes it and `verify/2` gives it back: the public ids
  of the run's workspace, node and gateway, the gateway's address and its public keys (raw,
  32 bytes each), the registration's instance id, and the two times, to the second.
  """
  @type grant :: %{
          run_id: Ecto.UUID.t(),
          workspace: String.t(),
          node_id: String.t(),
          gateway: String.t(),
          gateway_url: String.t(),
          gateway_public_keys: [<<_::256>>, ...],
          instance_id: String.t(),
          issued: DateTime.t(),
          attach_by: DateTime.t()
        }

  @doc "The longest a run key may be, in characters."
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  @doc """
  issue/2 makes the run key of `grant`, signed under `key`, the instance's own unless
  given: `{:ok, run_key, payload}`, with the payload's exact bytes, which the run keeps.
  `{:error, :invalid}` when the grant breaks a rule of the payload, an address that is not
  `https`, say, and `{:error, :too_long}` when the run key would be longer than
  `max_length/0`: no run key is made then.
  """
  @spec issue(grant, SigningKey.t() | nil) ::
          {:ok, String.t(), binary} | {:error, :invalid | :too_long}
  def issue(%{} = grant, key \\ nil) do
    key = key || SigningKey.current()

    payload =
      Jason.encode!(
        Jason.OrderedObject.new(
          version: @version,
          signer: SigningKey.fingerprint(key),
          run_id: grant.run_id,
          workspace: grant.workspace,
          node_id: grant.node_id,
          gateway: grant.gateway,
          gateway_url: grant.gateway_url,
          gateway_public_key:
            Enum.map(
              grant.gateway_public_keys,
              &Jason.OrderedObject.new(alg: "ed25519", public_key: Ed25519.encode(&1))
            ),
          instance_id: grant.instance_id,
          issued: time(grant.issued),
          attach_by: time(grant.attach_by)
        )
      )

    run_key = encode(payload, key)

    cond do
      not match?({:ok, _grant}, read(payload)) -> {:error, :invalid}
      String.length(run_key) > @max_length -> {:error, :too_long}
      true -> {:ok, run_key, payload}
    end
  end

  @doc """
  encode/2 is the run key of `payload`, bytes a run key was made of before, signed under
  `key`, the instance's own unless given: the same run key again, since Ed25519 signs a
  message the same way every time.
  """
  @spec encode(binary, SigningKey.t() | nil) :: String.t()
  def encode(payload, key \\ nil) when is_binary(payload) do
    key = key || SigningKey.current()

    @prefix <>
      Ed25519.encode(payload) <>
      "." <> Ed25519.encode(SigningKey.sign(key, SignedMessage.run_key(payload)))
  end

  @doc """
  verify/2 reads `run_key` under `keys`, the signing keys a run key may be signed under,
  the instance's own unless given: `{:ok, grant, payload}` (`t:grant/0`, and the payload's
  exact bytes), or `:error` for anything that is not a run key those keys signed.
  """
  @spec verify(term, [SigningKey.t()] | nil) :: {:ok, grant, binary} | :error
  def verify(run_key, keys \\ nil)

  def verify(@prefix <> rest = run_key, keys) when byte_size(run_key) <= @max_length do
    keys = keys || [SigningKey.current()]

    with [encoded_payload, encoded_signature] <- String.split(rest, "."),
         {:ok, payload} <- decode(encoded_payload),
         {:ok, signature} <- Ed25519.decode(encoded_signature, 64),
         {:ok, %{"signer" => signer}} when is_binary(signer) <- Jason.decode(payload),
         %SigningKey{} = key <- Enum.find(keys, &(SigningKey.fingerprint(&1) == signer)),
         true <-
           Ed25519.verify(
             SignedMessage.run_key(payload),
             signature,
             SigningKey.public_key(key)
           ),
         {:ok, grant} <- read(payload) do
      {:ok, grant, payload}
    else
      _ -> :error
    end
  end

  def verify(_run_key, _keys), do: :error

  # Strict base64url without padding: the bytes, encoded again, are the text as given.
  defp decode(text) do
    with {:ok, bytes} when bytes != "" <- Base.url_decode64(text, padding: false),
         true <- Ed25519.encode(bytes) == text do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  # The payload against its rules, every member required and no other.
  defp read(payload) do
    with {:ok, %{} = map} <- Jason.decode(payload),
         true <- Enum.sort(Map.keys(map)) == Enum.sort(@members),
         true <- map["version"] === @version,
         true <- like?(map["signer"], @fingerprint),
         true <- like?(map["run_id"], @uuid),
         true <- like?(map["workspace"], @workspace),
         true <- like?(map["node_id"], @node),
         true <- like?(map["gateway"], @gateway),
         true <- gateway_url?(map["gateway_url"]),
         {:ok, keys} <- public_keys(map["gateway_public_key"]),
         true <- like?(map["instance_id"], @instance_id),
         {:ok, issued} <- read_time(map["issued"]),
         {:ok, attach_by} <- read_time(map["attach_by"]) do
      {:ok,
       %{
         run_id: map["run_id"],
         workspace: map["workspace"],
         node_id: map["node_id"],
         gateway: map["gateway"],
         gateway_url: map["gateway_url"],
         gateway_public_keys: keys,
         instance_id: map["instance_id"],
         issued: issued,
         attach_by: attach_by
       }}
    else
      _ -> :error
    end
  end

  defp like?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp gateway_url?(url) do
    like?(url, @gateway_url) and
      match?({:ok, %URI{host: host}} when is_binary(host) and host != "", URI.new(url))
  end

  defp public_keys(entries) when is_list(entries) and length(entries) in 1..2 do
    keys =
      Enum.map(entries, fn
        %{"alg" => "ed25519", "public_key" => key} = entry when map_size(entry) == 2 ->
          with true <- like?(key, @public_key), {:ok, raw} <- Ed25519.decode(key, 32), do: raw

        _ ->
          nil
      end)

    if Enum.all?(keys, &is_binary/1) and Enum.uniq(keys) == keys, do: {:ok, keys}, else: :error
  end

  defp public_keys(_entries), do: :error

  defp read_time(value) do
    with true <- like?(value, @whole_seconds),
         {:ok, time, 0} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _ -> :error
    end
  end

  defp time(%DateTime{} = time),
    do:
      time
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
end
