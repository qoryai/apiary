defmodule Apiary.Secrets.Sealing do
  @moduledoc """
  The answer to the Forager contract's secrets request: the values of a run's credentials,
  sealed with HPKE base mode (RFC 9180) to the gateway's access key, and the envelope
  signed under the instance's signing key (`secrets-answer.schema.json`). Pure functions:
  nothing here touches the database or writes a log line.

  **The suite**, `x25519-sha256-aes256gcm`: DHKEM(X25519, HKDF-SHA256) 0x0020,
  HKDF-SHA256 0x0001 and AES-256-GCM 0x0002, with `:crypto` (`Apiary.Secrets.Hpke`). The
  recipient's X25519 key is the access key's Ed25519 public key converted to its
  Montgomery u-coordinate (`Apiary.Contract.Ed25519.x25519_public_key/1`), as Forager
  converts it.

  **What is bound.** `info/1` and `aad/4` are built from the values `seal/2` is given,
  never from an envelope:

    * `info`: `qory secrets v1`, a zero byte, the suite's three ids as u16 big-endian,
      and lp(access key id);
    * `aad`: lp(run id), lp(access key id), lp(run configuration digest) and lp(exp in
      decimal);
    * the signature: Ed25519 over lp32 of `qory envelope v1`, the suite, the access key
      id, the run id, the digest, exp in decimal, `enc` and `ct`, the last two raw.

  lp is a u16 big-endian length, then the bytes; lp32 a u32 big-endian length.

  **The plaintext** (`sealed-plaintext.schema.json`) is written as Forager writes it:
  compact JSON of `version`, `run_configuration`, the credentials sorted, and the values
  sorted by credential, quoted as Go's `jsontext` quotes. Each value is `credential`, then
  `value`, then `expires_at` and `apply` where it has them. `expires_at` is RFC 3339 with
  a zone, written as given. Each item of `apply` is `hosts`, `scheme`, `username`,
  `header` and `paths`, in that order, each where the item has it.

  **What it refuses**, each with an atom and nothing of the input: a recipient that is not
  a map (`:recipient`); identifiers outside their forms (`:identifiers`); an access key
  that fails a key check, or whose seal fails in `:crypto` (`:key`); a plaintext whose
  digest is not the given one (`:digest`); credentials that are not 1 to 8 names, each
  once (`:credentials`); values that are not one for each credential (`:values`); a value
  that is not 1 to 16,384 bytes of UTF-8 without a NUL, or whose `expires_at` or `apply`
  is outside the schema's form (`:value`); any other plaintext (`:plaintext`).

  **Keys.** `seal/2` seals with a fresh ephemeral key and signs under the instance's
  signing key (`Apiary.SigningKey.current/0`). It uses no other key: the tests of the
  contract's known answers seal through an entry point that only the test build compiles.
  Nothing of the ephemeral private key or of the shared secret leaves the seal: a seal
  that fails in `:crypto` returns `{:error, :key}`, and the exception is dropped.
  """

  import Bitwise, only: [bsr: 2, band: 2]

  alias Apiary.Contract.Ed25519
  alias Apiary.Secrets.Hpke
  alias Apiary.SigningKey

  @suite "x25519-sha256-aes256gcm"
  @kem_id 0x0020
  @kdf_id 0x0001
  @aead_id 0x0002
  @info_domain "qory secrets v1"
  @envelope_domain "qory envelope v1"

  # How far after the server's clock exp lies, in seconds.
  @lifetime 600
  @max_credentials 8
  @max_value_bytes 16_384
  @max_integer Integer.pow(2, 53) - 1

  @access_key_id ~r/\Aak_[0-9a-hjkmnp-tv-z]{16}\z/
  @run_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @digest ~r/\Asha256=[0-9a-f]{64}\z/
  @credential ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

  # The forms of `sealed-plaintext.schema.json`'s `expires_at` and of an `apply` item
  # (`run-configuration.schema.json`, `$defs.apply`).
  @expires_at ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/
  @apply_members ~w(hosts scheme username header paths)
  @max_apply 16
  @max_hosts 16
  @max_paths 32
  @host_patterns [
    ~r/\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/,
    ~r/\A(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}\z/,
    ~r/\A(((0|[1-9a-f][0-9a-f]{0,3}):){7}(0|[1-9a-f][0-9a-f]{0,3})|((0|[1-9a-f][0-9a-f]{0,3}):){1,7}:|((0|[1-9a-f][0-9a-f]{0,3}):){1,6}:(0|[1-9a-f][0-9a-f]{0,3})|((0|[1-9a-f][0-9a-f]{0,3}):){1,5}(:(0|[1-9a-f][0-9a-f]{0,3})){1,2}|((0|[1-9a-f][0-9a-f]{0,3}):){1,4}(:(0|[1-9a-f][0-9a-f]{0,3})){1,3}|((0|[1-9a-f][0-9a-f]{0,3}):){1,3}(:(0|[1-9a-f][0-9a-f]{0,3})){1,4}|((0|[1-9a-f][0-9a-f]{0,3}):){1,2}(:(0|[1-9a-f][0-9a-f]{0,3})){1,5}|(0|[1-9a-f][0-9a-f]{0,3}):(:(0|[1-9a-f][0-9a-f]{0,3})){1,6}|:((:(0|[1-9a-f][0-9a-f]{0,3})){1,7}|:))\z/
  ]
  @username ~r/\A[^:\s]+\z/
  @header ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}\z/
  @path ~r/\A\/[^*?#\s]*\*?\z/

  @typedoc """
  Whom and what the values are sealed for: the access key the request verified under, by
  its `access_key_id` and its Ed25519 `public_key` (32 raw bytes), the request's `run_id`,
  its `run_configuration` digest, and `exp` (`expiry/1`).
  """
  @type recipient :: %{
          required(:access_key_id) => String.t(),
          required(:public_key) => <<_::256>>,
          required(:run_id) => String.t(),
          required(:run_configuration) => String.t(),
          required(:exp) => non_neg_integer
        }

  @typedoc "The errors `seal/2` returns for its input."
  @type refusal ::
          :recipient
          | :identifiers
          | :key
          | :digest
          | :credentials
          | :values
          | :value
          | :plaintext

  # Whether the test build compiles `seal_with/3`, the entry point of the known answers'
  # tests (config/test.exs).
  @known_answers Application.compile_env(:apiary, [__MODULE__, :known_answers], false)

  @doc "suite/0 is the envelope's suite."
  @spec suite() :: String.t()
  def suite, do: @suite

  @doc "expiry/1 is exp for an envelope sealed at `now`, in Unix seconds: now plus 600."
  @spec expiry(DateTime.t()) :: non_neg_integer
  def expiry(%DateTime{} = now), do: DateTime.to_unix(now) + @lifetime

  @doc """
  seal/2 is the body of the secrets answer: `plaintext`, the decoded document of
  `sealed-plaintext.schema.json` with string keys, sealed to `recipient`'s access key with
  a fresh ephemeral key, and the envelope signed under the instance's signing key.
  `{:ok, bytes}`, compact JSON, or `{:error, refusal}` (see the module's documentation).
  """
  @spec seal(map, recipient) :: {:ok, binary} | {:error, refusal}
  def seal(plaintext, recipient),
    do:
      sealed(plaintext, recipient, fn -> :crypto.strong_rand_bytes(32) end, &SigningKey.current/0)

  if @known_answers do
    # seal_with/3 is seal/2 with the keys of the contract's known answers: `opts` has
    # `:signing_key`, an `Apiary.SigningKey`, and `:ephemeral_private_key`, 32 raw bytes,
    # each taken as seal/2 uses it when not given. Compiled in the test build alone.
    @doc false
    @spec seal_with(map, recipient, keyword) :: {:ok, binary} | {:error, refusal}
    def seal_with(plaintext, recipient, opts) when is_list(opts) do
      ephemeral =
        case Keyword.fetch(opts, :ephemeral_private_key) do
          {:ok, <<_::binary-size(32)>> = key} -> fn -> key end
          {:ok, _other} -> raise ArgumentError, "the ephemeral private key is not 32 bytes"
          :error -> fn -> :crypto.strong_rand_bytes(32) end
        end

      signing_key =
        case Keyword.fetch(opts, :signing_key) do
          {:ok, key} -> fn -> key end
          :error -> &SigningKey.current/0
        end

      sealed(plaintext, recipient, ephemeral, signing_key)
    end
  end

  defp sealed(%{} = plaintext, %{} = recipient, ephemeral, signing_key) do
    with {:ok, ids} <- identifiers(recipient),
         {:ok, pk_r} <- recipient_key(recipient),
         {:ok, pt} <- plaintext(plaintext, ids.run_configuration) do
      info = info(ids.access_key_id)
      aad = aad(ids.run_id, ids.access_key_id, ids.run_configuration, ids.exp)

      with {:ok, enc, ct} <- Hpke.seal(ephemeral, pk_r, info, aad, pt) do
        {:ok, envelope(ids, enc, ct, signing_key.())}
      end
    end
  end

  defp sealed(_plaintext, recipient, _ephemeral, _signing_key) when not is_map(recipient),
    do: {:error, :recipient}

  defp sealed(_plaintext, _recipient, _ephemeral, _signing_key), do: {:error, :plaintext}

  @doc """
  plaintext/2 is the bytes `seal/2` seals: `plaintext` as Forager writes it, its
  `run_configuration` checked against `digest`. `{:ok, bytes}`, or `{:error, refusal}`.
  """
  @spec plaintext(map, String.t()) :: {:ok, binary} | {:error, refusal}
  def plaintext(
        %{
          "version" => 1,
          "run_configuration" => digest,
          "credentials" => credentials,
          "values" => values
        } = plaintext,
        digest
      )
      when map_size(plaintext) == 4 and is_list(credentials) and is_list(values) do
    with {:ok, credentials} <- credentials(credentials),
         {:ok, values} <- values(values, credentials) do
      {:ok,
       IO.iodata_to_binary([
         ~s({"version":1,"run_configuration":),
         quote_json(digest),
         ~s(,"credentials":[),
         Enum.map_intersperse(credentials, ",", &quote_json/1),
         ~s(],"values":[),
         Enum.map_intersperse(values, ",", &value_json/1),
         "]}"
       ])}
    end
  end

  def plaintext(%{"run_configuration" => other}, digest)
      when is_binary(other) and is_binary(digest) and other != digest,
      do: {:error, :digest}

  def plaintext(_plaintext, _digest), do: {:error, :plaintext}

  @doc "info/1 is HPKE's info for the access key `access_key_id`."
  @spec info(String.t()) :: binary
  def info(access_key_id) when is_binary(access_key_id),
    do: @info_domain <> <<0, @kem_id::16, @kdf_id::16, @aead_id::16>> <> lp(access_key_id)

  @doc "aad/4 is the associated data of the seal, built from the four values given."
  @spec aad(String.t(), String.t(), String.t(), non_neg_integer) :: binary
  def aad(run_id, access_key_id, digest, exp)
      when is_binary(run_id) and is_binary(access_key_id) and is_binary(digest) and
             is_integer(exp) and exp >= 0,
      do: lp(run_id) <> lp(access_key_id) <> lp(digest) <> lp(Integer.to_string(exp))

  # The recipient's identifiers, each in its form, or `:identifiers`.
  defp identifiers(%{
         access_key_id: access_key_id,
         run_id: run_id,
         run_configuration: digest,
         exp: exp
       })
       when is_binary(access_key_id) and is_binary(run_id) and is_binary(digest) and
              is_integer(exp) and exp >= 0 and exp <= @max_integer do
    if Regex.match?(@access_key_id, access_key_id) and Regex.match?(@run_id, run_id) and
         Regex.match?(@digest, digest),
       do:
         {:ok,
          %{access_key_id: access_key_id, run_id: run_id, run_configuration: digest, exp: exp}},
       else: {:error, :identifiers}
  end

  defp identifiers(_recipient), do: {:error, :identifiers}

  defp recipient_key(%{public_key: public_key}) do
    case Ed25519.x25519_public_key(public_key) do
      {:ok, u} -> {:ok, u}
      {:error, _refusal} -> {:error, :key}
    end
  end

  defp recipient_key(_recipient), do: {:error, :key}

  # The credentials sorted: 1 to 8 names of the grammar, each once.
  defp credentials(credentials) do
    sorted = Enum.sort(credentials)

    if length(sorted) in 1..@max_credentials and
         Enum.all?(sorted, &(is_binary(&1) and Regex.match?(@credential, &1))) and
         Enum.dedup(sorted) == sorted,
       do: {:ok, sorted},
       else: {:error, :credentials}
  end

  # The values as `{credential, value, expires_at, apply}`, sorted by credential, nil for a
  # member the value does not have: exactly one for each of `credentials`, each in its
  # form.
  defp values(values, credentials) do
    entries =
      for %{"credential" => credential, "value" => value} = entry <- values,
          entry |> Map.keys() |> Enum.all?(&(&1 in ~w(credential value expires_at apply))),
          do: {credential, value, Map.get(entry, "expires_at"), Map.get(entry, "apply")}

    sorted = Enum.sort_by(entries, &elem(&1, 0))

    cond do
      length(entries) != length(values) -> {:error, :plaintext}
      Enum.map(sorted, &elem(&1, 0)) != credentials -> {:error, :values}
      Enum.all?(sorted, &entry?/1) -> {:ok, sorted}
      true -> {:error, :value}
    end
  end

  defp entry?({_credential, value, expires_at, apply}),
    do: value?(value) and expires_at?(expires_at) and apply?(apply)

  defp expires_at?(nil), do: true

  defp expires_at?(expires_at) when is_binary(expires_at),
    do:
      Regex.match?(@expires_at, expires_at) and
        match?({:ok, _, _}, DateTime.from_iso8601(expires_at))

  defp expires_at?(_expires_at), do: false

  defp apply?(nil), do: true

  defp apply?(items) when is_list(items),
    do: length(items) in 1..@max_apply and Enum.all?(items, &apply_item?/1)

  defp apply?(_items), do: false

  defp apply_item?(%{"hosts" => hosts, "scheme" => scheme} = item) do
    Enum.all?(Map.keys(item), &(&1 in @apply_members)) and
      list_of?(hosts, @max_hosts, &host?/1) and scheme_members?(scheme, item) and
      (not Map.has_key?(item, "paths") or list_of?(item["paths"], @max_paths, &path?/1))
  end

  defp apply_item?(_item), do: false

  defp scheme_members?("bearer", item),
    do: not Map.has_key?(item, "username") and not Map.has_key?(item, "header")

  defp scheme_members?("basic", %{"username" => username} = item),
    do:
      not Map.has_key?(item, "header") and is_binary(username) and String.valid?(username) and
        Regex.match?(@username, username)

  defp scheme_members?("header", %{"header" => header} = item),
    do: not Map.has_key?(item, "username") and is_binary(header) and Regex.match?(@header, header)

  defp scheme_members?(_scheme, _item), do: false

  # A list of 1 to `max` strings, none twice, each one `check` takes.
  defp list_of?(list, max, check) when is_list(list),
    do:
      length(list) in 1..max and Enum.uniq(list) == list and
        Enum.all?(list, &(is_binary(&1) and String.valid?(&1) and check.(&1)))

  defp list_of?(_list, _max, _check), do: false

  defp host?(host),
    do: byte_size(host) <= 253 and Enum.any?(@host_patterns, &Regex.match?(&1, host))

  defp path?(path), do: Regex.match?(@path, path)

  defp value_json({credential, value, expires_at, apply}) do
    [
      ~s({"credential":),
      quote_json(credential),
      ~s(,"value":),
      quote_json(value),
      if(expires_at, do: [~s(,"expires_at":), quote_json(expires_at)], else: []),
      if(apply,
        do: [~s(,"apply":[), Enum.map_intersperse(apply, ",", &item_json/1), "]"],
        else: []
      ),
      "}"
    ]
  end

  # An `apply` item, its members in the schema's order.
  defp item_json(item) do
    members =
      for name <- @apply_members, Map.has_key?(item, name) do
        [quote_json(name), ":", member_json(item[name])]
      end

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp member_json(list) when is_list(list),
    do: ["[", Enum.map_intersperse(list, ",", &quote_json/1), "]"]

  defp member_json(string), do: quote_json(string)

  defp value?(value) when is_binary(value),
    do:
      byte_size(value) in 1..@max_value_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp value?(_value), do: false

  # A JSON string as Go's jsontext.AppendQuote writes it: `"` and `\` escaped with a
  # backslash; backspace, form feed, line feed, carriage return and tab in their short
  # forms; every other byte below 0x20 as \u00 and two lower-case hex digits; the rest,
  # valid UTF-8 checked before, as it is.
  defp quote_json(string), do: [?", escape(string, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<byte, rest::binary>>, acc) when byte < 0x20,
    do: escape(rest, [["\\u00", hex(bsr(byte, 4)), hex(band(byte, 15))] | acc])

  defp escape(<<byte, rest::binary>>, acc), do: escape(rest, [byte | acc])

  defp hex(digit), do: Enum.at(~c"0123456789abcdef", digit)

  defp envelope(ids, enc, ct, signing_key) do
    exp = Integer.to_string(ids.exp)

    message =
      Enum.map_join(
        [
          @envelope_domain,
          @suite,
          ids.access_key_id,
          ids.run_id,
          ids.run_configuration,
          exp,
          enc,
          ct
        ],
        &lp32/1
      )

    sig = SigningKey.sign(signing_key, message)

    # Every identifier is in its form, which has no character JSON escapes.
    IO.iodata_to_binary([
      ~s({"version":1,"sealed":{"suite":"),
      @suite,
      ~s(","access_key_id":"),
      ids.access_key_id,
      ~s(","run_id":"),
      ids.run_id,
      ~s(","run_configuration":"),
      ids.run_configuration,
      ~s(","exp":),
      exp,
      ~s(,"enc":"),
      Ed25519.encode(enc),
      ~s(","ct":"),
      Ed25519.encode(ct),
      ~s(","sig":"),
      Ed25519.encode(sig),
      ~s("}})
    ])
  end

  defp lp(bytes), do: <<byte_size(bytes)::16>> <> bytes
  defp lp32(bytes), do: <<byte_size(bytes)::32>> <> bytes
end
