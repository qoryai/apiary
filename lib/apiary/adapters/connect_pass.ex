defmodule Apiary.Adapters.ConnectPass do
  @moduledoc false

  # A connect pass: the grant this server makes when a person connects an adapter (a node
  # of kind `adapter`, `na_`) to their organisation, for the organisation's connection to
  # it (`ac_`, `Apiary.Adapters.Connection`), carried to the adapter as the `state` of the
  # connect step, which the adapter checks under the instance's public key before it acts
  # on it. The module is hidden from the generated documentation, which every instance
  # serves.
  #
  # Its form. One string, the payload in base64url without padding, `.`, and the
  # signature in base64url without padding, at most `max_length/0` characters. The payload
  # is the JSON bytes the server signed, never serialised again; the signature is 64 bytes
  # of Ed25519 under the instance's signing key (`Apiary.SigningKey`) over the connect
  # pass's message (`Apiary.Contract.SignedMessage.connect_pass/1`):
  # `qory-connect-ed25519-v1`, a line feed, then the payload's bytes.
  #
  # The payload, its members in this order, each required and no other, with no
  # whitespace:
  #
  #   * `version`, 1;
  #   * `adapter_id`, the adapter, by its public id (`na_`);
  #   * `connection_id`, the connection it is made for, by its public id (`ac_`);
  #   * `nonce`, 16 random bytes in base64url without padding, 22 characters;
  #   * `expires_at`, when the pass stops being good, in UTC to the second, as
  #     `2026-10-15T12:15:00Z`: `validity/0` seconds after it was made. Each new pass of a
  #     connection expires strictly later than the one before it, which is how the adapter
  #     tells the newer pass: when that would take a pass more than `validity/0` seconds
  #     ahead (`beyond_validity?/2`), the connection ends instead, and the pass is the first
  #     of a new connection in its place (`issue/3`). So no pass expires more than
  #     `validity/0` seconds after it was made, which the adapter would refuse.
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
  @members ~w(version adapter_id connection_id nonce expires_at)

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  # What a connect pass grants, as `verify/3` gives it back: the adapter's public id, the
  # connection's, the nonce's 16 raw bytes, and when it stops being good, to the second.
  @type pass :: %{
          adapter_id: String.t(),
          connection_id: String.t(),
          nonce: <<_::128>>,
          expires_at: DateTime.t()
        }

  # The longest a connect pass may be, in characters.
  @doc false
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  # How long a connect pass is good for after it is made, in seconds.
  @doc false
  @spec validity() :: pos_integer
  def validity, do: @validity

  # A fresh nonce for a pass: 16 random bytes. The connection keeps the nonce of its latest
  # pass: `Apiary.Adapters.connect/2` makes it with this, and
  # `Apiary.Adapters.Connections.start/3` hands it to `issue/3`.
  @doc false
  @spec new_nonce() :: <<_::128>>
  def new_nonce, do: :crypto.strong_rand_bytes(@nonce_size)

  # issue/3 makes the connect pass of the adapter `adapter_id` (`na_`) for the connection
  # `connection_id` (`ac_`): `{:ok, pass}`, the string, or `{:error, :invalid}` when
  # `adapter_id` is not an adapter's public id, `connection_id` not a connection's, when
  # `opts[:nonce]` is not 16 bytes, when `opts[:now]` is not a `DateTime`, or when
  # `opts[:not_before]` is given and not a `DateTime`; and `{:error, :too_long}` when the
  # pass would be longer than `max_length/0`. No pass is made on an error.
  #
  # It expires at `expires_at/2` of now and `opts[:not_before]`: `validity/0` seconds
  # after now, to the second, or `:not_before` when that is later. The caller that keeps a
  # connection's passes (`Apiary.Adapters.Connections.start/3`) gives `:not_before` as one
  # second after the connection's previous pass expires, and only when that is no later
  # than `validity/0` seconds after now (`beyond_validity?/2`), so the pass expires
  # `validity/0` seconds after now, strictly later than the one before it. When it is
  # later, as for two passes in the same second, or after the clock stepped back, that
  # caller ends the connection (`replaced`) and makes the first pass of a new connection
  # in its place; it gives no `:not_before` for a connection's first pass.
  # It is signed under the instance's signing key, with `opts[:nonce]` as its nonce, 16
  # bytes, which the caller that keeps it makes with `new_nonce/0`, else 16 fresh random
  # bytes. `:now`, a `DateTime`, is the time the pass is made, the current time unless
  # given: that caller gives the time it keeps with the pass, and tests and the shared
  # fixture give one for a known answer. `:key`, a `t:Apiary.SigningKey.t/0`, is for a
  # known answer in tests and the shared fixture only: a production caller passes none,
  # and a pass then has the instance's signing key.
  @doc false
  @spec issue(String.t(), String.t(), keyword) ::
          {:ok, String.t()} | {:error, :invalid | :too_long}
  def issue(adapter_id, connection_id, opts \\ []) do
    key = Keyword.get_lazy(opts, :key, &SigningKey.current/0)
    nonce = Keyword.get_lazy(opts, :nonce, &new_nonce/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    not_before = Keyword.get(opts, :not_before)

    with true <- PublicId.valid?("na", adapter_id),
         true <- PublicId.valid?("ac", connection_id),
         true <- is_binary(nonce) and byte_size(nonce) == @nonce_size,
         %DateTime{} <- now,
         true <- is_nil(not_before) or is_struct(not_before, DateTime) do
      expires_at = expires_at(now, not_before)

      payload = payload(adapter_id, connection_id, nonce, expires_at)

      pass =
        Ed25519.encode(payload) <>
          "." <> Ed25519.encode(SigningKey.sign(key, SignedMessage.connect_pass(payload)))

      if String.length(pass) <= @max_length, do: {:ok, pass}, else: {:error, :too_long}
    else
      _ -> {:error, :invalid}
    end
  end

  # When a pass made at `now` expires, in UTC to the second: `validity/0` seconds after
  # `now`, truncated to the second, or `not_before`, rounded up to the second, when that is
  # later; `not_before` is `nil` for none. `issue/3` signs it, and the caller that keeps a
  # connection's passes keeps it with the pass, so the two are the same time.
  @doc false
  @spec expires_at(DateTime.t(), DateTime.t() | nil) :: DateTime.t()
  def expires_at(%DateTime{} = now, not_before) do
    after_now =
      now
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> DateTime.add(@validity, :second)

    case not_before do
      nil -> after_now
      %DateTime{} -> Enum.max([after_now, whole_second_up(not_before)], DateTime)
    end
  end

  # Whether a pass made at `now` that may expire no earlier than `not_before` would expire
  # more than `validity/0` seconds after `now`, as `expires_at/2` rounds both: `true` when
  # `not_before`, rounded up to the second, is later than `validity/0` seconds after
  # `now`, truncated to the second; `false` when it is that time or earlier, and for
  # `nil`. Such a pass is one the adapter refuses, and `verify/3` too. The caller that
  # keeps a connection's passes makes none: it ends the connection and starts a new one
  # instead (`Apiary.Adapters.Connections.start/3`).
  @doc false
  @spec beyond_validity?(DateTime.t(), DateTime.t() | nil) :: boolean
  def beyond_validity?(%DateTime{} = now, not_before),
    do: DateTime.compare(expires_at(now, not_before), expires_at(now, nil)) == :gt

  defp whole_second_up(time) do
    time = DateTime.shift_zone!(time, "Etc/UTC")
    whole = DateTime.truncate(time, :second)
    if DateTime.compare(whole, time) == :eq, do: whole, else: DateTime.add(whole, 1, :second)
  end

  # verify/3 reads `pass` under `public_key`, the 32 raw bytes of the key that signed it:
  # `{:ok, pass}` (`t:pass/0`), or `:error` for anything that is not a connect pass that
  # key signed, or one that is not good at `now` (`opts[:now]`, the current time unless
  # given): at or after its `expires_at`, or expiring more than `validity/0` seconds after
  # `now`.
  @doc false
  @spec verify(term, term, keyword) :: {:ok, pass} | :error
  def verify(pass, public_key, opts \\ [])

  def verify(pass, <<_::binary-size(32)>> = public_key, opts)
      when is_binary(pass) and byte_size(pass) <= @max_length do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with [encoded_payload, encoded_signature] <- String.split(pass, "."),
         {:ok, payload} <- decode(encoded_payload),
         {:ok, signature} <- Ed25519.decode(encoded_signature, 64),
         true <- Ed25519.verify(SignedMessage.connect_pass(payload), signature, public_key),
         {:ok, read} <- read(payload),
         true <- good_at?(read.expires_at, now) do
      {:ok, read}
    else
      _ -> :error
    end
  end

  def verify(_pass, _public_key, _opts), do: :error

  defp payload(adapter_id, connection_id, nonce, expires_at) do
    Jason.encode!(
      Jason.OrderedObject.new(
        version: @version,
        adapter_id: adapter_id,
        connection_id: connection_id,
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
  # exactly those `issue/3` writes: the members in their order, no whitespace.
  defp read(payload) do
    with {:ok, %{} = map} <- Jason.decode(payload),
         true <- Enum.sort(Map.keys(map)) == Enum.sort(@members),
         true <- map["version"] === @version,
         true <- PublicId.valid?("na", map["adapter_id"]),
         true <- PublicId.valid?("ac", map["connection_id"]),
         {:ok, nonce} <- Ed25519.decode(map["nonce"], @nonce_size),
         {:ok, expires_at} <- read_time(map["expires_at"]),
         true <- payload(map["adapter_id"], map["connection_id"], nonce, expires_at) == payload do
      {:ok,
       %{
         adapter_id: map["adapter_id"],
         connection_id: map["connection_id"],
         nonce: nonce,
         expires_at: expires_at
       }}
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
