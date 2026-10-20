defmodule Apiary.Adapters.SeenRequests do
  @moduledoc false

  # The signatures of the requests of an adapter's access key that were accepted, kept so
  # the same request sent again is refused, as the integration contract's replay rule has
  # it (`definitions.schema.json`): the check is keyed on the 64 decoded bytes of
  # `X-Qory-Signature-Ed25519`, and each signature is kept until the request's `time` (a
  # POST) or `X-Qory-Timestamp` (a GET) is more than 300 seconds behind the clock.
  #
  # The store is the table `adapter_seen_requests`, whose primary key is the access key
  # and the signature, so it holds across every node of a cluster: `record/4` inserts the
  # pair, and a pair that is there already is a replay. A row is kept until
  # `max(time, now) + retention/0`: at least `retention/0` seconds after it was accepted,
  # and `retention/0` - 300 seconds after the request's window closed, a margin for clocks
  # that differ between the nodes. `purge/1`, run by `Apiary.Adapters.SeenRequestsPurge`,
  # deletes the rows past that time; a row not yet deleted refuses nothing a fresh request
  # could be, since its request's time is outside the window by then.

  import Ecto.Query, only: [from: 2]

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo

  @retention 600

  # How long a signature is kept, in seconds, from its request's time or from when it was
  # accepted, whichever is later.
  @doc false
  @spec retention() :: pos_integer
  def retention, do: @retention

  # Records `signature`, 64 bytes, as accepted under `access_key` for a request whose time
  # is `time` (Unix seconds), `now` being the contract's clock: `:ok`, or `:seen` when the
  # key's request with that signature was accepted before.
  @doc false
  @spec record(AccessKey.t(), <<_::512>>, integer, integer) :: :ok | :seen
  def record(%AccessKey{id: id}, <<_::binary-size(64)>> = signature, time, now)
      when is_binary(id) and is_integer(time) and is_integer(now) do
    expires_at = DateTime.from_unix!(max(time, now) + @retention, :second)

    row = %{
      access_key_id: Ecto.UUID.dump!(id),
      signature: signature,
      expires_at: DateTime.add(expires_at, 0, :microsecond)
    }

    case Repo.insert_all("adapter_seen_requests", [row], on_conflict: :nothing) do
      {1, _rows} -> :ok
      {0, _rows} -> :seen
    end
  end

  # Deletes the signatures kept past their time at `now`: the count deleted.
  @doc false
  @spec purge(DateTime.t()) :: non_neg_integer
  def purge(%DateTime{} = now) do
    {count, _rows} =
      Repo.delete_all(from(s in "adapter_seen_requests", where: s.expires_at < ^now))

    count
  end
end
