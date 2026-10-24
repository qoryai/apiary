defmodule Apiary.Secrets.AdapterSealing do
  @moduledoc """
  An adapter's secrets on the wire, in both directions, as the integration contract has
  them (qoryai/integrations, `contracts/integration/v1`, `adapter-secrets.schema.json`,
  `adapter-secrets-answer.schema.json` and `adapter-secrets-plaintext.schema.json`). Pure
  functions: nothing here touches the database or writes a log line.

  **The suite**, `x25519-sha256-aes256gcm`, HPKE base mode (`Apiary.Secrets.Hpke`), as the
  gateway's secrets answer has it (`Apiary.Secrets.Sealing`).

  **The upload**, `POST /v1/adapter/secrets`: the adapter seals its secrets to the
  instance's signing key, whose X25519 key is the Ed25519 key converted
  (`Apiary.SigningKey.x25519_private_key/1`). `open_upload/4` opens it.

  **The delivery**, the answer to `GET /v1/adapter/secrets`: the secrets sealed to the
  access key the request verified under, with a fresh ephemeral key for each answer.
  `delivery/3` seals it.

  **What is bound.** `info` and `aad` are built from what the instance enrolled and
  verified, never from a body:

    * the upload's `info`: `qory adapter secrets upload v1`, a zero byte, the suite's three
      ids as u16 big-endian, and lp(server key), the key as the body's `server_key` writes
      it, base64url;
    * the delivery's `info`: `qory adapter secrets v1`, a zero byte, the suite's three ids,
      and lp(access key id);
    * `aad`, both ways: lp(adapter id) and lp(access key id).

  lp is a u16 big-endian length, then the bytes. The two domains differ from each other and
  from the gateway's (`qory secrets v1`), so no envelope of one kind opens as another.

  **The plaintext**: compact JSON, `{"version":1,"secrets":[{"name":…,"value":…}]}`, at most
  16 secrets, each name once, of lower-case letters, digits, dots, underscores and hyphens,
  1 to 64 characters, starting with a letter or a digit, each value 1 to 16,384 bytes of
  UTF-8 without a NUL. A delivery writes them sorted by name.

  Nothing of a key, the shared secret or a value leaves this module in an error: each
  refusal is an atom.
  """

  alias Apiary.Adapters.Wire
  alias Apiary.Contract.Ed25519
  alias Apiary.Secrets.{Hpke, Instance, InstanceSecretValue}
  alias Apiary.SigningKey

  @suite "x25519-sha256-aes256gcm"
  @upload_domain "qory adapter secrets upload v1"
  @delivery_domain "qory adapter secrets v1"
  @plaintext_keys ~w(secrets version)
  @entry_keys ~w(name value)

  @typedoc "Whom a delivery is sealed for: the adapter's public id, and the access key the request verified under, its id and its Ed25519 public key."
  @type recipient :: %{
          required(:adapter_id) => String.t(),
          required(:access_key_id) => String.t(),
          required(:public_key) => <<_::256>>
        }

  @doc "suite/0 is the suite of every envelope."
  @spec suite() :: String.t()
  def suite, do: @suite

  @doc "upload_info/1 is HPKE's info of an upload sealed to `server_key`, as base64url."
  @spec upload_info(String.t()) :: binary
  def upload_info(server_key) when is_binary(server_key), do: info(@upload_domain, server_key)

  @doc "delivery_info/1 is HPKE's info of a delivery sealed to the access key `access_key_id`."
  @spec delivery_info(String.t()) :: binary
  def delivery_info(access_key_id) when is_binary(access_key_id),
    do: info(@delivery_domain, access_key_id)

  @doc "aad/2 is the associated data of both directions."
  @spec aad(String.t(), String.t()) :: binary
  def aad(adapter_id, access_key_id) when is_binary(adapter_id) and is_binary(access_key_id),
    do: lp(adapter_id) <> lp(access_key_id)

  defp info(domain, id), do: domain <> <<0>> <> Hpke.suite_ids() <> lp(id)

  @doc """
  open_upload/4 opens `sealed`, the decoded `sealed` member of an upload, sent by the
  adapter `adapter_id` under the access key `access_key_id`, with `signing_key`, the
  instance's (`Apiary.SigningKey.current/0`) unless given: `{:ok, values}`, the
  `Apiary.Secrets.InstanceSecretValue`s it holds, or `{:error, refusal}`:

    * `:sealed`: `sealed` is not exactly `suite`, `server_key`, `enc` and `ct`, with the
      suite above, a public key, `enc` 32 bytes and `ct` at least 16, each strict
      base64url;
    * `:server_key`: `server_key` is not the signing key's public key;
    * `:open`: the seal does not open;
    * `:plaintext`: what it holds is not a plaintext of the module's documentation.
  """
  @spec open_upload(term, String.t(), String.t(), SigningKey.t() | nil) ::
          {:ok, [InstanceSecretValue.t()]} | {:error, :sealed | :server_key | :open | :plaintext}
  def open_upload(sealed, adapter_id, access_key_id, signing_key \\ nil)
      when is_binary(adapter_id) and is_binary(access_key_id) do
    signing_key = signing_key || SigningKey.current()

    with {:ok, server_key, enc, ct} <- sealed(sealed),
         :ok <- held(server_key, signing_key),
         {:ok, pt} <- open(signing_key, enc, ct, server_key, adapter_id, access_key_id) do
      plaintext(pt)
    end
  end

  defp sealed(%{"suite" => @suite, "server_key" => server_key, "enc" => enc, "ct" => ct} = sealed)
       when map_size(sealed) == 4 do
    with {:ok, _key} <- Ed25519.decode(server_key, 32),
         {:ok, enc} <- Ed25519.decode(enc, 32),
         {:ok, ct} <- strict(ct),
         true <- byte_size(ct) >= 16 do
      {:ok, server_key, enc, ct}
    else
      _ -> {:error, :sealed}
    end
  end

  defp sealed(_sealed), do: {:error, :sealed}

  defp held(server_key, signing_key) do
    if Ed25519.encode(SigningKey.public_key(signing_key)) == server_key,
      do: :ok,
      else: {:error, :server_key}
  end

  defp open(signing_key, enc, ct, server_key, adapter_id, access_key_id) do
    case Hpke.open(
           SigningKey.x25519_private_key(signing_key),
           enc,
           upload_info(server_key),
           aad(adapter_id, access_key_id),
           ct
         ) do
      {:ok, pt} -> {:ok, pt}
      :error -> {:error, :open}
    end
  end

  # Base64url without padding, read strictly: the bytes write back as the value.
  defp strict(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} ->
        if Base.url_encode64(bytes, padding: false) == value, do: {:ok, bytes}, else: :error

      :error ->
        :error
    end
  end

  defp strict(_value), do: :error

  @doc """
  plaintext/1 reads the bytes of a plaintext: `{:ok, values}`, sorted by name, or
  `{:error, :plaintext}`. An object that repeats a member, at any depth, is refused.
  """
  @spec plaintext(binary) :: {:ok, [InstanceSecretValue.t()]} | {:error, :plaintext}
  def plaintext(pt) when is_binary(pt) do
    with true <- String.valid?(pt),
         {:ok, %{"version" => 1, "secrets" => secrets} = doc} <- Wire.decode(pt),
         true <- Enum.sort(Map.keys(doc)) == @plaintext_keys,
         true <- is_list(secrets),
         {:ok, values} <- entries(secrets),
         true <- Instance.valid_values?(values) do
      {:ok, Enum.sort_by(values, & &1.value_id)}
    else
      _ -> {:error, :plaintext}
    end
  end

  def plaintext(_pt), do: {:error, :plaintext}

  defp entries(secrets) do
    Enum.reduce_while(secrets, {:ok, []}, fn
      %{"name" => name, "value" => value} = entry, {:ok, acc}
      when is_binary(name) and is_binary(value) ->
        if Enum.sort(Map.keys(entry)) == @entry_keys,
          do: {:cont, {:ok, [%InstanceSecretValue{value_id: name, value: value} | acc]}},
          else: {:halt, :error}

      _entry, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  @doc """
  delivery/3 is the body of the answer to `GET /v1/adapter/secrets`: `values`, sorted by
  name, sealed to `recipient`'s access key with a fresh ephemeral key, for the contract
  revision `revision`, as compact JSON: `{"version":1,"revision":…,"sealed":{"suite":…,
  "access_key_id":…,"enc":…,"ct":…}}`. `{:ok, bytes}`, or `{:error, :key}` for an access key
  that is not a point of the curve or a seal that fails in `:crypto`, or
  `{:error, :plaintext}` for values `Apiary.Secrets.Instance.valid_values?/1` refuses. The
  caller checks the access key (`Apiary.Contract.Ed25519.check_public_key/1`) first.
  """
  @spec delivery([InstanceSecretValue.t()], recipient, pos_integer) ::
          {:ok, binary} | {:error, :key | :plaintext}
  def delivery(values, recipient, revision),
    do: delivery(values, recipient, revision, fn -> :crypto.strong_rand_bytes(32) end)

  @doc false
  # delivery/4 is delivery/3 with the ephemeral private key that `ephemeral`, a function of
  # no arguments, gives: for the tests.
  @spec delivery([InstanceSecretValue.t()], recipient, pos_integer, (-> <<_::256>>)) ::
          {:ok, binary} | {:error, :key | :plaintext}
  def delivery(
        values,
        %{adapter_id: adapter_id, access_key_id: access_key_id, public_key: public_key},
        revision,
        ephemeral
      )
      when is_binary(adapter_id) and is_binary(access_key_id) and is_integer(revision) and
             revision > 0 do
    with true <- Instance.valid_values?(values) || {:error, :plaintext},
         {:ok, pk_r} <- recipient_key(public_key),
         pt = encode_plaintext(values),
         {:ok, enc, ct} <-
           Hpke.seal(
             ephemeral,
             pk_r,
             delivery_info(access_key_id),
             aad(adapter_id, access_key_id),
             pt
           ) do
      {:ok,
       Jason.encode!(
         Jason.OrderedObject.new([
           {"version", 1},
           {"revision", revision},
           {"sealed",
            Jason.OrderedObject.new([
              {"suite", @suite},
              {"access_key_id", access_key_id},
              {"enc", Ed25519.encode(enc)},
              {"ct", Ed25519.encode(ct)}
            ])}
         ])
       )}
    end
  end

  # The access key's X25519 key. The key checks are the caller's
  # (`Apiary.Contract.Ed25519.check_public_key/1`), but the curve's, which the conversion
  # makes: a fixture key converts, so a test can seal to one.
  defp recipient_key(public_key) do
    case Ed25519.x25519_public_key(public_key) do
      {:ok, u} -> {:ok, u}
      {:error, _refusal} -> {:error, :key}
    end
  end

  @doc false
  # The bytes a delivery seals: the plaintext of the module's documentation, compact, the
  # secrets sorted by name.
  @spec encode_plaintext([InstanceSecretValue.t()]) :: binary
  def encode_plaintext(values) do
    secrets =
      values
      |> Enum.sort_by(& &1.value_id)
      |> Enum.map(fn %InstanceSecretValue{value_id: name, value: value} ->
        Jason.OrderedObject.new([{"name", name}, {"value", value}])
      end)

    Jason.encode!(Jason.OrderedObject.new([{"version", 1}, {"secrets", secrets}]))
  end

  defp lp(bytes), do: <<byte_size(bytes)::16>> <> bytes
end
