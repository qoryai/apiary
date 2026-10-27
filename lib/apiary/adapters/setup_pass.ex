defmodule Apiary.Adapters.SetupPass do
  @moduledoc false

  # A setup pass: the grant this server makes when an instance admin asks to set an
  # adapter (a node of kind `adapter`, `na_`) up at the system it reads from, carried to
  # the adapter as the `state` of its `setup_url` (`Apiary.Adapters.setup/2`), which the
  # adapter checks under the instance's public key before it acts on it. The module is
  # hidden from the generated documentation, which every instance serves.
  #
  # Its form, as a connect pass's (`Apiary.Adapters.ConnectPass`). One string, the
  # payload in base64url without padding, `.`, and the signature in base64url without
  # padding, at most `max_length/0` characters. The payload is the JSON bytes the server
  # signed, never serialised again; the signature is 64 bytes of Ed25519 under the
  # instance's signing key (`Apiary.SigningKey`), the key a connect pass is signed under,
  # over the setup pass's message (`Apiary.Contract.SignedMessage.setup_pass/1`):
  # `qory-setup-ed25519-v1`, a line feed, then the payload's bytes. That first line is
  # not a connect pass's, so neither pass ever verifies as the other.
  #
  # The payload, its members in this order and no other, with no whitespace, each
  # required but the last:
  #
  #   * `version`, 1;
  #   * `adapter_id`, the adapter, by its public id (`na_`);
  #   * `nonce`, 16 random bytes in base64url without padding, 22 characters, new for
  #     each pass;
  #   * `expires_at`, when the pass stops being good, in UTC to the second, as
  #     `2026-10-15T12:15:00Z`: `validity/0` seconds after it was made;
  #   * `organisation_slug`, optional, the slug of the instance's organisation
  #     (`Apiary.Organisations.Slug`): 1 to 40 lower-case letters, digits and hyphens,
  #     with no hyphen at either end. An adapter may suggest a name from it at the
  #     system it reads from. Qory Apiary writes it in every pass
  #     (`Apiary.Adapters.setup/2`); an adapter also reads a pass without it.
  #
  # The adapter keeps the nonce, to take each pass once; this server keeps neither the
  # pass nor its nonce, and compares no setup pass with another.
  #
  # `issue/3` makes one; `verify/3` reads one back: the length, both parts decoded
  # strictly, the signature over the message under the public key given, the payload
  # against the rules above and byte for byte as `issue/3` writes it, and last its time.
  # Any failure is `:error`, whatever the cause. Nothing here touches the database, logs,
  # or puts a pass in an error.

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.{PublicId, SigningKey}

  @max_length 1024
  @version 1
  @validity 900
  @nonce_size 16
  @members ~w(version adapter_id nonce expires_at)
  @optional_members ~w(organisation_slug)
  @slug_max_length 40
  @slug_format ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  # What a setup pass grants, as `verify/3` gives it back: the adapter's public id, the
  # nonce's 16 raw bytes, when it stops being good, to the second, and the slug of the
  # instance's organisation when the pass has one.
  @type pass :: %{
          required(:adapter_id) => String.t(),
          required(:nonce) => <<_::128>>,
          required(:expires_at) => DateTime.t(),
          optional(:organisation_slug) => String.t()
        }

  # The longest a setup pass may be, in characters.
  @doc false
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  # How long a setup pass is good for after it is made, in seconds.
  @doc false
  @spec validity() :: pos_integer
  def validity, do: @validity

  # issue/3 makes the setup pass of the adapter `adapter_id` (`na_`), with
  # `organisation_slug` as its last member: `{:ok, pass}`, the string, or
  # `{:error, :invalid}` when `adapter_id` is not an adapter's public id, when
  # `organisation_slug` is neither a slug of 1 to 40 characters (see the payload) nor
  # nil, when `opts[:nonce]` is not 16 bytes, or when `opts[:now]` is not a `DateTime`.
  # No pass is made on an error. A nil `organisation_slug` leaves the member out, as the
  # contract's fixture without it does. Its payload is at most 180 bytes, well under
  # `max_length/0`.
  #
  # It expires `validity/0` seconds after now, to the second. It is signed under the
  # instance's signing key, with 16 fresh random bytes as its nonce. `:now`, a
  # `DateTime`, is the time the pass is made, the current time unless given; `:nonce` and
  # `:key`, a `t:Apiary.SigningKey.t/0`, are for a known answer in tests and the shared
  # fixture only: a production caller passes neither.
  @doc false
  @spec issue(String.t(), String.t() | nil, keyword) :: {:ok, String.t()} | {:error, :invalid}
  def issue(adapter_id, organisation_slug, opts \\ []) do
    key = Keyword.get_lazy(opts, :key, &SigningKey.current/0)
    nonce = Keyword.get_lazy(opts, :nonce, fn -> :crypto.strong_rand_bytes(@nonce_size) end)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with true <- PublicId.valid?("na", adapter_id),
         true <- is_nil(organisation_slug) or slug?(organisation_slug),
         true <- is_binary(nonce) and byte_size(nonce) == @nonce_size,
         %DateTime{} <- now do
      payload = payload(adapter_id, nonce, expires_at(now), organisation_slug)

      {:ok,
       Ed25519.encode(payload) <>
         "." <> Ed25519.encode(SigningKey.sign(key, SignedMessage.setup_pass(payload)))}
    else
      _ -> {:error, :invalid}
    end
  end

  # When a pass made at `now` expires: `validity/0` seconds after `now`, in UTC, truncated
  # to the second.
  defp expires_at(now) do
    now
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.add(@validity, :second)
  end

  # verify/3 reads `pass` under `public_key`, the 32 raw bytes of the key that signed it:
  # `{:ok, pass}` (`t:pass/0`), or `:error` for anything that is not a setup pass that key
  # signed, or one that is not good at `now` (`opts[:now]`, the current time unless
  # given): at or after its `expires_at`, or expiring more than `validity/0` seconds after
  # `now`. The adapter reads a pass so; this server makes passes and reads none, and its
  # tests read them back with it.
  @doc false
  @spec verify(term, term, keyword) :: {:ok, pass} | :error
  def verify(pass, public_key, opts \\ [])

  def verify(pass, <<_::binary-size(32)>> = public_key, opts)
      when is_binary(pass) and byte_size(pass) <= @max_length do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with [encoded_payload, encoded_signature] <- String.split(pass, "."),
         {:ok, payload} <- decode(encoded_payload),
         {:ok, signature} <- Ed25519.decode(encoded_signature, 64),
         true <- Ed25519.verify(SignedMessage.setup_pass(payload), signature, public_key),
         {:ok, read} <- read(payload),
         true <- good_at?(read.expires_at, now) do
      {:ok, read}
    else
      _ -> :error
    end
  end

  def verify(_pass, _public_key, _opts), do: :error

  defp payload(adapter_id, nonce, expires_at, organisation_slug) do
    members = [
      version: @version,
      adapter_id: adapter_id,
      nonce: Ed25519.encode(nonce),
      expires_at: DateTime.to_iso8601(expires_at)
    ]

    members =
      if is_nil(organisation_slug),
        do: members,
        else: members ++ [organisation_slug: organisation_slug]

    Jason.encode!(Jason.OrderedObject.new(members))
  end

  # A slug as the contract has it: 1 to 40 lower-case letters, digits and hyphens, with
  # no hyphen at either end. Every character it allows is one byte.
  defp slug?(value),
    do:
      is_binary(value) and byte_size(value) <= @slug_max_length and
        Regex.match?(@slug_format, value)

  # Strict base64url without padding: the bytes, encoded again, are the text as given.
  defp decode(text) do
    with {:ok, bytes} when bytes != "" <- Base.url_decode64(text, padding: false),
         true <- Ed25519.encode(bytes) == text do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  # The payload against its rules, every required member, with or without the optional
  # one, and no other, and its bytes exactly those `issue/3` writes: the members in their
  # order, no whitespace.
  defp read(payload) do
    with {:ok, %{} = map} <- Jason.decode(payload),
         {required, optional} = Map.split(map, @members),
         true <- map_size(required) == length(@members),
         true <- Enum.all?(Map.keys(optional), &(&1 in @optional_members)),
         true <- map["version"] === @version,
         true <- PublicId.valid?("na", map["adapter_id"]),
         {:ok, nonce} <- Ed25519.decode(map["nonce"], @nonce_size),
         {:ok, expires_at} <- read_time(map["expires_at"]),
         slug = map["organisation_slug"],
         true <- not Map.has_key?(map, "organisation_slug") or slug?(slug),
         true <- payload(map["adapter_id"], nonce, expires_at, slug) == payload do
      read = %{adapter_id: map["adapter_id"], nonce: nonce, expires_at: expires_at}
      {:ok, if(is_nil(slug), do: read, else: Map.put(read, :organisation_slug, slug))}
    else
      _ -> :error
    end
  end

  defp read_time(value) do
    with true <- is_binary(value) and Regex.match?(@whole_seconds, value),
         {:ok, time, 0} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _ -> :error
    end
  end

  defp good_at?(expires_at, %DateTime{} = now) do
    DateTime.compare(now, expires_at) == :lt and
      DateTime.diff(expires_at, now, :second) <= @validity
  end

  defp good_at?(_expires_at, _now), do: false
end
