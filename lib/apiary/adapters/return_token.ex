defmodule Apiary.Adapters.ReturnToken do
  @moduledoc false

  # A return: what an adapter hands back, as the query parameter `return` of the link to
  # `/integrations/{ac_…}`, once a person comes back from connecting it to their
  # organisation with a connect pass (`Apiary.Adapters.ConnectPass`). The adapter makes
  # one only after it verified the pass. It says how the connect step ended, for the
  # connection the pass was made for, and is signed under the adapter's enrolled key. The
  # module is hidden from the generated documentation, which every instance serves.
  #
  # Its form. One string, the payload in base64url without padding, `.`, and the
  # signature in base64url without padding, at most `max_length/0` characters. The
  # signature is 64 bytes of Ed25519 under one of the adapter's access keys in use over
  # the return's message (`Apiary.Contract.SignedMessage.connect_return/1`):
  # `qory-connect-return-ed25519-v1`, a line feed, then the payload's bytes as sent.
  #
  # The payload, a JSON object, its members in any order, none twice, and no other:
  #
  #   * `version`, 1;
  #   * `connection_id`, the connection, by its public id (`ac_`);
  #   * `nonce`, the nonce of the pass it answers, 16 bytes in base64url without padding;
  #   * `outcome`, `linked`, `refused` or `cancelled`;
  #   * `reason`, with `refused` alone, one of `reasons/0`;
  #   * `expires_at`, when it stops being good, in UTC to the second, as
  #     `2026-10-15T12:05:00Z`, `validity/0` seconds after it was made at most.
  #
  # `verify/2` reads one: the length, both parts decoded strictly, the signature over the
  # message under one of the public keys given, then the payload against the rules above.
  # Its time is `good_at?/2`'s, asked apart, so that a caller decides when to ask it.
  # Any failure is `:error`, whatever the cause. Nothing here touches the database, logs,
  # or puts a return in an error.

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.PublicId

  @max_length 1024
  @version 1
  @validity 300
  @nonce_size 16
  @outcomes %{"linked" => :linked, "refused" => :refused, "cancelled" => :cancelled}
  @reasons ~w(not_admin installation_taken installation_not_confirmed installation_suspended
              permission_missing pass_expired github_unavailable)a
  @required ~w(version connection_id nonce outcome expires_at)

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc "Why the adapter refused to link, as a return names it."
  @type reason ::
          :not_admin
          | :installation_taken
          | :installation_not_confirmed
          | :installation_suspended
          | :permission_missing
          | :pass_expired
          | :github_unavailable

  # What a return says, as `verify/2` reads it: the connection's public id, the nonce's 16
  # raw bytes, how it ended and why, for `:refused` alone, and when it stops being good.
  @type t :: %{
          connection_id: String.t(),
          nonce: <<_::128>>,
          outcome: :linked | :refused | :cancelled,
          reason: reason | nil,
          expires_at: DateTime.t()
        }

  # The longest a return may be, in characters.
  @doc false
  @spec max_length() :: pos_integer
  def max_length, do: @max_length

  # How long after it is made a return may still be good, in seconds.
  @doc false
  @spec validity() :: pos_integer
  def validity, do: @validity

  # The reasons a refused return may give, in the contract's order.
  @doc false
  @spec reasons() :: [reason]
  def reasons, do: @reasons

  # verify/2 reads `token` under `public_keys`, the 32 raw bytes of each access key of
  # the adapter in use: `{:ok, return}` (`t:t/0`), or `:error` for anything that is not a
  # return one of those keys signed, as the rules above have it. Its time is not asked
  # here: `good_at?/2` is.
  @doc false
  @spec verify(term, term) :: {:ok, t} | :error
  def verify(token, public_keys)
      when is_binary(token) and byte_size(token) <= @max_length and is_list(public_keys) do
    with [encoded_payload, encoded_signature] <- String.split(token, "."),
         {:ok, payload} <- decode(encoded_payload),
         {:ok, signature} <- Ed25519.decode(encoded_signature, 64),
         true <- signed_by_one?(payload, signature, public_keys) do
      read(payload)
    else
      _ -> :error
    end
  end

  def verify(_token, _public_keys), do: :error

  # good_at?/2 says whether a return is good at `now`: before its `expires_at`, and
  # expiring no more than `validity/0` seconds after `now`.
  @doc false
  @spec good_at?(t, DateTime.t()) :: boolean
  def good_at?(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(now, expires_at) == :lt and
      DateTime.diff(expires_at, now, :second) <= @validity
  end

  def good_at?(_return, _now), do: false

  defp signed_by_one?(payload, signature, public_keys) do
    message = SignedMessage.connect_return(payload)

    Enum.any?(public_keys, fn
      <<_::binary-size(32)>> = key -> Ed25519.verify(message, signature, key)
      _other -> false
    end)
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

  # The payload against its rules: an object, no member twice, every required member,
  # `reason` exactly with `refused`, and no other.
  defp read(payload) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(payload, objects: :ordered_objects),
         keys = Enum.map(values, &elem(&1, 0)),
         true <- Enum.uniq(keys) == keys,
         map = Map.new(values),
         true <- map["version"] === @version,
         true <- PublicId.valid?("ac", map["connection_id"]),
         {:ok, nonce} <- Ed25519.decode(map["nonce"], @nonce_size),
         {:ok, outcome} <- Map.fetch(@outcomes, map["outcome"]),
         {:ok, reason} <- read_reason(outcome, map),
         true <- Enum.sort(keys) == Enum.sort(members(outcome)),
         {:ok, expires_at} <- read_time(map["expires_at"]) do
      {:ok,
       %{
         connection_id: map["connection_id"],
         nonce: nonce,
         outcome: outcome,
         reason: reason,
         expires_at: expires_at
       }}
    else
      _ -> :error
    end
  end

  defp members(:refused), do: ["reason" | @required]
  defp members(_outcome), do: @required

  defp read_reason(:refused, %{"reason" => reason}) when is_binary(reason) do
    case Enum.find(@reasons, &(Atom.to_string(&1) == reason)) do
      nil -> :error
      known -> {:ok, known}
    end
  end

  defp read_reason(:refused, _map), do: :error
  defp read_reason(_outcome, _map), do: {:ok, nil}

  defp read_time(value) do
    with true <- is_binary(value) and Regex.match?(@whole_seconds, value),
         {:ok, time, 0} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _ -> :error
    end
  end
end
