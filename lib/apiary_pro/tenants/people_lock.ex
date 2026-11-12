defmodule ApiaryPro.Tenants.PeopleLock do
  @moduledoc """
  A people lock is a row of the edition, one per organisation, keyed by its
  `organisation_id` beside its tenant (`ApiaryPro.Tenants.Tenant`), for the edition to
  lock (`ApiaryPro.Tenants.lock_rows/1`) to keep a change of the organisation's people
  and a write that relies on someone's level there one after the other, without locking
  a membership: a change of an operator's people locks its row `FOR UPDATE`, and a write
  in one of its clients `FOR SHARE`. It holds nothing but its key and when it was
  written.

  The row is written with its tenant, in the same transaction, or by the migration that
  created the table for a tenant written before it, or, for a tenant written without it,
  as it is first locked (`ApiaryPro.Tenants.lock_people/1`); it goes with its tenant. No
  other table references it, so no write elsewhere takes a lock on it through a key. No
  field is ever cast from a form.
  """
  use Ecto.Schema

  @primary_key {:organisation_id, :binary_id, autogenerate: false}
  schema "people_locks" do
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @typedoc "The people lock of one organisation."
  @type t :: %__MODULE__{
          organisation_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t() | nil
        }
end
