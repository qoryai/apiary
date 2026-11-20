defmodule Apiary.Artifacts.Delivery do
  @moduledoc false

  # Where the delivery of a version to an adapter stands, stored on the version
  # (`Apiary.Artifacts.Version`: `delivery`, `delivery_reply`, `delivery_failure` and
  # `delivery_at`). A delivery is one `change_request` entry of the adapter's change feed,
  # for the version's target.
  #
  # A version's target and type are those of its artifact: an artifact is unique per work
  # item, type and name, and a delivered output's name is the target's (Q-73), so the
  # versions of one artifact are the versions for one target and type.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Artifacts.Version
  alias Apiary.Repo

  @doc """
  previous_address/1 is the address of `version`'s previous delivery, the `address` of the
  adapter's newest reply for the same target and type, for the entry's `previous.address`:
  a map as the adapter sent it, or nil when no other version of the artifact has a reply,
  or when the newest reply has no address (a reply for an entry that asked for no change).

  The newest reply is the one with the latest `delivery_at`, then the latest
  `inserted_at` of its version. A version with a reply and no `delivery_at` is older than
  every version with one. The version itself is left out. It reads the versions of the
  artifact by `artifact_id`, which the unique index on `artifact_id` and `number` serves.
  """
  @spec previous_address(Version.t()) :: map | nil
  def previous_address(%Version{id: id, artifact_id: artifact_id}) do
    reply =
      Repo.one(
        from v in Version,
          where: v.artifact_id == ^artifact_id and v.id != ^id and not is_nil(v.delivery_reply),
          order_by: [desc_nulls_last: v.delivery_at, desc: v.inserted_at],
          limit: 1,
          select: v.delivery_reply
      )

    reply && reply["address"]
  end

  @doc """
  record_invalid/2 stores that the entry for `version` failed Qory Apiary's check, so
  nothing is sent: `result` is what `Apiary.Adapters.ChangeRequest.validate/1` returned
  for the entry. For `{:error, summary}` it sets `delivery` to `:failed`,
  `delivery_failure` to `:invalid` and `delivery_at` to the time, and returns the version
  with them. For `:ok` it changes nothing and returns the version. A version that already
  has a `delivery` is left as it is and gets `{:error, :delivery_set}`, so a delivery that
  was sent, or a reply that was stored, is not overwritten. The run is not stopped: only
  the delivery fails.

  The summary is not stored: the columns have no place for it.
  """
  @spec record_invalid(Version.t(), :ok | {:error, map}) ::
          {:ok, Version.t()} | {:error, :delivery_set}
  def record_invalid(%Version{} = version, :ok), do: {:ok, version}

  def record_invalid(%Version{id: id} = version, {:error, %{valid: false}}) do
    at = DateTime.utc_now()

    {count, _rows} =
      Repo.update_all(
        from(v in Version, where: v.id == ^id and is_nil(v.delivery)),
        set: [delivery: :failed, delivery_failure: :invalid, delivery_at: at]
      )

    case count do
      1 -> {:ok, %{version | delivery: :failed, delivery_failure: :invalid, delivery_at: at}}
      0 -> {:error, :delivery_set}
    end
  end
end
