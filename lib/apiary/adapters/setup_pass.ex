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
  # The payload, its members in this order, each required and no other, with no
  # whitespace:
  #
  #   * `version`, 1;
  #   * `adapter_id`, the adapter, by its public id (`na_`);
  #   * `nonce`, 16 random bytes in base64url without padding, 22 characters, new for
  #     each pass;
  #   * `expires_at`, when the pass stops being good, in UTC to the second, as
  #     `2026-10-15T12:15:00Z`: `validity/0` seconds after it was made.
  #
  # The adapter keeps the nonce, to take each pass once; this server keeps neither the
  # pass nor its nonce, and compares no setup pass with another.
  #
  # `issue/2` makes one; `verify/3` reads one back: the length, both parts decoded
  # strictly, the signature over the message under the public key given, the payload
  # against the rules above and byte for byte as `issue/2` writes it, and last its time.
  # Any failure is `:error`, whatever the cause. Nothing here touches the database, logs,
  # or puts a pass in an error.

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.{PublicId, SigningKey}

  @max_length 1024
  @version 1
  @validity 900
  @nonce_size 16
  @members ~w(version adapter_id nonce expires_at)

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  # What a setup pass grants, as `verify/3` gives it back: the adapter's public id, the
  # nonce's 16 raw bytes, and when it stops being good, to the second.
  @type pass :: %{adapter_id: String.t(), nonce: <<_::128>>, expires_at: DateTime.t()}

  # The longest a setup pass may be, in characters.
  @doc false
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  # How long a setup pass is good for after it is made, in seconds.
  @doc false
  @spec validity() :: pos_integer
  def validity, do: @validity

  # issue/2 makes the setup pass of the adapter `adapter_id` (`na_`): `{:ok, pass}`, the
  # string, or `{:error, :invalid}` when `adapter_id` is not an adapter's public id, when
  # `opts[:nonce]` is not 16 bytes, or when `opts[:now]` is not a `DateTime`. No pass is
  # made on an error. Its payload has a fixed length, well under `max_length/0`.
  #
  # It expires `validity/0` seconds after now, to the second. It is signed under the
  # instance's signing key, with 16 fresh random bytes as its nonce. `:now`, a
  # `DateTime`, is the time the pass is made, the current time unless given; `:nonce` and
  # `:key`, a `t:Apiary.SigningKey.t/0`, are for a known answer in tests and the shared
  # fixture only: a production caller passes neither.
  @doc false
  @spec issue(String.t(), keyword) :: {:ok, String.t()} | {:error, :invalid}
  def issue(adapter_id, opts \\ []) do
    key = Keyword.get_lazy(opts, :key, &SigningKey.current/0)
    nonce = Keyword.get_lazy(opts, :nonce, fn -> :crypto.strong_rand_bytes(@nonce_size) end)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with true <- PublicId.valid?("na", adapter_id),
         true <- is_binary(nonce) and byte_size(nonce) == @nonce_size,
         %DateTime{} <- now do
      payload = payload(adapter_id, nonce, expires_at(now))

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

  defp payload(adapter_id, nonce, expires_at) do
    Jason.encode!(
      Jason.OrderedObject.new(
        version: @version,
        adapter_id: adapter_id,
        nonce: Ed25519.encode(nonce),
        expires_at: DateTime.to_iso8601(expires_at)
      )
    )
  end

  # Strict base64url without padding: the bytes, encoded again, are the text as given.
  defp decode(text) do
    with {:ok, bytes} when bytes != "" <- Base.url_decode64(text, padding: false),
         true <- Ed25519.encode(bytes) == text do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  # The payload against its rules, every member required and no other, and its bytes
  # exactly those `issue/2` writes: the members in their order, no whitespace.
  defp read(payload) do
    with {:ok, %{} = map} <- Jason.decode(payload),
         true <- Enum.sort(Map.keys(map)) == Enum.sort(@members),
         true <- map["version"] === @version,
         true <- PublicId.valid?("na", map["adapter_id"]),
         {:ok, nonce} <- Ed25519.decode(map["nonce"], @nonce_size),
         {:ok, expires_at} <- read_time(map["expires_at"]),
         true <- payload(map["adapter_id"], nonce, expires_at) == payload do
      {:ok, %{adapter_id: map["adapter_id"], nonce: nonce, expires_at: expires_at}}
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
