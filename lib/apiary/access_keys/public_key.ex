defmodule Apiary.AccessKeys.PublicKey do
  @moduledoc """
  A row of the ledger of public keys (`access_key_public_keys`): one public key, one access
  key, ever, on the instance.

  Every node's key's public key is written here in the transaction that makes the key,
  under the key's id, and refused when it is here already, whatever state its row is in
  and whichever organisation it was in: so a public key never serves a second access key,
  nor comes back once retired. Its `state` follows the key: `current` while the key is
  in use, `tombstone` once retired, with when and why (`retired_reason`: `revoked`,
  `expired`, `node_deleted` or `workspace_deleted`).

  The ledger is the instance's own: it has no organisation and no foreign key, so it
  outlives the purge of the key's workspace and organisation, and no purge walks it.
  """
  use Ecto.Schema

  @typedoc "A public key in the ledger."
  @type t :: %__MODULE__{}

  @typedoc "Why a public key was retired."
  @type reason :: :revoked | :expired | :node_deleted | :workspace_deleted

  @reasons [:revoked, :expired, :node_deleted, :workspace_deleted]

  @primary_key {:public_key, :binary, autogenerate: false}
  schema "access_key_public_keys" do
    field :key_id, :string
    field :state, Ecto.Enum, values: [:current, :tombstone]
    field :received_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :retired_reason, Ecto.Enum, values: @reasons

    timestamps(type: :utc_datetime_usec)
  end

  @doc "reasons/0 is why a public key may be retired."
  @spec reasons() :: [reason]
  def reasons, do: @reasons
end
